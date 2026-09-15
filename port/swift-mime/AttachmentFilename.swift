// MPL-2.0: https://mozilla.org/MPL/2.0/
import CoreFoundation
import Foundation

/// Decode MIME filename parameters once, before they reach cache or file APIs.
/// RFC 2231 segments are joined as bytes before decoding the declared charset.
public enum AttachmentFilename {
    static func serialized(_ filename: String) -> String {
        if filename.utf8.allSatisfy({ (32...126).contains($0) }) {
            return "filename=\"" + filename.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return "filename*=utf-8''" + filename.utf8.map { String(format: "%%%02X", $0) }.joined()
    }

    public static func decode(disposition: [String: String], contentType: [String: String]) -> String? {
        value(disposition, key: "filename") ?? value(contentType, key: "name")
    }

    public static func disposition(_ header: String?, contentType: String?) -> ContentDisposition? {
        let original = header.flatMap { ContentDisposition(rawValue: $0) }
        guard let name = decode(disposition: parameters(header ?? ""), contentType: parameters(contentType ?? "")) else { return original }
        let old = original?.file
        let file = ContentDisposition.File(filename: name, creationDate: old?.creationDate,
            modificationDate: old?.modificationDate, readDate: old?.readDate, size: old?.size)
        switch original {
        case .attachment: return .attachment(file)
        case .inline, nil: return .inline(file)
        case .extensionToken: return original
        }
    }

    /// Parameter quoted strings can contain semicolons and escaped quotes.
    /// This parser is deliberately local to filenames; body charset/boundary
    /// parsing keeps its existing behavior.
    static func parameters(_ header: String) -> [String: String] {
        guard header.utf8.count <= 65536 else { return [:] }
        var pieces: [String] = [], current = "", quoted = false, escaped = false
        for character in header {
            if escaped { current.append(character); escaped = false }
            else if quoted && character == "\\" { current.append(character); escaped = true }
            else if character == "\"" { current.append(character); quoted.toggle() }
            else if character == ";" && !quoted { pieces.append(current); current = "" }
            else { current.append(character) }
        }
        if !quoted { pieces.append(current) }
        var result: [String: String] = [:], duplicates: Set<String> = []
        for piece in pieces {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                var unquoted = "", escape = false
                for character in value {
                    if escape { unquoted.append(character); escape = false }
                    else if character == "\\" { escape = true }
                    else { unquoted.append(character) }
                }
                if escape { continue }
                value = unquoted
            }
            if result[key] != nil { duplicates.insert(key) }
            result[key] = value
        }
        for key in duplicates { result.removeValue(forKey: key) }
        return result
    }

    static func value(_ input: [String: String], key: String) -> String? {
        var values: [String: String] = [:], duplicates: Set<String> = []
        for (name, value) in input {
            let name = name.lowercased()
            if values[name] != nil { duplicates.insert(name) }
            values[name] = value
        }
        for name in duplicates { values.removeValue(forKey: name) }
        if let extended = values[key + "*"], let decoded = decodeSegments([(extended, true)]), !decoded.isEmpty { return decoded }
        var segments: [Int: (String, Bool)] = [:], invalid = false
        for (name, value) in values where name.hasPrefix(key + "*") && name != key + "*" {
            var suffix = String(name.dropFirst(key.count + 1))
            let encoded = suffix.hasSuffix("*")
            if encoded { suffix.removeLast() }
            guard let index = Int(suffix), index >= 0, index < 64, String(index) == suffix,
                  segments[index] == nil else { invalid = true; continue }
            segments[index] = (value, encoded)
        }
        if !invalid, !segments.isEmpty, segments.count <= 64,
           (0..<segments.count).allSatisfy({ segments[$0] != nil }),
           let decoded = decodeSegments((0..<segments.count).compactMap { segments[$0] }), !decoded.isEmpty { return decoded }
        guard let plain = values[key], !plain.isEmpty, plain.utf8.count <= 16384 else { return nil }
        // Encoded words are not legal RFC 2231 parameters, but are emitted by
        // existing mail clients. Reuse the tolerant header decoder for these.
        return HeaderDecoding.decode(plain)
    }

    private static func decodeSegments(_ segments: [(String, Bool)]) -> String? {
        guard !segments.isEmpty else { return nil }
        if !segments.contains(where: { $0.1 }) {
            let text = segments.map { $0.0 }.joined()
            return text.utf8.count <= 16384 ? HeaderDecoding.decode(text) : nil
        }
        var bytes = Data(), charset = ""
        for (index, segment) in segments.enumerated() {
            var text = segment.0
            guard text.utf8.count <= 16384 else { return nil }
            if index == 0 && segment.1 {
                let fields = text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count == 3 else { return nil }
                charset = String(fields[0]); text = String(fields[2])
            }
            if segment.1 {
                guard let decoded = percentBytes(text) else { return nil }
                bytes.append(decoded)
            } else { bytes.append(contentsOf: text.utf8) }
            guard bytes.count <= 16384 else { return nil }
        }
        // A missing charset has no implied legacy encoding. Preserve valid
        // UTF-8/ASCII only; never repair unknown bytes by lossy reinterpretation.
        if charset.isEmpty || ["utf-8", "utf8"].contains(charset.lowercased()) { return String(data: bytes, encoding: .utf8) }
        let name = CFStringCreateWithCString(nil, charset, CFStringBuiltInEncodings.UTF8.rawValue)
        let value = CFStringConvertIANACharSetNameToEncoding(name)
        guard value != kCFStringEncodingInvalidId else { return nil }
        return String(data: bytes, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(value)))
    }

    private static func percentBytes(_ text: String) -> Data? {
        let source = Array(text.utf8)
        var bytes = Data(), index = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        while index < source.count {
            if source[index] == 37 {
                guard index + 2 < source.count, let high = hex(source[index + 1]), let low = hex(source[index + 2]) else { return nil }
                bytes.append(high * 16 + low); index += 3
            } else { bytes.append(source[index]); index += 1 }
        }
        return bytes
    }
}
