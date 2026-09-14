// MPL-2.0: https://mozilla.org/MPL/2.0/
import NIOIMAP

/// A notification watermark is independent from list pagination and message flags.
public struct InboxCheckCursor: Codable, Equatable, Sendable {
    public let version: Int
    public let validity: UInt32
    public let next: UInt32
    public init(validity: UInt32, next: UInt32) {
        version = 1; self.validity = validity; self.next = next
    }
    public var isValid: Bool { version == 1 && validity > 0 && next > 0 }
}

/// Baselines, epoch changes, regressions and unchanged watermarks need no FETCH.
public func inboxCheckRange(previous: InboxCheckCursor?, current: InboxCheckCursor,
                            count: Int) -> ClosedRange<SequenceNumber>? {
    guard let previous, previous.isValid, current.isValid,
          previous.validity == current.validity, previous.next < current.next,
          count > 0, count < Int(UInt32.max) else { return nil }
    return SequenceNumber(rawValue: UInt32(max(1, count - 49)))...SequenceNumber(rawValue: UInt32(count))
}

public func inboxCheckNewMessages(_ messages: [SequenceNumber: Message], range: ClosedRange<SequenceNumber>,
                                  previous: InboxCheckCursor, current: InboxCheckCursor) -> Int {
    var unseen = Set<UInt32>(), seen = Set<UInt32>()
    for (sequence, message) in messages {
        // Unsolicited FETCH updates can accompany the requested sequence range.
        guard range.contains(sequence), let uid = message.uid?.rawValue,
              uid >= previous.next, uid < current.next, message.flagsWereReceived else { continue }
        if message.flags.contains(.seen) { seen.insert(uid) } else { unseen.insert(uid) }
    }
    // Deduplicate UID responses and conservatively respect a concurrent Seen update.
    return unseen.subtracting(seen).count
}

/// EXAMINE's UNSEEN response is a sequence number, not a count. Only a
/// consistent STATUS MESSAGES/UNSEEN pair can supply a complete unread total.
public func inboxCheckUnreadTotal(messageCount: Int?, unseenCount: Int?) -> Int? {
    guard let messageCount, let unseenCount,
          messageCount >= 0, messageCount <= Int(UInt32.max),
          unseenCount >= 0, unseenCount <= messageCount else { return nil }
    return unseenCount
}
