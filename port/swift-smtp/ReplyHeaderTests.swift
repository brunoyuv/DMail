// MPL-2.0: https://mozilla.org/MPL/2.0/
import Testing
import Foundation
import MIME
import EmailAddress
import NIOCore
@testable import SMTP

struct ReplyHeaderTests {
    @Test func encodedReplyCarriesFoldedThreadHeaders() throws {
        let email = Email(sender: EmailAddress("sender@example.test"), recipients: [EmailAddress("to@example.test")],
            inReplyTo: ["parent@example.test"], references: ["root@example.test", "parent@example.test"])
        var buffer = ByteBufferAllocator().buffer(capacity: 1024)
        try RequestEncoder().encode(data: .transferData(email), out: &buffer)
        let wire = String(buffer: buffer)
        #expect(wire.contains("In-Reply-To: <parent@example.test>\r\n"))
        #expect(wire.contains("References: <root@example.test>\r\n <parent@example.test>\r\n"))
    }
    @Test func maliciousReplyHeadersAreRejected() {
        for id in ["parent@example.test\r\nBcc: bad@example.test", "<parent@example.test>", "bad", "é@example.test"] {
            #expect(throws: SMTPError.self) { try replyHeader([id]) }
        }
        #expect(throws: SMTPError.self) { try replyHeader(Array(repeating: "a@b", count: 101)) }
    }
}
