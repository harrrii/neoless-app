import Foundation
import NeolessCloud
import NeolessCore

/// Learned corrections (learning.json) and the 自动学习 switch.
/// Every learned `right` goes into the dictionary; forgetting a pair removes the word again
/// only when learning added it and no other pair still teaches it. A word learned without a mapping
/// (`LearnedTerm`) is in the book and in the dictionary the same way: a learned word, never one of the
/// user's own, and gone again when the edit that taught it is taken back.
///
/// It also keeps what became of the user's recent edits (`LearningLog`: codes and counts, never text), and
/// says the things worth one line where the user is (`onAnnounce`, the capsule): a word was remembered, a
/// fix could not be, or an app's edits cannot be seen. The log is on disk (learning-log.json) only while
/// 保存历史 is on; with it off it lives in memory until neoless quits. 清空, the list's own 清除 and
/// switching 自动学习 off empty it.
///
/// Two more things live here, because the dictionary page shows them with the rest. A word typed over
/// another that does not sound like it is only remembered the first time (`candidates`) and learned, as a
/// hint for the model, when the same swap is made in another dictation. And 我的习惯 (`habits`, habits.json):
/// the user's own writing preferences, given to every polish and kept in step with the Neo by `HubSync`;
/// when the same edit that is no word fix keeps coming back (a stop taken off, a filler deleted), a habit is
/// offered (`suggestion`), and added only when the user says so.
@MainActor
final class LearningStore: ObservableObject {
    /// The latest learning event, for the "已记住：A → B  撤销" line.
    struct Notice: Identifiable, Equatable {
        let event: LearningEvent
        /// The rest of the events of the same edit (one that fixed more words than an event takes).
        var more: [LearningEvent] = []
        /// Words learned without a mapping by this edit (in the events, like the pairs).
        var terms: [String] = []
        let recordID: UUID?
        let source: LearnedCorrection.Source
        let date: Date

        var id: UUID { event.id }
        /// What the edit taught: the fixes, and the swaps learned now that they were made a second time.
        var pairs: [CorrectionPair] { ([event] + more).flatMap { $0.learned + $0.promoted } }
        /// "Open Air → OpenAI、金币 → 硬币、Nio"
        var summary: String { LearningText.summary(pairs: pairs, terms: terms) }
    }

    /// Something worth one line where the user is.
    enum Announcement: Equatable {
        case learned(pairs: [CorrectionPair], terms: [String])
        /// A word was typed over another that does not sound like it: remembered, and learned when the same
        /// swap is made again ("记下了：X → Y，再这样改一次就记住").
        case noted(pairs: [CorrectionPair])
        /// The user fixed a term, but nothing could be learned from it.
        case missed(Extraction.Nothing)
        /// What the user changes in this app cannot be seen.
        case unwatched(app: String?)
    }

    static let enabledKey = "learnCorrections"
    static let editorsKey = "learnInEditors"

    @Published var enabled: Bool {
        didSet {
            if persists { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
            // Switched off: what became of earlier edits is no longer kept either, nor what was counted
            // towards offering a habit. (我的习惯 themselves are the user's own and stay.)
            if !enabled {
                clearLog()
                clearHabitNotes()
            }
        }
    }
    /// The code editors (bundle ids, `WebAccessibility.editors`) the user switched learning on for. Only
    /// these are asked for their accessibility tree: an editor of the VS Code family may switch to its
    /// screen-reader mode when asked.
    @Published private(set) var editors: Set<String>
    /// Newest first.
    @Published private(set) var items: [LearnedCorrection] = []
    @Published private(set) var lastEvent: Notice?
    /// Record whose target app could not be observed; the home page shows a hint for it.
    @Published private(set) var unsupportedRecordID: UUID?
    /// The Neo's corrections that this Mac's own list does not have, most used first.
    @Published private(set) var hubItems: [LearningEntry] = []
    /// What became of the recent edits, newest first.
    @Published private(set) var log: [LearningLog.Entry] = []
    /// Corrections of this Mac's that the Neo does not hold (`LearningBook.key`), with what it holds instead
    /// (`HubLearning.missing`). Worked out from this Mac's book, the Neo's list at the last sync and what
    /// still waits to go, so it says the same after a relaunch. Empty when no Neo is paired.
    @Published private(set) var notOnHub: [String: HubLearning.Holding] = [:]
    /// Stored corrections (this Mac's and the Neo's, by `LearningBook.key`) that today's rules would not
    /// learn (`LearningBook.unusable`): an older version learned them, or the dictionary word they were
    /// learned towards is gone. They are listed, marked, and used for nothing: neither put before the model
    /// nor written into text.
    @Published private(set) var unused: Set<String> = []
    /// Swaps made once and waiting for their second time, newest first (`LearningBook.candidates`): used
    /// for nothing yet. Listed so the user sees them and can delete one (`removeCandidate`).
    @Published private(set) var candidates: [LearningBook.Candidate] = []
    /// The swaps the latest edit only remembered, for a line where the user is looking (the home page: the
    /// capsule says it in other apps).
    @Published private(set) var lastNoted: Noted?
    /// 我的习惯, in the user's order.
    @Published private(set) var habits: [String] = []
    /// The one habit neoless offers to add right now, or nil (`acceptSuggestion`, `declineSuggestion`).
    @Published private(set) var suggestion: HabitSuggestion?
    /// Whether the Neo, which does the polishing, has these habits.
    @Published private(set) var habitsOnHub: HabitsOnHub = .unknown

    /// Swaps an edit remembered (`lastNoted`).
    struct Noted: Equatable {
        var pairs: [CorrectionPair]
        var recordID: UUID?
        var date: Date
    }

    /// What the Neo has of 我的习惯.
    enum HabitsOnHub: Equatable {
        /// No Neo is paired, or it has not been synced with yet.
        case unknown
        /// The Neo has the same habits.
        case same
        /// Changed here, and not on the Neo yet: they go with the next sync.
        case waiting
        /// The Neo is from before habits: they are used only when this Mac polishes itself.
        case unsupported
    }

    private(set) var book: LearningBook
    /// The Neo's learned corrections (`HubSync`), used with this Mac's own for the dictations it polishes or types
    /// itself.
    private var hubEntries: [LearningEntry] = []
    /// Whether a Neo is paired and has been synced with (`notOnHub` means something only then), its dictionary
    /// at that sync, and this Mac's corrections that are waiting to go or went since.
    private var hubKnown = false
    private var hubWords: [String] = []
    private var hubPending = Set<String>()
    /// `book` with the Neo's corrections added and without those today's rules would not learn (`unused`):
    /// what the prompt and `applyConfirmed` use.
    private var promptBook = LearningBook()
    /// What the stored corrections were judged against, and the answers (`LearningBook.unusable`).
    private var judged: (known: Set<String>, verdicts: [String: Bool]) = ([], [:])
    /// What one change did to the counts, for the Neo (`HubSync`).
    struct Change {
        /// Pairs learned or counted again (`LearningEvent.learned`; undoing a change-back counts it up again).
        /// A word learned without a mapping goes as a pair with nothing on the wrong side (`Change.word`):
        /// the Neo learns the same word, as a learned one.
        var learned: [CorrectionPair] = []
        /// Pairs counted down: changed back by the user (`LearningEvent.reversed`), or a learning undone.
        var unlearned: [CorrectionPair] = []
        /// Swaps learned or counted again as made twice (`LearningEvent.promoted`): they go to the Neo as
        /// that (`LearningObservations.kind`), since by the rules for recognition errors it would not take them.
        var repeated: [CorrectionPair] = []
        /// The dictation record the change comes from.
        var recordID: UUID?

        var isEmpty: Bool { learned.isEmpty && unlearned.isEmpty && repeated.isEmpty }

        /// A word learned without a mapping, as it goes to the Neo.
        static func word(_ term: String) -> CorrectionPair { CorrectionPair(wrong: "", right: term) }
    }

    /// Every change to the counts: `HubSync` makes the same change on the Neo.
    var onChange: ((Change) -> Void)?
    /// Corrections the user forgot (by their `wrong`): `HubSync` forgets them on the Neo too.
    var onForget: (([String]) -> Void)?
    /// One line for the capsule (`AppDelegate`).
    var onAnnounce: ((Announcement) -> Void)?
    /// The user changed 我的习惯 here: `HubSync` takes them to the Neo.
    var onHabitsChange: (() -> Void)?
    private let vocabulary: VocabularyStore
    private let file = "learning.json"
    private let logFile = "learning-log.json"
    private let habitsFile = "habits.json"
    /// Which patterns were seen in which dictations (`HabitBook`): keys, ids, app names and times, never text.
    /// On disk only while 保存历史 is on, like the log.
    private let habitNotesFile = "habit-notes.json"
    private var habitList = Habits()
    private var habitBook = HabitBook()
    /// False for `--snapshot`: nothing is read from or written to disk.
    private(set) var persists = true
    private var history = LearningLog()
    /// Lower-cased terms that exist in the dictionary only because they were learned.
    private var learnedTerms = Set<String>()
    /// Events that can still be undone exactly, oldest first, with the record each came from and how.
    private var undoable: [(event: LearningEvent, recordID: UUID?, source: LearnedCorrection.Source)] = []
    /// The log entry that says what an event taught (by the event's id), so taking the event back is said too.
    private var logged: [UUID: UUID] = [:]
    /// The same for the entry that says an event remembered a swap.
    private var loggedNotes: [UUID: UUID] = [:]
    /// Apps already said to be out of sight this launch, and records already told a fix was not learned.
    private var hintedApps = Set<String>()
    private var missedRecords: [UUID] = []
    /// Swaps the user deleted (撤销 on the line that said one was remembered, or its row on the dictionary
    /// page), with the dictation each was made in. A swap moves nothing into what the passage is compared
    /// with, so the same passage edited further shows it again: it is not remembered a second time from
    /// there, and nothing is said about it. In memory only, like the watch of a passage; bounded.
    private var dismissedSwaps: [(key: String, recordID: UUID)] = []

    init(vocabulary: VocabularyStore) {
        self.vocabulary = vocabulary
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        editors = Set(UserDefaults.standard.stringArray(forKey: Self.editorsKey) ?? [])
        book = AppFiles.read(LearningBook.self, from: file) ?? LearningBook()
        // A swap that waited too long for its second time is forgotten.
        if book.expireCandidates() { AppFiles.write(book, to: file) }
        habitList = AppFiles.read(Habits.self, from: habitsFile) ?? Habits()
        habits = habitList.items
        if keepsLog, enabled {
            history = AppFiles.read(LearningLog.self, from: logFile) ?? LearningLog()
            habitBook = AppFiles.read(HabitBook.self, from: habitNotesFile) ?? HabitBook()
        } else {
            // 保存历史 or 自动学习 was switched off: a log left from before is not kept.
            AppFiles.remove(logFile)
            AppFiles.remove(habitNotesFile)
        }
        log = history.entries
        suggestion = habitBook.suggestion(habits: habitList.items)
        publish()
        // Numbers only, never a word.
        if !unused.isEmpty { NSLog("neoless: learning: %d stored corrections no longer pass the rules and are not used", unused.count) }
        // 保存历史 switched off while running: the log leaves the disk at once (it stays in memory).
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.keepsLog else { return }
                AppFiles.remove(self.logFile)
                AppFiles.remove(self.habitNotesFile)
            }
        }
    }

    /// In-memory store for `--snapshot`; never touches disk or UserDefaults.
    init(preview: [LearnedCorrection], vocabulary: VocabularyStore) {
        self.vocabulary = vocabulary
        enabled = true
        editors = []
        persists = false
        book = LearningBook(items: preview)
        publish()
    }

    /// Switches learning in a code editor on or off (Settings).
    func setEditor(_ bundleID: String, on: Bool) {
        var next = editors
        if on { next.insert(bundleID) } else { next.remove(bundleID) }
        guard next != editors else { return }
        editors = next
        if persists { UserDefaults.standard.set(next.sorted(), forKey: Self.editorsKey) }
    }

    // MARK: Learning

    /// The user's own dictionary words, for `CorrectionExtractor`: a fix towards one of them is easier to
    /// accept. Never the words learning put there (here or on the Neo): one learned word would lower the bar
    /// for every later edit towards it.
    var knownTerms: Set<String> {
        let learned = learnedTerms.union(vocabulary.hubLearned.map { $0.lowercased() })
        return Set(vocabulary.words.filter { !learned.contains($0.lowercased()) })
    }

    /// Everything one settled edit taught (`CorrectionExtractor.extract`): mappings are recorded (an edit that
    /// fixed more words than one event takes, as several events), and so are the words learned without a
    /// mapping, which join the dictionary as learned words. When it taught nothing, why is kept in the log.
    /// Returns the events, for taking them back (the words learned alone go with them).
    /// `earlier`: the events the earlier comparisons of the same passage returned. What they remembered or
    /// learned of swaps that this comparison no longer finds there is taken back first (`takeBackSwaps`).
    @discardableResult
    func learn(_ found: Extraction, source: LearnedCorrection.Source, recordID: UUID?, app: String?,
               earlier: [LearningEvent] = []) -> [LearningEvent] {
        guard enabled else { return [] }
        let place = source == .inApp ? nil : app
        takeBackSwaps(in: earlier, goneFrom: found)
        var events: [LearningEvent] = []
        /// The day's new corrections were used up for something in this edit.
        var limited = false
        // Words typed over others that do not sound like them: remembered the first time, learned as hints
        // when the same swap is made in another dictation. Not one the user deleted from this dictation.
        let swaps = found.candidates.filter { !isDismissed($0, from: recordID) }
        if !swaps.isEmpty {
            let outcome = record(pairs: [], terms: [], candidates: swaps, source: source, recordID: recordID)
            if let event = outcome.event { events.append(event) }
            limited = limited || outcome.limited
        }
        let pairs = found.pairs
        if found.nothing == nil {
            for start in stride(from: 0, to: pairs.count, by: LearningBook.maxPairsPerEvent) {
                let some = Array(pairs[start..<min(pairs.count, start + LearningBook.maxPairsPerEvent)])
                let outcome = record(pairs: some, terms: [], source: source, recordID: recordID)
                if let event = outcome.event { events.append(event) }
                limited = limited || outcome.limited
            }
            if !found.terms.isEmpty || !found.sightings.isEmpty {
                let outcome = record(pairs: [], terms: found.terms, sightings: found.sightings, source: source, recordID: recordID)
                if let event = outcome.event { events.append(event) }
                limited = limited || outcome.limited
            }
        }
        // A name typed in the same edit that could not be learned: kept in the log, after what was learned,
        // so the user finds which word to add (the capsule has the line about what was remembered).
        defer {
            if let missed = found.missedName { record(LearningLog.Code(missed), app: place) }
        }

        let learned = events.flatMap(\.learned), terms = events.flatMap(\.terms)
        let promoted = events.flatMap(\.promoted), noted = events.flatMap(\.candidates)
        if learned.isEmpty, terms.isEmpty, promoted.isEmpty {
            if !noted.isEmpty {
                // Remembered, and said so: "记下了：X → Y，再这样改一次就记住".
                say(noted: noted, in: events, source: source, recordID: recordID, app: place)
            } else if limited {
                // The day's new corrections used up is said, and only when that is what happened.
                record(.dailyLimit, app: place)
            } else if let nothing = found.nothing {
                // By the rules the edit taught nothing, and no swap in it was remembered: why is kept. Not
                // for a swap the book holds already: a passage edited further is compared with the delivered
                // text again, the swap in it was said to be remembered then, and "没记" now would deny it.
                // Nor for one the user deleted from this dictation: they know.
                if events.isEmpty, !accounted(found.candidates, from: recordID) {
                    noteNothing(nothing, source: source, recordID: recordID, app: app)
                }
            } else if events.contains(where: { !$0.noted.isEmpty }) {
                // A capital seen for the first time, which is learned when it is given again.
                record(.seenOnce, app: place)
            } else if events.isEmpty, pairs.isEmpty, !found.isEmpty {
                // A word that taught nothing new because the dictionary has it already. (A pair changed
                // back says nothing.)
                record(.inDictionary, app: place)
            }
            return events
        }
        // One line for the whole edit (each event set its own on the way).
        let counted = events.filter { !$0.learned.isEmpty || !$0.terms.isEmpty || !$0.promoted.isEmpty }
        lastEvent = Notice(event: counted.first ?? LearningEvent(), more: Array(counted.dropFirst()), terms: terms,
                           recordID: recordID, source: source, date: Date())
        // Only swaps made a second time: said as that in the log.
        let code: LearningLog.Code = learned.isEmpty && terms.isEmpty ? .repeated : .learned
        let entry = record(code, app: place, count: learned.count + terms.count + promoted.count)
        for event in counted { logged[event.id] = entry }
        // A swap the same edit only remembered has its own line in the log; the capsule says what was learned.
        if !noted.isEmpty { say(noted: noted, in: events, source: .inApp, recordID: recordID, app: place) }
        // On the home page the line under the text says it; anywhere else the capsule does, and only what the
        // book holds now.
        if source != .inApp, let line = current(.learned(pairs: learned + promoted, terms: terms)) { onAnnounce?(line) }
        return events
    }

    /// Whether every one of `swaps` is accounted for already: the book has it (waiting for its second time,
    /// or learned as made twice), the Neo holds it as made twice, or the user deleted it from this
    /// dictation. False for none at all.
    private func accounted(_ swaps: [CorrectionPair], from recordID: UUID?) -> Bool {
        guard !swaps.isEmpty else { return false }
        let held = Set(book.candidates.map { LearningBook.key($0.pair) }
            + book.items.filter(\.isRepeated).map { LearningBook.key($0.pair) }).union(hubSwaps)
        return swaps.allSatisfy { held.contains(LearningBook.key($0)) || isDismissed($0, from: recordID) }
    }

    /// The swaps made twice that the Neo holds (`LearningBook.key`): in use from there, so one of them made
    /// here is neither remembered nor listed as waiting.
    private var hubSwaps: Set<String> {
        Set(hubEntries.filter { $0.kind == .repeated }.map { LearningBook.key($0.pair) })
    }

    /// Takes back what `events`, the earlier comparisons of one passage, remembered or learned of swaps that
    /// the passage no longer shows, by the latest comparison of it (`Extraction.shows`: a word typed in two
    /// halves, a swap changed back while its word stands elsewhere). Only those events: the same dictation
    /// may be edited in two places (where it was typed, and on the home page), and what one of them shows
    /// says nothing about the other. A swap only remembered is forgotten by itself (what else its event did
    /// stays, and nothing is said again about a swap of the same event that is still there); one learned as
    /// made twice is undone with its event, which also tells the Neo. Unlike a swap the user deleted, one
    /// that is gone may be made and remembered again in the same passage.
    private func takeBackSwaps(in events: [LearningEvent], goneFrom found: Extraction) {
        guard events.contains(where: { !$0.swaps.isEmpty }) else { return }
        let ids = Set(events.map(\.id))
        var change = Change()
        // As they are kept here: a swap the user deleted since is no longer part of its event.
        for entry in undoable.reversed() where ids.contains(entry.event.id) && entry.event.holdsSwap(goneFrom: found) {
            if entry.event.promoted.contains(where: { !found.shows($0) }) {
                revert(entry.event, into: &change)
            } else {
                for swap in entry.event.candidates where !found.shows(swap) { removeCandidate(swap, dismissing: false) }
            }
        }
        report(change)
    }

    private func isDismissed(_ swap: CorrectionPair, from recordID: UUID?) -> Bool {
        guard let recordID, !dismissedSwaps.isEmpty else { return false }
        let key = LearningBook.key(swap)
        return dismissedSwaps.contains { $0.recordID == recordID && $0.key == key }
    }

    /// The user deleted the swap `key` that dictation `recordIDs` showed: not remembered again from there.
    private func dismiss(_ key: String, from recordIDs: [UUID]) {
        dismissedSwaps = Array((dismissedSwaps + recordIDs.map { (key, $0) }).suffix(60))
    }

    /// `events` remembered the swaps `noted`: kept in the log, shown (`lastNoted`), and said on the capsule
    /// when the edit was made in another app.
    private func say(noted: [CorrectionPair], in events: [LearningEvent], source: LearnedCorrection.Source,
                     recordID: UUID?, app: String?) {
        lastNoted = Noted(pairs: noted, recordID: recordID, date: Date())
        let entry = record(.candidate, app: app, count: noted.count)
        for event in events where !event.candidates.isEmpty { loggedNotes[event.id] = entry }
        if source != .inApp, let line = current(.noted(pairs: noted)) { onAnnounce?(line) }
    }

    /// Records `pairs` from one settled edit and adds their terms to the dictionary.
    @discardableResult
    func learn(pairs: [CorrectionPair], source: LearnedCorrection.Source, recordID: UUID?) -> LearningEvent? {
        record(pairs: pairs, terms: [], source: source, recordID: recordID).event
    }

    /// Records `pairs` and `terms` (words learned without a mapping) from one settled edit and adds what they
    /// teach to the dictionary, as learned words. `sightings`: words given a capital, noted the first time
    /// and learned the second (`LearningBook.record`). `limited`: something was left out because the day's
    /// new corrections are used up.
    /// `candidates`: swaps the rules neither take nor forbid, remembered the first time and learned as hints
    /// the second (`LearningBook.record`); nothing of them goes into the dictionary.
    private func record(pairs: [CorrectionPair], terms: [String], sightings: [String] = [], candidates: [CorrectionPair] = [],
                        source: LearnedCorrection.Source, recordID: UUID?) -> (event: LearningEvent?, limited: Bool) {
        guard enabled, !pairs.isEmpty || !terms.isEmpty || !sightings.isEmpty || !candidates.isEmpty else { return (nil, false) }
        var pairs = pairs
        var change = Change(recordID: recordID)
        // A→B then B→C in one record (say a wrong IME candidate fixed again): learn A→C instead of both.
        if let recordID, let (earlier, composed) = undoable.reversed().lazy
            .filter({ $0.recordID == recordID })
            .compactMap({ e in LearningBook.chained(pairs, after: e.event.learned).map { (e.event, $0) } }).first {
            revert(earlier, into: &change)
            pairs = composed
            guard !pairs.isEmpty || !terms.isEmpty || !sightings.isEmpty || !candidates.isEmpty else {
                report(change)
                return (nil, false)
            }
        }
        // A word that is in the dictionary only because it was learned does not count as existing,
        // so a second pair teaching it is also marked as having added it.
        let existing = Set(vocabulary.words.map { $0.lowercased() }).subtracting(learnedTerms)
        var next = book
        // The reverse of a correction only the Neo has weakens that one there; it is never learned here as a
        // mapping of its own, which would leave this Mac and the Neo contradicting each other.
        let event = next.record(pairs, terms: terms, sightings: sightings, candidates: candidates, source: source,
                                recordID: recordID, heldElsewhere: hubEntries.map(\.pair),
                                repeatedElsewhere: hubEntries.filter { $0.kind == .repeated }.map(\.pair)) {
            existing.contains($0.lowercased())
        }
        let limited = !event.overLimit.isEmpty
        guard !event.isEmpty else {
            report(change)
            return (nil, limited)
        }
        let before = book
        book = next
        if !event.learned.isEmpty || !event.terms.isEmpty {
            vocabulary.addLearned(event.learned.map(\.right) + event.terms)
            lastEvent = Notice(event: event, terms: event.terms, recordID: recordID, source: source, date: Date())
        }
        forgetUntaught(since: before)
        undoable = Array((undoable + [(event, recordID, source)]).suffix(20))
        commit()
        change.unlearned += event.reversed
        change.learned += event.learned + event.terms.map(Change.word)
        change.repeated += event.promoted
        report(change)
        return (event, limited)
    }

    /// An edit was looked at and taught nothing: kept in the log, and said once per dictation when the user
    /// was fixing a term (typed a name neoless could not learn a mapping for, or one next to a secret).
    func noteNothing(_ nothing: Extraction.Nothing, source: LearnedCorrection.Source, recordID: UUID?, app: String?) {
        guard enabled else { return }
        record(LearningLog.Code(nothing), app: source == .inApp ? nil : app)
        guard LearningText.missed(nothing) != nil else { return }
        if let recordID {
            guard !missedRecords.contains(recordID) else { return }
            missedRecords = Array((missedRecords + [recordID]).suffix(20))
        }
        onAnnounce?(.missed(nothing))
    }

    /// What of `announcement` is true now: a line that waited (a dictation had the capsule) must not say
    /// "已记住" for a pair or a word that was taken back meanwhile. Nil when nothing of it is left.
    func current(_ announcement: Announcement) -> Announcement? {
        if case .noted(let pairs) = announcement {
            // "记下了" only for what still waits for its second time.
            let waiting = Set(book.candidates.map { LearningBook.key($0.pair) })
            let kept = pairs.filter { waiting.contains(LearningBook.key($0)) }
            return kept.isEmpty ? nil : .noted(pairs: kept)
        }
        guard case let .learned(pairs, terms) = announcement else { return announcement }
        let held = Set(book.items.map { LearningBook.key($0.pair) })
        let words = Set(book.terms.map { $0.term.lowercased() })
        let kept = pairs.filter { held.contains(LearningBook.key($0)) }
        let keptTerms = terms.filter { words.contains($0.lowercased()) }
        return kept.isEmpty && keptTerms.isEmpty ? nil : .learned(pairs: kept, terms: keptTerms)
    }

    /// A paste landed where its text could not be found again (`why`: the field does not say what is in it,
    /// the text is not in it, it holds too much text, the app did not answer, or it is an editor learning is
    /// not switched on for): edits there cannot be seen. The home page hints at it for that record; the
    /// capsule says it once per app per launch; the log keeps one line per app.
    func noteUnwatched(_ why: LearningLog.Code, app: String?, recordID: UUID) {
        guard enabled else { return }
        unsupportedRecordID = recordID
        record(why, app: app)
        if hintedApps.insert(app ?? "").inserted { onAnnounce?(.unwatched(app: app)) }
    }

    /// Reverts one event when the edit that taught it is taken back (the text in the field is as it was).
    func undo(_ event: LearningEvent) {
        guard undoable.contains(where: { $0.event.id == event.id }) else { return }
        var change = Change()
        revert(event, into: &change)
        report(change)
    }

    /// 撤销 on the "已记住" line: the text stays as the user left it. The words learned without a mapping
    /// are in the events, so they go too.
    func undoLastEvent() {
        guard let notice = lastEvent else { return }
        var change = Change()
        // A swap among it is not learned or remembered again from this dictation: the passage still shows
        // it, and is compared with the delivered text again when it is edited further.
        if let recordID = notice.recordID {
            for event in [notice.event] + notice.more {
                for swap in event.promoted + event.candidates { dismiss(LearningBook.key(swap), from: [recordID]) }
            }
        }
        for event in ([notice.event] + notice.more).reversed() { revert(event, into: &change) }
        lastEvent = nil
        report(change)
    }

    /// Undoes `event` here and adds what that does to the counts to `change`: what it counted up goes down
    /// again, what it counted down (changed back) goes up.
    private func revert(_ event: LearningEvent, into change: inout Change) {
        guard let i = undoable.firstIndex(where: { $0.event.id == event.id }) else { return }
        let recordID = undoable[i].recordID
        // As it is kept here: a swap of it the user deleted since (`removeCandidate`) is no longer part of it.
        let event = undoable[i].event
        undoable.remove(at: i)
        change.recordID = change.recordID ?? recordID
        change.unlearned += event.learned + event.terms.map(Change.word) + event.promoted
        // What it counted down goes up again, each as what it is: a swap made twice sent as a plain
        // correction would be judged as a recognition error by the Neo, and refused.
        change.learned += event.reversedByKind.fixes
        change.repeated += event.reversedByKind.swaps
        let before = book
        // A word the user has as their own now stays theirs, even when the undo brings back an older copy
        // of an item that still says learning added it.
        let manual = Set(vocabulary.words.map { $0.lowercased() }).subtracting(learnedTerms)
        book.undo(event, manualTerms: manual)
        forgetUntaught(since: before)
        let restored = book.items.filter { item in item.addedTerm && !before.items.contains { $0.id == item.id } }
            .map(\.pair.right) + book.terms.filter { term in !before.terms.contains { $0.id == term.id } }.map(\.term)
        if !restored.isEmpty { vocabulary.addLearned(restored) }
        if let notice = lastEvent, notice.id == event.id || notice.more.contains(where: { $0.id == event.id }) { lastEvent = nil }
        // The log no longer says these words are remembered.
        if let entry = logged.removeValue(forKey: event.id) {
            history.takeBack(event.learned.count + event.terms.count + event.promoted.count, from: entry)
            log = history.entries
            saveLog()
        }
        // Nor that a swap is remembered.
        if let entry = loggedNotes.removeValue(forKey: event.id) {
            history.takeBack(event.candidates.count, from: entry)
            log = history.entries
            saveLog()
        }
        if let noted = lastNoted, !event.candidates.isEmpty {
            let gone = Set(event.candidates.map(LearningBook.key))
            let left = noted.pairs.filter { !gone.contains(LearningBook.key($0)) }
            lastNoted = left.isEmpty ? nil : Noted(pairs: left, recordID: noted.recordID, date: noted.date)
        }
        commit()
    }

    private func report(_ change: Change) {
        if !change.isEmpty { onChange?(change) }
    }

    func remove(id: UUID) {
        guard let item = book.remove(id: id) else { return }
        // A swap made twice that was deleted is not remembered afresh from a passage that still shows it.
        if item.isRepeated { dismiss(LearningBook.key(item.pair), from: item.recordIDs) }
        // Gone here at once; the Neo's copy goes when `HubSync` reaches it.
        hubEntries = HubLearning.without(forgotten: [item.pair.wrong], hubEntries)
        onForget?([item.pair.wrong])
        var before = book
        before.items.append(item)
        forgetUntaught(since: before)
        // Undoing an event that touched this item would bring it back.
        undoable.removeAll { $0.event.added.contains(id) || $0.event.previous.contains { $0.id == id } }
        if let notice = lastEvent, !undoable.contains(where: { $0.event.id == notice.id }) { lastEvent = nil }
        commit()
    }

    /// Forgets a correction only the Neo has (the dictionary page lists those too).
    func removeFromHub(wrong: String) {
        hubEntries = HubLearning.without(forgotten: [wrong], hubEntries)
        onForget?([wrong])
        publish()
    }

    /// Forgets a swap that was only remembered (its row on the dictionary page was deleted, or 撤销 on the
    /// line that said it). `dismissing`: the user did it, so the swap is not remembered again from the
    /// dictation it was made in; false when the passage simply no longer shows it (`takeBackSwaps`).
    func removeCandidate(_ pair: CorrectionPair, dismissing: Bool = true) {
        guard let removed = book.removeCandidate(pair) else { return }
        let key = LearningBook.key(pair)
        // The passage it was made in may still be watched, and edited further.
        if dismissing { dismiss(key, from: removed.recordID.map { [$0] } ?? []) }
        // The event that remembered it has that much less to take back (what else it did can still be
        // undone), and the log no longer says the swap is remembered.
        for i in undoable.indices where undoable[i].event.candidates.contains(where: { LearningBook.key($0) == key }) {
            undoable[i].event.candidates.removeAll { LearningBook.key($0) == key }
            undoable[i].event.previousCandidates.removeAll { LearningBook.key($0.pair) == key }
            if let entry = loggedNotes[undoable[i].event.id] {
                history.takeBack(1, from: entry)
                log = history.entries
                saveLog()
            }
        }
        for gone in undoable where gone.event.isEmpty { loggedNotes[gone.event.id] = nil }
        undoable.removeAll { $0.event.isEmpty }
        if let noted = lastNoted {
            let left = noted.pairs.filter { LearningBook.key($0) != key }
            lastNoted = left.isEmpty ? nil : Noted(pairs: left, recordID: noted.recordID, date: noted.date)
        }
        commit()
    }

    /// 撤销 on the "记下了" line: the swaps the latest edit remembered are forgotten again. The text stays as
    /// the user left it.
    func forgetLastNoted() {
        guard let noted = lastNoted else { return }
        for pair in noted.pairs { removeCandidate(pair) }
        lastNoted = nil
    }

    func clearAll() {
        let all = book.items
        // The Neo's own are listed with this Mac's, so 清空 forgets those too.
        let wrongs = all.map(\.pair.wrong) + hubEntries.map(\.wrong)
        hubEntries = []
        var seen = Set<String>()
        onForget?(wrongs.filter { seen.insert($0).inserted })
        let before = book
        book = LearningBook()
        forgetUntaught(since: before)
        // The words learned without a mapping are taken back on the Neo too.
        report(Change(unlearned: before.terms.map { Change.word($0.term) }))
        undoable = []
        lastEvent = nil
        lastNoted = nil
        dismissedSwaps = []
        // What became of earlier edits goes with what they taught, and so does what was counted towards
        // offering a habit. (我的习惯 are the user's own words, not something learned: they stay.)
        clearLog()
        clearHabitNotes()
        publish()
        if persists { AppFiles.remove(file) }
    }

    /// Empties the list of what became of recent edits (最近的修改), on disk too.
    func clearLog() {
        history.clear()
        logged = [:]
        loggedNotes = [:]
        log = []
        saveLog()
    }

    // MARK: Using what was learned

    /// `text` with the corrections the user has confirmed (fixed in at least `LearningPrompt.confirmedCount`
    /// dictations) applied without asking ChatGPT. For text typed as is: 原样转写, and the original
    /// transcript typed after a failed polish.
    func applyConfirmed(_ text: String) -> String {
        dictionaryChanged()
        return LearningPrompt.applyConfirmed(text, book: promptBook)
    }

    /// Learned pairs worth sending with this transcript to `Polisher.polish(corrections:)`.
    func promptPairs(for transcript: String) -> [CorrectionPair] {
        dictionaryChanged()
        return LearningPrompt.pairs(for: transcript, from: promptBook)
    }

    /// What else a polish of this transcript is given (`Polisher.polish(extras:)`): the swaps made twice whose
    /// first word is in it, and 我的习惯. The habits go along whether 自动学习 is on or not: the user wrote them.
    func promptExtras(for transcript: String) -> PolishExtras {
        dictionaryChanged()
        return PolishExtras(repeated: LearningPrompt.repeated(for: transcript, from: promptBook), habits: habitList.items)
    }

    /// Whether the stored correction `pair` is one today's rules would not learn: listed, and not used.
    func isUnused(_ pair: CorrectionPair) -> Bool {
        unused.contains(LearningBook.key(pair))
    }

    /// The user's own dictionary words may have changed: a correction is judged against them (one learned
    /// towards a word that was taken out is no longer used; one whose word was added is). Cheap when they
    /// have not.
    func dictionaryChanged() {
        if knownTerms != judged.known { publish() }
    }

    /// The Neo's learned corrections, from the latest sync (empty when unpaired). `known`: a Neo is paired
    /// and was synced with; `words`: its dictionary then; `pending`: this Mac's corrections (`LearningBook.key`)
    /// that wait to go to it or went since that sync, which are not called missing there yet.
    func setHub(_ entries: [LearningEntry], words: [String] = [], known: Bool = false, pending: Set<String> = []) {
        hubEntries = entries
        hubWords = words
        hubKnown = known
        hubPending = pending
        publish()
    }

    /// What waits to go to the Neo changed (`setHub`'s `pending`).
    func setHubPending(_ pending: Set<String>) {
        guard pending != hubPending else { return }
        hubPending = pending
        publish()
    }

    /// Whether the Neo (as of the latest sync) has `pair`: in its list, or, for a word learned without a
    /// mapping (`Change.word`), in its dictionary as a learned word.
    func hubHas(_ pair: CorrectionPair) -> Bool {
        if pair.wrong.isEmpty { return vocabulary.isHubLearned(pair.right) }
        return HubLearning.contains(hubEntries, pair)
    }

    /// A sync came back after corrections were sent (`sent`, by `LearningBook.key`): those of them this Mac
    /// holds and the Neo's list still lacks were not taken there. Said in the log, once for that sending.
    /// Read off the Neo's list rather than its answers, so it also holds for a Neo from before answers named
    /// what was refused, and for a pair of which the Neo kept only the word.
    func noteNotTaken(sent: Set<String>) {
        guard enabled else { return }
        let count = sent.filter { notOnHub[$0] != nil }.count
        if count > 0 { record(.hubRefused, app: nil, count: count) }
    }

    /// What the Neo holds of this Mac's correction `pair` when it does not hold the correction itself; nil
    /// when it has it, when it is on its way there, or when no Neo is paired.
    func hubHolding(of pair: CorrectionPair) -> HubLearning.Holding? {
        notOnHub[LearningBook.key(pair)]
    }

    // MARK: 我的习惯

    /// The user's own list, as the dictionary page edited it: cleaned (`Habits.normalized`: one line each, at
    /// most `Habits.maxItems` of `Habits.maxLength` characters, nothing that poses as instructions), saved,
    /// and taken to the Neo.
    func setHabits(_ items: [String]) {
        let next = Habits(items)
        guard next != habitList else { return }
        habitList = next
        habitsChanged(here: true)
    }

    /// Adds one habit at the end. False when nothing was added: it cleans to nothing, is there already, or
    /// the list is full (`Habits.maxItems`).
    @discardableResult
    func addHabit(_ text: String) -> Bool {
        guard habitList.add(text) else { return false }
        habitsChanged(here: true)
        return true
    }

    func removeHabit(_ text: String) {
        guard habitList.remove(text) else { return }
        habitsChanged(here: true)
    }

    /// The Neo's list becomes this Mac's (`HubSync`: it was changed on another device, or the two were
    /// brought together). Not sent back.
    func mirrorHabits(_ items: [String]) {
        let next = Habits(items)
        guard next != habitList else { return }
        habitList = next
        habitsChanged(here: false)
    }

    /// What the Neo has of the habits, as the latest sync found it (`HubSync`).
    func setHabitsOnHub(_ state: HabitsOnHub) {
        if state != habitsOnHub { habitsOnHub = state }
    }

    private func habitsChanged(here: Bool) {
        habits = habitList.items
        if persists {
            if habitList.isEmpty { AppFiles.remove(habitsFile) } else { AppFiles.write(habitList, to: habitsFile) }
        }
        // A habit the user now has is not offered.
        refreshSuggestion()
        guard here else { return }
        if habitsOnHub == .same { habitsOnHub = .waiting }
        onHabitsChange?()
    }

    /// What the passage of dictation `recordID` shows now, compared with the text as it was delivered, that
    /// is no word fix and could be a habit (`HabitDetector`: the final stop taken off, a filler deleted, a
    /// list turned into running text or back). Counted once for each dictation; seen in
    /// `HabitBook.threshold` of them, the habit is offered (`suggestion`). Only the pattern is kept (for a
    /// deleted word, that word), never the text.
    func notePatterns(original: String, edited: String, recordID: UUID, app: String?) {
        guard enabled else { return }
        guard habitBook.note(HabitDetector.patterns(original: original, edited: edited), recordID: recordID, app: app) else { return }
        saveHabitNotes()
        refreshSuggestion()
    }

    /// The user took the offered habit: it joins 我的习惯, and is not offered again. False when it could not
    /// be added (the list is full): the offer then stays.
    @discardableResult
    func acceptSuggestion() -> Bool {
        guard let offered = suggestion, addHabit(offered.wording) else { return false }
        habitBook.answer(offered.key)
        saveHabitNotes()
        refreshSuggestion()
        return true
    }

    /// The user turned the offer down: that pattern is not offered again for `HabitBook.quiet`.
    func declineSuggestion() {
        guard let offered = suggestion else { return }
        habitBook.answer(offered.key)
        saveHabitNotes()
        refreshSuggestion()
    }

    private func refreshSuggestion() {
        let next = enabled ? habitBook.suggestion(habits: habitList.items) : nil
        if next != suggestion { suggestion = next }
    }

    private func clearHabitNotes() {
        habitBook.clear()
        saveHabitNotes()
        refreshSuggestion()
    }

    private func saveHabitNotes() {
        guard persists else { return }
        if keepsLog, !habitBook.isEmpty { AppFiles.write(habitBook, to: habitNotesFile) } else { AppFiles.remove(habitNotesFile) }
    }

    // MARK: Dictionary

    /// The word is in the dictionary only because it was learned, here or on the Neo (the 自动 tag).
    func isLearnedTerm(_ word: String) -> Bool {
        learnedTerms.contains(word.lowercased()) || vocabulary.isHubLearned(word)
    }

    /// The user added these words by hand (same separators as `VocabularyStore.add`):
    /// forgetting a pair must no longer remove them.
    func markManual(_ text: String) {
        let terms = text.components(separatedBy: CharacterSet(charactersIn: ",，、\n;；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isLearnedTerm($0) }
        guard !terms.isEmpty else { return }
        for term in terms { book.markManualTerm(term) }
        commit()
    }

    /// `--snapshot` only: shows a learning notice or the unsupported-app hint without learning anything.
    func _debugSet(notice pairs: [CorrectionPair]?, recordID: UUID?, unsupported: UUID? = nil) {
        lastEvent = pairs.map { Notice(event: LearningEvent(learned: $0), recordID: recordID, source: .otherApp, date: Date()) }
        unsupportedRecordID = unsupported
    }

    /// `--snapshot` only: shows habits, an offered habit and remembered swaps without anything being learned
    /// or written to disk (the store is a preview one). `noted`: the record the newest swap was just made in,
    /// for the "记下了" line under it. `log`: what 最近的修改 lists, newest first.
    func _debugSet(habits items: [String], suggestion offered: HabitSuggestion? = nil,
                   candidates swaps: [LearningBook.Candidate] = [], onHub: HabitsOnHub = .unknown,
                   noted: UUID? = nil, log entries: [LearningLog.Entry]? = nil) {
        guard !persists else { return }
        habitList = Habits(items)
        habits = habitList.items
        suggestion = offered
        habitsOnHub = onHub
        book.candidates = swaps
        lastNoted = noted.flatMap { id in swaps.first.map { Noted(pairs: [$0.pair], recordID: id, date: Date()) } }
        if let entries { log = entries }
        publish()
    }

    // MARK: Private

    /// Returns the id of the log entry that says it.
    @discardableResult
    private func record(_ code: LearningLog.Code, app: String?, count: Int = 0) -> UUID {
        let entry = history.add(code, app: app, count: count)
        log = history.entries
        saveLog()
        return entry
    }

    /// The log is kept on disk only while 保存历史 is on: with it off, nothing about what the user dictated
    /// (not even which app and when) outlives this launch.
    private var keepsLog: Bool {
        persists && (UserDefaults.standard.object(forKey: "keepHistory") as? Bool ?? true)
    }

    private func saveLog() {
        guard persists else { return }
        if keepsLog, !history.entries.isEmpty { AppFiles.write(history, to: logFile) } else { AppFiles.remove(logFile) }
    }

    /// Takes out of the dictionary the words that were in it only because `before` taught them and that
    /// nothing teaches any more (a correction forgotten or undone, a word learned alone taken back).
    private func forgetUntaught(since before: LearningBook) {
        let gone = before.learnedOnlyTerms.filter { !book.teaches($0) }
        guard !gone.isEmpty else { return }
        for word in vocabulary.words where gone.contains(word.lowercased()) { vocabulary.remove(word) }
    }

    private func commit() {
        publish()
        if persists { AppFiles.write(book, to: file) }
    }

    private func publish() {
        items = book.items
        // A swap the Neo already holds as made twice is in use, not waiting: it is listed once, as the Neo's.
        let elsewhere = hubSwaps
        let waiting = elsewhere.isEmpty ? book.candidates : book.candidates.filter { !elsewhere.contains(LearningBook.key($0.pair)) }
        if candidates != waiting { candidates = waiting }
        learnedTerms = book.learnedOnlyTerms
        // What today's rules would not learn is used for nothing, wherever it is stored.
        let merged = HubLearning.merged(book, hub: hubEntries)
        let known = knownTerms
        if known != judged.known { judged = (known, [:]) }
        let off = merged.unusable(knownTerms: known, verdicts: &judged.verdicts)
        if off != unused { unused = off }
        promptBook = merged.without(off)
        let own = Set(book.items.map { LearningBook.key($0.pair) })
        hubItems = hubEntries.filter { !own.contains(LearningBook.key($0.pair)) }
            .sorted { ($0.count, $0.lastSeen) > ($1.count, $1.lastSeen) }
        let missing = hubKnown ? HubLearning.missing(from: hubEntries, hubWords: hubWords, book: book, pending: hubPending) : [:]
        if missing != notOnHub { notOnHub = missing }
        // Learned-only terms, most often fixed first and the words learned without a mapping last, for the
        // recognizer hints and the prompt word list.
        vocabulary.setLearned(book.learnedRanking)
    }
}
