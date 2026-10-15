import Foundation
import Testing
@testable import NeolessCore

/// Feeds events one after another and keeps every effect.
private struct Run {
    var flow = CaptureFlow()

    @discardableResult
    mutating func callAsFunction(_ events: CaptureFlow.Event...) -> [CaptureFlow.Effect] {
        events.flatMap { flow.handle($0) }
    }
}

@Suite struct CaptureFlowTentativeTests {
    @Test func tentativeStartCapturesButShowsNothing() {
        var run = Run()
        #expect(run(.start(tentative: true)) == [.beginCapture])
        #expect(run.flow.isCapturing)
        #expect(run.flow.tentative)
        // Audio arriving while the press is unresolved still shows nothing.
        #expect(run(.audioArrived) == [])
        #expect(run.flow.stage == .recording)
    }

    @Test func shortcutDiscardsSilently() {
        var run = Run()
        run(.start(tentative: true), .audioArrived)
        #expect(run(.discard) == [.discard])
        #expect(run.flow.stage == .idle)
        #expect(!run.flow.isCapturing)
    }

    @Test func escapeBeforeResolutionIsSilentToo() {
        var run = Run()
        run(.start(tentative: true))
        #expect(run(.escape) == [.discard])
    }

    @Test func tapResolvesHandsFreeAndCommits() {
        var run = Run()
        run(.start(tentative: true))
        // Released as a tap: it can no longer be a shortcut.
        #expect(run(.handsFree) == [.reveal(.handsFree), .commit])
        #expect(run.flow.kind == .handsFree)
        #expect(!run.flow.shortcutPossible)
        #expect(run(.audioArrived) == [.showRecording])
    }

    @Test func holdRevealsAfterTheThresholdWithoutCommitting() {
        var run = Run()
        run(.start(tentative: true))
        // Shown, but Fn+← may still come: the last dictation's watch keeps running.
        #expect(run(.holdElapsed) == [.reveal(.hold)])
        #expect(run.flow.kind == .hold)
        #expect(run.flow.shortcutPossible)
        // A later hold timer changes nothing.
        #expect(run(.holdElapsed) == [])
    }

    @Test func holdAfterAudioRevealsWithRecording() {
        var run = Run()
        // Audio alone never reveals a press: only the hold threshold does.
        #expect(run(.start(tentative: true), .audioArrived) == [.beginCapture])
        #expect(run(.holdElapsed) == [.reveal(.hold), .showRecording])
    }

    @Test func handsFreeAfterAHoldRestylesAndCommits() {
        var run = Run()
        run(.start(tentative: true), .holdElapsed)
        #expect(run(.handsFree) == [.restyle(.handsFree), .commit])
        #expect(run(.handsFree) == [])
    }

    @Test func shortcutAfterTheRevealIsStillDroppedQuietly() {
        // Hold Fn, the capsule shows at the threshold, then ← within the chord window.
        var run = Run()
        let fx = run(.start(tentative: true), .audioArrived, .holdElapsed, .discard)
        #expect(fx == [.beginCapture, .reveal(.hold), .showRecording, .discard])
        #expect(!fx.contains(.commit))
        #expect(run.flow.stage == .idle)
    }

    @Test func shortcutWindowCommitsOnce() {
        var run = Run()
        run(.start(tentative: true), .holdElapsed)
        #expect(run(.shortcutWindowElapsed) == [.commit])
        #expect(!run.flow.shortcutPossible)
        #expect(run(.shortcutWindowElapsed, .handsFree) == [.restyle(.handsFree)])
    }

    @Test func discardAfterTheShortcutWindowIsAVisibleCancel() {
        var run = Run()
        run(.start(tentative: true), .holdElapsed, .shortcutWindowElapsed)
        #expect(run(.discard) == [.cancel])
    }

    @Test func escapeOnAShownHoldCancelsButNeverCommits() {
        var run = Run()
        let fx = run(.start(tentative: true), .holdElapsed, .escape)
        #expect(fx.last == .cancel)
        #expect(!fx.contains(.commit))
    }

    @Test func unresolvedPressAtTheShortcutWindowIsAHold() {
        var run = Run()
        run(.start(tentative: true))
        #expect(run(.shortcutWindowElapsed) == [.reveal(.hold), .commit])
    }

    @Test func toggleStartIsFinal() {
        var run = Run()
        #expect(run(.start(tentative: false)) == [.beginCapture, .reveal(.handsFree), .commit])
        #expect(!run.flow.tentative)
        #expect(!run.flow.shortcutPossible)
        #expect(run(.startClicked) == [])
        // Not a hotkey press that could be a shortcut: a discard is a real cancel.
        #expect(run(.discard) == [.cancel])
    }

    @Test func windowStartIsFinal() {
        var run = Run()
        #expect(run(.startClicked) == [.beginCapture, .reveal(.handsFree), .commit])
    }
}

@Suite struct CaptureFlowStopTests {
    @Test func stopWhileRecordingFinishes() {
        var run = Run()
        run(.start(tentative: false), .audioArrived)
        #expect(run(.stop) == [.finish(.user)])
        #expect(run.flow.stage == .processing)
        #expect(!run.flow.isCapturing)
    }

    @Test func holdReleaseRevealsThenFinishes() {
        var run = Run()
        run(.start(tentative: true), .audioArrived)
        #expect(run(.stop) == [.reveal(.hold), .showRecording, .commit, .finish(.user)])
    }

    @Test func releaseOfAShownHoldCommitsThenFinishes() {
        var run = Run()
        run(.start(tentative: true), .audioArrived, .holdElapsed)
        #expect(run(.stop) == [.commit, .finish(.user)])
    }

    @Test func tentativeStopBeforeAudioCommitsAndWaits() {
        var run = Run()
        run(.start(tentative: true))
        #expect(run(.stop) == [.reveal(.hold), .commit, .armLateStop])
        #expect(run(.audioArrived) == [.showRecording, .finish(.lateStop)])
    }

    @Test func earlyStopWaitsForAudio() {
        var run = Run()
        run(.start(tentative: false))
        #expect(run(.stop) == [.armLateStop])
        #expect(run.flow.stopRequested)
        // A second stop does not arm the limit again.
        #expect(run(.confirmClicked) == [])
        #expect(run(.audioArrived) == [.showRecording, .finish(.lateStop)])
        #expect(run.flow.stage == .processing)
    }

    @Test func earlyStopWithoutAudioCancelsAfterTheLimit() {
        var run = Run()
        run(.start(tentative: false), .stop)
        #expect(run(.lateStopElapsed) == [.cancel])
        #expect(run.flow.stage == .idle)
    }

    @Test func lateStopLimitIsIgnoredOnceAudioCame() {
        var run = Run()
        run(.start(tentative: false), .stop, .audioArrived)
        #expect(run(.lateStopElapsed) == [])
    }

    @Test func confirmDiscDuringWarmUpActsLikeStop() {
        var run = Run()
        run(.startClicked)
        #expect(run(.confirmClicked) == [.armLateStop])
        #expect(run(.audioArrived) == [.showRecording, .finish(.lateStop)])
    }

    @Test func capFinishesTheRecording() {
        var run = Run()
        run(.start(tentative: false), .audioArrived)
        #expect(run(.capReached) == [.finish(.cap)])
    }

    @Test func capWhileStartingDoesNothing() {
        var run = Run()
        run(.start(tentative: false))
        #expect(run(.capReached) == [])
    }
}

@Suite struct CaptureFlowProcessingTests {
    private func processing() -> Run {
        var run = Run()
        run(.start(tentative: false), .audioArrived, .stop)
        return run
    }

    @Test func startIsIgnoredWhileProcessing() {
        var run = processing()
        #expect(run(.start(tentative: true), .start(tentative: false), .startClicked) == [])
        #expect(run.flow.stage == .processing)
    }

    @Test func hotkeyStopsAndDiscardsAreIgnoredWhileProcessing() {
        var run = processing()
        #expect(run(.stop, .handsFree, .discard, .confirmClicked, .holdElapsed, .shortcutWindowElapsed) == [])
    }

    @Test func escapeKeepsTheResultWithoutPasting() {
        var run = processing()
        #expect(run(.escape) == [.keepWithoutPaste])
        #expect(run.flow.stage == .idle)
        // A new dictation can start right away.
        #expect(run(.start(tentative: true)) == [.beginCapture])
    }

    @Test func cancelButtonWhileProcessingKeepsTheResultToo() {
        var run = processing()
        #expect(run(.cancelClicked) == [.keepWithoutPaste])
    }

    @Test func deliveredGoesIdle() {
        var run = processing()
        #expect(run(.delivered) == [])
        #expect(run.flow.stage == .idle)
    }

    @Test func escapeIsConsumedForTheWholeDictation() {
        // life-esc-processing: an Esc that stops neoless must not also reach the app (Codex, ChatGPT…)
        var run = Run()
        #expect(!run.flow.consumesEscape)
        run(.start(tentative: true))
        #expect(run.flow.consumesEscape)
        run(.handsFree, .audioArrived, .stop)
        #expect(run.flow.stage == .processing)
        #expect(run.flow.consumesEscape)
        run(.delivered)
        #expect(!run.flow.consumesEscape)
    }

    @Test func escapeIsReleasedOnceThePasteIsCancelled() {
        var run = processing()
        #expect(run(.escape) == [.keepWithoutPaste])
        // The take finishes in the background; the next Esc belongs to the app again.
        #expect(!run.flow.consumesEscape)
    }
}

@Suite struct CaptureFlowCommandTests {
    @Test func menuFinishesWhileCapturingAndCancelsOnlyThePasteWhileProcessing() {
        var run = Run()
        #expect(run.flow.menuCommand == .start)
        #expect(run.flow.menuCommand.event == .startClicked)
        run(.startClicked)
        #expect(run.flow.menuCommand == .finish)
        // 结束听写 while the microphone opens finishes once audio arrives, like ✓.
        #expect(run(run.flow.menuCommand.event) == [.armLateStop])
        run(.audioArrived)
        #expect(run.flow.stage == .processing)
        #expect(run.flow.menuCommand == .cancelPaste)
        #expect(run(run.flow.menuCommand.event) == [.keepWithoutPaste])
    }

    @Test func menuFinishWhileRecordingProcesses() {
        var run = Run()
        run(.startClicked, .audioArrived)
        #expect(run.flow.menuCommand == .finish)
        #expect(run(run.flow.menuCommand.event) == [.finish(.user)])
    }

    @Test func menuTitles() {
        #expect(CaptureFlow.MenuCommand.start.title == "开始听写")
        #expect(CaptureFlow.MenuCommand.finish.title == "结束听写")
        #expect(CaptureFlow.MenuCommand.cancelPaste.title == "取消输入")
        #expect(CaptureFlow.MenuCommand(rawValue: CaptureFlow.MenuCommand.cancelPaste.rawValue) == .cancelPaste)
    }

    @Test func windowButtonFollowsItsIcon() {
        var run = Run()
        #expect(run.flow.buttonEvent == .startClicked)
        run(.startClicked)
        // × while the microphone opens.
        #expect(run.flow.buttonEvent == .cancelClicked)
        run(.audioArrived)
        // ■ while recording.
        #expect(run.flow.buttonEvent == .confirmClicked)
        run(.stop)
        // × while processing: stops the paste only.
        #expect(run.flow.buttonEvent == .cancelClicked)
        #expect(run(run.flow.buttonEvent) == [.keepWithoutPaste])
    }
}

@Suite struct CaptureFlowFailureTests {
    @Test func failureAfterRealSoundSalvages() {
        var run = Run()
        run(.start(tentative: false), .audioArrived)
        #expect(run(.captureFailed(heardSignal: true)) == [.finish(.salvage)])
        #expect(run.flow.stage == .processing)
    }

    @Test func failureWithoutSoundFails() {
        var run = Run()
        run(.start(tentative: false), .audioArrived)
        #expect(run(.captureFailed(heardSignal: false)) == [.fail])
        #expect(run.flow.stage == .idle)
    }

    @Test func failureWhileStartingFails() {
        var run = Run()
        run(.startClicked)
        #expect(run(.captureFailed(heardSignal: false)) == [.fail])
    }

    @Test func tentativeFailureWaitsForThePressToResolve() {
        var run = Run()
        run(.start(tentative: true))
        #expect(run(.captureFailed(heardSignal: false)) == [])
        #expect(run(.holdElapsed) == [.fail])
        #expect(run.flow.stage == .idle)
        #expect(run(.shortcutWindowElapsed) == [])
    }

    @Test func tentativeFailureThenShortcutShowsNothing() {
        var run = Run()
        run(.start(tentative: true), .captureFailed(heardSignal: false))
        #expect(run(.discard) == [.discard])
    }

    @Test func tentativeFailureThenReleaseShowsTheError() {
        var run = Run()
        run(.start(tentative: true), .captureFailed(heardSignal: false))
        #expect(run(.stop) == [.fail])
        #expect(run.flow.stage == .idle)
    }

    @Test func tentativeFailureAfterSoundWaitsForThePress() {
        // life-tentative-salvage: nothing is shown or committed while the press may be Fn+←
        var run = Run()
        run(.start(tentative: true), .audioArrived)
        #expect(run(.captureFailed(heardSignal: true)) == [])
        #expect(run.flow.salvagePending)
        #expect(run.flow.stage == .recording)
        // Released as a tap: a dictation after all, so what was recorded is processed.
        #expect(run(.handsFree) == [.reveal(.handsFree), .showRecording, .commit, .finish(.salvage)])
        #expect(run.flow.stage == .processing)
        #expect(!run.flow.salvagePending)
    }

    @Test func tentativeSalvageThenShortcutIsDroppedQuietly() {
        var run = Run()
        run(.start(tentative: true), .audioArrived, .captureFailed(heardSignal: true))
        #expect(run(.discard) == [.discard])
        #expect(run.flow.stage == .idle)
        #expect(!run.flow.salvagePending)
        #expect(run(.handsFree) == [])
    }

    @Test func tentativeSalvageThenEscapeIsDroppedQuietly() {
        var run = Run()
        run(.start(tentative: true), .audioArrived, .captureFailed(heardSignal: true))
        #expect(run(.escape) == [.discard])
    }

    @Test func tentativeSalvageThenReleaseOfAHoldFinishes() {
        var run = Run()
        run(.start(tentative: true), .audioArrived, .captureFailed(heardSignal: true))
        #expect(run(.stop) == [.reveal(.hold), .showRecording, .commit, .finish(.salvage)])
    }

    @Test func salvageOnAShownHoldWaitsForTheShortcutWindow() {
        var run = Run()
        #expect(run(.start(tentative: true), .audioArrived, .holdElapsed) == [.beginCapture, .reveal(.hold), .showRecording])
        // Still possibly a shortcut: the last dictation's watch keeps running.
        #expect(run(.captureFailed(heardSignal: true)) == [])
        #expect(run(.holdElapsed) == [])
        #expect(run(.shortcutWindowElapsed) == [.commit, .finish(.salvage)])
    }

    @Test func salvageOnAShownHoldThenShortcutIsDroppedQuietly() {
        var run = Run()
        run(.start(tentative: true), .audioArrived, .holdElapsed, .captureFailed(heardSignal: true))
        #expect(run(.discard) == [.discard])
    }

    @Test func committedFailureAfterSoundSalvagesAtOnce() {
        var run = Run()
        run(.start(tentative: true), .handsFree, .audioArrived)
        #expect(run(.captureFailed(heardSignal: true)) == [.finish(.salvage)])
    }

    @Test func failureNoteWording() {
        #expect(FinishReason.user.note == nil)
        #expect(FinishReason.lateStop.note == nil)
        #expect(FinishReason.salvage.note != nil)
        #expect(FinishReason.cap.note?.contains("10 分钟") == true)
        // The same words as the capsule's notice when nobody spoke at all.
        #expect(FinishReason.silence.note == "一分钟没听到说话，已自动结束")
        #expect(CaptureText.nobodySpoke == FinishReason.silence.note)
    }

    @Test func onlyRecordingsThatEndedOnTheirOwnStayWithTheirApp() {
        // audio-5: a cap or a long silence may come long after the user moved on
        #expect(FinishReason.cap.pastesOnlyWhereStarted)
        #expect(FinishReason.silence.pastesOnlyWhereStarted)
        #expect(!FinishReason.user.pastesOnlyWhereStarted)
        #expect(!FinishReason.lateStop.pastesOnlyWhereStarted)
        #expect(!FinishReason.salvage.pastesOnlyWhereStarted)
    }
}

@Suite struct CaptureFlowSilenceTests {
    private func handsFree() -> Run {
        var run = Run()
        run(.start(tentative: true), .handsFree, .audioArrived)
        return run
    }

    @Test func silenceAfterSpeechFinishes() {
        var run = handsFree()
        #expect(run(.silenceElapsed(heardSpeech: true)) == [.finish(.silence)])
        #expect(run.flow.stage == .processing)
    }

    @Test func nobodySpeakingStopsWithoutKeepingAnything() {
        var run = handsFree()
        #expect(run(.silenceElapsed(heardSpeech: false)) == [.nobodySpoke])
        #expect(run.flow.stage == .idle)
        #expect(!run.flow.consumesEscape)
    }

    @Test func aHeldKeyIsSomeoneStillThere() {
        var run = Run()
        run(.start(tentative: true), .audioArrived, .holdElapsed, .shortcutWindowElapsed)
        #expect(run.flow.kind == .hold)
        #expect(run(.silenceElapsed(heardSpeech: false), .silenceElapsed(heardSpeech: true)) == [])
        #expect(run.flow.stage == .recording)
    }

    @Test func aPressThatMayBeAShortcutIsLeftAlone() {
        var run = Run()
        run(.start(tentative: true), .audioArrived)
        #expect(run(.silenceElapsed(heardSpeech: false)) == [])
    }

    @Test func ignoredWhileStartingOrProcessing() {
        var run = Run()
        run(.startClicked)
        #expect(run(.silenceElapsed(heardSpeech: true)) == [])
        run(.audioArrived, .stop)
        #expect(run(.silenceElapsed(heardSpeech: true)) == [])
        #expect(run.flow.stage == .processing)
    }

    @Test func windowAndToggleStartsAreHandsFree() {
        var run = Run()
        run(.startClicked, .audioArrived)
        #expect(run(.silenceElapsed(heardSpeech: true)) == [.finish(.silence)])
    }
}

@Suite struct SilenceWatchTests {
    /// Levels every 50 ms from `from` for `seconds`; whether the last one found it quiet.
    private func feed(_ watch: inout SilenceWatch, level: Float, from: TimeInterval, seconds: TimeInterval) -> Bool {
        var quiet = false
        var t = from
        while t < from + seconds {
            quiet = watch.level(level, at: t)
            t += 0.05
        }
        return quiet
    }

    @Test func aMinuteOfQuietEndsIt() {
        var watch = SilenceWatch(startedAt: 0)
        let early = feed(&watch, level: 0, from: 0, seconds: 59.5)
        let late = watch.level(0, at: 60)
        #expect(!early && late)
        #expect(!watch.heardSpeech)
    }

    @Test func speechRestartsTheMinute() {
        var watch = SilenceWatch(startedAt: 0)
        let talking = feed(&watch, level: 0.5, from: 0, seconds: 2)
        #expect(!talking && watch.heardSpeech)
        let early = feed(&watch, level: 0, from: 2, seconds: 59.5)
        let late = watch.level(0, at: 62)
        #expect(!early && late)
    }

    @Test func aClickIsNotSpeech() {
        var watch = SilenceWatch(startedAt: 0)
        _ = watch.level(0.9, at: 30)
        _ = watch.level(0.9, at: 30.05)
        _ = watch.level(0, at: 30.1)
        #expect(!watch.heardSpeech)
        let quiet = watch.level(0, at: 60)
        #expect(quiet)
    }

    @Test func aQuietRoomIsQuiet() {
        // a quiet room on a laptop mic is near -60 dBFS; speech starts around -50
        var watch = SilenceWatch(startedAt: 0)
        let room = AudioMath.normalizedLevel(rms: 0.001)
        #expect(room < SilenceWatch.speechLevel)
        let early = feed(&watch, level: room, from: 0, seconds: 59)
        let late = watch.level(room, at: 60)
        #expect(!early && late)
        #expect(SilenceWatch.limit == 60)
    }
}

@Suite struct SecondPassPlanTests {
    @Test func emptyOrLostLiveTextGetsTheLongerRecovery() {
        #expect(SecondPass.budget(live: "", diedEarly: false, lostAudio: false, hasSpeech: true, audioSeconds: 20)
                == RecognitionTiming.recovery(audioSeconds: 20))
        // life-long-recording-tail: the live session gave up 3 minutes into a 10-minute dictation
        #expect(SecondPass.budget(live: "前三分钟", diedEarly: true, lostAudio: true, hasSpeech: true, audioSeconds: 600) == 120)
    }

    @Test func aRestartedSessionIsCheckedOnlyWhenThePassCanFinish() {
        #expect(SecondPass.budget(live: "你好", diedEarly: true, lostAudio: false, hasSpeech: true, audioSeconds: 20)
                == RecognitionTiming.secondPass(audioSeconds: 20))
        #expect(SecondPass.budget(live: "你好", diedEarly: true, lostAudio: false, hasSpeech: true, audioSeconds: 120) != nil)
        // a long dictation stitched across restarts keeps its live text instead of waiting
        #expect(SecondPass.budget(live: "你好", diedEarly: true, lostAudio: false, hasSpeech: true, audioSeconds: 300) == nil)
    }

    @Test func nothingToRecover() {
        #expect(SecondPass.budget(live: "你好", diedEarly: false, lostAudio: false, hasSpeech: true, audioSeconds: 20) == nil)
        #expect(SecondPass.budget(live: "", diedEarly: true, lostAudio: true, hasSpeech: false, audioSeconds: 20) == nil)
    }

    @Test func incompleteWhenNothingWholeReplacedLostAudio() {
        #expect(SecondPass.incomplete(lostAudio: true, secondWon: false, secondComplete: false))
        #expect(SecondPass.incomplete(lostAudio: true, secondWon: false, secondComplete: true))
        #expect(!SecondPass.incomplete(lostAudio: true, secondWon: true, secondComplete: true))
        #expect(SecondPass.incomplete(lostAudio: false, secondWon: true, secondComplete: false))
        #expect(!SecondPass.incomplete(lostAudio: false, secondWon: false, secondComplete: false))
        #expect(CaptureText.incomplete.contains("不完整"))
    }

    @Test func shortRecordingsAreOnePiece() {
        #expect(SecondPass.pieces([Float](repeating: 0.1, count: 100), sampleRate: 10) == [0..<100])
        #expect(SecondPass.pieces([], sampleRate: 10).isEmpty)
    }

    @Test func longRecordingsAreCutAtTheQuietestMoment() {
        // 10 Hz: 30 s pieces are 300 samples, the search covers their last 100, windows are 1 sample
        var samples = [Float](repeating: 0.2, count: 700)
        samples[250] = 0       // a pause 25 s in
        samples[520] = 0.01    // the quietest moment in the next piece's last 10 s
        let pieces = SecondPass.pieces(samples, sampleRate: 10)
        #expect(pieces == [0..<250, 250..<520, 520..<700])
        // every sample once, in order
        #expect(pieces.map(\.count).reduce(0, +) == samples.count)
    }

    @Test func noPauseCutsAtTheLimit() {
        let pieces = SecondPass.pieces([Float](repeating: 0.2, count: 650), sampleRate: 10)
        #expect(pieces.allSatisfy { $0.count <= 300 && !$0.isEmpty })
        #expect(pieces.first?.lowerBound == 0 && pieces.last?.upperBound == 650)
    }
}

@Suite struct SecondPassTests {
    @Test func emptyLiveTakesTheSecondPass() {
        #expect(SecondPass.choose(live: "", second: "明天下午三点开会", liveDiedEarly: false) == "明天下午三点开会")
    }

    @Test func emptySecondKeepsLive() {
        #expect(SecondPass.choose(live: "明天开会", second: "", liveDiedEarly: true) == "明天开会")
    }

    @Test func supersetWins() {
        let live = "明天下午三点开会"
        let second = "明天下午三点开会，记得带电脑。"
        #expect(SecondPass.choose(live: live, second: second, liveDiedEarly: false) == second)
    }

    @Test func punctuationDifferencesStillCountAsSuperset() {
        let live = "明天下午，三点开会。"
        let second = "明天下午三点开会，在三楼"
        #expect(SecondPass.choose(live: live, second: second, liveDiedEarly: false) == second)
    }

    @Test func longerButDifferentLosesWhenLiveDidNotDie() {
        let live = "我们明天下午三点开会"
        let second = "我们明天下午商量开会的事情吧"
        #expect(SecondPass.choose(live: live, second: second, liveDiedEarly: false) == live)
    }

    @Test func clearlyLongerWinsWhenLiveDiedEarly() {
        let live = "我们明天下午三点开会"
        let second = "我们明天下午开会然后讨论预算的事情"
        #expect(SecondPass.choose(live: live, second: second, liveDiedEarly: true) == second)
    }

    @Test func barelyLongerLosesEvenWhenLiveDiedEarly() {
        let live = "我们明天下午三点开会讨论"
        let second = "我们明天下午三点钟开会讨"
        #expect(SecondPass.choose(live: live, second: second, liveDiedEarly: true) == live)
    }

    @Test func shorterSecondNeverWins() {
        #expect(SecondPass.choose(live: "明天下午三点开会", second: "明天开会", liveDiedEarly: true) == "明天下午三点开会")
    }

    @Test func duplicatedSecondPassNeverWins() {
        let live = "明天下午三点在会议室开会"
        let second = "明天下午三点在会议室开会明天下午三点在会议室开会"
        #expect(SecondPass.choose(live: live, second: second, liveDiedEarly: true) == live)
        #expect(SecondPass.choose(live: live, second: second, liveDiedEarly: false) == live)
    }

    @Test func partlyDuplicatedSecondPassNeverWins() {
        let live = "第一件事是预算，第二件事是招聘"
        let second = "第一件事是预算，第一件事是预算，第二件事是招聘"
        #expect(SecondPass.choose(live: live, second: second, liveDiedEarly: true) == live)
    }

    @Test func naturalRepetitionAfterOtherWordsStillWins() {
        let live = "请把这个文件发给张三"
        let second = "请把这个文件发给张三，然后把这个文件发给李四"
        #expect(SecondPass.choose(live: live, second: second, liveDiedEarly: true) == second)
        let live2 = "明天下午三点开会"
        let second2 = "明天下午三点开会，后天下午三点开会也可以"
        #expect(SecondPass.choose(live: live2, second: second2, liveDiedEarly: true) == second2)
    }

    @Test func replayWithPunctuationBetweenNeverWins() {
        let live = "第一件事是预算，第二件事是招聘"
        let second = "第一件事是预算。第一件事是预算，第二件事是招聘，"
        #expect(SecondPass.choose(live: live, second: second, liveDiedEarly: true) == live)
    }

    @Test func repetitionTheLiveTextHasTooIsFine() {
        let live = "好的好的好的好的好的好的"
        let second = "好的好的好的好的好的好的好的"
        #expect(SecondPass.choose(live: live, second: second, liveDiedEarly: true) == second)
    }

    @Test func englishIsComparedWithoutCaseOrSpaces() {
        let live = "open the README"
        let second = "Open the readme file please"
        #expect(SecondPass.choose(live: live, second: second, liveDiedEarly: false) == second)
    }

    @Test func repeatDetection() {
        #expect(SecondPass.repeatsPassage(Array("abcdefabcdef")))
        #expect(!SecondPass.repeatsPassage(Array("abcdefghijkl")))
        #expect(!SecondPass.repeatsPassage(Array("abcab")))
        #expect(SecondPass.repeatsPassage(Array("xyabcdefabcdefzz")))
        // The same words again after other words are not a replay.
        #expect(!SecondPass.repeatsPassage(Array("abcdefxyzabcdef")))
        #expect(!SecondPass.repeatsPassage(Array("abcdefgabcdefh")))
    }
}
