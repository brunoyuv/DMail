// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import FoundationNetworking
import Dispatch
import JMAP

private struct AccountRequest: Decodable, Sendable {
    let operation: String
    let sessionUrl: String
    let authorization: String
    let accountId: String?
    let mailboxId: String?
    let position: Int?
    let queryState: String?
    let emailIds: [String]?
    let includeBody: Bool?
    let emailId: String?
    let keyword: String?
    let enabled: Bool?
    let undo: ArchiveUndoDTO?
    let draft: JMAPClient.Draft?
}
struct Nullable<T: Encodable>: Encodable {
    let value: T?
    init(_ value: T?) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value { try container.encode(value) } else { try container.encodeNil() }
    }
}
private struct AccountDTO: Encodable {
    let id: String, name: String
    let isPersonal: Bool, isReadOnly: Bool
}
private struct SessionDTO: Encodable {
    let apiUrl: String, state: String
    let accounts: [AccountDTO]
    let primaryAccountId: Nullable<String>
    let maxObjectsInGet: Int
}
private struct MailboxDTO: Encodable {
    let id: String, name: String
    let parentId: Nullable<String>, role: Nullable<String>
    let sortOrder: Int, totalEmails: Int, unreadEmails: Int
    let maySetSeen: Bool, maySetKeywords: Bool, mayAddItems: Bool, mayRemoveItems: Bool
}
private struct AccountReply: Encodable {
    var session: SessionDTO?
    var maxRequestBytes: Int?
    var mailboxes: [MailboxDTO]?
    var page: MessagePageDTO?
    var messages: MessageSnapshotDTO?
    var state: String?
    var undo: ArchiveUndoDTO?
    var createdDraft: JMAPClient.CreatedDraft?
    var error: String?
    var mayHaveCreated: Bool?
}
func validId(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count <= 255 && id.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
    }
}
private func authorization(_ raw: String) throws -> Authorization {
    guard raw.range(of: "^(Bearer|Basic) [A-Za-z0-9._~+/-]+=*$", options: .regularExpression) != nil else {
        throw NativeJmapError.authenticationRequired
    }
    if raw.hasPrefix("Bearer ") { return .bearer(String(raw.dropFirst(7))) }
    guard let data = Data(base64Encoded: String(raw.dropFirst(6))), let text = String(data: data, encoding: .utf8),
          let colon = text.firstIndex(of: ":") else { throw NativeJmapError.authenticationRequired }
    return .basic(String(text[..<colon]), String(text[text.index(after: colon)...]))
}
private func performAccountRequest(_ input: AccountRequest) async throws -> AccountReply {
    guard ["connect", "mailboxes", "emailPage", "getEmails", "setKeyword", "archiveEmail", "undoArchive", "createDraft"].contains(input.operation) else { throw NativeJmapError.invalidResponse }
    if input.operation == "createDraft" {
        guard let draft = input.draft else { return AccountReply(error: "invalidDraft", mayHaveCreated: false) }
        try draft.validate()
    }
    let endpoint = try jmapEndpoint(input.sessionUrl)
    let transport = makeJmapTransport()
    defer { transport.invalidateAndCancel() }
    let client = try await JMAPClient.session(Server(authorization: try authorization(input.authorization),
        host: endpoint.host!, port: endpoint.port ?? 443), urlSession: transport, sessionURL: endpoint, accountID: input.accountId)
    guard let session = client.session, let core = session.capabilities[.core], session.capabilities[.mail] != nil,
          let maxObjects = core.maxObjectsInGet, maxObjects > 0 else { throw NativeJmapError.invalidResponse }
    let apiURL = try jmapEndpoint(session.apiURL.absoluteString)
    guard sameJmapOrigin(endpoint, apiURL) else { throw NativeJmapError.untrustedApiOrigin }
    let maxRequest = core.maxSizeRequest ?? 4 * 1024 * 1024
    guard maxRequest > 0 else { throw NativeJmapError.invalidResponse }
    let accounts = try session.accounts.filter { $0.value.capabilities[.mail] != nil }.map { id, account in
        guard validId(id) else { throw NativeJmapError.invalidResponse }
        return AccountDTO(id: id, name: account.name, isPersonal: account.isPersonal, isReadOnly: account.isReadOnly)
    }.sorted { $0.id < $1.id }
    guard !accounts.isEmpty else { throw NativeJmapError.mailNotSupported }
    let primary = session.primaryAccounts[.mail]
    if let primary, !accounts.contains(where: { $0.id == primary }) { throw NativeJmapError.invalidResponse }
    if input.operation == "connect" {
        return AccountReply(session: SessionDTO(apiUrl: apiURL.absoluteString, state: session.state,
            accounts: accounts, primaryAccountId: Nullable(primary), maxObjectsInGet: maxObjects), maxRequestBytes: min(maxRequest, 4 * 1024 * 1024))
    }
    guard let selected = input.accountId, accounts.contains(where: { $0.id == selected }) else { throw NativeJmapError.accountNotFound }
    if input.operation == "createDraft", let draft = input.draft {
        return AccountReply(createdDraft: try await client.createDraft(draft))
    }
    if input.operation == "setKeyword" {
        guard let id = input.emailId, validId(id), let raw = input.keyword,
              let keyword = Email.Keyword(rawValue: raw), let enabled = input.enabled else { throw NativeJmapError.invalidArgument }
        return AccountReply(state: try await client.setKeyword(keyword, enabled: enabled, for: id))
    }
    if input.operation == "archiveEmail" {
        guard let id = input.emailId, validId(id) else { throw NativeJmapError.invalidArgument }
        return AccountReply(undo: ArchiveUndoDTO(try await client.archiveEmail(id)))
    }
    if input.operation == "undoArchive" {
        guard let undo = input.undo, undo.accountId == selected else { throw NativeJmapError.invalidArgument }
        return AccountReply(state: try await client.undoArchive(undo.nativeValue))
    }
    if input.operation == "emailPage" {
        guard let mailboxID = input.mailboxId, let position = input.position else { throw NativeJmapError.invalidArgument }
        return AccountReply(page: try await messagePage(client, accountID: selected, mailboxID: mailboxID,
            position: position, previousState: input.queryState, limit: min(maxObjects, 50)))
    }
    if input.operation == "getEmails" {
        guard let ids = input.emailIds, let includeBody = input.includeBody, ids.count <= min(maxObjects, 50) else {
            throw NativeJmapError.invalidArgument
        }
        return AccountReply(messages: try await messageSnapshot(client, ids: ids, includeBody: includeBody))
    }
    let boxes = try await client.mailboxes()
    var ids = Set<String>()
    let mapped = try boxes.map { box in
        guard validId(box.id), ids.insert(box.id).inserted, box.sortOrder >= 0, box.totalEmails >= 0,
              box.unreadEmails >= 0 else { throw NativeJmapError.invalidResponse }
        return MailboxDTO(id: box.id, name: box.name, parentId: Nullable(box.parentID), role: Nullable(box.role?.rawValue),
            sortOrder: box.sortOrder, totalEmails: box.totalEmails, unreadEmails: box.unreadEmails,
            maySetSeen: box.rights.maySetSeen, maySetKeywords: box.rights.maySetKeywords,
            mayAddItems: box.rights.mayAddItems, mayRemoveItems: box.rights.mayRemoveItems)
    }
    return AccountReply(mailboxes: mapped)
}
private final class AccountResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value = AccountReply(error: "network")
    private var finished = false
    // The deadline seals the result so a later cancellation cannot overwrite it.
    func set(_ value: AccountReply) {
        lock.lock(); defer { lock.unlock() }
        if !finished { self.value = value; finished = true }
    }
    func get() -> AccountReply { lock.lock(); defer { lock.unlock() }; return value }
}

// Called on a Node-API worker, never on the ArkUI thread. Credentials live only
// for this request; persistent secrets continue to belong to Harmony's store.
@_cdecl("thunderbird_jmap_account_request")
public func jmapAccountRequest(_ raw: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let raw, let string = String(validatingCString: raw), string.utf8.count <= 4 * 1024 * 1024 else { return nil }
    let data = Data(string.utf8)
    guard let input = try? JSONDecoder().decode(AccountRequest.self, from: data) else {
        struct Operation: Decodable { let operation: String }
        let draft = (try? JSONDecoder().decode(Operation.self, from: data))?.operation == "createDraft"
        return encodeAccountReply(AccountReply(error: draft ? "invalidDraft" : "invalidResponse", mayHaveCreated: draft ? false : nil))
    }
    let result = AccountResult(), done = DispatchSemaphore(value: 0)
    let task = Task {
        defer { done.signal() }
        do { result.set(try await performAccountRequest(input)) }
        catch let error as NativeJmapError { result.set(AccountReply(error: error.rawValue)) }
        catch let error as JMAPClient.DraftFailure {
            result.set(AccountReply(error: error.code.rawValue, mayHaveCreated: error.mayHaveCreated))
        }
        catch let error as JMAPClient.MessageChangeError { result.set(AccountReply(error: error.rawValue)) }
        catch let error as JMAPError { result.set(AccountReply(error: messageChangeError(error))) }
        catch is DecodingError { result.set(AccountReply(error: "invalidResponse")) }
        catch let error as CocoaError where error.code == .propertyListReadCorrupt {
            result.set(AccountReply(error: "invalidResponse"))
        }
        catch let error as URLError {
            let code = error.code == .userAuthenticationRequired ? "authenticationRequired" :
                error.code == .cannotDecodeContentData ? "invalidResponse" :
                error.code == .dataLengthExceedsMaximum ? "requestTooLarge" : "network"
            result.set(AccountReply(error: code))
        }
        catch { result.set(AccountReply(error: "network")) }
    }
    if done.wait(timeout: .now() + 35) == .timedOut {
        result.set(input.operation == "createDraft" ? AccountReply(error: "draftOutcomeUnknown", mayHaveCreated: true) : AccountReply(error: "network"))
        task.cancel()
    }
    return encodeAccountReply(result.get())
}
private func encodeAccountReply(_ reply: AccountReply) -> UnsafeMutablePointer<CChar>? {
    guard let data = try? JSONEncoder().encode(reply) else { return nil }
    let output = UnsafeMutablePointer<CChar>.allocate(capacity: data.count + 1)
    for (i, byte) in data.enumerated() { output[i] = CChar(bitPattern: byte) }
    output[data.count] = 0
    return output
}
