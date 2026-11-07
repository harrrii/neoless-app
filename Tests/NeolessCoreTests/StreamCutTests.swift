import Foundation
import Testing
@testable import NeolessCore

/// 边说边传 cuts a recording in pauses (`StreamCut`).
@Suite struct StreamCutTests {
    static let rate = 16_000.0

    /// Speech-like sound (a tone with a little noise) with silence at `pauses` (start, length in seconds).
    static func recording(seconds: Double, pauses: [(Double, Double)] = [], room: Float = 0.0005) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            let quiet = pauses.contains { t >= $0.0 && t < $0.0 + $0.1 }
            let noise = Float.random(in: -room...room, using: &generator)
            return quiet ? noise : 0.2 * Float(sin(2 * .pi * 220 * t)) + noise
        }
    }

    @Test func noPieceBeforeTwentySeconds() {
        // A pause at 10 s is too early, and 19 s of sound is not enough yet.
        #expect(StreamCut.point(in: Self.recording(seconds: 19, pauses: [(10, 0.6)]), sampleRate: Self.rate) == nil)
    }

    @Test func itCutsInTheMiddleOfAPause() throws {
        let samples = Self.recording(seconds: 30, pauses: [(24, 0.6)])
        let point = try #require(StreamCut.point(in: samples, sampleRate: Self.rate))
        let seconds = Double(point) / Self.rate
        #expect(seconds > 24.1 && seconds < 24.5)
    }

    @Test func theLongestPauseWins() throws {
        let samples = Self.recording(seconds: 40, pauses: [(22, 0.35), (31, 1.0)])
        let point = try #require(StreamCut.point(in: samples, sampleRate: Self.rate))
        #expect(abs(Double(point) / Self.rate - 31.5) < 0.2)
    }

    @Test func aShortGapIsNoPause() {
        // 200 ms is a gap between words, not a place to cut; and no cut is forced before 45 s.
        #expect(StreamCut.point(in: Self.recording(seconds: 40, pauses: [(25, 0.2)]), sampleRate: Self.rate) == nil)
    }

    @Test func withoutAPauseItCutsAtFortyFiveSecondsAtTheQuietestMoment() throws {
        var samples = Self.recording(seconds: 46)
        // A softer stretch (still sound) at 33 s.
        for i in Int(33 * Self.rate)..<Int(33.1 * Self.rate) { samples[i] *= 0.3 }
        let point = try #require(StreamCut.point(in: samples, sampleRate: Self.rate))
        #expect(abs(Double(point) / Self.rate - 33.05) < 0.1)
    }

    @Test func aNoisyRoomStillHasPauses() throws {
        // The room hum is louder than `AudioMath.speechRMS`; quiet is judged against the piece itself.
        let samples = Self.recording(seconds: 30, pauses: [(26, 0.5)], room: 0.01)
        let point = try #require(StreamCut.point(in: samples, sampleRate: Self.rate))
        #expect(abs(Double(point) / Self.rate - 26.25) < 0.2)
    }

    @Test func theNewestAudioIsNotCutInto() {
        // The pause is still going on at the very end: it may be the start of a word that is cut off.
        #expect(StreamCut.point(in: Self.recording(seconds: 21.2, pauses: [(21.0, 0.2)]), sampleRate: Self.rate) == nil)
    }

    @Test func aSliceIsCountedFromItsStart() throws {
        let samples = Self.recording(seconds: 50, pauses: [(34, 0.6)])
        let start = Int(10 * Self.rate)
        let point = try #require(StreamCut.point(in: samples[start...], sampleRate: Self.rate))
        #expect(abs(Double(point) / Self.rate - 24.3) < 0.2)
    }

    @Test func piecesJoinAsOneText() {
        #expect(StreamCut.join(["第一段。", "第二段"]) == "第一段。第二段")
        #expect(StreamCut.join(["讲 Fisher", "effect 吧"]) == "讲 Fisher effect 吧")
        #expect(StreamCut.join(["OK,", "Cursor 打开"]) == "OK, Cursor 打开")
        #expect(StreamCut.join(["", " 只有这段 ", ""]) == "只有这段")
        #expect(StreamCut.join(["数字 3", "5 个"]) == "数字 3 5 个")
    }
}
