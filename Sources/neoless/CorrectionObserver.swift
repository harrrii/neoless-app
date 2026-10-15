import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import CryptoKit
import Foundation
import NeolessCore

/// Watches the passage neoless just pasted into another app and learns the user's term fixes.
///
/// After the paste it finds the passage in the field's own text (`PassageLocator`: apps change what is
/// pasted a little, so nothing has to match exactly), then looks at it a few times a second
/// (`PassageWatch`) and compares each settled state with the one before (`EditTracker`,
/// `CorrectionExtractor`). When the message is sent or the next dictation begins, the last text it saw is
/// still compared, so a fix made just before is not lost. Another app in front, or focus elsewhere, does not
/// end the watch: it goes on from afar until the text has settled, and continues when the user comes back.
///
/// Only the lengths and SHA-256 hashes of the text around the passage are kept, the passage itself stays in
/// memory for at most `PassageWatch.maxDuration`, password fields are never read, nothing typed into a
/// password manager is watched, and a field holding more than `AX.maxField` characters is neither kept nor
/// compared. Such a field is asked how much it holds before any of it is read; one that does not say is
/// read once to find out, and a watched field that grows past the limit is read on the look that sees it,
/// which ends the watch. Every AX call runs on a private queue with a per-element timeout, so a slow app
/// can never stall the main thread or the hotkey. Quitting waits for that queue at most `shutdownWait`.
///
/// Chromium and Electron apps (Claude, ChatGPT, Chrome…) answer Accessibility only once asked to build their
/// accessibility tree. Only the ones on `WebAccessibility`'s list are asked, when a dictation into them begins:
/// - An Electron app gets `AXManualAccessibility` set, unless it says the switch is on already, or its
///   focused field can be read as it is (then a tree is there, someone else's, and is left alone). neoless
///   sets it back when the watch on that app is over, when
///   自动学习 is switched off and at quit, and notes on disk (ax-woken.json) what it set, so the next launch
///   sets back what a crash or a kill left on. The app keeps a tree for all its windows meanwhile, which
///   costs it some work; an app may also react to it as it would to a screen reader.
/// - A Chromium browser has no such switch: reading the application's role makes it build the tree, and
///   nothing switches that off again. It stays until the browser drops it itself or is restarted.
/// - The VS Code family (VS Code, Cursor, Windsurf, VSCodium) switches to its screen-reader mode when asked,
///   so it is asked only for the editors the user switched on in Settings (`LearningStore.editors`).
/// Nothing is asked while VoiceOver is on (it asks itself), and nothing is set back under it.
@MainActor
final class CorrectionObserver {
    /// The app a paste is about to land in.
    struct Probe: Sendable {
        let pid: pid_t
        let bundleID: String?
        var launched: Date?
    }

    enum Capture: Sendable {
        case target(Probe)
        /// Learning off, no Accessibility, secure input, a password manager or neoless itself in front.
        case skip
    }

    /// How long quitting waits for the apps neoless asked to be told they may stop. What is not done by then
    /// is done by the next launch (ax-woken.json).
    static let shutdownWait: TimeInterval = 0.8
    /// How soon after a watch is over the app is told it may stop keeping its tree, and how long a dictation
    /// that began (and whose text has not landed yet) keeps it asked.
    static let restDelay: TimeInterval = 2, preparedHold: TimeInterval = 300

    private let learning: LearningStore
    /// False for snapshots: no app is ever asked, nothing is kept on disk.
    private let live: Bool
    private let queue = DispatchQueue(label: "neoless.correction-observer", qos: .utility)
    private let extractor = CorrectionExtractor()
    private var generation = 0
    /// The watch being landed or kept, and those that ended with a comparison still running.
    private var sessions: [Int: Session] = [:]
    private var current: Int?
    /// Apps a dictation is on its way into (asked when it began), and when: they stay asked until its text
    /// lands and a watch takes over, or `preparedHold` has passed (the dictation was given up).
    private var prepared: [pid_t: TimeInterval] = [:]
    private var bag = Set<AnyCancellable>()

    /// One pasted passage, from the paste until its last comparison is done. Main actor only.
    private final class Session {
        let generation: Int
        let probe: Probe
        let recordID: UUID
        let appName: String?
        let inserted: String
        let started = ProcessInfo.processInfo.systemUptime
        var target: AX.Target?
        var watch: PassageWatch?
        var tracker: EditTracker
        var events: [LearningEvent] = []
        var extracting = false
        /// A text that settled while a comparison was running; compared once that one has committed.
        var pending: String?
        /// Why the watch is ending: one last look is on its way, ticks no longer count.
        var finishing: PassageWatch.End?
        var ended = false
        /// What has the focus instead of the field, once it was looked at and found not to be the field: it
        /// is not read again while focus stays on it.
        var elsewhere: AX.Element?

        init(generation: Int, probe: Probe, recordID: UUID, appName: String?, inserted: String) {
            self.generation = generation
            self.probe = probe
            self.recordID = recordID
            self.appName = appName
            self.inserted = inserted
            tracker = EditTracker(original: inserted)
        }
    }

    init(learning: LearningStore) {
        self.learning = learning
        live = learning.persists
        if live {
            // What a neoless that was killed or crashed left switched on is set back now.
            let voiceOver = NSWorkspace.shared.isVoiceOverEnabled
            queue.async {
                AX.load()
                if !voiceOver { AX.restAll() }
            }
        }
        learning.$enabled.sink { [weak self] on in
            guard !on, let self else { return }
            self.stop()
            self.restApps()
        }.store(in: &bag)
        // The sink runs before the new value is stored: an editor switched off is told it may stop at once.
        learning.$editors.sink { [weak self] now in
            guard let self else { return }
            let off = self.learning.editors.subtracting(now)
            guard !off.isEmpty, self.live, !NSWorkspace.shared.isVoiceOverEnabled else { return }
            self.queue.async { AX.rest(bundleIDs: off) }
        }.store(in: &bag)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.activated(pid) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated { self?.terminated(pid) }
        }
    }

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// How `probe`'s app is asked for its accessibility tree, or nil when it is not to be asked (not on the
    /// list, an editor the user did not switch on, VoiceOver on, a snapshot).
    private func request(for probe: Probe) -> AX.Asking? {
        guard live, !NSWorkspace.shared.isVoiceOverEnabled,
              let kind = WebAccessibility.kind(bundleID: probe.bundleID, optedIn: learning.editors) else { return nil }
        return AX.Asking(pid: probe.pid, bundleID: probe.bundleID ?? "", launched: probe.launched, kind: kind)
    }

    /// A dictation began with `app` in front. An app that answers Accessibility only when asked is asked now,
    /// so its fields can be read by the time the text lands in one. Not when another app's panel has the
    /// keyboard (a launcher over it): the text is not going into this one.
    func prepare(for app: NSRunningApplication?) {
        guard learning.enabled, Permissions.accessibility, let app,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let asking = request(for: Probe(pid: app.processIdentifier, bundleID: app.bundleIdentifier, launched: app.launchDate))
        else { return }
        prepared[asking.pid] = uptime
        queue.async { AX.ask(asking, whenFocusOwner: true) }
        // A dictation that is given up never lands: the app must not stay asked for it.
        scheduleRest(asking.pid, after: Self.preparedHold + Self.restDelay)
    }

    /// Before pasting `text`: which app it is going to. Nothing is read from the app here, so the paste
    /// never waits for it.
    func capture(inserting text: String) async -> Capture {
        // Normally over already: the dictation that produced `text` ended the watch on the last one.
        finish(.newDictation)
        guard learning.enabled, Permissions.accessibility, !IsSecureEventInputEnabled(),
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              // What is typed into a password manager is never watched, secure field or not.
              !WebAccessibility.isPasswordManager(front.bundleIdentifier ?? "") else { return .skip }
        return .target(Probe(pid: front.processIdentifier, bundleID: front.bundleIdentifier, launched: front.launchDate))
    }

    /// Starts watching after a successful paste.
    func begin(_ capture: Capture, inserted: String, recordID: UUID, appName: String?) {
        finish(.newDictation)
        guard learning.enabled, case .target(let probe) = capture, !inserted.isEmpty,
              // The user switched apps between the capture and the paste.
              NSWorkspace.shared.frontmostApplication?.processIdentifier == probe.pid else { return }
        generation += 1
        sessions[generation] = Session(generation: generation, probe: probe, recordID: recordID, appName: appName, inserted: inserted)
        current = generation
        // The watch keeps the app asked from here on.
        prepared[probe.pid] = nil
        land(generation)
    }

    /// The watch is over because a new dictation began. The field is looked at once more, and a fix not
    /// compared yet still is; what it teaches is learned for the dictation it was made in, whatever starts
    /// meanwhile.
    func finish(_ reason: PassageWatch.End) {
        guard let gen = current, let session = sessions[gen] else { return }
        current = nil
        guard reason.flushes, !session.ended, session.finishing == nil, let target = session.target,
              let watch = session.watch else {
            // Still looking for the text, or nothing may be read any more.
            if !session.extracting { remove(gen) } else { session.ended = true }
            return
        }
        session.finishing = reason
        let last = watch.passage, afar = watch.isAway, elsewhere = session.elsewhere
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == session.probe.pid
        queue.async { [weak self] in
            let look = AX.read(target, last: last, front: front, afar: afar, elsewhere: elsewhere)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.looked(gen, look) }
            }
        }
    }

    /// Stops at once: nothing more is read, compared or learned (自动学习 off, quitting).
    func stop() {
        current = nil
        sessions = [:]
        prepared = [:]
    }

    /// Quitting: stops, and the apps neoless asked for their accessibility tree are told they may stop
    /// keeping it. Waits for that at most `shutdownWait`: an app that does not answer never holds up the
    /// quit, and what was not done is on disk for the next launch to do.
    func shutdown() {
        stop()
        guard live, !NSWorkspace.shared.isVoiceOverEnabled else { return }
        let done = DispatchSemaphore(value: 0)
        queue.async {
            AX.restAll()
            done.signal()
        }
        _ = done.wait(timeout: .now() + Self.shutdownWait)
    }

    private func restApps() {
        guard live, !NSWorkspace.shared.isVoiceOverEnabled else { return }
        queue.async { AX.restAll() }
    }

    // MARK: Asking and setting back

    /// Takes a watch out. Its app may stop keeping its accessibility tree, unless something else still needs it.
    private func remove(_ gen: Int) {
        guard let session = sessions.removeValue(forKey: gen) else { return }
        if current == gen { current = nil }
        scheduleRest(session.probe.pid, after: Self.restDelay)
    }

    private func scheduleRest(_ pid: pid_t, after delay: TimeInterval) {
        guard live else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.restIfIdle(pid) }
        }
    }

    /// Tells the app it may stop keeping its tree, when no watch is on it and no dictation is on its way
    /// into it. (Only an app neoless itself switched on is touched, `AX.rest`.)
    private func restIfIdle(_ pid: pid_t) {
        // A watch on it: its end asks again.
        guard !sessions.values.contains(where: { $0.probe.pid == pid }) else { return }
        if let asked = prepared[pid] {
            // A dictation is on its way: `begin` takes over, or the check scheduled for when it is given up.
            guard uptime - asked >= Self.preparedHold else { return }
            prepared[pid] = nil
        }
        // Under VoiceOver nothing is set back; it stays noted, for the next watch's end, the quit or the launch.
        guard !NSWorkspace.shared.isVoiceOverEnabled else { return }
        queue.async { AX.rest(pid: pid) }
    }

    /// Another app came to the front: the watch goes on from afar (`PassageWatch.leave`). While the text is
    /// still being looked for, `landed` sees it and gives up.
    private func activated(_ pid: pid_t?) {
        guard let gen = current, let session = sessions[gen], pid != session.probe.pid, session.finishing == nil else { return }
        session.watch?.leave()
    }

    private func terminated(_ pid: pid_t) {
        for (gen, session) in sessions where session.probe.pid == pid {
            sessions[gen] = nil
            if current == gen { current = nil }
        }
        prepared[pid] = nil
        queue.async { AX.forget(pid: pid) }
    }

    // MARK: Landing

    /// Looks for the pasted text in the focused field, again and again until it is there or the time is up
    /// (`PassageLanding`).
    private func land(_ gen: Int) {
        guard let session = sessions[gen], current == gen else { return }
        let probe = session.probe, inserted = session.inserted
        let asking = request(for: probe)
        queue.asyncAfter(deadline: .now() + PassageLanding.interval) { [weak self] in
            let landing = AX.land(probe, inserted: inserted, asking: asking)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.landed(gen, landing) }
            }
        }
    }

    private func landed(_ gen: Int, _ landing: AX.Landing) {
        guard let session = sessions[gen], current == gen else { return }
        guard learning.enabled, !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == session.probe.pid else { return drop(gen) }
        switch landing {
        case let .found(target, shown):
            session.target = target
            // Later edits are compared with the passage as the field shows it, so what the app changed while
            // pasting (its own spaces and line breaks) never counts as the user's edit.
            session.tracker = EditTracker(original: shown)
            session.watch = PassageWatch(shown: shown, at: uptime)
            scheduleTick(gen)
        case .secure, .elsewhere:
            // Nothing to watch, and nothing to say: for `.elsewhere`, nothing was dictated into this app.
            drop(gen)
        case .missing(var why):
            let asked = WebAccessibility.mayAsk(bundleID: session.probe.bundleID, optedIn: learning.editors)
            if PassageLanding.retries(why, asked: asked, elapsed: uptime - session.started) {
                land(gen)
            } else {
                if why == .unreadable {
                    if asked {
                        // Asked, and still nothing to read: the next dictation asks once more.
                        let pid = session.probe.pid
                        queue.async { AX.askAgain(pid: pid) }
                    } else if WebAccessibility.isEditor(session.probe.bundleID) {
                        why = .needsOptIn
                    }
                }
                learning.noteUnwatched(why, app: session.appName, recordID: session.recordID)
                drop(gen)
            }
        }
    }

    private func drop(_ gen: Int) {
        remove(gen)
    }

    // MARK: Watching

    private func scheduleTick(_ gen: Int) {
        guard let watch = sessions[gen]?.watch else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + watch.interval(at: uptime)) { [weak self] in
            MainActor.assumeIsolated { self?.tick(gen) }
        }
    }

    private func tick(_ gen: Int) {
        guard let session = sessions[gen], current == gen, !session.ended, session.finishing == nil,
              let target = session.target, var watch = session.watch else { return }
        guard learning.enabled, !IsSecureEventInputEnabled() else {
            // Nothing more is read; a comparison already running is dropped with the session.
            return drop(gen)
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == session.probe.pid
        if !front, !watch.isAway {
            watch.leave()
            session.watch = watch
        }
        // Another app is in front and nothing waits to be compared: nothing is read, only the time is counted.
        if !front, !watch.hasUncompared {
            return looked(gen, AX.Look(reading: .moved, focused: false))
        }
        // From afar the field is read only for a change that waits to be compared: to see that it stays as it is.
        let last = watch.passage, afar = watch.isAway && watch.hasUncompared, elsewhere = session.elsewhere
        queue.async { [weak self] in
            let look = AX.read(target, last: last, front: front, afar: afar, elsewhere: elsewhere)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.ticked(gen, look) }
            }
        }
    }

    private func ticked(_ gen: Int, _ look: AX.Look) {
        // A watch that is ending waits for its own last look.
        guard let session = sessions[gen], current == gen, session.finishing == nil else { return }
        looked(gen, look)
    }

    /// One look at the field: of a tick, or the last one of a watch that is ending.
    private func looked(_ gen: Int, _ look: AX.Look) {
        guard let session = sessions[gen], !session.ended, var watch = session.watch else { return }
        if let target = look.target { session.target = target }
        if look.focused || look.elsewhere != nil { session.elsewhere = look.elsewhere }
        let now = uptime
        var step = watch.take(look.reading, at: now, focused: look.focused)
        if let reason = session.finishing {
            if case .settled(let text) = step { evaluate(session, text) }
            if case .end = step {} else { step = watch.end(reason, at: now) }
        }
        session.watch = watch
        switch step {
        case .wait:
            scheduleTick(gen)
        case .settled(let text):
            evaluate(session, text)
            scheduleTick(gen)
        case let .end(_, flush):
            session.ended = true
            if current == gen { current = nil }
            if let flush { evaluate(session, flush) }
            retire(gen)
        }
    }

    // MARK: Learning

    private func evaluate(_ session: Session, _ text: String) {
        // The running comparison may still move the baseline: settle this text after it.
        if session.extracting {
            session.pending = text
            return
        }
        // A word learned alone that the text no longer shows was taken back, or was half of a name typed
        // with a pause: what taught it is undone, and the tracker compares again from before it.
        takeBack(session.tracker.withdrawn(from: text), in: session)
        // What the passage shows now that could be a habit (a stop taken off, a filler deleted), for the
        // offer on the dictionary page. Compared with the text as delivered, whatever the step below says.
        learning.notePatterns(original: session.tracker.original, edited: text, recordID: session.recordID, app: session.appName)
        switch session.tracker.settle(text) {
        case .none:
            // Only deleting teaches nothing: said (in the log), so it is not a silence.
            if session.tracker.removesOnly(text) {
                learning.noteNothing(.removedOnly, source: .otherApp, recordID: session.recordID, app: session.appName)
            }
        case .retract:
            for event in session.events.reversed() { learning.undo(event) }
            session.events = []
        case let .extract(inserted, edited):
            session.extracting = true
            let extractor = self.extractor, known = learning.knownTerms, gen = session.generation
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let found = extractor.extract(inserted: inserted, edited: edited, knownTerms: known)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.extracted(gen, found, inserted, edited) }
                }
            }
        }
    }

    private func extracted(_ gen: Int, _ found: Extraction, _ inserted: String, _ edited: String) {
        guard let session = sessions[gen] else { return }
        session.extracting = false
        if learning.enabled {
            // Only a step that taught something moves the baseline, and only by the stretches it learned
            // from: a word still being typed or deleted in the same text is compared again when it is done.
            // A swap that is only remembered moves nothing: it is compared again with what was delivered.
            if found.teaches {
                session.tracker.commit(edited, over: inserted, understood: found.baseline, alone: found.alone)
            }
            // What an earlier look at this passage remembered of a swap that is no longer in it is taken
            // back by the same call (`earlier`).
            session.events += learning.learn(found, source: .otherApp, recordID: session.recordID, app: session.appName,
                                             earlier: session.events)
        }
        if let next = session.pending {
            session.pending = nil
            evaluate(session, next)
        }
        retire(gen)
    }

    /// Undoes the events of this watch that learned or noted one of `words` alone (`EditTracker.withdrawn`).
    private func takeBack(_ words: [String], in session: Session) {
        guard !words.isEmpty else { return }
        let gone = Set(words.map { $0.lowercased() })
        for event in session.events.reversed() where event.aloneWords.contains(where: { gone.contains($0.lowercased()) }) {
            learning.undo(event)
            session.events.removeAll { $0.id == event.id }
        }
    }

    /// A watch that ended goes once its last comparison is done.
    private func retire(_ gen: Int) {
        guard let session = sessions[gen], session.ended, !session.extracting else { return }
        remove(gen)
    }
}

// MARK: - Anchor

/// Where the passage sits: lengths and hashes of the text before and after it, never the text.
struct InsertionAnchor: Sendable {
    let prefixLength: Int   // UTF-16
    let suffixLength: Int
    let prefixHash: SHA256.Digest
    let suffixHash: SHA256.Digest

    static let maxPassage = CorrectionExtractor.maxPassage

    /// `passage`: where the passage is in `value`, in UTF-16 (`PassageLocator.Found.range`); nil when it is
    /// out of range or splits a surrogate pair.
    init?(value: String, passage: Range<Int>) {
        let count = value.utf16.count
        guard passage.lowerBound >= 0, passage.upperBound <= count,
              let start = Self.index(value, passage.lowerBound),
              let end = Self.index(value, passage.upperBound) else { return nil }
        prefixLength = passage.lowerBound
        suffixLength = count - passage.upperBound
        prefixHash = SHA256.hash(data: Data(value[..<start].utf8))
        suffixHash = SHA256.hash(data: Data(value[end...].utf8))
    }

    /// The passage between the unchanged prefix and suffix, or nil if the text around it changed.
    func passage(in value: String) -> String? {
        let n = value.utf16.count
        guard n >= prefixLength + suffixLength, n - prefixLength - suffixLength <= Self.maxPassage * 2,
              let start = Self.index(value, prefixLength),
              let end = Self.index(value, n - suffixLength),
              SHA256.hash(data: Data(value[..<start].utf8)) == prefixHash,
              SHA256.hash(data: Data(value[end...].utf8)) == suffixHash else { return nil }
        let passage = String(value[start..<end])
        return passage.count <= Self.maxPassage ? passage : nil
    }

    /// The String index at a UTF-16 offset, only if it falls on a Unicode scalar boundary.
    private static func index(_ s: String, _ offset: Int) -> String.Index? {
        let i = s.utf16.index(s.utf16.startIndex, offsetBy: offset)
        return i.samePosition(in: s.unicodeScalars) == nil ? nil : i
    }
}

// MARK: - Accessibility reads (private queue only)

private enum AX {
    struct Target: @unchecked Sendable {
        let pid: pid_t
        let element: AXUIElement
        let anchor: InsertionAnchor
    }

    /// An element of another app, to hand between the queue and the main actor.
    struct Element: @unchecked Sendable {
        let ref: AXUIElement
    }

    /// An app to be asked for its accessibility tree, and how.
    struct Asking: Sendable {
        let pid: pid_t
        let bundleID: String
        let launched: Date?
        let kind: WebAccessibility.Kind
    }

    /// What looking for the pasted text found.
    enum Landing: @unchecked Sendable {
        /// The field and the passage as it shows it.
        case found(Target, String)
        /// A password field: never read.
        case secure
        /// The keyboard is with another app's panel (a launcher over this app): the text did not go here.
        case elsewhere
        case missing(LearningLog.Code)
    }

    /// One look at a watched field. `target`: the field with the passage found again after the text around
    /// it changed. `focused`: keyboard focus was in the field (false for a field read from afar, or not read).
    /// `elsewhere`: what has the focus instead, when that was seen not to be the field.
    struct Look: @unchecked Sendable {
        var reading: PassageWatch.Reading
        var target: Target?
        var focused = true
        var elsewhere: Element?
    }

    /// An attribute's value, or why there is none: the element has none, or the app did not answer in time.
    enum Got<T> {
        case value(T)
        case none
        case timeout
    }

    static let timeout: Float = 0.15, landTimeout: Float = 0.3
    /// The most text (UTF-16 units) a field may hold to be read at all.
    static let maxField = 20_000
    static let textRoles: Set<String> = [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole]
    static let manualAccessibility = "AXManualAccessibility"
    static let wokenFile = "ax-woken.json"

    /// The Electron apps whose `AXManualAccessibility` neoless set and has not set back (`wokenFile`).
    nonisolated(unsafe) private static var woken = WokenApps()
    /// Whether `woken` is kept on disk (never for snapshots, which ask nothing of anyone).
    nonisolated(unsafe) private static var keeps = false
    /// Chromium browsers whose role was read this launch (that cannot be undone, so it is not noted).
    nonisolated(unsafe) private static var roleRead = Set<pid_t>()
    /// Apps to ask once more although they were asked: the last paste into them could not be read.
    nonisolated(unsafe) private static var again = Set<pid_t>()
    /// When each Electron app's switch was last set, until it is set back: it is not set again within
    /// `askGap`, however often the text is looked for meanwhile (an app may count the requests, and one
    /// "you may stop" must be enough to undo them).
    nonisolated(unsafe) private static var askedAt: [pid_t: TimeInterval] = [:]
    static let askGap: TimeInterval = 5

    // MARK: Asking an app for its accessibility tree

    /// At launch: what an earlier neoless set and did not set back.
    static func load() {
        guard !keeps else { return }
        keeps = true
        woken = AppFiles.read(WokenApps.self, from: wokenFile) ?? WokenApps()
    }

    private static func save() {
        guard keeps else { return }
        if woken.isEmpty { AppFiles.remove(wokenFile) } else { AppFiles.write(woken, to: wokenFile) }
    }

    /// Asks the app to build its accessibility tree, unless it has one. Never `AXEnhancedUserInterface`:
    /// that one also changes how the app's windows behave.
    ///
    /// Electron: `AXManualAccessibility` is set, and only when the app does not say it is on already
    /// (`AccessibilityTreeRequest.decide`): a tree that was there before is someone else's and is neither noted
    /// nor ever switched off by neoless. What is set is noted first (`woken`), whatever the call returns: a
    /// call that timed out may still take effect, and must be set back too. The application's role is not
    /// read: that would also switch on what cannot be switched off.
    ///
    /// Chromium: the tree is built when the application's role is read, once per launch of the browser.
    ///
    /// `whenFocusOwner`: only when the app has the keyboard focus, as far as the system says.
    static func ask(_ asking: Asking, whenFocusOwner: Bool = false) {
        let pid = asking.pid
        if whenFocusOwner, let owner = focusOwner(), owner != pid, owner != ProcessInfo.processInfo.processIdentifier { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, landTimeout)
        let retry = again.remove(pid) != nil
        switch asking.kind {
        case .chromium:
            guard retry || !roleRead.contains(pid) else { return }
            // Readable already: the tree is there.
            if focusReadsAsText(app) { return }
            roleRead.insert(pid)
            _ = copy(app, kAXRoleAttribute)
        case .electron:
            let before: AccessibilityTreeRequest.Before
            switch copy(app, manualAccessibility) {
            case .value(let value):
                if let on = value as? Bool { before = on ? .on : .off } else { before = .unknown }
            case .none: before = .unknown
            case .timeout: before = .busy
            }
            let ours = woken.contains(pid: pid)
            // A field that reads as text means a tree is there, whatever the app says about the switch.
            // Looked at only where it decides something: the app says off or does not say, and neoless has
            // not set the switch itself.
            let readable = (before == .unknown || before == .off) && !ours && focusReadsAsText(app)
            guard AccessibilityTreeRequest.decide(before: before, focusReadsAsText: readable, ours: ours, again: retry) == .ask else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if let last = askedAt[pid], now - last < askGap { return }
            askedAt[pid] = now
            woken.add(WokenApps.App(pid: pid, bundleID: asking.bundleID, launched: asking.launched))
            save()
            _ = AXUIElementSetAttributeValue(app, manualAccessibility as CFString, kCFBooleanTrue)
        }
    }

    /// The last paste into the app could not be read although it was asked: the next dictation asks once more.
    static func askAgain(pid: pid_t) {
        again.insert(pid)
    }

    /// The watch on the app is over: if neoless switched its tree on, it may stop keeping it.
    static func rest(pid: pid_t) {
        // (`again` stays: a paste that could not be read is remembered until the next dictation asks.)
        askedAt[pid] = nil
        guard let app = woken.remove(pid: pid) else { return }
        save()
        setBack(app)
    }

    /// The user switched learning off for these editors.
    static func rest(bundleIDs: Set<String>) {
        for app in woken.apps where bundleIDs.contains(app.bundleID) { rest(pid: app.pid) }
    }

    /// Every app neoless asked may stop (neoless is quitting, 自动学习 was switched off, or a neoless before
    /// this one left them on). The note goes only once all were told: cut short, the next launch does it again.
    static func restAll() {
        for app in woken.apps { setBack(app) }
        woken = WokenApps()
        save()
        roleRead = []
        again = []
        askedAt = [:]
    }

    private static func setBack(_ app: WokenApps.App) {
        // The process id may belong to another app by now.
        let running = NSRunningApplication(processIdentifier: app.pid)
        guard WokenApps.isSame(app, bundleID: running?.bundleIdentifier, launched: running?.launchDate) else { return }
        let element = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        _ = AXUIElementSetAttributeValue(element, manualAccessibility as CFString, kCFBooleanFalse)
    }

    /// The app quit.
    static func forget(pid: pid_t) {
        roleRead.remove(pid)
        again.remove(pid)
        askedAt[pid] = nil
        if woken.remove(pid: pid) != nil { save() }
    }

    /// The app that has the keyboard focus, when the system says: a non-activating panel of another app
    /// (Spotlight, a launcher) takes it without becoming frontmost. No messaging timeout is set on the
    /// system-wide element (that would change every AX call neoless makes); the system answers this itself.
    private static func focusOwner() -> pid_t? {
        guard case .value(let ref) = copy(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute),
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(ref as! AXUIElement, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    /// The app's focused element says what text it holds: its accessibility tree is there.
    private static func focusReadsAsText(_ app: AXUIElement) -> Bool {
        if case .value(let field) = element(app, kAXFocusedUIElementAttribute, timeout: landTimeout), isText(field) { return true }
        return false
    }

    // MARK: Finding the pasted text

    /// Looks for `inserted` in the focused field of the app, or (web editors put focus on something inside
    /// the field) in one of the elements around it. A field is asked how much text it holds before any of
    /// it is read: one over `maxField` (a terminal's scrollback, a long document) is never copied out, and
    /// says so (`.tooLong`), so it is not looked at again for this paste.
    static func land(_ probe: CorrectionObserver.Probe, inserted: String, asking: Asking?) -> Landing {
        // A launcher's panel over this app has the keyboard: the text went there. This app is neither read
        // nor asked for its tree (so every `ask` below is for the app that has the keyboard).
        if PassageLanding.isElsewhere(focusOwner: focusOwner(), target: probe.pid, own: ProcessInfo.processInfo.processIdentifier) {
            return .elsewhere
        }
        let app = AXUIElementCreateApplication(probe.pid)
        AXUIElementSetMessagingTimeout(app, landTimeout)
        let focused: AXUIElement
        switch element(app, kAXFocusedUIElementAttribute, timeout: landTimeout) {
        case .value(let found): focused = found
        case .timeout: return .missing(.slow)
        case .none:
            if let asking { ask(asking) }
            return .missing(.unreadable)
        }
        var miss = LearningLog.Code.unreadable
        var fallback: Landing?
        var node: AXUIElement? = focused
        walk: for _ in 0...4 {
            guard let current = node else { break }
            if isSecure(current) { return .secure }
            if let count = int(current, kAXNumberOfCharactersAttribute), count > maxField {
                // What is around it holds at least as much.
                if miss == .unreadable { miss = .tooLong }
                break walk
            }
            switch text(current) {
            case .value(let value):
                guard value.utf16.count <= maxField else {
                    if miss == .unreadable { miss = .tooLong }
                    break walk
                }
                let caret = range(current, kAXSelectedTextRangeAttribute).map { $0.location + $0.length }
                if let found = PassageLocator.locate(inserted, in: value, caret: caret),
                   let anchor = InsertionAnchor(value: value, passage: found.range) {
                    let landing = Landing.found(Target(pid: probe.pid, element: current, anchor: anchor), found.text)
                    // A text field is the field; anything else that holds the text (a paragraph inside
                    // it) only if no field around it does.
                    if isTextRole(current) { return landing }
                    if fallback == nil { fallback = landing }
                } else {
                    miss = .notFound
                }
            case .timeout:
                if miss == .unreadable { miss = .slow }
            case .none:
                break
            }
            if case .value(let parent) = element(current, kAXParentAttribute, timeout: landTimeout) { node = parent } else { node = nil }
        }
        if let fallback { return fallback }
        if let asking, miss == .unreadable { ask(asking) }
        return .missing(miss)
    }

    // MARK: Watching

    /// One look at the watched field. `front`: its app is in front. With focus in the field it is read as
    /// usual. With focus elsewhere (or another app in front) it is read only when `afar` says a change is
    /// waiting to be compared, and then the field itself, never whatever has the focus. What has the focus
    /// instead is read only when the watched field itself is gone (it no longer answers): then it may be
    /// that field built anew by its page (`refound`), and it is read once to see. While the watched field
    /// still answers, focus has simply moved, and no other field's text is read at all. `elsewhere` is what
    /// had the focus at the last look and was not the field, so the same question is not asked on every look.
    static func read(_ target: Target, last: String, front: Bool, afar: Bool, elsewhere: Element?) -> Look {
        var focused = false
        var other: Element?
        if front {
            let app = AXUIElementCreateApplication(target.pid)
            AXUIElementSetMessagingTimeout(app, timeout)
            switch element(app, kAXFocusedUIElementAttribute, timeout: timeout) {
            case .timeout: return Look(reading: .failed, focused: false, elsewhere: elsewhere)
            case .none: break
            case .value(let element):
                if isSameField(element, target.element) {
                    focused = true
                } else if let elsewhere, CFEqual(element, elsewhere.ref) {
                    other = elsewhere
                } else {
                    // Does the watched field still answer? (Its role: nothing of its text is copied for this.)
                    switch copy(target.element, kAXRoleAttribute) {
                    case .value: break
                    case .timeout: return Look(reading: .failed, focused: false, elsewhere: elsewhere)
                    case .none:
                        if let rebuilt = refound(last, in: element, target: target) { return rebuilt }
                    }
                    other = Element(ref: element)
                }
            }
        }
        func look(_ reading: PassageWatch.Reading, at moved: Target? = nil) -> Look {
            Look(reading: reading, target: moved, focused: focused, elsewhere: other)
        }
        guard focused || afar else { return look(.moved) }
        // No longer a field that may be read.
        if isSecure(target.element) { return look(.lost) }
        let value: String
        switch text(target.element) {
        case .value(let found): value = found
        case .timeout: return look(.failed)
        // From afar: the field is gone (a page built it anew), there is nothing to see until the user is back.
        case .none: return look(focused ? .failed : .moved)
        }
        // A chat app sent the message (some leave a line break behind).
        if value.allSatisfy(\.isWhitespace) { return look(.empty) }
        guard value.utf16.count <= maxField else { return look(.lost) }
        let composing = (range(target.element, "AXMarkedTextRange")?.length ?? 0) > 0
        if let passage = target.anchor.passage(in: value) {
            return look(.passage(passage, composing: composing))
        }
        // The text around the passage changed (the user typed on before or after it): where is it now?
        if let found = PassageLocator.relocate(last, in: value, near: target.anchor.prefixLength),
           let anchor = InsertionAnchor(value: value, passage: found.range) {
            return look(.passage(last, composing: composing),
                        at: Target(pid: target.pid, element: target.element, anchor: anchor))
        }
        return look(.lost)
    }

    /// Focus is on another element. A web page may have built the field anew (the same field to the user, a
    /// new element to Accessibility): if what has focus is a text field that shows the same text, the passage
    /// where it was with the same text before and after it, the watch goes on there. Anything else is focus
    /// having left the field: another field that merely holds the same words somewhere (the document a
    /// search term was dictated for) is text neoless did not type, and editing it teaches nothing.
    private static func refound(_ last: String, in focused: AXUIElement, target: Target) -> Look? {
        guard !isSecure(focused), isTextRole(focused) else { return nil }
        if let count = int(focused, kAXNumberOfCharactersAttribute), count > maxField { return nil }
        guard case .value(let value) = text(focused), value.utf16.count <= maxField,
              target.anchor.passage(in: value) == last else { return nil }
        let composing = (range(focused, "AXMarkedTextRange")?.length ?? 0) > 0
        return Look(reading: .passage(last, composing: composing),
                    target: Target(pid: target.pid, element: focused, anchor: target.anchor), focused: true)
    }

    /// Focus is on the field itself or (web editors) on something up to four levels inside it.
    private static func isSameField(_ focused: AXUIElement, _ field: AXUIElement) -> Bool {
        var node: AXUIElement? = focused
        for _ in 0...4 {
            guard let current = node else { return false }
            if CFEqual(current, field) { return true }
            if case .value(let parent) = element(current, kAXParentAttribute, timeout: timeout) { node = parent } else { node = nil }
        }
        return false
    }

    private static func isSecure(_ e: AXUIElement) -> Bool {
        if case .value(let v) = copy(e, kAXSubroleAttribute), let subrole = v as? String, subrole.lowercased().contains("secure") { return true }
        if case .value(let v) = copy(e, "AXProtectedContent"), (v as? Bool) == true { return true }
        return false
    }

    private static func isTextRole(_ e: AXUIElement) -> Bool {
        if case .value(let v) = copy(e, kAXRoleAttribute), let role = v as? String { return textRoles.contains(role) }
        return false
    }

    /// The element says what text it holds (a text field of an app whose accessibility tree is there).
    private static func isText(_ e: AXUIElement) -> Bool {
        if isTextRole(e) { return true }
        if case .value = text(e) { return true }
        return false
    }

    // MARK: Plumbing

    private static func copy(_ e: AXUIElement, _ attribute: String) -> Got<CFTypeRef> {
        var out: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(e, attribute as CFString, &out)
        if error == .success, let out { return .value(out) }
        return error == .cannotComplete ? .timeout : .none
    }

    private static func element(_ e: AXUIElement, _ attribute: String, timeout: Float) -> Got<AXUIElement> {
        switch copy(e, attribute) {
        case .value(let v):
            guard CFGetTypeID(v) == AXUIElementGetTypeID() else { return .none }
            let found = v as! AXUIElement
            AXUIElementSetMessagingTimeout(found, timeout)
            return .value(found)
        case .none: return .none
        case .timeout: return .timeout
        }
    }

    /// The text an element holds. A password field is never asked (`isSecure` first).
    private static func text(_ e: AXUIElement) -> Got<String> {
        switch copy(e, kAXValueAttribute) {
        case .value(let v):
            if let s = v as? String { return .value(s) }
            if let s = (v as? NSAttributedString)?.string { return .value(s) }
            return .none
        case .none: return .none
        case .timeout: return .timeout
        }
    }

    private static func int(_ e: AXUIElement, _ attribute: String) -> Int? {
        guard case .value(let v) = copy(e, attribute) else { return nil }
        return (v as? NSNumber)?.intValue
    }

    private static func range(_ e: AXUIElement, _ attribute: String) -> CFRange? {
        guard case .value(let v) = copy(e, attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }
}
