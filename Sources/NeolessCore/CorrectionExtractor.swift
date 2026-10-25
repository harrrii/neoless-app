import Foundation
import NaturalLanguage

/// A recognition error the user fixed by hand: `wrong` was delivered, `right` is what they changed it to.
public struct CorrectionPair: Codable, Hashable, Sendable {
    public var wrong: String
    public var right: String

    public init(wrong: String, right: String) {
        self.wrong = wrong; self.right = right
    }
}

/// One thing an edit taught.
public struct TermFix: Equatable, Sendable {
    public var pair: CorrectionPair
    /// Only `right` is learned, as a word for the dictionary and the recognizer, never the mapping: the
    /// misheard side is everyday text (你好 → Nio would rewrite every 你好), or the fix is a capital given
    /// to a word (cursor → Cursor).
    public var termOnly: Bool
    /// A capital given to a lowercase word in the middle of a Chinese clause (cursor → Cursor, but also
    /// bug → Bug): one such edit is as often style as a name, so the word is only noted, and learned when
    /// the same capital is given in a second dictation (`LearningBook.record`, `sightings`).
    public var tentative: Bool

    public init(pair: CorrectionPair, termOnly: Bool = false, tentative: Bool = false) {
        self.pair = pair; self.termOnly = termOnly; self.tentative = tentative
    }
}

/// What an edit taught, or why it taught nothing.
public struct Extraction: Equatable, Sendable {
    /// Why nothing was learned, for one quiet line.
    public enum Nothing: String, Codable, Sendable {
        /// Words were only removed or added: there is no wrong → right in that.
        case removedOnly
        /// Only punctuation, spacing or capitals.
        case formatOnly
        /// Most of the passage was rewritten.
        case rewrite
        /// The change sits next to a password, a code, an address or a link.
        case sensitive
        /// Words were replaced, but not by sound-alike terms (other words, numbers, everyday words): the user
        /// reworded something.
        case notTerms
        /// A name in Latin letters was typed in place of words that do not sound enough like it to learn a
        /// mapping from. The user was fixing a term, so this one is worth telling them.
        case unlikeName
        /// The same, and the name is one of the user's own dictionary words already: adding it there would
        /// not help, the change just does not look like a recognition error (Jason → Martin, CPU → GPU).
        case knownName
    }

    public var fixes: [TermFix]
    public var nothing: Nothing?
    /// The delivered text with the learned stretches changed and nothing else, when the edit taught something:
    /// what the next edit is compared with (`EditTracker.commit`). A stretch that taught nothing (a word still
    /// being typed, a deletion, a rephrased clause) stays as it was delivered, so it is looked at again whole
    /// once the user is done with it.
    public var baseline: String?
    /// The edit taught something, and in the same edit a name was typed that could not be learned
    /// (`.unlikeName` or `.knownName`): worth telling the user as well, so they know which word to add.
    public var missedName: Nothing?
    /// Words the user typed over others that do not sound like them (米线 → 曲线, GitHub → GitLab): no term
    /// fix by the rules, alike enough to be a slip of the recognizer all the same, and nothing a rule
    /// forbids (`CorrectionExtractor.isRepeatable`). One such swap teaches nothing and is used for nothing;
    /// it is only remembered, and learned when the same swap is made in another dictation
    /// (`LearningBook.candidates`). Each is the words that changed and no more, so that it is the same pair
    /// in whatever sentence it is made (`CorrectionExtractor.swap`). `nothing` still says why the edit
    /// taught nothing by the rules.
    public var candidates: [CorrectionPair]
    /// Every stretch of the compared text that was replaced, with what stands in its place, as the two
    /// texts were cut into words. For `shows(_:)` only, and like the rest of a comparison never kept: it
    /// holds the user's text. Empty when the comparison gave up (a rewrite, a secret in the passage).
    public var replaced: [CorrectionPair]
    /// Words typed over others that the rules could not take as recognition errors only because the two do
    /// not sound alike, or because a name was typed over everyday words, and that no rule forbids
    /// (`CorrectionExtractor.isJudgeable`): worth asking ChatGPT about, with what the recognizer heard
    /// (`POST /v1/learning/judge`). Each like `candidates`, the words that changed and no more. Asking
    /// teaches nothing by itself; what ChatGPT judges misheard is learned on the Neo (`Kind.judged`).
    public var doubts: [CorrectionPair]

    public init(fixes: [TermFix] = [], nothing: Nothing? = nil, baseline: String? = nil, missedName: Nothing? = nil,
                candidates: [CorrectionPair] = [], replaced: [CorrectionPair] = [], doubts: [CorrectionPair] = []) {
        self.fixes = fixes; self.nothing = nothing; self.baseline = baseline; self.missedName = missedName
        self.candidates = candidates; self.replaced = replaced; self.doubts = doubts
    }

    /// Whether the passage this comparison looked at still shows `swap`, which an earlier comparison of the
    /// same passage remembered. A swap moves nothing into what the passage is compared with, so it is found
    /// again each time while it is there: among `candidates`, or, when more was typed right next to it since
    /// (曲线吧, 曲线的走势: the change is then one longer stretch, and no swap by the rules), in a replaced
    /// stretch that holds its typed-over word and, as a word of its own, the word typed over it. It is gone
    /// when the delivered word is back (no stretch holds it), when something else stands there now, or when
    /// the word typed over it has grown into a longer one (曲线 into 曲线图, 学习 into 学习曲线: it was the
    /// first half of a word typed with a pause). Gone too, with everything, when the passage was rewritten
    /// or holds a secret now.
    public func shows(_ swap: CorrectionPair) -> Bool {
        let key = LearningBook.key(swap)
        if candidates.contains(where: { LearningBook.key($0) == key }) { return true }
        let wrong = swap.wrong.lowercased()
        return replaced.contains { $0.wrong.lowercased().contains(wrong) && CorrectionExtractor.standsAlone(swap.right, in: $0.right) }
    }

    /// The fixes that are wrong → right mappings.
    public var pairs: [CorrectionPair] { fixes.filter { !$0.termOnly }.map(\.pair) }
    /// The words learned without a mapping (`TermFix.termOnly`).
    public var terms: [String] { fixes.filter { $0.termOnly && !$0.tentative }.map(\.pair.right) }
    /// The words only noted for now (`TermFix.tentative`).
    public var sightings: [String] { fixes.filter(\.tentative).map(\.pair.right) }
    public var isEmpty: Bool { fixes.isEmpty }
    /// The edit left something in the learning book: a fix, a word, or a swap to remember. The comparison is
    /// then committed (`EditTracker.commit`, with `baseline` and `alone`).
    public var teaches: Bool { !fixes.isEmpty || !candidates.isEmpty }
    /// The words this edit put there on their own, for `EditTracker.commit(alone:)`: when the text no longer
    /// shows one of them, what taught it is taken back.
    public var alone: [String] { terms + sightings + candidates.map(\.right) }
}

/// Finds term corrections between the text neoless delivered and the user's edit of it. Every changed
/// stretch is judged on its own: a deleted filler word or a rephrased clause teaches nothing and takes
/// nothing away from a term fixed next to it. Meaning edits, numbers and formatting are never learned,
/// only short sound-alike fixes of names and terms.
///
/// A wrong pair is worse than none: once learned it is put before the model, and after a second fix written
/// into text without it. So wherever a rule cannot tell a recognition error from the user changing what
/// they said, nothing is learned: a number, a date, a negation or an opposite that changed; one name or one
/// ordinary word typed over another that does not sound the same (also towards a dictionary word, when what
/// was typed over is itself a word of the dictionary, an acronym, a name written with a capital inside, or
/// a person's name); one Han character that cannot be placed in a word; anything in a passage that holds a
/// secret. And what is learned is written into text without the model only when its misheard side is
/// nothing anyone says on purpose (`replacesBlindly`).
public struct CorrectionExtractor: Sendable {
    /// Splits one run of Han characters into words.
    public var segmentCJK: @Sendable (String) -> [String]
    /// Says whether one Chinese word is a name, and of what (`nameKind(of:)`): asked only before a swap is
    /// remembered (`isRepeatable`), after the lists of names it is checked against.
    public var nameKind: @Sendable (String) -> NameKind?

    /// What a name names.
    public enum NameKind: Equatable, Sendable { case person, place, organization }

    /// `maxPairs`: how many pairs one learning event takes (`LearningBook.maxPairsPerEvent`); an edit with
    /// more fixes is learned as several events.
    public static let maxPassage = 4_000, maxPairs = 3
    /// More replaced stretches than this is a rewrite, not a set of fixes.
    static let maxScattered = 8
    /// Above this share of the passage deleted or replaced by something that is no term fix, nothing is learned.
    static let rewriteShare = 0.4
    /// More stretches than this reworded (replaced by other words, not a fix and not formatting): the user is
    /// rewriting, and what looks like a fix in between is not trusted.
    static let maxReworded = 2
    static let maxMiddleTokens = 400
    /// How different two sides may sound (0 the same, 1 nothing in common): everyday text; a term already in
    /// the dictionary; Han written for a foreign name (科德克斯 → Codex). A short name (under six letters either
    /// way) further off than `shortNameDistance`, or two Han characters further off than
    /// `twoCharacterNameDistance`, is learned as a word only.
    static let maxPhoneticDistance = 0.45, knownPhoneticDistance = 0.6, namePhoneticDistance = 0.65
    static let shortNameDistance = 0.5, twoCharacterNameDistance = 0.34
    /// An all-capital run this close to the pinyin of what it replaced is the IME's, with Caps Lock on.
    static let capsPinyinDistance = 0.4

    public init(segmentCJK: @escaping @Sendable (String) -> [String] = { CorrectionExtractor.wordSegments($0) },
                nameKind: @escaping @Sendable (String) -> NameKind? = { CorrectionExtractor.nameKind(of: $0) }) {
        self.segmentCJK = segmentCJK
        self.nameKind = nameKind
    }

    /// What the system's tagger takes the Chinese word `word` for, when it takes all of it for one name:
    /// a person (王伟, 张总, 小李), a place (广州, 法国), an organization. Nil for any other word, and
    /// for one the tagger does not know. It knows far more names than a list can hold, but what it says may
    /// differ from one system to the next: it only ever adds to what is refused, never to what is learned.
    public static func nameKind(of word: String) -> NameKind? {
        guard !word.isEmpty else { return nil }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = word
        tagger.setLanguage(.simplifiedChinese, range: word.startIndex..<word.endIndex)
        var tags: [NLTag?] = []
        tagger.enumerateTags(in: word.startIndex..<word.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, _ in
            tags.append(tag)
            return tags.count < 2
        }
        guard tags.count == 1, let tag = tags[0] else { return nil }
        switch tag {
        case .personalName: return .person
        case .placeName: return .place
        case .organizationName: return .organization
        default: return nil
        }
    }

    /// NLTokenizer word segmentation of one Han run, gaps kept so the pieces always rejoin to `run`.
    public static func wordSegments(_ run: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = run
        var out: [String] = []
        var last = run.startIndex
        tokenizer.enumerateTokens(in: run.startIndex..<run.endIndex) { range, _ in
            if last < range.lowerBound { out.append(String(run[last..<range.lowerBound])) }
            out.append(String(run[range]))
            last = range.upperBound
            return true
        }
        if last < run.endIndex { out.append(String(run[last...])) }
        return out
    }

    /// The wrong → right mappings in an edit. `knownTerms`: the user's own dictionary words (never the ones
    /// learning put there, or one learned word would lower the bar for every later edit towards it), which
    /// make a fix towards one of them easier to accept (claude → Claude, labels → Lavoben, 金币 → 音币).
    public func pairs(inserted: String, edited: String, knownTerms: Set<String> = []) -> [CorrectionPair] {
        extract(inserted: inserted, edited: edited, knownTerms: knownTerms).pairs
    }

    /// Everything an edit taught, mappings and words, in the order they occur (at most `maxScattered`).
    public func extract(inserted: String, edited: String, knownTerms: Set<String> = []) -> Extraction {
        let a = inserted.precomposedStringWithCanonicalMapping
        let b = edited.precomposedStringWithCanonicalMapping
        guard a != b, !a.isEmpty else { return Extraction() }
        guard a.count <= Self.maxPassage, b.count <= Self.maxPassage else { return Extraction(nothing: .rewrite) }
        let known = Set(knownTerms.map(Self.termKey))

        var old = tokenize(a), new = tokenize(b)
        guard var hunks = Self.diff(old, new) else { return Extraction(nothing: .rewrite) }
        hunks = Self.merged(hunks, old: old).map { $0.trimmed(old: old, new: new) }
        // The changes as the two texts were first cut into words, one for each hunk: a change the next step
        // cuts down to one character is still a change of the word that was delivered (`candidates`).
        let wordOld = old, wordNew = new
        var wordHunks = hunks
        hunks = Self.refined(hunks, old: &old, new: &new, known: known, segment: segmentCJK)
        hunks = hunks.map { $0.trimmed(old: old, new: new) }
        let kept = hunks.indices.filter { !(hunks[$0].old.isEmpty && hunks[$0].new.isEmpty) }
        wordHunks = kept.map { wordHunks[$0] }
        hunks = kept.map { hunks[$0] }
        let replacing = hunks.indices.filter { !hunks[$0].old.isEmpty && !hunks[$0].new.isEmpty }
        let replacements = replacing.map { hunks[$0] }
        guard !replacements.isEmpty else { return Extraction(nothing: hunks.isEmpty ? .formatOnly : .removedOnly) }
        guard replacements.count <= Self.maxScattered else { return Extraction(nothing: .rewrite) }
        /// What was replaced by what, for `Extraction.shows`.
        let stretches = replacing.map { i in
            CorrectionPair(wrong: Self.text(wordOld[wordHunks[i].old]), right: Self.text(wordNew[wordHunks[i].new]))
        }

        func size(_ tokens: ArraySlice<Token>) -> Int { tokens.reduce(0) { $0 + $1.text.filter { !$0.isWhitespace }.count } }
        var seen = Set<String>()
        var fixes: [TermFix] = []
        var skips: [Skip] = []
        /// The stretches that taught something, as learned.
        var learned: [Hunk] = []
        /// Characters replaced by something that is no term fix, and how many stretches were reworded.
        var unexplained = 0, reworded = 0
        /// A stretch was replaced by a name that could not be learned; one of those names is not in the
        /// dictionary (so adding it there is what would help).
        var nameMissed = false, unknownNameMissed = false
        /// Swaps no rule takes and none forbids: remembered, and learned when made again (`Extraction.candidates`).
        var candidates: [CorrectionPair] = []
        /// Swaps worth asking ChatGPT about (`Extraction.doubts`).
        var doubts: [CorrectionPair] = []
        for (n, core) in replacements.enumerated() {
            let h = Self.widened(core, old: old, new: new, known: known, segment: segmentCJK)
            // With the unchanged capitalized words next to it, as it would be learned: the dictionary may
            // have the name only that way (Claude Code, VS Code, Air France).
            let e = Self.extended(h, old: old, new: new)
            let phrase = Self.text(new[e.new])
            let phraseKnown = e.new.count > h.new.count && known.contains(Self.termKey(phrase))
            let verdict = Self.judge(h, core: core, old: old, new: new, alone: tokenize(Self.text(old[h.old])), known: known,
                                     phraseKnown: phraseKnown)
            if case .no(let skip) = verdict {
                skips.append(skip)
                // Every one of them is listed; `LearningBook.record` takes `maxPairsPerEvent` of them.
                if Self.nameSkips.contains(skip) {
                    // The words that changed, and nothing of what stands next to them: the same swap must
                    // be the same pair in every sentence, or its second time is never recognised. Only
                    // when the dictionary has the name with the unchanged capitalized words next to it
                    // (Claude Code) is it that phrase.
                    let swap = phraseKnown ? CorrectionPair(wrong: Self.text(old[e.old]), right: phrase)
                        : Self.swap(wordHunks[replacing[n]], old: wordOld, new: wordNew,
                                    placed: CorrectionPair(wrong: Self.text(old[h.old]), right: Self.text(new[h.new])))
                    func same(_ p: CorrectionPair) -> Bool {
                        p.wrong.lowercased() == swap.wrong.lowercased() && p.right.lowercased() == swap.right.lowercased()
                    }
                    if Self.repeatSkips.contains(skip), repeatable(wrong: swap.wrong, right: swap.right, known: known),
                       !candidates.contains(where: same) {
                        candidates.append(swap)
                    }
                    if repeatable(wrong: swap.wrong, right: swap.right, known: known, judging: true),
                       !doubts.contains(where: same) {
                        doubts.append(swap)
                    }
                }
                let name = Self.text(new[h.new])
                let named = Self.nameSkips.contains(skip) && Self.isLatinName(name)
                if named {
                    nameMissed = true
                    if !known.contains(Self.termKey(name)), !known.contains(Self.termKey(phrase)) { unknownNameMissed = true }
                }
                // A name typed over one word or one run of characters that could not be learned (Curser →
                // Cursor without Cursor in the dictionary) is no rewording of the passage: it takes nothing
                // away from a fix next to it. A name typed over a longer mixed stretch is rewording.
                let over = Self.text(old[h.old])
                if !(named && !(over.contains(where: Self.isHan) && over.contains(where: Self.isLatinAlnum))) {
                    if skip != .format, skip != .caseOnly { unexplained += size(old[core.old]) }
                    if Self.rewordings.contains(skip) { reworded += 1 }
                }
                continue
            }
            learned.append(e)
            let pair = CorrectionPair(wrong: Self.text(old[e.old]), right: phrase)
            guard seen.insert(pair.wrong.lowercased() + "|" + pair.right.lowercased()).inserted else { continue }
            fixes.append(TermFix(pair: pair, termOnly: verdict != .pair, tentative: verdict == .tentative))
        }
        // Rewritten: much of the passage replaced by other words, or several stretches reworded. What looks
        // like a fix inside a rewrite is not trusted. Anything less is judged stretch by stretch, so a deleted
        // filler word or one rephrased clause takes nothing away from a term fixed next to it. Deleted text
        // counts towards the share only next to rewording: cutting a sentence out and fixing a name in what is
        // left is two plain things, not a rewrite.
        let removed = reworded == 0 ? 0 : hunks.filter { $0.new.isEmpty }.reduce(0) { $0 + size(old[$1.old]) }
        guard Double(unexplained + removed) <= max(12, Self.rewriteShare * Double(size(old[...]))),
              reworded <= Self.maxReworded else { return Extraction(nothing: .rewrite) }
        // A secret anywhere in the passage: no word typed over another in it is learned, however far from
        // the secret it is.
        let replaced = !fixes.isEmpty || skips.contains { $0 != .format && $0 != .caseOnly }
        if replaced, Self.holdsSecret(a) || Self.holdsSecret(b) { return Extraction(nothing: .sensitive) }
        let missed: Extraction.Nothing? = nameMissed ? (unknownNameMissed ? .unlikeName : .knownName) : nil
        guard fixes.isEmpty else {
            return Extraction(fixes: fixes, baseline: Self.applying(learned, old: old, new: new), missedName: missed,
                              candidates: candidates, replaced: stretches, doubts: doubts)
        }
        if skips.contains(.sensitive) { return Extraction(nothing: .sensitive) }
        if skips.allSatisfy({ $0 == .format || $0 == .caseOnly }) { return Extraction(nothing: .formatOnly) }
        // A swap that is only remembered moves nothing into the baseline: it is compared again, whole, with
        // what was delivered, so its wrong side is never something the user typed on the way.
        return Extraction(nothing: missed ?? .notTerms, baseline: candidates.isEmpty ? nil : a, candidates: candidates,
                          replaced: stretches, doubts: doubts)
    }

    /// Whether `word` stands in `text` as a word of its own: at each end the text ends, or what follows is
    /// no part of a word it could belong to. For letters and digits that is anything else; for Han it is
    /// anything but Han, and a Han character that is a word of its own (的, 吧, 了, 是: `standaloneHan`,
    /// `structuralHan`). So 曲线 stands alone in 曲线吧 and 曲线的走势, and not in 曲线图 or 双曲线.
    static func standsAlone(_ word: String, in text: String) -> Bool {
        let w = Array(word.lowercased()), t = Array(text.lowercased())
        guard let first = w.first, let last = w.last, w.count <= t.count else { return false }
        func apart(_ edge: Character, _ next: Character) -> Bool {
            if isLatinAlnum(edge) { return !isLatinAlnum(next) }
            guard isHan(edge), isHan(next) else { return true }
            return standaloneHan.contains(next) || structuralHan.contains(String(next))
        }
        for start in 0...(t.count - w.count) where Array(t[start..<(start + w.count)]) == w {
            let end = start + w.count
            if start > 0, !apart(first, t[start - 1]) { continue }
            if end < t.count, !apart(last, t[end]) { continue }
            return true
        }
        return false
    }

    /// The reasons a stretch replaced by a name was not learned that are about the name not being close enough
    /// (not about numbers, secrets, opposites or leftover pinyin).
    static let nameSkips: Set<Skip> = [.sound, .everyday, .long, .structural]
    /// The reasons that say the user put other words there (not formatting, a secret or the input method).
    static let rewordings: Set<Skip> = [.number, .long, .structural, .opposite, .everyday, .sound]

    /// What a replaced stretch is remembered as when it is no fix by the rules (`Extraction.candidates`): the
    /// words of the delivered text that changed, and what stands in their place. `word` is the change as the
    /// two texts were first cut into words. Changing part of a run of Han re-segments what is left of it, so
    /// such a change can hold words that never changed (脚步|来 → 脚|本来): those are cut off again, at the
    /// word edges of the delivered text, which is what a later transcript will be searched for (脚步 → 脚本,
    /// and 金币|多 → 音|币多 is 金币 → 音币). Never the unchanged words next to the change: a name is the
    /// same swap after "Ask" and after "think" (Cloud → Claude). Where that leaves one Han character, which
    /// is part of countless words, the swap is the word the rules place it in (`placed`: 代码|厂 → 代码|仓 is
    /// 代码厂 → 代码仓), or the whole change when they place it nowhere.
    static func swap(_ word: Hunk, old: [Token], new: [Token], placed: CorrectionPair) -> CorrectionPair {
        let o = Array(old[word.old].map(\.text).joined()), n = Array(new[word.new].map(\.text).joined())
        let whole = CorrectionPair(wrong: String(o).trimmingCharacters(in: .whitespacesAndNewlines),
                                   right: String(n).trimmingCharacters(in: .whitespacesAndNewlines))
        let limit = min(o.count, n.count)
        var cp = 0
        while cp < limit, o[cp] == n[cp], isHan(o[cp]) { cp += 1 }
        var cs = 0
        while cs < limit - cp, o[o.count - 1 - cs] == n[n.count - 1 - cs], isHan(o[o.count - 1 - cs]) { cs += 1 }
        let edges = old[word.old].reduce(into: [0]) { $0.append($0[$0.count - 1] + $1.text.count) }
        let left = edges.last { $0 <= cp } ?? 0
        let right = edges.map { o.count - $0 }.filter { $0 <= cs }.max() ?? 0
        var out = whole
        if left + right > 0, o.count - left - right > 0, n.count - left - right > 0 {
            out = CorrectionPair(wrong: String(o[left..<(o.count - right)]).trimmingCharacters(in: .whitespacesAndNewlines),
                                 right: String(n[left..<(n.count - right)]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        func oneHan(_ s: String) -> Bool { s.count == 1 && s.allSatisfy(isHan) }
        if oneHan(out.wrong) || out.wrong.isEmpty || out.right.isEmpty {
            out = placed.wrong.count > 1 && placed.right.count > 1 ? placed : whole
        }
        return out
    }

    /// `old` with the `learned` stretches replaced by what they were changed to, and nothing else changed.
    static func applying(_ learned: [Hunk], old: [Token], new: [Token]) -> String {
        var out = ""
        var i = 0
        for h in learned.sorted(by: { $0.old.lowerBound < $1.old.lowerBound }) where h.old.lowerBound >= i {
            out += old[i..<h.old.lowerBound].map(\.text).joined() + new[h.new].map(\.text).joined()
            i = h.old.upperBound
        }
        return out + old[i...].map(\.text).joined()
    }

    /// Latin letters only, with a capital: a name or a term, as someone types it on purpose.
    static func isLatinName(_ s: String) -> Bool {
        s.contains(where: \.isUppercase) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " " || latinJoiners.contains($0)) }
    }

    // MARK: Sensitive text

    /// Words that introduce a secret (密码是 …), or are one. A passage that holds one teaches nothing
    /// (`holdsSecret`).
    static let secretWords = [
        "密码", "密碼", "口令", "暗号", "验证码", "校验码", "安全码", "恢复码", "授权码", "激活码", "密钥", "私钥", "助记词",
        "卡号", "身份证",
        "password", "passwd", "passcode", "passphrase", "private key", "seed phrase", "api key", "api_key",
        "api-key", "apikey", "secret", "credential", "bearer ",
    ]
    /// Everyday words in talk about code that introduce a secret only as a label: `token 是 …`, `token: …`,
    /// alone on the line above, or a clause or two before a link (`token 之前给过你，就是 …`). They count only
    /// near the change, never for the whole passage.
    static let labelWords = ["token", "pwd", "pin", "key"]
    static let labelLinks = ["是", "为", "就是", "is ", "is\n", ":", "：", "="]
    /// What a clause ends in when the next thing said is the value itself (`…，就是 X`, `… is X`, `…: X`).
    static let closingLinks = ["是", "为", "is", ":", "：", "="]
    /// An unbroken run of letters and digits this long, with both in it, reads as a key or a hash.
    static let keyRun = 20

    /// Whether the passage `s` holds a secret: a word that introduces one or is one, wherever it stands (a
    /// password given after its label across a full stop, a blank line, a list marker or a longer clause is
    /// still a password), or something shaped like a key. Nothing is learned from such a passage: what is
    /// learned is stored, shown, sent to the Neo and from then on sent with every polish.
    static func holdsSecret(_ s: String) -> Bool {
        let lower = s.lowercased()
        if secretWords.contains(where: lower.contains) { return true }
        var run = 0, letters = false, digits = false
        for c in lower + " " {
            if isLatinAlnum(c) || c == "_" || c == "-" {
                run += 1
                if c.isLetter { letters = true }
                if c.isNumber { digits = true }
                continue
            }
            if run >= keyRun, letters, digits { return true }
            (run, letters, digits) = (0, false, false)
        }
        return false
    }

    /// Whether `s` itself reads like something secret or an address: never part of a learned pair.
    static func isSensitive(_ s: String) -> Bool {
        let lower = s.lowercased()
        if secretWords.contains(where: lower.contains) || isAddress(lower) { return true }
        var word = 0
        for c in lower + " " {
            if isLatinAlnum(c) { word += 1; continue }
            // One unbroken run too long to be a name: a key, a hash.
            if word >= 20 { return true }
            word = 0
        }
        return false
    }

    static func isAddress(_ lower: String) -> Bool {
        lower.contains("@") || lower.contains("://") || lower.contains("www.")
    }

    /// How many words before a change are looked at for a word that introduces a secret (a label may stand a
    /// clause or two back: `token 之前给过你，就是 …`), and how many after it.
    static let secretLookBack = 10, secretLookAhead = 3

    /// Whether the change in `r` sits where a secret would: after a word that introduces one, also across a
    /// comma, a colon, 就是 or one line break (密码⏎abcdef, 新的密码，就是 abcdef), right before one, or in an
    /// address or a link (foo@example.com, foo @ example.com, https://…). For addresses, links and labels
    /// such as `token` only what is near the change counts: an address or talk about tokens elsewhere in
    /// the passage is no reason to learn nothing. (A password word anywhere is: `holdsSecret`.)
    static func sensitiveContext(_ r: Range<Int>, in tokens: [Token]) -> Bool {
        // The unbroken run of ASCII around the change: an address or a link is one of these.
        func ascii(_ t: Token) -> Bool { t.kind != .space && t.text.allSatisfy(\.isASCII) }
        var lo = r.lowerBound, hi = r.upperBound
        while lo > 0, ascii(tokens[lo - 1]) { lo -= 1 }
        while hi < tokens.count, ascii(tokens[hi]) { hi += 1 }
        if isAddress(tokens[lo..<hi].map(\.text).joined().lowercased()) { return true }
        // An @ a word or two away on the same line: an address typed with spaces.
        func at(from start: Int, step: Int) -> Bool {
            var i = start, seen = 0
            while i >= 0, i < tokens.count, seen < 3 {
                let t = tokens[i]
                if t.kind == .space {
                    if t.text.contains(where: \.isNewline) { return false }
                } else {
                    if t.text == "@" { return true }
                    seen += 1
                }
                i += step
            }
            return false
        }
        if at(from: r.lowerBound - 1, step: -1) || at(from: r.upperBound, step: 1) { return true }

        // Before: a few words back, through commas, colons, list markers and one line break, up to the end of
        // the sentence before.
        var i = r.lowerBound - 1, words = 0, lines = 0
        var before: [String] = []
        while i >= 0, words < secretLookBack {
            let t = tokens[i]
            if t.kind == .space {
                lines += t.text.filter(\.isNewline).count
                if lines > 1 { break }
            } else if t.kind == .punct {
                if let c = t.text.first, sentenceStops.contains(c) { break }
            } else {
                words += 1
            }
            before.append(t.text)
            i -= 1
        }
        let lead = before.reversed().joined().lowercased()
        if secretWords.contains(where: lead.contains) || labels(lead) { return true }

        // After: within the clause.
        var j = r.upperBound
        words = 0
        var after = ""
        while j < tokens.count, words < secretLookAhead {
            let t = tokens[j]
            if t.kind == .space, t.text.contains(where: \.isNewline) { break }
            if t.kind == .punct, let c = t.text.first, clauseEnds.contains(c) { break }
            if t.kind != .space, t.kind != .punct { words += 1 }
            after += t.text
            j += 1
        }
        return secretWords.contains(where: after.lowercased().contains)
    }

    /// `lead` (the text right before a change, lowercased) introduces a secret by a label: it ends in one
    /// (`token 是 `, `token: `, or `token` alone on the line above), or it holds one and ends in a link, so
    /// what follows is the thing the label was about (`token 之前给过你，就是 `, `新的 token 我发你了，是 `).
    /// A label is a word of its own: `pin` is none in `pinyin`, `key` none in `keyboard`.
    static func labels(_ lead: String) -> Bool {
        let chars = Array(lead)
        let end = String(lead.reversed().drop(while: \.isWhitespace).reversed())
        let linked = closingLinks.contains(where: end.hasSuffix)
        func letter(_ i: Int) -> Bool { i >= 0 && i < chars.count && chars[i].isASCII && chars[i].isLetter }
        for word in labelWords {
            let w = Array(word)
            guard w.count <= chars.count else { continue }
            for start in 0...(chars.count - w.count) where Array(chars[start..<(start + w.count)]) == w {
                let after = start + w.count
                guard !letter(start - 1), !letter(after) else { continue }
                if linked { return true }
                let next = String(chars[after...].drop { $0 == " " || $0 == "\t" })
                if next.isEmpty || next.first?.isNewline == true || labelLinks.contains(where: { next.hasPrefix($0) }) { return true }
            }
        }
        return false
    }

    static let clauseEnds = Set("。！？；，、,.!?;")
    static let sentenceStops = Set("。！？；!?;")

    /// Where a change stands, for what a capital given to its first letter says about the word.
    enum Place {
        /// At the start of the text, a line, a sentence, a list item or a quotation, after any punctuation:
        /// a capital there is how sentences and headings are written, also for a dictionary word.
        case start
        /// In the middle of a Chinese clause (用 cursor 写): a capital names a word.
        case afterHan
        /// Inside English text: a capital says something only about a word the user has in the dictionary.
        case afterLatin
        /// A pair that arrives without its text.
        case unknown
    }

    static func place(of r: Range<Int>, in tokens: [Token]) -> Place {
        var i = r.lowerBound - 1
        while i >= 0, tokens[i].kind == .space {
            if tokens[i].text.contains(where: \.isNewline) { return .start }
            i -= 1
        }
        guard i >= 0 else { return .start }
        switch tokens[i].kind {
        case .cjk: return .afterHan
        case .latin: return .afterLatin
        default: return .start
        }
    }

    // MARK: Tokens

    enum Kind { case latin, number, cjk, space, punct, other }

    struct Token: Equatable {
        var kind: Kind
        var text: String
        /// Cut off a longer word of its text by `refined` (成 of 成瘾, once 瘾 was seen to be what changed): in
        /// that text it was no character standing alone. Not part of what makes two tokens equal.
        var fragment = false

        static func == (a: Token, b: Token) -> Bool { a.kind == b.kind && a.text == b.text }
    }

    static let latinJoiners: Set<Character> = [".", "'", "-", "_", "+"]
    static let cjkNumerals = Set("零〇一二两三四五六七八九十百千万亿")
    static let cjkUnits = Set("元角分块整币")
    static let englishNumbers: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh",
        "twelfth", "half", "quarter", "dozen",
    ]

    func tokenize(_ s: String) -> [Token] {
        let chars = Array(s)
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            var j = i + 1
            if Self.isLatinAlnum(c) {
                while j < chars.count {
                    if Self.isLatinAlnum(chars[j]) { j += 1 }
                    else if j + 1 < chars.count, Self.latinJoiners.contains(chars[j]), Self.isLatinAlnum(chars[j + 1]) { j += 2 }
                    else { break }
                }
                let text = String(chars[i..<j])
                let number = !text.contains(where: \.isLetter) || Self.englishNumbers.contains(text.lowercased())
                tokens.append(Token(kind: number ? .number : .latin, text: text))
            } else if Self.isHan(c) {
                while j < chars.count, Self.isHan(chars[j]) { j += 1 }
                let run = String(chars[i..<j])
                var parts = segmentCJK(run).filter { !$0.isEmpty }
                if parts.joined() != run { parts = run.map { String($0) } }
                for part in parts { tokens.append(Self.hanToken(part)) }
            } else if c.isWhitespace {
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                tokens.append(Token(kind: .space, text: String(chars[i..<j])))
            } else {
                tokens.append(Token(kind: Self.isPunct(c) ? .punct : .other, text: String(c)))
            }
            i = j
        }
        return tokens
    }

    static func hanToken(_ text: String) -> Token {
        Token(kind: text.allSatisfy(cjkNumerals.contains) ? .number : .cjk, text: text)
    }

    static func isLatinAlnum(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    static func isHan(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let v = c.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0x20000...0x3134F).contains(v) || v == 0x3007
    }

    static func isPunct(_ c: Character) -> Bool {
        if c.isPunctuation || (c.isASCII && !c.isLetter && !c.isNumber && !c.isWhitespace) { return true }
        guard c.isSymbol, let category = c.unicodeScalars.first?.properties.generalCategory else { return false }
        return [.mathSymbol, .currencySymbol, .modifierSymbol].contains(category)
    }

    static func text(_ tokens: ArraySlice<Token>) -> String {
        tokens.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How a dictionary word is looked up: case and spacing do not matter.
    static func termKey(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Diff

    /// One changed region: token ranges in the old and new token lists.
    struct Hunk {
        var old: Range<Int>
        var new: Range<Int>

        func trimmed(old o: [Token], new n: [Token]) -> Hunk {
            Hunk(old: Self.trim(old, o), new: Self.trim(new, n))
        }

        static func trim(_ r: Range<Int>, _ tokens: [Token]) -> Range<Int> {
            var lo = r.lowerBound, hi = r.upperBound
            func edge(_ t: Token) -> Bool { t.kind == .space || t.kind == .punct }
            while lo < hi, edge(tokens[lo]) { lo += 1 }
            while hi > lo, edge(tokens[hi - 1]) { hi -= 1 }
            return lo..<hi
        }
    }

    /// Common prefix and suffix trimmed, then an LCS over the middle. `nil` when the middle is too long.
    static func diff(_ a: [Token], _ b: [Token]) -> [Hunk]? {
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        let x = Array(a[p..<(a.count - s)]), y = Array(b[p..<(b.count - s)])
        guard x.count <= maxMiddleTokens, y.count <= maxMiddleTokens else { return nil }

        // lcs[i][j] = LCS length of x[i...] and y[j...]
        let w = y.count + 1
        var lcs = [Int](repeating: 0, count: (x.count + 1) * w)
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            for j in stride(from: y.count - 1, through: 0, by: -1) {
                lcs[i * w + j] = x[i] == y[j] ? lcs[(i + 1) * w + j + 1] + 1 : max(lcs[(i + 1) * w + j], lcs[i * w + j + 1])
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0
        while i < x.count || j < y.count {
            if i < x.count, j < y.count, x[i] == y[j] { i += 1; j += 1; continue }
            let (i0, j0) = (i, j)
            while i < x.count || j < y.count {
                if i < x.count, j < y.count, x[i] == y[j] { break }
                if j == y.count || (i < x.count && lcs[(i + 1) * w + j] >= lcs[i * w + j + 1]) { i += 1 } else { j += 1 }
            }
            hunks.append(Hunk(old: (p + i0)..<(p + i), new: (p + j0)..<(p + j)))
        }
        return hunks
    }

    /// Joins hunks separated only by whitespace (`Open Air` → `OpenAI` is one change).
    static func merged(_ hunks: [Hunk], old: [Token]) -> [Hunk] {
        var out: [Hunk] = []
        for h in hunks {
            if let last = out.last, old[last.old.upperBound..<h.old.lowerBound].allSatisfy({ $0.kind == .space }) {
                out[out.count - 1] = Hunk(old: last.old.lowerBound..<h.old.upperBound, new: last.new.lowerBound..<h.new.upperBound)
            } else {
                out.append(h)
            }
        }
        return out
    }

    /// Hunks are made of whole segmenter words, and changing part of a Han run re-segments what is left of it
    /// (好|用 becomes 好用 once the name before it is Latin), so a hunk can swallow characters that never
    /// changed. Cuts each replacement back to what changed, kept to whole words of the corrected text
    /// (以|经改 → 已经|改 is 以经 → 已经). When that leaves one character on each side, the word of the misheard
    /// text it stood in is taken instead (金币|多 → 音|币多 is 金币 → 音币), but only when the corrected side is
    /// then a word too, the user's own or the segmenter's: where the misheard character had merely joined its
    /// neighbour into some other word (换|成瘾|币 for 换成音币), that word says nothing about what was meant,
    /// and 成瘾 → 成音 would be a pair of an unrelated everyday word with no word at all. Then the change
    /// stays the one character, for `widened` to place. Tokens cut in two are split in `old` and `new`.
    static func refined(_ hunks: [Hunk], old: inout [Token], new: inout [Token], known: Set<String> = [],
                        segment: (String) -> [String] = { wordSegments($0) }) -> [Hunk] {
        var out: [Hunk] = []
        var shiftOld = 0, shiftNew = 0
        for original in hunks {
            var h = Hunk(old: (original.old.lowerBound + shiftOld)..<(original.old.upperBound + shiftOld),
                         new: (original.new.lowerBound + shiftNew)..<(original.new.upperBound + shiftNew))
            guard !h.old.isEmpty, !h.new.isEmpty else { out.append(h); continue }
            let o = Array(old[h.old].map(\.text).joined()), n = Array(new[h.new].map(\.text).joined())
            let limit = min(o.count, n.count)
            var cp = 0
            while cp < limit, o[cp] == n[cp], isHan(o[cp]) { cp += 1 }
            var cs = 0
            while cs < limit - cp, o[o.count - 1 - cs] == n[n.count - 1 - cs], isHan(o[o.count - 1 - cs]) { cs += 1 }
            guard cp > 0 || cs > 0 else { out.append(h); continue }

            /// Character offsets of the word edges in `tokens`, 0 and the total included.
            func edges(_ tokens: ArraySlice<Token>) -> [Int] {
                tokens.reduce(into: [0]) { $0.append($0[$0.count - 1] + $1.text.count) }
            }
            let nEdges = edges(new[h.new]), oEdges = edges(old[h.old])
            var left = nEdges.last { $0 <= cp } ?? 0
            var right = nEdges.map { n.count - $0 }.filter { $0 <= cs }.max() ?? 0
            if o.count - left - right == 1, n.count - left - right == 1 {
                let wider = (left: min(left, oEdges.last { $0 <= cp } ?? 0),
                             right: min(right, oEdges.map { o.count - $0 }.filter { $0 <= cs }.max() ?? 0))
                if wider.left != left || wider.right != right {
                    let corrected = String(n[wider.left..<(n.count - wider.right)])
                    if known.contains(termKey(corrected)) || segment(corrected).count == 1 { (left, right) = wider }
                }
            }
            guard left > 0 || right > 0 else { out.append(h); continue }

            let oldCut = cut(&old, h.old, from: left, to: o.count - right)
            let newCut = cut(&new, h.new, from: left, to: n.count - right)
            h = Hunk(old: oldCut.range, new: newCut.range)
            shiftOld += oldCut.added
            shiftNew += newCut.added
            out.append(h)
        }
        return out
    }

    /// The tokens of `range` between character offsets `from` and `to` (counted from the start of `range`),
    /// splitting a token an offset falls inside. `added`: how many tokens the splits added.
    static func cut(_ tokens: inout [Token], _ range: Range<Int>, from: Int, to: Int) -> (range: Range<Int>, added: Int) {
        var added = 0
        /// The index of the token that starts at character `offset`, splitting one if needed.
        func boundary(_ offset: Int) -> Int {
            var at = 0, i = range.lowerBound
            let end = range.upperBound + added
            while i < end {
                let length = tokens[i].text.count
                if at == offset { return i }
                if offset < at + length {
                    let chars = Array(tokens[i].text)
                    tokens[i] = hanToken(String(chars[..<(offset - at)]))
                    tokens[i].fragment = true
                    tokens.insert(hanToken(String(chars[(offset - at)...])), at: i + 1)
                    tokens[i + 1].fragment = true
                    added += 1
                    return i + 1
                }
                at += length
                i += 1
            }
            return end
        }
        let hi = boundary(to)
        let before = added
        let lo = boundary(from)
        return (lo..<(hi + added - before), added)
    }

    /// Single Han characters that are words of their own, never part of a name: a changed character is not
    /// widened across them (按纽设 stays 按纽 → 按钮), and one or two of them heard for a Latin name are
    /// everyday text, not its syllables.
    static let standaloneHan = Set(
        "说找看请给让把被跟对去来要想用叫问这那有也都就还很个不没别我你他她它的地得了吗呢吧和与或在是"
            + "设放改写发做打开关拿加减买卖走跑到上下里外中前后时再又才从向往为以及并而但若如因所将已曾正刚会能可该等比"
            + "点种些次遍下回吃喝听读学教带送接住站坐想知懂爱怕像算过着完好坏多少大小新旧快慢高低")

    /// A change of one Han character is no pair by itself (one character is part of countless words): it is
    /// widened to the word it stands in, up to 4 characters, never across a numeral.
    /// 1. The unchanged words around it that make the corrected side one of the user's own dictionary words
    ///    (棍 → 滚 in 回棍一下, with 回滚 in the dictionary): that word is what was meant.
    /// 2. The unchanged single characters around it: the segmenter cuts names and rare words into characters
    ///    (张 → 章 in 张伟说 is 张伟 → 章伟). Never a character that is a word of its own, and never one cut
    ///    off a longer word of the delivered text (`Token.fragment`).
    /// 3. Still alone: the unchanged word right before it, when the two make a compound the segmenter does not
    ///    know (厂 → 仓 after 代码 is 代码厂 → 代码仓). Not when either character is a word of its own (方案好 is
    ///    everyday text, whatever 好 was changed to), or the word before it is about time, number or negation.
    /// What cannot be widened stays one character and teaches nothing.
    static func widened(_ h: Hunk, old: [Token], new: [Token], known: Set<String> = [],
                        segment: (String) -> [String] = { wordSegments($0) }) -> Hunk {
        func single(_ t: Token) -> Bool { t.kind == .cjk && t.text.count == 1 }
        guard h.old.count == 1, h.new.count == 1, single(old[h.old.lowerBound]), single(new[h.new.lowerBound]) else { return h }
        let (lo, hi, nlo, nhi) = (h.old.lowerBound, h.old.upperBound, h.new.lowerBound, h.new.upperBound)
        /// The same Han word (no numeral) at these places of the two texts.
        func same(_ i: Int, _ j: Int) -> Bool {
            i >= 0 && j >= 0 && i < old.count && j < new.count && old[i] == new[j] && old[i].kind == .cjk
        }

        if !known.isEmpty {
            var best: (hunk: Hunk, size: Int)?
            for l in 0...3 {
                guard l == 0 || same(lo - l, nlo - l) else { break }
                for r in 0...3 where l + r > 0 {
                    guard r == 0 || same(hi + r - 1, nhi + r - 1) else { break }
                    let candidate = Hunk(old: (lo - l)..<(hi + r), new: (nlo - l)..<(nhi + r))
                    let size = old[candidate.old].reduce(0) { $0 + $1.text.count }
                    guard size <= 4 else { break }
                    if size < (best?.size ?? .max), known.contains(termKey(text(new[candidate.new]))) { best = (candidate, size) }
                }
            }
            if let best { return best.hunk }
        }

        func joinable(_ i: Int, _ j: Int) -> Bool {
            old[i] == new[j] && single(old[i]) && !old[i].fragment && !new[j].fragment
                && !standaloneHan.contains(Character(old[i].text))
        }
        var (a, b, na, nb) = (lo, hi, nlo, nhi)
        while b - a < 4, a > 0, na > 0, joinable(a - 1, na - 1) { a -= 1; na -= 1 }
        while b - a < 4, b < old.count, nb < new.count, joinable(b, nb) { b += 1; nb += 1 }
        if b - a > 1 { return Hunk(old: a..<b, new: na..<nb) }

        if same(lo - 1, nlo - 1), !old[lo - 1].fragment, !new[nlo - 1].fragment {
            let word = old[lo - 1].text
            let everyday = (old[lo].text + new[nlo].text).contains {
                standaloneHan.contains($0) || structuralHan.contains(String($0)) || negatingHan.contains($0)
            }
            if (2...3).contains(word.count), !everyday, !structuralHan.contains(word),
               !structuralHanSubstrings.contains(where: word.contains),
               !word.contains(where: { cjkNumerals.contains($0) || negatingHan.contains($0) }),
               segment(word + old[lo].text).count > 1 {
                return Hunk(old: (lo - 1)..<hi, new: (nlo - 1)..<nhi)
            }
        }
        return h
    }

    /// A single changed Latin word takes the unchanged capitalized words next to it (one space apart,
    /// up to 3 words), so a common word is never stored alone: Open Air → Open AI, not Air → AI.
    static func extended(_ h: Hunk, old: [Token], new: [Token]) -> Hunk {
        guard h.old.count == 1, old[h.old.lowerBound].kind == .latin else { return h }
        func name(_ i: Int, _ j: Int) -> Bool {
            let t = old[i]
            return t == new[j] && t.kind == .latin && t.text.first?.isUppercase == true
                && !structuralWords.contains(t.text.lowercased())
        }
        func gap(_ i: Int, _ j: Int) -> Bool { old[i] == new[j] && old[i].text == " " }
        var (lo, hi, nlo, nhi, words) = (h.old.lowerBound, h.old.upperBound, h.new.lowerBound, h.new.upperBound, 1)
        while words < 3, lo >= 2, nlo >= 2, gap(lo - 1, nlo - 1), name(lo - 2, nlo - 2) { lo -= 2; nlo -= 2; words += 1 }
        while words < 3, hi + 1 < old.count, nhi + 1 < new.count, gap(hi, nhi), name(hi + 1, nhi + 1) {
            hi += 2; nhi += 2; words += 1
        }
        return Hunk(old: lo..<hi, new: nlo..<nhi)
    }

    // MARK: Rules

    static let structuralWords: Set<String> = [
        "a", "an", "the", "i", "me", "my", "we", "us", "our", "you", "your", "he", "him", "his", "she", "her",
        "it", "its", "they", "them", "their", "this", "that", "these", "those", "there", "here",
        "is", "am", "are", "was", "were", "be", "been", "do", "does", "did", "done", "go", "goes", "went",
        "not", "no", "yes", "don't", "can't", "won't", "isn't", "never", "send", "sent", "delete", "keep",
        "buy", "sell", "if", "then", "else", "and", "or", "but", "so", "to", "of", "in", "on", "at", "for",
        "from", "with", "by", "as", "can", "could", "will", "would", "should", "may", "might", "must",
        "have", "has", "had", "what", "when", "where", "who", "why", "how", "all", "any", "some",
        "before", "after", "today", "tomorrow", "yesterday", "please", "ok", "okay",
    ]
    static let structuralHan: Set<String> = [
        "不", "没", "别", "无", "非", "未", "我", "你", "他", "她", "它", "的", "地", "得", "了",
        "吗", "呢", "吧", "和", "与", "或", "在", "是",
        "今天", "明天", "昨天", "后天", "前天", "上周", "下周", "本周", "上午", "下午", "早上", "晚上", "中午",
        "去年", "明年", "今年",
    ]
    /// Characters whose swap flips the meaning (明天→今天, 买入→卖出, 升级→降级, 盈利→亏损); any two in one
    /// group are opposites.
    static let oppositeHan: [Set<Character>] = [
        "上下", "左右", "前后", "早晚", "今明昨", "加降减", "增减", "买卖", "入出", "进出", "涨跌", "男女", "大小",
        "多少", "高低", "开关", "正负", "内外", "收支", "东西南北", "长短",
        "升降", "涨降", "升跌", "盈亏损", "赚赔亏", "肯否", "是否", "好坏", "优劣", "对错", "真假伪", "有无没",
        "已未", "可不", "合非", "退付", "收付", "借还贷", "存取", "启停禁", "始终", "先后", "快慢", "新旧",
        "轻重", "强弱", "冷热", "深浅", "远近", "来去回", "胜负败", "输赢", "攻守防", "黑白", "公私", "主次副",
        "正反", "顺逆", "奇偶", "单双", "阴阳", "生死", "松紧", "宽窄", "厚薄", "软硬", "粗细", "胖瘦",
    ].map { Set($0) }
    static let negatingPrefixes = ["un", "in", "im", "il", "ir", "dis", "non", "mis", "a"]
    static let swappablePrefixes = [
        "", "in", "im", "ex", "de", "up", "down", "pre", "post", "over", "under", "en", "dis", "un", "on", "off",
        "inter", "intra", "sub", "super", "micro", "macro", "max", "min", "pro", "anti",
    ]
    /// Days and months in English: one typed over another is a date changed, like a number (Tuesday →
    /// Thursday, November → December).
    static let calendarWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
        "january", "february", "march", "april", "june", "july", "august", "september", "october", "november",
        "december", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]
    static let structuralHanSubstrings = [
        "不要", "不能", "没有", "不是", "可以", "应该", "需要", "如果", "然后", "但是", "因为", "所以",
        "删除", "保留", "取消", "发送", "告诉", "购买", "我们", "你们", "他们",
    ]
    /// Characters that turn a phrase into its negation (不同意 → 同意).
    static let negatingHan = Set("不没别无非未勿")

    /// Why one changed stretch is not a term fix.
    enum Skip: Hashable {
        case onesided, format, caseOnly, sensitive, number, long, structural, opposite, everyday, sound, pinyin
    }

    enum Verdict: Equatable {
        case pair, termOnly
        /// Only the word, and only once it was seen in a second dictation (`TermFix.tentative`).
        case tentative
        case no(Skip)
    }

    /// Judges one change where it stands. `h` is the hunk as learned (maybe widened), `core` the changed
    /// tokens alone, `alone` the misheard side segmented on its own. What the text around the change says is
    /// checked here; everything that depends on the two sides alone is `verdict`, which the hub's check of a
    /// bare pair (`strength(of:)`) shares.
    /// `phraseKnown`: with the unchanged capitalized words next to it (`extended`), the corrected side is one
    /// of the user's own dictionary words.
    static func judge(_ h: Hunk, core: Hunk, old: [Token], new: [Token], alone: [Token], known: Set<String>,
                      phraseKnown: Bool = false) -> Verdict {
        let wrongTokens = Array(old[h.old]), rightTokens = Array(new[h.new])
        let wrong = text(old[h.old]), right = text(new[h.new])
        // R1 pure insertion or deletion
        guard !wrong.isEmpty, !right.isEmpty else { return .no(.onesided) }
        // R2 punctuation or spacing only
        guard formatKey(wrong) != formatKey(right) else { return .no(.format) }
        if sensitiveContext(h.old, in: old) || sensitiveContext(h.new, in: new) { return .no(.sensitive) }
        // R4 next to a number. One right before the change blocks it (100 金币); one right after only blocks
        // a change whose result is not a Latin name, so a product before its model number is still learned
        // (Iphone 15, 欧泼斯 5 → Opus 5).
        if numberBefore(h.old, in: old) || numberBefore(h.new, in: new) { return .no(.number) }
        let latinResult = rightTokens.allSatisfy { $0.kind == .latin || $0.kind == .space }
        if !latinResult, numberAfter(h.old, in: old) || numberAfter(h.new, in: new) { return .no(.number) }
        return verdict(wrong: wrong, right: right, wrongTokens: wrongTokens, rightTokens: rightTokens,
                       coreWrong: Array(old[core.old]), coreRight: Array(new[core.new]), wrongAlone: alone,
                       inSentence: true, known: known, place: place(of: h.new, in: new), phraseKnown: phraseKnown)
    }

    /// The rules that need only the two sides of a change. `known`: the user's own dictionary words as
    /// `termKey`s. `wrongAlone`: the misheard side segmented on its own, which is all a bare pair has (the
    /// segmenter cuts the same characters differently inside a sentence: 斯|威|夫|特 there, 斯威夫特 alone).
    /// `inSentence`: `coreWrong` is how the sentence was segmented; false for a pair that arrives without its
    /// text. `place`: where the change stands, for what a capital says. `phraseKnown`: see `judge`.
    static func verdict(wrong: String, right: String, wrongTokens: [Token], rightTokens: [Token],
                        coreWrong: [Token], coreRight: [Token], wrongAlone: [Token], inSentence: Bool,
                        known: Set<String>, place: Place, phraseKnown: Bool = false) -> Verdict {
        guard !wrong.isEmpty, !right.isEmpty, wrong != right else { return .no(.onesided) }
        guard formatKey(wrong) != formatKey(right) else { return .no(.format) }
        if isSensitive(wrong) || isSensitive(right) { return .no(.sensitive) }
        // The words that changed, without what is the same at both ends (Cloud → Claude in Cloud Code →
        // Claude Code): a bare pair is judged by them as a change in its sentence is.
        let (changedWrong, changedRight) = changed(coreWrong, coreRight)
        /// The corrected word itself is one of the user's own words, or the dictionary has it only inside a
        /// longer term that the unchanged words around it complete (Claude Code, VS Code, Air France): then
        /// those words say which thing is meant.
        let wordKnown = !changedRight.isEmpty && known.contains(termKey(text(changedRight[...])))
        let wholeKnown = known.contains(termKey(right)) || phraseKnown
        let rightKnown = wordKnown || wholeKnown
        let inPhrase = wholeKnown && !wordKnown
        let latinResult = rightTokens.contains { $0.kind == .latin }
            && rightTokens.allSatisfy { $0.kind == .latin || $0.kind == .space }
        /// A name or a term in Latin letters: capitalized somewhere, or in the dictionary.
        let nameResult = latinResult && (rightKnown || right.contains(where: \.isUppercase))
        /// Only the corrected word is learned, never the mapping (`TermFix.termOnly`); and that only once
        /// the same edit was seen in a second dictation (`TermFix.tentative`).
        var termOnly = false, tentative = false

        // R3 case only: inner capitals (iPhone, GitHub) are learned as they are, and so is a dictionary word
        // (用 claude 写 → Claude), except where the capital is only how a sentence, a line or a list item
        // starts. A plain capital on any other word says nothing there or inside English text; in the middle
        // of a Chinese clause it may name a word (用 cursor 写 → Cursor) or be style (这个 bug → Bug): only
        // the word is learned, never the mapping (the lowercase spelling is an everyday word elsewhere), and
        // only once the same capital was given in a second dictation.
        if wrong.lowercased() == right.lowercased() {
            let inner = right.dropFirst().contains(where: \.isUppercase)
            let sentenceCase = wrong.first?.isLowercase == true && right.first?.isUppercase == true
                && wrong.dropFirst() == right.dropFirst()
            if rightKnown {
                if !inner, sentenceCase, place == .start { return .no(.caseOnly) }
            } else if !inner {
                let plain = place == .afterHan && latinResult && rightTokens.count == 1 && sentenceCase
                    && right.filter(\.isLetter).count >= 3 && !structuralWords.contains(right.lowercased())
                guard plain else { return .no(.caseOnly) }
                termOnly = true
                tentative = true
            }
        }
        let caseOnly = wrong.lowercased() == right.lowercased()

        // Separate words only joined into one term (I phone → iPhone, one drive → OneDrive): the letters stay.
        let joined = wrongTokens.filter { $0.kind == .latin || $0.kind == .number }.count > 1
            && wrong.filter { !$0.isWhitespace }.lowercased() == right.lowercased()
            && right.dropFirst().contains(where: \.isUppercase)

        // R4 numbers, amounts and dates: never. Digits and currency; a number or a day or month by name on
        // either side (三百 → 三千, fifteen → fifty, GPT four → GPT-4, Tuesday → Thursday); a Chinese numeral
        // that comes, goes or changes, also inside a word (周五 → 周日, 十一月 → 十月, 三个月 → 上个月, 一定 →
        // 必定): every 周五 said later would be at risk. Only a Latin name typed over Han that happened to
        // hold a numeral (三星 → Samsung) still teaches something, the name alone.
        if hasDigits(wrong) || hasDigits(right) { return .no(.number) }
        if (wrongTokens + rightTokens).contains(where: { $0.kind == .latin && calendarWords.contains($0.text.lowercased()) }) {
            return .no(.number)
        }
        if rightTokens.contains(where: { $0.kind == .number }) { return .no(.number) }
        if !joined {
            if isPureNumber(wrong) { return .no(.number) }
            // A spelled-out number among the misheard words only towards a dictionary word.
            if !rightKnown, wrongTokens.contains(where: { $0.kind == .number && !$0.text.allSatisfy(isHan) }) {
                return .no(.number)
            }
        }
        if changesNumerals(wrong, right) || wrongTokens.contains(where: { $0.kind == .number && $0.text.allSatisfy(isHan) }) {
            guard nameResult, !right.contains(where: isHan) else { return .no(.number) }
            termOnly = true
        }

        // R5 length. The misheard side may be the syllables of a foreign name written in Han (科德克斯), which the
        // segmenter cuts into characters, so it is measured in characters, not words.
        for (side, tokens) in [(wrong, wrongTokens), (right, rightTokens)] {
            if side.count > 24 || tokens.filter({ $0.kind == .latin }).count > 3 || side.filter(isHan).count > 8 { return .no(.long) }
        }
        guard right.count >= 2 else { return .no(.everyday) }
        // One Han character alone is never the misheard side (先 → 西安, 天 → 提案): it is part of countless
        // words, and every one of them would be rewritten or put before the model with the pair.
        if !wrong.contains(where: isLatinAlnum), wrong.filter(isHan).count < 2 { return .no(.everyday) }
        let coreHan = coreWrong.reduce(0) { $0 + $1.text.filter(isHan).count }
        guard coreHan <= (nameResult ? 6 : 4) else { return .no(.long) }

        // Han heard for a Latin name. Three or more lone characters are its syllables (科|德|克|斯), which
        // nobody writes on purpose: a mapping. A word the segmenter knows (你好, 立刻, 特斯拉), one or two
        // characters that are words of their own (你|有), or a run with a pronoun, a negation or a particle in
        // it, or with more than one one-character word (他|不|来, 你|要|死, 吃|个|饭, 去|买|菜), is everyday text:
        // only the name is learned, or every 吃个饭 said later would become the name. One such character twice
        // is still a name spelled out (爱|皮|爱). Where the segmenter joined some of the syllables but not all
        // (克|劳德), they are syllables too when none of them is a word of its own, and the name must then
        // sound closer (`shortNameDistance`). Whether characters stand alone is read from the sentence. A pair
        // that arrives without it (the hub's check) cannot see that: three or more characters are taken as
        // the device took them, or the hub would keep only the word of a mapping this Mac learned
        // (斯威夫特 → Swift); two characters must stand alone by either reading.
        func hanTokens(_ tokens: [Token]) -> [Token] {
            tokens.filter { ($0.kind == .cjk || $0.kind == .number) && $0.text.allSatisfy(isHan) }
        }
        let han = hanTokens(coreWrong)
        let hanForName = nameResult && !han.isEmpty && !wrong.contains(where: isLatinAlnum)
        var syllables = false, partlyJoined = false
        if hanForName {
            let characters = han.flatMap { Array($0.text) }
            guard characters.count >= 2 else { return .no(.everyday) }
            let alone = hanTokens(wrongAlone).allSatisfy { $0.text.count == 1 }
            let singles = han.allSatisfy { $0.text.count == 1 }
            let lone = (!inSentence || singles) && (characters.count >= 3 || alone)
            let functional = characters.contains { structuralHan.contains(String($0)) || negatingHan.contains($0) }
            let everyday = characters.filter { standaloneHan.contains($0) || structuralHan.contains(String($0)) }
            syllables = lone && characters.count >= 3 && !functional && Set(everyday).count <= 1
                && everyday.count < characters.count
            partlyJoined = inSentence && !singles && han.count >= 2 && characters.count >= 3 && !functional && everyday.isEmpty
            if partlyJoined { syllables = true }
            if !(lone || partlyJoined) || (!syllables && (functional || !everyday.isEmpty)) { termOnly = true }
        }

        // R6 structural words: negation, pronouns, particles, actions, time. In the result they are never
        // learned. In the misheard text they make it unsafe to map: then only a name is learned, as a word.
        var loose = false
        if !joined {
            for t in coreRight {
                if t.kind == .latin, structuralWords.contains(t.text.lowercased()) { return .no(.structural) }
                if t.kind == .cjk, structuralHan.contains(t.text) { return .no(.structural) }
            }
            for t in coreWrong {
                if t.kind == .latin, structuralWords.contains(t.text.lowercased()) { loose = true }
                if t.kind == .cjk, structuralHan.contains(t.text) { loose = true }
            }
        }
        if structuralHanSubstrings.contains(where: right.contains) { return .no(.structural) }
        if structuralHanSubstrings.contains(where: wrong.contains) { loose = true }

        // R6b opposites and negations: 明天→今天, 买入→卖出, 升级→降级, 不同意→同意, likely→unlikely,
        // import→export. A negating character that comes or goes with the change is one too, whatever it
        // stands in for (有效→无效, 合法→非法, 已婚→未婚, 可行→不行, 不行→步行): the same sound does not make
        // 不行 safe to rewrite. Only a Latin name typed over such words still teaches something, the name.
        if swapsOpposites(wrong, right) { return .no(.opposite) }
        if changesNegation(wrong, right) {
            guard nameResult, !right.contains(where: isHan) else { return .no(.opposite) }
            termOnly = true
        }
        func word(_ tokens: [Token]) -> Bool {
            tokens.count == 1 && (tokens[0].kind == .latin || tokens[0].kind == .number) && tokens[0].text.allSatisfy(\.isASCII)
        }
        // The typed-over word is itself one of the user's own dictionary words (Typeless → neoless, Sarah →
        // Sara, 王伟 → 王磊 with both in the dictionary, 音币 → 硬币): they have that word and said the other.
        // Never a fix, whatever it is changed to.
        if !caseOnly, !joined {
            let over = text(changedWrong[...])
            if known.contains(termKey(wrong)) || (!over.isEmpty && known.contains(termKey(over))) { return .no(.sound) }
        }
        // R6c one word in Latin letters typed over another. Opposites never (likely → unlikely, Enable →
        // Disable). Everyday words swapped for each other (bug → bag, accept → except) depend on context.
        // Anything else is a fix only when it is the same word spelled out (Martn → Martin: a letter put in
        // or left out, none changed); another word or another name (Eric → Erin, GitHub → GitLab, CPU → GPU)
        // is the user changing what they said. Towards a word of the user's own dictionary it is taken
        // (Cloud → Claude), as a hint for the model only (`replacesBlindly`). Not when what was typed over
        // was written on purpose, with all capitals or a capital inside (CPU → GPU, JSON → BSON, GitHub →
        // GitLab: another thing, whichever is in the dictionary), unless the dictionary has the corrected
        // word inside a longer term that the words around it complete (BS Code → VS Code). And a person's
        // name typed over is another person (Jason → Martin, Eric → Erica, Chris → Christine), unless it is
        // the same name spelled the way the user's dictionary has it (Sara → Sarah).
        if word(changedWrong), word(changedRight) {
            let (w, r) = (changedWrong[0].text, changedRight[0].text)
            if isPolarityFlip(w, r) { return .no(.opposite) }
            if w.lowercased() != r.lowercased() {
                if !rightKnown, [w, r].allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isLowercase } }) { return .no(.everyday) }
                let variant = isSpellingVariant(w, r)
                if isPersonName(w) {
                    guard variant, rightKnown else { return .no(.sound) }
                } else if !variant {
                    let onPurpose = w.dropFirst().contains(where: \.isUppercase)
                    guard rightKnown, !onPurpose || inPhrase else { return .no(.sound) }
                }
            }
        }
        // The same for several words typed over as many others (Tim Cook → Tom Brook): each must be the word
        // it replaced, spelled out, or the whole must be one of the user's own words; a person's name among
        // them is another person either way, unless it is only spelled differently.
        let wrongWords = changedWrong.filter { $0.kind != .space }, rightWords = changedRight.filter { $0.kind != .space }
        if wrongWords.count > 1, wrongWords.count == rightWords.count,
           (wrongWords + rightWords).allSatisfy({ $0.kind == .latin }) {
            for (w, r) in zip(wrongWords, rightWords) where w.text.lowercased() != r.text.lowercased() {
                let variant = isSpellingVariant(w.text, r.text)
                if isPersonName(w.text) ? !(variant && rightKnown) : !(variant || rightKnown) { return .no(.sound) }
            }
        }

        // R7 must sound alike. Two Chinese words must sound the same (张伟 → 章伟, 权利 → 权力, 以经 → 已经;
        // z/zh, c/ch, s/sh and -n/-ng count as the same): words that only sound close are as often another
        // word the user meant (广州 → 杭州, 小李 → 小林, 方法 → 办法, 报告 → 报道). Those are learned only
        // towards a word of the user's own dictionary, and then every changed syllable must be close
        // (金币 → 音币; not 日元 → 美元, which one shared character would let through).
        let mixed = nameResult && wrong.contains(where: isHan)
        let limit = mixed ? namePhoneticDistance : (rightKnown ? knownPhoneticDistance : maxPhoneticDistance)
        let distance = mixed ? min(phoneticDistance(wrong, right), spokenDistance(wrong, right)) : phoneticDistance(wrong, right)
        let hanOnly = !(wrong + right).contains(where: isLatinAlnum) && wrong.contains(where: isHan) && right.contains(where: isHan)
        if hanOnly {
            guard sameSound(wrong, right) || (rightKnown && closeSound(wrong, right)) else { return .no(.sound) }
        } else {
            guard distance <= limit else { return .no(.sound) }
        }
        // Too little to map on: two characters are as likely a word the segmenter does not know (谷歌) as a
        // name misheard, unless they sound just like it (拉玛 → Llama); a short name only roughly like what
        // was heard.
        if hanForName, !rightKnown {
            let short = max(phoneticKey(wrong).count, phoneticKey(right).count) < 6
            let few = han.reduce(0, { $0 + $1.text.count }) <= 2
            if (few && distance > twoCharacterNameDistance) || (short && distance > shortNameDistance) { termOnly = true }
        }
        if partlyJoined, distance > shortNameDistance { termOnly = true }
        // R8 uncommitted pinyin such as `yin币`, `yinbi`, `yin'bi` or `YINBI`, on either side: typed and not
        // chosen yet, or left in the text the fix was made over (`yin币` → 硬币).
        if !rightKnown, isLeftoverPinyin(wrong, right) { return .no(.pinyin) }
        if isPinyinDebris(wrong, right) { return .no(.pinyin) }

        if termOnly { return tentative ? .tentative : .termOnly }
        guard loose else { return .pair }
        return nameResult ? .termOnly : .no(.structural)
    }

    /// `a` and `b` without the tokens they share at the front and at the back.
    static func changed(_ a: [Token], _ b: [Token]) -> ([Token], [Token]) {
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        func trimmed(_ tokens: ArraySlice<Token>) -> [Token] {
            Array(tokens.drop { $0.kind == .space }.reversed().drop { $0.kind == .space }.reversed())
        }
        return (trimmed(a[p..<(a.count - s)]), trimmed(b[p..<(b.count - s)]))
    }

    /// A Chinese numeral comes, goes or changes between the two sides.
    static func changesNumerals(_ wrong: String, _ right: String) -> Bool {
        wrong.filter(cjkNumerals.contains).sorted() != right.filter(cjkNumerals.contains).sorted()
    }

    /// A negating character comes or goes between the two sides (also when it stands in for another character).
    static func changesNegation(_ wrong: String, _ right: String) -> Bool {
        let removed = Set(wrong).subtracting(right), added = Set(right).subtracting(wrong)
        return !removed.union(added).isDisjoint(with: negatingHan)
    }

    /// A character is replaced by its opposite (`oppositeHan`).
    static func swapsOpposites(_ wrong: String, _ right: String) -> Bool {
        let removed = Set(wrong).subtracting(right), added = Set(right).subtracting(wrong)
        return oppositeHan.contains { !$0.isDisjoint(with: removed) && !$0.isDisjoint(with: added) }
    }

    /// One spelling is the other with a letter put in or left out and none changed, whatever the capitals
    /// (Martn → Martin, Annna → Anna, Jon → John): the same word spelled out, not another word. One letter,
    /// two in a long word: more is another word that happens to hold the same letters (Apple → App,
    /// Chris → Christine).
    static func isSpellingVariant(_ a: String, _ b: String) -> Bool {
        let x = Array(a.lowercased().filter(isLatinAlnum)), y = Array(b.lowercased().filter(isLatinAlnum))
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        guard short.count >= 2, long.count - short.count <= (short.count >= 8 ? 2 : 1) else { return false }
        var i = 0
        for c in long where i < short.count && c == short[i] { i += 1 }
        return i == short.count
    }

    /// Whether `word` is written as a person's name (a capital first) and is a common given name: Jason, Alice,
    /// Dustin. Not a misspelling or an everyday word (Martn, Cloud, Labels). A fixed list, so this Mac and the
    /// hub always agree; a name that is not on it is judged like any other word.
    static func isPersonName(_ word: String) -> Bool {
        word.first?.isUppercase == true && givenNames.contains(word.lowercased())
    }

    /// Common given names in English, lowercase.
    static let givenNames: Set<String> = [
        "james", "john", "robert", "michael", "william", "david", "richard", "joseph", "thomas", "charles",
        "christopher", "daniel", "matthew", "anthony", "donald", "steven", "paul", "andrew", "joshua", "kenneth",
        "kevin", "brian", "george", "timothy", "ronald", "edward", "jason", "jeffrey", "ryan", "jacob", "gary",
        "nicholas", "eric", "jonathan", "stephen", "larry", "justin", "scott", "brandon", "benjamin", "samuel",
        "gregory", "alexander", "patrick", "raymond", "jack", "dennis", "jerry", "tyler", "aaron", "adam", "nathan",
        "henry", "douglas", "zachary", "peter", "kyle", "ethan", "walter", "noah", "jeremy", "keith", "roger", "terry",
        "gerald", "harold", "sean", "austin", "carl", "arthur", "lawrence", "dylan", "jesse", "bryan", "billy", "joe",
        "bruce", "gabriel", "logan", "albert", "alan", "juan", "wayne", "elijah", "randy", "roy", "vincent", "ralph",
        "eugene", "russell", "bobby", "philip", "louis", "liam", "oliver", "lucas", "leo", "tom", "tim",
        "jim", "bob", "mike", "dave", "steve", "chris", "matt", "dan", "ben", "sam", "tony", "andy", "alex", "luke",
        "simon", "martin", "victor", "oscar", "felix", "hugo", "ivan", "dustin", "derek", "shawn", "travis", "marcus",
        "colin", "ian", "neil", "craig", "glenn", "todd", "chad", "brad", "greg", "jon", "josh", "jake", "evan",
        "owen", "caleb", "isaac", "connor", "aiden", "jayden", "carter", "wyatt", "julian", "adrian", "damian",
        "mary", "patricia", "jennifer", "linda", "elizabeth", "barbara", "susan", "jessica", "sarah", "karen", "lisa",
        "nancy", "betty", "margaret", "sandra", "ashley", "kimberly", "emily", "donna", "michelle", "carol", "amanda",
        "dorothy", "melissa", "deborah", "stephanie", "rebecca", "sharon", "laura", "cynthia", "kathleen", "amy",
        "angela", "shirley", "anna", "brenda", "pamela", "emma", "nicole", "helen", "samantha", "katherine",
        "christine", "debra", "rachel", "carolyn", "janet", "catherine", "maria", "heather", "diane", "ruth", "julie",
        "olivia", "joyce", "virginia", "victoria", "kelly", "lauren", "christina", "joan", "evelyn", "judith", "megan",
        "andrea", "cheryl", "hannah", "jacqueline", "martha", "gloria", "teresa", "ann", "sara", "madison", "frances",
        "kathryn", "janice", "jean", "abigail", "alice", "julia", "judy", "sophia", "denise", "doris", "marilyn",
        "danielle", "beverly", "isabella", "theresa", "diana", "natalie", "brittany", "charlotte", "marie", "kayla",
        "alexis", "lori", "erin", "tina", "sofia", "mia", "ava", "chloe", "zoe", "lily", "ella", "lucy", "nina", "eva",
        "claire", "kate", "jane", "erica", "monica", "tiffany", "vanessa", "wendy", "cindy", "tracy", "stacy", "holly",
        "molly", "jenny", "annie", "sophie", "ellie", "justine", "jasmine", "leah", "naomi", "elena", "irene",
    ]

    /// How a learned fix may be used.
    public enum Strength: Equatable, Sendable {
        /// A wrong → right mapping.
        case pair
        /// Only the word (`TermFix.termOnly`).
        case termOnly
    }

    /// What `pair`, arriving without its text (corrections a device saw elsewhere, `POST
    /// /v1/learning/observations`), may be learned as: nil for anything `extract` would never learn, whatever
    /// stood around it (a secret, a number or amount, a negation or opposite, a structural word, a long phrase,
    /// two things that do not sound alike). The same rules as `extract`, without the ones that need the text
    /// around a change, and in this direction only: the reverse of a learned pair, sent to count it down, is
    /// the hub's to recognise (it has the pair), not something to learn. `knownTerms`: the user's own
    /// dictionary words, never the ones learning put there.
    public func strength(of pair: CorrectionPair, knownTerms: Set<String> = []) -> Strength? {
        let wrong = pair.wrong.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = pair.right.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = tokenize(wrong), b = tokenize(right)
        switch Self.verdict(wrong: wrong, right: right, wrongTokens: a, rightTokens: b, coreWrong: a, coreRight: b,
                            wrongAlone: a, inSentence: false, known: Set(knownTerms.map(Self.termKey)), place: .unknown) {
        case .pair: return .pair
        case .termOnly: return .termOnly
        case .tentative, .no: return nil
        }
    }

    /// Whether `pair`, arriving without its text, may be learned as a wrong → right mapping (`strength(of:)`).
    public func isTermFix(_ pair: CorrectionPair, knownTerms: Set<String> = []) -> Bool {
        strength(of: pair, knownTerms: knownTerms) == .pair
    }

    // MARK: A swap made twice

    /// The reasons a replaced stretch was refused that say no more than "this does not sound like what it
    /// replaced" or "these are two everyday words": the only ones a swap made twice may still be learned
    /// after. A number, a negation, an opposite, a structural word, a secret, a long phrase or leftover
    /// pinyin is refused for good.
    static let repeatSkips: Set<Skip> = [.sound, .everyday]

    /// Whether `pair` may be learned as a swap the user made twice (`LearningBook.candidates`, kind
    /// `repeated`): one word or short phrase typed over another that does not sound like it, so by the
    /// rules no recognition error, and still nothing a rule forbids. Such a pair is only ever a hint for
    /// the model, never written into text without it.
    ///
    /// Something must speak for a slip of the recognizer (`resembles`): the two words share a character
    /// where it stands (米线 → 曲线, 报告 → 报道), every syllable sounds close (机会 → 计划), or most of the
    /// letters are the same (Cloud → Claude). Two words with nothing in common (函数 → 脚本, 上海 → 深圳,
    /// approve → reject) are the user saying something else: made twice, that is still no evidence of what
    /// they will mean the third time.
    ///
    /// And what stays refused, however alike the two are and however often the swap is made:
    /// - a numeral or a digit on either side, an amount, a quantity (半, 倍, 全价 → 半价), a date, a weekday,
    ///   a month, a time of day, a week, month or year by where it lies (本月, 下周, 年底), a holiday, one
    ///   length of time for another (日报 → 周报), in English too (morning, weekly, spring);
    /// - a negating character or word on either side, a character of refusal or failure that comes or goes
    ///   (有效 → 失效, 合法 → 违法), an opposite (买 / 卖, 虚 / 实, 同意 / 拒绝, 开始 / 结束, open / close,
    ///   enable / disable), one of a set for another (one currency, colour or season for another);
    /// - one person for another (王伟 → 王磊, 张总 → 李总, 小王 → 小李, 妈妈 → 爸爸, Eric → Erin; the same name
    ///   spelled out is none: Jon → John), one place for another (广州 → 杭州, 德国 → 法国, Boston →
    ///   Chicago): nobody mishears those twice, they are what changed;
    /// - pronouns, particles and the other structural words, on either side;
    /// - anything that reads as a secret or an address;
    /// - what the input method left behind (yin币, lowercase letters over Han);
    /// - one acronym typed over another (CPU → GPU, JSON → BSON): written on purpose, another thing;
    /// - an everyday word typed over with a name in Latin letters (苹果 → Apple, 你好 → Nio), or a name
    ///   translated into Chinese: only characters that make no word may stand for a name (派森 → Python);
    /// - a word of the user's own dictionary as the typed-over side: they have that word and said the other;
    /// - a word with something added to it or taken off it (部署 → 部署包): that is no swap;
    /// - a single character, more than six Han characters or three Latin words on a side, punctuation inside.
    /// The lists of opposites, names and sets cannot be complete, which is why they are not relied on
    /// alone: what they miss must still resemble what it replaced, is learned only from the same swap made
    /// in two dictations, is shown, and is put before the model only for a sentence in which the typed-over
    /// word makes no sense (`PolishPrompt.repeatedLine`).
    /// `knownTerms`: the user's own dictionary words, never the ones learning put there.
    public func isRepeatable(_ pair: CorrectionPair, knownTerms: Set<String> = []) -> Bool {
        repeatable(wrong: pair.wrong, right: pair.right, known: Set(knownTerms.map(Self.termKey)))
    }

    /// Whether ChatGPT may be asked if `pair` was misheard, and what it judges misheard learned
    /// (`LearnedCorrection.Kind.judged`): everything `isRepeatable` refuses for good stays refused (numbers,
    /// dates, negation, opposites, one person or place for another, secrets, structural words, the user's
    /// own dictionary word typed over, leftover pinyin…). Let through are only the two things the rules
    /// cannot decide from the words alone: that the two do not sound alike (`resembles`), and a name in
    /// Latin letters typed over Chinese words (克劳德 → Claude, 萝卜 → Notion). What the recognizer heard
    /// is what decides those, and only ChatGPT is shown it.
    public func isJudgeable(_ pair: CorrectionPair, knownTerms: Set<String> = []) -> Bool {
        repeatable(wrong: pair.wrong, right: pair.right, known: Set(knownTerms.map(Self.termKey)), judging: true)
    }

    /// `isRepeatable`, with the dictionary as `termKey`s; `isJudgeable` when `judging`.
    func repeatable(wrong rawWrong: String, right rawRight: String, known: Set<String>, judging: Bool = false) -> Bool {
        let wrong = rawWrong.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rawRight.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wrong.isEmpty, !right.isEmpty, !(wrong + right).contains(where: \.isNewline) else { return false }
        // The same letters with other capitals, spacing or punctuation is formatting, not another word; a
        // word with something added or taken off is no swap either.
        let plainWrong = Self.formatKey(wrong).lowercased().filter { !$0.isWhitespace }
        let plainRight = Self.formatKey(right).lowercased().filter { !$0.isWhitespace }
        guard !plainWrong.isEmpty, !plainRight.isEmpty, !plainWrong.contains(plainRight), !plainRight.contains(plainWrong) else {
            return false
        }
        if Self.isSensitive(wrong) || Self.isSensitive(right) { return false }
        let a = tokenize(wrong), b = tokenize(right)
        /// Either side holds one of `words`.
        func either(_ words: [String]) -> Bool { words.contains { wrong.contains($0) || right.contains($0) } }

        // A word or a short phrase on each side, of letters and Han only. A numeral that is a word of its
        // own is a `.number` token and ends it here, like punctuation.
        for (side, tokens) in [(wrong, a), (right, b)] {
            guard tokens.allSatisfy({ $0.kind == .latin || $0.kind == .cjk || $0.kind == .space }) else { return false }
            guard side.count <= 24, side.filter(Self.isHan).count <= 6, tokens.filter({ $0.kind == .latin }).count <= 3,
                  side.filter({ Self.isHan($0) || Self.isLatinAlnum($0) }).count >= 2 else { return false }
        }
        // Numbers, amounts and dates, also inside a word (一起, 周五, 三星).
        let both = wrong + right
        if Self.hasDigits(both) || both.contains(where: Self.cjkNumerals.contains) { return false }
        if either(Self.timeWords) || Self.namesTime(wrong) || Self.namesTime(right) { return false }
        // The characters that went and those that came.
        let changedHan = Set(wrong).symmetricDifference(Set(right))
        if !changedHan.isDisjoint(with: Self.quantityHan) { return false }
        // Negation, refusal and failure, opposites, one of a set for another.
        if both.contains(where: Self.negatingHan.contains) { return false }
        if !changedHan.isDisjoint(with: Self.refusingHan) { return false }
        if Self.swapsOpposites(wrong, right) || Self.swaps(Self.repeatOpposites, wrong, right) { return false }
        if Self.swapsWords(Self.antonyms, wrong.lowercased(), right.lowercased()) { return false }
        if Self.exclusiveSets.contains(where: { set in
            set.contains(where: wrong.contains) && set.contains(where: { right.contains($0) && !wrong.contains($0) })
        }) { return false }
        // Structural words, and the words for a time in English.
        if either(Self.structuralHanSubstrings) { return false }
        for t in a + b {
            let word = t.text.lowercased()
            if t.kind == .latin, Self.structuralWords.contains(word) || Self.calendarWords.contains(word)
                || Self.timeWordsLatin.contains(word) || word.hasSuffix("n't") { return false }
            if t.kind == .cjk, Self.structuralHan.contains(t.text) { return false }
        }
        let wrongWords = a.filter { $0.kind != .space }, rightWords = b.filter { $0.kind != .space }
        if wrongWords.count == 1, rightWords.count == 1, wrongWords[0].kind == .latin, rightWords[0].kind == .latin,
           Self.isPolarityFlip(wrongWords[0].text, rightWords[0].text) { return false }
        // One of a set of words in Latin letters for another (dollars → euros, Boston → Chicago).
        let wrongLatin = Set(wrongWords.filter { $0.kind == .latin }.map { $0.text.lowercased() })
        let rightLatin = Set(rightWords.filter { $0.kind == .latin }.map { $0.text.lowercased() })
        if Self.exclusiveWords.contains(where: { set in
            !set.isDisjoint(with: wrongLatin) && !set.intersection(rightLatin).isSubset(of: wrongLatin)
        }) { return false }
        // Everyday talk in single characters (很|好, 去|买) is rewording, not a word.
        for words in [wrongWords, rightWords] where words.count > 1 {
            if words.allSatisfy({ $0.kind == .cjk && $0.text.count == 1 && Self.standaloneHan.contains(Character($0.text)) }) {
                return false
            }
        }

        // One person for another, one place for another: what changed, not what was misheard.
        for name in wrongWords where name.kind == .latin && Self.isPersonName(name.text) && !rightLatin.contains(name.text.lowercased()) {
            // The same name spelled out is still that person (Jon → John).
            guard rightWords.contains(where: { $0.kind == .latin && Self.isSpellingVariant(name.text, $0.text) }) else { return false }
        }
        if isPersonLike(wrong), isPersonLike(right) { return false }
        if let last = wrong.last, last == right.last, Self.placeEndings.contains(last) { return false }

        // The typed-over word is the user's own: they have it, and said the other.
        if known.contains(Self.termKey(wrong)) { return false }
        let over = Self.text(Self.changed(a, b).0[...])
        if !over.isEmpty, known.contains(Self.termKey(over)) { return false }

        // Which writing stands for which.
        let hanWrong = wrong.contains(where: Self.isHan), latinWrong = wrong.contains(where: Self.isLatinAlnum)
        let hanRight = right.contains(where: Self.isHan), latinRight = right.contains(where: Self.isLatinAlnum)
        if (hanWrong && latinWrong) || (hanRight && latinRight) { return false }
        if latinWrong, hanRight { return false }
        if hanWrong, latinRight {
            // Only characters that make no word, heard for a name with a capital: an everyday word typed
            // over with a name (苹果 → Apple) would be put before the model for every 苹果.
            guard Self.isLatinName(right) else { return false }
            if !judging {
                guard wrongWords.count >= 2, wrongWords.allSatisfy({ $0.text.count == 1 }),
                      !wrong.contains(where: { Self.standaloneHan.contains($0) || Self.structuralHan.contains(String($0)) }) else {
                    return false
                }
            }
        }
        if latinWrong, latinRight, wrongWords.count == 1, rightWords.count == 1,
           Self.isAcronym(wrong), Self.isAcronym(right) { return false }

        // What the input method left.
        if !known.contains(Self.termKey(right)), Self.isLeftoverPinyin(wrong, right) { return false }
        if Self.isPinyinDebris(wrong, right) { return false }
        // And something must speak for a slip of the recognizer: the words, or (judging) ChatGPT.
        guard judging || Self.resembles(wrong, right) else { return false }
        // Last, because it costs the most: one person or one place for another, by names no list has (what
        // the system takes both words for).
        if hanWrong, hanRight, let kind = nameKind(wrong), kind == nameKind(right) { return false }
        return true
    }

    /// Whether `wrong` could have been heard or written for `right`, as far as the two words say. Two
    /// Chinese words: at least half of the longer one is the same characters in the same places, counted
    /// from the front or from the back (米线 / 曲线, 报告 / 报道, 代码厂 / 代码仓; never 金币 / 金字塔, and
    /// never words that differ in length by more than a character), or they have as many syllables and each
    /// sounds close to the one it replaced (机会 / 计划). Two words in Latin letters: at most half of the
    /// letters differ (Cloud / Claude, GitHub / GitLab; not Alice / Carol, week / month). Han characters
    /// that make no word, typed over with a name in Latin letters, are let through: `repeatable` has made
    /// sure nobody writes them on purpose.
    static func resembles(_ wrong: String, _ right: String) -> Bool {
        let x = Array(wrong.filter(isHan)), y = Array(right.filter(isHan))
        let latinWrong = wrong.contains(where: isLatinAlnum), latinRight = right.contains(where: isLatinAlnum)
        if !latinWrong, !latinRight {
            guard !x.isEmpty, !y.isEmpty, abs(x.count - y.count) <= 1 else { return false }
            var front = 0, back = 0
            for i in 0..<min(x.count, y.count) {
                if x[i] == y[i] { front += 1 }
                let a: Character = x[x.count - 1 - i], b: Character = y[y.count - 1 - i]
                if a == b { back += 1 }
            }
            if max(front, back) * 2 >= max(x.count, y.count) { return true }
            return x.count == y.count && closeSound(String(x), String(y))
        }
        if latinWrong, latinRight, x.isEmpty, y.isEmpty { return phoneticDistance(wrong, right) <= swapDistance }
        return !x.isEmpty && latinRight && !latinWrong
    }

    /// How different two words in Latin letters may be written and still be one heard for the other.
    static let swapDistance = 0.5

    /// All capitals, two or more: CPU, JSON.
    static func isAcronym(_ s: String) -> Bool {
        let letters = s.filter(\.isLetter)
        return letters.count >= 2 && s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) && letters.allSatisfy(\.isUppercase)
    }

    /// A character of one group goes and another of the same group comes (`swapsOpposites`, for other groups).
    static func swaps(_ groups: [Set<Character>], _ wrong: String, _ right: String) -> Bool {
        let removed = Set(wrong).subtracting(right), added = Set(right).subtracting(wrong)
        return groups.contains { !$0.isDisjoint(with: removed) && !$0.isDisjoint(with: added) }
    }

    /// One side holds a word of a pair and the other side holds its counterpart (both lowercased). A Latin
    /// word counts only as a word of its own (`long` is none in `longer`).
    static func swapsWords(_ pairs: [(String, String)], _ wrong: String, _ right: String) -> Bool {
        func holds(_ text: String, _ word: String) -> Bool {
            guard word.allSatisfy(\.isASCII) else { return text.contains(word) }
            return text.split(whereSeparator: { !isLatinAlnum($0) }).contains { $0 == word }
        }
        return pairs.contains { one, other in
            (holds(wrong, one) && holds(right, other)) || (holds(wrong, other) && holds(right, one))
        }
    }

    /// Words for a day or a part of it, a week, a month, a year, a holiday: a date or a time that changed
    /// is never learned, like a number. (Those written with a numeral are refused for the numeral, and
    /// those said by where they lie, 本月 or 年底, by `namesTime`.)
    static let timeWords = [
        "星期", "礼拜", "周日", "周天", "周末", "今天", "明天", "昨天", "后天", "前天", "今晚", "明晚", "昨晚", "今早", "明早",
        "上周", "下周", "本周", "这周", "上午", "下午", "早上", "晚上", "中午", "凌晨", "傍晚", "半夜", "去年", "明年", "今年",
        "前年", "后年", "月份", "月底", "月初", "年底", "年初", "上个月", "下个月", "这个月", "季度", "上旬", "中旬", "下旬",
        "白天", "夜里", "夜间", "夜晚", "晚间", "早晨", "清晨", "黄昏", "午夜", "午后", "深夜", "通宵", "刚才", "现在", "以后", "以前",
        "春节", "国庆", "元旦", "中秋", "端午", "清明", "除夕", "圣诞", "假期", "寒假", "暑假", "工作日", "节假日", "休息日",
    ]

    /// Characters that say where a time lies (本月, 下周, 当天, 次日), the lengths of time they are said of, and
    /// the parts of one (月底, 年初, 周末).
    static let timePointers = Set("本上下前后去明今昨次当每这那头翌")
    static let timeLengths = Set("日天周月年季晚早午夜旬")
    static let timeParts = Set("底初末中头尾")

    /// Whether `s` holds a week, a month, a year or a day said by where it lies or by its part: 本月, 下月,
    /// 当天, 每周, 月底, 年中. Whichever it is typed over with, it is a date that changed.
    static func namesTime(_ s: String) -> Bool {
        let chars = Array(s)
        guard chars.count >= 2 else { return false }
        for i in 0..<(chars.count - 1) {
            if timePointers.contains(chars[i]), timeLengths.contains(chars[i + 1]) { return true }
            if timeLengths.contains(chars[i]), timeParts.contains(chars[i + 1]) { return true }
        }
        return false
    }

    /// Words for a time in English: a part of the day, a length of time and how often, a season.
    static let timeWordsLatin: Set<String> = [
        "morning", "afternoon", "evening", "night", "tonight", "noon", "midnight", "day", "days", "week", "weeks",
        "month", "months", "year", "years", "hour", "hours", "minute", "minutes", "daily", "weekly", "monthly",
        "yearly", "quarterly", "annual", "annually", "hourly", "nightly", "weekday", "weekdays", "weekend", "weekends",
        "spring", "summer", "autumn", "fall", "winter",
    ]

    /// Characters that make an amount of what they stand in (半价, 翻倍): one that comes or goes with a swap
    /// changes how much, like a numeral.
    static let quantityHan = Set("半倍")

    /// Characters of refusal, failure and loss. One that comes or goes with a swap turns the word around
    /// (有效 → 失效, 合法 → 违法, 接受 → 谢绝, 成功 → 失败), whatever the two words share.
    static let refusingHan = Set("否拒绝失违缺禁免废停错误败跌亏赔")

    /// More characters whose swap flips the meaning, for what is learned from a swap made twice: the two
    /// sides of a pair (虚线 → 实线, 需求 → 供给, 明处 → 暗处), and one of a set for another (红 → 绿, 春 → 秋,
    /// 日报 → 周报, 全价 → 半价, 爸 → 妈). `oppositeHan` is left
    /// as it is: the rules for sound-alike fixes do not need these, nothing that sounds alike is among them.
    static let repeatOpposites: [Set<Character>] = [
        "供需", "本外", "胀缩", "升贬", "顶底", "进退", "得失", "利弊", "乘除", "首尾末",
        "存贷", "虚实", "明暗", "动静", "贫富", "贵贱", "父母", "夫妻", "兄弟姐妹哥", "师生", "敌友", "甲乙丙",
        "原被", "毛净", "同异", "合分", "聚散", "悲喜", "苦乐", "爱恨", "善恶", "美丑", "赏罚", "褒贬", "扩缩", "起落伏",
        "浮沉", "盛衰", "兴亡", "成败", "荣辱", "安危", "吉凶", "祸福", "难易", "昼夜", "日夜", "古今", "城乡", "天地",
        "春夏秋冬", "红绿蓝黄紫橙灰粉青", "金银铜", "直间", "主被", "热冷", "干湿",
        "日周月年季", "寒暑", "全半满空清", "爸妈爷奶公婆叔姨伯婶舅姑儿女孙", "生死", "优差", "快迟",
    ].map { Set($0) }

    /// Words that are each other's opposite, where no single character says so. Lowercase.
    static let antonyms: [(String, String)] = [
        ("同意", "拒绝"), ("同意", "反对"), ("支持", "反对"), ("赞成", "反对"), ("接受", "拒绝"), ("允许", "禁止"),
        ("通过", "驳回"), ("通过", "拒绝"), ("喜欢", "讨厌"), ("肯定", "否定"), ("正确", "错误"), ("固定", "浮动"),
        ("积极", "消极"), ("乐观", "悲观"), ("简单", "复杂"), ("容易", "困难"), ("便宜", "昂贵"), ("全部", "部分"),
        ("所有", "部分"), ("添加", "移除"), ("显示", "隐藏"), ("在线", "离线"), ("本地", "远程"), ("自动", "手动"),
        ("流入", "流出"), ("盈余", "赤字"), ("扩张", "收缩"), ("宏观", "微观"),
        ("入场", "离场"), ("准时", "晚点"), ("准时", "迟到"), ("提前", "推迟"), ("提前", "延后"), ("按时", "延期"),
        ("开始", "结束"), ("启动", "关闭"), ("继续", "暂停"), ("发布", "撤回"), ("批准", "驳回"), ("安全", "危险"),
        ("参加", "退出"), ("出席", "请假"), ("高兴", "难过"), ("开心", "伤心"), ("相信", "怀疑"), ("熟悉", "陌生"),
        ("定金", "全款"), ("定金", "尾款"), ("首付", "尾款"), ("收入", "支出"), ("收益", "成本"), ("甲方", "乙方"),
        ("阳性", "阴性"), ("良性", "恶性"), ("急性", "慢性"), ("门诊", "住院"), ("饭前", "饭后"), ("内服", "外用"),
        ("及格", "挂科"), ("必修", "选修"), ("入学", "毕业"), ("入职", "离职"), ("录取", "淘汰"), ("表扬", "批评"),
        ("出发", "到达"), ("起飞", "降落"), ("出境", "入境"), ("往返", "单程"), ("国内", "国际"), ("室内", "室外"),
        ("胜诉", "败诉"), ("合法", "违法"), ("有效", "无效"), ("公开", "保密"), ("原告", "被告"), ("房东", "租客"),
        ("上传", "下载"), ("导入", "导出"), ("安装", "卸载"), ("启用", "停用"), ("升级", "降级"), ("加密", "解密"),
        ("压缩", "解压"), ("串联", "并联"), ("正极", "负极"), ("主场", "客场"), ("进攻", "防守"), ("线上", "线下"),
        ("批发", "零售"), ("顺时针", "逆时针"), ("横向", "纵向"), ("奇数", "偶数"), ("升序", "降序"), ("白天", "晚上"),
        ("up", "down"), ("high", "low"), ("higher", "lower"),
        ("open", "close"), ("opened", "closed"), ("on", "off"), ("true", "false"), ("min", "max"),
        ("minimum", "maximum"), ("add", "remove"), ("start", "stop"), ("begin", "end"), ("left", "right"),
        ("top", "bottom"), ("above", "below"), ("over", "under"), ("more", "less"), ("most", "least"), ("win", "lose"),
        ("profit", "loss"), ("gain", "loss"), ("accept", "reject"), ("allow", "deny"), ("allow", "block"),
        ("show", "hide"), ("push", "pull"), ("push", "pop"), ("input", "output"), ("inside", "outside"),
        ("internal", "external"), ("public", "private"), ("positive", "negative"), ("credit", "debit"),
        ("asset", "liability"), ("supply", "demand"), ("deposit", "withdraw"), ("lend", "borrow"), ("raise", "lower"),
        ("rise", "fall"), ("hot", "cold"), ("old", "new"), ("big", "small"), ("large", "small"), ("fast", "slow"),
        ("early", "late"), ("pass", "fail"), ("success", "failure"), ("male", "female"),
        ("same", "different"), ("front", "back"), ("frontend", "backend"),
        ("client", "server"), ("local", "remote"), ("read", "write"), ("get", "set"),
        ("entry", "exit"), ("inflow", "outflow"), ("surplus", "deficit"), ("expansion", "contraction"),
        ("micro", "macro"), ("sync", "async"), ("light", "dark"), ("staging", "production"),
        ("approve", "reject"), ("approve", "deny"), ("approved", "rejected"), ("confirm", "cancel"), ("accept", "decline"),
        ("accept", "refuse"), ("agree", "refuse"), ("safe", "dangerous"), ("correct", "wrong"), ("right", "wrong"),
        ("good", "bad"), ("best", "worst"), ("better", "worse"), ("easy", "hard"), ("easy", "difficult"),
        ("cheap", "expensive"), ("strong", "weak"), ("full", "empty"), ("rich", "poor"), ("login", "logout"),
        ("winner", "loser"), ("buyer", "seller"), ("lender", "borrower"), ("sender", "receiver"), ("friend", "enemy"),
        ("love", "hate"), ("join", "leave"), ("arrive", "leave"), ("arrival", "departure"), ("past", "future"),
        ("present", "absent"), ("income", "expense"), ("revenue", "cost"), ("upper", "lower"),
        ("grow", "shrink"), ("increase", "reduce"), ("lock", "release"), ("merge", "revert"), ("commit", "revert"),
        ("upload", "download"), ("import", "export"), ("install", "uninstall"), ("enable", "disable"),
        ("encrypt", "decrypt"), ("compress", "decompress"), ("include", "exclude"), ("ascending", "descending"),
        ("horizontal", "vertical"), ("odd", "even"), ("benign", "malignant"), ("acute", "chronic"),
        ("inpatient", "outpatient"), ("inbound", "outbound"), ("domestic", "international"), ("indoor", "outdoor"),
        ("online", "offline"), ("plaintiff", "defendant"), ("guilty", "innocent"), ("legal", "illegal"),
        ("valid", "invalid"), ("offense", "defense"), ("home", "away"), ("north", "south"), ("east", "west"),
        ("wholesale", "retail"), ("landlord", "tenant"), ("employer", "employee"), ("junior", "senior"),
        ("before", "after"), ("always", "never"), ("day", "night"), ("summer", "winter"),
    ]

    /// Words of which one typed over another changes what is meant, like a number: one currency or
    /// unit of time for another, one relative for another, one place for another. (A place the lists do not
    /// have is refused by its ending, `placeEndings`, when both have the same.)
    static let exclusiveSets: [[String]] = [
        ["人民币", "美元", "美金", "美刀", "欧元", "英镑", "日元", "韩元", "港币", "港元", "台币", "新币", "澳元", "澳币",
         "纽币", "加元", "法郎", "瑞郎", "卢布", "卢比", "泰铢", "比索", "里拉", "雷亚尔", "兰特", "林吉特", "越南盾",
         "迪拉姆", "克朗", "兹罗提"],
        ["小时", "分钟", "秒钟", "毫秒"],
        ["爸爸", "妈妈", "爷爷", "奶奶", "外公", "外婆", "姥姥", "姥爷", "哥哥", "姐姐", "弟弟", "妹妹", "叔叔", "阿姨", "伯伯",
         "舅舅", "姑姑", "老公", "老婆", "丈夫", "妻子", "儿子", "女儿", "父亲", "母亲", "先生", "太太", "男朋友", "女朋友",
         "同事", "同学", "老师", "老板", "客户", "朋友"],
        ["北京", "上海", "天津", "重庆", "广州", "深圳", "杭州", "南京", "苏州", "成都", "武汉", "西安", "长沙", "郑州", "青岛",
         "厦门", "宁波", "无锡", "合肥", "福州", "济南", "大连", "沈阳", "哈尔滨", "长春", "昆明", "南宁", "贵阳", "南昌", "太原",
         "石家庄", "兰州", "乌鲁木齐", "拉萨", "海口", "三亚", "东莞", "佛山", "珠海", "香港", "澳门", "台北", "台湾",
         "河北", "山西", "辽宁", "吉林", "黑龙江", "江苏", "浙江", "安徽", "福建", "江西", "山东", "河南", "湖北", "湖南",
         "广东", "海南", "四川", "贵州", "云南", "陕西", "甘肃", "青海", "内蒙古", "广西", "西藏", "宁夏", "新疆",
         "中国", "美国", "英国", "法国", "德国", "日本", "韩国", "俄罗斯", "印度", "意大利", "西班牙", "荷兰", "瑞士", "瑞典",
         "土耳其", "埃及", "南非", "新加坡", "泰国", "越南", "马来西亚", "印尼", "菲律宾", "澳大利亚", "新西兰",
         "葡萄牙", "希腊", "波兰", "奥地利", "比利时", "爱尔兰", "丹麦", "挪威", "芬兰", "以色列", "沙特", "伊朗",
         "巴基斯坦", "肯尼亚", "尼日利亚", "加拿大", "墨西哥", "古巴", "巴西", "阿根廷", "智利", "秘鲁", "哥伦比亚",
         "欧洲", "亚洲", "非洲", "美洲", "北美", "南美",
         "纽约", "洛杉矶", "旧金山", "芝加哥", "西雅图", "温哥华", "波士顿", "华盛顿", "休斯敦", "迈阿密", "费城", "达拉斯", "亚特兰大",
         "丹佛", "拉斯维加斯", "墨西哥城", "哈瓦那", "多伦多", "圣保罗", "里约热内卢",
         "布宜诺斯艾利斯", "圣地亚哥", "波哥大", "利马", "伦敦", "曼彻斯特", "爱丁堡", "都柏林", "巴黎", "柏林", "慕尼黑",
         "法兰克福", "罗马", "米兰", "马德里", "巴塞罗那", "里斯本", "阿姆斯特丹", "布鲁塞尔", "苏黎世", "日内瓦", "维也纳",
         "布拉格", "布达佩斯", "华沙", "雅典", "斯德哥尔摩", "哥本哈根", "奥斯陆", "赫尔辛基", "伊斯坦布尔", "莫斯科",
         "东京", "大阪", "京都", "首尔", "曼谷", "河内", "吉隆坡", "雅加达", "马尼拉", "孟买", "新德里", "迪拜", "开罗",
         "内罗毕", "开普敦", "悉尼", "墨尔本", "布里斯班", "珀斯", "奥克兰", "惠灵顿"],
    ]

    /// The same for words in Latin letters, lowercase, each a word of its own: currencies and places.
    static let exclusiveWords: [Set<String>] = [
        ["dollar", "dollars", "euro", "euros", "pound", "pounds", "yen", "yuan", "rmb", "franc", "francs", "peso", "pesos",
         "rupee", "rupees", "won", "baht", "ruble", "rubles", "lira", "rand", "ringgit", "dirham", "krona", "zloty",
         "usd", "eur", "gbp", "jpy", "cny", "hkd", "twd", "krw", "sgd", "aud", "nzd", "cad", "chf", "sek", "nok", "dkk",
         "inr", "thb", "myr", "php", "idr", "vnd", "mxn", "brl", "zar", "aed", "rub", "pln"],
        ["boston", "chicago", "seattle", "vancouver", "houston", "miami", "philadelphia", "dallas", "atlanta", "denver", "detroit",
         "havana", "toronto", "bogota", "caracas", "lima", "quito", "santiago", "montevideo", "london", "manchester",
         "edinburgh", "dublin", "paris", "berlin", "munich", "frankfurt", "hamburg", "rome", "milan", "madrid",
         "barcelona", "lisbon", "amsterdam", "brussels", "zurich", "geneva", "vienna", "prague", "budapest", "warsaw",
         "athens", "stockholm", "copenhagen", "oslo", "helsinki", "istanbul", "moscow", "tokyo", "osaka", "kyoto",
         "seoul", "bangkok", "hanoi", "jakarta", "manila", "mumbai", "delhi", "dubai", "cairo", "nairobi", "lagos",
         "sydney", "melbourne", "brisbane", "perth", "auckland", "wellington", "beijing", "shanghai", "shenzhen",
         "guangzhou", "hangzhou", "taipei", "singapore", "china", "america", "usa", "japan", "korea", "india",
         "thailand", "vietnam", "indonesia", "france", "germany", "england", "britain", "ireland", "italy", "spain",
         "portugal", "greece", "poland", "austria", "belgium", "sweden", "norway", "denmark", "finland", "russia",
         "egypt", "kenya", "nigeria", "canada", "mexico", "cuba", "brazil", "argentina", "chile", "peru", "colombia",
         "australia", "europe", "asia", "africa"],
    ]

    /// Characters a place ends in. Two words that both end in the same one are two places (徐州 → 台州, 德国 →
    /// 法国, 余杭区 → 西湖区), whichever lists have them.
    static let placeEndings = Set("州市省县区镇村国洲岛港湾")

    /// The most common Chinese family names, one character each.
    static let surnames = Set(
        "王李张刘陈杨黄赵吴周徐孙马朱胡郭何高林罗郑梁谢宋唐许韩冯邓曹彭曾肖田董袁潘于蒋蔡余杜叶程苏魏吕丁任沈姚卢姜崔钟谭陆汪范金石廖贾夏韦付方白邹孟熊秦邱江尹薛闫段雷侯龙史陶黎贺顾毛郝龚邵万钱严覃武戴莫孔向汤")
    /// What a family name is followed by when a person is called by it (张总, 李经理, 王哥).
    static let personTitles: Set<String> = [
        "总", "工", "老师", "哥", "姐", "叔", "姨", "伯", "嫂", "爷", "经理", "医生", "博士", "教授", "同学", "先生", "女士", "小姐",
        "太太", "师傅", "老板", "主任", "校长", "院长", "局长", "处长", "科长", "队长", "组长", "主管", "总监", "董", "导", "某",
    ]
    /// Characters common in given names, for what a person is called after 小 or 阿 (小明, 阿强).
    static let givenHan = Set("明红刚华芳丽强军伟磊娜敏静杰涛勇艳鹏超霞平辉玲燕波斌宇浩凯健俊帆帅旭宁龙凤兰梅菊竹松云峰东南")

    /// Whether `s` reads as how a person is called in Chinese: 小王, 老李, 阿强, 小明; a family name and a
    /// title (张总, 李经理, 王哥); or a family name and a given name of one or two characters, which the
    /// segmenter cuts apart because it is no word (王|伟, 周|杰伦), where a word that only begins with such
    /// a character is one piece (方法, 金币, 高点). Two of these, one typed over the other, are two people.
    func isPersonLike(_ s: String) -> Bool {
        let chars = Array(s)
        guard (2...4).contains(chars.count), chars.allSatisfy(Self.isHan) else { return false }
        if chars.count == 2, "小老阿".contains(chars[0]) {
            if Self.surnames.contains(chars[1]) || (chars[0] != "老" && Self.givenHan.contains(chars[1])) { return true }
        }
        guard Self.surnames.contains(chars[0]) else { return false }
        if Self.personTitles.contains(String(chars.dropFirst())) { return true }
        return chars.count <= 3 && segmentCJK(s).filter { !$0.isEmpty }.count > 1
    }

    /// Whether `term`, arriving alone (a word a device learned without a mapping), may join the dictionary as
    /// a learned word: a short name in Latin letters with a capital, as `extract` learns them (Nio, Cursor,
    /// Claude Code), never a number, a secret or an everyday word.
    public static func isLearnableTerm(_ term: String) -> Bool {
        let word = term.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard word.count >= 2, word.count <= 24, isLatinName(word), !hasDigits(word), !isSensitive(word) else { return false }
        let words = word.lowercased().split(separator: " ").map(String.init)
        return words.count <= 3 && !words.allSatisfy(structuralWords.contains) && !isNumberWords(word)
            && !words.contains(where: calendarWords.contains)
    }

    /// Whether `wrong` reads as a number, an amount or a date (一百, 两块, 统一, 星期三, 三个月, twenty): a learned
    /// pair with such a wrong side is a hint for the model only, never replaced on its own
    /// (`LearningPrompt.applyConfirmed`).
    public static func isNumberLike(_ wrong: String) -> Bool {
        if isAmount(wrong) || isNumberWords(wrong) { return true }
        // A numeral next to a word for time or quantity: 星期三, 三个月, 十一点.
        let chars = Array(wrong)
        for (i, c) in chars.enumerated() where cjkNumerals.contains(c) {
            if i > 0, countedHan.contains(chars[i - 1]) { return true }
            if i + 1 < chars.count, countedHan.contains(chars[i + 1]) { return true }
        }
        return false
    }

    /// Characters that make a numeral beside them a date, a time or a quantity.
    static let countedHan = Set("周期拜月号日天年点时分秒个次倍岁半块元")

    /// Whether a learned pair may be written into text without the model seeing the sentence
    /// (`LearningPrompt.applyConfirmed`: 原样转写, or the original typed after a failed polish). Only when
    /// the misheard side cannot be something the user says on purpose; every other pair stays a hint for the
    /// model, which sees the sentence. Wherever the pair came from (an older version, an import, another
    /// device), never:
    /// - when its two sides differ by a number, a negation or an opposite;
    /// - in Latin letters, when a word was changed for another (Cloud → Claude would rewrite "upload to the
    ///   cloud", labels → Lavoben every label, Apple Store → App Store every Apple Store, and so Cloud Code →
    ///   Claude Code too). What is safe: the same letters joined or re-capitalized inside (Iphone → iPhone,
    ///   Git hub → GitHub), and words joined into one name with a letter put in or left out (Open Air → OpenAI);
    /// - in Chinese, when the misheard side is one character (part of countless words), is a word or holds
    ///   one (即使 → 及时 would rewrite every 即使; 金币, 借口, 代码厂), or does not sound the same as the
    ///   corrected side (金币 → 音币, learned towards a dictionary word). What is safe: characters that make
    ///   no word, heard for a word that sounds the same (引必 → 音币, 以经 → 已经, 张伟 → 章伟), or three or
    ///   more of them heard for a name in Latin letters (科德克斯 → Codex).
    public static func replacesBlindly(_ pair: CorrectionPair) -> Bool {
        let wrong = pair.wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = pair.right.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNumberLike(wrong) || changesNumerals(wrong, right) { return false }
        if wrong.filter(\.isNumber) != right.filter(\.isNumber) { return false }
        if changesNegation(wrong, right) || swapsOpposites(wrong, right) { return false }
        let words = wrong.lowercased().split(whereSeparator: \.isWhitespace)
        if words.contains(where: { calendarWords.contains(String($0)) }) { return false }
        let han = wrong.filter(isHan)
        if han.isEmpty {
            let into = right.split(whereSeparator: \.isWhitespace).count
            let letters = wrong.lowercased().filter(isLatinAlnum)
            if letters == right.lowercased().filter(isLatinAlnum) {
                // Joined (Tail wind → Tailwind), or re-capitalized inside; never a name split up again.
                return into <= words.count && (into < words.count || right.dropFirst().contains(where: \.isUppercase))
            }
            return words.count > 1 && into == 1 && isSpellingVariant(wrong, right)
        }
        if han.count < 2 || wordSegments(String(han)).contains(where: { $0.count > 1 }) { return false }
        // Characters that make no word, mixed with letters (欧盆AI): nothing anyone says on purpose.
        if wrong.contains(where: isLatinAlnum) { return true }
        if right.contains(where: isLatinAlnum) {
            // Syllables of a name, as `verdict` tells them from everyday words (吃个饭, 你要死).
            let functional = han.contains { structuralHan.contains(String($0)) || negatingHan.contains($0) }
            return han.count >= 3 && !functional && Set(han.filter(standaloneHan.contains)).count <= 1
        }
        return sameSound(wrong, right)
    }

    /// Nothing but a number or an amount: digits, Chinese numerals with their units (一百, 两块), or number
    /// words (twenty one).
    static func isPureNumber(_ s: String) -> Bool {
        if hasDigits(s) || isNumberWords(s) { return true }
        let chars = s.filter { !$0.isWhitespace }
        return chars.contains(where: cjkNumerals.contains) && chars.allSatisfy { cjkNumerals.contains($0) || cjkUnits.contains($0) }
    }

    static func isNumberWords(_ s: String) -> Bool {
        guard !s.contains(where: isHan) else { return false }
        let words = s.lowercased().split(whereSeparator: { !isLatinAlnum($0) })
        return !words.isEmpty && words.allSatisfy { englishNumbers.contains(String($0)) }
    }

    /// Punctuation dropped; whitespace kept (as one space) only between two Latin alphanumerics.
    static func formatKey(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                var j = i
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if let prev = out.last, isLatinAlnum(prev), j < chars.count, isLatinAlnum(chars[j]) { out.append(" ") }
                i = j
                continue
            }
            if !isPunct(c) { out.append(c) }
            i += 1
        }
        return out
    }

    static func hasDigits(_ s: String) -> Bool {
        s.contains { ($0.isASCII && $0.isNumber) || $0.unicodeScalars.first?.properties.generalCategory == .currencySymbol }
    }

    static func isAmount(_ s: String) -> Bool {
        if hasDigits(s) { return true }
        let numerals = s.filter(cjkNumerals.contains).count
        return numerals > 0 && (numerals + s.filter(cjkUnits.contains).count) * 2 >= s.count
    }

    static func numberBefore(_ r: Range<Int>, in tokens: [Token]) -> Bool {
        var i = r.lowerBound - 1
        while i >= 0, tokens[i].kind == .space { i -= 1 }
        return i >= 0 && tokens[i].kind == .number
    }

    static func numberAfter(_ r: Range<Int>, in tokens: [Token]) -> Bool {
        var j = r.upperBound
        while j < tokens.count, tokens[j].kind == .space { j += 1 }
        return j < tokens.count && tokens[j].kind == .number
    }

    /// One word is the other with a negating prefix or n't (likely → unlikely), or both share a stem
    /// behind opposite prefixes (increase → decrease, import → export).
    static func isPolarityFlip(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        for (short, long) in [(x, y), (y, x)] where short.count >= 3 && long.count > short.count {
            if negatingPrefixes.contains(where: { $0 + short == long }) || short + "n't" == long { return true }
        }
        for p in swappablePrefixes where x.hasPrefix(p) {
            let stem = x.dropFirst(p.count)
            if stem.count >= 4, swappablePrefixes.contains(where: { $0 != p && y == $0 + stem }) { return true }
        }
        return false
    }

    /// Han replaced by letters the IME left uncommitted: an apostrophe, an all-lowercase run, an
    /// all-uppercase run touching Han or close to the pinyin of `wrong` (Caps Lock on: 金币 → YINBI), or
    /// letters that are just the pinyin of `wrong`. Real names keep their capitals (瑞迪特 → Reddit,
    /// 欧盆AI → OpenAI), and an acronym is nothing like the pinyin of what it was heard as (爱皮爱 → API).
    static func isLeftoverPinyin(_ wrong: String, _ right: String) -> Bool {
        guard !wrong.contains(where: isLatinAlnum), right.contains(where: { $0.isASCII && $0.isLetter }) else { return false }
        if right.contains("'") || right.contains("\u{2019}") { return true }
        let heard = phoneticKey(wrong)
        let chars = Array(right)
        var i = 0
        while i < chars.count {
            guard chars[i].isASCII, chars[i].isLetter else { i += 1; continue }
            var j = i
            while j < chars.count, chars[j].isASCII, chars[j].isLetter { j += 1 }
            let run = chars[i..<j]
            let touchesHan = (i > 0 && isHan(chars[i - 1])) || (j < chars.count && isHan(chars[j]))
            if run.allSatisfy(\.isLowercase) { return true }
            if run.allSatisfy(\.isUppercase), touchesHan || distance(String(run).lowercased(), heard) <= capsPinyinDistance { return true }
            i = j
        }
        let letters = phoneticKey(String(right.filter { $0.isASCII && $0.isLetter }))
        return heard.contains(letters)
    }

    /// The misheard side holds what the input method left there: lowercase letters touching Han (`yin币`),
    /// or nothing but lowercase letters where the corrected side is Chinese (`yin bi`, `yinbi` → 硬币). A fix
    /// made over text that was still being typed when it was last compared: its wrong side was never
    /// delivered, so it is no correction. (A name keeps its capital: Taobao → 淘宝 is left to the other rules.)
    static func isPinyinDebris(_ wrong: String, _ right: String) -> Bool {
        guard right.contains(where: isHan), !right.contains(where: { $0.isASCII && $0.isLetter }) else { return false }
        let chars = Array(wrong)
        var letters = false, capital = false
        var i = 0
        while i < chars.count {
            guard chars[i].isASCII, chars[i].isLetter else { i += 1; continue }
            var j = i
            while j < chars.count, chars[j].isASCII, chars[j].isLetter { j += 1 }
            letters = true
            if chars[i..<j].contains(where: \.isUppercase) {
                capital = true
            } else if (i > 0 && isHan(chars[i - 1])) || (j < chars.count && isHan(chars[j])) {
                return true
            }
            i = j
        }
        return letters && !capital && !wrong.contains(where: isHan)
    }

    // MARK: Sound

    /// Pinyin or Latin letters only, lowercase, no tones: 金币 → "jinbi", Open Air → "openair".
    static func phoneticKey(_ s: String) -> String {
        let latin = s.applyingTransform(.mandarinToLatin, reverse: false) ?? s
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return String(plain.lowercased().filter { $0.isASCII && $0.isLetter })
    }

    /// `phoneticKey`, with the Latin letters of `s` written the way they are said, as far as a few letters
    /// go: a hard c and q are k, x is ks, ph is f (Codex → "kodeks"). For comparing a name with the Han
    /// syllables it was heard as; pinyin's own c, q and x are other sounds and stay.
    static func spokenKey(_ s: String) -> String {
        var out = ""
        var run: [Character] = []
        func flush() {
            let letters = Array(String(run).lowercased())
            var i = 0
            while i < letters.count {
                let c = letters[i], next = i + 1 < letters.count ? letters[i + 1] : " "
                switch c {
                case "c" where next == "k": break                      // ck → k
                case "c" where next == "h": out += "ch"; i += 1
                case "c" where !"eiy".contains(next): out.append("k")
                case "q": out.append("k")
                case "x": out += "ks"
                case "p" where next == "h": out.append("f"); i += 1
                default: out.append(c)
                }
                i += 1
            }
            run = []
        }
        for c in s {
            if c.isASCII, c.isLetter { run.append(c); continue }
            flush()
            if isHan(c) { out += phoneticKey(String(c)) }
        }
        flush()
        return out
    }

    /// The syllables of `s` in pinyin without tones, one for each Han character, with what speakers and
    /// recognizers do not tell apart written the same: z/zh, c/ch, s/sh, and -n/-ng. A character with several
    /// readings is taken by the one the system gives it, which is not always the one meant (银行 reads as
    /// "yin xing"): `readings` has the others.
    static func syllables(_ s: String) -> [String] {
        let latin = s.applyingTransform(.mandarinToLatin, reverse: false) ?? s
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return plain.lowercased().split(whereSeparator: { !($0.isASCII && $0.isLetter) }).map { syllable(String($0)) }
    }

    /// One pinyin syllable as it is compared (`syllables`).
    static func syllable(_ pinyin: String) -> String {
        var syllable = pinyin
        for (long, short) in [("zh", "z"), ("ch", "c"), ("sh", "s")] where syllable.hasPrefix(long) {
            syllable = short + syllable.dropFirst(2)
        }
        if syllable.hasSuffix("ng") { syllable.removeLast() }
        return syllable
    }

    /// Common characters with more than one reading (行 in 银行 and 行业, 重 in 重构 and 重要, 模 in 模板 and 模型),
    /// each with all of them. The system gives only one, so a true sound-alike written with such a character
    /// would compare as different (引航 / 银行, 冲构 / 重构, 木板 / 模板).
    static let otherReadings: [Character: [String]] = [
        "行": ["xing", "hang"], "重": ["zhong", "chong"], "模": ["mo", "mu"], "调": ["diao", "tiao"], "长": ["chang", "zhang"],
        "乐": ["le", "yue"], "还": ["hai", "huan"], "觉": ["jue", "jiao"], "角": ["jiao", "jue"], "会": ["hui", "kuai"],
        "率": ["lu", "shuai"], "朝": ["chao", "zhao"], "传": ["chuan", "zhuan"], "藏": ["cang", "zang"], "曾": ["ceng", "zeng"],
        "差": ["cha", "chai"], "都": ["dou", "du"], "降": ["jiang", "xiang"], "系": ["xi", "ji"], "单": ["dan", "shan"],
        "卡": ["ka", "qia"], "薄": ["bo", "bao"], "血": ["xue", "xie"], "解": ["jie", "xie"], "校": ["xiao", "jiao"],
        "参": ["can", "shen"], "便": ["bian", "pian"], "厦": ["sha", "xia"], "查": ["cha", "zha"], "弹": ["dan", "tan"],
        "奇": ["qi", "ji"], "强": ["qiang", "jiang"], "圈": ["quan", "juan"], "省": ["sheng", "xing"], "宿": ["su", "xiu"],
        "提": ["ti", "di"], "盛": ["sheng", "cheng"], "落": ["luo", "la"], "绿": ["lu"], "什": ["shen", "shi"],
        "扎": ["zha", "za"], "折": ["zhe", "she"], "壳": ["ke", "qiao"], "区": ["qu", "ou"], "仔": ["zai", "zi"],
        "栅": ["zha", "shan"], "脉": ["mai", "mo"], "趟": ["tang"], "核": ["he", "hu"], "幢": ["zhuang", "chuang"],
    ]

    /// For each Han character of `s`, every reading it may have, as `syllable`s.
    static func readings(_ s: String) -> [Set<String>] {
        let han = s.filter(isHan)
        let usual = syllables(String(han))
        return han.enumerated().map { i, c in
            var all = Set((otherReadings[c] ?? []).map(syllable))
            // In its word, as the system reads it; and by itself, where that differs.
            if usual.count == han.count { all.insert(usual[i]) }
            all.formUnion(syllables(String(c)).prefix(1))
            return all
        }
    }

    /// Whether two Chinese words are said the same, syllable for syllable (张伟 / 章伟, 权利 / 权力, 金 / 京; a
    /// character with several readings by any of them: 引航 / 银行), or, both of two or more characters, run
    /// together to the same sound (西安门 / 先门). One character against two is never the same word.
    static func sameSound(_ a: String, _ b: String) -> Bool {
        let x = readings(a), y = readings(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x.count == y.count { return zip(x, y).allSatisfy { !$0.isDisjoint(with: $1) } }
        guard x.count >= 2, y.count >= 2 else { return false }
        return syllables(a).joined() == syllables(b).joined()
    }

    /// Whether two Chinese words of as many syllables sound close, syllable for syllable: each within
    /// `syllableDistance` of the one it replaced (金 / 音), by any of their readings, so a word is not let
    /// through by the characters it shares with another (日元 / 美元).
    static func closeSound(_ a: String, _ b: String) -> Bool {
        let x = readings(a), y = readings(b)
        guard !x.isEmpty, x.count == y.count else { return false }
        return zip(x, y).allSatisfy { one, other in
            one.contains { p in other.contains { distance(p, $0) <= syllableDistance } }
        }
    }

    /// How far one syllable may be from the one it replaced: one letter of three (jin / yin).
    static let syllableDistance = 0.34

    /// Edit distance of the phonetic keys over the longer key: 0 sounds the same, 1 nothing in common.
    static func phoneticDistance(_ a: String, _ b: String) -> Double {
        distance(phoneticKey(a), phoneticKey(b))
    }

    /// `phoneticDistance` over `spokenKey`.
    static func spokenDistance(_ a: String, _ b: String) -> Double {
        distance(spokenKey(a), spokenKey(b))
    }

    static func distance(_ x: String, _ y: String) -> Double {
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 1 }
        return Double(levenshtein(x, y)) / Double(longest)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty else { return y.count }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var diagonal = row[0]
            row[0] = i
            for j in stride(from: 1, through: y.count, by: 1) {
                let above = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, diagonal + (x[i - 1] == y[j - 1] ? 0 : 1))
                diagonal = above
            }
        }
        return row[y.count]
    }
}
