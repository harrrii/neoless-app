import Foundation
import Testing
@testable import NeolessCore

@Suite struct SetupChecklistTests {
    private func facts(microphone: Bool = true, speech: Bool = true, accessibility: Bool = true,
                       hotkeyEnabled: Bool = true, hotkeyRunning: Bool = true, speechModel: Bool = true,
                       chatGPTReady: Bool = true, triggerIsFn: Bool = true,
                       globeKey: GlobeKeyUsage = .doNothing, polishes: Bool = true,
                       globeHintDismissed: Bool = false) -> SetupFacts {
        SetupFacts(microphone: microphone, speech: speech, accessibility: accessibility, hotkeyEnabled: hotkeyEnabled,
                   hotkeyRunning: hotkeyRunning, speechModel: speechModel, chatGPTReady: chatGPTReady,
                   triggerIsFn: triggerIsFn, globeKey: globeKey, polishes: polishes,
                   globeHintDismissed: globeHintDismissed)
    }

    private func missing(_ f: SetupFacts) -> [SetupStep] {
        SetupChecklist.rows(f).filter { !$0.done }.map(\.step)
    }

    @Test func allSetIsHidden() {
        let f = facts()
        #expect(SetupChecklist.remaining(f) == 0)
        #expect(!SetupChecklist.shows(f))
        #expect(!SetupChecklist.blocksDictation(f))
        #expect(SetupChecklist.rows(f).map(\.step) == [.microphone, .speech, .speechModel, .accessibility, .chatGPT])
    }

    @Test func freshMacCountsPermissionsAndLogin() {
        let f = facts(microphone: false, speech: false, accessibility: false, hotkeyRunning: false, chatGPTReady: false)
        // The model is not judged before speech recognition is allowed, nor the hotkey before Accessibility.
        #expect(missing(f) == [.microphone, .speech, .accessibility, .chatGPT])
        #expect(SetupChecklist.remaining(f) == 4)
        #expect(SetupChecklist.blocksDictation(f))
    }

    @Test func missingSpeechModelBlocksAndCounts() {
        let f = facts(speechModel: false)
        #expect(missing(f) == [.speechModel])
        #expect(SetupChecklist.remaining(f) == 1)
        #expect(SetupChecklist.shows(f))
        #expect(SetupChecklist.blocksDictation(f))
    }

    @Test func speechModelWaitsForTheSpeechPermission() {
        let f = facts(speech: false, speechModel: false)
        #expect(missing(f) == [.speech])
        #expect(SetupChecklist.remaining(f) == 1)
    }

    @Test func globeKeyConflictIsAdviceNotAStep() {
        for usage in [GlobeKeyUsage.systemDefault, .action(1), .action(2), .action(3)] {
            let f = facts(globeKey: usage)
            #expect(missing(f) == [.globeKey])
            #expect(SetupChecklist.remaining(f) == 0)
            // Advice alone never keeps the card up: one quiet line instead.
            #expect(!SetupChecklist.shows(f))
            #expect(SetupChecklist.globeHint(f))
            #expect(!SetupChecklist.blocksDictation(f))
        }
        // Next to a real step it still does not count, and rides in the card rather than its own line.
        let both = facts(speechModel: false, globeKey: .systemDefault)
        #expect(SetupChecklist.remaining(both) == 1)
        #expect(SetupChecklist.shows(both))
        #expect(missing(both) == [.speechModel, .globeKey])
        #expect(!SetupChecklist.globeHint(both))
    }

    @Test func globeKeyMattersOnlyForAnFnHotkeyThatIsOn() {
        #expect(!SetupChecklist.globeHint(facts(triggerIsFn: false, globeKey: .systemDefault)))
        #expect(!SetupChecklist.globeHint(facts(hotkeyEnabled: false, globeKey: .action(2))))
        #expect(!SetupChecklist.globeHint(facts(globeKey: .doNothing)))
        #expect(!SetupChecklist.shows(facts(triggerIsFn: false, globeKey: .systemDefault)))
    }

    @Test func dismissedGlobeAdviceStaysAwayButSettingsStillKnows() {
        let f = facts(globeKey: .action(1), globeHintDismissed: true)
        #expect(!SetupChecklist.globeHint(f))
        #expect(missing(f).isEmpty)
        #expect(!SetupChecklist.rows(facts(speechModel: false, globeKey: .action(1), globeHintDismissed: true))
            .contains { $0.step == .globeKey })
        // Settings › 快捷键 keeps its row: the conflict is still there.
        #expect(SetupChecklist.globeKeyConflicts(f))
    }

    @Test func globeDismissalIsPerValue() {
        // The app stores the token it was dismissed for; a different value brings the advice back.
        #expect(GlobeKeyUsage.doNothing.token == 0)
        #expect(GlobeKeyUsage.systemDefault.token == -1)
        #expect(GlobeKeyUsage.action(2).token == 2)
        #expect(Set([GlobeKeyUsage.systemDefault, .action(1), .action(2), .action(3)].map(\.token)).count == 4)
    }

    @Test func globeTextSaysWhatThatValueDoes() {
        #expect(GlobeKeyText.title(.action(1)) == "fn 也会切换输入法")
        #expect(GlobeKeyText.sentence(.action(1)) == "每次按 fn，系统还会切换输入法。")
        #expect(GlobeKeyText.sentence(.action(2)) == "每次按 fn，系统还会打开表情与符号。")
        // 开始听写 fires only on a double press, so it never says "每次".
        #expect(GlobeKeyText.sentence(.action(3)) == "连按两下 fn 会打开系统听写。")
        #expect(GlobeKeyText.title(.action(3)).hasPrefix("连按两下"))
        // Unknown: the Mac's default, which depends on the keyboard.
        #expect(GlobeKeyText.sentence(.systemDefault).contains("可能"))
        #expect(GlobeKeyText.title(.systemDefault).contains("可能"))
        for usage in [GlobeKeyUsage.systemDefault, .action(1), .action(2), .action(3), .action(9)] {
            #expect(!GlobeKeyText.title(usage).isEmpty)
            #expect(GlobeKeyText.sentence(usage).hasSuffix("。"))
        }
        // The labels exactly as System Settings › 键盘 shows them.
        #expect(GlobeKeyText.fix.contains("“按下🌐\u{FE0E}键时”"))
        #expect(GlobeKeyText.fix.contains("“不执行任何操作”"))
        #expect(!GlobeKeyText.fix.contains("地球仪"))
    }

    @Test func chatGPTCountsOnlyWhenTheModePolishes() {
        // 原样转写 needs no ChatGPT: the row is advice then, so it neither counts nor keeps the card up.
        let raw = facts(chatGPTReady: false, polishes: false)
        #expect(missing(raw) == [.chatGPT])
        #expect(SetupChecklist.remaining(raw) == 0)
        #expect(!SetupChecklist.shows(raw))
        #expect(SetupChecklist.remaining(facts(chatGPTReady: false, polishes: true)) == 1)
        // Next to a real step it still shows in the card, uncounted.
        let both = facts(microphone: false, chatGPTReady: false, polishes: false)
        #expect(SetupChecklist.remaining(both) == 1)
        #expect(SetupChecklist.rows(both).first { $0.step == .chatGPT }?.counts == false)
    }

    @Test func hotkeyPendingCountsOnlyWithAccessibilityAndTheSwitchOn() {
        #expect(missing(facts(hotkeyRunning: false)) == [.hotkey])
        #expect(SetupChecklist.remaining(facts(hotkeyRunning: false)) == 1)
        #expect(missing(facts(accessibility: false, hotkeyRunning: false)) == [.accessibility])
        #expect(missing(facts(hotkeyEnabled: false, hotkeyRunning: false)).isEmpty)
    }

    @Test func signedOutIsAStepThatDoesNotBlockDictation() {
        // Dictation still works: it types the original.
        let signedOut = facts(chatGPTReady: false)
        #expect(SetupChecklist.remaining(signedOut) == 1)
        #expect(!SetupChecklist.blocksDictation(signedOut))
    }
}
