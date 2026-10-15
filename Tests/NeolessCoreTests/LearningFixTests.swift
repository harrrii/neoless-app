import Foundation
import Testing
@testable import NeolessCore

// What the user fixes after neoless typed it, and what neoless makes of it: the rules reviewed after "I change
// what it typed and it neither records nor learns it". All text here is made up.

/// One edit and what it teaches.
struct FixRow: Sendable, CustomTestStringConvertible {
    var n: Int
    var inserted: String
    var edited: String
    /// What the edit teaches: mappings as "错 → 对", words learned alone as "[词]", words only noted for now
    /// (a capital seen once) as "(词)".
    var expected: [String]
    /// The user's dictionary.
    var known: Set<String> = []
    var nothing: Extraction.Nothing?

    var testDescription: String { "#\(n)" }
}

func fixes(_ e: Extraction) -> [String] {
    e.fixes.map { fix in
        guard fix.termOnly else { return "\(fix.pair.wrong) → \(fix.pair.right)" }
        return fix.tentative ? "(\(fix.pair.right))" : "[\(fix.pair.right)]"
    }
}

let fixRows: [FixRow] = [
    // A fix towards a word in the dictionary is easier to accept: a plain capital, a looser sound, a lowercase name.
    FixRow(n: 201, inserted: "claude 很好用", edited: "Claude 很好用", expected: [], nothing: .formatOnly),
    // A capital that only starts the sentence says nothing, also for a dictionary word; inside the sentence it does.
    FixRow(n: 202, inserted: "claude 很好用", edited: "Claude 很好用", expected: [], known: ["Claude"], nothing: .formatOnly),
    FixRow(n: 207, inserted: "我用 claude 写", edited: "我用 Claude 写", expected: ["claude → Claude"], known: ["Claude"]),
    FixRow(n: 203, inserted: "我在用 labels 输入", edited: "我在用 Lavoben 输入", expected: [], nothing: .unlikeName),
    // Learned, as a hint for the model: "labels" is an everyday word, so the pair is never written into text
    // without it (`replacesBlindly`, `anEverydayWordHeardForADictionaryNameIsOnlyAHint`).
    FixRow(n: 204, inserted: "我在用 labels 输入", edited: "我在用 Lavoben 输入", expected: ["labels → Lavoben"], known: ["Lavoben"]),
    FixRow(n: 205, inserted: "叫做牛莱斯", edited: "叫做 neoless", expected: [], nothing: .notTerms),
    FixRow(n: 206, inserted: "叫做牛莱斯", edited: "叫做 neoless", expected: ["牛莱斯 → neoless"], known: ["neoless"]),
    // Han syllables heard for a Latin name are a mapping; everyday words heard for one only teach the name.
    FixRow(n: 211, inserted: "我用科德克斯写代码", edited: "我用 Codex 写代码", expected: ["科德克斯 → Codex"]),
    FixRow(n: 212, inserted: "问一下杰迷奈", edited: "问一下 Gemini", expected: ["杰迷奈 → Gemini"]),
    FixRow(n: 213, inserted: "用拉玛跑一下", edited: "用 Llama 跑一下", expected: ["拉玛 → Llama"]),
    FixRow(n: 214, inserted: "这个你有很好用", edited: "这个 Nio 很好用", expected: ["[Nio]"]),
    FixRow(n: 215, inserted: "这个你好很好用", edited: "这个 Nio 很好用", expected: ["[Nio]"]),
    FixRow(n: 216, inserted: "马上立刻去找他", edited: "马上 Nick 去找他", expected: ["[Nick]"]),
    FixRow(n: 217, inserted: "这台车马力很足", edited: "这台车 Mary 很足", expected: ["[Mary]"]),
    FixRow(n: 218, inserted: "去谷歌搜一下", edited: "去 Google 搜一下", expected: ["[Google]"]),
    FixRow(n: 219, inserted: "去谷歌搜一下", edited: "去 Google 搜一下", expected: ["谷歌 → Google"], known: ["Google"]),
    FixRow(n: 220, inserted: "用爱写代码", edited: "用 AI 写代码", expected: [], nothing: .unlikeName),
    // Rewording is not fixing a term: nothing to tell the user about.
    FixRow(n: 221, inserted: "这个方案很好", edited: "这个方案还行", expected: [], nothing: .notTerms),
    FixRow(n: 222, inserted: "明天去北京开会", edited: "明天去上海开会", expected: [], nothing: .notTerms),
    // A plain capital: only in the middle of a Chinese clause, and then as a word, not a mapping, and only
    // noted the first time (`CapitalSeenTwiceTests`).
    FixRow(n: 231, inserted: "- update the docs", edited: "- Update the docs", expected: [], nothing: .formatOnly),
    FixRow(n: 232, inserted: "他说：hello", edited: "他说：Hello", expected: [], nothing: .formatOnly),
    FixRow(n: 233, inserted: "好的，thanks", edited: "好的，Thanks", expected: [], nothing: .formatOnly),
    FixRow(n: 234, inserted: "“sorry”", edited: "“Sorry”", expected: [], nothing: .formatOnly),
    FixRow(n: 235, inserted: "（optional）", edited: "（Optional）", expected: [], nothing: .formatOnly),
    FixRow(n: 236, inserted: "please review", edited: "please Review", expected: [], nothing: .formatOnly),
    FixRow(n: 237, inserted: "1. update 文档", edited: "1. Update 文档", expected: [], nothing: .formatOnly),
    FixRow(n: 238, inserted: "标题\nupdate 文档", edited: "标题\nUpdate 文档", expected: [], nothing: .formatOnly),
    FixRow(n: 239, inserted: "我用 cursor 写代码", edited: "我用 Cursor 写代码", expected: ["(Cursor)"]),
    FixRow(n: 240, inserted: "先装 github 再说", edited: "先装 GitHub 再说", expected: ["github → GitHub"]),
    // Where a secret would stand: after its label, also on the next line or after a comma; in an address.
    FixRow(n: 251, inserted: "WiFi 密码\nSunhouse 记一下", edited: "WiFi 密码\nSunhome 记一下", expected: [], nothing: .sensitive),
    FixRow(n: 252, inserted: "新的密码，就是 Sunhouse 那个", edited: "新的密码，就是 Sunhome 那个", expected: [], nothing: .sensitive),
    FixRow(n: 253, inserted: "- 口令\n  Sunhouse", edited: "- 口令\n  Sunhome", expected: [], nothing: .sensitive),
    FixRow(n: 254, inserted: "the secret is Sunhouse ok", edited: "the secret is Sunhome ok", expected: [], nothing: .sensitive),
    FixRow(n: 255, inserted: "token 是 Sunhouse 这个", edited: "token 是 Sunhome 这个", expected: [], nothing: .sensitive),
    FixRow(n: 256, inserted: "发到 Martn @ example.com", edited: "发到 Martin @ example.com", expected: [], nothing: .sensitive),
    // Talk about tokens elsewhere in the passage is no reason to learn nothing. A password word anywhere in it is:
    // what follows may be the password, however many words, full stops or lines later.
    FixRow(n: 257, inserted: "这个 token 用量太高了，问一下 Martn 吧", edited: "这个 token 用量太高了，问一下 Martin 吧",
           expected: ["Martn → Martin"]),
    FixRow(n: 258, inserted: "密码我已经改好了。另外 Open Air 的账单也看一下", edited: "密码我已经改好了。另外 OpenAI 的账单也看一下",
           expected: [], nothing: .sensitive),
    // Numbers: what was heard as a number is never the wrong side of a pair.
    FixRow(n: 261, inserted: "打印一百", edited: "打印一版", expected: [], nothing: .notTerms),
    FixRow(n: 262, inserted: "先出一百看看", edited: "先出一版看看", expected: [], nothing: .notTerms),
    FixRow(n: 263, inserted: "I have twenty", edited: "I have Trenty", expected: [], nothing: .notTerms),
    // Leftover pinyin with Caps Lock on, whatever the segmenter left of the hunk.
    FixRow(n: 271, inserted: "看看金币是多少", edited: "看看YINBI是多少", expected: [], nothing: .notTerms),
    FixRow(n: 272, inserted: "调一下爱皮爱接口", edited: "调一下 API 接口", expected: ["爱皮爱 → API"]),
    FixRow(n: 273, inserted: "调一下爱皮爱", edited: "调一下API", expected: ["爱皮爱 → API"]),
    // Every stretch is judged on its own: deletions and rephrasing take nothing away from a fix next to them.
    FixRow(n: 281, inserted: "这个，嗯，我觉得 Open Air 的模型还不错，你看一下", edited: "我觉得 OpenAI 的模型还不错，你看一下",
           expected: ["Open Air → OpenAI"]),
    FixRow(n: 282, inserted: "帮我把这段话发给 Martn，然后问他周五有没有空", edited: "帮我把这段话发给 Martin，问他周五有没有空",
           expected: ["Martn → Martin"]),
    FixRow(n: 283, inserted: "Open Air 和 Martn 和 Cloud Code 和 Iphone 和 Word press",
           edited: "OpenAI 和 Martin 和 Claude Code 和 iPhone 和 WordPress",
           expected: ["Open Air → OpenAI", "Martn → Martin", "Cloud Code → Claude Code", "Iphone → iPhone", "Word press → WordPress"],
           known: ["Claude"]),
    FixRow(n: 284, inserted: "1. 打开 Open Air\n2. 找到 Martn", edited: "1. 打开 OpenAI\n2. 找到 Martin",
           expected: ["Open Air → OpenAI", "Martn → Martin"]),
    FixRow(n: 285, inserted: "帮我看看金币是多少然后告诉我", edited: "帮我看看是多少", expected: [], nothing: .removedOnly),
    FixRow(n: 286, inserted: "我们下周三去见张伟聊聊合同的细节", edited: "请帮我约李娜明天上午讨论预算安排", expected: [], nothing: .rewrite),
    FixRow(n: 287, inserted: "你好，世界", edited: "你好。世界", expected: [], nothing: .formatOnly),
]

/// Why one changed stretch teaches something or nothing, where the old rules gave up on the whole edit.
@Suite struct LearningFixTests {
    @Test(arguments: fixRows)
    func whatAnEditTeaches(_ row: FixRow) {
        let found = CorrectionExtractor().extract(inserted: row.inserted, edited: row.edited, knownTerms: row.known)
        #expect(fixes(found) == row.expected)
        #expect(found.nothing == row.nothing)
        // `pairs` is the mappings alone; the words learned without one are `terms`.
        #expect(found.pairs.count == row.expected.filter { !$0.hasPrefix("[") && !$0.hasPrefix("(") }.count)
        #expect(found.terms.map { "[\($0)]" } == row.expected.filter { $0.hasPrefix("[") })
        #expect(found.sightings.map { "(\($0))" } == row.expected.filter { $0.hasPrefix("(") })
        #expect(CorrectionExtractor().pairs(inserted: row.inserted, edited: row.edited, knownTerms: row.known) == found.pairs)
    }


    @Test func nineScatteredFixesAreARewrite() {
        let names = ["Martn", "Jhn", "Petr", "Annna", "Lucs", "Sofa", "Dvid", "Emmma", "Olver"]
        let fixed = ["Martin", "John", "Peter", "Anna", "Lucas", "Sofia", "David", "Emma", "Oliver"]
        func passage(_ words: [String]) -> String { words.map { "今天和 \($0) 开会讨论了很多事情" }.joined(separator: "。") }
        let eight = CorrectionExtractor().extract(inserted: passage(Array(names.prefix(8))), edited: passage(Array(fixed.prefix(8))))
        #expect(eight.pairs.count == 8, "\(fixes(eight))")
        let nine = CorrectionExtractor().extract(inserted: passage(names), edited: passage(fixed))
        #expect(nine.isEmpty && nine.nothing == .rewrite)
    }


    @Test func aBarePairIsJudgedInItsOwnDirectionOnly() {
        let extractor = CorrectionExtractor()
        // A mapping.
        #expect(extractor.strength(of: p("科德克斯", "Codex")) == .pair)
        #expect(extractor.strength(of: p("瘾币", "音币")) == .pair)
        #expect(extractor.strength(of: p("金币", "音币"), knownTerms: ["音币"]) == .pair)
        #expect(extractor.strength(of: p("claude", "Claude"), knownTerms: ["Claude"]) == .pair)
        // Everyday text heard for a name: the name only, never a mapping.
        #expect(extractor.strength(of: p("你有", "Nio")) == .termOnly)
        #expect(extractor.strength(of: p("你好", "Nio")) == .termOnly)
        #expect(!extractor.isTermFix(p("你有", "Nio")) && !extractor.isTermFix(p("你好", "Nio")))
        // The reverse of something learnable is not learnable for that: a name turned into everyday words, a
        // word into a number, a joined name split again.
        for pair in [p("Nio", "你有"), p("Nick", "立刻"), p("一版", "一百"), p("一百", "一版"), p("iPhone", "I phone"),
                     p("Codex", "科德克斯"), p("update", "Update"), p("twenty", "Trenty")] {
            #expect(extractor.strength(of: pair) == nil, "\(pair)")
        }
    }


    @Test func numberLikeWrongSidesAreNeverReplacedBlindly() {
        #expect(CorrectionExtractor.isNumberLike("一百") && CorrectionExtractor.isNumberLike("两块")
               && CorrectionExtractor.isNumberLike("twenty one") && CorrectionExtractor.isNumberLike("统一")
               && CorrectionExtractor.isNumberLike("3 号"))
        // A numeral next to a word for time or quantity, however long the word.
        #expect(CorrectionExtractor.isNumberLike("星期三") && CorrectionExtractor.isNumberLike("礼拜三")
               && CorrectionExtractor.isNumberLike("三个月") && CorrectionExtractor.isNumberLike("十一点半"))
        #expect(!CorrectionExtractor.isNumberLike("金币") && !CorrectionExtractor.isNumberLike("Open Air")
               && !CorrectionExtractor.isNumberLike("第一版本的"))
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func item(_ wrong: String, _ right: String) -> LearnedCorrection {
            LearnedCorrection(pair: p(wrong, right), count: 3, firstSeen: now, lastSeen: now, source: .imported, addedTerm: false)
        }
        // However often it was fixed, or wherever the pair came from (imported, the Neo's).
        let book = LearningBook(items: [item("一百", "一版"), item("引必", "音币"), item("twenty", "Trenty")])
        #expect(LearningPrompt.applyConfirmed("转一百块给他，一共一百二十，引必也算上，about twenty people", book: book)
               == "转一百块给他，一共一百二十，音币也算上，about twenty people")
        // The model still gets it as a hint, with the sentence to judge by.
        #expect(LearningPrompt.pairs(for: "先出一百看看", from: book) == [p("一百", "一版")])
    }


    @Test func countingDownIsToldFromLearning() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var book = LearningBook()
        _ = book.record([p("金币", "硬币"), p("Iphone", "iPhone")], source: .otherApp, recordID: nil, now: now) { _ in false }
        #expect(book.countsDown(p("硬币", "金币")))
        #expect(!book.countsDown(p("金币", "硬币")))
        #expect(book.countsDown(p("iPhone", "Iphone")) && !book.countsDown(p("Iphone", "iPhone")))
        #expect(!book.countsDown(p("Nio", "你有")))
    }


    @Test func trackerSaysWhenTextWasOnlyRemoved() {
        var t = EditTracker(original: "嗯这个我觉得金币还可以")
        #expect(t.settle("我觉得金币还可以") == .none)
        #expect(t.removesOnly("我觉得金币还可以"))
        #expect(!t.removesOnly("我觉得音币还可以") && !t.removesOnly("嗯这个我觉得金币还可以"))
        // The baseline stays, and the fix made afterwards is still found: the deleted words are a stretch of their own.
        guard case let .extract(inserted, edited) = t.settle("我觉得音币还可以") else {
                Issue.record("the fix after the deletion was not handed out")
                return
            }
        #expect(inserted == "嗯这个我觉得金币还可以")
        #expect(CorrectionExtractor().pairs(inserted: inserted, edited: edited, knownTerms: ["音币"]) == [p("金币", "音币")])
    }
}

/// Finding the pasted passage in a field that shows it a little differently.
@Suite struct PassageLocatorTests {
    @Test func locatorFindsThePassageAsTheFieldShowsIt() {
        let text = "帮我看看 Open Air 的账单。\n\n然后发给 Martn。"
        // As pasted.
        let exact = PassageLocator.locate(text, in: "早上好。" + text)
        #expect(exact?.text == text && exact?.range == 4..<(4 + text.utf16.count))
        // A no-break space for a space, one line break for two, a line break added at the end, a zero-width space.
        let shown = "帮我看看\u{00A0}Open Air 的账单。\n然后发给 Martn。\u{200B}"
        let changed = PassageLocator.locate(text, in: "早上好。" + shown + "\n")
        #expect(changed?.text == "帮我看看\u{00A0}Open Air 的账单。\n然后发给 Martn。")
        #expect(changed?.range.lowerBound == 4)
        // A trailing line break in what was pasted is not looked for.
        #expect(PassageLocator.locate("好的\n", in: "好的")?.text == "好的")
        // Not there (a field that shows something else, or nothing).
        #expect(PassageLocator.locate(text, in: "早上好。") == nil)
        #expect(PassageLocator.locate(text, in: "") == nil && PassageLocator.locate("  \n", in: "abc") == nil)
    }


    @Test func locatorTakesThePlaceTheCaretIsAt() {
        let value = "好的收到。中间一些话。好的收到。"
        // In two places and no caret to tell which was just typed: not guessed (WL-9). Watching the other one
        // would learn from edits of text neoless did not type.
        #expect(PassageLocator.locate("好的收到。", in: value) == nil)
        #expect(PassageLocator.locate("金币", in: "我有金币。再看一下金币的图案") == nil)
        #expect(PassageLocator.locate("金币", in: "我有金币。再看一下金币的图案", caret: 4)?.range == 2..<4)
        #expect(PassageLocator.locate("好的收到。", in: value, caret: 5)?.range == 0..<5)
        #expect(PassageLocator.locate("好的收到。", in: value, caret: 16)?.range == 11..<16)
        // Offsets are UTF-16: an emoji before the passage counts two.
        #expect(PassageLocator.locate("收到", in: "😀收到")?.range == 2..<4)
    }


    @Test func locatorToleratesALongPassageChangedInTheMiddle() {
        let pasted = "第一点：先把上周的会议记录整理出来。\n- 第二点：再把 \"预算表\" 发给大家看一下，周五之前要定下来。"
        // The app wrote its own quotation marks and turned the list marker into a bullet.
        let shown = "第一点：先把上周的会议记录整理出来。\n• 第二点：再把 “预算表” 发给大家看一下，周五之前要定下来。"
        let found = PassageLocator.locate(pasted, in: "前面的话。" + shown + "后面的话。")
        #expect(found?.text == shown)
        // Too short to be found by its ends alone.
        #expect(PassageLocator.locate("把 \"预算表\" 发出去", in: "把 “预算表” 发出去") == nil)
    }


    @Test func locatorFindsThePassageAgainAfterTextAroundItChanged() {
        let passage = "看看金币是多少"
        let found = PassageLocator.relocate(passage, in: "新加的一句。" + passage + "。后面也加了", near: 0)
        #expect(found?.range == 6..<13 && found?.text == passage)
        // Of two, the one nearest to where it was.
        #expect(PassageLocator.relocate("好的", in: "好的，好的", near: 3)?.range == 3..<5)
        #expect(PassageLocator.relocate(passage, in: "看看硬币是多少", near: 0) == nil)
    }
}

/// When a watched passage is compared, and what a watch that ends still hands over.
@Suite struct PassageWatchTests {
    @Test func watchComparesATextOnceItHasSettled() {
        var watch = PassageWatch(shown: "看看金币", at: 100)
        #expect(watch.take(.passage("看看金币", composing: false), at: 100.4) == .wait)
        #expect(watch.take(.passage("看看硬币", composing: false), at: 101) == .wait)
        #expect(watch.interval(at: 101.2) == PassageWatch.busyInterval)
        #expect(watch.take(.passage("看看硬币", composing: false), at: 102) == .wait)
        #expect(watch.take(.passage("看看硬币", composing: false), at: 102.5) == .settled("看看硬币"))
        // Once: the same text is not handed out again.
        #expect(watch.take(.passage("看看硬币", composing: false), at: 103) == .wait)
        #expect(watch.interval(at: 105) == PassageWatch.pollInterval)
        #expect(watch.passage == "看看硬币")
    }


    @Test func watchHandsOverAnUncomparedFixOnlyWhereTheUserIsDoneWithIt() {
        // Fixed a word, then sent the message: the field is empty before the text had settled.
        var sent = PassageWatch(shown: "看看金币", at: 0)
        _ = sent.take(.passage("看看硬币", composing: false), at: 1)
        #expect(sent.take(.empty, at: 1.5) == .end(.sent, flush: "看看硬币"))
        // The same for a new dictation.
        var again = PassageWatch(shown: "看看金币", at: 0)
        _ = again.take(.passage("看看硬币", composing: false), at: 1)
        #expect(again.end(.newDictation, at: 1.4) == .end(.newDictation, flush: "看看硬币"))
        // Still typing when it ended (changed a moment ago): a half-typed word teaches nothing.
        var typing = PassageWatch(shown: "看看金币", at: 0)
        _ = typing.take(.passage("看看假", composing: false), at: 1)
        #expect(typing.end(.newDictation, at: 1.2) == .end(.newDictation, flush: nil))
        // Nothing changed, or it was compared already: nothing to hand over.
        var untouched = PassageWatch(shown: "看看金币", at: 0)
        #expect(untouched.take(.empty, at: 5) == .end(.sent, flush: nil))
        var settled = PassageWatch(shown: "看看金币", at: 0)
        _ = settled.take(.passage("看看硬币", composing: false), at: 1)
        #expect(settled.take(.passage("看看硬币", composing: false), at: 2.6) == .settled("看看硬币"))
        #expect(settled.take(.lost, at: 3) == .end(.lost, flush: nil))
        // 自动学习 switched off: nothing more is compared.
        var off = PassageWatch(shown: "看看金币", at: 0)
        _ = off.take(.passage("看看硬币", composing: false), at: 1)
        #expect(off.end(.off, at: 5) == .end(.off, flush: nil))

        // Anywhere the user has not plainly finished, the last text seen may be a word half typed
        // (科德克斯 → Code, on the way to Codex): nothing is handed over. The field shows other text…
        var lost = PassageWatch(shown: "我用科德克斯写代码", at: 0)
        _ = lost.take(.passage("我用 Code 写代码", composing: false), at: 1)
        #expect(lost.take(.lost, at: 2) == .end(.lost, flush: nil))
        // …the app stopped answering while the user typed on…
        var failing = PassageWatch(shown: "我用科德克斯写代码", at: 0)
        _ = failing.take(.passage("我用 Code 写代码", composing: false), at: 1)
        _ = failing.take(.failed, at: 1.3)
        _ = failing.take(.failed, at: 1.6)
        #expect(failing.take(.failed, at: 1.9) == .end(.failed, flush: nil))
        // …or the time was up in the middle of an edit.
        var late = PassageWatch(shown: "我用科德克斯写代码", at: 0)
        _ = late.take(.passage("我用 Code 写代码", composing: false), at: PassageWatch.maxDuration - 0.5)
        #expect(late.take(.passage("我用 Code 写代码", composing: false), at: PassageWatch.maxDuration + 0.1) == .end(.deadline, flush: nil))
        #expect(PassageWatch.End.sent.flushes && PassageWatch.End.newDictation.flushes)
        for reason in [PassageWatch.End.moved, .lost, .failed, .deadline, .idle, .appChanged, .off, .quit] {
            #expect(!reason.flushes, "\(reason)")
        }
    }


    @Test func aWatchGoesOnFromAfarWhenTheUserLeaves() {
        // Half a word typed, then another app in front: nothing is compared at the switch.
        var watch = PassageWatch(shown: "我用科德克斯写代码", at: 0)
        _ = watch.take(.passage("我用 Code 写代码", composing: false), at: 1)
        watch.leave()
        #expect(watch.isAway && watch.hasUncompared)
        // While a change waits, the field is read from afar as often as before; once it has been still for
        // the usual time it is compared, like any settled text.
        #expect(watch.interval(at: 1.2) == PassageWatch.busyInterval)
        #expect(watch.take(.passage("我用 Code 写代码", composing: false), at: 1.4, focused: false) == .wait)
        #expect(watch.take(.passage("我用 Code 写代码", composing: false), at: 2.6, focused: false) == .settled("我用 Code 写代码"))
        // Not over: the user may come back. Nothing waits, so it is looked at seldom, and the idle time does not run.
        #expect(watch.isAway && !watch.hasUncompared)
        #expect(watch.interval(at: 10) == PassageWatch.awayInterval)
        #expect(watch.take(.moved, at: 2.6 + PassageWatch.idleAfterChange + 5) == .wait)
        // Back in the field, the word is finished: compared again, so the two steps chain into 科德克斯 → Codex
        // (`LearningBook.chained`).
        let back: TimeInterval = 50
        #expect(watch.take(.passage("我用 Code 写代码", composing: false), at: back) == .wait)
        #expect(!watch.isAway)
        #expect(watch.take(.passage("我用 Codex 写代码", composing: false), at: back + 1) == .wait)
        #expect(watch.take(.passage("我用 Codex 写代码", composing: false), at: back + 2.6) == .settled("我用 Codex 写代码"))
        // The idle time counts again, from the return.
        #expect(watch.take(.passage("我用 Codex 写代码", composing: false), at: back + 2.6 + PassageWatch.idleAfterChange - 1) == .wait)
        #expect(watch.take(.passage("我用 Codex 写代码", composing: false), at: back + 2.6 + PassageWatch.idleAfterChange + 1) == .end(.idle, flush: nil))

        // Focus elsewhere in the same app is the same: it does not end the watch.
        var moved = PassageWatch(shown: "看看金币", at: 0)
        _ = moved.take(.passage("看看硬币", composing: false), at: 1)
        #expect(moved.take(.moved, at: 1.2) == .wait)
        #expect(moved.isAway)
        #expect(moved.take(.passage("看看硬币", composing: false), at: 2.6, focused: false) == .settled("看看硬币"))

        // What changes while focus is elsewhere is not the user typing into the field: it is never compared,
        // and what was waiting is no longer what the field shows.
        var changed = PassageWatch(shown: "看看金币", at: 0)
        _ = changed.take(.passage("看看硬币", composing: false), at: 1)
        changed.leave()
        #expect(changed.take(.passage("看看别的", composing: false), at: 1.5, focused: false) == .wait)
        #expect(!changed.hasUncompared)
        #expect(changed.take(.passage("看看别的", composing: false), at: 5, focused: false) == .wait)
        #expect(changed.end(.newDictation, at: 6) == .end(.newDictation, flush: nil))

        // Left, and a new dictation begins elsewhere before the text had been still for the usual time: the
        // word may be half typed. After that time it is handed over.
        var hasty = PassageWatch(shown: "我用科德克斯写代码", at: 0)
        _ = hasty.take(.passage("我用 Code 写代码", composing: false), at: 1)
        hasty.leave()
        var patient = hasty
        #expect(hasty.end(.newDictation, at: 2) == .end(.newDictation, flush: nil))
        #expect(patient.end(.newDictation, at: 2.6) == .end(.newDictation, flush: "我用 Code 写代码"))
        // Sent, then left at once: sending says the text was final.
        var sentThenLeft = PassageWatch(shown: "看看金币", at: 0)
        _ = sentThenLeft.take(.passage("看看硬币", composing: false), at: 1)
        sentThenLeft.leave()
        #expect(sentThenLeft.take(.empty, at: 1.4, focused: false) == .end(.sent, flush: "看看硬币"))
        // The time is up while away.
        var gone = PassageWatch(shown: "看看金币", at: 0)
        gone.leave()
        #expect(gone.take(.moved, at: PassageWatch.maxDuration - 1) == .wait)
        #expect(gone.take(.moved, at: PassageWatch.maxDuration + 1) == .end(.deadline, flush: nil))
    }


    @Test func landingLooksAgainOnlyWhileThatCanHelp() {
        // An app asked for its accessibility tree only now gets time to build it; any other app a moment.
        #expect(PassageLanding.retries(.unreadable, asked: true, elapsed: 3.9))
        #expect(!PassageLanding.retries(.unreadable, asked: true, elapsed: 4.1))
        #expect(PassageLanding.retries(.notFound, asked: false, elapsed: 1))
        #expect(!PassageLanding.retries(.notFound, asked: false, elapsed: 1.6))
        #expect(PassageLanding.retries(.slow, asked: false, elapsed: 0.3))
        // A field with too much text stays too long: never read again for this paste.
        #expect(!PassageLanding.retries(.tooLong, asked: true, elapsed: 0.2))
        #expect(!PassageLanding.retries(.tooLong, asked: false, elapsed: 0))
        // A launcher's panel over the app has the keyboard: the text went there, and the app underneath is
        // neither read nor asked for anything. neoless's own panel, or no answer, is not "elsewhere".
        #expect(PassageLanding.isElsewhere(focusOwner: 77, target: 501, own: 9))
        #expect(!PassageLanding.isElsewhere(focusOwner: 501, target: 501, own: 9))
        #expect(!PassageLanding.isElsewhere(focusOwner: 9, target: 501, own: 9))
        #expect(!PassageLanding.isElsewhere(focusOwner: nil, target: 501, own: 9))
    }


    @Test func watchWaitsForTheInputMethod() {
        var watch = PassageWatch(shown: "看看金币", at: 0)
        #expect(watch.take(.passage("看看yin币", composing: true), at: 1) == .wait)
        #expect(watch.take(.passage("看看yin币", composing: true), at: 3) == .wait)
        // Uncommitted text is never handed over at the end.
        var ending = watch
        #expect(ending.end(.newDictation, at: 3) == .end(.newDictation, flush: nil))
        // Committed: settles like any change.
        #expect(watch.take(.passage("看看硬币", composing: false), at: 3.4) == .wait)
        #expect(watch.take(.passage("看看硬币", composing: false), at: 5) == .settled("看看硬币"))
        // A field that says "composing" for ever is taken at its word no longer.
        var stuck = PassageWatch(shown: "看看金币", at: 0)
        _ = stuck.take(.passage("看看硬币", composing: true), at: 1)
        #expect(stuck.take(.passage("看看硬币", composing: true), at: 4) == .wait)
        #expect(stuck.take(.passage("看看硬币", composing: true), at: 5.1) == .settled("看看硬币"))
    }


    @Test func watchEndsOnFailuresAndDeadlines() {
        var failing = PassageWatch(shown: "a", at: 0)
        #expect(failing.take(.failed, at: 1) == .wait)
        #expect(failing.take(.failed, at: 2) == .wait)
        // An answer in between starts the count again.
        #expect(failing.take(.passage("a", composing: false), at: 3) == .wait)
        #expect(failing.take(.failed, at: 4) == .wait)
        #expect(failing.take(.failed, at: 5) == .wait)
        #expect(failing.take(.failed, at: 6) == .end(.failed, flush: nil))

        var long = PassageWatch(shown: "a", at: 0)
        #expect(long.take(.passage("a", composing: false), at: PassageWatch.maxDuration - 1) == .wait)
        #expect(long.take(.passage("a", composing: false), at: PassageWatch.maxDuration + 1) == .end(.deadline, flush: nil))

        var idle = PassageWatch(shown: "a", at: 0)
        _ = idle.take(.passage("b", composing: false), at: 1)
        #expect(idle.take(.passage("b", composing: false), at: 3) == .settled("b"))
        #expect(idle.take(.passage("b", composing: false), at: 3 + PassageWatch.idleAfterChange - 1) == .wait)
        #expect(idle.take(.passage("b", composing: false), at: 3 + PassageWatch.idleAfterChange + 1) == .end(.idle, flush: nil))
    }
}

/// What the user is told: the log, the capsule's lines, and which apps are asked to make their fields readable.
@Suite struct LearningSurfaceTests {
    @Test func logKeepsWhatBecameOfRecentEdits() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var log = LearningLog()
        log.add(.removedOnly, app: "Notes", at: start)
        // The same thing again a moment later is one entry.
        log.add(.removedOnly, app: "Notes", at: start.addingTimeInterval(30))
        #expect(log.entries.count == 1 && log.entries[0].at == start.addingTimeInterval(30))
        log.add(.learned, app: "Notes", count: 2, at: start.addingTimeInterval(40))
        log.add(.learned, app: "Notes", count: 1, at: start.addingTimeInterval(50))
        log.add(.unreadable, app: "Claude", at: start.addingTimeInterval(60))
        log.add(.removedOnly, app: nil, at: start.addingTimeInterval(70))
        #expect(log.entries.map(\.code) == ["removedOnly", "unreadable", "learned", "learned", "removedOnly"])
        #expect(log.entries[2].count == 1 && log.entries[3].count == 2)
        for n in 0..<(LearningLog.limit + 5) { log.add(.learned, app: "Notes", count: n, at: start.addingTimeInterval(100 + Double(n))) }
        #expect(log.entries.count == LearningLog.limit && log.entries[0].count == LearningLog.limit + 4)
        // Codes, counts, the app and the time: nothing else is in the file.
        let data = try JSONEncoder().encode(log)
        #expect(try JSONDecoder().decode(LearningLog.self, from: data) == log)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let first = (object?["entries"] as? [[String: Any]])?.first
        #expect(Set(first?.keys.map { $0 } ?? []) == ["id", "at", "app", "code", "count"])
        // Every reason an edit teaches nothing has its code.
        for nothing in [Extraction.Nothing.removedOnly, .formatOnly, .rewrite, .sensitive, .notTerms, .unlikeName, .knownName] {
            #expect(LearningLog.Code(nothing).rawValue == nothing.rawValue)
        }
        #expect(LearningLog.Code.unreadable.isUnwatched && LearningLog.Code.slow.isUnwatched && !LearningLog.Code.notTerms.isUnwatched)
        #expect(LearningText.line(code: LearningLog.Code.unlikeName.rawValue, count: 0) == "换成的名字不确定是听错的，可手动加进词典")
    }


    @Test func learningLines() {
        let narrow: (String) -> Bool = { $0.count <= 12 }
        #expect(LearningText.learned(pairs: [p("金币", "硬币")]) == "已记住：金币 → 硬币")
        #expect(LearningText.learned(pairs: [p("Open Air", "OpenAI")], fits: narrow) == "已记住：OpenAI")
        #expect(LearningText.learned(pairs: [], terms: ["Nio"]) == "已记住：Nio")
        #expect(LearningText.learned(pairs: [p("金币", "硬币"), p("Martn", "Martin")], terms: ["Nio"])
               == "已记住：金币 → 硬币、Martn → Martin、Nio")
        #expect(LearningText.learned(pairs: [p("金币", "硬币"), p("Martn", "Martin")], terms: ["Nio"], fits: narrow) == "已记住：硬币等 3 个词")
        #expect(LearningText.learned(pairs: [p("Open Air", "OpenAI"), p("Martn", "Martin")], fits: { $0.count <= 8 }) == "已记住 2 个词")
        #expect(LearningText.summary(pairs: [p("Open Air", "OpenAI")], terms: ["Nio"]) == "Open Air → OpenAI、Nio")
        // Only a term fix that was not learned is worth a line; deleting, rewording or rewriting is not one.
        #expect(LearningText.missed(.unlikeName) == "没记住，可手动加进词典" && LearningText.missed(.sensitive) == "没记住：这段话像有密码或地址")
        #expect(LearningText.missed(.removedOnly) == nil && LearningText.missed(.formatOnly) == nil
                && LearningText.missed(.rewrite) == nil && LearningText.missed(.notTerms) == nil)
        #expect(LearningText.unwatched(app: "Claude") == "学不到 Claude 里的修改")
        #expect(LearningText.unwatched(app: "微信") == "学不到微信里的修改")
        #expect(LearningText.unwatched(app: "An App With A Very Long Name", fits: narrow) == "学不到这里的修改")
        #expect(LearningText.unwatched(app: nil) == "学不到这里的修改")
        #expect(LearningText.line(code: "learned", count: 2) == "记住了 2 个词")
        #expect(LearningText.line(code: "hubRefused", count: 1) == "Neo 没收下 1 条纠正")
        #expect(LearningText.line(code: "from-a-newer-version", count: 0) == "没有记")
        // The capsule tells them apart from a dictation's result, and keeps them up long enough to read.
        #expect(CapsuleText.kind(done: LearningText.learned(pairs: [p("金币", "硬币")])) == .learned)
        #expect(CapsuleText.kind(done: LearningText.missed(.unlikeName) ?? "") == .note)
        #expect(CapsuleText.kind(done: LearningText.unwatched(app: "Claude")) == .note)
        #expect(CapsuleTiming.linger(.learned, text: "已记住：OpenAI") > CapsuleTiming.linger(.done, text: "已输入 9 字"))
        #expect(!CapsuleTiming.collapsesQuietly(done: LearningText.learned(pairs: [p("金币", "硬币")])))
    }


    @Test func onlyListedAppsAreAskedForTheirAccessibilityTree() {
        for id in ["com.anthropic.claudefordesktop", "com.openai.codex", "com.openai.chat"] {
            #expect(WebAccessibility.kind(bundleID: id) == .electron, "\(id)")
        }
        #expect(WebAccessibility.kind(bundleID: "com.google.Chrome") == .chromium)
        // Native apps need no asking; unknown apps are left alone; password managers always.
        for id in ["com.apple.Notes", "com.tencent.xinWeChat", "com.example.unknown", "com.1password.1password", "com.bitwarden.desktop"] {
            #expect(!WebAccessibility.mayAsk(bundleID: id), "\(id)")
        }
        #expect(!WebAccessibility.mayAsk(bundleID: nil))
        #expect(WebAccessibility.electron.union(WebAccessibility.chromium).allSatisfy { !WebAccessibility.isPasswordManager($0) })
    }


    @Test func codeEditorsAreAskedOnlyWhenSwitchedOn() {
        // The VS Code family takes being asked for a screen reader and switches to its screen-reader mode.
        let family = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
                      "com.exafunction.windsurf", "com.vscodium"]
        #expect(WebAccessibility.editors.map(\.bundleID) == family)
        #expect(WebAccessibility.editors.map(\.name) == ["VS Code", "VS Code Insiders", "Cursor", "Windsurf", "VSCodium"])
        for id in family {
            #expect(WebAccessibility.isEditor(id), "\(id)")
            #expect(!WebAccessibility.mayAsk(bundleID: id), "\(id)")
            #expect(!WebAccessibility.electron.contains(id) && !WebAccessibility.chromium.contains(id), "\(id)")
        }
        // One by one.
        let on: Set<String> = ["com.todesktop.230313mzl4w4u92"]
        #expect(WebAccessibility.kind(bundleID: "com.todesktop.230313mzl4w4u92", optedIn: on) == .electron)
        #expect(!WebAccessibility.mayAsk(bundleID: "com.microsoft.VSCode", optedIn: on))
        // Switching on is for these editors only: it puts nothing else on the list.
        #expect(!WebAccessibility.mayAsk(bundleID: "com.apple.Notes", optedIn: ["com.apple.Notes"]))
        #expect(!WebAccessibility.mayAsk(bundleID: "com.1password.1password", optedIn: ["com.1password.1password"]))
        #expect(!WebAccessibility.isEditor("com.anthropic.claudefordesktop") && !WebAccessibility.isEditor(nil))
        #expect(WebAccessibility.editorWarning.contains("屏幕阅读器"))
        #expect(LearningText.line(code: "needsOptIn", count: 0) == "没打开对这个编辑器的学习，可在设置里打开")
    }


    @Test func nothingTypedIntoAPasswordManagerIsWatched() {
        for id in ["com.apple.Passwords", "com.markmcguill.strongbox", "com.apple.keychainaccess", "com.agilebits.onepassword7",
                   "com.1password.1password", "org.keepassxc.keepassxc", "com.bitwarden.desktop"] {
            #expect(WebAccessibility.isPasswordManager(id), "\(id)")
        }
        for id in ["com.google.Chrome", "com.apple.Notes", "com.anthropic.claudefordesktop", "com.apple.Terminal", "com.apple.TextEdit"] {
            #expect(!WebAccessibility.isPasswordManager(id), "\(id)")
        }
        #expect(WebAccessibility.editors.allSatisfy { !WebAccessibility.isPasswordManager($0.bundleID) })
    }


    @Test func anAppIsAskedOnlyWhenItsTreeIsNotAlreadyThere() {
        typealias Request = AccessibilityTreeRequest
        // It says the switch is on: someone else's tree, or neoless's own still on. Never asked, so never
        // noted as neoless's to switch off.
        #expect(Request.decide(before: .on, focusReadsAsText: false, ours: false, again: false) == .nothing)
        #expect(Request.decide(before: .on, focusReadsAsText: false, ours: true, again: true) == .nothing)
        // Off: asked. Also when neoless asked before and something switched it off since.
        #expect(Request.decide(before: .off, focusReadsAsText: false, ours: false, again: false) == .ask)
        #expect(Request.decide(before: .off, focusReadsAsText: true, ours: true, again: false) == .ask)
        // It says off, and the field reads as text all the same, without neoless having asked: a tree is there
        // whatever the switch says (what an app answers about it is not always the whole truth). Someone
        // else's: not set, so never noted, so never switched off under them.
        #expect(Request.decide(before: .off, focusReadsAsText: true, ours: false, again: false) == .nothing)
        #expect(Request.decide(before: .off, focusReadsAsText: true, ours: false, again: true) == .nothing)
        // No answer in time: nothing is asked of a busy app.
        #expect(Request.decide(before: .busy, focusReadsAsText: false, ours: false, again: true) == .nothing)
        // It does not say. A field that reads as text means a tree is there: not neoless's, not touched.
        #expect(Request.decide(before: .unknown, focusReadsAsText: true, ours: false, again: false) == .nothing)
        #expect(Request.decide(before: .unknown, focusReadsAsText: false, ours: false, again: false) == .ask)
        // Asked already: once more only after a paste that could not be read, not on every dictation.
        #expect(Request.decide(before: .unknown, focusReadsAsText: false, ours: true, again: false) == .nothing)
        #expect(Request.decide(before: .unknown, focusReadsAsText: false, ours: true, again: true) == .ask)
    }


    @Test func whatWasSwitchedOnIsNotedForTheNextLaunch() throws {
        let launched = Date(timeIntervalSince1970: 1_790_000_000)
        var woken = WokenApps()
        #expect(woken.isEmpty)
        woken.add(.init(pid: 501, bundleID: "com.anthropic.claudefordesktop", launched: launched))
        woken.add(.init(pid: 502, bundleID: "com.openai.codex", launched: nil))
        // Asked again: noted once.
        woken.add(.init(pid: 501, bundleID: "com.anthropic.claudefordesktop", launched: launched))
        #expect(woken.apps.map(\.pid) == [502, 501])
        #expect(woken.contains(pid: 501) && !woken.contains(pid: 7))
        // Process id, bundle id and launch time: nothing else is in the file.
        let data = try JSONEncoder().encode(woken)
        #expect(try JSONDecoder().decode(WokenApps.self, from: data) == woken)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let last = (object?["apps"] as? [[String: Any]])?.last
        #expect(Set(last?.keys.map { $0 } ?? []) == ["pid", "bundleID", "launched"])
        // Only the same process is told to stop: a process id is used again after an app quits.
        let claude = woken.apps[1]
        #expect(WokenApps.isSame(claude, bundleID: "com.anthropic.claudefordesktop", launched: launched))
        // The launch time read back from disk has lost its fraction of a second.
        #expect(WokenApps.isSame(claude, bundleID: "com.anthropic.claudefordesktop", launched: launched.addingTimeInterval(0.4)))
        #expect(!WokenApps.isSame(claude, bundleID: "com.apple.Notes", launched: launched))
        #expect(!WokenApps.isSame(claude, bundleID: "com.anthropic.claudefordesktop", launched: launched.addingTimeInterval(600)))
        #expect(!WokenApps.isSame(claude, bundleID: nil, launched: nil))
        #expect(WokenApps.isSame(woken.apps[0], bundleID: "com.openai.codex", launched: launched))
        #expect(woken.remove(pid: 501) == claude)
        #expect(woken.remove(pid: 501) == nil)
        #expect(woken.apps.count == 1 && !woken.isEmpty)
    }


    @Test func aLineThatWaitsIsSaidOnceAndNotWhenItIsOld() {
        var held = HeldLine<String>()
        #expect(held.isEmpty)
        #expect(held.take(at: 0) == nil)
        // The newest replaces the one waiting…
        held.hold("已记住：OpenAI", at: 10)
        held.hold("已记住：Codex", at: 11)
        #expect(!held.isEmpty)
        #expect(held.take(at: 15) == "已记住：Codex")
        #expect(held.take(at: 16) == nil)
        // …unless the one waiting matters more.
        held.hold("已记住：OpenAI", at: 20)
        held.hold("学不到这里的修改", at: 21) { $0.hasPrefix(LearningText.learnedPrefix) }
        #expect(held.take(at: 22) == "已记住：OpenAI")
        // One that has waited too long is no longer about what the user just did.
        held.hold("已记住：OpenAI", at: 30)
        #expect(held.take(at: 30 + HeldLine<String>.maxAge + 1) == nil)
        #expect(held.isEmpty)
    }


    @Test func theLogSaysOncePerAppThatItsEditsCannotBeSeen() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var log = LearningLog()
        let first = log.add(.tooLong, app: "Terminal", at: start)
        log.add(.learned, app: "Notes", count: 1, at: start.addingTimeInterval(600))
        // An hour later, again: the same line with the new time, not a second one. The list is not a record of
        // every dictation into that app.
        let again = log.add(.tooLong, app: "Terminal", at: start.addingTimeInterval(3_600))
        #expect(again == first)
        #expect(log.entries.map(\.code) == ["tooLong", "learned"])
        #expect(log.entries[0].at == start.addingTimeInterval(3_600))
        // Another app, or another reason, has its own line.
        log.add(.tooLong, app: "Xcode", at: start.addingTimeInterval(3_700))
        log.add(.unreadable, app: "Terminal", at: start.addingTimeInterval(3_800))
        log.add(.needsOptIn, app: "Cursor", at: start.addingTimeInterval(3_900))
        log.add(.needsOptIn, app: "Cursor", at: start.addingTimeInterval(9_000))
        #expect(log.entries.map(\.code) == ["needsOptIn", "unreadable", "tooLong", "tooLong", "learned"])
        #expect(LearningLog.Code.tooLong.isUnwatched && LearningLog.Code.needsOptIn.isUnwatched)
        #expect(LearningText.line(code: "tooLong", count: 0) == "输入框里的文字太多，学不到")
        // 清空, the list's own 清除, 自动学习 switched off.
        log.clear()
        #expect(log.entries.isEmpty)
    }
}
