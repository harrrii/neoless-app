import Foundation
import NeolessCore

public enum PolishError: LocalizedError, Equatable, Sendable {
    case notSignedIn, http(Int, String), failed(String), empty, timeout, incomplete

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return "未登录 ChatGPT"
        case .http(401, _), .http(403, _): return "ChatGPT 登录已失效，请在设置里重新登录"
        case .http(429, _): return "ChatGPT 额度暂时用完或请求太频繁"
        case .http(let code, _): return "ChatGPT 暂时出错（\(code)），稍后再试"
        case .failed(let why): return "整理失败：\(why)"
        case .empty: return "整理结果为空"
        case .timeout: return "整理超时"
        case .incomplete: return "整理没有完成：连接中途断开，结果不完整"
        }
    }

    /// A few words for the HUD: "ChatGPT 登录已失效".
    public var short: String {
        switch self {
        case .notSignedIn: return "未登录 ChatGPT"
        case .http(401, _), .http(403, _): return "ChatGPT 登录已失效"
        case .http(429, _): return "ChatGPT 额度暂时用完"
        case .http: return "ChatGPT 出错"
        case .failed: return "整理失败"
        case .empty: return "整理结果为空"
        case .timeout: return "整理超时"
        case .incomplete: return "整理中断"
        }
    }
}

/// A polish failure as the HUD says it (a few words) and as History keeps it (with details).
public enum PolishFailure {
    public static func short(_ error: Error) -> String {
        if let e = error as? PolishError { return e.short }
        return FailureText.short(error) ?? "整理失败"
    }

    public static func detail(_ error: Error) -> String {
        if let e = error as? PolishError { return e.errorDescription ?? e.short }
        return "整理失败：" + (FailureText.detail(error) ?? error.localizedDescription)
    }
}

/// Runs `operation`, throwing `PolishError.timeout` if it takes longer than `seconds`.
public func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw PolishError.timeout
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
