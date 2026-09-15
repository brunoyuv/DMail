// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import Testing
import NIOCore
import NIOPosix
import NIOSSL
import NIOIMAP
@testable import IMAP

private final class SyncTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ value: String) { lock.withLock { names.append(value) } }
    func count(_ value: String) -> Int { lock.withLock { names.filter { $0 == value }.count } }
}
private final class SyncPeer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let trace: SyncTrace
    let stall: Bool
    var input = ""
    init(trace: SyncTrace, stall: Bool) { self.trace = trace; self.stall = stall }
    func send(_ text: String, _ context: ChannelHandlerContext) { context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: text)), promise: nil) }
    func channelActive(context: ChannelHandlerContext) { trace.add("CONNECT"); send("* OK Synthetic sync peer\r\n", context) }
    func channelInactive(context: ChannelHandlerContext) { trace.add("CLOSE"); context.fireChannelInactive() }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        input += String(buffer: unwrapInboundIn(data))
        while let end = input.range(of: "\r\n") {
            let line = String(input[..<end.lowerBound]); input.removeSubrange(..<end.upperBound)
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count >= 2 else { context.close(promise: nil); return }
            let tag = String(fields[0]), name = String(fields[1]).uppercased(); trace.add(name)
            switch name {
            case "CAPABILITY": send("* CAPABILITY IMAP4rev1\r\n\(tag) OK Capabilities\r\n", context)
            case "LOGIN": send("\(tag) OK Authenticated\r\n", context)
            case "EXAMINE":
                send("* FLAGS (\\Seen)\r\n* 3 EXISTS\r\n* 0 RECENT\r\n* OK [UIDVALIDITY 7] Valid\r\n* OK [UIDNEXT 4] Next\r\n\(tag) OK [READ-ONLY] Selected\r\n", context)
            case "UID":
                if !stall { send("* 1 FETCH (UID 1 FLAGS ())\r\n\(tag) OK Fetched\r\n", context) }
            default: send("\(tag) BAD Unexpected command\r\n", context)
            }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
private final class HandshakePeer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let trace: SyncTrace
    init(_ trace: SyncTrace) { self.trace = trace }
    func channelActive(context: ChannelHandlerContext) { trace.add("TCP"); context.fireChannelActive() }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { /* Hold TLS handshake deliberately. */ }
    func channelInactive(context: ChannelHandlerContext) { trace.add("CLOSE"); context.fireChannelInactive() }
}
private struct SyncFixture {
    let trace: SyncTrace, group: MultiThreadedEventLoopGroup, server: Channel, directory: URL
    var port: Int { server.localAddress!.port! }
    static func start(stall: Bool = false, handshake: Bool = false) async throws -> Self {
        let trace = SyncTrace(), group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dmail-sync-session-\(UUID().uuidString)")
        let context = try NIOSSLContext(configuration: fixtureTLSConfiguration(in: directory))
        let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            if handshake { return channel.pipeline.addHandler(HandshakePeer(trace)) }
            return channel.pipeline.addHandlers([NIOSSLServerHandler(context: context), SyncPeer(trace: trace, stall: stall)])
        }.bind(host: "127.0.0.1", port: 0).get()
        return Self(trace: trace, group: group, server: server, directory: directory)
    }
    func stop() async { try? await server.close().get(); try? await group.shutdownGracefully(); try? FileManager.default.removeItem(at: directory) }
    func create() -> IMAPClient {
        trace.add("CLIENT")
        var tls = TLSConfiguration.makeClientConfiguration(); tls.certificateVerification = .none
        return IMAPClient(Server(hostname: "127.0.0.1", username: "synthetic", password: "synthetic", port: port),
            logger: nil, tlsConfiguration: tls, connectionTimeout: .seconds(1), commandTimeout: 1)
    }
    func read(_ pool: SyncReadSessionPool, _ id: String, owner: [String] = ["synthetic"], fail: Bool = false) async throws -> Int {
        try await pool.read(id: id, owner: owner, create: { create() }, authenticate: { try await $0.login() }, operation: { client in
            if fail { throw SyncReadSessionError.invalidArgument }
            let status = try await client.examine(mailbox: "INBOX")
            let messages = try await client.fetch(uid: UIDSet(UID(rawValue: 1)), attributes: [.uid, .flags])
            return (status.messageCount ?? 0) + messages.count
        })
    }
}
private func eventually(_ condition: @escaping @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}
private func rejects(_ body: () async throws -> Void) async { do { try await body(); Issue.record("Expected synthetic failure") } catch {} }

struct SyncReadSessionTests {
    @Test func multipleReadsReuseOneOriginalTLSClientThenReadLimitRotatesIt() async throws {
        let f = try await SyncFixture.start(), pool = SyncReadSessionPool(idle: .seconds(15), age: .seconds(60), maxReads: 3)
        let id = UUID().uuidString
        do {
            for _ in 0..<3 { #expect(try await f.read(pool, id) == 4) }
            #expect(f.trace.count("CLIENT") == 1 && f.trace.count("CONNECT") == 1 && f.trace.count("LOGIN") == 1)
            try await eventually { f.trace.count("CLOSE") == 1 }
            #expect(try await f.read(pool, id) == 4)
            #expect(f.trace.count("CLIENT") == 2 && f.trace.count("LOGIN") == 2)
            try await pool.close(id: id)
            try await eventually { f.trace.count("CLOSE") == 2 }
            print("Synthetic sync session reuse: 4 reads, 2 TLS clients/authentications with 3-read limit; 4 EXAMINE and 4 UID FETCH, no replay")
        } catch { try? await pool.close(id: id); await f.stop(); throw error }
        await f.stop()
    }

    @Test func closeBeforeOpenAndOwnerChangesRejectWithoutNewTLSAndFreshUUIDWorks() async throws {
        let f = try await SyncFixture.start(), pool = SyncReadSessionPool(), retired = UUID().uuidString, active = UUID().uuidString, next = UUID().uuidString
        do {
            try await pool.close(id: retired)
            await rejects { _ = try await f.read(pool, retired) }; #expect(f.trace.count("CLIENT") == 0)
            #expect(try await f.read(pool, active, owner: ["endpoint", "login", "old-token"]) == 4)
            await rejects { _ = try await f.read(pool, active, owner: ["endpoint", "login", "new-token"]) }
            #expect(f.trace.count("CLIENT") == 1)
            await rejects { _ = try await f.read(pool, active, owner: ["endpoint", "login", "old-token"]) }
            #expect(try await f.read(pool, next, owner: ["endpoint", "login", "new-token"]) == 4)
            try await pool.close(id: active); #expect(try await f.read(pool, next, owner: ["endpoint", "login", "new-token"]) == 4)
            try await pool.close(id: next)
            try await eventually { f.trace.count("CLOSE") == 2 }
        } catch { try? await pool.close(id: active); try? await pool.close(id: next); await f.stop(); throw error }
        await f.stop()
    }

    @Test func activeReadIsExclusiveAndExplicitCloseCancelsWithoutReplay() async throws {
        let f = try await SyncFixture.start(stall: true), pool = SyncReadSessionPool(), id = UUID().uuidString
        let first = Task { try await f.read(pool, id) }
        do {
            try await eventually { f.trace.count("UID") == 1 }
            await rejects { _ = try await f.read(pool, id) }
            #expect(f.trace.count("CLIENT") == 1 && f.trace.count("UID") == 1)
            let start = ContinuousClock.now; try await pool.close(id: id)
            await rejects { _ = try await first.value }
            #expect(start.duration(to: .now) < .seconds(2))
            try await eventually { f.trace.count("CLOSE") == 1 }
            #expect(f.trace.count("UID") == 1)
        } catch { first.cancel(); try? await pool.close(id: id); await f.stop(); throw error }
        await f.stop()
    }

    @Test func parentCancellationAndFailedOperationDisposeConnectionWithoutAutomaticRetry() async throws {
        let f = try await SyncFixture.start(stall: true), pool = SyncReadSessionPool(), id = UUID().uuidString
        let first = Task { try await f.read(pool, id) }
        do {
            try await eventually { f.trace.count("UID") == 1 }; first.cancel()
            await rejects { _ = try await first.value }
            try await eventually { f.trace.count("CLOSE") == 1 }
            #expect(f.trace.count("CLIENT") == 1)
            await rejects { _ = try await f.read(pool, id, fail: true) }
            #expect(f.trace.count("CLIENT") == 2 && f.trace.count("UID") == 1)
            try await eventually { f.trace.count("CLOSE") == 2 }
        } catch { first.cancel(); try? await pool.close(id: id); await f.stop(); throw error }
        await f.stop()
    }

    @Test func idleAndAgeDeadlinesDisposeWithoutPollingAndAReadUsesFreshClientAfterExpiry() async throws {
        let f = try await SyncFixture.start(), pool = SyncReadSessionPool(idle: .milliseconds(80), age: .milliseconds(250), maxReads: 16), id = UUID().uuidString
        do {
            #expect(try await f.read(pool, id) == 4)
            try await eventually { f.trace.count("CLOSE") == 1 }
            #expect(try await f.read(pool, id) == 4)
            try await pool.close(id: id)
            try await eventually { f.trace.count("CLOSE") == 2 }
            let ageID = UUID().uuidString, agePool = SyncReadSessionPool(idle: .seconds(5), age: .milliseconds(100), maxReads: 16)
            #expect(try await f.read(agePool, ageID) == 4)
            try await eventually { f.trace.count("CLOSE") == 3 }
            try await agePool.close(id: ageID)
        } catch { try? await pool.close(id: id); await f.stop(); throw error }
        await f.stop()
    }

    @Test func commandTimeoutAndActiveAgeExpiryCloseWithoutReplayingTheRead() async throws {
        for age in [Duration.seconds(60), Duration.milliseconds(150)] {
            let f = try await SyncFixture.start(stall: true)
            let pool = SyncReadSessionPool(idle: .seconds(15), age: age, maxReads: 16), id = UUID().uuidString
            do {
                let start = ContinuousClock.now
                await rejects { _ = try await f.read(pool, id) }
                #expect(start.duration(to: .now) < .seconds(3))
                #expect(f.trace.count("CLIENT") == 1 && f.trace.count("CONNECT") == 1 && f.trace.count("UID") == 1)
                try await eventually { f.trace.count("CLOSE") == 1 }
                try await pool.close(id: id)
                await rejects { _ = try await f.read(pool, id) }
                #expect(f.trace.count("CLIENT") == 1)
            } catch { try? await pool.close(id: id); await f.stop(); throw error }
            await f.stop()
        }
    }

    @Test func invalidIdentifiersAndRepeatedClosedRequestsNeverConstructClients() async throws {
        let pool = SyncReadSessionPool(), id = UUID().uuidString
        let create: @Sendable () throws -> IMAPClient = { Issue.record("Invalid/closed request created a client"); throw SyncReadSessionError.invalidArgument }
        await rejects { let _: Int = try await pool.read(id: "not-a-uuid", owner: ["synthetic"], create: create, authenticate: { _ in }, operation: { _ in 1 }) }
        try await pool.close(id: id.lowercased())
        for _ in 0..<20 {
            await rejects { let _: Int = try await pool.read(id: id, owner: ["synthetic"], create: create, authenticate: { _ in }, operation: { _ in 1 }) }
            try await pool.close(id: id)
        }
    }

    @Test func poolCapacityAndCloseDuringTLSHandshakeAreBounded() async throws {
        let f = try await SyncFixture.start(), pool = SyncReadSessionPool(idle: .seconds(15), age: .seconds(60), maxReads: 16, maxSessions: 2)
        let ids = (0..<3).map { _ in UUID().uuidString }
        do {
            #expect(try await f.read(pool, ids[0]) == 4); #expect(try await f.read(pool, ids[1]) == 4)
            await rejects { _ = try await f.read(pool, ids[2]) }; #expect(f.trace.count("CLIENT") == 2)
            try await pool.close(id: ids[0]); #expect(try await f.read(pool, ids[2]) == 4)
            for id in ids { try await pool.close(id: id) }
        } catch { for id in ids { try? await pool.close(id: id) }; await f.stop(); throw error }
        await f.stop()
        let held = try await SyncFixture.start(handshake: true), heldPool = SyncReadSessionPool(), heldID = UUID().uuidString
        let pending = Task { try await held.read(heldPool, heldID) }
        do {
            try await eventually { held.trace.count("TCP") == 1 }
            let start = ContinuousClock.now; try await heldPool.close(id: heldID)
            await rejects { _ = try await pending.value }
            #expect(start.duration(to: .now) < .seconds(3)); #expect(held.trace.count("CLIENT") == 1)
        } catch { pending.cancel(); try? await heldPool.close(id: heldID); await held.stop(); throw error }
        await held.stop()
    }
}
