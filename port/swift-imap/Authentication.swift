// MPL-2.0: https://mozilla.org/MPL/2.0/
import NIOCore
import NIOIMAP

/// Only an explicit rejection of an authentication command asks for new credentials.
/// Transport/protocol failures and later CAPABILITY commands keep their own errors.
public enum AuthenticationFailure: Error, Equatable, CustomStringConvertible {
    case rejected
    public var description: String { "Authentication rejected" }
}

// Prefer protocol fields. Outlook can instead send an uncoded NO stating that
// authentication succeeded but the mailbox connection failed. Recognize only
// that fixed prefix; never retain or expose the provider's text/diagnostic suffix.
// Other uncoded NO replies remain LOGIN/AUTHENTICATE rejections for older servers.
func authenticationRejected(_ state: TaggedResponse.State) -> Bool {
    guard case .no(let text) = state else { return false }
    switch text.code {
    case nil, .alert?:
        let prefix = String(decoding: text.text.utf8.prefix(128), as: UTF8.self).lowercased()
        let unavailable = "user is authenticated but not connected"
        if prefix == unavailable || prefix.hasPrefix(unavailable + ".") || prefix.hasPrefix(unavailable + " [") {
            return false
        }
        return true
    case .authenticationFailed?, .authorizationFailed?, .expired?: return true
    default: return false
    }
}

// Preserve the original capability collection and success handling. Only LOGIN
// gets authentication classification; CAPABILITY's NO cannot expire a login.
final class LoginHandler: CapabilityHandler, @unchecked Sendable {
    private let downloadTrace = MailDownloadTrace.current
    override func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        if case .tagged(let tagged) = response, tagged.tag == tag {
            downloadTrace?.response(tagged.state)
            switch tagged.state {
            case .no, .bad:
                if authenticationRejected(tagged.state) { promise.fail(AuthenticationFailure.rejected) }
                else { promise.fail(IMAPError.commandFailed("Login exchange failed")) }
                return
            case .ok: break
            }
        }
        super.channelRead(context: context, data: data)
    }
}
