import CryptoKit
import Foundation
import Security

/// Signing in with the user's own ChatGPT account (OAuth with PKCE), and where the polishing requests go.
public enum ChatGPTOAuth {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let issuer = "https://auth.openai.com"
    public static let callbackPort: UInt16 = 1455
    public static let callbackPath = "/auth/callback"
    public static var redirectURI: String { "http://localhost:\(callbackPort)\(callbackPath)" }
    public static let responsesURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!

    public static func randomURLSafe(bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64URL(data)
    }

    public static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func authorizeURL(challenge: String, state: String) -> URL {
        var c = URLComponents(string: issuer + "/oauth/authorize")!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: "openid profile email offline_access"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "state", value: state),
            .init(name: "originator", value: "codex_cli_rs"),
        ]
        return c.url!
    }

    public static func tokenExchangeBody(code: String, verifier: String) -> Data {
        formBody([
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
            ("client_id", clientID), ("code_verifier", verifier),
        ])
    }

    public static func refreshBody(refreshToken: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "client_id": clientID, "grant_type": "refresh_token",
            "refresh_token": refreshToken, "scope": "openid profile email",
        ])
    }

    /// Parses `GET /auth/callback?code=..&state=..` from the browser redirect. The state is checked first, for an
    /// error too: any web page can send the browser to this port, and only the redirect of the login this device
    /// started may end it. The error text is kept as plain text: no control characters, at most 200 characters.
    public static func parseCallback(requestLine: String, expectedState: String) -> Result<String, CallbackError> {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let c = URLComponents(string: String(parts[1])) else { return .failure(.notCallback) }
        guard c.path == callbackPath else { return .failure(.notCallback) }
        let items = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard items["state"] == expectedState else { return .failure(.stateMismatch) }
        if let err = items["error"] { return .failure(.denied(plainText(items["error_description"] ?? err))) }
        guard let code = items["code"], !code.isEmpty else { return .failure(.notCallback) }
        return .success(code)
    }

    /// `text` without control characters (no terminal escape sequences), at most 200 characters.
    static func plainText(_ text: String) -> String {
        let kept = text.unicodeScalars.filter { $0.properties.generalCategory != .control }
        let clean = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > 200 ? String(clean.prefix(200)) + "…" : clean
    }

    public enum CallbackError: Error, Equatable {
        case notCallback, stateMismatch, denied(String)
    }

    // MARK: JWT claims (read-only; signature is checked by the server that issued it)

    public static func claims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    public static func expiry(_ jwt: String) -> Date? {
        (claims(jwt)?["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    public static func accountID(_ jwt: String) -> String? {
        (claims(jwt)?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
    }

    public static func email(_ jwt: String) -> String? {
        if let e = claims(jwt)?["email"] as? String { return e }
        return (claims(jwt)?["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String
    }

    public static func plan(_ jwt: String) -> String? {
        (claims(jwt)?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func formBody(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(pairs.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
            .joined(separator: "&").utf8)
    }
}

/// Request body and streamed-event parsing for the Responses endpoint.
public enum ResponsesRequest {
    public static func body(model: String, instructions: String, userText: String, fast: Bool) -> Data {
        var json: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": [["type": "message", "role": "user",
                       "content": [["type": "input_text", "text": userText]]]],
            "store": false,
            "stream": true,
            "reasoning": ["effort": "low"],
            "text": ["verbosity": "low"],
        ]
        if fast { json["service_tier"] = "priority" }
        return try! JSONSerialization.data(withJSONObject: json)
    }
}

public struct ResponsesStreamParser: Sendable {
    /// Output text so far: each content part in order (deltas, or the part's final text once it is done).
    public var text: String { parts.sorted { $0.key < $1.key }.map(\.value.text).joined() }
    /// A `response.completed` event arrived. Text without it is cut off and must not be used.
    public private(set) var completed = false
    public private(set) var failure: String?
    /// Some output text has arrived (for the stall timeout).
    public var sawText: Bool { parts.values.contains { !$0.text.isEmpty } }

    private struct PartKey: Comparable, Hashable, Sendable {
        let output: Int, content: Int
        static func < (a: PartKey, b: PartKey) -> Bool { (a.output, a.content) < (b.output, b.content) }
    }
    private var parts: [PartKey: (text: String, done: Bool)] = [:]

    public init() {}

    /// Feed one line of the `text/event-stream` body.
    public mutating func consume(line: String) {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        let key = PartKey(output: (event["output_index"] as? NSNumber)?.intValue ?? 0,
                          content: (event["content_index"] as? NSNumber)?.intValue ?? 0)
        switch type {
        case "response.output_text.delta":
            guard parts[key]?.done != true else { break }
            parts[key, default: ("", false)].text += event["delta"] as? String ?? ""
        case "response.output_text.done":
            // The final text of this one part; other parts are kept.
            if let full = event["text"] as? String, !full.isEmpty { parts[key] = (full, true) }
        case "response.completed":
            completed = true
        case "response.incomplete":
            // Stopped early (length limit, content filter): the text is partial.
            let response = event["response"] as? [String: Any]
            let reason = (response?["incomplete_details"] as? [String: Any])?["reason"] as? String
            failure = "整理结果不完整" + (reason.map { "（\($0)）" } ?? "")
        case "response.failed":
            let response = event["response"] as? [String: Any]
            let error = response?["error"] as? [String: Any]
            failure = error?["message"] as? String ?? "整理请求失败"
        case "error":
            failure = (event["message"] as? String) ?? ((event["error"] as? [String: Any])?["message"] as? String) ?? "整理请求失败"
        default:
            break
        }
    }

    /// What a finished stream produced: the text only when the response completed.
    public enum Outcome: Equatable, Sendable {
        case text(String)
        case failed(String)
        /// The stream ended without `response.completed` (connection closed mid-response).
        case cutOff
    }

    public var outcome: Outcome {
        if let failure { return .failed(failure) }
        return completed ? .text(text) : .cutOff
    }
}

/// Our own login's refresh token rotates on every use and other processes (a debug command, a second build)
/// may rotate it too, so the copy on disk can be newer than the one in memory.
public enum TokenRotation {
    /// Use the stored copy instead of refreshing with ours when it carries a different refresh token and was
    /// refreshed no earlier than ours: another process already rotated it.
    public static func preferStored(storedRefreshToken: String, storedLastRefresh: Date,
                                    currentRefreshToken: String, currentLastRefresh: Date) -> Bool {
        storedRefreshToken != currentRefreshToken && storedLastRefresh >= currentLastRefresh
    }

    /// A refresh failure that means the login is gone for good (revoked, expired or already used), as opposed
    /// to a passing server or network problem. Only these may delete the saved login.
    public static func isPermanentRefreshFailure(status: Int, body: String) -> Bool {
        if status == 401 { return true }
        guard status == 400 else { return false }
        let json = body.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let code = (json?["error"] as? String) ?? ((json?["error"] as? [String: Any])?["code"] as? String) ?? ""
        return ["invalid_grant", "refresh_token_reused", "refresh_token_expired", "refresh_token_invalidated"].contains(code)
    }

    /// What a refresh does after the server rejected its refresh token for good.
    public enum Recovery: Equatable, Sendable {
        /// The saved copy holds a refresh token not tried yet and an access token still valid: use it.
        case useStored
        /// The saved copy holds a refresh token not tried yet but its access token has expired too:
        /// refresh again with the saved refresh token.
        case refreshStored
        /// As `refreshStored`, but after `maxRefreshAttempts` tries in a row: keep the saved copy and report
        /// this failure; the next request starts over with it.
        case keepStored
        /// Nothing new on disk: the login is gone and the user must sign in again.
        case signOut
    }

    public static let maxRefreshAttempts = 3

    /// - Parameters:
    ///   - storedRefreshToken: the refresh token in the saved login file, nil when there is none.
    ///   - storedIsFresh: the saved access token is valid for a while yet.
    ///   - tried: refresh tokens this refresh already sent, the rejected one included.
    public static func recovery(storedRefreshToken: String?, storedIsFresh: Bool, tried: [String]) -> Recovery {
        guard let stored = storedRefreshToken, !stored.isEmpty, !tried.contains(stored) else { return .signOut }
        if storedIsFresh { return .useStored }
        return tried.count < maxRefreshAttempts ? .refreshStored : .keepStored
    }
}
