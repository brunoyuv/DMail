// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import FoundationNetworking
import Dispatch

enum NativeJmapError: String, Error {
    case unsafeEndpoint, untrustedApiOrigin, authenticationRequired, invalidResponse
    case responseTooLarge, redirectRejected, accountNotFound, mailNotSupported, network
    case invalidArgument, queryChanged
}

func jmapEndpoint(_ value: String) throws -> URL {
    guard !value.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 || $0 == "\\" }),
          let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil,
          url.user == nil, url.password == nil, url.fragment == nil else { throw NativeJmapError.unsafeEndpoint }
    return url
}
func sameJmapOrigin(_ a: URL, _ b: URL) -> Bool {
    a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() &&
        (a.port ?? 443) == (b.port ?? 443)
}

// A per-session URLProtocol lets the original client's async data(for:) API use
// a streaming delegate underneath, enforcing the limit before buffering a body.
final class JmapBoundedProtocol: URLProtocol {
    private let lock = NSLock()
    private var inner: URLSession?
    private var transfer: URLSessionDataTask?
    private var stopped = false
    private var bytes = 0
    private var body = Data()
    private var redirects = 0
    private var failure: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Corelibs invokes URLProtocol on its shared serial work queue. Creating
        // another session's task there synchronously re-enters that queue.
        let delegate = JmapStreamDelegate(owner: self)
        DispatchQueue.global().async { delegate.startLoading() }
    }
    fileprivate func startTransfer(delegate: JmapStreamDelegate) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        lock.lock()
        if stopped { lock.unlock(); session.invalidateAndCancel(); return }
        inner = session; transfer = task
        lock.unlock()
        task.resume()
    }
    override func stopLoading() {
        lock.lock(); stopped = true
        let session = inner; inner = nil; transfer = nil
        body = Data()
        lock.unlock()
        session?.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.lock()
        let original = self.request
        let allowed = !stopped && original.httpMethod == "GET" && redirects < 3 &&
            original.url != nil && request.url != nil && sameJmapOrigin(original.url!, request.url!)
        if allowed { redirects += 1 } else { failure = NativeJmapError.redirectRejected }
        lock.unlock()
        completionHandler(allowed ? request : nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        var error: Error?
        if let response = response as? HTTPURLResponse {
            if response.statusCode == 401 || response.statusCode == 403 { error = NativeJmapError.authenticationRequired }
            else if (300...399).contains(response.statusCode) { error = NativeJmapError.redirectRejected }
            else if !(200...299).contains(response.statusCode) { error = NativeJmapError.network }
            else if response.mimeType?.lowercased() != "application/json" { error = NativeJmapError.invalidResponse }
            else if response.expectedContentLength > 4 * 1024 * 1024 { error = NativeJmapError.responseTooLarge }
        } else { error = NativeJmapError.invalidResponse }
        lock.lock()
        if let error { failure = error }
        let accept = !stopped && failure == nil
        lock.unlock()
        if accept { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        completionHandler(accept ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let accept = !stopped && failure == nil && data.count <= 4 * 1024 * 1024 - bytes
        if accept { bytes += data.count; body.append(data) }
        else if !stopped && failure == nil { failure = NativeJmapError.responseTooLarge }
        lock.unlock()
        if !accept { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let notify = !stopped; stopped = true
        let result = failure ?? error
        let responseBody = body; body = Data()
        inner = nil; transfer = nil
        lock.unlock()
        if notify {
            if let result { client?.urlProtocol(self, didFailWithError: result) }
            else {
                // Corelibs' custom URLProtocol client replaces its responseData
                // on each didLoad callback. Deliver the bounded aggregate once.
                client?.urlProtocol(self, didLoad: responseBody)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        session.finishTasksAndInvalidate()
    }
}

func makeJmapTransport() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [JmapBoundedProtocol.self]
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 30
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    return URLSession(configuration: configuration)
}

// URLProtocol explicitly disallows Sendable conformance in corelibs. Keep its
// delegate separate; the owner's mutable state is protected by its lock.
fileprivate final class JmapStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private weak var owner: JmapBoundedProtocol?
    init(owner: JmapBoundedProtocol) { self.owner = owner }
    func startLoading() { owner?.startTransfer(delegate: self) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if let owner { owner.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler) }
        else { completionHandler(nil) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if let owner { owner.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler) }
        else { completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner?.urlSession(session, dataTask: dataTask, didReceive: data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let owner { owner.urlSession(session, task: task, didCompleteWithError: error) }
        else { session.finishTasksAndInvalidate() }
    }
}
