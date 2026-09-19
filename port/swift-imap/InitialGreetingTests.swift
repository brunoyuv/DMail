// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import Testing
import NIOCore
import NIOPosix
import NIOEmbedded
import NIOIMAP
import NIOSSL
@testable import IMAP

private final class GreetingTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func add(_ value: String) { lock.lock(); defer { lock.unlock() }; events.append(value) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return events }
}

private enum GreetingScenario: Sendable {
    case immediate, delayedIR, delayedChallenge, bye, preauth, malformed, tagged, continuation, missing, drop
    var accepted: Bool { self == .immediate || self == .delayedIR || self == .delayedChallenge }
}

private final class GreetingPeer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let scenario: GreetingScenario, trace: GreetingTrace
    private var input = "", greeted = false, challengeTag: String?
    private var delayed: Scheduled<Void>?
    init(_ scenario: GreetingScenario, _ trace: GreetingTrace) { self.scenario = scenario; self.trace = trace }
    private func send(_ value: String, _ context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: value)), promise: nil)
    }
    func channelActive(context: ChannelHandlerContext) {
        trace.add("CONNECTED")
        if scenario == .missing { return }
        if scenario == .drop { context.close(promise: nil); return }
        if scenario == .delayedIR || scenario == .delayedChallenge {
            let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            delayed = context.eventLoop.scheduleTask(in: .milliseconds(250)) { self.greeting(boundContext.value) }
        } else { greeting(context) }
    }
    private func greeting(_ context: ChannelHandlerContext) {
        greeted = true; trace.add("GREETING")
        switch scenario {
        case .bye: send("* BYE synthetic-private-response\r\n", context)
        case .preauth: send("* PREAUTH synthetic-private-response\r\n", context)
        case .malformed: send("* INVALID synthetic-private-response\r\n", context)
        case .tagged: send("a1 OK synthetic-private-response\r\n", context)
        case .continuation: send("+ synthetic-private-response\r\n", context)
        default: send("* OK Synthetic greeting peer\r\n", context)
        }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if !greeted {
            trace.add("EARLY_COMMAND")
            send("* BYE Client sent before greeting\r\n", context)
            context.close(promise: nil)
            return
        }
        input += String(buffer: unwrapInboundIn(data))
        while let end = input.range(of: "\r\n") {
            let line = String(input[..<end.lowerBound]); input.removeSubrange(..<end.upperBound)
            let expected = Data("user=synthetic-user\u{1}auth=Bearer synthetic-token\u{1}\u{1}".utf8).base64EncodedString()
            if let tag = challengeTag {
                trace.add(line == expected ? "VALID_CONTINUATION" : "INVALID_CONTINUATION")
                challengeTag = nil; send("\(tag) OK Authenticated\r\n", context); continue
            }
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count >= 2 else { trace.add("INVALID_COMMAND"); context.close(promise: nil); return }
            let tag = String(fields[0]), command = String(fields[1]); trace.add(command)
            switch command {
            case "CAPABILITY":
                let ir = scenario == .delayedChallenge ? "" : " SASL-IR"
                send("* CAPABILITY IMAP4rev1 AUTH=XOAUTH2\(ir)\r\n\(tag) OK Capabilities\r\n", context)
            case "AUTHENTICATE":
                if scenario == .delayedChallenge { challengeTag = tag; send("+ \r\n", context) }
                else {
                    trace.add(fields.count == 3 && fields[2] == "XOAUTH2 \(expected)" ? "VALID_INITIAL" : "INVALID_INITIAL")
                    send("\(tag) OK Authenticated\r\n", context)
                }
            case "LOGOUT": send("* BYE Closing\r\n\(tag) OK Logout\r\n", context)
            default: send("\(tag) BAD Unexpected command\r\n", context)
            }
        }
    }
    func channelInactive(context: ChannelHandlerContext) {
        delayed?.cancel(); delayed = nil; trace.add("CLOSED"); context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

private final class GreetingClientBox: @unchecked Sendable {
    let client: IMAPClient
    init(_ client: IMAPClient) { self.client = client }
}

private final class GreetingResult: @unchecked Sendable {
    var completions = 0
    var succeeded = false
}

struct InitialGreetingTests {
    @Test func actualTLSWaitsBeforeCommandsAndPreservesBothOAuthPhases() async throws {
        try await withPeers([.immediate, .delayedIR, .delayedChallenge]) { client, trace, scenario in
            try await client.connect()
            try await client.authenticateXOAUTH2(username: "synthetic-user", accessToken: "synthetic-token")
            try await client.logout(timeout: 1)
            let events = trace.snapshot()
            #expect(!events.contains("EARLY_COMMAND"))
            #expect(events.filter { $0 == "CAPABILITY" }.count == 2)
            #expect(events.filter { $0 == "AUTHENTICATE" }.count == 1)
            #expect(events.contains(scenario == .delayedChallenge ? "VALID_CONTINUATION" : "VALID_INITIAL"))
            #expect(!events.contains("INVALID_CONTINUATION") && !events.contains("INVALID_INITIAL"))
        }
    }

    @Test func rejectedInvalidMissingAndDroppedGreetingsCloseWithoutCommands() async throws {
        try await withPeers([.bye, .preauth, .malformed, .tagged, .continuation, .missing, .drop]) { client, trace, scenario in
            let start = ContinuousClock.now
            do { try await client.connect(); Issue.record("Unexpected accepted greeting: \(scenario)") }
            catch {
                #expect(!(error is AuthenticationFailure))
                #expect(!String(describing: error).contains("synthetic-private-response"))
            }
            #expect(start.duration(to: .now) < .seconds(3))
            #expect(!client.isConnected)
            let events = trace.snapshot()
            #expect(!events.contains("EARLY_COMMAND"))
            #expect(!events.contains("CAPABILITY") && !events.contains("AUTHENTICATE"))
            try await waitForClose(trace)
        }
    }

    @Test func cancellationClosesThePendingGreetingWithoutWaitingForItsDeadline() async throws {
        try await withPeers([.missing], timeout: .seconds(5)) { client, trace, _ in
            let box = GreetingClientBox(client)
            let pending = Task { try await box.client.connect() }
            do {
                for _ in 0..<100 {
                    if trace.snapshot().contains("CONNECTED") { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(trace.snapshot().contains("CONNECTED"))
                let start = ContinuousClock.now; pending.cancel()
                do { try await pending.value; Issue.record("Cancelled connect succeeded") }
                catch { #expect(error is CancellationError) }
                #expect(start.duration(to: .now) < .seconds(1))
                #expect(!client.isConnected)
                #expect(!trace.snapshot().contains("EARLY_COMMAND"))
                try await waitForClose(trace)
            } catch { pending.cancel(); _ = try? await pending.value; throw error }
        }
    }

    @Test func greetingDeadlineAndRemovalCompleteOnceAndReleaseTimers() throws {
        for success in [false, true] {
            let loop = EmbeddedEventLoop(), result = GreetingResult()
            let handler = InitialGreetingHandler(eventLoop: loop, timeout: .milliseconds(50))
            handler.ready.whenComplete { outcome in
                result.completions += 1
                if case .success = outcome { result.succeeded = true }
            }
            let channel = EmbeddedChannel(handlers: [IMAPClientHandler(), handler], loop: loop)
            if success { _ = try channel.writeInbound(ByteBuffer(string: "* OK Ready\r\n")) }
            else { loop.advanceTime(by: .milliseconds(50)) }
            _ = channel.pipeline.syncOperations.removeHandler(handler)
            _ = try? channel.finish(acceptAlreadyClosed: true)
            loop.advanceTime(by: .seconds(10))
            #expect(result.completions == 1)
            #expect(result.succeeded == success)
        }
    }

    private func waitForClose(_ trace: GreetingTrace) async throws {
        for _ in 0..<100 {
            if trace.snapshot().contains("CLOSED") { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Synthetic peer connection was not closed")
    }

    private func withPeers(_ scenarios: [GreetingScenario], timeout: TimeAmount = .seconds(1),
        operation: (IMAPClient, GreetingTrace, GreetingScenario) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dmail-greeting-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try NIOSSLContext(configuration: fixtureTLSConfiguration(in: directory))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            for scenario in scenarios {
                let trace = GreetingTrace()
                let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                    channel.pipeline.addHandlers([NIOSSLServerHandler(context: context), GreetingPeer(scenario, trace)])
                }.bind(host: "127.0.0.1", port: 0).get()
                guard let port = server.localAddress?.port else { throw IMAPError.notConnected }
                var tls = TLSConfiguration.makeClientConfiguration()
                tls.certificateVerification = .none // Synthetic self-signed loopback peer only.
                let client = IMAPClient(Server(hostname: "127.0.0.1", username: "synthetic-user", password: "synthetic-password", port: port),
                    logger: nil, tlsConfiguration: tls, connectionTimeout: timeout, commandTimeout: 1)
                do { try await operation(client, trace, scenario) }
                catch { try? await client.shutdown(); try? await server.close().get(); throw error }
                try await client.shutdown(); try await server.close().get()
            }
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
}
