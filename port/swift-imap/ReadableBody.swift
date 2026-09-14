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
    public var parts: [ReadablePart] = []
    public var attachments: [AttachmentPart] = []
    public var hasAttachments = false
    public var partial = false
    public init(_ structure: BodyStructure) throws {
        var remaining = 512, budget = 6 * 1024 * 1024
        try visit(structure, path: [], depth: 0, remaining: &remaining, budget: &budget)
    }
    private mutating func visit(_ structure: BodyStructure, path: [Int], depth: Int,
                                remaining: inout Int, budget: inout Int) throws {
        guard remaining > 0, depth < 32 else { throw IMAPError.unexpectedResponse("Body structure exceeds limits") }
        remaining -= 1
        switch structure {
        case .multipart(let multi):
            if multi.extension?.dispositionAndLanguage?.disposition?.kind.rawValue.lowercased() == "attachment" {
                hasAttachments = true; return
            }
            for (index, part) in multi.parts.enumerated() {
                try visit(part, path: path + [index + 1], depth: depth + 1, remaining: &remaining, budget: &budget)
            }
        case .singlepart(let part):
            let disposition = part.extension?.dispositionAndLanguage?.disposition
            let attached = disposition?.kind.rawValue.lowercased() == "attachment"
            let location = part.extension?.dispositionAndLanguage?.language?.location?.location
            let referencedImage: Bool
            if case .basic(let media) = part.kind { referencedImage = media.topLevel == .image && (part.fields.id != nil || location != nil) }
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
                let name = parameters.first(where: { $0.key.lowercased() == "filename" })?.value ??
                    part.fields.parameters.first(where: { $0.key.lowercased() == "name" })?.value ?? ""
                let type: String
                switch part.kind {
                case .basic(let media): type = "\(media.topLevel.debugDescription)/\(media.sub.debugDescription)"
                case .text(let text): type = "text/\(text.mediaSubtype.debugDescription)"
                case .message: type = "message/rfc822"
                }
                attachments.append(AttachmentPart(id: components.map(String.init).joined(separator: "."),
                    name: String(name.prefix(512)), contentType: type, section: .init(part: .init(components)), encodedSize: part.fields.octetCount))
                if !referencedImage { return }
            }
            if !readable { return }
            let size = part.fields.octetCount
            guard size >= 0, size <= 4 * 1024 * 1024, size <= budget, parts.count < 24 else { partial = true; return }
            budget -= size
            parts.append(ReadablePart(section: SectionSpecifier(part: .init(path.isEmpty ? [1] : path)), octets: size))
        }
    }
}
public struct ReadableMessage: Sendable {
    public let message: Message
    public let body: MIME.Body?
    public let hasAttachments: Bool
    public let partial: Bool
    public let attachments: [AttachmentPart]
}
extension IMAPClient {
    public func fetchReadable(uid: UID) async throws -> ReadableMessage? {
        let ids = UIDSet(uid)
        let initial = try await fetch(uid: ids, attributes: [.bodyStructure(extensions: true),
            .bodySection(peek: true, .headerFields(["References"]), nil)] + .standard)
        guard !initial.isEmpty else { return nil }
        guard initial.count == 1, let message = initial.values.first, message.uid == uid else {
            throw IMAPError.unexpectedResponse("Mismatched UID")
        }
        guard let structure = message.bodyStructure else {
            // Some older servers omit BODYSTRUCTURE. Retain the bounded original path.
            let full = try await fetch(uid: uid, attributes: .complete)
            guard full.uid == uid else { throw IMAPError.unexpectedResponse("Mismatched UID") }
            return ReadableMessage(message: full, body: full.body, hasAttachments: false, partial: false, attachments: [])
        }
        let plan = try ReadablePlan(structure)
        let boundary = "thunderbird-" + UUID().uuidString
        var mime = Data("Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n".utf8)
        var partial = plan.partial
        for part in plan.parts {
            let header = SectionSpecifier(part: part.section.part, kind: .MIMEHeader)
            let values = try await fetch(uid: ids, attributes: [.uid,
                .bodySection(peek: true, header, nil), .bodySection(peek: true, part.section, nil)])
            guard values.count == 1, let fetched = values.values.first, fetched.uid == uid else {
                throw IMAPError.unexpectedResponse("Mismatched UID")
            }
            guard let headers = fetched.bodySections[header], let content = fetched.bodySections[part.section],
                  headers.count <= 65536, content.count <= 4 * 1024 * 1024,
                  mime.count + headers.count + content.count < 7 * 1024 * 1024 else { partial = true; continue }
            mime.append(Data("--\(boundary)\r\n".utf8))
            mime.append(headers)
            if !headers.suffix(4).elementsEqual([13, 10, 13, 10]) { mime.append(Data("\r\n".utf8)) }
            mime.append(content); mime.append(Data("\r\n".utf8))
        }
        mime.append(Data("--\(boundary)--\r\n".utf8))
        return ReadableMessage(message: message, body: plan.parts.isEmpty ? nil : try MIME.Body(mime),
            hasAttachments: plan.hasAttachments, partial: partial, attachments: plan.attachments)
    }

    /// Fetch only a part that the current server BODYSTRUCTURE identifies as an
    /// attachment. The caller also binds UID to mailbox and UIDVALIDITY.
    public func fetchAttachment(uid: UID, id: String) async throws -> MIME.Part {
        let values = try await fetch(uid: UIDSet(uid), attributes: [.uid, .bodyStructure(extensions: true)])
        guard values.count == 1, let message = values.values.first, message.uid == uid,
              let structure = message.bodyStructure,
              let attachment = try ReadablePlan(structure).attachments.first(where: { $0.id == id }) else {
            throw IMAPError.unexpectedResponse("Attachment no longer available")
        }
        guard attachment.encodedSize >= 0, attachment.encodedSize <= 4 * 1024 * 1024 else {
            throw IMAPError.unexpectedResponse("Attachment exceeds download limit")
        }
        let header = SectionSpecifier(part: attachment.section.part, kind: .MIMEHeader)
        let parts = try await fetch(uid: UIDSet(uid), attributes: [.uid,
            .bodySection(peek: true, header, nil), .bodySection(peek: true, attachment.section, nil)])
        guard parts.count == 1, let fetched = parts.values.first, fetched.uid == uid,
              let headers = fetched.bodySections[header], let data = fetched.bodySections[attachment.section],
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
