// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation

// Preserve reply ancestry before the MIME body decoder discards non-MIME headers.
// Read only a bounded header prefix, never parse nested message/attachment headers.
func replyReferences(_ data: Data) -> [String] {
    let text = String(decoding: data.prefix(65_536), as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
    guard let end = text.range(of: "\n\n") else { return [] }
    var fields = [String]()
    for line in text[..<end.lowerBound].components(separatedBy: "\n") {
        if (line.hasPrefix(" ") || line.hasPrefix("\t")), !fields.isEmpty { fields[fields.count - 1] += " " + line.trimmingCharacters(in: .whitespaces) }
        else { fields.append(line) }
    }
    let references = fields.filter { $0.prefix(11).lowercased() == "references:" }
    guard references.count == 1 else { return [] }
    var ids = [String](), current: String?, depth = 0, escaped = false
    for character in references[0].dropFirst(11) {
        if depth > 0 {
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "(" { depth += 1 }
            else if character == ")" { depth -= 1 }
            continue
        }
        if current == nil && character == "(" { depth = 1; continue }
        if character == "<" { current = "" }
        else if character == ">", let id = current {
            if !id.isEmpty && id.utf8.count <= 900 { ids.append(id) }
            current = nil
        } else if current != nil { current?.append(character) }
    }
    return ids.count <= 100 ? ids : [ids[0]] + ids.suffix(99)
}
