import Foundation
import NeolessCore
import Testing
@testable import NeolessCloud

private let token = "dGVzdC10b2tlbi0xMjM0NTY3ODkwYWJjZGVmZ2hpams"

private func result(for id: UUID = UUID(), recognizer: HubRecognizer = .qwen3ASR) -> DictationResult {
    DictationResult(clientRecordingID: id, raw: "嗯明天开会", text: "明天开会。", mode: .natural, polished: true,
                    recognizer: recognizer, timings: HubTimings(decodeMs: 5, asrMs: 300, polishMs: 900, totalMs: 1210))
}

/// A client talking to a stubbed hub at its own host. `GET /v1/ping` (the reachability probe sent alongside
/// dictations and polishes) gets `ping`; every other request goes to `handler`, which counts only those.
private final class Harness: @unchecked Sendable {
    let host = stubHost()
    let client: HubClient
    private let lock = NSLock()
    private var count = 0

    init(timeouts: HubTimeouts = .standard, path: String = "",
         ping: StubProtocol.Reply = .respond(status: 200, body: Data(#"{"ok":true}"#.utf8)),
         _ handler: @escaping StubProtocol.Handler) {
        client = HubClient(server: URL(string: "https://\(host)\(path)")!, token: token, session: StubProtocol.session(),
                           timeouts: timeouts)
        StubProtocol.register(host: host) { [weak self] request, body, _ in
            if request.url?.path.hasSuffix(HubPath.ping) == true { return ping }
            guard let self else { return .fail(.cannotFindHost) }
            let n: Int = self.lock.withLock {
                defer { self.count += 1 }
                return self.count
            }
            return handler(request, body, n)
        }
    }

    private var all: [StubProtocol.Seen] { StubProtocol.requests(host: host) }
    /// Everything but pings.
    var requests: [StubProtocol.Seen] { all.filter { $0.request.url?.path.hasSuffix(HubPath.ping) == false } }
    var pings: [StubProtocol.Seen] { all.filter { $0.request.url?.path.hasSuffix(HubPath.ping) == true } }

    func done() { StubProtocol.remove(host: host) }
}

private func elapsed(_ work: () async throws -> Void) async -> (TimeInterval, Error?) {
    let started = Date()
    do {
        try await work()
        return (Date().timeIntervalSince(started), nil)
    } catch {
        return (Date().timeIntervalSince(started), error)
    }
}

private let fast = HubTimeouts(connect: 0.3, quick: 1, ping: 0.3, hubPolishFloor: 1)

/// A value tests change while a stub answers with it.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@Suite struct HubClientTests {
    let request = DictationRequest(mode: .natural, autoStructured: true, appName: "备忘录", localTranscript: "明天开会",
                                   durationSeconds: 2, client: .ios, clientVersion: "1.2.0")

    @Test func dictationSendsAudioHeaderAndToken() async throws {
        let request = self.request
        let answer = result(for: request.clientRecordingID)
        let hub = Harness { _, _, _ in .respond(status: 200, headers: ["Content-Type": "application/json"], body: json(answer)) }
        defer { hub.done() }
        let audio = Data((0..<4_000).map { UInt8($0 % 251) })
        let got = try await hub.client.dictate(audio: audio, type: .m4a, request: request)
        #expect(got == answer)

        let seen = try #require(hub.requests.first)
        #expect(hub.requests.count == 1)
        #expect(seen.request.httpMethod == "POST")
        #expect(seen.request.url?.path == "/v1/dictations")
        #expect(seen.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(seen.request.value(forHTTPHeaderField: "Content-Type") == "audio/mp4")
        #expect(seen.body == audio)
        let header = try #require(seen.request.value(forHTTPHeaderField: HubHeader.request))
        #expect(try DictationRequest(headerValue: header) == request)
    }

    @Test func encodedAudioGoesAsItsType() async throws {
        let request = self.request
        let hub = Harness { _, _, _ in .respond(status: 200, body: json(result(for: request.clientRecordingID))) }
        defer { hub.done() }
        let wav = EncodedAudio(data: AudioUpload.wav([0, 1, -1]), type: .wav, durationSeconds: 3.0 / 16_000)
        _ = try await hub.client.dictate(wav, request: request)
        #expect(hub.requests.first?.request.value(forHTTPHeaderField: "Content-Type") == "audio/wav")
    }

    @Test func pingNeedsNoToken() async throws {
        let hub = Harness { _, _, _ in .respond(status: 200, body: Data(#"{"ok":true}"#.utf8)) }
        defer { hub.done() }
        #expect(try await hub.client.ping() == HubOK())
        #expect(hub.pings.count == 1 && hub.requests.isEmpty)
        #expect(hub.pings.first?.request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func everyEndpointUsesItsMethodAndPath() async throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let vocabulary = VocabularySnapshot(words: ["硬币"], learned: [], revision: "r2")
        let learning = LearningList(pairs: [LearningEntry(wrong: "引必", right: "硬币", count: 1, lastSeen: HubJSON.rounded(Date()))])
        let health = HubHealth(version: "1.2.0", asr: .init(ready: true, model: "Qwen3-ASR-0.6B-4bit"),
                               chatgpt: .init(ready: false, problem: "未登录 ChatGPT"), device: "iPhone")
        let page = HistoryPage(items: [HistoryItem(result: result(), appName: "微信", client: .ios)], nextBefore: nil)
        let sync = SyncSnapshot(vocabulary: vocabulary, learning: learning, settings: HubSettings())
        let edited = EditResponse(result: result(), learned: [CorrectionPair(wrong: "引必", right: "硬币")])
        let hub = Harness { request, _, _ in
            let path = request.url?.path ?? ""
            let body: Data
            switch (request.httpMethod ?? "", path) {
            case ("GET", "/v1/health"): body = json(health)
            case ("POST", "/v1/polish"), ("POST", "/v1/dictations/\(id.uuidString)/repolish"): body = json(result(recognizer: .local))
            case ("POST", "/v1/dictations/\(id.uuidString)/edit"): body = json(edited)
            case ("POST", "/v1/learning/observations"): body = json(LearningObservationsResponse(accepted: 1))
            case ("GET", "/v1/learning"), ("DELETE", "/v1/learning"), ("POST", "/v1/learning/forget"): body = json(learning)
            case ("GET", "/v1/vocabulary"), ("PUT", "/v1/vocabulary"): body = json(vocabulary)
            case ("GET", "/v1/history"): body = json(page)
            case ("DELETE", "/v1/history/\(id.uuidString)"): body = json(HubOK())
            case ("GET", "/v1/sync"): body = json(sync)
            default: return .respond(status: 404, body: json(HubErrorBody(error: "没有这个接口", code: HubErrorCode.notFound)))
            }
            return .respond(status: 200, body: body)
        }
        defer { hub.done() }
        let client = hub.client
        #expect(try await client.health() == health)
        #expect(try await client.polish(PolishRequest(text: "明天开会", mode: .natural, autoStructured: true)).recognizer == .local)
        #expect(try await client.repolish(id: id, mode: .structured).recognizer == .local)
        #expect(try await client.edit(id: id, text: "硬币").learned == edited.learned)
        #expect(try await client.observe([CorrectionPair(wrong: "引必", right: "硬币")], dictationID: id).accepted == 1)
        #expect(try await client.learning() == learning)
        #expect(try await client.forget(wrong: "引必") == learning)
        #expect(try await client.forget(wrongs: ["引必", "金币"]) == learning)
        #expect(try await client.vocabulary() == vocabulary)
        #expect(try await client.updateVocabulary(words: ["硬币"], expectedRevision: "r1") == vocabulary)
        #expect(try await client.history() == page)
        try await client.deleteHistory(id: id)
        #expect(try await client.sync() == sync)

        let seen = hub.requests
        #expect(seen.count == 13)
        #expect(seen.allSatisfy { $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" })
        // JSON bodies are what the contract names.
        let bodies = Dictionary(seen.map { ("\($0.request.httpMethod!) \($0.request.url!.path)", $0.body) }) { a, _ in a }
        let repolish = try #require(bodies["POST /v1/dictations/\(id.uuidString)/repolish"])
        let edit = try #require(bodies["POST /v1/dictations/\(id.uuidString)/edit"])
        let update = try #require(bodies["PUT /v1/vocabulary"])
        let observe = try #require(bodies["POST /v1/learning/observations"])
        #expect(try HubJSON.decode(RepolishRequest.self, from: repolish) == RepolishRequest(mode: .structured))
        #expect(try HubJSON.decode(EditRequest.self, from: edit) == EditRequest(text: "硬币"))
        #expect(try HubJSON.decode(VocabularyUpdate.self, from: update) == VocabularyUpdate(words: ["硬币"], expectedRevision: "r1"))
        #expect(try HubJSON.decode(LearningObservations.self, from: observe).dictationID == id)
        let forget = try #require(bodies["POST /v1/learning/forget"])
        #expect(try HubJSON.decode(LearningForget.self, from: forget) == LearningForget(wrongs: ["引必", "金币"]))
        let polish = seen.first { $0.request.url?.path == "/v1/polish" }
        #expect(polish?.request.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
    }

    @Test func queryValuesArePercentEncoded() async throws {
        let hub = Harness { request, _, _ in
            request.url?.path == "/v1/history" ? .respond(status: 200, body: json(HistoryPage(items: [])))
                : .respond(status: 200, body: json(LearningList()))
        }
        defer { hub.done() }
        _ = try await hub.client.forget(wrong: "音 币&x+y=1")
        _ = try await hub.client.history(limit: 500, before: "2026-10-09T08:30:00.123+08:00")
        let forget = try #require(hub.requests.first?.request.url)
        #expect(forget.query?.contains("+") == false && forget.query?.contains(" ") == false)
        let items = URLComponents(url: forget, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items == [URLQueryItem(name: "wrong", value: "音 币&x+y=1")])
        let history = try #require(hub.requests.last?.request.url)
        let query = URLComponents(url: history, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query == [URLQueryItem(name: "limit", value: "200"),
                          URLQueryItem(name: "before", value: "2026-10-09T08:30:00.123+08:00")])
    }

    @Test func serverPathPrefixIsKept() async throws {
        let hub = Harness(path: "/neoless/") { _, _, _ in .respond(status: 200, body: Data(#"{"ok":true}"#.utf8)) }
        defer { hub.done() }
        _ = try await hub.client.ping()
        #expect(hub.pings.first?.request.url?.path == "/neoless/v1/ping")
    }

    @Test func errorBodyBecomesTheMessage() async throws {
        let body = HubErrorBody(error: "这台设备已被吊销，请重新配对", code: HubErrorCode.forbidden)
        let hub = Harness { _, _, _ in .respond(status: 403, body: json(body)) }
        defer { hub.done() }
        let error = await #expect(throws: HubError.self) { try await hub.client.health() }
        #expect(error == .server(status: 403, body: body))
        #expect(error?.errorDescription == "这台设备已被吊销，请重新配对")
        #expect(error?.needsPairing == true)
        #expect(error?.retryable == false)
    }

    @Test func cloudflarePageWhenTheNeoSleeps() async throws {
        let hub = Harness { _, _, _ in .respond(status: 530, headers: ["Content-Type": "text/html"], body: Data("<html>1033</html>".utf8)) }
        defer { hub.done() }
        let error = await #expect(throws: HubError.self) { try await hub.client.sync() }
        #expect(error == .server(status: 530, body: nil))
        #expect(error?.errorDescription == "Neo 没有响应，可能在睡眠或断网")
        #expect(error?.retryable == true)
        // One try only: an answer, even an error, is not a dropped connection.
        #expect(hub.requests.count == 1)
    }

    @Test func statusTextsAreChinese() {
        #expect(HubError.server(status: 401, body: nil).errorDescription == "请求被网络拦下了（401）")
        // Cloudflare reached the Neo, which was still working (524): not a sleeping Neo.
        #expect(HubError.server(status: 524, body: nil).errorDescription == "Neo 处理超时")
        #expect(HubError.server(status: 524, body: nil).retryable)
        #expect(HubError.server(status: 522, body: nil).errorDescription == "Neo 没有响应，可能在睡眠或断网")
        #expect(HubError.server(status: 409, body: nil).isConflict)
        #expect(HubError.server(status: 413, body: nil).errorDescription == "内容太大，Neo 不收")
        #expect(HubError.server(status: 429, body: nil).retryable)
        #expect(HubError.server(status: 418, body: nil).errorDescription == "Neo 出错了（418）")
        #expect(HubError.server(status: 500, body: HubErrorBody(error: " ", code: "internal")).errorDescription == "Neo 出错了（500）")
        #expect(HubError.unreachable.errorDescription == "连不上 Neo")
        #expect(HubError.offline.errorDescription == "没有网络")
        #expect(HubError.timeout.errorDescription == "Neo 处理超时")
        #expect(HubError.notPaired.errorDescription == "还没连接 Neo")
    }

    @Test func onlyTheHubsOwnRefusalAsksToPairAgain() async throws {
        // Cloudflare's challenge or block page in front of the hub says nothing about the token.
        let page = Harness { _, _, _ in
            .respond(status: 403, headers: ["Content-Type": "text/html"], body: Data("<html>Attention Required! | Cloudflare</html>".utf8))
        }
        defer { page.done() }
        let error = await #expect(throws: HubError.self) { try await page.client.sync() }
        #expect(error == .server(status: 403, body: nil))
        #expect(error?.needsPairing == false)
        #expect(error?.retryable == true)
        #expect(error?.errorDescription == "请求被网络拦下了（403）")

        // The hub's own refusal asks to pair again, with its text or without.
        let unauthorized = HubError.server(status: 401, body: HubErrorBody(error: " ", code: HubErrorCode.unauthorized))
        #expect(unauthorized.needsPairing && !unauthorized.retryable)
        #expect(unauthorized.errorDescription == HubError.pairAgain)
        #expect(HubError.server(status: 403, body: HubErrorBody(error: "已吊销", code: HubErrorCode.forbidden)).needsPairing)
        #expect(!HubError.server(status: 429, body: HubErrorBody(error: "太频繁", code: HubErrorCode.rateLimited)).needsPairing)
    }

    @Test func badJSONIsABadResponse() async {
        let hub = Harness { _, _, _ in .respond(status: 200, body: Data("<html>".utf8)) }
        defer { hub.done() }
        await #expect(throws: HubError.badResponse) { try await hub.client.vocabulary() }
    }

    @Test func deleteTakesAnEmptyAnswer() async throws {
        let hub = Harness { _, _, _ in .respond(status: 204) }
        defer { hub.done() }
        try await hub.client.deleteHistory(id: UUID())
        #expect(hub.requests.first?.request.httpMethod == "DELETE")
    }

    @Test func deletingWhatIsAlreadyGoneIsDone() async throws {
        // The first try deleted it but its answer was lost; the second finds nothing there.
        let hub = Harness { _, _, n in
            n == 0 ? .fail(.networkConnectionLost)
                : .respond(status: 404, body: json(HubErrorBody(error: "Neo 上没有这条记录", code: HubErrorCode.notFound)))
        }
        defer { hub.done() }
        try await hub.client.deleteHistory(id: UUID())
        #expect(hub.requests.count == 2 && hub.requests.allSatisfy { $0.request.httpMethod == "DELETE" })

        // A 404 that is not the hub's (a wrong server address) is still an error.
        let elsewhere = Harness { _, _, _ in .respond(status: 404, headers: ["Content-Type": "text/html"], body: Data("<html>".utf8)) }
        defer { elsewhere.done() }
        await #expect(throws: HubError.server(status: 404, body: nil)) { try await elsewhere.client.deleteHistory(id: UUID()) }
    }

    @Test func vocabularyConflict() async throws {
        let hub = Harness { _, _, _ in
            .respond(status: 409, body: json(HubErrorBody(error: "词典已在别的设备上改过", code: HubErrorCode.conflict)))
        }
        defer { hub.done() }
        let error = await #expect(throws: HubError.self) {
            try await hub.client.updateVocabulary(words: [], expectedRevision: "old")
        }
        #expect(error?.isConflict == true)
    }

    @Test func tooLargeAudioIsNotSent() async {
        let hub = Harness { _, _, _ in .respond(status: 200) }
        defer { hub.done() }
        await #expect(throws: HubError.audioTooLarge) {
            try await hub.client.dictate(audio: Data(count: Hub.maxAudioBytes + 1), type: .wav, request: request)
        }
        #expect(hub.requests.isEmpty)
    }

    // MARK: Time limits, retries, cancellation

    @Test func unreachableHubFailsFast() async {
        let hub = Harness(timeouts: HubTimeouts(connect: 0.3, quick: 30)) { _, _, _ in .hang }
        defer { hub.done() }
        let (took, error) = await elapsed { _ = try await hub.client.health() }
        #expect(error as? HubError == .unreachable)
        // Far below the 30 s budget (generous: a busy test run can hold timers back).
        #expect(took >= 0.25 && took < 10, "\(took)")
    }

    @Test func dictationToAnUnreachableHubFailsFastToo() async {
        let request = self.request
        let hub = Harness(timeouts: HubTimeouts(connect: 0.3), ping: .hang) { _, _, _ in .hang }
        defer { hub.done() }
        let (took, error) = await elapsed { _ = try await hub.client.dictate(audio: Data(count: 1_000), type: .m4a, request: request) }
        #expect(error as? HubError == .unreachable)
        #expect(took >= 0.25 && took < 10, "\(took)")   // the budget is about 30 s
        #expect(hub.pings.count == 1)
    }

    @Test func sleepingNeoIsUnreachable() async {
        // The tunnel answers for the Neo (530) while the upload itself goes nowhere.
        let hub = Harness(timeouts: HubTimeouts(connect: 0.3, hubPolishFloor: 30), ping: .respond(status: 530)) { _, _, _ in .hang }
        defer { hub.done() }
        let (took, error) = await elapsed {
            _ = try await hub.client.polish(PolishRequest(text: "好", mode: .natural, autoStructured: true))
        }
        #expect(error as? HubError == .unreachable)
        #expect(took < 10, "\(took)")   // the budget is about 35 s
    }

    @Test func reachableHubGetsTheWholeBudget() async throws {
        let request = self.request
        let answer = result(for: request.clientRecordingID)
        // Longer than `connect`, but the ping alongside came back: the hub is working on it.
        let hub = Harness(timeouts: HubTimeouts(connect: 0.5)) { _, _, _ in .respond(status: 200, body: json(answer), delay: 1.5) }
        defer { hub.done() }
        #expect(try await hub.client.dictate(audio: Data(count: 1_000), type: .m4a, request: request) == answer)
        #expect(hub.pings.count == 1)
    }

    @Test func connectedButSlowRunsOutOfBudget() async {
        let hub = Harness(timeouts: HubTimeouts(connect: 0.2, cap: 0.8)) { _, _, _ in .hang }
        defer { hub.done() }
        let (took, error) = await elapsed { _ = try await hub.client.repolish(id: UUID()) }
        #expect(error as? HubError == .timeout)
        #expect(took >= 0.7 && took < 10, "\(took)")
    }

    @Test func aQuickAnswerMayTakeLongerThanConnectToArrive() async throws {
        // A slow link on a reused connection (no TLS handshake): the hub's answer starts at once, but a full
        // history page takes longer than `connect` to come down.
        let items = (0..<Hub.maxHistoryLimit).map { _ in HistoryItem(result: result(), appName: "微信", client: .ios) }
        let page = HistoryPage(items: items, nextBefore: "2026-10-09T08:30:00.123Z")
        // (`connect` of 1 s, not less: a busy machine running tests side by side can hold the answer back.)
        let hub = Harness(timeouts: HubTimeouts(connect: 1, quick: 8)) { _, _, _ in
            .respond(status: 200, headers: ["Content-Type": "application/json"], body: json(page), bodyDelay: 2.5, leading: 100)
        }
        defer { hub.done() }
        #expect(try await hub.client.history(limit: Hub.maxHistoryLimit) == page)
    }

    @Test func anAnswerThatStallsRunsOutOfTheQuickBudget() async {
        let hub = Harness(timeouts: HubTimeouts(connect: 1, quick: 2.5)) { _, _, _ in
            .respond(status: 200, headers: ["Content-Type": "application/json"], body: json(SyncSnapshot(vocabulary: VocabularySnapshot(words: [], learned: [], revision: "r1"),
                                                          learning: LearningList(), settings: HubSettings())),
                     bodyDelay: 60, leading: 1)
        }
        defer { hub.done() }
        let (took, error) = await elapsed { _ = try await hub.client.sync() }
        // Reached (its answer began), so not "unreachable".
        #expect(error as? HubError == .timeout)
        #expect(took >= 2.4 && took < 12, "\(took)")
    }

    @Test func quickCallsGetNoProbe() async throws {
        let hub = Harness { _, _, _ in .respond(status: 200, body: json(LearningList())) }
        defer { hub.done() }
        _ = try await hub.client.learning()
        _ = try await hub.client.forget(wrong: "引必")
        #expect(hub.pings.isEmpty && hub.requests.count == 2)
    }

    @Test func droppedConnectionIsSentOnceMoreWithTheSameRecording() async throws {
        let request = self.request
        let hub = Harness { _, _, n in
            n == 0 ? .fail(.networkConnectionLost) : .respond(status: 200, body: json(result(for: request.clientRecordingID)))
        }
        defer { hub.done() }
        let got = try await hub.client.dictate(audio: Data(count: 100), type: .m4a, request: request)
        #expect(got.clientRecordingID == request.clientRecordingID)
        let headers = hub.requests.map { $0.request.value(forHTTPHeaderField: HubHeader.request) }
        #expect(headers.count == 2 && headers[0] != nil && headers[0] == headers[1])
        #expect(hub.requests.map(\.body.count) == [100, 100])
    }

    @Test func aDropLateInTheBudgetStillLeavesTimeToSendAgain() async throws {
        let request = self.request
        let answer = result(for: request.clientRecordingID)
        // The connection drops with 2.5 s of the 6 s budget left, less than `connect`. The hub finished the job
        // the first try started and answers the second try with it; sending the recording again takes a moment.
        // (Wide margins: a busy test run can hold the timers back.)
        let hub = Harness(timeouts: HubTimeouts(connect: 3, margin: 3, cap: 6)) { _, _, n in
            n == 0 ? .fail(.networkConnectionLost, delay: 3.5) : .respond(status: 200, body: json(answer), delay: 0.2)
        }
        defer { hub.done() }
        #expect(try await hub.client.dictate(audio: Data(count: 1_000), type: .m4a, request: request) == answer)
        #expect(hub.requests.count == 2)
    }

    @Test func droppedTwiceGivesUp() async {
        let hub = Harness { _, _, _ in .fail(.networkConnectionLost) }
        defer { hub.done() }
        await #expect(throws: HubError.connectionLost) {
            try await hub.client.polish(PolishRequest(text: "好", mode: .natural, autoStructured: true))
        }
        #expect(hub.requests.count == 2)
    }

    // Cloudflare's 524: it waited 100 s for the hub's answer to begin and gave up, while the hub goes on working.

    private static func cloudflareGaveUp(after delay: TimeInterval = 0) -> StubProtocol.Reply {
        .respond(status: 524, headers: ["Content-Type": "text/html"], body: Data("<html>Error 524 A timeout occurred</html>".utf8),
                 delay: delay)
    }

    @Test func aDictationStillWorkingIsAskedAgainWithTheSameRecording() async throws {
        let request = self.request
        let answer = result(for: request.clientRecordingID)
        // (A moment before each 524, so the ping sent alongside has started before the answer cancels it.)
        let hub = Harness { _, _, n in n < 2 ? Self.cloudflareGaveUp(after: 0.3) : .respond(status: 200, body: json(answer)) }
        defer { hub.done() }
        let audio = Data((0..<1_000).map { UInt8($0 % 251) })
        #expect(try await hub.client.dictate(audio: audio, type: .m4a, request: request) == answer)
        // The same call each time: the hub runs one job per recording and answers the last with its result.
        let seen = hub.requests
        #expect(seen.count == 3)
        #expect(seen.allSatisfy { $0.request.url?.path == "/v1/dictations" && $0.body == audio })
        let headers = Set(seen.compactMap { $0.request.value(forHTTPHeaderField: HubHeader.request) })
        #expect(headers.count == 1)
        // Each try checks again that the hub is there.
        #expect(hub.pings.count == 3)
    }

    @Test func polishAndRepolishStillWorkingAreAskedAgainToo() async throws {
        let hub = Harness { _, _, n in n % 2 == 0 ? Self.cloudflareGaveUp() : .respond(status: 200, body: json(result(recognizer: .local))) }
        defer { hub.done() }
        _ = try await hub.client.polish(PolishRequest(text: "明天开会", mode: .natural, autoStructured: true))
        _ = try await hub.client.repolish(id: UUID(), mode: .structured)
        #expect(hub.requests.map { $0.request.url?.path.hasSuffix("/repolish") == true } == [false, false, true, true])
    }

    @Test func stillWorkingAtTheEndIsATimeoutNotASleepingNeo() async {
        let request = self.request
        // Cloudflare keeps giving up on a hub that never finishes: a few tries, then a timeout.
        let always = Harness { _, _, _ in Self.cloudflareGaveUp() }
        defer { always.done() }
        await #expect(throws: HubError.timeout) {
            try await always.client.dictate(audio: Data(count: 1_000), type: .m4a, request: request)
        }
        #expect(always.requests.count == HubClient.maxTries)

        // A 524 with less than `connect` of the budget left is not worth sending the recording again.
        let late = Harness(timeouts: HubTimeouts(connect: 1.5, cap: 2)) { _, _, _ in Self.cloudflareGaveUp(after: 1) }
        defer { late.done() }
        let (took, error) = await elapsed {
            _ = try await late.client.dictate(audio: Data(count: 1_000), type: .m4a, request: request)
        }
        #expect(error as? HubError == .timeout)
        #expect(late.requests.count == 1)
        #expect(took < 10, "\(took)")
    }

    @Test func onlySlowCallsAndOnlyCloudflaresOwn524AreAskedAgain() async {
        // A quick call never waits 100 s for its answer; a 524 there is reported as it is.
        let quick = Harness { _, _, _ in Self.cloudflareGaveUp() }
        defer { quick.done() }
        let error = await #expect(throws: HubError.self) { try await quick.client.sync() }
        #expect(error == .server(status: 524, body: nil))
        #expect(error?.errorDescription == "Neo 处理超时")
        #expect(quick.requests.count == 1)

        // A 524 with the hub's own error body is the hub's answer, not Cloudflare giving up.
        let body = HubErrorBody(error: "整理失败", code: HubErrorCode.internalError)
        let own = Harness { _, _, _ in .respond(status: 524, body: json(body)) }
        defer { own.done() }
        await #expect(throws: HubError.server(status: 524, body: body)) {
            try await own.client.polish(PolishRequest(text: "好", mode: .natural, autoStructured: true))
        }
        #expect(own.requests.count == 1)
        #expect(!HubClient.stillWorking(status: 504, data: Data()))
        #expect(HubClient.stillWorking(status: 524, data: Data()))
    }

    @Test func aDropAfterStillWorkingIsStillSentOnceMore() async throws {
        let request = self.request
        let answer = result(for: request.clientRecordingID)
        let hub = Harness { _, _, n in
            switch n {
            case 0: return Self.cloudflareGaveUp()
            case 1: return .fail(.networkConnectionLost)
            default: return .respond(status: 200, body: json(answer))
            }
        }
        defer { hub.done() }
        #expect(try await hub.client.dictate(audio: Data(count: 100), type: .m4a, request: request) == answer)
        #expect(hub.requests.count == 3)
    }

    @Test func observationsAndDictionaryChangesAreNotRepeated() async {
        let hub = Harness { _, _, _ in .fail(.networkConnectionLost) }
        defer { hub.done() }
        await #expect(throws: HubError.connectionLost) { try await hub.client.observe([CorrectionPair(wrong: "a", right: "b")]) }
        await #expect(throws: HubError.connectionLost) { try await hub.client.updateVocabulary(words: [], expectedRevision: "r") }
        #expect(hub.requests.count == 2)
    }

    @Test func theHubsPolishFloorSizesLaterBudgets() async throws {
        var health = HubHealth(version: "1.2.0", asr: .init(ready: true, model: "Qwen3-ASR-0.6B-4bit"),
                               chatgpt: .init(ready: true), device: "Mac", polishTimeout: 30)
        let answer = Locked(health)
        let hub = Harness { _, _, _ in .respond(status: 200, body: json(answer.value)) }
        defer { hub.done() }
        let before = hub.client.timeouts.dictation(durationSeconds: 5, audioBytes: 20_000)
        #expect(hub.client.timeouts.hubPolishFloor == HubTimeouts.standard.hubPolishFloor)
        _ = try await hub.client.health()
        // The Neo may polish for 30 s: a dictation waits for that, not the usual 10.
        #expect(hub.client.timeouts.hubPolishFloor == 30)
        #expect(hub.client.timeouts.dictation(durationSeconds: 5, audioBytes: 20_000) == before + 20)
        // Kept within the setting's range; an older hub that does not say leaves it as it was.
        health.polishTimeout = 100
        answer.value = health
        _ = try await hub.client.health()
        #expect(hub.client.timeouts.hubPolishFloor == PolishTimeout.settingRange.upperBound)
        health.polishTimeout = nil
        answer.value = health
        _ = try await hub.client.health()
        #expect(hub.client.timeouts.hubPolishFloor == PolishTimeout.settingRange.upperBound)
    }

    @Test func aRequestEndedOnTheWayIsNotACancellation() {
        // Only cancelling the task is a CancellationError; a network filter ending the request is a failed call.
        #expect(HubClient.map(URLError(.cancelled), reached: true) as? HubError == .connectionLost)
        #expect(HubClient.map(URLError(.cancelled), reached: false) as? HubError == .unreachable)
    }

    @Test func offlineIsNotRetried() async {
        let hub = Harness { _, _, _ in .fail(.notConnectedToInternet) }
        defer { hub.done() }
        await #expect(throws: HubError.offline) { try await hub.client.health() }
        #expect(hub.requests.count == 1)
    }

    @Test func interceptedTLSIsUnreachableNotADroppedConnection() async {
        // A captive portal's certificate arrived (which counts as reaching a server), then failed the system's check.
        for code in [URLError.Code.serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .secureConnectionFailed] {
            #expect(HubClient.map(URLError(code), reached: true) as? HubError == .unreachable, "\(code)")
        }
        #expect(HubClient.map(URLError(.networkConnectionLost), reached: true) as? HubError == .connectionLost)
        let hub = Harness { _, _, _ in .fail(.serverCertificateUntrusted) }
        defer { hub.done() }
        await #expect(throws: HubError.unreachable) { try await hub.client.health() }
        #expect(hub.requests.count == 1)
    }

    @Test func otherNetworkFailuresAreUnreachable() async {
        let hub = Harness { _, _, _ in .fail(.cannotConnectToHost) }
        defer { hub.done() }
        await #expect(throws: HubError.unreachable) { try await hub.client.health() }
    }

    @Test func cancellationStopsTheRequest() async {
        let hub = Harness(timeouts: HubTimeouts(connect: 30, quick: 30)) { _, _, _ in .hang }
        defer { hub.done() }
        let client = hub.client
        let task = Task { try await client.health() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        task.cancel()
        let outcome = await task.result
        #expect(Date().timeIntervalSince(started) < 5)
        guard case .failure(let error) = outcome else {
            Issue.record("a cancelled request returned a result")
            return
        }
        #expect(error is CancellationError, "\(error)")
    }

    @Test func anAnswerCountsAsReachedOnURLSessionsOwnQueue() async throws {
        let host = stubHost()
        StubProtocol.register(host: host) { _, _, _ in .respond(status: 200) }
        defer { StubProtocol.remove(host: host) }
        let watch = ConnectionWatch()
        #expect(!watch.connected)
        _ = try await StubProtocol.session().data(for: URLRequest(url: URL(string: "https://\(host)/v1/health")!), delegate: watch)
        #expect(watch.connected)

        let failed = ConnectionWatch()
        StubProtocol.register(host: host) { _, _, _ in .fail(.cannotConnectToHost) }
        _ = try? await StubProtocol.session().data(for: URLRequest(url: URL(string: "https://\(host)/v1/health")!), delegate: failed)
        #expect(!failed.connected)
    }

    @Test func aResponseCountsAsReachedBeforeItsBodyIsIn() async throws {
        // The answer begins and its body never finishes: it was reached all the same.
        let host = stubHost()
        StubProtocol.register(host: host) { _, _, _ in
            .respond(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8), bodyDelay: 60, leading: 1)
        }
        defer { StubProtocol.remove(host: host) }
        let watch = ConnectionWatch(handshakeCounts: false)
        let task = Task { try await StubProtocol.session().data(for: URLRequest(url: URL(string: "https://\(host)/v1/sync")!), delegate: watch) }
        let started = Date()
        while !watch.connected && Date().timeIntervalSince(started) < 10 { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(watch.connected)
        task.cancel()
        _ = await task.result
    }

    @Test func pairingStoreGivesNoClientWhenNotPaired() throws {
        try withTestDefaults { defaults in
            let store = HubPairingStore(defaults: defaults, secrets: MemorySecretStore())
            #expect(throws: HubError.notPaired) { try store.client() }
        }
    }
}

@Suite struct HubTimeoutTests {
    let t = HubTimeouts.standard

    @Test func dictationBudgetGrowsWithTheRecording() {
        let short = t.dictation(durationSeconds: 5, audioBytes: 20_000)
        let minute = t.dictation(durationSeconds: 60, audioBytes: 240_000)
        let long = t.dictation(durationSeconds: 1_200, audioBytes: 4_800_000)
        #expect(short >= 20 && short <= 40, "\(short)")
        #expect(minute > short && minute <= 90, "\(minute)")
        #expect(long == HubTimeouts.longest)
        // Never less than the hub may spend polishing.
        #expect(short > t.connect + PolishTimeout.seconds(forCharacters: 25, minimum: t.hubPolishFloor))
        #expect(t.dictation(durationSeconds: .nan, audioBytes: -5) > t.connect)
    }

    @Test func resendBudget() {
        #expect(t.resend(bytes: 0) == t.connect + t.margin)
        #expect(t.resend(bytes: 240_000) == t.connect + 7.5 + t.margin)
        #expect(t.resend(bytes: -1) == t.resend(bytes: 0))
        #expect(t.resend(bytes: Hub.maxAudioBytes * 100) == HubTimeouts.longest)
    }

    @Test func polishBudget() {
        #expect(t.polish(characters: nil) == t.connect + PolishTimeout.cap + t.margin)
        #expect(t.polish(characters: 10) == t.connect + t.hubPolishFloor + t.margin)
        #expect(t.polish(characters: 100_000) == t.polish(characters: nil))
    }
}

/// `POST /v1/warm`: fire and forget, so the client keeps it short, sends it once, and takes an older hub's 404 as an
/// answer rather than a failure.
@Suite struct HubWarmClientTests {
    @Test func itSaysWhichModelTheDictationWillUse() async throws {
        let hub = Harness { _, _, _ in .respond(status: 200, body: json(HubOK())) }
        defer { hub.done() }
        #expect(try await hub.client.warm(model: .small))
        #expect(try await hub.client.warm(model: nil))
        #expect(try await hub.client.warm(model: .auto))
        #expect(hub.requests.count == 3)
        for seen in hub.requests {
            #expect(seen.request.httpMethod == "POST")
            #expect(seen.request.url?.path == "/v1/warm")
            #expect(seen.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        }
        let bodies = try hub.requests.map { try HubJSON.decode(WarmRequest.self, from: $0.body) }
        #expect(bodies == [WarmRequest(asrModel: .small), WarmRequest(), WarmRequest()])
        #expect(String(decoding: hub.requests[1].body, as: UTF8.self) == "{}")
        // Not one of the slow calls: no ping goes along.
        #expect(hub.pings.isEmpty)
    }

    @Test func aHubFromBeforeTheRouteSaysSoWithoutAnError() async throws {
        let hub = Harness { _, _, _ in
            .respond(status: 404, body: json(HubErrorBody(error: "没有这个接口", code: HubErrorCode.notFound)))
        }
        defer { hub.done() }
        #expect(try await hub.client.warm(model: .large) == false)
    }

    @Test func itIsSentOnceAndKeptShort() async throws {
        let dropped = Harness(timeouts: fast) { _, _, _ in .fail(.networkConnectionLost) }
        defer { dropped.done() }
        await #expect(throws: HubError.connectionLost) { try await dropped.client.warm(model: nil) }
        #expect(dropped.requests.count == 1)
        let silent = Harness(timeouts: fast) { _, _, _ in .hang }
        defer { silent.done() }
        let (seconds, error) = await elapsed { try await silent.client.warm(model: nil) }
        #expect(error as? HubError == .unreachable)
        #expect(seconds < fast.ping + 2, "\(seconds)")
        let busy = Harness { _, _, _ in
            .respond(status: 429, body: json(HubErrorBody(error: "请求太频繁", code: HubErrorCode.rateLimited, retryable: true)))
        }
        defer { busy.done() }
        await #expect(throws: HubError.self) { try await busy.client.warm(model: nil) }
        #expect(busy.requests.count == 1)
    }
}

@Suite struct HubWarmGateTests {
    @Test func atMostOnceInTheInterval() {
        var gate = HubWarmGate()
        var asked: [Bool] = []
        for now in [100, 100, 100 + Hub.warmInterval - 0.1, 100 + Hub.warmInterval] { asked.append(gate.take(at: now)) }
        #expect(asked == [true, false, false, true])
        // Answered: nothing changes.
        gate.answered(supported: true, at: 100 + Hub.warmInterval)
        let next = gate.take(at: 100 + 2 * Hub.warmInterval)
        #expect(next)
    }

    @Test func aHubWithoutTheRouteIsLeftAloneForAWhile() {
        var gate = HubWarmGate()
        let first = gate.take(at: 0)
        #expect(first)
        gate.answered(supported: false, at: 1)
        var asked: [Bool] = []
        for now in [Hub.warmInterval + 1, HubWarmGate.unsupportedPause, HubWarmGate.unsupportedPause + 1] {
            asked.append(gate.take(at: now))
        }
        #expect(asked == [false, false, true])
        #expect(HubWarmGate.unsupportedPause > Hub.warmInterval)
    }
}
