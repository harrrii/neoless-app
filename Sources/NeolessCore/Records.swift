import Foundation

public enum DictationMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case natural, structured, raw
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .natural: return "自然整理"
        case .structured: return "结构化（发给 AI）"
        case .raw: return "原样转写"
        }
    }

    /// Whether this mode sends the transcript to ChatGPT.
    public var polishes: Bool { self != .raw }

    /// The closest mode builds from before 结构化 can decode. They read history.json all or nothing, so a
    /// single "structured" there would leave them an empty history, which their next save writes back.
    public var legacy: DictationMode { self == .structured ? .natural : self }

    /// The mode one dictation uses: 自然整理 turns into 结构化 in AI apps when `autoStructured` is on.
    /// A mode the user picked on purpose (结构化 or 原样) is never changed.
    public static func effective(_ mode: DictationMode, autoStructured: Bool, bundleID: String?, appName: String?) -> DictationMode {
        mode == .natural && autoStructured && AIApps.isAIApp(bundleID: bundleID, name: appName) ? .structured : mode
    }
}

/// Apps where dictation is usually a request to an AI assistant or agent: chat apps, AI editors, terminals.
/// The bundle ID is checked first; the display name is the fallback.
public enum AIApps {
    /// Bundle identifiers, matched case-insensitively as a prefix (so Insiders, Preview and Stable builds count).
    public static let bundleIDPrefixes = [
        "com.openai.codex", "com.openai.chat", "com.anthropic.claude",
        "com.todesktop.230313mzl4w4u92",                        // Cursor
        "com.microsoft.VSCode", "com.visualstudio.code.oss", "com.vscodium",
        "com.exafunction.windsurf", "dev.zed.Zed",
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp",
    ]

    /// Apps from the same makers that are not for prompting, whatever their name says: OpenAI's browser
    /// (ChatGPT Atlas), where dictation is usually an email or a form.
    public static let excludedBundleIDPrefixes = ["com.openai.atlas"]

    /// Display names, matched case-insensitively as the whole name, or followed by a `channelSuffixes` entry.
    public static let names = [
        "Codex", "Claude", "ChatGPT", "Cursor", "Visual Studio Code", "Code", "VSCodium", "Windsurf", "Zed",
        "Terminal", "终端", "iTerm", "iTerm2", "Warp",
    ]

    /// What a beta or preview build adds after the name ("Zed Preview", "Code - Insiders"). Any other word
    /// makes it a different app: "ChatGPT Atlas", "Code Runner".
    public static let channelSuffixes = ["preview", "insiders", "- insiders", "beta", "nightly", "canary"]

    public static func isAIApp(bundleID: String?, name: String?) -> Bool {
        if let id = bundleID?.lowercased(), !id.isEmpty {
            if excludedBundleIDPrefixes.contains(where: { id.hasPrefix($0.lowercased()) }) { return false }
            if bundleIDPrefixes.contains(where: { id.hasPrefix($0.lowercased()) }) { return true }
        }
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !name.isEmpty else { return false }
        return names.contains { known in
            let k = known.lowercased()
            guard name.hasPrefix(k) else { return false }
            // Not "Codeshot" or "Cursorcerer" either: the name must end or go on with a space.
            let rest = name.dropFirst(k.count)
            return rest.isEmpty
                || (rest.first == " " && channelSuffixes.contains(rest.dropFirst().trimmingCharacters(in: .whitespaces)))
        }
    }
}

public enum Delivery: String, Codable, Sendable {
    case pasted        // ⌘V sent to the focused app
    case copied        // left on the clipboard for the user
    case inApp         // shown on neoless's own home page
    case notInserted   // e.g. password field: kept in history only
}

public struct DictationRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var duration: TimeInterval
    public var raw: String
    public var polished: String?
    public var finalText: String
    public var appName: String?
    public var mode: DictationMode
    public var model: String?
    public var polishSeconds: TimeInterval?
    public var note: String?
    public var delivery: Delivery
    /// The Neo's id for this dictation (`DictationResult.id`), when the Neo processed it: its 重新整理 and the
    /// user's edits go there. History stays on each device; this only links the two.
    public var hubID: UUID?
    /// What recognised the speech when the Neo processed it: "qwen3-asr" (the Neo's model) or "local" (this
    /// Mac's transcript: 本机识别, or the Neo heard nothing or not in time). Nil: this Mac did everything itself.
    public var recognizer: String?
    /// Where the wait after the recording stopped went (`TimingText.breakdown`). Nil for records from before it was
    /// kept, and after 重新整理 (the text it timed is gone).
    public var timings: DictationTimings?

    public init(id: UUID = UUID(), date: Date = Date(), duration: TimeInterval, raw: String, polished: String?,
                finalText: String, appName: String?, mode: DictationMode, model: String?,
                polishSeconds: TimeInterval?, note: String?, delivery: Delivery, hubID: UUID? = nil, recognizer: String? = nil,
                timings: DictationTimings? = nil) {
        self.id = id; self.date = date; self.duration = duration; self.raw = raw; self.polished = polished
        self.finalText = finalText; self.appName = appName; self.mode = mode; self.model = model
        self.polishSeconds = polishSeconds; self.note = note; self.delivery = delivery
        self.hubID = hubID; self.recognizer = recognizer; self.timings = timings
    }

    /// The Neo's own speech model recognised it (not this Mac's recognizer).
    public var recognizedOnHub: Bool { hubID != nil && recognizer != nil && recognizer != "local" }

    // `mode` is saved as `mode.legacy`, which every build reads, and the real mode goes in `exactMode` when it
    // differs; older builds ignore that key and see 结构化 as 自然整理. An `exactMode` this build does not
    // know (from a newer one) falls back to `mode` the same way. `hubID`, `recognizer` and `timings` are new keys
    // that older builds ignore; one that does not read here (written by a newer build) is left out, not an error.
    private enum CodingKeys: String, CodingKey {
        case id, date, duration, raw, polished, finalText, appName, mode, exactMode, model, polishSeconds, note, delivery
        case hubID, recognizer, timings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        raw = try c.decode(String.self, forKey: .raw)
        polished = try c.decodeIfPresent(String.self, forKey: .polished)
        finalText = try c.decode(String.self, forKey: .finalText)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        let exact = try? c.decodeIfPresent(DictationMode.self, forKey: .exactMode)
        mode = try exact ?? c.decode(DictationMode.self, forKey: .mode)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        polishSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .polishSeconds)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        delivery = try c.decode(Delivery.self, forKey: .delivery)
        hubID = try? c.decodeIfPresent(UUID.self, forKey: .hubID)
        recognizer = try? c.decodeIfPresent(String.self, forKey: .recognizer)
        timings = (try? c.decodeIfPresent(DictationTimings.self, forKey: .timings)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(date, forKey: .date)
        try c.encode(duration, forKey: .duration)
        try c.encode(raw, forKey: .raw)
        try c.encodeIfPresent(polished, forKey: .polished)
        try c.encode(finalText, forKey: .finalText)
        try c.encodeIfPresent(appName, forKey: .appName)
        try c.encode(mode.legacy, forKey: .mode)
        if mode != mode.legacy { try c.encode(mode, forKey: .exactMode) }
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(polishSeconds, forKey: .polishSeconds)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encode(delivery, forKey: .delivery)
        try c.encodeIfPresent(hubID, forKey: .hubID)
        try c.encodeIfPresent(recognizer, forKey: .recognizer)
        try c.encodeIfPresent(timings, forKey: .timings)
    }
}

/// Where the wait after a recording stopped went, in milliseconds, as a history record keeps it. A part that was not
/// measured is nil (left out of the JSON): a dictation this Mac did alone has only `waitMs`.
public struct DictationTimings: Codable, Equatable, Sendable {
    /// From the stop (the key let go, ✓, the recording ending on its own) to the text typed, measured on this Mac:
    /// what the user waited, the recording's 0.25 s tail, the upload and the paste included.
    public var waitMs: Int?
    /// This Mac's call to the Neo whose answer was used, from sending it (with the upload, for a recording) to the
    /// whole answer: the Neo's work (`totalMs`) and the way there and back.
    public var requestMs: Int?
    /// The Neo's own (`HubTimings`): decoding the recording, recognition (with waiting for its worker and a model
    /// load), polishing, and all of its work together.
    public var decodeMs: Int?
    public var asrMs: Int?
    public var polishMs: Int?
    public var totalMs: Int?
    /// A call to the Neo whose answer was not used, before the text came another way: from sending it (the first
    /// one, when there were two) to this Mac giving up on it (its budget ran out, or it failed) or to its answer that
    /// it heard nothing or could not listen (then this Mac's transcript followed to `/v1/polish`, or this Mac did the
    /// rest itself). Part of `waitMs`; not of `requestMs`, the call whose answer was used.
    public var neoWaitMs: Int?

    public init(waitMs: Int? = nil, requestMs: Int? = nil, decodeMs: Int? = nil, asrMs: Int? = nil, polishMs: Int? = nil,
                totalMs: Int? = nil, neoWaitMs: Int? = nil) {
        self.waitMs = waitMs; self.requestMs = requestMs; self.decodeMs = decodeMs; self.asrMs = asrMs
        self.polishMs = polishMs; self.totalMs = totalMs; self.neoWaitMs = neoWaitMs
    }

    /// Whole milliseconds of `duration` (never negative).
    public static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return max(0, Int(seconds) * 1_000 + Int(attoseconds / 1_000_000_000_000_000))
    }
}

/// The quiet line under a history entry's details: where the wait went.
public enum TimingText {
    /// "识别 3.1 秒 · 整理 2.4 秒 · 传输 0.3 秒 · 共 6.0 秒", in the parts that were measured, or nil for a record
    /// without timings. First, "等 Neo 35.0 秒（没用上）" when a call to the Neo was given up on, or its answer was
    /// not used (`neoWaitMs`), so the slowest dictations say where their time went. 识别 is the Neo's recognition;
    /// "本机识别" when this Mac's transcript was used (本机识别, or the Neo did not hear it in time: then how long the
    /// Neo waited for its own). 整理 is the polish, wherever it ran, with a Neo polish that did not come through
    /// counted too. 传输 is the Neo call that was used less the Neo's own work: the upload and the way there and back
    /// (left out with `transfer` false, for a narrow window). 共 is the whole wait.
    public static func breakdown(_ record: DictationRecord, transfer: Bool = true) -> String? {
        guard let t = record.timings else { return nil }
        var parts: [String] = []
        if let unused = t.neoWaitMs { parts.append("等 Neo " + seconds(unused) + "（没用上）") }
        if let recognizer = record.recognizer, recognizer != "local" {
            if let asr = t.asrMs { parts.append("识别 " + seconds(asr)) }
        } else if let asr = t.asrMs, asr >= 1_000 {
            parts.append("本机识别（等了 Neo " + seconds(asr) + "）")
        } else {
            parts.append("本机识别")
        }
        // Polished here, or a Neo polish that was not used (it failed, and this Mac polished, or typed the original).
        var polish = record.polished != nil ? (record.polishSeconds ?? 0) : 0
        if record.hubID == nil || record.polished == nil, let neo = t.polishMs { polish += Double(neo) / 1_000 }
        if polish > 0 { parts.append("整理 " + seconds(polish)) }
        if transfer, let request = t.requestMs, let total = t.totalMs, request >= total {
            parts.append("传输 " + seconds(request - total))
        }
        if let wait = t.waitMs { parts.append("共 " + seconds(wait)) }
        return parts.joined(separator: " · ")
    }

    static func seconds(_ ms: Int) -> String { seconds(Double(ms) / 1_000) }

    static func seconds(_ value: Double) -> String { String(format: "%.1f 秒", max(0, value)) }
}

public enum HistoryRetention {
    public static let days = 30

    public static func prune(_ records: [DictationRecord], now: Date = Date()) -> [DictationRecord] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return records.filter { $0.date >= cutoff }.sorted { $0.date > $1.date }
    }
}

public enum Vocabulary {
    public static let maxWords = 2_000
    public static let maxWordLength = 80
    /// Apple recommends keeping contextual strings short; more is not better.
    public static let recognizerHintLimit = 100
    public static let promptCharacterBudget = 2_000

    /// What a new install starts with: a few names a recognizer often gets wrong. Everyone replaces it with
    /// their own words.
    public static let defaults = ["OpenAI", "ChatGPT", "Codex", "Claude", "neoless", "GitHub", "App Store", "SSH"]

    /// Trims, drops empties and over-long entries, removes case-insensitive duplicates (newest wins, order kept).
    public static func normalize(_ words: [String]) -> [String] {
        Array(deduplicated(words).prefix(maxWords))
    }

    /// `normalize` without the `maxWords` cap.
    static func deduplicated(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for word in words {
            let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty, w.count <= maxWordLength, seen.insert(w.lowercased()).inserted else { continue }
            out.append(w)
        }
        return out
    }

    static func key(_ word: String) -> String { word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// The dictionary after the user typed `added`: they go to the front (a word already listed moves up),
    /// and from now on they count as the user's own even if learning also teaches them. `learned` lists the
    /// learned-only terms; past `maxWords` those go first (oldest first), so the user's words are dropped last.
    public static func adding(_ added: [String], to words: [String], learned: [String]) -> [String] {
        let typed = Set(added.map(key))
        return trimmed(deduplicated(added + words), learned: learned.filter { !typed.contains(key($0)) })
    }

    /// The dictionary after learning taught `terms`: new ones go to the front (most recent first) and a word
    /// already listed keeps its place, so learning never reorders the user's list. Past `maxWords`, learned-only
    /// terms go first (the oldest, then these new ones); the user's own words are never dropped for them.
    public static func addingLearned(_ terms: [String], to words: [String], learned: [String]) -> [String] {
        let listed = deduplicated(words)
        var keys = Set(listed.map(key))
        let new = deduplicated(terms).filter { keys.insert(key($0)).inserted }
        return trimmed(new + listed, learned: learned + new)
    }

    /// `words` cut to `maxWords`: learned-only terms are dropped from the end (the oldest) before anything else.
    static func trimmed(_ words: [String], learned: [String]) -> [String] {
        var out = words
        var excess = out.count - maxWords
        guard excess > 0 else { return out }
        let learnedKeys = Set(learned.map(key))
        var i = out.count - 1
        while excess > 0, i >= 0 {
            if learnedKeys.contains(key(out[i])) {
                out.remove(at: i)
                excess -= 1
            }
            i -= 1
        }
        return Array(out.prefix(maxWords))
    }

    /// At most this many recognizer hints, and this many prompt characters, go to learned terms.
    public static let learnedHintLimit = 30
    public static let learnedPromptBudget = 600

    /// Splits `words` into the user's own words (added by hand or defaults, order kept) and learned-only
    /// terms (in the order of `learned`, most useful first). `learned` lists terms that are in the
    /// dictionary only because they were learned; entries not in `words` are ignored.
    public static func prioritized(_ words: [String], learned: [String]) -> (manual: [String], learned: [String]) {
        let all = normalize(words)
        let learnedKeys = Set(learned.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let manual = all.filter { !learnedKeys.contains($0.lowercased()) }
        var byKey: [String: String] = [:]
        for w in all where learnedKeys.contains(w.lowercased()) { byKey[w.lowercased()] = w }
        var seen = Set<String>()
        let ranked = learned.compactMap { term -> String? in
            let key = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard seen.insert(key).inserted else { return nil }
            return byKey[key]
        }
        return (manual, ranked)
    }

    /// Words given to the speech recognizer as hints. The user's own words come first, in order; learned
    /// terms only fill what is left, at most `learnedHintLimit` of them, so they never crowd manual words out.
    public static func recognizerHints(_ words: [String], learned: [String] = []) -> [String] {
        let (manual, ranked) = prioritized(words, learned: learned)
        let own = Array(manual.prefix(recognizerHintLimit))
        return own + ranked.prefix(min(learnedHintLimit, recognizerHintLimit - own.count))
    }

    /// The words one polish prompt lists, already cut to the budgets. The two lists stay apart because the
    /// prompt weighs them differently: the user's own words (typed by hand, or the defaults they kept) are
    /// 热词 and win over 原样保留; learned-only terms were added by learning from a single edit, without the
    /// user choosing them, so they are listed on their own and used only when the context fits.
    public struct PromptWords: Equatable, Sendable {
        public var own: [String]
        public var learned: [String]

        public init(own: [String] = [], learned: [String] = []) {
            self.own = own; self.learned = learned
        }

        /// Both lists, the user's own words first.
        public var all: [String] { own + learned }
    }

    /// Words listed in the polish prompt, within a character budget: the user's own words first, then
    /// learned terms within at most `learnedPromptBudget` characters. Cutting the result again
    /// (`promptWords(result.all, learned: result.learned)`) leaves it unchanged.
    public static func promptWords(_ words: [String], learned: [String] = []) -> PromptWords {
        let (manual, ranked) = prioritized(words, learned: learned)
        var used = 0
        func take(_ list: [String], budget: Int) -> [String] {
            var spent = 0
            var out: [String] = []
            for w in list {
                let cost = w.count + 1
                guard used + cost <= promptCharacterBudget, spent + cost <= budget else { break }
                used += cost
                spent += cost
                out.append(w)
            }
            return out
        }
        let own = take(manual, budget: promptCharacterBudget)
        return PromptWords(own: own, learned: take(ranked, budget: learnedPromptBudget))
    }
}
