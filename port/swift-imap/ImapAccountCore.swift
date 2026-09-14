import Foundation
import Dispatch
import IMAP
import MIME
import EmailAddress
import NIO
import NIOSSL
import HarmonyLogging

private struct Epoch: Codable, Equatable {
    let validity: UInt32, next: UInt32, count: Int
    init(_ status: IMAP.Mailbox.Status) throws {
        let logger = Logger(subsystem: "net.thunderbird", category: "IMAPAccount")
        guard let validity = status.uidValidity.map({ UInt32($0) }), validity > 0 else {
            logger.error("Mailbox selection has no valid UIDVALIDITY")
            throw ImapFailure.invalidResponse
        }
        guard let next = status.nextUID?.rawValue, next > 0 else {
            logger.error("Mailbox selection has no valid UIDNEXT")
            throw ImapFailure.invalidResponse
        }
        guard let count = status.messageCount, count >= 0, count < Int(UInt32.max) else {
            logger.error("Mailbox selection has no valid EXISTS count")
            throw ImapFailure.invalidResponse
        }
        self.validity = validity; self.next = next; self.count = count
    }
}
// Older servers can omit UIDNEXT from SELECT/EXAMINE (RFC 3501 §6.3.1).
// Fetch it explicitly, retaining the selected mailbox's identity and count.
// Never guess a next UID or merge status from a changed mailbox epoch.
private func selectedEpoch(_ status: IMAP.Mailbox.Status, client: IMAPClient,
                           mailbox: IMAP.Mailbox.Name) async throws -> Epoch {
    if status.nextUID != nil { return try Epoch(status) }
    guard let validity = status.uidValidity, UInt32(validity) > 0,
          let count = status.messageCount, count >= 0 else { throw ImapFailure.invalidResponse }
    let refreshed = try await client.status(mailbox: mailbox, attributes: [.messageCount, .uidValidity, .uidNext])
    let epoch = try Epoch(refreshed)
    guard epoch.validity == UInt32(validity), epoch.count == count else { throw ImapFailure.queryChanged }
    return epoch
}

struct ImapConnection: Sendable {
    let host: String, port: Int, username: String, password: String
    let accessToken: String?
    init(_ input: ImapRequest) throws {
        guard input.sessionUrl.utf8.count <= 1024,
              !input.sessionUrl.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 || $0.value == 92 }),
              let url = URLComponents(string: input.sessionUrl), url.scheme == "imaps",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", let host = url.host, !host.isEmpty, host.utf8.count <= 253,
              (1...65535).contains(url.port ?? 993) else { throw ImapFailure.unsafeEndpoint }
        self.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")); port = url.port ?? 993
        if input.authorization.hasPrefix("Bearer ") {
            let token = String(input.authorization.dropFirst(7))
            guard let login = input.username, !login.isEmpty, login.utf8.count <= 512,
                  !login.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  !token.isEmpty, token.utf8.count <= 32768, token.utf8.allSatisfy({ $0 > 32 && $0 < 127 })
            else { throw ImapFailure.authenticationRequired }
            username = login; password = ""; accessToken = token
            return
        }
        accessToken = nil
        guard input.authorization.hasPrefix("Basic "), input.authorization.utf8.count <= 4096,
              let bytes = Data(base64Encoded: String(input.authorization.dropFirst(6))),
              let credentials = String(data: bytes, encoding: .utf8), let separator = credentials.firstIndex(of: ":") else { throw ImapFailure.authenticationRequired }
        username = String(credentials[..<separator]); password = String(credentials[credentials.index(after: separator)...])
        guard !username.isEmpty, !password.isEmpty, username.utf8.count <= 512, password.utf8.count <= 1024,
              !credentials.contains("\0"), !credentials.contains("\r"), !credentials.contains("\n") else { throw ImapFailure.authenticationRequired }
    }
}
private func email(_ message: IMAP.Message, mailbox: String, epoch: Epoch, includeBody: Bool, selection: MailboxSelection? = nil, readable: ReadableMessage? = nil) throws -> ImapEmail {
    guard let uid = message.uid?.rawValue, uid > 0 else { throw ImapFailure.invalidResponse }
    let id = try imapEncode(ImapIdentity(mailbox: mailbox, validity: epoch.validity, uid: uid))
    func addresses(_ values: [any EmailAddressProtocol]) -> [ImapAddress] {
        values.flatMap { $0.addresses }.map { ImapAddress(name: $0.label ?? "", email: $0.value) }
    }
    var body: EmailBody?, failed = false
    if includeBody {
        do { body = try EmailBody(body: readable?.body ?? message.body) }
        catch { failed = true }
    }
    let html = body?.html(.inlineAttachments)
    let text = body?.text
    let capped = text.map { String($0.prefix(200_000)) }
    var keywords = [String]()
    if message.flags.contains(.seen) { keywords.append("$seen") }
    if message.flags.contains(.flagged) { keywords.append("$flagged") }
    var result = ImapEmail(inReplyTo: message.envelope.inReplyTo.map { [$0] } ?? [], references: message.references, id: id, threadId: id, messageIds: message.envelope.messageID.map { [$0] } ?? [],
        mailboxIds: [try imapEncode(mailbox)], keywords: keywords,
        from: addresses(message.envelope.from), to: addresses(message.envelope.to), cc: addresses(message.envelope.cc), replyTo: addresses(message.envelope.reply),
        subject: message.envelope.subject ?? "", preview: String((text ?? "").prefix(180)),
        receivedAt: (((message.internalDate ?? message.envelope.date?.date)?.timeIntervalSince1970 ?? 0) * 1000).rounded(),
        hasAttachment: (readable?.hasAttachments ?? false) || !(body?.attachments.isEmpty ?? true), maySetSeen: selection?.mayStore(.seen) ?? false, maySetKeywords: selection?.mayStore(.flagged) ?? false,
        htmlBody: ImapNullable(html.map { String($0.prefix(2_000_000)) }), textBody: ImapNullable(capped),
        bodyTruncated: (readable?.partial ?? false) || (text?.count ?? 0) > 200_000 || (html?.count ?? 0) > 2_000_000, bodyEncodingProblem: failed || (body?.decodingHadErrors ?? false),
        hasHtmlBody: html != nil)
    if includeBody, let readable {
        if readable.message.bodyStructure != nil {
            result.attachments = readable.attachments.map { ImapAttachment(id: $0.id,
                name: $0.name.isEmpty ? "attachment." + $0.contentType.components(separatedBy: "/").last! : $0.name,
                contentType: $0.contentType, size: max(0, $0.encodedSize), sizeIsEncoded: true) }
        } else if let body {
            result.attachments = body.attachments.enumerated().compactMap { index, item in
                if case .inline = item.contentDisposition, case .image = item.contentType { return nil }
                return ImapAttachment(id: "legacy:\(index)", name: item.contentDisposition.file?.filename ?? "attachment.\(item.contentType.subtype)",
                    contentType: item.contentType.description.components(separatedBy: ";")[0], size: item.data.count, sizeIsEncoded: false)
            }
        }
    }
    return result
}

private func perform(_ input: ImapRequest) async throws -> ImapReply {
    guard ["connect", "mailboxes", "emailPage", "readEmail", "readAttachment", "setKeyword", "checkInbox", "watchInbox", "stopInboxWatch"].contains(input.operation) else { throw ImapFailure.unsupported }
    if input.operation == "stopInboxWatch" {
        guard let id = input.watchId, UUID(uuidString: id) != nil else { throw ImapFailure.invalidArgument }
        try IMAP.InboxWatchRegistry.shared.stop(id: id)
        return ImapReply(state: "stopped")
    }
    guard input.operation == "connect" || input.accountId == "default" else { throw ImapFailure.invalidArgument }
    var inboxPrevious: IMAP.InboxCheckCursor?
    if input.operation == "checkInbox", let state = input.queryState {
        let cursor = try imapDecode(IMAP.InboxCheckCursor.self, state)
        guard cursor.isValid else { throw ImapFailure.invalidArgument }
        inboxPrevious = cursor
    }
    if input.operation == "setKeyword" {
        guard let keyword = input.keyword, ["$seen", "$flagged"].contains(keyword), input.enabled != nil else {
            throw ImapFailure.invalidArgument
        }
    }
    let connection = try ImapConnection(input)
    if input.operation == "watchInbox" {
        guard let id = input.watchId, UUID(uuidString: id) != nil else { throw ImapFailure.invalidArgument }
        do {
            let result = try IMAP.InboxWatchRegistry.shared.snapshot(id: id,
                owner: [input.sessionUrl, input.accountId ?? "", connection.username, input.authorization],
                accessToken: connection.accessToken) {
                let trust: ImapTrust
                do { trust = try ImapTrust(host: connection.host) } catch { throw IMAP.InboxWatchError.certificate }
                return IMAPClient(Server(hostname: connection.host, username: connection.username,
                    password: connection.password, port: connection.port), logger: nil,
                    tlsConfiguration: trust.configuration, commandTimeout: 5, additionalPeerVerification: trust.verifyPeer)
            }
            return ImapReply(inboxWatch: result)
        } catch let error as IMAP.InboxWatchError {
            switch error {
            case .invalidArgument: throw ImapFailure.invalidArgument
            case .authenticationRequired: throw ImapFailure.authenticationRequired
            case .certificate: throw ImapFailure.certificate
            case .network: throw ImapFailure.network
            case .watchRestart: throw ImapFailure.watchRestart
            }
        }
    }
    // Trust roots and pins come from the calling app's HarmonyOS policy, never JSON input.
    let trust = try ImapTrust(host: connection.host)
    let client = IMAPClient(Server(hostname: connection.host, username: connection.username,
        password: connection.password, port: connection.port), tlsConfiguration: trust.configuration,
        commandTimeout: 10, additionalPeerVerification: trust.verifyPeer)
    do {
        try await client.connect()
        do {
            if let token = connection.accessToken {
                try await client.authenticateXOAUTH2(username: connection.username, accessToken: token)
            } else { try await client.login() }
        } catch { throw ImapFailure.authenticationRequired }
        let reply: ImapReply
        var optionalInboxCountFailed = false
        switch input.operation {
        case "connect":
            reply = ImapReply(session: ImapSession(apiUrl: input.sessionUrl,
                accounts: [ImapAccount(id: "default", name: connection.username)]))
        case "checkInbox":
            let mailbox = IMAP.Mailbox.Name("INBOX")
            let epoch = try await selectedEpoch(client.examine(mailbox: mailbox), client: client, mailbox: mailbox)
            let current = IMAP.InboxCheckCursor(validity: epoch.validity, next: epoch.next)
            var newMessages = 0
            if let range = IMAP.inboxCheckRange(previous: inboxPrevious, current: current, count: epoch.count),
               let previous = inboxPrevious {
                try Task.checkCancellation()
                let messages = try await client.fetch(SequenceSet(range: .init(range)), attributes: [.uid, .flags])
                newMessages = IMAP.inboxCheckNewMessages(messages, range: range, previous: previous, current: current)
                let again = try await client.examine(mailbox: mailbox)
                guard IMAP.flagMutationValidity(again) == epoch.validity else { throw ImapFailure.queryChanged }
            }
            // Keep the first selection's watermark. Mail arriving during FETCH
            // is outside this check and remains eligible for the next check.
            // Counts are optional metadata on this same authenticated session.
            // A server rejecting STATUS must not suppress detected arrivals.
            var unreadEmails: Int?
            do {
                try Task.checkCancellation()
                // The optional count must not consume the whole native request
                // budget after arrivals have already been detected. The shared
                // client closes a timed-out command's channel before returning.
                let status = try await client.status(mailbox: mailbox, attributes: [.messageCount, .unseenCount], timeout: 2)
                unreadEmails = IMAP.inboxCheckUnreadTotal(messageCount: status.messageCount, unseenCount: status.unseenCount)
            } catch {
                try Task.checkCancellation()
                optionalInboxCountFailed = true
            }
            reply = ImapReply(inboxCheck: ImapInboxCheck(state: try imapEncode(current),
                mailboxId: try imapEncode("INBOX"), newMessages: newMessages, unreadEmails: unreadEmails))
        case "mailboxes":
            let listed = try await client.list()
            guard listed.count <= 500 else { throw ImapFailure.messageTooLarge }
            let sentMailbox = IMAP.sentMailbox(in: listed.map { $0.0 })
            var boxes = [ImapMailbox](), ids = Set<String>()
            // Counts decorate the folder list; they must not gate inbox access.
            // Some servers reject extended STATUS attributes or individual
            // folders. Stop optional queries on the first failure or budget
            // exhaustion, and preserve LIST results with unknown counts.
            let countsDeadline = Date().addingTimeInterval(5)
            var canQueryCounts = true
            for (box, suppliedStatus) in listed where !box.attributes.contains(.noSelect) {
                try Task.checkCancellation()
                let name = box.path.name.description
                let id = try imapEncode(name)
                guard !name.isEmpty, name.utf8.count <= 1024, ids.insert(id).inserted else { throw ImapFailure.invalidResponse }
                var status = suppliedStatus
                if (status?.messageCount == nil || status?.unseenCount == nil),
                   canQueryCounts, Date() < countsDeadline {
                    do {
                        status = try await client.status(mailbox: box.path.name, attributes: [.messageCount, .unseenCount])
                    } catch {
                        try Task.checkCancellation()
                        canQueryCounts = false
                    }
                }
                let total = status?.messageCount, unread = status?.unseenCount
                let known = total != nil && unread != nil && total! >= 0 && unread! >= 0 && unread! <= total!
                let inbox = name.uppercased() == "INBOX"
                let sent = box.path.name == sentMailbox
                boxes.append(ImapMailbox(id: id, name: name, role: ImapNullable(inbox ? "inbox" : sent ? "sent" : nil),
                    sortOrder: inbox ? 0 : 1, totalEmails: known ? total! : 0,
                    unreadEmails: known ? unread! : 0, countsKnown: known))
            }
            reply = ImapReply(mailboxes: boxes)
        case "emailPage":
            guard let mailboxId = input.mailboxId, let position = input.position, position >= 0,
                  position == 0 || input.queryState != nil else { throw ImapFailure.invalidArgument }
            let mailbox = try imapMailboxName(mailboxId)
            let epoch = try await selectedEpoch(client.examine(mailbox: IMAP.Mailbox.Name(mailbox)), client: client, mailbox: IMAP.Mailbox.Name(mailbox))
            let state = try imapEncode(epoch)
            if let previous = input.queryState, previous != state { throw ImapFailure.queryChanged }
            guard position <= epoch.count else { throw ImapFailure.queryChanged }
            let end = epoch.count-position, start = max(1,end-49)
            var emails = [ImapEmail]()
            if end > 0 {
                let range = SequenceNumber(rawValue: UInt32(start))...SequenceNumber(rawValue: UInt32(end))
                let messages = try await client.fetch(SequenceSet(range: .init(range)), attributes: .standard)
                guard messages.count == end-start+1,
                      Set(messages.keys.map { Int($0.rawValue) }) == Set(start...end) else { throw ImapFailure.queryChanged }
                let again = try await selectedEpoch(client.examine(mailbox: IMAP.Mailbox.Name(mailbox)), client: client, mailbox: IMAP.Mailbox.Name(mailbox))
                guard again == epoch else { throw ImapFailure.queryChanged }
                var uids = Set<UInt32>()
                emails = try messages.keys.sorted().reversed().map { sequence in
                    let message = messages[sequence]!
                    guard let uid = message.uid?.rawValue, uids.insert(uid).inserted else { throw ImapFailure.invalidResponse }
                    return try email(message, mailbox: mailbox, epoch: epoch, includeBody: false)
                }
            }
            reply = ImapReply(page: ImapPage(queryState: state, position: position,
                nextPosition: ImapNullable(start > 1 ? position+emails.count : nil), total: epoch.count, emails: emails))
        case "readEmail", "readAttachment", "setKeyword":
            guard let id = input.emailId else { throw ImapFailure.invalidArgument }
            let identity = try imapDecode(ImapIdentity.self,id)
            guard identity.uid > 0, identity.validity > 0,
                  try imapMailboxName(imapEncode(identity.mailbox)) == identity.mailbox else { throw ImapFailure.invalidArgument }
            let mailbox = IMAP.Mailbox.Name(identity.mailbox)
            let selection = try await client.selectWithPermissions(mailbox: mailbox)
            let uid = UID(rawValue: identity.uid)
            let identifiers = UIDSet(range: .init(uid...uid))
            if input.operation == "setKeyword" {
                guard let validity = IMAP.flagMutationValidity(selection.status) else { throw ImapFailure.invalidResponse }
                guard identity.validity == validity else { throw ImapFailure.queryChanged }
                let flag: Flag = input.keyword == "$seen" ? .seen : .flagged
                guard !selection.isReadOnly else { throw ImapFailure.accountReadOnly }
                guard selection.mayStore(flag) else { throw ImapFailure.forbidden }
                let before = try await client.fetch(uid: identifiers, attributes: [.uid, .flags])
                guard !before.isEmpty else { throw ImapFailure.messageNotFound }
                guard IMAP.flagMutationTarget(in: before, uid: uid) != nil else { throw ImapFailure.invalidResponse }
                // Once STORE is attempted, any failure may follow a server-side
                // change. Never retry or claim success without a tagged reply
                // and a matching fetched flag on the selected UID.
                do {
                    try await client.setFlag(uid: uid, flag: flag, enabled: input.enabled!)
                    let after = try await client.fetch(uid: identifiers, attributes: [.uid, .flags])
                    guard let message = IMAP.flagMutationTarget(in: after, uid: uid),
                          message.flags.contains(flag) == input.enabled! else { throw ImapFailure.changeUnconfirmed }
                    let again = try await client.examine(mailbox: mailbox)
                    guard IMAP.flagMutationValidity(again) == validity else { throw ImapFailure.changeUnconfirmed }
                } catch { throw ImapFailure.changeUnconfirmed }
                // This is an opaque mutation acknowledgement, not a paging cursor.
                reply = ImapReply(state: try imapEncode(identity))
                break
            }
            let epoch = try await selectedEpoch(selection.status, client: client, mailbox: mailbox)
            guard identity.validity == epoch.validity else { throw ImapFailure.queryChanged }
            if input.operation == "readAttachment" {
                guard let attachmentId = input.attachmentId, attachmentId.utf8.count <= 256 else { throw ImapFailure.invalidArgument }
                let attachment: EmailAttachment
                if attachmentId.hasPrefix("legacy:") {
                    guard let index = Int(attachmentId.dropFirst(7)), index >= 0,
                          let readable = try await client.fetchReadable(uid: uid), readable.message.bodyStructure == nil,
                          let body = try? EmailBody(body: readable.body), index < body.attachments.count else { throw ImapFailure.messageNotFound }
                    attachment = body.attachments[index]
                } else {
                    let part = try await client.fetchAttachment(uid: uid, id: attachmentId)
                    attachment = EmailAttachment(data: try part.data.decoded(from: part.contentTransferEncoding),
                        contentType: part.contentType, contentDisposition: part.contentDisposition, contentID: part.contentID)
                }
                guard attachment.data.count <= 4 * 1024 * 1024 else { throw ImapFailure.messageTooLarge }
                let again = try await selectedEpoch(client.examine(mailbox: mailbox), client: client, mailbox: mailbox)
                guard again.validity == epoch.validity else { throw ImapFailure.queryChanged }
                reply = ImapReply(attachment: ImapAttachmentData(name: attachment.contentDisposition.file?.filename ?? "attachment.\(attachment.contentType.subtype)",
                    contentType: attachment.contentType.description.components(separatedBy: ";")[0], base64: attachment.data.base64EncodedString()))
                break
            }
            let readable = try await client.fetchReadable(uid: uid)
            let again = try await selectedEpoch(client.examine(mailbox: mailbox), client: client, mailbox: mailbox)
            guard again.validity == epoch.validity else { throw ImapFailure.queryChanged }
            if let readable {
                let message = readable.message
                guard message.uid?.rawValue == identity.uid else { throw ImapFailure.invalidResponse }
                reply = ImapReply(email: ImapNullable(try email(message,mailbox:identity.mailbox,epoch:epoch,includeBody:true,selection:selection,readable:readable)))
            } else { reply = ImapReply(email: ImapNullable(nil)) }
        default: throw ImapFailure.unsupported
        }
        try? await client.logout()
        // Failure of optional count metadata may already have closed the
        // connection. Its cleanup cannot discard a completed arrival check.
        if optionalInboxCountFailed { try? await client.shutdown() }
        else { try await client.shutdown() }
        return reply
    } catch {
        try? await client.shutdown()
        throw error
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reply = ImapReply(error: ImapFailure.network.rawValue)
    private var sealed = false
    func set(_ value: ImapReply) { lock.lock(); defer { lock.unlock() }; if !sealed { reply=value;sealed=true } }
    func get() -> ImapReply { lock.lock();defer { lock.unlock() };return reply }
}
private func encoded(_ reply: ImapReply) -> UnsafeMutablePointer<CChar>? {
    guard let bytes = try? JSONEncoder().encode(reply) else { return nil }
    let output = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count+1)
    for (index,byte) in bytes.enumerated() { output[index] = CChar(bitPattern:byte) }
    output[bytes.count]=0;return output
}
@_cdecl("thunderbird_imap_account_request")
public func imapAccountRequest(_ raw: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let raw, let input = String(validatingCString:raw), input.utf8.count <= 128 * 1024,
          let request = try? JSONDecoder().decode(ImapRequest.self,from:Data(input.utf8)) else {
        return encoded(ImapReply(error:ImapFailure.invalidArgument.rawValue))
    }
    let result=ResultBox(), done=DispatchSemaphore(value:0)
    let task=Task {
        do { result.set(try await perform(request)) }
        catch { result.set(ImapReply(error:(error as? ImapFailure ?? .network).rawValue)) }
        done.signal()
    }
    if done.wait(timeout:.now()+30) == .timedOut {
        result.set(ImapReply(error:(request.operation == "setKeyword" ? ImapFailure.changeUnconfirmed : .network).rawValue));task.cancel()
    }
    return encoded(result.get())
}
