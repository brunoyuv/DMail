// MPL-2.0: https://mozilla.org/MPL/2.0/
@testable import MIME
import Foundation
import Testing

struct AttachmentFilenameTests {
    @Test func extendedUnicodeOverridesAsciiFallbackWithoutDoubleDecoding() {
        #expect(AttachmentFilename.decode(disposition: ["FILENAME": "fallback.pdf",
            "FiLeNaMe*": "utf-8'zh'%E6%8A%A5%E5%91%8A%20%F0%9F%93%84.pdf"], contentType: [:]) == "报告 📄.pdf")
        #expect(AttachmentFilename.decode(disposition: ["filename*": "utf-8''100%2520%2B.pdf"], contentType: [:]) == "100%20+.pdf")
        #expect(AttachmentFilename.decode(disposition: ["filename": "报告.pdf"], contentType: [:]) == "报告.pdf")
    }

    @Test func continuationOrderAndSplitMultibyteSequences() {
        #expect(AttachmentFilename.decode(disposition: ["filename*2": ".pdf", "filename*1*": "%A5%E5%91%8A",
            "filename*0*": "utf-8''%E6%8A"], contentType: [:]) == "报告.pdf")
        #expect(AttachmentFilename.decode(disposition: [:], contentType: ["name*1": ".pdf", "name*0": "Résumé"]) == "Résumé.pdf")
        #expect(AttachmentFilename.decode(disposition: ["filename*": "ISO-8859-1'en'caf%E9.pdf"], contentType: [:]) == "café.pdf")
    }

    @Test func encodedWordCompatibilityAndLiteralPercent() {
        #expect(AttachmentFilename.decode(disposition: ["filename": "=?UTF-8?B?5oql5ZGK?= =?UTF-8?Q?_=F0=9F=93=84.pdf?="], contentType: [:]) == "报告 📄.pdf")
        #expect(AttachmentFilename.decode(disposition: ["filename": "=?UTF-8?Q?caf=C3=A9.pdf?="], contentType: [:]) == "café.pdf")
        #expect(AttachmentFilename.decode(disposition: ["filename": "100%20_done.pdf"], contentType: [:]) == "100%20_done.pdf")
    }

    @Test func malformedExtendedValuesPreserveUsableFallback() {
        for value in ["utf-8''%GG.pdf", "utf-8''%E6%8A.pdf", "unknown-charset''name.pdf", "missing-delimiters"] {
            #expect(AttachmentFilename.decode(disposition: ["filename*": value, "filename": "fallback.pdf"], contentType: [:]) == "fallback.pdf")
        }
        for values in [["filename*0*": "utf-8''first", "filename*2": "last.pdf"],
                       ["filename*00*": "utf-8''first", "filename*1": "last.pdf"],
                       ["filename*0": "one", "filename*0*": "utf-8''two"]] {
            #expect(AttachmentFilename.decode(disposition: values, contentType: ["name": "type.pdf"]) == "type.pdf")
        }
        #expect(AttachmentFilename.decode(disposition: ["filename*": "utf-8''" + String(repeating: "x", count: 17000)], contentType: [:]) == nil)
    }

    @Test func rawDispositionAcceptsUnicodeAndQuotedSemicolons() throws {
        let raw = #"attachment; filename="=?UTF-8?Q?caf=C3=A9?=; \"report\".pdf"; size=123"#
        let disposition = try ContentDisposition(raw)
        #expect(disposition.file?.filename == "café; \"report\".pdf")
        #expect(disposition.file?.size == 123)
        #expect(ContentDisposition.File(filename: "报告.pdf").filename == "报告.pdf")
        #expect(ContentDisposition.File(rawValue: ContentDisposition.File(filename: "报告.pdf").rawValue)?.filename == "报告.pdf")
        #expect(ContentDisposition.File(filename: "").filename == nil)
    }

    @Test func downloadedMimePartMatchesMetadataAndKeepsItsBytes() throws {
        let raw = "Content-Type: application/pdf; name=\"fallback.pdf\"\r\n" +
            "Content-Disposition: attachment; filename*0*=utf-8''%E6%8A;\r\n filename*1*=%A5%E5%91%8A.pdf; size=12\r\n" +
            "Content-Transfer-Encoding: base64\r\n\r\nJVBERi1maXh0dXJl"
        let part = try MIME.Part(Data(raw.utf8))
        #expect(part.contentDisposition?.file?.filename == "报告.pdf")
        #expect(part.contentDisposition?.file?.size == 12)
        #expect(part.data == Data("JVBERi1maXh0dXJl".utf8))
        let wire = part.rawValue
        #expect(String(data: wire, encoding: .ascii) != nil)
        #expect(try MIME.Part(wire).contentDisposition?.file?.filename == "报告.pdf")
        let named = try MIME.Part(Data("Content-Type: application/pdf; name*=utf-8''%E6%8A%A5%E5%91%8A.pdf\r\n\r\n%PDF-fixture".utf8))
        #expect(named.contentDisposition?.file?.filename == "报告.pdf")
        if case .attachment = named.contentDisposition { Issue.record("A name fallback must not change inline disposition") }
    }
}
