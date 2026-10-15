import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NeolessCloud
import NeolessCore
import Testing
@testable import NeolessHubKit

/// The speech model a device asks for (`DictationRequest.asrModel`) on its way to the worker (`X-Model`), and
/// what the worker has on its way back to the device (`GET /v1/health`).
@Suite struct HubASRModelTests {
    // MARK: Device → hub → worker

    @Test @MainActor func theDevicesChoiceReachesTheWorker() async throws {
        let hub = try HubFixture()
        for (asked, sent) in [(HubASRModel.large, HubASRModel.large), (.small, .small), (.auto, .auto), (nil, .auto)] {
            var request = dictation()
            request.asrModel = asked
            let response = try await hub.dictate(request)
            #expect(response.status == .ok)
            #expect(hub.asr.calls.last?.model == sent)
        }
        #expect(hub.asr.calls.count == 4)
    }

    /// With the device's own transcript along the hub does not wait long for the worker; the choice goes with it
    /// all the same.
    @Test @MainActor func theChoiceGoesAlongWhenTheDeviceHeardItToo() async throws {
        let hub = try HubFixture()
        var request = dictation(local: "明天下午三点开会")
        request.asrModel = .small
        let result = try decode(DictationResult.self, try await hub.dictate(request))
        #expect(result.recognizer == .qwen3ASR)
        #expect(hub.asr.calls.map(\.model) == [.small])
    }

    /// A device that knows nothing of models (its header has no `asrModel`) is an `auto` dictation.
    @Test @MainActor func anOlderDevicesHeaderIsAuto() async throws {
        let hub = try HubFixture()
        let id = UUID()
        let old = #"{"mode":"natural","autoStructured":true,"locale":"zh-CN","durationSeconds":1,"# +
            #""clientRecordingID":"\#(id.uuidString)","client":"mac","clientVersion":"1.2.0"}"#
        let headers = hub.headers([.contentType: HubAudioType.m4a.rawValue,
                                   HubServer.requestHeader: Base64URL.encode(Data(old.utf8))])
        let response = try await hub.send(.post, HubPath.dictations, headers: headers, body: ByteBuffer(bytes: AudioFixture.m4a))
        #expect(response.status == .ok)
        #expect(hub.asr.calls.map(\.model) == [.auto])
    }

    /// A choice this hub has never heard of (a newer device's) is an `auto` dictation too, not a refused one.
    @Test @MainActor func aChoiceThisHubDoesNotKnowIsAuto() async throws {
        let hub = try HubFixture()
        for odd in [#""medium""#, #""LARGE""#, "7", "null"] {
            let newer = #"{"mode":"natural","autoStructured":true,"locale":"zh-CN","durationSeconds":1,"# +
                #""clientRecordingID":"\#(UUID().uuidString)","client":"mac","clientVersion":"9.0","asrModel":\#(odd)}"#
            let headers = hub.headers([.contentType: HubAudioType.m4a.rawValue,
                                       HubServer.requestHeader: Base64URL.encode(Data(newer.utf8))])
            let response = try await hub.send(.post, HubPath.dictations, headers: headers, body: ByteBuffer(bytes: AudioFixture.m4a))
            #expect(response.status == .ok, "\(odd)")
            #expect(hub.asr.calls.last?.model == .auto, "\(odd)")
        }
        #expect(hub.asr.calls.count == 4)
        // Read by itself such a value is `auto`; what this version knows is read as it is and written as before.
        let read = try HubJSON.decode([HubASRModel].self, from: Data(#"["medium","small","large","auto",""]"#.utf8))
        #expect(read == [.auto, .small, .large, .auto, .auto])
        #expect(String(decoding: try HubJSON.encode([HubASRModel.large, .small, .auto]), as: UTF8.self) == #"["large","small","auto"]"#)
        var request = dictation()
        request.asrModel = .small
        #expect(try DictationRequest(headerValue: request.headerValue()) == request)
        // The rest of the header is still checked: without what a dictation needs it is refused as before.
        #expect(throws: HubProtocolError.badRequestHeader) {
            _ = try DictationRequest(headerValue: Base64URL.encode(Data(#"{"asrModel":"medium"}"#.utf8)))
        }
    }

    // MARK: Hub → worker, on a real socket

    @Test func workerClientSendsTheModelHeader() async throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let source = WorkerSecretSource(folder: dir)
        let secret = try source.value()
        let record = WorkerRecord()
        try await stubWorker(secret: { secret }, record: record).test(.live) { client in
            let worker = ASRWorkerClient(baseURL: URL(string: "http://localhost:\(client.port!)")!, secret: source)
            let wav = AudioUpload.wav([Int16](repeating: 100, count: 16_000))
            for model in HubASRModel.allCases {
                #expect(try await worker.recognize(wav: wav, hints: [], audioSeconds: 1, model: model).raw == "明天下午三点开会")
            }
            // Without a choice (`neoless-hub transcribe`, older callers): auto, said in so many words.
            _ = try await worker.recognize(wav: wav, hints: ["OpenAI"], audioSeconds: 1)
            #expect(record.models == ["auto", "large", "small", "auto"])
            #expect(record.requests.last?.hints == ["OpenAI"])
        }
        #expect(HubHeader.model == "X-Model")
        #expect(HubASRModel.allCases.map(\.rawValue) == ["auto", "large", "small"])
    }

    /// A worker that made a new secret is asked again; the second try carries the same choice.
    @Test func theRetryAfterANewSecretKeepsTheModel() async throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let source = WorkerSecretSource(folder: dir)
        let secret = Box(try source.value())
        let record = WorkerRecord()
        try await stubWorker(secret: { secret.value }, record: record).test(.live) { client in
            let worker = ASRWorkerClient(baseURL: URL(string: "http://localhost:\(client.port!)")!, secret: source)
            let fresh = "a-brand-new-worker-secret-0123456789"
            try fresh.write(to: WorkerSecret.url(in: dir), atomically: true, encoding: .utf8)
            secret.value = fresh
            _ = try await worker.recognize(wav: AudioUpload.wav([1, 2, 3]), hints: [], audioSeconds: 1, model: .large)
            #expect(record.models == ["large", "large"])
        }
    }

    // MARK: Worker → hub → device

    @Test @MainActor func healthTellsTheDeviceWhatTheNeoHas() async throws {
        let hub = try HubFixture()
        hub.asr.healthAnswer = ASRWorkerHealth(ok: true, model: "Qwen3-ASR-1.7B-4bit", loaded: true, pending: 0,
                                               largeModel: "Qwen3-ASR-1.7B-4bit", smallModel: "Qwen3-ASR-0.6B-4bit",
                                               autoUses: "large")
        var health = try decode(HubHealth.self, try await hub.send(.get, HubPath.health))
        #expect(health.asr == HubHealth.ASR(ready: true, model: "Qwen3-ASR-1.7B-4bit", largeModel: "Qwen3-ASR-1.7B-4bit",
                                            smallModel: "Qwen3-ASR-0.6B-4bit", autoUses: .large))
        // The Neo is busy: auto uses the small one for a while, and `model` follows.
        hub.asr.healthAnswer = ASRWorkerHealth(ok: true, model: "Qwen3-ASR-0.6B-4bit", loaded: true,
                                               largeModel: "Qwen3-ASR-1.7B-4bit", smallModel: "Qwen3-ASR-0.6B-4bit",
                                               autoUses: "small")
        health = try decode(HubHealth.self, try await hub.send(.get, HubPath.health))
        #expect(health.asr.model == "Qwen3-ASR-0.6B-4bit" && health.asr.autoUses == .small)
        // One model only: no small one, and it answers every choice.
        hub.asr.healthAnswer = ASRWorkerHealth(ok: true, model: "Qwen3-ASR-0.6B-4bit", loaded: false,
                                               largeModel: "Qwen3-ASR-0.6B-4bit", autoUses: "large")
        health = try decode(HubHealth.self, try await hub.send(.get, HubPath.health))
        #expect(health.asr == HubHealth.ASR(ready: true, model: "Qwen3-ASR-0.6B-4bit", largeModel: "Qwen3-ASR-0.6B-4bit",
                                            autoUses: .large))
        // A worker before 1.3 says none of it, and neither does the hub; no worker at all is as before.
        hub.asr.healthAnswer = ASRWorkerHealth(ok: true, model: "Qwen3-ASR-0.6B-4bit", loaded: true, pending: 0)
        let body = try await hub.send(.get, HubPath.health)
        let text = String(decoding: Data(body.body.readableBytesView), as: UTF8.self)
        #expect(!text.contains("largeModel") && !text.contains("smallModel") && !text.contains("autoUses"))
        #expect(try decode(HubHealth.self, body).asr == HubHealth.ASR(ready: true, model: "Qwen3-ASR-0.6B-4bit"))
        hub.asr.healthAnswer = nil
        health = try decode(HubHealth.self, try await hub.send(.get, HubPath.health))
        #expect(health.asr == HubHealth.ASR(ready: false, model: ASRWorker.defaultModel))
    }

    // MARK: The shapes on the wire

    @Test func workerHealthWithAndWithoutTheModels() throws {
        let new = #"{"ok":true,"model":"Qwen3-ASR-0.6B-4bit","loaded":true,"pending":1,"largeModel":"Qwen3-ASR-1.7B-4bit","# +
            #""smallModel":"Qwen3-ASR-0.6B-4bit","autoUses":"small"}"#
        let health = try HubJSON.decode(ASRWorkerHealth.self, from: Data(new.utf8))
        #expect(health == ASRWorkerHealth(ok: true, model: "Qwen3-ASR-0.6B-4bit", loaded: true, pending: 1,
                                          largeModel: "Qwen3-ASR-1.7B-4bit", smallModel: "Qwen3-ASR-0.6B-4bit", autoUses: "small"))
        #expect(health.forDevices.autoUses == .small)
        let old = #"{"ok":false,"model":"Qwen3-ASR-0.6B-4bit","loaded":false,"pending":0,"problem":"识别模型加载失败。"}"#
        let before = try HubJSON.decode(ASRWorkerHealth.self, from: Data(old.utf8))
        #expect(before.largeModel == nil && before.smallModel == nil && before.autoUses == nil)
        #expect(before.forDevices == HubHealth.ASR(ready: false, model: "Qwen3-ASR-0.6B-4bit"))
        // A word this hub does not know for `autoUses` is passed over, not an error.
        let odd = ASRWorkerHealth(ok: true, model: "m", loaded: true, largeModel: "L", smallModel: "S", autoUses: "medium")
        #expect(odd.forDevices == HubHealth.ASR(ready: true, model: "m", largeModel: "L", smallModel: "S"))
    }

    @Test func hubHealthReadsAnythingOlderOrNewer() throws {
        // An older hub: the device sees the one model, as before.
        let old = #"{"ok":true,"version":"1.2.1","asr":{"ready":true,"model":"Qwen3-ASR-0.6B-4bit"},"# +
            #""chatgpt":{"ready":true},"device":"Mac"}"#
        #expect(try HubJSON.decode(HubHealth.self, from: Data(old.utf8)).asr == HubHealth.ASR(ready: true, model: "Qwen3-ASR-0.6B-4bit"))
        // A newer hub with a choice this device has never heard of: the rest is still read.
        let newer = #"{"ok":true,"version":"9","asr":{"ready":true,"model":"X","largeModel":"L","smallModel":"S","# +
            #""autoUses":"medium","mediumModel":"M"},"chatgpt":{"ready":true},"device":"Mac"}"#
        #expect(try HubJSON.decode(HubHealth.self, from: Data(newer.utf8)).asr
                == HubHealth.ASR(ready: true, model: "X", largeModel: "L", smallModel: "S"))
        // What this hub writes is read back the same.
        let asr = HubHealth.ASR(ready: true, model: "L", largeModel: "L", smallModel: "S", autoUses: .large)
        let health = HubHealth(version: "1.2.1", asr: asr, chatgpt: .init(ready: true), device: "Mac", polishTimeout: 10)
        #expect(try HubJSON.decode(HubHealth.self, from: try HubJSON.encode(health)) == health)
    }

    @Test func workerResultReadsSegments() throws {
        let new = #"{"raw":"好的。Sounds good.","status":"ok","asrMs":900,"model":"Qwen3-ASR-1.7B-4bit","loadMs":0,"# +
            #""queueMs":0,"audioSeconds":4.2,"segments":2}"#
        let result = try HubJSON.decode(ASRWorkerResult.self, from: Data(new.utf8))
        #expect(result.segments == 2 && result.model == "Qwen3-ASR-1.7B-4bit")
        let old = #"{"raw":"好的","status":"ok","asrMs":300,"model":"Qwen3-ASR-0.6B-4bit","loadMs":0,"queueMs":0,"audioSeconds":1}"#
        #expect(try HubJSON.decode(ASRWorkerResult.self, from: Data(old.utf8)).segments == nil)
    }

    // MARK: neoless-hub status

    @Test func statusNamesBothModels() {
        let one = ASRWorkerHealth(ok: true, model: "Qwen3-ASR-0.6B-4bit", loaded: true, pending: 0)
        #expect(HubCommands.workerLine(one) == "语音识别：在线（Qwen3-ASR-0.6B-4bit，模型已加载）")
        var two = ASRWorkerHealth(ok: true, model: "Qwen3-ASR-1.7B-4bit", loaded: false, pending: 0,
                                  largeModel: "Qwen3-ASR-1.7B-4bit", smallModel: "Qwen3-ASR-0.6B-4bit", autoUses: "large")
        #expect(HubCommands.workerLine(two)
                == "语音识别：在线（大模型 Qwen3-ASR-1.7B-4bit，小模型 Qwen3-ASR-0.6B-4bit，自动现在用大模型；模型未加载，下次请求时加载）")
        two.autoUses = "small"
        two.loaded = true
        #expect(HubCommands.workerLine(two).contains("自动现在用小模型（Neo 忙，大模型先歇着）；模型已加载"))
        // One model that says so the new way reads like the old line.
        let single = ASRWorkerHealth(ok: false, model: "Qwen3-ASR-0.6B-4bit", loaded: false, problem: "识别模型加载失败。",
                                     largeModel: "Qwen3-ASR-0.6B-4bit", autoUses: "large")
        #expect(HubCommands.workerLine(single) == "语音识别：在线（Qwen3-ASR-0.6B-4bit，识别模型加载失败。）")
    }
}
