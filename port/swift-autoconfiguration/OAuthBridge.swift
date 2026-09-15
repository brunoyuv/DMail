// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation

private let browserOAuthSessions = BrowserOAuthSessions()
private struct OAuthInput: Decodable {
    let operation: String
    let provider: MailOAuthProvider?
    let clientID: String?
    let redirectURI: String?
    let email: String?
    let id: String?
    let callback: String?
    let refreshToken: String?
    let microsoftPersonalOnly: Bool?

    func registration() throws -> OAuth2.Request {
        guard let provider, let clientID, let redirectURI else { throw BrowserOAuthError.invalidConfiguration }
        return try provider.registration(clientID: clientID, redirectURI: redirectURI, microsoftPersonalOnly: microsoftPersonalOnly ?? false)
    }
}
private struct OAuthReply: Encodable {
    var authorization: BrowserAuthorization?
    var tokens: OAuthTokenSet?
    var cancelled: Bool?
    var error: String?
}
@_cdecl("thunderbird_oauth_request")
public func oauthRequest(_ raw: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let raw, let string = String(validatingCString: raw), string.utf8.count <= 128 * 1024 else { return nil }
    let reply: OAuthReply
    do {
        let input = try JSONDecoder().decode(OAuthInput.self, from: Data(string.utf8))
        switch input.operation {
        case "begin":
            reply = OAuthReply(authorization: try browserOAuthSessions.begin(input.registration(), hint: input.email,
                parameters: input.provider!.authorizationParameters))
        case "callback":
            guard let id = input.id, let callback = input.callback else { throw BrowserOAuthError.invalidCallback }
            let request = try GoogleDesktopAuthentication.apply(browserOAuthSessions.consume(id: id, callback: callback))
            reply = OAuthReply(tokens: try OAuthTokenSet.parse(OAuthTokenTransfer().submit(request)))
        case "refresh":
            guard let token = input.refreshToken else { throw BrowserOAuthError.invalidTokenResponse }
            let request = try GoogleDesktopAuthentication.apply(BrowserOAuthSessions.refresh(input.registration(), token: token))
            reply = OAuthReply(tokens: try OAuthTokenSet.parse(OAuthTokenTransfer().submit(request), previousRefreshToken: token))
        case "cancel":
            guard let id = input.id else { throw BrowserOAuthError.invalidCallback }
            browserOAuthSessions.cancel(id: id)
            reply = OAuthReply(cancelled: true)
        default: throw BrowserOAuthError.invalidConfiguration
        }
    } catch {
        reply = OAuthReply(error: (error as? BrowserOAuthError)?.rawValue ?? (error as? OAuthTransferError)?.rawValue ?? "invalidConfiguration")
    }
    guard let data = try? JSONEncoder().encode(reply) else { return nil }
    let bytes = Array(data)
    let output = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
    for (index, byte) in bytes.enumerated() { output[index] = CChar(bitPattern: byte) }
    output[bytes.count] = 0
    return output
}
