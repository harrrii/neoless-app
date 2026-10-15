import Foundation
import Testing
@testable import NeolessCloud
import NeolessCore

/// 识别模型 on the wire: the setting (`NeoModelChoice`, in the core) and the request field (`HubASRModel`) name
/// the same three things, and a request that leaves the choice to the Neo says nothing at all.
@Suite struct NeoModelWireTests {
    private func request(_ model: HubASRModel?) -> DictationRequest {
        DictationRequest(mode: .natural, autoStructured: true, appName: "备忘录", durationSeconds: 2,
                         clientRecordingID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
                         client: .mac, clientVersion: "1.3.0", asrModel: model)
    }

    private func keys(_ request: DictationRequest) throws -> [String: Any] {
        let data = try #require(Base64URL.decode(try request.headerValue()))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func theSettingAndTheFieldUseTheSameNames() throws {
        #expect(HubASRModel.allCases.map(\.rawValue) == NeoModelChoice.neoModels.map(\.rawValue))
        // 本机识别 is the setting's alone: no request names it, and a hub reads it as auto should one ever arrive.
        #expect(HubASRModel(rawValue: NeoModelChoice.local.rawValue) == nil)
        #expect(try HubJSON.decode([HubASRModel].self, from: Data(#"["local"]"#.utf8)) == [.auto])
    }

    @Test func aRequestThatLeavesTheChoiceToTheNeoHasNoField() throws {
        // What 自动 sends: nothing, which is all a hub from before the field knows.
        #expect(try keys(request(nil))["asrModel"] == nil)
        #expect(try DictationRequest(headerValue: request(nil).headerValue()).asrModel == nil)
    }

    @Test func aChosenModelTravelsInTheHeader() throws {
        #expect(try keys(request(.large))["asrModel"] as? String == "large")
        #expect(try keys(request(.small))["asrModel"] as? String == "small")
        #expect(try DictationRequest(headerValue: request(.small).headerValue()) == request(.small))
    }

    @Test func aRequestFromBeforeTheFieldStillReads() throws {
        let old = #"{"mode":"raw","autoStructured":false,"locale":"zh-CN","durationSeconds":1,"clientRecordingID":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","client":"mac","clientVersion":"1.2.0"}"#
        #expect(try DictationRequest(headerValue: Base64URL.encode(Data(old.utf8))).asrModel == nil)
    }
}

/// What a device sends for each choice, and how long it waits. 大模型 says "一直用大模型，Neo 忙时要多等一会儿":
/// the request must not let the hub give up on a busy Neo and polish the device's own transcript instead.
@Suite struct NeoModelRequestTests {
    private let heard = "本机听到的话"

    private func base(seconds: Double = 20) -> DictationRequest {
        DictationRequest(mode: .natural, autoStructured: true, appName: "备忘录", localTranscript: heard, durationSeconds: seconds,
                         clientRecordingID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
                         client: .mac, clientVersion: "1.3.0")
    }

    private func keys(_ request: DictationRequest) throws -> [String: Any] {
        let data = try #require(Base64URL.decode(try request.headerValue()))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func askingForTheLargeModelLeavesTheDevicesTranscriptOut() throws {
        let request = base().asking(for: .large)
        #expect(request.asrModel == .large)
        #expect(request.localTranscript == nil)
        #expect(request.waitsForNeo)
        // On the wire: the model by name, and no transcript for the hub to fall back on while the Neo is busy.
        let sent = try keys(request)
        #expect(sent["asrModel"] as? String == "large")
        #expect(sent["localTranscript"] == nil)
        // Everything else is the recording's own.
        var same = request
        same.localTranscript = heard
        same.asrModel = nil
        #expect(same == base())
    }

    @Test func theOtherChoicesTakeTheTranscriptAlong() throws {
        let small = base().asking(for: .small)
        #expect(small.asrModel == .small && small.localTranscript == heard && !small.waitsForNeo)
        #expect(try keys(small)["asrModel"] as? String == "small")
        // 自动 says nothing at all, whichever way it is put: all a hub from before the field reads.
        for auto in [base().asking(for: nil), base().asking(for: .auto)] {
            #expect(auto == base())
            #expect(try keys(auto)["asrModel"] == nil)
            #expect(!auto.waitsForNeo)
        }
        // Asked again, the last asking counts; the transcript left out for the large model is not brought back.
        #expect(base().asking(for: .small).asking(for: nil) == base())
        #expect(base().asking(for: .large).asking(for: .small).localTranscript == nil)
    }

    @Test func theTranscriptStillFollowsWhenTheNeoHearsNothing() {
        // `raw` came back empty: the transcript left out goes to /v1/polish under the same recording id.
        let request = base().asking(for: .large)
        let empty = DictationResult(clientRecordingID: request.clientRecordingID, raw: "", text: "", mode: .natural,
                                    polished: false, recognizer: .qwen3ASR, timings: HubTimings(), createdAt: Date(timeIntervalSince1970: 0))
        #expect(HubDictation.next(empty, request: request, localTranscript: heard) == .polish(request.polishRequest(text: heard)))
        #expect(request.polishRequest(text: heard).clientRecordingID == request.clientRecordingID)
    }

    @Test func theTranscriptFollowsWhenTheNeoCannotListenAtAll() {
        let unavailable = HubError.server(status: 503, body: HubErrorBody(error: "Neo 的识别暂时不可用", code: HubErrorCode.asrUnavailable,
                                                                        retryable: true))
        #expect(HubDictation.transcriptFollows(unavailable, request: base().asking(for: .large)))
        // A request that took its transcript along was answered with it; nothing follows.
        #expect(!HubDictation.transcriptFollows(unavailable, request: base()))
        #expect(!HubDictation.transcriptFollows(unavailable, request: base().asking(for: .small)))
        // Any other failure is this device's to handle: the hub may still be working on the recording (a timeout),
        // was not reached, or refused it.
        let large = base().asking(for: .large)
        let others: [Error] = [HubError.timeout, HubError.unreachable, HubError.connectionLost, HubError.accessDenied,
                               HubError.server(status: 503, body: nil),
                               HubError.server(status: 422, body: HubErrorBody(error: "解不开", code: HubErrorCode.decodeFailed)),
                               HubError.server(status: 500, body: HubErrorBody(error: "出错了", code: HubErrorCode.internalError)),
                               CancellationError()]
        for other in others {
            #expect(!HubDictation.transcriptFollows(other, request: large))
        }
    }

    @Test func aRequestThatWaitsForTheNeoGetsALongerBudget() {
        let t = HubTimeouts.interactive
        // 20 s of speech, about 80 KB of AAC. Unchanged for the other choices: connect 3 + upload 2.5 + model load 8
        // + recognition 16 (0.8 s per second of audio, `HubTimeouts.asrPerAudioSecond`) + polish 10 + margin 5.
        let usual = t.dictation(durationSeconds: 20, audioBytes: 80_000)
        #expect(abs(usual - 44.5) < 0.001)
        #expect(t.dictation(durationSeconds: 20, audioBytes: 80_000, patient: false) == usual)
        // Waiting: recognition gets what the hub itself gives it without a transcript, 30 s + half the recording.
        let patient = t.dictation(durationSeconds: 20, audioBytes: 80_000, patient: true)
        #expect(abs(patient - 60.5) < 0.001)
        // Never past the longest a device where someone waits gives one call.
        #expect(t.dictation(durationSeconds: 300, audioBytes: 1_200_000, patient: true) == HubTimeouts.interactiveCap)
        #expect(abs(t.dictation(durationSeconds: .nan, audioBytes: -1, patient: true) - 48) < 0.001)
    }

    @Test func aRequestWhoseTranscriptCanStandInFitsEveryHubsWait() {
        // A request that carries this device's transcript keeps the usual budget, whichever hub answers it: an older
        // one waits up to 6 s + 0.8 s per second of audio (at most a minute) before it polishes the transcript,
        // a newer one `standInRecognition`, and `standInLoad` more while a model load may be under way. So the hub's
        // answer always comes within the budget, and the device may be updated before its hub.
        let t = HubTimeouts.interactive
        for seconds in [0.0, 1, 5, 20, 44, 60, 120] {
            let usual = HubTimeouts.modelLoad + HubTimeouts.asrPerAudioSecond * seconds
            let older = min(60, 6 + 0.8 * seconds)
            let newer = HubTimeouts.standInRecognition(audioSeconds: seconds) + HubTimeouts.standInLoad
            #expect(usual >= older && usual >= newer, "\(seconds)")
            let polish = PolishTimeout.seconds(forCharacters: Int(seconds * HubTimeouts.charactersPerAudioSecond),
                                               minimum: t.hubPolishFloor)
            #expect(t.dictation(durationSeconds: seconds, audioBytes: 0)
                    == min(t.cap, t.connect + usual + polish + t.margin), "\(seconds)")
        }
        // The hub's own wait stops growing at 20 s.
        #expect(abs(HubTimeouts.standInRecognition(audioSeconds: 44) - 20) < 0.5)
        #expect(HubTimeouts.standInRecognition(audioSeconds: 300) == HubTimeouts.standInCap)
    }

    @Test func theTranscriptGoesInTheHeaderOnlyWhenItFits() throws {
        #expect(try DictationRequest(headerValue: base().headerValue()).localTranscript == base().localTranscript)
        // Too long for the header: it is left out (`headerValue()`), so the hub has nothing to stand in and waits for
        // its worker as long as it takes.
        var request = base()
        request.localTranscript = String(repeating: "长", count: 3_000)
        #expect(try DictationRequest(headerValue: request.headerValue()).localTranscript == nil)
        // The large model's request leaves it out on purpose.
        #expect(base().asking(for: .large).localTranscript == nil)
        #expect(base().asking(for: .small).localTranscript == base().localTranscript)
    }
}

/// What `GET /v1/health` says about the Neo's speech models, which the 识别模型 row depends on.
@Suite struct NeoModelHealthTests {
    private func asr(_ json: String) throws -> HubHealth.ASR {
        let body = #"{"ok":true,"version":"1.3.0","asr":\#(json),"chatgpt":{"ready":true},"device":"Mac"}"#
        return try HubJSON.decode(HubHealth.self, from: Data(body.utf8)).asr
    }

    @Test func aHubWithBothModelsNamesThem() throws {
        let both = try asr(#"{"ready":true,"model":"Qwen3-ASR-0.6B-4bit","largeModel":"Qwen3-ASR-1.7B-4bit","smallModel":"Qwen3-ASR-0.6B-4bit","autoUses":"small"}"#)
        #expect(both == HubHealth.ASR(ready: true, model: "Qwen3-ASR-0.6B-4bit", largeModel: "Qwen3-ASR-1.7B-4bit",
                                      smallModel: "Qwen3-ASR-0.6B-4bit", autoUses: .small))
        #expect(NeoModelNames(current: both.model, large: both.largeModel, small: both.smallModel).support == .both)
    }

    @Test func anOlderHubNamesNeitherAndASingleModelOnlyOne() throws {
        let older = try asr(#"{"ready":true,"model":"Qwen3-ASR-1.7B-4bit"}"#)
        #expect(older.largeModel == nil && older.smallModel == nil && older.autoUses == nil)
        #expect(NeoModelNames(current: older.model, large: older.largeModel, small: older.smallModel).support == .outdated)
        let single = try asr(#"{"ready":true,"model":"Qwen3-ASR-1.7B-4bit","largeModel":"Qwen3-ASR-1.7B-4bit","autoUses":"large"}"#)
        #expect(NeoModelNames(current: single.model, large: single.largeModel, small: single.smallModel).support == .single)
    }

    @Test func aValueThisVersionDoesNotKnowDoesNotFailTheAnswer() throws {
        let odd = try asr(#"{"ready":true,"model":"m","largeModel":"l","smallModel":"s","autoUses":"medium"}"#)
        #expect(odd.autoUses == nil && odd.largeModel == "l" && odd.smallModel == "s")
        #expect(try asr(#"{"ready":true,"model":"m","autoUses":7}"#).autoUses == nil)
    }
}
