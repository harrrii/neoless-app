import Foundation
import NeolessCore
import Testing
@testable import NeolessCloud

/// The keys of a JSON object, to check bodies against the contract in docs/hub.md.
private func keys(_ data: Data) throws -> Set<String> {
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return Set(object.keys)
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try HubJSON.decode(T.self, from: HubJSON.encode(value))
}

private let created = HubJSON.date(from: "2026-10-09T08:30:00.123Z")!

private func sampleResult(fallback: HubFallback? = nil) -> DictationResult {
    DictationResult(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                    clientRecordingID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                    raw: "嗯明天下午三点开会", text: "明天下午三点开会。", mode: .natural, polished: fallback == nil,
                    fallback: fallback, recognizer: .qwen3ASR,
                    timings: HubTimings(decodeMs: 12, asrMs: 640, polishMs: 1800, totalMs: 2460), createdAt: created)
}

@Suite struct Base64URLTests {
    @Test func roundTripsEveryByte() {
        let data = Data((0...255).map { UInt8($0) } + [0xFB, 0xFF, 0xFE])
        let text = Base64URL.encode(data)
        #expect(!text.contains("+") && !text.contains("/") && !text.contains("="))
        #expect(Base64URL.decode(text) == data)
    }

    @Test func acceptsPaddingAndRejectsOtherAlphabets() {
        #expect(Base64URL.decode("aGk") == Data("hi".utf8))
        #expect(Base64URL.decode("aGk=") == Data("hi".utf8))
        #expect(Base64URL.decode("+/8") == nil)
        #expect(Base64URL.decode("a") == nil)
        #expect(Base64URL.decode("中文") == nil)
        #expect(Base64URL.decode("") == Data())
    }
}

@Suite struct HubDateTests {
    @Test func millisecondsInUTC() {
        let date = Date(timeIntervalSince1970: 1_760_000_000.1234)
        #expect(HubJSON.string(from: date) == "2025-10-09T08:53:20.123Z")
        #expect(HubJSON.string(from: Date(timeIntervalSince1970: 1_760_000_000)) == "2025-10-09T08:53:20.000Z")
        // .9996 rounds up into the next second.
        #expect(HubJSON.string(from: Date(timeIntervalSince1970: 1_760_000_000.9996)) == "2025-10-09T08:53:21.000Z")
    }

    @Test func roundedDatesSurviveARoundTrip() {
        for offset in [0.0, 0.001, 0.123, 0.5, 0.999, 0.4567, 1234.5678] {
            let date = HubJSON.rounded(Date(timeIntervalSince1970: 1_760_000_000 + offset))
            #expect(HubJSON.date(from: HubJSON.string(from: date)) == date, "\(offset)")
        }
    }

    @Test func readsOtherISO8601Forms() {
        let base = Date(timeIntervalSince1970: 1_760_000_000)
        #expect(HubJSON.date(from: "2025-10-09T08:53:20Z") == base)
        #expect(HubJSON.date(from: "2025-10-09T08:53:20.5Z") == base.addingTimeInterval(0.5))
        #expect(HubJSON.date(from: "2025-10-09T16:53:20+08:00") == base)
        #expect(HubJSON.date(from: "2025-10-09T08:53:20.+Z") == nil)
        #expect(HubJSON.date(from: "昨天") == nil)
    }
}

@Suite struct DictationRequestTests {
    let request = DictationRequest(mode: .natural, autoStructured: true, appName: "微信", bundleID: "com.tencent.xinWeChat",
                                   localTranscript: "明天下午三点开会", durationSeconds: 4.25,
                                   clientRecordingID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                                   client: .ios, clientVersion: "1.2.0")

    @Test func fieldsMatchTheContract() throws {
        let body = try object(HubJSON.encode(request))
        #expect(Set(body.keys) == ["mode", "autoStructured", "appName", "bundleID", "locale", "localTranscript",
                                   "durationSeconds", "clientRecordingID", "client", "clientVersion"])
        #expect(body["mode"] as? String == "natural")
        #expect(body["locale"] as? String == "zh-CN")
        #expect(body["client"] as? String == "ios")
        #expect(body["clientRecordingID"] as? String == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        #expect(body["durationSeconds"] as? Double == 4.25)
    }

    @Test func headerRoundTrip() throws {
        let value = try request.headerValue()
        #expect(value.unicodeScalars.allSatisfy { Base64URL.isAlphabet($0) })
        #expect(try DictationRequest(headerValue: value) == request)
        // A padded value from another encoder reads the same.
        let padded = try HubJSON.encode(request).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        #expect(try DictationRequest(headerValue: padded) == request)
    }

    @Test func optionalFieldsMayBeLeftOut() throws {
        let minimal = #"{"mode":"raw","autoStructured":false,"locale":"zh-CN","durationSeconds":1,"clientRecordingID":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","client":"mac","clientVersion":"1.2.0"}"#
        let decoded = try DictationRequest(headerValue: Base64URL.encode(Data(minimal.utf8)))
        #expect(decoded.appName == nil && decoded.bundleID == nil && decoded.localTranscript == nil)
        #expect(decoded.mode == .raw && decoded.client == .mac)
        #expect(decoded.clientRecordingID == UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        #expect(!(try keys(HubJSON.encode(decoded))).contains("appName"))
    }

    @Test func longLocalTranscriptIsLeftOutNotCut() throws {
        var long = request
        long.localTranscript = String(repeating: "明天下午三点开会，", count: 600)
        let value = try long.headerValue()
        #expect(value.utf8.count <= Hub.maxRequestHeaderBytes)
        let decoded = try DictationRequest(headerValue: value)
        #expect(decoded.localTranscript == nil)
        #expect(decoded.clientRecordingID == request.clientRecordingID && decoded.appName == "微信")
    }

    @Test func fallbackPolishIsTheSameRecording() {
        // The hub heard nothing and the transcript had been left out of the header: the device's own transcript
        // goes to /v1/polish under the recording's id (the hub keeps no empty result under it).
        let polish = request.polishRequest(text: "明天下午三点开会")
        #expect(polish == PolishRequest(text: "明天下午三点开会", mode: .natural, autoStructured: true, appName: "微信",
                                        bundleID: "com.tencent.xinWeChat", clientRecordingID: request.clientRecordingID,
                                        client: .ios, clientVersion: "1.2.0", durationSeconds: 4.25))
        #expect(polish.effectiveMode == request.effectiveMode)
    }

    @Test func tooLongEvenWithoutTranscript() {
        var huge = request
        huge.appName = String(repeating: "应用", count: 3_000)
        #expect(throws: HubProtocolError.requestHeaderTooLarge) { try huge.headerValue() }
    }

    @Test func badHeadersAreRefused() {
        for value in ["", "%%%", Base64URL.encode(Data("{}".utf8)), Base64URL.encode(Data("not json".utf8)),
                      Base64URL.encode(Data(#"{"mode":"loud","autoStructured":true,"locale":"zh-CN","durationSeconds":1,"clientRecordingID":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","client":"mac","clientVersion":"1"}"#.utf8))] {
            #expect(throws: HubProtocolError.badRequestHeader) { try DictationRequest(headerValue: value) }
        }
        var negative = request
        negative.durationSeconds = -1
        #expect(throws: HubProtocolError.badRequestHeader) { try DictationRequest(headerValue: negative.headerValue()) }
    }

    @Test func effectiveModeFollowsAIApps() {
        var codex = request
        codex.appName = "Codex"
        codex.bundleID = "com.openai.codex"
        #expect(codex.effectiveMode == .structured)
        #expect(request.effectiveMode == .natural)
        codex.autoStructured = false
        #expect(codex.effectiveMode == .natural)
    }
}

@Suite struct DictationResultTests {
    @Test func fieldsMatchTheContract() throws {
        let data = try HubJSON.encode(sampleResult())
        let body = try object(data)
        #expect(Set(body.keys) == ["id", "clientRecordingID", "raw", "text", "mode", "polished", "recognizer", "timings", "createdAt"])
        #expect(body["recognizer"] as? String == "qwen3-asr")
        #expect(body["createdAt"] as? String == "2026-10-09T08:30:00.123Z")
        let timings = try #require(body["timings"] as? [String: Any])
        #expect(Set(timings.keys) == ["decodeMs", "asrMs", "polishMs", "totalMs"])
        #expect(try roundTrip(sampleResult()) == sampleResult())
    }

    @Test func fallbackIsPresentOnlyWhenSet() throws {
        let fallen = sampleResult(fallback: HubFallback(title: "已输入原文", reason: "整理超时"))
        let body = try object(HubJSON.encode(fallen))
        let fallback = try #require(body["fallback"] as? [String: String])
        #expect(fallback == ["title": "已输入原文", "reason": "整理超时"])
        #expect(try roundTrip(fallen) == fallen)
    }

    @Test func readsDatesWithoutMilliseconds() throws {
        var body = try object(HubJSON.encode(sampleResult()))
        body["createdAt"] = "2026-10-09T08:30:00Z"
        let decoded = try HubJSON.decode(DictationResult.self, from: JSONSerialization.data(withJSONObject: body))
        #expect(decoded.createdAt == HubJSON.date(from: "2026-10-09T08:30:00.000Z"))
    }

    @Test func unknownRecognizerIsKept() throws {
        var body = try object(HubJSON.encode(sampleResult()))
        body["recognizer"] = "whisper-large"
        let decoded = try HubJSON.decode(DictationResult.self, from: JSONSerialization.data(withJSONObject: body))
        #expect(decoded.recognizer.rawValue == "whisper-large")
        #expect(try object(HubJSON.encode(decoded))["recognizer"] as? String == "whisper-large")
    }
}

@Suite struct HubBodyTests {
    @Test func historyItemIsOneFlatObject() throws {
        let item = HistoryItem(result: sampleResult(), appName: "备忘录", client: .mac, edited: true)
        let body = try object(HubJSON.encode(item))
        #expect(Set(body.keys) == ["id", "clientRecordingID", "raw", "text", "mode", "polished", "recognizer", "timings",
                                   "createdAt", "appName", "client", "edited"])
        #expect(body["edited"] as? Bool == true)
        #expect(try roundTrip(item) == item)
        #expect(item.id == sampleResult().id)

        // `edited` left out reads as false; appName and client are optional.
        var bare = body
        bare["edited"] = nil
        bare["appName"] = nil
        bare["client"] = nil
        let decoded = try HubJSON.decode(HistoryItem.self, from: JSONSerialization.data(withJSONObject: bare))
        #expect(decoded == HistoryItem(result: sampleResult()))
    }

    @Test func historyPage() throws {
        let page = HistoryPage(items: [HistoryItem(result: sampleResult(), appName: "微信", client: .ios)],
                               nextBefore: "2026-10-09T08:30:00.123Z")
        #expect(try keys(HubJSON.encode(page)) == ["items", "nextBefore"])
        #expect(try roundTrip(page) == page)
        #expect(try keys(HubJSON.encode(HistoryPage(items: []))) == ["items"])
    }

    @Test func health() throws {
        let health = HubHealth(version: "1.2.0", asr: .init(ready: true, model: "Qwen3-ASR-0.6B-4bit"),
                               chatgpt: .init(ready: true, account: "a***@example.com"), device: "iPhone")
        let body = try object(HubJSON.encode(health))
        #expect(Set(body.keys) == ["ok", "version", "asr", "chatgpt", "device"])
        #expect(Set(try #require(body["chatgpt"] as? [String: Any]).keys) == ["ready", "account"])
        #expect(Set(try #require(body["asr"] as? [String: Any]).keys) == ["ready", "model"])
        #expect(try roundTrip(health) == health)
        let problem = HubHealth(version: "1.2.0", asr: .init(ready: false, model: "Qwen3-ASR-0.6B-4bit"),
                                chatgpt: .init(ready: false, problem: "ChatGPT 登录已过期"), device: "Mac")
        #expect(try roundTrip(problem) == problem)
    }

    @Test func polishAndEditBodies() throws {
        let polish = PolishRequest(text: "明天开会", mode: .structured, autoStructured: false, appName: "Codex",
                                   bundleID: "com.openai.codex", client: .mac, clientVersion: "1.2.0", durationSeconds: 3)
        #expect(try keys(HubJSON.encode(polish)) == ["text", "mode", "autoStructured", "appName", "bundleID", "clientRecordingID",
                                                      "client", "clientVersion", "durationSeconds"])
        #expect(try roundTrip(polish) == polish)
        let minimal = PolishRequest(text: "好", mode: .raw, autoStructured: true, client: nil)
        #expect(try keys(HubJSON.encode(minimal)) == ["text", "mode", "autoStructured", "clientRecordingID"])

        #expect(try HubJSON.encode(RepolishRequest()) == Data("{}".utf8))
        #expect(try roundTrip(RepolishRequest(mode: .structured)) == RepolishRequest(mode: .structured))
        #expect(try HubJSON.encode(EditRequest(text: "硬币")) == Data(#"{"text":"硬币"}"#.utf8))

        let edit = EditResponse(result: sampleResult(), learned: [CorrectionPair(wrong: "引必", right: "硬币")])
        let body = try object(HubJSON.encode(edit))
        #expect(Set(body.keys) == ["result", "learned"])
        #expect(body["learned"] as? [[String: String]] == [["wrong": "引必", "right": "硬币"]])
        #expect(try roundTrip(edit) == edit)
    }

    @Test func learningBodies() throws {
        let observations = LearningObservations(pairs: [CorrectionPair(wrong: "欧喷", right: "Open")], dictationID: sampleResult().id)
        #expect(try keys(HubJSON.encode(observations)) == ["pairs", "dictationID"])
        #expect(try roundTrip(observations) == observations)
        #expect(try HubJSON.encode(LearningObservationsResponse(accepted: 1)) == Data(#"{"accepted":1}"#.utf8))

        let list = LearningList(pairs: [LearningEntry(wrong: "欧喷", right: "Open", count: 3, lastSeen: created)])
        let entry = try #require(try object(HubJSON.encode(list))["pairs"] as? [[String: Any]]).first
        #expect(Set(try #require(entry).keys) == ["wrong", "right", "count", "lastSeen"])
        #expect(entry?["lastSeen"] as? String == "2026-10-09T08:30:00.123Z")
        #expect(try roundTrip(list) == list)
        #expect(list.pairs[0].pair == CorrectionPair(wrong: "欧喷", right: "Open"))
    }

    @Test func vocabularyAndSync() throws {
        let vocabulary = VocabularySnapshot(words: ["Martin", "硬币"], learned: ["硬币"], revision: "r7")
        #expect(try keys(HubJSON.encode(vocabulary)) == ["words", "learned", "revision"])
        let update = VocabularyUpdate(words: ["Martin"], expectedRevision: "r7")
        #expect(try keys(HubJSON.encode(update)) == ["words", "expectedRevision"])
        let sync = SyncSnapshot(vocabulary: vocabulary, learning: LearningList(), settings: HubSettings(autoStructured: false))
        let body = try object(HubJSON.encode(sync))
        #expect(Set(body.keys) == ["vocabulary", "learning", "settings"])
        #expect(body["settings"] as? [String: Bool] == ["autoStructured": false])
        for value in [vocabulary] { #expect(try roundTrip(value) == value) }
        #expect(try roundTrip(update) == update)
        #expect(try roundTrip(sync) == sync)
    }

    @Test func errorBodyAndOK() throws {
        let error = HubErrorBody(error: "设备已被吊销", code: HubErrorCode.forbidden, retryable: false)
        #expect(try HubJSON.encode(error) == Data(#"{"code":"forbidden","error":"设备已被吊销","retryable":false}"#.utf8))
        #expect(try roundTrip(error) == error)
        #expect(try HubJSON.encode(HubOK()) == Data(#"{"ok":true}"#.utf8))
    }

    @Test func workerBodies() throws {
        let health = ASRWorkerHealth(ok: true, model: "Qwen3-ASR-0.6B-4bit", loaded: false)
        #expect(try keys(HubJSON.encode(health)) == ["ok", "model", "loaded"])
        let result = ASRWorkerResult(raw: "", status: .noSpeech, asrMs: 20, model: "Qwen3-ASR-0.6B-4bit")
        #expect(try object(HubJSON.encode(result))["status"] as? String == "no_speech")
        #expect(try roundTrip(result) == result)
        #expect(try roundTrip(health) == health)
    }

    /// The exact bodies hub/asr/asr_worker.py sends.
    @Test func workerBodiesFromThePythonWorker() throws {
        let health = try HubJSON.decode(ASRWorkerHealth.self, from: Data(
            #"{"ok": false, "model": "Qwen3-ASR-0.6B-4bit", "loaded": false, "pending": 2, "problem": "模型加载失败"}"#.utf8))
        #expect(health == ASRWorkerHealth(ok: false, model: "Qwen3-ASR-0.6B-4bit", loaded: false, pending: 2, problem: "模型加载失败"))
        let result = try HubJSON.decode(ASRWorkerResult.self, from: Data(
            #"{"raw": "明天开会", "status": "ok", "asrMs": 412, "loadMs": 0, "queueMs": 3, "model": "Qwen3-ASR-0.6B-4bit", "audioSeconds": 4.8}"#.utf8))
        #expect(result == ASRWorkerResult(raw: "明天开会", status: .ok, asrMs: 412, model: "Qwen3-ASR-0.6B-4bit",
                                          loadMs: 0, queueMs: 3, audioSeconds: 4.8))
        #expect(try keys(HubJSON.encode(result)) == ["raw", "status", "asrMs", "model", "loadMs", "queueMs", "audioSeconds"])
    }

    @Test func hintsHeader() {
        let hints = ["Martin", "硬币", "OpenLess", "neoless"]
        #expect(ASRHints.decode(ASRHints.headerValue(hints)) == hints)
        #expect(ASRHints.decode(ASRHints.headerValue([])) == [])
        // Too many: cut from the end (least important) until it fits.
        let many = (0..<2_000).map { "热词\($0)" }
        let value = ASRHints.headerValue(many)
        #expect(value.utf8.count <= Hub.maxHintsHeaderBytes)
        let kept = ASRHints.decode(value) ?? []
        #expect(!kept.isEmpty && kept.count < many.count)
        #expect(Array(many.prefix(kept.count)) == kept)
        #expect(ASRHints.decode("@@") == nil)
    }

    @Test func audioTypes() {
        #expect(HubAudioType(contentType: "audio/mp4") == .m4a)
        #expect(HubAudioType(contentType: "Audio/MP4; codecs=mp4a.40.2") == .m4a)
        #expect(HubAudioType(contentType: "audio/x-m4a") == .m4a)
        #expect(HubAudioType(contentType: "audio/wav") == .wav)
        #expect(HubAudioType(contentType: "audio/x-wav") == .wav)
        #expect(HubAudioType(contentType: "audio/x-caf") == .caf)
        #expect(HubAudioType(contentType: "audio/mpeg") == nil)
        #expect(HubAudioType(contentType: "") == nil)
        #expect(HubAudioType.m4a.fileExtension == "m4a")
    }

    @Test func pathsAndClientKind() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        #expect(HubPath.repolish(id) == "/v1/dictations/11111111-2222-3333-4444-555555555555/repolish")
        #expect(HubPath.edit(id) == "/v1/dictations/11111111-2222-3333-4444-555555555555/edit")
        #expect(HubPath.historyItem(id) == "/v1/history/11111111-2222-3333-4444-555555555555")
        #expect(HubClientKind.current == .mac)
        #expect(HubClientKind(rawValue: "watch").rawValue == "watch")
    }
}

@Suite struct HubPairingTests {
    let token = HubToken.generate()

    @Test func linkRoundTrip() throws {
        let pairing = try HubPairing(server: URL(string: "https://hub.example.com/")!, token: token, name: "小明的 iPhone & Mac+1")
        let link = pairing.url
        #expect(link.scheme == "neoless" && link.host == "pair")
        #expect(!link.absoluteString.contains(" "))
        #expect(link.absoluteString.hasPrefix("neoless://pair?server=https%3A%2F%2Fhub.example.com&token="))
        let parsed = try HubPairing(url: link)
        #expect(parsed == pairing)
        #expect(parsed.server.absoluteString == "https://hub.example.com")
        #expect(parsed.name == "小明的 iPhone & Mac+1")
    }

    @Test func readsHandWrittenAndPastedLinks() throws {
        let plain = try HubPairing(link: "  neoless://pair?server=https://hub.example.com&token=\(token)&name=iPhone\n")
        #expect(plain.server == URL(string: "https://hub.example.com"))
        #expect(plain.token == token && plain.name == "iPhone")
        let noName = try HubPairing(link: "neoless://pair?token=\(token)&server=https%3A%2F%2Fhub.example.com%2F")
        #expect(noName.name == "" && noName.server.absoluteString == "https://hub.example.com")
        let local = try HubPairing(link: "neoless://pair?server=http://127.0.0.1:18800&token=\(token)&name=Mac")
        #expect(local.server.absoluteString == "http://127.0.0.1:18800")
        let opaque = try HubPairing(link: "NEOLESS:pair?server=https://hub.example.com&token=\(token)")
        #expect(opaque.token == token)
    }

    @Test func refusesBadLinks() {
        #expect(throws: HubProtocolError.notPairLink) { try HubPairing(link: "https://hub.example.com") }
        #expect(throws: HubProtocolError.notPairLink) { try HubPairing(link: "neoless://record") }
        #expect(throws: HubProtocolError.notPairLink) { try HubPairing(link: "不是链接") }
        #expect(throws: HubProtocolError.badServer) { try HubPairing(link: "neoless://pair?token=\(token)") }
        #expect(throws: HubProtocolError.badServer) {
            try HubPairing(link: "neoless://pair?server=http://hub.example.com&token=\(token)")
        }
        #expect(throws: HubProtocolError.badServer) {
            try HubPairing(link: "neoless://pair?server=ftp://hub.example.com&token=\(token)")
        }
        #expect(throws: HubProtocolError.badToken) { try HubPairing(link: "neoless://pair?server=https://hub.example.com") }
        #expect(throws: HubProtocolError.badToken) {
            try HubPairing(link: "neoless://pair?server=https://hub.example.com&token=short")
        }
        #expect(throws: HubProtocolError.badToken) {
            try HubPairing(link: "neoless://pair?server=https://hub.example.com&token=has+plus/slash=padding0000")
        }
    }

    @Test func tokens() {
        let a = HubToken.generate(), b = HubToken.generate()
        #expect(a.count == 43 && a != b && HubToken.isWellFormed(a))
        let hash = HubToken.hash(a)
        #expect(hash.count == 64 && hash == hash.lowercased())
        #expect(HubToken.hash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(HubToken.matches(a, hash: hash))
        #expect(HubToken.matches(a, hash: hash.uppercased()))
        #expect(!HubToken.matches(b, hash: hash))
        #expect(!HubToken.matches(a, hash: String(hash.dropLast())))
    }
}
