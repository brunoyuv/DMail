@testable import Autoconfiguration
import Foundation
import FoundationNetworking
import Testing

struct GoogleDesktopAuthenticationTests {
    let registration = GoogleDesktopRegistration(clientID: "synthetic-desktop-client", clientSecret: "synthetic+&=secret")
    func values(_ request: URLRequest) -> [String: String] {
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: URLComponents(string: "https://local.invalid/?" + body)!.queryItems!.map { ($0.name, $0.value!) })
    }
    @Test func codeExchangeKeepsPKCEAndEncodesSecretOnlyInGooglePOST() throws {
        let sessions = BrowserOAuthSessions()
        let request = try MailOAuthProvider.google.registration(clientID: registration.clientID, redirectURI: "http://127.0.0.1:49152/oauth2redirect")
        let auth = try sessions.begin(request)
        #expect(!auth.url.contains("client_secret"))
        let state = URLComponents(string: auth.url)!.queryItems!.first { $0.name == "state" }!.value!
        let input = try sessions.consume(id: auth.id, callback: request.redirectURI + "?state=" + state + "&code=synthetic-code")
        let output = try GoogleDesktopAuthentication.apply(input, registration: registration)
        #expect(output.url == input.url)
        #expect(output.url!.query == nil)
        #expect(values(output)["client_secret"] == registration.clientSecret)
        #expect(values(output)["code_verifier"] == values(input)["code_verifier"])
        #expect(values(output)["code"] == "synthetic-code")
        #expect(String(decoding: output.httpBody!, as: UTF8.self).contains("%2B"))
    }
    @Test func refreshAlsoAuthenticatesWithoutChangingRefreshToken() throws {
        let request = try MailOAuthProvider.google.registration(clientID: registration.clientID, redirectURI: "http://127.0.0.1:49152/oauth2redirect")
        let input = try BrowserOAuthSessions.refresh(request, token: "synthetic-refresh")
        let output = try GoogleDesktopAuthentication.apply(input, registration: registration)
        #expect(values(output)["client_secret"] == registration.clientSecret)
        #expect(values(output)["refresh_token"] == "synthetic-refresh")
    }
    @Test func unrelatedProviderOrClientCannotReceiveDesktopSecret() throws {
        for provider in [MailOAuthProvider.google, .microsoft] {
            let request = try provider.registration(clientID: "different-client", redirectURI: "http://127.0.0.1:49152/oauth2redirect")
            let input = try BrowserOAuthSessions.refresh(request, token: "synthetic-refresh")
            #expect(try GoogleDesktopAuthentication.apply(input, registration: registration) == input)
        }
        let request = try MailOAuthProvider.microsoft.registration(clientID: registration.clientID, redirectURI: "http://127.0.0.1:49152/oauth2redirect")
        let input = try BrowserOAuthSessions.refresh(request, token: "synthetic-refresh")
        #expect(try GoogleDesktopAuthentication.apply(input, registration: registration) == input)
    }
    @Test func malformedSecretOrDuplicateFieldIsRejected() throws {
        let request = try MailOAuthProvider.google.registration(clientID: registration.clientID, redirectURI: "http://127.0.0.1:49152/oauth2redirect")
        var input = try BrowserOAuthSessions.refresh(request, token: "synthetic-refresh")
        for secret in ["", "unsafe\nsecret"] {
            #expect(throws: BrowserOAuthError.invalidConfiguration) {
                try GoogleDesktopAuthentication.apply(input, registration: GoogleDesktopRegistration(clientID: registration.clientID, clientSecret: secret))
            }
        }
        input.httpBody!.append(Data("&client_secret=other".utf8))
        #expect(throws: BrowserOAuthError.invalidConfiguration) { try GoogleDesktopAuthentication.apply(input, registration: registration) }
    }
}
