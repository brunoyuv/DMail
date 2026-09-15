// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import Testing
import NIOCore
import NIOPosix
import NIOSSL
import NIOIMAP
@testable import IMAP

struct ArchiveCreationTests {
    private func box(_ name: String, _ flags: [Mailbox.Attribute] = [], delimiter: Character? = "/") -> Mailbox {
        Mailbox(attributes: flags, path: try! Mailbox.Path(name: Mailbox.Name(name), pathSeparator: delimiter), extensions: [:])
    }
    @Test func absentArchiveUsesOneExactPersonalNamespacePrefix() {
        for prefix in ["", "INBOX.", "Mail/", "#mh/", "&T2BZfQ-/"] {
            let delimiter: Character = prefix == "INBOX." ? "." : "/"
            let list = [box("INBOX", delimiter: delimiter)]
            let plan = archiveDestination(in: list, namespaces: [Namespace(.user, delimiter: delimiter, prefix: prefix)])
            #expect(plan?.name.description == prefix + "Archive")
            #expect(plan?.requiresCreation == true)
            let after = list + [box(prefix + "Archive", delimiter: delimiter)]
            #expect(archiveDestination(in: after, namespaces: [Namespace(.user, delimiter: delimiter, prefix: prefix)])?.requiresCreation == false)
        }
    }
    @Test func ambiguousSharedOrMalformedNamespacesNeverProduceACreationPlan() {
        let list = [box("INBOX")]
        for spaces in [[Namespace](), [Namespace(.shared, prefix: "Shared/")], [Namespace(.other, prefix: "Other/")],
                       [Namespace(.user), Namespace(.user, prefix: "Mail/")], [Namespace(.user, prefix: "bad\r\n")],
                       [Namespace(.user, prefix: String(repeating: "x", count: 1001))]] {
            #expect(archiveDestination(in: list, namespaces: spaces) == nil)
        }
    }
    @Test func listFallbackUsesVisibleRootOrInboxHierarchyAndRejectsUnrelatedTrees() {
        #expect(archiveDestination(in: [box("INBOX")])?.name.description == "Archive")
        #expect(archiveDestination(in: [box("INBOX"), box("Sent")])?.name.description == "Archive")
        #expect(archiveDestination(in: [box("INBOX", delimiter: "."), box("INBOX.Sent", delimiter: ".")])?.name.description == "INBOX.Archive")
        #expect(archiveDestination(in: [box("INBOX"), box("INBOX/Sent")])?.name.description == "INBOX/Archive")
        #expect(archiveDestination(in: [box("INBOX"), box("Someone/Sent")]) == nil)
        #expect(archiveDestination(in: [box("INBOX"), box("Sent", delimiter: ".")]) == nil)
        #expect(archiveDestination(in: [box("INBOX", [.noInferiors]), box("INBOX/Sent")]) == nil)
        #expect(archiveDestination(in: [box("INBOX", delimiter: nil)])?.name.description == "Archive")
    }
    @Test func existingUnsafeOrAmbiguousArchiveNeverBecomesCreatePermission() {
        let inbox = box("INBOX")
        for rest in [[box("Archive"), box("Archives")], [box("Archive", [.noSelect])],
                     [box("Archive", [.init("\\Trash")])], [box("declared", [.init("\\Archive"), .noSelect])],
                     [box("declared", [.init("\\Archive")]), box("all", [.init("\\All")])]] {
            #expect(archiveDestination(in: [inbox] + rest) == nil)
        }
        let all = box("[Gmail]/localized", [.init("\\All")])
        #expect(archiveDestination(in: [inbox, all])?.name == all.path.name)
        #expect(archiveDestination(in: [inbox, all])?.requiresCreation == false)
    }
}

private enum CreationScenario: String, CaseIterable, Sendable {
    case root, inboxNamespace, customNamespace, race, rejected, dropped, stalled, noConfirmation, conflictingConfirmation,
         readOnly, changedEpoch, absentUID, unrelatedUID, changedAfterCreate, existing
    var prefix: String { self == .inboxNamespace ? "INBOX." : self == .customNamespace ? "Mail/" : "" }
    var delimiter: String { self == .inboxNamespace ? "." : "/" }
    var namespace: Bool { self == .inboxNamespace || self == .customNamespace || self == .existing }
    var succeeds: Bool { [.root, .inboxNamespace, .customNamespace, .race, .existing].contains(self) }
    var validatesSource: Bool { ![.readOnly, .changedEpoch, .absentUID, .unrelatedUID].contains(self) }
}
private final class CreationCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}
private final class CreationPeer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let scenario: CreationScenario, commands: CreationCommands
    let deleting: Bool
    var input = "", selected = "INBOX", created = false, selections = 0
    init(_ scenario: CreationScenario, _ commands: CreationCommands, deleting: Bool = false) { self.scenario = scenario; self.commands = commands; self.deleting = deleting }
    func send(_ value: String, _ context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: value)), promise: nil)
    }
    func channelActive(context: ChannelHandlerContext) { send("* OK Synthetic archive creation peer\r\n", context) }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        input += String(buffer: unwrapInboundIn(data))
        while let range = input.range(of: "\r\n") {
            let line = String(input[..<range.lowerBound]); input.removeSubrange(..<range.upperBound)
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count >= 2 else { context.close(promise: nil); return }
            let tag = String(fields[0]), command = String(fields[1]).uppercased()
            let arguments = fields.count > 2 ? String(fields[2]) : ""
            commands.append(command + (arguments.isEmpty ? "" : " " + arguments))
            switch command {
            case "CAPABILITY":
                send("* CAPABILITY IMAP4rev1 MOVE UIDPLUS \(scenario.namespace ? "NAMESPACE" : "")\r\n\(tag) OK Capabilities\r\n", context)
            case "LOGIN": send("\(tag) OK Authenticated\r\n", context)
            case "NAMESPACE": send("* NAMESPACE ((\"\(scenario.prefix)\" \"\(scenario.delimiter)\")) NIL NIL\r\n\(tag) OK Namespace\r\n", context)
            case "LIST":
                if deleting && scenario != .noConfirmation {
                    send("* LIST (\\Trash) \"/\" \"Trash\"\r\n", context)
                    if scenario == .conflictingConfirmation { send("* LIST (\\Trash) \"/\" \"OtherTrash\"\r\n", context) }
                }
                send("* LIST () \"\(scenario.delimiter)\" \"INBOX\"\r\n* LIST () \"\(scenario.delimiter)\" \"\(scenario.prefix)Sent\"\r\n", context)
                if scenario == .existing || (created && scenario != .noConfirmation) {
                    send("* LIST () \"\(scenario.delimiter)\" \"\(scenario.prefix)Archive\"\r\n", context)
                    if scenario == .conflictingConfirmation { send("* LIST () \"/\" \"Archives\"\r\n", context) }
                }
                send("\(tag) OK Listed\r\n", context)
            case "SELECT":
                selections += 1; selected = arguments.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let archive = selected == scenario.prefix + (deleting ? "Trash" : "Archive")
                let validity = scenario == .changedEpoch || (scenario == .changedAfterCreate && selections > 1) ? 8 : archive ? 91 : 7
                let mode = scenario == .readOnly ? "READ-ONLY" : "READ-WRITE"
                send("* FLAGS (\\Seen)\r\n* 1 EXISTS\r\n* 0 RECENT\r\n* OK [UIDVALIDITY \(validity)] Valid\r\n* OK [UIDNEXT \(archive ? 106 : 43)] Next\r\n\(tag) OK [\(mode)] Selected\r\n", context)
            case "CREATE":
                guard arguments == "\"\(scenario.prefix)Archive\"" else { send("\(tag) BAD Wrong namespace\r\n", context); return }
                switch scenario {
                case .rejected: send("\(tag) NO [NOPERM] Not permitted\r\n", context)
                case .dropped: created = true; context.close(promise: nil)
                case .stalled: break
                case .race: created = true; send("\(tag) NO [ALREADYEXISTS] Created by another client\r\n", context)
                default: created = true; send("\(tag) OK Created\r\n", context)
                }
            case "UID":
                if arguments.hasPrefix("FETCH ") {
                    if scenario != .absentUID {
                        let uid = scenario == .unrelatedUID ? 43 : selected == scenario.prefix + (deleting ? "Trash" : "Archive") ? 105 : 42
                        send("* 1 FETCH (UID \(uid) FLAGS ())\r\n", context)
                    }
                    send("\(tag) OK Fetched\r\n", context)
                } else if arguments == "MOVE 42 \"\(scenario.prefix)\(deleting ? "Trash" : "Archive")\"" {
                    if deleting && scenario == .rejected { send("\(tag) NO [NOPERM] Refused\r\n", context); return }
                    if deleting && scenario == .dropped { context.close(promise: nil); return }
                    if deleting && scenario == .stalled { return }
                    send("* OK [COPYUID 91 42 105] Moving\r\n* 1 EXPUNGE\r\n\(tag) OK Moved\r\n", context)
                } else if arguments == "MOVE 105 \"INBOX\"" {
                    send("* OK [COPYUID 7 105 106] Restoring\r\n* 1 EXPUNGE\r\n\(tag) OK Moved\r\n", context)
                } else { send("\(tag) BAD Unexpected UID command\r\n", context) }
            case "LOGOUT": send("* BYE Done\r\n\(tag) OK Logout\r\n", context)
            default: send("\(tag) BAD Unexpected command\r\n", context)
            }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

extension ArchiveCreationTests {
    @Test func shippingArchiveCreatesOnceOnlyAfterValidatedSourceThenVerifiesMovesAndUndoes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dmail-create-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tlsContext = try NIOSSLContext(configuration: fixtureTLSConfiguration(in: directory))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            for scenario in CreationScenario.allCases {
                let commands = CreationCommands()
                let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                    channel.pipeline.addHandlers([NIOSSLServerHandler(context: tlsContext), CreationPeer(scenario, commands)])
                }.bind(host: "127.0.0.1", port: 0).get()
                guard let port = listener.localAddress?.port else { throw IMAPError.notConnected }
                var tls = TLSConfiguration.makeClientConfiguration(); tls.certificateVerification = .none
                let client = IMAPClient(Server(hostname: "127.0.0.1", username: "synthetic", password: "synthetic", port: port),
                    logger: nil, tlsConfiguration: tls, connectionTimeout: .seconds(2), commandTimeout: 1)
                do {
                    try await client.connect(); try await client.login()
                    let metadata = try await client.list().map { $0.0 }
                    let hint = try await discoverArchiveDestination(client: client, mailboxes: metadata)
                    #expect(hint?.name.description == scenario.prefix + "Archive")
                    #expect(hint?.requiresCreation == (scenario != .existing))
                    let before = commands.snapshot()
                    #expect(!before.contains(where: { $0.hasPrefix("CREATE") || $0.hasPrefix("UID ") || $0.hasPrefix("SELECT ") }))
                    let start = ContinuousClock.now
                    do {
                        let archived = try await archiveMessage(client: client, source: "INBOX", validity: 7, uid: 42)
                        #expect(scenario.succeeds, "Unexpected move success: \(scenario.rawValue)")
                        #expect(archived.destination.description == scenario.prefix + "Archive")
                        #expect(archived.move.validity == 91 && archived.move.uid == 105)
                        if scenario.succeeds {
                            let restored = try await archiveMessage(client: client, source: archived.destination, validity: 91, uid: 105, undoInbox: "INBOX")
                            #expect(restored.destination == Mailbox.Name("INBOX"))
                            #expect(restored.move.validity == 7 && restored.move.uid == 106)
                        }
                    } catch {
                        #expect(!scenario.succeeds, "Unexpected error for \(scenario.rawValue): \(String(reflecting: error))")
                        switch scenario {
                        case .readOnly: #expect(error as? ArchiveOperationError == .readOnly)
                        case .changedEpoch, .changedAfterCreate: #expect(error as? ArchiveOperationError == .identityChanged)
                        case .absentUID: #expect(error as? ArchiveOperationError == .messageNotFound)
                        case .unrelatedUID: #expect(error as? ArchiveOperationError == .invalidResponse)
                        case .rejected: #expect(error as? ArchiveOperationError == .forbidden)
                        case .dropped, .stalled: #expect(error as? ArchiveOperationError == .createUnconfirmed)
                        case .noConfirmation, .conflictingConfirmation: #expect(error as? ArchiveOperationError == .unavailable)
                        default: break
                        }
                    }
                    let elapsed = start.duration(to: .now)
                    #expect(elapsed < .seconds(4), "\(scenario.rawValue): \(elapsed)")
                    if scenario == .stalled { #expect(elapsed >= .milliseconds(750)) }
                    let captured = commands.snapshot()
                    let creates = captured.enumerated().filter { $0.element.hasPrefix("CREATE ") }
                    #expect(creates.count == (scenario.validatesSource && scenario != .existing ? 1 : 0))
                    if let creation = creates.first {
                        let earlier = captured.prefix(creation.offset)
                        #expect(earlier.contains("SELECT \"INBOX\""))
                        #expect(earlier.contains("UID FETCH 42 (UID FLAGS)"))
                    }
                    let moves = captured.enumerated().filter { $0.element.hasPrefix("UID MOVE ") }
                    #expect(moves.count == (scenario.succeeds ? 2 : 0))
                    if let move = moves.first, let creation = creates.first {
                        #expect(captured[(creation.offset + 1)..<move.offset].contains(where: { $0.hasPrefix("LIST ") }))
                    }
                    #expect(!captured.contains(where: { $0.hasPrefix("UID STORE ") || $0.hasPrefix("UID COPY ") || $0 == "EXPUNGE" }))
                    if scenario == .existing { #expect(!captured.contains("NAMESPACE")) }
                    if client.isConnected { try? await client.logout(timeout: 1) }
                    try await client.shutdown(); #expect(!client.isConnected)
                } catch { try? await client.shutdown(); try? await listener.close().get(); throw error }
                try await listener.close().get()
            }
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
}

extension ArchiveCreationTests {
    @Test func trashSelectionRequiresOneExistingSafeDestination() {
        let inbox = box("INBOX")
        #expect(trashMailbox(in: [inbox, box("Trash")])?.description == "Trash")
        #expect(trashMailbox(in: [inbox, box("INBOX.Deleted Items", delimiter: ".")])?.description == "INBOX.Deleted Items")
        #expect(trashMailbox(in: [inbox, box("本地化", [.init("\\Trash")])])?.description == "本地化")
        for rest in [[], [box("Trash"), box("Deleted Items")], [box("Trash", [.noSelect])],
                     [box("Trash", [.init("\\Sent")])], [box("a", [.init("\\Trash")]), box("b", [.init("\\Trash")])],
                     [box("bad\r\nname", [.init("\\Trash")])]] as [[Mailbox]] {
            #expect(trashMailbox(in: [inbox] + rest) == nil)
        }
    }
    @Test func deleteAndUndoNeverCreateFoldersAndPreserveSourceChecks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dmail-trash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tlsContext = try NIOSSLContext(configuration: fixtureTLSConfiguration(in: directory))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            for scenario in [CreationScenario.root, .readOnly, .changedEpoch, .absentUID, .unrelatedUID,
                             .rejected, .dropped, .stalled, .noConfirmation, .conflictingConfirmation] {
                let commands = CreationCommands()
                let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                    channel.pipeline.addHandlers([NIOSSLServerHandler(context: tlsContext), CreationPeer(scenario, commands, deleting: true)])
                }.bind(host: "127.0.0.1", port: 0).get()
                let port = try #require(listener.localAddress?.port)
                var tls = TLSConfiguration.makeClientConfiguration(); tls.certificateVerification = .none
                let client = IMAPClient(Server(hostname: "127.0.0.1", username: "synthetic", password: "synthetic", port: port),
                    logger: nil, tlsConfiguration: tls, connectionTimeout: .seconds(2), commandTimeout: 1)
                do {
                    try await client.connect(); try await client.login()
                    do {
                        let moved = try await deleteMessage(client: client, source: "INBOX", validity: 7, uid: 42)
                        #expect(scenario == .root)
                        #expect(moved.destination.description == "Trash")
                        #expect(moved.move.validity == 91 && moved.move.uid == 105)
                        let undo = try await deleteMessage(client: client, source: moved.destination, validity: 91, uid: 105, undoInbox: "INBOX")
                        #expect(undo.destination.description == "INBOX" && undo.move.uid == 106)
                    } catch {
                        #expect(scenario != .root, "\(error)")
                        if scenario == .rejected { #expect(error as? ArchiveOperationError == .forbidden) }
                        if scenario == .dropped || scenario == .stalled { #expect(error as? ArchiveOperationError == .moveUnconfirmed) }
                    }
                    let all = commands.snapshot()
                    #expect(!all.contains(where: { $0.hasPrefix("CREATE") || $0.hasPrefix("EXPUNGE") || $0.hasPrefix("UID STORE") || $0.hasPrefix("NAMESPACE") }))
                    let expectedMoves = scenario == .root ? 2 : [.rejected, .dropped, .stalled].contains(scenario) ? 1 : 0
                    #expect(all.filter { $0.hasPrefix("UID MOVE") }.count == expectedMoves)
                    try? await client.shutdown()
                } catch { try? await client.shutdown(); try? await listener.close().get(); throw error }
                try await listener.close().get()
            }
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
}
