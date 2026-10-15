import Foundation

/// Follows one delivered text through the user's settled edits and says what to learn from each.
/// The baseline only moves when a comparison taught something (`commit`), so a fix made in
/// several pauses is compared as a whole until it is recognisable. Undo and redo land on states
/// seen before, so they move the baseline without teaching anything; returning to the delivered
/// text retracts what this session learned.
///
/// A deletion that taught nothing does not move the baseline either: the word typed in its place
/// later is then still seen as a replacement (delete, then retype). That costs nothing, because
/// `CorrectionExtractor` judges every changed stretch on its own: a phrase deleted earlier is a
/// stretch that teaches nothing and takes nothing away from a term fixed elsewhere afterwards.
///
/// When a comparison taught something, only the stretches it learned from move into the baseline
/// (`commit(_:over:understood:)`). The rest of that text stays as it was delivered: a word still
/// being typed in pinyin, or one deleted and not typed again yet, is compared again whole when the
/// user is done with it, so its wrong side is always what was delivered, never the half-typed state.
///
/// A word a step learned alone (a name typed over everyday words) is remembered with the text it was
/// learned over. When a later text no longer shows it (`withdrawn`), it was taken back, or it was the first
/// half of a name typed with a pause (Cla, then Claude): the caller takes back what it taught, and the
/// comparison starts again from before it, so the whole change is looked at (克劳德 → Claude, never
/// Cla → Claude).
///
/// A swap that was only remembered (`Extraction.candidates`) is committed too, with a baseline that has not
/// moved: its wrong side must stay what was delivered. The text coming back to the delivered text is then
/// no change from the baseline, and is still the user taking the edit back (`noted`). Since the baseline
/// does not move for it, every later comparison lists the swaps the passage still shows: one that an
/// earlier comparison found and the latest does not is gone (a half-typed word that was finished, a swap
/// changed back while its word stands elsewhere in the text), and the caller takes back what remembered
/// it (`LearningEvent.holdsSwap(goneFrom:)`). `withdrawn` alone cannot see those: it looks for the word
/// anywhere in the text, and Han has no word boundaries to look between.
public struct EditTracker: Sendable {
    public enum Step: Equatable, Sendable {
        case none
        /// The user undid every edit: forget what this session learned.
        case retract
        /// Compare `inserted` (the baseline) with `edited`; call `commit` if that found pairs.
        case extract(inserted: String, edited: String)
    }

    public let original: String
    public private(set) var baseline: String
    /// Digests of committed states, never the text itself.
    private var seen: Set<UInt64>
    /// For a committed state only part of which was learned from: the baseline it left (by its digest).
    private var understood: [UInt64: String] = [:]
    /// The last candidate handed out, so the same settled text is not compared twice.
    private var candidate: UInt64?
    /// Words committed steps learned alone, oldest first, each with the baseline it was learned over (bounded).
    private var alone: [Alone] = []
    static let maxAlone = 12
    /// A committed step left the baseline at the delivered text (it only remembered a swap): back at that
    /// text, there is something to take back although nothing differs from the baseline.
    private var noted = false

    private struct Alone: Sendable {
        var word: String
        var before: String
    }

    public init(original: String) {
        self.original = original
        baseline = original
        seen = [Self.digest(original)]
    }

    /// Call with each settled (stable, not composing) state of the text.
    public mutating func settle(_ text: String) -> Step {
        guard text != baseline else {
            guard noted, text == original else { return .none }
            noted = false
            candidate = nil
            alone = []
            return .retract
        }
        if text == original {
            baseline = original
            candidate = nil
            alone = []
            noted = false
            return .retract
        }
        let d = Self.digest(text)
        if seen.contains(d) {
            baseline = understood[d] ?? text
            candidate = nil
            return .none
        }
        guard candidate != d else { return .none }
        // A pure deletion is usually the first half of delete-then-retype, so it is compared only
        // once the retyped text settles. Removing only spaces ("Open AI" → "OpenAI") is a fix of its own.
        // And while a swap is remembered from this text (`noted`), a deletion from the delivered text is
        // compared at once: the swap is no longer in it (it was changed back, and something else was
        // deleted), and only a comparison tells the caller so.
        if !noted, let removed = Self.deletion(from: baseline, to: text), !removed.allSatisfy(\.isWhitespace) { return .none }
        candidate = d
        return .extract(inserted: baseline, edited: text)
    }

    /// Whether `text` is the baseline with one run of characters taken out (not only spaces): `settle`
    /// hands that out as `.none`, and the caller may say that deleting alone teaches nothing. (Not while a
    /// swap is remembered from this text: then `settle` hands the deletion out to be compared, and the
    /// comparison says it.)
    public func removesOnly(_ text: String) -> Bool {
        guard !noted, let removed = Self.deletion(from: baseline, to: text) else { return false }
        return !removed.allSatisfy(\.isWhitespace)
    }

    /// The comparison of `inserted` with `edited` taught something: later edits build on `understood`,
    /// the delivered text with only the learned stretches changed (`Extraction.baseline`), or on all of
    /// `edited` when that is nil. Ignored when the baseline has moved on since that step was handed out.
    /// `alone`: the words it learned or noted without a mapping (`Extraction.terms`, `sightings`).
    public mutating func commit(_ edited: String, over inserted: String, understood partly: String? = nil,
                                alone words: [String] = []) {
        guard baseline == inserted else { return }
        let d = Self.digest(edited)
        baseline = partly ?? edited
        if baseline == original, edited != original { noted = true }
        seen.insert(d)
        understood[d] = baseline == edited ? nil : baseline
        candidate = nil
        alone = Array((alone + words.map { Alone(word: $0, before: inserted) }).suffix(Self.maxAlone))
    }

    /// The words earlier steps learned alone that `text` no longer shows as they were written (as words of
    /// their own: Cla is not in Claude). Call with each settled text, before `settle`, and take back what
    /// taught the words returned. The comparison then starts again from before the first of them, so `settle`
    /// hands out the whole change since. Empty when every such word is still there.
    public mutating func withdrawn(from text: String) -> [String] {
        // Back to the delivered text: `settle` takes everything back (`.retract`).
        guard text != original, let first = alone.firstIndex(where: { !Self.shows($0.word, in: text) }) else { return [] }
        let gone = alone[first...].filter { !Self.shows($0.word, in: text) }.map(\.word)
        baseline = alone[first].before
        candidate = nil
        // The steps from that one on are compared again, and commit what they still teach.
        alone.removeSubrange(first...)
        return gone
    }

    /// Whether `word` stands in `text` as written, not inside a longer run of letters or digits.
    static func shows(_ word: String, in text: String) -> Bool {
        guard !word.isEmpty else { return true }
        func wordy(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
        var from = text.startIndex
        while let found = text.range(of: word, range: from..<text.endIndex) {
            let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : " "
            let after = found.upperBound < text.endIndex ? text[found.upperBound] : " "
            if !(wordy(before) && word.first.map(wordy) == true), !(wordy(after) && word.last.map(wordy) == true) { return true }
            from = text.index(after: found.lowerBound)
        }
        return false
    }

    /// `b` is `a` with one contiguous run of characters removed.
    static func isDeletion(from a: String, to b: String) -> Bool {
        deletion(from: a, to: b) != nil
    }

    /// The run removed from `a` to get `b`, or nil when `b` is not `a` minus one contiguous run.
    static func deletion(from a: String, to b: String) -> Substring? {
        let x = Array(a), y = Array(b)
        guard y.count < x.count else { return nil }
        var prefix = 0
        while prefix < y.count, x[prefix] == y[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < y.count - prefix, x[x.count - 1 - suffix] == y[y.count - 1 - suffix] { suffix += 1 }
        guard prefix + suffix == y.count else { return nil }
        return Substring(String(x[prefix..<(x.count - suffix)]))
    }

    /// FNV-1a over UTF-8; in-memory only, so stability across launches does not matter.
    static func digest(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }
}
