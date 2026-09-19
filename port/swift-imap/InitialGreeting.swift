// MPL-2.0: https://mozilla.org/MPL/2.0/
import NIOCore
import NIOIMAP

/// Installed before TCP/TLS can deliver data, so even an immediate greeting is
/// retained until connect() starts waiting. State belongs to the channel loop.
final class InitialGreetingHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = Response

    let ready: EventLoopFuture<Void>
    private let promise: EventLoopPromise<Void>
    private let timeout: TimeAmount
    private var deadline: Scheduled<Void>?
    private var finished = false

    init(eventLoop: EventLoop, timeout: TimeAmount) {
        promise = eventLoop.makePromise(of: Void.self)
        ready = promise.futureResult
        self.timeout = timeout
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        deadline = context.eventLoop.scheduleTask(in: timeout) {
            self.fail(IMAPError.commandFailed("IMAP greeting timed out"), context: boundContext.value)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finished else { context.fireChannelRead(data); return }
        switch unwrapInboundIn(data) {
        case .untagged(.conditionalState(.ok)):
            finished = true
            deadline?.cancel(); deadline = nil
            promise.succeed(())
        case .untagged(.conditionalState(.preauth)):
            // This client must authenticate the requested account itself; the
            // greeting does not bind a preauthenticated session to that account.
            fail(IMAPError.commandNotSupported("Preauthenticated IMAP connection"), context: context)
        case .fatal, .untagged(.conditionalState(.bye)):
            fail(IMAPError.serverDisconnected, context: context)
        default:
            fail(IMAPError.unexpectedResponse("Invalid IMAP greeting"), context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Parser/state errors may embed provider input; TLS/network errors keep
        // their types for existing trust classification.
        let safeError: Error = error is ParserError || error is UnexpectedResponse ||
            error is UnexpectedContinuationRequest || error is IMAPDecoderError
            ? IMAPError.unexpectedResponse("Invalid IMAP greeting") : error
        if finished { context.fireErrorCaught(safeError); context.close(promise: nil) }
        else { fail(safeError, context: context) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(IMAPError.serverDisconnected, context: context)
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        fail(IMAPError.serverDisconnected, context: context)
    }

    private func fail(_ error: Error, context: ChannelHandlerContext) {
        guard !finished else { return }
        finished = true
        deadline?.cancel(); deadline = nil
        promise.fail(error)
        context.close(promise: nil)
    }
}
