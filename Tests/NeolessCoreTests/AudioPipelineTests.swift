import Foundation
import Testing
@testable import NeolessCore

@Suite struct AccumulatorRegressionTests {
    private func run(_ steps: [(String, Bool)]) -> TranscriptAccumulator {
        var t = TranscriptAccumulator()
        for (text, ends) in steps { t.update(text, endsUtterance: ends) }
        return t
    }

    /// `steps`, then the final the recognizer sends after the user stopped.
    private func run(_ steps: [(String, Bool)], final: String) -> TranscriptAccumulator {
        var t = run(steps)
        t.update(final, isFinal: true)
        return t
    }

    // audio-3: revising the first word of a long partial is a revision, not a new sentence.

    @Test func firstWordHomophoneRevisionDoesNotDuplicate() {
        let t = run([("知道了我们明天去", false), ("只到了我们明天去北京", false)])
        #expect(t.text == "只到了我们明天去北京")
        #expect(t.segments.isEmpty)
    }

    @Test func englishFirstWordRevisionDoesNotDuplicate() {
        let t = run([("I think we should", false), ("Hi think we should go", false)])
        #expect(t.text == "Hi think we should go")
    }

    @Test func sameLengthSingleCharacterFixDoesNotDuplicate() {
        let t = run([("在我们明天去", false), ("再我们明天去", false)])
        #expect(t.text == "再我们明天去")
    }

    @Test func wholeShortPartialRewriteIsARevision() {
        let t = run([("四是四", false), ("事实是", false)])
        #expect(t.text == "事实是")
    }

    @Test func middleRevisionStaysOneSegment() {
        let t = run([("我们明天去工员", false), ("我们明天去公园了", false)])
        #expect(t.text == "我们明天去公园了")
    }

    // Restarts without metadata are still detected.

    @Test func unrelatedSentenceOfSimilarLengthStartsNewSegment() {
        let t = run([("我们明天上午去公园", false), ("然后再去吃饭吧好", false)])
        #expect(t.text == "我们明天上午去公园然后再去吃饭吧好")
        #expect(t.segments == ["我们明天上午去公园"])
    }

    @Test func restartSharingHalfTheSentenceStartsNewSegment() {
        // Different first character, and only half of the sentence survives: the next sentence.
        let t = run([("今天我们去公园玩", false), ("明天我们去学校", false)])
        #expect(t.text == "今天我们去公园玩明天我们去学校")
        #expect(t.segments == ["今天我们去公园玩"])
    }

    @Test func shrinkingRestartKeepsEarlierSentence() {
        let t = run([("我们明天上午十点去公园散步。", false), ("我", false), ("我觉得可以", false)])
        #expect(t.text == "我们明天上午十点去公园散步。我觉得可以")
    }

    // End-of-utterance metadata commits at once.

    @Test func metadataCommitsImmediately() {
        let t = run([("我们明天去公园。", true)])
        #expect(t.segments == ["我们明天去公园。"])
        #expect(t.current.isEmpty)
        #expect(t.text == "我们明天去公园。")
    }

    @Test func shortNewUtteranceAfterCommitIsKept() {
        let t = run([("今天天气很好。", true), ("好", false), ("好的", false)])
        #expect(t.text == "今天天气很好。好的")
    }

    // Final full-text replay is de-duplicated.

    @Test func finalReplayOfEverythingAfterCommittedUtterances() {
        let t = run([
            ("今天天气很好", false), ("今天天气很好我们出去玩", true),
            ("明天", false), ("明天开会讨论预算", true),
            ("今天天气很好我们出去玩 明天开会讨论预算", true),
        ])
        #expect(t.text == "今天天气很好我们出去玩 明天开会讨论预算")
    }

    @Test func finalReplayAfterPauseWithoutMetadataOnSecondSentence() {
        let t = run([("我们明天去公园。", true), ("然后", false), ("然后去吃饭。", false),
                     ("我们明天去公园。然后去吃饭。", true)])
        #expect(t.text == "我们明天去公园。然后去吃饭。")
    }

    @Test func finalRepeatingOnlyTheCommittedUtteranceIsIgnored() {
        let t = run([("我们明天去公园", true), ("然后去吃饭", false), ("我们明天去公园。", false)])
        #expect(t.text == "我们明天去公园然后去吃饭")
    }

    @Test func finalRepeatingTheLastUtteranceWithPunctuation() {
        let t = run([("我们明天去公园", true), ("我们明天去公园。", true)])
        #expect(t.text == "我们明天去公园。")
        #expect(t.segments.count == 1)
    }

    @Test func recognizerKeepsGrowingTheLastUtteranceAfterMetadata() {
        let t = run([("第一句话说完了。", true), ("我们明天", true), ("我们明天去公园", false)])
        #expect(t.text == "第一句话说完了。我们明天去公园")
    }

    @Test func finalRevisionOfCommittedUtteranceReplacesIt() {
        let t = run([("我们明天去工员", true), ("我们明天去公园。", true)])
        #expect(t.text == "我们明天去公园。")
    }

    // A replay of everything that also revised words is still a replay.

    @Test func revisedFinalReplayFixingTheLastSegmentHasNoDuplicate() {
        let t = run([("今天天气很好", true), ("我们明天去工员", true)], final: "今天天气很好。我们明天去公园。")
        #expect(t.text == "今天天气很好。我们明天去公园。")
    }

    @Test func revisedFinalReplayFixingAnEarlierSegmentHasNoDuplicate() {
        let t = run([("今天天汽很好", true), ("我们明天去公园", true), ("然后去吃饭", true)],
                    final: "今天天气很好。我们明天去公园。然后去吃饭。")
        #expect(t.text == "今天天气很好。我们明天去公园。然后去吃饭。")
    }

    @Test func reformattedFinalReplayHasNoDuplicate() {
        let t = run([("会议在三点开始", true), ("大家准时到", true)], final: "会议在3点开始。大家准时到。")
        #expect(t.text == "会议在3点开始。大家准时到。")
        let numbers = run([("我们有一百二十个人报名", true), ("大家准时到", true)], final: "我们有120个人报名。大家准时到。")
        #expect(numbers.text == "我们有120个人报名。大家准时到。")
    }

    @Test func revisedFinalReplayIncludingTheUtteranceUnderWay() {
        let t = run([("会议在三点开始", true), ("大家准时", false)], final: "会议在3点开始。大家准时到。")
        #expect(t.text == "会议在3点开始。大家准时到。")
    }

    @Test func finalReplayDroppingAFillerSegment() {
        let t = run([("今天天气很好", true), ("嗯", true), ("我们明天去公园", true)], final: "今天天气很好。我们明天去公园。")
        #expect(t.text == "今天天气很好。我们明天去公园。")
    }

    @Test func finalRevisingAndContinuingTheLastUtterance() {
        let t = run([("我们明天去工员", true)], final: "我们明天去公园，然后去吃饭。")
        #expect(t.text == "我们明天去公园，然后去吃饭。")
    }

    @Test func revisedReplayOfSeveralSegmentsInAPartial() {
        let t = run([("今天天气很好", true), ("我们明天去工员", true), ("今天天气很好我们明天去公园然后", false)])
        #expect(t.text == "今天天气很好我们明天去公园然后")
    }

    @Test func revisedReplayOfALongDictation() {
        // 40 utterances; the final fixes words in several of them and drops or adds characters.
        let words = Array("我们明天去公园然后吃饭今天天气很好大家准时到会议开始讨论预算下午见面")
        let sentences = (0..<40).map { (i: Int) -> String in
            let length = 8 + i % 9
            return String((0..<length).map { (j: Int) -> Character in words[(i * 7 + j * 3) % words.count] })
        }
        var t = TranscriptAccumulator()
        for s in sentences {
            t.update(String(s.prefix(3)))
            t.update(s + "。", endsUtterance: true)
        }
        var final = Array(sentences.joined(separator: "。"))
        final[20] = "改"
        final.remove(at: 150)
        final.insert(contentsOf: "插入", at: 300)
        final[final.count - 5] = "改"
        t.update(String(final), isFinal: true)
        #expect(t.text == String(final))
    }

    @Test func alignPrefixAllowsRevisedWords() {
        let a = TranscriptAccumulator.alignPrefix([Array("我们明天去工员")], Array("我们明天去公园然后"))
        #expect(a.matched == 5 && a.length == 7)
        let b = TranscriptAccumulator.alignPrefix([Array("一百二十个人"), Array("大家")], Array("120个人大家好"))
        #expect(b.matched == 4 && b.length == 7)
        let c = TranscriptAccumulator.alignPrefix([Array("嗯"), Array("我们")], Array("我们走"))
        #expect(c.matched == 2 && c.length == 2)
    }

    @Test func similarSentenceAsFirstResultAfterAFinalIsNotARevisedReplay() {
        var t = TranscriptAccumulator()
        t.update("我们明天去公园。", endsUtterance: true, isFinal: true)
        t.update("我们后天去公园然后去吃饭。", endsUtterance: true, isFinal: true)
        #expect(t.text == "我们明天去公园。我们后天去公园然后去吃饭。")
    }

    // A new utterance that starts with the whole previous one keeps both, once.

    @Test func newUtteranceRepeatingThePreviousOneAndGoingOnKeepsBoth() {
        let t = run([("我知道了。", true), ("我", false), ("我知道", false), ("我知道了", false), ("我知道了，谢谢", false)])
        #expect(t.segments == ["我知道了。"])
        #expect(t.text == "我知道了。我知道了，谢谢")
    }

    @Test func repeatedOpeningSkippingAPartialStillKeepsBoth() {
        let t = run([("我知道了。", true), ("我", false), ("我知道", false), ("我知道了，谢谢", false)])
        #expect(t.text == "我知道了。我知道了，谢谢")
    }

    @Test func repeatedOpeningThenFinalReplayHasNoDuplicate() {
        let t = run([("我知道了。", true), ("我", false), ("我知道", false), ("我知道了，谢谢", false),
                     ("我知道了。我知道了，谢谢。", true)])
        #expect(t.text == "我知道了。我知道了，谢谢。")
    }

    @Test func repeatedWordsArrivingInOnePartialKeepBoth() {
        // Partials jump from "我" straight to the committed words (知道了 is one token).
        let t = run([("我知道了。", true), ("我", false), ("我知道了", false), ("我知道了，谢谢", false)])
        #expect(t.segments == ["我知道了。"])
        #expect(t.text == "我知道了。我知道了，谢谢")
    }

    @Test func repeatedSentenceWithMetadataIsKept() {
        let t = run([("我知道了。", true), ("我", false), ("我知道了。", true), ("谢谢", false)])
        #expect(t.segments == ["我知道了。", "我知道了。"])
        #expect(t.text == "我知道了。我知道了。谢谢")
    }

    @Test func shortPartialThenFinalReplayOfEverything() {
        let t = run([("我知道了。", true), ("我", false)], final: "我知道了。我也是。")
        #expect(t.text == "我知道了。我也是。")
        let stray = run([("我们明天去公园", true), ("们", false)], final: "我们明天去公园。然后去吃饭。")
        #expect(stray.text == "我们明天去公园。然后去吃饭。")
    }

    @Test func misheardStartOfASimilarSentenceIsKept() {
        var t = TranscriptAccumulator()
        t.update("我们明天去公园", endsUtterance: true, isFinal: true)
        t.update("我门后")
        t.update("我们后天去公园。", endsUtterance: true, isFinal: true)
        t.update("然后")
        #expect(t.text == "我们明天去公园我们后天去公园。然后")
    }

    @Test func repeatedOpeningGrowsThroughRevisions() {
        let t = run([("我知道了。", true), ("我知道", false), ("我知道了我", false), ("我知道了我知", false),
                     ("我知道了，我知道你", false)])
        #expect(t.text == "我知道了。我知道了，我知道你")
    }

    @Test func freshTaskNeverReplaysEarlierSegments() {
        var t = TranscriptAccumulator()
        t.update("我知道了")
        t.startNewTask()
        t.update("我知道了，谢谢")
        #expect(t.text == "我知道了我知道了，谢谢")
        #expect(t.segments == ["我知道了"])
    }

    @Test func freshTaskStillDeduplicatesItsOwnReplays() {
        var t = TranscriptAccumulator()
        t.update("第一句。")
        t.startNewTask()
        t.update("我们明天", endsUtterance: true)
        t.update("我们明天去公园")
        #expect(t.text == "第一句。我们明天去公园")
    }

    // A repeated, similar sentence is not a revision of the one before it.

    @Test func similarNewSentenceAfterCommitIsKept() {
        let t = run([("我们明天去公园。", true), ("我们后天去公园", false)])
        #expect(t.text == "我们明天去公园。我们后天去公园")
    }

    @Test func similarSentenceBuiltUpFromPartialsIsKept() {
        let t = run([("我们明天去公园。", true), ("我们", false), ("我们后天", false), ("我们后天去公园。", true)])
        #expect(t.segments == ["我们明天去公园。", "我们后天去公园。"])
    }

    @Test func similarFinalAfterAFinalIsANewSentence() {
        var t = TranscriptAccumulator()
        t.update("我们明天去公园。", endsUtterance: true, isFinal: true)
        t.update("我们后天去公园。", endsUtterance: true, isFinal: true)
        #expect(t.text == "我们明天去公园。我们后天去公园。")
    }

    @Test func finalAfterStopStillRevisesTheLastUtterance() {
        var t = TranscriptAccumulator()
        t.update("我们明天去工员", endsUtterance: true)
        t.update("我们明天去公园。", isFinal: true)
        #expect(t.text == "我们明天去公园。")
    }

    @Test func freshTaskCannotReviseAnEarlierSegment() {
        var t = TranscriptAccumulator()
        t.update("我们明天去公园", endsUtterance: true)
        t.startNewTask()
        t.update("我们明天去工员。", endsUtterance: true, isFinal: true)
        #expect(t.text == "我们明天去公园我们明天去工员。")
    }

    @Test func manualCommitStartsNewSegment() {
        var t = TranscriptAccumulator()
        t.update("我们明天去公园")
        t.commit()
        t.update("我")
        t.update("我觉得可以")
        #expect(t.text == "我们明天去公园我觉得可以")
    }

    @Test func emptyAndPunctuationOnlyResultsAreIgnored() {
        let t = run([("我们明天", false), ("", false), ("。", false), ("  ", true)])
        #expect(t.text == "我们明天")
    }

    @Test func lcsIgnoresSharedPrefixAndSuffix() {
        #expect(TranscriptAccumulator.lcs(Array("abcxyz"), Array("abcqyz")) == 5)
        #expect(TranscriptAccumulator.lcs(Array("aa"), Array("a")) == 1)
        #expect(TranscriptAccumulator.lcs(Array(""), Array("abc")) == 0)
    }

    @Test func latinSentencePunctuationGetsASpace() {
        #expect(TextJoin.join(["We should go to the park.", "Then we eat."]) == "We should go to the park. Then we eat.")
        #expect(TextJoin.join(["我们去公园。", "然后吃饭"]) == "我们去公园。然后吃饭")
        #expect(TextJoin.join(["Version 2.", "中文"]) == "Version 2.中文")
    }
}

@Suite struct RecognitionTimingTests {
    @Test func liveFinishNeverShorterThanRequestedAndCapped() {
        #expect(abs(RecognitionTiming.liveFinish(requested: 4, audioSeconds: 20) - 5) < 1e-9)
        #expect(RecognitionTiming.liveFinish(requested: 4, audioSeconds: 0) == 4)
        #expect(RecognitionTiming.liveFinish(requested: 4, audioSeconds: 3600) == 12)
        #expect(RecognitionTiming.liveFinish(requested: 20, audioSeconds: 10) == 20)
    }

    @Test func secondPassIsBounded() {
        #expect(RecognitionTiming.secondPass(audioSeconds: 2) == 6)
        #expect(abs(RecognitionTiming.secondPass(audioSeconds: 20) - 12) < 1e-9)
        #expect(RecognitionTiming.secondPass(audioSeconds: 3600) == 30)
    }

    @Test func recoveryGrowsWithTheRecordingUpToTwoMinutes() {
        #expect(RecognitionTiming.recovery(audioSeconds: 2) == 6)
        #expect(abs(RecognitionTiming.recovery(audioSeconds: 20) - 12) < 1e-9)
        #expect(abs(RecognitionTiming.recovery(audioSeconds: 150) - 90) < 1e-9)
        #expect(RecognitionTiming.recovery(audioSeconds: 600) == 120)
        #expect(RecognitionTiming.recovery(audioSeconds: 600) > RecognitionTiming.secondPass(audioSeconds: 600))
    }

    @Test func restartBudgetGrowsWithTheAudio() {
        // life-long-recording-tail: four takeovers were not enough for a 10-minute dictation with pauses
        #expect(RecognitionTiming.restartBudget(audioSeconds: 0) == 4)
        #expect(RecognitionTiming.restartBudget(audioSeconds: 19) == 4)
        #expect(RecognitionTiming.restartBudget(audioSeconds: 60) == 7)
        #expect(RecognitionTiming.restartBudget(audioSeconds: 600) == 34)
        #expect(RecognitionTiming.restartBudget(audioSeconds: -5) == 4)
    }
}

@Suite struct SpeechErrorTextTests {
    @Test func noSpeechAndCancellationAreSilent() {
        #expect(SpeechErrorText.message(domain: "kAFAssistantErrorDomain", code: 1110, description: "No speech detected") == nil)
        #expect(SpeechErrorText.message(domain: "kAFAssistantErrorDomain", code: 216, description: "x") == nil)
        #expect(SpeechErrorText.message(domain: "kLSRErrorDomain", code: 301, description: "Recognition request was canceled") == nil)
        #expect(SpeechErrorText.isNoSpeech(domain: "kAFAssistantErrorDomain", code: 203))
        #expect(!SpeechErrorText.isNoSpeech(domain: "kLSRErrorDomain", code: 203))
    }

    @Test func knownErrorsAreChinese() {
        #expect(SpeechErrorText.message(domain: "kLSRErrorDomain", code: 201, description: "Siri and Dictation are disabled")
            == "需要打开听写：系统设置 › 键盘 › 听写")
        #expect(SpeechErrorText.message(domain: "kAFAssistantErrorDomain", code: 1101, description: "x")?.contains("没有响应") == true)
        #expect(SpeechErrorText.message(domain: "kAFAssistantErrorDomain", code: 1700, description: "x") != nil)
    }

    @Test func unknownEnglishErrorsShowOnlyTheCode() {
        #expect(SpeechErrorText.message(domain: "Foo", code: 7, description: "Something broke") == "错误代码 7")
        #expect(SpeechErrorText.message(domain: "Foo", code: 7, description: "识别服务出错") == "识别服务出错")
    }
}

@Suite struct AudioMathTests {
    private func sine(rms: Float, seconds: Double = 0.5) -> [Float] {
        let n = Int(16_000 * seconds)
        let amplitude = rms * 2.0.squareRoot().floatValue
        return (0..<n).map { amplitude * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }

    @Test func quietSpeechCounts() {
        #expect(AudioMath.hasSpeech(sine(rms: 0.005)))   // about -46 dBFS
        #expect(AudioMath.hasSpeech(sine(rms: 0.0035)))
    }

    @Test func silenceAndRoomNoiseDoNot() {
        #expect(!AudioMath.hasSpeech([Float](repeating: 0, count: 16_000)))
        #expect(!AudioMath.hasSpeech(sine(rms: 0.001)))   // -60 dBFS
        #expect(!AudioMath.hasSpeech([]))
        #expect(!AudioMath.hasSpeech(sine(rms: 0.05, seconds: 0.05)))   // shorter than one window
    }

    @Test func levelMapping() {
        #expect(AudioMath.normalizedLevel(rms: 0) == 0)
        #expect(AudioMath.normalizedLevel(rms: 1) == 1)
        #expect(AudioMath.normalizedLevel(rms: 0.0001) == 0)
    }
}

@Suite struct CaptureHealthTests {
    typealias S = CaptureHealth.Snapshot

    @Test func waitsForFirstBuffer() {
        #expect(CaptureHealth.check(S(engineStartedAt: 0, now: 1), device: .other, lidClosed: false) == .healthy)
        #expect(CaptureHealth.check(S(engineStartedAt: 0, now: 2.5), device: .other, lidClosed: false) == .noBuffers)
    }

    @Test func bluetoothGetsLongerToStart() {
        #expect(CaptureHealth.check(S(engineStartedAt: 0, now: 3), device: .bluetooth, lidClosed: false) == .healthy)
        #expect(CaptureHealth.check(S(engineStartedAt: 0, now: 4.6), device: .bluetooth, lidClosed: false) == .noBuffers)
    }

    @Test func builtInZerosSwitchDeviceQuickly() {
        let s = S(engineStartedAt: 0, firstBufferAt: 0.1, lastBufferAt: 0.9, now: 0.95)
        #expect(CaptureHealth.check(s, device: .builtIn, lidClosed: false) == .digitalSilence(switchDevice: true))
        let early = S(engineStartedAt: 0, firstBufferAt: 0.1, lastBufferAt: 0.5, now: 0.5)
        #expect(CaptureHealth.check(early, device: .builtIn, lidClosed: false) == .healthy)
    }

    @Test func otherDevicesMayGateSilenceLonger() {
        let s = S(engineStartedAt: 0, firstBufferAt: 0.1, lastBufferAt: 1.5, now: 1.5)
        #expect(CaptureHealth.check(s, device: .other, lidClosed: false) == .healthy)
        let later = S(engineStartedAt: 0, firstBufferAt: 0.1, lastBufferAt: 2.7, now: 2.7)
        #expect(CaptureHealth.check(later, device: .other, lidClosed: false) == .digitalSilence(switchDevice: false))
    }

    @Test func stallMidRecordingIsDetected() {
        let s = S(engineStartedAt: 0, firstBufferAt: 0.1, lastBufferAt: 30, lastSignalAt: 30, now: 31.6)
        #expect(CaptureHealth.check(s, device: .builtIn, lidClosed: false) == .stalled)
        let ok = S(engineStartedAt: 0, firstBufferAt: 0.1, lastBufferAt: 31, lastSignalAt: 31, now: 31.6)
        #expect(CaptureHealth.check(ok, device: .builtIn, lidClosed: false) == .healthy)
    }

    @Test func lidClosedMidRecordingSwitchesOnlyForBuiltIn() {
        let s = S(engineStartedAt: 0, firstBufferAt: 0.1, lastBufferAt: 20, lastSignalAt: 18, now: 20)
        #expect(CaptureHealth.check(s, device: .builtIn, lidClosed: true) == .lidClosed)
        #expect(CaptureHealth.check(s, device: .builtIn, lidClosed: false) == .healthy)
        #expect(CaptureHealth.check(s, device: .other, lidClosed: true) == .healthy)
    }

    // A closed lid is its own verdict, so the recorder does not remember the mic as dead.

    @Test func builtInZerosFromStartWithLidClosedAreNotADeadMic() {
        let s = S(engineStartedAt: 0, firstBufferAt: 0.1, lastBufferAt: 0.9, now: 0.95)
        #expect(CaptureHealth.check(s, device: .builtIn, lidClosed: true) == .lidClosed)
        #expect(CaptureHealth.check(s, device: .builtIn, lidClosed: false) == .digitalSilence(switchDevice: true))
    }

    @Test func lidStateIsOnlyAskedForABuiltInMicDeliveringZeros() {
        var asked = 0
        func lid() -> Bool { asked += 1; return true }
        let talking = S(engineStartedAt: 0, firstBufferAt: 0.1, lastBufferAt: 5, lastSignalAt: 5, now: 5)
        _ = CaptureHealth.check(talking, device: .builtIn, lidClosed: lid())
        let gated = S(engineStartedAt: 0, firstBufferAt: 0.1, lastBufferAt: 5, now: 5)
        _ = CaptureHealth.check(gated, device: .other, lidClosed: lid())
        #expect(asked == 0)
        let zeros = S(engineStartedAt: 0, firstBufferAt: 0.1, lastBufferAt: 1, now: 1)
        #expect(CaptureHealth.check(zeros, device: .builtIn, lidClosed: lid()) == .lidClosed)
        #expect(asked == 1)
    }

    // Gated mics (USB, Bluetooth) send exact zeros while nobody talks.

    @Test func gatedMicZerosAfterSignalAreAPause() {
        // After a restart (device change) the new engine has seen only zeros, but the
        // recording was heard before: the user is pausing, not a dead device.
        let s = S(engineStartedAt: 10, firstBufferAt: 10.1, lastBufferAt: 40, now: 40, heard: true)
        #expect(CaptureHealth.check(s, device: .other, lidClosed: false) == .healthy)
        #expect(CaptureHealth.check(s, device: .bluetooth, lidClosed: false) == .healthy)
        // The built-in mic has no gate: zeros there are still a dead mic.
        #expect(CaptureHealth.check(s, device: .builtIn, lidClosed: false) == .digitalSilence(switchDevice: true))
    }

    @Test func gatedMicBeforeFirstWordIsReopenedOnceThenWaited() {
        let first = S(engineStartedAt: 0, firstBufferAt: 0.1, lastBufferAt: 2.7, now: 2.7)
        #expect(CaptureHealth.check(first, device: .other, lidClosed: false) == .digitalSilence(switchDevice: false))
        // Reopened once: the user may simply be thinking. 8 s, 20 s: keep waiting.
        for t in [8.0, 20.0, 29.0] {
            let waiting = S(engineStartedAt: 0, firstBufferAt: 0.1, lastBufferAt: t, now: t, zeroRetries: 1)
            #expect(CaptureHealth.check(waiting, device: .other, lidClosed: false) == .healthy)
        }
        let gaveUp = S(engineStartedAt: 0, firstBufferAt: 0.1, lastBufferAt: 30.2, now: 30.2, zeroRetries: 1)
        #expect(CaptureHealth.check(gaveUp, device: .bluetooth, lidClosed: false) == .neverHeard)
    }

    @Test func stallIsStillDetectedOnAGatedMic() {
        let s = S(engineStartedAt: 0, firstBufferAt: 0.1, lastBufferAt: 12, now: 13.6, heard: true)
        #expect(CaptureHealth.check(s, device: .other, lidClosed: false) == .stalled)
    }

    // Configuration changes posted by our own restart.

    @Test func ownRestartConfigurationChangeIsNotARestart() {
        #expect(CaptureHealth.configurationChange(secondsSinceStart: 0.2, engineRunning: true, formatChanged: false) == .ignore)
        #expect(CaptureHealth.configurationChange(secondsSinceStart: 0.2, engineRunning: false, formatChanged: false) == .resume)
        #expect(CaptureHealth.configurationChange(secondsSinceStart: 0.2, engineRunning: false, formatChanged: true) == .restart)
        #expect(CaptureHealth.configurationChange(secondsSinceStart: 5, engineRunning: true, formatChanged: false) == .restart)
    }
}

@Suite struct InputChoiceTests {
    typealias C = InputChoice.Candidate
    let builtIn = C(uid: "mac", kind: .builtIn)
    let airPods = C(uid: "airpods", kind: .bluetooth)
    let usb = C(uid: "usb", kind: .other)

    @Test func autoPrefersTheBuiltInMic() {
        #expect(InputChoice.auto([airPods, builtIn], defaultUID: "airpods", lidClosed: false) == "mac")
        #expect(InputChoice.auto([airPods, usb], defaultUID: "airpods", lidClosed: false) == nil)
    }

    @Test func lidClosedUsesTheDefaultOrAnExternalMic() {
        #expect(InputChoice.auto([builtIn, airPods, usb], defaultUID: "airpods", lidClosed: true) == nil)
        #expect(InputChoice.auto([builtIn, airPods, usb], defaultUID: "mac", lidClosed: true) == "usb")
        #expect(InputChoice.auto([builtIn, airPods], defaultUID: "mac", lidClosed: true) == "airpods")
        #expect(InputChoice.auto([builtIn], defaultUID: "mac", lidClosed: true) == "mac")
    }

    @Test func lidClosedVirtualDefaultUsesAnExternalMic() {
        // A loopback driver (BlackHole) is the default: not among the candidates, and silent.
        #expect(InputChoice.auto([builtIn, airPods, usb], defaultUID: "blackhole", lidClosed: true) == "usb")
        #expect(InputChoice.auto([builtIn, airPods], defaultUID: "blackhole", lidClosed: true) == "airpods")
        #expect(InputChoice.auto([builtIn, usb], defaultUID: nil, lidClosed: true) == "usb")
        // Nothing else to record from: leave the system default alone.
        #expect(InputChoice.auto([builtIn], defaultUID: "blackhole", lidClosed: true) == nil)
    }

    @Test func noBuiltInMicSkipsAVirtualDefault() {
        #expect(InputChoice.auto([airPods, usb], defaultUID: "blackhole", lidClosed: false) == "usb")
        #expect(InputChoice.auto([airPods, usb], defaultUID: "usb", lidClosed: false) == nil)
        #expect(InputChoice.auto([], defaultUID: "blackhole", lidClosed: false) == nil)
    }

    @Test func silentMarkNeverMovesAutoToBluetooth() {
        let marked = C(uid: "mac", kind: .builtIn, markedSilent: true)
        #expect(InputChoice.auto([marked, airPods], defaultUID: "mac", lidClosed: false) == "mac")
        #expect(InputChoice.auto([marked, airPods], defaultUID: "airpods", lidClosed: false) == "mac")
        #expect(InputChoice.auto([marked, airPods, usb], defaultUID: "mac", lidClosed: false) == "usb")
        #expect(InputChoice.auto([marked, airPods, usb], defaultUID: "usb", lidClosed: false) == nil)
    }

    @Test func fallbackPrefersWiredThenBuiltInThenBluetooth() {
        // The failed device is the default: pick another one.
        #expect(InputChoice.fallback([builtIn, airPods, usb], from: "mac", defaultUID: "mac", lidClosed: true) == "usb")
        #expect(InputChoice.fallback([builtIn, airPods], from: "mac", defaultUID: "mac", lidClosed: true) == "airpods")
        #expect(InputChoice.fallback([builtIn, airPods, usb], from: "usb", defaultUID: "usb", lidClosed: false) == "mac")
        // The default is another usable device: use it.
        #expect(InputChoice.fallback([builtIn, airPods], from: "mac", defaultUID: "airpods", lidClosed: true) == nil)
        // The default is the closed-lid built-in mic: not usable.
        #expect(InputChoice.fallback([builtIn, airPods, usb], from: "usb", defaultUID: "mac", lidClosed: true) == "airpods")
        // Nothing else: the system default again.
        #expect(InputChoice.fallback([builtIn], from: "mac", defaultUID: "mac", lidClosed: false) == nil)
    }
}

private extension Double {
    var floatValue: Float { Float(self) }
}
