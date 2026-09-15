import Foundation
import IMAP

enum ImapFailure: String, Error { case archiveUnavailable, forbidden, accountReadOnly, messageNotFound, changeUnconfirmed, invalidArgument, unsafeEndpoint, authenticationRequired, certificate, network, watchRestart, queryChanged, invalidResponse, unsupported, messageTooLarge }
struct ImapRequest: Decodable, Sendable {
    let operation: String, sessionUrl: String, authorization: String
    var username: String? = nil
    let accountId: String?
    let mailboxId: String?
    let position: Int?
    let queryState: String?
    let emailId: String?
    let keyword: String?
    let enabled: Bool?
    let attachmentId: String?
    var watchId: String? = nil
    var syncSessionId: String? = nil
    var previewKnownIds: [String]? = nil
}
struct ImapNullable<T: Encodable & Sendable>: Encodable, Sendable {
    let value: T?
    init(_ value: T?) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value { try container.encode(value) } else { try container.encodeNil() }
    }
}
struct ImapAccount: Encodable, Sendable { let id: String, name: String; let isPersonal = true, isReadOnly = false }
struct ImapSession: Encodable, Sendable {
    let apiUrl: String, state = "imap", accounts: [ImapAccount]
    let primaryAccountId = "default", maxObjectsInGet = 50
}
struct ImapMailbox: Encodable, Sendable {
    let id: String, name: String
    let parentId = ImapNullable<String>(nil)
    let role: ImapNullable<String>
    let sortOrder: Int, totalEmails: Int, unreadEmails: Int
    let countsKnown: Bool
    let maySetSeen = false, maySetKeywords = false
    var mayAddItems = false, mayRemoveItems = false
    var archiveDestinationId: String? = nil
    var archiveDestinationName: String? = nil
}
struct ImapAddress: Encodable, Sendable { let name: String, email: String }
struct ImapAttachment: Encodable, Sendable { let id: String, name: String, contentType: String; let size: Int; let sizeIsEncoded: Bool }
struct ImapAttachmentData: Encodable, Sendable { let name: String, contentType: String, base64: String }
struct ImapEmail: Encodable, Sendable {
    let inReplyTo: [String], references: [String]
    let id: String, threadId: String, messageIds: [String], mailboxIds: [String], keywords: [String]
    let from: [ImapAddress], to: [ImapAddress], cc: [ImapAddress], replyTo: [ImapAddress]
    let subject: String, preview: String, receivedAt: Double, hasAttachment: Bool
    let maySetSeen: Bool, maySetKeywords: Bool
    let htmlBody: ImapNullable<String>
    let textBody: ImapNullable<String>, bodyTruncated: Bool, bodyEncodingProblem: Bool, hasHtmlBody: Bool
    var attachments: [ImapAttachment] = []
}
struct ImapPage: Encodable, Sendable {
    let accountId = "default", queryState: String
    let emailState = ImapNullable<String>(nil)
    let position: Int, nextPosition: ImapNullable<Int>, total: Int
    let emails: [ImapEmail], notFound: [String] = []
}
struct ImapInboxCheck: Encodable, Sendable {
    let state: String, mailboxId: String
    let newMessages: Int
    var unreadEmails: Int? = nil
}
struct ImapArchiveUndo: Encodable, Sendable {
    let accountId = "default"
    let emailId: String, inboxId: String, archiveId: String
    let addedArchive = true
    let expectedMailboxIds: [String]
    let movedEmailId: String?
    let canUndo: Bool
    let archiveMailbox: ImapMailbox
    var action: String? = nil
    let imap = true
}
struct ImapReply: Encodable, Sendable {
    var session: ImapSession?
    var mailboxes: [ImapMailbox]?
    var page: ImapPage?
    var email: ImapNullable<ImapEmail>?
    var error: String?
    var state: String?
    var attachment: ImapAttachmentData?
    var inboxCheck: ImapInboxCheck?
    var inboxWatch: IMAP.InboxWatchResult?
    var archive: ImapArchiveUndo?
    var movedEmailId: String?
}

// An IMAP UID has meaning only inside one mailbox and UIDVALIDITY epoch.
// Base64url keeps the identity opaque to UI/cache code without discarding it.
struct ImapIdentity: Codable {
    let mailbox: String, validity: UInt32, uid: UInt32
}
func imapEncode<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value).base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
func imapDecode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
    guard !value.isEmpty, value.utf8.count <= 4096,
          value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw ImapFailure.invalidArgument }
    let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    guard let data = Data(base64Encoded: base + String(repeating: "=", count: (4-base.count%4)%4)),
          let decoded = try? JSONDecoder().decode(type, from: data) else { throw ImapFailure.invalidArgument }
    return decoded
}
func imapMailboxName(_ id: String) throws -> String {
    let name = try imapDecode(String.self, id)
    guard !name.isEmpty, name.utf8.count <= 1024, !name.contains("\0"), !name.contains("\r"), !name.contains("\n") else { throw ImapFailure.invalidArgument }
    return name
}
