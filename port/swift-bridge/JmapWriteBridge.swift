// MPL-2.0: https://mozilla.org/MPL/2.0/
import JMAP

struct ArchiveUndoDTO: Codable, Sendable {
    let accountId: String, emailId: String, inboxId: String, archiveId: String
    let addedArchive: Bool
    let expectedMailboxIds: [String]
    init(_ value: JMAPClient.ArchiveUndo) {
        accountId = value.accountID; emailId = value.emailID; inboxId = value.inboxID; archiveId = value.archiveID
        addedArchive = value.addedArchive; expectedMailboxIds = value.expectedMailboxIDs
    }
    var nativeValue: JMAPClient.ArchiveUndo {
        JMAPClient.ArchiveUndo(accountID: accountId, emailID: emailId, inboxID: inboxId, archiveID: archiveId,
            addedArchive: addedArchive, expectedMailboxIDs: expectedMailboxIds)
    }
}

// Map only known codes, never server descriptions or raw response contents.
func messageChangeError(_ error: JMAPError) -> String {
    switch error {
    case .method(let error):
        switch error {
        case .accountNotFound: return "accountNotFound"
        case .accountReadOnly: return "accountReadOnly"
        case .stateMismatch: return "stateMismatch"
        case .tooManyObjects: return "tooManyObjects"
        case .forbidden: return "forbidden"
        case .invalidArguments: return "invalidArgument"
        default: return "methodFailed"
        }
    case .set(let error):
        switch error {
        case .forbidden: return "forbidden"
        case .notFound: return "messageNotFound"
        case .stateMismatch: return "stateMismatch"
        default: return "updateRejected"
        }
    default: return "network"
    }
}
