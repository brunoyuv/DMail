// MPL-2.0: https://mozilla.org/MPL/2.0/
// Use the original IMAP client and NIO body structure to fetch readable MIME parts,
// without downloading PDF/other attachments merely to display the message.
import Foundation
import MIME
import NIOIMAPCore

public struct ReadablePart: Sendable {
    public let section: SectionSpecifier
    public let octets: Int
}
public struct AttachmentPart: Sendable {
    public let id: String, name: String, contentType: String
    public let section: SectionSpecifier
    public let encodedSize: Int
}
public struct ReadablePlan: Sendable {
    private let structure: BodyStructure
    public private(set) var metadataSections: [SectionSpecifier] = []
    public var parts: [ReadablePart] = []
    public var attachments: [AttachmentPart] = []
    public var hasAttachments = false
    public var partial = false
    public init(_ structure: BodyStructure) throws {
        self.structure = structure
        var remaining = 512, budget = 6 * 1024 * 1024
        try visit(structure, path: [], depth: 0, remaining: &remaining, budget: &budget)
    }
    private mutating func visit(_ structure: BodyStructure, path: [Int], depth: Int,
                                remaining: inout Int, budget: inout Int, relatedRoot: Bool = false) throws {
        guard remaining > 0, depth < 32 else { throw IMAPError.unexpectedResponse("Body structure exceeds limits") }
        remaining -= 1
        switch structure {
        case .multipart(let multi):
            if !relatedRoot && multi.extension?.dispositionAndLanguage?.disposition?.kind.rawValue.lowercased() == "attachment" {
                hasAttachments = true; return
            }
            let related = multi.mediaSubtype == .init("related")
            var relatedRoots: Set<Int> = []
            if related, let start = multi.extension?.parameters.first(where: { $0.key.lowercased() == "start" })?.value {
                let wanted = Self.identifier(start)
                let matches = multi.parts.indices.filter {
                    if case .singlepart(let leaf) = multi.parts[$0] { return leaf.fields.id.map(Self.identifier) == wanted }
                    return false
                }
                if matches.count == 1 { relatedRoots.insert(matches[0]) }
                if matches.isEmpty {
                    // BODYSTRUCTURE omits multipart Content-ID. Fetch only the
                    // direct container MIME headers needed to resolve start;
                    // never guess a multipart root from its position.
                    for (index, child) in multi.parts.enumerated() {
                        if case .multipart = child {
                            guard metadataSections.count < 32 else { throw IMAPError.unexpectedResponse("Related metadata exceeds limits") }
                            metadataSections.append(.init(part: .init(path + [index + 1]), kind: .MIMEHeader))
                            relatedRoots.insert(index)
                        }
                    }
                }
            } else if related {
                relatedRoots.insert(0)
                if let first = multi.parts.first, case .singlepart(let leaf) = first,
                   case .basic(let media) = leaf.kind, media.topLevel == .image,
                   let declared = multi.extension?.parameters.first(where: { $0.key.lowercased() == "type" })?.value.lowercased() {
                    let matches = multi.parts.indices.filter {
                        switch multi.parts[$0] {
                        case .singlepart(let part):
                            if case .text(let text) = part.kind { return "text/\(text.mediaSubtype.debugDescription)" == declared && ["text/html", "text/plain"].contains(declared) }
                            return false
                        case .multipart(let part):
                            return "multipart/\(part.mediaSubtype.debugDescription)" == declared && ["multipart/related", "multipart/alternative"].contains(declared)
                        }
                    }
                    if matches.count == 1 { relatedRoots = Set(matches) }
                }
            }
            for (index, part) in multi.parts.enumerated() {
                try visit(part, path: path + [index + 1], depth: depth + 1, remaining: &remaining, budget: &budget, relatedRoot: relatedRoots.contains(index))
            }
        case .singlepart(let part):
            let disposition = part.extension?.dispositionAndLanguage?.disposition
            let attached = disposition?.kind.rawValue.lowercased() == "attachment"
            let location = part.extension?.dispositionAndLanguage?.language?.location?.location
            let referencedImage: Bool
            if case .basic(let media) = part.kind { referencedImage = (media.topLevel == .image ||
                (media.topLevel == .application && [Media.Subtype("octet-stream"), Media.Subtype("binary")].contains(media.sub))) &&
                (part.fields.id != nil || location != nil) }
            else { referencedImage = false }
            let readable: Bool
            switch part.kind {
            case .text(let text): readable = [Media.Subtype("plain"), Media.Subtype("html")].contains(text.mediaSubtype)
            case .basic: readable = referencedImage
            case .message: readable = false
            }
            if attached || (!readable && !referencedImage) {
                hasAttachments = true
                guard attachments.count < 64 else { partial = true; return }
                let components = path.isEmpty ? [1] : path
                let parameters = disposition?.parameters ?? [:]
                let name = AttachmentFilename.decode(
                    disposition: Dictionary(uniqueKeysWithValues: parameters.map { ($0.key, $0.value) }),
                    contentType: Dictionary(uniqueKeysWithValues: part.fields.parameters.map { ($0.key, $0.value) })) ?? ""
                let type: String
                switch part.kind {
                case .basic(let media): type = "\(media.topLevel.debugDescription)/\(media.sub.debugDescription)"
                case .text(let text): type = "text/\(text.mediaSubtype.debugDescription)"
                case .message: type = "message/rfc822"
                }
                attachments.append(AttachmentPart(id: components.map(String.init).joined(separator: "."),
                    name: String(name.prefix(512)), contentType: type, section: .init(part: .init(components)), encodedSize: part.fields.octetCount))
                if !referencedImage && !(relatedRoot && readable) { return }
            }
            if !readable { return }
            let size = part.fields.octetCount
            guard size >= 0, size <= 4 * 1024 * 1024, size <= budget, parts.count < 24 else { partial = true; return }
            budget -= size
            parts.append(ReadablePart(section: SectionSpecifier(part: .init(path.isEmpty ? [1] : path)), octets: size))
        }
    }
    private static func identifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }

    /// Rebuild the pruned MIME tree from the original section headers/data.
    /// Keeping container types and child positions is necessary for related
    /// root selection and alternative-local CID resolution in EmailBody.
    public func assemble(_ sections: [SectionSpecifier: Data], metadata: [SectionSpecifier: Data] = [:]) throws -> MIME.Body? {
        guard !parts.isEmpty else { return nil }
        func omitted() -> MIME.Part { MIME.Part(data: Data(), contentType: .application("x-dmail-omitted")) }
        func build(_ node: BodyStructure, path: [Int]) throws -> MIME.Part {
            switch node {
            case .singlepart:
                let section = SectionSpecifier(part: .init(path.isEmpty ? [1] : path))
                guard let data = sections[section] else { return omitted() }
                return try MIME.Part(data)
            case .multipart(let multi):
                if multi.extension?.dispositionAndLanguage?.disposition?.kind.rawValue.lowercased() == "attachment" &&
                    !parts.contains(where: { Array($0.section.part).starts(with: path) }) { return omitted() }
                let children = try multi.parts.enumerated().map { try build($0.element, path: path + [$0.offset + 1]) }
                let parameters = (multi.extension?.parameters.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }) ?? [:]
                let type = ContentType.multipart(multi.mediaSubtype.debugDescription)
                let assembled = try MIME.Part(parts: children, contentType: type)
                let actual: MIME.Part?
                if path.isEmpty { actual = nil }
                else {
                    let header = SectionSpecifier(part: .init(path), kind: .MIMEHeader)
                    actual = try metadata[header].map { try MIME.Part($0) }
                }
                return MIME.Part(data: assembled.data, contentID: actual?.contentID, contentType: type,
                    contentLocation: actual?.contentLocation ?? multi.extension?.dispositionAndLanguage?.language?.location?.location,
                    contentTypeParameters: parameters)
            }
        }
        let body = try MIME.Body(part: build(structure, path: []))
        guard body.part.data.count < 8 * 1024 * 1024 else { throw IMAPError.unexpectedResponse("Readable body exceeds limits") }
        return body
    }

}
public struct ReadableMessage: Sendable {
    public let message: Message
    public let body: MIME.Body?
    public let hasAttachments: Bool
    public let partial: Bool
    public let attachments: [AttachmentPart]
}
// Other messages' unsolicited FLAGS may arrive during a UID FETCH. Select
// only the explicit requested UID, rejecting ambiguous duplicate identities.
func readableFetchTarget(_ messages: MessageSet, uid: UID) throws -> Message {
    let matching = messages.values.filter { $0.uid == uid }
    guard matching.count == 1, let message = matching.first else {
        throw IMAPError.unexpectedResponse("Mismatched UID")
    }
    return message
}
extension IMAPClient {
    public func fetchReadable(uid: UID) async throws -> ReadableMessage? {
        let ids = UIDSet(uid)
        let initial = try await fetch(uid: ids, attributes: [.bodyStructure(extensions: true),
            .bodySection(peek: true, .headerFields(["References"]), nil)] + .standard)
        guard !initial.isEmpty else { return nil }
        let message = try readableFetchTarget(initial, uid: uid)
        guard let structure = message.bodyStructure else {
            // Some older servers omit BODYSTRUCTURE. Retain the bounded original path.
            let full = try await fetch(uid: uid, attributes: .complete)
            guard full.uid == uid else { throw IMAPError.unexpectedResponse("Mismatched UID") }
            return ReadableMessage(message: full, body: full.body, hasAttachments: false, partial: false, attachments: [])
        }
        let plan = try ReadablePlan(structure)
        var sections: [SectionSpecifier: Data] = [:], metadata: [SectionSpecifier: Data] = [:]
        var totalBytes = 0, partial = plan.partial
        // One bounded metadata request, only for explicit related starts that
        // BODYSTRUCTURE cannot identify because the root is itself multipart.
        if !plan.metadataSections.isEmpty {
            let attributes: [FetchAttribute] = [.uid] + plan.metadataSections.map { .bodySection(peek: true, $0, nil) }
            let values = try await fetch(uid: ids, attributes: attributes)
            let fetched = try readableFetchTarget(values, uid: uid)
            for section in plan.metadataSections {
                guard let headers = fetched.bodySections[section], headers.count <= 65536,
                      totalBytes + headers.count <= 256 * 1024 else { partial = true; continue }
                var bytes = headers
                if !headers.suffix(4).elementsEqual([13, 10, 13, 10]) && !headers.suffix(2).elementsEqual([10, 10]) { bytes.append(Data("\r\n".utf8)) }
                // Parse now so malformed metadata cannot erase valid siblings.
                guard (try? MIME.Part(bytes)) != nil else { partial = true; continue }
                metadata[section] = bytes; totalBytes += headers.count
            }
        }
        for part in plan.parts {
            let header = SectionSpecifier(part: part.section.part, kind: .MIMEHeader)
            let values = try await fetch(uid: ids, attributes: [.uid,
                .bodySection(peek: true, header, nil), .bodySection(peek: true, part.section, nil)])
            let fetched = try readableFetchTarget(values, uid: uid)
            guard let headers = fetched.bodySections[header], let content = fetched.bodySections[part.section],
                  headers.count <= 65536, content.count <= 4 * 1024 * 1024,
                  totalBytes + headers.count + content.count < 7 * 1024 * 1024 else { partial = true; continue }
            var bytes = headers
            if !headers.suffix(4).elementsEqual([13, 10, 13, 10]) && !headers.suffix(2).elementsEqual([10, 10]) { bytes.append(Data("\r\n".utf8)) }
            bytes.append(content)
            guard (try? MIME.Part(bytes)) != nil else { partial = true; continue }
            sections[part.section] = bytes; totalBytes += headers.count + content.count
        }
        return ReadableMessage(message: message, body: try plan.assemble(sections, metadata: metadata),
            hasAttachments: plan.hasAttachments, partial: partial, attachments: plan.attachments)
    }

    /// Fetch only a part that the current server BODYSTRUCTURE identifies as an
    /// attachment. The caller also binds UID to mailbox and UIDVALIDITY.
    public func fetchAttachment(uid: UID, id: String) async throws -> MIME.Part {
        let values = try await fetch(uid: UIDSet(uid), attributes: [.uid, .bodyStructure(extensions: true)])
        let message = try readableFetchTarget(values, uid: uid)
        guard let structure = message.bodyStructure,
              let attachment = try ReadablePlan(structure).attachments.first(where: { $0.id == id }) else {
            throw IMAPError.unexpectedResponse("Attachment no longer available")
        }
        guard attachment.encodedSize >= 0, attachment.encodedSize <= 4 * 1024 * 1024 else {
            throw IMAPError.unexpectedResponse("Attachment exceeds download limit")
        }
        let header = SectionSpecifier(part: attachment.section.part, kind: .MIMEHeader)
        let parts = try await fetch(uid: UIDSet(uid), attributes: [.uid,
            .bodySection(peek: true, header, nil), .bodySection(peek: true, attachment.section, nil)])
        let fetched = try readableFetchTarget(parts, uid: uid)
        guard let headers = fetched.bodySections[header], let data = fetched.bodySections[attachment.section],
              headers.count <= 65536, data.count <= 4 * 1024 * 1024 else {
            throw IMAPError.unexpectedResponse("Invalid attachment response")
        }
        var bytes = headers
        if !headers.suffix(4).elementsEqual([13,10,13,10]) && !headers.suffix(2).elementsEqual([10,10]) {
            bytes.append(Data("\r\n".utf8))
        }
        bytes.append(data)
        return try MIME.Part(bytes)
    }
}
