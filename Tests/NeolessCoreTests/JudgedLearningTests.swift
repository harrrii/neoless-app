import Foundation
import Testing
@testable import NeolessCore

/// Words the rules could not decide about (`Extraction.doubts`), what may be asked about (`isJudgeable`), the
/// question and its answer (`MisheardJudge`), and what a judged pair is in the book (`Kind.judged`). Also the
/// watch of a pasted passage, which must see a word fixed and sent at once. All text here is made up.
struct JudgedLearningTests {
    private let extractor = CorrectionExtractor()
    private func pair(_ wrong: String, _ right: String) -> CorrectionPair { CorrectionPair(wrong: wrong, right: right) }

    @Test func wordsTheRulesCannotDecideAboutAreDoubts() {
        // Does not sound alike: no fix by the rules, and worth asking about.
        let swap = extractor.extract(inserted: "我们看一下米线的走势", edited: "我们看一下曲线的走势")
        #expect(swap.fixes.isEmpty && swap.doubts == [pair("米线", "曲线")])
        // A name in Latin letters over everyday words: no fix by the rules, worth asking about.
        let name = extractor.extract(inserted: "帮我打开萝卜看看", edited: "帮我打开 Notion 看看")
        #expect(name.pairs.isEmpty && name.doubts == [pair("萝卜", "Notion")])
        // What a rule forbids is never asked about.
        for (a, b) in [("周五下午开会", "周日下午开会"), ("这个方案有效", "这个方案无效"), ("王伟明天到", "王磊明天到"),
                       ("我们去广州吧", "我们去杭州吧"), ("买 100 股", "买 200 股")] {
            #expect(extractor.extract(inserted: a, edited: b).doubts.isEmpty, "\(a) → \(b)")
        }
        // A fix the rules take is learned, not asked about.
        let fix = extractor.extract(inserted: "用科德克斯写代码", edited: "用 Codex 写代码")
        #expect(fix.doubts.isEmpty)
    }

    @Test func judgeableIsRepeatableWithoutTheSoundRule() {
        #expect(extractor.isJudgeable(pair("函数", "脚本")) && !extractor.isRepeatable(pair("函数", "脚本")))
        #expect(extractor.isJudgeable(pair("萝卜", "Notion")) && !extractor.isRepeatable(pair("萝卜", "Notion")))
        for (a, b) in [("周五", "周日"), ("有效", "无效"), ("王伟", "王磊"), ("广州", "杭州"), ("买入", "卖出"), ("CPU", "GPU"),
                       ("密码", "口令"), ("曲线", "曲线图"), ("萝卜", "notion")] {
            #expect(!extractor.isJudgeable(pair(a, b)), "\(a) → \(b)")
        }
        // The typed-over word is the user's own.
        #expect(!extractor.isJudgeable(pair("米线", "曲线"), knownTerms: ["米线"]))
    }

    @Test func theQuestionAndItsAnswer() {
        let asked = [pair("米线", "曲线"), pair("萝卜", "Notion")]
        let question = MisheardJudge.question(heard: "我们看一下米线的走势\n然后", delivered: "我们看一下米线的走势。", pairs: asked)
        #expect(question.contains("<识别原文>\n我们看一下米线的走势\n然后\n</识别原文>"))
        #expect(question.contains("1. 错写：米线  改成：曲线") && question.contains("2. 错写：萝卜  改成：Notion"))
        #expect(MisheardJudge.instructions.contains("拿不准就是 false"))

        let answer = #"{"results":[{"wrong":"米线","right":"曲线","misheard":false},{"wrong":"萝卜","right":"NOTION","misheard":true}]}"#
        #expect(MisheardJudge.misheard(in: answer, asked: asked) == [pair("萝卜", "Notion")])
        // In a code fence, with words around it.
        #expect(MisheardJudge.misheard(in: "好的：\n```json\n\(answer)\n```", asked: asked) == [pair("萝卜", "Notion")])
        // A pair not asked about, a verdict that is not true, or no JSON: nothing.
        #expect(MisheardJudge.misheard(in: #"{"results":[{"wrong":"日志","right":"记录","misheard":true}]}"#, asked: asked).isEmpty)
        #expect(MisheardJudge.misheard(in: #"{"results":[{"wrong":"米线","right":"曲线","misheard":"true"}]}"#, asked: asked).isEmpty)
        #expect(MisheardJudge.misheard(in: "是听错", asked: asked).isEmpty)
        // At most `maxPairs` are asked, and only those count.
        let many = (1...5).map { pair("词\($0)", "字\($0)") }
        #expect(!MisheardJudge.question(heard: "", delivered: "", pairs: many).contains("4. "))
    }

    @Test func aJudgedPairIsACorrectionHeldToWhatNoRuleForbids() {
        var book = LearningBook()
        let id = UUID()
        let event = book.record([], judged: [pair("米线", "曲线")], source: .otherApp, recordID: id) { _ in false }
        #expect(event.learned == [pair("米线", "曲线")] && event.promoted.isEmpty)
        let item = try! #require(book.items.first)
        #expect(item.kind == .judged && item.isJudged && !item.isRepeated && item.count == 1 && item.addedTerm)
        // The rules for recognition errors would not take it; as judged it is in use.
        #expect(extractor.strength(of: item.pair) == nil)
        #expect(book.unusable(knownTerms: []).isEmpty)
        #expect(LearningPrompt.pairs(for: "看看米线", from: book) == [pair("米线", "曲线")])
        // Never written into text without the model, however often it was judged so.
        _ = book.record([], judged: [pair("米线", "曲线")], source: .otherApp, recordID: UUID()) { _ in false }
        #expect(book.items.first?.count == 2)
        #expect(LearningPrompt.applyConfirmed("看看米线", book: book) == "看看米线")
        // One a rule forbids, stored as judged by a mistake or an older version, is not used.
        var bad = LearningBook()
        _ = bad.record([], judged: [pair("周五", "周日")], source: .otherApp, recordID: id) { _ in false }
        #expect(bad.unusable(knownTerms: []) == [LearningBook.key(pair("周五", "周日"))])
    }

    @Test func aWordFixedAndSentAtOnceIsCompared() {
        // Deleted, retyped and sent within a moment: the last text seen is what was sent.
        var watch = PassageWatch(shown: "看看报告", at: 0)
        _ = watch.take(.passage("看看", composing: false), at: 1)
        _ = watch.take(.passage("看看报道", composing: false), at: 3)
        #expect(watch.take(.empty, at: 3.1) == .end(.sent, flush: "看看报道"))
        // Not while the input method still had uncommitted text in it.
        var composing = PassageWatch(shown: "看看报告", at: 0)
        _ = composing.take(.passage("看看bao", composing: true), at: 1)
        #expect(composing.take(.empty, at: 1.1) == .end(.sent, flush: nil))
        // The new word landed while focus seemed elsewhere (an input method's candidate window): back in the
        // field with it still there, it is compared once it has settled.
        var ime = PassageWatch(shown: "看看报告", at: 0)
        _ = ime.take(.passage("看看", composing: false), at: 1)
        #expect(ime.take(.passage("看看", composing: false), at: 2.6) == .settled("看看"))
        _ = ime.take(.passage("看看报道", composing: false), at: 3, focused: false)
        #expect(ime.take(.passage("看看报道", composing: false), at: 3.5) == .wait)
        #expect(ime.take(.passage("看看报道", composing: false), at: 5.1) == .settled("看看报道"))
        // And sent at once from there.
        var imeSent = PassageWatch(shown: "看看报告", at: 0)
        _ = imeSent.take(.passage("看看报道", composing: false), at: 1, focused: false)
        #expect(imeSent.take(.empty, at: 1.2) == .end(.sent, flush: "看看报道"))
        // A long dictation read through first: a fix four minutes in is still seen.
        var late = PassageWatch(shown: "看看报告", at: 0)
        #expect(late.take(.passage("看看报告", composing: false), at: 230) == .wait)
        _ = late.take(.passage("看看报道", composing: false), at: 240)
        #expect(late.take(.passage("看看报道", composing: false), at: 241.6) == .settled("看看报道"))
        // And a second fix a minute after the first.
        _ = late.take(.passage("看看报道吧", composing: false), at: 290)
        #expect(late.take(.passage("看看报道吧", composing: false), at: 291.6) == .settled("看看报道吧"))
        // Nothing changing for a while: looked at less often.
        #expect(late.interval(at: 291.6 + PassageWatch.quietAfter + 1) == PassageWatch.awayInterval)
    }
}
