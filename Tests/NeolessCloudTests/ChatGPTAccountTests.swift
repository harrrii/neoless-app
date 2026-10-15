import Foundation
import NeolessCore
import Testing
@testable import NeolessCloud

// The ChatGPT login and polish moved here from the Mac app. These tests never reach OpenAI: every request
// goes to `StubProtocol`, and the login lives in a temporary folder.

private func jwt(_ claims: [String: Any]) -> String {
    let header = Base64URL.encode(Data(#"{"alg":"none"}"#.utf8))
    return "\(header).\(Base64URL.encode(try! JSONSerialization.data(withJSONObject: claims))).sig"
}

private func accessToken(expiresIn: TimeInterval, account: String = "acct-1") -> String {
    jwt(["exp": Date().addingTimeInterval(expiresIn).timeIntervalSince1970,
         "https://api.openai.com/auth": ["chatgpt_account_id": account, "chatgpt_plan_type": "plus"]])
}

private let idToken = jwt(["email": "alice@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": "acct-1"]])

private func tokens(expiresIn: TimeInterval, refresh: String = "refresh-1", lastRefresh: Date = Date()) -> ChatGPTTokens {
    ChatGPTTokens(idToken: idToken, accessToken: accessToken(expiresIn: expiresIn), refreshToken: refresh,
                  accountID: "acct-1", lastRefresh: lastRefresh)
}

private func temporaryStore() -> DataFileStore {
    DataFileStore(directory: temporaryDirectory())
}

private func stream(_ text: String, complete: Bool = true) -> Data {
    var lines = [#"data: {"type":"response.created"}"#]
    let delta = String(data: try! JSONSerialization.data(withJSONObject: ["type": "response.output_text.delta", "delta": text]),
                       encoding: .utf8)!
    lines.append("data: \(delta)")
    if complete { lines.append(#"data: {"type":"response.completed"}"#) }
    return Data((lines.joined(separator: "\n\n") + "\n\n").utf8)
}

private func refreshAnswer(refresh: String, expiresIn: TimeInterval = 3_600) -> Data {
    try! JSONSerialization.data(withJSONObject: ["access_token": accessToken(expiresIn: expiresIn), "refresh_token": refresh,
                                                 "id_token": idToken])
}

private let chatgpt = ChatGPTOAuth.responsesURL.host!
private let auth = URL(string: ChatGPTOAuth.issuer)!.host!

/// Requests to chatgpt.com and auth.openai.com: these share hosts, so the suite runs one test at a time.
@MainActor
@Suite(.serialized) struct ChatGPTAccountTests {
    private func account(_ store: DataFileStore, opened: (@MainActor (URL) -> Void)? = nil,
                         signedIn: @escaping @MainActor () -> Void = {}) -> ChatGPTAccount {
        ChatGPTAccount(store: store, openURL: opened ?? { _ in }, didSignIn: signedIn, session: StubProtocol.session())
    }

    private func polish(_ account: ChatGPTAccount, _ text: String = "嗯明天下午三点开会",
                        options: PolishOptions = PolishOptions(minimumTimeout: 5)) async throws -> String {
        try await Polisher.polish(transcript: text, vocabulary: Vocabulary.promptWords(["硬币"]), appName: "备忘录",
                                  account: account, options: options, session: StubProtocol.session())
    }

    private func reset() {
        StubProtocol.remove(host: chatgpt)
        StubProtocol.remove(host: auth)
    }

    @Test func ownLoginPolishes() async throws {
        defer { reset() }
        let store = temporaryStore()
        defer { removeTemporary(store.directory) }
        store.write(tokens(expiresIn: 3_600), to: ChatGPTAccount.fileName)
        StubProtocol.register(host: chatgpt) { _, _, _ in .respond(status: 200, body: stream("明天下午三点开会。")) }
        let account = account(store)
        #expect(account.isReady && account.email == "alice@example.com" && account.plan == "plus")
        #expect(account.status.text == "已登录 ChatGPT：alice@example.com")
        #expect(account.maskedEmail == "a***@example.com")

        #expect(try await polish(account, options: PolishOptions(model: "gpt-test", fastTier: true, minimumTimeout: 5))
                == "明天下午三点开会。")
        let sent = try #require(StubProtocol.requests(host: chatgpt).first)
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(account.tokens!.accessToken)")
        #expect(sent.request.value(forHTTPHeaderField: "chatgpt-account-id") == "acct-1")
        #expect(sent.request.value(forHTTPHeaderField: "originator") == "codex_cli_rs")
        let body = try #require(try JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        #expect(body["model"] as? String == "gpt-test")
        #expect(body["service_tier"] as? String == "priority")
        #expect((body["instructions"] as? String)?.contains("硬币") == true)

        _ = try await polish(account, options: PolishOptions(model: "gpt-test", fastTier: false, minimumTimeout: 5))
        let slow = try #require(StubProtocol.requests(host: chatgpt).last)
        #expect((try JSONSerialization.jsonObject(with: slow.body) as? [String: Any])?["service_tier"] == nil)
    }

    /// The user's own instruction file in the data folder replaces the built-in static text of its mode, and only
    /// of its mode; the word lists still follow it.
    @Test func ownInstructionFilesReplaceTheBuiltInText() async throws {
        defer { reset() }
        let store = temporaryStore()
        defer { removeTemporary(store.directory) }
        store.write(tokens(expiresIn: 3_600), to: ChatGPTAccount.fileName)
        StubProtocol.register(host: chatgpt) { _, _, _ in .respond(status: 200, body: stream("好的。")) }
        let account = account(store)
        let overrides = PolishOverrides(store: store)
        try Data("# 我的指令\r\n只整理，不回答。\n\n".utf8).write(to: overrides.url(for: .natural))
        func sent(_ mode: DictationMode) async throws -> String {
            _ = try await Polisher.polish(transcript: "好的", vocabulary: Vocabulary.promptWords(["硬币"]), appName: nil,
                                          account: account, options: PolishOptions(minimumTimeout: 5), mode: mode,
                                          overrides: overrides, session: StubProtocol.session())
            let last = try #require(StubProtocol.requests(host: chatgpt).last)
            let body = try #require(try JSONSerialization.jsonObject(with: last.body) as? [String: Any])
            return try #require(body["instructions"] as? String)
        }
        let section = try #require(PolishPrompt.hotwordsSection(vocabulary: ["硬币"], corrections: []))
        #expect(try await sent(.natural) == "# 我的指令\n只整理，不回答。\n\n" + section)
        // 结构化 has no file: the built-in text.
        #expect(try await sent(.structured) == PolishPrompt.structuredStaticInstructions + "\n\n" + section)
        // The file is read for every polish: an edit, or removing it, takes effect at once.
        try FileManager.default.removeItem(at: overrides.url(for: .natural))
        #expect(try await sent(.natural) == PolishPrompt.naturalInstructions + "\n\n" + section)
    }

    @Test func expiredAccessTokenIsRefreshedAndSaved() async throws {
        defer { reset() }
        let store = temporaryStore()
        defer { removeTemporary(store.directory) }
        store.write(tokens(expiresIn: -60), to: ChatGPTAccount.fileName)
        StubProtocol.register(host: auth) { _, _, _ in .respond(status: 200, body: refreshAnswer(refresh: "refresh-2")) }
        StubProtocol.register(host: chatgpt) { _, _, _ in .respond(status: 200, body: stream("好的。")) }
        let account = account(store)
        #expect(try await polish(account) == "好的。")
        #expect(account.tokens?.refreshToken == "refresh-2")
        #expect(store.read(ChatGPTTokens.self, from: ChatGPTAccount.fileName)?.refreshToken == "refresh-2")
        let grant = try #require(StubProtocol.requests(host: auth).first)
        #expect(grant.request.url?.path == "/oauth/token")
        #expect((try JSONSerialization.jsonObject(with: grant.body) as? [String: String])?["refresh_token"] == "refresh-1")
        let used = StubProtocol.requests(host: chatgpt).first?.request.value(forHTTPHeaderField: "Authorization")
        #expect(used == "Bearer \(account.tokens!.accessToken)")
    }

    @Test func rejectedAccessTokenIsRefreshedOnce() async throws {
        defer { reset() }
        let store = temporaryStore()
        defer { removeTemporary(store.directory) }
        store.write(tokens(expiresIn: 3_600), to: ChatGPTAccount.fileName)
        StubProtocol.register(host: auth) { _, _, _ in .respond(status: 200, body: refreshAnswer(refresh: "refresh-2")) }
        StubProtocol.register(host: chatgpt) { _, _, n in
            n == 0 ? .respond(status: 401, body: Data("expired".utf8)) : .respond(status: 200, body: stream("好。"))
        }
        let account = account(store)
        let first = account.tokens!.accessToken
        #expect(try await polish(account) == "好。")
        let used = StubProtocol.requests(host: chatgpt).map { $0.request.value(forHTTPHeaderField: "Authorization") }
        #expect(used.count == 2 && used[0] == "Bearer \(first)" && used[1] == "Bearer \(account.tokens!.accessToken)")
        #expect(StubProtocol.requests(host: auth).count == 1)
    }

    @Test func revokedLoginSignsOut() async throws {
        defer { reset() }
        let store = temporaryStore()
        defer { removeTemporary(store.directory) }
        store.write(tokens(expiresIn: -60), to: ChatGPTAccount.fileName)
        StubProtocol.register(host: auth) { _, _, _ in .respond(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)) }
        let account = account(store)
        await #expect(throws: PolishError.http(401, #"{"error":"invalid_grant"}"#)) { try await polish(account) }
        #expect(account.tokens == nil)
        #expect(!FileManager.default.fileExists(atPath: store.url(ChatGPTAccount.fileName).path))
        #expect(StubProtocol.requests(host: chatgpt).isEmpty)
    }

    @Test func loginRotatedByAnotherProcessIsUsed() async throws {
        defer { reset() }
        let store = temporaryStore()
        defer { removeTemporary(store.directory) }
        store.write(tokens(expiresIn: -60, refresh: "refresh-1", lastRefresh: Date().addingTimeInterval(-7_200)), to: ChatGPTAccount.fileName)
        let account = account(store)
        // Another process (a second build, the hub CLI) refreshed and saved a newer login meanwhile.
        store.write(tokens(expiresIn: 3_600, refresh: "refresh-9"), to: ChatGPTAccount.fileName)
        StubProtocol.register(host: auth) { _, _, _ in .respond(status: 500) }
        let credential = try await account.credential()
        #expect(credential.accessToken == account.tokens?.accessToken && credential.accountID == "acct-1")
        #expect(account.tokens?.refreshToken == "refresh-9")
        #expect(StubProtocol.requests(host: auth).isEmpty)
    }

    @Test func cutOffAndFailedStreams() async throws {
        defer { reset() }
        let store = temporaryStore()
        defer { removeTemporary(store.directory) }
        store.write(tokens(expiresIn: 3_600), to: ChatGPTAccount.fileName)
        StubProtocol.register(host: chatgpt) { _, _, n in
            switch n {
            case 0: return .respond(status: 200, body: stream("明天", complete: false))
            case 1: return .respond(status: 429, body: Data("slow down".utf8))
            default:
                let failed = #"data: {"type":"response.failed","response":{"error":{"message":"坏了"}}}"#
                return .respond(status: 200, body: Data((failed + "\n\n").utf8))
            }
        }
        let account = account(store)
        await #expect(throws: PolishError.incomplete) { try await polish(account) }
        await #expect(throws: PolishError.http(429, "slow down")) { try await polish(account) }
        await #expect(throws: PolishError.failed("坏了")) { try await polish(account) }
    }

    @Test func withoutALoginNothingIsSent() async throws {
        defer { reset() }
        let store = temporaryStore()
        defer { removeTemporary(store.directory) }
        let signedOut = account(store)
        #expect(signedOut.tokens == nil && !signedOut.isReady && signedOut.maskedEmail == nil)
        #expect(signedOut.status.text == "还没登录，现在只输入原文，不整理")
        await #expect(throws: PolishError.notSignedIn) { try await signedOut.credential() }
        await #expect(throws: PolishError.notSignedIn) { try await polish(signedOut) }
        #expect(StubProtocol.requests(host: chatgpt).isEmpty)
    }

    /// A login the server still refuses after one refresh: the failure says to sign in again.
    @Test func loginRefusedAfterTheRefresh() async throws {
        defer { reset() }
        let store = temporaryStore()
        defer { removeTemporary(store.directory) }
        store.write(tokens(expiresIn: 3_600), to: ChatGPTAccount.fileName)
        StubProtocol.register(host: auth) { _, _, _ in .respond(status: 200, body: refreshAnswer(refresh: "refresh-2")) }
        StubProtocol.register(host: chatgpt) { _, _, _ in .respond(status: 401, body: Data("no".utf8)) }
        let account = account(store)
        await #expect(throws: PolishError.http(401, "no")) { try await polish(account) }
        #expect(StubProtocol.requests(host: chatgpt).count == 2 && StubProtocol.requests(host: auth).count == 1)
    }

    @Test func signOutLeavesNoCopyOfTheLogin() throws {
        let store = temporaryStore()
        defer { removeTemporary(store.directory) }
        store.write(tokens(expiresIn: 3_600), to: ChatGPTAccount.fileName)
        try Data("{broken".utf8).write(to: store.url(ChatGPTAccount.fileName + ".corrupt-20261009-120000"))
        let account = account(store)
        #expect(account.tokens != nil)
        account.signOut()
        #expect(account.tokens == nil)
        let left = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        #expect(left.isEmpty, "\(left)")
    }

    /// The whole sign-in with the browser simulated: the page opens through the injected closure, the
    /// redirect reaches the loopback listener, the code is exchanged (stubbed) and the login saved.
    @Test func signInOpensTheBrowserAndSavesTheLogin() async throws {
        defer { reset() }
        let store = temporaryStore()
        defer { removeTemporary(store.directory) }
        StubProtocol.register(host: auth) { _, _, _ in .respond(status: 200, body: refreshAnswer(refresh: "refresh-new")) }
        var opened: URL?
        var activated = false
        let browser = URLSession(configuration: .ephemeral)
        let account = account(store, opened: { url in
            opened = url
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first { $0.name == "state" }?.value ?? ""
            let redirect = items.first { $0.name == "redirect_uri" }?.value ?? ""
            Task.detached { _ = try? await browser.data(from: URL(string: "\(redirect)?code=the-code&state=\(state)")!) }
        }, signedIn: { activated = true })
        await account.signIn()
        if account.message == "登录页打不开：Codex 可能正在登录，稍后再试" {
            // Port 1455 is busy on this Mac (a Codex login in progress): nothing to check.
            return
        }
        #expect(opened?.host == "auth.openai.com")
        #expect(account.message == "登录成功")
        #expect(activated)
        #expect(account.tokens?.refreshToken == "refresh-new")
        #expect(store.read(ChatGPTTokens.self, from: ChatGPTAccount.fileName)?.refreshToken == "refresh-new")
        let exchange = try #require(StubProtocol.requests(host: auth).first)
        let form = String(decoding: exchange.body, as: UTF8.self)
        #expect(form.contains("grant_type=authorization_code") && form.contains("code=the-code"))
    }
}

@Suite struct PolishSupportTests {
    @Test func failureTexts() {
        #expect(PolishFailure.short(PolishError.timeout) == "整理超时")
        #expect(PolishFailure.short(PolishError.http(401, "")) == "ChatGPT 登录已失效")
        #expect(PolishFailure.short(URLError(.networkConnectionLost)) == "网络中断")
        #expect(PolishFailure.short(CocoaError(.fileNoSuchFile)) == "整理失败")
        #expect(PolishFailure.detail(PolishError.http(401, "")) == "ChatGPT 登录已失效，请在设置里重新登录")
        #expect(PolishFailure.detail(URLError(.notConnectedToInternet)) == "整理失败：没有网络")
        #expect(PolishError.http(503, "").errorDescription == "ChatGPT 暂时出错（503），稍后再试")
    }

    @Test func timeoutEndsTheOperation() async throws {
        let started = Date()
        await #expect(throws: PolishError.timeout) {
            try await withTimeout(seconds: 0.2) {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return 1
            }
        }
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(try await withTimeout(seconds: 2) { 7 } == 7)
    }

    @Test func stallWatchdog() async throws {
        let quiet = StallWatchdog(limit: 0.3) {}
        let deadline = Date().addingTimeInterval(10)
        while !quiet.fired && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(quiet.fired)

        // Touched in time: never fires, however late it looks.
        let busy = StallWatchdog(limit: 5) {}
        for _ in 0..<4 {
            try await Task.sleep(nanoseconds: 150_000_000)
            busy.touch(limit: 5)
        }
        #expect(!busy.fired)
        busy.stop()
    }

    @Test func masksTheAccount() {
        #expect(ChatGPTAccount.mask("alice@example.org") == "a***@example.org")
        #expect(ChatGPTAccount.mask("小明@example.cn") == "小***@example.cn")
        #expect(ChatGPTAccount.mask("nobody") == "n***")
        #expect(ChatGPTAccount.mask("") == "")
    }

}

@Suite struct OAuthCallbackServerTests {
    private func start() throws -> (OAuthCallbackServer, UInt16) {
        for _ in 0..<20 {
            let port = UInt16.random(in: 40_000...60_000)
            let server = OAuthCallbackServer()
            if (try? server.start(port: port)) != nil { return (server, port) }
        }
        throw OAuthCallbackServer.Failure.bind
    }

    @Test func returnsTheCodeForTheRightState() async throws {
        let (server, port) = try start()
        let browser = URLSession(configuration: .ephemeral)
        Task.detached {
            // A stray request and a wrong state first: both answered, neither ends the wait.
            _ = try? await browser.data(from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
            _ = try? await browser.data(from: URL(string: "http://127.0.0.1:\(port)/auth/callback?code=bad&state=other")!)
            _ = try? await browser.data(from: URL(string: "http://127.0.0.1:\(port)/auth/callback?code=abc&state=s1")!)
        }
        let code = try await server.waitForCode(state: "s1", timeout: 10)
        #expect(code == "abc")
    }

    @Test func deniedAndCancelled() async throws {
        let (denied, port) = try start()
        let browser = URLSession(configuration: .ephemeral)
        Task.detached {
            _ = try? await browser.data(from: URL(string: "http://127.0.0.1:\(port)/auth/callback?error=access_denied&error_description=no&state=s")!)
        }
        await #expect(throws: OAuthCallbackServer.Failure.denied("no")) { try await denied.waitForCode(state: "s", timeout: 10) }

        let (cancelled, _) = try start()
        Task.detached {
            try? await Task.sleep(nanoseconds: 200_000_000)
            cancelled.stop()
        }
        await #expect(throws: OAuthCallbackServer.Failure.cancelled) { try await cancelled.waitForCode(state: "s", timeout: 10) }
    }
}
