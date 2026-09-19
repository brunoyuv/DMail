// MPL-2.0: https://mozilla.org/MPL/2.0/
// Byte-preserving parsing adapter for Thunderbird's MIME Part model.
import Foundation

// Diagnostic callback carries only fixed categories and numeric structural data.
// It never changes parsing behavior or exposes field values/body bytes.
public enum MimeDiagnosticReason: String, Sendable {
    case inputTooLarge, separatorMissing, headerTooLarge, duplicateHeader, contentTypeInvalid, parsed
}
public enum MimeDiagnostics {
    @TaskLocal public static var sink: (@Sendable (MimeDiagnosticReason, Int, Int) -> Void)?
}

struct ParsedPart {
    let data: Data
    let disposition: ContentDisposition?
    let transfer: ContentTransferEncoding?
    let id: ContentID?
    let location: String?
    let type: ContentType
    let parameters: [String: String]
}
func parsePart(_ data: Data) throws -> ParsedPart {
    guard data.count <= 8 * 1024 * 1024 else { MimeDiagnostics.sink?(.inputTooLarge, data.count, 0); throw MIMEError.dataNotFound }
    let separator = data.range(of: Data([13, 10, 13, 10])) ?? data.range(of: Data([10, 10]))
    guard let separator else { MimeDiagnostics.sink?(.separatorMissing, data.count, 0); throw MIMEError.dataNotFound }
    guard separator.lowerBound - data.startIndex <= 65536 else { MimeDiagnostics.sink?(.headerTooLarge, separator.lowerBound - data.startIndex, 0); throw MIMEError.dataNotFound }
    let text = String(decoding: data[..<separator.lowerBound], as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
    var unfolded: [String] = []
    for line in text.components(separatedBy: "\n") {
        if (line.hasPrefix(" ") || line.hasPrefix("\t")), !unfolded.isEmpty {
            unfolded[unfolded.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
        } else { unfolded.append(line) }
    }
    var fields: [String: String] = [:]
    for line in unfolded {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = line[..<colon].lowercased()
        guard ["content-type", "content-transfer-encoding", "content-disposition", "content-id", "content-location"].contains(name) else { continue }
        guard fields[name] == nil else {
            let index = ["content-type", "content-transfer-encoding", "content-disposition", "content-id", "content-location"].firstIndex(of: name) ?? 5
            MimeDiagnostics.sink?(.duplicateHeader, index + 1, unfolded.count); throw MIMEError.dataNotFound
        }
        fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let type: ContentType
    do { type = try fields["content-type"].map { try ContentType($0) } ?? .text(.plain, .ascii) }
    catch { MimeDiagnostics.sink?(.contentTypeInvalid, fields["content-type"]?.utf8.count ?? 0, 0); throw error }
    let flags = (fields["content-type"] != nil ? 1 : 0) | (fields["content-transfer-encoding"] != nil ? 2 : 0) |
        (fields["content-id"] != nil ? 4 : 0) | (fields["content-disposition"] != nil ? 8 : 0) | (fields["content-location"] != nil ? 16 : 0)
    MimeDiagnostics.sink?(.parsed, separator.lowerBound - data.startIndex, flags)
    return ParsedPart(data: Data(data[separator.upperBound...]),
                      disposition: AttachmentFilename.disposition(fields["content-disposition"], contentType: fields["content-type"]),
                      transfer: fields["content-transfer-encoding"].flatMap { ContentTransferEncoding(rawValue: $0.lowercased()) },
                      id: fields["content-id"].map { ContentID($0) }, location: fields["content-location"], type: type,
                      parameters: fields["content-type"]?.parameters ?? [:])
}
func splitMultipart(_ data: Data, boundary: String) throws -> [Data] {
    let marker = Data("--\(boundary)".utf8)
    var parts: [Data] = [], start: Int?, lineStart = data.startIndex
    while lineStart < data.endIndex {
        let lineEnd = data[lineStart...].firstIndex(of: 10) ?? data.endIndex
        var end = lineEnd
        while end > lineStart && [UInt8(13), 32, 9].contains(data[end - 1]) { end -= 1 }
        let line = Data(data[lineStart..<end])
        if line == marker || line == marker + Data([45, 45]) {
            if let start {
                var bodyEnd = lineStart
                if bodyEnd > start && data[bodyEnd - 1] == 10 { bodyEnd -= 1 }
                if bodyEnd > start && data[bodyEnd - 1] == 13 { bodyEnd -= 1 }
                guard parts.count < 512 else { throw MIMEError.dataNotFound }
                // An empty MIME payload still needs its header/body separator.
                // The newline before the boundary can be that separator's last line.
                let untrimmed = Data(data[start..<lineStart])
                let trimmed = Data(data[start..<bodyEnd])
                let separators = [Data([13, 10, 13, 10]), Data([10, 10])]
                parts.append(!separators.contains(where: { trimmed.range(of: $0) != nil }) &&
                    separators.contains(where: { untrimmed.range(of: $0) != nil }) ? untrimmed : trimmed)
            }
            if line != marker {
                guard !parts.isEmpty else { throw MIMEError.dataNotFound }
                return parts
            }
            start = lineEnd < data.endIndex ? lineEnd + 1 : lineEnd
        }
        lineStart = lineEnd < data.endIndex ? lineEnd + 1 : lineEnd
    }
    throw MIMEError.dataNotFound
}
