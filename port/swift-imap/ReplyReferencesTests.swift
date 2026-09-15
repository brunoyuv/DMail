// MPL-2.0: https://mozilla.org/MPL/2.0/
import Testing
import Foundation
@testable import IMAP
struct ReplyReferencesTests {
    @Test func foldedHeaderExcludesCommentsAndBody() {
        let message = "References: <root@example.test> (ignore <comment@example.test>)\r\n\t<parent@example.test>\r\nContent-Type: text/plain\r\n\r\nReferences: <body@example.test>"
        #expect(replyReferences(Data(message.utf8)) == ["root@example.test", "parent@example.test"])
    }
    @Test func ambiguousAndOversizedHeadersAreOmitted() {
        #expect(replyReferences(Data("References: <a@b>\nReferences: <c@d>\n\nbody".utf8)).isEmpty)
        #expect(replyReferences(Data((String(repeating: "x", count: 65_536) + "\n\nbody").utf8)).isEmpty)
    }
}
