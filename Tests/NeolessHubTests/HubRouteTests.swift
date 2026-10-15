import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NeolessCloud
import NeolessCore
import Testing
@testable import NeolessHubKit

/// Auth, limits and every route through the router, with stubbed recognition and polishing.
@MainActor
@Suite struct HubRouteTests {
    // MARK: Auth

    @Test func pingNeedsNoToken() async throws {
        let hub = try HubFixture()
        let response = try await hub.send(.get, HubPath.ping, headers: [:])
        #expect(response.status == .ok)
        #expect(try decode(HubOK.self, response) == HubOK())
        #expect(response.headers[.contentType] == "application/json; charset=utf-8")
    }

    @Test func noOrWrongTokenIs401() async throws {
        let hub = try HubFixture()
        for headers: HTTPFields in [[:], [.authorization: "Bearer"], [.authorization: "Basic abc"],
                                    [.authorization: "Bearer not a token"],
                                    [.authorization: "Bearer \(HubToken.generate())"]] {
            let response = try await hub.send(.get, HubPath.health, headers: headers)
            #expect(response.status == .unauthorized)
            let body = try #require(errorBody(response))
            #expect(body.code == HubErrorCode.unauthorized && !body.retryable)
            #expect(body.error.contains("重新配对"))
        }
        // Unknown routes do not tell strangers what exists.
        #expect(try await hub.send(.get, "/v1/nothing", headers: [:]).status == .unauthorized)
        // "bearer" in any case.
        #expect(try await hub.send(.get, HubPath.health, headers: [.authorization: "bearer \(hub.token)"]).status == .ok)
    }

    @Test func revokedDeviceIs403() async throws {
        let hub = try HubFixture()
        #expect(try await hub.send(.get, HubPath.health).status == .ok)
        try hub.service.devices.revoke(name: "iphone")
        let response = try await hub.send(.get, HubPath.health)
        #expect(response.status == .forbidden)
        #expect(errorBody(response)?.code == HubErrorCode.forbidden)
    }

    @Test func pairingAgainReplacesTheOldToken() async throws {
        let hub = try HubFixture()
        let (newToken, replaced) = try hub.service.devices.pair(name: "iPhone")
        #expect(replaced)
        #expect(try await hub.send(.get, HubPath.health).status == .forbidden)
        let response = try await hub.send(.get, HubPath.health, headers: [.authorization: "Bearer \(newToken)"])
        #expect(response.status == .ok)
        #expect(try decode(HubHealth.self, response).device == "iPhone")
    }

    @Test func rateLimitPerDeviceButNotPing() async throws {
        let hub = try HubFixture(rateLimit: 3)
        let other = try hub.service.devices.pair(name: "Mac").token
        for _ in 0..<3 { #expect(try await hub.send(.get, HubPath.vocabulary).status == .ok) }
        let refused = try await hub.send(.get, HubPath.vocabulary)
        #expect(refused.status == .tooManyRequests)
        let body = try #require(errorBody(refused))
        #expect(body.code == HubErrorCode.rateLimited && body.retryable && body.error == "请求太频繁，稍后再试")
        // Another device has its own allowance, and ping counts for nobody.
        #expect(try await hub.send(.get, HubPath.vocabulary, headers: [.authorization: "Bearer \(other)"]).status == .ok)
        for _ in 0..<5 { #expect(try await hub.send(.get, HubPath.ping, headers: hub.auth).status == .ok) }
    }

    @Test func unknownRouteIs404InChinese() async throws {
        let hub = try HubFixture()
        let response = try await hub.send(.get, "/v1/nothing")
        #expect(response.status == .notFound)
        #expect(errorBody(response) == HubErrorBody(error: "没有这个接口", code: HubErrorCode.notFound))
    }

    // MARK: Limits

    @Test func jsonOver256KBIs413() async throws {
        let hub = try HubFixture()
        let big = PolishRequest(text: String(repeating: "长", count: 100_000), mode: .natural, autoStructured: true)
        let response = try await hub.post(HubPath.polish, big)
        #expect(response.status == .contentTooLarge)
        #expect(errorBody(response)?.code == HubErrorCode.tooLarge)
        #expect(hub.polisher.calls.isEmpty)
        // Said up front in Content-Length: refused before reading (the router test client sets its own length,
        // so this is checked directly).
        let declared = Request(head: HTTPRequest(method: .post, scheme: "http", authority: "127.0.0.1", path: HubPath.polish,
                                                 headerFields: [.contentLength: String(Hub.maxJSONBytes + 1)]),
                               body: RequestBody(buffer: ByteBuffer(string: "{}")))
        await #expect(throws: HubFailure.jsonTooLarge) {
            try await HubServer.collect(declared, limit: Hub.maxJSONBytes, failure: .jsonTooLarge)
        }
    }

    @Test func audioOver12MBIs413() async throws {
        let hub = try HubFixture()
        let audio = Data(count: Hub.maxAudioBytes + 1)
        let response = try await hub.dictate(dictation(), audio: audio)
        #expect(response.status == .contentTooLarge)
        let body = try #require(errorBody(response))
        #expect(body.code == HubErrorCode.tooLarge && body.error.contains("12 MB"))
        #expect(hub.asr.calls.isEmpty)
    }

    @Test func audioTypeAndHeaderAreChecked() async throws {
        let hub = try HubFixture()
        let request = dictation()
        var headers = try hub.dictationHeaders(request)
        headers[.contentType] = "text/plain"
        let wrongType = try await hub.send(.post, HubPath.dictations, headers: headers, body: ByteBuffer(bytes: AudioFixture.wav))
        #expect(wrongType.status == .unsupportedMediaType)
        #expect(errorBody(wrongType)?.code == HubErrorCode.unsupportedMedia)

        for value in [nil, "%%%", Base64URL.encode(Data("{\"mode\":\"natural\"}".utf8))] {
            var headers = hub.headers([.contentType: "audio/wav"])
            if let value { headers[HubServer.requestHeader] = value }
            let response = try await hub.send(.post, HubPath.dictations, headers: headers, body: ByteBuffer(bytes: AudioFixture.wav))
            #expect(response.status == .badRequest)
            #expect(errorBody(response) == HubErrorBody(error: "听写请求的格式不对", code: HubErrorCode.badRequest))
        }
        #expect(hub.asr.calls.isEmpty)
    }

    @Test func malformedJSONIs400() async throws {
        let hub = try HubFixture()
        for uri in [HubPath.polish, HubPath.learningObservations] {
            let response = try await hub.send(.post, uri, body: ByteBuffer(string: "{not json"))
            #expect(response.status == .badRequest)
            #expect(errorBody(response)?.code == HubErrorCode.badRequest)
        }
        let badID = try await hub.post("/v1/dictations/not-a-uuid/edit", EditRequest(text: "x"))
        #expect(badID.status == .badRequest)
    }

    // MARK: Health

    @Test func health() async throws {
        let hub = try HubFixture()
        var health = try decode(HubHealth.self, try await hub.send(.get, HubPath.health))
        #expect(health == HubHealth(version: HubService.version, asr: .init(ready: true, model: "Qwen3-ASR-0.6B-4bit"),
                                    chatgpt: .init(ready: true, account: "a***@example.com"), device: "iPhone",
                                    polishTimeout: 10))
        hub.asr.healthAnswer = nil
        hub.polisher.health = HubHealth.ChatGPT(ready: false, problem: HubLoginText.notSignedIn)
        health = try decode(HubHealth.self, try await hub.send(.get, HubPath.health))
        #expect(health.asr == .init(ready: false, model: ASRWorker.defaultModel))
        #expect(health.chatgpt == .init(ready: false, problem: HubLoginText.notSignedIn))
    }

    /// The real ChatGPT side with no login: health says so, and a dictation is typed as the original
    /// (the polish fails before any request leaves the Mac).
    @Test func noChatGPTLoginTypesTheOriginal() async throws {
        let hub = try HubFixture(realPolisher: true)
        let health = try decode(HubHealth.self, try await hub.send(.get, HubPath.health))
        #expect(health.chatgpt == HubHealth.ChatGPT(ready: false, problem: HubLoginText.notSignedIn))
        let result = try decode(DictationResult.self, try await hub.dictate(dictation()))
        #expect(result.raw == "嗯明天下午三点开会" && result.text == result.raw && !result.polished)
        #expect(result.fallback == HubFallback(title: "已输入原文", reason: "未登录 ChatGPT"))
    }

    // MARK: Dictations

    @Test func dictationHappyPath() async throws {
        let hub = try HubFixture()
        let request = dictation(local: "明天下午三点开会")
        let response = try await hub.dictate(request)
        #expect(response.status == .ok)
        let result = try decode(DictationResult.self, response)
        #expect(result.clientRecordingID == request.clientRecordingID)
        #expect(result.raw == "嗯明天下午三点开会")
        #expect(result.text == "明天下午三点开会。")
        #expect(result.mode == .natural && result.polished && result.fallback == nil)
        #expect(result.recognizer == .qwen3ASR)
        #expect(result.timings.totalMs >= result.timings.asrMs)

        // The worker got 16 kHz mono 16-bit WAV of about a second, with the dictionary as hints.
        let call = try #require(hub.asr.calls.first)
        #expect(call.wav.prefix(4) == Data("RIFF".utf8))
        #expect(abs(call.seconds - 1) < 0.1)
        #expect(call.hints == Vocabulary.recognizerHints(Vocabulary.defaults))
        // ChatGPT got the vocabulary and the app.
        let polish = try #require(hub.polisher.calls.first)
        #expect(polish.appName == "备忘录" && polish.vocabulary.own.contains("ChatGPT"))

        let saved = try #require(hub.service.history.entry(id: result.id))
        #expect(saved.result == result && saved.client == .ios && saved.appName == "备忘录" && saved.clientVersion == "1.2.0")
    }

    @Test(arguments: [HubAudioType.wav, .caf, .m4a])
    func everyUploadTypeDecodes(_ type: HubAudioType) async throws {
        let hub = try HubFixture()
        let audio = switch type {
        case .wav: AudioFixture.wav
        case .caf: AudioFixture.caf
        case .m4a: AudioFixture.m4a
        }
        let response = try await hub.dictate(dictation(), audio: audio, type: type)
        #expect(response.status == .ok)
        let call = try #require(hub.asr.calls.first)
        #expect(abs(call.seconds - 1) < 0.1)
        // 44-byte header, then 16-bit samples at 16 kHz.
        #expect(abs(call.wav.count - 44 - 32_000) < 3_200)
    }

    @Test func aiAppsGetStructuredAndRawSkipsChatGPT() async throws {
        let hub = try HubFixture()
        let structured = try decode(DictationResult.self,
                                    try await hub.dictate(dictation(appName: "Codex", bundleID: "com.openai.codex")))
        #expect(structured.mode == .structured && structured.text == "- 嗯明天下午三点开会")
        #expect(hub.polisher.calls.last?.mode == .structured)

        let off = try decode(DictationResult.self,
                             try await hub.dictate(dictation(autoStructured: false, appName: "Codex", bundleID: "com.openai.codex")))
        #expect(off.mode == .natural)

        let raw = try decode(DictationResult.self, try await hub.dictate(dictation(mode: .raw)))
        #expect(raw.mode == .raw && !raw.polished && raw.fallback == nil && raw.text == raw.raw)
        #expect(hub.polisher.calls.count == 2)
    }

    @Test func undecodableAudio() async throws {
        let hub = try HubFixture()
        let garbage = Data("this is not audio at all".utf8)
        let refused = try await hub.dictate(dictation(), audio: garbage)
        #expect(refused.status == .unprocessableContent)
        #expect(errorBody(refused)?.code == HubErrorCode.decodeFailed)
        // With the device's own transcript, nothing is lost.
        let local = try decode(DictationResult.self, try await hub.dictate(dictation(local: "本机听到的"), audio: garbage))
        #expect(local.raw == "本机听到的" && local.recognizer == .local && local.polished)
        #expect(hub.asr.calls.isEmpty)
    }

    @Test func workerDown() async throws {
        let hub = try HubFixture()
        hub.asr.reply = .fail(.unreachable)
        let refused = try await hub.dictate(dictation())
        #expect(refused.status == .serviceUnavailable)
        let body = try #require(errorBody(refused))
        #expect(body.code == HubErrorCode.asrUnavailable && body.retryable)
        #expect(hub.service.history.entries.isEmpty)

        let local = try decode(DictationResult.self, try await hub.dictate(dictation(local: "本机听到的")))
        #expect(local.recognizer == .local && local.raw == "本机听到的")

        hub.asr.reply = .fail(.rejected(status: 413, code: "too_long"))
        #expect(try await hub.dictate(dictation()).status == .contentTooLarge)
    }

    @Test func heardNothingIsNotKeptAndTheLocalTranscriptFollows() async throws {
        let hub = try HubFixture()
        hub.asr.reply = .silence
        let id = UUID()
        let empty = try decode(DictationResult.self, try await hub.dictate(dictation(id)))
        #expect(empty.raw.isEmpty && empty.text.isEmpty && !empty.polished && empty.clientRecordingID == id)
        #expect(hub.service.history.entries.isEmpty && hub.polisher.calls.isEmpty)

        // The device sends its own transcript under the same id (`DictationRequest.polishRequest(text:)`).
        let polish = dictation(id).polishRequest(text: "本机听到的话")
        let result = try decode(DictationResult.self, try await hub.post(HubPath.polish, polish))
        #expect(result.raw == "本机听到的话" && result.recognizer == .local && result.clientRecordingID == id)
        #expect(hub.service.history.entries.count == 1)
        #expect(hub.service.history.entries.first?.client == .ios)
    }

    // MARK: Polish

    @Test func polishHappyPathAndFallback() async throws {
        let hub = try HubFixture()
        let request = PolishRequest(text: "嗯明天开会", mode: .natural, autoStructured: true, appName: "微信",
                                    client: .mac, clientVersion: "1.2.0", durationSeconds: 2)
        let result = try decode(DictationResult.self, try await hub.post(HubPath.polish, request))
        #expect(result.text == "明天开会。" && result.polished && result.recognizer == .local)
        let saved = try #require(hub.service.history.entry(id: result.id))
        #expect(saved.client == .mac && saved.appName == "微信" && saved.durationSeconds == 2)

        hub.polisher.answer = { _, _ in throw PolishError.timeout }
        let failed = try decode(DictationResult.self,
                                try await hub.post(HubPath.polish, PolishRequest(text: "嗯后天开会", mode: .natural, autoStructured: true)))
        #expect(!failed.polished && failed.text == "嗯后天开会")
        #expect(failed.fallback == HubFallback(title: "已输入原文", reason: "整理超时"))
        #expect(hub.service.history.entry(id: failed.id) != nil)
    }

    /// 本机识别 on the Mac (`NeoModelChoice.local`): no recording, only its own transcript, through the route every
    /// hub has, and polished like the Neo's own.
    @Test func aMacsOwnTranscriptIsPolishedLikeWhatTheNeoHeard() async throws {
        // An invented fix towards a word of the dictionary, as in `fallbackAppliesConfirmedCorrections`.
        let hub = try HubFixture(words: ["音币"])
        _ = try hub.service.updateHabits(HabitsUpdate(items: ["句末不要句号"]))
        for _ in 0..<2 {
            hub.service.words.learn([CorrectionPair(wrong: "引必", right: "音币")], source: .inApp, recordID: UUID())
        }
        let id = UUID()
        let request = PolishRequest(text: "嗯问一下 Codex 引必还剩多少", mode: .natural, autoStructured: true, appName: "Codex",
                                    bundleID: "com.openai.codex", clientRecordingID: id, client: .mac,
                                    clientVersion: "1.4.0", durationSeconds: 3)
        let result = try decode(DictationResult.self, try await hub.post(HubPath.polish, request))
        // The AI-app rule, as for a recording.
        #expect(result.mode == .structured && result.polished && result.recognizer == .local)
        #expect(result.clientRecordingID == id && result.timings.asrMs == 0 && result.timings.decodeMs == 0)
        #expect(hub.asr.calls.isEmpty && hub.asr.warms.isEmpty)
        // The dictionary, what was learned and 我的习惯 go with it.
        let call = try #require(hub.polisher.calls.last)
        #expect(call.vocabulary.all.contains("Codex"))
        #expect(call.corrections.contains(CorrectionPair(wrong: "引必", right: "音币")))
        #expect(call.extras.habits == ["句末不要句号"])
        let saved = try #require(hub.service.history.entry(id: result.id))
        #expect(saved.client == .mac && saved.durationSeconds == 3 && saved.result.recognizer == .local)
        // Its id is one of the Neo's dictations: edits and 重新整理 go there.
        let edited = try decode(EditResponse.self,
                                try await hub.post(HubPath.edit(result.id), EditRequest(text: "问一下 Codex 音币还剩多少", learn: false)))
        #expect(edited.result.text == "问一下 Codex 音币还剩多少")
        #expect(try await hub.send(.post, HubPath.repolish(result.id)).status == .ok)
        // The same take sent again (a resend after a dropped connection) is not polished again.
        let again = try decode(DictationResult.self, try await hub.post(HubPath.polish, request))
        #expect(again.id == result.id && hub.polisher.calls.count == 2)
    }

    @Test func fallbackAppliesConfirmedCorrections() async throws {
        let hub = try HubFixture(words: ["音币"])
        // Fixed twice: confirmed, so the original is corrected even without ChatGPT. (引必 is no word anyone
        // says on purpose; a pair whose misheard side is a word, as 金币 → 音币, is left to the model.)
        for _ in 0..<2 {
            hub.service.words.learn([CorrectionPair(wrong: "引必", right: "音币"), CorrectionPair(wrong: "金币", right: "音币")],
                                    source: .inApp, recordID: UUID())
        }
        hub.polisher.answer = { _, _ in throw PolishError.http(429, "") }
        let result = try decode(DictationResult.self,
                                try await hub.post(HubPath.polish, PolishRequest(text: "看看引必和金币是多少", mode: .natural, autoStructured: true)))
        #expect(result.text == "看看音币和金币是多少" && result.raw == "看看引必和金币是多少")
        #expect(result.fallback == HubFallback(title: "已输入原文", reason: "ChatGPT 额度暂时用完"))
        // And ChatGPT is told about both when it answers.
        hub.polisher.answer = { text, _ in text }
        _ = try await hub.post(HubPath.polish, PolishRequest(text: "金币还剩多少", mode: .natural, autoStructured: true))
        #expect(hub.polisher.calls.last?.corrections == [CorrectionPair(wrong: "金币", right: "音币")])
    }

    // MARK: Once per recording

    @Test func sameRecordingTwiceIsWorkedOnOnce() async throws {
        let hub = try HubFixture()
        let request = dictation()
        let first = try decode(DictationResult.self, try await hub.dictate(request))
        let second = try decode(DictationResult.self, try await hub.dictate(request))
        #expect(first == second)
        #expect(hub.asr.calls.count == 1 && hub.polisher.calls.count == 1)
        // /v1/polish shares the id: the dictation's result, not a second job.
        let polish = try decode(DictationResult.self, try await hub.post(HubPath.polish, request.polishRequest(text: "别的")))
        #expect(polish == first && hub.polisher.calls.count == 1)
        #expect(hub.service.history.entries.count == 1)
    }

    @Test func aRepeatWhileRunningWaitsForTheSameJob() async throws {
        let hub = try HubFixture()
        let gate = Gate()
        hub.asr.gate = gate
        let request = dictation()
        async let first = hub.dictate(request)
        #expect(await eventually { gate.arrived == 1 })
        async let second = hub.dictate(request)
        // The second one waits for the first job before that is let go.
        #expect(await eventually { await MainActor.run { hub.service.joined == 1 } })
        gate.open()
        let (a, b) = try await (decode(DictationResult.self, first), decode(DictationResult.self, second))
        #expect(a == b)
        #expect(hub.asr.calls.count == 1 && hub.polisher.calls.count == 1)
    }

    @Test func aBusyWorkerIsNotWaitedForWhenTheDeviceHeardItToo() async throws {
        let hub = try HubFixture()
        let gate = Gate()
        hub.asr.gate = gate            // the worker never answers
        await MainActor.run { hub.service.impatientTimeout = { _ in 0.2 } }
        // The stub cannot be cancelled the way a real request can, so it is let go a little after the wait ran out:
        // counted from when the worker was asked, since decoding the audio first can take long on a busy Mac.
        Task {
            _ = await eventually { gate.arrived == 1 }
            try? await Task.sleep(nanoseconds: 600_000_000)
            gate.open()
        }
        let result = try decode(DictationResult.self, try await hub.dictate(dictation(local: "本机听到的话")))
        #expect(result.recognizer == .local && result.raw == "本机听到的话")
    }

    @Test func theImpatientWaitGrowsWithTheRecordingAndStaysShort() {
        func wait(_ seconds: Double) -> TimeInterval { ASRWorker.impatientTimeout(audioSeconds: seconds) }
        #expect(wait(0) == 2.5)
        #expect(abs(wait(10) - 6.5) < 0.001)
        #expect(wait(600) == 20 && wait(.infinity) == 2.5 && wait(.nan) == 2.5 && wait(-3) == 2.5)
        #expect(wait(30) < ASRWorker.timeout(audioSeconds: 30))
        // A calm Neo wins with either model: the large model's and the small one's measured times (audio seconds,
        // asrMs), each with room to spare.
        for (audio, took) in [(6.9, 2.8), (10.4, 3.0), (11.9, 3.3), (7.7, 1.0)] {
            #expect(wait(audio) >= 1.6 * took, "\(audio)")
        }
        // So does a recording with pauses that mixes the languages, at the large model's 0.5 s per second of audio,
        // up to 20 s of it.
        for audio in [3.0, 10, 20] { #expect(wait(audio) >= 0.5 * audio, "\(audio)") }
        // A swamped Neo is given up on in seconds: each of these measured waits would have ended sooner, by over a
        // second and a half.
        for (audio, took) in [(7.3, 7.2), (5.3, 13.0), (13.1, 16.3), (21.9, 13.0)] {
            #expect(wait(audio) < took - 1.5, "\(audio)")
        }
        // Never longer than the wait before it (6 s + 0.8 s per second, at most a minute).
        for audio in [0.0, 5, 30, 120, 600] { #expect(wait(audio) <= min(60, 6 + 0.8 * audio)) }
        // The device's budget for a request that carries its transcript covers this wait, a model load's allowance
        // on top of it, and the polish that follows.
        let device = HubTimeouts.standard
        for seconds in [1.0, 5, 15, 30, 60, 120] {
            let polish = PolishTimeout.seconds(forCharacters: Int(seconds * HubTimeouts.charactersPerAudioSecond),
                                               minimum: device.hubPolishFloor)
            let budget = device.dictation(durationSeconds: seconds, audioBytes: 0)
            #expect(budget >= device.connect + wait(seconds) + HubTimeouts.standInLoad + polish + device.margin, "\(seconds)")
        }
    }

    @Test func aFailureIsSharedAndTheNextTryRunsAgain() async throws {
        let hub = try HubFixture()
        let gate = Gate()
        hub.asr.gate = gate
        hub.asr.reply = .fail(.timeout)
        let request = dictation()
        async let first = hub.dictate(request)
        #expect(await eventually { gate.arrived == 1 })
        async let second = hub.dictate(request)
        #expect(await eventually { await MainActor.run { hub.service.joined == 1 } })
        gate.open()
        let (a, b) = try await (first, second)
        #expect(a.status == .serviceUnavailable && b.status == .serviceUnavailable)
        #expect(hub.asr.calls.count == 1)
        hub.asr.reply = .text("好了")
        let again = try decode(DictationResult.self, try await hub.dictate(request))
        #expect(again.raw == "好了" && hub.asr.calls.count == 2)
    }

    /// The device went away (or Cloudflare gave up after 100 s): the job still finishes and is saved.
    @Test func aDroppedRequestDoesNotStopTheJob() async throws {
        let hub = try HubFixture()
        let gate = Gate()
        hub.asr.gate = gate
        let request = dictation()
        let asking = Task { try await hub.service.dictate(audio: AudioFixture.m4a, type: .m4a, request: request) }
        #expect(await eventually { gate.arrived == 1 })
        asking.cancel()
        gate.open()
        let saved = await eventually { await MainActor.run { hub.service.history.entry(clientRecordingID: request.clientRecordingID) != nil } }
        #expect(saved)
        // Asked again: the saved result, no second recognition.
        let result = try decode(DictationResult.self, try await hub.dictate(request))
        #expect(result.text == "明天下午三点开会。" && hub.asr.calls.count == 1)
    }

    // MARK: Repolish

    @Test func repolish() async throws {
        let hub = try HubFixture()
        let original = try decode(DictationResult.self, try await hub.dictate(dictation()))
        let uri = "/v1/dictations/\(original.id.uuidString.lowercased())/repolish"

        let structured = try decode(DictationResult.self, try await hub.post(uri, RepolishRequest(mode: .structured)))
        #expect(structured.id == original.id && structured.mode == .structured && structured.text == "- 嗯明天下午三点开会")
        #expect(structured.createdAt == original.createdAt)

        let raw = try decode(DictationResult.self, try await hub.post(uri, RepolishRequest(mode: .raw)))
        #expect(raw.mode == .raw && raw.text == raw.raw && !raw.polished)
        #expect(hub.polisher.calls.count == 2)

        // No mode, and no body at all: a 原样转写 record is polished as 自然整理.
        let natural = try decode(DictationResult.self, try await hub.send(.post, uri))
        #expect(natural.mode == .natural && natural.polished && natural.text == "明天下午三点开会。")
        #expect(hub.service.history.entry(id: original.id)?.result == natural)

        let missing = try await hub.post("/v1/dictations/\(UUID().uuidString)/repolish", RepolishRequest())
        #expect(missing.status == .notFound && errorBody(missing)?.code == HubErrorCode.notFound)
    }

    @Test func repolishFailureKeepsTheText() async throws {
        let hub = try HubFixture()
        let original = try decode(DictationResult.self, try await hub.dictate(dictation()))
        hub.polisher.answer = { _, _ in throw PolishError.notSignedIn }
        let response = try await hub.post(HubPath.repolish(original.id), RepolishRequest(mode: .structured))
        #expect(response.status == .serviceUnavailable)
        #expect(errorBody(response) == HubErrorBody(error: "未登录 ChatGPT", code: HubErrorCode.polishFailed, retryable: false))
        #expect(hub.service.history.entry(id: original.id)?.result == original)

        // The few words, not the app's "…在设置里重新登录": the login is the Neo's.
        hub.polisher.answer = { _, _ in throw PolishError.http(401, "") }
        let refused = try await hub.post(HubPath.repolish(original.id), RepolishRequest(mode: .structured))
        #expect(errorBody(refused) == HubErrorBody(error: "ChatGPT 登录已失效", code: HubErrorCode.polishFailed, retryable: false))
    }

    @Test func repolishAskedTwiceWhileRunningCallsChatGPTOnce() async throws {
        let hub = try HubFixture()
        let original = try decode(DictationResult.self, try await hub.dictate(dictation()))
        let gate = Gate()
        hub.polisher.gate = gate
        async let first = hub.post(HubPath.repolish(original.id), RepolishRequest(mode: .structured))
        #expect(await eventually { gate.arrived == 1 })
        async let second = hub.post(HubPath.repolish(original.id), RepolishRequest(mode: .structured))
        #expect(await eventually { await MainActor.run { hub.service.joined == 1 } })
        gate.open()
        let (a, b) = try await (decode(DictationResult.self, first), decode(DictationResult.self, second))
        #expect(a == b && a.mode == .structured)
        #expect(hub.polisher.calls.count == 2)   // the dictation, then one repolish
    }

    @Test func anEditWhileRepolishingIsKept() async throws {
        let hub = try HubFixture()
        hub.asr.reply = .text("我的 I phone 坏了")
        let original = try decode(DictationResult.self, try await hub.dictate(dictation()))
        let gate = Gate()
        hub.polisher.gate = gate
        async let repolishing = hub.post(HubPath.repolish(original.id), RepolishRequest(mode: .structured))
        #expect(await eventually { gate.arrived == 1 })
        // The Mac fixes a word in the same dictation while ChatGPT works on the iPhone's repolish.
        let edit = try decode(EditResponse.self, try await hub.post(HubPath.edit(original.id),
                                                                    EditRequest(text: "我的 iPhone 坏了。")))
        #expect(edit.learned == [CorrectionPair(wrong: "I phone", right: "iPhone")])
        gate.open()
        let response = try await repolishing
        #expect(response.status == .ok)
        let repolished = try decode(DictationResult.self, response)
        #expect(repolished == edit.result && repolished.text == "我的 iPhone 坏了。")
        let entry = hub.service.history.entry(id: original.id)
        #expect(entry?.result == edit.result && entry?.edited == true)

        // Asked for after the edit, a repolish replaces it as usual.
        hub.polisher.gate = nil
        let again = try decode(DictationResult.self, try await hub.post(HubPath.repolish(original.id),
                                                                       RepolishRequest(mode: .structured)))
        #expect(again.mode == .structured && again.text == "- 我的 I phone 坏了")
        #expect(hub.service.history.entry(id: original.id)?.edited == false)
    }

    // MARK: Edit and learning

    @Test func editLearnsOnceAndIsIdempotent() async throws {
        let hub = try HubFixture()
        hub.polisher.answer = { text, _ in text }
        hub.asr.reply = .text("我的 I phone 坏了")
        let original = try decode(DictationResult.self, try await hub.dictate(dictation()))
        let before = try decode(VocabularySnapshot.self, try await hub.send(.get, HubPath.vocabulary))

        let uri = HubPath.edit(original.id)
        let edited = try decode(EditResponse.self, try await hub.post(uri, EditRequest(text: "我的 iPhone 坏了")))
        #expect(edited.learned == [CorrectionPair(wrong: "I phone", right: "iPhone")])
        #expect(edited.result.text == "我的 iPhone 坏了" && edited.result.id == original.id)

        let learning = try decode(LearningList.self, try await hub.send(.get, HubPath.learning))
        #expect(learning.pairs.map(\.pair) == [CorrectionPair(wrong: "I phone", right: "iPhone")])
        #expect(learning.pairs.first?.count == 1)
        // The term went into the dictionary as a learned one, which changed its revision.
        let after = try decode(VocabularySnapshot.self, try await hub.send(.get, HubPath.vocabulary))
        #expect(after.words.first == "iPhone" && after.learned == ["iPhone"] && after.revision != before.revision)

        // Sent again after a dropped connection: nothing more is learned.
        let again = try decode(EditResponse.self, try await hub.post(uri, EditRequest(text: "我的 iPhone 坏了")))
        #expect(again.learned.isEmpty && again.result == edited.result)
        #expect(try decode(LearningList.self, try await hub.send(.get, HubPath.learning)).pairs.first?.count == 1)

        let page = try decode(HistoryPage.self, try await hub.send(.get, HubPath.history))
        #expect(page.items.first?.edited == true && page.items.first?.result.text == "我的 iPhone 坏了")

        let missing = try await hub.post(HubPath.edit(UUID()), EditRequest(text: "x"))
        #expect(missing.status == .notFound)
    }

    @Test func aFixFixedAgainIsLearnedAsOne() async throws {
        let hub = try HubFixture(words: ["音币"])
        hub.polisher.answer = { text, _ in text }
        hub.asr.reply = .text("看看金币是多少")
        let original = try decode(DictationResult.self, try await hub.dictate(dictation()))
        _ = try await hub.post(HubPath.edit(original.id), EditRequest(text: "看看瘾币是多少"))
        let second = try decode(EditResponse.self, try await hub.post(HubPath.edit(original.id), EditRequest(text: "看看音币是多少")))
        #expect(second.learned == [CorrectionPair(wrong: "金币", right: "音币")])
        let learning = try decode(LearningList.self, try await hub.send(.get, HubPath.learning))
        #expect(learning.pairs.map(\.pair) == [CorrectionPair(wrong: "金币", right: "音币")])
    }

    @Test func observationsAndForgetting() async throws {
        let hub = try HubFixture()
        let body = LearningObservations(pairs: [CorrectionPair(wrong: "You Tube", right: "YouTube"),
                                                CorrectionPair(wrong: " ", right: "x"),
                                                CorrectionPair(wrong: "同", right: "同")])
        let accepted = try decode(LearningObservationsResponse.self, try await hub.post(HubPath.learningObservations, body))
        #expect(accepted.accepted == 1)
        #expect(try decode(VocabularySnapshot.self, try await hub.send(.get, HubPath.vocabulary)).learned == ["YouTube"])

        let wrong = "You Tube".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let after = try decode(LearningList.self, try await hub.send(.delete, "\(HubPath.learning)?wrong=\(wrong)"))
        #expect(after.pairs.isEmpty)
        // Learning added the word, so forgetting takes it out again.
        #expect(!(try decode(VocabularySnapshot.self, try await hub.send(.get, HubPath.vocabulary)).words.contains("YouTube")))
        // Forgetting it again is not an error.
        #expect(try await hub.send(.delete, "\(HubPath.learning)?wrong=\(wrong)").status == .ok)
        #expect(try await hub.send(.delete, HubPath.learning).status == .badRequest)
    }

    // MARK: Vocabulary, history, sync

    @Test func vocabularyRevisions() async throws {
        let hub = try HubFixture()
        let first = try decode(VocabularySnapshot.self, try await hub.send(.get, HubPath.vocabulary))
        #expect(first.words == Vocabulary.defaults && first.learned.isEmpty && !first.revision.isEmpty)

        let update = VocabularyUpdate(words: ["  Hummingbird ", "Neo", "neo"] + first.words, expectedRevision: first.revision)
        let second = try decode(VocabularySnapshot.self, try await hub.send(.put, HubPath.vocabulary, body: try json(update)))
        #expect(second.words.prefix(2) == ["Hummingbird", "Neo"] && second.words.count == first.words.count + 2)
        #expect(second.revision != first.revision)

        // Another device still has the first revision: refused, nothing changes.
        let stale = VocabularyUpdate(words: ["别的"], expectedRevision: first.revision)
        let conflict = try await hub.send(.put, HubPath.vocabulary, body: try json(stale))
        #expect(conflict.status == .conflict)
        #expect(errorBody(conflict)?.code == HubErrorCode.conflict)
        #expect(try decode(VocabularySnapshot.self, try await hub.send(.get, HubPath.vocabulary)) == second)
        // The hints follow the dictionary.
        _ = try await hub.dictate(dictation())
        #expect(hub.asr.calls.last?.hints.prefix(2) == ["Hummingbird", "Neo"])
    }

    @Test func historyPagesAndDeletes() async throws {
        let hub = try HubFixture()
        var made: [DictationResult] = []
        for i in 0..<5 {
            made.append(try decode(DictationResult.self,
                                   try await hub.post(HubPath.polish, PolishRequest(text: "第\(i)条", mode: .raw, autoStructured: true))))
        }
        let first = try decode(HistoryPage.self, try await hub.send(.get, "\(HubPath.history)?limit=2"))
        #expect(first.items.map(\.id) == [made[4].id, made[3].id])
        let before = try #require(first.nextBefore)
        let encoded = before.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let second = try decode(HistoryPage.self, try await hub.send(.get, "\(HubPath.history)?limit=2&before=\(encoded)"))
        #expect(second.items.map(\.id) == [made[2].id, made[1].id])
        let last = try decode(HistoryPage.self,
                              try await hub.send(.get, "\(HubPath.history)?limit=2&before=\(second.nextBefore!.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)"))
        #expect(last.items.map(\.id) == [made[0].id] && last.nextBefore == nil)

        let all = try decode(HistoryPage.self, try await hub.send(.get, "\(HubPath.history)?limit=500"))
        #expect(all.items.count == 5 && all.nextBefore == nil)
        #expect(all.items.first?.client == .mac && all.items.first?.edited == false)   // PolishRequest says .current
        #expect(try await hub.send(.get, "\(HubPath.history)?limit=0").status == .badRequest)
        #expect(try await hub.send(.get, "\(HubPath.history)?before=yesterday").status == .badRequest)

        let deleted = try await hub.send(.delete, HubPath.historyItem(made[4].id))
        #expect(deleted.status == .ok)
        #expect(try decode(HubOK.self, deleted) == HubOK())
        let again = try await hub.send(.delete, HubPath.historyItem(made[4].id))
        #expect(again.status == .notFound && errorBody(again)?.code == HubErrorCode.notFound)
        #expect(try decode(HistoryPage.self, try await hub.send(.get, HubPath.history)).items.count == 4)
    }

    @Test func sync() async throws {
        let hub = try HubFixture()
        hub.service.words.learn([CorrectionPair(wrong: "金币", right: "硬币")], source: .inApp, recordID: nil)
        let snapshot = try decode(SyncSnapshot.self, try await hub.send(.get, HubPath.sync))
        #expect(snapshot.vocabulary == hub.service.words.snapshot)
        #expect(snapshot.learning.pairs.map(\.pair) == [CorrectionPair(wrong: "金币", right: "硬币")])
        #expect(snapshot.settings == HubSettings(autoStructured: true))
    }

    // MARK: Log

    @Test func oneLogLinePerRequestWithoutWords() async throws {
        let hub = try HubFixture()
        let token = try hub.service.devices.pair(name: "日志测试").token
        hub.asr.reply = .text("这句话不能出现在日志里")
        let headers = try hub.dictationHeaders(dictation(local: "本机的话也不能出现"))
        var fields = headers
        fields[.authorization] = "Bearer \(token)"
        _ = try await hub.send(.post, HubPath.dictations, headers: fields, body: ByteBuffer(bytes: AudioFixture.m4a))
        let lines = TestLog.shared.all
        #expect(lines.contains { $0.contains("POST /v1/dictations 200") && $0.hasSuffix(" 日志测试") })
        #expect(!lines.contains { $0.contains("这句话") || $0.contains("本机的话") || $0.contains(token) })
    }
}
