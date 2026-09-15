// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import Testing
import NIOCore
import NIOPosix
import NIOSSL
import NIOIMAP
@testable import IMAP

private enum SessionScenario: String, CaseIterable, Sendable {
    case statusStall, statusRejected, suppliedCounts, logoutStall, confirmedStoreLogoutStall, unconfirmedStoreDrop
    var store: Bool { self == .confirmedStoreLogoutStall || self == .unconfirmedStoreDrop }
}

private final class SessionCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ command: String) { lock.lock(); defer { lock.unlock() }; values.append(command) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class SessionPeer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let scenario: SessionScenario, commands: SessionCommands
    var input = "", seen = false
    init(_ scenario: SessionScenario, commands: SessionCommands) { self.scenario = scenario; self.commands = commands }
    func send(_ value: String, _ context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: value)), promise: nil)
    }
    func channelActive(context: ChannelHandlerContext) {
        commands.append("CONNECT"); send("* OK Synthetic session peer\r\n", context)
    }
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
            case "CAPABILITY":
                send("* CAPABILITY IMAP4rev1 LIST-EXTENDED LIST-STATUS\r\n\(tag) OK Capabilities\r\n", context)
            case "LOGIN": send("\(tag) OK Authenticated\r\n", context)
            case "LIST":
                send("* LIST () \"/\" \"INBOX\"\r\n* LIST () \"/\" \"Archive\"\r\n* LIST () \"/\" \"Sent\"\r\n", context)
                if scenario == .suppliedCounts {
                    for name in ["INBOX", "Archive", "Sent"] {
                        send("* STATUS \"\(name)\" (MESSAGES 10 UNSEEN 3)\r\n", context)
                    }
                } else if scenario == .statusStall || scenario == .statusRejected {
                    // Preserve both partial and complete LIST-supplied counts
                    // after the first optional request stalls or is rejected.
                    send("* STATUS \"INBOX\" (MESSAGES 10)\r\n* STATUS \"Sent\" (MESSAGES 4 UNSEEN 0)\r\n", context)
                }
                send("\(tag) OK Listed\r\n", context)
            case "STATUS":
                if !arguments.hasSuffix("(MESSAGES UNSEEN)") { commands.append("INVALID_STATUS") }
                if scenario == .statusStall { /* Deliberately no acknowledgement. */ }
                else if scenario == .statusRejected { send("\(tag) NO Status unavailable\r\n", context) }
                else {
                    let mailbox = arguments.components(separatedBy: " (")[0]
                    send("* STATUS \(mailbox) (MESSAGES 10 UNSEEN 3)\r\n\(tag) OK Counted\r\n", context)
                }
            case "SELECT", "EXAMINE":
                send("* FLAGS (\\Seen)\r\n* 1 EXISTS\r\n* 0 RECENT\r\n* OK [UIDVALIDITY 7] Valid\r\n* OK [UIDNEXT 2] Next\r\n* OK [PERMANENTFLAGS (\\Seen)] Flags\r\n\(tag) OK [READ-WRITE] Selected\r\n", context)
            case "UID":
                if arguments.hasPrefix("STORE ") {
                    seen = true
                    if scenario == .unconfirmedStoreDrop { context.close(promise: nil) }
                    else { send("\(tag) OK Stored\r\n", context) }
                } else if arguments.hasPrefix("FETCH ") {
                    if !arguments.hasSuffix("(UID FLAGS)") { commands.append("INVALID_FETCH") }
                    send("* 1 FETCH (UID 1 FLAGS (\(seen ? "\\Seen" : "")))\r\n\(tag) OK Fetched\r\n", context)
                } else { send("\(tag) BAD Unexpected UID command\r\n", context) }
            case "LOGOUT":
                if scenario != .logoutStall && scenario != .confirmedStoreLogoutStall {
                    send("* BYE Finished\r\n\(tag) OK Logged out\r\n", context)
                }
            default: send("\(tag) BAD Unexpected command\r\n", context)
            }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

private enum SessionFailure: Error, Equatable { case changeUnconfirmed, cleanup }

struct AccountSessionTests {
    @Test func optionalCountBudgetUsesMonotonicDeadlineAndShortCommandLimits() {
        let now = ContinuousClock.now, counts = OptionalMailboxCounts(now: now)
        #expect(counts.timeout(now: now) == 2)
        #expect(counts.timeout(now: now.advanced(by: .seconds(3))) == 2)
        #expect(counts.timeout(now: now.advanced(by: .milliseconds(3500))) == 1)
        #expect(counts.timeout(now: now.advanced(by: .milliseconds(4001))) == nil)
        #expect(counts.timeout(now: now.advanced(by: .seconds(5))) == nil)
        #expect(counts.timeout(now: now.advanced(by: .seconds(8))) == nil)
        #expect(VoidCommand(.logout).timeout == 60)
        #expect(VoidCommand(.logout, timeout: 1).timeout == 1)
        #expect(VoidCommand(.expunge).timeout == 60)
    }

    @Test func cleanupFailuresCannotReplaceConfirmedResult() async throws {
        var calls: [String] = []
        let value = try await finishIMAPOperation(Result<String, Error>.success("confirmed"), logout: {
            calls.append("logout"); throw SessionFailure.cleanup
        }, shutdown: {
            calls.append("shutdown"); throw SessionFailure.cleanup
        })
        #expect(value == "confirmed")
        #expect(calls == ["logout", "shutdown"])
    }

    @Test func failedOperationSkipsLogoutAndPreservesOriginalFailure() async throws {
        let errors: [Error] = [SessionFailure.changeUnconfirmed, AuthenticationFailure.rejected, SentAppendError.unconfirmed]
        for original in errors {
            var calls: [String] = []
            var caught: Error?
            do {
                let _: String = try await finishIMAPOperation(.failure(original), logout: {
                    calls.append("logout"); throw SessionFailure.cleanup
                }, shutdown: {
                    calls.append("shutdown"); throw SessionFailure.cleanup
                })
            } catch { caught = error }
            let actual = try #require(caught)
            #expect(String(reflecting: actual) == String(reflecting: original))
            #expect(calls == ["shutdown"])
        }
    }

    @Test func actualTLSOptionalCountAndLogoutStallsPreserveProvedResultsWithoutRetries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dmail-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try NIOSSLContext(configuration: fixtureTLSConfiguration(in: directory))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            for scenario in SessionScenario.allCases {
                let commands = SessionCommands()
                let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                    channel.pipeline.addHandlers([NIOSSLServerHandler(context: context), SessionPeer(scenario, commands: commands)])
                }.bind(host: "127.0.0.1", port: 0).get()
                guard let port = server.localAddress?.port else { throw IMAPError.notConnected }
                var tls = TLSConfiguration.makeClientConfiguration(); tls.certificateVerification = .none
                let client = IMAPClient(Server(hostname: "127.0.0.1", username: "synthetic-user", password: "synthetic-password", port: port),
                    logger: nil, tlsConfiguration: tls, connectionTimeout: .seconds(2), commandTimeout: 10)
                do {
                    try await client.connect(); try await client.login()
                    let start = ContinuousClock.now
                    if scenario.store {
                        let selected = try await client.selectWithPermissions(mailbox: "INBOX")
                        let validity = flagMutationValidity(selected.status), uid = UID(rawValue: 1)
                        let identifiers = UIDSet(range: .init(uid...uid))
                        #expect(validity == 7 && selected.mayStore(.seen))
                        let before = try await client.fetch(uid: identifiers, attributes: [.uid, .flags])
                        #expect(flagMutationTarget(in: before, uid: uid)?.flags.contains(.seen) == false)
                        let outcome: Result<String, Error>
                        do {
                            try await client.setFlag(uid: uid, flag: .seen, enabled: true)
                            let after = try await client.fetch(uid: identifiers, attributes: [.uid, .flags])
                            let again = try await client.examine(mailbox: "INBOX")
                            guard flagMutationTarget(in: after, uid: uid)?.flags.contains(.seen) == true,
                                  flagMutationValidity(again) == validity else { throw SessionFailure.changeUnconfirmed }
                            outcome = .success("confirmed")
                        } catch { outcome = .failure(SessionFailure.changeUnconfirmed) }
                        do {
                            let value = try await finishIMAPOperation(outcome,
                                logout: { if client.isConnected { try await client.logout(timeout: 1) } },
                                shutdown: { try await client.shutdown() })
                            #expect(scenario == .confirmedStoreLogoutStall && value == "confirmed")
                        } catch { #expect(scenario == .unconfirmedStoreDrop && error as? SessionFailure == .changeUnconfirmed) }
                    } else {
                        let listed = try await client.list()
                        var counts = OptionalMailboxCounts(), received: [(String, Mailbox.Status?)] = []
                        for (box, supplied) in listed {
                            let status = try await counts.status(mailbox: box.path.name, supplied: supplied, client: client)
                            received.append((box.path.name.description, status))
                        }
                        let result = try await finishIMAPOperation(Result<[(String, Mailbox.Status?)], Error>.success(received),
                            logout: { if client.isConnected { try await client.logout(timeout: 1) } },
                            shutdown: { try await client.shutdown() })
                        #expect(result.map { $0.0 } == ["INBOX", "Archive", "Sent"])
                        if scenario == .statusStall || scenario == .statusRejected {
                            #expect(result[0].1?.messageCount == 10 && result[0].1?.unseenCount == nil)
                            #expect(result[1].1 == nil)
                            #expect(result[2].1?.messageCount == 4 && result[2].1?.unseenCount == 0)
                        } else { #expect(result.allSatisfy { $0.1?.messageCount == 10 && $0.1?.unseenCount == 3 }) }
                    }
                    let elapsed = start.duration(to: .now)
                    #expect(elapsed < .seconds(4), "\(scenario.rawValue): \(elapsed)")
                    if scenario == .statusStall { #expect(elapsed >= .milliseconds(1500)) }
                    if scenario == .logoutStall || scenario == .confirmedStoreLogoutStall { #expect(elapsed >= .milliseconds(750)) }
                    #expect(!client.isConnected)
                    let names = commands.snapshot()
                    #expect(names.filter { $0 == "CONNECT" }.count == 1)
                    #expect(names.filter { $0 == "LOGIN" }.count == 1)
                    #expect(names.filter { $0 == "CAPABILITY" }.count == 1)
                    #expect(names.filter { $0 == "LIST" }.count == (scenario.store ? 0 : 1))
                    let statusCount = scenario == .suppliedCounts || scenario.store ? 0 : scenario == .logoutStall ? 3 : 1
                    #expect(names.filter { $0 == "STATUS" }.count == statusCount)
                    #expect(names.filter { $0 == "UID STORE" }.count == (scenario.store ? 1 : 0))
                    #expect(names.filter { $0 == "UID FETCH" }.count == (scenario == .confirmedStoreLogoutStall ? 2 : scenario == .unconfirmedStoreDrop ? 1 : 0))
                    let logoutCount = scenario == .statusStall || scenario == .statusRejected || scenario == .unconfirmedStoreDrop ? 0 : 1
                    #expect(names.filter { $0 == "LOGOUT" }.count == logoutCount)
                    #expect(!names.contains("INVALID_FETCH") && !names.contains("INVALID_STATUS"))
                    print("Synthetic account cleanup: \(scenario.rawValue), \(elapsed), commands=\(names.joined(separator: ","))")
                } catch {
                    try? await client.shutdown(); try? await server.close().get(); throw error
                }
                try await server.close().get()
            }
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
}
