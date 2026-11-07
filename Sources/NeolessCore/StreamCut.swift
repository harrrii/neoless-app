import Foundation

/// Where a recording sent piece by piece while the user speaks (边说边传, docs/hub.md) is cut: in a pause, so no
/// word is split between two pieces and each is recognised on its own as well as the whole would be. How long a
/// piece is depends on the model (`Plan`): long enough that the speech model has context, short enough that what is
/// left once the user stops is a few seconds of work for the Neo.
public enum StreamCut {
    /// How long the pieces are.
    public struct Plan: Equatable, Sendable {
        /// No piece shorter than this.
        public var minSeconds: Double
        /// Past this, the piece is cut at its quietest moment even without a pause.
        public var maxSeconds: Double

        public init(minSeconds: Double, maxSeconds: Double) {
            self.minSeconds = minSeconds; self.maxSeconds = maxSeconds
        }

        /// 大模型: 20–45 s. The large model has a fixed cost of about 2 s a call and gains from context.
        public static let large = Plan(minSeconds: 20, maxSeconds: 45)
        /// 小模型 and 自动: 10–20 s. The small model has hardly any fixed cost (0.6 s for 3.8 s of audio, 2 s for
        /// 27.6 s on the Neo, 2026-11-06), so shorter pieces leave less for it once the user stops; much shorter
        /// would only add seams.
        public static let quick = Plan(minSeconds: 10, maxSeconds: 20)
    }

    /// The large model's (`Plan.large`).
    public static let minSeconds: Double = Plan.large.minSeconds
    public static let maxSeconds: Double = Plan.large.maxSeconds
    /// The frames compared, and how many quiet ones in a row make a pause (300 ms).
    public static let frameSeconds: Double = 0.1
    public static let pauseFrames = 3
    /// The newest audio is never cut into: a sound may be just starting there.
    public static let guardSeconds: Double = 0.3

    /// Where to cut `samples`, the audio not sent yet (it starts where the last piece ended): how many of its
    /// samples make the piece (counted from its start, whatever the slice's indices); nil to wait for more. In the
    /// middle of the longest pause after `plan.minSeconds` (frames quieter than a quarter of the piece's typical
    /// loudness, or than `AudioMath.speechRMS`); with no pause by `plan.maxSeconds`, at the quietest frame.
    public static func point(in samples: ArraySlice<Float>, sampleRate: Double, plan: Plan = .large) -> Int? {
        let frame = max(1, Int(sampleRate * frameSeconds))
        let first = samples.startIndex
        let usable = samples.count - Int(sampleRate * guardSeconds)
        let start = Int(sampleRate * plan.minSeconds)
        guard usable >= start + frame * pauseFrames else { return nil }
        let end = min(usable, Int(sampleRate * plan.maxSeconds))
        // Loudness of every frame of the piece, to judge what "quiet" is for this microphone and this room.
        var levels: [Float] = []
        levels.reserveCapacity(end / frame)
        var offset = 0
        while offset + frame <= end {
            levels.append(rms(samples[(first + offset)..<(first + offset + frame)]))
            offset += frame
        }
        let firstFrame = start / frame
        guard levels.count > firstFrame else { return nil }
        let typical = levels.sorted()[levels.count / 2]
        let quiet = max(AudioMath.speechRMS, typical * 0.25)
        // The longest run of quiet frames after `minSeconds`.
        var best: (start: Int, length: Int)?
        var run: Int?
        for index in firstFrame...levels.count {
            if index < levels.count, levels[index] < quiet {
                if run == nil { run = index }
                continue
            }
            if let begun = run {
                let length = index - begun
                if length >= pauseFrames, length > (best?.length ?? 0) { best = (begun, length) }
            }
            run = nil
        }
        if let best { return (best.start * frame) + (best.length * frame) / 2 }
        guard usable >= Int(sampleRate * plan.maxSeconds) else { return nil }
        let quietest = (firstFrame..<levels.count).min { levels[$0] < levels[$1] } ?? firstFrame
        return quietest * frame + frame / 2
    }

    public static func point(in samples: [Float], sampleRate: Double, plan: Plan = .large) -> Int? {
        point(in: samples[...], sampleRate: sampleRate, plan: plan)
    }

    static func rms(_ frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }
        var sum: Float = 0
        for value in frame { sum += value * value }
        return (sum / Float(frame.count)).squareRoot()
    }

    /// The pieces' transcripts as one: as they come for Chinese, with a space where two Latin words would meet.
    public static func join(_ pieces: [String]) -> String {
        var text = ""
        for piece in pieces {
            let piece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if let last = text.unicodeScalars.last, let next = piece.unicodeScalars.first,
               isLatin(last) && isLatin(next) || (CharacterSet.punctuationCharacters.contains(last) && last.isASCII && isLatin(next)) {
                text += " "
            }
            text += piece
        }
        return text
    }

    private static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
    }
}
