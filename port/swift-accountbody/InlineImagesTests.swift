import Foundation
import MIME
@testable import AccountBody
import Testing

struct InlineImageReferenceTests {
    private func attachment(_ id: String = "photo@test", data: Data = Data([1,2,3]), location: String? = nil) throws -> EmailAttachment {
        EmailAttachment(data: data, contentType: .image("png"), contentID: try ContentID("<\(id)>"), contentLocation: location)
    }
    @Test func onlyWholeImageReferencesAreExpanded() throws {
        let input = """
        <p>cid:photo@test</p><a href="cid:photo@test">link</a><!-- <img src="cid:photo@test"> -->
        <img src='cid:photo@test'><img src=cid:photo@test-extra><script>"<img src='cid:photo@test'>"</script>
        """
        let result = input.inliningImages(attachments: [try attachment()], limit: 2000)
        #expect(result.html.contains("<p>cid:photo@test</p>"))
        #expect(result.html.contains("<a href=\"cid:photo@test\">"))
        #expect(result.html.contains("<!-- <img src=\"cid:photo@test\"> -->"))
        #expect(result.html.contains("src=\"data:image/png;base64,AQID\""))
        #expect(result.html.contains("src=cid:photo@test-extra"))
        #expect(result.html.contains("<script>\"<img src='cid:photo@test'>\"</script>"))
        #expect(!result.truncated)
    }
    @Test func cssSourcesAndPercentEncodedCIDAreMatched() throws {
        let input = """
        <style>.x{background:url('cid:photo%40test')} .y{content:"cid:photo@test"}</style>
        <table background="cid:photo@test"><img srcset="cid:photo@test 1x, https://example.test/large 2x" style="background:url(&quot;cid:photo@test&quot;)"></table>
        """
        let result = input.inliningImages(attachments: [try attachment()], limit: 4000)
        #expect(result.html.components(separatedBy: "data:image/png;base64,AQID").count == 5)
        #expect(result.html.contains("content:\"cid:photo@test\""))
        #expect(result.html.contains("https://example.test/large 2x"))
        #expect(!result.truncated)
    }
    @Test func relativeContentLocationsRespectDocumentBase() throws {
        let input = "<img src=images/photo.png><img src=https://other.test/images/photo.png>"
        let result = input.inliningImages(attachments: [try attachment(location: "https://example.test/mail/images/photo.png")], limit: 2000, baseLocation: "https://example.test/mail/index.html")
        #expect(result.html.contains("src=\"data:image/png;base64,AQID\""))
        #expect(result.html.contains("src=https://other.test/images/photo.png"))
    }
    @Test func duplicateIdentifiersCannotBorrowArbitraryPicture() throws {
        let result = "<img src=cid:photo@test>".inliningImages(attachments: [try attachment(), try attachment(data: Data([4,5,6]))], limit: 2000)
        #expect(!result.html.contains("data:"))
    }
    @Test func repeatedExpansionStaysWithinBudgetWithoutCuttingDataURI() throws {
        let image = try attachment(data: Data(repeating: 1, count: 300))
        let tag = "<img srcset=\"" + Array(repeating: "cid:photo@test 1x", count: 200).joined(separator: ", ") + "\">"
        let result = (tag + "<p>Still readable 😀</p>").inliningImages(attachments: [image], limit: 6000)
        #expect(result.truncated)
        #expect(result.html.utf16.count <= 6000)
        #expect(result.html.contains("Still readable 😀"))
        let uri = "data:image/png;base64," + image.data.base64EncodedString()
        #expect(result.html.components(separatedBy: uri).count > 1)
        #expect(!result.html.replacingOccurrences(of: uri, with: "").contains("data:"))
    }
    @Test func tooLargeImageDoesNotEraseTextAndUnicodeIsNotSplit() throws {
        let result = "<img src=cid:photo@test><p>Readable</p>".inliningImages(attachments: [try attachment(data: Data(repeating: 1, count: 2000))], limit: 100)
        #expect(result.truncated)
        #expect(result.html.contains("Readable"))
        #expect(!result.html.contains("data:"))
        let text = "A😀B".inliningImages(attachments: [], limit: 2)
        #expect(text.html == "A")
        #expect(text.truncated)
    }

    @Test func malformedLongTokensAdvanceWithoutRepeatedSuffixSearches() {
        let fixtures = [
            "<div " + String(repeating: "x", count: 40_000) + ">Visible 中文</div>",
            String(repeating: "<style ", count: 20_000),
            "<div title='" + String(repeating: "<style ", count: 20_000),
            "<style>" + String(repeating: "url(", count: 20_000) + "</style><p>Visible</p>",
            "<style>.a{background:url('" + String(repeating: "url(", count: 20_000) + "</style>"
        ]
        let start = Date()
        for source in fixtures {
            let result = source.inliningImages(attachments: [], limit: source.utf16.count + 1)
            #expect(result.html == source)
            #expect(!result.truncated)
        }
        print("INLINE_IMAGE_PROGRESS fixtures=\(fixtures.count) elapsed_ms=\(Date().timeIntervalSince(start) * 1000)")
    }

    @Test func cssQuotesCommentsAndFailedCandidatesKeepLaterValidReferences() throws {
        let source = """
        <style>/* url(cid:photo@test) */ .a{content:'url(cid:photo@test)';broken:url( ; background:url('cid:photo@test')}
        .b{background:URL( "cid:photo@test" )}.c{content:"escaped\\\" url(cid:photo@test)"}</style>
        """
        let result = source.inliningImages(attachments: [try attachment()], limit: 4000)
        #expect(result.html.components(separatedBy: "data:image/png;base64,AQID").count == 3)
        #expect(result.html.contains("/* url(cid:photo@test) */"))
        #expect(result.html.contains("content:'url(cid:photo@test)'"))
        #expect(result.html.contains("escaped\\\" url(cid:photo@test)"))
        #expect(!result.truncated)
    }

    @Test func cancelledMalformedRenderingStillFinishes() async {
        let source = "<style>" + String(repeating: "url(", count: 20_000) + "</style>"
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return source.inliningImages(attachments: [], limit: source.utf16.count + 1).html
        }
        #expect(await task.value == source)
    }

    @Test func previewRemovalPreservesVisibleTextAndMalformedOpenings() {
        let source = "<head><title>Hidden</title></head><p>Visible 中文</p><STYLE>.a{color:red}</STYLE><script>hidden</script><template>hidden</template><p>Tail</p>"
        let result = EmailBody(html: source.removingMailPreviewBlocks()).html(.stripped)
        #expect(result == "Visible 中文   Tail")
        #expect("Before<style>unclosed".removingMailPreviewBlocks() == "Before ")
        #expect("<style title='>'>hidden</style>Visible".removingMailPreviewBlocks() == " Visible")
        let unfinished = String(repeating: "<head ", count: 20_000) + "中文"
        #expect(unfinished.removingMailPreviewBlocks() == unfinished)
    }
}
