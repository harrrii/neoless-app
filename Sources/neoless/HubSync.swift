import Foundation
import NeolessCloud
import NeolessCore

/// Keeps this Mac's dictionary and learned corrections in step with the Neo while 用 Neo 处理 is on. Corrections
/// learned here (in other apps, on the home page, and changed back or undone), the text of the Neo's dictations
/// edited here and corrections forgotten go to the Neo through an outbox (hub-outbox.json) that waits while it
/// cannot be reached, a few requests a minute at most (`HubOutbox.requestsPerMinute`). What the Neo knows comes
/// back at launch and every few minutes (`GET /v1/sync`, kept in hub-sync.json): its dictionary becomes this Mac's,
/// for the recognizer's hints, once the words added or removed here since the last sync have gone there
/// (`HubVocabulary.reconcile`, against the Neo's words at that sync), and its corrections join this Mac's for the
/// dictations it does itself. Pairing with a Neo for the first time also gives it this Mac's most used corrections.
/// 我的习惯 are brought together with the Neo's at each sync (`HubHabits.reconcile`, against the Neo's list at the
/// last sync): changed here they go there (`PUT /v1/habits`), changed on another device they come here. A Neo
/// from before habits has none in its sync answer; nothing is sent to it, and the habits are then used only
/// for what this Mac polishes itself.
///
/// Which of this Mac's corrections the Neo does not hold is read off its list at each sync (`LearningStore.notOnHub`,
/// the tag on the dictionary page), not remembered from its answers, so it is the same after a relaunch. When the
/// Neo says it is another version than the one this Mac last saw, the corrections it lacks are offered to it once
/// more (`HubLearning.resend`): its rules may take now what they turned down before.
@MainActor
final class HubSync {
    static let interval: TimeInterval = 5 * 60
    /// The Neo (its address) that was given this Mac's most used corrections: once per Neo.
    private static let seededKey = "hubSeededServer"
    /// Those corrections are still in the outbox: an unpairing that throws the outbox away lets the next pairing
    /// with that Neo give them again.
    private static let seedWaitingKey = "hubSeedWaiting"
    /// The Neo and its version ("address|version") this Mac last offered its missing corrections to; `seeded`
    /// in place of the version right after the first pairing, when the seed has just gone and nothing is missing yet.
    private static let resentKey = "hubResentFor"
    private static let justSeeded = "seeded"
    private static let outboxFile = "hub-outbox.json"
    private static let cacheFile = "hub-sync.json"

    private let hub: HubConnection
    private let vocabulary: VocabularyStore
    private let learning: LearningStore
    /// The Neo's id of a dictation record here, for corrections learned from it.
    var hubID: (UUID) -> UUID? = { _ in nil }

    private var outbox: HubOutbox
    /// What a flush is sending and has not sent yet: saved with the outbox as it shrinks, so quitting meanwhile
    /// neither loses it nor sends again what went.
    private var inFlight: HubOutbox?
    /// Edits a repolish took out while a flush was carrying them: not put back when the flush returns.
    private var takenEdits = Set<UUID>()
    /// When this Mac's flushes sent their requests (the last minute), for `HubOutbox.requestsPerMinute`.
    private var sentAt: [Date] = []
    /// Corrections sent since the last sync (`LearningBook.key`): the Neo has them, though its list here does not
    /// show them yet, so taking one back sends the reverse.
    private var sentSinceSync = Set<String>()
    /// The Neo's corrections as last given (a sync, or the answer to a forget); nil before the first sync with
    /// this Neo.
    private var hubList: LearningList?
    /// The Neo's words at the last sync: what the dictionaries are compared against. Nil before the first sync
    /// with this Neo.
    private var base: [String]?
    /// The Neo's dictionary `base` came from (`VocabularySnapshot.generation`): a Neo whose dictionary started over
    /// since is compared as at a first sync, so this Mac's words are not taken for removed there.
    private var baseGeneration: String?
    /// The Neo's habits at the last sync: what this Mac's are compared against. Nil before the first sync with
    /// this Neo, and for a Neo from before habits.
    private var hubHabits: HabitsSnapshot?
    /// How many syncs in a row found the Neo's habits changed under them (409). The first is compared again
    /// at once; after `habitRetries` it waits for the next sync, so a Neo that goes on refusing is not asked
    /// over and over.
    private var habitConflicts = 0
    private static let habitRetries = 2
    private var running: Task<Void, Never>?
    private var again = false
    private var soon: Task<Void, Never>?
    private var timer: Timer?
    /// Bumped when the pairing goes (`reset`): a sync that began before leaves the outbox, the cache and the
    /// dictionary alone when its calls come back, since what it carried and fetched belongs to the old Neo.
    private var epoch = 0

    init(hub: HubConnection, vocabulary: VocabularyStore, learning: LearningStore) {
        self.hub = hub
        self.vocabulary = vocabulary
        self.learning = learning
        outbox = AppFiles.read(HubOutbox.self, from: Self.outboxFile) ?? HubOutbox()
        if let cache = AppFiles.read(SyncSnapshot.self, from: Self.cacheFile) {
            base = cache.vocabulary.words
            baseGeneration = cache.vocabulary.generation
            hubHabits = cache.habits
            // As of the last sync, until the next one says more (a cache from before habits says nothing).
            if hub.pairing != nil, let theirs = cache.habits {
                learning.setHabitsOnHub(Habits.normalized(learning.habits) == Habits.normalized(theirs.items) ? .same : .waiting)
            }
            setHubLearning(cache.learning)
            vocabulary.setHubLearned(cache.vocabulary.learned)
        }
        learning.onChange = { [weak self] change in self?.learningChanged(change) }
        learning.onForget = { [weak self] wrongs in
            guard let self, self.hub.pairing != nil else { return }
            wrongs.forEach { self.outbox.forget($0) }
            self.queued()
            // Forgotten here: no longer used from the Neo's list either, whatever its next answer says.
            self.tellLearning()
        }
        vocabulary.onUserEdit = { [weak self] _ in
            // Compared and sent with the next sync, whenever the Neo can be reached.
            self?.syncSoon(after: 1)
        }
        learning.onHabitsChange = { [weak self] in
            // The same for 我的习惯.
            guard let self, self.hub.pairing != nil else { return }
            self.syncSoon(after: 1)
        }
        hub.onReady = { [weak self] in
            self?.seedIfNew()
            self?.sync()
        }
        hub.onUnpaired = { [weak self] in self?.reset() }
        seedIfNew()
    }

    /// Every few minutes; the first one when the Neo first answers (`HubConnection.onReady`).
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    // MARK: Changes made here

    /// Corrections counted up or down on this Mac: the Neo makes the same change, from observations (the learning
    /// from an edit of the Neo's own dictation too: its edits carry the text only, `HubOutbox.Edit.learn`). While
    /// paired, changes wait in the outbox even with 用 Neo 处理 switched off, and go when it is on again.
    private func learningChanged(_ change: LearningStore.Change) {
        guard hub.pairing != nil else { return }
        // The Neo's id of the dictation, or for one this Mac did itself the record's own id: the Neo counts a
        // pair once for each such id and keeps the ids with its corrections, so an observation sent again
        // after a lost answer is never counted twice, also when the Neo restarted in between.
        let dictation = change.recordID.map { hubID($0) ?? $0 }
        let before = outbox
        for pair in change.unlearned {
            outbox.unlearn(pair, dictationID: dictation, hubHas: neoHas(pair))
        }
        // With an id of its own, so it can go again when its answer is lost (`HubClient.flush`).
        outbox.observe(change.learned, dictationID: dictation, id: UUID())
        // Swaps made twice go as that: by the rules for recognition errors the Neo would take none of them.
        outbox.observe(change.repeated, dictationID: dictation, id: UUID(), kind: .repeated)
        if outbox != before { queued() }
    }

    /// Whether the Neo has `pair`: in its list at the last sync, sent since, or being sent now. (One that was
    /// sent before and got no answer is seen to by `HubOutbox.unlearn` itself.)
    private func neoHas(_ pair: CorrectionPair) -> Bool {
        let key = LearningBook.key(pair)
        return learning.hubHas(pair) || sentSinceSync.contains(key)
            || (inFlight?.observations.contains { $0.pairs.contains { LearningBook.key($0) == key } } ?? false)
    }

    /// This Mac's corrections that are on their way to the Neo, or went since its list was last taken: not to
    /// be called missing there yet.
    private var pendingKeys: Set<String> {
        var keys = sentSinceSync
        for observation in outbox.observations + (inFlight?.observations ?? []) {
            keys.formUnion(observation.pairs.map(LearningBook.key))
        }
        return keys
    }

    /// Gives `LearningStore` the Neo's corrections (without those forgotten here that the Neo has not forgotten
    /// yet: still in the outbox, or being sent) and what it needs to say which of this Mac's the Neo lacks.
    private func tellLearning() {
        guard let hubList else { return learning.setHub([]) }
        let forgotten = outbox.forgotten + (inFlight?.forgotten ?? [])
        learning.setHub(HubLearning.without(forgotten: forgotten, hubList.pairs), words: base ?? [],
                        known: hub.pairing != nil, pending: pendingKeys)
    }

    /// The user changed the text of the Neo's dictation `id` on the home page: the Neo keeps the text (what it
    /// teaches goes as observations, `learningChanged`).
    func edited(_ id: UUID, text: String) {
        guard hub.pairing != nil else { return }
        outbox.edit(id, text: text, learn: false)
        queued()
    }

    /// Before the Neo polishes its dictation `id` again: an edit of it still waiting must not reach the Neo after
    /// the new text and replace it. Waits a moment for a flush that may be carrying it, then takes it out. Nil when
    /// there is none. `restore` puts it back when the Neo did not polish it again.
    func takeEdit(beforeRepolishing id: UUID) async -> HubOutbox.Edit? {
        if let task = running { _ = try? await withTimeout(seconds: 5) { await task.value } }
        if let edit = outbox.takeEdit(id) {
            saveOutbox()
            return edit
        }
        if let edit = inFlight?.edits.first(where: { $0.id == id }) {
            takenEdits.insert(id)
            return edit
        }
        return nil
    }

    /// An edit `takeEdit(beforeRepolishing:)` took goes after all, unless a newer one of that dictation waits.
    func restore(_ edit: HubOutbox.Edit) {
        takenEdits.remove(edit.id)
        guard hub.pairing != nil, !outbox.edits.contains(where: { $0.id == edit.id }) else { return }
        outbox.edit(edit.id, text: edit.text, learn: edit.learn)
        queued()
    }

    private func queued() {
        saveOutbox()
        learning.setHubPending(pendingKeys)
        syncSoon(after: 1)
    }

    /// The outbox and what a flush has not sent yet.
    private func saveOutbox() {
        var all = outbox
        if let inFlight { all.merge(earlier: inFlight) }
        if all.isEmpty { AppFiles.remove(Self.outboxFile) } else { AppFiles.write(all, to: Self.outboxFile) }
    }

    /// Once per Neo, as soon as this Mac is paired with it: this Mac's most used corrections go first in the
    /// outbox. What is learned from then on follows them, so nothing is counted twice there.
    private func seedIfNew() {
        guard let server = hub.pairing?.server.absoluteString,
              UserDefaults.standard.string(forKey: Self.seededKey) != server else { return }
        var seed = HubOutbox()
        // Not what today's rules would not learn (`LearningStore.unused`): the Neo would turn it down too.
        seed.observations = HubLearning.seed(learning.book.without(learning.unused))
        UserDefaults.standard.set(server, forKey: Self.seededKey)
        // A Neo paired with for the first time gets the seed, not a second offer on top of it.
        UserDefaults.standard.set("\(server)|\(Self.justSeeded)", forKey: Self.resentKey)
        guard !seed.isEmpty else { return }
        outbox.merge(earlier: seed)
        UserDefaults.standard.set(true, forKey: Self.seedWaitingKey)
        queued()
    }

    // MARK: Syncing

    private func syncSoon(after seconds: TimeInterval) {
        soon?.cancel()
        soon = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.sync()
        }
    }

    /// Sends what is waiting, then takes the Neo's dictionary and corrections. One at a time: a sync asked for
    /// while one runs follows it.
    func sync() {
        guard hub.dictationClient != nil else { return }
        if running != nil {
            again = true
            return
        }
        let started = epoch
        running = Task { [weak self] in
            await self?.run(started)
            // A sync of an older pairing: `reset` let go of it, and a newer one may be running.
            guard let self, self.epoch == started else { return }
            self.running = nil
            if self.again {
                self.again = false
                self.sync()
            }
        }
    }

    private func run(_ started: Int) async {
        guard let client = hub.dictationClient else { return }
        guard await send(client, epoch: started) else { return }
        var snapshot: SyncSnapshot
        do {
            snapshot = try await client.sync()
        } catch {
            hub.note(error, from: client)
            return
        }
        guard epoch == started, hub.client === client else { return }
        hub.noteReached(client)
        // This Mac's dictionary changes since the last sync go to the Neo before its dictionary becomes this Mac's.
        // The last sync's words count only for the same dictionary on the Neo.
        let local = vocabulary.words
        let known = snapshot.vocabulary.generation == baseGeneration ? base : nil
        let edits = HubVocabulary.reconcile(local: local, localLearned: vocabulary.learnedRanking, base: known,
                                            hub: snapshot.vocabulary.words)
        let addedWords = HubVocabulary.adds(edits)
        if !edits.isEmpty {
            do {
                snapshot.vocabulary = try await client.applyVocabulary(edits)
            } catch {
                hub.note(error, from: client)
                // The Neo turned the dictionary down itself (not a reach problem): its corrections still come over.
                // The dictionary waits, so nothing typed here is lost by taking the Neo's.
                if epoch == started, error is HubError, HubStatus.after(error) == nil { keepHubLearning(snapshot.learning) }
                return
            }
            guard epoch == started else { return }
            // Changed again meanwhile: compare once more before replacing anything.
            guard vocabulary.words == local else {
                again = true
                return
            }
        }
        // 我的习惯: this Mac's and the Neo's are brought together. A Neo from before habits says nothing of them.
        if let theirs = snapshot.habits {
            let mine = learning.habits
            // The last sync's habits count only for the same data on the Neo: one that started over (its
            // folder was made anew, its habits.json was lost) has an empty list nobody emptied.
            let habitBase = HubHabits.base(last: hubHabits, now: theirs,
                                           sameDictionary: snapshot.vocabulary.generation == baseGeneration)
            switch HubHabits.reconcile(local: mine, base: habitBase, hub: theirs.items) {
            case .keep:
                habitConflicts = 0
                learning.setHabitsOnHub(.same)
            case .take(let items):
                habitConflicts = 0
                learning.mirrorHabits(items)
                learning.setHabitsOnHub(.same)
            case .send(let items):
                do {
                    let stored = try await client.updateHabits(items: items, expectedRevision: theirs.revision)
                    guard epoch == started else { return }
                    habitConflicts = 0
                    snapshot.habits = stored
                    if learning.habits == mine {
                        // What the Neo keeps is what this Mac keeps (both changes together, when both changed).
                        learning.mirrorHabits(stored.items)
                        learning.setHabitsOnHub(.same)
                    } else {
                        // Changed again meanwhile: compared once more.
                        again = true
                    }
                } catch {
                    guard epoch == started else { return }
                    hub.note(error, from: client)
                    // Not there yet: compared again next time, against what the Neo had at the last sync. Changed
                    // on another device at the same moment (409): at once.
                    snapshot.habits = hubHabits
                    learning.setHabitsOnHub(.waiting)
                    if (error as? HubError)?.isConflict == true {
                        habitConflicts += 1
                        if habitConflicts <= Self.habitRetries { again = true }
                    }
                }
            }
        } else {
            learning.setHabitsOnHub(.unsupported)
        }
        apply(snapshot)
        // Words added here reached the Neo only now, after the corrections that were waiting (the outbox
        // goes first): one learned towards such a word was judged there without it, and turned down. What
        // the Neo lacks is offered once more, now that it has the words.
        if addedWords { offerMissing() }
    }

    /// Flushes the outbox, as many requests as this minute allows (the rest follows a minute later). False when
    /// the Neo could not be reached (the rest waits for the next time), or the pairing went meanwhile.
    private func send(_ client: HubClient, epoch started: Int) async -> Bool {
        guard !outbox.isEmpty else {
            // Everything that was waiting has gone, the seed (first in line) included.
            UserDefaults.standard.removeObject(forKey: Self.seedWaitingKey)
            return true
        }
        let now = Date()
        sentAt.removeAll { now.timeIntervalSince($0) >= 60 }
        let allowed = HubOutbox.requestsPerMinute - sentAt.count
        if allowed > 0 {
            let sending = outbox
            outbox = HubOutbox()
            inFlight = sending
            let result = await client.flush(sending, requests: allowed) { [weak self] left in
                guard let self, self.epoch == started else { return }
                self.inFlight = left
                self.saveOutbox()
            }
            // Unpaired or paired with another Neo meanwhile: what is left was for the old one.
            guard epoch == started else { return false }
            sentAt += Array(repeating: Date(), count: result.sent)
            inFlight = nil
            // What the Neo did not take is said once its list comes back (`apply`): read off the list, which
            // also covers a Neo whose answers do not name what it refused.
            var left = result.left
            left.edits.removeAll { takenEdits.contains($0.id) }
            takenEdits = []
            // Observations go in order, so those sent are the ones in front of what is left.
            let sent = sending.observations.prefix(max(0, sending.observations.count - result.left.observations.count))
            sentSinceSync.formUnion(sent.flatMap(\.pairs).map(LearningBook.key))
            // Changes made while it was sending stay after what is left.
            outbox.merge(earlier: left)
            saveOutbox()
            if let list = result.learning { keepHubLearning(list) } else { learning.setHubPending(pendingKeys) }
            if let error = result.stoppedBy {
                hub.note(error, from: client)
                return false
            }
        }
        if outbox.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.seedWaitingKey)
        } else {
            // Over this minute's requests: the rest goes when the oldest of them is a minute old.
            let wait = sentAt.first.map { 60 - Date().timeIntervalSince($0) } ?? 0
            syncSoon(after: max(1, wait + 1))
        }
        return true
    }

    private func apply(_ snapshot: SyncSnapshot) {
        AppFiles.write(snapshot, to: Self.cacheFile)
        base = snapshot.vocabulary.words
        baseGeneration = snapshot.vocabulary.generation
        hubHabits = snapshot.habits
        vocabulary.mirror(HubVocabulary.mirrored(snapshot.vocabulary, localLearned: vocabulary.learnedInWords),
                          hubLearned: snapshot.vocabulary.learned)
        // The snapshot was taken after everything sent so far.
        let sent = sentSinceSync
        sentSinceSync = []
        setHubLearning(snapshot.learning)
        // Of what went since the last sync, what the Neo's list still lacks was not taken there.
        learning.noteNotTaken(sent: sent)
        resendIfHubChanged()
    }

    /// The Neo says it is another version than the one this Mac last offered its corrections to (it was
    /// updated, or this Mac sees its version for the first time): the corrections it lacks are offered once more,
    /// a few at a time (`HubLearning.resendLimit`). Its own rules decide again; what it still does not take
    /// stays tagged on the dictionary page.
    private func resendIfHubChanged() {
        guard let server = hub.pairing?.server.absoluteString, case .connected(let health) = hub.status else { return }
        let now = "\(server)|\(health.version)"
        let before = UserDefaults.standard.string(forKey: Self.resentKey)
        guard before != now else { return }
        UserDefaults.standard.set(now, forKey: Self.resentKey)
        // Just paired and seeded: nothing was ever turned down by this Neo.
        guard before != "\(server)|\(Self.justSeeded)" else { return }
        offerMissing()
    }

    /// Offers the Neo this Mac's corrections it does not hold once more (`HubLearning.resend`), after what is
    /// waiting already. Not those today's rules would not learn (`LearningStore.unused`): the Neo judges by
    /// the same rules, and they are used for nothing here either.
    private func offerMissing() {
        let offer = HubLearning.resend(learning.book, missing: Set(learning.notOnHub.keys).subtracting(learning.unused))
        guard !offer.isEmpty else { return }
        var later = HubOutbox()
        later.observations = offer
        later.merge(earlier: outbox)
        outbox = later
        queued()
    }

    /// The Neo's corrections as an answer just gave them (after a flush, or without its dictionary), kept in the
    /// cache too, so a relaunch before the next sync does not bring back what was just forgotten there.
    private func keepHubLearning(_ list: LearningList) {
        setHubLearning(list)
        if var cache = AppFiles.read(SyncSnapshot.self, from: Self.cacheFile) {
            cache.learning = list
            AppFiles.write(cache, to: Self.cacheFile)
        }
    }

    /// The Neo's corrections for the dictations this Mac does itself (`tellLearning`).
    private func setHubLearning(_ list: LearningList) {
        hubList = list
        tellLearning()
    }

    /// Unpaired, or paired with another Neo: what was kept for the old one goes, and a sync still talking to it
    /// keeps nothing it brings back. The dictionary stays (its words are the user's), and the next Neo gets the
    /// words it lacks. Which Neo already has this Mac's corrections is kept: pairing the same one again must not
    /// count them twice. Unless they never went: then they go to it next time.
    private func reset() {
        epoch += 1
        running?.cancel()
        running = nil
        again = false
        soon?.cancel()
        outbox = HubOutbox()
        inFlight = nil
        takenEdits = []
        sentSinceSync = []
        hubList = nil
        saveOutbox()
        base = nil
        baseGeneration = nil
        hubHabits = nil
        habitConflicts = 0
        AppFiles.remove(Self.cacheFile)
        learning.setHub([])
        learning.setHabitsOnHub(.unknown)
        vocabulary.setHubLearned([])
        UserDefaults.standard.removeObject(forKey: Self.resentKey)
        if UserDefaults.standard.bool(forKey: Self.seedWaitingKey) {
            UserDefaults.standard.removeObject(forKey: Self.seededKey)
            UserDefaults.standard.removeObject(forKey: Self.seedWaitingKey)
        }
    }
}
