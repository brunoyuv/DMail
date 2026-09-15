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

    @Test func attachmentsRoundTripOriginalBytesAndUnicodeNamesThroughMixedMIME() throws {
        let bytes = Data([0, 1, 2, 255, 10, 13, 128])
        let original = try compositionBody(text: "Hello 中文")
        let body = try appendingAttachments([
            CompositionAttachment(name: "报价 café 📎.pdf", contentType: "application/pdf", data: bytes),
            CompositionAttachment(name: "empty.txt", contentType: "text/plain", data: Data())
        ], to: original)
        #expect(body.contentType.isMultipart)
        let parts = try MIME.Body(body.rawValue).part.parts
        #expect(parts.count == 3)
        #expect(parts[0].data == original.part.data)
        #expect(parts[1].contentDisposition?.file?.filename == "报价 café 📎.pdf")
        #expect(parts[1].contentType == .application("pdf"))
        #expect(parts[1].contentTransferEncoding == .base64)
        #expect(Data(base64Encoded: parts[1].data, options: .ignoreUnknownCharacters) == bytes)
        #expect(parts[2].contentDisposition?.file?.filename == "empty.txt")
        #expect(parts[2].data.isEmpty)
        #expect(body.rawValue.allSatisfy { $0 < 128 })
        #expect(body.description.contains("filename*=utf-8''"))
    }

    @Test func attachmentBoundsAllowTenMiBButRejectCountTotalAndHeaderInjection() throws {
        let original = try compositionBody(text: "Bounded attachment")
        let maximum = CompositionAttachment(name: "large.bin", contentType: "application/octet-stream", data: Data(repeating: 42, count: maximumAttachmentBytes))
        let body = try appendingAttachments([maximum], to: original)
        #expect(body.part.data.count < maximumOutgoingMessageBytes)
        #expect(body.part.data.count > maximumAttachmentBytes)
        #expect(throws: (any Error).self) { try appendingAttachments([maximum,
            CompositionAttachment(name: "extra.bin", contentType: "application/octet-stream", data: Data([1]))], to: original) }
        #expect(throws: (any Error).self) { try appendingAttachments(Array(repeating:
            CompositionAttachment(name: "zero.bin", contentType: "application/octet-stream", data: Data()), count: 11), to: original) }
        for name in ["bad\r\nBcc: injected@example.invalid", "bad\0.pdf", String(repeating: "界", count: 171)] {
            #expect(throws: (any Error).self) { try validateAttachment(name: name, contentType: "application/pdf", size: 1) }
        }
        for type in ["multipart/mixed", "application/pdf;bad=value", "text/plain\r\nInjected: yes"] {
            #expect(throws: (any Error).self) { try validateAttachment(name: "file", contentType: type, size: 1) }
        }
        #expect(throws: (any Error).self) { try validateAttachment(name: "file", contentType: "application/pdf", size: -1) }
    }

    @Test func forwardingKeepsTheExistingHtmlBodyAsTheFirstMixedPart() throws {
        let original = try compositionBody(text: "Forward introduction", forwardHtml: "<p>Original 中文</p>")
        let body = try appendingAttachments([CompositionAttachment(name: "image.png", contentType: "image/png", data: Data([137,80,78,71]))], to: original)
        let parts = try body.part.parts
        #expect(parts[0].contentType == original.contentType)
        #expect(parts[0].data == original.part.data)
        #expect(parts[1].contentDisposition?.file?.filename == "image.png")
        #expect(try appendingAttachments([], to: original).rawValue == original.rawValue)
    }
}
