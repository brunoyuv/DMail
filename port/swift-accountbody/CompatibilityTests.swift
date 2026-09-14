import AccountBody
import MIME
import Foundation
import Testing

struct AccountBodyCompatibilityTests {
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
