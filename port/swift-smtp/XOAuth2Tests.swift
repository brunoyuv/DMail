import Foundation
import Testing
import EmailAddress
import NIOCore
import NIOEmbedded
import NIOSSL
import NIOTLS
@testable import SMTP

private final class SMTPResult: @unchecked Sendable {
    var value: Result<Void, Error>?
    var failed: Bool { if case .failure? = value { return true }; return false }
    var succeeded: Bool { if case .success? = value { return true }; return false }
}
private final class SMTPWire {
    let loop = EmbeddedEventLoop()
    let result = SMTPResult()
    let channel: EmbeddedChannel
    init(secure: Bool = true) throws {
        let email = Email(sender: EmailAddress("sender@example.test"), recipients: [EmailAddress("reader@example.test")])
        let server = Server(.tls, hostname: "unused.example.test", username: "login@example.test", password: "must-not-be-used", accessToken: "synthetic-token")
        let promise: EventLoopPromise<Void> = loop.makePromise()
        let result = self.result
        promise.futureResult.whenComplete { result.value = $0 }
        let handler = SendHandler(email, server: server, tlsContext: try NIOSSLContext(configuration: .makeClientConfiguration()), verifyPeer: nil, done: promise)
        channel = EmbeddedChannel(handlers: [MessageToByteHandler(RequestEncoder()), handler], loop: loop)
        if secure { channel.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: nil)) }
    }
    func receive(_ code: Int, _ lines: [String] = []) throws { _ = try channel.writeInbound(Response.reply(code, lines)); loop.run() }
    func outbound() throws -> String? {
        guard let buffer = try channel.readOutbound(as: ByteBuffer.self) else { return nil }
        return String(buffer: buffer)
    }
    func close() { _ = try? channel.finish(acceptAlreadyClosed: true); loop.run() }
}
struct SMTPXOAuth2Tests {
    @Test func tokenEncodingAndBounds() throws {
        let expected = Data("user=login@example.test\u{1}auth=Bearer synthetic-token\u{1}\u{1}".utf8).base64EncodedString()
        #expect(try xoauth2Payload(username: "login@example.test", accessToken: "synthetic-token") == expected)
        for token in ["", "a\u{1}b", "a b", String(repeating: "a", count: 32769)] {
            #expect(throws: SMTPError.self) { try xoauth2Payload(username: "login", accessToken: token) }
        }
        #expect(throws: SMTPError.self) { try xoauth2Payload(username: "a\r\n", accessToken: "token") }
    }
    @Test func oauthOverridesPasswordMechanismsAndSuccessCanSend() throws {
        let wire = try SMTPWire(); defer { wire.close() }
        try wire.receive(220); _ = try wire.outbound()
        try wire.receive(250, ["AUTH PLAIN LOGIN XOAUTH2"])
        #expect(try wire.outbound() == "AUTH XOAUTH2 \(xoauth2Payload(username: "login@example.test", accessToken: "synthetic-token"))\r\n")
        try wire.receive(235)
        #expect(try wire.outbound() == "MAIL FROM:<sender@example.test>\r\n")
        try wire.receive(250); _ = try wire.outbound()
        try wire.receive(250); #expect(try wire.outbound() == "DATA\r\n")
        try wire.receive(354); _ = try wire.outbound()
        try wire.receive(250); #expect(wire.result.succeeded)
    }
    @Test func challengeFailureNeverResendsTokenOrAcceptsLaterSuccess() throws {
        let wire = try SMTPWire(); defer { wire.close() }
        try wire.receive(220); _ = try wire.outbound()
        try wire.receive(250, ["AUTH XOAUTH2 PLAIN LOGIN"]); _ = try wire.outbound()
        try wire.receive(334, ["eyJzdGF0dXMiOiI0MDEifQ=="])
        #expect(try wire.outbound() == "\r\n")
        try wire.receive(235)
        #expect(wire.result.failed)
        #expect(try wire.outbound() == nil)
    }
    @Test func missingMechanismOrTLSNeverSendsCredentials() throws {
        for secure in [true, false] {
            let wire = try SMTPWire(secure: secure); defer { wire.close() }
            try wire.receive(220); _ = try wire.outbound()
            try wire.receive(250, [secure ? "AUTH PLAIN LOGIN" : "AUTH XOAUTH2 PLAIN LOGIN"])
            #expect(wire.result.failed)
            #expect(try wire.outbound() == nil)
        }
    }
}
