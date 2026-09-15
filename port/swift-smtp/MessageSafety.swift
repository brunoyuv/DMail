// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import EmailAddress
import MIME

private func validateSenderName(_ name: String) throws {
    guard name.utf8.count <= 800,
          !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw SMTPError.invalidMessage }
}

/// Keep the SMTP envelope mailbox distinct from the optional header display name.
/// Validate the raw name before EmailAddress can trim invisible edge characters.
public func senderAddress(_ mailbox: String, name: String = "") throws -> EmailAddress {
    try validateSenderName(name)
    let bare = EmailAddress(mailbox)
    guard bare.value == mailbox, bare.label == nil else { throw SMTPError.invalidMessage }
    return EmailAddress(mailbox, label: name)
}

public func validateMessage(_ email: Email) throws {
    _ = try replyHeader(email.inReplyTo)
    _ = try replyHeader(email.references)
    let addresses = [email.sender] + email.allRecipients
    guard !email.allRecipients.isEmpty, email.allRecipients.count <= 100,
          email.subject.utf8.count <= 998, !email.subject.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
          email.body.part.data.count <= maximumOutgoingMessageBytes - 65536 else { throw SMTPError.invalidMessage }
    try validateSenderName(email.sender.label ?? "")
    guard email.allRecipients.allSatisfy({ $0.label == nil }) else { throw SMTPError.invalidMessage }
    for address in addresses {
        // SMTP envelope addresses stay explicit ASCII mailboxes without SMTPUTF8.
        // Only the separate sender label is encoded into the From header.
        let value = address.value
        guard address.isEmailAddress, value.utf8.count <= 254,
              value.range(of: #"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil,
              !value.contains("..") else { throw SMTPError.invalidMessage }
    }
}

func subjectHeader(_ subject: String) throws -> String {
    if subject.utf8.count <= 42 { return try subject.headerEncoded() }
    return encodedHeaderWords(subject)
}

func senderHeader(_ sender: EmailAddress) throws -> String {
    guard let name = sender.label, !name.isEmpty else { return sender.value }
    try validateSenderName(name)
    // Encode even ASCII punctuation so it can never introduce another mailbox.
    return "\(encodedHeaderWords(name)) <\(sender.value)>"
}

private func encodedHeaderWords(_ value: String) -> String {
    // Fold only between encoded words, each below RFC 2047's 75-byte limit.
    // Work in Unicode scalars so UTF-8 characters are never split.
    var words = [String](), part = ""
    for scalar in value.unicodeScalars {
        if part.utf8.count + scalar.utf8.count > 42 {
            words.append("=?UTF-8?B?\(Data(part.utf8).base64EncodedString())?="); part = ""
        }
        part.unicodeScalars.append(scalar)
    }
    if !part.isEmpty { words.append("=?UTF-8?B?\(Data(part.utf8).base64EncodedString())?=") }
    return words.joined(separator: "\r\n ")
}


func replyHeader(_ ids: [String]) throws -> String {
    guard ids.count <= 100 else { throw SMTPError.invalidMessage }
    for id in ids {
        guard id.utf8.count <= 900,
              id.range(of: #"^[A-Za-z0-9!#$%&'*+\-/=?^_`{|}~.]+@[A-Za-z0-9.\-\[\]:]+$"#, options: .regularExpression) != nil else { throw SMTPError.invalidMessage }
    }
    return ids.map { "<\($0)>" }.joined(separator: "\r\n ")
}
