// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import MIME

/// The same RFC 5322/MIME bytes are used for SMTP and the private Sent copy.
/// SMTP framing and dot stuffing belong only to RequestEncoder.
public func messageData(_ email: Email, includeBcc: Bool = false) throws -> Data {
    try validateMessage(email)
    var message = "From: \(try senderHeader(email.sender))\(crlf)"
    if !email.recipients.isEmpty { message += "To: \(email.recipients.map { $0.value }.joined(separator: ",\r\n "))\(crlf)" }
    if !email.copied.isEmpty { message += "Cc: \(email.copied.map { $0.value }.joined(separator: ",\r\n "))\(crlf)" }
    if includeBcc && !email.blindCopied.isEmpty { message += "Bcc: \(email.blindCopied.map { $0.value }.joined(separator: ",\r\n "))\(crlf)" }
    message += "Date: \(email.date.rfc822Format())\(crlf)Message-ID: \(email.messageID)\(crlf)"
    if !email.inReplyTo.isEmpty { message += "In-Reply-To: \(try replyHeader(email.inReplyTo))\(crlf)" }
    if !email.references.isEmpty { message += "References: \(try replyHeader(email.references))\(crlf)" }
    message += "Subject: \(try subjectHeader(email.subject))\(crlf)MIME-Version: 1.0\(crlf)"
    guard let body = String(data: email.body.rawValue, encoding: .ascii) else { throw SMTPError.invalidMessage }
    message += body
    message = message.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        .components(separatedBy: "\n").joined(separator: crlf)
    if !message.hasSuffix(crlf) { message += crlf }
    let data = Data(message.utf8)
    guard data.count <= maximumOutgoingMessageBytes else { throw SMTPError.invalidMessage }
    return data
}

/// Gmail documents automatic Sent saving for SMTP. Match the actual servers,
/// never an address suffix or a lookalike hostname; other providers use APPEND.
public func serverSavesSent(smtpEndpoint: String, imapEndpoint: String, smtpUsername: String, imapUsername: String) -> Bool {
    guard !smtpUsername.isEmpty, smtpUsername.lowercased() == imapUsername.lowercased() else { return false }
    guard let smtp = URLComponents(string: smtpEndpoint), let imap = URLComponents(string: imapEndpoint),
          ["smtp", "smtps"].contains(smtp.scheme ?? ""), imap.scheme == "imaps",
          smtp.user == nil, smtp.password == nil, smtp.query == nil, smtp.fragment == nil,
          imap.user == nil, imap.password == nil, imap.query == nil, imap.fragment == nil,
          smtp.path.isEmpty || smtp.path == "/", imap.path.isEmpty || imap.path == "/" else { return false }
    return ["smtp.gmail.com", "smtp.googlemail.com"].contains(smtp.host?.lowercased() ?? "") &&
        ["imap.gmail.com", "imap.googlemail.com"].contains(imap.host?.lowercased() ?? "")
}
