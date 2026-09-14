@testable import Autoconfiguration
import Foundation
import FoundationNetworking
import Testing

struct ConfigCompatibilityTests {
    private func document(_ extra: String = "", name: String = "Example &amp; Mail") -> Data {
        Data("""
        <clientConfig version="1.1"><emailProvider id="example.test">
          <domain>example.test</domain><displayName>\(name)</displayName><displayShortName>Example</displayShortName>
          <incomingServer type="imap"><hostname>imap.example.test</hostname><port>993</port><socketType>SSL</socketType>
            <username>%EMAIL<![CDATA[LOCALPART]]>%</username><authentication>OAuth2</authentication>
            <authentication>future-auth</authentication><authentication>password-cleartext</authentication></incomingServer>
          <incomingServer type="imap"><hostname>mail.example.test</hostname><port>143</port><socketType>STARTTLS</socketType>
            <username>%EMAILADDRESS%</username><authentication>GSSAPI</authentication></incomingServer>
          <outgoingServer type="smtp"><hostname>smtp.example.test</hostname><port>587</port><socketType>STARTTLS</socketType>
            <username>smtp-%EMAILLOCALPART%</username><authentication>password-cleartext</authentication></outgoingServer>
          \(extra)
        </emailProvider></clientConfig>
        """.utf8)
    }

    @Test func chunksEntitiesAndLoginPlaceholders() throws {
        let config = try ClientConfig.parse(document(), emailAddress: "bruno@example.test")
        let provider = try #require(config.emailProvider)
        #expect(provider.displayName == "Example & Mail")
        #expect(provider.servers.map(\.hostname) == ["imap.example.test", "mail.example.test", "smtp.example.test"])
        #expect(provider.servers.map(\.username) == ["bruno", "bruno@example.test", "smtp-bruno"])
        #expect(provider.servers[0].authentication == [.oAuth2, .unknown, .passwordCleartext])
        #expect(provider.servers[1].socketType == .startTLS)
        #expect(provider.servers[1].authentication == [.gssapi])
    }

    @Test func extensionSubtreesCannotOverwriteServerFields() throws {
        let extra = "<extension><incomingServer type=\"imap\"><hostname>wrong.example.test</hostname></incomingServer></extension>"
        let config = try ClientConfig.parse(document(extra), emailAddress: "bruno@example.test")
        #expect(config.emailProvider?.servers.count == 3)
        #expect(config.emailProvider?.servers.first?.hostname == "imap.example.test")
    }

    @Test func malformedOversizedAndNestedLeafDocumentsFail() {
        let malformed = Data(document().dropLast(10))
        for data in [malformed, Data(repeating: 32, count: 524289), document(name: "Good<nested>Bad</nested>")] {
            #expect(throws: (any Error).self) { try ClientConfig.parse(data, emailAddress: "bruno@example.test") }
        }
    }

    @Test func entityDeclarationsFailEvenInUTF16() {
        let text = "<!DOCTYPE clientConfig [<!ENTITY hidden 'injected'>]>" + String(data: document(name: "&hidden;"), encoding: .utf8)!
        for encoding in [String.Encoding.utf8, .utf16] {
            #expect(throws: (any Error).self) {
                try ClientConfig.parse(text.data(using: encoding)!, emailAddress: "bruno@example.test")
            }
        }
    }

    @Test func unknownTransportAndProtocolAreRetainedWithoutBeingAssumedSupported() throws {
        let extra = """
        <incomingServer type="future"><hostname>future.example.test</hostname><port>143</port><socketType>future</socketType>
          <username>%EMAILADDRESS%</username><authentication>future</authentication></incomingServer>
        """
        let config = try ClientConfig.parse(document(extra), emailAddress: "bruno@example.test")
        #expect(config.emailProvider?.servers.last?.serverType == .unknown)
        #expect(config.emailProvider?.servers.last?.socketType == .unknown)
    }

    @Test func tokenFormsPreserveLiteralPlusAndStayOutOfURL() throws {
        let request = try OAuth2.Request(authURI: "https://example.test/authorize", tokenURI: "https://example.test/token",
                                        redirectURI: "test:/oauth", responseType: "code", scope: ["mail"], clientID: "client+id")
        let token = try URLRequest.token(request, code: "a+b&c", pkce: OAuth2.PKCE())
        let refresh = try URLRequest.refreshToken(request, refreshToken: "refresh+secret")
        for value in [token, refresh] {
            #expect(value.url?.query == nil)
            #expect(value.httpMethod == "POST")
            #expect(value.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
            #expect(String(data: value.httpBody!, encoding: .utf8)!.contains("client%2Bid"))
        }
        #expect(String(data: token.httpBody!, encoding: .utf8)!.contains("a%2Bb%26c"))
        #expect(String(data: refresh.httpBody!, encoding: .utf8)!.contains("refresh%2Bsecret"))
    }

    @Test func discoveryDomainCannotInjectURLComponents() throws {
        for domain in ["example.test/path", "example.test?secret=1", "example.test#fragment", "example.test:8443", "example%2Etest", "example.test\\path"] {
            for source in Source.allCases {
                #expect(throws: URLError.self) { try URL.autoconfig("user@" + domain, source: source) }
            }
        }
        #expect(try URL.autoconfig("user+tag@example.test", source: .ispDB).absoluteString == "https://autoconfig.thunderbird.net/v1.1/example.test")
    }

    @Test func oauthHostBindingRequiresDomainBoundary() throws {
        let request = try OAuth2.Request(authURI: "https://example.test/auth", tokenURI: "https://example.test/token",
                                        redirectURI: "test:/oauth", responseType: "code", scope: ["mail"], clientID: "client", hosts: ["Example.Test"])
        #expect(request.matches("imap.example.test"))
        #expect(request.matches("EXAMPLE.TEST"))
        #expect(!request.matches("wrongexample.test"))
        #expect(!request.matches("example.test.evil.test"))
    }

    @Test func discoveryKeepsProtocolOrderAndSeparateUsernames() throws {
        let result = try MailDiscovery.parse(document(), email: "bruno@example.test", source: "fixture")
        #expect(result.incoming.map(\.username) == ["bruno", "bruno@example.test"])
        #expect(result.outgoing.map(\.username) == ["smtp-bruno"])
        #expect(result.incoming[0].supported)
        #expect(!result.incoming[1].supported)
        #expect(result.incoming[1].reason == "imapStarttlsPending")
        #expect(result.outgoing[0].supported)
        #expect(result.outgoing[0].security == "STARTTLS")
        #expect(result.incoming[0].authentication == ["OAuth2", "unknown", "password-cleartext"])
    }

    @Test func discoveryFallsThroughFailuresButKeepsValidUnsupportedProvider() throws {
        var urls: [URL] = []
        let result = try MailDiscovery.discover(email: "bruno@example.test") { url in
            urls.append(url)
            if urls.count == 1 { throw URLError(.cannotConnectToHost) }
            if urls.count == 2 { return Data("not XML".utf8) }
            return document()
        }
        #expect(urls.map(\.host) == ["autoconfig.example.test", "example.test", "autoconfig.thunderbird.net"])
        #expect(result.source == "ISPDB")
        urls = []
        let oauthOnly = String(decoding: document(), as: UTF8.self)
            .replacingOccurrences(of: "<authentication>password-cleartext</authentication>", with: "")
        let unsupported = try MailDiscovery.discover(email: "bruno@example.test") { url in
            urls.append(url)
            return Data(oauthOnly.utf8)
        }
        #expect(urls.count == 1)
        #expect(unsupported.source == "provider")
        #expect(unsupported.incoming.allSatisfy { !$0.supported })
        #expect(unsupported.incoming[0].reason == "unsupportedAuthentication")
    }

    @Test func discoveryRejectsInvalidInputBeforeNetworkAndReportsExhaustion() {
        for email in ["no-domain", "a@@example.test", "a@example.test/path", "a@-bad.test", "a\n@example.test"] {
            #expect(throws: DiscoveryError.invalidAddress) {
                try MailDiscovery.discover(email: email) { _ in
                    Issue.record("Invalid identity reached the network")
                    return document()
                }
            }
        }
        var attempts = 0
        #expect(throws: DiscoveryError.notFound) {
            try MailDiscovery.discover(email: "bruno@example.test") { _ in
                attempts += 1; throw URLError(.timedOut)
            }
        }
        #expect(attempts == 3)
    }

    @Test func discoveryCResponseUsesSharedSwiftOwnership() throws {
        for operation in ["sources", "parse", "unknown"] {
            let input = try JSONSerialization.data(withJSONObject: ["operation": operation,
                "email": "bruno@example.test", "document": String(decoding: document(), as: UTF8.self)])
            for _ in 0..<32 {
                let response = try #require(String(decoding: input, as: UTF8.self).withCString { discoveryRequest($0) })
                defer { response.deallocate() }
                let value = try JSONSerialization.jsonObject(with: Data(String(cString: response).utf8)) as! [String: Any]
                #expect(value[operation == "sources" ? "sources" : operation == "parse" ? "configuration" : "error"] != nil)
            }
        }
        #expect(discoveryRequest(nil) == nil)
    }
}
