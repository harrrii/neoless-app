import Foundation
import NeolessCloud
import NeolessCore

/// A word list and a list of fixes the user brings (two JSON files, say put together from the history of another
/// dictation app; examples/vocabulary.example.json and examples/corrections.example.json show the format): what
/// `neoless-hub import-samples` takes from them. Only the fields used here are read; any others are ignored.
public enum SampleImport {
    /// One entry of `vocabulary.json`.
    public struct Term: Decodable, Equatable, Sendable {
        public var term: String
        /// The smaller, the more important. `junkTier` and above are left out (entries marked as not worth keeping).
        public var tier: Int
        public var rank: Int

        public init(term: String, tier: Int, rank: Int) {
            self.term = term; self.tier = tier; self.rank = rank
        }
    }

    /// One entry of `corrections.json`.
    public struct Correction: Decodable, Equatable, Sendable {
        /// One or more wrong forms, separated by "/": "代码苍 / 代码舱".
        public var wrong: String
        public var right: String
        public var count: Int?
        /// When the fix was made (ISO 8601).
        public var records: [String]?
        /// high, medium or low.
        public var confidence: String

        public init(wrong: String, right: String, count: Int? = nil, records: [String]? = nil, confidence: String) {
            self.wrong = wrong; self.right = right; self.count = count; self.records = records; self.confidence = confidence
        }
    }

    struct VocabularyFile: Decodable { var terms: [Term] }
    struct CorrectionsFile: Decodable { var corrections: [Correction] }

    /// The word list's junk tier: entries its author marked as noise (a stray fragment another app once learned).
    public static let junkTier = 5

    /// What to import, and what was left out and why.
    public struct Plan: Equatable, Sendable {
        /// The words, most important first (the file's tier, then rank).
        public var words: [String] = []
        /// Left out: the junk tier.
        public var junk: [String] = []
        /// Left out: a correction below teaches it as a wrong form ("Githup" when the fixes say Githup → GitHub).
        public var misspelt: [String] = []
        /// The high-confidence corrections, one pair per wrong form.
        public var corrections: [ImportedCorrection] = []
        /// Medium and low confidence entries: not imported.
        public var unsure = 0

        public init() {}
    }

    /// Reads both files. Throws `HubSetupError` (in Chinese) when one cannot be read.
    public static func plan(vocabulary: URL, corrections: URL, now: Date = Date()) throws -> Plan {
        func load<T: Decodable>(_ type: T.Type, _ url: URL, _ what: String) throws -> T {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw HubSetupError("读不了\(what) \(url.path)")
            }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw HubSetupError("\(what) \(url.path) 的格式不对")
            }
        }
        let terms = try load(VocabularyFile.self, vocabulary, "词表").terms
        let list = try load(CorrectionsFile.self, corrections, "纠正表").corrections
        return plan(terms: terms, corrections: list, now: now)
    }

    public static func plan(terms: [Term], corrections list: [Correction], now: Date = Date()) -> Plan {
        var plan = Plan()
        plan.corrections = Self.corrections(list, now: now)
        plan.unsure = list.filter { !isHigh($0) }.count
        let wrongs = Set(plan.corrections.map { $0.pair.wrong.lowercased() })
        // A stable order: tier first, then rank, then the file's order.
        let ordered = terms.enumerated().sorted { ($0.element.tier, $0.element.rank, $0.offset) < ($1.element.tier, $1.element.rank, $1.offset) }
        var seen = Set<String>()
        for term in ordered.map(\.element) {
            let word = term.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { continue }
            if term.tier >= junkTier {
                plan.junk.append(word)
            } else if wrongs.contains(word.lowercased()) {
                plan.misspelt.append(word)
            } else {
                plan.words.append(word)
            }
        }
        return plan
    }

    static func isHigh(_ correction: Correction) -> Bool {
        correction.confidence.trimmingCharacters(in: .whitespaces).lowercased() == "high"
    }

    /// The high-confidence entries as pairs: "代码苍 / 代码舱" → 代码仓 is 代码苍→代码仓 and 代码舱→代码仓. First and last seen are
    /// the entry's record times (now when it has none that read).
    static func corrections(_ list: [Correction], now: Date) -> [ImportedCorrection] {
        var out: [ImportedCorrection] = []
        for entry in list where isHigh(entry) {
            let right = entry.right.trimmingCharacters(in: .whitespacesAndNewlines)
            let dates = (entry.records ?? []).compactMap(date(from:))
            let first = dates.min() ?? now, last = dates.max() ?? now
            for part in entry.wrong.split(separator: "/") {
                let wrong = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !wrong.isEmpty, !right.isEmpty, wrong != right,
                      wrong.count <= Vocabulary.maxWordLength, right.count <= Vocabulary.maxWordLength,
                      !(wrong + right).contains(where: \.isNewline) else { continue }
                out.append(ImportedCorrection(pair: CorrectionPair(wrong: wrong, right: right),
                                              count: max(1, entry.count ?? 1), firstSeen: first, lastSeen: last))
            }
        }
        return out
    }

    /// ISO 8601 with more than milliseconds and an offset too ("2026-01-02T03:04:05.678901+00:00"), as Python writes it.
    static func date(from text: String) -> Date? {
        if let date = HubJSON.date(from: text) { return date }
        // Fractions longer than milliseconds are cut to them.
        guard let dot = text.firstIndex(of: "."),
              let end = text[text.index(after: dot)...].firstIndex(where: { !$0.isNumber }) else { return nil }
        let digits = text[text.index(after: dot)..<end]
        return HubJSON.date(from: String(text[..<dot]) + "." + String(digits.prefix(3)) + String(text[end...]))
    }

    /// What the command prints: a few lines in Chinese.
    public static func summary(plan: Plan, result: SampleImportResult, dryRun: Bool, folder: URL) -> [String] {
        func list(_ words: [String], limit: Int = 12) -> String {
            let shown = words.prefix(limit).joined(separator: "、")
            return words.count > limit ? shown + " 等 \(words.count) 个" : shown
        }
        func pairs(_ pairs: [CorrectionPair]) -> String {
            pairs.map { "\($0.wrong)→\($0.right)" }.joined(separator: "、")
        }
        var lines = [dryRun ? "导入词表和纠正表（试运行，什么也没改）：\(folder.path)" : "导入词表和纠正表：\(folder.path)"]
        var words = "词典：\(dryRun ? "会" : "")新加 \(result.added.count) 个词（按词表的顺序，排在原有的词后面）"
        if !result.present.isEmpty { words += "，\(result.present.count) 个已经有了（位置不变）" }
        lines.append(words)
        if !result.adopted.isEmpty {
            lines.append("  原来是自动学到的、现在算你自己的词：\(list(result.adopted))")
        }
        if !result.full.isEmpty {
            lines.append("  词典满了（最多 \(Vocabulary.maxWords) 个），没加：\(list(result.full))")
        }
        if !result.tooLong.isEmpty {
            lines.append("  太长（最多 \(Vocabulary.maxWordLength) 个字），没加：\(list(result.tooLong))")
        }
        var skipped: [String] = []
        if !plan.junk.isEmpty { skipped.append("\(plan.junk.map { "“\($0)”" }.joined(separator: "、"))（词表里标成无用）") }
        if !plan.misspelt.isEmpty { skipped.append("\(plan.misspelt.map { "“\($0)”" }.joined(separator: "、"))（是错写，纠正表里把它改成正确的写法）") }
        if !skipped.isEmpty { lines.append("  没导入：" + skipped.joined(separator: "；")) }
        lines.append("  之后你自己的词共 \(result.ownWords) 个：语音识别提示用前 \(result.hintCount) 个（其中这次新加的 \(result.addedInHints) 个），"
                     + "整理提示词放得下 \(result.promptCount) 个（其中这次新加的 \(result.addedInPrompt) 个）")
        let c = result.corrections
        lines.append("纠正：\(dryRun ? "会" : "")导入 \(c.added.count) 对高把握的纠正（来源标成“导入”，可以删除；算作已确认的纠正：整理时参考，原样转写和整理失败时也直接改）"
                     + (c.added.isEmpty ? "" : "：\(pairs(c.added))"))
        if !c.present.isEmpty {
            lines.append("  已经有了（不重复导入）：\(pairs(c.present))")
        }
        if !c.conflicting.isEmpty {
            lines.append("  已经有同一个错词的别的改法（或反过来的纠正），保留原来的：\(pairs(c.conflicting))")
        }
        if !c.full.isEmpty {
            lines.append("  学习簿满了（最多 \(LearningBook.maxItems) 条），没导入：\(pairs(c.full))")
        }
        if !result.learnedTerms.isEmpty {
            lines.append("  这些纠正教的词不在词典里，作为自动学到的词加进去（删掉纠正时一起删）：\(list(result.learnedTerms))")
        }
        if plan.unsure > 0 {
            lines.append("  中等和低把握的 \(plan.unsure) 条没导入")
        }
        if dryRun {
            lines.append("去掉 --dry-run 才会真的导入。")
        } else if result.added.isEmpty && c.added.isEmpty && result.adopted.isEmpty {
            lines.append("没有要改的：这些词和纠正已经都在了。")
        } else {
            lines.append("已保存。设备下次同步时会拿到新的词典和纠正。")
        }
        return lines
    }
}
