// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import Testing
import EmailAddress
import MIME
import NIOCore
@testable import SMTP

private func policy(smtpEndpoint: String, imapEndpoint: String,
                    smtpUsername: String = "login@example.test", imapUsername: String = "login@example.test") -> Bool {
    serverSavesSent(smtpEndpoint: smtpEndpoint, imapEndpoint: imapEndpoint,
        smtpUsername: smtpUsername, imapUsername: imapUsername)
}

struct MessageDataTests {
    @Test func sentCopySharesOriginalMessageIDDateThreadHeadersAndMIMEWithoutSMTPFraming() throws {
        let email = Email(sender: EmailAddress("sender@example.test"), recipients: [EmailAddress("reader@example.test")],
            blindCopied: [EmailAddress("private@example.test")], subject: "中文 sent",
            inReplyTo: ["parent@example.test"], references: ["root@example.test", "parent@example.test"],
            date: Date(timeIntervalSince1970: 1789257600), body: try compositionBody(text: "One\n.\n..two\n日本語"),
            id: UUID(uuidString: "7adc6f52-e9bb-4fe2-9c52-6fbd9f399cc6")!)
        let smtp = String(decoding: try messageData(email), as: UTF8.self)
        let sent = String(decoding: try messageData(email, includeBcc: true), as: UTF8.self)
        #expect(sent.replacingOccurrences(of: "Bcc: private@example.test\r\n", with: "") == smtp)
        #expect(!smtp.contains("private@example.test"))
        #expect(sent.contains("Message-ID: \(email.messageID)\r\n"))
        #expect(sent.contains("In-Reply-To: <parent@example.test>\r\n"))
        #expect(sent.contains("References: <root@example.test>\r\n <parent@example.test>\r\n"))
        #expect(!sent.hasSuffix("\r\n.\r\n"))
        var wire = ByteBuffer()
        try RequestEncoder().encode(data: .transferData(email), out: &wire)
        #expect(String(buffer: wire) == smtp + ".\r\n")
        #expect(try messageData(email) == messageData(email))
    }
    @Test func automaticSentPolicyMatchesGmailServerPairOnly() {
        #expect(!policy(smtpEndpoint: "smtps://smtp.gmail.com", imapEndpoint: "imaps://imap.gmail.com",
            smtpUsername: "other@example.test", imapUsername: "login@example.test"))
        #expect(!policy(smtpEndpoint: "smtps://smtp.gmail.com", imapEndpoint: "imaps://imap.gmail.com",
            smtpUsername: "", imapUsername: ""))
        #expect(policy(smtpEndpoint: "smtps://smtp.gmail.com", imapEndpoint: "imaps://imap.gmail.com",
            smtpUsername: "LOGIN@example.test", imapUsername: "login@example.test"))
        #expect(policy(smtpEndpoint: "smtps://smtp.gmail.com:465", imapEndpoint: "imaps://imap.gmail.com"))
        #expect(policy(smtpEndpoint: "smtp://smtp.googlemail.com:587", imapEndpoint: "imaps://imap.googlemail.com:993"))
        for host in ["smtp.gmail.com.evil.test", "smtp.example.test", "gmail.com"] {
            #expect(!policy(smtpEndpoint: "smtps://\(host)", imapEndpoint: "imaps://imap.gmail.com"))
        }
        #expect(!policy(smtpEndpoint: "smtps://smtp.gmail.com", imapEndpoint: "imaps://imap.example.test"))
        #expect(!policy(smtpEndpoint: "smtps://smtp.gmail.com", imapEndpoint: "imaps://imap.gmail.com.evil.test"))
        #expect(!policy(smtpEndpoint: "smtps://smtp.gmail.com", imapEndpoint: "imap://imap.gmail.com"))
    }
}
