import CryptoKit
import Foundation
import NeolessCloud
import NeolessCore

/// The dictionary (vocabulary.json, the same list of words as the Mac app's) and the learned corrections
/// (learning.json, a `LearningBook`). They are kept together because learning changes the dictionary: every
/// learned `right` goes into it, and forgetting a pair takes the word out again when learning added it and no
/// other pair still teaches it (the Mac app's `LearningStore` rules). 我的习惯 (habits.json, `Habits`) are kept
/// here too: with the words and the corrections they are what the hub gives every polish.
@MainActor
public final class WordStore {
    public private(set) var words: [String]
    public private(set) var book: LearningBook
    /// 我的习惯: the user's own writing preferences, as a device last sent them.
    public private(set) var habits: Habits
    /// A new one whenever the dictionary starts over (no vocabulary.json, or one that could not be read and was
    /// set aside): `VocabularySnapshot.generation`.
    public private(set) var generation: String
    /// The same for the habits (no habits.json, or one that could not be read and was set aside):
    /// `HabitsSnapshot.generation`. An empty list of another generation is a list nobody ever stored here, not
    /// one a device emptied.
    public private(set) var habitsGeneration: String
    /// The most a `PUT /v1/habits` body may be, the most lines it may carry and the longest one may be (UTF-8
    /// bytes): well over what `Habits` keeps (`maxItems` lines of `maxLength` characters), and little enough
    /// that cleaning what a device sends is never more than a moment's work.
    public static let maxHabitsJSONBytes = 16 * 1024, maxHabitLines = Habits.maxLines, maxHabitBytes = 1_024

    /// What vocabulary-generation.json keeps.
    struct Generation: Codable {
        var generation: String
    }

    private let store: DataFileStore
    private let now: () -> Date
    /// Recent learning events and the dictation each came from, so a second fix of the same text chains:
    /// A→B then B→C is learned as A→C (oldest first, bounded).
    private var recent: [(event: LearningEvent, recordID: UUID?, source: LearnedCorrection.Source)] = []
    static let recentLimit = 20

    public init(store: DataFileStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        let saved = store.read([String].self, from: HubDataFolder.File.vocabulary)
        words = Vocabulary.normalize(saved ?? Vocabulary.defaults)
        book = store.read(LearningBook.self, from: HubDataFolder.File.learning) ?? LearningBook()
        let savedHabits = store.read(Habits.self, from: HubDataFolder.File.habits)
        habits = savedHabits ?? Habits()
        if savedHabits != nil, let kept = store.read(Generation.self, from: HubDataFolder.File.habitsGeneration) {
            habitsGeneration = kept.generation
        } else {
            // Habits that start over now (or a file from before generations): devices compare against them anew,
            // so a list that was lost here is sent again, not taken for emptied. Saved, so the next start reads
            // the same one.
            habitsGeneration = UUID().uuidString
            if savedHabits == nil { store.write(habits, to: HubDataFolder.File.habits) }
            store.write(Generation(generation: habitsGeneration), to: HubDataFolder.File.habitsGeneration)
        }
        if saved != nil, let kept = store.read(Generation.self, from: HubDataFolder.File.vocabularyGeneration) {
            generation = kept.generation
        } else {
            // A dictionary that starts over now (or one from before generations): devices compare against it anew.
            // Saved with it, so the next start reads the same one.
            generation = UUID().uuidString
            if saved == nil { store.write(words, to: HubDataFolder.File.vocabulary) }
            store.write(Generation(generation: generation), to: HubDataFolder.File.vocabularyGeneration)
        }
    }

    // MARK: Dictionary

    /// Lower-cased terms that are in the dictionary only because they were learned.
    var learnedTerms: Set<String> { Self.learnedTerms(of: book) }

    /// The user's own words: the dictionary without what learning put there. Only these make a fix easier to
    /// accept (`CorrectionExtractor`'s `knownTerms`), or one learned word would lower the bar for every later
    /// correction towards it.
    public var ownWords: [String] {
        let learned = learnedTerms
        return words.filter { !learned.contains($0.lowercased()) }
    }

    /// Learned-only terms, most often fixed first (as the app ranks them for hints and the prompt).
    var learnedRanking: [String] { Self.learnedRanking(of: book) }

    /// Hints for the ASR worker, most important first.
    public var recognizerHints: [String] { Vocabulary.recognizerHints(words, learned: learnedRanking) }
    /// The word lists one polish prompt gets.
    public var promptWords: Vocabulary.PromptWords { Vocabulary.promptWords(words, learned: learnedRanking) }

    /// Opaque; changes whenever `words` does.
    public var revision: String { Self.revision(of: words) }

    static func revision(of words: [String]) -> String {
        let data = (try? JSONEncoder().encode(words)) ?? Data()
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public var snapshot: VocabularySnapshot {
        VocabularySnapshot(words: words, learned: Vocabulary.prioritized(words, learned: learnedRanking).learned,
                           revision: revision, generation: generation)
    }

    /// `PUT /v1/vocabulary`: the whole new list, refused when the dictionary changed since `expectedRevision`.
    /// Learned terms the user puts back by hand count as their own from now on.
    public func replace(words new: [String], expectedRevision: String) throws -> VocabularySnapshot {
        guard expectedRevision == revision else { throw HubFailure.conflict }
        let next = Vocabulary.normalize(new)
        let before = Set(words.map { $0.lowercased() })
        let learned = learnedTerms
        var bookChanged = false
        for word in next where !before.contains(word.lowercased()) && learned.contains(word.lowercased()) {
            book.markManualTerm(word)
            bookChanged = true
        }
        if next != words {
            words = next
            store.write(words, to: HubDataFolder.File.vocabulary)
        }
        if bookChanged { store.write(book, to: HubDataFolder.File.learning) }
        return snapshot
    }

    // MARK: Learning

    public var learningList: LearningList {
        LearningList(pairs: book.items.map { LearningEntry(wrong: $0.pair.wrong, right: $0.pair.right, count: $0.count,
                                                           lastSeen: $0.lastSeen, kind: $0.kind) })
    }

    /// Learns `pairs` from one edit or observation and adds their terms to the dictionary, and `terms`, the
    /// words it taught without a mapping (`CorrectionExtractor.Strength.termOnly`: the misheard side is
    /// everyday text, so only the corrected word is kept). Those join the dictionary as learned words, like
    /// the ones a correction teaches: listed under `learned`, weighed below the user's own, and taken out
    /// again when the edit is taken back. `sightings`: words an edit gave a capital to, noted the first time
    /// and learned the second (`LearningBook.record`). `candidates`: swaps an edit made that the rules neither
    /// take nor forbid, remembered the first time and learned as a hint the second (in another dictation).
    /// `repeated`: swaps a device saw twice itself, learned as hints at once. Neither puts a word in the
    /// dictionary. Returns nil when nothing changed.
    @discardableResult
    public func learn(_ pairs: [CorrectionPair], terms: [String] = [], sightings: [String] = [],
                      candidates: [CorrectionPair] = [], repeated: [CorrectionPair] = [],
                      source: LearnedCorrection.Source, recordID: UUID?) -> LearningEvent? {
        guard !pairs.isEmpty || !terms.isEmpty || !sightings.isEmpty || !candidates.isEmpty || !repeated.isEmpty else { return nil }
        var pairs = pairs
        // A→B then B→C in one dictation (a fix fixed again): learn A→C instead of both.
        if let recordID, let (earlier, composed) = recent.reversed().lazy
            .filter({ $0.recordID == recordID })
            .compactMap({ e in LearningBook.chained(pairs, after: e.event.learned).map { (e.event, $0) } }).first {
            undo(earlier)
            pairs = composed
            guard !pairs.isEmpty || !terms.isEmpty || !sightings.isEmpty || !candidates.isEmpty || !repeated.isEmpty else { return nil }
        }
        // A word in the dictionary only because it was learned does not count as existing, so a second pair
        // teaching it is also marked as having added it.
        let existing = Set(words.map { $0.lowercased() }).subtracting(learnedTerms)
        var next = book
        let event = next.record(pairs, terms: terms, sightings: sightings, candidates: candidates, repeated: repeated,
                                source: source, recordID: recordID, now: now()) {
            existing.contains($0.lowercased())
        }
        guard !event.isEmpty else { return nil }
        let before = book
        let ranking = learnedRanking
        book = next
        if !event.learned.isEmpty || !event.terms.isEmpty {
            words = Vocabulary.addingLearned(event.learned.map(\.right) + event.terms, to: words, learned: ranking)
        }
        forgetUntaught(since: before)
        recent = Array((recent + [(event, recordID, source)]).suffix(Self.recentLimit))
        save()
        return event
    }

    /// The text of dictation `recordID` is as it was delivered again: what its edits taught since the hub started
    /// is taken back.
    public func takeBack(recordID: UUID) {
        for event in recent.filter({ $0.recordID == recordID }).map(\.event).reversed() { undo(event) }
    }

    /// The text of dictation `recordID` no longer shows `word`, the new side of a swap one of its edits
    /// remembered or learned as made twice: what those edits did is taken back. (A word learned alone goes
    /// with `unlearnTerm`.)
    public func takeBack(word: String, recordID: UUID) {
        let key = word.lowercased()
        for event in recent.filter({ $0.recordID == recordID }).map(\.event).reversed()
        where (event.candidates + event.promoted).contains(where: { $0.right.lowercased() == key }) {
            undo(event)
        }
    }

    /// The passage of dictation `recordID` no longer shows a swap one of its edits remembered or learned as
    /// made twice, by the latest comparison of it (`LearningEvent.holdsSwap(goneFrom:)`). What those edits
    /// did is taken back; a swap of theirs that is still there is remembered again by the learning that
    /// follows. Only what the hub learned from the text itself (`…/edit`, source `.inApp`): what a device
    /// observed and sent for the same dictation was read off another copy of the text.
    public func takeBackSwaps(recordID: UUID, goneFrom found: Extraction) {
        let edits = recent.filter { $0.recordID == recordID && $0.source == .inApp }.map(\.event)
        for event in edits.reversed() where event.holdsSwap(goneFrom: found) { undo(event) }
    }

    /// A device took back a word it had learned without a mapping (the edit was undone there). The word
    /// leaves the dictionary when it was in it only for that; a note of it (a capital seen once) goes too.
    /// Returns whether there was such a learned word.
    @discardableResult
    public func unlearnTerm(_ term: String) -> Bool {
        let before = book
        guard book.removeTerm(term) != nil else {
            if book != before { save() }
            return false
        }
        let ids = Set(before.terms.filter { $0.term.lowercased() == term.lowercased() }.map(\.id))
        // Undoing the event that learned it must not take it out twice, or bring back what it pushed out.
        recent.removeAll { e in e.event.addedTerms.contains(where: ids.contains) || e.event.previousTerms.contains { ids.contains($0.id) } }
        forgetUntaught(since: before)
        save()
        return true
    }

    /// `DELETE /v1/learning?wrong=…`: forgets every pair with this `wrong` (ignoring case and spacing).
    /// Returns whether anything was forgotten.
    @discardableResult
    public func forget(wrong: String) -> Bool {
        forget(wrongs: [wrong])
    }

    /// `POST /v1/learning/forget`: every pair with one of these `wrong`s, saved once.
    @discardableResult
    public func forget(wrongs: [String]) -> Bool {
        let keys = Set(wrongs.map(Self.fold))
        let gone = book.items.filter { keys.contains(Self.fold($0.pair.wrong)) }
        guard !gone.isEmpty else { return false }
        let before = book
        for item in gone { book.remove(id: item.id) }
        forgetUntaught(since: before)
        let ids = Set(gone.map(\.id))
        // Undoing an event that touched these would bring them back.
        recent.removeAll { e in e.event.added.contains(where: ids.contains) || e.event.previous.contains { ids.contains($0.id) } }
        save()
        return true
    }

    // MARK: Import

    /// `neoless-hub import-samples`: `terms` (the file's words, most important first) join the dictionary as the
    /// user's own, after the words already there, which keep their places; then `corrections` are imported into the
    /// learning book (`LearningBook.importCorrections`) and the terms they teach that are not in the dictionary join
    /// it as learned-only ones, as learning would add them, so deleting such a pair takes its word out again. The
    /// dictionary's cap (`Vocabulary.maxWords`) is kept: nothing is dropped to make room. A word that is in the
    /// dictionary only because it was learned counts as the user's own from now on. With `dryRun` nothing changes:
    /// the result says what the import would do.
    public func importSamples(words terms: [String], corrections: [ImportedCorrection], dryRun: Bool) -> SampleImportResult {
        var result = SampleImportResult()
        var next = words
        var nextBook = book
        let learned = learnedTerms
        var keys = Set(next.map { $0.lowercased() })
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            guard term.count <= Vocabulary.maxWordLength, !term.contains(where: \.isNewline) else {
                result.tooLong.append(term)
                continue
            }
            let key = term.lowercased()
            if keys.contains(key) {
                if learned.contains(key) {
                    nextBook.markManualTerm(term)
                    result.adopted.append(term)
                } else {
                    result.present.append(term)
                }
                continue
            }
            guard next.count < Vocabulary.maxWords else {
                result.full.append(term)
                continue
            }
            next.append(term)
            keys.insert(key)
            result.added.append(term)
        }

        let ownWords = Set(next.map { $0.lowercased() }).subtracting(Self.learnedTerms(of: nextBook))
        result.corrections = nextBook.importCorrections(corrections) { ownWords.contains($0.lowercased()) }
        let listed = Set(next.map { $0.lowercased() })
        var taught = Set<String>()
        result.learnedTerms = result.corrections.added.map(\.right)
            .filter { !listed.contains($0.lowercased()) && taught.insert($0.lowercased()).inserted }
        if !result.learnedTerms.isEmpty {
            next = Vocabulary.addingLearned(result.learnedTerms, to: next, learned: Self.learnedRanking(of: nextBook))
        }

        let ranking = Self.learnedRanking(of: nextBook)
        let hints = Set(Vocabulary.recognizerHints(next, learned: ranking).map { $0.lowercased() })
        let prompt = Vocabulary.promptWords(next, learned: ranking)
        let inPrompt = Set(prompt.all.map { $0.lowercased() })
        result.ownWords = Vocabulary.prioritized(next, learned: ranking).manual.count
        result.hintCount = hints.count
        result.addedInHints = result.added.filter { hints.contains($0.lowercased()) }.count
        result.promptCount = prompt.own.count
        result.addedInPrompt = result.added.filter { inPrompt.contains($0.lowercased()) }.count

        guard !dryRun, next != words || nextBook != book else { return result }
        words = next
        book = nextBook
        save()
        return result
    }

    static func learnedTerms(of book: LearningBook) -> Set<String> { book.learnedOnlyTerms }

    static func learnedRanking(of book: LearningBook) -> [String] { book.learnedRanking }

    /// The text typed as is (原样转写, or the original after a failed polish) with the confirmed corrections.
    public func applyConfirmed(_ text: String) -> String { LearningPrompt.applyConfirmed(text, book: usableBook) }

    /// Learned pairs worth sending with this transcript.
    public func promptPairs(for transcript: String) -> [CorrectionPair] { LearningPrompt.pairs(for: transcript, from: usableBook) }

    /// What else a polish of this transcript is given: the swaps made twice whose first word is in it, and
    /// the user's habits.
    public func promptExtras(for transcript: String) -> PolishExtras {
        PolishExtras(repeated: LearningPrompt.repeated(for: transcript, from: usableBook), habits: habits.items)
    }

    // MARK: Habits

    /// Opaque; changes whenever the habits do.
    static func revision(of habits: Habits) -> String { revision(of: habits.items) }

    public var habitsSnapshot: HabitsSnapshot {
        HabitsSnapshot(items: habits.items, revision: Self.revision(of: habits), generation: habitsGeneration)
    }

    /// `PUT /v1/habits`: the whole new list, cleaned (`Habits.normalized`), refused when `expectedRevision`
    /// is given and the list changed since. More lines than `maxHabitLines`, or one longer than
    /// `maxHabitBytes`, is no list of habits and is refused whole (413), before any of it is cleaned.
    public func replaceHabits(_ items: [String], expectedRevision: String?) throws -> HabitsSnapshot {
        guard items.count <= Self.maxHabitLines, items.allSatisfy({ $0.utf8.count <= Self.maxHabitBytes }) else {
            throw HubFailure.habitsTooLarge
        }
        if let expectedRevision, expectedRevision != Self.revision(of: habits) { throw HubFailure.habitsConflict }
        let next = Habits(items)
        if next != habits {
            habits = next
            store.write(habits, to: HubDataFolder.File.habits)
        }
        return habitsSnapshot
    }

    /// How many stored corrections today's rules would not learn (`LearningBook.unusable`): kept in the book
    /// and listed, used for nothing.
    public var unusedCorrections: Int { book.items.count - usableBook.items.count }

    /// The book without the corrections today's rules would not learn: one stored by an older version (a
    /// weekday, a negation, an opposite, one everyday character), or learned towards a dictionary word that
    /// is gone, is neither put before the model nor written into text any more. Worked out again only when
    /// the book or the dictionary changed.
    private var usableBook: LearningBook {
        if let usable, usable.book == book, usable.words == words { return usable.result }
        // Each correction is judged once for the same own words: learning one more does not judge the rest again.
        let own = ownWords
        if judged.own != own { judged = (own, [:]) }
        let result = book.without(book.unusable(knownTerms: Set(own), verdicts: &judged.verdicts))
        usable = (book, words, result)
        return result
    }
    private var usable: (book: LearningBook, words: [String], result: LearningBook)?
    private var judged: (own: [String], verdicts: [String: Bool]) = ([], [:])

    // MARK: Private

    private func undo(_ event: LearningEvent) {
        guard let i = recent.firstIndex(where: { $0.event.id == event.id }) else { return }
        recent.remove(at: i)
        let before = book
        // A word the user has as their own now stays theirs.
        let manual = Set(words.map { $0.lowercased() }).subtracting(learnedTerms)
        book.undo(event, manualTerms: manual)
        forgetUntaught(since: before)
        let restored = book.items.filter { item in item.addedTerm && !before.items.contains { $0.id == item.id } }
            .map(\.pair.right) + book.terms.filter { term in !before.terms.contains { $0.id == term.id } }.map(\.term)
        if !restored.isEmpty {
            words = Vocabulary.addingLearned(restored, to: words, learned: learnedRanking)
        }
        save()
    }

    /// Takes out of the dictionary the words that were in it only because `before` taught them and that
    /// nothing teaches any more (a correction forgotten or undone, a word learned alone taken back).
    private func forgetUntaught(since before: LearningBook) {
        let gone = before.learnedOnlyTerms.filter { !book.teaches($0) }
        guard !gone.isEmpty else { return }
        words.removeAll { gone.contains($0.lowercased()) }
    }

    private func save() {
        store.write(book, to: HubDataFolder.File.learning)
        store.write(words, to: HubDataFolder.File.vocabulary)
    }

    static func fold(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// What `WordStore.importSamples` did, or would do in a dry run.
public struct SampleImportResult: Equatable, Sendable {
    /// Added to the dictionary as the user's own words, in this order, after the words already there.
    public var added: [String] = []
    /// Already the user's own words: left where they are.
    public var present: [String] = []
    /// In the dictionary only because learning added them: the user's own from now on.
    public var adopted: [String] = []
    /// Not added: the dictionary is full (`Vocabulary.maxWords`).
    public var full: [String] = []
    /// Not added: longer than `Vocabulary.maxWordLength`, or more than one line.
    public var tooLong: [String] = []
    public var corrections = LearningImport()
    /// Terms the imported corrections teach that were not in the dictionary: added as learned-only ones.
    public var learnedTerms: [String] = []
    /// After the import: the user's own words, how many go to the recognizer (`Vocabulary.recognizerHintLimit` at
    /// most) and into the polish prompt (`Vocabulary.promptCharacterBudget`), and how many of `added` are among them.
    public var ownWords = 0, hintCount = 0, addedInHints = 0, promptCount = 0, addedInPrompt = 0

    public init() {}
}
