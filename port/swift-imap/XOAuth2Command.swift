// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import NIOCore
import NIOIMAP

// Keep the token out of command descriptions and provider error messages.
struct XOAuth2Command: IMAPCommand {
    typealias Result = Void
    typealias Handler = XOAuth2Handler
    let payload: ByteBuffer
    let initialResponse: Bool
    var name: String { "AUTHENTICATE XOAUTH2" }

    init(username: String, accessToken: String, initialResponse: Bool) throws {
        guard !username.isEmpty, username.utf8.count <= 512,
              !username.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !accessToken.isEmpty, accessToken.utf8.count <= 32768,
              accessToken.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw IMAPError.commandFailed("Invalid OAuth credentials")
        }
        payload = ByteBuffer(string: "user=\(username)\u{1}auth=Bearer \(accessToken)\u{1}\u{1}")
        self.initialResponse = initialResponse
    }

    func tagged(_ tag: String) -> TaggedCommand {
        TaggedCommand(tag: tag, command: .authenticate(mechanism: AuthenticationMechanism("XOAUTH2")!,
            initialResponse: initialResponse ? InitialResponse(payload) : nil))
    }
    func makeHandler(tag: String, promise: EventLoopPromise<Void>) -> XOAuth2Handler {
        XOAuth2Handler(tag: tag, promise: promise, payload: payload, initialSent: initialResponse)
    }
}

final class XOAuth2Handler: IMAPCommandHandler, @unchecked Sendable {
    typealias InboundIn = Response
    typealias OutboundOut = IMAPClientHandler.Message
    typealias Result = Void
    let tag: String
    let promise: EventLoopPromise<Void>
    var clientBug: String?
    private var payload = ByteBuffer()
    private enum Phase { case initial, sent, rejected }
    private var phase: Phase = .initial
    private var finished = false

    required init(tag: String, promise: EventLoopPromise<Void>) { self.tag = tag; self.promise = promise }
    convenience init(tag: String, promise: EventLoopPromise<Void>, payload: ByteBuffer, initialSent: Bool) {
        self.init(tag: tag, promise: promise)
        self.payload = payload; self.phase = initialSent ? .sent : .initial
    }
    private func fail(_ context: ChannelHandlerContext, error: Error = IMAPError.commandFailed("OAuth exchange failed")) {
        guard !finished else { return }; finished = true; payload.clear()
        promise.fail(error)
        context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) { fail(context, error: IMAPError.serverDisconnected); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(context, error: error) }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finished else { return }
        switch unwrapInboundIn(data) {
        case .authenticationChallenge(let challenge):
            guard challenge.readableBytes <= 8192, phase != .rejected else { fail(context); return }
            let reply: ByteBuffer
            if phase == .initial && challenge.readableBytes == 0 {
                reply = payload; phase = .sent
            } else {
                // Gmail returns a base64 JSON error as a SASL challenge. Finish
                // that exchange with an empty response, never send the token twice.
                reply = ByteBuffer(); phase = .rejected
            }
            payload.clear()
            context.writeAndFlush(wrapOutboundOut(.part(.continuationResponse(reply)))).whenFailure { error in self.fail(context, error: error) }
        case .tagged(let response):
            guard response.tag == tag else { fail(context); return }
            if authenticationRejected(response.state) { fail(context, error: AuthenticationFailure.rejected); return }
            guard phase == .sent, case .ok = response.state else { fail(context); return }
            finished = true; payload.clear(); promise.succeed(())
        case .fatal:
            fail(context)
        default:
            context.fireChannelRead(data)
        }
    }
}
