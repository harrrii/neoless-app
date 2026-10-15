import Foundation
import NeolessCore

// What a device does around the hub's calls (docs/hub.md): how long someone waits, what the status says, what a
// dictation does with the hub's answer or its failure, and the changes made on the device that the hub has not
// got yet. The Mac app uses all of it; the iPhone app can use the same.

// MARK: - Waiting

extension HubTimeouts {
    /// The longest a device where someone waits for the text gives one call.
    public static let interactiveCap: TimeInterval = 90

    /// For a device where someone waits for the text (the Mac app): the standard budgets, but no call waits longer
    /// than `interactiveCap`, so a Neo that was reached but stalls is given up on before Cloudflare's own wait
    /// (`HubClient.cloudflareWait`) and the device uses its own result.
    public static let interactive = HubTimeouts(cap: interactiveCap)
}

// MARK: - Warm-up

/// When a device asks the Neo to get its speech model ready (`HubClient.warm`): for a press that becomes a dictation
/// through the Neo, at most once in `Hub.warmInterval` (the model stays in memory for ten idle minutes once loaded,
/// so a burst of presses is one request), and, after a hub answered that it does not know the route (a hub from
/// before it), not again for `unsupportedPause`. Times are seconds of a clock that only goes forward (the system's
/// uptime), so a change of the wall clock never stops it.
public struct HubWarmGate: Equatable, Sendable {
    /// How long a device leaves a hub that does not know `POST /v1/warm` alone before it asks again (it may have been
    /// updated since).
    public static let unsupportedPause: TimeInterval = 10 * 60

    private var next: TimeInterval?

    public init() {}

    /// Whether to ask now. If so, the next one is not before `Hub.warmInterval` from now.
    public mutating func take(at now: TimeInterval) -> Bool {
        if let next, now < next { return false }
        next = now + Hub.warmInterval
        return true
    }

    /// The hub answered a warm-up; `supported` false: it does not know the route.
    public mutating func answered(supported: Bool, at now: TimeInterval) {
        guard !supported else { return }
        next = max(next ?? now, now + Self.unsupportedPause)
    }
}

// MARK: - Pairing input

extension HubPairing {
    /// The server address as someone types it ("hub.example.com", "https://hub.example.com/"), normalised
    /// as a pairing keeps it; nil when it is not an https address (http only for this Mac itself).
    public static func server(from text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var parts = URLComponents(string: text) else { return nil }
        // Host names are not case-sensitive: one spelling, so the same Neo is never two.
        parts.host = parts.host?.lowercased()
        return parts.url.flatMap(normalize)
    }

    /// What was pasted into the pairing field: a `neoless://pair?…` link, or a bare device token, which pairs with
    /// `server` under `name`. A link without a name gets `name` too. A link brings its own address; a bare token
    /// with no `server` (nothing typed in the address field) is `HubProtocolError.noServer`: there is no default hub.
    public init(pasted text: String, server: URL?, name: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix(Self.scheme + ":") {
            try self.init(link: text)
            if self.name.isEmpty { self.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
        } else if HubToken.isWellFormed(text) {
            guard let server else { throw HubProtocolError.noServer }
            try self.init(server: server, token: text, name: name)
        } else {
            throw HubProtocolError.notPairingText
        }
    }
}

// MARK: - Status

/// What a device says about its link to the Neo: the Settings row, the sidebar line and the menu bar.
public enum HubStatus: Equatable, Sendable {
    /// 用 Neo 处理 is off.
    case off
    /// On, but this device is not paired.
    case unpaired
    /// Paired; not checked yet, or being checked.
    case checking
    /// The Neo answered `GET /v1/health`.
    case connected(HubHealth)
    /// The last call did not reach the Neo; the reason as `HubError` words.
    case unreachable(String)
    /// The Neo no longer takes this device's token: pair again.
    case revoked
    /// Cloudflare Access (双重锁) stops this device's requests before they reach the Neo: its pairing has no
    /// service token, or not the current one. Pair again with a new link from the Neo.
    case accessDenied
    /// The Neo answered, but takes only requests that came through Cloudflare Access (`requireAccess`), and this
    /// one did not: Access in front of it is off or does not cover the request. To be fixed on Cloudflare (or with
    /// `neoless-hub access require off`); pairing again does not help.
    case accessRequired

    /// The Settings status row.
    public var text: String {
        switch self {
        case .off: return "已关闭，用本机处理"
        case .unpaired: return "还没配对"
        case .checking: return "正在连接 Neo…"
        case .connected(let health):
            if !health.asr.ready { return "已连接 · Neo 的识别暂时不可用" }
            if !health.chatgpt.ready { return "已连接 · Neo 上的 ChatGPT 不可用" }
            return "已连接 · 识别和整理都正常"
        case .unreachable: return Self.unreachableText
        case .revoked: return "配对已失效，请重新配对"
        case .accessDenied: return "Cloudflare 门禁没放行"
        case .accessRequired: return "Neo 只收经过 Cloudflare 门禁的请求"
        }
    }

    /// The line under the status row: what is behind it, when there is more to say.
    public var detail: String? {
        switch self {
        case .connected(let health):
            // The worker's last model load failed; the next dictation tries again. Meanwhile the Neo polishes the
            // transcript this device sends along, or this device does it all.
            if !health.asr.ready { return "暂时用这台设备的识别结果，Neo 照常整理" }
            if !health.chatgpt.ready {
                // `problem` is the cause alone ("Neo 还没登录 ChatGPT"); what it means is said here.
                let problem = health.chatgpt.problem?.trimmingCharacters(in: CharacterSet(charactersIn: "。 \n"))
                let why = problem.flatMap { $0.isEmpty ? nil : $0 } ?? "Neo 上没有登录 ChatGPT"
                return why + "。识别照常，整理用这台设备的 ChatGPT"
            }
            return nil
        case .unreachable(let reason):
            // "连不上 Neo" says nothing more than the row; "没有网络" or "Neo 没有响应…" does.
            return reason == HubError.unreachable.errorDescription ? nil : reason
        case .revoked: return "Neo 不再接受这台设备的密钥，在 Neo 上重新生成配对链接"
        case .accessDenied: return Self.accessDeniedDetail
        case .accessRequired: return Self.accessRequiredDetail
        default: return nil
        }
    }

    /// The sidebar's short line about the Neo, or nil when the Neo is not in use.
    public var short: String? {
        switch self {
        case .off, .unpaired: return nil
        case .checking: return "正在连接 Neo…"
        case .connected(let health):
            if !health.asr.ready { return "Neo 识别暂时不可用" }
            if !health.chatgpt.ready { return "Neo 上的 ChatGPT 不可用" }
            return "用 Neo 处理"
        case .unreachable: return Self.unreachableText
        case .revoked: return "Neo 配对已失效"
        case .accessDenied: return "Cloudflare 门禁没放行"
        case .accessRequired: return Self.accessRequiredShort
        }
    }

    /// Something the user may want to know about (out of reach, revoked, or the Neo cannot do its part): soft,
    /// since the device does the work itself meanwhile.
    public var isProblem: Bool {
        switch self {
        case .off, .unpaired, .checking: return false
        case .connected(let health): return !health.asr.ready || !health.chatgpt.ready
        case .unreachable, .revoked, .accessDenied, .accessRequired: return true
        }
    }

    /// For the menu-bar warning (`ServiceHealth`).
    public var serviceFact: ServiceFacts.Hub {
        switch self {
        case .off, .unpaired: return .off
        case .checking: return .connected
        case .connected(let health):
            if !health.asr.ready { return .cannotRecognize }
            return health.chatgpt.ready ? .connected : .cannotPolish
        case .unreachable: return .unreachable
        case .revoked: return .revoked
        case .accessDenied: return .accessDenied
        case .accessRequired: return .accessRequired
        }
    }

    /// The Neo does all the work: it is in use, not known to be out of reach or to refuse this device, and it can
    /// both recognise and polish. The device's own ChatGPT login matters only when this is false: a Neo that
    /// cannot recognise leaves some dictations to the device, and a Neo whose ChatGPT is down types the original,
    /// which the device then polishes with its own login.
    public var covers: Bool {
        switch self {
        case .checking: return true
        case .connected(let health): return health.asr.ready && health.chatgpt.ready
        case .off, .unpaired, .unreachable, .revoked, .accessDenied, .accessRequired: return false
        }
    }

    /// The Neo recognises the recordings (the home page says "Neo 识别"): in use, not known to be out of reach or
    /// to refuse this device, and its recognition is up.
    public var recognizes: Bool {
        switch self {
        case .checking: return true
        case .connected(let health): return health.asr.ready
        case .off, .unpaired, .unreachable, .revoked, .accessDenied, .accessRequired: return false
        }
    }

    public static let unreachableText = "连不上 Neo，用本机处理"
    /// What `accessDenied` says under the status row: why. The Neo may be fine, only the way to it is closed; the
    /// fix (a new pairing link) is the device's to offer next to it.
    public static let accessDeniedDetail = "请求在 Cloudflare 就被拦下了，没到 Neo：这台设备没有现在的门禁凭据"
    /// What `accessRequired` says in a few words (the sidebar, the menu bar, a dictation's note).
    public static let accessRequiredShort = "Cloudflare 门禁没设好"
    /// What `accessRequired` says under the status row: the Neo is there, the gate in front of it is not.
    public static let accessRequiredDetail = "请求没经过门禁就到了 Neo：检查 Cloudflare 上的 Access 设置。重新配对没用"

    /// How a failed call changes what is known about the Neo: refused the token (revoked), stopped by Cloudflare
    /// Access in front of it (accessDenied), refused because it did not come through Access (accessRequired), not
    /// reached (unreachable, with the reason), or nothing (it answered, with an error or slowly).
    public static func after(_ error: Error) -> HubStatus? {
        guard let error = error as? HubError else { return nil }
        if error.needsPairing { return .revoked }
        switch error {
        case .accessDenied:
            return .accessDenied
        case .server(403, let body?) where body.code == HubErrorCode.accessRequired:
            // The hub takes only what came through Access, and this did not: Access in front of it is off or set
            // up wrong. The Neo answered, so it is not out of reach; pairing again does not help.
            return .accessRequired
        case .offline, .unreachable, .connectionLost:
            return .unreachable(error.errorDescription ?? unreachableText)
        case .server(let status, .none) where (status >= 500 && status != 524) || status == 401 || status == 403:
            // Not the hub's answer: Cloudflare's page while the Neo sleeps or the tunnel is down, or a network
            // that turns the request away before it gets there.
            return .unreachable(error.errorDescription ?? unreachableText)
        default:
            return nil
        }
    }
}

// MARK: - Dictation

/// What a dictation does with the hub's answer, and what it notes when the device does the work itself.
extension DictationRequest {
    /// This request, asking the Neo for `model`. Nil or `.auto` leaves the choice to the Neo and says nothing, which
    /// is all a hub from before the field reads. Asking for the large model means waiting for it: this device's own
    /// transcript is left out, because a hub that has one gives a busy Neo only a short while before it polishes
    /// that instead, and the text typed would not be the large model's. The transcript still follows when the Neo
    /// hears nothing (`HubDictation.next`) or cannot listen at all (`HubDictation.transcriptFollows`).
    public func asking(for model: HubASRModel?) -> DictationRequest {
        var request = self
        request.asrModel = model == .auto ? nil : model
        if model == .large { request.localTranscript = nil }
        return request
    }

    /// The device waits for the Neo however busy it is: the request asks for the large model by name. Its call's
    /// budget covers the hub's own, longer wait for its worker
    /// (`HubTimeouts.dictation(durationSeconds:audioBytes:patient:)`).
    public var waitsForNeo: Bool { asrModel == .large }
}

extension DictationTimings {
    /// The Neo's own timings of a result (`HubTimings`), with how long this device's call for it took (`requestMs`)
    /// and an earlier call whose answer was not used (`neoWaitMs`); `waitMs` is the device's to add once the text is
    /// typed.
    public init(_ hub: HubTimings, requestMs: Int?, neoWaitMs: Int? = nil) {
        self.init(requestMs: requestMs, decodeMs: hub.decodeMs, asrMs: hub.asrMs, polishMs: hub.polishMs, totalMs: hub.totalMs,
                  neoWaitMs: neoWaitMs)
    }
}

public enum HubDictation {
    /// The dictation failed with `error`: whether this device's transcript should follow to `POST /v1/polish`
    /// under the same recording id. Only when it was held back for the large model (`DictationRequest.asking`)
    /// and the hub answered that its recognition did not work (`asr_unavailable`: the worker is down, or did not
    /// finish in the hub's own time): had the transcript come along, the hub would have polished it. The hub
    /// keeps nothing under the id of a recording that failed. Any other failure is the device's own to handle.
    public static func transcriptFollows(_ error: Error, request: DictationRequest) -> Bool {
        guard request.waitsForNeo, case .server(_, let body?)? = error as? HubError else { return false }
        return body.code == HubErrorCode.asrUnavailable
    }

    public enum Next: Equatable, Sendable {
        /// Type the hub's text.
        case use(DictationResult)
        /// The hub heard nothing and did not have this device's transcript (it was left out of the request header,
        /// `DictationRequest.headerValue`): send that to `POST /v1/polish`, same recording id.
        case polish(PolishRequest)
        /// Nothing was heard here or there.
        case nothingHeard
    }

    public static func next(_ result: DictationResult, request: DictationRequest, localTranscript: String) -> Next {
        if !result.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .use(result) }
        let local = localTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !local.isEmpty else { return .nothingHeard }
        return .polish(request.polishRequest(text: local))
    }

    /// Why the hub typed the original, said as the Neo's ("Neo 上 ChatGPT 登录已失效", "Neo 上整理超时"): signing
    /// in again on this device would not fix it.
    public static func reason(_ fallback: HubFallback) -> String {
        let reason = fallback.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return "Neo 上没有整理" }
        return reason.contains("Neo") ? reason : MixedText.join("Neo 上", reason)
    }

    /// The quiet note a dictation keeps when the device did the work itself because the hub did not:
    /// "连不上 Neo，用本机处理".
    public static func fallbackNote(_ error: Error) -> String {
        cause(error) + "，用本机处理"
    }

    /// The note when 重新整理 did not happen at all: the Neo could not do it, and this device has no ChatGPT
    /// login of its own to do it instead. "连不上 Neo，没有重新整理".
    public static func notRepolishedNote(_ error: Error) -> String {
        cause(error) + "，" + notRepolished
    }

    public static let notRepolished = "没有重新整理"

    /// The note when the hub typed the original (its ChatGPT did not polish) and this device polished it with its
    /// own login: "Neo 上 ChatGPT 登录已失效，用本机整理".
    public static func polishedHereNote(_ fallback: HubFallback) -> String {
        reason(fallback) + "，用本机整理"
    }

    /// Why the hub did not do it, in a few words: "连不上 Neo", "Neo 上整理超时".
    static func cause(_ error: Error) -> String {
        if let error = error as? HubError {
            if error.needsPairing { return "Neo 配对已失效" }
            if error == .accessDenied { return "Cloudflare 门禁没放行" }
            if case .server(403, let body?) = error, body.code == HubErrorCode.accessRequired {
                return HubStatus.accessRequiredShort
            }
            // …/repolish reached the Neo, whose ChatGPT did not polish: its reason, said as the Neo's.
            if case .server(_, let body?) = error, body.code == HubErrorCode.polishFailed {
                return reason(HubFallback(title: "", reason: body.error))
            }
            return (error.errorDescription ?? "连不上 Neo").trimmingCharacters(in: CharacterSet(charactersIn: "。 "))
        }
        if case PolishError.timeout? = error as? PolishError { return HubError.timeout.errorDescription ?? "Neo 处理超时" }
        return "Neo 出错了"
    }
}

// MARK: - Dictionary

/// A change the user made to the dictionary on a device, kept until the hub has it.
public enum VocabularyEdit: Codable, Equatable, Sendable {
    /// Words typed into the dictionary (several at once).
    case add([String])
    /// A word taken out.
    case remove(String)
}

public enum HubVocabulary {
    static func key(_ word: String) -> String { word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// `words` with `edits` applied in order, the way a device applies them to its own list: added words go to the
    /// front, a word already there moves up.
    public static func applying(_ edits: [VocabularyEdit], to words: [String], learned: [String] = []) -> [String] {
        edits.reduce(words) { list, edit in
            switch edit {
            case .add(let new): return Vocabulary.adding(new, to: list, learned: learned)
            case .remove(let word): return list.filter { key($0) != key(word) }
            }
        }
    }

    /// What the hub's dictionary needs so that it has this device's changes: a three-way comparison with `base`,
    /// the hub's words at the last sync. A word here that was not in the hub then was added here (while the Neo
    /// slept, or with 用 Neo 处理 off); a word the hub had then that is gone here was removed here. Words the hub
    /// added or removed since are left to it. Without a base (the first sync with this hub) nothing counts as
    /// removed, and the words added are this device's own that the hub lacks, so a dictionary built here is not
    /// replaced by the hub's. `localLearned`: terms in the dictionary here only because this device learned them;
    /// the hub learns those itself, from the corrections.
    public static func reconcile(local: [String], localLearned: [String], base: [String]?, hub: [String]) -> [VocabularyEdit] {
        let learned = Set(localLearned.map(key)), known = Set((base ?? hub).map(key)), here = Set(local.map(key))
        var seen = Set<String>()
        let added = local.filter { word in
            let k = key(word)
            return !k.isEmpty && !known.contains(k) && !learned.contains(k) && seen.insert(k).inserted
        }
        var edits: [VocabularyEdit] = added.isEmpty ? [] : [.add(added)]
        if let base {
            var gone = Set<String>()
            for word in base where !here.contains(key(word)) && gone.insert(key(word)).inserted { edits.append(.remove(word)) }
        }
        return edits
    }

    /// Whether `edits` give the hub words it did not have: a correction learned on the device towards one of
    /// them was judged by the hub without the word if it got there first (the outbox is flushed before the
    /// dictionaries are compared), so after such a sync the device offers what the hub lacks once more.
    public static func adds(_ edits: [VocabularyEdit]) -> Bool {
        edits.contains { edit in
            if case .add(let words) = edit { return !words.isEmpty }
            return false
        }
    }

    /// The device's dictionary after a sync: the hub's, and the terms this device learned that the hub has not put
    /// in (yet), so they still help recognition here. `localLearned`: the device's learned-only terms that are in
    /// its dictionary now.
    public static func mirrored(_ hub: VocabularySnapshot, localLearned: [String]) -> [String] {
        Vocabulary.addingLearned(localLearned, to: hub.words, learned: hub.learned)
    }
}

// MARK: - Learning

public enum HubLearning {
    /// `local` with the hub's learned corrections added, for polishing and typing on this device when the hub
    /// cannot be reached. A pair both know keeps the higher count and the later date; the hub's own pairs are
    /// kept as learned elsewhere (`.otherApp`) and never add dictionary words here.
    public static func merged(_ local: LearningBook, hub entries: [LearningEntry]) -> LearningBook {
        guard !entries.isEmpty else { return local }
        var book = local
        var index: [String: Int] = [:]
        for (i, item) in book.items.enumerated() { index[LearningBook.key(item.pair), default: i] = i }
        for entry in entries where !entry.wrong.isEmpty && !entry.right.isEmpty && entry.count > 0 {
            let key = LearningBook.key(entry.pair)
            if let i = index[key] {
                book.items[i].count = max(book.items[i].count, entry.count)
                book.items[i].lastSeen = max(book.items[i].lastSeen, entry.lastSeen)
            } else {
                index[key] = book.items.count
                book.items.append(LearnedCorrection(pair: entry.pair, count: entry.count, firstSeen: entry.lastSeen,
                                                    lastSeen: entry.lastSeen, source: .otherApp, addedTerm: false,
                                                    kind: entry.kind))
            }
        }
        return book
    }

    /// `entries` without the corrections forgotten on the device and not yet forgotten on the hub (waiting in
    /// the outbox): matched as the hub forgets them (`DELETE /v1/learning?wrong=…`), ignoring case and spacing.
    public static func without(forgotten wrongs: [String], _ entries: [LearningEntry]) -> [LearningEntry] {
        guard !wrongs.isEmpty else { return entries }
        let gone = Set(wrongs.map(fold))
        return entries.filter { !gone.contains(fold($0.wrong)) }
    }

    /// Whether the hub's list has `pair` (as `LearningBook` matches pairs).
    public static func contains(_ entries: [LearningEntry], _ pair: CorrectionPair) -> Bool {
        let key = LearningBook.key(pair)
        return entries.contains { LearningBook.key($0.pair) == key }
    }

    static func fold(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// What the hub holds of a correction the device learned.
    public enum Holding: Equatable, Sendable {
        /// Nothing: the correction is on the device only.
        case nothing
        /// Its word, in the dictionary, but not the mapping (the hub judged the misheard side everyday text).
        case wordOnly
    }

    /// The device's corrections the hub does not hold, by `LearningBook.key`, with what it holds instead: for
    /// the tag on the device's list, since the hub does the polishing. Worked out from what is kept anyway (the
    /// device's book, the hub's list and dictionary at the last sync, what still waits to go), so it is the same
    /// after a relaunch. A correction that is waiting in the outbox, or went since that sync (`pending`), is
    /// not called missing yet.
    public static func missing(from hub: [LearningEntry], hubWords: [String], book: LearningBook,
                               pending: Set<String>) -> [String: Holding] {
        let there = Set(hub.map { LearningBook.key($0.pair) })
        let words = Set(hubWords.map { $0.lowercased() })
        var out: [String: Holding] = [:]
        for item in book.items {
            let key = LearningBook.key(item.pair)
            guard !there.contains(key), !pending.contains(key) else { continue }
            out[key] = words.contains(item.pair.right.lowercased()) ? .wordOnly : .nothing
        }
        return out
    }

    /// The most corrections sent again at once (`resend`): half of what a hub's learning book takes as new
    /// in a day, so the day's fresh fixes still find room.
    public static let resendLimit = LearningBook.maxNewPerDay / 2

    /// The device's corrections the hub does not hold (`missing`), to be offered to it once more after the
    /// hub was updated: its rules may take now what they turned down before. The most recently fixed first,
    /// at most `limit`, each observation with the record the fix last came from (the hub counts a pair once
    /// per record) and an id of its own, so one whose answer is lost can go again. A swap made twice goes as
    /// one (`LearningObservations.kind`).
    public static func resend(_ book: LearningBook, missing: Set<String>, limit: Int = resendLimit) -> [LearningObservations] {
        let items = book.items.filter { missing.contains(LearningBook.key($0.pair)) }
            .sorted { $0.lastSeen > $1.lastSeen }.prefix(max(0, limit))
        return items.map { LearningObservations(pairs: [$0.pair], dictationID: $0.recordIDs.last, id: UUID(), kind: $0.kind) }
    }

    /// The device's learned corrections worth giving the hub once after pairing: the most used first, at most
    /// `limit` (the most new pairs a learning book takes in a day), as many observations as
    /// `LearningBook.maxPairsPerEvent` allows each. The swaps made twice among them go after the others, in
    /// observations of their own kind (`LearningObservations.kind`).
    public static func seed(_ book: LearningBook, limit: Int = LearningBook.maxNewPerDay) -> [LearningObservations] {
        let ranked = book.items.sorted { ($0.count, $0.lastSeen) > ($1.count, $1.lastSeen) }.prefix(max(0, limit))
        func observations(_ pairs: [CorrectionPair], kind: LearnedCorrection.Kind?) -> [LearningObservations] {
            stride(from: 0, to: pairs.count, by: LearningBook.maxPairsPerEvent).map { start in
                LearningObservations(pairs: Array(pairs[start..<min(pairs.count, start + LearningBook.maxPairsPerEvent)]), kind: kind)
            }
        }
        return observations(ranked.filter { !$0.isRepeated }.map(\.pair), kind: nil)
            + observations(ranked.filter(\.isRepeated).map(\.pair), kind: .repeated)
    }
}

// MARK: - Habits

/// 我的习惯 between a device and the hub. The device keeps its own list and polishes with it when it does the
/// work itself; the hub keeps one for the polishing it does. They are brought together at each sync.
public enum HubHabits {
    /// What a sync does about the habits.
    public enum Step: Equatable, Sendable {
        /// The same on both sides (or nothing to do).
        case keep
        /// The hub's list becomes the device's: it was changed on another device, or this device has none.
        case take([String])
        /// This list goes to the hub (`PUT /v1/habits`) and becomes the device's too: it was changed here,
        /// or on both sides, and is then both changes together.
        case send([String])
    }

    /// What `reconcile` may compare with: the hub's habits at the last sync (`last`), but only while they are
    /// still the same hub data. Nil, as at a first sync, when the hub's habits started over since
    /// (`HabitsSnapshot.generation` differs), or its whole data did (`sameDictionary` false: the dictionary's
    /// generation differs, which also tells of a hub from before habits had a generation of their own). An
    /// empty list on such a hub is a list nobody stored there: compared with a base, it would read as "another
    /// device deleted every habit", and the device would delete its own.
    public static func base(last: HabitsSnapshot?, now: HabitsSnapshot, sameDictionary: Bool) -> [String]? {
        guard let last, sameDictionary, last.generation == now.generation else { return nil }
        return last.items
    }

    /// A three-way comparison with `base`, the hub's habits at the last sync with this hub (nil at the
    /// first, and when the hub started over since: `base(last:now:sameDictionary:)`). Changed only here: the device's list goes. Changed only there: the hub's is taken. Changed
    /// on both sides: the device's list, with what the other device added put after it and what it took
    /// out left out. Without a base: whichever side has habits; with habits on both, the device's first and
    /// then the hub's others. Always within `Habits.maxItems`.
    public static func reconcile(local: [String], base: [String]?, hub: [String]) -> Step {
        let local = Habits.normalized(local), hub = Habits.normalized(hub)
        guard local != hub else { return .keep }
        func keys(_ list: [String]) -> Set<String> { Set(list.map { $0.lowercased().filter { !$0.isWhitespace } }) }
        func key(_ habit: String) -> String { habit.lowercased().filter { !$0.isWhitespace } }
        guard let base = base.map(Habits.normalized) else {
            if local.isEmpty { return .take(hub) }
            if hub.isEmpty { return .send(local) }
            let here = keys(local)
            return .send(Habits.normalized(local + hub.filter { !here.contains(key($0)) }))
        }
        if local == base { return .take(hub) }
        if hub == base { return .send(local) }
        // Both changed: this device's list, without what the other took out, and with what the other added.
        let was = keys(base), there = keys(hub), here = keys(local)
        let kept = local.filter { !was.contains(key($0)) || there.contains(key($0)) }
        let added = hub.filter { !was.contains(key($0)) && !here.contains(key($0)) }
        let merged = Habits.normalized(kept + added)
        return merged == hub ? .take(hub) : .send(merged)
    }
}

// MARK: - Outbox

/// Changes made on a device that the hub has not got yet, sent when it can be reached (`HubClient.flush`). The
/// device saves it with its data, so a change made while the Neo sleeps is not lost. (Dictionary changes need no
/// outbox: each sync compares the dictionaries, `HubVocabulary.reconcile`.)
public struct HubOutbox: Codable, Equatable, Sendable {
    public struct Edit: Codable, Equatable, Sendable {
        public var id: UUID
        public var text: String
        /// False: the hub only keeps the text (`EditRequest.learn`), because the device sends what it learned from
        /// the change as observations itself. Nil: the hub learns from it.
        public var learn: Bool?
        public init(id: UUID, text: String, learn: Bool? = nil) { self.id = id; self.text = text; self.learn = learn }
    }

    /// The most observations and edits kept: older ones are dropped first.
    public static let limit = 100
    /// The most forgotten corrections kept (newest kept): 清空 forgets every correction the device has, up to
    /// `LearningBook.maxItems`, and they go many to a request.
    public static let forgetLimit = 1_000
    /// How many `wrong`s one `POST /v1/learning/forget` carries.
    public static let forgetsPerRequest = 200
    /// The most requests a device's flushes send in a minute (`HubClient.flush(requests:)`): well under the hub's
    /// `Hub.requestsPerMinute`, which also counts the syncs and health checks; the rest waits for the next minute.
    public static let requestsPerMinute = 20

    /// Learned corrections forgotten on the device (`POST /v1/learning/forget`), oldest first.
    public var forgotten: [String] = []
    /// Corrections learned on the device (`POST /v1/learning/observations`).
    public var observations: [LearningObservations] = []
    /// The final text of dictations the user changed (`POST /v1/dictations/{id}/edit`), one per dictation.
    public var edits: [Edit] = []
    /// Observations (by `LearningObservations.id`) that were sent and got no answer: the hub may have counted
    /// them. They wait to go again, and taking one back must reach the hub too (`unlearn`).
    public var unanswered: [UUID] = []

    public init() {}

    enum CodingKeys: String, CodingKey { case forgotten, observations, edits, unanswered }

    /// A file from before `unanswered` has none.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        forgotten = try c.decodeIfPresent([String].self, forKey: .forgotten) ?? []
        observations = try c.decodeIfPresent([LearningObservations].self, forKey: .observations) ?? []
        edits = try c.decodeIfPresent([Edit].self, forKey: .edits) ?? []
        unanswered = try c.decodeIfPresent([UUID].self, forKey: .unanswered) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(forgotten, forKey: .forgotten)
        try c.encode(observations, forKey: .observations)
        try c.encode(edits, forKey: .edits)
        if !unanswered.isEmpty { try c.encode(unanswered, forKey: .unanswered) }
    }

    public var isEmpty: Bool { forgotten.isEmpty && observations.isEmpty && edits.isEmpty }

    /// Whether `pair` waits here in an observation that was sent before and got no answer.
    public func mayHaveReached(_ pair: CorrectionPair) -> Bool {
        let key = LearningBook.key(pair)
        return observations.contains { observation in
            guard let id = observation.id, unanswered.contains(id) else { return false }
            return observation.pairs.contains { LearningBook.key($0) == key }
        }
    }

    /// Only observations still waiting can be unanswered.
    private mutating func prune() {
        guard !unanswered.isEmpty else { return }
        let waiting = Set(observations.compactMap(\.id))
        unanswered.removeAll { !waiting.contains($0) }
    }

    /// Matched as the hub forgets: ignoring case and spacing (`HubLearning.fold`).
    public mutating func forget(_ wrong: String) {
        let key = HubLearning.fold(wrong)
        guard !key.isEmpty else { return }
        forgotten = Array((forgotten.filter { HubLearning.fold($0) != key } + [wrong]).suffix(Self.forgetLimit))
        // Pairs not sent yet that teach it would bring it back. (One that may have arrived is forgotten there
        // by this very request: the forgotten go first.)
        observations = Self.removing(Set([key]), from: observations)
        // A count-down of it that waits (its reverse, sent without an id of its own, `unlearn`) has nothing left
        // to count down, and alone on the hub it would be judged as a correction of its own.
        observations = observations.compactMap { observation in
            guard observation.id == nil else { return observation }
            var observation = observation
            observation.pairs.removeAll { HubLearning.fold($0.right) == key }
            return observation.pairs.isEmpty ? nil : observation
        }
        prune()
    }

    /// `observations` without the pairs whose `wrong` folds to one of `keys`.
    static func removing(_ keys: Set<String>, from observations: [LearningObservations]) -> [LearningObservations] {
        observations.compactMap { observation in
            var observation = observation
            observation.pairs.removeAll { keys.contains(HubLearning.fold($0.wrong)) }
            return observation.pairs.isEmpty ? nil : observation
        }
    }

    /// `id`: the device's id for it (`LearningObservations.id`), which lets it go again when its answer is lost.
    /// `kind`: `.repeated` when the pairs are swaps made twice (`LearningObservations.kind`).
    public mutating func observe(_ pairs: [CorrectionPair], dictationID: UUID? = nil, id: UUID? = nil,
                                 kind: LearnedCorrection.Kind? = nil) {
        guard !pairs.isEmpty else { return }
        observations = Array((observations + [LearningObservations(pairs: pairs, dictationID: dictationID, id: id, kind: kind)])
            .suffix(Self.limit))
        prune()
    }

    /// A correction counted down on the device: the user changed it back (`LearningEvent.reversed`), or a
    /// learning was undone. One still waiting to go, never sent, is taken back. One that was sent and got no
    /// answer (`unanswered`) may be on the hub already: it stays in line and the reverse pair follows it, so the
    /// hub ends at zero whether the first sending arrived or not (sent again, it is counted once for its
    /// dictation; then the reverse counts it down). Otherwise, when the hub has it (`hubHas`), the reverse pair
    /// goes: the hub's learning book counts that down the same way (`LearningBook.record`, or its own undo when
    /// the pair came from the same dictation). A pair the hub does not have sends nothing: it would learn the
    /// reverse as a new correction.
    public mutating func unlearn(_ pair: CorrectionPair, dictationID: UUID? = nil, hubHas: Bool) {
        let key = LearningBook.key(pair)
        let reverse = CorrectionPair(wrong: pair.right, right: pair.wrong)
        if let i = observations.lastIndex(where: { $0.pairs.contains { LearningBook.key($0) == key } }),
           let j = observations[i].pairs.lastIndex(where: { LearningBook.key($0) == key }) {
            if let id = observations[i].id, unanswered.contains(id) {
                observe([reverse], dictationID: dictationID)
                return
            }
            observations[i].pairs.remove(at: j)
            if observations[i].pairs.isEmpty { observations.remove(at: i) }
            prune()
        } else if hubHas {
            observe([reverse], dictationID: dictationID)
        }
    }

    /// The latest text of dictation `id`: an earlier one still waiting is replaced.
    public mutating func edit(_ id: UUID, text: String, learn: Bool? = nil) {
        edits = Array((edits.filter { $0.id != id } + [Edit(id: id, text: text, learn: learn)]).suffix(Self.limit))
    }

    /// Takes the waiting edit of dictation `id` out (the dictation is about to be polished again, and an older
    /// text arriving after that would replace the new one).
    public mutating func takeEdit(_ id: UUID) -> Edit? {
        guard let i = edits.firstIndex(where: { $0.id == id }) else { return nil }
        return edits.remove(at: i)
    }

    /// Puts back what an earlier outbox still had (what a flush could not send) in front of what was added since.
    public mutating func merge(earlier: HubOutbox) {
        let forgottenNow = Set(forgotten.map(HubLearning.fold))
        forgotten = Array((earlier.forgotten.filter { !forgottenNow.contains(HubLearning.fold($0)) } + forgotten)
            .suffix(Self.forgetLimit))
        let olderObservations = Self.removing(forgottenNow, from: earlier.observations)
        observations = Array((olderObservations + observations).suffix(Self.limit))
        unanswered = earlier.unanswered + unanswered.filter { !earlier.unanswered.contains($0) }
        prune()
        let editedNow = Set(edits.map(\.id))
        edits = Array((earlier.edits.filter { !editedNow.contains($0.id) } + edits).suffix(Self.limit))
    }
}

/// What `HubClient.flush` did.
public struct HubFlushResult: Sendable {
    /// What is still waiting: the hub could not be reached, or refused this device, or the flush sent as many
    /// requests as it was allowed.
    public var left: HubOutbox
    /// The hub's learned corrections after the last ones forgotten.
    public var learning: LearningList?
    /// Why it stopped early (nil when it only ran out of requests).
    public var stoppedBy: Error?
    /// How many requests it sent.
    public var sent = 0
    /// Corrections the hub answered and did not take: the ones it named (`LearningObservationsResponse.refused`),
    /// or, from a hub that names none, every pair of an observation it took nothing of. The reverse of a pair,
    /// sent to count it down, can be among them. Only what the answers said: a hub from before it named them
    /// that took some of an observation's pairs says nothing about the rest, so what the device shows comes
    /// from the hub's list after the next sync instead (`HubLearning.missing`).
    public var refused: [CorrectionPair] = []
}

extension HubClient {
    /// Applies `edits` to the hub's dictionary: reads it, writes the result with the revision it read, and when it
    /// changed meanwhile on another device (409) reads it again and applies the edits again, up to `attempts` times.
    public func applyVocabulary(_ edits: [VocabularyEdit], attempts: Int = 3) async throws -> VocabularySnapshot {
        var snapshot = try await vocabulary()
        var tries = 1
        while true {
            let words = HubVocabulary.applying(edits, to: snapshot.words, learned: snapshot.learned)
            if words == snapshot.words { return snapshot }
            do {
                return try await updateVocabulary(words: words, expectedRevision: snapshot.revision)
            } catch let error as HubError where error.isConflict && tries < attempts {
                tries += 1
                snapshot = try await vocabulary()
            }
        }
    }

    /// Whether a flush keeps the item it was sending and stops: the hub was not reached (no network, Cloudflare's
    /// page while the Neo sleeps, something on the way turning the request away, Cloudflare Access stopping it),
    /// does not take this device, wants fewer requests (429) or is busy (503), or the task was cancelled. Any other answer of the hub's own (a 404
    /// for a dictation it no longer has, its 500) would be the same next time: that item is dropped, so one bad
    /// item never holds up the rest, or the syncs after them.
    public static func flushStops(at error: Error) -> Bool {
        guard let error = error as? HubError else { return true }
        if error.needsPairing { return true }
        switch error {
        case .notPaired, .offline, .unreachable, .connectionLost, .timeout, .accessDenied: return true
        case .server(let status, nil): return status == 401 || status == 403 || status == 429 || status >= 500
        // The hub takes only what came through Access, and this did not: the same for every item until it is fixed.
        case .server(403, let body?) where body.code == HubErrorCode.accessRequired: return true
        case .server(let status, _?): return status == 429 || status == 503
        case .audioTooLarge, .invalidRequest, .badResponse: return false
        }
    }

    /// Sends what is waiting: the corrections forgotten (many to a request), then those learned, then the edited
    /// texts, at most `requests` requests (`HubOutbox.requestsPerMinute` paces a device's flushes, so they never
    /// use up the hub's per-device limit). Stops where `flushStops` says so, keeping the rest; an item the hub
    /// turns down for itself is dropped. Corrections learned are counted on the hub, so one whose answer was lost
    /// on the way (it may have arrived) goes again only when the hub cannot count it twice: it carries an id of
    /// its own and the record it comes from (`dictationID`). The hub counts a pair once per record and keeps the
    /// records with its corrections on disk, so that holds whatever its version and also when it restarted in
    /// between; its memory of observation ids alone is not relied on. It is then marked `HubOutbox.unanswered`.
    /// Anything else is dropped, as before: better not learned there than counted twice. `progress` gets what
    /// is left after every request, so the device can save it as it goes.
    public func flush(_ outbox: HubOutbox, requests limit: Int = .max,
                      progress: (@Sendable @MainActor (HubOutbox) -> Void)? = nil) async -> HubFlushResult {
        var left = outbox
        var result = HubFlushResult(left: outbox)
        func stop(_ error: Error?) -> HubFlushResult {
            result.left = left
            result.stoppedBy = error
            return result
        }

        while !left.forgotten.isEmpty {
            guard result.sent < limit else { return stop(nil) }
            let wrongs = Array(left.forgotten.prefix(HubOutbox.forgetsPerRequest))
            result.sent += 1
            do {
                result.learning = try await forget(wrongs: wrongs)
            } catch {
                if Self.flushStops(at: error) { return stop(error) }
            }
            left.forgotten.removeFirst(wrongs.count)
            await progress?(left)
        }
        while let observation = left.observations.first {
            guard result.sent < limit else { return stop(nil) }
            result.sent += 1
            do {
                let answer = try await observe(observation.pairs, dictationID: observation.dictationID, id: observation.id,
                                               kind: observation.kind)
                // A hub that names what it refused; one that does not took nothing when it says zero.
                result.refused += answer.refused ?? (answer.accepted == 0 ? observation.pairs : [])
            } catch {
                // Sent, but the answer did not come back: the hub may have counted it. What follows waits, as the
                // connection is shaky; this one goes again next time only when that cannot count it twice.
                if let hub = error as? HubError, hub == .connectionLost || hub == .timeout {
                    if let id = observation.id, observation.dictationID != nil {
                        if !left.unanswered.contains(id) { left.unanswered.append(id) }
                    } else {
                        left.observations.removeFirst()
                    }
                    await progress?(left)
                    return stop(error)
                }
                if Self.flushStops(at: error) { return stop(error) }
            }
            left.observations.removeFirst()
            if let id = observation.id { left.unanswered.removeAll { $0 == id } }
            await progress?(left)
        }
        while let edit = left.edits.first {
            guard result.sent < limit else { return stop(nil) }
            result.sent += 1
            do {
                _ = try await self.edit(id: edit.id, text: edit.text, learn: edit.learn ?? true)
            } catch {
                if Self.flushStops(at: error) { return stop(error) }
            }
            left.edits.removeFirst()
            await progress?(left)
        }
        return stop(nil)
    }
}
