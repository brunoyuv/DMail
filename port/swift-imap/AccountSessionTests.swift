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

private enum ReadFailureScenario: CaseIterable, Sendable { case rejected, truncatedLiteral, conflictingUID }

// Only UID 2 fails, after successful login and BODYSTRUCTURE. Healthy UID 1
// must remain readable on the next connection after every failed attempt.
private final class ReadFailurePeer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let scenario: ReadFailureScenario, commands: SessionCommands, senderDomain: String
    var input = ""
    let singlepartBytes: Int?
    static func syntheticHTML(_ count: Int) -> String {
        let prefix = "<html><head><style>", suffix = "</style></head><body><p>=E4=BD=A0=E5=A5=BD</p></body></html>"
        return prefix + String(repeating: " ", count: count - prefix.utf8.count - suffix.utf8.count) + suffix
    }
    init(_ scenario: ReadFailureScenario, commands: SessionCommands, senderDomain: String, singlepartBytes: Int? = nil) {
        self.scenario = scenario; self.commands = commands; self.senderDomain = senderDomain; self.singlepartBytes = singlepartBytes
    }
    func send(_ value: String, _ context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: value)), promise: nil)
    }
    func channelActive(context: ChannelHandlerContext) {
        commands.append("CONNECT"); send("* OK Synthetic read peer\r\n", context)
    }
    func channelInactive(context: ChannelHandlerContext) {
        commands.append("CLOSE"); context.fireChannelInactive()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        input += String(buffer: unwrapInboundIn(data))
        while let end = input.range(of: "\r\n") {
            let line = String(input[..<end.lowerBound]); input.removeSubrange(..<end.upperBound)
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count >= 2 else { context.close(promise: nil); return }
            let tag = String(fields[0]), command = String(fields[1]).uppercased()
            let arguments = fields.count > 2 ? String(fields[2]) : ""
            commands.append(command)
            switch command {
            case "CAPABILITY": send("* CAPABILITY IMAP4rev1 AUTH=XOAUTH2 SASL-IR\r\n\(tag) OK Capabilities\r\n", context)
            case "LOGIN", "AUTHENTICATE": send("\(tag) OK Authenticated\r\n", context)
            case "EXAMINE":
                send("* FLAGS (\\Seen)\r\n* 2 EXISTS\r\n* OK [UIDVALIDITY 7] Valid\r\n\(tag) OK [READ-ONLY] Selected\r\n", context)
            case "FETCH":
                for uid in 1...2 {
                    let address = "((\"Synthetic sender\" NIL \"offers\" \"\(senderDomain)\"))"
                    let envelope = "(NIL \"Synthetic offer\" \(address) \(address) \(address) NIL NIL NIL NIL \"<synthetic-\(uid)@example.test>\")"
                    send("* \(uid) FETCH (UID \(uid) FLAGS () ENVELOPE \(envelope) BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"8BIT\" 5 1))\r\n", context)
                }
                send("\(tag) OK Headers\r\n", context)
            case "UID":
                let uid = arguments.hasPrefix("FETCH 2 ") ? 2 : 1
                if let count = singlepartBytes {
                    if arguments.contains("BODYSTRUCTURE") {
                        commands.append("STRUCTURE")
                        send("* 1 FETCH (UID 1 BODYSTRUCTURE (\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"QUOTED-PRINTABLE\" \(count) 1))\r\n\(tag) OK Structure\r\n", context)
                    } else {
                        commands.append("BODY")
                        var mime = ""
                        if arguments.contains("BODY.PEEK[HEADER]") {
                            let section = "HEADER"
                            let header = "Subject: Synthetic offer\r\nFrom: offers@example.test\r\nMIME-Version: 1.0\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
                            mime = "BODY[\(section)] {\(header.utf8.count)}\r\n\(header) "
                            commands.append("ROOT_HEADERS")
                        }
                        // Match the uploaded trace: 1.MIME is absent, but the
                        // full advertised BODY[1] arrives and FETCH ends OK.
                        send("* 1 FETCH (UID 1 \(mime)BODY[1] {\(count)}\r\n\(Self.syntheticHTML(count)))\r\n\(tag) OK Body\r\n", context)
                    }
                } else if arguments.contains("<0.2048>") {
                    commands.append("PREVIEW")
                    // The bad message has no usable sample, as in the report.
                    send("* 1 FETCH (UID 1 BODY[1]<0> {5}\r\nhello)\r\n* 2 FETCH (UID 2 BODY[1]<0> {0}\r\n)\r\n\(tag) OK Samples\r\n", context)
                } else if arguments.contains("BODYSTRUCTURE") {
                    send("* \(uid) FETCH (UID \(uid) BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"8BIT\" 5 1))\r\n\(tag) OK Structure\r\n", context)
                } else if uid == 2 {
                    switch scenario {
                    case .rejected: send("\(tag) NO Synthetic part unavailable\r\n", context)
                    case .truncatedLiteral:
                        // Keep the socket open with a promised literal unfinished.
                        send("* 2 FETCH (UID 2 BODY[1] {100}\r\nshort", context)
                    case .conflictingUID:
                        send("* 2 FETCH (UID 2 FLAGS ())\r\n* 2 FETCH (UID 3 FLAGS ())\r\n\(tag) OK Conflicting\r\n", context)
                    }
                } else {
                    let header = "Content-Type: text/plain; charset=utf-8\r\n\r\n"
                    let section = arguments.components(separatedBy: "BODY.PEEK[").dropFirst().first?.components(separatedBy: "]").first ?? "1.MIME"
                    send("* 1 FETCH (UID 1 BODY[\(section)] {\(header.utf8.count)}\r\n\(header) BODY[1] {5}\r\nhello)\r\n\(tag) OK Body\r\n", context)
                }
            case "LOGOUT": send("* BYE Finished\r\n\(tag) OK Logged out\r\n", context)
            default: send("\(tag) BAD Unexpected command\r\n", context)
            }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

struct AccountSessionTests {
    @Test(arguments: [false, true], [80407, 97088])
    func singlepartHTMLUsesRootMIMEHeadersWhenPartMIMEIsAbsent(oauth: Bool, bytes: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dmail-singlepart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try NIOSSLContext(configuration: fixtureTLSConfiguration(in: directory))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let commands = SessionCommands()
        do {
            let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                channel.pipeline.addHandlers([NIOSSLServerHandler(context: context),
                    ReadFailurePeer(.rejected, commands: commands, senderDomain: "email.microsoft.com", singlepartBytes: bytes)])
            }.bind(host: "127.0.0.1", port: 0).get()
            do {
                var tls = TLSConfiguration.makeClientConfiguration(); tls.certificateVerification = .none
                let port = try #require(server.localAddress?.port)
                let client = IMAPClient(Server(hostname: "127.0.0.1", username: "synthetic", password: "synthetic", port: port),
                    logger: nil, tlsConfiguration: tls, connectionTimeout: .seconds(2), commandTimeout: 2)
                do {
                    try await client.connect()
                    if oauth { try await client.authenticateXOAUTH2(username: "synthetic", accessToken: "synthetic-token") }
                    else { try await client.login() }
                    _ = try await client.examine(mailbox: "INBOX")
                    let trace = MailDownloadTrace()
                    let readable = try #require(try await MailDownloadTrace.$current.withValue(trace) { try await client.fetchReadable(uid: 1) })
                    let body = try #require(readable.body)
                    #expect(body.part.data == Data(ReadFailurePeer.syntheticHTML(bytes).utf8))
                    #expect(body.part.contentType.subtype == "html")
                    #expect(body.contentTransferEncoding == .quotedPrintable)
                    #expect(body.part.contentTypeParameters["charset"] == "utf-8")
                    #expect(!readable.partial && !readable.hasAttachments)
                    #expect(trace.snapshot().contains { $0.stage == "partDone" && $0.bytes == bytes })
                    #expect(!trace.snapshot().contains { $0.stage == "partRejected" })
                    #expect(commands.snapshot().filter { $0 == "STRUCTURE" }.count == 1)
                    #expect(commands.snapshot().filter { $0 == "BODY" }.count == 1)
                    #expect(commands.snapshot().filter { $0 == "ROOT_HEADERS" }.count == 1)
                    try await client.logout(timeout: 1)
                    try await client.shutdown()
                    #expect(!client.isConnected)
                } catch { try? await client.shutdown(); throw error }
            } catch { try? await server.close().get(); throw error }
            try await server.close().get()
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }

    @Test(arguments: [false, true])
    func pooledInboxHeadersAndSinglepartBodiesUseOneLogin(oauth: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dmail-mixed-reads-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try NIOSSLContext(configuration: fixtureTLSConfiguration(in: directory))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1), commands = SessionCommands()
        let pool = SyncReadSessionPool(), id = UUID().uuidString
        do {
            let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                channel.pipeline.addHandlers([NIOSSLServerHandler(context: context),
                    ReadFailurePeer(.rejected, commands: commands, senderDomain: "email.microsoft.com", singlepartBytes: 97088)])
            }.bind(host: "127.0.0.1", port: 0).get()
            do {
                let port = try #require(server.localAddress?.port)
                for bodyRead in [false, true, false, true, true, false] {
                    let trace = MailDownloadTrace()
                    let count = try await MailDownloadTrace.$current.withValue(trace) {
                        try await pool.read(id: id, owner: ["synthetic", oauth ? "oauth" : "password"], create: {
                            var tls = TLSConfiguration.makeClientConfiguration(); tls.certificateVerification = .none
                            return IMAPClient(Server(hostname: "127.0.0.1", username: "synthetic", password: "synthetic", port: port),
                                logger: nil, tlsConfiguration: tls, connectionTimeout: .seconds(2), commandTimeout: 2)
                        }, authenticate: { client in
                            if oauth { try await client.authenticateXOAUTH2(username: "synthetic", accessToken: "synthetic-token") }
                            else { try await client.login() }
                        }, operation: { client in
                            _ = try await client.examine(mailbox: "INBOX")
                            if bodyRead {
                                let readable = try #require(try await client.fetchReadable(uid: 1))
                                #expect(readable.body?.part.data == Data(ReadFailurePeer.syntheticHTML(97088).utf8))
                                #expect(!readable.partial)
                                return 1
                            }
                            let headers = try await client.fetch(SequenceSet(range: .init(SequenceNumber(1)...SequenceNumber(2))),
                                attributes: [.bodyStructure(extensions: true)] + .standard)
                            return headers.count
                        })
                    }
                    #expect(count == (bodyRead ? 1 : 2))
                    #expect(trace.snapshot().contains { $0.reason == (commands.snapshot().filter { $0 == "EXAMINE" }.count == 1 ? "sessionCreated" : "sessionReused") })
                }
                #expect(commands.snapshot().filter { $0 == "CONNECT" }.count == 1)
                #expect(commands.snapshot().filter { $0 == (oauth ? "AUTHENTICATE" : "LOGIN") }.count == 1)
                #expect(commands.snapshot().filter { $0 == "ROOT_HEADERS" }.count == 3)
                try await pool.close(id: id)
            } catch { try? await pool.close(id: id); try? await server.close().get(); throw error }
            try await server.close().get(); try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }

    // Sender is changed independently of credentials and message content.
    // Both saved password LOGIN and the Microsoft browser-login XOAUTH2 path
    // exercise the original client over local TLS, without any real account.
    @Test(arguments: [false, true], ["microsoft.com", "email.microsoft.com", "accountprotection.microsoft.com",
        "outlook.com", "microsoft.com.example.test", "control.example.test"])
    func repeatedMessageFailuresCloseEachConnectionAndDoNotPoisonLaterReads(oauth: Bool, senderDomain: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dmail-read-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try NIOSSLContext(configuration: fixtureTLSConfiguration(in: directory))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            for scenario in ReadFailureScenario.allCases {
                let commands = SessionCommands()
                let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                    channel.pipeline.addHandlers([NIOSSLServerHandler(context: context), ReadFailurePeer(scenario, commands: commands, senderDomain: senderDomain)])
                }.bind(host: "127.0.0.1", port: 0).get()
                do {
                    let port = try #require(server.localAddress?.port)
                    for _ in 0..<3 {
                        for uid in [UID(rawValue: 2), UID(rawValue: 1)] {
                            var tls = TLSConfiguration.makeClientConfiguration(); tls.certificateVerification = .none
                            let client = IMAPClient(Server(hostname: "127.0.0.1", username: "synthetic", password: "synthetic", port: port),
                                logger: nil, tlsConfiguration: tls, connectionTimeout: .seconds(1), commandTimeout: 1)
                            let started = ContinuousClock.now
                            let outcome: Result<ReadableMessage?, Error>
                            let trace = MailDownloadTrace()
                            do {
                                try await client.connect()
                                if oauth { try await client.authenticateXOAUTH2(username: "synthetic", accessToken: "synthetic-token") }
                                else { try await client.login() }
                                _ = try await client.examine(mailbox: "INBOX")
                                // Read a new inbox page before every body attempt, including
                                // after the preceding failed connection has been closed.
                                let headers = try await client.fetch(SequenceSet(range: .init(SequenceNumber(1)...SequenceNumber(2))),
                                    attributes: [.bodyStructure(extensions: true)] + .standard)
                                #expect(headers.count == 2)
                                for message in headers.values {
                                    #expect(message.envelope.subject == "Synthetic offer")
                                    #expect(message.envelope.from.flatMap { $0.addresses }.map { $0.value } == ["offers@" + senderDomain])
                                    #expect(message.body == nil)
                                }
                                let section = SectionSpecifier(part: .init([1]))
                                let samples = try await client.fetch(uid: UIDSet(range: .init(UID(1)...UID(2))),
                                    attributes: [.uid, .bodySection(peek: true, section, 0...2047)], timeout: 1)
                                #expect(samples.values.first { $0.uid == 1 }?.bodySections[section] == Data("hello".utf8))
                                #expect(samples.values.first { $0.uid == 2 }?.bodySections[section]?.isEmpty == true)
                                outcome = .success(try await MailDownloadTrace.$current.withValue(trace) { try await client.fetchReadable(uid: uid) })
                            } catch { outcome = .failure(error) }
                            do {
                                let message = try await finishIMAPOperation(outcome,
                                    logout: { if client.isConnected { try await client.logout(timeout: 1) } },
                                    shutdown: { try await client.shutdown() })
                                #expect(uid == 1)
                                #expect(message?.body?.part.data == Data("hello".utf8))
                            } catch {
                                #expect(uid == 2)
                                #expect(!(error is AuthenticationFailure))
                            }
                            let events = trace.snapshot()
                            #expect(events.first?.stage == "structure")
                            #expect(events.contains { $0.stage == (uid == 1 ? "assemble" : "commandFailed") })
                            if uid == 2 && scenario == .truncatedLiteral { #expect(events.contains { $0.code == "timeout" }) }
                            if uid == 1 || scenario == .truncatedLiteral { #expect(events.contains { $0.stage == "literalStart" }) }
                            #expect(events.contains { $0.stage == "part" && $0.part == 1 && $0.bytes == 5 })
                            #expect(!client.isConnected)
                            #expect(started.duration(to: .now) < .seconds(3))
                            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                            while commands.snapshot().filter({ $0 == "CLOSE" }).count < commands.snapshot().filter({ $0 == "CONNECT" }).count && ContinuousClock.now < deadline {
                                try await Task.sleep(for: .milliseconds(10))
                            }
                            let names = commands.snapshot()
                            #expect(names.filter { $0 == "CLOSE" }.count == names.filter { $0 == "CONNECT" }.count)
                        }
                    }
                    let names = commands.snapshot()
                    #expect(names.filter { $0 == "CONNECT" }.count == 6)
                    #expect(names.filter { $0 == "LOGIN" }.count == (oauth ? 0 : 6))
                    #expect(names.filter { $0 == "AUTHENTICATE" }.count == (oauth ? 6 : 0))
                    #expect(names.filter { $0 == "FETCH" }.count == 6)
                    #expect(names.filter { $0 == "PREVIEW" }.count == 6)
                    #expect(names.filter { $0 == "UID" }.count == 18)
                    #expect(names.filter { $0 == "LOGOUT" }.count == 3)
                } catch { try? await server.close().get(); throw error }
                try await server.close().get()
            }
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }

    @Test func downloadTraceBoundsEventsAndNeverSerializesAssociatedErrorText() throws {
        let trace = MailDownloadTrace()
        for _ in 0..<600 { trace.mark(.part, part: 9999, bytes: Int.max, error: IMAPError.unexpectedResponse("SECRET mail/token")) }
        let events = trace.snapshot()
        #expect(events.count == 513)
        #expect(events.dropLast().allSatisfy { $0.part == 512 && $0.bytes == 33554432 && $0.code == "invalidResponse" })
        let json = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        #expect(!json.contains("SECRET"))
        trace.mark(.failed, error: IMAPError.timedOut(seconds: 10))
        #expect(trace.snapshot().dropLast().last?.code == "timeout")
        trace.mark(.failed, error: AuthenticationFailure.rejected)
        #expect(trace.snapshot().dropLast().last?.code == "authenticationRejected")
        #expect(MailDownloadTrace.current == nil)
    }

    @Test func everyPartRejectionHasAnExactReasonAndSafeByteCounts() throws {
        let good = Data("Content-Type: text/html; charset=utf-8\r\n\r\n".utf8)
        let payload = Data("<p>Synthetic offer</p>".utf8)
        let cases: [(String, Data?, Data?, Int, Int, String?)] = [
            ("missingHeader", nil, payload, 80407, 0, nil),
            ("missingContent", good, nil, 80407, 0, nil),
            ("headerLimit", Data(repeating: 65, count: 65537), payload, 80407, 0, nil),
            ("contentLimit", good, Data(repeating: 65, count: 4 * 1024 * 1024 + 1), 97088, 0, nil),
            ("emptyUnexpected", good, Data(), 80407, 0, nil),
            ("aggregateLimit", good, payload, 80407, 7 * 1024 * 1024, nil),
            ("mimeParse", Data("Content-Type: text/html".utf8), payload, 80407, 0, "separatorMissing"),
            ("mimeParse", Data("Content-Type: text/html\r\nContent-Type: text/plain\r\n\r\n".utf8), payload, 97088, 0, "duplicateHeader"),
            ("mimeParse", Data("Content-Type: SECRET-invalid\r\n\r\n".utf8), payload, 97088, 0, "contentTypeInvalid")
        ]
        for (reason, headers, content, expected, total, mimeReason) in cases {
            let trace = MailDownloadTrace()
            let result = MailDownloadTrace.$current.withValue(trace) {
                validatedReadableSection(headers: headers, content: content, expected: expected, total: total, ordinal: 1, section: [1, 2])
            }
            #expect(result == nil)
            let events = trace.snapshot()
            #expect(events.last?.reason == reason)
            #expect(events.first?.values == [headers?.count ?? -1, content?.count ?? -1, expected, total])
            #expect(events.last?.section == [1, 2])
            if let mimeReason { #expect(events.contains { $0.stage == "mime" && $0.reason == mimeReason }) }
            #expect(!String(decoding: try JSONEncoder().encode(events), as: UTF8.self).contains("SECRET"))
        }
        for count in [80407, 97088] {
            let content = Data(repeating: 65, count: count), trace = MailDownloadTrace()
            let result = MailDownloadTrace.$current.withValue(trace) {
                validatedReadableSection(headers: good, content: content, expected: count, total: 0, ordinal: 1, section: [1])
            }
            #expect(result == good + content)
            #expect(trace.snapshot().contains { $0.reason == "parsed" })
            #expect(!trace.snapshot().contains { $0.stage == "partRejected" })
        }
    }

    @Test func lateCleanupIsRetainedOnceWithoutPollingOrUnboundedGrowth() {
        let completions = MailDownloadCompletions(), trace = MailDownloadTrace()
        trace.mark(.shutdownDone)
        #expect(completions.begin() == 1)
        #expect(completions.begin() == 2)
        completions.finish(attempt: 1, trace: trace.snapshot(), wasLate: false)
        completions.finish(attempt: 2, trace: trace.snapshot(), wasLate: true)
        let late = completions.drain()
        #expect(late.count == 1 && late[0].attempt == 2 && late[0].trace.last?.stage == "shutdownDone")
        #expect(completions.drain().isEmpty)
        for id in 3...15 {
            #expect(completions.begin() == 1)
            completions.finish(attempt: id, trace: trace.snapshot(), wasLate: true)
        }
        #expect(completions.drain().count == 8)
    }

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
