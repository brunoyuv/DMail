// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import Testing
import EmailAddress
import MIME
import NIOCore
@testable import SMTP

struct SenderIdentityTests {
    @Test func unicodeAndPunctuationNamesAreEncodedWithoutChangingEnvelopeOrSentCopy() throws {
        for name in ["李明 / Zoë 📬", String(repeating: "日本語 📬", count: 20), "Doe, Jane \"Team\" <not-an-address>"] {
            let sender = try senderAddress("sender@example.test", name: name)
            let header = try senderHeader(sender)
            let words = header.components(separatedBy: " <sender@example.test>")[0]
                .components(separatedBy: "\r\n ")
            let decoded = try words.map { word -> String in
                #expect(word.hasPrefix("=?UTF-8?B?") && word.hasSuffix("?="))
                #expect(word.utf8.count <= 75)
                let data = try #require(Data(base64Encoded: String(word.dropFirst(10).dropLast(2))))
                return try #require(String(data: data, encoding: .utf8))
            }.joined()
            #expect(decoded == name)
            #expect(header.utf8.allSatisfy { $0 < 128 })
            let email = Email(sender: sender, recipients: [EmailAddress("reader@example.test")],
                blindCopied: [EmailAddress("hidden@example.test")], body: try compositionBody(text: "Synthetic body"))
            let smtp = String(decoding: try messageData(email), as: UTF8.self)
            let sent = String(decoding: try messageData(email, includeBcc: true), as: UTF8.self)
            #expect(smtp.hasPrefix("From: \(header)\r\nTo: reader@example.test\r\n"))
            #expect(sent.replacingOccurrences(of: "Bcc: hidden@example.test\r\n", with: "") == smtp)
            var envelope = ByteBuffer()
            try RequestEncoder().encode(data: .mailFrom(sender), out: &envelope)
            #expect(String(buffer: envelope) == "MAIL FROM:<sender@example.test>\r\n")
        }
    }

    @Test func rawSenderNameInjectionIsRejectedBeforeAddressTrimmingOrEncoding() {
        for name in ["\r\nBcc: attacker@example.test", "Name\n", "\tName", "Name\0", "Name\u{7f}", String(repeating: "x", count: 801)] {
            #expect(throws: SMTPError.self) { try senderAddress("sender@example.test", name: name) }
        }
        for mailbox in [" Name <sender@example.test>", "sender@example.test\r\n", "sender@example.test "] {
            #expect(throws: SMTPError.self) { try senderAddress(mailbox, name: "Sender") }
        }
    }

    @Test func emptySenderNameRemainsBareAndRecipientLabelsRemainRejected() throws {
        #expect(try senderHeader(senderAddress("sender@example.test")) == "sender@example.test")
        let email = Email(sender: try senderAddress("sender@example.test", name: "Sender"),
            recipients: [EmailAddress("reader@example.test", label: "Recipient")])
        #expect(throws: SMTPError.self) { try validateMessage(email) }
    }
}
