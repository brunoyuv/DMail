// Isolated test driver for the original Thunderbird IMAP and MIME modules.
// This diagnostic is not shipped in the application.
import Foundation
import Dispatch
import IMAP
import NIOSSL
import MIME
import ImapAccountCore

private struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeFailure(message) }
}

private func session(mode: String, ca: String) async throws {
    var tls = TLSConfiguration.makeClientConfiguration()
    tls.trustRoots = .file(ca)
    let port = mode == "untrusted" ? 9762 : mode == "wronghost" ? 9763 : 9761
    let client = IMAPClient(Server(hostname: "localhost", username: mode,
                                   password: "fixture-password", port: port),
                            tlsConfiguration: tls, connectionTimeout: .seconds(3),
                            commandTimeout: mode == "stall" ? 1 : 5)
    var stage = "connect"
    let start = Date()
    do {
        try await client.connect()
        stage = "login"
        try await client.login()
        stage = "list"
        let folders = try await client.list()
        try check(Set(folders.map { $0.0.path.name.description }) == ["INBOX", "Archive"], "Folder names differ")
        try check(folders.first { $0.0.path.name.description == "INBOX" }?.1?.unseenCount == 1, "Unread count differs")
        stage = "select"
        let status = try await client.select(mailbox: "INBOX")
        try check(status.messageCount == 1 && status.uidValidity == 77 && status.nextUID == 43, "Mailbox UID state differs")
        stage = "fetch"
        let message = try await client.fetch(uid: 42, attributes: .complete)
        try check(mode == "reader", "Negative scenario unexpectedly succeeded")
        try check(message.uid == 42 && message.flags.isEmpty, "UID or flags differ")
        try check(message.envelope.subject == "Native IMAP fixture", "Subject differs")
        try check(message.body?.contentTransferEncoding == .base64, "MIME transfer encoding differs")
        guard let encoded = message.body?.part.data,
              let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              let text = String(data: decoded, encoding: .utf8) else { throw ProbeFailure("MIME body missing") }
        try check(text == "Hello from Thunderbird IMAP. 日本語 ✓", "Unicode body differs")
        stage = "logout"
        try await client.logout()
        try await client.shutdown()
        try check(!client.isConnected, "Channel remains connected after shutdown")
    } catch {
        try? await client.shutdown()
        if error is ProbeFailure { throw error }
        let elapsed = Date().timeIntervalSince(start)
        switch mode {
        case "untrusted", "wronghost": try check(stage == "connect", "TLS accepted before rejection")
        case "bad": try check(stage == "login", "Wrong failure stage for bad credentials")
        case "stall": try check(stage == "fetch" && elapsed >= 0.9 && elapsed < 3, "Command timeout not bounded")
        case "drop", "oversized", "wrongtag":
            try check(stage == "fetch" && elapsed < 3, "Protocol failure was not rejected promptly")
        case "cancel":
            try check(stage == "fetch" && error is CancellationError && elapsed < 3, "Cancellation did not close pending fetch")
        default: throw ProbeFailure("\(stage): \(error)")
        }
        try check(!client.isConnected, "Failed session remains connected")
    }
}

// Semaphore supplies synchronization for this C entry point's result.
private final class ProbeResult: @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    var status: Int32 = 1
}

@_cdecl("thunderbird_imap_probe")
public func imapProbe(_ modePointer: UnsafePointer<CChar>, _ caPointer: UnsafePointer<CChar>) -> Int32 {
    let mode = String(cString: modePointer), ca = String(cString: caPointer)
    let result = ProbeResult()
    let task = Task {
        do {
            if mode == "bodies" { try bodyFixtures(ca: ca) }
            else { for _ in 0..<(mode == "reader" ? 3 : 1) { try await session(mode: mode, ca: ca) } }
            print("THUNDERBIRD_IMAP_OK \(mode)")
            result.status = 0
        } catch { print("THUNDERBIRD_IMAP_FAIL \(mode): \(error)") }
        result.finished.signal()
    }
    if mode == "cancel" {
        Task { try? await Task.sleep(for: .milliseconds(500)); task.cancel() }
    }
    // C driver also has an alarm, covering runtime or shutdown deadlocks.
    result.finished.wait()
    return result.status
}

private func bodyFixtures(ca: String) throws {
    // Counts are the assertions in upstream AccountTests/EmailBodyTests.swift.
    let expected: [(String, Int, Int?, Int?)] = [
        ("2EA571DD",0,4239,nil),("976C6A94",0,27271,1842),("86925F24",0,3243,2172),
        ("7A690F43",0,nil,1591),("60EB5CAE",0,nil,2387),("F02140B7",1,2741,nil),
        ("BFA06D93",0,65621,599),("89526045",0,8072,nil),("E18BEE81",0,18084,962),
        ("2874E3C9",1,34165,nil),("1759430F",0,15687,2916),("E1FA0690",0,126076,15450),
        ("CFD4D3A3",5,5644,1492)]
    let folder = URL(fileURLWithPath: ca).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("mime-fixtures")
    for (id,attachments,html,text) in expected {
        let value = try EmailBody(body: Body(Data(contentsOf: folder.appendingPathComponent("mime-body-\(id).eml"))))
        try check(value.attachments.count == attachments && value.html(.none)?.count == html && value.text?.count == text,
                  "Original Account body fixture \(id) differs")
    }
}
