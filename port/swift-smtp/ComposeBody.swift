// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import MIME

/// Build the text editor and optional forwarded HTML using Thunderbird's MIME encoder.
public func compositionBody(text: String, forwardHtml: String = "") throws -> MIME.Body {
    guard text.utf8.count <= 256 * 1024, forwardHtml.utf8.count <= 512 * 1024,
          !text.contains("\0"), !forwardHtml.contains("\0") else { throw SMTPError.invalidMessage }
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let content: String
    let type: MIME.ContentType
    if forwardHtml.isEmpty {
        content = normalized.replacingOccurrences(of: "\n", with: "\r\n")
        type = .text(.plain, .utf8)
    } else {
        let escaped = normalized.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "\n", with: "<br>")
        content = "<html><body><div>\(escaped)</div><br>\(forwardHtml)</body></html>"
        type = .text(.html, .utf8)
    }
    let body = try MIME.Body(part: MIME.Part(data: Data(content.utf8).base64EncodedData(options: [
        .lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed
    ]), contentTransferEncoding: .base64, contentType: type))
    guard body.rawValue.count <= 1024 * 1024 else { throw SMTPError.invalidMessage }
    return body
}
