import Foundation
import NeolessCloud
import NeolessCore

/// What the hub needs from the speech recognizer (the Python ASR worker on 127.0.0.1:18801; tests stub it).
public protocol ASRRecognizing: Sendable {
    /// Recognizes a 16 kHz mono 16-bit WAV. `hints` most important first; `model` is what the device asked for.
    func recognize(wav: Data, hints: [String], audioSeconds: Double, model: HubASRModel) async throws -> ASRWorkerResult
    /// The worker's `/health`, or nil when it does not answer.
    func health() async -> ASRWorkerHealth?
    /// Asks the worker to get the model a recognition asking for `model` would use ready (`POST /warm`). Returns
    /// once the worker has taken the request, not once the model is loaded: whether that model was in memory already
    /// (nothing loads), or nil when the worker did not say. Any failure (a worker that is down, or from before 1.4
    /// and so without the route) is no failure of anything else and is only that nil.
    @discardableResult
    func warm(model: HubASRModel) async -> Bool?
}

extension ASRRecognizing {
    /// With the model the worker picks itself (`HubASRModel.auto`).
    public func recognize(wav: Data, hints: [String], audioSeconds: Double) async throws -> ASRWorkerResult {
        try await recognize(wav: wav, hints: hints, audioSeconds: audioSeconds, model: .auto)
    }

    /// A recognizer that cannot be asked ahead: the first recognition loads the model, if it is not in memory.
    @discardableResult
    public func warm(model: HubASRModel) async -> Bool? { nil }
}

/// Why the worker gave no transcript.
public enum ASRFailure: Error, Equatable, Sendable {
    /// Not running, or the connection failed.
    case unreachable
    /// No answer within the time this recording may take.
    case timeout
    /// The worker answered with an error (`code` from its body: `busy`, `too_long`, `bad_audio`…).
    case rejected(status: Int, code: String?)
    /// A 200 whose body does not decode.
    case badResponse
}

/// The model the worker runs, for `/v1/health` when it does not say.
public enum ASRWorker {
    public static let defaultModel = "Qwen3-ASR-0.6B-4bit"
    public static var defaultURL: URL { URL(string: "http://127.0.0.1:\(Hub.asrWorkerPort)")! }

    /// How long one recognition may take when nothing can stand in for it: model load, queueing behind other
    /// requests and recognition itself (on the Neo 0.1–0.2 s per second of audio with the small model and up to
    /// 0.5 s with the large one when the recording has pauses), capped below Cloudflare's 100 s for short
    /// recordings and at 4 minutes for the longest.
    public static func timeout(audioSeconds: Double) -> TimeInterval {
        let seconds = audioSeconds.isFinite ? max(0, audioSeconds) : 0
        return min(240, 30 + 0.5 * seconds)
    }

    /// How long the hub waits when the device sent its own transcript along: 2.5 s + 0.4 s per second of audio, at
    /// most 20 s (`HubTimeouts.standInRecognition`, where the numbers behind it are), and `HubTimeouts.standInLoad`
    /// more while a model load may be under way (`HubService`). Past this the Neo is too busy to be worth waiting
    /// for, and the device's transcript is polished instead, so a busy Neo costs accuracy, not the user's time.
    public static func impatientTimeout(audioSeconds: Double) -> TimeInterval {
        HubTimeouts.standInRecognition(audioSeconds: audioSeconds)
    }
}

/// The shared secret, read from its file once and again after the worker refuses it (a new secret since).
public final class WorkerSecretSource: @unchecked Sendable {
    private let folder: URL
    private let lock = NSLock()
    private var cached: String?

    public init(folder: URL) { self.folder = folder }

    public func value(reload: Bool = false) throws -> String {
        try lock.withLock {
            if !reload, let cached { return cached }
            let value = try WorkerSecret.loadOrCreate(in: folder)
            cached = value
            return value
        }
    }
}

/// HTTP client of the ASR worker (docs/hub.md, "ASR worker").
public struct ASRWorkerClient: ASRRecognizing {
    public let baseURL: URL
    public let secret: WorkerSecretSource
    public let session: URLSession

    public init(baseURL: URL = ASRWorker.defaultURL, secret: WorkerSecretSource, session: URLSession = ASRWorkerClient.makeSession()) {
        self.baseURL = baseURL; self.secret = secret; self.session = session
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]   // 127.0.0.1 only, never through a proxy
        // Backstops only: every call has its own deadline (`deadline`), shorter than these.
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }

    public func recognize(wav: Data, hints: [String], audioSeconds: Double, model: HubASRModel) async throws -> ASRWorkerResult {
        let timeout = ASRWorker.timeout(audioSeconds: audioSeconds)
        var (data, status) = try await send(wav: wav, hints: hints, model: model, secret: secret.value(), timeout: timeout)
        if status == 401 {
            // The worker made a new secret since we read it (or created it first): read the file again, once.
            (data, status) = try await send(wav: wav, hints: hints, model: model, secret: secret.value(reload: true),
                                            timeout: timeout)
        }
        guard status == 200 else {
            throw ASRFailure.rejected(status: status, code: (try? HubJSON.decode(HubErrorBody.self, from: data))?.code)
        }
        guard let result = try? HubJSON.decode(ASRWorkerResult.self, from: data) else { throw ASRFailure.badResponse }
        return result
    }

    public func health() async -> ASRWorkerHealth? {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(HubPath.workerHealth.dropFirst())))
        request.timeoutInterval = 2
        let session = session
        guard let (data, response) = try? await Self.deadline(2, { try await session.data(for: request) }),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? HubJSON.decode(ASRWorkerHealth.self, from: data)
    }

    /// How long a warm-up request may take: the worker answers at once and loads in the background.
    static let warmTimeout: TimeInterval = 2

    @discardableResult
    public func warm(model: HubASRModel) async -> Bool? {
        guard let first = try? secret.value() else { return nil }
        var answer = await sendWarm(model: model, secret: first)
        if answer?.status == 401, let again = try? secret.value(reload: true) {
            // A new secret since it was read: read the file again, once.
            answer = await sendWarm(model: model, secret: again)
        }
        guard let answer, answer.status == 200 else { return nil }
        return (try? HubJSON.decode(ASRWorkerWarm.self, from: answer.data))?.loaded
    }

    /// `POST /warm`: the worker's status and answer, or nil when it did not answer in time.
    private func sendWarm(model: HubASRModel, secret: String) async -> (status: Int, data: Data)? {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(HubPath.workerWarm.dropFirst())))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.warmTimeout
        request.setValue(secret, forHTTPHeaderField: HubHeader.worker)
        request.setValue(model.rawValue, forHTTPHeaderField: HubHeader.model)
        let session = session
        let prepared = request
        guard let (data, response) = try? await Self.deadline(Self.warmTimeout, { try await session.data(for: prepared) }),
              let status = (response as? HTTPURLResponse)?.statusCode else {
            return nil
        }
        return (status, data)
    }

    /// `operation`, or `ASRFailure.timeout` after `seconds` (the request is cancelled then).
    static func deadline<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw ASRFailure.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func send(wav: Data, hints: [String], model: HubASRModel, secret: String,
                      timeout: TimeInterval) async throws -> (Data, Int) {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(HubPath.workerRecognize.dropFirst())))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(HubAudioType.wav.rawValue, forHTTPHeaderField: "Content-Type")
        request.setValue(secret, forHTTPHeaderField: HubHeader.worker)
        if !hints.isEmpty { request.setValue(ASRHints.headerValue(hints), forHTTPHeaderField: HubHeader.hints) }
        // Always said, "auto" too. A worker before 1.3 does not read it and picks the model itself.
        request.setValue(model.rawValue, forHTTPHeaderField: HubHeader.model)
        let session = session
        let prepared = request
        do {
            let (data, response) = try await Self.deadline(timeout) { try await session.upload(for: prepared, from: wav) }
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch ASRFailure.timeout {
            throw ASRFailure.timeout
        } catch let error as URLError where error.code == .timedOut {
            throw ASRFailure.timeout
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ASRFailure.unreachable
        }
    }
}
