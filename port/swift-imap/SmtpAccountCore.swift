// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import Dispatch
import SMTP
import MIME
import EmailAddress
import IMAP

private struct SentDestination: Decodable, Sendable {
    let sessionUrl: String, authorization: String
    let username: String?
}

private struct SmtpRequest: Decodable, Sendable {
    let operation: String, endpoint: String, username: String, password: String
    let accessToken: String?
    let senderName: String?
    let from: String, to: [String], cc: [String], bcc: [String], subject: String, text: String
    let id: String, date: Double
    let inReplyTo: [String]?, references: [String]?
    let forwardHtml: String?
    let sentDestination: SentDestination?
}
private final class SmtpFlights: @unchecked Sendable {
    static let shared = SmtpFlights()
    private let lock = NSLock()
    private var active = Set<UUID>()
    func begin(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return active.insert(id).inserted }
    func end(_ id: UUID) { lock.lock(); defer { lock.unlock() }; active.remove(id) }
}
private struct SmtpReply: Encodable {
    var accepted: Bool?; var error: String?
    var messageId: String?; var date: Double?
    var textBody: String?; var htmlBody: String?
    var sentCopy: String?; var sentMailboxId: String?
}

private func saveSent(_ destination: SentDestination?, smtpEndpoint: String, smtpUsername: String, data: Data) async -> (String, String?) {
    guard let destination else { return ("failed", nil) }
    var automaticallySaved = false
    do {
        let input = ImapRequest(operation: "connect", sessionUrl: destination.sessionUrl,
            authorization: destination.authorization, username: destination.username,
            accountId: nil, mailboxId: nil, position: nil, queryState: nil, emailId: nil,
            keyword: nil, enabled: nil, attachmentId: nil)
        let connection = try ImapConnection(input)
        automaticallySaved = SMTP.serverSavesSent(smtpEndpoint: smtpEndpoint, imapEndpoint: destination.sessionUrl,
            smtpUsername: smtpUsername, imapUsername: connection.username)
        let trust = try ImapTrust(host: connection.host)
        let client = IMAPClient(IMAP.Server(hostname: connection.host, username: connection.username,
            password: connection.password, port: connection.port), tlsConfiguration: trust.configuration,
            commandTimeout: 10, additionalPeerVerification: trust.verifyPeer)
        // Gmail saves during SMTP delivery, but the UI still needs the actual
        // IMAP folder identity. Discover it before returning the auto-save
        // result; never APPEND a second Gmail copy, even if discovery fails.
        var outcome = automaticallySaved ? "server" : "failed", mailboxId: String?
        do {
            try await client.connect()
            if let token = connection.accessToken {
                try await client.authenticateXOAUTH2(username: connection.username, accessToken: token)
            } else { try await client.login() }
            let listed = try await client.list()
            guard listed.count <= 500, let mailbox = IMAP.sentMailbox(in: listed.map { $0.0 }) else {
                throw SentAppendError.rejected
            }
            mailboxId = try imapEncode(mailbox.description)
            if !automaticallySaved {
                do { try await client.appendSent(data, to: mailbox); outcome = "saved" }
                catch { outcome = (error as? SentAppendError) == .rejected ? "failed" : "unconfirmed" }
            }
        } catch { outcome = automaticallySaved ? "server" : "failed" }
        try? await client.logout()
        try? await client.shutdown()
        return (outcome, mailboxId)
    } catch { return (automaticallySaved ? "server" : "failed", nil) }
}
private func sendMessage(_ input: SmtpRequest) async throws -> SmtpReply {
    guard input.operation == "send" || input.operation == "validate",
          input.endpoint.utf8.count <= 1024,
          !input.endpoint.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 || $0.value == 92 }),
          let url = URLComponents(string: input.endpoint), url.scheme == "smtp" || url.scheme == "smtps",
          url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
          url.path.isEmpty || url.path == "/", let host = url.host, !host.isEmpty, host.utf8.count <= 253,
          (1...65535).contains(url.port ?? (url.scheme == "smtps" ? 465 : 587)) else { throw ImapFailure.unsafeEndpoint }
    guard !input.username.isEmpty, input.username.utf8.count <= 512,
          !input.username.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw ImapFailure.authenticationRequired }
    if input.operation != "validate", let token = input.accessToken {
        guard !token.isEmpty, token.utf8.count <= 32768, token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw ImapFailure.authenticationRequired }
    } else if input.operation != "validate" {
        guard !input.password.isEmpty, input.password.utf8.count <= 1024,
              !input.password.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) else { throw ImapFailure.authenticationRequired }
    }
    guard let id = UUID(uuidString: input.id), input.date.isFinite, input.date >= 0,
          input.text.utf8.count <= 256 * 1024, !input.text.contains("\0") else { throw SMTPError.invalidMessage }
    let body = try SMTP.compositionBody(text: input.text, forwardHtml: input.forwardHtml ?? "")
    let email = SMTP.Email(sender: try SMTP.senderAddress(input.from, name: input.senderName ?? ""), recipients: input.to.map { EmailAddress($0) },
        copied: input.cc.map { EmailAddress($0) }, blindCopied: input.bcc.map { EmailAddress($0) },
        subject: input.subject, inReplyTo: input.inReplyTo ?? [], references: input.references ?? [], date: Date(timeIntervalSince1970: input.date / 1000), body: body, id: id)
    // Mailboxes remain explicit, separate from the validated sender display name.
    let rawAddresses = [input.from] + input.to + input.cc + input.bcc
    guard rawAddresses.allSatisfy({ EmailAddress($0).value == $0 && EmailAddress($0).label == nil }) else { throw SMTPError.invalidMessage }
    try SMTP.validateMessage(email)
    if input.operation == "validate" { return SmtpReply(accepted: false) }
    let sentData = try SMTP.messageData(email, includeBcc: true)
    guard SmtpFlights.shared.begin(id) else { throw SMTPError.deliveryUnconfirmed }
    defer { SmtpFlights.shared.end(id) }
    let hostname = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let trust = try ImapTrust(host: hostname)
    let client = SMTPClient(SMTP.Server(url.scheme == "smtps" ? .tls : .startTLS, hostname: hostname,
        username: input.username, password: input.password, port: url.port ?? (url.scheme == "smtps" ? 465 : 587), accessToken: input.accessToken),
        tlsConfiguration: trust.configuration, additionalPeerVerification: trust.verifyPeer)
    try await client.send(email)
    // SMTP acceptance is final even if saving the Sent copy fails. Never turn
    // a failed/lost APPEND reply into a resend of an already delivered message.
    let (copy, mailboxId) = await saveSent(input.sentDestination, smtpEndpoint: input.endpoint, smtpUsername: input.username, data: sentData)
    let readable = try? EmailBody(body: email.body)
    return SmtpReply(accepted: true, messageId: String(email.messageID.description.dropFirst().dropLast()),
        date: input.date, textBody: readable?.text, htmlBody: readable?.html(.inlineAttachments),
        sentCopy: copy, sentMailboxId: mailboxId)
}
private final class SmtpResult: @unchecked Sendable {
    var reply = SmtpReply(error: "network")
}
@_cdecl("thunderbird_smtp_account_request")
public func smtpAccountRequest(_ raw: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    let result = SmtpResult()
    if let raw, let json = String(validatingCString: raw), json.utf8.count <= 2 * 1024 * 1024,
       let input = try? JSONDecoder().decode(SmtpRequest.self, from: Data(json.utf8)) {
        let done = DispatchSemaphore(value: 0)
        Task {
            do { result.reply = try await sendMessage(input) }
            catch {
                let code: String
                if let failure = error as? ImapFailure { code = failure.rawValue }
                else if let failure = error as? SMTPError {
                    switch failure {
                    case .deliveryUnconfirmed: code = "deliveryUnconfirmed"
                    case .authenticationRequired: code = "authenticationRequired"
                    case .invalidMessage, .emailRecipientNotFound: code = "invalidMessage"
                    case .rejected: code = "rejected"
                    case .requiredTLSNotConfigured: code = "certificate"
                    default: code = "network"
                    }
                } else { code = "network" }
                result.reply = SmtpReply(error: code)
            }
            done.signal()
        }
        // The SMTP transport has connect and transaction deadlines. Do not
        // return while it can still submit DATA in the background.
        done.wait()
    } else { result.reply = SmtpReply(error: "invalidMessage") }
    guard let bytes = try? JSONEncoder().encode(result.reply) else { return nil }
    let output = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
    for (index, byte) in bytes.enumerated() { output[index] = CChar(bitPattern: byte) }
    output[bytes.count] = 0; return output
}
