// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import Testing
@testable import MIME

struct HtmlEntityTests {
    @Test func unterminatedAmpersandsAndQueryStringsRemainLiteral() {
        for value in ["&", "A & B", "&&&&", "&amp", "&#123", "&#x20ac",
                      "https://example.invalid/image?a=1&b=2", "中文 & café 👩🏽‍💻"] {
            #expect(value.htmlEntitiesDecoded() == value)
        }
    }

    @Test func knownNumericAndUnknownEntitiesPreserveExistingMeaning() {
        #expect("&amp;&lt;&gt;&quot;&apos;&copy;".htmlEntitiesDecoded() == "&<>\"'©")
        #expect("&#65;&#x20ac;&#X1f600;".htmlEntitiesDecoded() == "A€😀")
        #expect("&unknown; &#xD800; &#1114112; &#; &#x;".htmlEntitiesDecoded() ==
                "&unknown; &#xD800; &#1114112; &#; &#x;")
        #expect("&broken&copy; &unknown;&amp; &tail".htmlEntitiesDecoded() == "&broken© &unknown;& &tail")
        #expect("e\u{301} &amp; 中文 &\u{301}amp; &amp;\u{301} 👩🏽‍💻".htmlEntitiesDecoded() ==
                "e\u{301} & 中文 &\u{301}amp; &\u{301} 👩🏽‍💻")
        #expect(("&#" + String(repeating: "0", count: 1000) + "65;").htmlEntitiesDecoded() == "A")
    }

    @Test func repeatedMalformedPrefixesDoNotRescanTheRemainingMessage() {
        let malformed = String(repeating: "&invalid", count: 100_000)
        let source = malformed + "&copy; 中文 &"
        let start = Date()
        #expect(source.htmlEntitiesDecoded() == malformed + "© 中文 &")
        print("HTML_ENTITY_LINEAR bytes=\(source.utf8.count) elapsed_ms=\(Date().timeIntervalSince(start) * 1000)")
    }
}
