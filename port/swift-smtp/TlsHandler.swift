// MPL-2.0: https://mozilla.org/MPL/2.0/
import NIOCore
import NIOSSL
func smtpTLS(_ context: NIOSSLContext, host: String, verify: (@Sendable (NIOSSLCertificate, Channel) -> EventLoopFuture<Void>)?) throws -> NIOSSLClientHandler {
    let hostname = (try? SocketAddress(ipAddress: host, port: 465)) == nil ? host : nil
    if let verify {
        return try NIOSSLClientHandler._makeSSLClientHandler(context: context, serverHostname: hostname,
            additionalPeerCertificateVerificationCallback: verify)
    }
    return try NIOSSLClientHandler(context: context, serverHostname: hostname)
}
