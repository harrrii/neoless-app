import Foundation
import Testing
@testable import NeolessCore

// A word typed over another that does not sound like it (米线 → 曲线) is no recognition error by the rules,
// and one such edit teaches nothing. It is remembered, and the same swap made in another dictation is learned
// as a hint for the model: "用户两次把 X 改成 Y". Only when the two words have something in common that
// speaks for a slip of the recognizer; and what a rule forbids (numbers, dates, negation, opposites, one
// person or place for another, secrets, structural words, leftover pinyin, an everyday word for a name) is
// never learned this way either, however often it is made. All text here is made up.

/// One edit, and the swap it holds.
struct SwapRow: Sendable, CustomTestStringConvertible {
    var inserted: String
    var edited: String
    /// "错|对", or nil when nothing may be remembered.
    var swap: String?
    var known: Set<String> = []

    var testDescription: String { "\(inserted) ⇒ \(edited)" }

    var pair: CorrectionPair? {
        swap.map { text in
            let parts = text.components(separatedBy: "|")
            return CorrectionPair(wrong: parts[0], right: parts[1])
        }
    }
}

private func pair(_ s: String) -> CorrectionPair {
    let parts = s.components(separatedBy: "|")
    return CorrectionPair(wrong: parts[0], right: parts[1])
}

private let day = Date(timeIntervalSince1970: 1_790_000_000)

/// The suites for swaps made twice and for 我的习惯 (this file and HabitTests.swift) run one test at a time,
/// across all of them: every case cuts text into words, and a burst of them at the start of a run takes the
/// processor time that the timing tests of other suites count on.
@Suite(.serialized) struct SwapAndHabitTests {}

extension SwapAndHabitTests {
@Suite struct RepeatedSwapTests {
    // MARK: Learned the second time

    static let swaps: [SwapRow] = [
        SwapRow(inserted: "看一下米线", edited: "看一下曲线", swap: "米线|曲线"),
        SwapRow(inserted: "看一下曲面的走势", edited: "看一下曲线的走势", swap: "曲面|曲线"),
        SwapRow(inserted: "换个方法试试", edited: "换个办法试试", swap: "方法|办法"),
        SwapRow(inserted: "写个报告", edited: "写个报道", swap: "报告|报道"),
        SwapRow(inserted: "看看走势", edited: "看看趋势", swap: "走势|趋势"),
        // One character changed, in a word of the delivered text: the swap is that word, not the character.
        SwapRow(inserted: "看看金币是多少", edited: "看看音币是多少", swap: "金币|音币"),
        SwapRow(inserted: "推到 GitHub 上", edited: "推到 GitLab 上", swap: "GitHub|GitLab"),
        SwapRow(inserted: "用 Cloud 写", edited: "用 Claude 写", swap: "Cloud|Claude"),
        SwapRow(inserted: "这个 color 不对", edited: "这个 colour 不对", swap: "color|colour"),
    ]

    @Test(arguments: swaps)
    func aSwapIsRememberedOnceAndLearnedTheSecondTime(_ row: SwapRow) throws {
        let swap = try #require(row.pair)
        let found = CorrectionExtractor().extract(inserted: row.inserted, edited: row.edited, knownTerms: row.known)
        // By the rules it is still no fix: nothing is learned from one edit.
        #expect(found.fixes.isEmpty && found.nothing != nil, "\(fixes(found))")
        #expect(found.candidates == [swap])
        #expect(found.teaches && found.alone == [swap.right])
        // Nothing of it moves into what the next edit is compared with.
        #expect(found.baseline == row.inserted)

        var book = LearningBook()
        let first = UUID(), second = UUID()
        let noted = book.record([], candidates: found.candidates, source: .otherApp, recordID: first, now: day) { _ in false }
        #expect(noted.candidates == [swap] && noted.promoted.isEmpty && noted.learned.isEmpty && !noted.isEmpty)
        #expect(book.items.isEmpty && book.candidates.map(\.pair) == [swap])
        // Remembered is not used: not put before the model, not written into text, no word for the dictionary.
        #expect(LearningPrompt.pairs(for: row.inserted, from: book).isEmpty)
        #expect(LearningPrompt.repeated(for: row.inserted, from: book).isEmpty)
        #expect(LearningPrompt.applyConfirmed(row.inserted, book: book) == row.inserted)
        #expect(book.learnedOnlyTerms.isEmpty && !book.teaches(swap.right))

        // The same dictation again is not a second time.
        let same = book.record([], candidates: found.candidates, source: .otherApp, recordID: first, now: day) { _ in false }
        #expect(same.isEmpty && book.items.isEmpty && book.candidates.count == 1)

        // Another dictation is.
        let later = day.addingTimeInterval(3 * 86_400)
        let learned = book.record([], candidates: found.candidates, source: .otherApp, recordID: second, now: later) { _ in false }
        #expect(learned.promoted == [swap] && learned.learned.isEmpty && learned.candidates.isEmpty)
        #expect(book.candidates.isEmpty)
        let item = try #require(book.items.first)
        #expect(book.items.count == 1 && item.pair == swap && item.kind == .repeated && item.isRepeated)
        #expect(item.count == 2 && item.recordIDs == [first, second] && !item.addedTerm)

        // A hint only, for ever: listed apart, never among the fixes, never written without the model, and
        // its word is not put in the dictionary.
        #expect(LearningPrompt.repeated(for: row.inserted, from: book) == [swap])
        #expect(LearningPrompt.pairs(for: row.inserted, from: book).isEmpty)
        #expect(LearningPrompt.applyConfirmed(row.inserted, book: book) == row.inserted)
        var often = book
        often.items[0].count = 50
        #expect(LearningPrompt.applyConfirmed(row.inserted, book: often) == row.inserted)
        #expect(book.learnedOnlyTerms.isEmpty && book.learnedRanking.isEmpty && !book.teaches(swap.right))
        // It passes what is asked of a stored swap, and a bare pair is judged the same (the hub's check).
        #expect(book.unusable(knownTerms: row.known).isEmpty)
        #expect(CorrectionExtractor().isRepeatable(swap, knownTerms: row.known))
        // The rules for recognition errors still do not take it.
        #expect(CorrectionExtractor().strength(of: swap, knownTerms: row.known) != .pair)
    }

    // MARK: Never learned

    static let forbidden: [SwapRow] = [
        // Numbers and dates.
        SwapRow(inserted: "帮我订周五的票", edited: "帮我订周日的票"),
        SwapRow(inserted: "我们一起去", edited: "我们一同去"),
        SwapRow(inserted: "需要 100 美元", edited: "需要 200 美元"),
        SwapRow(inserted: "明天去北京开会", edited: "后天去北京开会"),
        SwapRow(inserted: "Tuesday 开会", edited: "Thursday 开会"),
        // Negation and opposites.
        SwapRow(inserted: "他说有效", edited: "他说无效"),
        SwapRow(inserted: "这个版本升级了", edited: "这个版本降级了"),
        SwapRow(inserted: "这里画虚线", edited: "这里画实线"),
        SwapRow(inserted: "先买入再说", edited: "先卖出再说"),
        SwapRow(inserted: "同意这个方案", edited: "拒绝这个方案"),
        SwapRow(inserted: "看看需求曲线", edited: "看看供给曲线"),
        SwapRow(inserted: "设成 public", edited: "设成 private"),
        SwapRow(inserted: "把 Enable 打开", edited: "把 Disable 打开"),
        // One of a set for another.
        SwapRow(inserted: "用红色标出来", edited: "用绿色标出来"),
        SwapRow(inserted: "换成美元", edited: "换成音币"),
        SwapRow(inserted: "发 HTML 给他", edited: "发 HTMX 给他"),
        SwapRow(inserted: "占用 CPU 太高", edited: "占用 GPU 太高"),
        // Structural words, and everyday talk.
        SwapRow(inserted: "我们去", edited: "你们去"),
        SwapRow(inserted: "请删除文件", edited: "请保留文件"),
        SwapRow(inserted: "这个方案很好", edited: "这个方案还行"),
        // An everyday word typed over with a name; what the input method left.
        SwapRow(inserted: "我想吃苹果", edited: "我想吃 Apple"),
        SwapRow(inserted: "看看金币是多少", edited: "看看yin币是多少"),
        SwapRow(inserted: "叫做牛莱斯", edited: "叫做 neoless"),
        // A passage with a secret in it.
        SwapRow(inserted: "密码是 abcdef，再看看米线", edited: "密码是 abcdef，再看看曲线"),
        // One person for another, one place for another: what changed, not what was misheard.
        SwapRow(inserted: "请把报告发给王伟。", edited: "请把报告发给李娜。"),
        SwapRow(inserted: "问一下王伟", edited: "问一下王磊"),
        SwapRow(inserted: "问一下张总", edited: "问一下李总"),
        SwapRow(inserted: "发给小王", edited: "发给小李"),
        SwapRow(inserted: "问问妈妈", edited: "问问爸爸"),
        SwapRow(inserted: "和 Eric 说", edited: "和 Erin 说"),
        SwapRow(inserted: "Ask Alice to review.", edited: "Ask Carol to review."),
        SwapRow(inserted: "去广州出差", edited: "去杭州出差"),
        SwapRow(inserted: "明天去上海", edited: "明天去深圳"),
        // Dates, amounts and opposites that no numeral and no 不 gives away.
        SwapRow(inserted: "本月交", edited: "下月交"),
        SwapRow(inserted: "记得写日报", edited: "记得写周报"),
        SwapRow(inserted: "全价买", edited: "半价买"),
        SwapRow(inserted: "他说有效", edited: "他说失效"),
        SwapRow(inserted: "这个版本合法", edited: "这个版本违法"),
        SwapRow(inserted: "审核通过了", edited: "审核失败了"),
        // Two words with nothing in common: the user said something else.
        SwapRow(inserted: "写个函数处理一下。", edited: "写个脚本处理一下。"),
        SwapRow(inserted: "看一下米线的走势。", edited: "看一下学习曲线的走势。"),
        // The typed-over word is the user's own.
        SwapRow(inserted: "我在用 Typeless 输入", edited: "我在用 Neoless 输入", known: ["Typeless", "Neoless"]),
        // Something added to a word is no swap.
        SwapRow(inserted: "做好部署", edited: "做好部署包"),
        // A rewrite.
        SwapRow(inserted: "他告诉我，今天不用给她邮件。", edited: "请明天帮我给 Martin 发邮件。"),
    ]

    @Test(arguments: forbidden)
    func whatARuleForbidsIsNeverRememberedHoweverOftenItIsMade(_ row: SwapRow) {
        var book = LearningBook()
        for n in 0..<4 {
            let found = CorrectionExtractor().extract(inserted: row.inserted, edited: row.edited, knownTerms: row.known)
            #expect(found.candidates.isEmpty, "\(found.candidates)")
            _ = book.record(found.pairs, candidates: found.candidates, source: .otherApp, recordID: UUID(),
                            now: day.addingTimeInterval(Double(n) * 86_400)) { _ in false }
        }
        #expect(book.candidates.isEmpty && !book.items.contains(where: \.isRepeated))
        #expect(LearningPrompt.repeated(for: row.inserted, from: book).isEmpty)
    }

    /// Pairs as they arrive without their text (the hub's check, and what is asked of a stored swap).
    static let allowedPairs = [
        "米线|曲线", "方法|办法", "金币|音币", "报告|报道", "走势|趋势", "草稿|初稿", "代码厂|代码仓", "操作说明书|使用说明书",
        // No character in common, but every syllable sounds close.
        "机会|计划",
        "GitHub|GitLab", "Cloud|Claude", "color|colour", "Cloud Opus Preview|Claude Opus Preview",
        // The same name spelled out is still that person.
        "Jon|John",
        "派森|Python",
    ]

    static let refusedPairs = [
        // Numbers, amounts, dates.
        "周五|周日", "三百|三千", "一起|一同", "第一|首先", "今天|明天", "上午|下午", "周末|周日", "GPT4|GPT5",
        "Tuesday|Thursday", "twenty|thirty", "美元|欧元", "美元|日元", "英镑|港币", "小时|分钟",
        // Negation and opposites.
        "有效|无效", "不行|步行", "没空|有空", "买入|卖出", "虚线|实线", "升值|贬值", "通胀|通缩",
        "需求|供给", "本币|外币", "同意|拒绝", "支持|反对", "成功|失败", "红色|绿色", "春天|秋天", "deposit|withdraw", "profit|loss",
        "Enable|Disable", "likely|unlikely", "can|can't", "true|false",
        // Structural words; everyday talk in single characters.
        "我们|你们", "删除|保留", "然后|接着", "很好|还行", "the|a",
        // Secrets and addresses.
        "密码|口令", "fo@example.com|foo@example.com",
        // One acronym for another.
        "CPU|GPU", "HTML|HTMX", "SSL|SSH",
        // An everyday word for a name, a name put into Chinese, mixed writing.
        "苹果|Apple", "你好|Nio", "Taobao|淘宝", "欧盆AI|OpenAI",
        // What the input method left.
        "金币|yin币", "金币|YINBI", "牛莱斯|neoless",
        // Too little, too much, formatting, something only added or taken off.
        "先|西安", "金|音", "Open Air|OpenAI", "cursor|Cursor", "部署|部署包", "这是一个很长很长的说法|这是另外一个很长的说法",
        "你好，世界|你好。世界", "a b c d|e f g h",
        // One person for another.
        "王伟|李娜", "王伟|王磊", "张总|李总", "王经理|李经理", "王哥|李哥", "小王|小李", "小明|小红", "老张|老蒋", "小李|小林",
        "妈妈|爸爸", "老婆|老公", "Eric|Erin", "Alice|Carol", "Tim Cook|Tom Brook",
        // One place for another.
        "广州|杭州", "上海|深圳", "徐州|台州", "德国|法国", "英国|美国", "伦敦|巴黎", "济南|海南", "山东|广东", "长沙|长春",
        "Boston|Chicago",
        // Dates and times no numeral gives away.
        "春节|国庆", "本月|下月", "寒假|暑假", "白天|夜里", "日报|周报", "当天|次日", "每周|每月",
        "月底|年底", "week|month", "weekly|monthly", "morning|evening", "morning|afternoon", "spring|autumn",
        // Amounts and sizes.
        "全价|半价", "翻倍|减半", "定金|全款", "dollars|euros", "dollars|pounds",
        // Opposites no 不 gives away.
        "同意|否决", "通过|失败", "有效|失效", "合法|违法", "接受|谢绝", "参加|缺席",
        "收入|支出", "准时|晚点", "approve|reject", "confirm|cancel", "safe|dangerous", "correct|wrong",
        // Nothing in common: the user said something else.
        "函数|脚本", "米线|学习", "米线|学习曲线", "代码|脚本", "漂亮|好看", "金币|金字塔",
    ]

    @Test(arguments: allowedPairs)
    func aBarePairNoRuleForbidsMayBeLearnedAsMadeTwice(_ text: String) {
        #expect(CorrectionExtractor().isRepeatable(pair(text)), "\(text)")
    }

    @Test(arguments: refusedPairs)
    func aBarePairARuleForbidsIsRefused(_ text: String) {
        #expect(!CorrectionExtractor().isRepeatable(pair(text)), "\(text)")
    }

    @Test func aWordOfTheUsersOwnDictionaryIsNeverTheTypedOverSide() {
        let extractor = CorrectionExtractor()
        #expect(extractor.isRepeatable(pair("Typeless|Neoless")))
        #expect(!extractor.isRepeatable(pair("Typeless|Neoless"), knownTerms: ["typeless"]))
        #expect(!extractor.isRepeatable(pair("米线|曲线"), knownTerms: ["米线"]))
        // The corrected side in the dictionary is no reason against it.
        #expect(extractor.isRepeatable(pair("米线|曲线"), knownTerms: ["曲线"]))
        // A stored swap whose typed-over side became the user's own word is no longer used.
        let book = LearningBook(items: [LearnedCorrection(pair: pair("米线|曲线"), count: 2, firstSeen: day, lastSeen: day,
                                                          source: .otherApp, addedTerm: false, kind: .repeated)])
        #expect(book.unusable(knownTerms: []).isEmpty)
        #expect(book.unusable(knownTerms: ["米线"]) == [LearningBook.key(pair("米线|曲线"))])
    }

    // MARK: The book

    @Test func withoutARecordNothingIsEverASecondTime() {
        var book = LearningBook()
        let swap = pair("米线|曲线")
        for n in 0..<3 {
            _ = book.record([], candidates: [swap], source: .otherApp, recordID: nil, now: day.addingTimeInterval(Double(n))) { _ in false }
        }
        #expect(book.items.isEmpty && book.candidates.map(\.pair) == [swap])
        // Nor when only one of the two has a record.
        _ = book.record([], candidates: [swap], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(book.items.isEmpty && book.candidates.count == 1)
    }

    @Test func undoingTheEditTakesItBack() throws {
        var book = LearningBook()
        let swap = pair("米线|曲线")
        let first = UUID(), second = UUID()
        let noted = book.record([], candidates: [swap], source: .otherApp, recordID: first, now: day) { _ in false }
        var undone = book
        undone.undo(noted)
        #expect(undone.candidates.isEmpty && undone.items.isEmpty)

        let learned = book.record([], candidates: [swap], source: .otherApp, recordID: second, now: day) { _ in false }
        #expect(book.items.count == 1 && book.candidates.isEmpty)
        #expect(learned.aloneWords == ["曲线"])
        // The second edit undone: the first sighting waits again.
        book.undo(learned)
        #expect(book.items.isEmpty && book.candidates.map(\.pair) == [swap] && book.candidates.first?.recordID == first)
        // The user deleted the row.
        let removed = book.removeCandidate(pair("米线|曲线"))
        #expect(removed?.pair == swap && book.candidates.isEmpty)
        let nothing = book.removeCandidate(swap)
        #expect(nothing == nil)
    }

    @Test func changingItBackTakesItBack() {
        var book = LearningBook()
        let swap = pair("米线|曲线"), back = pair("曲线|米线")
        // Before it was learned: the note goes, and the reverse is not remembered in its place.
        _ = book.record([], candidates: [swap], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        let event = book.record([], candidates: [back], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(book.candidates.isEmpty && book.items.isEmpty && event.candidates.isEmpty && !event.isEmpty)
        // After: one change back leaves a single sighting, which is no evidence.
        _ = book.record([], candidates: [swap], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        _ = book.record([], candidates: [swap], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(book.items.map(\.count) == [2])
        let reversed = book.record([], candidates: [back], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(reversed.reversed == [swap] && book.items.isEmpty && book.candidates.isEmpty)
        // Made a third time it counts on; then one change back still leaves two.
        for _ in 0..<3 { _ = book.record([], candidates: [swap], source: .otherApp, recordID: UUID(), now: day) { _ in false } }
        #expect(book.items.map(\.count) == [3])
        _ = book.record([], candidates: [back], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(book.items.map(\.count) == [2] && book.items[0].isRepeated)
    }

    @Test func aNoteWaitsOnlySoLongAndOnlySoManyAreKept() {
        var book = LearningBook()
        let swap = pair("米线|曲线")
        _ = book.record([], candidates: [swap], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        // Long after: a first time again, not a second.
        let late = day.addingTimeInterval(LearningBook.candidateLifetime + 86_400)
        let again = book.record([], candidates: [swap], source: .otherApp, recordID: UUID(), now: late) { _ in false }
        #expect(again.candidates == [swap] && again.promoted.isEmpty && book.items.isEmpty)
        #expect(book.candidates.count == 1 && book.candidates[0].seen == late)
        var old = LearningBook(candidates: [LearningBook.Candidate(pair: swap, seen: day, recordID: nil)])
        let expired = old.expireCandidates(now: late)
        #expect(expired && old.candidates.isEmpty)
        let again2 = old.expireCandidates(now: late)
        #expect(!again2)

        var many = LearningBook()
        for n in 0..<(LearningBook.maxCandidates + 10) {
            _ = many.record([], candidates: [CorrectionPair(wrong: "词\(n)甲", right: "词\(n)乙")], source: .otherApp,
                            recordID: UUID(), now: day.addingTimeInterval(Double(n))) { _ in false }
        }
        #expect(many.candidates.count == LearningBook.maxCandidates)
        #expect(many.candidates.first?.pair.wrong == "词\(LearningBook.maxCandidates + 9)甲")
    }

    @Test func theDaysLimitHoldsForSwapsToo() {
        var book = LearningBook()
        for n in 0..<LearningBook.maxNewPerDay {
            _ = book.record([CorrectionPair(wrong: "错\(n)", right: "对\(n)")], source: .otherApp, recordID: nil, now: day) { _ in false }
        }
        let swap = pair("米线|曲线")
        _ = book.record([], candidates: [swap], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        let event = book.record([], candidates: [swap], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(event.overLimit == ["曲线"] && event.promoted.isEmpty && !book.items.contains(where: \.isRepeated))
        // The note is still there, for tomorrow.
        #expect(book.candidates.map(\.pair) == [swap])
        let tomorrow = book.record([], candidates: [swap], source: .otherApp, recordID: UUID(), now: day.addingTimeInterval(86_400)) { _ in false }
        #expect(tomorrow.promoted == [swap])
    }

    @Test func aFixByTheRulesNeedsNoSecondTime() {
        // The dictionary changed and the rules take the pair now: the note has nothing left to wait for.
        var book = LearningBook()
        let swap = pair("金币|音币")
        _ = book.record([], candidates: [swap], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        let event = book.record([swap], source: .otherApp, recordID: UUID(), now: day) { _ in true }
        #expect(event.learned == [swap] && book.candidates.isEmpty)
        #expect(book.items.map(\.kind) == [nil])
        var undone = book
        undone.undo(event)
        #expect(undone.items.isEmpty && undone.candidates.map(\.pair) == [swap])
        // A correction the rules learned is not turned into a hint by a swap seen later.
        let later = book.record([], candidates: [swap], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(later.isEmpty && book.items.map(\.kind) == [nil] && book.items.map(\.count) == [1])
    }

    @Test func aDeviceThatSawItTwiceTeachesItAtOnce() throws {
        // The hub: a swap arrives as made twice (`LearningObservations.kind`).
        var book = LearningBook()
        let swap = pair("米线|曲线")
        let record = UUID()
        let event = book.record([], repeated: [swap], source: .otherApp, recordID: record, now: day) { _ in false }
        #expect(event.promoted == [swap] && event.learned.isEmpty)
        let item = try #require(book.items.first)
        #expect(item.isRepeated && item.count == 2 && !item.addedTerm && item.recordIDs == [record])
        // Sent again for the same dictation it is not counted again; for another it is.
        _ = book.record([], repeated: [swap], source: .otherApp, recordID: record, now: day) { _ in false }
        #expect(book.items.map(\.count) == [2])
        _ = book.record([], repeated: [swap], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(book.items.map(\.count) == [3])
        // Taken back there: the reverse counts it down, and below two it is gone.
        #expect(book.countsDown(pair("曲线|米线")))
        _ = book.record([pair("曲线|米线")], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        _ = book.record([pair("曲线|米线")], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(book.items.isEmpty)
    }

    @Test func storedSwapsAreJudgedByWhatNoRuleAllows() {
        // Whatever stored it (an older version, another device): a swap a rule forbids is used for nothing.
        let bad = ["周五|周日", "有效|无效", "买入|卖出", "虚线|实线", "HTML|HTMX", "苹果|Apple", "广州|杭州", "Eric|Erin", "函数|脚本"]
        let good = ["米线|曲线", "Cloud|Claude"]
        let book = LearningBook(items: (bad + good).map {
            LearnedCorrection(pair: pair($0), count: 5, firstSeen: day, lastSeen: day, source: .otherApp, addedTerm: false, kind: .repeated)
        })
        let off = book.unusable(knownTerms: [])
        #expect(off == Set(bad.map { LearningBook.key(pair($0)) }))
        let used = book.without(off)
        #expect(LearningPrompt.repeated(for: "周五买入有效的苹果，看米线", from: used) == [pair("米线|曲线")])
        // And a swap is not judged as a recognition error, which it is not: as one, none of these would pass.
        var asFixes = book
        for i in asFixes.items.indices { asFixes.items[i].kind = nil }
        #expect(asFixes.unusable(knownTerms: []).count == bad.count + good.count)
    }

    @Test func theBookReadsOlderAndNewerFiles() throws {
        // From before swaps were remembered: no `candidates`, no `kind`.
        let old = #"{"version":1,"items":[{"id":"11111111-2222-3333-4444-555555555555","pair":{"wrong":"引必","right":"音币"},"count":2,"firstSeen":0,"lastSeen":0,"source":"otherApp","addedTerm":true,"recordIDs":[]}]}"#
        let book = try JSONDecoder().decode(LearningBook.self, from: Data(old.utf8))
        #expect(book.candidates.isEmpty && book.items.map(\.kind) == [nil] && !book.items[0].isRepeated)
        // A kind this version does not know still reads, and is no swap made twice.
        let newer = old.replacingOccurrences(of: #""recordIDs":[]"#, with: #""recordIDs":[],"kind":"something-new""#)
        let read = try JSONDecoder().decode(LearningBook.self, from: Data(newer.utf8))
        #expect(read.items[0].kind?.rawValue == "something-new" && !read.items[0].isRepeated)

        var now = LearningBook()
        _ = now.record([], candidates: [pair("米线|曲线")], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        _ = now.record([], candidates: [pair("米线|曲线"), pair("方法|办法")], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        let data = try JSONEncoder().encode(now)
        #expect(try JSONDecoder().decode(LearningBook.self, from: data) == now)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""kind":"repeated""#) && text.contains(#""candidates""#))
        // Only the two words and a date are kept of a swap: never the text around it.
        #expect(!text.contains("看一下") && !text.contains("试试"))
    }

    // MARK: Following the edit

    @Test func theTrackerComparesARememberedSwapAgainWithWhatWasDelivered() {
        let extractor = CorrectionExtractor()
        var t = EditTracker(original: "看看金币是多少")
        // A wrong candidate of the input method on the way: remembered for now.
        guard case let .extract(inserted, edited) = t.settle("看看瘾币是多少") else {
            Issue.record("no comparison")
            return
        }
        let found = extractor.extract(inserted: inserted, edited: edited)
        #expect(found.candidates == [pair("金币|瘾币")])
        t.commit(edited, over: inserted, understood: found.baseline, alone: found.alone)
        // The baseline is still what was delivered.
        #expect(t.baseline == "看看金币是多少")
        // The text no longer shows it: what remembered it is taken back, and the whole change is compared.
        #expect(t.withdrawn(from: "看看音币是多少") == ["瘾币"])
        guard case let .extract(from, to) = t.settle("看看音币是多少") else {
            Issue.record("no second comparison")
            return
        }
        #expect(from == "看看金币是多少")
        #expect(extractor.extract(inserted: from, edited: to).candidates == [pair("金币|音币")])
        // With the word in the dictionary the rules take it, as before.
        #expect(extractor.extract(inserted: from, edited: to, knownTerms: ["音币"]).pairs == [pair("金币|音币")])
    }

    @Test func backAtTheDeliveredTextARememberedSwapIsTakenBack() {
        // The baseline never moved for it, so the delivered text is no change from the baseline: it is still
        // the user taking the edit back.
        let extractor = CorrectionExtractor()
        var t = EditTracker(original: "看一下米线")
        guard case let .extract(inserted, edited) = t.settle("看一下曲线") else {
            Issue.record("no comparison")
            return
        }
        let found = extractor.extract(inserted: inserted, edited: edited)
        #expect(found.candidates == [pair("米线|曲线")])
        t.commit(edited, over: inserted, understood: found.baseline, alone: found.alone)
        #expect(t.baseline == "看一下米线")
        // The same edited text again (an undo and a redo land on it): nothing new, nothing taken back.
        #expect(t.settle("看一下曲线") == .none)
        #expect(t.withdrawn(from: "看一下米线").isEmpty)
        #expect(t.settle("看一下米线") == .retract)
        // Once: the text staying as delivered says nothing more.
        #expect(t.settle("看一下米线") == .none)
        // A tracker nothing was committed in has nothing to take back.
        var fresh = EditTracker(original: "看一下米线")
        #expect(fresh.settle("看一下米线") == .none)
    }

    @Test func aFixAndASwapInOneEditAreToldApart() {
        let found = CorrectionExtractor().extract(inserted: "用 Open Air 看一下米线", edited: "用 OpenAI 看一下曲线")
        #expect(found.pairs == [pair("Open Air|OpenAI")] && found.nothing == nil)
        #expect(found.candidates == [pair("米线|曲线")])
        // Only the fix moves into the baseline: the swap is compared again with what was delivered.
        #expect(found.baseline == "用 OpenAI 看一下米线")
        #expect(found.alone == ["曲线"])
    }

    // MARK: What speaks for a slip, and what is a name

    @Test func twoWordsMustHaveSomethingInCommon() {
        // The same characters in the same places for at least half of the longer word, from either end.
        for alike in ["米线|曲线", "报告|报道", "代码厂|代码仓", "操作说明书|使用说明书"] {
            let swap = pair(alike)
            #expect(CorrectionExtractor.resembles(swap.wrong, swap.right), "\(alike)")
        }
        // Or as many syllables, each close to the one it replaced.
        #expect(CorrectionExtractor.resembles("机会", "计划"))
        // Not one shared character of three, not a word a character longer with one in common, not words of
        // quite different lengths, not two words with nothing in common.
        for unlike in ["金币|金字塔", "米线|学习曲线", "函数|脚本", "上海|深圳", "接受|谢绝", "曲面|曲线图"] {
            let swap = pair(unlike)
            #expect(!CorrectionExtractor.resembles(swap.wrong, swap.right), "\(unlike)")
        }
        // Latin letters: at most half of them differ.
        #expect(CorrectionExtractor.resembles("Cloud", "Claude") && CorrectionExtractor.resembles("GitHub", "GitLab"))
        for unlike in ["Alice|Carol", "week|month", "approve|reject", "Boston|Chicago"] {
            let swap = pair(unlike)
            #expect(!CorrectionExtractor.resembles(swap.wrong, swap.right), "\(unlike)")
        }
        // Characters that make no word, for a name: `isRepeatable` has looked at them.
        #expect(CorrectionExtractor.resembles("派森", "Python") && !CorrectionExtractor.resembles("Taobao", "淘宝"))
    }

    @Test func whatTheSystemTakesForTwoNamesIsRefused() {
        // Names no list has: what the system's tagger says of both words. Asked last, and only ever a reason
        // to refuse. (Injected here, so the test does not depend on which names this system knows.)
        let swap = pair("米线|曲线")
        func extractor(_ kinds: [String: CorrectionExtractor.NameKind]) -> CorrectionExtractor {
            CorrectionExtractor(nameKind: { kinds[$0] })
        }
        #expect(extractor([:]).isRepeatable(swap))
        #expect(!extractor(["米线": .place, "曲线": .place]).isRepeatable(swap))
        #expect(!extractor(["米线": .person, "曲线": .person]).isRepeatable(swap))
        // One name and one word, or two names of different kinds, are not one for another.
        #expect(extractor(["曲线": .person]).isRepeatable(swap))
        #expect(extractor(["米线": .place, "曲线": .organization]).isRepeatable(swap))
        // Without the tagger the lists still refuse what they have.
        let plain = extractor([:])
        for listed in ["广州|杭州", "王伟|王磊", "张总|李总", "小王|小李", "徐州|台州", "妈妈|爸爸"] {
            #expect(!plain.isRepeatable(pair(listed)), "\(listed)")
        }
        // A word that only begins with a family name is no person (方法, 金币), and neither is 老 before a word.
        #expect(!plain.isPersonLike("方法") && !plain.isPersonLike("金币") && !plain.isPersonLike("老实"))
        #expect(plain.isPersonLike("王伟") && plain.isPersonLike("张总") && plain.isPersonLike("小李") && plain.isPersonLike("李经理"))
    }

    // MARK: The same swap is the same pair

    static let frames: [[String]] = [
        // A capitalized word next to the name is no part of it.
        ["Ask Cloud to review.", "Ask Claude to review.", "I think Cloud should review.", "I think Claude should review.", "Cloud|Claude"],
        ["Cloud Team is here", "Claude Team is here", "用 Cloud 写", "用 Claude 写", "Cloud|Claude"],
        // Nor is the word after it, which the corrected text happens to join differently (脚|本来).
        ["写一个脚步来处理输入。", "写一个脚本来处理输入。", "这个脚步写得不错", "这个脚本写得不错", "脚步|脚本"],
        ["换成金币多少钱", "换成音币多少钱", "看看金币多不多", "看看音币多不多", "金币|音币"],
        ["今天米线的走势不错", "今天曲线的走势不错", "米线画得很平", "曲线画得很平", "米线|曲线"],
    ]

    @Test(arguments: frames)
    func theSameSwapInAnotherSentenceIsItsSecondTime(_ row: [String]) throws {
        let swap = pair(row[4])
        let extractor = CorrectionExtractor()
        var book = LearningBook()
        let first = extractor.extract(inserted: row[0], edited: row[1])
        #expect(first.candidates == [swap], "\(first.candidates)")
        let noted = book.record([], candidates: first.candidates, source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(noted.candidates == [swap])
        let second = extractor.extract(inserted: row[2], edited: row[3])
        #expect(second.candidates == [swap], "\(second.candidates)")
        let learned = book.record([], candidates: second.candidates, source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(learned.promoted == [swap] && book.candidates.isEmpty && book.items.map(\.pair) == [swap])
    }

    @Test func aNameTheDictionaryHasWithItsNeighbourIsThatPhrase() {
        // Only then do the unchanged words next to the change belong to it.
        let extractor = CorrectionExtractor()
        #expect(extractor.extract(inserted: "Cloud Code is good", edited: "Claude Code is good").candidates == [pair("Cloud|Claude")])
        let known = extractor.extract(inserted: "Cloud Code is good", edited: "Claude Code is good", knownTerms: ["Claude Code"])
        #expect(known.fixes.map(\.pair) == [pair("Cloud Code|Claude Code")] && known.candidates.isEmpty)
    }

    // MARK: A swap the passage no longer shows

    /// One dictation's passage through its settled states, as `CorrectionObserver` and the hub follow it:
    /// what an earlier state remembered that the latest comparison no longer finds is taken back.
    private func follow(_ original: String, _ states: [String], record: UUID, book: inout LearningBook) {
        let extractor = CorrectionExtractor()
        var tracker = EditTracker(original: original)
        var events: [LearningEvent] = []
        for text in states {
            _ = tracker.withdrawn(from: text)
            guard case let .extract(inserted, edited) = tracker.settle(text) else { continue }
            let found = extractor.extract(inserted: inserted, edited: edited)
            for event in events.reversed() where event.holdsSwap(goneFrom: found) {
                book.undo(event)
                events.removeAll { $0.id == event.id }
            }
            if found.teaches { tracker.commit(edited, over: inserted, understood: found.baseline, alone: found.alone) }
            let event = book.record(found.pairs, candidates: found.candidates, source: .otherApp, recordID: record, now: day) { _ in false }
            if !event.isEmpty { events.append(event) }
        }
    }

    @Test func aWordTypedInTwoHalvesLeavesNothingBehind() {
        // 曲线, a pause, then 曲线图: the first half was remembered, and the word it became is no swap.
        // `withdrawn` cannot tell (曲线 still stands in 曲线图); the comparison can.
        var book = LearningBook()
        follow("看一下曲面的走势", ["看一下曲线的走势"], record: UUID(), book: &book)
        #expect(book.candidates.map(\.pair) == [pair("曲面|曲线")])
        book = LearningBook()
        for _ in 0..<2 {
            follow("看一下曲面的走势", ["看一下曲线的走势", "看一下曲线图的走势"], record: UUID(), book: &book)
            #expect(book.candidates.isEmpty && book.items.isEmpty)
        }
    }

    @Test func aSwapChangedBackIsGoneThoughItsWordStandsElsewhere() {
        let delivered = "先看米线，再对比曲线的斜率，然后下单。"
        var book = LearningBook()
        // Changed, then changed back while something else was deleted: 曲线 still stands further on, and the
        // text is not as delivered, so nothing but the comparison says the swap is gone.
        follow(delivered, ["先看曲线，再对比曲线的斜率，然后下单。", "先看米线，再对比曲线的斜率，下单。"], record: UUID(), book: &book)
        #expect(book.candidates.isEmpty)
        // One more dictation with that swap is then a first time, not a second.
        follow(delivered, ["先看曲线，再对比曲线的斜率，然后下单。"], record: UUID(), book: &book)
        #expect(book.items.isEmpty && book.candidates.map(\.pair) == [pair("米线|曲线")])
        // Kept in two dictations, it is learned.
        follow(delivered, ["先看曲线，再对比曲线的斜率，然后下单。"], record: UUID(), book: &book)
        #expect(book.items.map(\.pair) == [pair("米线|曲线")] && book.candidates.isEmpty)
    }

    @Test func whileASwapIsRememberedADeletionIsComparedAtOnce() {
        var t = EditTracker(original: "先看米线，然后下单")
        // Nothing remembered: a deletion waits for what is typed in its place.
        #expect(t.settle("先看米线，下单") == .none && t.removesOnly("先看米线，下单"))
        guard case let .extract(inserted, edited) = t.settle("先看曲线，然后下单") else {
            Issue.record("no comparison")
            return
        }
        let found = CorrectionExtractor().extract(inserted: inserted, edited: edited)
        #expect(found.candidates == [pair("米线|曲线")])
        t.commit(edited, over: inserted, understood: found.baseline, alone: found.alone)
        // Now the same deletion is handed out, with the delivered text to compare it with.
        #expect(!t.removesOnly("先看米线，下单"))
        #expect(t.settle("先看米线，下单") == .extract(inserted: "先看米线，然后下单", edited: "先看米线，下单"))
        // Once: the text staying so says nothing more.
        #expect(t.settle("先看米线，下单") == .none)
    }

    @Test func moreTypedNextToASwapDoesNotTakeItBack() {
        // The user went on typing right after the word: the change is one longer stretch now and no swap by
        // the rules, but the swap is still there, as a word of its own.
        let extractor = CorrectionExtractor()
        let swap = pair("米线|曲线")
        for later in ["看一下曲线吧", "看一下曲线的走势怎么样", "看一下曲线，再说"] {
            let found = extractor.extract(inserted: "看一下米线", edited: later)
            #expect(found.shows(swap), "\(later)")
        }
        var book = LearningBook()
        follow("看一下米线", ["看一下曲线", "看一下曲线吧", "看一下曲线的走势怎么样"], record: UUID(), book: &book)
        #expect(book.candidates.map(\.pair) == [swap])
        // Gone: the word grew into a longer one, something else stands there, the delivered word is back,
        // the passage was rewritten.
        #expect(!extractor.extract(inserted: "看一下曲面的走势", edited: "看一下曲线图的走势").shows(pair("曲面|曲线")))
        #expect(!extractor.extract(inserted: "看一下米线", edited: "看一下趋势").shows(swap))
        #expect(!extractor.extract(inserted: "看一下米线，然后下单", edited: "看一下米线，下单").shows(swap))
        #expect(!extractor.extract(inserted: "看一下米线", edited: "今天不想看盘了，出去走走，回来再说别的事情吧").shows(swap))
        // A word of its own: bounded by the ends, by what is no Han, or by a character that is a word itself.
        #expect(CorrectionExtractor.standsAlone("曲线", in: "曲线") && CorrectionExtractor.standsAlone("曲线", in: "曲线吧"))
        #expect(CorrectionExtractor.standsAlone("曲线", in: "看曲线的走势") && CorrectionExtractor.standsAlone("Claude", in: "用Claude写"))
        #expect(!CorrectionExtractor.standsAlone("曲线", in: "曲线图") && !CorrectionExtractor.standsAlone("曲线", in: "双曲线"))
        #expect(!CorrectionExtractor.standsAlone("学习", in: "学习曲线") && !CorrectionExtractor.standsAlone("Cla", in: "Claude"))
    }

    @Test func everySwapOfAnEditIsListed() {
        // Four swaps in one edit: all are listed, and the book takes three of them at once.
        let found = CorrectionExtractor().extract(inserted: "用 Cloud 和 GitHub，还有 Typeless 和 Curser",
                                                  edited: "用 Claude 和 GitLab，还有 Neoless 和 Cursor")
        let all = [pair("Cloud|Claude"), pair("GitHub|GitLab"), pair("Typeless|Neoless"), pair("Curser|Cursor")]
        #expect(found.candidates == all, "\(found.candidates)")
        #expect(all.allSatisfy(found.shows))
        var book = LearningBook()
        let event = book.record([], candidates: found.candidates, source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(event.candidates.count == LearningBook.maxPairsPerEvent && event.swaps == event.candidates)
        #expect(!event.holdsSwap(goneFrom: found) && event.holdsSwap(goneFrom: Extraction(nothing: .rewrite)))
    }

    // MARK: Used with the corrections, and held elsewhere

    @Test func aHintNeverDisplacesACorrection() {
        func item(_ s: String, count: Int, secondsAgo: Double, kind: LearnedCorrection.Kind? = nil) -> LearnedCorrection {
            let at = day.addingTimeInterval(-secondsAgo)
            return LearnedCorrection(pair: pair(s), count: count, firstSeen: at, lastSeen: at, source: .otherApp, addedTerm: false, kind: kind)
        }
        // 金币 → 音币 was fixed in five dictations; then 金笔 was typed over 金币 twice. The correction stays.
        let book = LearningBook(items: [item("金币|音币", count: 5, secondsAgo: 100), item("金币|金笔", count: 2, secondsAgo: 0, kind: .repeated)])
        #expect(LearningPrompt.pairs(for: "这枚金币什么时候寄到", from: book) == [pair("金币|音币")])
        #expect(LearningPrompt.repeated(for: "这枚金币什么时候寄到", from: book).isEmpty)
        // Alone, the swap is the hint it was.
        #expect(LearningPrompt.repeated(for: "这枚金币什么时候寄到", from: LearningBook(items: [book.items[1]])) == [pair("金币|金笔")])
        // Ten corrections and six swaps in one transcript: all ten corrections, and four of the swaps.
        let fixes = (0..<10).map { item("错\($0)字|对\($0)字", count: 2, secondsAgo: Double($0)) }
        let swaps = (0..<6).map { item("甲\($0)词|乙\($0)词", count: 9, secondsAgo: Double($0), kind: .repeated) }
        let said = (fixes + swaps).map(\.pair.wrong).joined(separator: "，")
        let full = LearningBook(items: swaps + fixes)
        #expect(LearningPrompt.pairs(for: said, from: full).count == LearningPrompt.maxPairs)
        #expect(LearningPrompt.repeated(for: said, from: full).map(\.wrong) == ["甲0词", "甲1词", "甲2词", "甲3词"])
        #expect(LearningPrompt.maxRepeated == 4 && LearningPrompt.repeated(for: said, from: full).count == LearningPrompt.maxRepeated)
    }

    @Test func aSwapHeldElsewhereIsNeitherRememberedNorLearnedAgainHere() {
        // The Neo holds 方法 → 办法 as made twice (another device taught it): in use already.
        let held = pair("方法|办法"), back = pair("办法|方法")
        var book = LearningBook()
        let made = book.record([], candidates: [held], source: .otherApp, recordID: UUID(), now: day,
                               heldElsewhere: [held], repeatedElsewhere: [held]) { _ in false }
        #expect(made.isEmpty && book.candidates.isEmpty && book.items.isEmpty)
        // A note of it from before the Neo learned it has nothing left to wait for.
        _ = book.record([], candidates: [held], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(book.candidates.count == 1)
        let again = book.record([], candidates: [held], source: .otherApp, recordID: UUID(), now: day,
                                heldElsewhere: [held], repeatedElsewhere: [held]) { _ in false }
        #expect(book.candidates.isEmpty && book.items.isEmpty && again.candidates.isEmpty && again.promoted.isEmpty)
        // Another swap is remembered as ever.
        let other = book.record([], candidates: [pair("米线|曲线")], source: .otherApp, recordID: UUID(), now: day,
                                heldElsewhere: [held], repeatedElsewhere: [held]) { _ in false }
        #expect(other.candidates == [pair("米线|曲线")])
        // Changed back here: weakened where it is held, and known to be a swap.
        let reversed = book.record([], candidates: [back], source: .otherApp, recordID: UUID(), now: day,
                                   heldElsewhere: [held], repeatedElsewhere: [held]) { _ in false }
        #expect(reversed.reversed == [held] && reversed.reversedSwaps == [held])
    }

    @Test func undoingAChangeBackRestoresASwapAsASwap() {
        // What an event counted down goes up again when it is undone, each as what it is: sent to the Neo as
        // a plain correction, a swap made twice would be judged as a recognition error and refused.
        let swap = pair("米线|曲线"), fix = pair("引必|音币")
        var book = LearningBook(items: [
            LearnedCorrection(pair: swap, count: 2, firstSeen: day, lastSeen: day, source: .otherApp, addedTerm: false, kind: .repeated),
            LearnedCorrection(pair: fix, count: 3, firstSeen: day, lastSeen: day, source: .otherApp, addedTerm: true),
        ])
        let event = book.record([pair("音币|引必")], candidates: [pair("曲线|米线")], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(Set(event.reversed) == [swap, fix] && event.reversedSwaps == [swap])
        #expect(event.reversedByKind.fixes == [fix] && event.reversedByKind.swaps == [swap])
        #expect(book.items.map(\.pair) == [fix] && book.items.map(\.count) == [2])
        book.undo(event)
        #expect(Set(book.items.map(\.pair)) == [swap, fix] && book.items.first { $0.pair == swap }?.isRepeated == true)
        // The reverse of a swap sent as a plain pair (as the Neo gets a count-down) is one too.
        var hub = LearningBook()
        _ = hub.record([], repeated: [swap], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        let down = hub.record([pair("曲线|米线")], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(down.reversed == [swap] && down.reversedSwaps == [swap] && hub.items.isEmpty)
    }

    @Test func whatThePicturesShowAsRememberedIsRemembered() {
        // The app's snapshots show these as remembered or learned as made twice: the rules must agree.
        let extractor = CorrectionExtractor()
        for swap in LearningSamples.swaps {
            #expect(extractor.isRepeatable(swap), "\(swap.wrong) → \(swap.right)")
            #expect(extractor.strength(of: swap) != .pair)
        }
        #expect(Set(LearningSamples.swaps.map(LearningBook.key)).count == LearningSamples.swaps.count)
    }

    // MARK: Saying it

    @Test func theLinesSayWhatHappened() {
        let swap = pair("米线|曲线")
        #expect(LearningText.noted(pairs: [swap]) == "记下了：米线 → 曲线，再这样改一次就记住")
        #expect(LearningText.noted(pairs: [swap], fits: { $0.count <= 16 }) == "记下了：曲线，再改一次就记住")
        #expect(LearningText.noted(pairs: [swap], fits: { $0.count <= 12 }) == "记下了，再改一次就记住")
        #expect(LearningText.noted(pairs: [swap, pair("方法|办法")]) == "记下了：米线 → 曲线、方法 → 办法，再这样改一次就记住")
        #expect(LearningText.learned(pairs: [swap]) == "已记住：米线 → 曲线")
        #expect(CapsuleText.kind(done: LearningText.noted(pairs: [swap])) == .note)
        #expect(CapsuleText.kind(done: LearningText.learned(pairs: [swap])) == .learned)

        #expect(LearningText.line(code: LearningLog.Code.candidate.rawValue, count: 1) == "换了词，记下了：再这样改一次就记住")
        #expect(LearningText.line(code: LearningLog.Code.repeated.rawValue, count: 1) == "同样的词又改了一次，记住了 1 个")
        #expect(LearningText.line(code: LearningLog.Code.candidateUndone.rawValue, count: 0) == "记下的词已撤销")

        // Taken back, the log says so on the same entry; each such entry stands on its own.
        var log = LearningLog()
        let noted = log.add(.candidate, app: "微信", count: 1, at: day)
        let learned = log.add(.repeated, app: "微信", count: 1, at: day.addingTimeInterval(10))
        let another = log.add(.candidate, app: "微信", count: 1, at: day.addingTimeInterval(20))
        #expect(Set([noted, learned, another]).count == 3 && log.entries.count == 3)
        log.takeBack(1, from: noted)
        log.takeBack(1, from: learned)
        #expect(log.entries.map(\.code) == ["candidate", "undone", "candidateUndone"])
        // Codes and counts only, never the words.
        let text = String(decoding: (try? JSONEncoder().encode(log)) ?? Data(), as: UTF8.self)
        #expect(!text.contains("米线") && !text.contains("曲线"))
    }

    @Test func aNarrowCapsuleSaysTheLineInTwoParts() {
        let swap = pair("米线|曲线")
        // Wide enough: the one line.
        #expect(LearningText.notedParts(pairs: [swap], fits: { _ in true }) == ["记下了：米线 → 曲线，再这样改一次就记住"])
        // The capsule holds about twelve characters: the swap first, then what to do.
        #expect(LearningText.notedParts(pairs: [swap], fits: { $0.count <= 12 }) == ["记下了：米线 → 曲线", "再这样改一次就记住"])
        // Longer words: the new word alone; several swaps: the first new word and how many.
        let long = LearningSamples.longSwap
        #expect(LearningText.notedParts(pairs: [long], fits: { $0.count <= 12 }) == ["记下了：使用说明书", "再这样改一次就记住"])
        #expect(LearningText.notedParts(pairs: [swap, pair("方法|办法")], fits: { $0.count <= 14 })
            == ["记下了：曲线等 2 个词", "再这样改一次就记住"])
        // Nothing of it fits: the short line that says both.
        let longer = pair("Cloud Opus Preview|Claude Opus Preview")
        #expect(LearningText.notedParts(pairs: [longer], fits: { $0.count <= 12 }) == ["记下了，再改一次就记住"])
        // Every part is a note, never a result's tick, and the parts together say the whole line.
        for part in LearningText.notedParts(pairs: [swap], fits: { $0.count <= 12 }) {
            #expect(CapsuleText.kind(done: part) == .note, "\(part)")
        }
        #expect(LearningText.notedParts(pairs: [swap], fits: { $0.count <= 12 }).joined(separator: "，") == LearningText.noted(pairs: [swap]))
        #expect(LearningText.notedParts(pairs: [], fits: { _ in false }) == ["记下了"])
    }

    // MARK: On the dictionary page

    @Test func aSwapMadeOnceIsListedWhereItsDatePutsIt() {
        func item(_ s: String, hoursAgo: Double, kind: LearnedCorrection.Kind? = nil) -> LearnedCorrection {
            let at = day.addingTimeInterval(-hoursAgo * 3_600)
            return LearnedCorrection(pair: pair(s), count: kind == nil ? 1 : 2, firstSeen: at, lastSeen: at, source: .otherApp,
                                     addedTerm: false, kind: kind)
        }
        func swap(_ s: String, hoursAgo: Double) -> LearningBook.Candidate {
            LearningBook.Candidate(pair: pair(s), seen: day.addingTimeInterval(-hoursAgo * 3_600), recordID: nil)
        }
        let items = [item("报告|报道", hoursAgo: 2, kind: .repeated), item("Open Air|OpenAI", hoursAgo: 30), item("全线|权限", hoursAgo: 80)]
        let rows = LearnedList.rows(items: items, candidates: [swap("草稿|初稿", hoursAgo: 50), swap("方法|办法", hoursAgo: 1),
                                                                 swap("走势|趋势", hoursAgo: 200)])
        #expect(rows.map(\.pair) == [pair("方法|办法"), pair("报告|报道"), pair("Open Air|OpenAI"), pair("草稿|初稿"),
                                     pair("全线|权限"), pair("走势|趋势")])
        // Which of them only wait is known from the row, not from where it stands.
        let waiting = rows.compactMap { row -> CorrectionPair? in
            if case .waiting(let swap) = row { return swap.pair }
            return nil
        }
        #expect(waiting == [pair("方法|办法"), pair("草稿|初稿"), pair("走势|趋势")])
        #expect(Set(rows.map(\.id)).count == rows.count)
        // Only corrections, only swaps, nothing.
        #expect(LearnedList.rows(items: items, candidates: []).map(\.pair) == items.map(\.pair))
        #expect(LearnedList.rows(items: [], candidates: [swap("草稿|初稿", hoursAgo: 50), swap("方法|办法", hoursAgo: 1)]).map(\.pair)
            == [pair("方法|办法"), pair("草稿|初稿")])
        #expect(LearnedList.rows(items: [], candidates: []).isEmpty)
        // Made at its second time, the swap is a correction where the waiting row stood: at the top.
        var book = LearningBook()
        let first = UUID(), second = UUID()
        _ = book.record([], candidates: [pair("方法|办法")], source: .otherApp, recordID: first, now: day) { _ in false }
        #expect(LearnedList.rows(items: book.items, candidates: book.candidates) == [.waiting(book.candidates[0])])
        _ = book.record([], candidates: [pair("方法|办法")], source: .otherApp, recordID: second, now: day.addingTimeInterval(600)) { _ in false }
        let after = LearnedList.rows(items: book.items, candidates: book.candidates)
        #expect(after.count == 1 && after.first?.pair == pair("方法|办法"))
        if case .correction(let learned)? = after.first { #expect(learned.isRepeated && learned.count == 2) } else { Issue.record("not learned") }
    }

    @Test func theTagsAreExplainedOnlyWhenTheyAreThere() {
        #expect(LearningText.tagFooter(waiting: false, repeated: false) == nil)
        let both = LearningText.tagFooter(waiting: true, repeated: true) ?? ""
        #expect(both.contains("“待确认 1/2”") && both.contains("“改过两次”"))
        #expect(LearningText.tagFooter(waiting: true, repeated: false)?.contains("改过两次") == false)
        #expect(LearningText.tagFooter(waiting: false, repeated: true)?.contains("待确认") == false)
        #expect(LearningText.waitingTag == "待确认 1/2" && LearningText.repeatedTag == "改过两次")
        // A swap made twice is a hint only, and the page says so.
        #expect(LearningText.repeatedHelp.contains("不直接改字") && LearningText.waitingHelp.contains("还没用上"))
    }
}
}
