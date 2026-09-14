@testable import SMTP
import MIME
import Foundation
import Testing

struct ComposeBodyTests {
    @Test func forwardHTMLUsesOriginalMIMEEncodingAndEscapesTheEditableIntroduction() throws {
        let body = try compositionBody(text: "Here <is> & \"mail\"\n日本語", forwardHtml: "<b>Original HTML</b>")
        #expect(body.contentType == .text(.html, .utf8))
        let decoded = try MIME.Body(body.rawValue)
        let text = String(data: Data(base64Encoded: decoded.part.data, options: .ignoreUnknownCharacters)!, encoding: .utf8)!
        #expect(text.contains("Here &lt;is&gt; &amp; &quot;mail&quot;<br>日本語"))
        #expect(text.contains("<b>Original HTML</b>"))
        #expect(body.description.contains("Content-Transfer-Encoding: base64"))
    }
    @Test func ordinaryCompositionRemainsTextAndRejectsOversizedOrNulContent() throws {
        let body = try compositionBody(text: "Hello\n日本語")
        #expect(body.contentType == .text(.plain, .utf8))
        #expect(String(data: Data(base64Encoded: body.part.data, options: .ignoreUnknownCharacters)!, encoding: .utf8) == "Hello\r\n日本語")
        #expect(throws: (any Error).self) { try compositionBody(text: "Hello", forwardHtml: "bad\0html") }
        #expect(throws: (any Error).self) { try compositionBody(text: String(repeating: "a", count: 262145)) }
        #expect(throws: (any Error).self) { try compositionBody(text: "Hello", forwardHtml: String(repeating: "a", count: 524289)) }
    }
}
