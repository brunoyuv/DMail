// MPL-2.0: https://mozilla.org/MPL/2.0/
import NIOCore
import NIOIMAP

/// Only an explicit rejection of an authentication command asks for new credentials.
/// Transport/protocol failures and later CAPABILITY commands keep their own errors.
public enum AuthenticationFailure: Error, Equatable, CustomStringConvertible {
    case rejected
    public var description: String { "Authentication rejected" }
}

// Use protocol fields, never provider text (which can contain account details).
// Uncoded NO is the original LOGIN/AUTHENTICATE rejection used by older servers.
func authenticationRejected(_ state: TaggedResponse.State) -> Bool {
    guard case .no(let text) = state else { return false }
    switch text.code {
    case nil, .alert?, .authenticationFailed?, .authorizationFailed?, .expired?: return true
    default: return false
    }
}

// Preserve the original capability collection and success handling. Only LOGIN
// gets authentication classification; CAPABILITY's NO cannot expire a login.
final class LoginHandler: CapabilityHandler, @unchecked Sendable {
    override func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        if case .tagged(let tagged) = response, tagged.tag == tag {
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
