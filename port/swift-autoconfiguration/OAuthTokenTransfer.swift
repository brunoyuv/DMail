// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import FoundationNetworking
import Dispatch

public enum OAuthTransferError: String, Error {
    case network, rejected, responseTooLarge, redirectRejected
    case invalid_client, invalid_grant, invalid_request, unauthorized_client, invalid_scope, access_denied

    // Only standard protocol codes cross the bridge, never provider descriptions
    // or arbitrary response text (which can include credentials or account data).
    static func rejection(_ data: Data) -> OAuthTransferError {
        struct Rejection: Decodable { let error: String }
        guard let value = try? JSONDecoder().decode(Rejection.self, from: data) else { return .rejected }
        // These standard failures describe a temporary provider condition,
        // not an invalid refresh token. Keep the saved credentials and do not
        // turn them into a browser reconnect prompt or replay this POST.
        if ["server_error", "temporarily_unavailable"].contains(value.error) { return .network }
        guard let code = OAuthTransferError(rawValue: value.error),
              [Self.invalid_client, .invalid_grant, .invalid_request, .unauthorized_client,
               .invalid_scope, .access_denied].contains(code) else { return .rejected }
        return code
    }
}

// Token POSTs must never follow redirects or resend a code automatically.
// A worker owns each transfer until its bounded response or deadline completes.
final class OAuthTokenTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()
    private var error: Error?
    private var finished = false
    private var status = 0
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        super.init()
    }

    func submit(_ input: URLRequest) throws -> Data {
        let config = configuration
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = input
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        session.dataTask(with: request).resume()
        if done.wait(timeout: .now() + 15) == .timedOut { finish(OAuthTransferError.network) }
        lock.lock(); defer { lock.unlock() }
        if let error { throw error }
        if status == 429 || (500...599).contains(status) { throw OAuthTransferError.network }
        guard status == 200 else { throw OAuthTransferError.rejection(data) }
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
        finish(OAuthTransferError.redirectRejected)
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= 65536 else {
            finish(OAuthTransferError.responseTooLarge); completionHandler(.cancel); return
        }
        lock.lock(); status = response.statusCode; lock.unlock()
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        let accept = !finished && chunk.count <= 65536 - data.count
        if accept { data.append(chunk) }
        lock.unlock()
        if !accept { finish(OAuthTransferError.responseTooLarge); dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error == nil ? nil : OAuthTransferError.network)
    }
}
