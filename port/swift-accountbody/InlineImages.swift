// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import MIME

// Rewrite complete resource references, never a substring of visible prose,
// another URL, a comment or an already expanded data URI. Each caller supplies
// the resources selected by its MIME branch, not the whole message's attachments.
private enum ImageMarkup {
    static let attributes = try! NSRegularExpression(pattern: #"(?<![^\s=/'"<>])([^\s=/'"<>]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s'"=<>`]+))"#)
    static let name = try! NSRegularExpression(pattern: #"^<\s*([A-Za-z][\w:-]*)"#)
    static let imageType = try! NSRegularExpression(pattern: #"^[A-Za-z0-9][A-Za-z0-9.+-]{0,127}$"#)

    struct Token {
        let range: NSRange
        let complete: Bool
        let rawElement: String?
    }
    struct CSSReference {
        let range: NSRange
        let reference: NSRange
    }
    private static func space(_ unit: unichar) -> Bool { [9, 10, 12, 13, 32].contains(unit) }
    private static func asciiLower(_ unit: unichar) -> unichar { (65...90).contains(unit) ? unit + 32 : unit }
    private static let commentStart: [unichar] = [60, 33, 45, 45]
    private static let cssCommentStart: [unichar] = [47, 42]
    private static let urlStart: [unichar] = [117, 114, 108]
    private static func starts(_ source: NSString, at position: Int, with units: [unichar]) -> Bool {
        guard position + units.count <= source.length else { return false }
        return units.indices.allSatisfy { asciiLower(source.character(at: position + $0)) == units[$0] }
    }

    // A failed regex token can restart at every '<' in one malformed suffix.
    // Keep one forward cursor instead; unterminated quotes/comments stay literal
    // and are consumed once, while well-formed raw elements remain opaque.
    static func tokens(_ source: NSString, rawElements: Set<String> = ["script", "style", "textarea", "title"]) -> [Token] {
        var result: [Token] = [], position = 0
        while position < source.length {
            let start = position
            if source.character(at: position) != 60 {
                repeat { position += 1 } while position < source.length && source.character(at: position) != 60
                result.append(Token(range: NSRange(location: start, length: position - start), complete: false, rawElement: nil))
                continue
            }
            if starts(source, at: position, with: commentStart) {
                let close = source.range(of: "-->", range: NSRange(location: position + 4, length: source.length - position - 4))
                position = close.location == NSNotFound ? source.length : NSMaxRange(close)
                result.append(Token(range: NSRange(location: start, length: position - start), complete: false, rawElement: nil))
                continue
            }
            position += 1
            var quote: unichar?, complete = false
            while position < source.length {
                let unit = source.character(at: position)
                if let expected = quote {
                    if unit == expected { quote = nil }
                } else if unit == 34 || unit == 39 { quote = unit }
                else if unit == 62 { position += 1; complete = true; break }
                else if unit == 60 { break }
                position += 1
            }
            var raw: String?
            if complete {
                var end = start + 1
                while end < position {
                    let unit = asciiLower(source.character(at: end))
                    if !(97...122).contains(unit) { break }
                    end += 1
                }
                let tag = source.substring(with: NSRange(location: start + 1, length: end - start - 1)).lowercased()
                if rawElements.contains(tag),
                   end < position && (space(source.character(at: end)) || [47, 62].contains(source.character(at: end))) {
                    raw = tag
                    var closing = position
                    while closing < source.length {
                        let match = source.range(of: "</" + tag, options: .caseInsensitive,
                            range: NSRange(location: closing, length: source.length - closing))
                        if match.location == NSNotFound { closing = source.length; break }
                        closing = NSMaxRange(match)
                        while closing < source.length && space(source.character(at: closing)) { closing += 1 }
                        if closing < source.length && source.character(at: closing) == 62 { closing += 1; break }
                    }
                    position = closing
                }
            }
            result.append(Token(range: NSRange(location: start, length: position - start), complete: complete, rawElement: raw))
        }
        return result
    }

    // Quoted strings and comments are opaque. An invalid url() candidate also
    // advances past the bytes already inspected, so nested unfinished calls do
    // not repeatedly scan the remaining style block.
    static func cssReferences(_ source: NSString) -> [CSSReference] {
        var result: [CSSReference] = [], position = 0
        func skipString(_ index: inout Int, quote: unichar) -> Bool {
            index += 1
            var escaped = false
            while index < source.length {
                let unit = source.character(at: index); index += 1
                if unit == 92 { escaped = true; if index < source.length { index += 1 } }
                else if unit == quote { return !escaped }
            }
            return false
        }
        while position < source.length {
            let unit = source.character(at: position)
            if unit == 34 || unit == 39 { _ = skipString(&position, quote: unit); continue }
            if starts(source, at: position, with: cssCommentStart) {
                let close = source.range(of: "*/", range: NSRange(location: position + 2, length: source.length - position - 2))
                position = close.location == NSNotFound ? source.length : NSMaxRange(close)
                continue
            }
            let previous = position > 0 ? source.character(at: position - 1) : 0
            let word = previous >= 128 || (48...57).contains(previous) || (65...90).contains(previous) ||
                (97...122).contains(previous) || previous == 95 || previous == 45
            guard !word && starts(source, at: position, with: urlStart) else { position += 1; continue }
            let start = position
            position += 3
            while position < source.length && space(source.character(at: position)) { position += 1 }
            guard position < source.length && source.character(at: position) == 40 else { continue }
            position += 1
            while position < source.length && space(source.character(at: position)) { position += 1 }
            guard position < source.length else { break }
            let referenceStart: Int, referenceEnd: Int
            let first = source.character(at: position)
            if first == 34 || first == 39 {
                referenceStart = position + 1
                guard skipString(&position, quote: first) else { continue }
                referenceEnd = position - 1
            } else {
                referenceStart = position
                while position < source.length {
                    let value = source.character(at: position)
                    if space(value) || [40, 41, 34, 39, 92].contains(value) { break }
                    position += 1
                }
                referenceEnd = position
            }
            while position < source.length && space(source.character(at: position)) { position += 1 }
            guard position < source.length && source.character(at: position) == 41 else { continue }
            position += 1
            result.append(CSSReference(range: NSRange(location: start, length: position - start),
                reference: NSRange(location: referenceStart, length: referenceEnd - referenceStart)))
        }
        return result
    }

    static func mediaType(_ attachment: EmailAttachment) -> String? {
        if case .image(let subtype) = attachment.contentType,
           imageType.firstMatch(in: subtype, range: range(subtype as NSString)) != nil { return "image/" + subtype }
        guard case .application(let subtype) = attachment.contentType,
              ["octet-stream", "binary"].contains(subtype.lowercased()) else { return nil }
        let bytes = Array(attachment.data.prefix(12))
        if bytes.starts(with: [137,80,78,71,13,10,26,10]) { return "image/png" }
        if bytes.starts(with: [255,216,255]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
        if bytes.count == 12 && bytes.starts(with: Array("RIFF".utf8)) && Array(bytes[8...11]) == Array("WEBP".utf8) { return "image/webp" }
        return nil
    }
    static func range(_ value: NSString) -> NSRange { NSRange(location: 0, length: value.length) }
    static func captured(_ match: NSTextCheckingResult, in value: NSString, from: Int, through: Int) -> NSRange? {
        for index in from...through where match.range(at: index).location != NSNotFound { return match.range(at: index) }
        return nil
    }
    static func canonical(_ value: String, base: String?) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("cid:") {
            let id = String(trimmed.dropFirst(4))
            return "cid:" + (id.removingPercentEncoding ?? id)
        }
        if let base, let origin = URL(string: base), let url = URL(string: trimmed, relativeTo: origin) {
            return url.absoluteURL.absoluteString
        }
        return trimmed
    }
    static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func prefix(_ text: NSString, units: Int) -> String {
        var end = min(max(0, units), text.length)
        if end > 0 && end < text.length && (0xD800...0xDBFF).contains(text.character(at: end - 1)) &&
            (0xDC00...0xDFFF).contains(text.character(at: end)) { end -= 1 }
        return text.substring(to: end)
    }
}

extension String {
    // The native preview and HTML picture renderer share a forward token walk.
    // Preview-only head/template/style/script removal must not restart a regex
    // over every unfinished opening tag in the same suffix.
    func removingMailPreviewBlocks() -> String {
        let source = self as NSString
        var result = ""
        result.reserveCapacity(utf8.count)
        for token in ImageMarkup.tokens(source, rawElements: ["head", "style", "script", "template"]) {
            if token.rawElement != nil { result += " " }
            else { result += source.substring(with: token.range) }
        }
        return result
    }

    // The UTF-16 budget bounds both copies and base64 expansion. Whole markup
    // tokens are kept or omitted; a data URI is never cut in the middle.
    func inliningImages(attachments: [EmailAttachment], limit: Int, baseLocation: String? = nil) -> (html: String, truncated: Bool) {
        let source = self as NSString, limit = max(0, limit)
        var base = baseLocation, links: [String: Int] = [:], ambiguous = Set<String>(), encoded: [Int: String] = [:], mediaTypes: [Int: String] = [:]
        let tokens = ImageMarkup.tokens(source)
        // An authored base is used only to compare inline references. It grants
        // no browser or network permission and is not copied into a new URL.
        for token in tokens {
            let value = source.substring(with: token.range) as NSString
            guard token.complete, token.rawElement == nil, let name = ImageMarkup.name.firstMatch(in: value as String, range: ImageMarkup.range(value)),
                  value.substring(with: name.range(at: 1)).lowercased() == "base" else { continue }
            for attr in ImageMarkup.attributes.matches(in: value as String, range: ImageMarkup.range(value)) {
                guard value.substring(with: attr.range(at: 1)).lowercased() == "href",
                      let range = ImageMarkup.captured(attr, in: value, from: 2, through: 4) else { continue }
                let candidate = ImageMarkup.canonical(value.substring(with: range).htmlEntitiesDecoded(), base: baseLocation)
                if let url = URL(string: candidate), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil { base = candidate }
                break
            }
            break
        }
        for (index, attachment) in attachments.enumerated() {
            guard let mediaType = ImageMarkup.mediaType(attachment) else { continue }
            mediaTypes[index] = mediaType
            for link in attachment.links {
                let key = ImageMarkup.canonical(link, base: baseLocation)
                if let existing = links[key], existing != index { ambiguous.insert(key) }
                else { links[key] = index }
            }
        }
        var remaining = limit, expansionBudget = 0, truncated = false, output = ""
        output.reserveCapacity(min(source.length, limit))
        func imageURL(_ reference: String) -> String? {
            let key = ImageMarkup.canonical(reference, base: base)
            guard !ambiguous.contains(key), let index = links[key] else { return nil }
            let attachment = attachments[index]
            let prefix = "data:\(mediaTypes[index]!);base64,"
            let size = prefix.utf16.count + ((attachment.data.count + 2) / 3) * 4
            // Reserve each occurrence before creating or copying a data URI.
            // A source tag with many repeated images cannot multiply the cap.
            let growth = max(0, size - reference.utf16.count) + 64
            guard growth <= expansionBudget else { truncated = true; return nil }
            expansionBudget -= growth
            if let cached = encoded[index] { return cached }
            let value = prefix + attachment.data.base64EncodedString()
            encoded[index] = value
            return value
        }
        func rewriteCSS(_ css: String) -> String {
            let original = css as NSString, result = NSMutableString(string: css)
            for token in ImageMarkup.cssReferences(original).reversed() {
                guard let uri = imageURL(original.substring(with: token.reference)) else { continue }
                result.replaceCharacters(in: token.range, with: "url(\"\(uri)\")")
            }
            return result as String
        }
        func rewriteSources(_ sources: String) -> String {
            let original = sources as NSString, result = NSMutableString(string: sources)
            var index = 0, replacements: [(NSRange, String)] = []
            func space(_ unit: unichar) -> Bool { [9, 10, 12, 13, 32].contains(unit) }
            while index < original.length {
                while index < original.length && (space(original.character(at: index)) || original.character(at: index) == 44) { index += 1 }
                let start = index
                while index < original.length && !space(original.character(at: index)) { index += 1 }
                var end = index
                while end > start && original.character(at: end - 1) == 44 { end -= 1 }
                if end > start {
                    let range = NSRange(location: start, length: end - start)
                    if let uri = imageURL(original.substring(with: range)) { replacements.append((range, uri)) }
                }
                if end < index { continue }
                var depth = 0
                while index < original.length {
                    let unit = original.character(at: index); index += 1
                    if unit == 40 { depth += 1 }; if unit == 41 { depth = max(0, depth - 1) }
                    if unit == 44 && depth == 0 { break }
                }
            }
            for (range, value) in replacements.reversed() { result.replaceCharacters(in: range, with: value) }
            return result as String
        }
        for token in tokens {
            guard remaining > 0 else { truncated = true; break }
            let original = source.substring(with: token.range), text = original as NSString
            var rendered = original
            expansionBudget = max(0, remaining - text.length)
            if let raw = token.rawElement {
                if raw == "style", let start = original.firstIndex(of: ">") {
                    let content = original.index(after: start)
                    let end = original.range(of: "</style", options: [.caseInsensitive, .backwards])?.lowerBound ?? original.endIndex
                    rendered = String(original[..<content]) + rewriteCSS(String(original[content..<end])) + String(original[end...])
                }
            } else if token.complete, let match = ImageMarkup.name.firstMatch(in: original, range: ImageMarkup.range(text)) {
                let element = text.substring(with: match.range(at: 1)).lowercased(), changed = NSMutableString(string: original)
                for attr in ImageMarkup.attributes.matches(in: original, range: ImageMarkup.range(text)).reversed() {
                    guard let range = ImageMarkup.captured(attr, in: text, from: 2, through: 4) else { continue }
                    let name = text.substring(with: attr.range(at: 1)).lowercased(), value = text.substring(with: range).htmlEntitiesDecoded()
                    let replacement: String?
                    if name == "style" { replacement = rewriteCSS(value) }
                    else if name == "srcset" && ["img", "source"].contains(element) { replacement = rewriteSources(value) }
                    else if (name == "src" && ["img", "source"].contains(element)) ||
                        (name == "background" && ["body", "table", "td", "th", "div"].contains(element)) ||
                        (["href", "xlink:href"].contains(name) && element == "image") { replacement = imageURL(value) }
                    else { replacement = nil }
                    if let replacement, replacement != value {
                        changed.replaceCharacters(in: attr.range, with: "\(name)=\"\(ImageMarkup.escaped(replacement))\"")
                    }
                }
                rendered = changed as String
            }
            let units = rendered.utf16.count
            if units <= remaining { output += rendered; remaining -= units }
            else {
                truncated = true
                if !original.hasPrefix("<") {
                    let prefix = ImageMarkup.prefix(rendered as NSString, units: remaining)
                    output += prefix; remaining -= prefix.utf16.count
                }
            }
        }
        return (output, truncated)
    }
}
