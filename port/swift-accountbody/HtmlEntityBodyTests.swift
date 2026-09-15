// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import Testing
@testable import AccountBody

struct HtmlEntityBodyTests {
    @Test func rawQueryAmpersandsFinishBothReaderRenderingAndPreview() {
        let source = "<html><body><img src=\"https://example.invalid/image?a=1&b=2\"><p>A & B</p></body></html>"
        let body = EmailBody(html: source)
        #expect(body.renderedHTML().html == source)
        #expect(body.html(.stripped) == "A & B")
    }

    @Test func cancelledLargeDecodeFinishesWithoutWaitingForAnotherCallback() async {
        // The bridge cancels a Swift Task after its deadline. Synchronous body
        // decoding must still finish; cancellation cannot preempt a busy loop.
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let text = String(repeating: "Unicode 中文 & ", count: 40_000)
            let body = EmailBody(html: "<p>" + text + "</p>")
            return (Task.isCancelled, body.html(.stripped), text.trimmingCharacters(in: .whitespaces))
        }
        let result = await task.value
        #expect(result.0)
        #expect(result.1 == result.2)
    }
}
