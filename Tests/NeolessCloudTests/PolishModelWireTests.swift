import Foundation
import Testing
@testable import NeolessCloud
import NeolessCore

/// 整理模型 on the wire: one list of models for the app's picker and the hub's check, and the device's model and
/// 快速模式 in every request that polishes on the Neo, which a hub from before the fields reads as it always did.
@Suite struct PolishModelWireTests {
    private let recording = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

    private func dictation(model: String? = nil, fastTier: Bool? = nil, local: String? = "明天开会") -> DictationRequest {
        DictationRequest(mode: .natural, autoStructured: true, appName: "备忘录", bundleID: "com.apple.Notes",
                         localTranscript: local, durationSeconds: 2, clientRecordingID: recording, client: .mac,
                         clientVersion: "1.4.0", asrModel: .small, polishModel: model, fastTier: fastTier)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func headerObject(_ request: DictationRequest) throws -> [String: Any] {
        try object(try #require(Base64URL.decode(try request.headerValue())))
    }

    // MARK: The list

    @Test func theListKeepsTheThreeModelsWithTheRecommendedOneFirst() {
        #expect(PolishModel.all.map(\.id) == ["gpt-6-luna", "gpt-6.1-sol", "gpt-5.6-luna"])
        #expect(PolishModel.all.map(\.title) == ["GPT-6-Luna（更快，推荐）", "GPT-6.1-Sol（更细致，慢一些）", "GPT-5.6-Luna"])
        #expect(Set(PolishModel.all.map(\.id)).count == PolishModel.all.count)
        #expect(PolishModel.all.first?.id == PolishModel.recommended)
        // The app's default and the hub's are both on the list: what an app that sends nothing gets is a model too.
        #expect(PolishModel.isKnown(PolishModel.recommended))
        #expect(PolishModel.isKnown(PolishOptions.defaultModel))
        #expect(PolishOptions().model == PolishOptions.defaultModel)
    }

    @Test func onlyAModelOnTheListIsKnown() {
        for model in PolishModel.all { #expect(PolishModel.isKnown(model.id)) }
        for odd in [nil, "", "gpt-7", "GPT-6-Luna", " gpt-6-luna", "gpt-6-luna\n"] as [String?] {
            #expect(!PolishModel.isKnown(odd))
        }
    }

    // MARK: What a device sends

    @Test func theDictationHeaderCarriesTheModelAndFastTier() throws {
        let request = dictation(model: "gpt-6-luna", fastTier: false)
        let sent = try headerObject(request)
        #expect(sent["polishModel"] as? String == "gpt-6-luna")
        #expect(sent["fastTier"] as? Bool == false)
        #expect(try DictationRequest(headerValue: request.headerValue()) == request)
        // A transcript too long for the header is left out; the model is not.
        let long = dictation(model: "gpt-6-luna", fastTier: true, local: String(repeating: "很长的话", count: 2_000))
        let shorter = try headerObject(long)
        #expect(shorter["localTranscript"] == nil && shorter["polishModel"] as? String == "gpt-6-luna")
    }

    @Test func aRequestThatSaysNothingHasNoFields() throws {
        let sent = try headerObject(dictation())
        #expect(sent["polishModel"] == nil && sent["fastTier"] == nil)
        let polish = try object(HubJSON.encode(PolishRequest(text: "好", mode: .natural, autoStructured: true)))
        #expect(polish["polishModel"] == nil && polish["fastTier"] == nil)
        #expect(try object(HubJSON.encode(RepolishRequest(mode: .natural))).keys.sorted() == ["mode"])
        #expect(try HubJSON.encode(RepolishRequest()) == Data("{}".utf8))
    }

    @Test func thePolishThatFollowsADictationKeepsItsModel() throws {
        let request = dictation(model: "gpt-5.6-luna", fastTier: false).asking(for: .large)
        let follow = request.polishRequest(text: "本机听到的话")
        #expect(follow.polishModel == "gpt-5.6-luna" && follow.fastTier == false)
        #expect(follow.clientRecordingID == recording)
        let sent = try object(HubJSON.encode(follow))
        #expect(sent["polishModel"] as? String == "gpt-5.6-luna" && sent["fastTier"] as? Bool == false)
        // And in the path where the Neo heard nothing.
        let result = DictationResult(clientRecordingID: recording, raw: "", text: "", mode: .natural, polished: false,
                                     recognizer: .qwen3ASR)
        guard case .polish(let next) = HubDictation.next(result, request: request, localTranscript: "本机听到的话") else {
            Issue.record("no polish")
            return
        }
        #expect(next.polishModel == "gpt-5.6-luna" && next.fastTier == false)
    }

    @Test func thePolishAndRepolishBodiesCarryTheFields() throws {
        let polish = PolishRequest(text: "好", mode: .natural, autoStructured: true, clientRecordingID: recording,
                                   polishModel: "gpt-6.1-sol", fastTier: true)
        let sent = try object(HubJSON.encode(polish))
        #expect(sent["polishModel"] as? String == "gpt-6.1-sol" && sent["fastTier"] as? Bool == true)
        #expect(try HubJSON.decode(PolishRequest.self, from: HubJSON.encode(polish)) == polish)
        let repolish = RepolishRequest(mode: .structured, polishModel: "gpt-6-luna", fastTier: false)
        #expect(try HubJSON.encode(repolish) == Data(#"{"fastTier":false,"mode":"structured","polishModel":"gpt-6-luna"}"#.utf8))
        #expect(try HubJSON.decode(RepolishRequest.self, from: HubJSON.encode(repolish)) == repolish)
    }

    // MARK: Hubs from before the fields, devices from before the fields

    /// The three requests as a hub from before the fields declares them (main at 1c9638b): it decodes with the
    /// same `HubJSON.decoder`, whose synthesized `Decodable` passes over keys it has no property for.
    private struct OldDictationRequest: Decodable, Equatable {
        var mode: DictationMode
        var autoStructured: Bool
        var appName: String?
        var bundleID: String?
        var locale: String
        var localTranscript: String?
        var durationSeconds: Double
        var clientRecordingID: UUID
        var client: HubClientKind
        var clientVersion: String
        var asrModel: HubASRModel?
    }

    private struct OldPolishRequest: Decodable, Equatable {
        var text: String
        var mode: DictationMode
        var autoStructured: Bool
        var appName: String?
        var bundleID: String?
        var clientRecordingID: UUID
        var client: HubClientKind?
        var clientVersion: String?
        var durationSeconds: Double?
    }

    private struct OldRepolishRequest: Decodable, Equatable {
        var mode: DictationMode?
    }

    @Test func aHubFromBeforeTheFieldsReadsTheNewRequests() throws {
        // The header as the old hub reads it: base64url, then JSON (`DictationRequest(headerValue:)`).
        let request = dictation(model: "gpt-6-luna", fastTier: false)
        let header = try #require(Base64URL.decode(try request.headerValue()))
        let old = try HubJSON.decode(OldDictationRequest.self, from: header)
        #expect(old == OldDictationRequest(mode: .natural, autoStructured: true, appName: "备忘录", bundleID: "com.apple.Notes",
                                           locale: "zh-CN", localTranscript: "明天开会", durationSeconds: 2,
                                           clientRecordingID: recording, client: .mac, clientVersion: "1.4.0",
                                           asrModel: .small))

        let polish = PolishRequest(text: "好", mode: .structured, autoStructured: false, appName: "微信",
                                   clientRecordingID: recording, client: .mac, clientVersion: "1.4.0", durationSeconds: 1,
                                   polishModel: "gpt-6-luna", fastTier: true)
        let oldPolish = try HubJSON.decode(OldPolishRequest.self, from: HubJSON.encode(polish))
        #expect(oldPolish == OldPolishRequest(text: "好", mode: .structured, autoStructured: false, appName: "微信",
                                              bundleID: nil, clientRecordingID: recording, client: .mac,
                                              clientVersion: "1.4.0", durationSeconds: 1))

        let repolish = try HubJSON.encode(RepolishRequest(mode: .natural, polishModel: "gpt-6-luna", fastTier: false))
        #expect(try HubJSON.decode(OldRepolishRequest.self, from: repolish) == OldRepolishRequest(mode: .natural))
        // Only the model asked for: what an old hub reads as "the dictation's own mode".
        let modeless = try HubJSON.encode(RepolishRequest(polishModel: "gpt-6-luna"))
        #expect(try HubJSON.decode(OldRepolishRequest.self, from: modeless) == OldRepolishRequest(mode: nil))
    }

    @Test func requestsFromBeforeTheFieldsReadAsSayingNothing() throws {
        let header = #"{"mode":"natural","autoStructured":true,"locale":"zh-CN","durationSeconds":1,"clientRecordingID":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","client":"mac","clientVersion":"1.3.0"}"#
        let request = try DictationRequest(headerValue: Base64URL.encode(Data(header.utf8)))
        #expect(request.polishModel == nil && request.fastTier == nil)
        let polish = try HubJSON.decode(PolishRequest.self, from: Data(
            #"{"text":"好","mode":"natural","autoStructured":true,"clientRecordingID":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}"#.utf8))
        #expect(polish.polishModel == nil && polish.fastTier == nil)
        #expect(try HubJSON.decode(RepolishRequest.self, from: Data(#"{"mode":"raw"}"#.utf8)) == RepolishRequest(mode: .raw))
        // A model this version does not know still reads: whether to use it is the hub's call, not the decoder's.
        let newer = try HubJSON.decode(RepolishRequest.self, from: Data(#"{"polishModel":"gpt-9-nova","fastTier":true}"#.utf8))
        #expect(newer == RepolishRequest(polishModel: "gpt-9-nova", fastTier: true))
    }

    // MARK: Whether the Neo follows it (GET /v1/health)

    /// The health answer as an app from before the field declares it (main at 1c9638b).
    private struct OldHubHealth: Decodable, Equatable {
        var ok: Bool
        var version: String
        var asr: HubHealth.ASR
        var chatgpt: HubHealth.ChatGPT
        var device: String
        var polishTimeout: Double?
    }

    @Test func healthSaysWhichModelsTheHubPolishesWith() throws {
        let health = HubHealth(version: "1.3.0", asr: .init(ready: true, model: "Qwen3-ASR-1.7B-4bit"),
                               chatgpt: .init(ready: true), device: "MacBook Air", polishTimeout: 10,
                               polishModels: PolishModel.all.map(\.id))
        let data = try HubJSON.encode(health)
        #expect(try object(data)["polishModels"] as? [String] == ["gpt-6-luna", "gpt-6.1-sol", "gpt-5.6-luna"])
        #expect(try HubJSON.decode(HubHealth.self, from: data) == health)
        #expect(NeoPolishSupport(health: health) == .listed(PolishModel.all.map(\.id)))
        // An app from before the field reads the answer as it always did.
        #expect(try HubJSON.decode(OldHubHealth.self, from: data)
                == OldHubHealth(ok: true, version: "1.3.0", asr: health.asr, chatgpt: health.chatgpt, device: "MacBook Air",
                                polishTimeout: 10))
        // A hub from before it (the one deployed at 1c9638b) says nothing: it polishes with its own settings.json.
        let old = try HubJSON.decode(HubHealth.self, from: Data(
            #"{"ok":true,"version":"1.2.1","asr":{"ready":true,"model":"Qwen3-ASR-1.7B-4bit"},"chatgpt":{"ready":true},"device":"MacBook Air","polishTimeout":10}"#.utf8))
        #expect(old.polishModels == nil)
        #expect(NeoPolishSupport(health: old) == .outdated)
        #expect(try object(HubJSON.encode(old))["polishModels"] == nil)
    }

    @Test func theRowsSayWhetherTheNeoFollowsThem() {
        let follows = "用 Neo 处理时也按这里"
        let fast = "优先处理，消耗更多额度；用 Neo 时也生效"
        let listed = NeoPolishSupport.listed(PolishModel.all.map(\.id))
        for model in PolishModel.all.map(\.id) {
            #expect(listed.follows(model) == true && listed.modelDetail(model) == follows)
            // A hub from before 整理模型: the line says the choice waits for the update.
            #expect(NeoPolishSupport.outdated.follows(model) == false)
            #expect(NeoPolishSupport.outdated.modelDetail(model) == "Neo 更新后才按这里，现在 Neo 用它自己设的模型")
            // Not heard from yet (or not in use): what a hub that reads the choice does with it.
            #expect(NeoPolishSupport.unknown.follows(model) == nil && NeoPolishSupport.unknown.modelDetail(model) == follows)
        }
        // A hub whose list lacks the one chosen (an older list, a newer app) polishes with its own.
        let older = NeoPolishSupport.listed(["gpt-6.1-sol"])
        #expect(older.follows("gpt-6-luna") == false)
        #expect(older.modelDetail("gpt-6-luna") == "这台 Neo 没有这个模型，用它自己设的模型整理")
        #expect(older.follows("gpt-6.1-sol") == true && older.modelDetail("gpt-6.1-sol") == follows)
        // 快速模式 counts on any hub that lists models, whatever model it is asked for.
        #expect(NeoPolishSupport.outdated.fastTierDetail == "优先处理，消耗更多额度；Neo 更新后才对 Neo 生效")
        for support in [listed, older, .unknown] { #expect(support.fastTierDetail == fast) }
    }
}
