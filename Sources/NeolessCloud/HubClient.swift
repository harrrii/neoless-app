import Foundation
import NeolessCore

/// Why a hub request failed. Whatever the case, a device that was dictating uses its own result instead
/// (the local transcript, polished by its own ChatGPT login when it has one): no words are ever lost.
public enum HubError: LocalizedError, Equatable, Sendable {
    /// No server or device token saved yet.
    case notPaired
    /// The device has no network at all.
    case offline
    /// No connection to the hub within `HubTimeouts.connect` (or DNS, TLS, refused…).
    case unreachable
    /// The connection dropped in the middle of the request.
    case connectionLost
    /// Connected, but the hub did not answer within the request's budget.
    case timeout
    /// The recording is over `Hub.maxAudioBytes`; it was not sent.
    case audioTooLarge
    /// The request could not be built (`HubProtocolError`); it was not sent.
    case invalidRequest(String)
    /// The hub answered with an error status. `body` is nil when the answer was not the hub's own
    /// (Cloudflare's page while the Neo is asleep, or its block page in front of the hub).
    case server(status: Int, body: HubErrorBody?)
    /// A success status with a body that does not decode.
    case badResponse
    /// Cloudflare Access (双重锁, docs/hub.md) stopped the request before it reached the Neo: this device's pairing
    /// has no service token, or not the one Access takes now (rotated, revoked or expired). The Neo itself may be
    /// fine; a new pairing link brings the current token. Not the hub's refusal of the device token
    /// (`needsPairing`), and not an unreachable Neo.
    case accessDenied

    public var errorDescription: String? {
        switch self {
        case .notPaired: return "还没连接 Neo"
        case .offline: return "没有网络"
        case .unreachable: return "连不上 Neo"
        case .connectionLost: return "和 Neo 的连接断了"
        case .timeout: return "Neo 处理超时"
        case .audioTooLarge: return "录音太大，发不出去"
        case .invalidRequest(let why): return why
        case .badResponse: return "Neo 的回答看不懂"
        case .accessDenied: return Self.accessDeniedText
        case .server(let status, let body):
            if let text = body?.error.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
            if needsPairing { return Self.pairAgain }
            return Self.text(forStatus: status)
        }
    }

    /// What `needsPairing` tells the user when the hub's answer carries no text of its own.
    public static let pairAgain = "这台设备和 Neo 的连接已失效，请重新配对"
    /// What `accessDenied` tells the user.
    public static let accessDeniedText = "Cloudflare 门禁没放行这台设备，请重新配对"

    /// What an error status means when the answer carries no text of its own. A 401 or 403 here is not the
    /// hub's (that one comes with its error body): something on the way, such as Cloudflare, turned it away.
    public static func text(forStatus status: Int) -> String {
        switch status {
        case 400: return "请求的格式不对"
        case 401, 403: return "请求被网络拦下了（\(status)）"
        case 404: return "Neo 上没有这条记录"
        case 409: return "词典已在别的设备上改过，请刷新后再改"
        case 413: return "内容太大，Neo 不收"
        case 415: return "Neo 不认识这种音频格式"
        case 422: return "Neo 解不开这段录音"
        case 429: return "请求太频繁，稍后再试"
        // Cloudflare reached the hub, which took longer than Cloudflare waits (`HubClient.cloudflareWait`).
        case 524: return "Neo 处理超时"
        case 502, 503, 504, 520...530: return "Neo 没有响应，可能在睡眠或断网"
        default: return "Neo 出错了（\(status)）"
        }
    }

    /// The hub itself no longer accepts the device token: pair again. Only the hub's own refusal counts (its
    /// error body says `unauthorized` or `forbidden`): a 401 or 403 page from something in front of it, such as
    /// a Cloudflare challenge or block, says nothing about the token, which must not be thrown away for it.
    public var needsPairing: Bool {
        guard case .server(let status, let body?) = self, status == 401 || status == 403 else { return false }
        return body.code == HubErrorCode.unauthorized || body.code == HubErrorCode.forbidden
    }

    /// `PUT /v1/vocabulary` lost to a change made elsewhere: load the dictionary again, then retry the change.
    public var isConflict: Bool {
        if case .server(409, _) = self { return true }
        return false
    }

    /// Whether the same request may work if sent again later.
    public var retryable: Bool {
        switch self {
        case .offline, .unreachable, .connectionLost, .timeout: return true
        // Not until this device is paired again with the current Access credentials.
        case .notPaired, .audioTooLarge, .invalidRequest, .badResponse, .accessDenied: return false
        case .server(let status, let body):
            if let body { return body.retryable }
            // Not the hub's answer: Cloudflare's page while the Neo sleeps, or a block in front of the hub.
            return status == 401 || status == 403 || status == 429 || (500...599).contains(status)
        }
    }
}

/// How long hub requests may take. A device must find out fast when the hub cannot be reached, so it can
/// fall back to its own result, and must give a reachable hub the time a long recording needs.
public struct HubTimeouts: Equatable, Sendable {
    /// No sign of the hub after this long: it is unreachable (`HubClient` says what counts as a sign).
    public var connect: TimeInterval
    /// The whole budget of a small request (health, lists, dictionary, edit, learning, sync).
    public var quick: TimeInterval
    /// The whole budget of `GET /v1/ping`, the reachability check.
    public var ping: TimeInterval
    /// The hub's own 整理超时 floor (`PolishOptions.minimumTimeout`): the hub may polish this long.
    public var hubPolishFloor: TimeInterval
    /// Decoding, saving and the trip back, on top of the work itself.
    public var margin: TimeInterval
    /// No request waits longer than this.
    public var cap: TimeInterval

    public init(connect: TimeInterval = 3, quick: TimeInterval = 10, ping: TimeInterval = 3, hubPolishFloor: TimeInterval = 10,
                margin: TimeInterval = 5, cap: TimeInterval = HubTimeouts.longest) {
        self.connect = connect; self.quick = quick; self.ping = ping; self.hubPolishFloor = hubPolishFloor
        self.margin = margin; self.cap = cap
    }

    public static let standard = HubTimeouts()

    /// The standard `cap`. Through the tunnel no single answer can take longer than Cloudflare waits
    /// (`HubClient.cloudflareWait`, 100 s); a longer job is asked about again (`HubClient` explains).
    public static let longest: TimeInterval = 300
    /// Slowest upload speed planned for, in bytes per second (about 256 kbit/s).
    public static let uploadBytesPerSecond: Double = 32_000
    /// Recognition by a request that does not ask for the large model by name (`patient`): loading the speech model
    /// again after the worker unloaded it (10 idle minutes), and recognition per second of audio. With or without
    /// this device's transcript in the request. When it carries one, the hub gives up on its worker sooner and
    /// polishes that transcript instead, and this covers that wait whichever rule the hub follows: an older one
    /// waits up to 6 s + 0.8 s per second of audio (at most a minute), a newer one `standInRecognition` and, while
    /// a model load may be under way, `standInLoad` on top. So the device can be updated before its hub, and the
    /// hub's answer arrives within the budget either way. A request without a transcript (it was not ready in time,
    /// or did not fit in the header) is waited for longer on the hub (`patientModelLoad`): the device gives up first
    /// and does the work itself.
    public static let modelLoad: TimeInterval = 8
    public static let asrPerAudioSecond: TimeInterval = 0.8
    /// What the hub itself gives recognition when no transcript came along to stand in for it (`ASRWorker.timeout`
    /// there): loading a model and waiting behind other requests, and recognition at half of real time.
    public static let patientModelLoad: TimeInterval = 30
    public static let patientASRPerAudioSecond: TimeInterval = 0.5
    /// `standInRecognition`: a fixed part, a part per second of audio, and the most it is.
    public static let standInBase: TimeInterval = 2.5
    public static let standInPerAudioSecond: TimeInterval = 0.4
    public static let standInCap: TimeInterval = 20
    /// What the hub adds to `standInRecognition` while a model load may be under way: a warm-up (`POST /v1/warm`)
    /// went to its worker less than `standInLoadWindow` ago, and the worker has not said that the model was in memory
    /// already. A load takes the Neo 1.5–2.5 s (`load=` in its asr.log); a recording that waits behind one in the
    /// worker's queue counts that wait against the hub's deadline. Past the window the load is over even on a busy
    /// Neo, and a recording finds the model in memory.
    public static let standInLoad: TimeInterval = 3
    public static let standInLoadWindow: TimeInterval = 20
    /// Characters spoken per second (Mandarin), to guess the transcript's length before it exists.
    public static let charactersPerAudioSecond: Double = 5

    /// How long the hub waits for its worker when the device's own transcript came along and can stand in for the
    /// Neo's (`ASRWorker.impatientTimeout` is this function), before it polishes the device's transcript instead: a
    /// swamped Neo costs accuracy (English names, mostly), not the user's time. 2.5 s + 0.4 s per second of audio, at
    /// most 20 s; `standInLoad` more while a model load may be under way. A device's budget covers it with room to
    /// spare (`modelLoad`).
    ///
    /// From recognition times measured on a Neo (`asrMs`, October 2026):
    /// - Calm, the large model took 2.8 s for 6.9 s of audio, 3.0 s for 10.4 s and 3.3 s for 11.9 s (about 2 s plus
    ///   0.1–0.3 s per second), the small one 1.0 s for 7.7 s. This gives them 5.3–7.3 s: twice what the large model
    ///   needed. A recording with pauses that mixes Chinese and English costs the large model up to 0.5 s per second
    ///   of audio (the language is asked piece by piece, and each stretch is a call of its own): still within this
    ///   up to about 20 s of audio.
    /// - The fixed 2.5 s is the recognition's own: the large model's 2 s or so however short the recording, with a
    ///   little room. It leaves nothing for a model load, which has `standInLoad` of its own. A load is likely just as
    ///   the recording arrives: the model is unloaded after ten idle minutes, and a press of Fn shorter than the
    ///   shortcut window (1.1 s) sends its warm-up only on release, a moment before the recording. A load nobody asked
    ///   for ahead (a device from before the warm-up) can make a short recording miss it; that costs accuracy, not
    ///   time.
    /// - Busy (the Neo's swap nearly full, other work running on it), the small model took 7.2 s for 7.3 s of audio
    ///   and 13.0 s for 5.3 s, the large one 16.3 s for 13.1 s and 13.0 s for 21.9 s. Given up on after 5.4, 4.6,
    ///   7.7 and 11.3 s instead: 1.7 to 8.6 s sooner (3 s less while a load may be under way).
    /// - At most 20 s, reached at about 44 s of audio: no recording that brings its own transcript waits longer for
    ///   the Neo's (but for a model load).
    ///
    /// Before: 6 s + 0.8 s per second, at most 60 s, so a busy Neo cost 10–12 s even with the device's transcript
    /// at hand. The worker still judges the large model too slow only past its own, longer limit (0.6 s per second
    /// of audio and more, `AdaptiveEngine.slow_limit` in hub/asr/asr_worker.py), so a recognition given up on here
    /// does not by itself send `auto` to the small model.
    public static func standInRecognition(audioSeconds: Double) -> TimeInterval {
        let seconds = audioSeconds.isFinite ? max(0, audioSeconds) : 0
        return min(standInCap, standInBase + standInPerAudioSecond * seconds)
    }

    /// The whole budget of `POST /v1/dictations`: connect, upload, recognition, polish and margin, so it grows with
    /// the recording. Recognition: `modelLoad` and `asrPerAudioSecond`, whether or not the request carries this
    /// device's transcript (see there); `patient`: the request waits for the Neo however busy it is
    /// (`DictationRequest.waitsForNeo`), so recognition gets as long as the hub itself gives it. `cap` still holds.
    public func dictation(durationSeconds: Double, audioBytes: Int, patient: Bool = false) -> TimeInterval {
        let duration = durationSeconds.isFinite ? max(0, durationSeconds) : 0
        let upload = Double(max(0, audioBytes)) / Self.uploadBytesPerSecond
        let characters = Int(duration * Self.charactersPerAudioSecond)
        let recognition = patient ? Self.patientModelLoad + Self.patientASRPerAudioSecond * duration
                                  : Self.modelLoad + Self.asrPerAudioSecond * duration
        let total = connect + upload + recognition + hubPolish(characters: characters) + margin
        return min(cap, total)
    }

    /// The whole budget of a request that polishes `characters` of text (`/v1/polish`); nil: unknown
    /// (`…/repolish`), the longest polish.
    public func polish(characters: Int?) -> TimeInterval {
        min(cap, connect + hubPolish(characters: characters) + margin)
    }

    /// The least a second try gets after a dropped connection: sending `bytes` again and collecting the answer.
    /// The hub runs one job per `clientRecordingID` and answers the second try with the first one's result,
    /// so a drop late in the budget must not leave too little time to send the recording again.
    public func resend(bytes: Int) -> TimeInterval {
        min(cap, connect + Double(max(0, bytes)) / Self.uploadBytesPerSecond + margin)
    }

    /// How long the hub's own polish may take (`Polisher.polish`'s budget there).
    func hubPolish(characters: Int?) -> TimeInterval {
        guard let characters else { return max(hubPolishFloor, PolishTimeout.cap) }
        return PolishTimeout.seconds(forCharacters: characters, minimum: hubPolishFloor)
    }
}

/// Talks to the hub (docs/hub.md) for the Mac app and the iPhone app. Every call is async, honours task
/// cancellation (throwing `CancellationError`) and throws `HubError` otherwise.
///
/// Timing. URLSession has no connect timeout of its own, so a request counts as having reached the hub when:
/// - its answer started to arrive (the response is in, however long the body still takes; small requests:
///   the hub answers at once, so `timeouts.connect` is all they get unless that happens or a new TLS
///   connection was made, which shows the network works: then `timeouts.quick`);
/// - for the slow ones (dictation, polish, repolish), a `GET /v1/ping` sent alongside came back 200 through the
///   same tunnel, which shows the hub itself is answering. Bytes written to the socket prove nothing: a dead
///   connection takes them too.
/// Without such a sign within `timeouts.connect` (3 s) the request fails as `.unreachable`, so the device falls
/// back quickly; with it, it may take its whole budget (`HubTimeouts`). Calls that are safe to repeat (reads,
/// deletes, and dictations and polishes, which the hub runs once per `clientRecordingID`) are sent once more
/// when the connection drops mid-way, with at least `HubTimeouts.resend` to go.
///
/// Cloudflare waits only `cloudflareWait` (100 s) for the hub's answer to begin, then answers 524 itself while the
/// hub goes on working. The slow calls are then sent again, the same request with the same `clientRecordingID`,
/// within what is left of their budget: the hub answers that one with the job's result once it is done.
///
/// 双重锁. With `access` (the pairing's Cloudflare Access service token) every request carries
/// `CF-Access-Client-Id` and `CF-Access-Client-Secret`, `GET /v1/ping` and the probe alongside the slow calls
/// included, so Cloudflare lets it through to the Neo. No request follows a redirect: the hub never sends one, and
/// the token and the secret must never go to another host. What Cloudflare Access sends instead of the hub's
/// answer (`HubAccessRefusal`) is `HubError.accessDenied`.
public final class HubClient: Sendable {
    public let server: URL
    private let token: String
    /// The Cloudflare Access service token every request carries, or nil.
    private let access: HubAccess?
    public let session: URLSession
    private let given: HubTimeouts
    /// The hub's own 整理超时 floor, once `GET /v1/health` said it (`HubHealth.polishTimeout`).
    private let hubFloor = PolishFloor()

    public init(server: URL, token: String, access: HubAccess? = nil, session: URLSession = HubClient.sharedSession,
                timeouts: HubTimeouts = .standard) {
        self.server = server
        self.token = token
        self.access = access
        self.session = session
        given = timeouts
    }

    /// The requests carry a Cloudflare Access service token (双重锁).
    public var hasAccess: Bool { access != nil }

    /// The budgets this client gives its calls: the ones it was made with, and the hub's polish floor as the
    /// hub's last health answer gave it, so a hub set to polish longer is waited for.
    public var timeouts: HubTimeouts {
        var timeouts = given
        if let floor = hubFloor.value { timeouts.hubPolishFloor = floor }
        return timeouts
    }

    public convenience init(pairing: HubPairing, session: URLSession = HubClient.sharedSession, timeouts: HubTimeouts = .standard) {
        self.init(server: pairing.server, token: pairing.token, access: pairing.access, session: session, timeouts: timeouts)
    }

    /// No cache, no cookies, no waiting for connectivity: a device that is offline must find out at once.
    public static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        // Backstops only: every request carries its own budget and is cancelled when that runs out.
        c.timeoutIntervalForRequest = HubTimeouts.longest
        c.timeoutIntervalForResource = HubTimeouts.longest + 60
        return URLSession(configuration: c)
    }

    public static let sharedSession = makeSession()

    // MARK: Endpoints

    /// `GET /v1/ping` (no token): is the hub there at all?
    public func ping() async throws -> HubOK {
        try await send(Call(method: "GET", path: HubPath.ping, authorized: false, budget: timeouts.ping, repeatable: false))
    }

    /// `GET /v1/health`. Its `polishTimeout` sizes this client's later budgets.
    public func health() async throws -> HubHealth {
        let health: HubHealth = try await send(quick("GET", HubPath.health))
        if let floor = health.polishTimeout, floor.isFinite {
            hubFloor.value = min(max(floor, PolishTimeout.settingRange.lowerBound), PolishTimeout.settingRange.upperBound)
        }
        return health
    }

    /// `POST /v1/warm`: a press became a dictation, and the Neo gets the speech model it will ask for (`model`; nil
    /// is `auto`) ready while the user is still speaking. The hub answers at once, whatever its worker does. Fire and
    /// forget: nothing waits for it or depends on it, so it is never sent again and gets only the ping's short
    /// budget. False: the hub is from before the route (its 404), and a device may stop asking for a while; any
    /// other failure throws as any call does.
    @discardableResult
    public func warm(model: HubASRModel?) async throws -> Bool {
        do {
            let _: HubOK = try await send(json("POST", HubPath.warm, WarmRequest(asrModel: model), budget: timeouts.ping,
                                               repeatable: false))
            return true
        } catch HubError.server(404, _) {
            return false
        }
    }

    /// `POST /v1/dictations`: the recording, recognised and polished on the hub.
    public func dictate(audio: Data, type: HubAudioType, request: DictationRequest) async throws -> DictationResult {
        guard audio.count <= Hub.maxAudioBytes else { throw HubError.audioTooLarge }
        let header: String
        do {
            header = try request.headerValue()
        } catch {
            throw HubError.invalidRequest((error as? LocalizedError)?.errorDescription ?? "听写请求的格式不对")
        }
        return try await send(Call(method: "POST", path: HubPath.dictations, body: audio, contentType: type.rawValue,
                                   headers: [HubHeader.request: header],
                                   budget: timeouts.dictation(durationSeconds: request.durationSeconds, audioBytes: audio.count,
                                                              patient: request.waitsForNeo),
                                   repeatable: true, slow: true))
    }

    /// `POST /v1/dictations` with audio from `AudioUpload.encode`.
    public func dictate(_ audio: EncodedAudio, request: DictationRequest) async throws -> DictationResult {
        try await dictate(audio: audio.data, type: audio.type, request: request)
    }

    /// `POST /v1/polish`: text the device recognised itself.
    public func polish(_ request: PolishRequest) async throws -> DictationResult {
        try await send(json("POST", HubPath.polish, request, budget: timeouts.polish(characters: request.text.count),
                            repeatable: true, slow: true))
    }

    /// `POST /v1/dictations/{id}/repolish`, in `mode` or the dictation's own.
    public func repolish(id: UUID, mode: DictationMode? = nil) async throws -> DictationResult {
        try await send(json("POST", HubPath.repolish(id), RepolishRequest(mode: mode), budget: timeouts.polish(characters: nil),
                            repeatable: true, slow: true))
    }

    /// `POST /v1/dictations/{id}/edit`: the text after the user changed it; the hub learns from the change, unless
    /// `learn` is false (the device sends what it learned as observations itself).
    public func edit(id: UUID, text: String, learn: Bool = true) async throws -> EditResponse {
        // Sending the same final text twice learns nothing the second time, so it may be repeated.
        try await send(json("POST", HubPath.edit(id), EditRequest(text: text, learn: learn ? nil : false),
                            budget: timeouts.quick, repeatable: true))
    }

    /// `POST /v1/learning/observations`. Not repeated here: a hub that does not know observation ids would count
    /// the pairs twice (`flush` decides what may go again).
    /// `kind`: `.repeated` for swaps the device saw twice (`LearningObservations.kind`).
    public func observe(_ pairs: [CorrectionPair], dictationID: UUID? = nil, id: UUID? = nil,
                        kind: LearnedCorrection.Kind? = nil) async throws -> LearningObservationsResponse {
        try await send(json("POST", HubPath.learningObservations,
                            LearningObservations(pairs: pairs, dictationID: dictationID, id: id, kind: kind),
                            budget: timeouts.quick, repeatable: false))
    }

    /// `GET /v1/learning`.
    public func learning() async throws -> LearningList {
        try await send(quick("GET", HubPath.learning))
    }

    /// `DELETE /v1/learning?wrong=…`: forget a learned correction. Returns the list afterwards.
    public func forget(wrong: String) async throws -> LearningList {
        try await send(quick("DELETE", HubPath.learning, query: [("wrong", wrong)]))
    }

    /// `POST /v1/learning/forget`: forget the corrections with these `wrong`s in one request. Returns the list
    /// afterwards. Forgetting again what is gone changes nothing, so it may be repeated.
    public func forget(wrongs: [String]) async throws -> LearningList {
        try await send(json("POST", HubPath.learningForget, LearningForget(wrongs: wrongs), budget: timeouts.quick,
                            repeatable: true))
    }

    /// `GET /v1/vocabulary`.
    public func vocabulary() async throws -> VocabularySnapshot {
        try await send(quick("GET", HubPath.vocabulary))
    }

    /// `PUT /v1/vocabulary`: the whole new list. Fails with `isConflict` when it changed since `expectedRevision`.
    /// Not repeated: had the first try arrived, a second would be refused as a conflict.
    public func updateVocabulary(words: [String], expectedRevision: String) async throws -> VocabularySnapshot {
        try await send(json("PUT", HubPath.vocabulary, VocabularyUpdate(words: words, expectedRevision: expectedRevision),
                            budget: timeouts.quick, repeatable: false))
    }

    /// `GET /v1/habits`: 我的习惯 as the hub has them. A hub from before habits answers 404.
    public func habits() async throws -> HabitsSnapshot {
        try await send(quick("GET", HubPath.habits))
    }

    /// `PUT /v1/habits`: the whole new list. With `expectedRevision` it fails with `isConflict` when the list
    /// changed since, and is then not repeated (had the first try arrived, a second would be refused as a
    /// conflict); without one it replaces the list whatever it was, which is safe to send twice.
    public func updateHabits(items: [String], expectedRevision: String? = nil) async throws -> HabitsSnapshot {
        try await send(json("PUT", HubPath.habits, HabitsUpdate(items: items, expectedRevision: expectedRevision),
                            budget: timeouts.quick, repeatable: expectedRevision == nil))
    }

    /// `GET /v1/history`, newest first; `before` is the previous page's `nextBefore`.
    public func history(limit: Int = Hub.defaultHistoryLimit, before: String? = nil) async throws -> HistoryPage {
        var query = [("limit", String(min(max(1, limit), Hub.maxHistoryLimit)))]
        if let before { query.append(("before", before)) }
        return try await send(quick("GET", HubPath.history, query: query))
    }

    /// `DELETE /v1/history/{id}`. An item the hub no longer has is deleted all the same: another device took it,
    /// or the first try of a delete sent again after a dropped connection did.
    public func deleteHistory(id: UUID) async throws {
        do {
            let _: Ignored = try await send(quick("DELETE", HubPath.historyItem(id)))
        } catch HubError.server(404, let body?) where body.code == HubErrorCode.notFound {
            return
        }
    }

    /// `GET /v1/sync`: what the device keeps for when the hub cannot be reached.
    public func sync() async throws -> SyncSnapshot {
        try await send(quick("GET", HubPath.sync))
    }

    // MARK: Requests

    struct Call {
        var method: String
        var path: String
        var query: [(String, String)] = []
        var body: Data? = nil
        var contentType: String? = nil
        var headers: [String: String] = [:]
        var authorized = true
        var budget: TimeInterval
        /// Safe to send twice: sent once more when the connection drops.
        var repeatable: Bool
        /// The hub takes its time before answering (recognition, polish): reachability is checked alongside.
        var slow = false
    }

    private func quick(_ method: String, _ path: String, query: [(String, String)] = []) -> Call {
        Call(method: method, path: path, query: query, budget: timeouts.quick, repeatable: true)
    }

    private func json<T: Encodable>(_ method: String, _ path: String, _ body: T, budget: TimeInterval, repeatable: Bool,
                                    slow: Bool = false) -> Call {
        Call(method: method, path: path, body: try? HubJSON.encode(body), contentType: "application/json; charset=utf-8",
             budget: budget, repeatable: repeatable, slow: slow)
    }

    /// The request as it goes out (tests look at it).
    func urlRequest(_ call: Call, timeout: TimeInterval) -> URLRequest {
        var parts = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        var base = parts.percentEncodedPath
        while base.hasSuffix("/") { base.removeLast() }
        parts.percentEncodedPath = base + call.path
        parts.percentEncodedQuery = call.query.isEmpty ? nil
            : call.query.map { "\(HubQuery.encode($0.0))=\(HubQuery.encode($0.1))" }.joined(separator: "&")
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = call.method
        request.httpBody = call.body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let type = call.contentType { request.setValue(type, forHTTPHeaderField: "Content-Type") }
        if call.authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        // Every request, the ping too: without them Cloudflare Access stops it before the Neo.
        for (name, value) in access?.headers ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        for (name, value) in call.headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    private func send<T: Decodable>(_ call: Call) async throws -> T {
        let (data, response) = try await perform(call)
        let status = response.statusCode
        // Cloudflare Access turned it away: not the hub's answer, whatever the status.
        if HubAccessRefusal.matches(response, data: data) { throw HubError.accessDenied }
        guard (200..<300).contains(status) else {
            throw HubError.server(status: status, body: try? HubJSON.decode(HubErrorBody.self, from: data))
        }
        if T.self == Ignored.self { return Ignored() as! T }
        do {
            return try HubJSON.decode(T.self, from: data)
        } catch {
            throw HubError.badResponse
        }
    }

    /// How long Cloudflare waits for the hub's answer to begin before it gives up with a 524 of its own and closes
    /// the connection to the hub (its Proxy Read Timeout, fixed on the plans the tunnel runs on). The hub sends
    /// nothing until a dictation is done, so a long one meets this limit well inside its budget.
    public static let cloudflareWait: TimeInterval = 100
    /// At most this many tries of one call while Cloudflare reports the hub as still working: as many of
    /// Cloudflare's waits as the longest budget holds (three), and a last try.
    static let maxTries = Int((HubTimeouts.longest / cloudflareWait).rounded(.up)) + 1

    /// Sends `call` within its budget: once more after a dropped connection when it is repeatable and, for the slow
    /// ones, again while Cloudflare says the hub is still working on it (`stillWorking`).
    private func perform(_ call: Call) async throws -> (Data, HTTPURLResponse) {
        let started = Date()
        var budget = call.budget
        var resentAfterDrop = false
        var tries = 0
        while true {
            tries += 1
            let left = budget - Date().timeIntervalSince(started)
            let connect = min(timeouts.connect, left)
            let probe = call.slow ? urlRequest(Call(method: "GET", path: HubPath.ping, authorized: false, budget: connect,
                                                    repeatable: false), timeout: connect + 1) : nil
            let data: Data, response: HTTPURLResponse
            do {
                (data, response) = try await Self.exchange(urlRequest(call, timeout: left + 5), probe: probe, session: session,
                                                           connect: connect, budget: left)
            } catch HubError.connectionLost where call.repeatable && !resentAfterDrop {
                resentAfterDrop = true
                // The hub finishes what the first try started and answers the second with it, which still has to
                // send the call again: what is left of the budget may be too little for that.
                budget = max(budget, Date().timeIntervalSince(started) + timeouts.resend(bytes: call.body?.count ?? 0))
                continue
            }
            guard call.slow, call.repeatable, Self.stillWorking(status: response.statusCode, data: data) else {
                return (data, response)
            }
            // The hub goes on with the job (one per `clientRecordingID`) and answers the same call sent again with
            // its result once it is done, so ask again while the budget lasts. The hub was reached, so a budget that
            // runs out is a timeout, not a sleeping Neo.
            guard tries < Self.maxTries, budget - Date().timeIntervalSince(started) >= timeouts.connect else {
                throw HubError.timeout
            }
        }
    }

    /// Cloudflare's own 524 (no hub error body): it reached the hub, which has not answered within
    /// `cloudflareWait` because it is still working on the call.
    static func stillWorking(status: Int, data: Data) -> Bool {
        status == 524 && (try? HubJSON.decode(HubErrorBody.self, from: data)) == nil
    }

    /// One request: `.unreachable` when nothing shows the hub was reached within `connect`, `.timeout` when it
    /// outlasts `budget`. `probe` (a ping) runs alongside; its 200 is the sign for a request the hub is slow to
    /// answer, and Cloudflare Access turning it away (`HubAccessRefusal`) ends the request as `.accessDenied` at
    /// once: it carries the same credentials, so the request itself gets no further (its own answer to a large
    /// upload may come late, or as a dropped connection).
    private static func exchange(_ request: URLRequest, probe: URLRequest?, session: URLSession, connect: TimeInterval,
                                 budget: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        // With a ping, only the ping (or the answer) counts: a handshake with Cloudflare says nothing about
        // whether the hub behind it is answering.
        let watch = ConnectionWatch(handshakeCounts: probe == nil)
        let started = Date()
        // The ping reports on URLSession's own queue, so a busy task pool cannot make it look late.
        let ping = probe.map { probe in
            session.dataTask(with: probe) { data, response, _ in
                guard let http = response as? HTTPURLResponse else { return }
                // Not the hub's answer but Access's: the request alongside is stopped the same way.
                if HubAccessRefusal.matches(http, data: data ?? Data()) {
                    watch.refused()
                    return
                }
                // Only the hub's own 200.
                guard http.statusCode == 200 else { return }
                watch.reached()
            }
        }
        // Like the request itself, the ping never follows a redirect.
        ping?.delegate = RefuseRedirects.shared
        ping?.resume()
        defer { ping?.cancel() }
        do {
            let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                group.addTask { try await session.data(for: request, delegate: watch) }
                group.addTask {
                    while true {
                        try await Task.sleep(nanoseconds: 25_000_000)
                        if watch.isRefused { throw HubError.accessDenied }
                        let elapsed = Date().timeIntervalSince(started)
                        let reached = watch.connected
                        if !reached && elapsed >= connect { throw HubError.unreachable }
                        if elapsed >= budget { throw reached ? HubError.timeout : HubError.unreachable }
                    }
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            guard let http = response as? HTTPURLResponse else { throw HubError.badResponse }
            return (data, http)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // The ping alongside met Cloudflare Access: whatever ended the request, that is why.
            if watch.isRefused { throw HubError.accessDenied }
            throw map(error, reached: watch.connected)
        }
    }

    static func map(_ error: Error, reached: Bool) -> Error {
        if error is HubError || error is CancellationError { return error }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return reached ? HubError.connectionLost : HubError.unreachable }
        switch URLError.Code(rawValue: ns.code) {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return HubError.offline
        case .networkConnectionLost:
            return HubError.connectionLost
        case .timedOut:
            return reached ? HubError.timeout : HubError.unreachable
        case .cancelled:
            // The task itself was not cancelled (`exchange` checks that first): something on the way ended the
            // request, such as a network filter.
            return reached ? HubError.connectionLost : HubError.unreachable
        case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData:
            return HubError.badResponse
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            // A network that intercepts TLS (a captive portal) shows its own certificate. Its arrival looked like
            // the hub's (`ConnectionWatch`), but the request never got past it.
            return HubError.unreachable
        default:
            // DNS, refused, …
            return reached ? HubError.connectionLost : HubError.unreachable
        }
    }

    /// A body nobody reads (`DELETE /v1/history/{id}` answers `{"ok": true}` or nothing).
    struct Ignored: Decodable {
        init() {}
        init(from decoder: Decoder) throws {}
    }
}

extension HubClient: CustomReflectable {
    /// Never the token or the Access secret in a debugger's dump.
    public var customMirror: Mirror {
        Mirror(self, children: ["server": server.absoluteString, "hasAccess": hasAccess], displayStyle: .class)
    }
}

/// The hub's polish floor as its health answer said it, read and written from any thread.
final class PolishFloor: @unchecked Sendable {
    private let lock = NSLock()
    private var floor: TimeInterval?

    var value: TimeInterval? {
        get { lock.withLock { floor } }
        set { lock.withLock { floor = newValue } }
    }
}

/// Whether a request has reached the hub's side: its answer started to arrive (the response is in, the body may
/// take a while yet), the ping alongside it came back, or (when `handshakeCounts`) a new TLS connection was set
/// up for it: the server's certificate arrived, so the network works. A certificate that then fails the system's
/// check is a network in the way, which `HubClient.map` reports as unreachable.
///
/// Every sign is set on URLSession's own queue, so a busy task pool cannot make the hub look late.
final class ConnectionWatch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var reachedServer = false
    /// The ping alongside was turned away by Cloudflare Access.
    private var refusedByAccess = false
    /// Weak: the task keeps its delegate, this watch, until it is done.
    private weak var task: URLSessionTask?
    private let handshakeCounts: Bool

    init(handshakeCounts: Bool = true) {
        self.handshakeCounts = handshakeCounts
    }

    func reached() {
        lock.withLock { reachedServer = true }
    }

    func refused() {
        lock.withLock { refusedByAccess = true }
    }

    var isRefused: Bool { lock.withLock { refusedByAccess } }

    var connected: Bool {
        let (reached, task) = lock.withLock { (reachedServer, self.task) }
        // URLSession sets the response when the answer's first bytes are in; the rest of the body may take
        // seconds more on a slow link. (Per-task delegates are not told about the response itself.)
        return reached || task?.response != nil
    }

    /// The request's task, whose response `connected` looks at.
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { self.task = task }
    }

    /// The task finished. With an answer, that counts even when the timer has not looked yet.
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        if task.response != nil { reached() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if handshakeCounts, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { reached() }
        // The system checks the certificate as it would without this delegate.
        return (.performDefaultHandling, nil)
    }

    /// No redirect is followed (`RefuseRedirects`): the redirect itself is the answer.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// Hub requests never follow a redirect. The hub sends none; Cloudflare Access sends one to its login page when it
/// stops a request (`HubAccessRefusal`), and URLSession would carry the request's headers, the device token and the
/// Access secret among them, along to wherever it points. The redirect is the answer instead.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RefuseRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// Whether an answer is Cloudflare Access stopping the request in front of the hub (docs/hub.md, "Access 双重锁"),
/// instead of the hub's own. The hub's own errors always carry its JSON error body, which Access's never do. Access:
/// - a redirect to its login page (on `<team>.cloudflareaccess.com`, or a `/cdn-cgi/access/` path), what it sends by
///   default when a request has no service token or a wrong one; or an answer that came from such a host;
/// - a 401 or 403 that says it is Access's: a `cf-access-*` header, its `CF_AppSession` / `CF_Authorization` cookie,
///   or an HTML page about Cloudflare Access;
/// - a 401 from Cloudflare (its `Server` / `CF-RAY` headers), what Access sends instead of the redirect when "Return
///   401 response for Service Auth policies" is on: Cloudflare's other blocks are 403s, 429s or challenges.
/// A 403 page of Cloudflare's firewall or of a network on the way is not (`HubError.server(403, nil)`).
public enum HubAccessRefusal {
    public static func matches(_ response: HTTPURLResponse, data: Data) -> Bool {
        if isAccessHost(response.url) { return true }
        let status = response.statusCode
        guard (300...399).contains(status) || status == 401 || status == 403 else { return false }
        // The hub's own answer, whatever it says.
        if (try? HubJSON.decode(HubErrorBody.self, from: data)) != nil { return false }
        switch status {
        case 300...399:
            guard let location = response.value(forHTTPHeaderField: "Location"),
                  let target = URL(string: location, relativeTo: response.url)?.absoluteURL else { return false }
            return isAccessHost(target) || target.path.lowercased().contains("/cdn-cgi/access/")
        case 401, 403:
            let names = response.allHeaderFields.keys.compactMap { ($0 as? String)?.lowercased() }
            if names.contains(where: { $0.hasPrefix("cf-access") }) { return true }
            if let cookie = response.value(forHTTPHeaderField: "Set-Cookie"),
               cookie.contains("CF_AppSession") || cookie.contains("CF_Authorization") { return true }
            let page = String(decoding: data.prefix(64 * 1024), as: UTF8.self).lowercased()
            if page.contains("cloudflareaccess.com") || page.contains("/cdn-cgi/access") || page.contains("cloudflare access") {
                return true
            }
            return status == 401 && fromCloudflare(response)
        default:
            return false
        }
    }

    /// `cloudflareaccess.com` or one of its hosts (a team's login page).
    static func isAccessHost(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "cloudflareaccess.com" || host.hasSuffix(".cloudflareaccess.com")
    }

    static func fromCloudflare(_ response: HTTPURLResponse) -> Bool {
        response.value(forHTTPHeaderField: "Server")?.lowercased() == "cloudflare"
            || response.value(forHTTPHeaderField: "CF-RAY") != nil
    }
}
