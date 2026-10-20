import Testing
@testable import NeolessCore

@Suite struct QuickTidyTests {
    @Test func shortPlainSentencesSkipChatGPT() {
        #expect(QuickTidy.applies(to: "好的，马上到。"))
        #expect(QuickTidy.applies(to: "帮我看一下这个报错"))
        #expect(!QuickTidy.applies(to: ""))
        #expect(!QuickTidy.applies(to: String(repeating: "长", count: 21)))
        #expect(!QuickTidy.applies(to: "明天三点，不对，四点见"))
        #expect(!QuickTidy.applies(to: "涨了百分之一点五"))
    }

    @Test func aSwapHabitIsMadeHereAndOtherHabitsAreLeftToLongerSentences() {
        let swap = ["把所有的吧换成“罢”"]
        #expect(QuickTidy.tidy("应该是这个吧。", habits: swap) == "应该是这个罢。")
        #expect(QuickTidy.tidy("嗯，好吧，用GPT吧", habits: swap) == "好罢，用 GPT 罢")
        #expect(QuickTidy.tidy("应该是这个吧。", habits: ["微信里句末不要句号"] + swap) == "应该是这个罢。")
        #expect(QuickTidy.tidy("应该是这个吧。", habits: []) == "应该是这个吧。")
    }

    @Test func shortSentencesGetDigitsAndArithmeticHere() {
        #expect(QuickTidy.applies(to: "一二三四五六七八九零一二三四。"))
        #expect(QuickTidy.tidy("一二三四五六七八九零一二三四。", habits: []) == "12345678901234。")
        #expect(QuickTidy.applies(to: "五乘五等于多少"))
        #expect(QuickTidy.tidy("五乘五等于多少", habits: []) == "5*5 等于多少")
        #expect(QuickTidy.tidy("号码是幺三八零", habits: []) == "号码是 1380")
        #expect(QuickTidy.applies(to: "五乘五，加五六七八。"))
        #expect(QuickTidy.tidy("五乘五，加五六七八。", habits: []) == "5*5+5678。")
        // Whether 七十二 is a quantity or a price depends on the sentence: ChatGPT writes it.
        #expect(!QuickTidy.applies(to: "一共七十二封"))
        #expect(!QuickTidy.applies(to: "三点见"))
        #expect(QuickTidy.applies(to: "快一点"))
    }

    @Test func whatCountsAsASwapHabit() {
        func swap(_ habit: String) -> [String]? { QuickTidy.swap(in: habit).map { [$0.from, $0.to] } }
        #expect(swap("把所有的吧换成“罢”") == ["吧", "罢"])
        #expect(swap("把吧换成罢") == ["吧", "罢"])
        #expect(swap("把吧都换成罢。") == ["吧", "罢"])
        #expect(swap("把全部的“首先”改成“第一”") == ["首先", "第一"])
        #expect(swap("“OpenAI”写成“Open AI”") == nil)  // a space in the word: left to the model
        #expect(swap("「嗯嗯」替换为「好的」") == ["嗯嗯", "好的"])
        #expect(swap("微信里把吧换成罢") == nil)
        #expect(swap("把吧换成罢，但是微信里不要") == nil)
        #expect(swap("微信里句末不要句号") == nil)
        #expect(swap("把吧换成吧") == nil)
        #expect(QuickTidy.swaps(for: []).isEmpty)
        #expect(QuickTidy.swaps(for: ["不要用“首先、其次”", "把吧换成罢"]).map(\.to) == ["罢"])
    }

    @Test func tidyDropsFillersAndSpacesLatin() {
        #expect(QuickTidy.tidy("嗯，帮我打开Claude", habits: []) == "帮我打开 Claude")
        #expect(QuickTidy.tidy("好的，嗯，3点见", habits: []) == "好的，3 点见")
        #expect(QuickTidy.tidy("嗯", habits: []) == "嗯")
        #expect(QuickTidy.tidy("用GPT-6跑一下", habits: []) == "用 GPT-6 跑一下")
    }

    @Test func compactInstructionsForShortTranscripts() {
        #expect(PolishPrompt.usesCompact("帮我把设置页的按钮改成蓝色"))
        #expect(!PolishPrompt.usesCompact(String(repeating: "字", count: 81)))
        let compact = PolishPrompt.compactInstructions(for: .natural)
        #expect(compact.count * 2 < PolishPrompt.naturalInstructions.count)
        #expect(compact.contains("<逐字稿>"))
        #expect(PolishPrompt.compactInstructions(for: .structured).contains("不写代码"))
    }
}
