// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import NIOSSL
import IMAP

// Ephemeral local-only identity; production trust policy is never altered.
func fixtureTLSConfiguration(in directory: URL) throws -> TLSConfiguration {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let key = directory.appendingPathComponent("synthetic.key"), certificate = directory.appendingPathComponent("synthetic.crt")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    process.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path,
        "-out", certificate.path, "-days", "1", "-subj", "/CN=localhost"]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw IMAPError.commandFailed("Synthetic TLS certificate setup failed") }
    return TLSConfiguration.makeServerConfiguration(certificateChain: try NIOSSLCertificate.fromPEMFile(certificate.path).map { .certificate($0) },
        privateKey: .privateKey(try NIOSSLPrivateKey(file: key.path, format: .pem)))
}
