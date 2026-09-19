// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import Testing
import NIOCore
import NIOPosix
import NIOSSL
import NIOIMAPCore
@testable import IMAP

private enum AuthScenario: String, CaseIterable, Sendable {
    case passwordRejected, passwordUncoded, passwordTemporary, passwordBad, passwordDrop, passwordStall
    case oauthRejected, oauthTemporary, oauthDrop, oauthStall, oauthChallengeRejected, oauthChallengeDrop
    case passwordMailboxUnavailable, oauthMailboxUnavailable, oauthMailboxUnavailableAlert
    case passwordCapabilityRejected, passwordCapabilityDrop, oauthCapabilityRejected, oauthCapabilityDrop, oauthCapabilityStall
    case passwordAccepted, oauthAccepted

    var oauth: Bool { rawValue.hasPrefix("oauth") }
    var capabilityFailure: Bool { rawValue.contains("Capability") }
    var rejected: Bool { [.passwordRejected, .passwordUncoded, .oauthRejected, .oauthChallengeRejected].contains(self) }
    var accepted: Bool { [.passwordAccepted, .oauthAccepted].contains(self) }
}

private final class AuthCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ command: String) { lock.lock(); defer { lock.unlock() }; values.append(command) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}

// The actual Swift client connects through TLS to this strictly local peer.
// It exposes command names only, never submitted credentials or response text.
private final class AuthPeer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let scenario: AuthScenario, commands: AuthCommands
    var input = "", authenticated = false, challengeTag: String?
    init(_ scenario: AuthScenario, commands: AuthCommands) { self.scenario = scenario; self.commands = commands }
    func send(_ value: String, _ context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: value)), promise: nil)
    }
    func channelActive(context: ChannelHandlerContext) { send("* OK Synthetic authentication peer\r\n", context) }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        input += String(buffer: unwrapInboundIn(data))
        while let range = input.range(of: "\r\n") {
            let line = String(input[..<range.lowerBound]); input.removeSubrange(..<range.upperBound)
            if let tag = challengeTag {
                commands.append(line.isEmpty ? "EMPTY" : "INVALID_CONTINUATION"); challengeTag = nil
                if scenario == .oauthChallengeDrop { context.close(promise: nil) }
                else { send("\(tag) NO [AUTHENTICATIONFAILED] synthetic-private-response\r\n", context) }
                continue
            }
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count >= 2 else { context.close(promise: nil); return }
            let tag = String(fields[0]), command = String(fields[1]).uppercased(); commands.append(command)
            if command == "CAPABILITY" {
                if authenticated && scenario.capabilityFailure {
                    if scenario.rawValue.hasSuffix("Drop") { context.close(promise: nil) }
                    else if !scenario.rawValue.hasSuffix("Stall") {
                        // Even an authentication-looking code is not a failed LOGIN.
                        send("\(tag) NO [AUTHENTICATIONFAILED] synthetic capability failure\r\n", context)
                    }
                } else { send("* CAPABILITY IMAP4rev1 AUTH=XOAUTH2 SASL-IR IDLE\r\n\(tag) OK Capabilities\r\n", context) }
            } else if command == "LOGIN" || command == "AUTHENTICATE" {
                if scenario == .oauthChallengeRejected || scenario == .oauthChallengeDrop {
                    challengeTag = tag; send("+ \(Data(#"{"status":"401"}"#.utf8).base64EncodedString())\r\n", context)
                } else if scenario.rawValue.hasSuffix("Drop") && !scenario.capabilityFailure { context.close(promise: nil) }
                else if scenario.rawValue.hasSuffix("Stall") && !scenario.capabilityFailure { /* Deliberately no acknowledgement. */ }
                else if scenario.rejected {
                    let code = scenario == .passwordUncoded ? "" : "[AUTHENTICATIONFAILED] "
                    send("\(tag) NO \(code)synthetic-private-response\r\n", context)
                } else if scenario == .passwordTemporary || scenario == .oauthTemporary {
                    send("\(tag) NO [UNAVAILABLE] synthetic temporary outage\r\n", context)
                } else if [.passwordMailboxUnavailable, .oauthMailboxUnavailable, .oauthMailboxUnavailableAlert].contains(scenario) {
                    let code = scenario == .oauthMailboxUnavailableAlert ? "[ALERT] " : ""
                    send("\(tag) NO \(code)User is authenticated but not connected. [synthetic-private-response]\r\n", context)
                } else if scenario == .passwordBad { send("\(tag) BAD synthetic-private-response\r\n", context) }
                else { authenticated = true; send("\(tag) OK Authenticated\r\n", context) }
            } else { send("\(tag) BAD Unexpected command\r\n", context) }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}


struct AuthenticationTests {
    @Test func mailboxConnectionHintCannotOverrideExplicitCredentialFailureOrUnrelatedText() {
        let message = "User is authenticated but not connected."
        for code: ResponseTextCode in [.authenticationFailed, .authorizationFailed, .expired] {
            #expect(authenticationRejected(.no(ResponseText(code: code, text: message))))
        }
        for text in ["AUTHENTICATE failed.", "Invalid user: " + message,
                     "User is authenticated but not connectedness", "User is authenticated but not connected: invalid password"] {
            #expect(authenticationRejected(.no(ResponseText(text: text))))
        }
        for text in [message, "USER IS AUTHENTICATED BUT NOT CONNECTED", message + " [private-server-details]",
                     "User is authenticated but not connected [private-server-details]"] {
            #expect(!authenticationRejected(.no(ResponseText(text: text))))
        }
    }

    @Test func actualTLSLoginAndOAuthSeparateRejectionFromTransportAndPostLoginCapabilityFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dmail-auth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try NIOSSLContext(configuration: fixtureTLSConfiguration(in: directory))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            for scenario in AuthScenario.allCases {
                let commands = AuthCommands()
                let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                    channel.pipeline.addHandlers([NIOSSLServerHandler(context: context), AuthPeer(scenario, commands: commands)])
                }.bind(host: "127.0.0.1", port: 0).get()
                guard let port = server.localAddress?.port else { throw IMAPError.notConnected }
                var tls = TLSConfiguration.makeClientConfiguration()
                // This synthetic peer has a newly generated self-signed certificate.
                // Production trust policy and the client implementation are unchanged.
                tls.certificateVerification = .none
                let client = IMAPClient(Server(hostname: "127.0.0.1", username: "synthetic-user", password: "synthetic-password", port: port),
                    logger: nil, tlsConfiguration: tls, connectionTimeout: .seconds(2), commandTimeout: 1)
                var failure: Error?
                do {
                    try await client.connect()
                    if scenario.oauth { try await client.authenticateXOAUTH2(username: "synthetic-user", accessToken: "synthetic-token") }
                    else {
                        try await client.login()
                        if scenario.capabilityFailure { try await client.refreshCapabilities() }
                    }
                } catch { failure = error }
                try await client.shutdown(); try await server.close().get()
                #expect((failure == nil) == scenario.accepted, "\(scenario.rawValue)")
                #expect((failure as? AuthenticationFailure == .rejected) == scenario.rejected, "\(scenario.rawValue)")
                if let failure {
                    let text = String(describing: failure)
                    #expect(!text.contains("synthetic-private-response"))
                    #expect(!text.contains("synthetic-password"))
                    #expect(!text.contains("synthetic-token"))
                    #expect(!text.contains("User is authenticated"))
                }
                let names = commands.snapshot()
                #expect(names.filter { $0 == "LOGIN" }.count == (scenario.oauth ? 0 : 1))
                #expect(names.filter { $0 == "AUTHENTICATE" }.count == (scenario.oauth ? 1 : 0))
                #expect(names.filter { $0 == "CAPABILITY" }.count == ((scenario.capabilityFailure || (scenario.oauth && scenario.accepted)) ? 2 : 1))
                #expect(!names.contains("INVALID_CONTINUATION"))
            }
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
}
