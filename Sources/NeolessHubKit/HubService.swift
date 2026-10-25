import Foundation
import NeolessCloud
import NeolessCore

/// Everything the hub does, without HTTP: `HubServer` routes requests here. One instance per process, on the
/// main actor (the ChatGPT login lives there); decoding and recognition run elsewhere and are awaited.
@MainActor
public final class HubService {
    /// Told to devices (`GET /v1/health`). Raised whenever the hub's learning rules change: a device then
    /// offers it once more the corrections it turned down before (`HubLearning.resend`).
    public nonisolated static let version = "1.4.0"

    public let folder: HubDataFolder
    public let devices: DeviceRegistry
    public let words: WordStore
    public let history: HubHistory
    private let configFile: WatchedFile<HubConfig>
    private let asr: ASRRecognizing
    /// How long recognition may take when the device's own transcript can stand in (`ASRWorker.impatientTimeout`).
    var impatientTimeout: @Sendable (Double) -> TimeInterval = ASRWorker.impatientTimeout
    /// What such a recognition gets on top while a model load may be under way (`mayBeLoading`).
    var loadAllowance: TimeInterval = HubTimeouts.standInLoad
    private let polisher: HubPolishing
    private let now: () -> Date
    private var limiter: RateLimiter

    /// Dictations and polishes being worked on, by `clientRecordingID`. Not tied to any request: a dropped
    /// connection (or Cloudflare's 524) does not stop them, and the same id asked again waits for the same job.
    private var running: [UUID: Task<DictationResult, Error>] = [:]
    /// Finished results by `clientRecordingID`, newest last (bounded); history is asked first.
    private var recent: [UUID: DictationResult] = [:]
    private var recentOrder: [UUID] = []
    static let recentLimit = 256
    /// Repolishes being worked on, by dictation id and mode.
    private var repolishing: [String: Task<DictationResult, Error>] = [:]
    /// How many times each dictation's text was edited (`…/edit`), by its id: a repolish that sees a new edit
    /// when ChatGPT answers keeps the user's text.
    private var edits: [UUID: Int] = [:]
    /// What the edits of a dictation are compared with (`EditTracker`: the text as the hub delivered it, moved on
    /// only by what an edit taught), for dictations edited since the hub started, newest last (bounded). So the
    /// wrong side of what an edit teaches is always text the hub typed, never what the user typed on the way.
    private var trackers: [UUID: EditTracker] = [:]
    private var trackerOrder: [UUID] = []
    /// Requests waiting for a job another request started (for tests and the log).
    private(set) var joined = 0
    /// When each device's last warm-up went to the worker (`warm(device:request:)`), by token hash.
    private var warmed: [String: Date] = [:]
    /// The last warm-up passed to the worker, which it may still be taking (for tests).
    private(set) var lastWarm: Task<Void, Never>?
    /// When the last warm-up went to the worker, unless the worker answered that the model was in memory already:
    /// a model load may be under way from then on (`mayBeLoading`).
    private var loadAskedAt: Date?

    /// - Parameters:
    ///   - asr: the ASR worker client.
    ///   - polisher: ChatGPT; nil uses the hub's own login (`ChatGPTPolisher`).
    ///   - rateLimit: requests per device per minute.
    /// Short, plain transcripts are tidied here instead of being sent to ChatGPT (`QuickTidy`). Tests about the
    /// polish request itself turn it off.
    public var quickTidy = true

    public init(folder: HubDataFolder, asr: ASRRecognizing, polisher: HubPolishing? = nil,
                rateLimit: Int = Hub.requestsPerMinute, now: @escaping () -> Date = Date.init) {
        self.folder = folder
        self.asr = asr
        self.now = now
        devices = DeviceRegistry(folder: folder)
        words = WordStore(store: folder.store, now: now)
        history = HubHistory(store: folder.store)
        let configFile = WatchedFile(store: folder.store, name: HubDataFolder.File.settings, fallback: HubConfig())
        self.configFile = configFile
        limiter = RateLimiter(limit: rateLimit, window: 60)
        self.polisher = polisher ?? ChatGPTPolisher(store: folder.store, config: { configFile.value })
        // The observations answered before this start: one of them sent again is still not counted twice.
        let before = folder.store.read(Observed.self, from: Self.observedFile)?.seen ?? []
        for seen in before.suffix(Self.recentLimit) {
            observed[seen.id] = LearningObservationsResponse(accepted: seen.accepted, id: seen.id)
            observedOrder.append(seen.id)
        }
    }

    public var config: HubConfig { configFile.value }

    // MARK: - Access

    /// Which of a device's rate limits a request counts against: dictations (recording, polish, repolish) have their
    /// own, so a device's background syncing never leaves its next dictation a 429; and so do warm-ups
    /// (`POST /v1/warm`), one for each press that becomes a dictation, so a burst of presses never uses up what the
    /// dictations themselves or the syncing need.
    public enum RequestKind: String, Sendable {
        case dictation, other, warm

        /// The kind of a route (`HubPath`, or the router's pattern such as "/v1/dictations/:id/repolish").
        public static func of(route: String) -> RequestKind {
            if route == HubPath.warm { return .warm }
            return route == HubPath.dictations || route == HubPath.polish || route.hasSuffix("/repolish") ? .dictation : .other
        }
    }

    /// The device a request comes from, counted against its rate limit for `kind`. Throws 401 (no or unknown
    /// token), 403 (revoked) or 429.
    public func authorize(_ authorization: String?, kind: RequestKind = .other) throws -> HubDevice {
        let device = try identify(authorization)
        try admit(device, kind: kind)
        return device
    }

    /// With `requireAccess` on, a request must carry the `Cf-Access-Jwt-Assertion` Cloudflare Access adds to what it
    /// lets through: 403 `access_required` otherwise. Only whether it is there, never its signature: anyone can send
    /// such a header, so this is no lock. It only tells honest devices, plainly and at once, that Access is not in
    /// front of the hub (the application deleted or not covering the request) instead of them going on with the
    /// device token alone. The lock is Access at the edge; the device token is the second one.
    public func checkAccess(jwt: String?) throws {
        guard config.requireAccess else { return }
        guard let jwt, !jwt.trimmingCharacters(in: .whitespaces).isEmpty else { throw HubFailure.accessRequired }
    }

    /// The paired device whose token this is. Throws 401 (no or unknown token) or 403 (revoked).
    public func identify(_ authorization: String?) throws -> HubDevice {
        guard let token = Self.bearerToken(authorization) else { throw HubFailure.unauthorized }
        switch devices.lookup(token: token) {
        case .unknown: throw HubFailure.unauthorized
        case .revoked: throw HubFailure.forbidden
        case .device(let device): return device
        }
    }

    /// Counts a request of `device` against its limit for `kind`. Throws 429 when it is over.
    public func admit(_ device: HubDevice, kind: RequestKind) throws {
        guard limiter.allow("\(device.tokenHash)|\(kind.rawValue)", now: now()) else { throw HubFailure.rateLimited }
        devices.touch(device, now: now())
    }

    static func bearerToken(_ header: String?) -> String? {
        guard let header else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    // MARK: - Health

    public func health(device: HubDevice) async -> HubHealth {
        let worker = await asr.health()
        return HubHealth(version: Self.version,
                         asr: worker?.forDevices ?? HubHealth.ASR(ready: false, model: ASRWorker.defaultModel),
                         chatgpt: polisher.health, device: device.name,
                         polishTimeout: config.polishOptions.minimumTimeout,
                         polishModels: PolishModel.all.map(\.id))
    }

    // MARK: - Warm-up

    /// `POST /v1/warm`: a press of `device` became a dictation; its recording will follow in a few seconds. The worker
    /// is asked to get the model that recording will use ready (`request.asrModel`; `auto` is whatever the worker uses
    /// now, the small model while the large one rests), so the recording does not wait for it to load, and the idle
    /// clock that unloads it starts again. Returns at once: the worker is asked in the background and nothing waits
    /// for it. At most one warm-up per device goes to the worker in `Hub.warmSpacing`; the others are answered all
    /// the same. Returns whether this one went to the worker.
    ///
    /// Until the worker answers that the model was in memory already, a load is taken to be under way: a recording
    /// whose transcript can stand in then gets `loadAllowance` more (`mayBeLoading`), so the recording that arrives
    /// while the model loads is not given up on for the load.
    @discardableResult
    public func warm(device: HubDevice, request: WarmRequest) -> Bool {
        let time = now()
        if let last = warmed[device.tokenHash], time.timeIntervalSince(last) < Hub.warmSpacing, time >= last { return false }
        warmed[device.tokenHash] = time
        loadAskedAt = time
        let asr = self.asr, model = request.asrModel ?? .auto
        lastWarm = Task.detached(priority: .userInitiated) { [weak self] in
            guard await asr.warm(model: model) == true else { return }
            await self?.modelWasInMemory(warmedAt: time)
        }
        return true
    }

    /// The worker answered the warm-up sent at `time`: the model was in memory, nothing loads.
    private func modelWasInMemory(warmedAt time: Date) {
        if loadAskedAt == time { loadAskedAt = nil }
    }

    /// Whether a model load a warm-up asked for may still be under way at `time`: less than
    /// `HubTimeouts.standInLoadWindow` since, and the worker did not say the model was in memory. An older worker,
    /// without `/warm`, loads on the recognition itself: also a load that may be under way.
    func mayBeLoading(at time: Date) -> Bool {
        guard let asked = loadAskedAt else { return false }
        let since = time.timeIntervalSince(asked)
        return since >= 0 && since < HubTimeouts.standInLoadWindow
    }

    /// Returns once no ChatGPT login refresh is running (one a polish timed out on): `serve` calls it before
    /// the process exits, so a rotated refresh token is saved first.
    public func waitForRefresh() async {
        await polisher.waitForRefresh()
    }

    // MARK: - Dictation and polish

    /// `POST /v1/dictations`.
    public func dictate(audio: Data, type: HubAudioType, request: DictationRequest) async throws -> DictationResult {
        try Self.checkLengths(texts: [request.localTranscript],
                              names: [request.appName, request.bundleID, request.clientVersion])
        return try await once(request.clientRecordingID, polishing: false) { [unowned self] in
            try await self.runDictation(audio: audio, type: type, request: request)
        }
    }

    /// `POST /v1/polish`.
    public func polish(_ request: PolishRequest) async throws -> DictationResult {
        try Self.checkLengths(texts: [request.text], names: [request.appName, request.bundleID, request.clientVersion])
        return try await once(request.clientRecordingID, polishing: true) { [unowned self] in
            let start = ContinuousClock.now
            return await self.finish(raw: request.text.trimmingCharacters(in: .whitespacesAndNewlines), recognizer: .local,
                                     mode: request.effectiveMode, clientRecordingID: request.clientRecordingID,
                                     about: Origin(appName: request.appName, bundleID: request.bundleID, client: request.client,
                                                   clientVersion: request.clientVersion,
                                                   durationSeconds: request.durationSeconds),
                                     options: self.config.polishOptions(model: request.polishModel, fastTier: request.fastTier),
                                     timings: HubTimings(), start: start)
        }
    }

    /// Runs `work` once per recording: a finished result is returned as it is, a running job is waited for.
    /// A result with an empty `raw` does not hold the id: the device's own transcript (`/v1/polish`) follows.
    private func once(_ id: UUID, polishing: Bool,
                      _ work: @escaping @MainActor () async throws -> DictationResult) async throws -> DictationResult {
        while true {
            if let done = finished(id) { return done }
            guard let job = running[id] else { break }
            let result = try await join(job)
            if !polishing || !result.raw.isEmpty { return result }
        }
        let job = Task { @MainActor [weak self] () throws -> DictationResult in
            defer { self?.running[id] = nil }
            let result = try await work()
            if !result.raw.isEmpty { self?.remember(result) }
            return result
        }
        running[id] = job
        return try await job.value
    }

    private func join(_ job: Task<DictationResult, Error>) async throws -> DictationResult {
        joined += 1
        defer { joined -= 1 }
        return try await job.value
    }

    /// The result already made for this recording: its history entry as it is now (edited, polished again),
    /// or the result kept in memory.
    private func finished(_ id: UUID) -> DictationResult? {
        history.entry(clientRecordingID: id)?.result ?? recent[id]
    }

    private func remember(_ result: DictationResult) {
        if recent.updateValue(result, forKey: result.clientRecordingID) == nil { recentOrder.append(result.clientRecordingID) }
        while recentOrder.count > Self.recentLimit { recent[recentOrder.removeFirst()] = nil }
    }

    private func forget(clientRecordingID id: UUID) {
        recent[id] = nil
        recentOrder.removeAll { $0 == id }
    }

    /// What the history keeps about where a dictation came from.
    struct Origin {
        var appName: String?
        var bundleID: String?
        var client: HubClientKind?
        var clientVersion: String?
        var durationSeconds: Double?
    }

    private func runDictation(audio: Data, type: HubAudioType, request: DictationRequest) async throws -> DictationResult {
        let start = ContinuousClock.now
        var timings = HubTimings()
        var raw = ""
        var problem: HubFailure?
        do {
            let prepared = try await AudioPrep.workerWAV(from: audio, type: type)
            timings.decodeMs = Self.ms(since: start)
            if prepared.seconds > 0 {
                let asrStart = ContinuousClock.now
                do {
                    let asr = self.asr, wav = prepared.wav, hints = words.recognizerHints, seconds = prepared.seconds
                    // The speech model the device asked for; an older device asks for none, which is `auto`.
                    let model = request.asrModel ?? .auto
                    let heard: ASRWorkerResult
                    if (request.localTranscript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        heard = try await asr.recognize(wav: wav, hints: hints, audioSeconds: seconds, model: model)
                    } else {
                        // The device heard it too: a busy Neo is not waited for (the worker finishes on its own). A
                        // model load a warm-up asked for may still be under way: that is waited for on top.
                        let wait = impatientTimeout(seconds) + (mayBeLoading(at: now()) ? loadAllowance : 0)
                        heard = try await ASRWorkerClient.deadline(wait) {
                            try await asr.recognize(wav: wav, hints: hints, audioSeconds: seconds, model: model)
                        }
                    }
                    raw = heard.raw.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    problem = Self.failure(forASR: error)
                    HubLog.write("asr: \(Self.describe(error))")
                }
                timings.asrMs = Self.ms(since: asrStart)
            }
        } catch AudioPrep.Failure.tooLong {
            timings.decodeMs = Self.ms(since: start)
            problem = .audioTooLong
        } catch {
            timings.decodeMs = Self.ms(since: start)
            problem = .decodeFailed
        }
        var recognizer = HubRecognizer.qwen3ASR
        let local = request.localTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty, !local.isEmpty {
            // The hub heard nothing (or could not listen): the device's own transcript, so no words are lost.
            raw = local
            recognizer = .local
        } else if let problem {
            throw problem
        }
        return await finish(raw: raw, recognizer: recognizer, mode: request.effectiveMode,
                            clientRecordingID: request.clientRecordingID,
                            about: Origin(appName: request.appName, bundleID: request.bundleID, client: request.client,
                                          clientVersion: request.clientVersion, durationSeconds: request.durationSeconds),
                            options: config.polishOptions(model: request.polishModel, fastTier: request.fastTier),
                            timings: timings, start: start)
    }

    /// Polishes `raw` with `options` (or types it as is, with the confirmed corrections), saves it and returns the
    /// result. An empty `raw` is returned as it is and not saved.
    private func finish(raw: String, recognizer: HubRecognizer, mode: DictationMode, clientRecordingID: UUID,
                        about: Origin, options: PolishOptions, timings: HubTimings,
                        start: ContinuousClock.Instant) async -> DictationResult {
        var timings = timings
        var text = raw
        var polished = false
        var fallback: HubFallback?
        var quick = false
        if !raw.isEmpty {
            if mode.polishes, quickTidy, QuickTidy.applies(to: raw) {
                // Short and plain: tidied here, without the 2.5–4 s a ChatGPT request takes (`QuickTidy`).
                text = QuickTidy.tidy(words.applyConfirmed(raw), habits: words.habits.items)
                polished = true
                quick = true
            } else if mode.polishes {
                let polishStart = ContinuousClock.now
                do {
                    text = try await polisher.polish(raw, mode: mode, appName: about.appName, vocabulary: words.promptWords,
                                                     corrections: words.promptPairs(for: raw),
                                                     extras: words.promptExtras(for: raw), options: options)
                    polished = true
                } catch {
                    text = words.applyConfirmed(raw)
                    fallback = .polishFailed(error)
                    HubLog.write("polish: \(PolishFailure.short(error))")
                }
                timings.polishMs = Self.ms(since: polishStart)
            } else {
                text = words.applyConfirmed(raw)
            }
        }
        timings.totalMs = Self.ms(since: start)
        let result = DictationResult(clientRecordingID: clientRecordingID, raw: raw, text: text, mode: mode,
                                     polished: polished, fallback: fallback, recognizer: recognizer, timings: timings,
                                     createdAt: HubJSON.rounded(now()))
        guard !raw.isEmpty else { return result }
        let entry = HubHistoryEntry(result: result, appName: about.appName, bundleID: about.bundleID, client: about.client,
                                    clientVersion: about.clientVersion, durationSeconds: about.durationSeconds,
                                    polishModel: polished && !quick ? options.model : nil)
        return history.add(entry).result
    }

    /// What the device hears when the worker gave no transcript (and there is no local one): by the worker's
    /// `code`. Only audio the worker cannot read is 422, only a recording over its limit 413; everything else
    /// (`busy`, `upload_timeout`, `bad_hints`, `unsupported_type`, a worker that is down, …) is a worker problem the
    /// device may try again: 503.
    static func failure(forASR error: Error) -> HubFailure {
        switch error {
        case ASRFailure.rejected(_, "bad_audio"?), ASRFailure.rejected(_, "unsupported_audio"?): return .decodeFailed
        case ASRFailure.rejected(_, "too_long"?), ASRFailure.rejected(_, "too_large"?): return .audioTooLong
        default: return .asrUnavailable
        }
    }

    /// 413 when a text the hub would keep is over `Hub.maxTextCharacters`, or a name over `Hub.maxNameCharacters`.
    static func checkLengths(texts: [String?], names: [String?]) throws {
        if texts.contains(where: { ($0?.count ?? 0) > Hub.maxTextCharacters }) { throw HubFailure.textTooLong }
        if names.contains(where: { ($0?.count ?? 0) > Hub.maxNameCharacters }) { throw HubFailure.textTooLong }
    }

    /// For the log: what went wrong, never what was said.
    static func describe(_ error: Error) -> String {
        switch error {
        case ASRFailure.unreachable: return "worker 没有响应"
        case ASRFailure.timeout: return "worker 超时"
        case ASRFailure.rejected(let status, let code): return "worker \(status) \(code ?? "")"
        case ASRFailure.badResponse: return "worker 回答看不懂"
        default: return (error as? LocalizedError)?.errorDescription ?? String(describing: type(of: error))
        }
    }

    // MARK: - Repolish and edit

    /// `POST /v1/dictations/{id}/repolish`. No mode: the dictation's own (原样转写 is polished as 自然整理).
    /// `.raw` turns it back into the original with the confirmed corrections, without ChatGPT. Edited while
    /// ChatGPT was working: the user's text stays and is returned as it is. `polishModel` and `fastTier`: the
    /// device's 整理模型 and 快速模式 (`HubConfig.polishOptions(model:fastTier:)`; nil, the hub's own).
    public func repolish(id: UUID, mode requested: DictationMode?, polishModel: String? = nil,
                         fastTier: Bool? = nil) async throws -> DictationResult {
        guard let entry = history.entry(id: id) else { throw HubFailure.notFound }
        let mode = requested ?? (entry.result.mode.polishes ? entry.result.mode : .natural)
        let options = config.polishOptions(model: polishModel, fastTier: fastTier)
        // The same dictation, mode and model asked again (a resend) waits for the one running.
        let key = "\(id.uuidString)|\(mode.rawValue)|\(options.model)|\(options.fastTier)"
        if let job = repolishing[key] { return try await join(job) }
        let job = Task { @MainActor [weak self] () throws -> DictationResult in
            defer { self?.repolishing[key] = nil }
            guard let self else { throw CancellationError() }
            return try await self.runRepolish(id: id, mode: mode, options: options)
        }
        repolishing[key] = job
        return try await job.value
    }

    private func runRepolish(id: UUID, mode: DictationMode, options: PolishOptions) async throws -> DictationResult {
        guard let entry = history.entry(id: id) else { throw HubFailure.notFound }
        let raw = entry.result.raw
        let editsBefore = edits[id, default: 0]
        var text: String
        var polishMs = 0
        if mode.polishes {
            let start = ContinuousClock.now
            do {
                text = try await polisher.polish(raw, mode: mode, appName: entry.appName, vocabulary: words.promptWords,
                                                 corrections: words.promptPairs(for: raw), extras: words.promptExtras(for: raw),
                                                 options: options)
            } catch {
                HubLog.write("repolish: \(PolishFailure.short(error))")
                throw HubFailure.polishFailed(error)
            }
            polishMs = Self.ms(since: start)
        } else {
            text = words.applyConfirmed(raw)
        }
        // Deleted while ChatGPT was working: nothing to update.
        guard var current = history.entry(id: id) else { throw HubFailure.notFound }
        // Edited meanwhile: that text was answered and learned from, so it is not replaced by one asked for before.
        guard edits[id, default: 0] == editsBefore else {
            HubLog.write("repolish: 整理期间这条被修改了，保留修改")
            return current.result
        }
        current.result.text = text
        current.result.mode = mode
        current.result.polished = mode.polishes
        current.result.fallback = nil
        current.result.timings.polishMs = polishMs
        current.result.timings.totalMs = current.result.timings.decodeMs + current.result.timings.asrMs + polishMs
        current.edited = false
        current.polishModel = mode.polishes ? options.model : nil
        history.update(current)
        // The text is the hub's own again: its edits are compared with this one from now on.
        trackers[id] = nil
        return current.result
    }

    /// `POST /v1/dictations/{id}/edit`: the user's final text. The corrections in it are learned, unless `learn`
    /// is false (the device sends what it learned as observations); sending the same text again changes nothing.
    public func edit(id: UUID, text: String, learn: Bool = true) throws -> EditResponse {
        try Self.checkLengths(texts: [text], names: [])
        guard var entry = history.entry(id: id) else { throw HubFailure.notFound }
        guard entry.result.text != text else { return EditResponse(result: entry.result, learned: []) }
        var found = Extraction()
        if learn {
            // Compared as a device compares (`EditTracker`): with the text as it was delivered, which only what an
            // edit taught moves on. A step that taught nothing (a wrong candidate typed on the way to the right
            // word) is not what the next one is compared with, or its wrong side would be the user's own typing.
            var tracker = trackers[id] ?? EditTracker(original: entry.result.text)
            // A word learned alone that the text no longer shows was taken back, or was half of a name typed
            // with a pause: it is unlearned, and the tracker compares again from before it. The same for the
            // new side of a swap that was remembered or learned as made twice.
            for word in tracker.withdrawn(from: text) {
                words.takeBack(word: word, recordID: entry.result.id)
                words.unlearnTerm(word)
            }
            switch tracker.settle(text) {
            case let .extract(inserted, edited):
                found = CorrectionExtractor().extract(inserted: inserted, edited: edited, knownTerms: Set(words.ownWords))
                // A swap an earlier edit of this dictation remembered that the text no longer shows (a word
                // typed in two halves, a swap changed back) is taken back.
                words.takeBackSwaps(recordID: entry.result.id, goneFrom: found)
                if found.teaches {
                    tracker.commit(edited, over: inserted, understood: found.baseline, alone: found.alone)
                }
            case .retract:
                // Back to the delivered text: what its edits taught is taken back.
                words.takeBack(recordID: entry.result.id)
            case .none:
                break
            }
            if trackers[id] == nil { trackerOrder.append(id) }
            trackers[id] = tracker
            if trackerOrder.count > Self.recentLimit { trackers[trackerOrder.removeFirst()] = nil }
        }
        // An edit that fixed more words than one event takes is learned as several.
        var learned: [CorrectionPair] = []
        let pairs = found.pairs
        for start in stride(from: 0, to: pairs.count, by: LearningBook.maxPairsPerEvent) {
            let some = Array(pairs[start..<min(pairs.count, start + LearningBook.maxPairsPerEvent)])
            learned += words.learn(some, source: .inApp, recordID: entry.result.id)?.learned ?? []
        }
        // Words learned without a mapping: learned words of the dictionary, not the user's own. A capital given
        // to a word is only noted the first time.
        words.learn([], terms: found.terms, sightings: found.sightings, source: .inApp, recordID: entry.result.id)
        // Words typed over others that do not sound like them: remembered, and learned as hints when the same
        // swap is made in another dictation. Those learned now are told to the device with the rest.
        learned += words.learn([], candidates: found.candidates, source: .inApp, recordID: entry.result.id)?.promoted ?? []
        entry.result.text = text
        entry.edited = true
        history.update(entry)
        edits[id, default: 0] += 1
        return EditResponse(result: entry.result, learned: learned)
    }

    // MARK: - Learning, dictionary, history, sync

    /// Longest `wrong` or `right` the hub learns (the dictionary's own word limit).
    static let maxPairLength = Vocabulary.maxWordLength

    /// Answers given to observations that carried an id, newest last (bounded): one sent again gets the same
    /// answer and is not counted twice. Which ids were answered, and how many pairs each had taken, is kept on
    /// disk (`observedFile`), so that holds across a restart too; the words themselves are not kept there, so
    /// after a restart the answer has the count and leaves `refused` out, like a hub from before it named them.
    private var observed: [UUID: LearningObservationsResponse] = [:]
    private var observedOrder: [UUID] = []
    static let observedFile = "observations.json"

    /// What `observedFile` keeps: ids and counts, never a word.
    struct Observed: Codable {
        struct Seen: Codable {
            var id: UUID
            var accepted: Int
        }
        var seen: [Seen] = []
    }

    /// `POST /v1/learning/observations`: corrections the Mac saw in another app. They arrive without their text,
    /// so each pair must look like a term fix on its own (`CorrectionExtractor.strength(of:)`, with the hub's own
    /// dictionary words): a device cannot teach the hub to rewrite numbers, secrets or negations everywhere. A
    /// pair whose misheard side is everyday text (`.termOnly`: 你好 → Nio) only puts its word in the dictionary,
    /// as a learned word, never a mapping. The reverse of a pair is taken only as what it is, a count-down of a
    /// pair the hub has; it is never learned as a mapping of its own. A pair with one side empty is a word the
    /// device learned without a mapping (`"" → Nio`: the same learned word here, if it reads like a name), or
    /// took back (`Nio → ""`: the word goes, when it was here only for that). The answer names what was not taken.
    ///
    /// An observation of kind `repeated` carries swaps the device saw the user make in two dictations (米线 →
    /// 曲线): no recognition errors by the rules, so they are not judged as such, only by
    /// `CorrectionExtractor.isRepeatable`: the two words must have something in common that speaks for a slip
    /// (a character where it stands, close syllables, most of the letters), and no rule may forbid the swap
    /// (numbers, dates, negation, opposites, one person or place for another, secrets, structural words, the
    /// user's own dictionary words as the typed-over side). The hub cannot know that the device saw the swap in
    /// two dictations; this check is what it has. What passes is learned as a hint for the model
    /// (`LearnedCorrection.Kind.repeated`), never written into text without it, and no word joins the
    /// dictionary for it.
    public func observe(_ body: LearningObservations) -> LearningObservationsResponse {
        if let id = body.id, let earlier = observed[id] { return earlier }
        let extractor = CorrectionExtractor()
        let known = Set(words.ownWords)
        var pairs: [CorrectionPair] = [], terms: [String] = [], takenBack: [String] = [], refused: [CorrectionPair] = []
        /// Swaps the device saw twice (`LearningObservations.kind`): hints only.
        var twice: [CorrectionPair] = []
        let sentAsRepeated = body.kind == .repeated
        for pair in body.pairs {
            let wrong = pair.wrong.trimmingCharacters(in: .whitespacesAndNewlines)
            let right = pair.right.trimmingCharacters(in: .whitespacesAndNewlines)
            if wrong.isEmpty != right.isEmpty {
                let term = wrong.isEmpty ? right : wrong
                if term.count <= Self.maxPairLength, CorrectionExtractor.isLearnableTerm(term) {
                    if wrong.isEmpty { terms.append(term) } else { takenBack.append(term) }
                } else {
                    refused.append(pair)
                }
                continue
            }
            guard !wrong.isEmpty, !right.isEmpty, wrong != right, wrong.count <= Self.maxPairLength,
                  right.count <= Self.maxPairLength, !(wrong + right).contains(where: \.isNewline) else {
                refused.append(pair)
                continue
            }
            let candidate = CorrectionPair(wrong: wrong, right: right)
            if words.book.countsDown(candidate) {
                pairs.append(candidate)
                continue
            }
            if sentAsRepeated {
                // One the hub's own rules take as a fix (towards a word of its dictionary) is learned as
                // that. Any other is not judged as a recognition error (it does not sound alike, and the
                // device says the user made it twice), only against what no rule allows: a number, a
                // negation, an opposite, a secret.
                if extractor.strength(of: candidate, knownTerms: known) == .pair {
                    pairs.append(candidate)
                } else if extractor.isRepeatable(candidate, knownTerms: known) {
                    twice.append(candidate)
                } else {
                    refused.append(candidate)
                }
                continue
            }
            switch extractor.strength(of: candidate, knownTerms: known) {
            case .pair: pairs.append(candidate)
            case .termOnly: terms.append(right)
            case nil: refused.append(candidate)
            }
        }
        // At most `maxPairsPerEvent` of either kind together.
        let taken = Array(pairs.prefix(LearningBook.maxPairsPerEvent))
        refused += pairs.dropFirst(LearningBook.maxPairsPerEvent)
        let takenTwice = Array(twice.prefix(LearningBook.maxPairsPerEvent - taken.count))
        refused += twice.dropFirst(takenTwice.count)
        let event = words.learn(taken, terms: terms, repeated: takenTwice, source: .otherApp, recordID: body.dictationID)
        // Not counted after all: the day's new corrections are used up.
        let learned = Set(((event?.learned ?? []) + (event?.promoted ?? [])).map(LearningBook.key))
        let countedDown = Set((event?.reversed ?? []).map(LearningBook.key))
        let left = (taken + takenTwice).filter { pair in
            !learned.contains(LearningBook.key(pair))
                && !countedDown.contains(LearningBook.key(CorrectionPair(wrong: pair.right, right: pair.wrong)))
        }
        refused += left
        let added = event?.terms ?? []
        for term in takenBack { words.unlearnTerm(term) }
        let answer = LearningObservationsResponse(accepted: taken.count + takenTwice.count - left.count, refused: refused,
                                                  terms: added.isEmpty ? nil : added, id: body.id)
        if let id = body.id {
            observed[id] = answer
            observedOrder.append(id)
            if observedOrder.count > Self.recentLimit { observed[observedOrder.removeFirst()] = nil }
            // After the learning book (saved by `words.learn`): an id on disk always has its count on disk.
            let seen = observedOrder.compactMap { id in observed[id].map { Observed.Seen(id: id, accepted: $0.accepted) } }
            folder.store.write(Observed(seen: seen), to: Self.observedFile)
        }
        return answer
    }

    public var learning: LearningList { words.learningList }

    /// `DELETE /v1/learning?wrong=…`. Forgetting what is already gone is not an error (a delete sent again).
    public func forgetLearning(wrong: String) -> LearningList {
        words.forget(wrong: wrong)
        return words.learningList
    }

    /// `POST /v1/learning/forget`: many at once (清空 on a device). 400 for more than `Hub.maxForgetWrongs`.
    /// `POST /v1/learning/judge`: words the user typed over others in a dictation of this hub that the rules could
    /// not tell from a change of mind. Each must be one no rule forbids (`CorrectionExtractor.isJudgeable`, with the
    /// hub's own dictionary words), and its typed-over side must be in the dictation as heard or delivered (unless
    /// the text was edited since): a device cannot have the hub ask about words it never wrote. ChatGPT is shown
    /// what the recognizer heard and what was delivered (`MisheardJudge`); what it judges misheard is learned with
    /// kind `.judged`, like a correction the rules learned. A ChatGPT failure is an error: nothing is learned and
    /// nothing is said about the words.
    public func judge(_ body: LearningJudgeRequest) async throws -> LearningJudgeResponse {
        guard let entry = history.entry(id: body.dictationID) else { throw HubFailure.notFound }
        let extractor = CorrectionExtractor()
        let known = Set(words.ownWords)
        func plain(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }
        let written = plain(entry.result.raw) + "\u{1F}" + plain(entry.result.text)
        var asked: [CorrectionPair] = [], refused: [CorrectionPair] = []
        var seen = Set<String>()
        for pair in body.pairs {
            let wrong = pair.wrong.trimmingCharacters(in: .whitespacesAndNewlines)
            let right = pair.right.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = CorrectionPair(wrong: wrong, right: right)
            guard asked.count < MisheardJudge.maxPairs, wrong.count <= Self.maxPairLength, right.count <= Self.maxPairLength,
                  seen.insert(LearningBook.key(candidate)).inserted,
                  entry.edited || written.contains(plain(wrong)),
                  extractor.isJudgeable(candidate, knownTerms: known) else {
                refused.append(pair)
                continue
            }
            asked.append(candidate)
        }
        guard !asked.isEmpty else { return LearningJudgeResponse(notMisheard: refused) }
        let misheard: [CorrectionPair]
        do {
            misheard = try await polisher.judge(heard: entry.result.raw, delivered: entry.result.text, pairs: asked,
                                                options: config.polishOptions)
        } catch {
            HubLog.write("judge: \(PolishFailure.short(error))")
            throw HubFailure.polishFailed(error)
        }
        let yes = Set(misheard.map(LearningBook.key))
        let event = words.learn([], judged: asked.filter { yes.contains(LearningBook.key($0)) }, source: .otherApp,
                                recordID: body.dictationID)
        let learned = Set((event?.learned ?? []).map(LearningBook.key))
        HubLog.write("judge: \(asked.count) asked, \(yes.count) misheard, \(learned.count) learned")
        return LearningJudgeResponse(learned: asked.filter { learned.contains(LearningBook.key($0)) },
                                     overLimit: asked.filter { yes.contains(LearningBook.key($0)) && !learned.contains(LearningBook.key($0)) },
                                     notMisheard: asked.filter { !yes.contains(LearningBook.key($0)) } + refused)
    }

    public func forgetLearning(_ body: LearningForget) throws -> LearningList {
        guard body.wrongs.count <= Hub.maxForgetWrongs else { throw HubFailure.badRequest("一次最多忘记 \(Hub.maxForgetWrongs) 条") }
        words.forget(wrongs: body.wrongs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        return words.learningList
    }

    public var vocabulary: VocabularySnapshot { words.snapshot }

    public func updateVocabulary(_ update: VocabularyUpdate) throws -> VocabularySnapshot {
        try words.replace(words: update.words, expectedRevision: update.expectedRevision)
    }

    public func historyPage(limit: Int, before: Date?) -> HistoryPage {
        history.page(limit: min(max(1, limit), Hub.maxHistoryLimit), before: before)
    }

    public func deleteHistory(id: UUID) throws {
        guard let gone = history.delete(id: id) else { throw HubFailure.notFound }
        forget(clientRecordingID: gone.result.clientRecordingID)
        edits[id] = nil
        trackers[id] = nil
    }

    /// `GET /v1/habits`.
    public var habits: HabitsSnapshot { words.habitsSnapshot }

    /// `PUT /v1/habits`: 409 when `expectedRevision` is given and the list changed since.
    public func updateHabits(_ update: HabitsUpdate) throws -> HabitsSnapshot {
        try words.replaceHabits(update.items, expectedRevision: update.expectedRevision)
    }

    public var sync: SyncSnapshot {
        SyncSnapshot(vocabulary: words.snapshot, learning: words.learningList, settings: config.settings,
                     habits: words.habitsSnapshot)
    }

    // MARK: - Helpers

    nonisolated static func ms(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// One line per event on standard output (the LaunchAgent's log file). Never a transcript, a text or a token.
public enum HubLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sink: @Sendable (String) -> Void = { line in
        print(line)
        fflush(stdout)
    }

    /// Tests silence or collect the log.
    public static func setSink(_ sink: @escaping @Sendable (String) -> Void) {
        lock.withLock { self.sink = sink }
    }

    public static func write(_ message: String) {
        let sink = lock.withLock { self.sink }
        sink("\(HubJSON.string(from: Date())) \(message)")
    }

    /// "POST /v1/dictations 200 1234ms iPhone".
    public static func request(method: String, route: String, status: Int, ms: Int, device: String?) {
        write("\(method) \(route) \(status) \(ms)ms \(device ?? "-")")
    }
}
