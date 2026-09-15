@testable import Autoconfiguration
import Foundation
import FoundationNetworking
import Testing

private final class TokenProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "tokens.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url!.path
        // Observe the request at the actual URLSession boundary, not just its builder.
        let valid = request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Accept") == "application/json" &&
            request.value(forHTTPHeaderField: "Cache-Control") == "no-store" && request.url?.query == nil
        let status = valid && path != "/rejected" && !path.hasPrefix("/error-") ? 200 : 400
        let headers = path == "/declared-large" ? ["Content-Length": "65537"] : ["Content-Type": "application/json"]
        client!.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if path == "/stream-large" {
            client!.urlProtocol(self, didLoad: Data(repeating: 65, count: 32768))
            client!.urlProtocol(self, didLoad: Data(repeating: 66, count: 32769))
        } else if path.hasPrefix("/error-") {
            let code = String(path.dropFirst("/error-".count))
            client!.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject:
                ["error": code, "error_description": "private-token-and-account-must-never-escape"]))
        } else {
            client!.urlProtocol(self, didLoad: Data(#"{"access_token":"synthetic-access","token_type":"Bearer","expires_in":3600,"refresh_token":"synthetic-refresh"}"#.utf8))
        }
        client!.urlProtocolDidFinishLoading(self)
    }
}

struct OAuthTokenTransferTests {
    private func transfer(_ path: String) throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TokenProtocol.self]
        let registration = try OAuth2.Request(authURI: "https://tokens.example.test/auth", tokenURI: "https://tokens.example.test/\(path)",
            redirectURI: "org.example.mail:/oauth", responseType: "code", scope: ["mail"], clientID: "synthetic-client")
        let request = try BrowserOAuthSessions.refresh(registration, token: "synthetic-refresh")
        return try OAuthTokenTransfer(configuration: configuration).submit(request)
    }
    @Test func successfulTokenPOSTUsesJSONAndNoStore() throws {
        let tokens = try OAuthTokenSet.parse(transfer("success"))
        #expect(tokens.accessToken == "synthetic-access")
        #expect(tokens.refreshToken == "synthetic-refresh")
    }
    @Test func errorStatusCannotBeAcceptedAsTokens() {
        #expect(throws: OAuthTransferError.rejected) { try transfer("rejected") }
    }
    @Test func standardProviderFailuresAreSanitizedAtTransportBoundary() {
        for code in ["invalid_client", "invalid_grant", "invalid_request", "unauthorized_client", "invalid_scope", "access_denied"] {
            #expect(throws: OAuthTransferError(rawValue: code)!) { try transfer("error-\(code)") }
        }
        #expect(throws: OAuthTransferError.rejected) { try transfer("error-private-secret") }
        #expect(throws: OAuthTransferError.rejected) { try transfer("error-network") }
    }
    @Test func oversizedTokenResponseRejectedWithAndWithoutLength() {
        #expect(throws: OAuthTransferError.responseTooLarge) { try transfer("declared-large") }
        #expect(throws: OAuthTransferError.responseTooLarge) { try transfer("stream-large") }
    }
}
