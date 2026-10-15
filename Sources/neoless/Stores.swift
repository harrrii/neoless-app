import Foundation
import NeolessCloud
import NeolessCore

/// ~/Library/Application Support/neoless, owner-only (0700 dir, 0600 files). A file that does not read back
/// is set aside, never overwritten or deleted without a backup (`DataFileStore`).
enum AppFiles {
    static let store = DataFileStore.applicationSupport("neoless")

    static var directory: URL { store.directory }

    /// Backups made this launch of files that did not read back (`history.json.corrupt-20261007-204500`),
    /// so the window can say what happened. Nothing shows them yet.
    static var recovered: [String] { store.recovered }

    static func url(_ name: String) -> URL { store.url(name) }

    /// The decoded file, or nil when it is missing or was set aside because it did not decode.
    static func read<T: Decodable>(_ type: T.Type, from name: String) -> T? { store.read(type, from: name) }

    /// Like `read`, for a JSON array: records that do not decode are skipped (the original is backed up first).
    static func readList<T: Decodable>(_ type: T.Type, from name: String) -> [T]? { store.readList(type, from: name) }

    /// Returns false when nothing was written (see `DataFileStore.write`).
    @discardableResult
    static func write<T: Encodable>(_ value: T, to name: String) -> Bool { store.write(value, to: name) }

    /// Deletes a data file; one that did not read back is deleted only once a backup of it exists.
    @discardableResult
    static func remove(_ name: String) -> Bool { store.remove(name) }

    /// Deletes a data file and all its backups (signing out of ChatGPT; see `DataFileStore.purge`).
    @discardableResult
    static func purge(_ name: String) -> Bool { store.purge(name) }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var records: [DictationRecord] = []
    private let file = "history.json"
    private var persists = true

    init() {
        records = HistoryRetention.prune(AppFiles.readList(DictationRecord.self, from: file) ?? [])
    }

    /// In-memory store for `--snapshot`; never touches disk.
    init(preview: [DictationRecord]) {
        records = preview
        persists = false
    }

    func add(_ record: DictationRecord) {
        records = HistoryRetention.prune([record] + records)
        save()
    }

    func update(_ record: DictationRecord) {
        guard let i = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[i] = record
        save()
    }

    func delete(_ id: UUID) {
        records.removeAll { $0.id == id }
        save()
    }

    func deleteAll() {
        records = []
        save()
    }

    private func save() { if persists { AppFiles.write(records, to: file) } }
}

/// 今日概览's numbers (`UsageStats`): per day, how many dictations, how many 字, how many seconds of speech.
/// No text. Counted when a dictation is delivered, whether or not it is also kept in history, and saved to
/// `usage.json` beside the other data files.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var stats: UsageStats
    /// The day it is now where the user is; follows midnight and a change of time zone.
    @Published private(set) var today: UsageDate
    /// 1 = Sunday, 2 = Monday: where the user's weeks start (系统设置 › 通用 › 语言与地区).
    let firstWeekday: Int
    private let file = "usage.json"
    private var persists = true
    private var observers: [NSObjectProtocol] = []

    /// Reads the saved stats. On the first launch of a build that has them, the dictations already in
    /// history (`history`, at most the last 30 days) are counted once.
    init(history: [DictationRecord]) {
        var stats = AppFiles.read(UsageStats.self, from: file) ?? UsageStats()
        let backfilled = stats.backfill(from: history, timeZone: .autoupdatingCurrent)
        self.stats = stats
        today = UsageDate(Date(), timeZone: .autoupdatingCurrent)
        firstWeekday = Calendar.current.firstWeekday
        if backfilled { save() }
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshToday() }
            })
        }
    }

    /// In-memory store for `--snapshot`; never touches disk.
    init(preview: UsageStats, today: UsageDate, firstWeekday: Int = 1) {
        stats = preview
        self.today = today
        self.firstWeekday = firstWeekday
        persists = false
    }

    /// A dictation ended with text. It counts when the text reached the user (typed, copied or shown in
    /// neoless); one that went nowhere (the paste stopped with Esc, a password field) changes nothing.
    func add(_ record: DictationRecord) {
        guard stats.add(record, timeZone: .autoupdatingCurrent) else { return }
        refreshToday()
        save()
    }

    /// The window is about to show: the day may have changed while the Mac slept.
    func refreshToday() {
        guard persists else { return }
        let now = UsageDate(Date(), timeZone: .autoupdatingCurrent)
        if now != today { today = now }
    }

    private func save() { if persists { AppFiles.write(stats, to: file) } }
}

@MainActor
final class VocabularyStore: ObservableObject {
    /// Most recent first, exactly as the dictionary page lists it; learned terms are mixed in. The hint and
    /// prompt lists below put the user's own words first by `learnedRanking`, not by position, so this
    /// order never changes behind the user's back.
    @Published private(set) var words: [String]
    /// Terms in the dictionary only because learning added them, most useful first. `LearningStore` keeps
    /// this current through `setLearned`; every other word counts as the user's own.
    private(set) var learnedRanking: [String] = []
    /// The words in the Neo's dictionary only because its learning added them (`HubSync`).
    private(set) var hubLearned: [String] = []
    /// The user typed or removed words on the dictionary page: `HubSync` takes the change to the Neo.
    var onUserEdit: ((VocabularyEdit) -> Void)?
    private let file = "vocabulary.json"
    private var persists = true

    /// Hints for the speech recognizer (`SpeechSession(localeID:hints:)`, `SpeechSession.recognize(...hints:)`):
    /// the user's own words first, at most `Vocabulary.learnedHintLimit` learned terms.
    var recognizerHints: [String] { Vocabulary.recognizerHints(words, learned: allLearned) }
    /// The word lists for `Polisher.polish(vocabulary:)`: the user's own words, and apart from them the learned
    /// terms within `Vocabulary.learnedPromptBudget` characters, which the prompt weighs less.
    var promptWords: Vocabulary.PromptWords { Vocabulary.promptWords(words, learned: allLearned) }

    /// Learned-only terms, this Mac's first, then the Neo's.
    private var allLearned: [String] {
        guard !hubLearned.isEmpty else { return learnedRanking }
        let own = Set(learnedRanking.map { $0.lowercased() })
        return learnedRanking + hubLearned.filter { !own.contains($0.lowercased()) }
    }

    /// This Mac's learned-only terms that are in the dictionary now (one the user took out stays out).
    var learnedInWords: [String] {
        let listed = Set(words.map { $0.lowercased() })
        return learnedRanking.filter { listed.contains($0.lowercased()) }
    }

    func isHubLearned(_ word: String) -> Bool {
        let key = word.lowercased()
        return hubLearned.contains { $0.lowercased() == key }
    }

    init() {
        words = Vocabulary.normalize(AppFiles.read([String].self, from: file) ?? Vocabulary.defaults)
    }

    /// In-memory store for `--snapshot`: never reads the user's dictionary and never touches disk.
    init(preview: [String]) {
        words = Vocabulary.normalize(preview)
        persists = false
    }

    /// Words the user typed. They go to the front and count as the user's own from now on, even when a
    /// learned pair teaches the same word (`LearningStore.markManual` makes that permanent).
    func add(_ text: String) {
        // Accept several words at once, separated by commas, 、 or new lines.
        let new = text.components(separatedBy: CharacterSet(charactersIn: ",，、\n;；"))
        let key = { (word: String) in word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let typed = Set(new.map(key))
        learnedRanking.removeAll { typed.contains(key($0)) }
        hubLearned.removeAll { typed.contains(key($0)) }
        words = Vocabulary.adding(new, to: words, learned: learnedRanking)
        save()
        let added = new.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !added.isEmpty { onUserEdit?(.add(added)) }
    }

    /// Terms learning taught. New ones go to the front; a word already in the dictionary keeps its place,
    /// so learning never reorders the user's list.
    func addLearned(_ terms: [String]) {
        let next = Vocabulary.addingLearned(terms, to: words, learned: learnedRanking)
        guard next != words else { return }
        words = next
        save()
    }

    /// Called by `LearningStore` whenever its items change, with the learned-only terms most useful first.
    /// Only the ranking changes; `words` keeps the user's order.
    func setLearned(_ ranking: [String]) {
        learnedRanking = ranking
    }

    func remove(_ word: String) {
        words.removeAll { $0 == word }
        save()
    }

    /// The user took `word` out on the dictionary page (not learning forgetting a term it had added).
    func removeByUser(_ word: String) {
        remove(word)
        onUserEdit?(.remove(word))
    }

    /// The Neo's dictionary, as this Mac's (`HubSync`): `merged` already holds the changes the Neo does not have yet.
    func mirror(_ merged: [String], hubLearned: [String]) {
        self.hubLearned = hubLearned
        let next = Vocabulary.normalize(merged)
        guard next != words else { return }
        words = next
        save()
    }

    func setHubLearned(_ terms: [String]) {
        hubLearned = terms
    }

    private func save() { if persists { AppFiles.write(words, to: file) } }
}
