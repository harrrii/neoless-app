import Foundation
import Testing
@testable import NeolessCore

// The second review of the learning fix (2026-10-10): what was still open
// after the first repair, one suite for each finding. The rule is the same: better to learn nothing than
// something false. All text here is made up.

private func extraction(_ row: RuleRow) -> Extraction {
    CorrectionExtractor().extract(inserted: row.inserted, edited: row.edited, knownTerms: row.known)
}

private func pair(_ s: String) -> CorrectionPair {
    let parts = s.components(separatedBy: "|")
    return CorrectionPair(wrong: parts[0], right: parts[1])
}

private let day = Date(timeIntervalSince1970: 1_790_000_000)

/// A book of corrections fixed often, as an older version or another device may have stored them.
private func stored(_ pairs: [String], source: LearnedCorrection.Source = .otherApp) -> LearningBook {
    LearningBook(items: pairs.map {
        LearnedCorrection(pair: pair($0), count: 5, firstSeen: day, lastSeen: day, source: source, addedTerm: false)
    })
}

// MARK: - WL-3: the dictionary lets a fix through only where the typed-over word was not itself meant

@Suite struct DictionaryRouteTests {
    /// The corrected word is in the dictionary, and still it is another word, another thing or another person.
    static let edits: [RuleRow] = [
        // The typed-over word is one of the user's own words too: they have it, and said the other.
        RuleRow(inserted: "我在用 Typeless 输入", edited: "我在用 neoless 输入", known: ["Typeless", "neoless"]),
        RuleRow(inserted: "我在用 neoless 输入", edited: "我在用 Typeless 输入", known: ["Typeless", "neoless"], nothing: .knownName),
        RuleRow(inserted: "发 HTML 给他", edited: "发 HTMX 给他", known: ["HTML", "HTMX"], nothing: .knownName),
        RuleRow(inserted: "和王伟开会", edited: "和王磊开会", known: ["王伟", "王磊"]),
        RuleRow(inserted: "换成音币", edited: "换成硬币", known: ["音币"]),
        RuleRow(inserted: "和 Sara 说", edited: "和 Sarah 说", known: ["Sara"], nothing: .unlikeName),
        // Written on purpose, in capitals or with a capital inside: another thing, whichever is in the dictionary.
        RuleRow(inserted: "发 HTML 给他", edited: "发 HTMX 给他", known: ["HTMX"], nothing: .knownName),
        RuleRow(inserted: "占用 CPU 太高", edited: "占用 GPU 太高", known: ["GPU"], nothing: .knownName),
        RuleRow(inserted: "用 SSL 连", edited: "用 SSH 连", known: ["SSH"], nothing: .knownName),
        RuleRow(inserted: "推到 GitHub 上", edited: "推到 GitLab 上", known: ["GitLab"], nothing: .knownName),
        // A given name with letters added is another person, with no dictionary to say otherwise.
        RuleRow(inserted: "和 Chris 说", edited: "和 Christine 说", nothing: .unlikeName),
        RuleRow(inserted: "和 Eric 说", edited: "和 Erica 说", nothing: .unlikeName),
        RuleRow(inserted: "和 Paul 说", edited: "和 Paula 说", nothing: .unlikeName),
        RuleRow(inserted: "和 Julia 说", edited: "和 Julian 说", nothing: .unlikeName),
        RuleRow(inserted: "和 Ian 说", edited: "和 Ivan 说", nothing: .unlikeName),
        RuleRow(inserted: "和 Alex 说", edited: "和 Alexis 说", nothing: .unlikeName),
        RuleRow(inserted: "和 Jon 开会", edited: "和 John 开会", nothing: .unlikeName),
        // Two letters dropped from a short word make another word, not a spelling.
        RuleRow(inserted: "去 Apple Store 买", edited: "去 App Store 买", nothing: .unlikeName),
        RuleRow(inserted: "和 Tim Cook 开会", edited: "和 Tom Brook 开会", known: ["Tom Brook"], nothing: .knownName),
    ]

    @Test(arguments: edits)
    func anotherWordIsNotAFixWhateverTheDictionaryHas(_ row: RuleRow) {
        let found = extraction(row)
        #expect(found.fixes.isEmpty, "\(fixes(found))")
        #expect(found.nothing == (row.nothing ?? .notTerms))
    }

    @Test(arguments: ["Typeless|neoless", "Sara|Sarah", "HTML|HTMX", "CPU|GPU", "SSL|SSH", "GitHub|GitLab", "王伟|王磊",
                      "音币|硬币", "Chris|Christine", "Eric|Erica", "Paul|Paula", "Julia|Julian", "Ian|Ivan", "Alex|Alexis"])
    func theHubRefusesThemWithBothWordsInItsDictionary(_ text: String) {
        let sides = pair(text)
        #expect(CorrectionExtractor().strength(of: sides, knownTerms: [sides.wrong, sides.right]) == nil)
    }

    @Test func whatTheDictionaryStillLetsThrough() {
        let extractor = CorrectionExtractor()
        // An everyday word, a misspelling, the same name spelled as the dictionary has it, a word inside a
        // longer term of the dictionary.
        for (text, known) in [("Cloud|Claude", "Claude"), ("Versel|Vercel", "Vercel"), ("Sarah|Sara", "Sara"),
                              ("Jon|John", "John"), ("BS Code|VS Code", "VS Code"), ("金币|音币", "音币")] {
            #expect(extractor.strength(of: pair(text), knownTerms: [known]) == .pair, "\(text)")
            // As a hint for the model only: never written into text without it.
            #expect(!CorrectionExtractor.replacesBlindly(pair(text)), "\(text)")
        }
        #expect(CorrectionExtractor.isSpellingVariant("Martn", "Martin") && CorrectionExtractor.isSpellingVariant("Kubernets", "Kubernetes"))
        #expect(!CorrectionExtractor.isSpellingVariant("Apple", "App") && !CorrectionExtractor.isSpellingVariant("Chris", "Christine"))
    }

    @Test func aPairLearnedOnlyBecauseItSoundsCloseIsNeverWrittenIntoText() {
        // 银杯 → 音币 and 王伟 → 王磊 are learned towards a dictionary word, as 金币 → 音币 is: they are as
        // often what the user meant, so the model gets them with the sentence, and nothing else does.
        let book = stored(["银杯|音币", "王伟|王磊", "金币|音币", "Apple Store|App Store"])
        for text in ["他拿了银杯，我也拿了银杯", "和王伟还有王磊开会", "金币也算上", "去 Apple Store 买手机"] {
            #expect(LearningPrompt.applyConfirmed(text, book: book) == text)
            #expect(!LearningPrompt.pairs(for: text, from: book).isEmpty, "\(text)")
        }
    }
}

// MARK: - single-han-char-wrong-side

@Suite struct OneCharacterTests {
    static let edits: [RuleRow] = [
        RuleRow(inserted: "我明天去先", edited: "我明天去西安"),
        RuleRow(inserted: "到了先给我打电话", edited: "到了西安给我打电话"),
        RuleRow(inserted: "这个天不错", edited: "这个提案不错"),
    ]

    @Test(arguments: edits)
    func oneCharacterIsNeverTheMisheardSide(_ row: RuleRow) {
        let found = extraction(row)
        #expect(found.fixes.isEmpty && found.nothing == .notTerms, "\(fixes(found))")
    }

    @Test(arguments: ["先|西安", "天|提案", "将|激昂", "票|皮袄", "张|张伟"])
    func notAsABarePairNorFromAnOlderVersion(_ text: String) {
        let sides = pair(text)
        #expect(CorrectionExtractor().strength(of: sides) == nil)
        #expect(CorrectionExtractor().strength(of: sides, knownTerms: [sides.right]) == nil)
        #expect(!CorrectionExtractor.replacesBlindly(sides))
        // Stored all the same (an older version learned it): the character is part of countless words.
        let book = stored([text])
        for said in ["我先去吃饭，先生你好，优先", "今天天气不错", "将来的门票", "张伟和张来了"] {
            #expect(LearningPrompt.applyConfirmed(said, book: book) == said)
            #expect(LearningPrompt.pairs(for: said, from: book.without(book.unusable(knownTerms: []))).isEmpty)
        }
    }
}

// MARK: - stored-pairs-not-rejudged

@Suite struct StoredCorrectionTests {
    /// What the version before this one learned (WL-1 to WL-4, and the cases found since).
    static let old = [
        "周五|周日", "广州|杭州", "机票|车票", "美元|日元", "虚线|实线", "春天|秋天", "他给我|Tagger", "你要死|Neos",
        "小明|小红", "老张|老蒋", "方法|办法", "有效|无效", "升级|降级", "他不来|Tableau", "先|西安", "天|提案",
        "Eric|Erica", "GitHub|GitLab", "十一月|十月", "吃个饭|Chigofan",
    ]
    static let said = [
        "帮我订周五去广州的机票", "换成美元，这里画虚线，现在是春天", "把他给我发过来，他说你要死了", "问一下小明和老张，换个方法",
        "这个方法有效，建议升级，今天他不来", "我先去吃饭，今天天气不错", "和 Eric 把代码推到 GitHub，十一月上线",
    ]

    @Test func whatTodaysRulesWouldNotLearnIsUsedForNothing() {
        let book = stored(Self.old)
        let off = book.unusable(knownTerms: Set(Vocabulary.defaults))
        #expect(off == Set(Self.old.map { LearningBook.key(pair($0)) }))
        let used = book.without(off)
        #expect(used.items.isEmpty)
        // Kept in the book, so the user sees them (marked) and can delete them.
        #expect(book.items.count == Self.old.count)
        for text in Self.said {
            #expect(LearningPrompt.applyConfirmed(text, book: used) == text)
            #expect(LearningPrompt.pairs(for: text, from: used).isEmpty, "\(text)")
        }
    }

    @Test func whatTheyWouldLearnStaysInUse() {
        let good = ["引必|音币", "Open Air|OpenAI", "科德克斯|Codex", "张伟|章伟", "Martn|Martin", "Iphone|iPhone", "金币|音币",
                    "Cloud|Claude"]
        let book = stored(good + Self.old)
        var verdicts: [String: Bool] = [:]
        // 音币 is one of the user's own words here.
        let known = Set(Vocabulary.defaults + ["音币"])
        let off = book.unusable(knownTerms: known, verdicts: &verdicts)
        #expect(book.without(off).items.map(\.pair) == good.map(pair))
        // Asked again with the answers kept: the same.
        #expect(book.unusable(knownTerms: known, verdicts: &verdicts) == off)
        #expect(verdicts.count == book.items.count)
        // A correction learned towards a dictionary word is judged without it once the word is gone.
        let without = book.unusable(knownTerms: [])
        #expect(without.contains(LearningBook.key(pair("金币|音币"))) && without.contains(LearningBook.key(pair("Cloud|Claude"))))
        #expect(!without.contains(LearningBook.key(pair("引必|音币"))))
        // What the user imported is theirs: not judged (and never written into text where that is unsafe).
        let imported = stored(Self.old, source: .imported)
        #expect(imported.unusable(knownTerms: []).isEmpty)
        #expect(LearningPrompt.applyConfirmed("帮我订周五去广州的机票，今天他不来", book: imported) == "帮我订周五去广州的机票，今天他不来")
        #expect(book.without([]) == book)
    }
}

// MARK: - miscut-pair-real-word

@Suite struct MiscutTests {
    static let edits: [RuleRow] = [
        // 换|成瘾|币: the misheard character had joined its neighbour into another word. That word says nothing
        // about what was meant.
        RuleRow(inserted: "把钱换成瘾币再说", edited: "把钱换成音币再说", expected: ["瘾币 → 音币"]),
        RuleRow(inserted: "把钱换成瘾币再说", edited: "把钱换成音币再说", expected: ["瘾币 → 音币"], known: ["音币"]),
        // 代码|厂里: never 厂里 → 仓里, which would rewrite "他在厂里上班".
        RuleRow(inserted: "他在代码厂里提交", edited: "他在代码仓里提交", expected: ["代码厂 → 代码仓"]),
        RuleRow(inserted: "他在厂里上班", edited: "他在仓里上班", nothing: .notTerms),
        // The word of the misheard text is still taken when the corrected side is a word too (the user's own).
        RuleRow(inserted: "看看金币多不多", edited: "看看音币多不多", expected: ["金币 → 音币"], known: ["音币"]),
        RuleRow(inserted: "看看金币多不多", edited: "看看音币多不多", nothing: .notTerms),
    ]

    @Test(arguments: edits)
    func theMisheardCharacterIsPlacedInTheWordThatWasMeant(_ row: RuleRow) {
        let found = extraction(row)
        #expect(fixes(found) == row.expected)
        #expect(found.nothing == row.nothing)
        for fix in found.fixes { #expect(CorrectionExtractor().strength(of: fix.pair, knownTerms: row.known) == .pair) }
    }

    @Test func aWordWithAnEverydayWordInItIsNeverWrittenWithoutTheModel() {
        let book = stored(["厂里|仓里", "成瘾|成音", "代码厂|代码仓"])
        for text in ["他在厂里上班", "上网成瘾了", "去代码厂参观"] { #expect(LearningPrompt.applyConfirmed(text, book: book) == text) }
        // The pair as it is learned now holds no word on its misheard side: written.
        #expect(LearningPrompt.applyConfirmed("换成瘾币", book: stored(["瘾币|音币"])) == "换成音币")
    }
}

// MARK: - legit-fix-lost-not-same-sound: the decision

@Suite struct OnlySoundAlikesTests {
    /// 米线 → 曲线 does not sound alike (mi / jun), and by sound it cannot be told from 苏州 → 杭州 or 日元 →
    /// 美元 (美元 is a dictionary word from the start). Taking it towards a dictionary word would take those
    /// too, as hints. Decided: nothing is learned; the user's own word 曲线 still goes to the recognizer and
    /// the model as a hot word.
    static let edits: [RuleRow] = [
        RuleRow(inserted: "看一下米线", edited: "看一下曲线"),
        RuleRow(inserted: "看一下米线", edited: "看一下曲线", known: ["曲线"]),
        RuleRow(inserted: "去苏州出差", edited: "去杭州出差", known: ["杭州"]),
        RuleRow(inserted: "换成日元", edited: "换成美元", known: ["美元"]),
    ]

    @Test(arguments: edits)
    func anotherWordThatDoesNotSoundAlikeIsNotLearnedTowardsTheDictionaryEither(_ row: RuleRow) {
        let found = extraction(row)
        #expect(found.fixes.isEmpty && found.nothing == .notTerms, "\(fixes(found))")
    }

    @Test func whatSoundsTheSameIsStillLearned() {
        for text in ["区线|曲线", "张伟|章伟", "权利|权力", "以经|已经", "按纽|按钮", "保错|报错", "日只|日志", "回掉|回调",
                     "接扣|接口", "人工只能|人工智能"] {
            #expect(CorrectionExtractor().strength(of: pair(text)) == .pair, "\(text)")
        }
    }
}

// MARK: - name-misses-count-as-rewrite

@Suite struct MissedNameTests {
    static let passage = "用 Curser 和 Jemini 部署到 Versel，再问张伟"
    static let fixed = "用 Cursor 和 Gemini 部署到 Vercel，再问章伟"

    @Test func namesThatCouldNotBeLearnedTakeNothingAwayFromAFixNextToThem() {
        let found = CorrectionExtractor().extract(inserted: Self.passage, edited: Self.fixed)
        #expect(fixes(found) == ["张伟 → 章伟"] && found.nothing == nil)
        // And the user is told the names were not learned, so they can add them.
        #expect(found.missedName == .unlikeName)
        // Only what was learned moves into the baseline: the names are compared again when they change again.
        #expect(found.baseline == "用 Curser 和 Jemini 部署到 Versel，再问章伟")
        // With the names in the dictionary everything is learned, and nothing was missed.
        let all = CorrectionExtractor().extract(inserted: Self.passage, edited: Self.fixed, knownTerms: ["Cursor", "Gemini", "Vercel"])
        #expect(fixes(all) == ["Curser → Cursor", "Jemini → Gemini", "Versel → Vercel", "张伟 → 章伟"] && all.missedName == nil)
        // Names alone: nothing learned, said as before.
        let names = CorrectionExtractor().extract(inserted: "用 Curser 和 Jemini 写", edited: "用 Cursor 和 Gemini 写")
        #expect(names.fixes.isEmpty && names.nothing == .unlikeName && names.missedName == nil)
    }

    @Test func theWatchGoesOnLearningAfterThem() {
        var t = EditTracker(original: Self.passage)
        #expect(HalfTypedTextTests.step(&t, Self.fixed) == ["张伟 → 章伟"])
        // A later fix in the same passage is compared, not called a rewrite.
        let later = Self.fixed + "和 Martn"
        var u = EditTracker(original: Self.passage + "和 Martn")
        #expect(HalfTypedTextTests.step(&u, later) == ["张伟 → 章伟"])
        #expect(HalfTypedTextTests.step(&u, Self.fixed + "和 Martin") == ["Martn → Martin"])
    }

    @Test func aNameAlreadyInTheDictionaryIsSaidDifferently() {
        // "可手动加进词典" would be wrong: the name is there. The change just does not read as misheard.
        let found = CorrectionExtractor().extract(inserted: "和 Jason 开会", edited: "和 Martin 开会", knownTerms: ["Martin"])
        #expect(found.nothing == .knownName)
        #expect(LearningText.missed(.knownName) == "没记住：不像是听错的")
        #expect(LearningText.line(code: LearningLog.Code(.knownName).rawValue, count: 0) == "换成了词典里的词，不像是听错的，没记")
        #expect(CapsuleText.kind(done: LearningText.missed(.knownName) ?? "") == .note)
        // One name of two is not in the dictionary: that one can be added, so that is what is said.
        let mixed = CorrectionExtractor().extract(inserted: "和 Jason 还有 Curser 开会", edited: "和 Martin 还有 Cursor 开会",
                                                  knownTerms: ["Martin"])
        #expect(mixed.fixes.isEmpty && mixed.nothing == .unlikeName)
    }

    @Test func aNameTypedOverALongerStretchIsStillRewording() {
        // Deleted text next to the name joins it into one changed stretch: with the rest cut too, a rewrite.
        let cut = CorrectionExtractor().extract(inserted: "嗯那个就是说我想问一下 Martn 这个事情到底怎么办才好呢", edited: "问一下 Martin 怎么办")
        #expect(cut.fixes.isEmpty && cut.nothing == .rewrite)
    }
}

// MARK: - legit-fix-never-learned-preexisting, multiword-dictionary-term

@Suite struct NamedFixTests {
    static let edits: [RuleRow] = [
        // The segmenter joins 劳德: still the syllables of a name, none of them a word of its own.
        RuleRow(inserted: "用克劳德写代码", edited: "用 Claude 写代码", expected: ["克劳德 → Claude"]),
        RuleRow(inserted: "用克劳德写代码", edited: "用 Claude 写代码", expected: ["克劳德 → Claude"], known: ["Claude"]),
        RuleRow(inserted: "卡帕西说的", edited: "Karpathy 说的", expected: ["卡帕西 → Karpathy"]),
        // A whole word the segmenter knows is everyday text (特斯拉 is how the car is written), and so is a
        // run with a one-character word in it (怕): the name only.
        RuleRow(inserted: "用特斯拉的", edited: "用 Tesla 的", expected: ["[Tesla]"]),
        RuleRow(inserted: "用速怕贝斯存", edited: "用 Supabase 存", expected: ["[Supabase]"]),
        // One changed character after a word: the compound is the fix.
        RuleRow(inserted: "推到代码厂", edited: "推到代码仓", expected: ["代码厂 → 代码仓"]),
        RuleRow(inserted: "推到代码厂", edited: "推到代码仓", expected: ["代码厂 → 代码仓"], known: ["代码仓"]),
        // Not when either character is a word of its own: 方案好 is everyday text. With the compound in the
        // dictionary it is learned.
        RuleRow(inserted: "这个方案好", edited: "这个方案号", nothing: .notTerms),
        RuleRow(inserted: "这个提示次不错", edited: "这个提示词不错", nothing: .notTerms),
        RuleRow(inserted: "这个提示次不错", edited: "这个提示词不错", expected: ["提示次 → 提示词"], known: ["提示词"]),
        RuleRow(inserted: "等它回棍一下", edited: "等它回滚一下", expected: ["回棍 → 回滚"], known: ["回滚"]),
        RuleRow(inserted: "等它回棍一下", edited: "等它回滚一下", nothing: .notTerms),
        // The dictionary has the name only as part of a longer term.
        RuleRow(inserted: "用 Cloud Code 写", edited: "用 Claude Code 写", expected: ["Cloud Code → Claude Code"], known: ["Claude Code"]),
        RuleRow(inserted: "用 BS Code 写", edited: "用 VS Code 写", expected: ["BS Code → VS Code"], known: ["VS Code"]),
        RuleRow(inserted: "坐 Air Frence 去", edited: "坐 Air France 去", expected: ["Air Frence → Air France"], known: ["Air France"]),
        RuleRow(inserted: "去 Apple Store 买", edited: "去 App Store 买", expected: ["Apple Store → App Store"], known: ["App Store"]),
    ]

    @Test(arguments: edits)
    func theFixIsLearnedAsTheUserMadeIt(_ row: RuleRow) {
        let found = extraction(row)
        #expect(fixes(found) == row.expected)
        #expect(found.nothing == row.nothing)
        // The hub takes each as this Mac learned it.
        for fix in found.fixes where !fix.termOnly {
            #expect(CorrectionExtractor().strength(of: fix.pair, knownTerms: row.known) == .pair, "\(fix.pair)")
        }
    }

    @Test func noneOfTheseIsWrittenWithoutTheModel() {
        // Each has a word someone may say on purpose on its misheard side.
        for text in ["克劳德|Claude", "卡帕西|Karpathy", "代码厂|代码仓", "提示次|提示词", "Cloud Code|Claude Code", "BS Code|VS Code",
                     "Air Frence|Air France", "Apple Store|App Store"] {
            #expect(!CorrectionExtractor.replacesBlindly(pair(text)), "\(text)")
        }
    }
}

// MARK: - real-word-homophone-written-blindly

@Suite struct RealWordTests {
    @Test(arguments: ["即使|及时", "联系|练习", "时间|事件", "借口|接口", "明明|命名", "便利|遍历", "经历|经理", "权利|权力", "金币|金笔"])
    func aRealWordIsNeverRewrittenWithoutTheModel(_ text: String) {
        let sides = pair(text)
        // A recognition error by its sound, so it is learned, and the model gets it with the sentence.
        #expect(CorrectionExtractor().strength(of: sides) == .pair)
        #expect(!CorrectionExtractor.replacesBlindly(sides))
        let book = stored([text])
        let said = "他\(sides.wrong)知道，\(sides.wrong)也去"
        #expect(LearningPrompt.applyConfirmed(said, book: book) == said)
        #expect(LearningPrompt.pairs(for: said, from: book) == [sides])
    }

    @Test(arguments: ["引必|音币", "以经|已经", "日只|日志", "区线|曲线", "张伟|章伟", "按纽|按钮", "图型|图形", "科德克斯|Codex",
                      "爱皮爱|API", "Open Air|OpenAI", "Tail wind|Tailwind", "Chat GPT|ChatGPT", "Iphone|iPhone", "github|GitHub"])
    func whatNobodySaysOnPurposeIsStillWritten(_ text: String) {
        #expect(CorrectionExtractor.replacesBlindly(pair(text)))
    }

    @Test func whatIsNotSafeWithoutTheSentence() {
        // One word for another in Latin letters, also inside a phrase; a name split up again; two characters
        // for a name; everyday words for a name.
        for text in ["Cloud|Claude", "Cloud Code|Claude Code", "Open Air|Open AI", "Super base|Supabase", "YouTube|You Tube",
                     "claude|Claude", "谷歌|Google", "拉玛|Llama", "吃个饭|Chigofan", "他给我|Tagger", "斯威夫特|Swift", "甲方|乙方"] {
            #expect(!CorrectionExtractor.replacesBlindly(pair(text)), "\(text)")
        }
    }
}

// MARK: - polyphone-same-sound

@Suite struct OtherReadingTests {
    static let edits: [RuleRow] = [
        RuleRow(inserted: "把这个函数冲构一下", edited: "把这个函数重构一下", expected: ["冲构 → 重构"]),
        RuleRow(inserted: "去引航办事", edited: "去银行办事", expected: ["引航 → 银行"]),
        RuleRow(inserted: "用这个木板", edited: "用这个模板", expected: ["木板 → 模板"]),
        RuleRow(inserted: "这个航业", edited: "这个行业", expected: ["航业 → 行业"]),
    ]

    @Test(arguments: edits)
    func aCharacterWithSeveralReadingsSoundsTheSameByAnyOfThem(_ row: RuleRow) {
        #expect(fixes(extraction(row)) == row.expected)
    }

    @Test func readingsAreComparedCharacterByCharacter() {
        #expect(CorrectionExtractor.sameSound("引航", "银行") && CorrectionExtractor.sameSound("冲构", "重构")
               && CorrectionExtractor.sameSound("木板", "模板") && CorrectionExtractor.sameSound("回掉", "回调"))
        #expect(CorrectionExtractor.readings("行") == [["xin", "han"]])
        // Another reading does not make another word sound the same.
        #expect(!CorrectionExtractor.sameSound("银行", "杭州") && !CorrectionExtractor.sameSound("重要", "冲构")
               && !CorrectionExtractor.sameSound("广州", "杭州"))
        #expect(CorrectionExtractor.closeSound("金币", "音币") && !CorrectionExtractor.closeSound("日元", "美元"))
    }
}

// MARK: - WL-4 residual

@Suite struct EverydayPhraseTests {
    static let edits: [RuleRow] = [
        RuleRow(inserted: "我想吃个饭再说", edited: "我想 Chigofan 再说", expected: ["[Chigofan]"]),
        RuleRow(inserted: "去买个包吧", edited: "去 Mygobo 吧", expected: ["[Mygobo]"]),
        RuleRow(inserted: "我去买菜了", edited: "我 Chumaicai 了", expected: ["[Chumaicai]"]),
        // One such character twice is still a name spelled out.
        RuleRow(inserted: "调一下爱皮爱接口", edited: "调一下 API 接口", expected: ["爱皮爱 → API"]),
    ]

    @Test(arguments: edits)
    func twoOneCharacterWordsInARunAreEverydayText(_ row: RuleRow) {
        #expect(fixes(extraction(row)) == row.expected)
    }

    @Test(arguments: ["吃个饭|Chigofan", "买个包|Mygobo", "去买菜|Chumaicai"])
    func theHubKeepsOnlyTheName(_ text: String) {
        #expect(CorrectionExtractor().strength(of: pair(text)) == .termOnly)
        #expect(!CorrectionExtractor.replacesBlindly(pair(text)))
    }
}

// MARK: - WL-6 residual

@Suite struct SecretLabelTests {
    @Test(arguments: [
        "登录 token 之前给过你，就是 Martn 开头的那串", "新的 token 我发你了，是 Martn", "access token 之前给过你，是 Martn 那个",
        "这个 key 之前给过你，就是 Martn 那个", "pin 是 Martn", "key 是 Martn", "暗号是 Martn", "恢复码发你了。Martn 知道",
        "授权码：\n\nMartn", "激活码我放在后面了，Martn", "你的 credential 我看了，问一下 Martn",
    ])
    func aLabelAClauseBackStillIntroducesASecret(_ text: String) {
        let found = CorrectionExtractor().extract(inserted: text, edited: text.replacingOccurrences(of: "Martn", with: "Martin"))
        #expect(found.fixes.isEmpty && found.nothing == .sensitive, "\(fixes(found))")
    }

    @Test(arguments: [
        "这个 token 用量太高了，问一下 Martn 吧", "运行一下 pwd 看看，然后问 Martn", "用 pinyin 输入 Martn",
        "按一下 keyboard 上的 Martn 键", "把这个 key 改成 Martn",
    ])
    func talkThatOnlyMentionsSuchAWordStillTeaches(_ text: String) {
        let found = CorrectionExtractor().extract(inserted: text, edited: text.replacingOccurrences(of: "Martn", with: "Martin"))
        #expect(fixes(found) == ["Martn → Martin"], "\(text)")
    }

    @Test func aLabelIsAWordOfItsOwn() {
        #expect(CorrectionExtractor.labels("token 是 ") && CorrectionExtractor.labels("token 之前给过你，就是 ")
               && CorrectionExtractor.labels("pin: ") && CorrectionExtractor.labels("这个 key 我发你了，是 "))
        #expect(!CorrectionExtractor.labels("pinyin 是 ") && !CorrectionExtractor.labels("keyboard 是 ")
               && !CorrectionExtractor.labels("这个 token 用量太高了，问一下 "))
        for word in ["暗号", "恢复码", "授权码", "激活码", "my credentials"] { #expect(CorrectionExtractor.holdsSecret(word), "\(word)") }
        #expect(!CorrectionExtractor.holdsSecret("keyboard shortcuts") && !CorrectionExtractor.holdsSecret("这个 key 很长"))
    }
}

// MARK: - WL-7 residual: a capital is learned the second time; a word taken back alone is unlearned

@Suite struct CapitalSeenTwiceTests {
    static let edits: [RuleRow] = [
        RuleRow(inserted: "我用 cursor 写代码", edited: "我用 Cursor 写代码", expected: ["(Cursor)"]),
        RuleRow(inserted: "这个 bug 很严重", edited: "这个 Bug 很严重", expected: ["(Bug)"]),
        RuleRow(inserted: "这个 apple 很好吃", edited: "这个 Apple 很好吃", expected: ["(Apple)"]),
        RuleRow(inserted: "我在用 cloud code 写", edited: "我在用 Cloud code 写", expected: ["(Cloud)"]),
    ]

    @Test(arguments: edits)
    func aCapitalGivenOnceIsOnlyNoted(_ row: RuleRow) {
        let found = extraction(row)
        #expect(fixes(found) == row.expected)
        #expect(found.terms.isEmpty && found.pairs.isEmpty && found.sightings.count == 1 && !found.isEmpty)
        // Nothing is learned from it: not in the book's words, not for the dictionary.
        var book = LearningBook()
        let event = book.record(found.pairs, terms: found.terms, sightings: found.sightings, source: .otherApp, recordID: UUID(),
                                now: day) { _ in false }
        #expect(event.terms.isEmpty && event.learned.isEmpty && event.noted == found.sightings && !event.isEmpty)
        #expect(book.terms.isEmpty && book.learnedOnlyTerms.isEmpty && book.learnedRanking.isEmpty && !book.teaches(found.sightings[0]))
        #expect(book.sightings.map(\.term) == found.sightings)
    }

    @Test func theSameCapitalInAnotherDictationIsLearned() throws {
        var book = LearningBook()
        let first = UUID()
        let noted = book.record([], sightings: ["Cursor"], source: .otherApp, recordID: first, now: day) { _ in false }
        // The same dictation again (the text settled twice) is not a second time.
        #expect(book.record([], sightings: ["Cursor"], source: .otherApp, recordID: first, now: day) { _ in false }.isEmpty)
        #expect(book.terms.isEmpty)
        // The note survives being written out and read back.
        book = try JSONDecoder().decode(LearningBook.self, from: try JSONEncoder().encode(book))
        let learned = book.record([], sightings: ["Cursor"], source: .otherApp, recordID: UUID(), now: day.addingTimeInterval(60)) { _ in false }
        #expect(learned.terms == ["Cursor"] && book.terms.map(\.term) == ["Cursor"] && book.sightings.isEmpty)
        #expect(book.learnedOnlyTerms == ["cursor"] && book.teaches("Cursor"))
        // Another capital of the same word is another word: cursor → CURSOR is not the second time for Cursor.
        var other = LearningBook()
        _ = other.record([], sightings: ["Cursor"], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(other.record([], sightings: ["CURSOR"], source: .otherApp, recordID: UUID(), now: day) { _ in false }.terms.isEmpty)
        // Taking the second edit back leaves the note, taking the first back leaves nothing.
        book.undo(learned)
        #expect(book.terms.isEmpty && book.sightings.map(\.term) == ["Cursor"])
        book.undo(noted)
        #expect(book.sightings.isEmpty && book == LearningBook())
    }

    @Test func nothingIsNotedForAWordThatIsThereAlready() {
        var book = LearningBook()
        // The user's own word, a word a correction teaches, a word learned alone.
        #expect(book.record([], sightings: ["Cursor"], source: .otherApp, recordID: UUID(), now: day) { $0 == "Cursor" }.isEmpty)
        _ = book.record([pair("科德克斯|Codex")], terms: ["Nio"], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        #expect(book.record([], sightings: ["Codex", "Nio"], source: .otherApp, recordID: UUID(), now: day) { _ in false }.isEmpty)
        #expect(book.sightings.isEmpty)
        // Typed into the dictionary by hand since: no longer waiting to be seen again.
        _ = book.record([], sightings: ["Cursor"], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        book.markManualTerm("cursor")
        #expect(book.sightings.isEmpty)
        // The oldest notes go first.
        for i in 0..<(LearningBook.maxSightings + 5) {
            _ = book.record([], sightings: ["Name\(i)x"], source: .otherApp, recordID: UUID(), now: day) { _ in false }
        }
        #expect(book.sightings.count == LearningBook.maxSightings && book.sightings.first?.term == "Name\(LearningBook.maxSightings + 4)x")
        // A book from before notes still reads.
        #expect((try? JSONDecoder().decode(LearningBook.self, from: Data(#"{"version":1,"items":[],"terms":[]}"#.utf8)))?.sightings == [])
        #expect(LearningText.line(code: LearningLog.Code.seenOnce.rawValue, count: 0) == "改了大小写：下次再这样改就记住")
    }
}

@Suite struct WordTakenBackTests {
    /// Like the app: asks the tracker which words learned alone are gone, then settles and commits.
    static func step(_ t: inout EditTracker, _ text: String, own: Set<String> = []) -> (gone: [String], fixes: [String]?) {
        let gone = t.withdrawn(from: text)
        guard case let .extract(inserted, edited) = t.settle(text) else { return (gone, nil) }
        let found = CorrectionExtractor().extract(inserted: inserted, edited: edited, knownTerms: own)
        if !found.isEmpty { t.commit(edited, over: inserted, understood: found.baseline, alone: found.terms + found.sightings) }
        return (gone, fixes(found))
    }

    @Test(arguments: [Set<String>(), ["Claude"]])
    func aNameTypedWithAPauseLeavesNoHalfBehind(_ own: Set<String>) {
        var t = EditTracker(original: "用克劳德写")
        // The text settles in the middle of the name: its first letters are learned as a word, for now.
        let half = Self.step(&t, "用 Cla 写", own: own)
        #expect(half.gone.isEmpty && half.fixes == ["[Cla]"])
        // The name is finished: the half is no word of the text any more. It is taken back, and the whole
        // change is compared with what was delivered: 克劳德 → Claude, never Cla → Claude.
        let whole = Self.step(&t, "用 Claude 写", own: own)
        #expect(whole.gone == ["Cla"] && whole.fixes == ["克劳德 → Claude"])
        #expect(t.baseline == "用Claude写")
        // Nothing more to take back.
        #expect(t.withdrawn(from: "用 Claude 写").isEmpty)
    }

    @Test func aWordChangedBackWhileAnotherFixStaysIsTakenBack() {
        var t = EditTracker(original: "这个你好很好用，Open Air 也是")
        #expect(Self.step(&t, "这个Nio很好用，OpenAI 也是").fixes == ["[Nio]", "Open Air → OpenAI"])
        // 你好 was right after all. The other fix stays: no return to the delivered text, so no retract.
        let back = Self.step(&t, "这个你好很好用，OpenAI 也是")
        #expect(back.gone == ["Nio"])
        // Compared again from before the word: what still stands is found again (and counts once, it is the
        // same dictation), and nothing is made of Nio → 你好.
        #expect(back.fixes == ["Open Air → OpenAI"])
        #expect(t.baseline == "这个你好很好用，OpenAI 也是")
        // A capital taken back is no longer noted either.
        var c = EditTracker(original: "我用 cursor 写代码，Open Air 也用")
        #expect(Self.step(&c, "我用 Cursor 写代码，OpenAI 也用").fixes == ["(Cursor)", "Open Air → OpenAI"])
        #expect(Self.step(&c, "我用 cursor 写代码，OpenAI 也用").gone == ["Cursor"])
    }

    @Test func theWholeTextBackIsStillARetract() {
        var t = EditTracker(original: "这个你好很好用")
        #expect(Self.step(&t, "这个Nio很好用").fixes == ["[Nio]"])
        // `settle` takes everything back; `withdrawn` leaves that to it.
        #expect(t.withdrawn(from: "这个你好很好用").isEmpty)
        #expect(t.settle("这个你好很好用") == .retract)
        #expect(t.withdrawn(from: "这个别的很好用").isEmpty)
        // A word still there, also with other text around it, is not taken back.
        var u = EditTracker(original: "这个你好很好用")
        _ = Self.step(&u, "这个Nio很好用")
        #expect(u.withdrawn(from: "这个Nio很好用，真的").isEmpty && u.withdrawn(from: "Nio，这个很好用").isEmpty)
        #expect(EditTracker.shows("Cla", in: "用 Cla 写") && !EditTracker.shows("Cla", in: "用 Claude 写")
               && !EditTracker.shows("Nio", in: "这个你好") && EditTracker.shows("Nio", in: "这个Nio很好用"))
    }
}

// MARK: - deletion-makes-rewrite

@Suite struct DeletionTests {
    @Test func aSentenceCutOutTakesNothingAwayFromAFixInWhatIsLeft() {
        let original = "第一句话说完了。第二句话是废话可以删掉不要了。问一下 Martn 吧"
        var t = EditTracker(original: original)
        // The sentence is deleted: settles as nothing, the baseline stays.
        #expect(t.settle("第一句话说完了。问一下 Martn 吧") == .none)
        #expect(HalfTypedTextTests.step(&t, "第一句话说完了。问一下 Martin 吧") == ["Martn → Martin"])
        // In one comparison: most of the passage deleted, one name fixed.
        let found = CorrectionExtractor().extract(inserted: "嗯那个就是说我想问一下 Martn 吧，这个事情到底怎么办才好呢",
                                                  edited: "问一下 Martin 吧，怎么办")
        #expect(fixes(found) == ["Martn → Martin"])
    }

    @Test func deletedTextNextToRewordingIsStillARewrite() {
        // Two stretches deleted and one reworded: the user is rewriting, and the name fixed in between is not trusted.
        let found = CorrectionExtractor().extract(inserted: "嗯那个就是说我想问一下 Martn 吧，然后明天买入，这个事情到底怎么办才好呢",
                                                  edited: "问一下 Martin 吧，然后今天买入，怎么办")
        #expect(found.fixes.isEmpty && found.nothing == .rewrite)
        // Deleted text alone is still nothing to learn from.
        #expect(CorrectionExtractor().extract(inserted: "嗯那个就是说我想问一下", edited: "问一下").nothing == .removedOnly)
    }
}
