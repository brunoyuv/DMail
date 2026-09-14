import Foundation
import NIO
import NIOSSL
import CHarmonyIMAPTrust

struct ImapTrust {
    var configuration: TLSConfiguration
    let pins: Set<Data>

    init(host: String) throws {
        guard let snapshot = tb_imap_trust_open(host) else { throw ImapFailure.certificate }
        defer { tb_imap_trust_close(snapshot) }
        configuration = .makeClientConfiguration()
        configuration.trustRoots = .file("/etc/security/certificates")
        for index in 0..<tb_imap_trust_count(snapshot) {
            guard let pointer = tb_imap_trust_certificate(snapshot, index),
                  let value = String(validatingCString: pointer), !value.isEmpty else { throw ImapFailure.certificate }
            if value.hasPrefix("-----BEGIN CERTIFICATE-----") {
                configuration.additionalTrustRoots.append(.certificates(try NIOSSLCertificate.fromPEMBytes(Array(value.utf8))))
            } else {
                guard value.hasPrefix("/"), !value.contains("\0") else { throw ImapFailure.certificate }
                // NetStack returns trust-anchor directories too. NIOSSL's
                // additional .file roots only accept PEM files (unlike its
                // primary trustRoots setting, which also accepts directories).
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: value, isDirectory: &directory) else {
                    throw ImapFailure.certificate
                }
                let paths: [String]
                if directory.boolValue {
                    let entries = try FileManager.default.contentsOfDirectory(atPath: value).sorted()
                    guard entries.count <= 512 else { throw ImapFailure.certificate }
                    paths = entries.map { (value as NSString).appendingPathComponent($0) }
                } else { paths = [value] }
                for path in paths {
                    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
                    guard bytes.count <= 4 * 1024 * 1024 else { throw ImapFailure.certificate }
                    configuration.additionalTrustRoots.append(.certificates(
                        try NIOSSLCertificate.fromPEMBytes(Array(bytes))))
                }
            }
        }
        var parsed = Set<Data>()
        if let pointer = tb_imap_trust_pins(snapshot), let text = String(validatingCString: pointer), !text.isEmpty {
            for value in text.split(separator: ";", omittingEmptySubsequences: false) {
                guard value.hasPrefix("sha256//"), let pin = Data(base64Encoded: String(value.dropFirst(8))),
                      pin.count == 32 else { throw ImapFailure.certificate }
                parsed.insert(pin)
            }
        }
        pins = parsed
    }

    var verifyPeer: @Sendable (NIOSSLCertificate, Channel) -> EventLoopFuture<Void> {
        let pins = pins
        return { certificate, channel in
            do {
                if !pins.isEmpty {
                    let key = try certificate.extractPublicKey().toSPKIBytes()
                    var digest = [UInt8](repeating: 0, count: 32)
                    guard tb_imap_sha256(key, key.count, &digest) == 1,
                          pins.contains(Data(digest)) else { throw ImapFailure.certificate }
                }
                return channel.eventLoop.makeSucceededFuture(())
            } catch { return channel.eventLoop.makeFailedFuture(ImapFailure.certificate) }
        }
    }
}
