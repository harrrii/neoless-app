import Foundation
import Testing
@testable import NeolessCore

/// Where the wait after a recording went: kept with each history record (`DictationTimings`), and the quiet line under
/// a history entry (`TimingText.breakdown`).
@Suite struct TimingTests {
    private func record(recognizer: String? = "qwen3-asr", hubID: UUID? = UUID(), polished: Bool = true,
                        polishSeconds: TimeInterval? = 2.4, timings: DictationTimings?) -> DictationRecord {
        DictationRecord(duration: 10.4, raw: "嗯明天开会", polished: polished ? "明天开会。" : nil,
                        finalText: polished ? "明天开会。" : "嗯明天开会", appName: "微信", mode: .natural, model: nil,
                        polishSeconds: polished ? polishSeconds : nil, note: nil, delivery: .pasted, hubID: hubID,
                        recognizer: recognizer, timings: timings)
    }

    private let neo = DictationTimings(waitMs: 6_000, requestMs: 5_540, decodeMs: 20, asrMs: 3_100, polishMs: 2_400,
                                       totalMs: 5_240)

    // MARK: Kept

    @Test func aRecordFromBeforeTimingsStillReadsAndNewOnesRoundTrip() throws {
        let old = #"{"id":"11111111-2222-3333-4444-555555555555","date":0,"duration":3,"raw":"好","finalText":"好","mode":"natural","delivery":"pasted","hubID":"11111111-2222-3333-4444-555555555556","recognizer":"qwen3-asr","polishSeconds":1.5}"#
        let read = try JSONDecoder().decode(DictationRecord.self, from: Data(old.utf8))
        #expect(read.timings == nil && read.polishSeconds == 1.5 && read.recognizer == "qwen3-asr")
        #expect(TimingText.breakdown(read) == nil)

        let kept = record(timings: neo)
        let data = try JSONEncoder().encode(kept)
        #expect(try JSONDecoder().decode(DictationRecord.self, from: data) == kept)
        // What was not measured is left out, not written as null.
        let alone = record(recognizer: nil, hubID: nil, timings: DictationTimings(waitMs: 3_200))
        let json = String(decoding: try JSONEncoder().encode(alone), as: UTF8.self)
        #expect(json.contains(#""timings":{"waitMs":3200}"#))
        #expect(!json.contains("null"))
        // Without timings, no key at all: what older builds wrote.
        #expect(!String(decoding: try JSONEncoder().encode(record(timings: nil)), as: UTF8.self).contains("timings"))
    }

    @Test func timingsANewerBuildWroteDifferentlyAreLeftOutNotFatal() throws {
        let odd = #"{"id":"11111111-2222-3333-4444-555555555555","date":0,"duration":3,"raw":"好","finalText":"好","mode":"natural","delivery":"pasted","timings":"6 s"}"#
        let read = try JSONDecoder().decode(DictationRecord.self, from: Data(odd.utf8))
        #expect(read.timings == nil && read.finalText == "好")
        // Fields this build does not know are ignored.
        let newer = #"{"id":"11111111-2222-3333-4444-555555555555","date":0,"duration":3,"raw":"好","finalText":"好","mode":"natural","delivery":"pasted","timings":{"waitMs":900,"queueMs":4}}"#
        #expect(try JSONDecoder().decode(DictationRecord.self, from: Data(newer.utf8)).timings == DictationTimings(waitMs: 900))
    }

    @Test func millisecondsOfADuration() {
        #expect(DictationTimings.milliseconds(.seconds(3)) == 3_000)
        #expect(DictationTimings.milliseconds(.milliseconds(1_234)) == 1_234)
        #expect(DictationTimings.milliseconds(.microseconds(2_999)) == 2)
        #expect(DictationTimings.milliseconds(.seconds(-1)) == 0)
    }

    @Test func theUsageCountsDoNotCareAboutTimings() {
        var with = UsageStats(), without = UsageStats()
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        let counted = (with.add(record(timings: neo), timeZone: zone), without.add(record(timings: nil), timeZone: zone))
        #expect(counted == (true, true))
        #expect(with == without)
    }

    // MARK: Shown

    @Test func theNeoHeardAndPolishedIt() {
        let kept = record(timings: neo)
        #expect(TimingText.breakdown(kept) == "识别 3.1 秒 · 整理 2.4 秒 · 传输 0.3 秒 · 共 6.0 秒")
        // A narrow window: the way there and back is the first to go.
        #expect(TimingText.breakdown(kept, transfer: false) == "识别 3.1 秒 · 整理 2.4 秒 · 共 6.0 秒")
    }

    @Test func thisMacsTranscriptSaysSo() {
        // 本机识别: sent as text, the Neo only polished it.
        let fast = record(recognizer: "local", timings: DictationTimings(waitMs: 3_000, requestMs: 2_650, decodeMs: 0, asrMs: 0,
                                                                         polishMs: 2_400, totalMs: 2_410))
        #expect(TimingText.breakdown(fast) == "本机识别 · 整理 2.4 秒 · 传输 0.2 秒 · 共 3.0 秒")
        // The Neo was waited for, then the Mac's transcript was polished instead: how long it was waited for.
        let late = record(recognizer: "local", timings: DictationTimings(waitMs: 10_100, requestMs: 9_500, decodeMs: 30,
                                                                         asrMs: 6_660, polishMs: 2_400, totalMs: 9_100))
        #expect(TimingText.breakdown(late) == "本机识别（等了 Neo 6.7 秒） · 整理 2.4 秒 · 传输 0.4 秒 · 共 10.1 秒")
        // This Mac did all of it (the Neo not in use, or out of reach).
        let alone = record(recognizer: nil, hubID: nil, polishSeconds: 1.9, timings: DictationTimings(waitMs: 3_240))
        #expect(TimingText.breakdown(alone) == "本机识别 · 整理 1.9 秒 · 共 3.2 秒")
    }

    @Test func aPolishThatDidNotComeThroughStillTookItsTime() {
        // The Neo's ChatGPT timed out and its original was typed.
        let raw = record(polished: false, timings: DictationTimings(waitMs: 13_500, requestMs: 13_300, decodeMs: 20,
                                                                    asrMs: 2_000, polishMs: 10_000, totalMs: 12_900))
        #expect(TimingText.breakdown(raw) == "识别 2.0 秒 · 整理 10.0 秒 · 传输 0.4 秒 · 共 13.5 秒")
        // ... or this Mac polished it after all (the record keeps no Neo id): both polishes were waited for.
        let here = record(hubID: nil, polishSeconds: 1.5, timings: DictationTimings(waitMs: 15_000, requestMs: 13_300,
                                                                                    decodeMs: 20, asrMs: 2_000,
                                                                                    polishMs: 10_000, totalMs: 12_900))
        #expect(TimingText.breakdown(here) == "识别 2.0 秒 · 整理 11.5 秒 · 传输 0.4 秒 · 共 15.0 秒")
        // 原样转写: nothing was polished.
        let verbatim = record(polished: false, timings: DictationTimings(waitMs: 2_600, requestMs: 2_400, decodeMs: 20,
                                                                         asrMs: 2_000, polishMs: 0, totalMs: 2_100))
        #expect(TimingText.breakdown(verbatim) == "识别 2.0 秒 · 传输 0.3 秒 · 共 2.6 秒")
    }

    @Test func aNeoCallThatWasNotUsedStillTookItsTime() throws {
        // 自动, 10 s of audio: the Neo did not answer within this Mac's budget, so this Mac recognised and polished it
        // itself. The 35 s are the Neo's, not this Mac's recognition.
        let gaveUp = record(recognizer: nil, hubID: nil, polishSeconds: 2.0,
                            timings: DictationTimings(waitMs: 37_500, neoWaitMs: 35_000))
        #expect(TimingText.breakdown(gaveUp) == "等 Neo 35.0 秒（没用上） · 本机识别 · 整理 2.0 秒 · 共 37.5 秒")
        // The Neo heard nothing, and this Mac's transcript followed to `/v1/polish`: the first call is its own part,
        // the way there and back is the second one's.
        let followed = record(recognizer: "local", timings: DictationTimings(waitMs: 6_400, requestMs: 2_650, decodeMs: 0,
                                                                             asrMs: 0, polishMs: 2_400, totalMs: 2_410,
                                                                             neoWaitMs: 3_500))
        #expect(TimingText.breakdown(followed) == "等 Neo 3.5 秒（没用上） · 本机识别 · 整理 2.4 秒 · 传输 0.2 秒 · 共 6.4 秒")
        // A narrow window drops the way there and back, never the wait.
        #expect(TimingText.breakdown(followed, transfer: false) == "等 Neo 3.5 秒（没用上） · 本机识别 · 整理 2.4 秒 · 共 6.4 秒")
        // Kept with the record, and left out when there was none.
        let json = String(decoding: try JSONEncoder().encode(gaveUp), as: UTF8.self)
        #expect(json.contains(#""neoWaitMs":35000"#))
        #expect(!String(decoding: try JSONEncoder().encode(record(timings: neo)), as: UTF8.self).contains("neoWaitMs"))
        #expect(try JSONDecoder().decode(DictationRecord.self, from: JSONEncoder().encode(gaveUp)) == gaveUp)
    }

    @Test func onlyWhatWasMeasuredIsShown() {
        #expect(TimingText.breakdown(record(timings: DictationTimings())) == "整理 2.4 秒")
        #expect(TimingText.breakdown(record(recognizer: nil, hubID: nil, polished: false, timings: DictationTimings())) == "本机识别")
        // A call that seems shorter than the Neo's own work (clocks on two machines) says nothing about the way.
        let odd = DictationTimings(waitMs: 5_000, requestMs: 4_000, asrMs: 2_000, polishMs: 2_400, totalMs: 4_500)
        #expect(TimingText.breakdown(record(timings: odd)) == "识别 2.0 秒 · 整理 2.4 秒 · 共 5.0 秒")
    }
}
