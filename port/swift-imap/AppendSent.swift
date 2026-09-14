// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import NIOCore
import NIOIMAP

public enum SentAppendError: Error { case rejected, unconfirmed }

/// Prefer the server's SPECIAL-USE role. Older servers may omit that role; as
/// in Thunderbird's mailbox mapping, recognize conventional existing names,
/// but require a single candidate and never invent or create a mailbox.
public func sentMailbox(in mailboxes: [Mailbox]) -> Mailbox.Name? {
    let selectable = mailboxes.filter { !$0.attributes.contains(.noSelect) }
    let declared = selectable.filter {
        $0.attributes.contains(where: { String($0).lowercased() == "\\sent" }) }
    // Multiple advertised Sent folders are ambiguous, even if one happens to
    // have a familiar name. Likewise do not bypass an unusable declared role.
    let hasDeclared = mailboxes.contains {
        $0.attributes.contains(where: { String($0).lowercased() == "\\sent" }) }
    let candidates = hasDeclared ? declared : selectable.filter { mailbox in
        let otherRoles = ["\\all", "\\archive", "\\drafts", "\\junk", "\\trash"]
        guard !mailbox.attributes.contains(where: { otherRoles.contains(String($0).lowercased()) }) else { return false }
        let path = mailbox.path
        let components = path.pathSeparator.map { path.name.description.lowercased().components(separatedBy: String($0)) }
            ?? [path.name.description.lowercased()]
        guard components.count == 1 || (components.count == 2 && components[0] == "inbox") else { return false }
        return ["sent", "sent items", "sent messages", "sent mail"].contains(components.last ?? "")
    }
    guard candidates.count == 1 else { return nil }
    let name = candidates[0].path.name
    guard !name.bytes.isEmpty, name.bytes.count <= 1024,
          !name.bytes.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }) else { return nil }
    return name
}

final class SentAppendHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = Response
    let tag: String
    let promise: EventLoopPromise<Void>
    private var finished = false
    init(tag: String, promise: EventLoopPromise<Void>) { self.tag = tag; self.promise = promise }
    func fail(_ error: SentAppendError = .unconfirmed) {
        guard !finished else { return }; finished = true; promise.fail(error)
    }
    func channelInactive(context: ChannelHandlerContext) { fail(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(); context.close(promise: nil) }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finished else { return }
        switch unwrapInboundIn(data) {
        case .tagged(let reply):
            guard reply.tag == tag else { fail(); context.close(promise: nil); return }
            switch reply.state {
            case .ok: finished = true; promise.succeed(())
            case .no, .bad: fail(.rejected)
            }
        case .fatal: fail(); context.close(promise: nil)
        default: context.fireChannelRead(data)
        }
    }
}

func sentAppendParts(tag: String, mailbox: Mailbox.Name, data: Data) -> [IMAPClientHandler.Message] {
    [.part(.append(.start(tag: tag, appendingTo: mailbox))),
     .part(.append(.beginMessage(message: AppendMessage(options: AppendOptions(flagList: [.seen]), data: AppendData(byteCount: data.count))))),
     .part(.append(.messageBytes(ByteBuffer(bytes: data)))), .part(.append(.endMessage)), .part(.append(.finish))]
}

// Reuses Thunderbird's authenticated channel and SwiftNIO IMAP literal state
// machine. It sends exactly once; a lost tagged reply is never retried.
func appendSentMessage(_ data: Data, to mailbox: Mailbox.Name, channel: Channel, timeout: Int64) async throws {
    guard !data.isEmpty, data.count <= 2 * 1024 * 1024 else { throw SentAppendError.rejected }
    try Task.checkCancellation()
    let tag = "S" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let promise: EventLoopPromise<Void> = channel.eventLoop.makePromise()
    let handler = SentAppendHandler(tag: tag, promise: promise)
    let timer = channel.eventLoop.scheduleTask(in: .seconds(max(1, timeout))) {
        handler.fail(); channel.close(promise: nil)
    }
    defer { timer.cancel(); channel.pipeline.removeHandler(handler, promise: nil) }
    do {
        try await withTaskCancellationHandler {
            try await channel.pipeline.addHandler(handler).get()
            try Task.checkCancellation()
            let parts = sentAppendParts(tag: tag, mailbox: mailbox, data: data)
            for part in parts.dropLast() { channel.write(part, promise: nil) }
            try await channel.writeAndFlush(parts.last!).get()
            try await promise.futureResult.get()
        } onCancel: { channel.close(promise: nil) }
    } catch {
        channel.close(promise: nil)
        throw (error as? SentAppendError) ?? .unconfirmed
    }
}
