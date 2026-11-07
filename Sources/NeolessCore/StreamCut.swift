import Foundation

/// Where a recording sent piece by piece while the user speaks (边说边传, docs/hub.md) is cut: in a pause, so no
/// word is split between two pieces and each is recognised on its own as well as the whole would be. A piece is
/// 20–45 s: long enough that the speech model has context and a recording of ten minutes is about twenty pieces,
/// short enough that what is left once the user stops is a few seconds of work for the Neo.
public enum StreamCut {
    /// No piece shorter than this.
    public static let minSeconds: Double = 20
    /// Past this, the piece is cut at its quietest moment even without a pause.
    public static let maxSeconds: Double = 45
    /// The frames compared, and how many quiet ones in a row make a pause (300 ms).
    public static let frameSeconds: Double = 0.1
    public static let pauseFrames = 3
    /// The newest audio is never cut into: a sound may be just starting there.
    public static let guardSeconds: Double = 0.3

    /// Where to cut `samples`, the audio not sent yet (it starts where the last piece ended): how many of its
    /// samples make the piece (counted from its start, whatever the slice's indices); nil to wait for more. In the middle of the longest pause after `minSeconds`
    /// (frames quieter than a quarter of the piece's typical loudness, or than `AudioMath.speechRMS`); with no pause
    /// by `maxSeconds`, at the quietest frame.
    public static func point(in samples: ArraySlice<Float>, sampleRate: Double) -> Int? {
        let frame = max(1, Int(sampleRate * frameSeconds))
        let first = samples.startIndex
        let usable = samples.count - Int(sampleRate * guardSeconds)
        let start = Int(sampleRate * minSeconds)
        guard usable >= start + frame * pauseFrames else { return nil }
        let end = min(usable, Int(sampleRate * maxSeconds))
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
        guard usable >= Int(sampleRate * maxSeconds) else { return nil }
        let quietest = (firstFrame..<levels.count).min { levels[$0] < levels[$1] } ?? firstFrame
        return quietest * frame + frame / 2
    }

    public static func point(in samples: [Float], sampleRate: Double) -> Int? {
        point(in: samples[...], sampleRate: sampleRate)
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
