import Foundation

/// One learned wrong→right pair and how often the user has made that fix.
public struct LearnedCorrection: Codable, Identifiable, Equatable, Sendable {
    /// `imported`: brought in from a file (`neoless-hub import-samples`, a word list and fixes kept elsewhere), not learned
    /// from an edit here; such pairs can be told apart and removed as a group.
    public enum Source: String, Codable, Sendable { case otherApp, inApp, imported }

    /// How a correction came to be learned, when not as a recognition error by the rules. Kept as text, so
    /// a file or an answer from a newer version still reads.
    public struct Kind: RawRepresentable, Codable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
        /// The user typed `right` over `wrong` in two dictations, and the two do not sound alike
        /// (`LearningBook.candidates`, `CorrectionExtractor.isRepeatable`): not known to be a recognition
        /// error, so only ever a hint for the model ("用户两次把 X 改成 Y"), never written into text without
        /// it, and its word is not put in the dictionary.
        public static let repeated = Kind(rawValue: "repeated")
    }

    public var id: UUID
    public var pair: CorrectionPair
    public var count: Int
    public var firstSeen: Date
    public var lastSeen: Date
    /// Where the most recent fix was made.
    public var source: Source
    /// `right` was not in the dictionary before it was learned, so forgetting the pair may remove it.
    public var addedTerm: Bool
    /// Dictation records that already counted toward `count`, oldest first (bounded).
    public var recordIDs: [UUID]
    /// Nil for a correction learned by the rules; `.repeated` for a swap made twice.
    public var kind: Kind?

    public init(id: UUID = UUID(), pair: CorrectionPair, count: Int = 1, firstSeen: Date, lastSeen: Date,
                source: Source, addedTerm: Bool, recordIDs: [UUID] = [], kind: Kind? = nil) {
        self.id = id; self.pair = pair; self.count = count; self.firstSeen = firstSeen; self.lastSeen = lastSeen
        self.source = source; self.addedTerm = addedTerm; self.recordIDs = recordIDs; self.kind = kind
    }

    /// Learned from a swap made twice: a hint only (`Kind.repeated`).
    public var isRepeated: Bool { kind == .repeated }
}

/// A word learned without a mapping (`TermFix.termOnly`: Nio typed over 你好, a capital given to cursor). It
/// is in the dictionary as a learned word, never as one of the user's own: listed after every word a
/// correction teaches, used by the model only where the context fits, and taken out again when the edit
/// that taught it is taken back.
public struct LearnedTerm: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var term: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var source: LearnedCorrection.Source

    public init(id: UUID = UUID(), term: String, firstSeen: Date, lastSeen: Date, source: LearnedCorrection.Source) {
        self.id = id; self.term = term; self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.source = source
    }
}

/// What one `record` call changed, so it can be undone exactly.
public struct LearningEvent: Equatable, Sendable {
    public var id = UUID()
    /// Pairs added or counted again; their `right` belongs in the dictionary.
    public var learned: [CorrectionPair] = []
    /// Stored pairs counted down because the user changed them back (each as stored, wrong→right). Also a
    /// pair held elsewhere (the Neo's) whose reverse the user made here: nothing changes in this book, and
    /// the pair is weakened where it is held.
    public var reversed: [CorrectionPair] = []
    /// Words learned without a mapping that this event put in the book; they belong in the dictionary as
    /// learned words.
    public var terms: [String] = []
    /// What was not learned because the day's new corrections are used up (`LearningBook.maxNewPerDay`): the
    /// corrected words.
    public var overLimit: [String] = []
    /// Items this event created.
    public var added: [UUID] = []
    /// Items as they were before this event changed, decremented or evicted them.
    public var previous: [LearnedCorrection] = []
    /// Learned words this event created, and those it learned again or pushed out, as they were before.
    public var addedTerms: [UUID] = []
    public var previousTerms: [LearnedTerm] = []
    /// Words this event only noted (`LearningBook.sightings`: a capital seen once), and the notes it used up
    /// to learn a word seen a second time, as they were.
    public var noted: [String] = []
    public var previousSightings: [LearningBook.Sighting] = []
    /// Swaps this event only remembered (`LearningBook.candidates`: made once, used for nothing).
    public var candidates: [CorrectionPair] = []
    /// Swaps this event learned or counted again as made twice (`LearnedCorrection.Kind.repeated`): hints
    /// only. Not in `learned`, because their `right` does not belong in the dictionary.
    public var promoted: [CorrectionPair] = []
    /// Remembered swaps this event used up (learned now), or took out (changed back), as they were.
    public var previousCandidates: [LearningBook.Candidate] = []
    /// Those of `reversed` that were swaps made twice (`LearnedCorrection.Kind.repeated`), here or where
    /// they are held. Undoing the event counts them up again, and they must then go to the Neo as what they
    /// are: sent as a plain correction, a swap is judged as a recognition error, which it is not, and refused.
    public var reversedSwaps: [CorrectionPair] = []

    public init(learned: [CorrectionPair] = []) {
        self.learned = learned
    }

    /// Nothing changed in the book, and nothing is to be passed on.
    public var isEmpty: Bool {
        added.isEmpty && previous.isEmpty && addedTerms.isEmpty && previousTerms.isEmpty && reversed.isEmpty
            && noted.isEmpty && previousSightings.isEmpty && candidates.isEmpty && previousCandidates.isEmpty
    }

    /// The words this event put in the book on their own account: learned or noted alone, or the new side
    /// of a swap remembered or learned as made twice. When the text no longer shows one of them
    /// (`EditTracker.withdrawn`), the event is taken back.
    public var aloneWords: [String] {
        terms + noted + candidates.map(\.right) + promoted.map(\.right)
    }

    /// The swaps this event remembered, or learned as made twice.
    public var swaps: [CorrectionPair] { candidates + promoted }

    /// Whether this event remembered or learned a swap that the passage no longer shows, by the latest
    /// comparison of that passage (`Extraction.shows`): a word typed in two halves with a pause between them
    /// (学习, then 学习曲线), or a swap changed back while its word still stands elsewhere in the text. What
    /// remembered it is then taken back, or it would wait in the book and count as the first of two times.
    public func holdsSwap(goneFrom found: Extraction) -> Bool {
        swaps.contains { !found.shows($0) }
    }

    /// `reversed` without the swaps made twice, and those swaps: what undoing this event counts up again,
    /// as corrections and as swaps (`reversedSwaps`).
    public var reversedByKind: (fixes: [CorrectionPair], swaps: [CorrectionPair]) {
        let keys = Set(reversedSwaps.map(LearningBook.key))
        return (reversed.filter { !keys.contains(LearningBook.key($0)) }, reversed.filter { keys.contains(LearningBook.key($0)) })
    }
}

/// A correction made elsewhere, for `LearningBook.importCorrections`.
public struct ImportedCorrection: Equatable, Sendable {
    public var pair: CorrectionPair
    /// How often it was fixed there.
    public var count: Int
    public var firstSeen: Date
    public var lastSeen: Date

    public init(pair: CorrectionPair, count: Int, firstSeen: Date, lastSeen: Date) {
        self.pair = pair; self.count = count; self.firstSeen = firstSeen; self.lastSeen = lastSeen
    }
}

/// What `LearningBook.importCorrections` did with each pair.
public struct LearningImport: Equatable, Sendable {
    public var added: [CorrectionPair] = []
    /// Already in the book (imported before, or learned): left as it is.
    public var present: [CorrectionPair] = []
    /// The book has another fix of the same `wrong`, or this pair's reverse: that one is kept.
    public var conflicting: [CorrectionPair] = []
    /// The book was full (`LearningBook.maxItems`).
    public var full: [CorrectionPair] = []

    public init() {}
}

/// All learned corrections. Pure value type: the app persists it and mirrors terms into the dictionary.
public struct LearningBook: Codable, Equatable, Sendable {
    public static let maxItems = 500, maxPairsPerEvent = 3, maxNewPerDay = 20
    /// The most words learned without a mapping that are kept: the oldest go first.
    public static let maxTerms = 200
    static let maxRecordIDs = 20

    /// A word seen once with a capital given to it in the middle of a Chinese clause (cursor → Cursor), and
    /// the dictation that was in. Not learned, not in the dictionary, used for nothing: only remembered, so
    /// that the same capital given in another dictation is known to be the second time.
    public struct Sighting: Codable, Equatable, Sendable {
        public var term: String
        public var seen: Date
        public var recordID: UUID?

        public init(term: String, seen: Date, recordID: UUID?) {
            self.term = term; self.seen = seen; self.recordID = recordID
        }
    }

    /// The most sightings kept: the oldest go first.
    public static let maxSightings = 50

    /// A word typed over another that does not sound like it (米线 → 曲线), seen once, and the dictation that
    /// was in. Not learned, not in the dictionary, put before no model and written into no text: only
    /// remembered, so that the same swap made in another dictation is known to be the second time, and is
    /// then learned as a hint (`LearnedCorrection.Kind.repeated`). The two words and a date, never the text
    /// around them.
    public struct Candidate: Codable, Equatable, Sendable {
        public var pair: CorrectionPair
        public var seen: Date
        public var recordID: UUID?

        public init(pair: CorrectionPair, seen: Date, recordID: UUID?) {
            self.pair = pair; self.seen = seen; self.recordID = recordID
        }
    }

    /// The most remembered swaps kept (the oldest go first), and how long one waits for its second time.
    public static let maxCandidates = 60
    public static let candidateLifetime: TimeInterval = 60 * 24 * 3600
    /// A swap made twice is in the book with this count, and is forgotten when it falls below it: the
    /// user changing it back once leaves a single sighting, which is no evidence.
    public static let repeatedCount = 2

    public var version = 1
    public var items: [LearnedCorrection]
    /// Words learned without a mapping, newest first.
    public var terms: [LearnedTerm]
    /// Words noted once and not learned yet, newest first.
    public var sightings: [Sighting]
    /// Swaps seen once and not learned yet, newest first.
    public var candidates: [Candidate]

    public init(items: [LearnedCorrection] = [], terms: [LearnedTerm] = [], sightings: [Sighting] = [],
                candidates: [Candidate] = []) {
        self.items = items; self.terms = terms; self.sightings = sightings; self.candidates = candidates
    }

    enum CodingKeys: String, CodingKey { case version, items, terms, sightings, candidates }

    /// A file from before words were learned on their own has no `terms`; one from before a capital had to be
    /// seen twice has no `sightings`; one from before swaps were remembered has no `candidates`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        items = try c.decode([LearnedCorrection].self, forKey: .items)
        terms = try c.decodeIfPresent([LearnedTerm].self, forKey: .terms) ?? []
        sightings = try c.decodeIfPresent([Sighting].self, forKey: .sightings) ?? []
        candidates = try c.decodeIfPresent([Candidate].self, forKey: .candidates) ?? []
    }

    /// Dedupe key: case-folded, whitespace-collapsed `wrong|right`.
    public static func key(_ pair: CorrectionPair) -> String {
        fold(pair.wrong) + "|" + fold(pair.right)
    }

    static func fold(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Learns `pairs` from one edit, and `terms`, the words it taught without a mapping. A repeat counts at
    /// most once per dictation record; the reverse of a stored pair (the user changed it back) weakens that
    /// pair instead of being learned. So does the reverse of a pair in `heldElsewhere` (the Neo's corrections
    /// this book does not have): it is never learned here as a mapping of its own, which would leave the two
    /// books contradicting each other; it is reported in `reversed`, to be weakened where it is held.
    /// `termExists` says whether a word is one of the user's own in the dictionary (not one learning put
    /// there): such a word is never recorded as learned. `sightings`: words the edit gave a capital to
    /// (`TermFix.tentative`). The first time one is only noted; given the same capital in another dictation it
    /// is learned, like the words in `terms`.
    ///
    /// `candidates`: swaps the edit made that the rules did not take and did not forbid
    /// (`Extraction.candidates`). The first time one is only remembered (`self.candidates`); made again in
    /// another dictation it is learned with kind `.repeated`, a hint for the model that is never written into
    /// text without it and puts no word in the dictionary. The same dictation again, or one that cannot be
    /// told from it (no record id), is not a second time. The reverse of a stored correction weakens that
    /// one, and the reverse of a remembered swap takes the note out.
    /// `repeated`: swaps another device already saw twice (the hub, for `LearningObservations.kind`):
    /// learned with that kind at once.
    /// `repeatedElsewhere`: those of `heldElsewhere` that are swaps made twice. Such a swap made here is
    /// neither remembered nor learned a second time: it is held, and in use, already. And its reverse is
    /// reported as the reverse of a swap (`LearningEvent.reversedSwaps`).
    public mutating func record(_ pairs: [CorrectionPair], terms words: [String] = [], sightings capitals: [String] = [],
                                candidates swaps: [CorrectionPair] = [], repeated twice: [CorrectionPair] = [],
                                source: LearnedCorrection.Source,
                                recordID: UUID?, now: Date = Date(), calendar: Calendar = .current,
                                heldElsewhere: [CorrectionPair] = [], repeatedElsewhere: [CorrectionPair] = [],
                                termExists: (String) -> Bool) -> LearningEvent {
        var event = LearningEvent()
        func remember(_ item: LearnedCorrection) {
            if !event.previous.contains(where: { $0.id == item.id }) { event.previous.append(item) }
        }
        let swapsElsewhere = Set(repeatedElsewhere.map(Self.key))
        /// A stored correction is counted down: noted as the reverse of a swap when it is one.
        func reverse(_ pair: CorrectionPair, swap: Bool) {
            if !event.reversed.contains(pair) { event.reversed.append(pair) }
            if swap, !event.reversedSwaps.contains(pair) { event.reversedSwaps.append(pair) }
        }
        /// New pairs and words learned today: imported ones are not learned today and never use up the day's.
        func newToday() -> Int {
            items.filter { $0.source != .imported && calendar.isDate($0.firstSeen, inSameDayAs: now) }.count
                + terms.filter { calendar.isDate($0.firstSeen, inSameDayAs: now) }.count
        }
        var seen = Set<String>()
        let unique = pairs.filter { seen.insert(Self.key($0)).inserted }
        for pair in unique.prefix(Self.maxPairsPerEvent) {
            let k = Self.key(pair)
            let reversed = CorrectionPair(wrong: pair.right, right: pair.wrong)
            let caseOnly = k == Self.key(reversed)
            if let i = items.firstIndex(where: { Self.key($0.pair) == k && (!caseOnly || $0.pair.right == pair.right) }) {
                remember(items[i])
                if recordID.map({ !items[i].recordIDs.contains($0) }) ?? true {
                    items[i].count += 1
                    if let recordID { items[i].recordIDs = Array((items[i].recordIDs + [recordID]).suffix(Self.maxRecordIDs)) }
                }
                items[i].lastSeen = now
                items[i].source = source
                event.learned.append(pair)
            } else if let i = items.firstIndex(where: { Self.key($0.pair) == Self.key(reversed) && (!caseOnly || $0.pair.right == pair.wrong) }) {
                remember(items[i])
                event.reversed.append(items[i].pair)
                if items[i].isRepeated { event.reversedSwaps.append(items[i].pair) }
                countDown(at: i)
            } else if let held = heldElsewhere.first(where: { Self.key($0) == Self.key(reversed) && (!caseOnly || $0.right == pair.wrong) }) {
                reverse(held, swap: swapsElsewhere.contains(Self.key(held)))
            } else {
                guard newToday() < Self.maxNewPerDay else {
                    event.overLimit.append(pair.right)
                    continue
                }
                let item = LearnedCorrection(pair: pair, firstSeen: now, lastSeen: now, source: source,
                                             addedTerm: !termExists(pair.right), recordIDs: recordID.map { [$0] } ?? [])
                items.insert(item, at: 0)
                event.added.append(item.id)
                event.learned.append(pair)
                // Learned by the rules now: a note of the same swap has nothing left to wait for.
                while let c = candidates.firstIndex(where: { Self.key($0.pair) == k }) {
                    event.previousCandidates.append(candidates.remove(at: c))
                }
            }
        }
        // Swaps the rules did not take: remembered the first time, learned as made twice the second.
        var seenSwaps = Set<String>()
        for pair in swaps.filter({ seenSwaps.insert(Self.key($0)).inserted }).prefix(Self.maxPairsPerEvent) {
            let k = Self.key(pair)
            let back = Self.key(CorrectionPair(wrong: pair.right, right: pair.wrong))
            guard k != back else { continue }
            if let i = items.firstIndex(where: { Self.key($0.pair) == k }) {
                // Learned as made twice already: made again in another dictation, it counts once more. A
                // correction the rules learned and no longer take (its dictionary word is gone) stays what
                // it is: stored, marked, and used for nothing.
                guard items[i].isRepeated, let recordID, !items[i].recordIDs.contains(recordID) else { continue }
                remember(items[i])
                items[i].count += 1
                items[i].recordIDs = Array((items[i].recordIDs + [recordID]).suffix(Self.maxRecordIDs))
                items[i].lastSeen = now
                items[i].source = source
                event.promoted.append(pair)
            } else if let i = items.firstIndex(where: { Self.key($0.pair) == back }) {
                remember(items[i])
                event.reversed.append(items[i].pair)
                if items[i].isRepeated { event.reversedSwaps.append(items[i].pair) }
                countDown(at: i)
            } else if let held = heldElsewhere.first(where: { Self.key($0) == back }) {
                reverse(held, swap: swapsElsewhere.contains(Self.key(held)))
            } else if let i = candidates.firstIndex(where: { Self.key($0.pair) == back }) {
                // Changed back before it was ever learned: the note goes.
                event.previousCandidates.append(candidates.remove(at: i))
            } else if swapsElsewhere.contains(k) {
                // Held elsewhere as made twice, and used from there: nothing to remember, and "记下了…
                // 再这样改一次就记住" would not be true of it. A note of it from before it was learned there
                // has nothing left to wait for.
                while let c = candidates.firstIndex(where: { Self.key($0.pair) == k }) {
                    event.previousCandidates.append(candidates.remove(at: c))
                }
                continue
            } else if let i = candidates.firstIndex(where: { Self.key($0.pair) == k }) {
                guard now.timeIntervalSince(candidates[i].seen) <= Self.candidateLifetime else {
                    // Too long ago to be the same habit: this is a first time again.
                    event.previousCandidates.append(candidates.remove(at: i))
                    candidates.insert(Candidate(pair: pair, seen: now, recordID: recordID), at: 0)
                    event.candidates.append(pair)
                    continue
                }
                // The same dictation again, or one that cannot be told from it, is not a second time.
                guard let recordID, let first = candidates[i].recordID, first != recordID else { continue }
                guard newToday() < Self.maxNewPerDay else {
                    event.overLimit.append(pair.right)
                    continue
                }
                event.previousCandidates.append(candidates.remove(at: i))
                let item = LearnedCorrection(pair: pair, count: Self.repeatedCount, firstSeen: now, lastSeen: now,
                                             source: source, addedTerm: false, recordIDs: [first, recordID], kind: .repeated)
                items.insert(item, at: 0)
                event.added.append(item.id)
                event.promoted.append(pair)
            } else {
                candidates.insert(Candidate(pair: pair, seen: now, recordID: recordID), at: 0)
                event.candidates.append(pair)
            }
        }
        // Swaps a device saw twice itself: learned as that at once.
        var seenTwice = Set<String>()
        for pair in twice.filter({ seenTwice.insert(Self.key($0)).inserted }).prefix(Self.maxPairsPerEvent) {
            let k = Self.key(pair)
            let back = Self.key(CorrectionPair(wrong: pair.right, right: pair.wrong))
            guard k != back else { continue }
            if let i = items.firstIndex(where: { Self.key($0.pair) == k }) {
                remember(items[i])
                if recordID.map({ !items[i].recordIDs.contains($0) }) ?? true {
                    items[i].count = max(items[i].count + 1, Self.repeatedCount)
                    if let recordID { items[i].recordIDs = Array((items[i].recordIDs + [recordID]).suffix(Self.maxRecordIDs)) }
                }
                items[i].lastSeen = now
                items[i].source = source
                event.promoted.append(pair)
            } else if let i = items.firstIndex(where: { Self.key($0.pair) == back }) {
                remember(items[i])
                event.reversed.append(items[i].pair)
                if items[i].isRepeated { event.reversedSwaps.append(items[i].pair) }
                countDown(at: i)
            } else {
                guard newToday() < Self.maxNewPerDay else {
                    event.overLimit.append(pair.right)
                    continue
                }
                while let c = candidates.firstIndex(where: { Self.key($0.pair) == k }) {
                    event.previousCandidates.append(candidates.remove(at: c))
                }
                let item = LearnedCorrection(pair: pair, count: Self.repeatedCount, firstSeen: now, lastSeen: now,
                                             source: source, addedTerm: false, recordIDs: recordID.map { [$0] } ?? [],
                                             kind: .repeated)
                items.insert(item, at: 0)
                event.added.append(item.id)
                event.promoted.append(pair)
            }
        }
        if candidates.count > Self.maxCandidates { candidates.removeLast(candidates.count - Self.maxCandidates) }
        // Words learned without a mapping. One the user has as their own, or one a correction already teaches,
        // changes nothing. One learned this way before is learned again (it goes back into the dictionary if the
        // user has taken it out since, as the word of a correction fixed again does); undoing that leaves the
        // first learning in place.
        for word in words {
            let term = word.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = term.lowercased()
            guard !term.isEmpty, !termExists(term), !event.terms.contains(where: { $0.lowercased() == key }),
                  !items.contains(where: { !$0.isRepeated && $0.pair.right.lowercased() == key }) else { continue }
            if let i = terms.firstIndex(where: { $0.term.lowercased() == key }) {
                if !event.previousTerms.contains(where: { $0.id == terms[i].id }) { event.previousTerms.append(terms[i]) }
                terms[i].lastSeen = now
                terms[i].source = source
                event.terms.append(terms[i].term)
                continue
            }
            guard newToday() < Self.maxNewPerDay else {
                event.overLimit.append(term)
                continue
            }
            let entry = LearnedTerm(term: term, firstSeen: now, lastSeen: now, source: source)
            terms.insert(entry, at: 0)
            event.addedTerms.append(entry.id)
            event.terms.append(term)
        }
        // A capital given to a word: noted the first time, learned the second (in another dictation). Nothing
        // to note when the word is the user's own, or is taught already.
        for word in capitals {
            let term = word.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = term.lowercased()
            guard !term.isEmpty, !termExists(term), !event.terms.contains(where: { $0.lowercased() == key }),
                  !event.noted.contains(term), !teaches(term) else { continue }
            guard let i = sightings.firstIndex(where: { $0.term == term }) else {
                sightings.insert(Sighting(term: term, seen: now, recordID: recordID), at: 0)
                event.noted.append(term)
                continue
            }
            // The same dictation again is not a second time.
            if let recordID, sightings[i].recordID == recordID { continue }
            guard newToday() < Self.maxNewPerDay else {
                event.overLimit.append(term)
                continue
            }
            event.previousSightings.append(sightings.remove(at: i))
            let entry = LearnedTerm(term: term, firstSeen: now, lastSeen: now, source: source)
            terms.insert(entry, at: 0)
            event.addedTerms.append(entry.id)
            event.terms.append(term)
        }
        if sightings.count > Self.maxSightings { sightings.removeLast(sightings.count - Self.maxSightings) }
        while terms.count > Self.maxTerms {
            let candidates = terms.indices.filter { !event.addedTerms.contains(terms[$0].id) }
            guard let victim = candidates.min(by: { terms[$0].lastSeen < terms[$1].lastSeen }) else { break }
            event.previousTerms.append(terms[victim])
            terms.remove(at: victim)
        }
        while items.count > Self.maxItems {
            let candidates = items.indices.filter { !event.added.contains(items[$0].id) }
            let pool = candidates.isEmpty ? Array(items.indices) : candidates
            let victim = pool.min { (items[$0].count, items[$0].lastSeen) < (items[$1].count, items[$1].lastSeen) }!
            remember(items[victim])
            items.remove(at: victim)
        }
        return event
    }

    /// The user changed the stored correction at `i` back: one fix fewer. It goes when none is left, and a
    /// swap made twice goes as soon as it is no longer made twice (`repeatedCount`).
    private mutating func countDown(at i: Int) {
        items[i].count -= 1
        if items[i].count <= 0 || (items[i].isRepeated && items[i].count < Self.repeatedCount) { items.remove(at: i) }
    }

    /// Whether `pair` is the reverse of a stored pair and not itself stored: recording it counts that pair down
    /// (`record`), it teaches nothing new. The hub takes such a pair from a device whatever it looks like.
    public func countsDown(_ pair: CorrectionPair) -> Bool {
        let k = Self.key(pair)
        let reversed = CorrectionPair(wrong: pair.right, right: pair.wrong)
        let caseOnly = k == Self.key(reversed)
        if items.contains(where: { Self.key($0.pair) == k && (!caseOnly || $0.pair.right == pair.right) }) { return false }
        return items.contains { Self.key($0.pair) == Self.key(reversed) && (!caseOnly || $0.pair.right == pair.wrong) }
    }

    /// Brings in corrections made elsewhere (`neoless-hub import-samples`): each becomes an item of its own with source
    /// `.imported`, counted at least `LearningPrompt.confirmedCount` times so it is used like a confirmed fix. What the
    /// book already has wins: a pair already in it, its reverse, or another `right` for the same `wrong` is left as it
    /// is and the import skipped (so importing twice changes nothing). Nothing is evicted for an import: past `maxItems` the rest are not added.
    /// `termExists` says whether a `right` is already the user's own dictionary word (else learning adds it).
    public mutating func importCorrections(_ corrections: [ImportedCorrection],
                                           termExists: (String) -> Bool) -> LearningImport {
        var outcome = LearningImport()
        for correction in corrections {
            let pair = correction.pair
            let wrong = Self.fold(pair.wrong), right = Self.fold(pair.right)
            let same = items.contains { Self.fold($0.pair.wrong) == wrong && Self.fold($0.pair.right) == right }
            let other = items.contains { item in
                let w = Self.fold(item.pair.wrong), r = Self.fold(item.pair.right)
                return w == wrong || (w == right && r == wrong)
            }
            if same {
                outcome.present.append(pair)
            } else if other {
                outcome.conflicting.append(pair)
            } else if items.count >= Self.maxItems {
                outcome.full.append(pair)
            } else {
                items.append(LearnedCorrection(pair: pair, count: max(correction.count, LearningPrompt.confirmedCount),
                                               firstSeen: correction.firstSeen, lastSeen: correction.lastSeen,
                                               source: .imported, addedTerm: !termExists(pair.right)))
                outcome.added.append(pair)
            }
        }
        return outcome
    }

    /// Reverts `event`: removes what it added and restores what it changed. `manualTerms` (lower-cased) are
    /// words the user has in the dictionary as their own right now: a restored copy of an item that still
    /// says learning added its term gets `addedTerm` false, because the user typed the word by hand since.
    public mutating func undo(_ event: LearningEvent, manualTerms: Set<String> = []) {
        items.removeAll { event.added.contains($0.id) }
        for var old in event.previous {
            if old.addedTerm, manualTerms.contains(old.pair.right.lowercased()) { old.addedTerm = false }
            if let i = items.firstIndex(where: { $0.id == old.id }) { items[i] = old } else { items.append(old) }
        }
        // The words it learned alone go; one it learned again or pushed out is as it was before, unless the user
        // has it as their own now.
        terms.removeAll { event.addedTerms.contains($0.id) }
        for old in event.previousTerms {
            if manualTerms.contains(old.term.lowercased()) {
                terms.removeAll { $0.id == old.id }
            } else if let i = terms.firstIndex(where: { $0.id == old.id }) {
                terms[i] = old
            } else {
                terms.append(old)
            }
        }
        // What it noted is forgotten; a note it used up to learn a word is there again.
        sightings.removeAll { event.noted.contains($0.term) }
        for old in event.previousSightings where !sightings.contains(where: { $0.term == old.term }) { sightings.append(old) }
        // The same for the swaps it remembered, and the notes it used up or took out.
        let notedSwaps = Set(event.candidates.map(Self.key))
        if !notedSwaps.isEmpty { candidates.removeAll { notedSwaps.contains(Self.key($0.pair)) } }
        for old in event.previousCandidates where !candidates.contains(where: { Self.key($0.pair) == Self.key(old.pair) }) {
            candidates.append(old)
        }
        if !event.previousCandidates.isEmpty { candidates.sort { $0.seen > $1.seen } }
    }

    /// Forgets a remembered swap (the user deleted its row). Returns it, or nil when there was none.
    @discardableResult
    public mutating func removeCandidate(_ pair: CorrectionPair) -> Candidate? {
        guard let i = candidates.firstIndex(where: { Self.key($0.pair) == Self.key(pair) }) else { return nil }
        return candidates.remove(at: i)
    }

    /// Forgets the remembered swaps that waited longer than `candidateLifetime` for their second time.
    /// Returns whether any went.
    @discardableResult
    public mutating func expireCandidates(now: Date = Date()) -> Bool {
        let before = candidates.count
        candidates.removeAll { now.timeIntervalSince($0.seen) > Self.candidateLifetime }
        return candidates.count != before
    }

    @discardableResult
    public mutating func remove(id: UUID) -> LearnedCorrection? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: i)
    }

    /// Whether anything still teaches `term` (a correction, or the word learned alone), so a learned-only
    /// dictionary word must stay.
    public func teaches(_ term: String) -> Bool {
        let key = term.lowercased()
        // A swap made twice puts no word in the dictionary, so it keeps none there.
        return items.contains { !$0.isRepeated && $0.pair.right.lowercased() == key } || terms.contains { $0.term.lowercased() == key }
    }

    /// The user added `term` to the dictionary by hand: forgetting a pair must not remove it, and it is no
    /// longer a word learned alone, or one noted to be.
    public mutating func markManualTerm(_ term: String) {
        for i in items.indices where items[i].pair.right.lowercased() == term.lowercased() {
            items[i].addedTerm = false
        }
        terms.removeAll { $0.term.lowercased() == term.lowercased() }
        sightings.removeAll { $0.term.lowercased() == term.lowercased() }
    }

    /// Takes back a word learned without a mapping (the edit that taught it was undone on another device),
    /// and a note of it. Returns the learned word, or nil when it was not learned that way.
    @discardableResult
    public mutating func removeTerm(_ term: String) -> LearnedTerm? {
        sightings.removeAll { $0.term.lowercased() == term.lowercased() }
        guard let i = terms.firstIndex(where: { $0.term.lowercased() == term.lowercased() }) else { return nil }
        return terms.remove(at: i)
    }

    // MARK: Stored corrections and today's rules

    /// The corrections in this book that today's rules would not learn (by `key`): stored by an older
    /// version, sent by another device, or learned towards a dictionary word that is no longer there. A
    /// mapping the rules now refuse (周五 → 周日, 有效 → 无效, 广州 → 杭州, 先 → 西安) or would keep only the
    /// word of (他不来 → Tableau) must not go on being put before the model or written into text, however
    /// often it was fixed: `without` takes them out of what is used. They stay in the book, so the user sees
    /// them (marked) and can delete them, and so that nothing is lost should the rules be wrong about one.
    /// Imported corrections (`.imported`) were chosen by the user and are not judged.
    /// `knownTerms`: the user's own dictionary words. `verdicts`: answers kept between calls (by the pair as
    /// written), for the same `knownTerms` only.
    public func unusable(knownTerms: Set<String>, extractor: CorrectionExtractor = CorrectionExtractor(),
                         verdicts: inout [String: Bool]) -> Set<String> {
        var out = Set<String>(), usable = Set<String>()
        for item in items {
            let key = Self.key(item.pair)
            if item.source == .imported {
                usable.insert(key)
                continue
            }
            // A swap made twice is no recognition error by the rules and need not be one: it is judged by
            // what a rule forbids (a number, a negation, an opposite, a secret…), which also holds for one
            // an older version or another device stored.
            let exact = (item.isRepeated ? "2\u{1F}" : "") + item.pair.wrong + "\u{1F}" + item.pair.right
            let passes = verdicts[exact] ?? (item.isRepeated ? extractor.isRepeatable(item.pair, knownTerms: knownTerms)
                                             : extractor.strength(of: item.pair, knownTerms: knownTerms) == .pair)
            verdicts[exact] = passes
            if passes { usable.insert(key) } else { out.insert(key) }
        }
        // Two spellings of one pair share a key (claude → Claude and its reverse): the key is out only when
        // none of them passes.
        return out.subtracting(usable)
    }

    /// The same, when nothing is kept between calls.
    public func unusable(knownTerms: Set<String>) -> Set<String> {
        var verdicts: [String: Bool] = [:]
        return unusable(knownTerms: knownTerms, verdicts: &verdicts)
    }

    /// This book without the corrections `keys` name: what `LearningPrompt` is given.
    public func without(_ keys: Set<String>) -> LearningBook {
        guard !keys.isEmpty else { return self }
        var book = self
        book.items.removeAll { keys.contains(Self.key($0.pair)) }
        return book
    }

    /// Lower-cased words that are in the dictionary only because they were learned: a correction's `right`
    /// that was not there before, or a word learned alone.
    public var learnedOnlyTerms: Set<String> {
        Set(items.filter(\.addedTerm).map { $0.pair.right.lowercased() } + terms.map { $0.term.lowercased() })
    }

    /// The learned-only words, most useful first, for the recognizer's hints and the prompt's word list: what
    /// corrections teach by how often and how lately they were fixed, then the words learned alone (the
    /// latest first). A word learned from a single edit without a mapping comes last.
    public var learnedRanking: [String] {
        let taught = items.filter(\.addedTerm).sorted { ($0.count, $0.lastSeen) > ($1.count, $1.lastSeen) }.map(\.pair.right)
        let known = Set(taught.map { $0.lowercased() })
        return taught + terms.sorted { $0.lastSeen > $1.lastSeen }.map(\.term).filter { !known.contains($0.lowercased()) }
    }

    /// `pairs` continue `earlier`, learned from the same dictation record: A→B then B→C is A→C, and
    /// A→B then B→A cancels. Returns what to learn in place of both, or nil when nothing chains.
    public static func chained(_ pairs: [CorrectionPair], after earlier: [CorrectionPair]) -> [CorrectionPair]? {
        var rest = earlier
        var out: [CorrectionPair] = []
        var chained = false
        for pair in pairs {
            guard let i = rest.firstIndex(where: { fold($0.right) == fold(pair.wrong) }) else { out.append(pair); continue }
            chained = true
            let first = rest.remove(at: i)
            if first.wrong != pair.right { out.append(CorrectionPair(wrong: first.wrong, right: pair.right)) }
        }
        return chained ? rest + out : nil
    }
}

/// Learned pairs worth mentioning in one polish request.
public enum LearningPrompt {
    public static let maxPairs = 10, characterBudget = 300
    /// The most swaps made twice mentioned in one request, and the characters they may take. Caps of their
    /// own: a hint never takes a place from a correction.
    public static let maxRepeated = 4, repeatedBudget = 120

    /// Pairs whose `wrong` occurs in `transcript` (ignoring case and spaces, on word boundaries when it
    /// starts or ends with a letter or digit), one per `wrong` (the most recent `right`), most frequent and
    /// recent first, within the pair and character caps. Never a swap made twice.
    public static func pairs(for transcript: String, from book: LearningBook) -> [CorrectionPair] {
        matched(for: transcript, from: book).fixes.map(\.pair)
    }

    /// The swaps the user made twice (`LearnedCorrection.Kind.repeated`) whose `wrong` occurs in
    /// `transcript`, chosen like `pairs(for:from:)` under caps of their own (`maxRepeated`). The prompt lists
    /// them apart, as what the user did and not as what was misheard (`PolishPrompt.repeatedLine`). Not one
    /// whose `wrong` a correction learned as a recognition error also has: that one is the better evidence
    /// of what the word was heard for, and the two must not contradict each other in one request.
    public static func repeated(for transcript: String, from book: LearningBook) -> [CorrectionPair] {
        matched(for: transcript, from: book).swaps.map(\.pair)
    }

    /// The corrections worth mentioning for `transcript`: those learned as recognition errors and the swaps
    /// made twice, each kind with one item per `wrong` (the most recent) and within its own caps. A swap
    /// never displaces a correction, neither for the same `wrong` nor from the list.
    static func matched(for transcript: String, from book: LearningBook) -> (fixes: [LearnedCorrection], swaps: [LearnedCorrection]) {
        let text = normalize(transcript), folded = fold(transcript)
        var fixes: [String: LearnedCorrection] = [:], swaps: [String: LearnedCorrection] = [:]
        for item in book.items {
            let wrong = normalize(item.pair.wrong)
            guard !wrong.isEmpty, text.contains(wrong), occurs(Array(wrong), in: folded) else { continue }
            if item.isRepeated {
                if let other = swaps[wrong], other.lastSeen >= item.lastSeen { continue }
                swaps[wrong] = item
            } else {
                if let other = fixes[wrong], other.lastSeen >= item.lastSeen { continue }
                fixes[wrong] = item
            }
        }
        for wrong in fixes.keys { swaps[wrong] = nil }
        func chosen(_ items: [LearnedCorrection], most: Int, budget: Int) -> [LearnedCorrection] {
            let ranked = items.sorted { ($0.count, $0.lastSeen) > ($1.count, $1.lastSeen) }
            var used = 0
            var out: [LearnedCorrection] = []
            for item in ranked.prefix(most) {
                let cost = item.pair.wrong.count + item.pair.right.count + 2   // "→" and "；"
                guard used + cost <= budget else { break }
                used += cost
                out.append(item)
            }
            return out
        }
        return (chosen(Array(fixes.values), most: maxPairs, budget: characterBudget),
                chosen(Array(swaps.values), most: maxRepeated, budget: repeatedBudget))
    }

    static func normalize(_ s: String) -> String {
        String(s.lowercased().filter { !$0.isWhitespace })
    }

    /// A pair must have been fixed in at least this many dictations before `applyConfirmed` uses it.
    public static let confirmedCount = 2

    /// Replaces learned wrong→right pairs in `text` without asking the model (原样转写, or the original
    /// transcript typed after a failed polish). Only pairs fixed at least `confirmedCount` times are used,
    /// one `right` per `wrong` (the most recent), matched like `pairs(for:from:)`: ignoring case and spaces,
    /// on word boundaries for letters and digits. A match that is already part of `right` is left alone,
    /// and overlapping matches go to the more frequent pair. Replaced text is never matched again. A pair
    /// that is not safe to write without the sentence (`CorrectionExtractor.replacesBlindly`: its `wrong`
    /// reads as a number or a date, as 一百, 两块, 星期三, twenty; its sides differ by a number, a negation or
    /// an opposite; or its `wrong` may be something the user says on purpose, as Cloud → Claude, 即使 → 及时
    /// or 金币 → 音币) is never applied here, however often it was fixed and wherever it came from: it stays
    /// a hint for the model, which sees the sentence.
    public static func applyConfirmed(_ text: String, book: LearningBook) -> String {
        var latest: [String: LearnedCorrection] = [:]
        let said = normalize(text)
        // A swap made twice is not known to be a recognition error: a hint only, whatever it looks like.
        for item in book.items where item.count >= confirmedCount && !item.isRepeated {
            let wrong = normalize(item.pair.wrong)
            guard !wrong.isEmpty, !item.pair.right.isEmpty, said.contains(wrong),
                  CorrectionExtractor.replacesBlindly(item.pair) else { continue }
            if let other = latest[wrong], other.lastSeen >= item.lastSeen { continue }
            latest[wrong] = item
        }
        guard !latest.isEmpty else { return text }
        let original = Array(text)
        let mapped = foldMapped(original)
        let folded = (chars: mapped.chars, spaced: mapped.spaced)
        let ranked = latest.values.sorted { ($0.count, $0.lastSeen) > ($1.count, $1.lastSeen) }

        var taken: [(start: Int, end: Int, right: String)] = []   // original character offsets, end exclusive
        for item in ranked {
            let wrong = Array(normalize(item.pair.wrong)), right = Array(normalize(item.pair.right))
            // Only when `right` is longer than `wrong` can a match sit inside an occurrence of `right`.
            let rightRanges = right == wrong ? [] : matches(right, in: folded, boundaries: false)
            for m in matches(wrong, in: folded, boundaries: true) {
                // "张" → "张三" must not turn "张三" into "张三三".
                if rightRanges.contains(where: { $0.lowerBound <= m.lowerBound && m.upperBound <= $0.upperBound }) { continue }
                let start = mapped.origin[m.lowerBound], end = mapped.origin[m.upperBound - 1] + 1
                guard !taken.contains(where: { start < $0.end && $0.start < end }) else { continue }
                if String(original[start..<end]) == item.pair.right { continue }
                taken.append((start, end, item.pair.right))
            }
        }
        guard !taken.isEmpty else { return text }
        var out = ""
        var i = 0
        for t in taken.sorted(by: { $0.start < $1.start }) {
            out += String(original[i..<t.start]) + t.right
            i = t.end
        }
        return out + String(original[i...])
    }

    /// `fold`, plus the offset in `chars` of the original character each folded character came from.
    static func foldMapped(_ chars: [Character]) -> (chars: [Character], spaced: [Bool], origin: [Int]) {
        var out: [Character] = [], spaced: [Bool] = [], origin: [Int] = []
        var gap = false
        for (i, c) in chars.enumerated() {
            if c.isWhitespace { gap = true; continue }
            for l in String(c).lowercased() {
                out.append(l); spaced.append(gap); origin.append(i)
                gap = false
            }
        }
        return (out, spaced, origin)
    }

    /// Every non-overlapping occurrence of `w` in `t`, left to right; with `boundaries`, only where `occurs` would accept it.
    static func matches(_ w: [Character], in t: (chars: [Character], spaced: [Bool]), boundaries: Bool) -> [Range<Int>] {
        guard let first = w.first, let last = w.last, w.count <= t.chars.count else { return [] }
        var out: [Range<Int>] = []
        var s = 0
        while s <= t.chars.count - w.count {
            let e = s + w.count
            guard t.chars[s..<e].elementsEqual(w) else { s += 1; continue }
            if boundaries {
                if isWord(first), s > 0, !t.spaced[s], isWord(t.chars[s - 1]) { s += 1; continue }
                if isWord(last), e < t.chars.count, !t.spaced[e], isWord(t.chars[e]) { s += 1; continue }
            }
            out.append(s..<e)
            s = e
        }
        return out
    }

    static func isWord(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }


    /// `normalize(s)` as characters, each marked when whitespace came right before it.
    static func fold(_ s: String) -> (chars: [Character], spaced: [Bool]) {
        var chars: [Character] = [], spaced: [Bool] = []
        var gap = false
        for c in s.lowercased() {
            if c.isWhitespace { gap = true; continue }
            chars.append(c); spaced.append(gap)
            gap = false
        }
        return (chars, spaced)
    }

    /// `Mac` matches `Mac 上` but not `Machine`; `Cloud` does not match `iCloud`.
    static func occurs(_ w: [Character], in t: (chars: [Character], spaced: [Bool])) -> Bool {
        guard let first = w.first, let last = w.last, w.count <= t.chars.count else { return false }
        func word(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
        for s in 0...(t.chars.count - w.count) where t.chars[s..<(s + w.count)].elementsEqual(w) {
            let e = s + w.count
            if word(first), s > 0, !t.spaced[s], word(t.chars[s - 1]) { continue }
            if word(last), e < t.chars.count, !t.spaced[e], word(t.chars[e]) { continue }
            return true
        }
        return false
    }
}
