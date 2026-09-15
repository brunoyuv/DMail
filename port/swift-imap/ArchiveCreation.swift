// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import NIOCore
import NIOIMAP

public struct ArchiveDestination: Sendable {
    public let name: Mailbox.Name
    public let requiresCreation: Bool
    // Retained only to verify the same plan after CREATE; never a mutable UI hint.
    fileprivate let namespaces: [Namespace]?
}
public enum ArchiveOperationError: Error {
    case unavailable, readOnly, messageNotFound, identityChanged, invalidResponse, forbidden, createUnconfirmed, moveUnconfirmed
}
public struct ArchiveOperationResult: Sendable {
    public let destination: Mailbox.Name
    public let move: ArchiveMoveResult
}

private func safeArchiveName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= 1024 &&
        !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
}
private func archiveRole(_ mailbox: Mailbox, _ roles: [String]) -> Bool {
    mailbox.attributes.contains { roles.contains(String($0).lowercased()) }
}
private func conventionalArchive(_ mailbox: Mailbox) -> Bool {
    let parts = mailbox.path.pathSeparator.map { mailbox.path.name.description.lowercased().components(separatedBy: String($0)) }
        ?? [mailbox.path.name.description.lowercased()]
    return (parts.count == 1 || (parts.count == 2 && parts[0] == "inbox")) &&
        ["archive", "archives"].contains(parts.last ?? "")
}

/// A nil result means unsafe/ambiguous, not permission to create an arbitrary
/// folder. NAMESPACE prefixes are concatenated exactly as returned by the server.
/// Without NAMESPACE, use the visible Inbox/root layout only; do not infer shared
/// or other-user prefixes from an unrelated folder tree.
public func archiveDestination(in mailboxes: [Mailbox], namespaces: [Namespace]? = nil) -> ArchiveDestination? {
    guard !mailboxes.isEmpty, mailboxes.count <= 500,
          mailboxes.allSatisfy({ safeArchiveName($0.path.name.description) }) else { return nil }
    let inboxes = mailboxes.filter { $0.path.name.description.uppercased() == "INBOX" && !$0.attributes.contains(.noSelect) }
    guard inboxes.count == 1 else { return nil }
    if let existing = archiveMailbox(in: mailboxes) {
        return ArchiveDestination(name: existing, requiresCreation: false, namespaces: namespaces)
    }
    // Existing declared or conventional-but-unusable folders must not cause a
    // second Archive to be created under a different guessed name.
    guard !mailboxes.contains(where: { archiveRole($0, ["\\archive", "\\all"]) || conventionalArchive($0) }) else { return nil }
    let prefix: String
    if let namespaces {
        guard namespaces.count <= 64 else { return nil }
        let personal = namespaces.filter { $0.scope == .user }
        guard personal.count == 1 else { return nil }
        let namespace = personal[0]
        guard namespace.prefix.utf8.count <= 1000,
              !namespace.prefix.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              namespace.delimiter == nil || String(namespace.delimiter!).utf8.count == 1 else { return nil }
        prefix = namespace.prefix
    } else {
        let inbox = inboxes[0], delimiter = inbox.path.pathSeparator
        let others = mailboxes.filter { $0.path.name.description.uppercased() != "INBOX" }
        guard others.allSatisfy({ $0.path.pathSeparator == delimiter }) else { return nil }
        if let delimiter {
            let inboxPrefix = inbox.path.name.description + String(delimiter)
            if !others.isEmpty && others.allSatisfy({ $0.path.name.description.hasPrefix(inboxPrefix) }) {
                guard !inbox.attributes.contains(.noInferiors) else { return nil }
                prefix = inboxPrefix
            } else {
                // A root peer or an empty hierarchy supplies the conventional
                // unprefixed destination. A solely unrelated nested tree does not.
                guard others.isEmpty || others.contains(where: { !$0.path.name.description.contains(delimiter) }) else { return nil }
                prefix = ""
            }
        } else { prefix = "" }
    }
    let candidates = mailboxes.filter {
        let name = $0.path.name.description
        return name.hasPrefix(prefix) && ["archive", "archives"].contains(String(name.dropFirst(prefix.count)).lowercased())
    }
    if !candidates.isEmpty {
        guard candidates.count == 1, !candidates[0].attributes.contains(.noSelect),
              !archiveRole(candidates[0], ["\\sent", "\\drafts", "\\junk", "\\trash"]),
              candidates[0].path.name.description.uppercased() != "INBOX" else { return nil }
        return ArchiveDestination(name: candidates[0].path.name, requiresCreation: false, namespaces: namespaces)
    }
    let name = prefix + "Archive"
    guard safeArchiveName(name), name.uppercased() != "INBOX",
          !mailboxes.contains(where: { $0.path.name.description == name }) else { return nil }
    return ArchiveDestination(name: Mailbox.Name(name), requiresCreation: true, namespaces: namespaces)
}

/// Read-only planning. Existing Archive/All Mail needs no namespace request.
public func discoverArchiveDestination(client: IMAPClient, mailboxes: [Mailbox]) async throws -> ArchiveDestination? {
    if archiveMailbox(in: mailboxes) != nil { return archiveDestination(in: mailboxes) }
    if mailboxes.contains(where: { archiveRole($0, ["\\archive", "\\all"]) || conventionalArchive($0) }) { return nil }
    let supportsNamespace = client.capabilities.contains { $0.rawValue.uppercased() == "NAMESPACE" }
    let namespaces: [Namespace]? = supportsNamespace ? try await client.namespace(timeout: 2) : nil
    return archiveDestination(in: mailboxes, namespaces: namespaces)
}

private func requireArchiveSource(client: IMAPClient, source: Mailbox.Name, validity: UInt32, uid: UID) async throws {
    let selection = try await client.selectWithPermissions(mailbox: source)
    guard let actual = flagMutationValidity(selection.status) else { throw ArchiveOperationError.invalidResponse }
    guard actual == validity else { throw ArchiveOperationError.identityChanged }
    guard !selection.isReadOnly else { throw ArchiveOperationError.readOnly }
    let identifiers = UIDSet(range: .init(uid...uid))
    let before = try await client.fetch(uid: identifiers, attributes: [.uid, .flags])
    guard !before.isEmpty else { throw ArchiveOperationError.messageNotFound }
    guard flagMutationTarget(in: before, uid: uid) != nil else { throw ArchiveOperationError.invalidResponse }
}

/// This is the shipping operation and the synthetic TLS test boundary. Planning
/// is read-only; CREATE follows source verification and is sent at most once.
public func archiveMessage(client: IMAPClient, source: Mailbox.Name, validity: UInt32, uid: UID,
                           undoInbox: Mailbox.Name? = nil) async throws -> ArchiveOperationResult {
    guard validity > 0, uid.rawValue > 0, uid != .max, safeArchiveName(source.description) else { throw ArchiveOperationError.invalidResponse }
    guard client.capabilities.contains(where: { $0.rawValue.uppercased() == "MOVE" }) else { throw ArchiveOperationError.unavailable }
    let listed = try await client.list().map { $0.0 }
    guard listed.count <= 500,
          let plan = try await discoverArchiveDestination(client: client, mailboxes: listed) else { throw ArchiveOperationError.unavailable }
    let destination: Mailbox.Name
    if let undoInbox {
        guard !plan.requiresCreation, source == plan.name, undoInbox.description.uppercased() == "INBOX" else { throw ArchiveOperationError.unavailable }
        destination = undoInbox
    } else {
        guard source.description.uppercased() == "INBOX" else { throw ArchiveOperationError.unavailable }
        destination = plan.name
    }
    try await requireArchiveSource(client: client, source: source, validity: validity, uid: uid)
    if undoInbox == nil && plan.requiresCreation {
        do { _ = try await client.archiveCreate(mailbox: plan.name) }
        catch ArchiveMoveError.rejected { throw ArchiveOperationError.forbidden }
        catch { throw ArchiveOperationError.createUnconfirmed }
        // A tagged success or ALREADYEXISTS is not sufficient: verify exactly
        // the planned selectable destination, preserving ambiguity refusals.
        let after: [Mailbox]
        do { after = try await client.list().map { $0.0 } }
        catch { throw ArchiveOperationError.createUnconfirmed }
        guard let confirmed = archiveDestination(in: after, namespaces: plan.namespaces),
              !confirmed.requiresCreation, confirmed.name == plan.name else { throw ArchiveOperationError.unavailable }
        // CREATE/LIST may take time. Recheck the selected epoch/UID before MOVE.
        try await requireArchiveSource(client: client, source: source, validity: validity, uid: uid)
    }
    let moved: ArchiveMoveResult
    do { moved = try await client.archiveMove(uid: uid, to: destination) }
    catch ArchiveMoveError.rejected { throw ArchiveOperationError.forbidden }
    catch { throw ArchiveOperationError.moveUnconfirmed }
    return ArchiveOperationResult(destination: destination, move: moved)
}

/// Delete is an explicit move to one existing Trash mailbox. Never create a
/// destination or fall back to STORE Deleted / mailbox-wide EXPUNGE.
public func trashMailbox(in mailboxes: [Mailbox]) -> Mailbox.Name? {
    guard !mailboxes.isEmpty, mailboxes.count <= 500,
          mailboxes.allSatisfy({ safeArchiveName($0.path.name.description) }) else { return nil }
    let declared = mailboxes.filter { archiveRole($0, ["\\trash"]) }
    let candidates = declared.isEmpty ? mailboxes.filter { box in
        let components = box.path.pathSeparator.map { box.path.name.description.lowercased().components(separatedBy: String($0)) }
            ?? [box.path.name.description.lowercased()]
        return (components.count == 1 || (components.count == 2 && components[0] == "inbox")) &&
            ["trash", "deleted items", "deleted messages"].contains(components.last ?? "")
    } : declared
    guard candidates.count == 1, let box = candidates.first,
          !box.attributes.contains(.noSelect), box.path.name.description.uppercased() != "INBOX",
          !archiveRole(box, ["\\sent", "\\drafts", "\\junk", "\\archive", "\\all"]) else { return nil }
    return box.path.name
}

public func deleteMessage(client: IMAPClient, source: Mailbox.Name, validity: UInt32, uid: UID,
                          undoInbox: Mailbox.Name? = nil) async throws -> ArchiveOperationResult {
    guard validity > 0, uid.rawValue > 0, uid != .max, safeArchiveName(source.description) else { throw ArchiveOperationError.invalidResponse }
    guard client.capabilities.contains(where: { $0.rawValue.uppercased() == "MOVE" }) else { throw ArchiveOperationError.unavailable }
    let listed = try await client.list().map { $0.0 }
    let inboxes = listed.filter { $0.path.name.description.uppercased() == "INBOX" && !$0.attributes.contains(.noSelect) }
    guard inboxes.count == 1, let trash = trashMailbox(in: listed) else { throw ArchiveOperationError.unavailable }
    let destination: Mailbox.Name
    if let undoInbox {
        guard source == trash, undoInbox == inboxes[0].path.name else { throw ArchiveOperationError.unavailable }
        destination = undoInbox
    } else {
        guard source == inboxes[0].path.name else { throw ArchiveOperationError.unavailable }
        destination = trash
    }
    try await requireArchiveSource(client: client, source: source, validity: validity, uid: uid)
    let moved: ArchiveMoveResult
    do { moved = try await client.archiveMove(uid: uid, to: destination) }
    catch ArchiveMoveError.rejected { throw ArchiveOperationError.forbidden }
    catch { throw ArchiveOperationError.moveUnconfirmed }
    return ArchiveOperationResult(destination: destination, move: moved)
}

public enum ArchiveCreateResult: Sendable { case created, alreadyExists }
struct ArchiveCreateCommand: IMAPCommand {
    let mailbox: Mailbox.Name
    typealias Result = ArchiveCreateResult
    typealias Handler = ArchiveCreateHandler
    var name: String { "archive create" }
    func tagged(_ tag: String) -> TaggedCommand { CreateCommand(mailbox).tagged(tag) }
}
final class ArchiveCreateHandler: IMAPCommandHandler, @unchecked Sendable {
    typealias InboundIn = Response
    typealias Result = ArchiveCreateResult
    let tag: String
    let promise: EventLoopPromise<Result>
    var clientBug: String?
    private var finished = false
    init(tag: String, promise: EventLoopPromise<Result>) { self.tag = tag; self.promise = promise }
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
            case .ok: finished = true; promise.succeed(.created)
            case .no(let text) where text.code == .alreadyExists:
                finished = true; promise.succeed(.alreadyExists)
            case .no, .bad: fail(.rejected)
            }
        case .fatal: fail(); context.close(promise: nil)
        default: context.fireChannelRead(data)
        }
    }
}
