import AVFoundation
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NeolessCloud
import NeolessCore
@testable import NeolessHubKit

// The hub's tests never reach the real ASR worker or ChatGPT: recognition is `StubASR`, polishing `StubPolisher`
// (or the real `ChatGPTPolisher` with no login, which fails before any request), and every data folder is a
// temporary one.

/// A temporary folder, deleted by `removeTemporary`.
func temporaryDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neoless-hub-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func removeTemporary(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

/// Every log line any test wrote (the sink is process-wide, so it is installed once and only collects).
final class TestLog: @unchecked Sendable {
    static let shared: TestLog = {
        let log = TestLog()
        HubLog.setSink { line in log.append(line) }
        return log
    }()

    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

/// Holds whoever waits until `open()` (a recognition or polish "still running").
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                arrivals += 1
                if isOpen { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// How many callers reached the gate so far.
    var arrived: Int { lock.withLock { arrivals } }

    func open() {
        let all: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        all.forEach { $0.resume() }
    }
}

/// Waits (up to `seconds`) until `condition` holds.
func eventually(_ seconds: Double = 15, _ condition: @escaping () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

/// The ASR worker, stubbed.
final class StubASR: ASRRecognizing, @unchecked Sendable {
    enum Reply {
        case text(String)
        case silence
        case fail(ASRFailure)
    }

    struct Call {
        let wav: Data
        let hints: [String]
        let seconds: Double
        let model: HubASRModel
    }

    private let lock = NSLock()
    private var _reply: Reply = .text("嗯明天下午三点开会")
    private var _calls: [Call] = []
    private var _warms: [HubASRModel] = []
    private var _warmGate: Gate?
    private var _warmAnswer: Bool? = true
    private var _gate: Gate?
    private var _health: ASRWorkerHealth? = ASRWorkerHealth(ok: true, model: "Qwen3-ASR-0.6B-4bit", loaded: true, pending: 0)

    var reply: Reply {
        get { lock.withLock { _reply } }
        set { lock.withLock { _reply = newValue } }
    }
    var gate: Gate? {
        get { lock.withLock { _gate } }
        set { lock.withLock { _gate = newValue } }
    }
    var healthAnswer: ASRWorkerHealth? {
        get { lock.withLock { _health } }
        set { lock.withLock { _health = newValue } }
    }
    var calls: [Call] { lock.withLock { _calls } }
    /// The model of each warm-up the hub asked for, in order.
    var warms: [HubASRModel] { lock.withLock { _warms } }
    /// Holds every warm-up until opened (a worker that is slow to answer).
    var warmGate: Gate? {
        get { lock.withLock { _warmGate } }
        set { lock.withLock { _warmGate = newValue } }
    }

    /// What each warm-up answers: whether the model was in memory already (nil: the worker did not say, as one
    /// from before 1.4 or one that is down).
    var warmAnswer: Bool? {
        get { lock.withLock { _warmAnswer } }
        set { lock.withLock { _warmAnswer = newValue } }
    }

    func warm(model: HubASRModel) async -> Bool? {
        if let warmGate { await warmGate.wait() }
        return lock.withLock {
            _warms.append(model)
            return _warmAnswer
        }
    }

    func recognize(wav: Data, hints: [String], audioSeconds: Double, model: HubASRModel) async throws -> ASRWorkerResult {
        lock.withLock { _calls.append(Call(wav: wav, hints: hints, seconds: audioSeconds, model: model)) }
        if let gate { await gate.wait() }
        switch reply {
        case .text(let text): return ASRWorkerResult(raw: text, status: .ok, asrMs: 5, model: "Qwen3-ASR-0.6B-4bit")
        case .silence: return ASRWorkerResult(raw: "", status: .noSpeech, asrMs: 0, model: "Qwen3-ASR-0.6B-4bit")
        case .fail(let failure): throw failure
        }
    }

    func health() async -> ASRWorkerHealth? { healthAnswer }
}

/// ChatGPT, stubbed.
@MainActor
final class StubPolisher: HubPolishing {
    struct Call {
        let transcript: String
        let mode: DictationMode
        let appName: String?
        let vocabulary: Vocabulary.PromptWords
        let corrections: [CorrectionPair]
        let extras: PolishExtras
        let options: PolishOptions
    }

    var answer: (String, DictationMode) throws -> String = { text, mode in
        mode == .structured ? "- \(text)" : text.replacingOccurrences(of: "嗯", with: "") + "。"
    }
    var gate: Gate?
    private(set) var calls: [Call] = []
    var health = HubHealth.ChatGPT(ready: true, account: "a***@example.com")

    func waitForRefresh() async {}

    func polish(_ transcript: String, mode: DictationMode, appName: String?, vocabulary: Vocabulary.PromptWords,
                corrections: [CorrectionPair], extras: PolishExtras, options: PolishOptions) async throws -> String {
        calls.append(Call(transcript: transcript, mode: mode, appName: appName, vocabulary: vocabulary, corrections: corrections,
                          extras: extras, options: options))
        if let gate { await gate.wait() }
        return try answer(transcript, mode)
    }
}

/// A hub with stubbed recognition and polishing, its data in a temporary folder, and one paired device.
@MainActor
final class HubFixture: @unchecked Sendable {
    let dir: URL
    let folder: HubDataFolder
    let asr = StubASR()
    let polisher: StubPolisher
    let service: HubService
    let token: String

    /// - Parameter words: the user's own words, put before the default dictionary (a test about a fix towards
    ///   a dictionary word needs one that is there).
    /// `quickTidy`: whether short transcripts skip ChatGPT (`HubService.quickTidy`); off, as most tests are about the request.
    init(rateLimit: Int = 1_000, realPolisher: Bool = false, words: [String] = [], quickTidy: Bool = false,
         now: @escaping () -> Date = Date.init) throws {
        _ = TestLog.shared
        dir = temporaryDirectory()
        folder = try HubDataFolder.at(dir)
        polisher = StubPolisher()
        service = HubService(folder: folder, asr: asr, polisher: realPolisher ? nil : polisher, rateLimit: rateLimit,
                             now: now)
        service.quickTidy = quickTidy
        token = try service.devices.pair(name: "iPhone").token
        if !words.isEmpty {
            let before = service.vocabulary
            _ = try service.updateVocabulary(VocabularyUpdate(words: words + before.words, expectedRevision: before.revision))
        }
    }

    deinit { removeTemporary(dir) }

    nonisolated var app: some ApplicationProtocol { Application(router: HubServer.router(service: service)) }

    nonisolated var auth: HTTPFields { [.authorization: "Bearer \(token)"] }

    nonisolated func headers(_ extra: [HTTPField.Name: String] = [:], authorized: Bool = true) -> HTTPFields {
        var fields = authorized ? auth : HTTPFields()
        for (name, value) in extra { fields[name] = value }
        return fields
    }

    /// `POST /v1/dictations` headers for `request` and an audio type.
    nonisolated func dictationHeaders(_ request: DictationRequest, type: HubAudioType = .m4a) throws -> HTTPFields {
        headers([.contentType: type.rawValue, HubServer.requestHeader: try request.headerValue()])
    }

    /// One request through the router (no network); authorized as the paired iPhone unless `headers` says otherwise.
    nonisolated func send(_ method: HTTPRequest.Method, _ uri: String, headers: HTTPFields? = nil,
                          body: ByteBuffer? = nil) async throws -> TestResponse {
        let fields = headers ?? auth
        return try await app.test(.router) { client in
            try await client.execute(uri: uri, method: method, headers: fields, body: body)
        }
    }

    /// `POST /v1/dictations` with `audio`.
    nonisolated func dictate(_ request: DictationRequest, audio: Data = AudioFixture.m4a,
                             type: HubAudioType = .m4a) async throws -> TestResponse {
        try await send(.post, HubPath.dictations, headers: try dictationHeaders(request, type: type), body: ByteBuffer(bytes: audio))
    }

    nonisolated func post<T: Encodable>(_ uri: String, _ value: T) async throws -> TestResponse {
        try await send(.post, uri, body: try json(value))
    }
}

func dictation(_ id: UUID = UUID(), mode: DictationMode = .natural, autoStructured: Bool = true, appName: String? = "备忘录",
               bundleID: String? = "com.apple.Notes", local: String? = nil, client: HubClientKind = .ios) -> DictationRequest {
    DictationRequest(mode: mode, autoStructured: autoStructured, appName: appName, bundleID: bundleID, localTranscript: local,
                     durationSeconds: 1, clientRecordingID: id, client: client, clientVersion: "1.2.0")
}

func json<T: Encodable>(_ value: T) throws -> ByteBuffer { ByteBuffer(bytes: try HubJSON.encode(value)) }

func decode<T: Decodable>(_ type: T.Type, _ response: TestResponse) throws -> T {
    try HubJSON.decode(T.self, from: Data(response.body.readableBytesView))
}

func errorBody(_ response: TestResponse) -> HubErrorBody? {
    try? HubJSON.decode(HubErrorBody.self, from: Data(response.body.readableBytesView))
}

/// Recordings for the upload formats: one second of a tone at 16 kHz.
enum AudioFixture {
    static let samples: [Float] = (0..<16_000).map { 0.3 * sin(2 * .pi * 440 * Float($0) / 16_000) }

    static let m4a: Data = (try? AudioUpload.aac(samples)) ?? Data()
    static let wav: Data = AudioUpload.wav(AudioUpload.int16(samples))

    /// 16-bit PCM in a CAF file, as an iPhone recording might be.
    static let caf: Data = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("neoless-hub-test-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 44_100.0,
                                           AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                                           AVLinearPCMIsFloatKey: false]
            try autoreleasepool {
                let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let count = 44_100
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))!
                for channel in 0..<2 {
                    let data = buffer.floatChannelData![channel]
                    for i in 0..<count { data[i] = 0.3 * sin(2 * .pi * 440 * Float(i) / 44_100) }
                }
                buffer.frameLength = AVAudioFrameCount(count)
                try file.write(from: buffer)
                if #available(macOS 15.0, *) { file.close() }
            }
            return try Data(contentsOf: url)
        } catch {
            return Data()
        }
    }()
}
