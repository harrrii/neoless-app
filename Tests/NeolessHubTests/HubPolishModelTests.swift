import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NeolessCloud
import NeolessCore
import Testing
@testable import NeolessHubKit

/// 整理模型 and 快速模式 chosen on the device: the hub polishes with the device's model when it is on the shared list
/// (`PolishModel.all`) and with its own (settings.json) otherwise, takes the device's 快速模式 when it says, and keeps
/// which model polished each entry. A request without the fields polishes exactly as before.
@MainActor
@Suite struct HubPolishModelTests {
    private func request(model: String? = nil, fastTier: Bool? = nil, mode: DictationMode = .natural) -> DictationRequest {
        var request = dictation(mode: mode)
        request.polishModel = model
        request.fastTier = fastTier
        return request
    }

    /// settings.json with `model` and `fastTier`, once the running hub has read it.
    private func configure(_ hub: HubFixture, model: String, fastTier: Bool) async {
        #expect(hub.folder.store.write(HubConfig(model: model, fastTier: fastTier), to: HubDataFolder.File.settings))
        #expect(await eventually { hub.service.config.model == model && hub.service.config.fastTier == fastTier })
    }

    /// What the last call to ChatGPT was sent with.
    private func lastOptions(_ hub: HubFixture) -> PolishOptions? { hub.polisher.calls.last?.options }

    // MARK: The rule

    @Test func theDevicesChoiceGoesOnTheHubsSettings() {
        let config = HubConfig(model: "gpt-5.6-luna", fastTier: false, polishTimeout: 30)
        #expect(config.polishOptions(model: nil, fastTier: nil) == config.polishOptions)
        #expect(config.polishOptions(model: "gpt-6-luna", fastTier: true)
                == PolishOptions(model: "gpt-6-luna", fastTier: true, minimumTimeout: 30))
        // A name not on the list never reaches ChatGPT; the 快速模式 that came with it still counts.
        for odd in ["gpt-9-nova", "", "GPT-6-Luna"] {
            #expect(config.polishOptions(model: odd, fastTier: true)
                    == PolishOptions(model: "gpt-5.6-luna", fastTier: true, minimumTimeout: 30))
        }
        // The time limit is always the hub's.
        #expect(HubConfig().polishOptions(model: "gpt-6-luna", fastTier: false).minimumTimeout == 10)
        // The hub's own default is unchanged, and a model.
        #expect(HubConfig().polishOptions == PolishOptions(model: "gpt-6.1-sol", fastTier: true, minimumTimeout: 10))
    }

    // MARK: GET /v1/health

    @Test func healthListsTheModelsADeviceCanChoose() async throws {
        let hub = try HubFixture()
        await configure(hub, model: "gpt-5.6-luna", fastTier: false)
        let health = try decode(HubHealth.self, try await hub.send(.get, HubPath.health))
        // The shared list, whatever settings.json says: so a device can tell this hub reads its 整理模型.
        #expect(health.polishModels == PolishModel.all.map(\.id))
        #expect(NeoPolishSupport(health: health) == .listed(["gpt-6-luna", "gpt-6.1-sol", "gpt-5.6-luna"]))
        // Each one listed is one a request is polished with.
        let config = HubConfig(model: "gpt-4.1", fastTier: true)
        for model in try #require(health.polishModels) {
            #expect(config.polishOptions(model: model, fastTier: nil).model == model)
        }
    }

    // MARK: POST /v1/dictations

    @Test func aDictationIsPolishedWithTheModelTheDeviceChose() async throws {
        let hub = try HubFixture()
        let result = try decode(DictationResult.self, try await hub.dictate(request(model: "gpt-6-luna", fastTier: false)))
        #expect(result.polished)
        #expect(lastOptions(hub) == PolishOptions(model: "gpt-6-luna", fastTier: false, minimumTimeout: 10))
        // The history keeps which model polished it, on disk too.
        #expect(hub.service.history.entry(id: result.id)?.polishModel == "gpt-6-luna")
        #expect(HubHistory(store: hub.folder.store).entry(id: result.id)?.polishModel == "gpt-6-luna")
        // The device sees what it always did: the field is the hub's own record, not in the answer.
        let item = try #require(try decode(HistoryPage.self, try await hub.send(.get, HubPath.history)).items.first)
        #expect(item.result == result)
    }

    @Test func aModelTheHubDoesNotKnowIsPassedOver() async throws {
        let hub = try HubFixture()
        await configure(hub, model: "gpt-5.6-luna", fastTier: false)
        let result = try decode(DictationResult.self, try await hub.dictate(request(model: "gpt-9-nova")))
        #expect(result.polished)
        #expect(lastOptions(hub) == PolishOptions(model: "gpt-5.6-luna", fastTier: false, minimumTimeout: 10))
        #expect(hub.service.history.entry(id: result.id)?.polishModel == "gpt-5.6-luna")
    }

    @Test func aDeviceThatSaysNothingGetsTheHubsSettings() async throws {
        let hub = try HubFixture()
        // Nothing in settings.json: the hub's defaults, as before the fields.
        _ = try await hub.dictate(request())
        #expect(lastOptions(hub) == PolishOptions(model: PolishOptions.defaultModel, fastTier: true, minimumTimeout: 10))
        await configure(hub, model: "gpt-6-luna", fastTier: false)
        let result = try decode(DictationResult.self, try await hub.dictate(request()))
        #expect(lastOptions(hub) == PolishOptions(model: "gpt-6-luna", fastTier: false, minimumTimeout: 10))
        #expect(hub.service.history.entry(id: result.id)?.polishModel == "gpt-6-luna")
    }

    @Test func theDevicesFastTierWinsEitherWay() async throws {
        let hub = try HubFixture()
        _ = try await hub.dictate(request(fastTier: false))
        #expect(lastOptions(hub)?.fastTier == false && lastOptions(hub)?.model == PolishOptions.defaultModel)
        await configure(hub, model: "gpt-6.1-sol", fastTier: false)
        _ = try await hub.dictate(request(fastTier: true))
        #expect(lastOptions(hub)?.fastTier == true)
        // With a model the hub passes over, too.
        _ = try await hub.dictate(request(model: "gpt-9-nova", fastTier: true))
        #expect(lastOptions(hub) == PolishOptions(model: "gpt-6.1-sol", fastTier: true, minimumTimeout: 10))
        // Left out: the hub's.
        _ = try await hub.dictate(request(model: "gpt-6-luna"))
        #expect(lastOptions(hub) == PolishOptions(model: "gpt-6-luna", fastTier: false, minimumTimeout: 10))
    }

    @Test func nothingPolishedKeepsNoModel() async throws {
        let hub = try HubFixture()
        let raw = try decode(DictationResult.self, try await hub.dictate(request(model: "gpt-6-luna", mode: .raw)))
        #expect(!raw.polished && hub.polisher.calls.isEmpty)
        #expect(hub.service.history.entry(id: raw.id)?.polishModel == nil)
        hub.polisher.answer = { _, _ in throw PolishError.timeout }
        let failed = try decode(DictationResult.self, try await hub.dictate(request(model: "gpt-6-luna")))
        #expect(!failed.polished && failed.fallback != nil)
        #expect(lastOptions(hub)?.model == "gpt-6-luna")
        #expect(hub.service.history.entry(id: failed.id)?.polishModel == nil)
    }

    // MARK: POST /v1/polish

    @Test func aPolishIsPolishedWithTheModelTheDeviceChose() async throws {
        let hub = try HubFixture()
        await configure(hub, model: "gpt-6.1-sol", fastTier: true)
        // 本机识别, or the transcript that follows a recording the Neo heard nothing in: the recording's model.
        let follow = request(model: "gpt-6-luna", fastTier: false).polishRequest(text: "嗯明天开会")
        let result = try decode(DictationResult.self, try await hub.post(HubPath.polish, follow))
        #expect(result.polished && result.recognizer == .local)
        #expect(lastOptions(hub) == PolishOptions(model: "gpt-6-luna", fastTier: false, minimumTimeout: 10))
        #expect(hub.service.history.entry(id: result.id)?.polishModel == "gpt-6-luna")

        _ = try await hub.post(HubPath.polish, PolishRequest(text: "嗯后天开会", mode: .natural, autoStructured: true,
                                                              polishModel: "gpt-9-nova"))
        #expect(lastOptions(hub) == PolishOptions(model: "gpt-6.1-sol", fastTier: true, minimumTimeout: 10))
        _ = try await hub.post(HubPath.polish, PolishRequest(text: "嗯周五开会", mode: .natural, autoStructured: true))
        #expect(lastOptions(hub) == PolishOptions(model: "gpt-6.1-sol", fastTier: true, minimumTimeout: 10))
    }

    // MARK: POST /v1/dictations/{id}/repolish

    @Test func aRepolishIsPolishedWithTheModelTheDeviceChoseThen() async throws {
        let hub = try HubFixture()
        let original = try decode(DictationResult.self, try await hub.dictate(request(model: "gpt-6.1-sol")))
        #expect(hub.service.history.entry(id: original.id)?.polishModel == "gpt-6.1-sol")

        let luna = try await hub.post(HubPath.repolish(original.id),
                                      RepolishRequest(mode: .structured, polishModel: "gpt-6-luna", fastTier: false))
        #expect(luna.status == .ok)
        #expect(lastOptions(hub) == PolishOptions(model: "gpt-6-luna", fastTier: false, minimumTimeout: 10))
        #expect(hub.service.history.entry(id: original.id)?.polishModel == "gpt-6-luna")

        // Unknown or left out: the hub's own, as before the fields.
        _ = try await hub.post(HubPath.repolish(original.id), RepolishRequest(mode: .natural, polishModel: "gpt-9-nova"))
        #expect(lastOptions(hub) == PolishOptions(model: PolishOptions.defaultModel, fastTier: true, minimumTimeout: 10))
        _ = try await hub.send(.post, HubPath.repolish(original.id))
        #expect(lastOptions(hub) == PolishOptions(model: PolishOptions.defaultModel, fastTier: true, minimumTimeout: 10))
        #expect(hub.service.history.entry(id: original.id)?.polishModel == PolishOptions.defaultModel)

        // Back to the original: nothing polished it.
        _ = try await hub.post(HubPath.repolish(original.id), RepolishRequest(mode: .raw, polishModel: "gpt-6-luna"))
        #expect(hub.service.history.entry(id: original.id)?.polishModel == nil)
    }

    @Test func aRepolishAskedAgainWithTheSameModelWaitsForTheFirst() async throws {
        let hub = try HubFixture()
        let original = try decode(DictationResult.self, try await hub.dictate(request()))
        let gate = Gate()
        hub.polisher.gate = gate
        let ask = RepolishRequest(mode: .structured, polishModel: "gpt-6-luna", fastTier: true)
        async let first = hub.post(HubPath.repolish(original.id), ask)
        #expect(await eventually { gate.arrived == 1 })
        async let second = hub.post(HubPath.repolish(original.id), ask)
        #expect(await eventually { await MainActor.run { hub.service.joined == 1 } })
        gate.open()
        let (a, b) = try await (decode(DictationResult.self, first), decode(DictationResult.self, second))
        #expect(a == b)
        #expect(hub.polisher.calls.count == 2)   // the dictation, then one repolish
    }

    // MARK: history.json

    @Test func historyFromBeforeTheFieldStillReads() throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let folder = try HubDataFolder.at(dir)
        let old = #"[{"id":"11111111-2222-3333-4444-555555555555","clientRecordingID":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","raw":"嗯好","text":"好。","mode":"natural","polished":true,"recognizer":"qwen3-asr","timings":{"decodeMs":1,"asrMs":2,"polishMs":3,"totalMs":6},"createdAt":"2026-10-09T08:30:00.123Z","edited":false}]"#
        try Data(old.utf8).write(to: folder.file(HubDataFolder.File.history))
        let history = HubHistory(store: folder.store)
        let entry = try #require(history.entries.first)
        #expect(entry.polishModel == nil && entry.result.text == "好。")
        // Written back without the key while there is nothing to say, with it once there is.
        let plain = try #require(try JSONSerialization.jsonObject(with: HubJSON.encode(entry)) as? [String: Any])
        #expect(plain["polishModel"] == nil)
        var polished = entry
        polished.polishModel = "gpt-6-luna"
        let data = try HubJSON.encode(polished)
        #expect(try HubJSON.decode(HubHistoryEntry.self, from: data) == polished)
        // A value that does not read (a newer hub's) is passed over, not the whole entry.
        let odd = String(decoding: data, as: UTF8.self).replacingOccurrences(of: #""gpt-6-luna""#, with: #"{"id":"x"}"#)
        #expect(try HubJSON.decode(HubHistoryEntry.self, from: Data(odd.utf8)).polishModel == nil)
    }

    // MARK: eval

    @Test func evalSaysWhichModelEachSampleWentTo() async throws {
        let hub = try HubFixture()
        let stub = HubSampleTests.StubEval()
        let samples = [HubEval.Sample(id: "a", app: nil, modeHint: "light", raw: "嗯好的"),
                       HubEval.Sample(id: "b", app: nil, modeHint: "raw", raw: "搜索")]
        let options = PolishOptions(model: "gpt-6-luna", fastTier: false, minimumTimeout: 10)
        let (results, stop) = await HubEval.run(samples, words: hub.service.words, polisher: stub, options: options,
                                                pause: .zero)
        #expect(stop == nil)
        #expect(stub.calls.map(\.options) == [options])
        #expect(results.map(\.model) == ["gpt-6-luna", nil])
    }
}
