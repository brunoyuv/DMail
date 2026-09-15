// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import EmailAddress
import JMAP

struct MessageAddressDTO: Encodable { let name: String; let email: String }
struct MessageDTO: Encodable {
    let id: String, threadId: String
    let inReplyTo: [String], references: [String]
    let messageIds: [String], mailboxIds: [String], keywords: [String]
    let from: [MessageAddressDTO], to: [MessageAddressDTO], cc: [MessageAddressDTO], replyTo: [MessageAddressDTO]
    let subject: String, preview: String
    let receivedAt: Double
    let hasAttachment: Bool
    let htmlBody: Nullable<String>
    let textBody: Nullable<String>
    let bodyTruncated: Bool, bodyEncodingProblem: Bool, hasHtmlBody: Bool
}
struct MessageSnapshotDTO: Encodable {
    let emails: [MessageDTO], notFound: [String], state: String
}
struct MessagePageDTO: Encodable {
    let accountId: String, queryState: String
    let emailState: Nullable<String>
    let position: Int
    let nextPosition: Nullable<Int>, total: Nullable<Int>
    let emails: [MessageDTO], notFound: [String]
}

private let maxSafeInteger = 9_007_199_254_740_991
private func addresses(_ source: [any EmailAddressProtocol]?) -> [MessageAddressDTO] {
    (source ?? []).flatMap { $0.addresses }.map { MessageAddressDTO(name: $0.label ?? "", email: $0.value) }
}
private func mapMessage(_ email: Email, includeBody: Bool) throws -> MessageDTO {
    guard validId(email.id), validId(email.threadID), validId(email.blobID),
          email.mailboxIDs.allSatisfy({ validId($0.key) && $0.value }), email.keywords.values.allSatisfy({ $0 }),
          let receivedAt = email.receivedAt, receivedAt.timeIntervalSince1970.isFinite,
          let subject = email.subject, let preview = email.preview else { throw NativeJmapError.invalidResponse }
    var text: [String] = [], html: [String] = [], truncated = false, encodingProblem = false
    if includeBody {
        var parts = Set<String>()
        for part in email.textBody where part.type.lowercased() == "text/plain" {
            guard let id = part.partID, !id.isEmpty, parts.insert(id).inserted,
                  let value = email.bodyValues?[id] else { throw NativeJmapError.invalidResponse }
            guard value.value.utf8.count <= 256 * 1024 else { throw NativeJmapError.responseTooLarge }
            text.append(value.value)
            truncated = truncated || value.isTruncated
            encodingProblem = encodingProblem || value.isEncodingProblem
        }
        for part in email.htmlBody where part.type.lowercased() == "text/html" {
            guard let id = part.partID, !id.isEmpty, parts.insert(id).inserted,
                  let value = email.bodyValues?[id] else { throw NativeJmapError.invalidResponse }
            guard value.value.utf8.count <= 256 * 1024 else { throw NativeJmapError.responseTooLarge }
            html.append(value.value)
            truncated = truncated || value.isTruncated
            encodingProblem = encodingProblem || value.isEncodingProblem
        }
    }
    return MessageDTO(id: email.id, threadId: email.threadID, inReplyTo: email.inReplyTo ?? [], references: email.references ?? [], messageIds: email.messageID ?? [],
        mailboxIds: email.mailboxIDs.keys.sorted(), keywords: email.keywords.keys.sorted(),
        from: addresses(email.from), to: addresses(email.to), cc: addresses(email.cc), replyTo: addresses(email.replyTo),
        subject: subject, preview: preview, receivedAt: (receivedAt.timeIntervalSince1970 * 1000).rounded(),
        hasAttachment: email.hasAttachment, htmlBody: Nullable(html.isEmpty ? nil : html.joined(separator: "<hr>")), textBody: Nullable(text.isEmpty ? nil : text.joined(separator: "\n\n")),
        bodyTruncated: truncated, bodyEncodingProblem: encodingProblem,
        hasHtmlBody: includeBody && !email.htmlBody.isEmpty)
}

func messageSnapshot(_ client: JMAPClient, ids: [String], includeBody: Bool) async throws -> MessageSnapshotDTO {
    guard !ids.isEmpty, ids.allSatisfy(validId), Set(ids).count == ids.count else { throw NativeJmapError.invalidArgument }
    let response = try await client.getEmails(ids, includeTextBody: includeBody)
    let emails = try response.decode([Email].self).map { try mapMessage($0, includeBody: includeBody) }
    let returned = emails.map(\.id) + response.notFound
    guard returned.allSatisfy(validId), Set(returned).count == returned.count,
          Set(returned) == Set(ids) else { throw NativeJmapError.invalidResponse }
    let byID = Dictionary(uniqueKeysWithValues: emails.map { ($0.id, $0) })
    return MessageSnapshotDTO(emails: ids.compactMap { byID[$0] }, notFound: response.notFound, state: response.state)
}

func messagePage(_ client: JMAPClient, accountID: String, mailboxID: String, position: Int,
                 previousState: String?, limit: Int) async throws -> MessagePageDTO {
    guard validId(mailboxID), position >= 0, position <= maxSafeInteger - limit else { throw NativeJmapError.invalidArgument }
    let query = try await client.queryEmails(in: mailboxID, position: position, limit: limit)
    guard query.position == position, previousState == nil || previousState == query.queryState else {
        throw NativeJmapError.queryChanged
    }
    guard query.ids.count <= limit, query.ids.allSatisfy(validId), Set(query.ids).count == query.ids.count else {
        throw NativeJmapError.invalidResponse
    }
    if let total = query.total {
        guard total <= maxSafeInteger, total >= 0,
              query.ids.isEmpty ? position >= total : total >= position + query.ids.count else {
            throw NativeJmapError.invalidResponse
        }
    }
    // Advance over all queried IDs, including messages deleted before the GET.
    let next = query.ids.isEmpty || query.total == position + query.ids.count ? nil : position + query.ids.count
    let snapshot = query.ids.isEmpty ? nil : try await messageSnapshot(client, ids: query.ids, includeBody: false)
    return MessagePageDTO(accountId: accountID, queryState: query.queryState, emailState: Nullable(snapshot?.state),
        position: position, nextPosition: Nullable(next), total: Nullable(query.total),
        emails: snapshot?.emails ?? [], notFound: snapshot?.notFound ?? [])
}
