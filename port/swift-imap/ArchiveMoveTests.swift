// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import Testing
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOSSL
import NIOIMAP
@testable import IMAP

private final class MoveOutcome: @unchecked Sendable {
    var result: Result<ArchiveMoveResult, Error>?
    var succeeded: Bool { if case .success? = result { return true }; return false }
    var value: ArchiveMoveResult? { if case .success(let value)? = result { return value }; return nil }
    var error: ArchiveMoveError? { if case .failure(let value)? = result { return value as? ArchiveMoveError }; return nil }
}
private final class MoveWire {
    let loop = EmbeddedEventLoop()
    let channel: EmbeddedChannel
    let outcome = MoveOutcome()
    init() throws {
        let promise: EventLoopPromise<ArchiveMoveResult> = loop.makePromise()
        let outcome = self.outcome
        promise.futureResult.whenComplete { outcome.result = $0 }
        let command = ArchiveMoveCommand(uid: 42, mailbox: "Archive folder")
        channel = EmbeddedChannel(handlers: [IMAPClientHandler(), command.makeHandler(tag: "A1", promise: promise)], loop: loop)
        channel.writeAndFlush(IMAPClientHandler.Message.part(.tagged(command.tagged("A1"))), promise: nil)
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
struct ArchiveMoveTests {
    private func box(_ name: String, _ flags: [Mailbox.Attribute] = [], separator: Character? = "/") -> Mailbox {
        Mailbox(attributes: flags, path: try! Mailbox.Path(name: Mailbox.Name(name), pathSeparator: separator), extensions: [:])
    }
    @Test func uniqueSpecialUseArchiveOrAllMailWinsOverConventionalNames() {
        let archive = box("localized folder", [.init("\\Archive")])
        #expect(archiveMailbox(in: [box("Archive"), archive]) == archive.path.name)
        let all = box("[Gmail]/&YkBnCQ-", [.init("\\All")])
        #expect(archiveMailbox(in: [box("INBOX"), box("Archive"), all]) == all.path.name)
        #expect(archiveMailbox(in: [box("All Mail")]) == nil)
    }
    @Test func ambiguousUnselectableAndConflictingRolesNeverGuess() {
        #expect(archiveMailbox(in: [box("one", [.init("\\Archive")]), box("two", [.init("\\All")])]) == nil)
        #expect(archiveMailbox(in: [box("Archive"), box("unselectable", [.init("\\Archive"), .noSelect])]) == nil)
        #expect(archiveMailbox(in: [box("INBOX", [.init("\\Archive")])]) == nil)
        #expect(archiveMailbox(in: [box("Archive", [.init("\\Trash")])]) == nil)
        #expect(archiveMailbox(in: [box("conflicting", [.init("\\Archive"), .init("\\Trash")])]) == nil)
        #expect(archiveMailbox(in: [box("Archive"), box("Archives")]) == nil)
    }
    @Test func conventionalFallbackRequiresOneExistingTopLevelOrInboxChildFolder() {
        for name in ["Archive", "archives", "INBOX/Archive"] {
            #expect(archiveMailbox(in: [box("INBOX"), box(name)]) == Mailbox.Name(name))
        }
        #expect(archiveMailbox(in: [box("INBOX.Archive", separator: ".")]) == Mailbox.Name("INBOX.Archive"))
        for name in ["Work/Archive", "Archive/2026", "INBOX/Work/Archive", "Archives-old"] {
            #expect(archiveMailbox(in: [box(name)]) == nil)
        }
    }
    @Test func originalUIDMoveEncoderAndTaggedCopyUIDMapping() throws {
        let wire = try MoveWire(); defer { wire.close() }
        #expect(try wire.outbound() == "A1 UID MOVE 42 \"Archive folder\"\r\n")
        try wire.inbound("* 3 EXPUNGE\r\n* 8 EXISTS\r\n")
        #expect(!wire.outcome.succeeded)
        try wire.inbound("A1 OK [COPYUID 91 42 105] Moved\r\n")
        #expect(wire.outcome.value?.validity == 91)
        #expect(wire.outcome.value?.uid == 105)
        #expect(try wire.outbound().isEmpty)
    }
    @Test func untaggedCopyUIDWaitsForMatchingFinalAcknowledgement() throws {
        let wire = try MoveWire(); defer { wire.close() }
        _ = try wire.outbound()
        try wire.inbound("* OK [COPYUID 91 42 105] Moving\r\n* 3 EXPUNGE\r\n")
        #expect(!wire.outcome.succeeded)
        try wire.inbound("A1 OK Moved\r\n")
        #expect(wire.outcome.value?.uid == 105)
    }
    @Test func absentMappingNeverInventsDestinationUID() throws {
        let wire = try MoveWire(); defer { wire.close() }
        _ = try wire.outbound(); try wire.inbound("A1 OK Moved\r\n")
        #expect(wire.outcome.succeeded)
        #expect(wire.outcome.value?.uid == nil)
        #expect(wire.outcome.value?.validity == nil)
    }
    @Test func malformedWrongAndConflictingMappingsCannotEnableUndo() throws {
        for line in ["A1 OK [COPYUID 91 41 105] Wrong source\r\n", "A1 OK [COPYUID 91 42:43 105:106] Too many\r\n",
                     "A1 OK [COPYUID 91 42 105:106] Too many destination\r\n",
                     "* OK [COPYUID 91 42 105] First\r\nA1 OK [COPYUID 92 42 106] Conflict\r\n"] {
            let wire = try MoveWire(); defer { wire.close() }
            _ = try wire.outbound(); try wire.inbound(line)
            #expect(wire.outcome.error == .unconfirmed)
            #expect(try wire.outbound().isEmpty)
        }
    }
    @Test func explicitRejectionAndLostConnectionDoNotReplayMove() throws {
        let rejected = try MoveWire(); defer { rejected.close() }
        _ = try rejected.outbound(); try rejected.inbound("A1 NO [NOPERM] Forbidden\r\n")
        #expect(rejected.outcome.error == .rejected)
        #expect(try rejected.outbound().isEmpty)
        let lost = try MoveWire(); defer { lost.close() }
        _ = try lost.outbound(); lost.close()
        #expect(lost.outcome.error == .unconfirmed)
        #expect(try lost.outbound().isEmpty)
    }
    @Test func unrelatedTaggedReplyCannotAcknowledgeMove() throws {
        let wire = try MoveWire(); defer { wire.close() }
        _ = try wire.outbound(); try wire.inbound("WRONG OK [COPYUID 91 42 105] Wrong command\r\n")
        #expect(wire.outcome.error == .unconfirmed)
    }
}

private enum MoveScenario: String, CaseIterable, Sendable { case confirmed, noCapability, rejected, dropped, stalled }
private final class MoveCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; commands.append(value) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return commands }
}
private final class MovePeer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let scenario: MoveScenario, commands: MoveCommands
    var input = ""
    init(_ scenario: MoveScenario, _ commands: MoveCommands) { self.scenario = scenario; self.commands = commands }
    func send(_ value: String, _ context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: value)), promise: nil)
    }
    func channelActive(context: ChannelHandlerContext) { send("* OK Synthetic move peer\r\n", context) }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        input += String(buffer: unwrapInboundIn(data))
        while let range = input.range(of: "\r\n") {
            let line = String(input[..<range.lowerBound]); input.removeSubrange(..<range.upperBound)
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count >= 2 else { context.close(promise: nil); return }
            let tag = String(fields[0]), command = String(fields[1]).uppercased()
            let arguments = fields.count > 2 ? String(fields[2]) : ""
            commands.append(command == "UID" ? "UID " + (arguments.split(separator: " ").first.map(String.init) ?? "") : command)
            switch command {
            case "CAPABILITY": send("* CAPABILITY IMAP4rev1 \(scenario == .noCapability ? "" : "MOVE UIDPLUS")\r\n\(tag) OK Capabilities\r\n", context)
            case "LOGIN": send("\(tag) OK Authenticated\r\n", context)
            case "SELECT": send("* FLAGS (\\Seen)\r\n* 1 EXISTS\r\n* 0 RECENT\r\n* OK [UIDVALIDITY 7] Valid\r\n* OK [UIDNEXT 43] Next\r\n\(tag) OK [READ-WRITE] Selected\r\n", context)
            case "UID":
                guard arguments == "MOVE 42 \"Archive\"" else { send("\(tag) BAD Unexpected command\r\n", context); return }
                switch scenario {
                case .confirmed: send("* OK [COPYUID 91 42 105] Moving\r\n* 1 EXPUNGE\r\n\(tag) OK Moved\r\n", context)
                case .rejected: send("\(tag) NO [NOPERM] Rejected\r\n", context)
                case .dropped: context.close(promise: nil)
                case .stalled, .noCapability: break
                }
            case "LOGOUT": send("* BYE Done\r\n\(tag) OK Logout\r\n", context)
            default: send("\(tag) BAD Unexpected\r\n", context)
            }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

extension ArchiveMoveTests {
    @Test func authenticatedOriginalClientMovesOnceAndBoundsStallsAndDisconnects() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dmail-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tlsContext = try NIOSSLContext(configuration: fixtureTLSConfiguration(in: directory))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            for scenario in MoveScenario.allCases {
                let commands = MoveCommands()
                let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                    channel.pipeline.addHandlers([NIOSSLServerHandler(context: tlsContext), MovePeer(scenario, commands)])
                }.bind(host: "127.0.0.1", port: 0).get()
                guard let port = listener.localAddress?.port else { throw IMAPError.notConnected }
                var tls = TLSConfiguration.makeClientConfiguration(); tls.certificateVerification = .none
                let client = IMAPClient(Server(hostname: "127.0.0.1", username: "synthetic", password: "synthetic", port: port),
                    logger: nil, tlsConfiguration: tls, connectionTimeout: .seconds(2), commandTimeout: 1)
                do {
                    try await client.connect(); try await client.login(); _ = try await client.selectWithPermissions(mailbox: "INBOX")
                    let start = ContinuousClock.now
                    do {
                        let moved = try await client.archiveMove(uid: 42, to: "Archive")
                        #expect(scenario == .confirmed)
                        #expect(moved.validity == 91 && moved.uid == 105)
                    } catch {
                        #expect(scenario != .confirmed)
                        if scenario == .noCapability { #expect(error as? ArchiveMoveError == .unavailable) }
                        if scenario == .rejected { #expect(error as? ArchiveMoveError == .rejected) }
                    }
                    let elapsed = start.duration(to: .now)
                    #expect(elapsed < .seconds(3))
                    if scenario == .stalled { #expect(elapsed >= .milliseconds(750)) }
                    if client.isConnected { try? await client.logout(timeout: 1) }
                    try await client.shutdown()
                    #expect(!client.isConnected)
                    let captured = commands.snapshot()
                    #expect(captured.filter { $0 == "UID MOVE" }.count == (scenario == .noCapability ? 0 : 1))
                    #expect(!captured.contains("UID COPY") && !captured.contains("UID STORE") && !captured.contains("EXPUNGE"))
                } catch { try? await client.shutdown(); try? await listener.close().get(); throw error }
                try await listener.close().get()
            }
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
}
