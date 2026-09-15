// MPL-2.0: https://mozilla.org/MPL/2.0/
// Harmony boundary around Thunderbird's original URL generation and XML models.
import Foundation
import FoundationNetworking
import Dispatch

public struct DiscoverySource: Codable, Sendable {
    public let name: String
    public let url: String
}
public struct DiscoveredServer: Codable, Sendable {
    public let protocolName: String, hostname: String, security: String, username: String
    public let port: Int
    public let authentication: [String]
    public let supported: Bool
    public let reason: String
}
public struct DiscoveryResult: Codable, Sendable {
    public let name: String, source: String
    public let incoming: [DiscoveredServer], outgoing: [DiscoveredServer]
}
public enum DiscoveryError: String, Error { case invalidAddress, invalidConfiguration, notFound }

public enum MailDiscovery {
    public static func sources(email: String) throws -> [DiscoverySource] {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard email.utf8.count <= 320, parts.count == 2, !parts[0].isEmpty,
              !email.contains(where: { $0.isWhitespace || $0.isNewline }),
              !email.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw DiscoveryError.invalidAddress
        }
        guard let domain = try? email.host, validHostname(domain) else { throw DiscoveryError.invalidAddress }
        return try Source.allCases.map { DiscoverySource(name: $0.description, url: try URL.autoconfig(email, source: $0).absoluteString) }
    }
    static func validHostname(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return host.utf8.count <= 253 && !labels.isEmpty && labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }
    public static func parse(_ data: Data, email: String, source: String) throws -> DiscoveryResult {
        _ = try sources(email: email)
        guard data.count <= 512 * 1024,
              let provider = try ClientConfig.parse(data, emailAddress: email).emailProvider,
              !provider.servers.isEmpty, provider.servers.count <= 64 else { throw DiscoveryError.invalidConfiguration }
        let servers = provider.servers.map { server -> DiscoveredServer in
            var reason = ""
            if !validHostname(server.hostname) || !(1...65535).contains(server.port) || server.username.isEmpty ||
                server.username.utf8.count > 1024 || server.username.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) ||
                server.username.contains(":") { reason = "invalidServer" }
            else if server.serverType != .imap && server.serverType != .smtp { reason = "unsupportedProtocol" }
            else if server.socketType != .ssl && !(server.serverType == .smtp && server.socketType == .startTLS) {
                reason = server.socketType == .startTLS ? "imapStarttlsPending" : "unsupportedSecurity"
            } else if !server.authentication.contains(.passwordCleartext) { reason = "unsupportedAuthentication" }
            return DiscoveredServer(protocolName: server.serverType.rawValue, hostname: server.hostname,
                security: server.socketType.rawValue, username: server.username, port: server.port,
                authentication: server.authentication.map(\.rawValue), supported: reason.isEmpty, reason: reason)
        }
        return DiscoveryResult(name: String(provider.displayName.prefix(256)), source: source,
            incoming: servers.filter { $0.protocolName != "smtp" }, outgoing: servers.filter { $0.protocolName == "smtp" })
    }
    // Failed/invalid sources fall through. A valid provider configuration retains
    // priority even when it describes authentication we cannot yet perform.
    public static func discover(email: String, fetch: (URL) throws -> Data) throws -> DiscoveryResult {
        for source in try sources(email: email) {
            if let result = try? parse(fetch(URL(string: source.url)!), email: email, source: source.name) { return result }
        }
        throw DiscoveryError.notFound
    }
}

// One request per Node-API worker. Streaming bounds apply before appending bytes;
// a separate wall deadline covers slow responses, redirects and cancellation.
private final class DiscoveryTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()
    private var error: Error?
    private var finished = false
    private var redirects = 0
    func fetch(_ url: URL) throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("application/xml, text/xml;q=0.9", forHTTPHeaderField: "Accept")
        session.dataTask(with: request).resume()
        if done.wait(timeout: .now() + 8) == .timedOut { finish(URLError(.timedOut)) }
        lock.lock(); defer { lock.unlock() }
        if let error { throw error }
        return data
    }
    private func finish(_ failure: Error?) {
        lock.lock()
        let notify = !finished
        if notify { finished = true; error = failure }
        lock.unlock()
        if notify { done.signal() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.lock()
        let url = request.url
        let allowed = !finished && redirects < 3 && url?.scheme == "https" && url?.host != nil &&
            url?.user == nil && url?.password == nil && url?.fragment == nil
        if allowed { redirects += 1 }
        lock.unlock()
        if !allowed { finish(URLError(.redirectToNonExistentLocation)) }
        completionHandler(allowed ? request : nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= 512 * 1024 else {
            finish(DiscoveryError.invalidConfiguration); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        let accept = !finished && chunk.count <= 512 * 1024 - data.count
        if accept { data.append(chunk) }
        lock.unlock()
        if !accept { finish(DiscoveryError.invalidConfiguration); dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { finish(error) }
}

private struct DiscoveryRequest: Decodable { let operation: String; let email: String; let document: String? }
private struct DiscoveryReply: Encodable {
    var sources: [DiscoverySource]?
    var configuration: DiscoveryResult?
    var error: String?
}
@_cdecl("thunderbird_discovery_request")
public func discoveryRequest(_ raw: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let raw, let string = String(validatingCString: raw), string.utf8.count <= 4 * 1024 * 1024 else { return nil }
    let result: DiscoveryReply
    do {
        let input = try JSONDecoder().decode(DiscoveryRequest.self, from: Data(string.utf8))
        switch input.operation {
        case "sources": result = DiscoveryReply(sources: try MailDiscovery.sources(email: input.email))
        case "parse":
            guard let document = input.document else { throw DiscoveryError.invalidConfiguration }
            result = DiscoveryReply(configuration: try MailDiscovery.parse(Data(document.utf8), email: input.email, source: "document"))
        case "discover": result = DiscoveryReply(configuration: try MailDiscovery.discover(email: input.email) { try DiscoveryTransfer().fetch($0) })
        default: throw DiscoveryError.invalidConfiguration
        }
    } catch { result = DiscoveryReply(error: (error as? DiscoveryError)?.rawValue ?? "invalidConfiguration") }
    guard let data = try? JSONEncoder().encode(result) else { return nil }
    // The shared Node-API bridge releases responses with Swift deallocate().
    let bytes = Array(data)
    let output = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
    for (index, byte) in bytes.enumerated() { output[index] = CChar(bitPattern: byte) }
    output[bytes.count] = 0
    return output
}
