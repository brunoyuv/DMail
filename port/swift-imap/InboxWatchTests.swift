// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import Testing
import NIOCore
import NIOEmbedded
import NIOIMAP
@testable import IMAP

private final class IdleOutcome: @unchecked Sendable {
    var result: Result<Void, Error>?
    var succeeded: Bool { if case .success? = result { return true }; return false }
    var failed: Bool { if case .failure? = result { return true }; return false }
}
private final class IdleWire {
    let loop = EmbeddedEventLoop()
    let channel: EmbeddedChannel
    let events: AsyncStream<IdleEvent>
    let outcome = IdleOutcome()
    init() throws {
        let pair = AsyncStream<IdleEvent>.makeStream()
        events = pair.stream
        let promise: EventLoopPromise<Void> = loop.makePromise()
        let outcome = self.outcome
        promise.futureResult.whenComplete { outcome.result = $0 }
        channel = EmbeddedChannel(handlers: [IMAPClientHandler(),
            IdleHandler(tag: "A1", promise: promise, continuation: pair.continuation)], loop: loop)
        try channel.writeOutbound(IMAPClientHandler.OutboundIn.part(.tagged(TaggedCommand(tag: "A1", command: .idleStart))))
        loop.run()
    }
    func inbound(_ line: String) throws { _ = try channel.writeInbound(ByteBuffer(string: line)); loop.run() }
    func outbound() throws -> String {
        var text = ""
        while let value = try channel.readOutbound(as: ByteBuffer.self) { text += String(buffer: value) }
        return text
    }
    func close() { _ = try? channel.finish(acceptAlreadyClosed: true); loop.run() }
}
struct InboxWatchTests {
    private func expectExists(_ changes: inout InboxWatchChanges, _ count: Int, changed: Bool) {
        let actual = changes.exists(count)
        #expect(actual == changed)
    }
    @Test func repeatedExistsDoesNotRepeatAnArrivalHint() {
        var changes = InboxWatchChanges(messageCount: 80)
        expectExists(&changes, 80, changed: false)
        expectExists(&changes, 81, changed: true)
        for _ in 0..<30 { expectExists(&changes, 81, changed: false) }
        expectExists(&changes, 82, changed: true)
    }
    @Test func expungeThenArrivalAtTheSameCountStillCreatesAHint() {
        var changes = InboxWatchChanges(messageCount: 80)
        changes.expunged()
        expectExists(&changes, 79, changed: false)
        expectExists(&changes, 80, changed: true)
        changes.expunged(); changes.expunged()
        expectExists(&changes, 80, changed: true)
        expectExists(&changes, 80, changed: false)
    }
    @Test func unknownAndEmptyMailboxCountsRemainSafe() {
        var unknown = InboxWatchChanges(messageCount: nil)
        unknown.expunged()
        expectExists(&unknown, 0, changed: true); expectExists(&unknown, 0, changed: false)
        unknown.expunged()
        expectExists(&unknown, 0, changed: false); expectExists(&unknown, 1, changed: true)
    }
    @Test func serverContinuationAndExistsUseOneIdleUntilDone() async throws {
        let wire = try IdleWire(); defer { wire.close() }
        #expect(try wire.outbound() == "A1 IDLE\r\n")
        try wire.inbound("+ idling\r\n* 81 EXISTS\r\n")
        var events = wire.events.makeAsyncIterator()
        guard case .ready? = await events.next() else { Issue.record("IDLE did not report accepted continuation"); return }
        guard case .status(let status)? = await events.next() else { Issue.record("IDLE did not report EXISTS"); return }
        #expect(status.messageCount == 81)
        #expect(try wire.outbound().isEmpty)
        #expect(!wire.outcome.succeeded)
        try wire.channel.writeOutbound(IMAPClientHandler.OutboundIn.part(.idleDone))
        #expect(try wire.outbound() == "DONE\r\n")
        try wire.inbound("A1 OK idle complete\r\n")
        #expect(await events.next() == nil)
        #expect(wire.outcome.succeeded)
    }
    @Test func droppedIdleFinishesItsStreamAndFailsThePendingDone() async throws {
        let wire = try IdleWire(); defer { wire.close() }
        _ = try wire.outbound(); try wire.inbound("+ idling\r\n")
        var events = wire.events.makeAsyncIterator()
        guard case .ready? = await events.next() else { Issue.record("IDLE not ready"); return }
        wire.close()
        #expect(await events.next() == nil)
        #expect(wire.outcome.failed)
    }
    @Test func invalidWatchIdNeverCreatesAConnection() throws {
        let registry = InboxWatchRegistry()
        #expect(throws: InboxWatchError.invalidArgument) {
            try registry.snapshot(id: "invalid", owner: [], accessToken: nil) {
                Issue.record("Invalid ID reached connection creation")
                throw InboxWatchError.network
            }
        }
    }
}
