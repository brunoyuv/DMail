// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import Testing
import NIOCore
import NIOEmbedded
import NIOIMAP
@testable import IMAP

private final class AppendOutcome: @unchecked Sendable {
    var result: Result<Void, Error>?
    var succeeded: Bool { if case .success? = result { return true }; return false }
    var error: SentAppendError? { if case .failure(let value)? = result { return value as? SentAppendError }; return nil }
}
private final class AppendWire {
    let loop = EmbeddedEventLoop()
    let channel: EmbeddedChannel
    let outcome = AppendOutcome()
    let message = Data("From: sender@example.test\r\nMessage-ID: <original@example.test>\r\n\r\n.\r\nBody\r\n".utf8)
    init() throws {
        let promise: EventLoopPromise<Void> = loop.makePromise()
        let outcome = self.outcome
        promise.futureResult.whenComplete { outcome.result = $0 }
        channel = EmbeddedChannel(handlers: [IMAPClientHandler(), SentAppendHandler(tag: "A1", promise: promise)], loop: loop)
        for part in sentAppendParts(tag: "A1", mailbox: "Sent folder", data: message) { channel.write(part, promise: nil) }
        channel.flush(); loop.run()
    }
    func inbound(_ line: String) throws { _ = try channel.writeInbound(ByteBuffer(string: line)); loop.run() }
    func outbound() throws -> String {
        var text = ""
        while let value = try channel.readOutbound(as: ByteBuffer.self) { text += String(buffer: value) }
        return text
    }
    func close() { _ = try? channel.finish(acceptAlreadyClosed: true); loop.run() }
}
struct AppendSentTests {
    @Test func synchronizingLiteralPreservesBytesAndWaitsForMatchingTaggedOK() throws {
        let wire = try AppendWire(); defer { wire.close() }
        let start = try wire.outbound()
        #expect(start == "A1 APPEND \"Sent folder\" (\\Seen) {\(wire.message.count)}\r\n")
        #expect(!wire.outcome.succeeded)
        try wire.inbound("+ Send literal\r\n")
        #expect(try wire.outbound() == String(decoding: wire.message, as: UTF8.self) + "\r\n")
        try wire.inbound("* 10 EXISTS\r\n")
        #expect(!wire.outcome.succeeded)
        try wire.inbound("A1 OK [APPENDUID 10 22] saved\r\n")
        #expect(wire.outcome.succeeded)
        #expect(try wire.outbound().isEmpty)
    }
    @Test func explicitRejectionAndLostAcknowledgementNeverRetryTheLiteral() throws {
        let rejected = try AppendWire(); defer { rejected.close() }
        _ = try rejected.outbound()
        try rejected.inbound("+ continue\r\n"); _ = try rejected.outbound()
        try rejected.inbound("A1 NO [OVERQUOTA] full\r\n")
        #expect(rejected.outcome.error == .rejected)
        #expect(try rejected.outbound().isEmpty)
        let lost = try AppendWire(); defer { lost.close() }
        _ = try lost.outbound(); try lost.inbound("+ continue\r\n"); _ = try lost.outbound()
        lost.close()
        #expect(lost.outcome.error == .unconfirmed)
        #expect(try lost.outbound().isEmpty)
        // The current NIOIMAP state machine rejects a tagged response before
        // its literal continuation. Keep that failure conservative and never
        // emit/retry the pending message bytes.
        let early = try AppendWire(); defer { early.close() }
        _ = try early.outbound(); try early.inbound("A1 NO rejected before literal\r\n")
        #expect(early.outcome.error == .unconfirmed)
        #expect(try early.outbound().isEmpty)
    }
    @Test func wrongTaggedAcknowledgementCannotClaimSaved() throws {
        let wire = try AppendWire(); defer { wire.close() }
        _ = try wire.outbound(); try wire.inbound("+ continue\r\n"); _ = try wire.outbound()
        try wire.inbound("WRONG OK saved\r\n")
        #expect(wire.outcome.error == .unconfirmed)
    }
    @Test func folderDiscoveryUsesUniqueSelectableSpecialUseAttribute() {
        func box(_ name: String, _ flags: [Mailbox.Attribute]) -> Mailbox {
            Mailbox(attributes: flags, path: try! Mailbox.Path(name: Mailbox.Name(name), pathSeparator: "/"), extensions: [:])
        }
        let special = box("localized-server-folder", [.init("\\Sent")])
        #expect(sentMailbox(in: [box("Sent", []), special]) == special.path.name)
        #expect(sentMailbox(in: [box("Sent", [])]) == Mailbox.Name("Sent"))
        #expect(sentMailbox(in: [special, box("other", [.init("\\Sent")])]) == nil)
        #expect(sentMailbox(in: [box("blocked", [.init("\\Sent"), .noSelect])]) == nil)
        #expect(sentMailbox(in: [box("blocked", [.init("\\Sent"), .noSelect]), box("Sent", [])]) == nil)
        let localized = box("[Gmail]/&XfJT0ZABTvY-", [.init("\\Sent")])
        #expect(sentMailbox(in: [box("Sent", []), localized]) == localized.path.name)
    }
    @Test func conventionalFolderDiscoveryRequiresOneExistingUnambiguousPath() {
        func box(_ name: String, separator: Character? = "/", flags: [Mailbox.Attribute] = []) -> Mailbox {
            Mailbox(attributes: flags, path: try! Mailbox.Path(name: Mailbox.Name(name), pathSeparator: separator), extensions: [:])
        }
        for name in ["Sent", "Sent Items", "sent messages", "Sent Mail", "INBOX/Sent"] {
            #expect(sentMailbox(in: [box("INBOX"), box(name)]) == Mailbox.Name(name))
        }
        #expect(sentMailbox(in: [box("INBOX.Sent", separator: ".")]) == Mailbox.Name("INBOX.Sent"))
        #expect(sentMailbox(in: [box("Sent", separator: nil)]) == Mailbox.Name("Sent"))
        #expect(sentMailbox(in: [box("Sent"), box("Sent Items")]) == nil)
        #expect(sentMailbox(in: [box("Sent"), box("INBOX/Sent")]) == nil)
        #expect(sentMailbox(in: [box("Sent", flags: [.noSelect])]) == nil)
        #expect(sentMailbox(in: [box("Sent Items", flags: [.init("\\Trash")])]) == nil)
        for name in ["Work/Sent", "Sent/Archive", "INBOX/Work/Sent", "Sentimental", "Sent  Items", "Archive"] {
            #expect(sentMailbox(in: [box(name)]) == nil)
        }
    }
}
