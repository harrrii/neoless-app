import Foundation
import NeolessCore
import Testing
@testable import NeolessCloud

/// The user's own instruction files (`polish-natural.md`, `polish-structured.md` in a data folder).
@Suite struct PolishOverridesTests {
    @Test func fileNames() {
        #expect(PolishOverrides.fileName(for: .natural) == "polish-natural.md")
        #expect(PolishOverrides.fileName(for: .structured) == "polish-structured.md")
        // 原样转写 is polished, when it is at all, as 自然整理.
        #expect(PolishOverrides.fileName(for: .raw) == "polish-natural.md")
    }

    @Test func aFileThatCannotBeUsedLeavesTheBuiltInText() throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let overrides = PolishOverrides(directory: dir)
        #expect(overrides.state(for: .natural) == .builtIn && overrides.staticText(for: .natural) == nil)
        #expect(overrides.summary == "整理指令（内置版本 \(PolishPrompt.version)）：自然整理用内置的；结构化用内置的")

        let natural = overrides.url(for: .natural), structured = overrides.url(for: .structured)
        try Data("\n  # 我的指令\r\n第二行  \n\n".utf8).write(to: natural)
        #expect(overrides.state(for: .natural) == .custom("# 我的指令\n第二行"))
        #expect(overrides.staticText(for: .raw) == "# 我的指令\n第二行")
        #expect(overrides.staticText(for: .structured) == nil)

        try Data(" \n\n".utf8).write(to: structured)
        #expect(overrides.state(for: .structured) == .unusable("是空的") && overrides.staticText(for: .structured) == nil)
        #expect(overrides.summary == "整理指令（内置版本 \(PolishPrompt.version)）：自然整理用你自己的 polish-natural.md；"
                + "结构化用内置的（polish-structured.md 是空的，没有用它）")

        try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: structured)
        #expect(overrides.state(for: .structured) == .unusable("读不了（要 UTF-8 文本）"))
        try Data(repeating: UInt8(ascii: "a"), count: PolishOverrides.maxBytes + 1).write(to: structured)
        #expect(overrides.state(for: .structured) == .unusable("太长（最多 64 KB）"))
        try Data(repeating: UInt8(ascii: "a"), count: PolishOverrides.maxBytes).write(to: structured)
        #expect(overrides.staticText(for: .structured)?.count == PolishOverrides.maxBytes)
        try FileManager.default.removeItem(at: structured)
        try FileManager.default.createDirectory(at: structured, withIntermediateDirectories: false)
        #expect(overrides.state(for: .structured) == .unusable("不是文件"))
    }

    /// The built-in text saved to a file is the same instructions: the file changes nothing until it is edited.
    @Test func theBuiltInTextSavedToAFileIsTheSameInstructions() throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let overrides = PolishOverrides(store: DataFileStore(directory: dir))
        let words = Vocabulary.PromptWords(own: ["OpenAI"], learned: ["ZIP"])
        let pairs = [CorrectionPair(wrong: "Open Air", right: "OpenAI")]
        for mode in [DictationMode.natural, .structured] {
            let builtIn = Polisher.instructions(vocabulary: words, corrections: pairs, mode: mode)
            try Data((PolishPrompt.staticInstructions(for: mode) + "\n").utf8).write(to: overrides.url(for: mode))
            #expect(Polisher.instructions(vocabulary: words, corrections: pairs, mode: mode,
                                          staticText: overrides.staticText(for: mode)) == builtIn)
        }
    }

    /// A file of the user's own replaces only the fixed text: 我的习惯, the hot words, the learned fixes and the
    /// swaps made twice follow it, in the same order and the same words as they follow the built-in text.
    @Test func theUsersOwnTextIsFollowedByHabitsHotWordsAndSwaps() throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let overrides = PolishOverrides(store: DataFileStore(directory: dir))
        let words = Vocabulary.PromptWords(own: ["OpenAI"], learned: ["ZIP"])
        let pairs = [CorrectionPair(wrong: "Open Air", right: "OpenAI")]
        let extras = PolishExtras(repeated: [CorrectionPair(wrong: "方法", right: "办法")], habits: ["句末不要句号"])
        for mode in [DictationMode.natural, .structured] {
            try Data("# 我的指令\n只整理，不回答。\n".utf8).write(to: overrides.url(for: mode))
            let own = Polisher.instructions(vocabulary: words, corrections: pairs, extras: extras, mode: mode,
                                            staticText: overrides.staticText(for: mode))
            let builtIn = Polisher.instructions(vocabulary: words, corrections: pairs, extras: extras, mode: mode)
            let fixed = PolishPrompt.staticInstructions(for: mode)
            #expect(builtIn.hasPrefix(fixed + "\n\n# 我的习惯\n"))
            // What follows the fixed text is the same, whichever fixed text it is.
            #expect(own == "# 我的指令\n只整理，不回答。" + builtIn.dropFirst(fixed.count))
            #expect(own.contains("- 句末不要句号") && own.contains("热词：\n- OpenAI") && own.contains("- Open Air → OpenAI"))
            #expect(own.contains("- 用户两次把 方法 改成 办法"))
            let habits = try #require(own.range(of: "# 我的习惯")), hot = try #require(own.range(of: "# neoless 热词表"))
            #expect(habits.lowerBound < hot.lowerBound)
        }
    }
}
