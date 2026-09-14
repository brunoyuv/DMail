import Foundation
import Testing
import NIOCore
import NIOEmbedded
import NIOIMAP
@testable import IMAP

private final class OAuthOutcome: @unchecked Sendable {
    var result: Result<Void, Error>?
    var succeeded: Bool { if case .success? = result { return true }; return false }
    var failed: Bool { if case .failure? = result { return true }; return false }
}
private final class OAuthWire {
    let loop = EmbeddedEventLoop()
    let channel: EmbeddedChannel
    let outcome = OAuthOutcome()
    init(initial: Bool) throws {
        let command = try XOAuth2Command(username: "login@example.test", accessToken: "synthetic-token", initialResponse: initial)
        let promise: EventLoopPromise<Void> = loop.makePromise()
        let outcome = self.outcome
        promise.futureResult.whenComplete { outcome.result = $0 }
        channel = EmbeddedChannel(handlers: [IMAPClientHandler(), command.makeHandler(tag: "A1", promise: promise)], loop: loop)
        _ = try channel.writeOutbound(IMAPClientHandler.Message.part(.tagged(command.tagged("A1"))))
    }
    func inbound(_ wire: String) throws { _ = try channel.writeInbound(ByteBuffer(string: wire)); loop.run() }
    func outbound() throws -> String? {
        guard let buffer = try channel.readOutbound(as: ByteBuffer.self) else { return nil }
        return String(buffer: buffer)
    }
    func close() { _ = try? channel.finish(acceptAlreadyClosed: true); loop.run() }
}
struct XOAuth2Tests {
    private let encoded = Data("user=login@example.test\u{1}auth=Bearer synthetic-token\u{1}\u{1}".utf8).base64EncodedString()

    @Test func authenticatesWithInitialSASLResponse() throws {
        let wire = try OAuthWire(initial: true); defer { wire.close() }
        #expect(try wire.outbound() == "A1 AUTHENTICATE XOAUTH2 \(encoded)\r\n")
        try wire.inbound("A1 OK authenticated\r\n")
        #expect(wire.outcome.succeeded)
        #expect(try wire.outbound() == nil)
    }
    @Test func authenticatesAfterEmptyChallengeWithoutSASLIR() throws {
        let wire = try OAuthWire(initial: false); defer { wire.close() }
        #expect(try wire.outbound() == "A1 AUTHENTICATE XOAUTH2\r\n")
        try wire.inbound("+ \r\n")
        #expect(try wire.outbound() == "\(encoded)\r\n")
        try wire.inbound("A1 OK authenticated\r\n")
        #expect(wire.outcome.succeeded)
    }
    @Test func errorChallengeGetsOnlyEmptyReplyEvenIfServerThenSaysOK() throws {
        let wire = try OAuthWire(initial: true); defer { wire.close() }
        _ = try wire.outbound()
        let error = Data(#"{"status":"401","schemes":"bearer"}"#.utf8).base64EncodedString()
        try wire.inbound("+ \(error)\r\n")
        #expect(try wire.outbound() == "\r\n")
        try wire.inbound("A1 OK misleading success\r\n")
        #expect(wire.outcome.failed)
        #expect(try wire.outbound() == nil)
    }
    @Test func unexpectedInitialChallengeDoesNotDiscloseCredentials() throws {
        let wire = try OAuthWire(initial: false); defer { wire.close() }
        _ = try wire.outbound()
        try wire.inbound("+ ZXJyb3I=\r\n")
        #expect(try wire.outbound() == "\r\n")
        try wire.inbound("A1 NO rejected\r\n")
        #expect(wire.outcome.failed)
    }
    @Test func rejectsWrongTagsEarlySuccessAndRepeatedChallenges() throws {
        for scenario in [0, 1, 2] {
            let wire = try OAuthWire(initial: scenario != 1); defer { wire.close() }
            _ = try wire.outbound()
            if scenario == 0 { try wire.inbound("OTHER OK authenticated\r\n") }
            if scenario == 1 { try wire.inbound("A1 OK authenticated\r\n") }
            if scenario == 2 {
                try wire.inbound("+ ZXJyb3I=\r\n"); _ = try wire.outbound()
                try wire.inbound("+ ZXJyb3I=\r\n")
            }
            #expect(wire.outcome.failed)
            #expect(try wire.outbound() == nil)
        }
    }
    @Test func credentialsAreBoundedAndCannotInjectSASLFields() throws {
        for username in ["", "login\u{1}auth=Bearer injected", "login\r\n", String(repeating: "u", count: 513)] {
            #expect(throws: IMAPError.self) { try XOAuth2Command(username: username, accessToken: "token", initialResponse: true) }
        }
        for token in ["", "token\u{1}", "token\r\n", "token with space", String(repeating: "a", count: 32769)] {
            #expect(throws: IMAPError.self) { try XOAuth2Command(username: "login", accessToken: token, initialResponse: true) }
        }
        let command = try XOAuth2Command(username: "login", accessToken: "private-token", initialResponse: true)
        #expect(!command.description.contains("private-token"))
        #expect(!command.description.contains("login"))
    }
    @Test func missingCapabilityDoesNotFallBackToPassword() async throws {
        let client = IMAPClient(Server(hostname: "unused.example.test", username: "login", password: "unused"))
        do {
            await #expect(throws: IMAPError.self) { try await client.authenticateXOAUTH2(username: "login", accessToken: "token") }
            try await client.shutdown()
        } catch { try? await client.shutdown(); throw error }
    }
}
