// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation

/// Folder counts decorate already verified LIST results. A slow optional
/// STATUS must not consume an ordinary ten-second command deadline per folder.
public struct OptionalMailboxCounts {
    private let deadline: ContinuousClock.Instant
    private var failed = false
    public init() { self.init(now: ContinuousClock.now) }
    init(now: ContinuousClock.Instant) { deadline = now.advanced(by: .seconds(5)) }

    func timeout(now: ContinuousClock.Instant = ContinuousClock.now) -> Int64? {
        let seconds = now.duration(to: deadline).components.seconds
        guard !failed, seconds >= 1 else { return nil }
        return min(2, seconds)
    }

    public mutating func status(mailbox: Mailbox.Name, supplied: Mailbox.Status?, client: IMAPClient) async throws -> Mailbox.Status? {
        if supplied?.messageCount != nil && supplied?.unseenCount != nil { return supplied }
        guard let timeout = timeout() else { return supplied }
        do {
            return try await client.status(mailbox: mailbox, attributes: [.messageCount, .unseenCount], timeout: timeout)
        } catch {
            try Task.checkCancellation()
            failed = true
            return supplied
        }
    }
}

/// Cleanup is attempted once, independently of the proved operation result.
/// Failed operations never add LOGOUT or get reclassified by cleanup errors.
public func finishIMAPOperation<Value>(_ outcome: Result<Value, Error>,
    logout: () async throws -> Void, shutdown: () async throws -> Void) async throws -> Value {
    if case .success = outcome { try? await logout() }
    try? await shutdown()
    return try outcome.get()
}
