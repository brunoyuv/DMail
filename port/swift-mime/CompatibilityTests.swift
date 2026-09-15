@testable import MIME
import Foundation
import Testing

struct CompatibilityTests {
    @Test func foldedHeadersAndEightBitBodyRetainBytes() throws {
        let source = "Subject: 日本語\r\nContent-Type:text/html;\r\n charset=utf-8\r\nContent-Transfer-Encoding:8bit\r\n\r\n<h1>日本語 & body</h1>"
        let body = try Body(Data(source.utf8))
        #expect(body.contentType == .text(.html, .utf8))
        #expect(String(data: body.part.data, encoding: .utf8) == "<h1>日本語 & body</h1>")
    }
    @Test func multipartBoundaryMustBeOnItsOwnLine() throws {
        let source = """
        Content-Type: multipart/related;
         boundary="example"

        preamble
        --example
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: 8bit

        <p>Do not split --example here. 日本語</p>
        --example
        Content-Type: image/png
        Content-ID: <picture@example.test>
        Content-Transfer-Encoding: base64

        aGVsbG8=
        --example--
        """
        let parts = try Body(Data(source.utf8)).part.parts
        #expect(parts.count == 2)
        #expect(String(data: parts[0].data, encoding: .utf8)?.contains("Do not split --example here. 日本語") == true)
        #expect(parts[1].contentID?.description == "<picture@example.test>")
    }
    @Test func missingTypeDefaultsToTextAndBodyWhitespaceIsPreserved() throws {
        let part = try Part(Data("Subject: test\r\n\r\n  text  \r\n".utf8))
        #expect(part.contentType == .text(.plain, .ascii))
        #expect(part.data == Data("  text  \r\n".utf8))
    }
    @Test func duplicateContentHeadersAndMissingTerminatorAreRejected() {
        #expect(throws: (any Error).self) { try Part("Content-Type: text/html\nContent-Type: text/plain\n\nx") }
        #expect(throws: (any Error).self) { try Body("Content-Type: multipart/mixed; boundary=x\n\n--x\nContent-Type: text/plain\n\nx").part.parts }
    }
}
