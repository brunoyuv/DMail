// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation

public enum SyncReadSessionError: Error { case invalidArgument, closed, busy, ownerChanged }

/// Bounded, serial sessions for read-only sync. Each owner receives one original
/// IMAPClient; mutations, SMTP and IDLE never enter this pool. Failed exchanges
/// are discarded rather than replayed on another connection.
public final class SyncReadSessionPool: @unchecked Sendable {
    public static let shared = SyncReadSessionPool()
    private let lock = NSLock()
    private var entries: [String: SyncReadSessionEntry] = [:]
    private var closedIDs: [String: ContinuousClock.Instant] = [:]
    private let idle: Duration, age: Duration, maxReads: Int, maxSessions: Int
    public init() { idle = .seconds(15); age = .seconds(60); maxReads = 16; maxSessions = 4 }
    init(idle: Duration, age: Duration, maxReads: Int, maxSessions: Int = 4) {
        self.idle = idle; self.age = age; self.maxReads = maxReads; self.maxSessions = maxSessions
    }

    private func identity(_ id: String) throws -> String {
        guard let value = UUID(uuidString: id) else { throw SyncReadSessionError.invalidArgument }
        return value.uuidString
    }
    private func rememberClosed(_ id: String, now: ContinuousClock.Instant) {
        closedIDs = closedIDs.filter { $0.value > now }
        closedIDs[id] = now.advanced(by: .seconds(120))
        if closedIDs.count > 256, let oldest = closedIDs.min(by: { $0.value < $1.value })?.key { closedIDs.removeValue(forKey: oldest) }
    }

    public func read<Value: Sendable>(id: String, owner: [String],
        create: @escaping @Sendable () throws -> IMAPClient,
        authenticate: @escaping @Sendable (IMAPClient) async throws -> Void,
        operation: @escaping @Sendable (IMAPClient) async throws -> Value) async throws -> Value {
        let id = try identity(id)
        guard !owner.isEmpty, owner.count <= 8, owner.reduce(0, { $0 + $1.utf8.count }) <= 128 * 1024 else {
            throw SyncReadSessionError.invalidArgument
        }
        var replaced: SyncReadSessionEntry?, problem: SyncReadSessionError?
        let entry: SyncReadSessionEntry? = lock.withLock {
            let now = ContinuousClock.now
            closedIDs = closedIDs.filter { $0.value > now }
            if closedIDs[id] != nil { problem = .closed; return nil }
            if let existing = entries[id] {
                if existing.owner != owner {
                    entries.removeValue(forKey: id); rememberClosed(id, now: now)
                    replaced = existing; problem = .ownerChanged; return nil
                }
                switch existing.claim() {
                case .claimed: return existing
                case .busy: problem = .busy; return nil
                case .retired: entries.removeValue(forKey: id); replaced = existing
                }
            }
            entries = entries.filter { !$0.value.isRetired }
            guard entries.count < maxSessions else { problem = .busy; return nil }
            let fresh = SyncReadSessionEntry(owner: owner, idle: idle, age: age, maxReads: maxReads)
            entries[id] = fresh
            _ = fresh.claim()
            return fresh
        }
        if let replaced { await replaced.stop() }
        guard let entry else { throw problem ?? SyncReadSessionError.closed }
        return try await entry.run(create: create, authenticate: authenticate, operation: operation)
    }

    /// Remember closure even before a queued bridge read registers its entry.
    /// UUIDs are private, rotated by the caller, and never intentionally reused.
    public func close(id: String) async throws {
        let id = try identity(id)
        let entry = lock.withLock { () -> SyncReadSessionEntry? in
            rememberClosed(id, now: .now)
            return entries.removeValue(forKey: id)
        }
        await entry?.stop()
    }
}

private final class SyncReadSessionEntry: @unchecked Sendable {
    enum Claim { case claimed, busy, retired }
    let owner: [String]
    private let lock = NSLock()
    private let created = ContinuousClock.now
    private let idle: Duration, age: Duration, maxReads: Int
    private var reads = 0, generation = 0, runRevision = 0
    private var busy = false, closed = false
    private var client: IMAPClient?
    private var cancel: (@Sendable () -> Void)?
    private var expiry: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(owner: [String], idle: Duration, age: Duration, maxReads: Int) {
        self.owner = owner; self.idle = idle; self.age = age; self.maxReads = maxReads
    }
    var isRetired: Bool { lock.withLock { closed && !busy } }

    func claim() -> Claim {
        lock.withLock {
            if busy { return .busy }
            if closed || reads >= maxReads || ContinuousClock.now >= created.advanced(by: age) { return .retired }
            busy = true; runRevision += 1; armExpiry(at: created.advanced(by: age))
            return .claimed
        }
    }
    private func armExpiry(at deadline: ContinuousClock.Instant) {
        generation += 1; let expected = generation
        expiry?.cancel()
        expiry = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            await self?.expire(expected)
        }
    }
    private func expire(_ expected: Int) async {
        let shouldStop = lock.withLock { () -> Bool in
            guard generation == expected else { return false }
            closed = true; return true
        }
        if shouldStop { await stop() }
    }

    func run<Value: Sendable>(create: @escaping @Sendable () throws -> IMAPClient,
        authenticate: @escaping @Sendable (IMAPClient) async throws -> Void,
        operation: @escaping @Sendable (IMAPClient) async throws -> Value) async throws -> Value {
        let revision = lock.withLock { runRevision }
        let task = Task<Value, Error> {
            do {
                try Task.checkCancellation()
                guard !self.lock.withLock({ self.closed }) else { throw SyncReadSessionError.closed }
                let existing = self.lock.withLock { self.client }
                let active: IMAPClient
                if let existing { MailDownloadTrace.current?.mark(.connect, reason: .sessionReused); active = existing }
                else {
                    MailDownloadTrace.current?.mark(.connect, reason: .sessionCreated)
                    active = try create()
                    self.lock.withLock { self.client = active }
                    try Task.checkCancellation()
                    try await active.connect()
                    try Task.checkCancellation()
                    try await authenticate(active)
                }
                try Task.checkCancellation()
                let value = try await operation(active)
                try Task.checkCancellation()
                await self.finish(success: true)
                return value
            } catch {
                await self.finish(success: false)
                throw error
            }
        }
        let cancelled = lock.withLock { () -> Bool in
            // A very fast failure may finish before this installation, and a
            // new claimant may already own the entry's cancellation slot.
            guard busy, runRevision == revision else { return true }
            cancel = { task.cancel() }; return closed
        }
        if cancelled { task.cancel() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func finish(success: Bool) async {
        let discarded = lock.withLock { () -> IMAPClient? in
            if success { reads += 1 }
            if !success || closed || client?.isConnected == false || reads >= maxReads || ContinuousClock.now >= created.advanced(by: age) {
                closed = true; generation += 1; expiry?.cancel(); expiry = nil
                let value = client; client = nil; return value
            }
            return nil
        }
        if let discarded {
            MailDownloadTrace.current?.mark(.shutdown, reason: .sessionDiscarded)
            do { try await discarded.shutdown(); MailDownloadTrace.current?.mark(.shutdownDone) }
            catch { MailDownloadTrace.current?.mark(.cleanupFailed, error: error) }
        }
        let completed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            // stop() may arrive during shutdown or between the two locks.
            // If it closed a retained client, let stop() own that shutdown.
            busy = false; cancel = nil
            if !closed { armExpiry(at: min(ContinuousClock.now.advanced(by: idle), created.advanced(by: age))) }
            let values = waiters; waiters.removeAll(); return values
        }
        for waiter in completed { waiter.resume() }
    }

    func stop() async {
        let values = lock.withLock { () -> ((@Sendable () -> Void)?, IMAPClient?) in
            closed = true; generation += 1; expiry?.cancel(); expiry = nil
            let value = busy ? nil : client
            if !busy { client = nil }
            return (cancel, value)
        }
        values.0?()
        if let client = values.1 { try? await client.shutdown() }
        await withCheckedContinuation { continuation in
            let complete = lock.withLock { () -> Bool in
                if busy { waiters.append(continuation); return false }
                return true
            }
            if complete { continuation.resume() }
        }
        // A close racing the final successful result may have been observed
        // after finish's first lock. Claim the now-idle client exactly once.
        let remaining = lock.withLock { () -> IMAPClient? in let value = client; client = nil; return value }
        if let remaining { try? await remaining.shutdown() }
    }
}
