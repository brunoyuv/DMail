// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import MIME

public let maximumCompositionAttachments = 10
public let maximumAttachmentBytes = 10 * 1024 * 1024
public let maximumOutgoingMessageBytes = 16 * 1024 * 1024

public struct CompositionAttachment: Sendable {
    public let name: String, contentType: String
    public let data: Data
    public init(name: String, contentType: String, data: Data) {
        self.name = name; self.contentType = contentType; self.data = data
    }
}

public func validateAttachment(name: String, contentType: String, size: Int) throws {
    guard !name.isEmpty, name.utf8.count <= 512,
          !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
          contentType.utf8.count <= 127,
          contentType.range(of: #"^(application|audio|example|font|haptics|image|message|model|text|video)/[a-z0-9][a-z0-9!#$&^_.+\-]*$"#,
              options: [.regularExpression, .caseInsensitive]) != nil,
          size >= 0, size <= maximumAttachmentBytes else { throw SMTPError.invalidMessage }
}

/// Keep the original MIME encoder responsible for boundaries, attachment
/// disposition/UTF-8 filenames and Base64 line wrapping. Files remain opaque.
public func appendingAttachments(_ attachments: [CompositionAttachment], to body: MIME.Body) throws -> MIME.Body {
    guard attachments.count <= maximumCompositionAttachments else { throw SMTPError.invalidMessage }
    if attachments.isEmpty { return body }
    var total = 0, parts = [body.part]
    for attachment in attachments {
        try validateAttachment(name: attachment.name, contentType: attachment.contentType, size: attachment.data.count)
        total += attachment.data.count
        guard total <= maximumAttachmentBytes else { throw SMTPError.invalidMessage }
        let part = MIME.Part(data: attachment.data.base64EncodedData(options: [
            .lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed
        ]), contentDisposition: .attachment(.init(filename: attachment.name, size: attachment.data.count)),
            contentTransferEncoding: .base64, contentType: try MIME.ContentType(attachment.contentType))
        parts.append(part)
    }
    let result = try MIME.Body(part: MIME.Part(parts: parts, contentType: .multipart(.mixed)))
    guard result.part.data.count <= maximumOutgoingMessageBytes - 65536 else { throw SMTPError.invalidMessage }
    return result
}

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
