// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import Foundation
import FoundationNetworking
import Dispatch

private struct Request: Decodable { let url: String?; let cancelAfterMs: Int?; let jmap: String? }
private struct Reply: Encodable {
    var status = 0
    var body = ""
    var errorCode = 0
    var errorMessage = ""
}
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reply = Reply()
    func set(_ value: Reply) { lock.lock(); defer { lock.unlock() }; reply = value }
    func get() -> Reply { lock.lock(); defer { lock.unlock() }; return reply }
}

// A diagnostic entry point used only in org.thunderbird.harmony.nettest.
@_cdecl("thunderbird_network_probe")
public func networkProbe(_ input: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let input, let string = String(validatingCString: input),
        let request = try? JSONDecoder().decode(Request.self, from: Data(string.utf8)) else { return nil }
    let result = ResultBox()
    let done = DispatchSemaphore(value: 0)
    let task = Task {
        defer { done.signal() }
        if let scenario = request.jmap {
            do { result.set(Reply(body: try await runJmapProbe(scenario))) }
            catch {
                let error = error as NSError
                result.set(Reply(errorCode: error.code, errorMessage: error.localizedDescription))
            }
            return
        }
        guard let rawURL = request.url, let url = URL(string: rawURL) else {
            result.set(Reply(errorCode: -1000, errorMessage: "Invalid probe URL")); return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(from: url)
            result.set(Reply(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                             body: String(decoding: data, as: UTF8.self)))
        } catch {
            let error = error as NSError
            result.set(Reply(errorCode: error.code, errorMessage: error.localizedDescription))
        }
    }
    if let delay = request.cancelAfterMs {
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delay)) { task.cancel() }
    }
    if done.wait(timeout: .now() + 20) == .timedOut {
        task.cancel()
        result.set(Reply(errorCode: -1001, errorMessage: "Probe deadline exceeded"))
    }
    guard let encoded = try? JSONEncoder().encode(result.get()) else { return nil }
    let output = UnsafeMutablePointer<CChar>.allocate(capacity: encoded.count + 1)
    for (index, byte) in encoded.enumerated() { output[index] = CChar(bitPattern: byte) }
    output[encoded.count] = 0
    return output
}

@_cdecl("thunderbird_network_probe_free")
public func freeNetworkProbe(_ output: UnsafeMutablePointer<CChar>?) { output?.deallocate() }
