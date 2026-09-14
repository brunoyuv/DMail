// MPL-2.0: https://mozilla.org/MPL/2.0/
import NIOIMAP

// Extracted from the account bridge so compatibility assumptions can be tested
// without connecting to an account. A UID mutation needs the selected identity,
// not a pagination cursor.
public func flagMutationValidity(_ status: Mailbox.Status) -> UInt32? {
    guard let validity = status.uidValidity.map({ UInt32($0) }), validity > 0 else { return nil }
    return validity
}

public func flagMutationTarget(in messages: [SequenceNumber: Message], uid: UID) -> Message? {
    // Unsolicited FETCH updates for other UIDs can accompany the command.
    // They do not invalidate an explicit, unique FLAGS response for our UID.
    let matching = messages.values.filter { $0.uid == uid }
    guard matching.count == 1, let message = matching.first, message.flagsWereReceived else { return nil }
    return message
}
