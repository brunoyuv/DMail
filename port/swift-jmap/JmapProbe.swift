// MPL-2.0: https://mozilla.org/MPL/2.0/
// Diagnostic client calls only; never linked into the mail application.
import Foundation
import JMAP

private struct Snapshot: Encodable {
    let username: String
    let mailboxNames: [String]
    let subjects: [String]
    let senders: [String]
    let received: [Double]
    let threadCount: Int
}

func runJmapProbe(_ scenario: String) async throws -> String {
    guard ["read", "unauthorized", "malformed", "mailboxChanges"].contains(scenario) else {
        throw URLError(.unsupportedURL)
    }
    let token = scenario == "unauthorized" ? "wrong-fixture-token" :
        scenario == "malformed" ? "malformed-fixture-token" : "native-jmap-fixture-token"
    let client = try await JMAPClient.session(Server(authorization: .bearer(token), host: "localhost", port: 9661))
    if scenario == "mailboxChanges" {
        let created = try await client.create(mailbox: Mailbox(name: "Private mailbox 84631", id: "new-folder"))
        guard let object = created?.created["new-folder"] as? [String: Any], let id = object["id"] as? String else {
            throw URLError(.cannotDecodeContentData)
        }
        let updatedMailbox = Mailbox(name: "Private renamed 84631", id: id)
        guard try await client.update(mailbox: updatedMailbox)?.updated == [id],
              try await client.destroy(mailbox: updatedMailbox)?.destroyed == [id] else {
            throw URLError(.cannotDecodeContentData)
        }
        return "NATIVE_JMAP_MAILBOX_CHANGES_OK"
    }
    let mailboxes = try await client.mailboxes()
    guard let inbox = mailboxes.first(where: { $0.role == .inbox }) else {
        throw URLError(.cannotDecodeContentData)
    }
    let emails = try await client.emails(in: inbox)
    guard let first = emails.first else { throw URLError(.cannotDecodeContentData) }
    let thread = try await client.thread(for: first)
    let snapshot = Snapshot(username: client.session?.username ?? "", mailboxNames: mailboxes.map(\.name),
                            subjects: emails.map { $0.subject ?? "" },
                            senders: emails.flatMap { $0.from?.flatMap { $0.addresses.map(\.value) } ?? [] },
                            received: emails.compactMap { $0.receivedAt?.timeIntervalSince1970 },
                            threadCount: thread.count)
    return String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
}
