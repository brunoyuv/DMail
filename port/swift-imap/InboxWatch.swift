// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation

public struct InboxWatchResult: Encodable, Sendable {
    public let supported: Bool
    public let changed: Bool
}
public enum InboxWatchError: Error { case invalidArgument, network, authenticationRequired, certificate, watchRestart }

/// Snapshot calls are immediate. Only the Swift task owns the persistent client;
/// the JavaScript timer consumes events without occupying NAPI worker threads.
public final class InboxWatchRegistry: @unchecked Sendable {
    public static let shared = InboxWatchRegistry()
    private let lock = NSLock()
    private var watches: [String: InboxWatchEntry] = [:]
    public init() {}

    public func snapshot(id: String, owner: [String], accessToken: String?,
                         create: @escaping @Sendable () throws -> IMAPClient) throws -> InboxWatchResult {
        guard UUID(uuidString: id) != nil else { throw InboxWatchError.invalidArgument }
        let entry: InboxWatchEntry? = try lock.withLock {
            if let existing = watches[id] {
                guard existing.owner == owner else { throw InboxWatchError.invalidArgument }
                return existing
            }
            watches = watches.filter { !$0.value.isExpired }
            guard watches.count < 8 else { return nil }
            let value = InboxWatchEntry(owner: owner, accessToken: accessToken, create: create)
            watches[id] = value; value.start(); return value
        }
        guard let entry else { return InboxWatchResult(supported: false, changed: false) }
        return try entry.snapshot()
    }
    public func stop(id: String) throws {
        guard UUID(uuidString: id) != nil else { throw InboxWatchError.invalidArgument }
        let value = lock.withLock { watches.removeValue(forKey: id) }
        value?.stop()
    }
}

private final class InboxWatchEntry: @unchecked Sendable {
    let owner: [String]
    private let accessToken: String?
    private let create: @Sendable () throws -> IMAPClient
    private let lock = NSLock()
    private var worker: Task<Void, Never>?
    private var lease: Task<Void, Never>?
    private var lastRead = Date()
    private let created = Date()
    private var changed = false
    private var ready = false
    private var supported = true
    private var renewal = false
    private var finished = false
    private var failure: InboxWatchError?
    init(owner: [String], accessToken: String?, create: @escaping @Sendable () throws -> IMAPClient) {
        self.owner = owner; self.accessToken = accessToken; self.create = create
    }
    var isExpired: Bool { lock.withLock { finished && Date().timeIntervalSince(lastRead) > 120 } }
    func snapshot() throws -> InboxWatchResult {
        try lock.withLock {
            lastRead = Date()
            if let failure { throw failure }
            let result = InboxWatchResult(supported: supported, changed: changed)
            changed = false; return result
        }
    }
    func start() {
        lock.withLock {
            worker = Task { await self.run() }
            lease = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    let expire = self.lock.withLock {
                        let now = Date()
                        if now.timeIntervalSince(self.created) > 25 * 60 { self.renewal = true }
                        return self.finished || now.timeIntervalSince(self.lastRead) > 120 ||
                            (!self.ready && now.timeIntervalSince(self.created) > 25) ||
                            now.timeIntervalSince(self.created) > 25 * 60
                    }
                    if expire { self.stop(); return }
                }
            }
        }
    }
    func stop() {
        let tasks = lock.withLock { () -> (Task<Void, Never>?, Task<Void, Never>?) in
            return (worker, lease)
        }
        tasks.0?.cancel(); tasks.1?.cancel()
    }
    private func fail(_ error: InboxWatchError) { lock.withLock { failure = renewal ? .watchRestart : error } }
    private func run() async {
        var client: IMAPClient?
        do {
            try Task.checkCancellation()
            let value = try create(); client = value
            try await value.connect()
            do {
                if let accessToken { try await value.authenticateXOAUTH2(username: value.server.username ?? "", accessToken: accessToken) }
                else {
                    try await value.login()
                    try await value.refreshCapabilities()
                }
            } catch { throw InboxWatchError.authenticationRequired }
            guard value.capabilities.contains(.idle) else {
                lock.withLock { supported = false }
                try await value.shutdown(); finish(); return
            }
            _ = try await value.examine(mailbox: Mailbox.Name("INBOX"))
            let events = try await value.idle()
            for await event in events {
                if Task.isCancelled { break }
                switch event {
                case .ready:
                    lock.withLock { ready = true; changed = true }
                case .status(let status):
                    if status.messageCount != nil { lock.withLock { changed = true } }
                case .bye:
                    throw InboxWatchError.network
                case .expunge, .fetch:
                    break
                }
            }
            // A terminated or aged connection is reopened by the foreground
            // owner with backoff; its new ready event covers any arrival gap.
            fail(.network)
        } catch { fail((error as? InboxWatchError) ?? .network) }
        if let client {
            if client.isIdling { try? await client.done() }
            try? await client.shutdown()
        }
        finish()
    }
    private func finish() {
        let timer = lock.withLock { () -> Task<Void, Never>? in
            finished = true; worker = nil; let timer = lease; lease = nil; return timer
        }
        timer?.cancel()
    }
}
