import Foundation
import NeolessCloud
import NeolessCore
import Testing
@testable import NeolessHubKit

// Never reaches auth.openai.com: the token requests go to `HeldAuth`, the login lives in a temporary folder.

private func jwt(_ claims: [String: Any]) -> String {
    let header = Base64URL.encode(Data(#"{"alg":"none"}"#.utf8))
    return "\(header).\(Base64URL.encode(try! JSONSerialization.data(withJSONObject: claims))).sig"
}

private func accessToken(expiresIn: TimeInterval) -> String {
    jwt(["exp": Date().addingTimeInterval(expiresIn).timeIntervalSince1970,
         "https://api.openai.com/auth": ["chatgpt_account_id": "acct-1", "chatgpt_plan_type": "plus"]])
}

private let idToken = jwt(["email": "alice@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": "acct-1"]])

private func login(refresh: String, expiresIn: TimeInterval) -> ChatGPTTokens {
    ChatGPTTokens(idToken: idToken, accessToken: accessToken(expiresIn: expiresIn), refreshToken: refresh,
                  accountID: "acct-1", lastRefresh: Date())
}

/// The token endpoint, stubbed: every request is held until `release`, then answered with a new login.
final class HeldAuth: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: [HeldAuth] = []
    nonisolated(unsafe) private static var count = 0

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldAuth.self]
        return URLSession(configuration: configuration)
    }

    static func reset() { lock.withLock { held = []; count = 0 } }

    /// Requests seen so far.
    static var requests: Int { lock.withLock { count } }

    /// Answers every held request with a login whose refresh token is `refresh`.
    static func release(refresh: String) {
        let all: [HeldAuth] = lock.withLock {
            defer { held = [] }
            return held
        }
        let body = try! JSONSerialization.data(withJSONObject: ["access_token": accessToken(expiresIn: 3_600),
                                                                "refresh_token": refresh, "id_token": idToken])
        for request in all {
            let response = HTTPURLResponse(url: request.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
            request.client?.urlProtocol(request, didLoad: body)
            request.client?.urlProtocolDidFinishLoading(request)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock {
            Self.held.append(self)
            Self.count += 1
        }
    }

    override func stopLoading() {}
}

/// Stopping the hub while a ChatGPT token refresh is still running (a polish timed out on it).
@MainActor
@Suite(.serialized) struct HubRefreshTests {
    /// A hub whose saved login needs a refresh before its next polish (the access token expires within 5 minutes).
    private func hub(_ dir: URL) throws -> (HubDataFolder, ChatGPTPolisher, HubService) {
        _ = TestLog.shared
        HeldAuth.reset()
        let folder = try HubDataFolder.at(dir)
        folder.store.write(login(refresh: "refresh-1", expiresIn: 60), to: ChatGPTAccount.fileName)
        let polisher = ChatGPTPolisher(store: folder.store, config: { HubConfig() }, authSession: HeldAuth.session())
        return (folder, polisher, HubService(folder: folder, asr: StubASR(), polisher: polisher))
    }

    /// A polish asks for a token, which starts a refresh, and then its time limit stops the wait.
    private func refreshAPolishGaveUpOn(_ polisher: ChatGPTPolisher) async {
        let polish = Task { _ = try await polisher.current.credential() }
        #expect(await eventually { HeldAuth.requests == 1 })
        polish.cancel()
        guard case .failure(let error) = await polish.result else {
            Issue.record("the token arrived before the refresh was answered")
            return
        }
        #expect(error is CancellationError)
    }

    /// The hub looks for the user's own instruction files in its data folder, and `status` says which are in use.
    @Test func ownInstructionFilesAreLookedForInTheDataFolder() throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let (folder, polisher, _) = try hub(dir)
        #expect(polisher.overrides == PolishOverrides(store: folder.store))
        #expect(polisher.overrides.staticText(for: .natural) == nil)
        try Data("# 我的指令\n只整理。\n".utf8).write(to: folder.url.appendingPathComponent("polish-natural.md"))
        #expect(polisher.overrides.staticText(for: .natural) == "# 我的指令\n只整理。")
        #expect(polisher.overrides.summary.contains("自然整理用你自己的 polish-natural.md；结构化用内置的"))
    }

    @Test func exitWaitsUntilTheRotatedTokenIsSaved() async throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let (folder, polisher, service) = try hub(dir)
        await refreshAPolishGaveUpOn(polisher)

        let exited = Box(false)
        let exit = Task {
            await service.waitForRefresh()
            exited.value = true
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!exited.value)
        #expect(folder.store.read(ChatGPTTokens.self, from: ChatGPTAccount.fileName)?.refreshToken == "refresh-1")

        HeldAuth.release(refresh: "refresh-2")
        await exit.value
        #expect(folder.store.read(ChatGPTTokens.self, from: ChatGPTAccount.fileName)?.refreshToken == "refresh-2")
        #expect(HeldAuth.requests == 1)
    }

    @Test func exitAlsoWaitsForALoginReplacedWhileItRefreshed() async throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let (folder, polisher, service) = try hub(dir)
        let first = polisher.current
        await refreshAPolishGaveUpOn(polisher)

        // `neoless-hub login` saved another login meanwhile: the hub moves on to it.
        folder.store.write(login(refresh: "refresh-9", expiresIn: 3_600), to: ChatGPTAccount.fileName)
        #expect(polisher.current !== first)

        let exited = Box(false)
        let exit = Task {
            await service.waitForRefresh()
            exited.value = true
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!exited.value)

        HeldAuth.release(refresh: "refresh-2")
        await exit.value
        #expect(HeldAuth.requests == 1)
    }

    @Test func nothingRunningMeansNoWait() async throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let (folder, polisher, service) = try hub(dir)
        // Signed out meanwhile, with nothing running: the old account is let go at once.
        _ = folder.store.purge(ChatGPTAccount.fileName)
        #expect(!polisher.health.ready)
        await service.waitForRefresh()
        #expect(HeldAuth.requests == 0)
    }
}
