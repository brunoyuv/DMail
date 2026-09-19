// MPL-2.0: https://mozilla.org/MPL/2.0/
// Use the original IMAP client and NIO body structure to fetch readable MIME parts,
// without downloading PDF/other attachments merely to display the message.
import Foundation
import MIME
import NIOIMAPCore
import NIOCore
import NIOSSL

// Diagnostic events are closed enums and numbers only. Never serialize errors,
// addresses, mailbox/UID values, MIME headers or message bytes.
public enum MailDownloadStage: String, Sendable {
    case request, trust, connect, authenticate, select, headers, preview, previewFailed
    case structure, plan, metadata, part, partDone, partRejected, assemble, verify, decode, complete, failed, deadline
    case section, validation, mime, structureNode, planDone, commandStart, commandDone, commandFailed
    case literalStart, literalDone, serverResponse, logout, logoutDone, shutdown, shutdownDone, cleanupFailed, dropped
}
public enum MailDownloadReason: String, Sendable {
    case sessionCreated, sessionReused, sessionDiscarded
    case none, missingHeader, missingContent, headerLimit, contentLimit, emptyUnexpected, aggregateLimit, mimeParse
    case inputTooLarge, separatorMissing, headerTooLarge, duplicateHeader, contentTypeInvalid, parsed
    case missingStructure, missingTarget, wrongTarget, metadataRejected, omitted, planned, partial
    case literalMismatch, serverOK, serverNO, serverBAD, authenticationFailed, unavailable, expired, alert
    case textPlain, textHtml, multipart, image, otherType, encoding7bit, encoding8bit, encodingBinary, encodingBase64, encodingQuotedPrintable, encodingOther
    case charsetUTF8, charsetASCII, charsetLatin1, charsetOther, charsetMissing
}
public struct MailDownloadEvent: Codable, Sendable {
    public let stage: String, ms: Int, part: Int, bytes: Int, code: String
    public let reason: String, values: [Int], section: [Int]
}
public final class MailDownloadTrace: @unchecked Sendable {
    @TaskLocal public static var current: MailDownloadTrace?
    private let lock = NSLock()
    private let started = ContinuousClock.now
    private var events: [MailDownloadEvent] = []
    private var dropped = 0
    public init() {}
    public func mark(_ stage: MailDownloadStage, part: Int = 0, bytes: Int = 0, error: Error? = nil, reason: MailDownloadReason = .none, values: [Int] = [], section: [Int] = []) {
        let elapsed = started.duration(to: .now).components
        let ms = max(0, min(600_000, Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)))
        let code: String
        switch error {
        case nil: code = "none"
        case is CancellationError: code = "cancelled"
        case is AuthenticationFailure: code = "authenticationRejected"
        case let value as MIMEError:
            switch value {
            case .dataNotFound: code = "mimeDataMissing"
            case .dataNotDecoded: code = "mimeDecode"
            case .contentTypeNotPossible: code = "mimeTypeImpossible"
            case .contentTypeNotFound: code = "mimeTypeMissing"
            case .characterSetNotFound: code = "mimeCharset"
            case .boundaryLength, .boundaryNotASCII: code = "mimeBoundary"
            case .dataNotQuotedPrintable: code = "mimeQuotedPrintable"
            case .headerNotDecoded, .headerNameNotFound, .headerValueNotASCII: code = "mimeHeader"
            default: code = "mimeOther"
            }
        case is IOError: code = "io"
        case is NIOSSLError: code = "tls"
        case let value as IMAPError:
            switch value {
            case .timedOut: code = "timeout"
            case .commandFailed: code = "commandRejected"
            case .unexpectedResponse: code = "invalidResponse"
            case .serverDisconnected, .notConnected: code = "disconnected"
            case .underlying(let cause):
                if cause is IOError { code = "io" } else if cause is NIOSSLError { code = "tls" } else { code = "transport" }
            default: code = "protocol"
            }
        default: code = "other"
        }
        lock.lock(); defer { lock.unlock() }
        if events.count >= 512 { events.remove(at: 1); dropped += 1 }
        events.append(MailDownloadEvent(stage: stage.rawValue, ms: ms, part: max(0, min(512, part)),
            bytes: max(0, min(32 * 1024 * 1024, bytes)), code: code, reason: reason.rawValue,
            values: values.prefix(12).map { max(-1, min(33554432, $0)) }, section: section.prefix(32).map { max(0, min(512, $0)) }))
    }
    public func snapshot() -> [MailDownloadEvent] {
        lock.lock(); defer { lock.unlock() }
        if dropped == 0 { return events }
        return events + [MailDownloadEvent(stage: "dropped", ms: 0, part: 0, bytes: 0, code: "none", reason: "none", values: [dropped], section: [])]
    }
    public func response(_ state: TaggedResponse.State) {
        let text: ResponseText, reason: MailDownloadReason
        switch state {
        case .ok(let value): text = value; reason = .serverOK
        case .no(let value): text = value; reason = .serverNO
        case .bad(let value): text = value; reason = .serverBAD
        }
        mark(.serverResponse, reason: reason, values: [text.code == nil ? 0 : 1])
        switch text.code {
        case .authenticationFailed?, .authorizationFailed?: mark(.serverResponse, reason: .authenticationFailed)
        case .unavailable?: mark(.serverResponse, reason: .unavailable)
        case .expired?: mark(.serverResponse, reason: .expired)
        case .alert?: mark(.serverResponse, reason: .alert)
        default: break
        }
    }
    public var mimeSink: @Sendable (MIME.MimeDiagnosticReason, Int, Int) -> Void { { [self] reason, a, b in self.mime(reason, a, b) } }
    public func mime(_ reason: MIME.MimeDiagnosticReason, _ first: Int, _ second: Int) {
        mark(.mime, reason: MailDownloadReason(rawValue: reason.rawValue) ?? .none, values: [first, second])
    }
}

public struct LateDownloadCompletion: Codable, Sendable {
    public let attempt: Int, trace: [MailDownloadEvent]
}
// A late bridge completion cannot call ArkTS after its promise has settled.
// Hand its safe final trace to the next diagnostic request instead of polling.
public final class MailDownloadCompletions: @unchecked Sendable {
    public static let shared = MailDownloadCompletions()
    private let lock = NSLock()
    private var pending = 0
    private var late: [LateDownloadCompletion] = []
    public init() {}
    public func begin() -> Int { lock.lock(); defer { lock.unlock() }; pending += 1; return pending }
    public func finish(attempt: Int, trace: [MailDownloadEvent], wasLate: Bool) {
        lock.lock(); defer { lock.unlock() }
        pending = max(0, pending - 1)
        if wasLate && attempt > 0 {
            late.append(LateDownloadCompletion(attempt: attempt, trace: trace))
            if late.count > 8 { late.removeFirst() }
        }
    }
    public func drain() -> [LateDownloadCompletion] { lock.lock(); defer { lock.unlock() }; let value = late; late = []; return value }
}

func validatedReadableSection(headers: Data?, content: Data?, expected: Int, total: Int, ordinal: Int, section: [Int]) -> Data? {
    let trace = MailDownloadTrace.current
    trace?.mark(.validation, part: ordinal, values: [headers?.count ?? -1, content?.count ?? -1, expected, total], section: section)
    func reject(_ reason: MailDownloadReason) -> Data? { trace?.mark(.partRejected, part: ordinal, reason: reason, section: section); return nil }
    guard let headers else { return reject(.missingHeader) }
    guard let content else { return reject(.missingContent) }
    guard headers.count <= 65536 else { return reject(.headerLimit) }
    guard content.count <= 4 * 1024 * 1024 else { return reject(.contentLimit) }
    guard expected == 0 || !content.isEmpty else { return reject(.emptyUnexpected) }
    guard total + headers.count + content.count < 7 * 1024 * 1024 else { return reject(.aggregateLimit) }
    var bytes = headers
    if !headers.suffix(4).elementsEqual([13, 10, 13, 10]) && !headers.suffix(2).elementsEqual([10, 10]) { bytes.append(Data("\r\n".utf8)) }
    bytes.append(content)
    do {
        _ = try MIME.MimeDiagnostics.$sink.withValue(trace?.mimeSink) { try MIME.Part(bytes) }
    } catch { trace?.mark(.partRejected, part: ordinal, error: error, reason: .mimeParse, section: section); return nil }
    return bytes
}

public struct ReadablePart: Sendable {
    public let section: SectionSpecifier
    public let octets: Int
}

// Pair adjacent small parts to avoid an extra round trip for text/plain + HTML.
// Reserve the full allowed MIME-header size for each part within a 512 KiB
// advertised-response budget. Larger parts keep their existing single request.
// Actual returned bytes still pass the independent per-part/aggregate checks.
func readableFetchBatches(_ parts: [ReadablePart]) -> [Range<Int>] {
    let pairedContentLimit = 512 * 1024 - 2 * 65536
    var batches: [Range<Int>] = [], start = 0
    while start < parts.count {
        var end = start + 1
        let first = parts[start].octets
        if end < parts.count, first >= 0, first <= pairedContentLimit {
            let second = parts[end].octets
            if second >= 0, second <= pairedContentLimit - first { end += 1 }
        }
        batches.append(start..<end)
        start = end
    }
    return batches
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
    private var hasNonemptyTextRepresentation = false
    private var emptyTextSections: Set<SectionSpecifier> = []
    private var resourceAttachments: [AttachmentPart] = []
    private var resourceFetchPartial = false
    public init(_ structure: BodyStructure) throws {
        self.structure = structure
        var remaining = 512, budget = 6 * 1024 * 1024
        try visit(structure, path: [], depth: 0, remaining: &remaining, budget: &budget)
        if hasNonemptyTextRepresentation { partial = partial || resourceFetchPartial }
        else {
            // Content-ID does not turn a standalone picture into an HTML body.
            // With no nonempty text representation, keep these files available through
            // attachment actions instead of fetching/assembling a non-text body.
            for item in resourceAttachments {
                guard attachments.count < 64 else { partial = true; break }
                attachments.append(item)
            }
            if !resourceAttachments.isEmpty { hasAttachments = true }
            parts.removeAll { !emptyTextSections.contains($0.section) }
            if parts.isEmpty { metadataSections.removeAll() }
        }
        resourceAttachments.removeAll()
    }
    private mutating func visit(_ structure: BodyStructure, path: [Int], depth: Int,
                                remaining: inout Int, budget: inout Int, relatedRoot: Bool = false) throws {
        guard remaining > 0, depth < 32 else { MailDownloadTrace.current?.mark(.plan, reason: .aggregateLimit, values: [remaining, depth]); throw IMAPError.unexpectedResponse("Body structure exceeds limits") }
        remaining -= 1
        let trace = MailDownloadTrace.current
        switch structure {
        case .multipart(let multi): trace?.mark(.structureNode, reason: .multipart, values: [depth, multi.parts.count], section: path)
        case .singlepart(let leaf):
            let type: MailDownloadReason
            switch leaf.kind {
            case .text(let text): type = text.mediaSubtype == .init("html") ? .textHtml : text.mediaSubtype == .init("plain") ? .textPlain : .otherType
            case .basic(let media): type = media.topLevel == .image ? .image : .otherType
            default: type = .otherType
            }
            trace?.mark(.structureNode, bytes: leaf.fields.octetCount, reason: type,
                values: [depth, leaf.fields.id == nil ? 0 : 1, leaf.extension?.dispositionAndLanguage?.disposition?.kind.rawValue.lowercased() == "attachment" ? 1 : 0], section: path)
            let encoding = leaf.fields.encoding?.debugDescription.lowercased() ?? "7bit"
            let kinds: [String: MailDownloadReason] = ["7bit": .encoding7bit, "8bit": .encoding8bit, "binary": .encodingBinary, "base64": .encodingBase64, "quoted-printable": .encodingQuotedPrintable]
            trace?.mark(.structureNode, reason: kinds[encoding] ?? .encodingOther, section: path)
            let charset = leaf.fields.parameters.first { $0.key.lowercased() == "charset" }?.value.lowercased()
            let charsets: [String: MailDownloadReason] = ["utf-8": .charsetUTF8, "us-ascii": .charsetASCII, "iso-8859-1": .charsetLatin1]
            trace?.mark(.structureNode, reason: charset == nil ? .charsetMissing : charsets[charset!] ?? .charsetOther, section: path)
        }
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
            case .text(let text):
                readable = [Media.Subtype("plain"), Media.Subtype("html")].contains(text.mediaSubtype)
                // Record advertised text before size limits: an omitted or
                // failed text representation must remain explicitly partial.
                if readable && (!attached || relatedRoot) {
                    if part.fields.octetCount == 0 {
                        emptyTextSections.insert(.init(part: .init(path.isEmpty ? [1] : path)))
                    } else { hasNonemptyTextRepresentation = true }
                }
            case .basic: readable = referencedImage
            case .message: readable = false
            }
            if attached || !readable || referencedImage {
                let resourceOnly = referencedImage && !attached
                if !resourceOnly { hasAttachments = true }
                guard (resourceOnly ? resourceAttachments.count : attachments.count) < 64 else { partial = true; return }
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
                let attachment = AttachmentPart(id: components.map(String.init).joined(separator: "."),
                    name: String(name.prefix(512)), contentType: type, section: .init(part: .init(components)), encodedSize: part.fields.octetCount)
                if resourceOnly { resourceAttachments.append(attachment) }
                else { attachments.append(attachment) }
                if !referencedImage && !(relatedRoot && readable) { return }
            }
            if !readable { return }
            let size = part.fields.octetCount
            guard size >= 0, size <= 4 * 1024 * 1024, size <= budget, parts.count < 24 else {
                MailDownloadTrace.current?.mark(.plan, reason: .aggregateLimit, values: [size, budget, parts.count], section: path)
                if referencedImage || (size == 0 && emptyTextSections.contains(.init(part: .init(path.isEmpty ? [1] : path)))) {
                    // An image-filled request budget can omit a zero-byte
                    // stub; that omission is harmless in attachment-only mail.
                    resourceFetchPartial = true
                }
                else { partial = true }
                return
            }
            budget -= size
            parts.append(ReadablePart(section: SectionSpecifier(part: .init(path.isEmpty ? [1] : path)), octets: size))
        }
    }
    private static func identifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }

    /// A singlepart root carries its MIME fields in the message header.
    /// Some servers return BODY[1] successfully but omit BODY[1.MIME]. Request
    /// the original fields directly, in the same FETCH, without retrying or
    /// inventing Content-Type/transfer encoding from a missing section.
    public func mimeHeader(for section: SectionSpecifier) -> SectionSpecifier {
        if case .singlepart = structure, Array(section.part) == [1] {
            return .header
        }
        return SectionSpecifier(part: section.part, kind: .MIMEHeader)
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
                guard let data = sections[section] else { MailDownloadTrace.current?.mark(.assemble, reason: .omitted, section: Array(section.part)); return omitted() }
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
        let body: MIME.Body
        do { body = try MIME.Body(part: build(structure, path: [])) }
        catch { MailDownloadTrace.current?.mark(.assemble, error: error, values: [sections.count, metadata.count]); throw error }
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
        MailDownloadTrace.current?.mark(.validation, reason: matching.isEmpty ? .missingTarget : .wrongTarget, values: [messages.count, matching.count])
        throw IMAPError.unexpectedResponse("Mismatched UID")
    }
    return message
}
extension IMAPClient {
    public func fetchReadable(uid: UID) async throws -> ReadableMessage? {
        MailDownloadTrace.current?.mark(.structure)
        let ids = UIDSet(uid)
        let initial = try await fetch(uid: ids, attributes: [.bodyStructure(extensions: true),
            .bodySection(peek: true, .headerFields(["References"]), nil)] + .standard)
        guard !initial.isEmpty else { MailDownloadTrace.current?.mark(.structure, reason: .missingTarget); return nil }
        let message = try readableFetchTarget(initial, uid: uid)
        guard let structure = message.bodyStructure else {
            MailDownloadTrace.current?.mark(.structure, reason: .missingStructure)
            // Some older servers omit BODYSTRUCTURE. Retain the bounded original path.
            let full = try await fetch(uid: uid, attributes: .complete)
            guard full.uid == uid else { throw IMAPError.unexpectedResponse("Mismatched UID") }
            return ReadableMessage(message: full, body: full.body, hasAttachments: false, partial: false, attachments: [])
        }
        MailDownloadTrace.current?.mark(.plan)
        let plan = try ReadablePlan(structure)
        MailDownloadTrace.current?.mark(.planDone, reason: plan.partial ? .partial : .planned,
            values: [plan.parts.count, plan.metadataSections.count, plan.attachments.count, plan.hasAttachments ? 1 : 0])
        var sections: [SectionSpecifier: Data] = [:], metadata: [SectionSpecifier: Data] = [:]
        var totalBytes = 0, partial = plan.partial
        // One bounded metadata request, only for explicit related starts that
        // BODYSTRUCTURE cannot identify because the root is itself multipart.
        if !plan.metadataSections.isEmpty {
            MailDownloadTrace.current?.mark(.metadata)
            let attributes: [FetchAttribute] = [.uid] + plan.metadataSections.map { .bodySection(peek: true, $0, nil) }
            let values = try await fetch(uid: ids, attributes: attributes)
            let fetched = try readableFetchTarget(values, uid: uid)
            for section in plan.metadataSections {
                MailDownloadTrace.current?.mark(.metadata, values: [fetched.bodySections[section]?.count ?? -1, totalBytes], section: Array(section.part))
                guard let headers = fetched.bodySections[section], headers.count <= 65536,
                      totalBytes + headers.count <= 256 * 1024 else {
                    let reason: MailDownloadReason = fetched.bodySections[section] == nil ? .missingHeader : (fetched.bodySections[section]?.count ?? 0) > 65536 ? .headerLimit : .aggregateLimit
                    MailDownloadTrace.current?.mark(.metadata, reason: reason, section: Array(section.part)); partial = true; continue
                }
                var bytes = headers
                if !headers.suffix(4).elementsEqual([13, 10, 13, 10]) && !headers.suffix(2).elementsEqual([10, 10]) { bytes.append(Data("\r\n".utf8)) }
                // Parse now so malformed metadata cannot erase valid siblings.
                do { _ = try MIME.Part(bytes) }
                catch { MailDownloadTrace.current?.mark(.metadata, error: error, reason: .mimeParse, section: Array(section.part)); partial = true; continue }
                metadata[section] = bytes; totalBytes += headers.count
            }
        }
        for batch in readableFetchBatches(plan.parts) {
            var attributes: [FetchAttribute] = [.uid]
            var requested: Set<SectionSpecifier> = []
            for index in batch {
                let part = plan.parts[index]
                MailDownloadTrace.current?.mark(.part, part: index + 1, bytes: part.octets)
                for section in [plan.mimeHeader(for: part.section), part.section] {
                    if requested.insert(section).inserted { attributes.append(.bodySection(peek: true, section, nil)) }
                }
            }
            // Keep one awaited original-client command, with the same UID and
            // cancellation/deadline handling. Never replay a rejected batch.
            let values = try await fetch(uid: ids, attributes: attributes)
            let fetched = try readableFetchTarget(values, uid: uid)
            for (section, bytes) in fetched.bodySections.filter({ !requested.contains($0.key) })
                .sorted(by: { Array($0.key.part).lexicographicallyPrecedes(Array($1.key.part)) }).prefix(64) {
                MailDownloadTrace.current?.mark(.section, bytes: bytes.count, values: [0], section: Array(section.part))
            }
            for index in batch {
                let part = plan.parts[index], header = plan.mimeHeader(for: part.section)
                for (section, kind) in [(header, 1), (part.section, 2)] {
                    if let bytes = fetched.bodySections[section] {
                        MailDownloadTrace.current?.mark(.section, part: index + 1, bytes: bytes.count,
                            values: [kind], section: Array(section.part))
                    }
                }
                guard let bytes = validatedReadableSection(headers: fetched.bodySections[header], content: fetched.bodySections[part.section],
                    expected: part.octets, total: totalBytes, ordinal: index + 1, section: Array(part.section.part)) else { partial = true; continue }
                MailDownloadTrace.current?.mark(.partDone, part: index + 1, bytes: fetched.bodySections[part.section]?.count ?? 0,
                    section: Array(part.section.part))
                sections[part.section] = bytes
                totalBytes += (fetched.bodySections[header]?.count ?? 0) + (fetched.bodySections[part.section]?.count ?? 0)
            }
        }
        MailDownloadTrace.current?.mark(.assemble, bytes: totalBytes)
        return ReadableMessage(message: message, body: try plan.assemble(sections, metadata: metadata),
            hasAttachments: plan.hasAttachments, partial: partial, attachments: plan.attachments)
    }

    /// Fetch only a part that the current server BODYSTRUCTURE identifies as an
    /// attachment. The caller also binds UID to mailbox and UIDVALIDITY.
    public func fetchAttachment(uid: UID, id: String) async throws -> MIME.Part {
        let values = try await fetch(uid: UIDSet(uid), attributes: [.uid, .bodyStructure(extensions: true)])
        let message = try readableFetchTarget(values, uid: uid)
        guard let structure = message.bodyStructure else {
            throw IMAPError.unexpectedResponse("Attachment no longer available")
        }
        let plan = try ReadablePlan(structure)
        guard let attachment = plan.attachments.first(where: { $0.id == id }) else {
            throw IMAPError.unexpectedResponse("Attachment no longer available")
        }
        guard attachment.encodedSize >= 0, attachment.encodedSize <= 4 * 1024 * 1024 else {
            throw IMAPError.unexpectedResponse("Attachment exceeds download limit")
        }
        let header = plan.mimeHeader(for: attachment.section)
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
