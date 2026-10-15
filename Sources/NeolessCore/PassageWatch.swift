import Foundation

/// Finds the passage neoless pasted in the text a field shows afterwards. Apps change what is pasted a
/// little (a no-break space for a space, one line break for two, a line break added at the end, a
/// zero-width character), so the search ignores how white space is written; the passage comes back as the
/// field shows it, and that, not the text as pasted, is what later edits are compared with.
public enum PassageLocator {
    public struct Found: Equatable, Sendable {
        /// Where the passage is in the field's text, in UTF-16 offsets (what Accessibility counts in).
        public var range: Range<Int>
        /// The passage as the field shows it.
        public var text: String

        public init(range: Range<Int>, text: String) {
            self.range = range; self.text = text
        }
    }

    /// One character of a text with white space folded: a run of it is one space, or one line break when it
    /// holds one. `start` and `end` are UTF-16 offsets in the text it came from.
    struct Unit {
        var c: Character
        var start: Int
        var end: Int
        var isSpace: Bool { c == " " || c == "\n" }
    }

    static let invisible: Set<Character> = ["\u{200B}", "\u{200C}", "\u{2060}", "\u{FEFF}"]
    /// A passage this long (folded characters) may be matched by its two ends alone (`loose`).
    static let looseMinimum = 36, looseEdge = 12

    static func fold(_ s: String) -> [Unit] {
        var out: [Unit] = []
        var offset = 0
        for ch in s {
            let start = offset
            offset += ch.utf16.count
            if invisible.contains(ch) { continue }
            guard ch.isWhitespace else {
                out.append(Unit(c: ch, start: start, end: offset))
                continue
            }
            if let last = out.last, last.isSpace {
                out[out.count - 1].end = offset
                if ch.isNewline { out[out.count - 1].c = "\n" }
            } else {
                out.append(Unit(c: ch.isNewline ? "\n" : " ", start: start, end: offset))
            }
        }
        return out
    }

    /// Where `inserted` is in `value`. Of several places, the one that ends nearest to `caret` (the UTF-16
    /// offset of the insertion point, which a paste leaves at its end). Nil when the field does not show it,
    /// or shows it in several places and there is no caret to tell which one was just typed: watching the
    /// wrong one would learn from edits of text neoless did not type.
    public static func locate(_ inserted: String, in value: String, caret: Int? = nil) -> Found? {
        var needle = fold(inserted)[...]
        while needle.first?.isSpace == true { needle.removeFirst() }
        while needle.last?.isSpace == true { needle.removeLast() }
        let hay = fold(value)
        guard !needle.isEmpty, needle.count <= hay.count else { return nil }
        let key = needle.map(\.c)
        var spans = occurrences(of: key, in: hay)
        if spans.isEmpty { spans = loose(key, in: hay) }
        let span: Range<Int>?
        if let caret {
            // The last of those equally near.
            span = spans.reversed().min { abs(hay[$0.upperBound - 1].end - caret) < abs(hay[$1.upperBound - 1].end - caret) }
        } else {
            span = spans.count == 1 ? spans[0] : nil
        }
        guard let span else { return nil }
        return found(value, hay[span.lowerBound].start..<hay[span.upperBound - 1].end)
    }

    /// Where `passage` (as the field showed it last) is now that the text around it changed: the place
    /// nearest to `offset`, its old start in UTF-16. Nil when the field no longer shows it as it was.
    public static func relocate(_ passage: String, in value: String, near offset: Int) -> Found? {
        guard !passage.isEmpty else { return nil }
        var best: Found?
        var bestGap = Int.max
        var from = value.startIndex
        while from < value.endIndex, let r = value.range(of: passage, options: .literal, range: from..<value.endIndex) {
            let lower = value.utf16.distance(from: value.startIndex, to: r.lowerBound)
            let upper = value.utf16.distance(from: value.startIndex, to: r.upperBound)
            let gap = abs(lower - offset)
            if gap < bestGap {
                bestGap = gap
                best = Found(range: lower..<upper, text: passage)
            }
            from = r.upperBound
        }
        return best
    }

    /// Every place `key` occurs in `hay` at or after `from`, left to right, none overlapping.
    static func occurrences(of key: [Character], in hay: [Unit], from: Int = 0) -> [Range<Int>] {
        var out: [Range<Int>] = []
        guard let first = key.first, key.count <= hay.count else { return out }
        var i = max(0, from)
        let last = hay.count - key.count
        while i <= last {
            if hay[i].c == first {
                var k = 1
                while k < key.count, hay[i + k].c == key[k] { k += 1 }
                if k == key.count {
                    out.append(i..<(i + k))
                    i += k
                    continue
                }
            }
            i += 1
        }
        return out
    }

    /// A long passage the app changed a little in the middle (its own quotation marks, a list marker turned
    /// into a bullet): the places that begin and end as it does and are about as long.
    static func loose(_ key: [Character], in hay: [Unit]) -> [Range<Int>] {
        guard key.count >= looseMinimum else { return [] }
        let head = Array(key.prefix(looseEdge)), tail = Array(key.suffix(looseEdge))
        let least = Int(Double(key.count) * 0.85), most = Int(Double(key.count) * 1.15) + 1
        var out: [Range<Int>] = []
        for start in occurrences(of: head, in: hay) {
            let ends = occurrences(of: tail, in: hay, from: start.upperBound)
            guard let end = ends.first(where: { (least...most).contains($0.upperBound - start.lowerBound) }) else { continue }
            out.append(start.lowerBound..<end.upperBound)
        }
        return out
    }

    static func found(_ value: String, _ r: Range<Int>) -> Found? {
        let u = value.utf16
        guard r.lowerBound >= 0, r.lowerBound < r.upperBound, r.upperBound <= u.count else { return nil }
        let a = u.index(u.startIndex, offsetBy: r.lowerBound), b = u.index(u.startIndex, offsetBy: r.upperBound)
        guard let text = String(u[a..<b]) else { return nil }
        return Found(range: r, text: text)
    }
}

/// When to look at the passage neoless pasted into another app, and when to stop: the timing of
/// `CorrectionObserver`, kept apart from Accessibility so it can be tested. Fed with what each look at the
/// field found, it says when a text has settled and may be compared, and when the watch is over.
///
/// A watch that ends hands over the last text it saw, when that was never compared, only where the user has
/// plainly finished with it: the message was sent, or the next dictation began. Anywhere else a text that
/// has not been still for `settle` may be a word still being typed, and a half-typed word learned as a
/// correction is worse than nothing learned:
/// - another app in front, or focus elsewhere in the app, does not end the watch. It goes on from afar
///   (`isAway`): the field is still read, a fix made just before leaving is compared once it has been still
///   for `settle` like any other, and when the user comes back and goes on typing, the next comparison
///   continues from it (科德克斯 → Code, then Code → Codex, is learned as 科德克斯 → Codex);
/// - what changes while focus is elsewhere is never compared: the user cannot be seen typing it;
/// - a field that no longer shows the passage, an app that stopped answering, the time being up: nothing
///   is handed over.
public struct PassageWatch: Sendable {
    /// What one look at the field found.
    public enum Reading: Equatable, Sendable {
        /// The passage as the field shows it now; `composing`: the input method has uncommitted text in it.
        case passage(String, composing: Bool)
        /// The field is empty: a chat app sent the message.
        case empty
        /// Keyboard focus is not in the field, and the field was not read.
        case moved
        /// The field shows other text: the passage is no longer in it as it was.
        case lost
        /// No answer in time.
        case failed
    }

    /// Why a watch ended.
    public enum End: String, Codable, Sendable {
        case sent, moved, lost, failed, deadline, idle, appChanged, newDictation
        /// 自动学习 was switched off, or secure input came on: nothing more is read or compared.
        case off
        case quit

        /// Whether the last text seen may still be compared: only where the user has plainly finished with it.
        public var flushes: Bool { self == .sent || self == .newDictation }
    }

    public enum Step: Equatable, Sendable {
        case wait
        /// This text has been still long enough: compare it.
        case settled(String)
        /// The watch is over. `flush`: a text never compared that is worth comparing first.
        case end(End, flush: String?)
    }

    /// A text is compared once it has not changed for `settle`. When the message is sent or the next
    /// dictation begins, `flushStable` is enough (the user has moved on); less than that is a word still
    /// being typed.
    public static let settle: TimeInterval = 1.5, flushStable: TimeInterval = 0.3
    /// An input method that reports uncommitted text for this long without the text changing is taken at
    /// its word no longer (some fields always report it): the text is compared as it is. Pinyin really left
    /// in it teaches nothing (`CorrectionExtractor.isLeftoverPinyin`).
    public static let composingStale: TimeInterval = 4
    /// The watch lasts at most `maxDuration`, and `idleAfterChange` after the last settled change while
    /// the user is in the field.
    public static let maxDuration: TimeInterval = 120, idleAfterChange: TimeInterval = 30
    /// Looks in a row without an answer before giving up: a busy app misses one now and then.
    public static let maxFailures = 3
    /// How often to look: more often for a few seconds after the text changed, seldom while the user is
    /// elsewhere and nothing waits to be compared.
    public static let pollInterval: TimeInterval = 0.4, busyInterval: TimeInterval = 0.2, busyFor: TimeInterval = 3
    public static let awayInterval: TimeInterval = 1

    private var last: String
    private var changedAt: TimeInterval
    private var composing = false
    /// `last` was handed out for comparing (or is the text as it landed, or changed while focus was elsewhere).
    private var compared = true
    private var lastSettled: TimeInterval?
    private var failures = 0
    private var away = false
    private let started: TimeInterval

    /// `shown`: the passage as the field showed it when it landed, at `now` (any steady clock, in seconds).
    public init(shown: String, at now: TimeInterval) {
        last = shown
        changedAt = now
        started = now
    }

    /// The passage as last seen.
    public var passage: String { last }

    /// The user is elsewhere: another app is in front, or focus is not in the field.
    public var isAway: Bool { away }

    /// A change seen with focus in the field is still waiting to be compared: while away, the field is read
    /// from afar until it has settled.
    public var hasUncompared: Bool { !compared }

    /// Another app came to the front. The watch goes on from afar until the user is back in the field
    /// (`take` with `focused`), a new dictation begins or the time is up.
    public mutating func leave() {
        away = true
    }

    /// `focused`: keyboard focus was in the field when it was read. False for a field read from afar
    /// (another app in front, or focus elsewhere in the app).
    public mutating func take(_ reading: Reading, at now: TimeInterval, focused: Bool = true) -> Step {
        switch reading {
        case .empty: return end(.sent, at: now)
        case .lost: return end(.lost, at: now)
        case .moved:
            failures = 0
            away = true
        case .failed:
            failures += 1
            if failures >= Self.maxFailures { return end(.failed, at: now) }
        case let .passage(text, isComposing):
            failures = 0
            if focused, away {
                away = false
                // Back in the field: the idle time counts from now.
                if lastSettled != nil { lastSettled = now }
            }
            if text != last || isComposing != composing {
                last = text
                composing = isComposing
                changedAt = now
                // What changes while focus is elsewhere is not the user typing into the field, as far as
                // can be seen: it is not compared, and what was waiting to be is no longer what the field shows.
                compared = !focused
            } else if !compared, now - changedAt >= (composing ? Self.composingStale : Self.settle) {
                compared = true
                lastSettled = now
                return .settled(text)
            }
        }
        // Not while a change waits to be compared (it keeps the watch until it has settled), and not while
        // the user is away: coming back within `maxDuration` goes on from where they left.
        if compared, !away, let lastSettled, now - lastSettled > Self.idleAfterChange { return end(.idle, at: now) }
        if now - started > Self.maxDuration { return end(.deadline, at: now) }
        return .wait
    }

    /// The watch is over: `take` said so, or something outside did (a new dictation began). Always `.end`.
    /// A text never compared is handed over only when the reason says the user has finished with it
    /// (`End.flushes`), no input method is composing in it, and it has been still for `flushStable`; from
    /// afar, for the whole `settle` unless the message was sent (the user left, and may have left a word
    /// half typed).
    public mutating func end(_ reason: End, at now: TimeInterval) -> Step {
        let needed = away && reason != .sent ? Self.settle : Self.flushStable
        let flush = reason.flushes && !compared && !composing && now - changedAt >= needed
        compared = true
        return .end(reason, flush: flush ? last : nil)
    }

    /// How long to wait before the next look.
    public func interval(at now: TimeInterval) -> TimeInterval {
        if away, compared { return Self.awayInterval }
        return now - changedAt < Self.busyFor ? Self.busyInterval : Self.pollInterval
    }
}

/// How long to go on looking for the pasted text in the field.
public enum PassageLanding {
    /// Between two looks.
    public static let interval: TimeInterval = 0.15
    /// An app asked for its accessibility tree only now needs a moment to build it; any other app shows
    /// the text within a moment of the paste or not at all.
    public static let askedTimeout: TimeInterval = 4, plainTimeout: TimeInterval = 1.5

    /// Whether to look again after a look that did not find the text (`why`), `elapsed` seconds after the
    /// paste. A field too long to read stays too long: looking again would only copy it out again.
    public static func retries(_ why: LearningLog.Code, asked: Bool, elapsed: TimeInterval) -> Bool {
        if why == .tooLong { return false }
        return elapsed < (asked ? askedTimeout : plainTimeout)
    }

    /// Whether the text went somewhere other than the app taken for its target (the frontmost one): the
    /// keyboard focus is with another app's panel (Spotlight, a launcher), which takes the keys without
    /// coming to the front. Then the app underneath is neither read nor asked for anything, and nothing is
    /// said about it: nothing was dictated into it. `focusOwner`: the process the system says has the
    /// keyboard, nil when it does not say. neoless's own panels never count as elsewhere.
    public static func isElsewhere(focusOwner: Int32?, target: Int32, own: Int32) -> Bool {
        guard let focusOwner else { return false }
        return focusOwner != target && focusOwner != own
    }
}

/// Apps built on Chromium or Electron, whose text fields answer Accessibility only once the app has been
/// asked to build its accessibility tree (a screen reader does that; without one a field there reads as
/// nothing, and neoless cannot see what the user changed in it). Only the apps listed here are ever asked,
/// and never a password manager.
///
/// What asking does, and how it is undone (`CorrectionObserver`):
/// - Electron apps (`electron`) are asked by setting `AXManualAccessibility` on the application, for the
///   time a dictation's text is watched. It is set back when that watch is over, when 自动学习 is switched
///   off and when neoless quits; what was set is kept on disk (`WokenApps`), so the next launch sets back
///   what a crash left on.
/// - Chromium browsers (`chromium`) have no such switch: they build the tree when an assistive app reads
///   the application's role, and nothing neoless can send switches it off again. It stays until the browser
///   drops it itself or is restarted.
/// - Code editors built on VS Code (`editors`) react to being asked: with their default setting they take
///   it for a screen reader and switch to their screen-reader mode. They are asked only when the user has
///   switched that on for the editor in Settings.
public enum WebAccessibility {
    public enum Kind: Equatable, Sendable {
        /// Asked with `AXManualAccessibility`, which can be set back.
        case electron
        /// Asked by reading the application's role, which cannot be undone.
        case chromium
    }

    /// A code editor the user may switch learning on for.
    public struct Editor: Equatable, Sendable {
        public let bundleID: String
        public let name: String
    }

    /// Electron apps: they build the tree when `AXManualAccessibility` is set on the application.
    static let electron: Set<String> = [
        "com.anthropic.claudefordesktop", "com.openai.codex", "com.openai.chat",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "notion.id", "md.obsidian", "com.linear", "com.figma.Desktop",
        "com.electron.lark", "com.github.GitHubClient",
    ]
    /// Chromium browsers: they build it when the application's role is read.
    static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "company.thebrowser.dia", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.openai.atlas",
        "ai.perplexity.comet",
    ]
    /// The VS Code family (Electron): never asked by default.
    public static let editors: [Editor] = [
        Editor(bundleID: "com.microsoft.VSCode", name: "VS Code"),
        Editor(bundleID: "com.microsoft.VSCodeInsiders", name: "VS Code Insiders"),
        Editor(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        Editor(bundleID: "com.exafunction.windsurf", name: "Windsurf"),
        Editor(bundleID: "com.vscodium", name: "VSCodium"),
    ]
    /// The setting's one-line warning.
    public static let editorWarning = "打开后，这个编辑器可能切到“屏幕阅读器”模式"

    static let passwordManagers = [
        "1password", "onepassword", "bitwarden", "lastpass", "dashlane", "keepass", "enpass", "keeper",
        "protonpass", "proton.pass", "nordpass", "roboform", "keychain", "passwords", "strongbox", "pwsafe",
        "com.outercorner.secrets",
    ]

    /// How the app is asked to build its accessibility tree, or nil when it is never asked. `optedIn`: the
    /// editors (bundle ids) the user switched learning on for.
    public static func kind(bundleID: String?, optedIn: Set<String> = []) -> Kind? {
        guard let bundleID, !isPasswordManager(bundleID) else { return nil }
        if electron.contains(bundleID) { return .electron }
        if chromium.contains(bundleID) { return .chromium }
        if isEditor(bundleID), optedIn.contains(bundleID) { return .electron }
        return nil
    }

    /// Whether the app may be asked to build its accessibility tree.
    public static func mayAsk(bundleID: String?, optedIn: Set<String> = []) -> Bool {
        kind(bundleID: bundleID, optedIn: optedIn) != nil
    }

    /// One of the code editors that are asked only when the user said so.
    public static func isEditor(_ bundleID: String?) -> Bool {
        editors.contains { $0.bundleID == bundleID }
    }

    /// A password manager: never asked for its accessibility tree, and what is typed into it is never
    /// watched at all (`CorrectionObserver.capture`).
    public static func isPasswordManager(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        return passwordManagers.contains(where: lower.contains)
    }
}

/// Whether to ask an Electron app for its accessibility tree, and whether it is then neoless's to switch
/// off again. Decided from what the app says about the switch before it is touched, so a tree a screen
/// reader or another tool asked for is never taken for neoless's own and switched off under it.
public enum AccessibilityTreeRequest {
    /// What reading `AXManualAccessibility` gave before asking.
    public enum Before: Equatable, Sendable {
        case on, off
        /// The app does not say (an older Electron, or not an Electron app after all).
        case unknown
        /// No answer in time: nothing is asked of a busy app, the next look asks again.
        case busy
    }

    public enum Action: Equatable, Sendable {
        case nothing
        /// Set the switch, and remember that neoless did (`WokenApps`).
        case ask
    }

    /// - Parameters:
    ///   - focusReadsAsText: the app's focused element already says what text it holds, so a tree is there.
    ///   - ours: neoless set the switch on this app and has not set it back since.
    ///   - again: the last paste into this app could not be read although it was asked.
    public static func decide(before: Before, focusReadsAsText: Bool, ours: Bool, again: Bool) -> Action {
        switch before {
        case .busy, .on: return .nothing
        // Off: never asked, set back since, or switched off by something else (an Electron app drops the
        // tree when VoiceOver goes off). Asked, also again. But not when the field can be read as it is and
        // neoless has not set the switch: then a tree is there whatever the app says about the switch (what
        // it says is not always the whole truth), it is someone else's, and there is nothing to gain by
        // setting it, only a tree to switch off under whoever asked for it.
        case .off: return focusReadsAsText && !ours ? .nothing : .ask
        case .unknown:
            // Asked already and it cannot be told whether that still holds: once more only after a paste
            // that could not be read, never on every dictation (an app may count the requests).
            if ours { return again ? .ask : .nothing }
            // The tree is there without neoless: someone else's, not to be touched.
            return focusReadsAsText ? .nothing : .ask
        }
    }
}

/// The apps whose `AXManualAccessibility` neoless set and has not set back yet (ax-woken.json): process
/// id, bundle id and launch time, nothing else. Kept on disk so that a neoless that was killed leaves a
/// note for the next launch, which sets them back.
public struct WokenApps: Codable, Equatable, Sendable {
    public struct App: Codable, Equatable, Sendable {
        public var pid: Int32
        public var bundleID: String
        /// When that process was launched: a process id is used again after the app quits.
        public var launched: Date?

        public init(pid: Int32, bundleID: String, launched: Date?) {
            self.pid = pid; self.bundleID = bundleID; self.launched = launched
        }
    }

    public private(set) var apps: [App]

    public init(apps: [App] = []) {
        self.apps = apps
    }

    public var isEmpty: Bool { apps.isEmpty }

    public func contains(pid: Int32) -> Bool {
        apps.contains { $0.pid == pid }
    }

    public mutating func add(_ app: App) {
        apps.removeAll { $0.pid == app.pid }
        apps.append(app)
    }

    @discardableResult
    public mutating func remove(pid: Int32) -> App? {
        guard let i = apps.firstIndex(where: { $0.pid == pid }) else { return nil }
        return apps.remove(at: i)
    }

    /// Whether `app` is still the process it was when neoless asked it: the same bundle id under that
    /// process id and, where both are known, the same launch time. `bundleID` and `launched`: what runs
    /// under `app.pid` now (nil when nothing does).
    public static func isSame(_ app: App, bundleID: String?, launched: Date?) -> Bool {
        guard let bundleID, bundleID == app.bundleID else { return false }
        guard let then = app.launched, let now = launched else { return true }
        return abs(then.timeIntervalSince(now)) < 1
    }
}

/// One thing kept to be said a little later (a learned word, while a dictation has the capsule), and
/// dropped when it has waited too long to still be about what the user just did.
public struct HeldLine<Value: Sendable>: Sendable {
    public static var maxAge: TimeInterval { 60 }

    private var held: (value: Value, at: TimeInterval)?

    public init() {}

    public var isEmpty: Bool { held == nil }

    /// Keeps `value` for later. One that is waiting is replaced, unless `keep` says it matters more.
    public mutating func hold(_ value: Value, at now: TimeInterval, unless keep: (Value) -> Bool = { _ in false }) {
        if let held, now - held.at <= Self.maxAge, keep(held.value) { return }
        held = (value, now)
    }

    /// What was kept, once: nil when nothing is waiting or it has waited longer than `maxAge`.
    public mutating func take(at now: TimeInterval) -> Value? {
        defer { held = nil }
        guard let held, now - held.at <= Self.maxAge else { return nil }
        return held.value
    }
}
