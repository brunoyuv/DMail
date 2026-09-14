// MPL-2.0: https://mozilla.org/MPL/2.0/
// Harmony browser-session boundary around Thunderbird's original OAuth helpers.
import Foundation
import FoundationNetworking

public enum BrowserOAuthError: String, Error {
    case invalidConfiguration, invalidCallback, stateMismatch, expiredSession
    case authorizationDenied, tooManySessions, invalidTokenResponse
}

public struct BrowserAuthorization: Codable, Sendable {
    public let id: String
    public let url: String
    public let expiresAt: Double
}

public struct OAuthTokenSet: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Double
    public let scope: String?

    public static func parse(_ data: Data, now: Date = Date(), previousRefreshToken: String? = nil) throws -> Self {
        struct Response: Decodable {
            let access_token: String
            let token_type: String
            let expires_in: Double
            let refresh_token: String?
            let scope: String?
        }
        guard data.count <= 64 * 1024, let response = try? JSONDecoder().decode(Response.self, from: data),
              response.token_type.lowercased() == "bearer", validToken(response.access_token),
              response.expires_in.isFinite, response.expires_in > 0, response.expires_in <= 366 * 86400,
              response.refresh_token.map(validToken) ?? true,
              response.scope.map({ $0.utf8.count <= 8192 && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }) ?? true,
              previousRefreshToken.map(validToken) ?? true else { throw BrowserOAuthError.invalidTokenResponse }
        return Self(accessToken: response.access_token, refreshToken: response.refresh_token ?? previousRefreshToken,
                    expiresAt: now.timeIntervalSince1970 + response.expires_in, scope: response.scope)
    }

    static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32768 && value.utf8.allSatisfy { $0 > 32 && $0 < 127 }
    }
}

public final class BrowserOAuthSessions: @unchecked Sendable {
    private struct Pending {
        let request: OAuth2.Request
        let pkce: OAuth2.PKCE
        let state: String
        let expires: Date
    }
    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    public init() {}

    // Callers supply an actual registered client ID and redirect URI. Provider
    // documents cannot supply/replace the registration used by this boundary.
    public func begin(_ request: OAuth2.Request, hint: String? = nil,
                      parameters: [String: String] = [:], now: Date = Date()) throws -> BrowserAuthorization {
        try Self.validate(request)
        guard hint.map({ $0.utf8.count <= 320 && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }) ?? true,
              parameters.keys.allSatisfy({ ["access_type", "prompt"].contains($0) }),
              parameters.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 && $0.utf8.allSatisfy { $0 >= 32 && $0 < 127 } })
        else { throw BrowserOAuthError.invalidConfiguration }
        let pkce = OAuth2.PKCE()
        let state = OAuth2.PKCE().codeVerifier
        let id = UUID().uuidString
        let expires = now.addingTimeInterval(600)
        var url = URLComponents(url: request.authURL(hint: hint, pkce: pkce), resolvingAgainstBaseURL: false)!
        url.queryItems!.append(URLQueryItem(name: "state", value: state))
        for name in parameters.keys.sorted() { url.queryItems!.append(URLQueryItem(name: name, value: parameters[name])) }
        lock.lock(); defer { lock.unlock() }
        pending = pending.filter { $0.value.expires > now }
        guard pending.count < 8 else { throw BrowserOAuthError.tooManySessions }
        pending[id] = Pending(request: request, pkce: pkce, state: state, expires: expires)
        return BrowserAuthorization(id: id, url: url.url!.absoluteString, expiresAt: expires.timeIntervalSince1970)
    }

    // Claim a valid callback once, before network exchange. A lost response is
    // not replayed with the same authorization code. Invalid unrelated callbacks
    // leave the pending session available for its real response.
    public func consume(id: String, callback: String, now: Date = Date()) throws -> URLRequest {
        lock.lock(); defer { lock.unlock() }
        guard let session = pending[id] else { throw BrowserOAuthError.expiredSession }
        guard now < session.expires else { pending.removeValue(forKey: id); throw BrowserOAuthError.expiredSession }
        guard callback.utf8.count <= 32768, !callback.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
              var components = URLComponents(string: callback), components.fragment == nil,
              components.user == nil, components.password == nil, let query = components.queryItems
        else { throw BrowserOAuthError.invalidCallback }
        components.query = nil
        guard components.string == session.request.redirectURI else { throw BrowserOAuthError.invalidCallback }
        var values: [String: String] = [:]
        for item in query {
            guard values[item.name] == nil, let value = item.value else { throw BrowserOAuthError.invalidCallback }
            values[item.name] = value
        }
        guard let state = values["state"], Self.equalState(state, session.state) else { throw BrowserOAuthError.stateMismatch }
        guard (values["code"] == nil) != (values["error"] == nil) else { throw BrowserOAuthError.invalidCallback }
        if values["error"] != nil {
            pending.removeValue(forKey: id)
            throw BrowserOAuthError.authorizationDenied
        }
        guard let code = values["code"], !code.isEmpty, code.utf8.count <= 16384,
              !code.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        else { throw BrowserOAuthError.invalidCallback }
        pending.removeValue(forKey: id)
        var request = try URLRequest.token(session.request, code: code, pkce: session.pkce)
        // Remove the upstream empty placeholder. The bridge adds a configured
        // Google Desktop secret only to matching Google token requests.
        request.httpBody = Self.withoutEmptySecret(request.httpBody!)
        return request
    }

    public func cancel(id: String) {
        lock.lock(); defer { lock.unlock() }
        pending.removeValue(forKey: id)
    }

    public static func refresh(_ registration: OAuth2.Request, token: String) throws -> URLRequest {
        try validate(registration)
        guard OAuthTokenSet.validToken(token) else { throw BrowserOAuthError.invalidTokenResponse }
        var request = try URLRequest.refreshToken(registration, refreshToken: token)
        request.httpBody = withoutEmptySecret(request.httpBody!)
        return request
    }

    private static func withoutEmptySecret(_ body: Data) -> Data {
        Data(String(decoding: body, as: UTF8.self).split(separator: "&").filter { $0 != "client_secret=" }.joined(separator: "&").utf8)
    }

    private static func equalState(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in a.indices { difference |= a[i] ^ b[i] }
        return difference == 0
    }

    public static func validate(_ request: OAuth2.Request) throws {
        func endpoint(_ value: String) -> Bool {
            guard value.utf8.count <= 2048, let url = URLComponents(string: value), url.scheme == "https",
                  let host = url.host, MailDiscovery.validHostname(host), url.user == nil, url.password == nil,
                  url.fragment == nil, url.query == nil, (1...65535).contains(url.port ?? 443)
            else { return false }
            return !value.unicodeScalars.contains { $0.value <= 32 || $0.value == 127 }
        }
        guard endpoint(request.authURI), endpoint(request.tokenURI), request.responseType == "code",
              !request.clientID.isEmpty, request.clientID.utf8.count <= 512,
              request.clientID.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              !request.scope.isEmpty, request.scope.count <= 32,
              request.scope.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && $0.utf8.allSatisfy { $0 > 32 && $0 < 127 } }),
              request.redirectURI.utf8.count <= 2048,
              !request.redirectURI.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
              let redirect = URLComponents(string: request.redirectURI), let scheme = redirect.scheme,
              redirect.query == nil, redirect.fragment == nil, redirect.user == nil, redirect.password == nil,
              !redirect.path.isEmpty,
              (scheme == "https" && redirect.host.map(MailDiscovery.validHostname) == true) ||
                (scheme == "http" && redirect.host == "127.0.0.1" && (1...65535).contains(redirect.port ?? 0)) ||
                (scheme.contains(".") && scheme != "https" && scheme != "http" && redirect.port == nil)
        else { throw BrowserOAuthError.invalidConfiguration }
    }
}
