@testable import Autoconfiguration
import Foundation
import FoundationNetworking
import Testing

struct BrowserOAuthTests {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)
    private func registration(redirect: String = "org.example.mail:/oauth/google", auth: String = "https://login.example.test/authorize") throws -> OAuth2.Request {
        try OAuth2.Request(authURI: auth, tokenURI: "https://login.example.test/token", redirectURI: redirect,
                           responseType: "code", scope: ["mail", "offline_access"], clientID: "registered-client+id")
    }
    private func query(_ url: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(string: url)!.queryItems!.map { ($0.name, $0.value!) })
    }
    private func callback(_ authorization: BrowserAuthorization, suffix: String = "") -> String {
        "org.example.mail:/oauth/google?state=\(query(authorization.url)["state"]!)&code=one%2Btime%26code\(suffix)"
    }

    @Test func browserRequestUsesFreshStateAndOriginalPKCE() throws {
        let sessions = BrowserOAuthSessions()
        let first = try sessions.begin(registration(), hint: "identity@example.test", parameters: ["access_type": "offline"], now: now)
        let second = try sessions.begin(registration(), now: now)
        let firstQuery = query(first.url), secondQuery = query(second.url)
        #expect(firstQuery["client_id"] == "registered-client+id")
        #expect(firstQuery["login_hint"] == "identity@example.test")
        #expect(firstQuery["code_challenge_method"] == "S256")
        #expect(firstQuery["code_verifier"] == nil)
        #expect(firstQuery["state"]!.count == 43)
        #expect(firstQuery["state"] != secondQuery["state"])
        #expect(firstQuery["code_challenge"] != secondQuery["code_challenge"])
        #expect(first.id != second.id)
        #expect(first.expiresAt == now.timeIntervalSince1970 + 600)
        let exchange = try sessions.consume(id: first.id, callback: callback(first), now: now)
        #expect(exchange.url?.absoluteString == "https://login.example.test/token")
        #expect(exchange.httpMethod == "POST")
        #expect(exchange.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let fields = query("https://example.test/?" + String(decoding: exchange.httpBody!, as: UTF8.self))
        #expect(fields["code"] == "one+time&code")
        #expect(fields["client_secret"] == nil)
        #expect(OAuth2.PKCE(codeVerifier: fields["code_verifier"]!).codeChallenge == firstQuery["code_challenge"])
        #expect(throws: BrowserOAuthError.expiredSession) { try sessions.consume(id: first.id, callback: callback(first), now: now) }
    }

    @Test func callbackMustMatchRegisteredDestinationAndState() throws {
        let sessions = BrowserOAuthSessions()
        let authorization = try sessions.begin(registration(), now: now)
        let valid = callback(authorization)
        for invalid in [valid.replacingOccurrences(of: "/oauth/google", with: "/oauth/microsoft"),
                        valid.replacingOccurrences(of: "org.example.mail:", with: "org.other.mail:"),
                        valid.replacingOccurrences(of: ":/oauth", with: "://oauth"), valid + "#code=wrong",
                        valid + "&code=duplicate", valid + "&state=duplicate", valid + "&error=access_denied",
                        valid.replacingOccurrences(of: "one%2Btime%26code", with: "%0D%0A") ] {
            #expect(throws: BrowserOAuthError.invalidCallback) { try sessions.consume(id: authorization.id, callback: invalid, now: now) }
        }
        let wrong = valid.replacingOccurrences(of: query(authorization.url)["state"]!, with: "wrong-state")
        #expect(throws: BrowserOAuthError.stateMismatch) { try sessions.consume(id: authorization.id, callback: wrong, now: now) }
        #expect(try sessions.consume(id: authorization.id, callback: valid, now: now).httpMethod == "POST")
    }

    @Test func deniedCancelledExpiredAndCrossSessionCallbacksCannotExchange() throws {
        let sessions = BrowserOAuthSessions()
        let first = try sessions.begin(registration(), now: now)
        let second = try sessions.begin(registration(), now: now)
        #expect(throws: BrowserOAuthError.stateMismatch) { try sessions.consume(id: second.id, callback: callback(first), now: now) }
        let denied = callback(first).replacingOccurrences(of: "code=one%2Btime%26code", with: "error=access_denied")
        #expect(throws: BrowserOAuthError.authorizationDenied) { try sessions.consume(id: first.id, callback: denied, now: now) }
        #expect(throws: BrowserOAuthError.expiredSession) { try sessions.consume(id: first.id, callback: callback(first), now: now) }
        sessions.cancel(id: second.id)
        #expect(throws: BrowserOAuthError.expiredSession) { try sessions.consume(id: second.id, callback: callback(second), now: now) }
        let expired = try sessions.begin(registration(), now: now)
        #expect(throws: BrowserOAuthError.expiredSession) { try sessions.consume(id: expired.id, callback: callback(expired), now: now.addingTimeInterval(600)) }
    }

    @Test func concurrentCallbacksClaimCodeOnlyOnce() async throws {
        let sessions = BrowserOAuthSessions()
        let authorization = try sessions.begin(registration(), now: now)
        let url = callback(authorization), timestamp = now
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 { group.addTask { (try? sessions.consume(id: authorization.id, callback: url, now: timestamp)) != nil } }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        #expect(successes == 1)
    }

    @Test func pendingSessionLimitExpiresAndCanBeCancelled() throws {
        let sessions = BrowserOAuthSessions()
        var ids: [String] = []
        for _ in 0..<8 { ids.append(try sessions.begin(registration(), now: now).id) }
        #expect(throws: BrowserOAuthError.tooManySessions) { try sessions.begin(registration(), now: now) }
        sessions.cancel(id: ids[0])
        _ = try sessions.begin(registration(), now: now)
        _ = try sessions.begin(registration(), now: now.addingTimeInterval(601))
    }

    @Test func decodedConfigurationsStillRequireValidation() throws {
        var data: [String: Any] = ["authURI": "https://login.example.test/auth", "tokenURI": "https://login.example.test/token",
            "redirectURI": "org.example.mail:/oauth/google", "responseType": "code", "scope": ["mail"], "hosts": [], "clientID": "registered"]
        for pair in [("authURI", "http://login.example.test/auth"), ("tokenURI", "https://user:pass@login.example.test/token"),
                     ("authURI", "https://login.example.test/auth?client_id=other"), ("tokenURI", "https://login.example.test/token#fragment"),
                     ("redirectURI", "javascript:alert(1)"), ("redirectURI", "http://example.test/callback"),
                     ("redirectURI", "org.example.mail:/callback?state=old"), ("responseType", "token"), ("clientID", "bad\nclient")] {
            let previous = data[pair.0]; data[pair.0] = pair.1
            let request = try JSONDecoder().decode(OAuth2.Request.self, from: JSONSerialization.data(withJSONObject: data))
            #expect(throws: BrowserOAuthError.invalidConfiguration) { try BrowserOAuthSessions().begin(request, now: now) }
            data[pair.0] = previous
        }
        #expect(throws: BrowserOAuthError.invalidConfiguration) {
            try BrowserOAuthSessions().begin(registration(), parameters: ["redirect_uri": "https://other.test/callback"], now: now)
        }
    }

    @Test func tokenResponsePreservesRefreshUnlessProviderRotatesIt() throws {
        let body = Data(#"{"access_token":"access-token","token_type":"Bearer","expires_in":3600,"scope":"mail"}"#.utf8)
        let token = try OAuthTokenSet.parse(body, now: now, previousRefreshToken: "previous-refresh")
        #expect(token.refreshToken == "previous-refresh")
        #expect(token.expiresAt == now.timeIntervalSince1970 + 3600)
        let rotated = Data(#"{"access_token":"access-token","token_type":"bearer","expires_in":3600,"refresh_token":"rotated"}"#.utf8)
        #expect(try OAuthTokenSet.parse(rotated, previousRefreshToken: "previous").refreshToken == "rotated")
        let refresh = try BrowserOAuthSessions.refresh(registration(), token: "refresh+token&value")
        #expect(refresh.url?.query == nil)
        let fields = query("https://example.test/?" + String(decoding: refresh.httpBody!, as: UTF8.self))
        #expect(fields["refresh_token"] == "refresh+token&value")
        #expect(fields["grant_type"] == "refresh_token")
        #expect(fields["client_secret"] == nil)
    }

    @Test func malformedOrUnsafeTokensAreRejected() {
        for body in [#"{"error":"invalid_grant"}"#,
                     #"{"access_token":"token","token_type":"mac","expires_in":3600}"#,
                     #"{"access_token":"token\r\nheader","token_type":"Bearer","expires_in":3600}"#,
                     #"{"access_token":"token","token_type":"Bearer","expires_in":0}"#,
                     #"{"access_token":"token","token_type":"Bearer","expires_in":3600,"refresh_token":""}"#,
                     String(repeating: "x", count: 65537)] {
            #expect(throws: BrowserOAuthError.invalidTokenResponse) { try OAuthTokenSet.parse(Data(body.utf8)) }
        }
    }

    @Test func loopbackRequiresExplicitPortAndExactLiteralAddress() throws {
        let sessions = BrowserOAuthSessions()
        let redirect = "http://127.0.0.1:45678/oauth2redirect"
        let authorization = try sessions.begin(registration(redirect: redirect), now: now)
        let state = query(authorization.url)["state"]!
        #expect(try sessions.consume(id: authorization.id, callback: "\(redirect)?state=\(state)&code=synthetic", now: now).httpMethod == "POST")
        for invalid in ["http://localhost:45678/oauth2redirect", "http://127.0.0.2:45678/oauth2redirect",
                        "http://0.0.0.0:45678/oauth2redirect", "http://192.168.0.1:45678/oauth2redirect",
                        "http://127.0.0.1/oauth2redirect", "http://127.0.0.1:0/oauth2redirect",
                        "http://127.0.0.1.example.test:45678/oauth2redirect"] {
            #expect(throws: BrowserOAuthError.invalidConfiguration) { try sessions.begin(registration(redirect: invalid), now: now) }
        }
    }

    @Test func microsoftPersonalRegistrationUsesConsumersForBothEndpoints() throws {
        let personal = try MailOAuthProvider.microsoft.registration(clientID: "synthetic", redirectURI: "http://127.0.0.1:49152/oauth2redirect", microsoftPersonalOnly: true)
        #expect(personal.authURI == "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize")
        #expect(personal.tokenURI == "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")
    }

    @Test func microsoftCodeAndRefreshFormsExplicitlyRetainTheAuthorizedOutlookResource() throws {
        for personalOnly in [false, true] {
            let registration = try MailOAuthProvider.microsoft.registration(clientID: "synthetic+client",
                redirectURI: "http://127.0.0.1:49152/oauth2redirect", microsoftPersonalOnly: personalOnly)
            let sessions = BrowserOAuthSessions()
            let authorization = try sessions.begin(registration, now: now)
            let authorized = query(authorization.url)
            let callback = "\(registration.redirectURI)?state=\(authorized["state"]!)&code=one%2Btime%26code"
            let exchange = try sessions.consume(id: authorization.id, callback: callback, now: now)
            let refresh = try BrowserOAuthSessions.refresh(registration, token: "refresh+token&value")
            for request in [exchange, refresh] {
                #expect(request.url?.absoluteString == registration.tokenURI)
                #expect(request.url?.query == nil)
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
                let fields = query("https://example.test/?" + String(decoding: request.httpBody!, as: UTF8.self))
                #expect(fields["scope"] == authorized["scope"])
                #expect(fields["client_id"] == "synthetic+client")
                #expect(fields["client_secret"] == nil)
                if fields["grant_type"] == "authorization_code" {
                    #expect(fields["code"] == "one+time&code")
                    #expect(fields["redirect_uri"] == registration.redirectURI)
                    #expect(OAuth2.PKCE(codeVerifier: fields["code_verifier"]!).codeChallenge == authorized["code_challenge"])
                } else {
                    #expect(fields["grant_type"] == "refresh_token")
                    #expect(fields["refresh_token"] == "refresh+token&value")
                }
            }
            #expect(throws: BrowserOAuthError.expiredSession) { try sessions.consume(id: authorization.id, callback: callback, now: now) }
        }
    }

    @Test func explicitOutlookTokenScopesDoNotChangeGoogleOrOtherRegistrations() throws {
        let google = try MailOAuthProvider.google.registration(clientID: "synthetic-google", redirectURI: "http://127.0.0.1:49152/oauth2redirect")
        let microsoft = try MailOAuthProvider.microsoft.registration(clientID: "synthetic", redirectURI: google.redirectURI)
        let registrations = [google,
            try OAuth2.Request(authURI: microsoft.authURI, tokenURI: "https://login.microsoftonline.com.example.test/common/oauth2/v2.0/token",
                redirectURI: google.redirectURI, responseType: "code", scope: microsoft.scope, clientID: "synthetic"),
            try OAuth2.Request(authURI: microsoft.authURI, tokenURI: microsoft.tokenURI,
                redirectURI: google.redirectURI, responseType: "code", scope: ["https://graph.microsoft.com/Mail.Read", "offline_access"], clientID: "synthetic")]
        for registration in registrations {
            let sessions = BrowserOAuthSessions()
            let authorization = try sessions.begin(registration, now: now)
            let callback = "\(registration.redirectURI)?state=\(query(authorization.url)["state"]!)&code=synthetic"
            for request in [try sessions.consume(id: authorization.id, callback: callback, now: now),
                            try BrowserOAuthSessions.refresh(registration, token: "refresh+token")] {
                let fields = query("https://example.test/?" + String(decoding: request.httpBody!, as: UTF8.self))
                #expect(fields["scope"] == nil)
                #expect(fields["client_secret"] == nil)
            }
        }
    }
}
