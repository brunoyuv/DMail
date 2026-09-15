// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import Testing
@testable import AccountBody

struct HtmlTextTests {
    // Keep the old expression only in small differential fixtures. Large broken
    // markup must never enter this reference implementation.
    private func previous(_ value: String) -> String {
        value.replacing(/<[^>]*>/, with: "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    @Test func markupAndUnicodeMatchTheOriginalExpression() {
        let fixtures = ["", "<", "<<", ">", "<>tail<", "a < 3 > b", "<a<b> c",
            "  <p>中文 café 😀</p>\n <div>Next line</div> ", "<p title='>'>Text</p>",
            "Text <!-- <tag> --> more", "<p\r\nclass=x>body</p>", "No <closing tag",
            "<\u{301}p>x</p>", "<p>\u{301}x</p>", "<p\u{301}>x", "x<\u{200D}p>z",
            "<p\u{200D}>x", "<\u{fe0f}p>x", "\u{600}<p>x", "x<p>\u{600}Y",
            "👩🏽‍💻<p>e\u{301} 🏳️‍🌈</p>\n\t終わり", "<&amp;>A &amp; B"]
        for value in fixtures { #expect(value.htmlTagsStripped() == previous(value)) }
        #expect(EmailBody(html: "<p>中文 &amp; café 😀</p>").html(.stripped) == "中文 & café 😀")
    }

    @Test func mixedMalformedMarkupMatchesSmallDifferentialFixtures() {
        let tokens = ["<", ">", "p", " ", "\n", "\r", "\t", "\"", "'", "中文", "😀",
            "\u{301}", "\u{200D}", "\u{600}", "\u{fe0f}", "&amp;"]
        var seed: UInt64 = 0xD_A11
        for _ in 0..<1000 {
            var value = ""
            for _ in 0..<48 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                value += tokens[Int(seed >> 32) % tokens.count]
            }
            #expect(value.htmlTagsStripped() == previous(value))
        }
    }

    @Test func longUnterminatedMarkupKeepsItsTextWithoutRepeatedSearches() {
        let broken = String(repeating: "<", count: 20_000) + "中文 😀"
        let start = Date()
        #expect(broken.htmlTagsStripped() == broken)
        let elapsed = Date().timeIntervalSince(start)
        print("HTML_TEXT_LINEAR units=\(broken.utf16.count) elapsed_ms=\(elapsed * 1000)")
        // Both a retained unmatched suffix and a single late closing delimiter
        // exercise the path that formerly rescanned the suffix for every '<'.
        #expect(("<p>Visible</p>" + broken).htmlTagsStripped() == "Visible" + broken)
        #expect((broken + ">retained").htmlTagsStripped() == "retained")
        #expect(EmailBody(html: broken).html(.stripped) == broken)
    }
}
