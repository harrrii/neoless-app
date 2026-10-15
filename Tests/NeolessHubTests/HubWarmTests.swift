import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NeolessCloud
import NeolessCore
import Testing
@testable import NeolessHubKit

/// `POST /v1/warm`: a press became a dictation, and the hub has its worker get the speech model ready while the user is
/// still speaking. Answered at once, never what a dictation waits on, and never what uses up a device's allowance.
@MainActor
@Suite struct HubWarmTests {
    @Test func itNeedsAPairedDevicesToken() async throws {
        let hub = try HubFixture()
        let body = try json(WarmRequest())
        #expect(try await hub.send(.post, HubPath.warm, headers: HTTPFields(), body: body).status == .unauthorized)
        #expect(try await hub.send(.post, HubPath.warm, headers: [.authorization: "Bearer not-a-paired-device-token"],
                                   body: body).status == .unauthorized)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(hub.asr.warms.isEmpty)
        // Unlike the ping, which needs none.
        #expect(try await hub.send(.get, HubPath.ping, headers: HTTPFields()).status == .ok)
    }

    @Test func itIsAnsweredAtOnceAndTheWorkerIsAskedMeanwhile() async throws {
        let hub = try HubFixture()
        let gate = Gate()
        hub.asr.warmGate = gate            // a worker that does not answer until it is let go
        // Should the route wait for the worker, the worker is let go after a while: the test then fails, not hangs.
        let safety = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            gate.open()
        }
        defer { safety.cancel() }
        let response = try await hub.post(HubPath.warm, WarmRequest())
        // Answered while the worker had still not answered.
        #expect(hub.asr.warms.isEmpty)
        #expect(response.status == .ok)
        #expect(try decode(HubOK.self, response) == HubOK())
        #expect(await eventually { gate.arrived == 1 })
        gate.open()
        await hub.service.lastWarm?.value
        #expect(hub.asr.warms == [.auto])
        // A warm-up is no recognition: nothing is recognised, polished or kept.
        #expect(hub.asr.calls.isEmpty && hub.polisher.calls.isEmpty && hub.service.history.entries.isEmpty)
    }

    @Test func theModelTheDictationWillAskForIsTheOneWarmed() async throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let now = Box(clock)
        let hub = try HubFixture(now: { now.value })
        func warm(_ body: ByteBuffer?) async throws {
            #expect(try await hub.send(.post, HubPath.warm, body: body).status == .ok)
            await hub.service.lastWarm?.value
            clock += Hub.warmSpacing
            now.value = clock
        }
        try await warm(try json(WarmRequest(asrModel: .small)))
        try await warm(try json(WarmRequest(asrModel: .large)))
        try await warm(try json(WarmRequest()))
        // An empty body is the same as no choice, and so is a choice this hub does not know (a newer device's).
        try await warm(nil)
        try await warm(ByteBuffer(string: #"{"asrModel":"medium"}"#))
        #expect(hub.asr.warms == [.small, .large, .auto, .auto, .auto])
        #expect(String(decoding: try HubJSON.encode(WarmRequest(asrModel: .auto)), as: UTF8.self) == "{}")
        #expect(String(decoding: try HubJSON.encode(WarmRequest(asrModel: .small)), as: UTF8.self) == #"{"asrModel":"small"}"#)
        // A body that is not one is refused, like any other.
        #expect(try await hub.send(.post, HubPath.warm, body: ByteBuffer(string: "[")).status == .badRequest)
    }

    @Test func aBurstOfPressesIsOneWarmUpForTheWorker() async throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let now = Box(start)
        let hub = try HubFixture(now: { now.value })
        for _ in 0..<5 {
            #expect(try await hub.post(HubPath.warm, WarmRequest()).status == .ok)
        }
        await hub.service.lastWarm?.value
        #expect(hub.asr.warms == [.auto])
        // Another device has its own.
        let other = try hub.service.devices.pair(name: "Mac").token
        let headers: HTTPFields = [.authorization: "Bearer \(other)"]
        #expect(try await hub.send(.post, HubPath.warm, headers: headers, body: try json(WarmRequest(asrModel: .small))).status == .ok)
        await hub.service.lastWarm?.value
        #expect(hub.asr.warms == [.auto, .small])
        // Just short of the spacing: still answered, still not passed on.
        now.value = start.addingTimeInterval(Hub.warmSpacing - 0.5)
        #expect(try await hub.post(HubPath.warm, WarmRequest()).status == .ok)
        #expect(!hub.service.warm(device: try hub.service.identify("Bearer \(hub.token)"), request: WarmRequest()))
        now.value = start.addingTimeInterval(Hub.warmSpacing)
        #expect(try await hub.post(HubPath.warm, WarmRequest(asrModel: .large)).status == .ok)
        await hub.service.lastWarm?.value
        #expect(hub.asr.warms == [.auto, .small, .large])
        // A device that keeps to its own interval is never turned away for arriving a little early.
        #expect(Hub.warmSpacing < Hub.warmInterval)
    }

    @Test func warmUpsHaveTheirOwnAllowance() async throws {
        let hub = try HubFixture(rateLimit: 3)
        for _ in 0..<3 { #expect(try await hub.post(HubPath.warm, WarmRequest()).status == .ok) }
        let refused = try await hub.post(HubPath.warm, WarmRequest())
        #expect(refused.status == .tooManyRequests && errorBody(refused)?.code == HubErrorCode.rateLimited)
        // Counted, but on their own: the dictations and the syncing still have all of theirs.
        for _ in 0..<3 {
            let polish = PolishRequest(text: "明天开会", mode: .natural, autoStructured: true, clientRecordingID: UUID())
            #expect(try await hub.post(HubPath.polish, polish).status == .ok)
        }
        for _ in 0..<3 { #expect(try await hub.send(.get, HubPath.vocabulary).status == .ok) }
        #expect(HubService.RequestKind.of(route: HubPath.warm) == .warm)
        #expect(HubService.RequestKind.of(route: HubPath.ping) == .other)
    }

    @Test func eachWarmUpIsOneQuietLogLine() async throws {
        let hub = try HubFixture()
        let name = try hub.service.devices.pair(name: "热身测试").token
        _ = try await hub.send(.post, HubPath.warm, headers: [.authorization: "Bearer \(name)"], body: try json(WarmRequest()))
        #expect(TestLog.shared.all.contains { $0.contains("POST /v1/warm 200") && $0.hasSuffix(" 热身测试") })
    }

    // MARK: A load the warm-up asked for

    /// A hub whose short wait for a recording the device heard too is `wait`, with `allowance` more while a model
    /// load may be under way.
    private func hub(wait: TimeInterval = 0.3, allowance: TimeInterval = 10,
                     now: @escaping () -> Date = Date.init) throws -> HubFixture {
        let hub = try HubFixture(now: now)
        hub.service.impatientTimeout = { _ in wait }
        hub.service.loadAllowance = allowance
        return hub
    }

    /// The worker answers the next recognition `seconds` after it was asked. The stub cannot be cancelled the way a
    /// real request can, so it is let go whether or not the hub still waits for it.
    private func answer(_ hub: HubFixture, after seconds: Double) {
        let gate = Gate()
        hub.asr.gate = gate
        Task {
            _ = await eventually { gate.arrived == 1 }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            gate.open()
        }
    }

    private func dictateHeard(_ hub: HubFixture) async throws -> DictationResult {
        try decode(DictationResult.self, try await hub.dictate(dictation(local: "本机听到的话")))
    }

    @Test func aRecordingThatArrivesWhileTheModelLoadsIsWaitedFor() async throws {
        // A press of about a second: its warm-up went only on release and found the model unloaded, so the recording
        // waits in the worker's queue behind the load. Past the usual short wait but within the load's allowance, the
        // Neo's own recognition is the one used (English names and all), not the device's transcript.
        let hub = try hub()
        hub.asr.warmAnswer = false
        #expect(try await hub.post(HubPath.warm, WarmRequest()).status == .ok)
        await hub.service.lastWarm?.value
        answer(hub, after: 1)
        let result = try await dictateHeard(hub)
        #expect(result.recognizer == .qwen3ASR && result.raw == "嗯明天下午三点开会")
    }

    @Test func withNothingLoadingTheShortWaitStays() async throws {
        // The worker said the model was in memory already: nothing loads, and a slow answer is given up on as usual.
        let loaded = try hub()
        loaded.asr.warmAnswer = true
        #expect(try await loaded.post(HubPath.warm, WarmRequest()).status == .ok)
        await loaded.service.lastWarm?.value
        answer(loaded, after: 1)
        #expect(try await dictateHeard(loaded).recognizer == .local)
        // No warm-up at all: nothing is known to be loading.
        let none = try hub()
        answer(none, after: 1)
        #expect(try await dictateHeard(none).recognizer == .local)
    }

    @Test func aLoadMayBeUnderWayUntilTheWorkerSaysOtherwiseOrItsWindowEnds() async throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let now = Box(start)
        let hub = try hub(now: { now.value })
        #expect(!hub.service.mayBeLoading(at: start))
        // The worker has not answered the warm-up yet (the recording may get there first): a load may be under way.
        let gate = Gate()
        hub.asr.warmGate = gate
        hub.asr.warmAnswer = true
        #expect(try await hub.post(HubPath.warm, WarmRequest()).status == .ok)
        #expect(hub.service.mayBeLoading(at: start))
        // It answers that the model was in memory: nothing loads.
        gate.open()
        await hub.service.lastWarm?.value
        #expect(!hub.service.mayBeLoading(at: start))
        // A worker from before 1.4 says nothing (no `/warm`): it loads on the recognition itself, if at all, so a load
        // may be under way, until the window is over.
        hub.asr.warmAnswer = nil
        let asked = start.addingTimeInterval(Hub.warmSpacing)
        now.value = asked
        #expect(try await hub.post(HubPath.warm, WarmRequest()).status == .ok)
        await hub.service.lastWarm?.value
        #expect(hub.service.mayBeLoading(at: asked))
        #expect(hub.service.mayBeLoading(at: asked.addingTimeInterval(HubTimeouts.standInLoadWindow - 0.5)))
        #expect(!hub.service.mayBeLoading(at: asked.addingTimeInterval(HubTimeouts.standInLoadWindow)))
        #expect(!hub.service.mayBeLoading(at: asked.addingTimeInterval(-1)))
    }

    @Test func theAllowanceIsALoadsAndPassesWithTheWindow() {
        // A load takes the Neo 1.5–2.5 s; a recording that waits behind one still gets the recognition's own time.
        #expect(HubTimeouts.standInLoad >= 2.5)
        // A press of Fn sends its warm-up as it becomes a dictation; the window outlasts any load, and stays well
        // short of the ten idle minutes after which the worker unloads the model again.
        #expect(HubTimeouts.standInLoadWindow > HubTimeouts.standInLoad && HubTimeouts.standInLoadWindow < 600)
        // With the allowance, a short recording on a calm Neo whose model is still loading is waited for: a load of
        // up to 2.5 s and the large model's 2.2 s or so for a recording of a second and a quarter.
        #expect(HubTimeouts.standInRecognition(audioSeconds: 1.25) + HubTimeouts.standInLoad >= 2.5 + 2.2)
    }
}

/// The hub's side of the worker's `POST /warm`, on a real socket.
@Suite struct WorkerWarmTests {
    @Test func theWorkerIsAskedWithTheSecretAndTheModel() async throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let source = WorkerSecretSource(folder: dir)
        let secret = Box(try source.value())
        let record = WorkerRecord()
        try await stubWorker(secret: { secret.value }, record: record).test(.live) { client in
            let worker = ASRWorkerClient(baseURL: URL(string: "http://localhost:\(client.port!)")!, secret: source)
            for model in HubASRModel.allCases {
                // The stub worker's model was not in memory: the warm-up has it loaded.
                #expect(await worker.warm(model: model) == false)
            }
            #expect(record.warms.map(\.model) == ["auto", "large", "small"])
            #expect(record.warms.allSatisfy { $0.secret == secret.value })
            // The worker made a new secret since: the file is read again and the warm-up sent once more.
            let old = secret.value
            let fresh = "a-brand-new-worker-secret-0123456789"
            try fresh.write(to: WorkerSecret.url(in: dir), atomically: true, encoding: .utf8)
            secret.value = fresh
            #expect(await worker.warm(model: .small) == false)
            #expect(record.warms.suffix(2).map(\.secret) == [old, fresh])
            #expect(record.warms.suffix(2).map(\.model) == ["small", "small"])
        }
        #expect(HubPath.workerWarm == "/warm")
    }

    @Test func aWorkerWithoutTheRouteOrNoWorkerAtAllIsNoFailure() async throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let source = WorkerSecretSource(folder: dir)
        let secret = try source.value()
        let record = WorkerRecord()
        // A worker from before 1.4: its 404 is all that happens.
        try await stubWorker(secret: { secret }, record: record, warms: false).test(.live) { client in
            let worker = ASRWorkerClient(baseURL: URL(string: "http://localhost:\(client.port!)")!, secret: source)
            #expect(await worker.warm(model: .auto) == nil)
            let heard = try await worker.recognize(wav: AudioUpload.wav([1, 2, 3]), hints: [], audioSeconds: 1)
            #expect(heard.raw == "明天下午三点开会")
        }
        #expect(record.warms.isEmpty)
        // Nobody listening: over within its own short deadline.
        let gone = ASRWorkerClient(baseURL: URL(string: "http://127.0.0.1:9")!, secret: source)
        let started = Date()
        #expect(await gone.warm(model: .large) == nil)
        #expect(Date().timeIntervalSince(started) < ASRWorkerClient.warmTimeout + 3)
    }
}
