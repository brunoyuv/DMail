// MPL-2.0: https://mozilla.org/MPL/2.0/
import Testing
import NIOIMAP
@testable import IMAP

struct FlagMutationTests {
    private func message(_ uid: UInt32, flags: [Flag]?) -> Message {
        var components: [Message.Component] = [.uid(UID(rawValue: uid))]
        if let flags { components.append(.flags(Set(flags))) }
        return Message(components)
    }

    @Test func mutationIdentityDoesNotDependOnUIDNEXTOrMailboxCount() {
        var status = Mailbox.Status()
        status.uidValidity = 77
        #expect(flagMutationValidity(status) == 77)
        status.messageCount = 51
        #expect(flagMutationValidity(status) == 77)
        status.nextUID = UID(rawValue: 93)
        #expect(flagMutationValidity(status) == 77)
        // Another arrival can change paging metadata without changing this UID.
        status.messageCount = 52; status.nextUID = UID(rawValue: 94)
        #expect(flagMutationValidity(status) == 77)
    }

    @Test func targetFlagsIgnoreUnrelatedUnsolicitedFetches() {
        let uid = UID(rawValue: 42)
        let expected = message(42, flags: [.seen])
        let responses: [SequenceNumber: Message] = [1: expected, 2: message(43, flags: [.flagged])]
        #expect(flagMutationTarget(in: responses, uid: uid)?.flags.contains(.seen) == true)
        let unread: [SequenceNumber: Message] = [1: message(42, flags: []), 2: message(43, flags: [.seen])]
        #expect(flagMutationTarget(in: unread, uid: uid)?.flags.contains(.seen) == false)
    }

    @Test func targetMustBeUniqueAndContainAnExplicitFlagsResponse() {
        let uid = UID(rawValue: 42)
        #expect(flagMutationTarget(in: [:], uid: uid) == nil)
        #expect(flagMutationTarget(in: [1: message(43, flags: [.seen])], uid: uid) == nil)
        #expect(flagMutationTarget(in: [1: message(42, flags: nil)], uid: uid) == nil)
        #expect(flagMutationTarget(in: [1: message(42, flags: []), 2: message(42, flags: [.seen])], uid: uid) == nil)
    }

    @Test func missingOrChangedUIDVALIDITYIsNeverAcceptedAsTheOriginalIdentity() {
        var status = Mailbox.Status()
        #expect(flagMutationValidity(status) == nil)
        status.uidValidity = 78
        #expect(flagMutationValidity(status) != 77)
    }
}
