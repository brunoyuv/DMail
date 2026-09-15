// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import NIOIMAP

/// A small inline text leaf, selected without fetching attachments or raw MIME.
public struct PreviewSample: Sendable {
    public let section: SectionSpecifier
    public let header: Data
    public let encoding: String
    public static let byteLimit = 2048

    public static func select(_ structure: BodyStructure) -> Self? {
        var candidates: [(Self, Bool)] = [], remaining = 512
        func visit(_ node: BodyStructure, path: [Int], depth: Int) {
            guard depth < 32, remaining > 0 else { return }
            remaining -= 1
            switch node {
            case .multipart(let part):
                guard part.extension?.dispositionAndLanguage?.disposition?.kind.rawValue.lowercased() != "attachment" else { return }
                for (index, child) in part.parts.enumerated() { visit(child, path: path + [index + 1], depth: depth + 1) }
            case .singlepart(let part):
                guard part.extension?.dispositionAndLanguage?.disposition?.kind.rawValue.lowercased() != "attachment",
                      case .text(let text) = part.kind, part.fields.octetCount > 0 else { return }
                let subtype = text.mediaSubtype.debugDescription.lowercased()
                guard ["plain", "html"].contains(subtype) else { return }
                let charset = part.fields.parameters.first(where: { $0.key.lowercased() == "charset" })?.value ?? "utf-8"
                let encoding = part.fields.encoding?.debugDescription.lowercased() ?? "7bit"
                guard charset.utf8.count <= 80, !charset.isEmpty,
                      charset.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }),
                      ["7bit", "8bit", "binary", "base64", "quoted-printable"].contains(encoding) else { return }
                let header = Data("Content-Type: text/\(subtype); charset=\"\(charset)\"\r\nContent-Transfer-Encoding: \(encoding)\r\n\r\n".utf8)
                candidates.append((Self(section: .init(part: .init(path.isEmpty ? [1] : path)), header: header, encoding: encoding), subtype == "plain"))
            }
        }
        visit(structure, path: [], depth: 0)
        return candidates.first(where: { $0.1 })?.0 ?? candidates.first?.0
    }

    public func mime(_ sample: Data) -> Data? {
        guard !sample.isEmpty, sample.count <= Self.byteLimit else { return nil }
        var bytes = sample
        if encoding == "base64" {
            bytes = Data(bytes.filter { ![9, 10, 13, 32].contains($0) })
            // A partial fetch can end in the middle of an encoded quartet.
            bytes = bytes.prefix(bytes.count - bytes.count % 4)
        } else if encoding == "quoted-printable" {
            if let equal = bytes.lastIndex(of: 61), bytes.distance(from: equal, to: bytes.endIndex) <= 2 {
                bytes = bytes.prefix(upTo: equal)
            }
        }
        return header + bytes
    }

    // Hitting the sample limit may split a charset codepoint even after the
    // transfer quartet/escape is complete. Let the original strict decoder try
    // a few shorter tails; never replace bytes or guess a different charset.
    public func candidates(_ sample: Data) -> [Data] {
        guard !sample.isEmpty, sample.count <= Self.byteLimit else { return [] }
        return (0...(sample.count == Self.byteLimit ? 12 : 0)).compactMap { trim in
            mime(Data(sample.dropLast(trim)))
        }
    }
}
