import Foundation
import Testing
@testable import NeolessCore

@Suite struct NeoModelChoiceTests {
    @Test func theFourChoicesInMenuOrder() {
        #expect(NeoModelChoice.allCases == [.auto, .large, .small, .local])
        // What is stored; the Neo's three are also what the hub's request field calls them.
        #expect(NeoModelChoice.allCases.map(\.rawValue) == ["auto", "large", "small", "local"])
        #expect(NeoModelChoice.neoModels == [.auto, .large, .small])
        #expect(NeoModelChoice.allCases.map(\.title)
                == ["自动（推荐）", "大模型（更准，慢一些）", "小模型（更快）", "本机识别（最快）"])
        // Only 本机识别 leaves the Neo's recognition out.
        #expect(NeoModelChoice.allCases.filter { !$0.usesNeoRecognition } == [.local])
    }

    @Test func nothingStoredOrSomethingUnknownIsAuto() {
        #expect(NeoModelChoice(stored: nil) == .auto)
        #expect(NeoModelChoice(stored: "") == .auto)
        #expect(NeoModelChoice(stored: "huge") == .auto)
        #expect(NeoModelChoice(stored: "LARGE") == .auto)
        #expect(NeoModelChoice(stored: "large") == .large)
        #expect(NeoModelChoice(stored: "small") == .small)
        #expect(NeoModelChoice(stored: "auto") == .auto)
        #expect(NeoModelChoice(stored: "local") == .local)
    }

    @Test func eachChoiceSaysWhatItDoesWithoutAnyNames() {
        #expect(NeoModelChoice.auto.detail() == "平时用大模型，Neo 忙时自动换小模型")
        #expect(NeoModelChoice.large.detail() == "一直用大模型，Neo 忙时要多等一会儿")
        #expect(NeoModelChoice.small.detail() == "一直用小模型，没有大模型准")
        #expect(NeoModelChoice.local.detail() == "说完直接整理这台 Mac 识别的文字，不等 Neo 再识别一遍；英文专有名词可能不准，本机没听清时照常交给 Neo")
        // Four different lines, none of them empty.
        #expect(Set(NeoModelChoice.allCases.map { $0.detail() }).count == 4)
        // 本机识别 names no model, whatever the Neo said.
        #expect(NeoModelChoice.local.detail(NeoModelNames(current: "Qwen3-ASR-1.7B-4bit", large: "Qwen3-ASR-1.7B-4bit",
                                                          small: "Qwen3-ASR-0.6B-4bit")) == NeoModelChoice.local.detail())
    }

    @Test func autoNamesTheModelInUseWhenTheNeoSaysIt() {
        // Only the model in use is named: the one it would use now, by its own name.
        let busy = NeoModelNames(current: "Qwen3-ASR-0.6B-4bit")
        #expect(NeoModelChoice.auto.detail(busy) == "平时用大模型，Neo 忙时自动换小模型。现在用的是 Qwen3\u{2011}ASR\u{2011}0.6B\u{2011}4bit")
        // A forced choice is not what the Neo would pick by itself: the name is left out.
        #expect(NeoModelChoice.large.detail(busy) == NeoModelChoice.large.detail())
        #expect(NeoModelChoice.small.detail(busy) == NeoModelChoice.small.detail())
    }

    @Test func aHubThatNamesBothModelsGetsThemShown() {
        let large = "Qwen3-ASR-1.7B-4bit", small = "Qwen3-ASR-0.6B-4bit"
        #expect(NeoModelChoice.auto.detail(NeoModelNames(current: large, large: large, small: small))
                == "平时用大模型，Neo 忙时自动换小模型。现在用的是大模型")
        #expect(NeoModelChoice.auto.detail(NeoModelNames(current: small, large: large, small: small))
                == "平时用大模型，Neo 忙时自动换小模型。现在用的是小模型")
        // In use and neither of the two (a hub set up with another model): its own name.
        #expect(NeoModelChoice.auto.detail(NeoModelNames(current: "Qwen3-ASR-1.7B-8bit", large: large, small: small))
                == "平时用大模型，Neo 忙时自动换小模型。现在用的是 Qwen3\u{2011}ASR\u{2011}1.7B\u{2011}8bit")
        // Named but none said to be in use: only the rule.
        #expect(NeoModelChoice.auto.detail(NeoModelNames(large: large, small: small)) == NeoModelChoice.auto.detail())
        #expect(NeoModelChoice.large.detail(NeoModelNames(large: large, small: small))
                == "一直用大模型（Qwen3\u{2011}ASR\u{2011}1.7B\u{2011}4bit），Neo 忙时要多等一会儿")
        #expect(NeoModelChoice.small.detail(NeoModelNames(large: large, small: small))
                == "一直用小模型（Qwen3\u{2011}ASR\u{2011}0.6B\u{2011}4bit），没有大模型准")
        // Only one of them named: the other line stays plain.
        #expect(NeoModelChoice.small.detail(NeoModelNames(large: large)) == NeoModelChoice.small.detail())
    }

    @Test func aModelsNameNeverBreaksAtItsHyphens() {
        // A line wraps at an ordinary hyphen: at the narrowest window "Qwen3-" ended one line and "ASR-1.7B-4bit"
        // began the next. Shown, the name has hyphens that do not break; nothing else about it changes.
        let large = "Qwen3-ASR-1.7B-4bit", small = "Qwen3-ASR-0.6B-4bit"
        let lines = [NeoModelChoice.auto.detail(NeoModelNames(current: "Qwen3-ASR-1.7B-8bit", large: large, small: small)),
                     NeoModelChoice.large.detail(NeoModelNames(large: large, small: small)),
                     NeoModelChoice.small.detail(NeoModelNames(large: large, small: small))]
        for line in lines {
            #expect(!line.contains("-"))
            #expect(line.contains("\u{2011}"))
        }
        #expect(lines[1].replacingOccurrences(of: "\u{2011}", with: "-").contains(large))
        // The names themselves stay as the Neo said them.
        #expect(NeoModelNames(large: large).large == large)
    }
}

/// Which Neo the choice does anything on, what a recording asks it for, and what the row says.
@Suite struct NeoModelSupportTests {
    private let large = "Qwen3-ASR-1.7B-4bit", small = "Qwen3-ASR-0.6B-4bit"

    @Test func whatTheNeoNamesSaysWhatItDoesWithAChoice() {
        // A hub from before the choice names only the model in use (or nothing).
        #expect(NeoModelNames().support == .outdated)
        #expect(NeoModelNames(current: large).support == .outdated)
        #expect(NeoModelNames(small: small).support == .outdated)
        // A worker without a second model: the large one answers everything.
        #expect(NeoModelNames(current: large, large: large).support == .single)
        #expect(NeoModelNames(large: large, small: large).support == .single)
        #expect(NeoModelNames(large: large, small: "  ").support == .single)
        #expect(NeoModelNames(current: small, large: large, small: small).support == .both)
    }

    @Test func onlyANeoWithBothModelsIsAskedForOne() {
        // 本机识别 included: when its recording does go to the Neo, the app asks for no model (`requested` is nil).
        for choice in NeoModelChoice.allCases {
            #expect(choice.asked(of: .both) == choice)
            // Not acted on there: nothing is asked, so nothing is waited for or left out for it.
            #expect(choice.asked(of: .outdated) == .auto)
            #expect(choice.asked(of: .single) == .auto)
            // Not heard from yet (out of reach as the app started): the choice was made on a Neo that had both.
            #expect(choice.asked(of: .unknown) == choice)
        }
    }

    @Test func theRowOffersEverythingOnANeoThatSaidItHasBoth() {
        let names = NeoModelNames(current: large, large: large, small: small)
        for choice in NeoModelChoice.allCases {
            let row = NeoModelRow(choice: choice, hubEnabled: true, paired: true, support: .both, names: names)
            #expect(row.enabled)
            #expect(row.detail == choice.detail(names))
            #expect(row.choices == NeoModelChoice.allCases)
        }
    }

    @Test func withoutTheNeoInUseItIsGrey() {
        for choice in NeoModelChoice.allCases {
            func row(on: Bool = true, paired: Bool = true, _ support: NeoModelSupport) -> NeoModelRow {
                NeoModelRow(choice: choice, hubEnabled: on, paired: paired, support: support,
                            names: NeoModelNames(current: large))
            }
            #expect(row(on: false, .both) == row(on: false, paired: false, .unknown))
            #expect(!row(on: false, .both).enabled && row(on: false, .both).detail == "用 Neo 处理时才起作用")
            #expect(!row(paired: false, .unknown).enabled && row(paired: false, .unknown).detail == "和 Neo 配对后才起作用")
            // Grey, the pop-up still shows what is stored.
            #expect(row(on: false, .both).choices.contains(choice))
        }
    }

    @Test func elsewhereOnlyAutoAndThisMacAreOfferedAndTheLineSaysWhatIsMissing() {
        // Whatever is stored: no line promises a model the Neo would not use, and 本机识别 needs nothing of the Neo's.
        for choice in NeoModelChoice.allCases {
            func row(_ support: NeoModelSupport) -> NeoModelRow {
                NeoModelRow(choice: choice, hubEnabled: true, paired: true, support: support, names: NeoModelNames(current: large))
            }
            // A stored large or small choice stays in the list, so the pop-up can show it.
            let offered: [NeoModelChoice] = choice == .large || choice == .small ? [.auto, choice, .local] : [.auto, .local]
            let lines: [(NeoModelSupport, String)] = [(.unknown, "连上 Neo 后才能选大模型、小模型"),
                                                      (.outdated, "Neo 更新后才能选大模型、小模型"),
                                                      (.single, "这台 Neo 只有一个识别模型")]
            for (support, line) in lines {
                #expect(row(support).enabled, "\(choice) \(support)")
                #expect(row(support).choices == offered, "\(choice) \(support)")
                #expect(row(support).detail == (choice == .local ? NeoModelChoice.localDetail : line), "\(choice) \(support)")
            }
        }
    }
}

@Suite struct NeoModelNamesTests {
    @Test func aNameIsOneShortLineOrNothing() {
        #expect(NeoModelNames() == NeoModelNames(current: nil, large: nil, small: nil))
        #expect(NeoModelNames(current: "  Qwen3-ASR-1.7B-4bit \n").current == "Qwen3-ASR-1.7B-4bit")
        #expect(NeoModelNames(current: "").current == nil)
        #expect(NeoModelNames(current: "   ").current == nil)
        #expect(NeoModelNames(large: "a\nb").large == nil)
        #expect(NeoModelNames(small: "a\u{0007}b").small == nil)
        #expect(NeoModelNames(small: "a\u{2028}b").small == nil)
        #expect(NeoModelNames(current: String(repeating: "x", count: NeoModelNames.maxLength)).current != nil)
        #expect(NeoModelNames(current: String(repeating: "x", count: NeoModelNames.maxLength + 1)).current == nil)
    }

    @Test func aNameThatIsNotOneChangesNoLine() {
        let bad = NeoModelNames(current: "x\ny", large: "", small: String(repeating: "长", count: 200))
        for choice in NeoModelChoice.allCases {
            #expect(choice.detail(bad) == choice.detail())
        }
    }
}

/// 本机识别: when this Mac's own transcript is polished as it is, and when the recording goes to the Neo after all.
@Suite struct LocalRecognitionTests {
    @Test func aTranscriptWithoutWordsIsNone() {
        for text in ["", "   ", "\n", "。", "，、？", "…"] {
            #expect(!LocalRecognition.usable(text, audioSeconds: 2), "\(text)")
        }
    }

    @Test func aShortRecordingTakesAnyWord() {
        #expect(LocalRecognition.usable("好", audioSeconds: 1))
        #expect(LocalRecognition.usable("OK", audioSeconds: LocalRecognition.checkedFrom))
        #expect(LocalRecognition.usable("3", audioSeconds: .nan))
        #expect(LocalRecognition.usable("嗯", audioSeconds: -1))
    }

    @Test func aLongRecordingWithAWordOrTwoIsOneThisMacMostlyMissed() {
        // People say 4–5 characters a second: a word or two for 12 seconds is not what was said.
        #expect(!LocalRecognition.usable("好的", audioSeconds: 12))
        #expect(!LocalRecognition.usable("明天", audioSeconds: 60))
        #expect(LocalRecognition.usable("明天下午三点开会", audioSeconds: 12))
        #expect(LocalRecognition.usable("明天开会", audioSeconds: 12))     // one per three seconds is enough
        #expect(LocalRecognition.usable("Please send the report before lunch", audioSeconds: 20))
        // Punctuation is no word.
        #expect(!LocalRecognition.usable("好。。。。。。。", audioSeconds: 12))
    }
}
