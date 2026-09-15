import AccountBody
import MIME
import Foundation
import Testing

struct CorpusBodyTests {
    @Test(arguments: (1...9).map { "body.\($0).txt" } + [
        "japanese.txt", "simple-multipart.anonymized.eml", "simple-embedded-message.anonymized.eml",
        "multipart-related-mhtml.txt", "rfc2060.txt", "empty-multipart.txt",
        "delivery-status.anonymized.eml", "missing-subtype.txt"
    ]) func publicMessages(_ name: String) throws {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Corpus").appendingPathComponent(name)
        let source = try Data(contentsOf: url)
        if name == "missing-subtype.txt" {
            #expect(throws: (any Error).self) { try MIME.Body(source) }
            return
        }
        let body = try EmailBody(body: MIME.Body(source))
        if name.hasPrefix("body.") {
            #expect((body.text ?? body.html() ?? "").contains("body"))
            #expect(!body.decodingHadErrors)
        } else if name == "japanese.txt" { #expect(body.text?.contains("日本語") == true) }
        else if name == "multipart-related-mhtml.txt" {
            #expect(body.html()?.contains("data:image/png;base64,") == true)
            #expect(body.html()?.contains("def") == true)
        } else if name == "empty-multipart.txt" {
            #expect(body.text?.contains("same level") == true)
            #expect(body.decodingHadErrors)
        } else if name != "delivery-status.anonymized.eml" { #expect(body.text?.isEmpty == false) }
    }
}
