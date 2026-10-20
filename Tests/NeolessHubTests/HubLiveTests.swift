import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NeolessCloud
import NeolessCore
import Testing
@testable import NeolessHubKit

/// What a stand-in ASR worker saw.
final class WorkerRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(secret: String?, hints: [String]?, type: String?, bytes: Int)] = []
    private var _models: [String?] = []
    private var _warms: [(secret: String?, model: String?)] = []
    func add(secret: String?, hints: [String]?, type: String?, bytes: Int, model: String? = nil) {
        lock.withLock {
            _requests.append((secret, hints, type, bytes))
            _models.append(model)
        }
    }
    func addWarm(secret: String?, model: String?) { lock.withLock { _warms.append((secret, model)) } }
    /// `POST /warm`: the secret and the `X-Model` header of each, in order.
    var warms: [(secret: String?, model: String?)] { lock.withLock { _warms } }
    var requests: [(secret: String?, hints: [String]?, type: String?, bytes: Int)] { lock.withLock { _requests } }
    /// The `X-Model` header of each request, in order.
    var models: [String?] { lock.withLock { _models } }
}

/// A stand-in for the Python ASR worker, on a real socket: checks the secret like the worker, answers `text`.
/// (`test(.live)` serves on localhost, port 0, whatever the configuration says.)
/// `warms`: it has `POST /warm` (worker 1.4); without it, that is a 404 as from an older worker.
func stubWorker(secret: @escaping @Sendable () -> String, record: WorkerRecord, text: String = "明天下午三点开会",
                status: HTTPResponse.Status = .ok, warms: Bool = true) -> some ApplicationProtocol {
    let router = Router()
    if warms {
        router.post("/warm") { request, _ in
            let given = request.headers[HTTPField.Name(HubHeader.worker)!]
            record.addWarm(secret: given, model: request.headers[HTTPField.Name(HubHeader.model)!])
            guard given == secret() else {
                return Response(status: .unauthorized, headers: [.contentType: "application/json"],
                                body: .init(byteBuffer: ByteBuffer(string: #"{"error":"密钥不对","code":"unauthorized","retryable":false}"#)))
            }
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: ByteBuffer(string: #"{"ok":true,"model":"Qwen3-ASR-0.6B-4bit","loaded":false,"warming":true}"#)))
        }
    }
    router.get("/health") { _, _ in
        Response(status: .ok, headers: [.contentType: "application/json"],
                 body: .init(byteBuffer: ByteBuffer(string: #"{"ok":true,"model":"Qwen3-ASR-0.6B-4bit","loaded":false,"pending":0}"#)))
    }
    router.post("/recognize") { request, _ in
        var bytes = 0
        for try await buffer in request.body { bytes += buffer.readableBytes }
        let given = request.headers[HTTPField.Name(HubHeader.worker)!]
        record.add(secret: given, hints: request.headers[HTTPField.Name(HubHeader.hints)!].flatMap(ASRHints.decode),
                   type: request.headers[.contentType], bytes: bytes, model: request.headers[HTTPField.Name(HubHeader.model)!])
        guard given == secret() else {
            return Response(status: .unauthorized, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: ByteBuffer(string: #"{"error":"密钥不对","code":"unauthorized","retryable":false}"#)))
        }
        guard status == .ok else {
            return Response(status: status, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: ByteBuffer(string: #"{"error":"排队已满","code":"busy","retryable":true}"#)))
        }
        let body = try HubJSON.encode(ASRWorkerResult(raw: text, status: .ok, asrMs: 12, model: "Qwen3-ASR-0.6B-4bit",
                                                      loadMs: 0, queueMs: 0, audioSeconds: 1))
        return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(bytes: body)))
    }
    return Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Real sockets: the worker client against a stand-in worker, and the clients' own `HubClient` against the hub.
@Suite struct HubLiveTests {
    @Test func workerClientSendsSecretHintsAndWAV() async throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let source = WorkerSecretSource(folder: dir)
        let secret = Box(try source.value())
        let record = WorkerRecord()
        try await stubWorker(secret: { secret.value }, record: record).test(.live) { client in
            let worker = ASRWorkerClient(baseURL: URL(string: "http://localhost:\(client.port!)")!, secret: source)
            let wav = AudioUpload.wav([Int16](repeating: 100, count: 16_000))
            let result = try await worker.recognize(wav: wav, hints: ["OpenAI", "硬币"], audioSeconds: 1)
            #expect(result.raw == "明天下午三点开会" && result.status == .ok)
            let seen = try #require(record.requests.last)
            #expect(seen.secret == secret.value && seen.hints == ["OpenAI", "硬币"])
            #expect(seen.type == "audio/wav" && seen.bytes == wav.count)

            // No hints: no header.
            _ = try await worker.recognize(wav: wav, hints: [], audioSeconds: 1)
            #expect(record.requests.last?.hints == nil)

            // The worker made a new secret since: read the file again and retry once.
            let old = secret.value
            let fresh = "a-brand-new-worker-secret-0123456789"
            try fresh.write(to: WorkerSecret.url(in: dir), atomically: true, encoding: .utf8)
            secret.value = fresh
            #expect(try await worker.recognize(wav: wav, hints: [], audioSeconds: 1).raw == "明天下午三点开会")
            #expect(record.requests.suffix(2).map(\.secret) == [old, fresh])

            let health = await worker.health()
            #expect(health == ASRWorkerHealth(ok: true, model: "Qwen3-ASR-0.6B-4bit", loaded: false, pending: 0))
        }
    }

    @Test func workerErrorsAreTold() async throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let source = WorkerSecretSource(folder: dir)
        let secret = try source.value()
        try await stubWorker(secret: { secret }, record: WorkerRecord(), status: .serviceUnavailable).test(.live) { client in
            let worker = ASRWorkerClient(baseURL: URL(string: "http://localhost:\(client.port!)")!, secret: source)
            await #expect(throws: ASRFailure.rejected(status: 503, code: "busy")) {
                try await worker.recognize(wav: AudioUpload.wav([1, 2, 3]), hints: [], audioSeconds: 1)
            }
        }
        // A deadline that runs out first.
        await #expect(throws: ASRFailure.timeout) {
            try await ASRWorkerClient.deadline(0.05) { try await Task.sleep(nanoseconds: 5_000_000_000) }
        }
        #expect(try await ASRWorkerClient.deadline(5) { 42 } == 42)
        // Nothing listening.
        let gone = ASRWorkerClient(baseURL: URL(string: "http://127.0.0.1:9")!, secret: source)
        await #expect(throws: ASRFailure.unreachable) { try await gone.recognize(wav: Data(), hints: [], audioSeconds: 1) }
        #expect(await gone.health() == nil)
    }

    /// The device side (`HubClient`, as the Mac and iPhone apps use it) against the hub on a real socket, with
    /// a stand-in worker behind it: the whole wire contract, both directions.
    @Test @MainActor func hubClientAgainstTheHub() async throws {
        _ = TestLog.shared
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let folder = try HubDataFolder.at(dir)
        let source = WorkerSecretSource(folder: dir)
        let secret = try source.value()
        let record = WorkerRecord()
        let polisher = StubPolisher()
        try await stubWorker(secret: { secret }, record: record, text: "嗯我的 I phone 坏了").test(.live) { workerClient in
            let worker = ASRWorkerClient(baseURL: URL(string: "http://localhost:\(workerClient.port!)")!, secret: source)
            let service = await HubService(folder: folder, asr: worker, polisher: polisher)
            await MainActor.run { service.quickTidy = false }
            let token = try await service.devices.pair(name: "Mac").token
            let app = Application(router: HubServer.router(service: service),
                                  configuration: .init(address: .hostname("127.0.0.1", port: 0)))
            try await app.test(.live) { hubClient in
                let client = HubClient(server: URL(string: "http://localhost:\(hubClient.port!)")!, token: token)
                #expect(try await client.ping() == HubOK())
                let health = try await client.health()
                #expect(health.device == "Mac" && health.asr.ready && health.chatgpt.ready)

                let samples: [Float] = (0..<16_000).map { 0.2 * sin(Float($0) / 10) }
                let audio = AudioUpload.encode(samples)
                let request = DictationRequest(mode: .natural, autoStructured: true, appName: "备忘录", localTranscript: "本机",
                                               durationSeconds: audio.durationSeconds, client: .mac, clientVersion: "1.2.0")
                let result = try await client.dictate(audio, request: request)
                #expect(result.raw == "嗯我的 I phone 坏了" && result.text == "我的 I phone 坏了。" && result.recognizer == .qwen3ASR)
                #expect(record.requests.last?.type == "audio/wav")
                #expect(try await client.dictate(audio, request: request) == result)

                let edited = try await client.edit(id: result.id, text: "我的 iPhone 坏了。")
                #expect(edited.learned == [CorrectionPair(wrong: "I phone", right: "iPhone")])
                let vocabulary = try await client.vocabulary()
                #expect(vocabulary.learned == ["iPhone"])
                do {
                    _ = try await client.updateVocabulary(words: ["x"], expectedRevision: "stale")
                    Issue.record("a stale revision was taken")
                } catch let error as HubError {
                    #expect(error.isConflict && !error.needsPairing)
                }
                let updated = try await client.updateVocabulary(words: ["Neo"] + vocabulary.words, expectedRevision: vocabulary.revision)
                #expect(updated.words.first == "Neo")

                let repolished = try await client.repolish(id: result.id, mode: .structured)
                #expect(repolished.mode == .structured && repolished.id == result.id)
                let polished = try await client.polish(PolishRequest(text: "嗯后天见", mode: .natural, autoStructured: true,
                                                                     client: .mac, clientVersion: "1.2.0"))
                #expect(polished.text == "后天见。" && polished.recognizer == .local)

                let page = try await client.history(limit: 1)
                #expect(page.items.map(\.id) == [polished.id] && page.nextBefore != nil)
                let older = try await client.history(limit: 5, before: page.nextBefore)
                #expect(older.items.map(\.id) == [result.id] && older.items.first?.edited == false)

                #expect(try await client.observe([CorrectionPair(wrong: "You Tube", right: "YouTube")]).accepted == 1)
                #expect(try await client.learning().pairs.count == 2)
                #expect(try await client.forget(wrong: "You Tube").pairs.count == 1)
                let sync = try await client.sync()
                #expect(sync.vocabulary.words.first == "Neo" && sync.settings.autoStructured)

                try await client.deleteHistory(id: polished.id)
                try await client.deleteHistory(id: polished.id)   // gone already: fine for the client

                // Revoked: the client is told to pair again.
                try await service.devices.revoke(name: "Mac")
                do {
                    _ = try await client.health()
                    Issue.record("a revoked device was answered")
                } catch let error as HubError {
                    #expect(error.needsPairing)
                }
            }
        }
    }
}
