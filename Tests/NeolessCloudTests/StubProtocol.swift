import Foundation
@testable import NeolessCloud

/// Answers URLSession requests in tests, per host, so suites running side by side never share answers.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        /// Headers after `delay` with the first `leading` bytes of the body (a slow link that has started to bring
        /// it down), the rest `bodyDelay` later.
        case respond(status: Int, headers: [String: String] = [:], body: Data = Data(), delay: TimeInterval = 0,
                     bodyDelay: TimeInterval = 0, leading: Int = 0)
        /// A URLError after `delay`.
        case fail(URLError.Code, delay: TimeInterval = 0)
        /// Never answers (a network that swallows the connection).
        case hang
        /// A redirect to `location` (as Cloudflare Access sends to its login page). Whether it is followed is the
        /// session's (its delegate's) call; when it is not, the redirect itself is the answer.
        case redirect(status: Int, location: String, headers: [String: String] = [:])
    }

    struct Seen: @unchecked Sendable {
        let request: URLRequest
        let body: Data
    }

    /// Gets the request, its body and how many requests to this host came before it.
    typealias Handler = @Sendable (URLRequest, Data, Int) -> Reply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var seen: [String: [Seen]] = [:]
    private static let queue = DispatchQueue(label: "stub-protocol")

    static func register(host: String, _ handler: @escaping Handler) {
        lock.withLock {
            handlers[host] = handler
            seen[host] = []
        }
    }

    static func requests(host: String) -> [Seen] { lock.withLock { seen[host] ?? [] } }

    static func remove(host: String) {
        lock.withLock {
            handlers[host] = nil
            seen[host] = nil
        }
    }

    /// A session whose requests all go to `StubProtocol`.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private let stateLock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        let (handler, index): (Handler?, Int) = Self.lock.withLock {
            let index = Self.seen[host]?.count ?? 0
            Self.seen[host, default: []].append(Seen(request: request, body: body))
            return (Self.handlers[host], index)
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch handler(request, body, index) {
        case .hang:
            return
        case .redirect(let status, let location, let headers):
            later(0) { this in
                var fields = headers
                fields["Location"] = location
                let response = HTTPURLResponse(url: this.request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                               headerFields: fields)!
                var next = URLRequest(url: URL(string: location, relativeTo: this.request.url)!.absoluteURL)
                next.allHTTPHeaderFields = this.request.allHTTPHeaderFields
                this.client?.urlProtocol(this, wasRedirectedTo: next, redirectResponse: response)
                // Not followed: the redirect is the answer.
                this.later(0.05) { this in
                    this.client?.urlProtocol(this, didReceive: response, cacheStoragePolicy: .notAllowed)
                    this.client?.urlProtocolDidFinishLoading(this)
                }
            }
        case .fail(let code, let delay):
            later(delay) { $0.client?.urlProtocol($0, didFailWithError: URLError(code)) }
        case .respond(let status, let headers, let data, let delay, let bodyDelay, let leading):
            later(delay) { this in
                let response = HTTPURLResponse(url: this.request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                               headerFields: headers)!
                this.client?.urlProtocol(this, didReceive: response, cacheStoragePolicy: .notAllowed)
                let first = data.prefix(max(0, leading)), rest = data.dropFirst(first.count)
                if !first.isEmpty { this.client?.urlProtocol(this, didLoad: Data(first)) }
                this.later(bodyDelay) { this in
                    if !rest.isEmpty { this.client?.urlProtocol(this, didLoad: Data(rest)) }
                    this.client?.urlProtocolDidFinishLoading(this)
                }
            }
        }
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
    }

    private func later(_ delay: TimeInterval, _ work: @escaping (StubProtocol) -> Void) {
        Self.queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard !stateLock.withLock({ stopped }) else { return }
            work(self)
        }
    }

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// A unique host for one test.
func stubHost() -> String { "hub-\(UUID().uuidString.lowercased()).test" }

/// JSON for `.respond` bodies, as the hub writes it.
func json<T: Encodable>(_ value: T) -> Data {
    try! HubJSON.encode(value)
}

/// A throwaway UserDefaults suite, one test at a time, removed afterwards (file included).
func withTestDefaults<T>(_ body: (UserDefaults) throws -> T) throws -> T {
    try testDefaultsLock.withLock {
        let suite = "app.neoless.tests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            let file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suite).plist")
            try? FileManager.default.removeItem(at: file)
        }
        return try body(defaults)
    }
}

private let testDefaultsLock = NSLock()

/// A temporary folder for one test's data files, deleted by `removeTemporary`.
func temporaryDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neoless-cloud-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func removeTemporary(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}
