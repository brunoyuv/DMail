// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import Testing
import NIOCore
import NIOEmbedded
import NIOIMAP
import MIME
@testable import IMAP

private final class FetchOutcome: @unchecked Sendable { var result: Result<MessageSet, Error>? }
private final class FetchWire {
    let loop = EmbeddedEventLoop()
    let channel: EmbeddedChannel
    let outcome = FetchOutcome()
    init() throws {
        let promise: EventLoopPromise<MessageSet> = loop.makePromise(), outcome = self.outcome
        promise.futureResult.whenComplete { outcome.result = $0 }
        let command = UIDFetchCommand(UIDSet(UID(rawValue: 7)), attributes: [.uid, .flags,
            .bodyStructure(extensions: true), .bodySection(peek: true, .init(part: .init([1]), kind: .MIMEHeader), nil),
            .bodySection(peek: true, .init(part: .init([1])), nil)])
        channel = EmbeddedChannel(handlers: [IMAPClientHandler(), command.makeHandler(tag: "A1", promise: promise)], loop: loop)
        _ = try channel.writeOutbound(IMAPClientHandler.Message.part(.tagged(command.tagged("A1"))))
    }
    func inbound(_ text: String) throws { _ = try channel.writeInbound(ByteBuffer(string: text)); loop.run() }
    func result() throws -> MessageSet { try #require(outcome.result).get() }
    func close() { _ = try? channel.finish(acceptAlreadyClosed: true); loop.run() }
}

struct FetchAssemblyTests {
    private let headers = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
    private let body = "Readable body 中文 café"
    private let section = SectionSpecifier(part: .init([1]))
    private let headerSection = SectionSpecifier(part: .init([1]), kind: .MIMEHeader)
    private var metadata: String {
        "UID 7 FLAGS () BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"8BIT\" \(body.utf8.count) 1)"
    }
    private func literal(_ value: String) -> String { "{\(value.utf8.count)}\r\n\(value)" }
    private var content: String { "BODY[1.MIME] \(literal(headers)) BODY[1] \(literal(body))" }
    private func checkReadable(_ messages: MessageSet) throws {
        let target = try readableFetchTarget(messages, uid: 7)
        #expect(target.uid == 7)
        #expect(target.bodySections[headerSection] == Data(headers.utf8))
        #expect(target.bodySections[section] == Data(body.utf8))
        let structure = try #require(target.bodyStructure), plan = try ReadablePlan(structure)
        let source = try #require(try plan.assemble([section: Data(headers.utf8) + Data(body.utf8)]))
        #expect(source.part.data == Data(body.utf8))
        #expect(source.contentType == .text(.plain, .utf8))
    }

    @Test func combinedAndSplitFetchRecordsPreserveTheSameReadableBody() throws {
        for split in [false, true] {
            let wire = try FetchWire(); defer { wire.close() }
            if split {
                try wire.inbound("* 1 FETCH (\(metadata))\r\n")
                try wire.inbound("* 1 FETCH (UID 7 BODY[1.MIME] \(literal(headers)))\r\n")
                try wire.inbound("* 1 FETCH (UID 7 BODY[1] \(literal(body)))\r\n")
            } else { try wire.inbound("* 1 FETCH (\(metadata) \(content))\r\n") }
            try wire.inbound("A1 OK complete\r\n")
            try checkReadable(wire.result())
        }
    }
    @Test func flagsUpdatesBeforeAndAfterTheBodyPreserveUIDAndSections() throws {
        let wire = try FetchWire(); defer { wire.close() }
        try wire.inbound("* 1 FETCH (FLAGS (\\Seen))\r\n")
        try wire.inbound("* 1 FETCH (\(metadata) \(content))\r\n")
        try wire.inbound("* 1 FETCH (FLAGS (\\Seen \\Flagged))\r\nA1 OK complete\r\n")
        let messages = try wire.result()
        try checkReadable(messages)
        let target = try readableFetchTarget(messages, uid: 7)
        #expect(target.flags == [.seen, .flagged])
        #expect(target.flagsWereReceived)
    }
    @Test func unrelatedUnsolicitedUpdatesDoNotInvalidateExplicitTarget() throws {
        let wire = try FetchWire(); defer { wire.close() }
        try wire.inbound("* 1 FETCH (\(metadata) \(content))\r\n")
        try wire.inbound("* 2 FETCH (UID 8 FLAGS (\\Seen))\r\n* 3 FETCH (FLAGS ())\r\nA1 OK complete\r\n")
        let messages = try wire.result()
        #expect(messages.count == 3)
        try checkReadable(messages)
    }
    @Test func changedUIDForTheSameSequenceRejectsInsteadOfCombiningBodies() throws {
        for conflicting in ["* 1 FETCH (UID 8 FLAGS ())\r\n", "* 1 FETCH (UID 7 UID 8 FLAGS ())\r\n"] {
            let wire = try FetchWire(); defer { wire.close() }
            try wire.inbound("* 1 FETCH (\(metadata) \(content))\r\n")
            try wire.inbound(conflicting)
            #expect(throws: (any Error).self) { try wire.result() }
            #expect(!wire.channel.isActive)
        }
    }
    @Test func duplicateTargetUIDsAndMissingTargetsAreRejected() throws {
        let wire = try FetchWire(); defer { wire.close() }
        try wire.inbound("* 1 FETCH (\(metadata) \(content))\r\n")
        try wire.inbound("* 2 FETCH (UID 7 FLAGS ())\r\nA1 OK complete\r\n")
        let messages = try wire.result()
        #expect(throws: (any Error).self) { try readableFetchTarget(messages, uid: 7) }
        #expect(throws: (any Error).self) { try readableFetchTarget(messages, uid: 9) }
    }
    @Test func missingHeaderIsNeverBorrowedFromAnotherSequence() throws {
        let wire = try FetchWire(); defer { wire.close() }
        try wire.inbound("* 1 FETCH (UID 7 BODY[1] \(literal(body)))\r\n")
        try wire.inbound("* 2 FETCH (UID 8 BODY[1.MIME] \(literal(headers)))\r\nA1 OK complete\r\n")
        let target = try readableFetchTarget(wire.result(), uid: 7)
        #expect(target.bodySections[headerSection] == nil)
        #expect(target.bodySections[section] == Data(body.utf8))
    }
}
