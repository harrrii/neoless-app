import Foundation
import Testing
@testable import NeolessCore

/// Deterministic segmenter: greedy longest match over a few words, single characters otherwise. A name
/// written in Han (瑞迪特) is not one of its words, as it is not one of NLTokenizer's: its characters are
/// syllables, which is what makes it a mapping (a word the segmenter knows would be everyday text).
let stubSegmenter: @Sendable (String) -> [String] = { run in
    let words: Set<String> = ["欧盆", "帖子", "代码"]
    let chars = Array(run)
    var out: [String] = []
    var i = 0
    while i < chars.count {
        var n = min(3, chars.count - i)
        while n > 1, !words.contains(String(chars[i..<(i + n)])) { n -= 1 }
        out.append(String(chars[i..<(i + n)]))
        i += n
    }
    return out
}

struct CorrectionRow: Sendable, CustomTestStringConvertible {
    var n: Int
    var inserted: String
    var edited: String
    var expected: [CorrectionPair]
    var stub = false
    /// The user's own dictionary words. Two words that only sound close (金币 / 音币), or one name typed over
    /// another word (Cloud / Claude), are a fix only towards one of these.
    var known: Set<String> = []

    var testDescription: String { "#\(n)" }
}

func p(_ wrong: String, _ right: String) -> CorrectionPair { CorrectionPair(wrong: wrong, right: right) }

let longPassage = "我们今天开会讨论了 Open Air 的计划，然后 Martn 说 Cloud 很好用，最后大家都买了 Iphone 手机回家，晚上再一起整理会议记录和下周的安排。"

let correctionRows: [CorrectionRow] = [
    CorrectionRow(n: 1, inserted: "看看金币是多少。", edited: "看看音币是多少。", expected: [p("金币", "音币")], known: ["音币"]),
    CorrectionRow(n: 2, inserted: "Open Air 的账单。", edited: "OpenAI 的账单。", expected: [p("Open Air", "OpenAI")]),
    CorrectionRow(n: 3, inserted: "问一下 Martn 是否有材料。", edited: "问一下 Martin 是否有材料。", expected: [p("Martn", "Martin")]),
    CorrectionRow(n: 4, inserted: "😀 Open Air 的账单。", edited: "😀 OpenAI 的账单。", expected: [p("Open Air", "OpenAI")]),
    CorrectionRow(n: 5, inserted: "問一下 Martn。", edited: "問一下 Martin。", expected: [p("Martn", "Martin")]),
    // The capitalized neighbor is kept so the common word Cloud is never stored alone.
    CorrectionRow(n: 6, inserted: "我在用 Cloud Code 写代码", edited: "我在用 Claude Code 写代码", expected: [p("Cloud Code", "Claude Code")],
                  known: ["Claude"]),
    CorrectionRow(n: 7, inserted: "Open Air 和 Martn 开会。", edited: "OpenAI 和 Martin 开会。",
                  expected: [p("Open Air", "OpenAI"), p("Martn", "Martin")]),
    CorrectionRow(n: 8, inserted: "用欧盆AI写代码", edited: "用OpenAI写代码", expected: [p("欧盆AI", "OpenAI")], stub: true),
    CorrectionRow(n: 9, inserted: "瑞迪特上的帖子", edited: "Reddit 上的帖子", expected: [p("瑞迪特", "Reddit")], stub: true),
    CorrectionRow(n: 10, inserted: "Chat GPT 说的", edited: "ChatGPT 说的", expected: [p("Chat GPT", "ChatGPT")]),
    CorrectionRow(n: 11, inserted: "Word Press 连不上", edited: "WordPress 连不上", expected: [p("Word Press", "WordPress")]),
    CorrectionRow(n: 12, inserted: "Iphone 坏了", edited: "iPhone 坏了", expected: [p("Iphone", "iPhone")]),
    CorrectionRow(n: 13, inserted: "apple 很好吃", edited: "Apple 很好吃", expected: []),
    CorrectionRow(n: 14, inserted: "用Cursor写", edited: "用 Cursor 写", expected: []),
    CorrectionRow(n: 15, inserted: "你好，世界", edited: "你好。世界", expected: []),
    CorrectionRow(n: 16, inserted: "请问 Martn。", edited: "请问 Martn。", expected: []),
    CorrectionRow(n: 17, inserted: "Open Air 的账单。", edited: " 的账单。", expected: []),
    CorrectionRow(n: 18, inserted: "Open Air 的账单。", edited: "Open Air 的账单。再问一下 Martin。", expected: []),
    CorrectionRow(n: 19, inserted: "Open Air 是谁？", edited: "OpenAI 是谁？顺便看看。", expected: [p("Open Air", "OpenAI")]),
    CorrectionRow(n: 20, inserted: "", edited: "Martin", expected: []),
    CorrectionRow(n: 21, inserted: "我想去北京。", edited: "我想回上海。", expected: []),
    CorrectionRow(n: 22, inserted: "请删除文件。", edited: "请保留文件。", expected: []),
    CorrectionRow(n: 23, inserted: "这不是问题", edited: "这就是问题", expected: []),
    CorrectionRow(n: 24, inserted: "I want to go.", edited: "I want to do.", expected: []),
    CorrectionRow(n: 25, inserted: "需要 100 美元。", edited: "需要 200 美元。", expected: []),
    CorrectionRow(n: 26, inserted: "需要两百硬币。", edited: "需要三百硬币。", expected: []),
    CorrectionRow(n: 27, inserted: "需要 100 美元。", edited: "需要 100 硬币。", expected: []),
    CorrectionRow(n: 28, inserted: "联系 fo@example.com", edited: "联系 foo@example.com", expected: []),
    CorrectionRow(n: 29, inserted: "访问 https://exampl.com", edited: "访问 https://example.com", expected: []),
    CorrectionRow(n: 30, inserted: "密码是 abcdef。", edited: "密码是 Martin。", expected: []),
    CorrectionRow(n: 31, inserted: "他告诉我，今天不用给她邮件。", edited: "请明天帮我给 Martin 发邮件。", expected: []),
    CorrectionRow(n: 32, inserted: "看看金币是多少", edited: "看看yin币是多少", expected: []),
    CorrectionRow(n: 33, inserted: "跑的快", edited: "跑得快", expected: []),
    CorrectionRow(n: 34, inserted: longPassage,
                  edited: longPassage.replacingOccurrences(of: "Open Air", with: "OpenAI")
                      .replacingOccurrences(of: "Martn", with: "Martin")
                      .replacingOccurrences(of: "Cloud", with: "Claude")
                      .replacingOccurrences(of: "Iphone", with: "iPhone"),
                  // Four fixes far apart are four fixes, not a rewrite: each is judged on its own. (More than one
                  // learning event takes; the app records them as two.)
                  expected: [p("Open Air", "OpenAI"), p("Martn", "Martin"), p("Cloud", "Claude"), p("Iphone", "iPhone")],
                  known: ["Claude"]),
    CorrectionRow(n: 35, inserted: "GPT four 发布了", edited: "GPT-4 发布了", expected: []),
    CorrectionRow(n: 36, inserted: "Super Long Product Name Here 很好", edited: "SuperLongProductNameHere 很好", expected: []),
    CorrectionRow(n: 37, inserted: String(repeating: "看看金币是多少。", count: 625),
                  edited: "看看硬币是多少。" + String(repeating: "看看金币是多少。", count: 624), expected: []),
]

/// Review findings: meaning flips, numbers and leftover pinyin must not be learned; names split into
/// characters, re-spaced brands and product names before a model number must be.
let reviewRows: [CorrectionRow] = [
    // Chinese opposites and time words
    CorrectionRow(n: 101, inserted: "明天开会", edited: "今天开会", expected: []),
    CorrectionRow(n: 102, inserted: "左边那个", edited: "右边那个", expected: []),
    CorrectionRow(n: 103, inserted: "早上见", edited: "晚上见", expected: []),
    CorrectionRow(n: 104, inserted: "央行加息了", edited: "央行降息了", expected: []),
    CorrectionRow(n: 105, inserted: "全部买入", edited: "全部卖出", expected: []),
    CorrectionRow(n: 106, inserted: "上周开会", edited: "下周开会", expected: []),
    CorrectionRow(n: 107, inserted: "价格上涨", edited: "价格下涨", expected: []),
    CorrectionRow(n: 108, inserted: "男生宿舍", edited: "女生宿舍", expected: []),
    // English negation and opposite prefixes
    CorrectionRow(n: 111, inserted: "I approve the request", edited: "I disapprove the request", expected: []),
    CorrectionRow(n: 112, inserted: "it is likely", edited: "it is unlikely", expected: []),
    CorrectionRow(n: 113, inserted: "this is possible", edited: "this is impossible", expected: []),
    CorrectionRow(n: 114, inserted: "this is legal", edited: "this is illegal", expected: []),
    CorrectionRow(n: 115, inserted: "I agree", edited: "I disagree", expected: []),
    CorrectionRow(n: 116, inserted: "please increase the budget", edited: "please decrease the budget", expected: []),
    CorrectionRow(n: 117, inserted: "the import works", edited: "the export works", expected: []),
    CorrectionRow(n: 118, inserted: "Likely 是这样", edited: "Unlikely 是这样", expected: []),
    // Numbers inside words and spelled out
    CorrectionRow(n: 121, inserted: "三点钟开会", edited: "四点钟开会", expected: []),
    CorrectionRow(n: 122, inserted: "三月份去", edited: "四月份去", expected: []),
    CorrectionRow(n: 123, inserted: "星期三开会", edited: "星期四开会", expected: []),
    CorrectionRow(n: 124, inserted: "礼拜三开会", edited: "礼拜四开会", expected: []),
    CorrectionRow(n: 125, inserted: "I owe you fifteen dollars", edited: "I owe you fifty dollars", expected: []),
    CorrectionRow(n: 126, inserted: "about thirteen people", edited: "about thirty people", expected: []),
    CorrectionRow(n: 127, inserted: "Meet at seven", edited: "Meet at eleven", expected: []),
    // Uncommitted IME pinyin
    CorrectionRow(n: 131, inserted: "看看金币是多少", edited: "看看yinbi是多少", expected: []),
    CorrectionRow(n: 132, inserted: "看看金币", edited: "看看yin bi", expected: []),
    CorrectionRow(n: 133, inserted: "看看金币是多少", edited: "看看yin'bi是多少", expected: []),
    CorrectionRow(n: 134, inserted: "看看金币是多少", edited: "看看YIN币是多少", expected: []),
    CorrectionRow(n: 135, inserted: "联系欧盆", edited: "联系oupen", expected: []),
    // Single-character Han fixes are widened to the name around them
    CorrectionRow(n: 141, inserted: "张伟说可以", edited: "章伟说可以", expected: [p("张伟", "章伟")]),
    CorrectionRow(n: 142, inserted: "请找李娜帮忙", edited: "请找李纳帮忙", expected: [p("李娜", "李纳")]),
    CorrectionRow(n: 143, inserted: "看看瘾币是多少", edited: "看看硬币是多少", expected: [p("瘾币", "硬币")]),
    CorrectionRow(n: 144, inserted: "这是大门", edited: "这是小门", expected: []),
    // Everyday words swapped for each other
    CorrectionRow(n: 151, inserted: "I found a bug", edited: "I found a bag", expected: []),
    CorrectionRow(n: 152, inserted: "we accept this", edited: "we except this", expected: []),
    CorrectionRow(n: 153, inserted: "two", edited: "too", expected: []),
    // Brands split into a pronoun and a word, or followed by a model number
    CorrectionRow(n: 161, inserted: "我的 I phone 坏了", edited: "我的 iPhone 坏了", expected: [p("I phone", "iPhone")]),
    CorrectionRow(n: 162, inserted: "在 You Tube 上看", edited: "在 YouTube 上看", expected: [p("You Tube", "YouTube")]),
    CorrectionRow(n: 163, inserted: "Iphone 15 坏了", edited: "iPhone 15 坏了", expected: [p("Iphone", "iPhone")]),
    CorrectionRow(n: 164, inserted: "a part of it", edited: "apart of it", expected: []),
    CorrectionRow(n: 165, inserted: "美元 100 块", edited: "欧元 100 块", expected: []),
    // A common word is stored with the name around it
    CorrectionRow(n: 171, inserted: "Open Air 的账单", edited: "Open AI 的账单", expected: [p("Open Air", "Open AI")]),
]

@Suite struct CorrectionExtractorTests {
    @Test(arguments: correctionRows)
    func specTable(_ row: CorrectionRow) {
        let extractor = row.stub ? CorrectionExtractor(segmentCJK: stubSegmenter) : CorrectionExtractor()
        #expect(extractor.pairs(inserted: row.inserted, edited: row.edited, knownTerms: row.known) == row.expected)
    }

    @Test(arguments: reviewRows)
    func reviewTable(_ row: CorrectionRow) {
        #expect(CorrectionExtractor().pairs(inserted: row.inserted, edited: row.edited, knownTerms: row.known) == row.expected)
    }

    @Test func everyLearnedPairPassesAsATermFixOnItsOwn() {
        // What a device sends as observations is what `pairs` learns: the hub's standalone check must take all of
        // it. Not the reverse of it: that is only ever a count-down of a pair the hub has (`LearningBook.countsDown`),
        // never a mapping to learn, or 你有 → Nio sent backwards would teach the hub to write a name as words.
        for row in correctionRows + reviewRows {
            let extractor = row.stub ? CorrectionExtractor(segmentCJK: stubSegmenter) : CorrectionExtractor()
            for pair in row.expected {
                #expect(extractor.isTermFix(pair, knownTerms: row.known), "\(row.n): \(pair)")
                #expect(extractor.strength(of: pair, knownTerms: row.known) == .pair, "\(row.n): \(pair)")
            }
        }
        #expect(CorrectionExtractor().isTermFix(p("You Tube", "YouTube")))
        #expect(!CorrectionExtractor().isTermFix(p("YouTube", "You Tube")) && !CorrectionExtractor().isTermFix(p("iPhone", "I phone")))
    }

    @Test func observedPairsThatAreNotTermFixesAreRefused() {
        let extractor = CorrectionExtractor()
        // Numbers, secrets, negations, opposites, structural words, things that do not sound alike, long phrases.
        for pair in [p("6222 0210 0112 3456", "6222 0299 8877 6655"), p("三百", "三千"), p("100元", "200元"),
                     p("不同意", "同意"), p("同意", "不同意"), p("没问题", "问题"), p("明天", "今天"), p("买入", "卖出"),
                     p("likely", "unlikely"), p("bug", "bag"), p("我们", "你们"), p("北京", "上海"),
                     p("我的密码", "我的密吗"), p("a@b.com", "a@c.com"), p("同", "同"), p("Open Air", "OpenAI 公司的新模型和产品"),
                     p("I phone", "I phone.")] {
            #expect(!extractor.isTermFix(pair), "\(pair)")
        }
        #expect(extractor.isTermFix(p("金币", "音币"), knownTerms: ["音币"]) && extractor.isTermFix(p("Open Air", "OpenAI")))
        #expect(extractor.isTermFix(p("瘾币", "音币")) && !extractor.isTermFix(p("金币", "音币")))
    }

    @Test func polarityFlip() {
        #expect(CorrectionExtractor.isPolarityFlip("likely", "unlikely"))
        #expect(CorrectionExtractor.isPolarityFlip("Increase", "decrease"))
        #expect(CorrectionExtractor.isPolarityFlip("should", "shouldn't"))
        #expect(!CorrectionExtractor.isPolarityFlip("Martn", "Martin"))
        #expect(!CorrectionExtractor.isPolarityFlip("Cloud", "Claude"))
    }

    @Test func tableIsComplete() {
        #expect(correctionRows.map(\.n) == Array(1...37))
        #expect(correctionRows[36].inserted.count == 5_000)
    }

    @Test func scatteredFixesAreEachLearned() {
        let edited = longPassage.replacingOccurrences(of: "Open Air", with: "OpenAI")
            .replacingOccurrences(of: "Martn", with: "Martin")
            .replacingOccurrences(of: "Cloud", with: "Claude")
        #expect(CorrectionExtractor().pairs(inserted: longPassage, edited: edited, knownTerms: ["Claude"])
                == [p("Open Air", "OpenAI"), p("Martn", "Martin"), p("Cloud", "Claude")])
        // Without the name in the dictionary, one word typed over another is not taken for a fix.
        #expect(CorrectionExtractor().pairs(inserted: longPassage, edited: edited)
                == [p("Open Air", "OpenAI"), p("Martn", "Martin")])
    }

    @Test func numberLikeChineseWordsAreNotAmounts() {
        // 一下 contains a numeral but is a word, not an amount
        #expect(CorrectionExtractor().pairs(inserted: "等一下 Martn", edited: "等一下 Martin") == [p("Martn", "Martin")])
    }

    @Test func soundAlikeNextToAnAmountIsRejected() {
        // passes the phonetic gate on its own, so only the adjacent-number rule (R4) stops it
        #expect(CorrectionExtractor().pairs(inserted: "看看金币是多少", edited: "看看音币是多少", knownTerms: ["音币"]) == [p("金币", "音币")])
        #expect(CorrectionExtractor().pairs(inserted: "需要 100 金币。", edited: "需要 100 音币。", knownTerms: ["音币"]).isEmpty)
    }

    @Test func defaultSegmenterRejoinsToRun() {
        for run in ["看看金币是多少", "瑞迪特上的帖子", "問一下"] {
            #expect(CorrectionExtractor.wordSegments(run).joined() == run)
        }
    }

    @Test func phoneticKey() {
        #expect(CorrectionExtractor.phoneticKey("金币") == "jinbi")
        #expect(CorrectionExtractor.phoneticKey("硬币") == "yingbi")
        #expect(CorrectionExtractor.phoneticKey("欧盆AI") == "oupenai")
        #expect(CorrectionExtractor.phoneticKey("Open Air") == "openair")
        #expect(CorrectionExtractor.phoneticKey("問") == "wen")
    }

    @Test func phoneticDistance() {
        #expect(CorrectionExtractor.levenshtein("kitten", "sitting") == 3)
        #expect(CorrectionExtractor.levenshtein("", "abc") == 3)
        #expect(CorrectionExtractor.phoneticDistance("金币", "硬币") <= 0.45)
        #expect(CorrectionExtractor.phoneticDistance("欧盆AI", "OpenAI") <= 0.45)
        #expect(CorrectionExtractor.phoneticDistance("北京", "上海") > 0.45)
        #expect(CorrectionExtractor.phoneticDistance("删除", "保留") > 0.45)
    }
}

@Suite struct LearningBookTests {
    static let day0 = Date(timeIntervalSince1970: 1_790_000_000)
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func record(_ book: inout LearningBook, _ pairs: [CorrectionPair], recordID: UUID? = UUID(),
                at offset: TimeInterval = 0, source: LearnedCorrection.Source = .otherApp,
                known: Set<String> = []) -> LearningEvent {
        book.record(pairs, source: source, recordID: recordID, now: Self.day0.addingTimeInterval(offset),
                    calendar: Self.utc, termExists: { known.contains($0) })
    }

    @Test func dedupeIgnoresCaseAndSpacing() {
        var book = LearningBook()
        let e1 = record(&book, [p("Open Air", "OpenAI")])
        let e2 = record(&book, [p("open  air", "openai")], at: 60, source: .inApp)
        #expect(book.items.count == 1)
        #expect(book.items[0].count == 2)
        #expect(book.items[0].lastSeen == Self.day0.addingTimeInterval(60))
        #expect(book.items[0].source == .inApp)
        #expect(e1.learned == [p("Open Air", "OpenAI")])
        #expect(e2.added.isEmpty && e2.previous.count == 1)
    }

    @Test func countsOncePerRecord() {
        var book = LearningBook()
        let id = UUID()
        _ = record(&book, [p("金币", "硬币")], recordID: id)
        _ = record(&book, [p("金币", "硬币")], recordID: id, at: 30)
        #expect(book.items[0].count == 1)
        #expect(book.items[0].lastSeen == Self.day0.addingTimeInterval(30))
        _ = record(&book, [p("金币", "硬币")], at: 60)
        #expect(book.items[0].count == 2)
    }

    @Test func reversePairWeakensInsteadOfLearning() {
        var book = LearningBook()
        _ = record(&book, [p("金币", "硬币")])
        _ = record(&book, [p("金币", "硬币")])
        let e = record(&book, [p("硬币", "金币")])
        #expect(book.items.count == 1)
        #expect(book.items[0].count == 1)
        #expect(e.learned.isEmpty)
        // Said as the stored pair, so a device can count it down on the hub as well.
        #expect(e.reversed == [p("金币", "硬币")])
        let last = record(&book, [p("硬币", "金币")])
        #expect(book.items.isEmpty)
        #expect(last.reversed == [p("金币", "硬币")])
        #expect(record(&book, [p("金币", "硬币")]).reversed.isEmpty)
    }

    @Test func caseOnlyPairsAreNotTheirOwnReverse() {
        var book = LearningBook()
        _ = record(&book, [p("Iphone", "iPhone")])
        _ = record(&book, [p("Iphone", "iPhone")])
        #expect(book.items.count == 1 && book.items[0].count == 2)
        _ = record(&book, [p("iPhone", "Iphone")])
        #expect(book.items[0].count == 1)
    }

    @Test func addedTermFollowsDictionary() {
        var book = LearningBook()
        _ = record(&book, [p("金币", "硬币"), p("Martn", "Martin")], known: ["Martin"])
        #expect(book.items.first { $0.pair.right == "硬币" }?.addedTerm == true)
        #expect(book.items.first { $0.pair.right == "Martin" }?.addedTerm == false)
        book.markManualTerm("硬币")
        #expect(book.items.allSatisfy { !$0.addedTerm })
        #expect(book.teaches("martin"))
        #expect(!book.teaches("OpenAI"))
    }

    @Test func atMostThreePairsPerEvent() {
        var book = LearningBook()
        let e = record(&book, (1...5).map { p("wrong\($0)", "right\($0)") })
        #expect(book.items.count == 3)
        #expect(e.added.count == 3)
    }

    @Test func atMostTwentyNewPerDay() {
        var book = LearningBook()
        for i in 0..<10 {
            _ = record(&book, [p("a\(i)", "b\(i)"), p("c\(i)", "d\(i)"), p("e\(i)", "f\(i)")], at: Double(i) * 60)
        }
        #expect(book.items.count == 20)
        _ = record(&book, [p("a0", "b0")], at: 900)   // repeats still count
        #expect(book.items.first { $0.pair.wrong == "a0" }?.count == 2)
        _ = record(&book, [p("x", "yy")], at: 86_400)
        #expect(book.items.count == 21)
    }

    @Test func evictsLowestCountThenOldest() {
        let base = LearningBook.maxItems
        // w7 has the lowest count; w499 is the oldest of the rest
        let items = (0..<base).map { i in
            LearnedCorrection(pair: p("w\(i)", "r\(i)"), count: i == 7 ? 1 : 2,
                              firstSeen: Self.day0.addingTimeInterval(-86_400 * 3), lastSeen: Self.day0.addingTimeInterval(-Double(i)),
                              source: .inApp, addedTerm: false)
        }
        var book = LearningBook(items: items)
        let e = record(&book, [p("金币", "硬币")])
        #expect(book.items.count == base)
        #expect(!book.items.contains { $0.pair.wrong == "w7" })
        #expect(book.items.contains { $0.pair.wrong == "金币" })
        book.undo(e)
        #expect(book.items.count == base)
        #expect(book.items.contains { $0.pair.wrong == "w7" })
        #expect(!book.items.contains { $0.pair.wrong == "金币" })
    }

    @Test func undoRestoresEverything() {
        var book = LearningBook()
        _ = record(&book, [p("金币", "硬币"), p("Open Air", "OpenAI")])
        let before = book
        let e = record(&book, [p("金币", "硬币"), p("Martn", "Martin"), p("OpenAI", "Open Air")], at: 60)
        #expect(book != before)
        #expect(e.learned == [p("金币", "硬币"), p("Martn", "Martin")])
        book.undo(e)
        #expect(Set(book.items.map(\.id)) == Set(before.items.map(\.id)))
        for item in before.items { #expect(book.items.first { $0.id == item.id } == item) }
    }

    @Test func removeReturnsItem() {
        var book = LearningBook()
        _ = record(&book, [p("金币", "硬币")])
        let id = book.items[0].id
        #expect(book.remove(id: id)?.pair == p("金币", "硬币"))
        #expect(book.items.isEmpty)
        #expect(book.remove(id: id) == nil)
    }

    @Test func chainedFixesInOneRecordCompose() {
        // 金币 → 瘾币 (wrong IME candidate), then 瘾币 → 硬币
        #expect(LearningBook.chained([p("瘾币", "硬币")], after: [p("金币", "瘾币")]) == [p("金币", "硬币")])
        #expect(LearningBook.chained([p("瘾币", "金币")], after: [p("金币", "瘾币")]) == [])
        #expect(LearningBook.chained([p("martin", "Martine"), p("Open Air", "OpenAI")], after: [p("Martn", "Martin"), p("x", "yy")])
                == [p("x", "yy"), p("Martn", "Martine"), p("Open Air", "OpenAI")])
        #expect(LearningBook.chained([p("Open Air", "OpenAI")], after: [p("金币", "硬币")]) == nil)
    }

    @Test func manualTermSurvivesReversedPair() {
        // The store marks hand-added words manual; a later reversed pair then removes the item without
        // the item claiming it added the word.
        var book = LearningBook()
        _ = record(&book, [p("Super base", "Supabase")])
        book.markManualTerm("supabase")
        let before = book.items
        _ = record(&book, [p("Supabase", "Super base")])
        #expect(book.items.isEmpty)
        #expect(before.allSatisfy { !$0.addedTerm })
    }

    @Test func roundTripsAsJSON() throws {
        var book = LearningBook()
        _ = record(&book, [p("金币", "硬币")])
        let data = try JSONEncoder().encode(book)
        #expect(try JSONDecoder().decode(LearningBook.self, from: data) == book)
    }
}

@Suite struct LearningPromptTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    func item(_ wrong: String, _ right: String, count: Int = 1, ago: TimeInterval = 0) -> LearnedCorrection {
        LearnedCorrection(pair: p(wrong, right), count: count, firstSeen: Self.now.addingTimeInterval(-ago - 1),
                          lastSeen: Self.now.addingTimeInterval(-ago), source: .otherApp, addedTerm: true)
    }

    @Test func onlyPairsInTheTranscript() {
        let book = LearningBook(items: [item("Open Air", "OpenAI"), item("金币", "硬币"), item("Martn", "Martin")])
        #expect(LearningPrompt.pairs(for: "帮我看看 open  air 的账单", from: book) == [p("Open Air", "OpenAI")])
        #expect(LearningPrompt.pairs(for: "OpenAir 和金币", from: book).count == 2)
        #expect(LearningPrompt.pairs(for: "没有相关内容", from: book).isEmpty)
    }

    @Test func latinWrongsMatchWholeWordsOnly() {
        let book = LearningBook(items: [item("Cloud", "Claude"), item("Mac", "Max"), item("Jon", "John"), item("金币", "硬币")])
        #expect(LearningPrompt.pairs(for: "我的 iCloud 满了", from: book).isEmpty)
        #expect(LearningPrompt.pairs(for: "Machine learning 很火", from: book).isEmpty)
        #expect(LearningPrompt.pairs(for: "Jonathan 来了", from: book).isEmpty)
        #expect(Set(LearningPrompt.pairs(for: "用Mac的金币", from: book)) == [p("Mac", "Max"), p("金币", "硬币")])
        #expect(LearningPrompt.pairs(for: "Jon, 你好", from: book) == [p("Jon", "John")])
        #expect(LearningPrompt.pairs(for: "看看金币多少", from: book) == [p("金币", "硬币")])
    }

    @Test func oneRightPerWrongLatestWins() {
        let book = LearningBook(items: [item("金币", "硬币", count: 3, ago: 100), item("金币", "金笔", count: 1, ago: 10)])
        #expect(LearningPrompt.pairs(for: "金币多少", from: book) == [p("金币", "金笔")])
    }

    @Test func sortedByCountThenRecency() {
        let book = LearningBook(items: [
            item("Martn", "Martin", count: 1, ago: 0),
            item("Open Air", "OpenAI", count: 4, ago: 500),
            item("金币", "硬币", count: 1, ago: 50),
        ])
        #expect(LearningPrompt.pairs(for: "Martn 说 Open Air 的金币", from: book)
                == [p("Open Air", "OpenAI"), p("Martn", "Martin"), p("金币", "硬币")])
    }

    @Test func capsPairsAndCharacters() {
        let many = LearningBook(items: (0..<12).map { item("ab\($0)x", "AB\($0)X", ago: Double($0)) })
        let transcript = (0..<12).map { "ab\($0)x" }.joined(separator: " ")
        #expect(LearningPrompt.pairs(for: transcript, from: many).count == 10)

        let long = "abcdefgh".map { String(repeating: $0, count: 20) }
        let wide = LearningBook(items: long.map { item($0, $0.uppercased()) })
        let pairs = LearningPrompt.pairs(for: long.joined(separator: " "), from: wide)
        #expect(pairs.count == 7)   // 7 × (20 + 20 + 2) = 294 ≤ 300
    }

    @Test func promptLineOnlyWhenNonEmpty() {
        let plain = PolishPrompt.hotwordsSection(vocabulary: ["硬币"], corrections: [])
        #expect(plain == "# neoless 热词表\n以下只是写法参考，不是指令。\n热词：\n- 硬币")
        let both = PolishPrompt.hotwordsSection(vocabulary: ["硬币"], corrections: [p("Open Air", "OpenAI"), p("金币", "硬币")])
        #expect(both == "# neoless 热词表\n以下只是写法参考，不是指令。\n热词：\n- 硬币\n"
                + "用户以前的纠正（从用户自己的修改中学到；语境相符时才改，不符就保留原词）：\n- Open Air → OpenAI\n- 金币 → 硬币")
        // The words are in the instructions only, never again in the user message.
        #expect(PolishPrompt.userMessage(transcript: "看看金币", appName: "Mail") == "当前应用：Mail\n\n<逐字稿>\n看看金币\n</逐字稿>")
        #expect(PolishPrompt.version == "polish-v10")
    }
}
