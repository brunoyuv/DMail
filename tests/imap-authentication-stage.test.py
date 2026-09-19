#!/usr/bin/env python3
"""Exercise shipping Swift input checks and safe error mapping without a socket."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class AuthenticationStageTests(unittest.TestCase):
    def test_connection_validation_and_error_mapping(self):
        models = (ROOT / 'port/swift-imap/ImapModels.swift').read_text()
        core = (ROOT / 'port/swift-imap/ImapAccountCore.swift').read_text()
        # Compile the real request, validator and mapper, with a minimal reply
        # shape so this check requires neither an IMAP server nor NIO dependencies.
        models = models.split('struct ImapNullable', 1)[0].replace('import IMAP\n', '')
        connection = 'struct ImapConnection: Sendable {' + core.split('struct ImapConnection: Sendable {', 1)[1].split('private func bodyPreview', 1)[0]
        trace = 'private func imapTraceError' + core.split('private func imapTraceError', 1)[1].split('private struct Epoch', 1)[0]
        source = models + '\n' + connection + '\n' + trace + r'''
enum AuthenticationFailure: Error { case rejected }
struct ImapReply: Encodable {
    var error: String?
    var authenticationStage: String? = nil
}
func request(_ operation: String = "connect", token: String = "synthetic-token", username: String? = "synthetic@example.test") throws -> ImapRequest {
    var value: [String: String] = ["operation": operation, "sessionUrl": "imaps://synthetic.test:993", "authorization": "Bearer \(token)"]
    value["username"] = username
    return try JSONDecoder().decode(ImapRequest.self, from: JSONSerialization.data(withJSONObject: value))
}
func checkReply(_ error: any Error, _ operation: String, code: String, stage: String?) throws {
    let reply = imapFailureReply(error)
    precondition(reply.error == code && reply.authenticationStage == stage)
    let output = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
    precondition(!output.contains("synthetic-private-response"))
    if stage == nil { precondition(!output.contains("authenticationStage")) }
}
let valid = try ImapConnection(request())
precondition(valid.username == "synthetic@example.test" && valid.accessToken == "synthetic-token")
for operation in ["connect", "mailboxes", "readEmail", "setKeyword", "watchInbox"] {
    let malformed = [try request(operation, username: nil), try request(operation, username: ""),
        try request(operation, username: "synthetic\nprivate"), try request(operation, token: ""),
        try request(operation, token: "synthetic token"), try request(operation, token: String(repeating: "x", count: 32769))]
    for input in malformed {
        do { _ = try ImapConnection(input); preconditionFailure("Malformed credentials accepted") }
        catch {
            try checkReply(error, operation, code: "authenticationRequired", stage: "credentials")
            precondition((imapTraceError(error) as? ImapFailure) == .authenticationRequired)
        }
    }
    let rejected = ImapAuthenticationStage.server
    try checkReply(rejected, operation, code: "authenticationRequired", stage: "server")
    precondition((imapTraceError(rejected) as? AuthenticationFailure) == .rejected)
    try checkReply(ImapFailure.network, operation, code: "network", stage: nil)
    try checkReply(ImapFailure.authenticationRequired, operation, code: "authenticationRequired", stage: nil)
    try checkReply(NSError(domain: "synthetic-private-response", code: 1), operation, code: "network", stage: nil)
}
precondition((imapTraceError(ImapFailure.network) as? ImapFailure) == .network)
print("Connection validation and safe authentication mapping passed")
'''
        with tempfile.TemporaryDirectory(prefix='dmail-auth-stage-') as directory:
            directory = Path(directory)
            fixture = directory / 'main.swift'
            fixture.write_text(source)
            result = subprocess.run([str(ROOT / '.tools/swift/usr/bin/swift'),
                '-module-cache-path', str(directory / 'cache'), str(fixture)],
                text=True, capture_output=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('safe authentication mapping passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
