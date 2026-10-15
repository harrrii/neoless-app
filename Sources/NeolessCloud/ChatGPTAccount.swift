import Combine
import Foundation
import NeolessCore

public struct ChatGPTTokens: Codable, Equatable, Sendable {
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String
    public var accountID: String
    public var lastRefresh: Date

    public init(idToken: String, accessToken: String, refreshToken: String, accountID: String, lastRefresh: Date) {
        self.idToken = idToken; self.accessToken = accessToken; self.refreshToken = refreshToken
        self.accountID = accountID; self.lastRefresh = lastRefresh
    }
}

/// The ChatGPT login used for polishing: the user's own, refreshed and saved in `store`. The Mac app keeps it in
/// ~/Library/Application Support/neoless, the hub in ~/Library/Application Support/neoless-hub: same file name,
/// same format.
@MainActor
public final class ChatGPTAccount: ObservableObject {
    public struct Credential: Sendable {
        public let accessToken: String
        public let accountID: String

        public init(accessToken: String, accountID: String) {
            self.accessToken = accessToken; self.accountID = accountID
        }
    }

    /// Where our own login is saved: `store`'s folder, under this name.
    public nonisolated static let fileName = "chatgpt-auth.json"

    @Published public private(set) var tokens: ChatGPTTokens?
    @Published public private(set) var signingIn = false
    @Published public var message: String?

    public let store: DataFileStore
    private let file: String
    private let openURL: @MainActor (URL) -> Void
    private let didSignIn: @MainActor () -> Void
    private let session: URLSession
    private var refreshing: Task<ChatGPTTokens, Error>?
    private var callbackServer: OAuthCallbackServer?

    /// - Parameters:
    ///   - store: the folder the login is saved in (owner-only).
    ///   - openURL: opens the sign-in page in the browser (`NSWorkspace.open` in the Mac app, `open` on the hub).
    ///   - didSignIn: runs after a successful sign-in (the Mac app brings itself to the front).
    ///   - session: for the token requests (tests stub it).
    public init(store: DataFileStore, fileName: String = ChatGPTAccount.fileName,
                openURL: @escaping @MainActor (URL) -> Void, didSignIn: @escaping @MainActor () -> Void = {}, session: URLSession = .shared) {
        self.store = store
        self.file = fileName
        self.openURL = openURL
        self.didSignIn = didSignIn
        self.session = session
        tokens = store.read(ChatGPTTokens.self, from: fileName)
    }

    public var email: String? { tokens.flatMap { ChatGPTOAuth.email($0.idToken) } }
    public var plan: String? { tokens.flatMap { ChatGPTOAuth.plan($0.idToken) ?? ChatGPTOAuth.plan($0.accessToken) } }

    /// The account's email as the hub's health check shows it to other devices: "a***@example.org".
    public var maskedEmail: String? { email.map(Self.mask) }

    /// "alice@example.org" → "a***@example.org"; text without an @ keeps only its first character.
    public nonisolated static func mask(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@"), at > email.startIndex else {
            return email.isEmpty ? "" : String(email.prefix(1)) + "***"
        }
        return String(email[..<email.index(after: email.startIndex)]) + "***" + String(email[at...])
    }

    /// Short status for the settings page and the setup checklist.
    public var status: (ready: Bool, text: String) {
        if tokens != nil {
            return (true, "已登录 ChatGPT" + (email.map { "：\($0)" } ?? ""))
        }
        return (false, "还没登录，现在只输入原文，不整理")
    }

    public var isReady: Bool { status.ready }

    public func credential() async throws -> Credential {
        if var current = tokens {
            if (ChatGPTOAuth.expiry(current.accessToken) ?? .distantPast) < Date().addingTimeInterval(300) {
                current = try await refresh()
            }
            return Credential(accessToken: current.accessToken, accountID: current.accountID)
        }
        throw PolishError.notSignedIn
    }

    /// Refreshes the tokens; concurrent callers share one refresh. Refresh tokens rotate on every use and
    /// another process (`--test-polish`, a second build) may already have rotated ours, so the saved file is
    /// read again first, and again after the server rejects a refresh token: a newer saved login is used as
    /// is, or refreshed in turn when it has expired too. Only when nothing newer is saved is the login deleted.
    ///
    /// The refresh itself always runs to the end, even when the caller is cancelled (a polish timeout):
    /// cut off mid-flight it could leave a refresh token the server has already used. The caller just
    /// stops waiting. A process about to exit must call `waitForRefresh()` first.
    @discardableResult
    public func refresh() async throws -> ChatGPTTokens {
        if let refreshing { return try await Self.value(of: refreshing) }
        guard let current = tokens else { throw PolishError.notSignedIn }
        let task = Task { () throws -> ChatGPTTokens in
            defer { self.refreshing = nil }
            return try await self.rotate(from: current)
        }
        refreshing = task
        return try await Self.value(of: task)
    }

    /// Returns once no refresh is running, so exiting cannot strand a rotated token before it is saved
    /// (`--test-polish` after a polish timeout).
    public func waitForRefresh() async {
        while let refreshing { _ = await refreshing.result }
    }

    private func rotate(from start: ChatGPTTokens) async throws -> ChatGPTTokens {
        var current = start
        if let stored = newerStoredTokens(than: current) {
            tokens = stored
            current = stored
            if Self.isFresh(stored) { return stored }
        }
        var tried: [String] = []
        while true {
            tried.append(current.refreshToken)
            do {
                let next = try await Self.requestRefresh(current, session: session)
                // Signed out, or signed in again, while this was running: these belong to a login that is gone.
                guard tokens?.refreshToken == current.refreshToken else { throw PolishError.notSignedIn }
                tokens = next
                store.write(next, to: file)
                return next
            } catch {
                guard case let PolishError.http(code, body) = error,
                      TokenRotation.isPermanentRefreshFailure(status: code, body: body) else { throw error }
                // Our refresh token was already used: maybe by another process that saved a newer one.
                let stored = store.read(ChatGPTTokens.self, from: file)
                switch TokenRotation.recovery(storedRefreshToken: stored?.refreshToken,
                                              storedIsFresh: stored.map(Self.isFresh) ?? false, tried: tried) {
                case .useStored:
                    tokens = stored
                    return stored!
                case .refreshStored:
                    tokens = stored
                    current = stored!
                case .keepStored:
                    tokens = stored
                    throw error
                case .signOut:
                    // Revoked, expired or reused for good: the user must sign in again, and Settings says so too.
                    // Backups of the login file go too, so no other refresh token is left behind.
                    tokens = nil
                    store.purge(file)
                    throw PolishError.http(401, body)
                }
            }
        }
    }

    /// One refresh-token grant. Any answer but 200 throws `PolishError.http` with the server's text.
    private static func requestRefresh(_ current: ChatGPTTokens, session: URLSession) async throws -> ChatGPTTokens {
        var request = URLRequest(url: URL(string: ChatGPTOAuth.issuer + "/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = ChatGPTOAuth.refreshBody(refreshToken: current.refreshToken)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PolishError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        var next = current
        if let v = json["id_token"] as? String { next.idToken = v }
        if let v = json["access_token"] as? String { next.accessToken = v }
        if let v = json["refresh_token"] as? String { next.refreshToken = v }
        next.lastRefresh = Date()
        return next
    }

    /// The result of `task`, or CancellationError as soon as the caller is cancelled. `task` is not cancelled.
    private static func value<T: Sendable>(of task: Task<T, Error>) async throws -> T {
        let once = ResumeOnce<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.install(continuation)
                Task { once.resume(with: await task.result) }
            }
        } onCancel: {
            once.resume(with: .failure(CancellationError()))
        }
    }

    /// The saved login when another process rotated it after we loaded ours.
    private func newerStoredTokens(than current: ChatGPTTokens) -> ChatGPTTokens? {
        guard let stored = store.read(ChatGPTTokens.self, from: file),
              TokenRotation.preferStored(storedRefreshToken: stored.refreshToken, storedLastRefresh: stored.lastRefresh,
                                         currentRefreshToken: current.refreshToken, currentLastRefresh: current.lastRefresh)
        else { return nil }
        return stored
    }

    private static func isFresh(_ tokens: ChatGPTTokens) -> Bool {
        (ChatGPTOAuth.expiry(tokens.accessToken) ?? .distantPast) > Date().addingTimeInterval(300)
    }

    /// "Sign in with ChatGPT" in the default browser, PKCE with a localhost callback.
    public func signIn() async {
        guard !signingIn else { return }
        signingIn = true
        message = "已在浏览器打开 ChatGPT 登录页…"
        defer { signingIn = false; callbackServer = nil }

        let verifier = ChatGPTOAuth.randomURLSafe(bytes: 64)
        let state = ChatGPTOAuth.randomURLSafe(bytes: 32)
        let server = OAuthCallbackServer()
        callbackServer = server
        do {
            try server.start(port: ChatGPTOAuth.callbackPort)
        } catch {
            message = "登录页打不开：Codex 可能正在登录，稍后再试"
            return
        }
        openURL(ChatGPTOAuth.authorizeURL(challenge: ChatGPTOAuth.codeChallenge(for: verifier), state: state))
        do {
            let code = try await server.waitForCode(state: state, timeout: 300)
            var request = URLRequest(url: URL(string: ChatGPTOAuth.issuer + "/oauth/token")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = ChatGPTOAuth.tokenExchangeBody(code: code, verifier: verifier)
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id_token"] as? String, let access = json["access_token"] as? String,
                  let refresh = json["refresh_token"] as? String
            else { throw PolishError.http(status, String(data: data, encoding: .utf8) ?? "") }
            guard let account = ChatGPTOAuth.accountID(id) ?? ChatGPTOAuth.accountID(access) else {
                throw PolishError.failed("这个账号不能用 ChatGPT 整理")
            }
            let next = ChatGPTTokens(idToken: id, accessToken: access, refreshToken: refresh, accountID: account, lastRefresh: Date())
            tokens = next
            // An old login file that does not read back and cannot be backed up is never overwritten.
            message = store.write(next, to: file) ? "登录成功" : "登录成功，但没能保存登录信息，下次打开需要重新登录"
            didSignIn()
        } catch {
            server.stop()
            message = "登录没有完成：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    public func cancelSignIn() {
        callbackServer?.stop()
    }

    /// Deletes the login and any backup of it (`chatgpt-auth.json.corrupt-…`), which may still hold a working token.
    public func signOut() {
        tokens = nil
        store.purge(file)
        message = nil
    }
}

/// Resumes a continuation exactly once, whichever comes first: the result or a cancellation, which may
/// arrive before the continuation is even installed.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?

    func install(_ continuation: CheckedContinuation<T, Error>) {
        let early: Result<T, Error>? = lock.withLock {
            if result == nil { self.continuation = continuation }
            return result
        }
        if let early { continuation.resume(with: early) }
    }

    func resume(with result: Result<T, Error>) {
        let waiting: CheckedContinuation<T, Error>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }
}
