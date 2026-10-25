import Foundation

/// What became of the user's recent edits of dictated text: learned, or why not. A short list the app keeps
/// (learning-log.json) and shows, so that "it did not learn" has an answer. Codes, counts, the app's name
/// and the time only: never the text, never the words.
public struct LearningLog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var at: Date
        /// The app the text was in; nil for neoless's own window.
        public var app: String?
        /// A `Code` raw value. Kept as text, so a file written by a newer version still reads.
        public var code: String
        /// How many words were learned (`learned`; those of them taken back since are not counted), or how
        /// many pairs the Neo turned down (`hubRefused`).
        public var count: Int

        public init(id: UUID = UUID(), at: Date, app: String?, code: Code, count: Int = 0) {
            self.id = id; self.at = at; self.app = app; self.code = code.rawValue; self.count = count
        }
    }

    public enum Code: String, Sendable {
        case learned
        /// What an edit taught was all taken back: the user undid the edit, or pressed 撤销.
        case undone
        // The edit was seen and taught nothing (`Extraction.Nothing`, with the same raw values).
        case removedOnly, formatOnly, rewrite, sensitive, notTerms, unlikeName, knownName
        // The edit could not be seen: the field does not say what is in it, the pasted text was not found in
        // it, the app did not answer in time, the field holds more text than is ever read (a terminal's
        // scrollback, a long document), or it is a code editor the user has not switched learning on for.
        case unreadable, notFound, slow, tooLong, needsOptIn
        /// The day's new corrections are used up (`LearningBook.maxNewPerDay`).
        case dailyLimit
        /// The word the edit would have taught is in the dictionary already.
        case inDictionary
        /// A capital was given to a word for the first time: noted, and learned when it is given again in
        /// another dictation (`LearningBook.sightings`).
        case seenOnce
        /// The Neo did not take corrections this Mac learned.
        case hubRefused
        /// A word was typed over another that does not sound like it: remembered, and learned when the same
        /// swap is made in another dictation (`LearningBook.candidates`). `count`: how many swaps.
        case candidate
        /// The same swap was made a second time: learned, as a hint for the model. `count`: how many.
        case repeated
        /// What was remembered of a swap was taken back: the user undid the edit.
        case candidateUndone
        /// Words the rules could not decide about were judged misheard by ChatGPT on the Neo, and learned
        /// (`LearnedCorrection.Kind.judged`). `count`: how many.
        case judged
        /// ChatGPT on the Neo judged that the words the user typed over others were not misheard.
        case judgedNo

        public init(_ nothing: Extraction.Nothing) {
            switch nothing {
            case .removedOnly: self = .removedOnly
            case .formatOnly: self = .formatOnly
            case .rewrite: self = .rewrite
            case .sensitive: self = .sensitive
            case .notTerms: self = .notTerms
            case .unlikeName: self = .unlikeName
            case .knownName: self = .knownName
            }
        }

        /// The edit could not be seen at all.
        public var isUnwatched: Bool {
            self == .unreadable || self == .notFound || self == .slow || self == .tooLong || self == .needsOptIn
        }
    }

    public static let limit = 40
    /// The same thing in the same app within this long is one entry (a pause between two deletions).
    static let repeatWindow: TimeInterval = 90

    public var version = 1
    /// Newest first.
    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// Returns the id of the entry that says it (a new one, or the one just before it that it joined).
    /// That an app's edits cannot be seen is said once per app, with the time it last happened: every
    /// dictation into such an app would otherwise leave a line, and the list would be a record of where the
    /// user dictated and when.
    @discardableResult
    public mutating func add(_ code: Code, app: String?, count: Int = 0, at now: Date = Date()) -> UUID {
        if code.isUnwatched, let i = entries.firstIndex(where: { $0.code == code.rawValue && $0.app == app }) {
            var entry = entries.remove(at: i)
            entry.at = now
            entries.insert(entry, at: 0)
            return entry.id
        }
        // What an edit put in the book is an entry of its own: taking it back is said on that entry.
        let counts = code == .learned || code == .repeated || code == .candidate
        if let first = entries.first, first.code == code.rawValue, first.app == app, !counts,
           now.timeIntervalSince(first.at) < Self.repeatWindow {
            entries[0].at = now
            entries[0].count = max(first.count, count)
            return first.id
        }
        let entry = Entry(at: now, app: app, code: code, count: count)
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        return entry.id
    }

    /// Forgets everything (清空, 自动学习 switched off, the list's own 清除).
    public mutating func clear() {
        entries = []
    }

    /// `count` of the words entry `id` says were learned have been taken back: it says so, instead of going
    /// on claiming them. An entry no longer in the log is left alone.
    public mutating func takeBack(_ count: Int, from id: UUID) {
        guard count > 0, let i = entries.firstIndex(where: { $0.id == id }),
              let code = Code(rawValue: entries[i].code), code == .learned || code == .repeated || code == .candidate else { return }
        entries[i].count -= count
        if entries[i].count <= 0 {
            entries[i].count = 0
            entries[i].code = (code == .candidate ? Code.candidateUndone : Code.undone).rawValue
        }
    }
}

/// 学到的纠正 on the dictionary page: this Mac's corrections, and among them the swaps made once that still
/// wait for their second time, so the user sees what an edit became and can delete it.
public enum LearnedList {
    public enum Row: Equatable, Identifiable, Sendable {
        case correction(LearnedCorrection)
        /// A swap made once (`LearningBook.Candidate`): remembered, used for nothing.
        case waiting(LearningBook.Candidate)

        public var id: String {
            switch self {
            case .correction(let item): return item.id.uuidString
            case .waiting(let swap): return "waiting|" + LearningBook.key(swap.pair)
            }
        }

        public var pair: CorrectionPair {
            switch self {
            case .correction(let item): return item.pair
            case .waiting(let swap): return swap.pair
            }
        }
    }

    /// `items` in their order (the newest first), each waiting swap put before the first correction that
    /// was learned earlier than it was made: a swap made a moment ago is at the top, where the correction it
    /// becomes at its second time will be, and an old one is down among the old.
    public static func rows(items: [LearnedCorrection], candidates: [LearningBook.Candidate]) -> [Row] {
        var waiting = candidates.sorted { $0.seen > $1.seen }[...]
        var out: [Row] = []
        for item in items {
            while let swap = waiting.first, swap.seen > item.firstSeen {
                out.append(.waiting(swap))
                waiting = waiting.dropFirst()
            }
            out.append(.correction(item))
        }
        return out + waiting.map(Row.waiting)
    }
}

/// Invented swaps for the app's own pictures (`--snapshot`): the capsule's lines and the dictionary page's
/// rows. A picture must not show as remembered what the rules never remember, so a test asks
/// `CorrectionExtractor.isRepeatable` of every one of them.
public enum LearningSamples {
    /// Made a moment ago, and the one made a second time.
    public static let swap = CorrectionPair(wrong: "方法", right: "办法")
    /// Made a few days ago, still waiting.
    public static let earlierSwap = CorrectionPair(wrong: "草稿", right: "初稿")
    /// Too long for the capsule to say in one line with its arrow.
    public static let longSwap = CorrectionPair(wrong: "操作说明书", right: "使用说明书")
    /// Learned as made twice.
    public static let learnedSwap = CorrectionPair(wrong: "报告", right: "报道")

    public static let swaps = [swap, earlierSwap, longSwap, learnedSwap]
}

/// The words neoless uses about learning: one line for the capsule, the menu and the dictionary page.
public enum LearningText {
    /// The tag on a swap made once, and what it means.
    public static let waitingTag = "待确认 1/2"
    public static let waitingHelp = "只改过一次，还没用上。在另一条听写里再这样改一次，才会记住。"
    /// The tag on a swap made twice (`LearnedCorrection.Kind.repeated`), and what it means.
    public static let repeatedTag = "改过两次"
    public static let repeatedHelp = "不一定是听错，是你两次都这样改才记住的。只作为提示交给 ChatGPT，不直接改字，也不加进词典。"

    /// Under 学到的纠正, when rows carry these tags: one sentence for each kind that is there.
    public static func tagFooter(waiting: Bool, repeated: Bool) -> String? {
        var lines: [String] = []
        if waiting { lines.append("标着“\(waitingTag)”的只改过一次，还没用上：在另一条听写里再这样改一次才记住。") }
        if repeated { lines.append("标着“\(repeatedTag)”的只作为提示交给 ChatGPT，不直接改字。") }
        return lines.isEmpty ? nil : lines.joined()
    }

    public static let learnedPrefix = "已记住"
    public static let notedPrefix = "记下了"
    public static let missedPrefix = "没记住"
    public static let unwatchedPrefix = "学不到"

    /// "Open Air → OpenAI、金币 → 硬币、Nio": mappings as they are, words learned alone by themselves.
    public static func summary(pairs: [CorrectionPair], terms: [String] = []) -> String {
        (pairs.map { "\($0.wrong) → \($0.right)" } + terms).joined(separator: "、")
    }

    /// The capsule's line after an edit taught something, the first of these that `fits`:
    /// "已记住：Open Air → OpenAI", "已记住：OpenAI", "已记住 1 个词".
    public static func learned(pairs: [CorrectionPair], terms: [String] = [], fits: (String) -> Bool = { _ in true }) -> String {
        let rights = pairs.map(\.right) + terms
        guard let first = rights.first else { return learnedPrefix }
        var candidates = ["\(learnedPrefix)：" + summary(pairs: pairs, terms: terms)]
        if rights.count == 1 {
            candidates.append("\(learnedPrefix)：\(first)")
        } else {
            candidates.append(MixedText.join("\(learnedPrefix)：\(first)", "等 \(rights.count) 个词"))
        }
        candidates.append("\(learnedPrefix) \(rights.count) 个词")
        return candidates.first(where: fits) ?? candidates[candidates.count - 1]
    }

    /// The capsule's line after a swap was remembered for the first time, the first of these that `fits`:
    /// "记下了：米线 → 曲线，再这样改一次就记住", "记下了：曲线，再改一次就记住", "记下了，再改一次就记住".
    public static func noted(pairs: [CorrectionPair], fits: (String) -> Bool = { _ in true }) -> String {
        guard let first = pairs.first else { return notedPrefix }
        var candidates = ["\(notedPrefix)：" + summary(pairs: pairs) + "，再这样改一次就记住"]
        if pairs.count == 1 { candidates.append("\(notedPrefix)：\(first.right)，再改一次就记住") }
        candidates.append("\(notedPrefix)，再改一次就记住")
        return candidates.first(where: fits) ?? candidates[candidates.count - 1]
    }

    /// What `notedParts` says second, when the line is too long for the capsule to say at once.
    public static let notedRest = "再这样改一次就记住"

    /// The same line for a capsule too narrow for it (`fits`), said in two parts, one after the other:
    /// "记下了：米线 → 曲线", then "再这样改一次就记住". The first part is the first of these that fits: the swaps
    /// as they are, the one new word ("记下了：曲线") or the first of several ("记下了：曲线等 2 个词"). One
    /// part when the whole line fits, and when no first part does ("记下了，再改一次就记住").
    public static func notedParts(pairs: [CorrectionPair], fits: (String) -> Bool) -> [String] {
        let whole = noted(pairs: pairs)
        guard let first = pairs.first, !fits(whole) else { return [whole] }
        var heads = ["\(notedPrefix)：" + summary(pairs: pairs)]
        if pairs.count == 1 {
            heads.append("\(notedPrefix)：\(first.right)")
        } else {
            heads.append(MixedText.join("\(notedPrefix)：\(first.right)", "等 \(pairs.count) 个词"))
        }
        guard let head = heads.first(where: fits) else { return ["\(notedPrefix)，再改一次就记住"] }
        return [head, notedRest]
    }

    /// The capsule's line when the user fixed a term and it could not be learned, or nil when the edit is
    /// not worth a line (deletions, punctuation, rewording, a rewrite: the user was not fixing a term).
    public static func missed(_ nothing: Extraction.Nothing) -> String? {
        switch nothing {
        case .unlikeName: return "\(missedPrefix)，可手动加进词典"
        // The name is in the dictionary already: nothing to add, the change just does not read as misheard.
        case .knownName: return "\(missedPrefix)：不像是听错的"
        case .sensitive: return "\(missedPrefix)：这段话像有密码或地址"
        case .removedOnly, .formatOnly, .rewrite, .notTerms: return nil
        }
    }

    /// The capsule's line when what the user changes in `app` cannot be seen.
    public static func unwatched(app: String?, fits: (String) -> Bool = { _ in true }) -> String {
        let named = app.map { MixedText.join(unwatchedPrefix, $0, "里的修改") } ?? ""
        return !named.isEmpty && fits(named) ? named : "\(unwatchedPrefix)这里的修改"
    }

    /// One entry of the log, for the dictionary page: "记住了 2 个词", "只删了字，没有可记的词"…
    public static func line(code: String, count: Int) -> String {
        guard let code = LearningLog.Code(rawValue: code) else { return "没有记" }
        switch code {
        case .learned: return "记住了 \(max(1, count)) 个词"
        case .undone: return "记住的词已撤销"
        case .removedOnly: return "只删了或加了字，没有改错的词"
        case .formatOnly: return "只改了标点或大小写"
        case .rewrite: return "改动太大，像是重写"
        case .sensitive: return "这段话像有密码或地址，不记"
        case .notTerms: return "换了词，不确定是听错的，没记"
        case .unlikeName: return "换成的名字不确定是听错的，可手动加进词典"
        case .knownName: return "换成了词典里的词，不像是听错的，没记"
        case .unreadable: return "读不到这个输入框，学不到"
        case .notFound: return "输入框里没找到刚输入的文字，学不到"
        case .slow: return "应用没有及时回应，学不到"
        case .tooLong: return "输入框里的文字太多，学不到"
        case .needsOptIn: return "没打开对这个编辑器的学习，可在设置里打开"
        case .dailyLimit: return "今天记的新词够多了，明天再记"
        case .inDictionary: return "这个词词典里已经有了"
        case .seenOnce: return "改了大小写：下次再这样改就记住"
        case .hubRefused: return "Neo 没收下 \(max(1, count)) 条纠正"
        case .candidate: return "换了词，记下了：再这样改一次就记住"
        case .repeated: return "同样的词又改了一次，记住了 \(max(1, count)) 个"
        case .candidateUndone: return "记下的词已撤销"
        case .judged: return "ChatGPT 判断是听错，记住了 \(max(1, count)) 个"
        case .judgedNo: return "ChatGPT 看过：像是换了说法，不是听错，没记"
        }
    }
}
