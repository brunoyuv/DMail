import AccountBody
import MIME
import Foundation
import Testing

struct AccountBodyCompatibilityTests {
    @Test func emptyTextAndAttachmentOnlyMultipartAreValidBodies() throws {
        let pdf = "Content-Type: application/pdf\r\nContent-Disposition: attachment; filename=report.pdf\r\n" +
            "Content-Transfer-Encoding: base64\r\n\r\n" + Data("%PDF-fixture".utf8).base64EncodedString()
        for emptyText in [false, true] {
            let source = "Content-Type: multipart/mixed; boundary=mail\r\n\r\n" +
                (emptyText ? "--mail\r\nContent-Type: text/plain\r\n\r\n\r\n" : "") +
                "--mail\r\n\(pdf)\r\n--mail--\r\n"
            let body = try EmailBody(body: MIME.Body(source))
            #expect(body.text == (emptyText ? "" : nil))
            #expect(body.html() == nil)
            #expect(!body.decodingHadErrors)
            #expect(body.attachments.count == 1)
            #expect(body.attachments[0].data == Data("%PDF-fixture".utf8))
        }
    }
    @Test func prunedAttachmentWithEmptyTextKeepsExplicitEmptyBody() throws {
        let part = try MIME.Part(parts: [
            MIME.Part(data: Data(), contentType: .text(.plain, .utf8)),
            MIME.Part(data: Data(), contentType: .application("x-dmail-omitted"))], contentType: .multipart(.mixed))
        let body = try EmailBody(body: MIME.Body(part: part))
        #expect(body.text == "")
        #expect(body.html() == nil)
        #expect(!body.decodingHadErrors)
    }
    @Test func foldedNewsletterWithEightBitUTF8AndCIDImage() throws {
        let source = """
        Subject: 日本語
        Content-Type:multipart/related;
          boundary="newsletter"

        --newsletter
        Content-Type:text/html;
          charset=UTF-8
        Content-Transfer-Encoding:8bit

        <h1>Newsletter 日本語</h1><img src="cid:picture@example.test">
        --newsletter
        Content-Type: image/png
        Content-ID: <picture@example.test>
        Content-Transfer-Encoding: base64

        aGVsbG8=
        --newsletter--
        """
        let body = try EmailBody(body: MIME.Body(Data(source.utf8)))
        #expect(body.html()?.contains("Newsletter 日本語") == true)
        #expect(body.html()?.contains("src=\"data:image/png;base64,aGVsbG8=\"") == true)
        #expect(!body.decodingHadErrors)
    }
    @Test func brokenAttachmentDoesNotEraseReadableHTML() throws {
        let source = """
        Content-Type:multipart/mixed; boundary=mail

        --mail
        Content-Type: text/html; charset=utf-8

        <p>Readable content</p>
        --mail
        Content-Type: image/png
        Content-Transfer-Encoding: base64

        a
        --mail--
        """
        let body = try EmailBody(body: MIME.Body(source))
        #expect(body.html()?.contains("Readable content") == true)
        #expect(body.decodingHadErrors)
    }
    @Test func legacyCharsetIsDecodedFromTheDeclaredEncoding() throws {
        let source = "Content-Type: text/html; charset=windows-1252\r\nContent-Transfer-Encoding: base64\r\n\r\n" + Data([60,112,62,99,97,102,233,32,128,60,47,112,62]).base64EncodedString()
        #expect(try EmailBody(body: MIME.Body(source)).html() == "<p>café €</p>")
    }
    @Test func quotedPrintableKeepsMultibyteLegacyCharactersTogether() throws {
        let source = "Content-Type: text/plain; charset=shift_jis\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n=93=FA=96{=8C=EA"
        #expect(try EmailBody(body: MIME.Body(source)).text == "日本語")
    }
    @Test func quotedPrintableDecodesUTF16AsOneByteSequence() throws {
        let source = "Content-Type: text/plain; charset=utf-16le\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nA=00B=00=2DN"
        #expect(try EmailBody(body: MIME.Body(source)).text == "AB中")
    }
    @Test(arguments: ["base64", "quoted-printable", "8bit"])
    func utf8BodyRecoversAfterIncorrectASCIIDeclaration(_ transfer: String) throws {
        let expected = "<p>中文 café 😀</p>"
        let payload: String
        switch transfer {
        case "base64": payload = Data(expected.utf8).base64EncodedString()
        case "quoted-printable": payload = "<p>=E4=B8=AD=E6=96=87 caf=C3=A9 =F0=9F=98=80</p>"
        default: payload = expected
        }
        let source = "Content-Type: text/html; charset=us-ascii\r\nContent-Transfer-Encoding: \(transfer)\r\n\r\n" + payload
        #expect(try EmailBody(body: MIME.Body(Data(source.utf8))).html() == expected)
    }
    @Test func missingContentTypeRecoversValidUTF8WithoutReplacingBytes() throws {
        let source = "Subject: fixture\r\n\r\n中文 café 😀"
        #expect(try EmailBody(body: MIME.Body(Data(source.utf8))).text == "中文 café 😀")
    }
    @Test func quotedPrintableUTF8SoftBreakMaySplitACharacter() throws {
        let source = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n=E4=B8=\r\n=AD=E6=96=87"
        #expect(try EmailBody(body: MIME.Body(source)).text == "中文")
    }
    @Test func validDeclaredLegacyCharsetIsNotOverriddenByUTF8Guessing() throws {
        let source = "Content-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: base64\r\n\r\nw6k="
        #expect(try EmailBody(body: MIME.Body(source)).text == "Ã©")
    }

    @Test func malformedQuotedPrintableEscapeDoesNotDiscardOtherDecodedText() throws {
        let source = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nprice=oops caf=C3=A9"
        #expect(try EmailBody(body: MIME.Body(source)).text == "price=oops café")
    }
    @Test func invalidUTF8IsNotSilentlyReplaced() {
        let source = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n/w=="
        #expect(throws: (any Error).self) { try EmailBody(body: MIME.Body(source)) }
    }

}

struct ScopedBodyTests {
    private let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aM0cAAAAASUVORK5CYII="
    private let gif = "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
    private func html(_ text: String, headers: String = "") -> String {
        "Content-Type: text/html; charset=utf-8\r\n" + headers + "\r\n" + text
    }
    private func image(_ data: String, type: String, id: String, location: String = "") -> String {
        "Content-Type: \(type)\r\nContent-ID: <\(id)>\r\nContent-Transfer-Encoding: base64\r\n" +
            (location.isEmpty ? "" : "Content-Location: \(location)\r\n") + "\r\n" + data
    }
    private func multipart(_ subtype: String, _ boundary: String, _ parts: [String], parameters: String = "", headers: String = "") -> String {
        "Content-Type: multipart/\(subtype); boundary=\"\(boundary)\"\(parameters)\r\n\(headers)\r\n" +
            parts.map { "--\(boundary)\r\n\($0)\r\n" }.joined() + "--\(boundary)--\r\n"
    }
    private func decode(_ source: String) throws -> EmailBody { try EmailBody(body: MIME.Body(source)) }

    @Test func choosesLastHTMLAlternativeAndKeepsPlainFallback() throws {
        let source = multipart("alternative", "alt", ["Content-Type: text/plain\r\n\r\nPlain fallback",
            html("<p>Old alternative</p>"), html("<p>Selected alternative</p>")])
        let body = try decode(source)
        #expect(body.html(.none) == "<p>Selected alternative</p>")
        #expect(body.text == "Plain fallback")
    }
    @Test func duplicateCIDIsResolvedInsideSelectedAlternative() throws {
        let old = multipart("related", "old", [html("<p>Old</p><img src='cid:picture@example.test'>"), image(gif, type: "image/gif", id: "picture@example.test")])
        let selected = multipart("related", "new", [html("<p>Selected</p><img src='cid:picture@example.test'>"), image(png, type: "image/png", id: "picture@example.test")])
        let body = try decode(multipart("alternative", "alt", [old, selected]))
        #expect(body.html()?.contains("data:image/png;base64,\(png)") == true)
        #expect(body.html()?.contains("data:image/gif") == false)
        #expect(body.html(.none)?.contains("Old") == false)
    }
    @Test func relatedStartSelectsRootWithoutDisplayingAuxiliaryHTML() throws {
        let source = multipart("related", "r", [html("<p>Auxiliary resource</p>", headers: "Content-ID: <aux@example.test>\r\n"),
            html("<p>Actual root</p>", headers: "Content-ID: <root@example.test>\r\nContent-Disposition: attachment\r\n")],
            parameters: "; start=\"<root@example.test>\"; type=\"text/html\"")
        #expect(try decode(source).html(.none) == "<p>Actual root</p>")
    }
    @Test func imageFirstRelatedWithoutStartRecoversOnlyOneDeclaredBody() throws {
        let picture = image(png, type: "image/png", id: "picture@example.test")
        let content = html("<p>Recoverable MHTML</p><img src='cid:picture@example.test'>")
        let source = multipart("related", "r", [picture, content], parameters: "; type=\"text/html\"")
        let body = try decode(source)
        #expect(body.html(.none) == "<p>Recoverable MHTML</p><img src='cid:picture@example.test'>")
        #expect(body.html()?.contains("data:image/png;base64,\(png)") == true)
        let ambiguous = try decode(multipart("related", "r", [picture, content, html("<p>Other body</p>")], parameters: "; type=\"text/html\""))
        #expect(ambiguous.html() == nil)
        let explicit = try decode(multipart("related", "r", [picture, content], parameters: "; type=\"text/html\"; start=\"<absent@example.test>\""))
        #expect(explicit.html() == nil)
    }
    @Test func missingRelatedRootDoesNotPromoteAnotherPart() throws {
        let body = try decode(multipart("related", "r", [html("<p>Not the root</p>")], parameters: "; start=\"<missing@example.test>\""))
        #expect(body.html() == nil)
        #expect(body.decodingHadErrors)
    }
    @Test func nestedRelatedCanUseOuterResourceButSiblingRelatedCannot() throws {
        let nested = multipart("related", "nested", [html("<img src='cid:outer@example.test'>")], headers: "Content-ID: <root@example.test>\r\n")
        let outer = multipart("related", "outer", [nested, image(png, type: "image/png", id: "outer@example.test")], parameters: "; start=\"<root@example.test>\"")
        #expect(try decode(outer).html()?.contains("data:image/png;base64,\(png)") == true)
        let sibling = multipart("related", "sibling", [html("<p>Separate document</p><img src='cid:outer@example.test'>")])
        let output = try decode(multipart("mixed", "m", [outer, sibling])).html() ?? ""
        #expect(output.components(separatedBy: "data:image/png;base64,").count == 2)
        #expect(output.contains("<p>Separate document</p><img src='cid:outer@example.test'>"))
        let alternative = multipart("alternative", "a", [outer])
        let alternativeOutput = try decode(multipart("mixed", "m", [alternative, sibling])).html() ?? ""
        #expect(alternativeOutput.contains("<p>Separate document</p><img src='cid:outer@example.test'>"))
    }
    @Test func rootAndResourceLocationsResolveWithinTheSameScope() throws {
        let source = multipart("related", "r", [html("<img src='logo.png'>", headers: "Content-Location: https://example.test/mail/index.html\r\n"),
            image(png, type: "image/png", id: "logo@example.test", location: "https://example.test/mail/logo.png")])
        #expect(try decode(source).html()?.contains("data:image/png;base64,\(png)") == true)
    }
    @Test func referencedGenericPNGIsInlinedButUnrecognizedBinaryIsNot() throws {
        let source = multipart("related", "r", [html("<img src='cid:good@example.test'><img src='cid:unknown@example.test'>"),
            image(png, type: "application/octet-stream", id: "good@example.test"),
            image("aGVsbG8=", type: "application/octet-stream", id: "unknown@example.test")])
        let output = try decode(source).html() ?? ""
        #expect(output.contains("data:image/png;base64,\(png)"))
        #expect(output.contains("cid:unknown@example.test"))
    }
    @Test func malformedPreferredAlternativeKeepsReadableEarlierAlternative() throws {
        let source = multipart("alternative", "a", [html("<p>Fallback</p>"),
            "Content-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n/w=="])
        let body = try decode(source)
        #expect(body.html(.none) == "<p>Fallback</p>")
        #expect(body.decodingHadErrors)
    }
    @Test func omittedDefaultRootKeepsItsPosition() throws {
        let source = multipart("related", "r", ["Content-Type: application/x-dmail-omitted\r\n\r\n", html("<p>Auxiliary</p>")])
        #expect(try decode(source).html() == nil)
    }
    @Test func metadataSurvivesPartSerialization() throws {
        let source = multipart("related", "r", [html("<p>Root</p>", headers: "Content-ID: <root@example.test>\r\n")],
            parameters: "; start=\"<root@example.test>\"", headers: "Content-ID: <container@example.test>\r\nContent-Location: https://example.test/mail/\r\n")
        let original = try MIME.Part(source), roundTrip = try MIME.Part(original.rawValue)
        #expect(roundTrip.contentTypeParameters["start"] == "<root@example.test>")
        #expect(roundTrip.contentID?.description == "<container@example.test>")
        #expect(roundTrip.contentLocation == "https://example.test/mail/")
        #expect(try roundTrip.parts.first?.contentID?.description == "<root@example.test>")
    }
}

struct EmptyCompositionBodyTests {
    @Test func emptyStandaloneTextAndHtmlDecodeWithoutAnError() throws {
        for subtype in [String.plain, .html] {
            for transfer in [ContentTransferEncoding.base64, .quotedPrintable, .data] {
                let part = MIME.Part(data: Data(), contentTransferEncoding: transfer, contentType: .text(subtype, .utf8))
                let body = try EmailBody(body: MIME.Body(part: part))
                #expect(body.text == (subtype == .html ? nil : ""))
                #expect(body.html(.none) == (subtype == .html ? "" : nil))
                #expect(!body.decodingHadErrors)
            }
        }
        #expect(throws: (any Error).self) { try EmailBody(body: nil) }
        #expect(throws: (any Error).self) { try EmailBody(body: MIME.Body(part: MIME.Part(data: Data(), contentType: .multipart(.mixed)))) }
    }
}
