import Foundation

/// 我的习惯: what the user wrote down, in their own words, about how they want their text written ("微信里句末
/// 不要句号", "不要用“首先、其次”"). Every polish is given them (`PolishPrompt.habitsSection`), after the fixed
/// instructions and as preferences only: they change how the tidied text is written, never what neoless
/// does with the transcript.
///
/// A habit is one short line of the user's own. It reaches the model as a list item under a heading that says
/// so, and is cleaned first (`clean`), so that no line can open a section of the instructions or pose as the
/// transcript's wrapper. What a line says cannot be held to a writing preference by a list of words
/// (`refused` keeps the obvious out, and can be written around): that is the work of the section the habits
/// are given in, which says before them and again after them what none of them changes
/// (`PolishPrompt.habitsLead`, `habitsClose`). Cleaning is not a judgement of the user: the same list is
/// taken from other devices through the Neo, and what plainly is no writing preference is left out rather
/// than passed on.
public struct Habits: Codable, Equatable, Sendable {
    /// The most habits kept, and the longest one may be.
    public static let maxItems = 12, maxLength = 60

    /// In the user's order, cleaned.
    public private(set) var items: [String]

    public init(_ items: [String] = []) {
        self.items = Self.normalized(items)
    }

    enum CodingKeys: String, CodingKey { case items }

    /// A file is cleaned as it is read, like everything else that comes in.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = Self.normalized(try c.decodeIfPresent([String].self, forKey: .items) ?? [])
    }

    public var isEmpty: Bool { items.isEmpty }

    /// Adds `line` at the end. False when nothing was added: it cleans to nothing, is there already, or
    /// the list is full.
    @discardableResult
    public mutating func add(_ line: String) -> Bool {
        guard let habit = Self.clean(line), items.count < Self.maxItems,
              !items.contains(where: { Self.fold($0) == Self.fold(habit) }) else { return false }
        items.append(habit)
        return true
    }

    /// Takes out the habit written like `line` (case and spacing aside). False when there was none.
    @discardableResult
    public mutating func remove(_ line: String) -> Bool {
        let key = Self.fold(line)
        guard let i = items.firstIndex(where: { Self.fold($0) == key }) else { return false }
        items.remove(at: i)
        return true
    }

    public func contains(_ line: String) -> Bool {
        let key = Self.fold(line)
        return items.contains { Self.fold($0) == key }
    }

    /// Why `add` would add nothing of `line`, so the page can say so instead of doing nothing.
    public enum Problem: Equatable, Sendable {
        /// Nothing is left of it once it is cleaned (empty, or a mark or two).
        case empty
        /// It reads as talk about the transcript's wrapper or the instructions (`refused`), not as a writing
        /// preference. (A line that says such a thing in other words is not caught here: the section the
        /// habits are given in says what none of them can change, `PolishPrompt.habitsClose`.)
        case refused
        /// The list has it already.
        case duplicate
        /// The list is full (`maxItems`).
        case full
    }

    /// Nil when `add(line)` would add it.
    public func problem(adding line: String) -> Problem? {
        switch Self.judge(line) {
        case .nothing: return .empty
        case .refused: return .refused
        case .kept(let habit):
            if contains(habit) { return .duplicate }
            return items.count >= Self.maxItems ? .full : nil
        }
    }

    /// `lines` cleaned, without what cleans to nothing and without repeats, at most `maxItems` (the first).
    /// No more than `maxLines` of them are looked at, however many come in.
    public static func normalized(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in lines.prefix(maxLines) {
            guard out.count < maxItems else { break }
            guard let habit = clean(line), seen.insert(fold(habit)).inserted else { continue }
            out.append(habit)
        }
        return out
    }

    /// How two habits are told to be the same: case and spacing do not matter.
    static func fold(_ s: String) -> String {
        String(s.lowercased().filter { !$0.isWhitespace })
    }

    /// What marks a line as talk about the instructions themselves, not about how to write: the wrapper the
    /// transcript arrives in, the instructions, or an order to stop following them or to answer what is said.
    /// Lowercase, and matched without regard to spacing. This list is hygiene, not protection: it keeps the
    /// obvious out of the list the user sees, and it can always be written around. What holds a habit to
    /// being a writing preference is the section it is given in (`PolishPrompt.habitsLead`, `habitsClose`).
    static let refused = [
        "逐字稿", "transcript", "system prompt", "系统提示", "系统指令", "系统消息", "提示词注入", "prompt injection",
        "ignore previous", "ignore all", "ignore above", "ignore the above", "disregard", "忽略以上", "忽略上面", "忽略上述",
        "忽略前面", "忽略之前", "忽略所有", "无视以上", "无视上面", "无视前面", "以上规则", "上面的规则", "上述规则", "前面的规则",
        "补充规则", "核心原则", "不再是", "你现在是", "你的角色", "扮演", "回答问题", "回答我", "回答用户", "回答提问",
        "直接回答", "执行命令", "执行指令", "当作指令", "当成指令", "新指令", "新的指令", "新任务", "新的任务", "不是数据",
        "作废", "只听这", "你是一个", "你是个", "用户的请求", "用户的问题", "答案", "解答", "翻译成", "照着做", "给你的指令",
        "各节规则", "answer", "forget the", "rules above", "the rules", "instructions",
    ]
    /// `refused`, as it is matched: without spaces.
    static let refusedKeys = refused.map { $0.filter { !$0.isWhitespace } }

    /// Whether `text` holds something of `refused`, however it is spaced.
    static func isRefused(_ text: String) -> Bool {
        let squeezed = text.lowercased().filter { !$0.isWhitespace }
        return refusedKeys.contains(where: squeezed.contains)
    }

    /// The most of a line that is looked at (in Unicode scalars), and the most lines of a list: a habit is
    /// `maxLength` characters and a list `maxItems` habits, so whatever lies beyond could only be cut later.
    /// Cut first, so that the work done on what a device sends is bounded like what is kept of it.
    public static let maxTyped = maxLength * 8, maxLines = 64

    /// One habit as it is kept and sent, or nil when nothing of it is: on one line, without anything that
    /// could open a section or a list of its own (leading `#`, `-`, `*`, `>`, `=`, a list number), without
    /// angle-bracket tags and code fences, at most `maxLength` characters. A line that talks about the
    /// transcript's wrapper or about the instructions (`refused`) is no writing preference and is dropped whole.
    public static func clean(_ line: String) -> String? {
        if case .kept(let habit) = judge(line) { return habit }
        return nil
    }

    /// What `clean` makes of a line: the habit, or why there is none.
    enum Judged: Equatable {
        case kept(String)
        /// It talks about the transcript's wrapper or about the instructions.
        case refused
        /// Nothing is left of it.
        case nothing
    }

    static func judge(_ line: String) -> Judged {
        // One line: every line break and tab is a space. A character that shows nothing (a zero-width
        // space or joiner, a direction mark, a control character) is no space but nothing at all, so it
        // cannot stand inside a word to hide it from the check below.
        var head = String.UnicodeScalarView()
        head.append(contentsOf: line.unicodeScalars.prefix(maxTyped))
        var scalars = String.UnicodeScalarView()
        for scalar in String(head).precomposedStringWithCanonicalMapping.unicodeScalars {
            if scalar.properties.isWhitespace {
                scalars.append(" ")
            } else if scalar.properties.generalCategory != .control, scalar.properties.generalCategory != .format {
                scalars.append(scalar)
            }
        }
        // Judged as it was typed too: what stood inside a tag counts (`</逐字稿>`).
        guard !isRefused(String(scalars)) else { return .refused }
        // Tags and fences: from a "<" to the next ">", in one pass.
        var text = ""
        var tag: [Character]?
        for c in String(scalars) {
            if tag != nil {
                if c == ">" {
                    text.append(" ")
                    tag = nil
                } else {
                    tag?.append(c)
                }
            } else if c == "<" {
                tag = []
            } else {
                text.append(c)
            }
        }
        // A "<" that nothing closes is no tag: what followed it stays.
        if let open = tag { text += String(open) }
        text = String(text.filter { !"<>`＜＞".contains($0) })
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Nothing at the front that starts a heading, a quote, a rule or a list item.
        let markers = Set("#＃-－–—*＊•·>＞=＝+~|：:，,。.、；; ")
        var changed = true
        while changed {
            changed = false
            while let first = text.first, markers.contains(first) {
                text.removeFirst()
                changed = true
            }
            // "1." / "2、" / "(3)" / "（4）", but not a number that goes on ("1.5 倍行距").
            let digits = text.prefix(while: { $0.isASCII && $0.isNumber })
            if !digits.isEmpty, digits.count <= 2, let next = text.dropFirst(digits.count).first, ".．、)）".contains(next),
               !(text.dropFirst(digits.count + 1).first.map { $0.isASCII && $0.isNumber } ?? false) {
                text.removeFirst(digits.count + 1)
                changed = true
            }
            if let first = text.first, "(（".contains(first) {
                let inner = text.dropFirst().prefix(while: { $0.isASCII && $0.isNumber })
                if !inner.isEmpty, inner.count <= 2, let next = text.dropFirst(1 + inner.count).first, ")）".contains(next) {
                    text.removeFirst(inner.count + 2)
                    changed = true
                }
            }
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return .nothing }
        guard !isRefused(text) else { return .refused }
        if text.count > maxLength { text = String(text.prefix(maxLength)).trimmingCharacters(in: .whitespaces) }
        // A habit says something: at least two letters or characters.
        guard text.filter({ $0.isLetter || $0.isNumber }).count >= 2 else { return .nothing }
        return .kept(text)
    }
}

/// The words of the 我的习惯 card on the dictionary page.
public enum HabitText {
    /// In the empty field: what it is for, with one habit as an example.
    public static let placeholderExample = "微信里句末不要句号"
    public static let placeholder = "添加一条习惯，例如：\(placeholderExample)"
    /// Offered under the field while the list is empty: clicking one puts it in the field, to be changed or
    /// added. Others than the field's own example.
    public static let examples = ["不要用“首先、其次”", "英文单词两边留空格", "数字用阿拉伯数字"]
    /// Under the card: how many, and how long.
    public static let limits = "最多 \(Habits.maxItems) 条，每条不超过 \(Habits.maxLength) 个字。"
    /// Under the card, when every polish follows them.
    public static let footer = "用自己的话写想要的写法，每次整理都会照做。" + limits
    /// Under the card, when the habits have not reached the Neo yet.
    public static let footerWaiting = footer + "还没同步到 Neo，连上后会自动同步。"
    /// Under the card, when the Neo, which does the polishing, is from before habits: "每次整理都会照做" would
    /// not be true.
    public static let footerOldHub = "用自己的话写想要的写法。" + limits + "Neo 的版本还不支持习惯：更新 Neo 之前，只有这台 Mac 自己整理时才照做。"
    /// In place of the field when the list is full.
    public static let full = "已经有 \(Habits.maxItems) 条了，删掉一条才能再加。"

    /// Why the line just typed was not added.
    public static func message(_ problem: Habits.Problem) -> String {
        switch problem {
        case .empty: return "写一句想要的写法，比如“句末不要句号”。"
        case .refused: return "这条加不了：习惯只能写标点、用词、格式这类写法。"
        case .duplicate: return "这条已经有了。"
        case .full: return full
        }
    }

    /// Under the offer: what taking it adds.
    public static func adds(_ wording: String) -> String { "记下就加一条：\(wording)" }
}

// MARK: - Suggesting a habit

/// Something the user keeps doing to dictated text that is no word fix and could be a habit: one of a few
/// patterns neoless can name. Only the pattern is kept, and for a deleted word that one word; never the text.
public enum HabitPattern: Hashable, Sendable {
    /// The full stop that ended the passage was taken off.
    case noFinalStop
    /// A filler or a connective was deleted (然后, 那个, 首先): one of `connectives` or `fillers`.
    case dropWord(String)
    /// A numbered list was turned back into running text.
    case noNumbering
    /// Running text was turned into a numbered list.
    case numbering

    /// Connectives a tidy-up may put in or leave in, which say little: deleting one over and over is a habit.
    /// At most three characters each. Nothing that carries the logic of a sentence (但是, 所以, 因为, 不过).
    public static let connectives: Set<String> = [
        "然后", "首先", "其次", "再次", "最后", "另外", "此外", "还有", "同时", "接着", "总之", "那么", "再者", "而且",
    ]
    /// Spoken fillers a tidy-up may have left in.
    public static let fillers: Set<String> = [
        "那个", "这个", "就是", "就是说", "然后呢", "其实", "的话", "对吧", "是吧", "反正", "基本上", "事实上", "实际上",
        "说实话", "我觉得", "我感觉", "怎么说", "你知道", "嗯嗯", "好的", "好吧",
    ]

    /// How the pattern is kept: "noFinalStop", "drop:然后", "noNumbering", "numbering".
    public var key: String {
        switch self {
        case .noFinalStop: return "noFinalStop"
        case .dropWord(let word): return "drop:" + word
        case .noNumbering: return "noNumbering"
        case .numbering: return "numbering"
        }
    }

    /// The pattern a `key` names, or nil for one this version does not know (or a word that is none of the lists).
    public init?(key: String) {
        switch key {
        case "noFinalStop": self = .noFinalStop
        case "noNumbering": self = .noNumbering
        case "numbering": self = .numbering
        default:
            guard key.hasPrefix("drop:") else { return nil }
            let word = String(key.dropFirst(5))
            guard Self.connectives.contains(word) || Self.fillers.contains(word) else { return nil }
            self = .dropWord(word)
        }
    }

    /// The habit to offer, ready to keep: "句末不要句号" (in one app only: "微信里句末不要句号"), "不要用“然后”",
    /// "不要用口头语“那个”", "短内容不要编号", "几件事分条写并编号".
    /// - Parameter app: the app every time it was seen in, when that was always the same one.
    public func wording(app: String? = nil) -> String {
        switch self {
        case .noFinalStop:
            guard let app = app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty else { return "句末不要句号" }
            return MixedText.join(app, "里句末不要句号")
        case .dropWord(let word):
            return Self.fillers.contains(word) ? "不要用口头语“\(word)”" : "不要用“\(word)”"
        case .noNumbering: return "短内容不要编号"
        case .numbering: return "几件事分条写并编号"
        }
    }

    /// What neoless saw the user do, for the offer: "看到你常删掉句末的句号" (in one app only: "看到你在微信里常
    /// 删掉句末的句号"), "看到你常删掉“然后”", "看到你常把编号列表改回一段话", "看到你常把几件事改成编号列表".
    /// - Parameter app: as for `wording(app:)`.
    public func observation(app: String? = nil) -> String {
        switch self {
        case .noFinalStop:
            guard let app = app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty else { return "看到你常删掉句末的句号" }
            return MixedText.join("看到你在", app, "里常删掉句末的句号")
        case .dropWord(let word): return "看到你常删掉“\(word)”"
        case .noNumbering: return "看到你常把编号列表改回一段话"
        case .numbering: return "看到你常把几件事改成编号列表"
        }
    }
}

/// Reads the patterns off one edit: what the passage looks like now, compared with what neoless delivered.
/// Cheap (no word segmentation), so it can be asked for every settled state of a watched passage.
public enum HabitDetector {
    /// Passages longer than this are not looked at.
    public static let maxPassage = 3_000
    /// More changed characters than this between the unchanged start and end: a rewrite, not looked at.
    static let maxMiddle = 600

    /// The patterns `edited` shows against `original`, the text as it was delivered. Empty when they are
    /// the same, or nothing nameable changed.
    public static func patterns(original: String, edited: String) -> Set<HabitPattern> {
        guard original != edited, !original.isEmpty, !edited.isEmpty,
              original.count <= maxPassage, edited.count <= maxPassage else { return [] }
        var out = Set<HabitPattern>()
        if removedFinalStop(original, edited) { out.insert(.noFinalStop) }
        let before = numberedLines(original), after = numberedLines(edited)
        if before >= 2, after == 0 {
            if keepsContent(original, edited) { out.insert(.noNumbering) }
        } else if before == 0, after >= 2 {
            if keepsContent(original, edited) { out.insert(.numbering) }
        } else {
            // The layout is as it was: what was deleted can be told word by word.
            for word in droppedWords(original, edited) { out.insert(.dropWord(word)) }
        }
        return out
    }

    static let closers = Set("。.！!？?…~～；;，,、：:")

    /// The passage ended in 。 and no longer does, and what stood right before the stop is still its end
    /// (so the last sentence was not deleted or rewritten, only its stop).
    static func removedFinalStop(_ original: String, _ edited: String) -> Bool {
        let o = trimmedEnd(original), e = trimmedEnd(edited)
        guard o.last == "。", let last = e.last, !closers.contains(last) else { return false }
        let body = o.dropLast()
        let tail = String(body.suffix(2))
        return !tail.isEmpty && e.hasSuffix(tail)
    }

    static func trimmedEnd(_ s: String) -> Substring {
        var out = Substring(s)
        while let last = out.last, last.isWhitespace { out.removeLast() }
        return out
    }

    /// How many lines open with a list number: "1." "2、" "3)" "(4)" "（5）", followed by text that is not
    /// more digits (so "3.5% 的折扣" is no list item).
    static func numberedLines(_ text: String) -> Int {
        var count = 0
        for line in text.split(whereSeparator: \.isNewline) {
            var rest = line.drop(while: { $0 == " " || $0 == "\t" || $0 == "\u{3000}" })
            let bracketed = rest.first.map { "(（".contains($0) } ?? false
            if bracketed { rest = rest.dropFirst() }
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            guard !digits.isEmpty, digits.count <= 2 else { continue }
            rest = rest.dropFirst(digits.count)
            guard let mark = rest.first, (bracketed ? ")）" : ".．、)）").contains(mark) else { continue }
            rest = rest.dropFirst().drop(while: { $0 == " " })
            guard let next = rest.first, !(next.isASCII && next.isNumber) else { continue }
            count += 1
        }
        return count
    }

    /// Most of what was said is still there (the list was laid out differently, not thrown away).
    static func keepsContent(_ a: String, _ b: String) -> Bool {
        func size(_ s: String) -> Int { s.filter { $0.isLetter }.count }
        let x = size(a), y = size(b)
        return min(x, y) > 0 && Double(min(x, y)) >= 0.6 * Double(max(x, y))
    }

    /// The fillers and connectives (`HabitPattern.connectives`, `fillers`) deleted from `original`, with
    /// nothing typed in their place: runs that are in `original` only, a listed word once the punctuation
    /// and spaces deleted with it are set aside.
    static func droppedWords(_ original: String, _ edited: String) -> Set<String> {
        let x = Array(original), y = Array(edited)
        var p = 0
        while p < x.count, p < y.count, x[p] == y[p] { p += 1 }
        var s = 0
        while s < x.count - p, s < y.count - p, x[x.count - 1 - s] == y[y.count - 1 - s] { s += 1 }
        let a = Array(x[p..<(x.count - s)]), b = Array(y[p..<(y.count - s)])
        guard !a.isEmpty, a.count <= maxMiddle, b.count <= maxMiddle else { return [] }

        // lcs[i][j] = LCS length of a[i...] and b[j...]
        let w = b.count + 1
        var lcs = [Int](repeating: 0, count: (a.count + 1) * w)
        if !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    lcs[i * w + j] = a[i] == b[j] ? lcs[(i + 1) * w + j + 1] + 1 : max(lcs[(i + 1) * w + j], lcs[i * w + j + 1])
                }
            }
        }
        var out = Set<String>()
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { i += 1; j += 1; continue }
            let (i0, j0) = (i, j)
            while i < a.count || j < b.count {
                if i < a.count, j < b.count, a[i] == b[j] { break }
                if j == b.count || (i < a.count && lcs[(i + 1) * w + j] >= lcs[i * w + j + 1]) { i += 1 } else { j += 1 }
            }
            // Only deleted, nothing typed there.
            guard j == j0, i > i0 else { continue }
            let run = String(a[i0..<i]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            if HabitPattern.connectives.contains(run) || HabitPattern.fillers.contains(run) { out.insert(run) }
        }
        return out
    }
}

/// A habit neoless offers to add, because the user kept doing the same thing by hand. Never added without
/// the user saying so.
public struct HabitSuggestion: Equatable, Sendable, Identifiable {
    /// `HabitPattern.key`.
    public var key: String
    /// The habit as it would be added.
    public var wording: String
    /// In how many dictations it was seen.
    public var count: Int
    /// The one app it was always seen in, when `wording` names it; nil otherwise.
    public var app: String?

    public var id: String { key }

    public init(key: String, wording: String, count: Int, app: String? = nil) {
        self.key = key; self.wording = wording; self.count = count; self.app = app
    }

    /// What was seen, as the offer says it: "看到你常删掉句末的句号" (`HabitPattern.observation`). For a key
    /// this version does not know, a line that is true of any of them.
    public var observation: String {
        HabitPattern(key: key)?.observation(app: app) ?? "看到你常这样改"
    }

    /// The offer's one line: "看到你常删掉句末的句号 · 记成习惯？".
    public var question: String { observation + " · 记成习惯？" }
}

/// Counts the patterns seen in the user's edits and says when one is worth offering as a habit: seen in
/// `threshold` dictations within `window`. What it keeps: the pattern's key (for a deleted word, that word),
/// the dictation's id, the app's name and the time. Never the text.
public struct HabitBook: Codable, Equatable, Sendable {
    public struct Sighting: Codable, Equatable, Sendable {
        public var key: String
        public var at: Date
        public var recordID: UUID
        public var app: String?

        public init(key: String, at: Date, recordID: UUID, app: String?) {
            self.key = key; self.at = at; self.recordID = recordID; self.app = app
        }
    }

    /// In how many dictations a pattern must be seen, and within how long.
    public static let threshold = 3
    public static let window: TimeInterval = 30 * 24 * 3600
    /// How long a pattern is not offered again after the user answered (declined, or accepted) an offer of it.
    public static let quiet: TimeInterval = 30 * 24 * 3600
    static let maxSightings = 300

    public var version = 1
    /// Newest first.
    public private(set) var sightings: [Sighting]
    /// When the user last answered an offer of a pattern, by its key.
    public private(set) var answered: [String: Date]

    public init(sightings: [Sighting] = [], answered: [String: Date] = [:]) {
        self.sightings = sightings; self.answered = answered
    }

    enum CodingKeys: String, CodingKey { case version, sightings, answered }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sightings = try c.decodeIfPresent([Sighting].self, forKey: .sightings) ?? []
        answered = try c.decodeIfPresent([String: Date].self, forKey: .answered) ?? [:]
    }

    public var isEmpty: Bool { sightings.isEmpty && answered.isEmpty }

    /// What the passage of dictation `recordID` shows now (`HabitDetector.patterns` against the delivered
    /// text). It replaces what was noted for that dictation before: a pattern counts once for each dictation,
    /// and one the user took back (typed the word again, put the stop back) no longer counts. Returns whether
    /// anything changed.
    @discardableResult
    public mutating func note(_ patterns: Set<HabitPattern>, recordID: UUID, app: String?, now: Date = Date()) -> Bool {
        let before = self
        sightings.removeAll { now.timeIntervalSince($0.at) > Self.window }
        answered = answered.filter { now.timeIntervalSince($0.value) <= Self.quiet }
        let keys = Set(patterns.map(\.key))
        sightings.removeAll { $0.recordID == recordID && !keys.contains($0.key) }
        let had = Set(sightings.filter { $0.recordID == recordID }.map(\.key))
        for key in keys.subtracting(had).sorted() {
            sightings.insert(Sighting(key: key, at: now, recordID: recordID, app: app), at: 0)
        }
        if sightings.count > Self.maxSightings { sightings.removeLast(sightings.count - Self.maxSightings) }
        return self != before
    }

    /// The one habit worth offering now, or nil: a pattern seen in `threshold` dictations within `window`,
    /// not answered within `quiet`, and not among `habits` already. Of several, the one seen most, then latest.
    public func suggestion(habits: [String] = [], now: Date = Date()) -> HabitSuggestion? {
        let have = Set(habits.map(Habits.fold))
        var best: (suggestion: HabitSuggestion, latest: Date)?
        let recent = sightings.filter { now.timeIntervalSince($0.at) <= Self.window }
        for (key, seen) in Dictionary(grouping: recent, by: \.key) {
            guard let pattern = HabitPattern(key: key) else { continue }
            if let last = answered[key], now.timeIntervalSince(last) <= Self.quiet { continue }
            let count = Set(seen.map(\.recordID)).count
            guard count >= Self.threshold else { continue }
            // Named for the app when it was only ever seen in one.
            let apps = Set(seen.map { $0.app ?? "" })
            let app = apps.count == 1 ? apps.first : nil
            let named = Habits.clean(pattern.wording(app: app))
            guard let habit = named ?? Habits.clean(pattern.wording()), !have.contains(Habits.fold(habit)),
                  !have.contains(Habits.fold(pattern.wording())) else { continue }
            let latest = seen.map(\.at).max() ?? now
            if let other = best, (other.suggestion.count, other.latest, other.suggestion.key) >= (count, latest, key) { continue }
            // The offer names the app only when the habit does.
            let inApp = habit != pattern.wording() ? app?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            best = (HabitSuggestion(key: key, wording: habit, count: count, app: inApp), latest)
        }
        return best?.suggestion
    }

    /// The user answered the offer of `key` (declined it, or took it): it is not offered again for `quiet`,
    /// and what was counted for it starts over.
    public mutating func answer(_ key: String, now: Date = Date()) {
        answered[key] = now
        sightings.removeAll { $0.key == key }
    }

    /// Forgets everything (自动学习 switched off, 清空).
    public mutating func clear() {
        sightings = []
        answered = [:]
    }
}
