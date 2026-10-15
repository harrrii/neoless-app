import Foundation
import NeolessCore

/// Minimal loopback HTTP listener for the OAuth redirect. Binds 127.0.0.1 and ::1 only.
public final class OAuthCallbackServer: @unchecked Sendable {
    public enum Failure: LocalizedError, Equatable {
        case bind, timeout, cancelled, denied(String)
        public var errorDescription: String? {
            switch self {
            case .bind: return "端口被占用"
            case .timeout: return "等待超时"
            case .cancelled: return "已取消"
            case .denied(let why): return why
            }
        }
    }

    private var sockets: [Int32] = []
    private let lock = NSLock()
    private var stopped = false

    public init() {}

    public func start(port: UInt16) throws {
        if let fd = Self.listen4(port: port) { sockets.append(fd) }
        if let fd = Self.listen6(port: port) { sockets.append(fd) }
        guard !sockets.isEmpty else { throw Failure.bind }
    }

    public func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            sockets.forEach { close($0) }
        }
    }

    public func waitForCode(state: String, timeout: TimeInterval) async throws -> String {
        let fds = sockets
        return try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread { [self] in
                let deadline = Date().addingTimeInterval(timeout)
                while true {
                    if lock.withLock({ stopped }) { continuation.resume(throwing: Failure.cancelled); return }
                    let remaining = deadline.timeIntervalSinceNow
                    if remaining <= 0 { stop(); continuation.resume(throwing: Failure.timeout); return }
                    var polls = fds.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
                    let ready = poll(&polls, nfds_t(polls.count), Int32(min(remaining, 1) * 1000))
                    guard ready > 0 else { continue }
                    for p in polls where p.revents & Int16(POLLIN) != 0 {
                        let client = accept(p.fd, nil, nil)
                        guard client >= 0 else { continue }
                        let line = Self.readRequestLine(client)
                        switch ChatGPTOAuth.parseCallback(requestLine: line, expectedState: state) {
                        case .success(let code):
                            Self.respond(client, status: "200 OK", body: Self.page("登录成功", "可以关闭这个页面，回到 neoless。"))
                            stop()
                            continuation.resume(returning: code)
                            return
                        case .failure(.denied(let why)):
                            Self.respond(client, status: "200 OK", body: Self.page("登录没有完成", why))
                            stop()
                            continuation.resume(throwing: Failure.denied(why))
                            return
                        case .failure(.stateMismatch):
                            Self.respond(client, status: "400 Bad Request", body: Self.page("登录请求不匹配", "请回到 neoless 重新点击登录。"))
                        case .failure(.notCallback):
                            Self.respond(client, status: "404 Not Found", body: "")
                        }
                    }
                }
            }
        }
    }

    private static func listen4(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        guard ok, Darwin.listen(fd, 8) == 0 else { close(fd); return nil }
        return fd
    }

    private static func listen6(port: UInt16) -> Int32? {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_loopback
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 }
        }
        guard ok, Darwin.listen(fd, 8) == 0 else { close(fd); return nil }
        return fd
    }

    private static func readRequestLine(_ fd: Int32) -> String {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 16_384 {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { break }
            data.append(buffer, count: n)
            if data.range(of: Data("\r\n".utf8)) != nil { break }
        }
        let text = String(decoding: data, as: UTF8.self)
        return text.components(separatedBy: "\r\n").first ?? ""
    }

    private static func respond(_ fd: Int32, status: String, body: String) {
        let bytes = Array(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        let all = Array(head.utf8) + bytes
        _ = all.withUnsafeBytes { send(fd, $0.baseAddress, all.count, 0) }
        close(fd)
    }

    private static func page(_ title: String, _ detail: String) -> String {
        let safe = detail.replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><meta charset="utf-8"><title>neoless</title>
        <body style="font:16px -apple-system,sans-serif;display:grid;place-items:center;height:90vh;color:#1d1d1f;background:#f6f6f8">
        <div style="text-align:center"><h2 style="font-weight:600">\(title)</h2><p style="color:#6e6e73">\(safe)</p></div>
        """
    }
}
