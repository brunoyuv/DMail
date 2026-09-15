// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import Testing
import NIOIMAP
@testable import IMAP

struct InboxCheckTests {
    private func cursor(_ next: UInt32, validity: UInt32 = 77) -> InboxCheckCursor { InboxCheckCursor(validity: validity, next: next) }
    private func message(_ uid: UInt32?, flags: [Flag]?) -> Message {
        var components: [Message.Component] = []
        if let uid { components.append(.uid(UID(rawValue: uid))) }
        if let flags { components.append(.flags(Set(flags))) }
        return Message(components)
    }
    @Test func onlyNewUIDsInTheSameEpochNeedFetch() {
        #expect(inboxCheckRange(previous: nil, current: cursor(181), count: 80) == nil)
        #expect(inboxCheckRange(previous: cursor(181), current: cursor(181), count: 79) == nil)
        #expect(inboxCheckRange(previous: cursor(181), current: cursor(10, validity: 78), count: 9) == nil)
        #expect(inboxCheckRange(previous: cursor(181), current: cursor(100), count: 80) == nil)
        #expect(inboxCheckRange(previous: cursor(180), current: cursor(181), count: 0) == nil)
    }
    @Test func fetchIsBoundedToTheNewestFiftySequenceNumbers() {
        #expect(inboxCheckRange(previous: cursor(170), current: cursor(181), count: 80) == 31...80)
        #expect(inboxCheckRange(previous: cursor(1), current: cursor(6), count: 5) == 1...5)
        #expect(inboxCheckRange(previous: cursor(1), current: cursor(UInt32.max), count: Int(UInt32.max) - 1)?.count == 50)
    }
    @Test func countUsesExplicitUnseenFlagsAndOriginalUIDWindowOnly() {
        let records: [SequenceNumber: Message] = [
            31: message(170, flags: []), 32: message(171, flags: [.seen]),
            33: message(169, flags: []), 34: message(181, flags: []),
            35: message(172, flags: nil), 36: message(nil, flags: []),
            37: message(170, flags: []), 38: message(173, flags: []),
            39: message(173, flags: [.seen]), 80: message(180, flags: [.flagged]),
            2: message(174, flags: []), 81: message(175, flags: [])
        ]
        #expect(inboxCheckNewMessages(records, range: 31...80, previous: cursor(170), current: cursor(181)) == 2)
        #expect(inboxCheckNewMessages([:], range: 31...80, previous: cursor(170), current: cursor(181)) == 0)
    }
    @Test func versionAndPositiveWatermarksAreRequired() throws {
        #expect(cursor(1).isValid)
        #expect(!cursor(0).isValid); #expect(!cursor(1, validity: 0).isValid)
        let decoder = JSONDecoder()
        let wrongVersion = try decoder.decode(InboxCheckCursor.self, from: Data(#"{"version":2,"validity":77,"next":181}"#.utf8))
        #expect(!wrongVersion.isValid)
        for value in [#"{"validity":77,"next":181}"#, #"{"version":1,"validity":77,"next":-1}"#, #"{"version":1,"validity":77,"next":4294967296}"#] {
            #expect(throws: DecodingError.self) { try decoder.decode(InboxCheckCursor.self, from: Data(value.utf8)) }
        }
    }
    @Test func unreadTotalRequiresAConsistentStatusCountPair() {
        #expect(inboxCheckUnreadTotal(messageCount: 900, unseenCount: 731) == 731)
        #expect(inboxCheckUnreadTotal(messageCount: 0, unseenCount: 0) == 0)
        #expect(inboxCheckUnreadTotal(messageCount: Int(UInt32.max), unseenCount: Int(UInt32.max)) == Int(UInt32.max))
        #expect(inboxCheckUnreadTotal(messageCount: nil, unseenCount: 1) == nil)
        #expect(inboxCheckUnreadTotal(messageCount: 1, unseenCount: nil) == nil)
        #expect(inboxCheckUnreadTotal(messageCount: -1, unseenCount: 0) == nil)
        #expect(inboxCheckUnreadTotal(messageCount: 2, unseenCount: -1) == nil)
        #expect(inboxCheckUnreadTotal(messageCount: 2, unseenCount: 3) == nil)
        #expect(inboxCheckUnreadTotal(messageCount: Int(UInt32.max) + 1, unseenCount: 1) == nil)
    }
    @Test func countDeadlineCanBeShortenedWithoutChangingOrdinaryStatusCommands() {
        let ordinary = StatusCommand(Mailbox.Name("INBOX"), attributes: [.messageCount, .unseenCount])
        let count = StatusCommand(Mailbox.Name("INBOX"), attributes: [.messageCount, .unseenCount], timeout: 2)
        #expect(ordinary.timeout == 60)
        #expect(count.timeout == 2)
        #expect(count.attributes == ordinary.attributes)
    }
}
