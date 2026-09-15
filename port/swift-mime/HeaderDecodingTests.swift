@testable import MIME
import Foundation
import Testing

struct HeaderDecodingTests {
    @Test func mixedPlainTextAndFoldedEncodedWords() throws {
        let value = "Re: =?UTF-8?B?5Lit5paH?=\r\n\t=?UTF-8?Q?_caf=C3=A9_=F0=9F=93=A8?= update"
        #expect(try value.headerDecoded() == "Re: 中文 café 📨 update")
    }

    @Test func onlyWhitespaceBetweenEncodedWordsIsRemoved() throws {
        let value = "=?UTF-8?B?5pel?= \t =?UTF-8?B?5pys?= =?UTF-8?B?6Kqe?= / =?UTF-8?Q?caf=C3=A9?="
        #expect(try value.headerDecoded() == "日本語 / café")
    }

    @Test func qHeaderSpacesAndLiteralUnderscoresAreDistinct() throws {
        #expect(try "=?UTF-8?Q?=E5=B1=B1=E7=94=B0_=E5=A4=AA=E9=83=8E?=".headerDecoded() == "山田 太郎")
        #expect(try "=?UTF-8?Q?first_last=5Fname?=".headerDecoded() == "first last_name")
        #expect(try "plain_name".headerDecoded() == "plain_name")
    }

    @Test func legacyCharsetAndCaseInsensitiveAliases() throws {
        #expect(try "=?windows-1252?Q?caf=E9_=80?=".headerDecoded() == "café €")
        #expect(try "=?utf8?q?=E4=B8=AD=E6=96=87?=".headerDecoded() == "中文")
        #expect(try "=?SHIFT_JIS?Q?=93=FA=96=7B=8C=EA?=".headerDecoded() == "日本語")
    }

    @Test func qBytesAreDecodedTogetherForStatefulCharsets() throws {
        // The unescaped ASCII bytes are still in JIS mode after ESC $ B.
        #expect(try "=?ISO-2022-JP?Q?=1B$BF|K\\8l=1B(B?=".headerDecoded() == "日本語")
    }

    @Test func malformedOrUnknownWordsDoNotEraseReadableHeaders() throws {
        #expect(try "Re: =?UTF-8?B?%%%?= update".headerDecoded() == "Re: =?UTF-8?B?%%%?= update")
        #expect(try "=?unknown-charset?B?YQ==?=".headerDecoded() == "=?unknown-charset?B?YQ==?=")
        #expect(try "=?UTF-8?Q?=C3?= =?UTF-8?Q?caf=C3=A9?=".headerDecoded() == "=?UTF-8?Q?=C3?= café")
        #expect(try "=?UTF-8?Q?bad=ZZ?=".headerDecoded() == "=?UTF-8?Q?bad=ZZ?=")
    }

    @Test func rawUnicodeAndBodyUnderscoresAreUnchanged() throws {
        #expect(try "  中文 café 📨  ".headerDecoded() == "  中文 café 📨  ")
        #expect(try String(quotedPrintable: "body_word=20caf=C3=A9") == "body_word café")
    }
}
