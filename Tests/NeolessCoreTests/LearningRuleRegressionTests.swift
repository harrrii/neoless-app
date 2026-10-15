import Foundation
import Testing
@testable import NeolessCore

// One suite for each finding of the review of the learning fix (2026-10-10). The
// rule they share: it is better to learn nothing than something false, because a learned pair is put before
// the model at once and written into text without it after a second fix. All text here is made up.

/// An edit that must teach nothing, or exactly `expected`.
struct RuleRow: Sendable, CustomTestStringConvertible {
    var inserted: String
    var edited: String
    /// Mappings as "错 → 对", words learned alone as "[词]".
    var expected: [String] = []
    var known: Set<String> = []
    var nothing: Extraction.Nothing?

    var testDescription: String { "\(inserted) ⇒ \(edited)".replacingOccurrences(of: "\n", with: "⏎") }
}

private func extraction(_ row: RuleRow) -> Extraction {
    CorrectionExtractor().extract(inserted: row.inserted, edited: row.edited, knownTerms: row.known)
}

/// A pair as "错|对", so a list of them reads as a table.
private func pair(_ s: String) -> CorrectionPair {
    let parts = s.components(separatedBy: "|")
    return CorrectionPair(wrong: parts[0], right: parts[1])
}

private let day = Date(timeIntervalSince1970: 1_790_000_000)
/// Shaped like an API key and made up. Written in two halves so that no tool searching for keys stops here.
private let madeUpKey = "sk-proj-" + "a1b2c3d4e5f6g7h8i9j0"

private func confirmed(_ pairs: [String]) -> LearningBook {
    LearningBook(items: pairs.map {
        LearnedCorrection(pair: pair($0), count: 5, firstSeen: day, lastSeen: day, source: .otherApp, addedTerm: false)
    })
}

// MARK: - WL-1 numbers and dates

@Suite struct NumeralRuleTests {
    /// A date, a time or a quantity changed: the user decided otherwise, neoless did not mishear.
    static let edits: [RuleRow] = [
        RuleRow(inserted: "帮我订周五去广州的机票", edited: "帮我订周日去广州的机票"),
        RuleRow(inserted: "星期三开会", edited: "星期天开会"),
        RuleRow(inserted: "十一月上线", edited: "十月上线"),
        RuleRow(inserted: "十二月上线", edited: "十月上线"),
        RuleRow(inserted: "十一点见", edited: "十点见"),
        RuleRow(inserted: "有效期三个月", edited: "有效期上个月"),
        RuleRow(inserted: "我一定去", edited: "我必定去"),
        RuleRow(inserted: "买个二手的", edited: "买个新手的"),
        RuleRow(inserted: "等一会儿再说", edited: "等待会儿再说"),
        RuleRow(inserted: "下周三交报告", edited: "下周末交报告"),
        RuleRow(inserted: "Meet on Tuesday", edited: "Meet on Thursday"),
        RuleRow(inserted: "due in November", edited: "due in December"),
    ]

    @Test(arguments: edits)
    func aNumberOrADateThatChangedTeachesNothing(_ row: RuleRow) {
        let found = extraction(row)
        #expect(found.fixes.isEmpty, "\(fixes(found))")
        #expect(found.nothing == .notTerms)
    }

    static let pairs = [
        "周五|周日", "周一|周日", "周六|周日", "星期三|星期天", "星期三|星期日", "礼拜三|礼拜天", "十一月|十月", "十二月|十月",
        "十一点|十点", "三个月|上个月", "一定|必定", "二手|新手", "等一|等待", "周五|周末", "三点|晚点", "每周一|每周日",
        "五点|午点", "五线|无线", "一会儿|待会儿", "二十号|十号", "Tuesday|Thursday", "Sunday|Monday", "November|December",
    ]

    @Test(arguments: pairs)
    func theHubRefusesThemAsBarePairs(_ text: String) {
        #expect(CorrectionExtractor().strength(of: pair(text)) == nil)
        #expect(!CorrectionExtractor().isTermFix(pair(text)))
    }

    @Test func aPairThatChangesANumberIsNeverWrittenWithoutTheModel() {
        // Learned by an older version, imported, or sent by another device: however often it was fixed.
        let book = confirmed(Self.pairs + ["有效期三个月|有效期上个月"])
        for text in ["下周三要交报告，星期三开会", "有效期三个月", "周五去广州，十一月回来", "二手的也行，等一会儿", "Tuesday and November"] {
            #expect(LearningPrompt.applyConfirmed(text, book: book) == text)
        }
        for text in Self.pairs { #expect(!CorrectionExtractor.replacesBlindly(pair(text)), "\(text)") }
    }

    @Test func aNameTypedOverWordsWithANumeralIsLearnedAsAWordOnly() {
        // 三星 → Samsung as a mapping would be a number rewritten; the name alone is harmless.
        let found = CorrectionExtractor().extract(inserted: "用三星手机", edited: "用 Samsung 手机")
        #expect(fixes(found) == ["[Samsung]"])
        #expect(CorrectionExtractor().strength(of: pair("一百|Ebay")) == nil)
    }
}

// MARK: - WL-2 negation

@Suite struct NegationRuleTests {
    /// A negating character comes or goes, also in place of another character.
    static let pairs = [
        "有效|无效", "无效|有效", "合法|非法", "非法|合法", "已婚|未婚", "未婚|已婚", "可行|不行", "有害|无害", "有关|无关",
        "有罪|无罪", "有偿|无偿", "无线|有线", "有用|无用", "有限|无限", "有空|没空", "正常|非常", "已经|未经",
        // The same sound does not make a negation safe to rewrite: every 不行 said later would become 步行.
        "不行|步行", "吴线|无线", "飞常|非常", "位来|未来", "不同意|同意", "同意|不同意", "没问题|问题",
    ]

    @Test(arguments: pairs)
    func aNegationThatComesOrGoesIsNeverLearned(_ text: String) {
        let extractor = CorrectionExtractor()
        #expect(extractor.strength(of: pair(text)) == nil)
        // Not with the corrected word in the dictionary either.
        #expect(extractor.strength(of: pair(text), knownTerms: [pair(text).right]) == nil)
        #expect(!CorrectionExtractor.replacesBlindly(pair(text)))
    }

    static let edits: [RuleRow] = [
        RuleRow(inserted: "这个方法有效", edited: "这个方法无效"),
        RuleRow(inserted: "这样做合法", edited: "这样做非法"),
        RuleRow(inserted: "他已婚", edited: "他未婚"),
        RuleRow(inserted: "这个方案可行", edited: "这个方案不行"),
        RuleRow(inserted: "用无线网络", edited: "用有线网络"),
        RuleRow(inserted: "今天有空", edited: "今天没空"),
        RuleRow(inserted: "这样不行的", edited: "这样步行的"),
    ]

    @Test(arguments: edits)
    func theSameEditInASentenceTeachesNothing(_ row: RuleRow) {
        let found = extraction(row)
        #expect(found.fixes.isEmpty && found.nothing == .notTerms, "\(fixes(found))")
    }

    @Test func aLearnedNegationIsNeverWrittenIntoText() {
        let book = confirmed(["有效|无效", "有关|无关"])
        for text in ["这个方法有效", "这个药没有效果", "有效期到明年", "和这件事有关"] {
            #expect(LearningPrompt.applyConfirmed(text, book: book) == text)
        }
    }
}

// MARK: - WL-3 the user changing what they said

@Suite struct RewordingRuleTests {
    /// One word or one name typed over another: an opposite, another currency, place, person or product, or
    /// simply another word. They sound close only because they share a character or most of their letters.
    static let pairs = [
        "升级|降级", "涨价|降价", "肯定|否定", "最好|最坏", "增产|减产", "退款|付款", "Enable|Disable",
        "美元|日元", "欧元|澳元", "HTML|HTMX", "广州|杭州", "小明|小红", "老张|老蒋", "小李|小林", "王伟|王磊",
        "Eric|Erin", "Jason|Martin", "Alice|Alex", "GitHub|GitLab", "CPU|GPU", "方法|办法", "性能|功能", "机票|车票",
        "这个月|上个月", "报告|报道", "金币|硬币", "金币|音币", "Cloud|Claude", "Versel|Vercel", "Tim Cook|Tom Brook",
    ]

    @Test(arguments: pairs)
    func anotherWordOrAnotherNameIsNotAFix(_ text: String) {
        #expect(CorrectionExtractor().strength(of: pair(text)) == nil)
    }

    static let edits: [RuleRow] = [
        RuleRow(inserted: "建议升级系统", edited: "建议降级系统"),
        RuleRow(inserted: "先安排增产再开会", edited: "先安排减产再开会"),
        RuleRow(inserted: "换成美元", edited: "换成日元"),
        RuleRow(inserted: "去广州出差", edited: "去杭州出差"),
        RuleRow(inserted: "问一下小明", edited: "问一下小红"),
        RuleRow(inserted: "找老张聊聊", edited: "找老蒋聊聊"),
        RuleRow(inserted: "和王伟开会", edited: "和王磊开会"),
        RuleRow(inserted: "换个方法试试", edited: "换个办法试试"),
        RuleRow(inserted: "写个报告", edited: "写个报道"),
        RuleRow(inserted: "看看金币是多少", edited: "看看硬币是多少"),
        RuleRow(inserted: "换成日元", edited: "换成美元", known: ["美元"]),
        RuleRow(inserted: "去苏州出差", edited: "去杭州出差", known: ["杭州"]),
        // A name in Latin letters was typed, so the user is told it was not learned and what to do about it.
        RuleRow(inserted: "发给 Eric 看", edited: "发给 Erin 看", nothing: .unlikeName),
        RuleRow(inserted: "推到 GitHub 上", edited: "推到 GitLab 上", nothing: .unlikeName),
        RuleRow(inserted: "占用 CPU 太高", edited: "占用 GPU 太高", nothing: .unlikeName),
        RuleRow(inserted: "发 HTML 给他", edited: "发 HTMX 给他", nothing: .unlikeName),
        RuleRow(inserted: "部署到 Versel 上", edited: "部署到 Vercel 上", nothing: .unlikeName),
        RuleRow(inserted: "和 Tim Cook 开会", edited: "和 Tom Brook 开会", nothing: .unlikeName),
        // One person's name typed over another's is another person, also when the new name is in the dictionary
        // (said differently then: there is nothing to add to it).
        RuleRow(inserted: "和 Jason 开会", edited: "和 Martin 开会", known: ["Martin"], nothing: .knownName),
        RuleRow(inserted: "和 Dustin 开会", edited: "和 Martin 开会", known: ["Martin"], nothing: .knownName),
        RuleRow(inserted: "发给 Alice 看", edited: "发给 Alex 看", known: ["Alex"], nothing: .knownName),
    ]

    @Test(arguments: edits)
    func theSameEditInASentenceTeachesNothing(_ row: RuleRow) {
        let found = extraction(row)
        #expect(found.fixes.isEmpty, "\(fixes(found))")
        #expect(found.nothing == (row.nothing ?? .notTerms))
    }

    /// What is still learned: the recognizer could not have known better (the same sound, the same word
    /// spelled out), or the corrected word is one of the user's own.
    static let fixed: [RuleRow] = [
        RuleRow(inserted: "和张伟开会", edited: "和章伟开会", expected: ["张伟 → 章伟"]),
        RuleRow(inserted: "这是他的权利", edited: "这是他的权力", expected: ["权利 → 权力"]),
        RuleRow(inserted: "看看引必是多少", edited: "看看音币是多少", expected: ["引必 → 音币"]),
        RuleRow(inserted: "我以经改了", edited: "我已经改了", expected: ["以经 → 已经"]),
        RuleRow(inserted: "设置按纽", edited: "设置按钮", expected: ["按纽 → 按钮"]),
        RuleRow(inserted: "看一下区线", edited: "看一下曲线", expected: ["区线 → 曲线"]),
        RuleRow(inserted: "问一下 Martn 吧", edited: "问一下 Martin 吧", expected: ["Martn → Martin"]),
        RuleRow(inserted: "看看金币是多少", edited: "看看音币是多少", expected: ["金币 → 音币"], known: ["音币"]),
        RuleRow(inserted: "部署到 Versel 上", edited: "部署到 Vercel 上", expected: ["Versel → Vercel"], known: ["Vercel"]),
        RuleRow(inserted: "我在用 Cloud Code 写代码", edited: "我在用 Claude Code 写代码", expected: ["Cloud Code → Claude Code"],
                known: ["Claude"]),
    ]

    @Test(arguments: fixed)
    func aRecognitionErrorIsStillLearned(_ row: RuleRow) {
        let found = extraction(row)
        #expect(fixes(found) == row.expected)
        // And the hub takes the pair as the Mac learned it.
        for fix in found.fixes { #expect(CorrectionExtractor().strength(of: fix.pair, knownTerms: row.known) == .pair) }
    }

    @Test func soundIsComparedSyllableBySyllable() {
        #expect(CorrectionExtractor.sameSound("张伟", "章伟") && CorrectionExtractor.sameSound("权利", "权力"))
        // What speakers and recognizers do not tell apart: z/zh, c/ch, s/sh, -n/-ng.
        #expect(CorrectionExtractor.sameSound("金东", "京东") && CorrectionExtractor.sameSound("字数", "指数"))
        // Syllables run together to the same sound, for words of two or more characters; one character alone
        // is never the same word as two.
        #expect(CorrectionExtractor.sameSound("西安门", "先门") && !CorrectionExtractor.sameSound("西安", "先"))
        #expect(!CorrectionExtractor.sameSound("金币", "音币") && !CorrectionExtractor.sameSound("小李", "小林")
               && !CorrectionExtractor.sameSound("广州", "杭州"))
        // Close, for a word of the user's own: every changed syllable, not the word as a whole.
        #expect(CorrectionExtractor.closeSound("金币", "音币"))
        #expect(!CorrectionExtractor.closeSound("日元", "美元") && !CorrectionExtractor.closeSound("苏州", "杭州"))
        #expect(CorrectionExtractor.isSpellingVariant("Martn", "Martin") && CorrectionExtractor.isSpellingVariant("Annna", "Anna")
               && CorrectionExtractor.isSpellingVariant("Jon", "John"))
        #expect(!CorrectionExtractor.isSpellingVariant("Eric", "Erin") && !CorrectionExtractor.isSpellingVariant("Cloud", "Claude"))
        // A person's name is told from a misspelling and from an everyday word.
        for name in ["Jason", "Dustin", "Alice", "Eric"] { #expect(CorrectionExtractor.isPersonName(name), "\(name)") }
        for word in ["Cloud", "Labels", "Martn", "Codecs", "cloud", "金币"] { #expect(!CorrectionExtractor.isPersonName(word), "\(word)") }
        let extractor = CorrectionExtractor()
        #expect(extractor.strength(of: pair("Jason|Martin"), knownTerms: ["Martin"]) == nil)
        #expect(extractor.strength(of: pair("Cloud|Claude"), knownTerms: ["Claude"]) == .pair)
        #expect(extractor.strength(of: pair("Sarah|Sara"), knownTerms: ["Sara"]) == .pair)
    }

    @Test func aRewriteTeachesNothingHoweverItsPartsLook() {
        let extractor = CorrectionExtractor()
        // The reviewer's two passages: every stretch is a meaning change.
        let first = extractor.extract(inserted: "这个方案有效，风险可控，建议升级，预计十一月上线",
                                      edited: "这个方案无效，风险不可控，建议降级，预计十月上线")
        #expect(first.fixes.isEmpty && first.nothing == .rewrite)
        let second = extractor.extract(inserted: "帮我订周五去广州的机票，顺便问一下小李酒店有没有订好",
                                       edited: "帮我订周日去杭州的车票，顺便问一下小林民宿有没有订好")
        #expect(second.fixes.isEmpty && second.nothing == .rewrite)
        // Three stretches reworded: the name fixed among them is not trusted either.
        let reworded = extractor.extract(inserted: "先问 Martn，然后买入，明天再看金币，最后发给我们",
                                         edited: "先问 Martin，然后卖出，今天再看金币，最后发给你们")
        #expect(reworded.fixes.isEmpty && reworded.nothing == .rewrite)
        // Much of the passage deleted counts as rewriting too.
        let cut = extractor.extract(inserted: "嗯那个就是说我想问一下 Martn 这个事情到底怎么办才好呢", edited: "问一下 Martin 怎么办")
        #expect(cut.fixes.isEmpty && cut.nothing == .rewrite)
        // One or two stretches rephrased, or a filler word deleted, take nothing away from a fix next to them.
        let kept = extractor.extract(inserted: "先问 Martn，然后买入，明天再看金币", edited: "先问 Martin，然后卖出，今天再看金币")
        #expect(fixes(kept) == ["Martn → Martin"])
    }

    @Test func aLearnedOppositeIsNeverWrittenIntoText() {
        let book = confirmed(["升级|降级", "增产|减产", "有效|无效"])
        let text = "系统这周五升级，先安排增产再开会，确认一下这个补丁有效"
        #expect(LearningPrompt.applyConfirmed(text, book: book) == text)
    }
}

// MARK: - WL-4 everyday words heard for a name

@Suite struct EverydayWordsForANameTests {
    /// Three one-character words in a row are not the syllables of a name.
    static let edits: [RuleRow] = [
        RuleRow(inserted: "用他不来做报表", edited: "用 Tableau 做报表", expected: ["[Tableau]"]),
        RuleRow(inserted: "他说你要死了", edited: "他说 Neos 了", expected: ["[Neos]"]),
        RuleRow(inserted: "把他给我发过来", edited: "把 Tagger 发过来", expected: ["[Tagger]"]),
        // Syllables nobody writes on purpose are still a mapping.
        RuleRow(inserted: "我用科德克斯写代码", edited: "我用 Codex 写代码", expected: ["科德克斯 → Codex"]),
        RuleRow(inserted: "调一下爱皮爱接口", edited: "调一下 API 接口", expected: ["爱皮爱 → API"]),
    ]

    @Test(arguments: edits)
    func onlyTheNameIsLearned(_ row: RuleRow) {
        #expect(fixes(extraction(row)) == row.expected)
    }

    @Test(arguments: ["他不来|Tableau", "你要死|Neos", "他给我|Tagger", "他没来|Tamela", "不太好|Butaho", "他都会|Tadohui"])
    func theHubNeverMakesItAMapping(_ text: String) {
        #expect(CorrectionExtractor().strength(of: pair(text)) != .pair)
    }

    @Test func everydayTextIsNeverRewrittenIntoTheName() {
        let found = CorrectionExtractor().extract(inserted: "用他不来做报表", edited: "用 Tableau 做报表")
        #expect(found.pairs.isEmpty && found.terms == ["Tableau"])
    }
}

// MARK: - WL-5 the dictionary lowers the bar only where it is safe

@Suite struct DictionaryRuleTests {
    @Test func anEverydayWordHeardForADictionaryNameIsOnlyAHint() {
        // Row 204: the pair is learned (the name is the user's own word), and the model gets it with the
        // sentence. It is never written into text without the model, however often it was fixed.
        let found = CorrectionExtractor().extract(inserted: "我在用 labels 输入", edited: "我在用 Lavoben 输入", knownTerms: ["Lavoben"])
        #expect(fixes(found) == ["labels → Lavoben"])
        let book = confirmed(["labels|Lavoben", "Cloud|Claude", "Jason|Martin", "useless|neoless", "review|Review", "cursor|Cursor"])
        for text in ["put the labels in the doc, Labels are fine", "upload to the cloud, cloud storage",
                     "和 Jason 还有 Martin 开会", "this is useless", "please review the bug", "move the cursor"] {
            #expect(LearningPrompt.applyConfirmed(text, book: book) == text)
        }
        #expect(LearningPrompt.pairs(for: "put the labels in the doc", from: book) == [pair("labels|Lavoben")])
        // Separate words joined, one word re-capitalized inside, or characters that make no word: cannot be
        // everyday text, still replaced.
        let safe = confirmed(["Open Air|OpenAI", "Iphone|iPhone", "Word press|WordPress", "引必|音币"])
        #expect(LearningPrompt.applyConfirmed("open air 的 iphone 和 word press 和引必", book: safe) == "OpenAI 的 iPhone 和 WordPress 和音币")
        // A word changed inside a phrase is a word changed (WL-3): "Apple Store" is said on purpose, and so
        // may "cloud code" be. A hint, like the single word.
        let phrases = confirmed(["Cloud Code|Claude Code", "Apple Store|App Store", "Open Air|Open AI"])
        let said = "upload the cloud code, 去 Apple Store 买，open air 音乐节"
        #expect(LearningPrompt.applyConfirmed(said, book: phrases) == said)
        #expect(LearningPrompt.pairs(for: said, from: phrases).count == 3)
    }

    /// A capital that is only how a sentence, a line or a list item starts says nothing, also for a word
    /// in the dictionary.
    static let capitals: [RuleRow] = [
        RuleRow(inserted: "- review the PR", edited: "- Review the PR", known: ["Review"], nothing: .formatOnly),
        RuleRow(inserted: "ok. review the PR", edited: "ok. Review the PR", known: ["Review"], nothing: .formatOnly),
        RuleRow(inserted: "claude 很好用", edited: "Claude 很好用", known: ["Claude"], nothing: .formatOnly),
        RuleRow(inserted: "标题\nclaude 很好用", edited: "标题\nClaude 很好用", known: ["Claude"], nothing: .formatOnly),
        RuleRow(inserted: "我用 claude 写", edited: "我用 Claude 写", expected: ["claude → Claude"], known: ["Claude"]),
        // Not sentence case: a real fix wherever it stands.
        RuleRow(inserted: "CLAUDE 很好用", edited: "Claude 很好用", expected: ["CLAUDE → Claude"], known: ["Claude"]),
    ]

    @Test(arguments: capitals)
    func aSentenceCapitalIsFormatting(_ row: RuleRow) {
        let found = extraction(row)
        #expect(fixes(found) == row.expected)
        #expect(found.nothing == row.nothing)
    }

    @Test func aLearnedWordDoesNotLowerTheBarForLaterEdits() {
        // "帮我 review 一下" → Review teaches the word. It is a learned word, not one of the user's own, so it
        // is not among `knownTerms`, and a later capital or a looser sound-alike towards it is judged as before.
        let extractor = CorrectionExtractor()
        #expect(fixes(extractor.extract(inserted: "帮我 review 一下", edited: "帮我 Review 一下")) == ["(Review)"])
        var book = LearningBook()
        let event = book.record([], terms: ["Review"], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(event.terms == ["Review"] && book.learnedOnlyTerms == ["review"])
        // What the app passes as `knownTerms`: the dictionary without `learnedOnlyTerms`.
        let dictionary = ["Review", "Claude"]
        let own = Set(dictionary.filter { !book.learnedOnlyTerms.contains($0.lowercased()) })
        #expect(own == ["Claude"])
        #expect(extractor.extract(inserted: "please review the bug", edited: "please Review the bug", knownTerms: own).nothing == .formatOnly)
        // Other words and names towards a dictionary word are refused when they change a place or a person
        // for another that does not sound the same.
        #expect(extractor.strength(of: pair("苏州|杭州"), knownTerms: ["杭州"]) == nil)
    }
}

// MARK: - WL-6, secret-gate-removed: a secret anywhere in the passage

@Suite struct SecretPassageTests {
    static func row(_ inserted: String, _ wrong: String, _ right: String) -> RuleRow {
        RuleRow(inserted: inserted, edited: inserted.replacingOccurrences(of: wrong, with: right), nothing: .sensitive)
    }

    /// The value follows its label across a full stop, a blank line, a list marker or a longer clause.
    static let passages: [RuleRow] = [
        row("WiFi 密码：\n\nSunhouse", "Sunhouse", "Sunhome"),
        row("WiFi 密码改了。新的是 Sunhouse 记一下", "Sunhouse", "Sunhome"),
        row("你问的那个密码？Sunhouse", "Sunhouse", "Sunhome"),
        row("Sunhouse 是新的 WiFi 的那个密码", "Sunhouse", "Sunhome"),
        row("助记词：\n1. apple\n2. Sunhouse\n3. river", "Sunhouse", "Sunhome"),
        row("我的 seed phrase 一共十二个词，第一个是 Sunhouse", "Sunhouse", "Sunhome"),
        row("下面是新的密码。Moonlite", "Moonlite", "Moonlight"),
        row("Wi-Fi 密码\n\nMoonlite", "Moonlite", "Moonlight"),
        row("密码我之前已经发给过你了你再仔细看一下就是那个 Moonlite", "Moonlite", "Moonlight"),
        row("Password:\n\nMoonlite", "Moonlite", "Moonlight"),
        row("密码如下。\n1. Moonlite", "Moonlite", "Moonlight"),
        // Fixes that would be learned anywhere else.
        row("WiFi 密码改了。新的是 Martn 记一下", "Martn", "Martin"),
        row("验证码。我用科德克斯写代码", "科德克斯", " Codex "),
        row("密码我已经改好了。另外 Open Air 的账单也看一下", "Open Air", "OpenAI"),
        row("You asked for the password! It is Martn", "Martn", "Martin"),
        // Labels the old list did not know, and something shaped like a key.
        row("pwd: Martn", "Martn", "Martin"),
        row("passwd 是 Martn", "Martn", "Martin"),
        row("API_KEY=Martn 记一下", "Martn", "Martin"),
        row("Bearer Martn 这个", "Martn", "Martin"),
        row("钥匙是 \(madeUpKey) 然后问 Martn", "Martn", "Martin"),
    ]

    @Test(arguments: passages)
    func nothingIsLearnedFromAPassageThatHoldsASecret(_ row: RuleRow) {
        let found = extraction(row)
        #expect(found.fixes.isEmpty && found.baseline == nil, "\(fixes(found))")
        #expect(found.nothing == .sensitive)
    }

    @Test func talkAboutTokensAndAddressesElsewhereStillTeaches() {
        let extractor = CorrectionExtractor()
        // `token` and `pwd` are everyday words in talk about code: only a label right before the change counts.
        for text in ["这个 token 用量太高了，问一下 Martn 吧", "运行一下 pwd 看看，然后问 Martn",
                     "发到 someone@example.com 了，再问一下 Martn"] {
            let found = extractor.extract(inserted: text, edited: text.replacingOccurrences(of: "Martn", with: "Martin"))
            #expect(fixes(found) == ["Martn → Martin"], "\(text)")
        }
        // An edit that only deletes or reformats is not said to be about a secret.
        #expect(extractor.extract(inserted: "密码改了。只删这个嗯", edited: "密码改了。只删这个").nothing == .removedOnly)
        #expect(extractor.extract(inserted: "密码改了，好的", edited: "密码改了。好的").nothing == .formatOnly)
        #expect(CorrectionExtractor.holdsSecret("新的密码") && CorrectionExtractor.holdsSecret("my Password is")
               && CorrectionExtractor.holdsSecret("a1b2c3d4e5f6a7b8c9d0e1f2") && !CorrectionExtractor.holdsSecret("这个 token 用量太高了")
               && !CorrectionExtractor.holdsSecret("handleUserAuthenticationCallback"))
        #expect(LearningText.missed(.sensitive) == "没记住：这段话像有密码或地址")
    }
}

// MARK: - WL-7, term-only-kept-after-retract, retract-leaves-term-only-words: words learned without a mapping

@Suite struct LearnedTermTests {
    /// Like the app: what the extractor found goes into the book, the events are kept for taking them back.
    static func learn(_ book: inout LearningBook, _ inserted: String, _ edited: String, own: Set<String> = [],
                      recordID: UUID = UUID()) -> LearningEvent {
        let found = CorrectionExtractor().extract(inserted: inserted, edited: edited, knownTerms: own)
        return book.record(found.pairs, terms: found.terms, source: .otherApp, recordID: recordID, now: day) { own.contains($0) }
    }

    static let edits: [RuleRow] = [
        RuleRow(inserted: "这个你好很好用", edited: "这个Nio很好用", expected: ["Nio"]),
        RuleRow(inserted: "这个你有很好用", edited: "这个 Nio 很好用", expected: ["Nio"]),
        RuleRow(inserted: "马上立刻去找他", edited: "马上 Nick 去找他", expected: ["Nick"]),
        RuleRow(inserted: "去谷歌搜一下", edited: "去 Google 搜一下", expected: ["Google"]),
    ]

    @Test(arguments: edits)
    func aWordLearnedAloneIsALearnedWordAndGoesWhenTheEditIsTakenBack(_ row: RuleRow) {
        var book = LearningBook()
        let event = Self.learn(&book, row.inserted, row.edited)
        // In the book as a learned word: tagged, never one of the user's own, and no mapping.
        #expect(event.terms == row.expected && event.learned.isEmpty && !event.isEmpty)
        #expect(book.items.isEmpty && book.terms.map(\.term) == row.expected)
        #expect(book.learnedOnlyTerms == Set(row.expected.map { $0.lowercased() }))
        #expect(book.teaches(row.expected[0]))
        // The user changes the text back (⌘Z): the tracker says retract, and undoing the session's events takes
        // the word out again. Nothing is left that still teaches it, so the dictionary lets go of it.
        var tracker = EditTracker(original: row.inserted)
        guard case .extract = tracker.settle(row.edited) else {
            Issue.record("the edit was not handed out")
            return
        }
        tracker.commit(row.edited, over: row.inserted, understood: nil)
        #expect(tracker.settle(row.inserted) == .retract)
        book.undo(event)
        #expect(book.terms.isEmpty && book.learnedOnlyTerms.isEmpty && !book.teaches(row.expected[0]))
    }

    @Test func aWordLearnedAloneComesLastAmongLearnedWords() {
        var book = LearningBook()
        _ = Self.learn(&book, "这个你好很好用", "这个Nio很好用")
        _ = book.record([pair("引必|音币"), pair("Open Air|OpenAI")], source: .otherApp, recordID: UUID(), now: day.addingTimeInterval(-600)) { _ in false }
        _ = book.record([pair("引必|音币")], source: .otherApp, recordID: UUID(), now: day.addingTimeInterval(-300)) { _ in false }
        // The words corrections teach first (most fixed first), the word from one edit without a mapping last.
        #expect(book.learnedRanking == ["音币", "OpenAI", "Nio"])
        let dictionary = ["Nio", "OpenAI", "音币", "Claude"]
        let prompt = Vocabulary.promptWords(dictionary, learned: book.learnedRanking)
        // Never among the user's own words (the prompt's 热词, which win over what was said).
        #expect(prompt.own == ["Claude"] && prompt.learned == ["音币", "OpenAI", "Nio"])
        #expect(Vocabulary.recognizerHints(dictionary, learned: book.learnedRanking) == ["Claude", "音币", "OpenAI", "Nio"])
    }

    @Test func theUsersOwnWordsAndTaughtWordsAreNotLearnedAgain() {
        var book = LearningBook()
        // Already the user's own word: nothing to learn.
        #expect(Self.learn(&book, "这个你好很好用", "这个Nio很好用", own: ["Nio"]).isEmpty)
        // Learned once. The same fix made again learns it again without a second entry (so a word the user had
        // taken out of the dictionary goes back in, as with a correction fixed again), and undoing the second
        // one leaves the first in place.
        #expect(Self.learn(&book, "这个你好很好用", "这个Nio很好用").terms == ["Nio"])
        let first = book
        let again = book.record([], terms: ["nio"], source: .inApp, recordID: UUID(), now: day.addingTimeInterval(60)) { _ in false }
        #expect(again.terms == ["Nio"] && again.addedTerms.isEmpty && !again.isEmpty && again.overLimit.isEmpty)
        #expect(book.terms.count == 1 && book.terms[0].lastSeen == day.addingTimeInterval(60))
        book.undo(again)
        #expect(book == first)
        // The user types the word by hand: theirs from now on, and no undo takes it out.
        book.markManualTerm("nio")
        #expect(book.terms.isEmpty && book.learnedOnlyTerms.isEmpty)
        // A correction that teaches a word: the word is not also learned alone.
        _ = book.record([pair("科德克斯|Codex")], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(book.record([], terms: ["Codex"], source: .otherApp, recordID: UUID(), now: day) { _ in false }.isEmpty)
    }

    @Test func wordsLearnedAloneCountTowardsTheDayAndAreCapped() {
        var book = LearningBook()
        let names = (0..<(LearningBook.maxNewPerDay + 2)).map { "Name\(String(UnicodeScalar(UInt8(65 + $0))))x" }
        let event = book.record([], terms: names, source: .otherApp, recordID: nil, now: day) { _ in false }
        #expect(event.terms.count == LearningBook.maxNewPerDay && event.overLimit == Array(names.suffix(2)))
        #expect(book.terms.count == LearningBook.maxNewPerDay)
    }

    @Test func aBookFromBeforeLearnedWordsStillReads() throws {
        let old = Data(#"{"version":1,"items":[]}"#.utf8)
        let book = try JSONDecoder().decode(LearningBook.self, from: old)
        #expect(book.items.isEmpty && book.terms.isEmpty)
        var next = book
        _ = next.record([pair("引必|音币")], terms: ["Nio"], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        let again = try JSONDecoder().decode(LearningBook.self, from: try JSONEncoder().encode(next))
        #expect(again == next && again.terms.map(\.term) == ["Nio"])
    }

    @Test func aWordSentAloneMustReadLikeAName() {
        for term in ["Nio", "Cursor", "Claude Code", "Tableau"] { #expect(CorrectionExtractor.isLearnableTerm(term), "\(term)") }
        for term in ["nio", "一百", "Twenty", "The", "password", "GPT4", "Tuesday", madeUpKey, "你好", "", "A"] {
            #expect(!CorrectionExtractor.isLearnableTerm(term), "\(term)")
        }
    }
}

// MARK: - WL-8 text still being typed never becomes the wrong side

@Suite struct HalfTypedTextTests {
    /// Settles `text` and, like the app, commits only the stretches that taught something.
    static func step(_ t: inout EditTracker, _ text: String, own: Set<String> = []) -> [String]? {
        guard case let .extract(inserted, edited) = t.settle(text) else { return nil }
        let found = CorrectionExtractor().extract(inserted: inserted, edited: edited, knownTerms: own)
        if !found.isEmpty { t.commit(edited, over: inserted, understood: found.baseline) }
        return fixes(found)
    }

    @Test(arguments: ["OpenAI 的yin币", "OpenAI 的yin bi", "OpenAI 的yinbi", "OpenAI 的yin'bi"])
    func pinyinInTheSameTextAsAFixDoesNotEnterTheBaseline(_ halfTyped: String) {
        var t = EditTracker(original: "Open Air 的金币")
        // One fix is done, and the next word is still being typed in pinyin when the text settles.
        #expect(Self.step(&t, halfTyped) == ["Open Air → OpenAI"])
        #expect(t.baseline == "OpenAI 的金币")
        // The word is chosen: it is compared with what was delivered, not with the pinyin.
        #expect(Self.step(&t, "OpenAI 的音币", own: ["音币"]) == ["金币 → 音币"])
        #expect(t.baseline == "OpenAI 的音币")
    }

    @Test func aWordDeletedWhileAnotherWasFixedIsStillAReplacementWhenRetyped() {
        var t = EditTracker(original: "Open Air 的 Martn 来了")
        #expect(Self.step(&t, "OpenAI 的  来了") == ["Open Air → OpenAI"])
        #expect(t.baseline == "OpenAI 的 Martn 来了")
        #expect(Self.step(&t, "OpenAI 的 Martin 来了") == ["Martn → Martin"])
        // The other order: deleted first (which settles as nothing), then the other word fixed.
        var u = EditTracker(original: "Open Air 的 Martn 来了")
        #expect(u.settle("Open Air 的  来了") == .none)
        #expect(Self.step(&u, "OpenAI 的  来了") == ["Open Air → OpenAI"])
        #expect(Self.step(&u, "OpenAI 的 Martin 来了") == ["Martn → Martin"])
    }

    @Test func undoAndRedoAroundAPartlyLearnedStateTeachNothing() {
        var t = EditTracker(original: "Open Air 的金币")
        #expect(Self.step(&t, "OpenAI 的yin币") == ["Open Air → OpenAI"])
        // The same text again, or reached again by redo: nothing to compare, and the baseline stays what was understood.
        #expect(t.settle("OpenAI 的yin币") == .none)
        #expect(t.baseline == "OpenAI 的金币")
        // Back to the delivered text: everything this session learned is taken back.
        #expect(t.settle("Open Air 的金币") == .retract)
        #expect(t.baseline == "Open Air 的金币")
    }

    @Test(arguments: ["yin币|硬币", "yin bi|硬币", "yinbi|硬币", "yin'bi|硬币", "sofa|沙发"])
    func leftoverPinyinIsNeverTheWrongSideOfAPair(_ text: String) {
        #expect(CorrectionExtractor().strength(of: pair(text)) == nil)
        // Not towards a dictionary word either: the wrong side was never delivered.
        #expect(CorrectionExtractor().strength(of: pair(text), knownTerms: [pair(text).right]) == nil)
    }

    @Test func aFixMadeOverLeftoverPinyinTeachesNothing() {
        let found = CorrectionExtractor().extract(inserted: "OpenAI 的yin币", edited: "OpenAI 的硬币")
        #expect(found.fixes.isEmpty && found.nothing == .notTerms)
    }
}

// MARK: - WL-10 a correction counts once for each dictation, also after a restart

@Suite struct CountOncePerRecordTests {
    @Test(arguments: [1, 2, 5])
    func anObservationSentAgainForTheSameRecordIsNotCountedAgain(_ resends: Int) throws {
        // The device sends its own record's id with every observation (the Neo's id of the dictation, or for a
        // dictation the Mac did itself the record's id), and the book keeps the ids with the pair: a resend
        // after a lost answer cannot count twice, also when the book was written out and read back in between
        // (the Neo restarted).
        let record = UUID()
        var book = LearningBook()
        _ = book.record([pair("Open Air|OpenAI")], source: .otherApp, recordID: record, now: day) { _ in false }
        for n in 0..<resends {
            book = try JSONDecoder().decode(LearningBook.self, from: try JSONEncoder().encode(book))
            _ = book.record([pair("Open Air|OpenAI")], source: .otherApp, recordID: record, now: day.addingTimeInterval(Double(n))) { _ in false }
        }
        #expect(book.items.map(\.count) == [1])
        #expect(LearningPrompt.applyConfirmed("open air 的账单", book: book) == "open air 的账单")
        // Another dictation is another fix.
        _ = book.record([pair("Open Air|OpenAI")], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(book.items.map(\.count) == [2])
    }
}

// MARK: - reverse-of-neo-only-pair-learned-as-mapping

@Suite struct ReverseOfAPairHeldElsewhereTests {
    @Test(arguments: ["音币|硬币", "Claude|Cloud", "iPhone|Iphone"])
    func theReverseOfANeoOnlyPairIsNeverLearnedAsAMappingHere(_ held: String) {
        // The Neo has `held` and this Mac's book does not. The user fixes text the other way round.
        let stored = pair(held)
        let fix = CorrectionPair(wrong: stored.right, right: stored.wrong)
        var book = LearningBook()
        let event = book.record([fix], source: .otherApp, recordID: UUID(), now: day, heldElsewhere: [stored]) { _ in false }
        // Nothing is learned here, so nothing says "已记住"; the pair is reported as changed back, to be weakened
        // on the Neo, as when this Mac's own book has it.
        #expect(book.items.isEmpty && event.learned.isEmpty && event.added.isEmpty)
        #expect(event.reversed == [stored] && !event.isEmpty)
        // Taking the edit back changes nothing in the book (the device counts the pair up again on the Neo).
        book.undo(event)
        #expect(book.items.isEmpty)
        // A pair the Neo does not have is learned as before, and this Mac's own pair is counted down as before.
        let other = book.record([pair("引必|音币")], source: .otherApp, recordID: UUID(), now: day, heldElsewhere: [stored]) { _ in false }
        #expect(other.learned == [pair("引必|音币")] && other.reversed.isEmpty)
        let own = book.record([pair("音币|引必")], source: .otherApp, recordID: UUID(), now: day, heldElsewhere: [stored]) { _ in false }
        #expect(own.reversed == [pair("引必|音币")] && book.items.isEmpty)
    }
}

// MARK: - learning-log-false-entries

@Suite struct LearningLogTruthTests {
    @Test func theDaysLimitIsSaidOnlyWhenItWasReached() {
        var book = LearningBook()
        let record = UUID()
        let first = book.record([pair("Open Air|OpenAI")], source: .otherApp, recordID: record, now: day) { _ in false }
        // The user changes it back in the same dictation: the two cancel (`chained` gives nothing to learn).
        // That is not the day's limit, and nothing says so.
        #expect(LearningBook.chained([pair("OpenAI|Open Air")], after: first.learned) == [])
        #expect(first.overLimit.isEmpty)
        // A pair changed back in another dictation is not the limit either.
        let back = book.record([pair("OpenAI|Open Air")], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(back.overLimit.isEmpty && back.reversed == [pair("Open Air|OpenAI")])
        // The limit itself: said for what it left out, and only then.
        for i in 0..<LearningBook.maxNewPerDay {
            let event = book.record([pair("wrong\(i)|Right\(i)")], source: .otherApp, recordID: UUID(), now: day) { _ in false }
            #expect(event.overLimit.isEmpty)
        }
        let over = book.record([pair("Martn|Martin")], terms: ["Nio"], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(over.overLimit == ["Martin", "Nio"] && over.learned.isEmpty && over.isEmpty)
        // A pair already in the book still counts on such a day.
        #expect(book.record([pair("wrong0|Right0")], source: .otherApp, recordID: UUID(), now: day) { _ in false }.overLimit.isEmpty)
    }

    /// `learned` words in an entry, `takenBack` of them undone: what the entry says afterwards.
    struct TakenBack: Sendable, CustomTestStringConvertible {
        var learned: Int
        var takenBack: Int
        var code: String
        var left: Int

        var testDescription: String { "\(takenBack) of \(learned)" }
    }

    @Test(arguments: [TakenBack(learned: 2, takenBack: 2, code: "undone", left: 0),
                      TakenBack(learned: 2, takenBack: 1, code: "learned", left: 1),
                      TakenBack(learned: 1, takenBack: 3, code: "undone", left: 0)])
    func aLearnedEntryNoLongerClaimsWordsThatWereTakenBack(_ row: TakenBack) {
        var log = LearningLog()
        log.add(.removedOnly, app: "Notes", at: day)
        let entry = log.add(.learned, app: "Claude", count: row.learned, at: day.addingTimeInterval(10))
        log.add(.notTerms, app: "Claude", at: day.addingTimeInterval(20))
        log.takeBack(row.takenBack, from: entry)
        #expect(log.entries[1].code == row.code && log.entries[1].count == row.left)
        // Only that entry, and only an entry about learning.
        #expect(log.entries[0].code == "notTerms" && log.entries[2].code == "removedOnly")
        log.takeBack(1, from: log.entries[0].id)
        log.takeBack(1, from: UUID())
        #expect(log.entries.map(\.code) == ["notTerms", row.code, "removedOnly"])
    }

    @Test func theLogSaysSoInPlainWords() {
        #expect(LearningText.line(code: "undone", count: 0) == "记住的词已撤销")
        // A fix whose word the dictionary already has taught nothing new: said, so it is not a silence.
        #expect(LearningText.line(code: LearningLog.Code.inDictionary.rawValue, count: 0) == "这个词词典里已经有了")
        #expect(LearningText.line(code: LearningLog.Code.notTerms.rawValue, count: 0) == "换了词，不确定是听错的，没记")
        #expect(LearningText.line(code: "learned", count: 1) == "记住了 1 个词")
        // The same thing twice in a row joins the entry before it, and says which entry that is.
        var log = LearningLog()
        let first = log.add(.removedOnly, app: "Notes", at: day)
        #expect(log.add(.removedOnly, app: "Notes", at: day.addingTimeInterval(5)) == first)
        #expect(log.add(.learned, app: "Notes", count: 1, at: day.addingTimeInterval(6)) != first)
    }
}

// MARK: - hub-termonly-for-mac-pair-unflagged: this Mac and the hub judge alike

@Suite struct SameVerdictOnBothSidesTests {
    /// What the Mac learns from an edit is what the hub makes of it when it arrives without its sentence: a
    /// mapping is a mapping there (`strength(of:)`), a word learned alone is a word it takes (`isLearnableTerm`).
    @Test(arguments: fixRows)
    func theHubTakesWhatTheMacLearnedAsTheMacLearnedIt(_ row: FixRow) {
        let extractor = CorrectionExtractor()
        for fix in extractor.extract(inserted: row.inserted, edited: row.edited, knownTerms: row.known).fixes {
            if fix.termOnly {
                #expect(CorrectionExtractor.isLearnableTerm(fix.pair.right), "#\(row.n) \(fix.pair)")
            } else {
                #expect(extractor.strength(of: fix.pair, knownTerms: row.known) == .pair, "#\(row.n) \(fix.pair)")
            }
        }
    }

    @Test func aMappingLearnedInASentenceIsAMappingOnTheHub() {
        // 斯|威|夫|特 inside the sentence, 斯威夫特 when the segmenter sees it alone: before, a mapping on the Mac
        // and only a word on the hub, with nothing saying so. The hub cannot see the sentence, so for three or
        // more characters it takes them as the device did.
        let extractor = CorrectionExtractor()
        let found = extractor.extract(inserted: "斯威夫特很好用", edited: "Swift 很好用")
        #expect(fixes(found) == ["斯威夫特 → Swift"])
        #expect(extractor.strength(of: pair("斯威夫特|Swift")) == .pair)
        #expect(fixes(extractor.extract(inserted: "我用科德克斯写代码", edited: "我用 Codex 写代码")) == ["科德克斯 → Codex"])
        #expect(extractor.strength(of: pair("科德克斯|Codex")) == .pair)
        // Everyday words stay words on both sides: two characters by either reading, a run with a pronoun or a
        // negation in it whatever its length.
        for text in ["你好|Nio", "你有|Nio", "马力|Mary", "立刻|Nick", "他不来|Tableau", "你要死|Neos"] {
            #expect(extractor.strength(of: pair(text)) == .termOnly, "\(text)")
        }
    }
}
