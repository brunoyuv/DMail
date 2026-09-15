// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import NIOCore
import NIOIMAP

public enum ArchiveMoveError: Error { case unavailable, rejected, unconfirmed }
public struct ArchiveMoveResult: Sendable {
    public let validity: UInt32?
    public let uid: UInt32?
}

/// Use a unique server role, including Gmail's All Mail, before conventional
/// existing Archive folders. Never create a folder or choose between duplicates.
public func archiveMailbox(in mailboxes: [Mailbox]) -> Mailbox.Name? {
    func hasRole(_ box: Mailbox, _ role: String) -> Bool {
        box.attributes.contains(where: { String($0).lowercased() == role })
    }
    let selectable = mailboxes.filter { !$0.attributes.contains(.noSelect) }
    let roles = ["\\archive", "\\all"]
    let declared = mailboxes.contains { box in roles.contains { hasRole(box, $0) } }
    let candidates = declared ? selectable.filter { box in roles.contains { hasRole(box, $0) } } : selectable.filter { box in
        let other = ["\\sent", "\\drafts", "\\junk", "\\trash"]
        guard !other.contains(where: { hasRole(box, $0) }) else { return false }
        let parts = box.path.pathSeparator.map { box.path.name.description.lowercased().components(separatedBy: String($0)) }
            ?? [box.path.name.description.lowercased()]
        guard parts.count == 1 || (parts.count == 2 && parts[0] == "inbox") else { return false }
        return ["archive", "archives"].contains(parts.last ?? "")
    }
    guard candidates.count == 1,
          !["\\sent", "\\drafts", "\\junk", "\\trash"].contains(where: { hasRole(candidates[0], $0) }) else { return nil }
    let name = candidates[0].path.name
    guard name.description.uppercased() != "INBOX", !name.bytes.isEmpty, name.bytes.count <= 1024,
          !name.bytes.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }) else { return nil }
    return name
}

/// Keep the original Thunderbird UIDMoveCommand wire encoder and its bounded
/// authenticated execute path; only the result handler needs COPYUID support.
struct ArchiveMoveCommand: IMAPCommand {
    let uid: UID
    let mailbox: Mailbox.Name
    typealias Result = ArchiveMoveResult
    typealias Handler = ArchiveMoveHandler
    var name: String { "archive move" }
    func tagged(_ tag: String) -> TaggedCommand {
        UIDMoveCommand(UIDSetNonEmpty(range: .init(uid...uid)), to: mailbox).tagged(tag)
    }
    func makeHandler(tag: String, promise: EventLoopPromise<Result>) -> Handler {
        let handler = Handler(tag: tag, promise: promise)
        handler.sourceUID = uid
        return handler
    }
}

final class ArchiveMoveHandler: IMAPCommandHandler, @unchecked Sendable {
    typealias InboundIn = Response
    typealias Result = ArchiveMoveResult
    let tag: String
    let promise: EventLoopPromise<Result>
    var clientBug: String?
    var sourceUID: UID?
    private var mapping: ResponseCodeCopy?
    private var invalidMapping = false
    private var finished = false
    init(tag: String, promise: EventLoopPromise<Result>) { self.tag = tag; self.promise = promise }
    private func record(_ code: ResponseTextCode?) {
        guard case .uidCopy(let copy)? = code else { return }
        if let mapping, mapping != copy { invalidMapping = true }
        mapping = copy
    }
    private func fail(_ error: ArchiveMoveError = .unconfirmed) {
        guard !finished else { return }; finished = true; promise.fail(error)
    }
    func channelInactive(context: ChannelHandlerContext) { fail(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(); context.close(promise: nil) }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finished else { context.fireChannelRead(data); return }
        switch unwrapInboundIn(data) {
        case .tagged(let response):
            guard response.tag == tag else { fail(); context.close(promise: nil); return }
            switch response.state {
            case .no, .bad: fail(.rejected)
            case .ok(let text):
                record(text.code)
                let result: ArchiveMoveResult
                if let copy = mapping {
                    // A single requested UID must have one exact single mapping.
                    // Never expand attacker-sized ranges or guess destination UIDs.
                    guard !invalidMapping, copy.sourceUIDs.count == 1, copy.destinationUIDs.count == 1,
                          copy.sourceUIDs[0].range.lowerBound == sourceUID,
                          copy.sourceUIDs[0].range.upperBound == sourceUID,
                          copy.destinationUIDs[0].range.lowerBound == copy.destinationUIDs[0].range.upperBound,
                          copy.destinationUIDs[0].range.lowerBound.rawValue > 0,
                          copy.destinationUIDs[0].range.lowerBound != .max,
                          UInt32(copy.destinationUIDValidity) > 0 else { fail(); return }
                    result = ArchiveMoveResult(validity: UInt32(copy.destinationUIDValidity),
                        uid: copy.destinationUIDs[0].range.lowerBound.rawValue)
                } else { result = ArchiveMoveResult(validity: nil, uid: nil) }
                finished = true; promise.succeed(result)
            }
        case .untagged(.conditionalState(.ok(let text))):
            record(text.code)
            context.fireChannelRead(data)
        case .fatal: fail(); context.close(promise: nil)
        default: context.fireChannelRead(data)
        }
    }
}
