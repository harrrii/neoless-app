import Foundation

/// Joins transcript pieces the way a person would type them: no space between
/// Chinese pieces, one space between two Latin words, and one space after Latin
/// sentence punctuation ("park. Then").
public enum TextJoin {
    public static func join(_ parts: [String]) -> String {
        var out = ""
        for part in parts {
            let piece = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if let last = out.unicodeScalars.last, let first = piece.unicodeScalars.first,
               isLatinWordChar(first), isLatinWordChar(last) || isLatinPunctuation(last) {
                out += " "
            }
            out += piece
        }
        return out
    }

    static func isLatinWordChar(_ s: Unicode.Scalar) -> Bool {
        s.isASCII && (CharacterSet.alphanumerics.contains(s))
    }

    static func isLatinPunctuation(_ s: Unicode.Scalar) -> Bool {
        ".,!?;:".unicodeScalars.contains(s)
    }
}

/// Apple's on-device recognizer can start a fresh transcript after a long pause:
/// the next partial result no longer contains the earlier sentence. This keeps
/// every segment so a pause never silently drops what was said before it.
///
/// Rules, in order:
/// 1. A result that repeats committed text (a final "replay" of everything, or a
///    recognizer that keeps growing the last utterance) replaces those segments
///    instead of being appended after them, also when the replay revised some of their
///    words. Only text the current recognition task heard can be replayed, and a new
///    utterance already under way that grows into the committed words ("我知道了", then
///    "我" → "我知道了，谢谢") is not a replay.
/// 2. Right after an utterance was committed, a final that closely revises it
///    (homophone fix) replaces it, unless that utterance was itself already final:
///    then a similar result is the user saying it again.
/// 3. Otherwise a result either revises the current utterance or, when it has
///    clearly restarted (much shorter, or little in common), starts a new one.
/// 4. `endsUtterance` (Apple's end-of-utterance metadata) commits immediately.
public struct TranscriptAccumulator: Sendable {
    public private(set) var segments: [String] = []
    public private(set) var current: String = ""
    /// Index of the first segment produced by the current recognition task.
    private var taskStart = 0
    /// The last segment came from a non-final result of the current task, so the
    /// recognizer may still send its final revision.
    private var revisable = false

    public init() {}

    public var text: String { TextJoin.join(segments + [current]) }

    /// - Parameters:
    ///   - endsUtterance: the recognizer attached end-of-utterance metadata to this result.
    ///   - isFinal: the recognizer's last word on this utterance (`SFSpeechRecognitionResult.isFinal`).
    public mutating func update(_ text: String, endsUtterance: Bool = false, isFinal: Bool = false) {
        let next = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = Array(Self.normalize(next))
        guard !n.isEmpty else { return }   // empty or punctuation only
        let c = Array(Self.normalize(current))

        if let replay = replayedSegments(n, singleRevised: (endsUtterance || isFinal) && (revisable || !c.isEmpty)) {
            let rest = Array(n[replay.length...])
            let atStart = Self.startCloseness(c, n)
            if c.isEmpty {
                // First result after a commit: the recognizer replays or keeps growing what it committed.
                segments.removeSubrange(replay.start...)
            } else if atStart >= 0.5, atStart > Self.startCloseness(c, rest) {
                // The utterance under way grew into the result: the user says the committed
                // words again ("我" → "我知道了" → "我知道了，谢谢"). In a replay of everything
                // it would follow the committed text instead of starting the result.
            } else if rest.isEmpty {
                return   // a late final of the committed text while a new utterance is under way
            } else {
                segments.removeSubrange(replay.start...)   // a replay of everything, the current utterance included
            }
        } else if c.isEmpty, revisable, endsUtterance || isFinal, let last = segments.last,
                  Self.isCloseRevision(of: last, next) {
            segments.removeLast()
        } else if !c.isEmpty, Self.startsNewSegment(previous: current, next: next) {
            segments.append(current)
        }
        current = next
        if endsUtterance {
            commit()
            revisable = !isFinal
        }
    }

    /// Ends the current utterance: the next result starts a new segment. Used on
    /// end-of-utterance metadata; the recognizer may still send a final revision of it.
    public mutating func commit() {
        guard !current.isEmpty else { return }
        segments.append(current)
        current = ""
        revisable = true
    }

    /// A fresh recognition task takes over the rest of the audio. It never heard the
    /// earlier audio, so nothing it says is a replay or revision of earlier segments,
    /// even when the user repeats them.
    public mutating func startNewTask() {
        if !current.isEmpty {
            segments.append(current)
            current = ""
        }
        taskStart = segments.count
        revisable = false
    }

    /// The committed segments (within the current task) that the result `n` starts by
    /// repeating: the smallest index `start` such that `n` begins with all segments from it
    /// on, and how many characters of `n` that repeat takes.
    /// - Exactly: short overlaps (under 4 characters) only count when the whole result is
    ///   that repeat, so "好。" then "好的…" stays two segments.
    /// - Revised: a final fixes words in what it replays ("工员" → "公园", "三点" → "3点"), so
    ///   70% of the segments reappearing in order is enough. Over a single segment that only
    ///   counts when `singleRevised`; otherwise a similar result is the user's next sentence.
    private func replayedSegments(_ n: [Character], singleRevised: Bool) -> (start: Int, length: Int)? {
        guard taskStart < segments.count else { return nil }
        let parts = segments[taskStart...].map { Array(Self.normalize($0)) }
        var tails = [Int](repeating: 0, count: parts.count + 1)   // tails[k]: characters in parts[k...]
        for k in parts.indices.reversed() { tails[k] = tails[k + 1] + parts[k].count }
        for k in parts.indices where tails[k] > 0 && tails[k] <= n.count && n.starts(with: parts[k...].joined()) {
            if tails[k] >= 4 || tails[k] == n.count { return (taskStart + k, tails[k]) }
        }
        for k in parts.indices where tails[k] >= 4 && n.count * 10 >= tails[k] * 7 {
            guard k < parts.count - 1 || singleRevised else { continue }
            let aligned = Self.alignPrefix(Array(parts[k...]), n)
            if aligned.matched * 10 >= max(tails[k], aligned.length) * 7 { return (taskStart + k, aligned.length) }
        }
        return nil
    }

    /// Lines the start of `n` up with `parts`, one part at a time, allowing for revised words.
    /// - Returns: how many characters of `parts` reappear in order, and how many characters
    ///   of `n` they take up.
    static func alignPrefix(_ parts: [[Character]], _ n: [Character]) -> (matched: Int, length: Int) {
        var matched = 0, pos = 0
        for (index, part) in parts.enumerated() {
            var lo = 0
            while lo < part.count, pos + lo < n.count, part[lo] == n[pos + lo] { lo += 1 }
            let x = Array(part[lo...])
            guard !x.isEmpty else { matched += lo; pos += lo; continue }
            // Revisions shift the text by a few characters, so only alignments within `band`
            // of the diagonal count. That keeps a long segment (a cumulative transcript) cheap.
            let band = min(32, x.count / 2 + 2)
            let y = Array(n[(pos + lo)..<min(n.count, pos + lo + x.count + band)])
            // row[j]: LCS of the rest of the part and the next j characters of `n` (outside
            // the band, a lower bound).
            var row = [Int](repeating: 0, count: y.count + 1)
            for i in 1...x.count {
                let first = max(1, i - band), last = min(y.count, i + band)
                guard first <= last else { continue }
                var diagonal = row[first - 1]
                for j in first...last {
                    let above = row[j]
                    row[j] = x[i - 1] == y[j - 1] ? diagonal + 1 : max(row[j], row[j - 1])
                    diagonal = above
                }
            }
            // The span the part matches best. On a tie, the one after which the next part
            // begins ("一百二十个人" → "120个人", then "大家…"), else the one closest to the
            // part's own length ("工员" → "公园"). A part that does not reappear at all (a
            // filler word the final dropped) takes none.
            let nextFirst = index + 1 < parts.count ? parts[index + 1].first : nil
            func startsNext(_ j: Int) -> Bool { pos + lo + j < n.count && n[pos + lo + j] == nextFirst }
            var best = 0
            if lo > 0 || row.contains(where: { $0 > 0 }) {
                for j in 0...y.count {
                    let gain = (lo + row[j]) * max(part.count, lo + best), held = (lo + row[best]) * max(part.count, lo + j)
                    let better = gain != held ? gain > held
                        : startsNext(j) != startsNext(best) ? startsNext(j)
                        : abs(j - x.count) < abs(best - x.count)
                    if better { best = j }
                }
            }
            matched += lo + row[best]
            pos += lo + best
        }
        return (matched, pos)
    }

    /// How well `x` starts like `c`: the LCS of `c` and as many leading characters of `x`, over |c|.
    static func startCloseness(_ c: [Character], _ x: [Character]) -> Double {
        guard !c.isEmpty else { return 0 }
        return Double(lcs(c, Array(x.prefix(c.count)))) / Double(c.count)
    }

    static func startsNewSegment(previous: String, next: String) -> Bool {
        let p = Array(normalize(previous)), n = Array(normalize(next))
        guard !p.isEmpty, !n.isEmpty else { return false }
        let common = zip(p, n).prefix { $0 == $1 }.count
        if n.count >= p.count && common == p.count { return false }   // plain growth
        if n.count * 2 < p.count { return true }                       // shrank by more than half: restarted
        // A long sentence replaced by one sharing little of it. Similarity, not a
        // shared prefix, so revising the first word ("知道了…" → "只到了…") is a revision.
        // When even the first character changed, most of the sentence has to survive:
        // "今天我们去公园玩" → "明天我们去学校" keeps half of it and is the next sentence.
        if p.count >= 6 && n.count >= 4 && similarity(p, n) < (common == 0 ? 0.7 : 0.4) { return true }
        return false                                                   // ordinary revision of the same sentence
    }

    /// The final result rewrote a just-committed utterance ("我们明天去工员" → "我们明天去公园").
    static func isCloseRevision(of committed: String, _ next: String) -> Bool {
        let c = Array(normalize(committed)), n = Array(normalize(next))
        guard c.count >= 4, n.count >= 4 else { return false }
        let longer = max(c.count, n.count)
        guard min(c.count, n.count) * 4 >= longer * 3 else { return false }   // similar length
        return closeness(c, n) >= 0.7
    }

    /// Longest common subsequence over the longer length: 1 for equal texts, 0 if either is empty.
    static func closeness(_ a: [Character], _ b: [Character]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(lcs(a, b)) / Double(max(a.count, b.count))
    }

    /// Share of `p` that survives, in order, in `n` (longest common subsequence / |p|).
    static func similarity(_ p: [Character], _ n: [Character]) -> Double {
        guard !p.isEmpty else { return 1 }
        return Double(lcs(p, n)) / Double(p.count)
    }

    /// Longest common subsequence length. Common prefix and suffix are stripped first
    /// and the middle is capped, so a long running transcript stays cheap.
    static func lcs(_ a: [Character], _ b: [Character]) -> Int {
        var lo = 0
        while lo < a.count, lo < b.count, a[lo] == b[lo] { lo += 1 }
        var hiA = a.count, hiB = b.count
        while hiA > lo, hiB > lo, a[hiA - 1] == b[hiB - 1] { hiA -= 1; hiB -= 1 }
        let shared = lo + (a.count - hiA)
        let x = Array(a[lo..<min(hiA, lo + 400)]), y = Array(b[lo..<min(hiB, lo + 400)])
        guard !x.isEmpty, !y.isEmpty else { return shared }
        var row = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            var diagonal = 0
            for j in 1...y.count {
                let above = row[j]
                row[j] = x[i - 1] == y[j - 1] ? diagonal + 1 : max(row[j], row[j - 1])
                diagonal = above
            }
        }
        return shared + row[y.count]
    }

    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.symbols.contains($0)
        }.map(Character.init))
    }
}

/// Wait budgets for the recognizer, in seconds.
public enum RecognitionTiming {
    /// After the user stops, how long the live task may take to finalize. Never
    /// shorter than the caller asked for; grows a little with long recordings, capped at 12 s.
    public static func liveFinish(requested: TimeInterval, audioSeconds: TimeInterval) -> TimeInterval {
        max(requested, min(12, 4 + 0.05 * max(0, audioSeconds)))
    }

    /// The second pass over the whole recording: proportional to its length, but
    /// bounded so a long recording never leaves the HUD stuck on 识别中.
    public static func secondPass(audioSeconds: TimeInterval) -> TimeInterval {
        min(30, max(6, 0.6 * max(0, audioSeconds)))
    }

    /// The second pass when the live session lost audio (it heard nothing, or gave up while the
    /// user was still talking): proportional to the recording and longer than `secondPass`, up to
    /// two minutes, so a long recording can still be recovered piece by piece.
    public static func recovery(audioSeconds: TimeInterval) -> TimeInterval {
        min(120, max(6, 0.6 * max(0, audioSeconds)))
    }

    /// How many times the live session may hand the rest of the audio to a fresh task (the task
    /// ends at a long pause, after a final, or on an error): a few, plus one for every 20 s of
    /// audio so far. A long dictation with many pauses keeps being recognized to the end, while a
    /// recognizer that fails at once cannot restart without end.
    public static func restartBudget(audioSeconds: TimeInterval) -> Int {
        4 + Int(max(0, audioSeconds) / 20)
    }
}

/// Classifies Speech framework errors and words them in Chinese for the HUD.
public enum SpeechErrorText {
    static let assistant = "kAFAssistantErrorDomain"
    static let local = "kLSRErrorDomain"

    /// "No speech detected": not a failure worth reporting.
    public static func isNoSpeech(domain: String, code: Int) -> Bool {
        domain == assistant && (code == 1110 || code == 203)
    }

    /// The task was cancelled (by us, or because a newer request replaced it).
    public static func isCancellation(domain: String, code: Int) -> Bool {
        (domain == assistant && code == 216) || (domain == local && code == 301)
            || (domain == NSCocoaErrorDomain && code == NSUserCancelledError)
    }

    /// nil when the error should not be shown at all.
    public static func message(domain: String, code: Int, description: String) -> String? {
        if isNoSpeech(domain: domain, code: code) || isCancellation(domain: domain, code: code) { return nil }
        if description.localizedCaseInsensitiveContains("Siri and Dictation are disabled") || (domain == local && code == 201) {
            return "需要打开听写：系统设置 › 键盘 › 听写"
        }
        if domain == assistant && code == 1101 { return "本机语音识别服务没有响应，请再试一次" }
        if domain == assistant && code == 1700 { return "本机识别还没准备好，请稍后再试" }
        if description.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { return description }
        return "错误代码 \(code)"
    }
}
