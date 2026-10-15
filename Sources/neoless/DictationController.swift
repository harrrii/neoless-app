import AppKit
import Foundation
import NeolessCloud
import NeolessCore

enum Phase: Equatable {
    case idle
    case starting               // waiting for the first audio from the microphone
    case recording
    case transcribing           // speech ended, waiting for the final transcript
    case polishing              // ChatGPT is tidying it up
    case done(String)
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self {
        case .starting, .recording, .transcribing, .polishing: return true
        default: return false
        }
    }
}

/// Record → recognize on this Mac → (optionally) polish with ChatGPT → paste at the cursor. With 用 Neo 处理 the
/// recording goes to the paired Neo, which recognises and polishes it; this Mac's own transcript still drives the
/// live captions, and when the Neo does not answer in time this Mac finishes the dictation itself, as it always
/// did (`HubConnection`, `DictationRequest`).
///
/// The session state lives in `CaptureFlow` (NeolessCore, unit-tested); this class carries out its
/// effects. `phase` is what the capsule, the window and the menu show. A tentative hotkey press
/// (one that may still be a shortcut such as Fn+←) records without changing it, so a quick
/// shortcut shows nothing at all, and until the press can no longer be a shortcut the watch on the
/// last pasted text keeps running; `isCapturing` is the real microphone state. Every async step
/// checks the session id, so a cancelled or superseded dictation can never type anything late. One
/// whose paste was cancelled with Esc still finishes in the background and lands in history (with
/// 保存历史 on) and on the home page (unless a newer dictation got there first, or the user is
/// editing the record shown there).
@MainActor
final class DictationController: ObservableObject {
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 24)
    @Published private(set) var startedAt: Date?
    @Published private(set) var liveText = ""
    /// A short notice about the recording itself (the 10-minute cap is near), shown above the
    /// capsule in place of the live transcript for a few seconds.
    @Published private(set) var notice: String?
    @Published private(set) var deviceName = ""
    /// Hold to talk: the capsule shows the wave alone, without × and ✓ (until the next dictation).
    @Published private(set) var holdToTalk = false
    /// The latest result, shown (and editable) on the home page.
    @Published var current: DictationRecord?
    @Published private(set) var repolishing = false

    /// The shown phase changed, or the capsule style (`holdToTalk`) changed with it.
    var onPhaseChange: ((Phase) -> Void)?
    /// The microphone opened or closed (`isCapturing`), tentative presses included: for the hotkey monitor.
    var onCaptureChange: ((Bool) -> Void)?
    /// Whether Esc belongs to neoless changed (`CaptureFlow.consumesEscape`: the whole dictation,
    /// recognizing and polishing included): for the hotkey monitor.
    var onConsumesEscapeChange: ((Bool) -> Void)?

    let settings: AppSettings
    let history: HistoryStore
    let vocabulary: VocabularyStore
    let account: ChatGPTAccount
    let learning: LearningStore
    let observer: CorrectionObserver
    /// 用 Neo 处理. Nil for snapshots.
    let hub: HubConnection?
    /// 今日概览's counts: every delivered dictation adds to them. Nil for snapshots.
    let usage: UsageStore?
    /// Takes edits of the Neo's dictations to the Neo (set by AppDelegate).
    var hubSync: HubSync?

    /// One dictation from start to delivery.
    private struct Take {
        let id: UUID
        /// The app in front when recording started: for the mode and the polish prompt.
        var appName: String?
        var bundleID: String?
        /// The mode chosen in Settings and the AI-app rule when recording started (the Neo applies them itself).
        var chosenMode: DictationMode
        var autoStructured: Bool
        /// The mode this Mac uses when it does the work itself (`AppSettings.effectiveMode`).
        var mode: DictationMode
        /// The app in front when recording started (neoless itself included).
        var startTarget: PasteTarget?
        /// The only app it may be pasted into: the one in front when recording stopped, or for a
        /// recording that ended on its own, the one it started in (`FinishReason.pastesOnlyWhereStarted`).
        var pasteTarget: PasteTarget?
        /// What had keyboard focus when recording stopped, read off the main thread meanwhile.
        var stopFocus: Task<FocusMark?, Never>?
        /// For the record's note.
        var notes: [String] = []
        /// When the recording was stopped: the wait for the text is counted from here (`DictationTimings.waitMs`).
        var stoppedAt: ContinuousClock.Instant?
    }

    private var flow = CaptureFlow()
    private var session = UUID()
    private var take: Take?
    private var recorder: AudioRecorder?
    private var speech: SpeechSession?
    private var work: Task<Void, Never>?
    /// The recording's tail (`CaptureTiming.tail`); cancelled to end it early.
    private var tail: Task<Void, Never>?
    private var timers: [Task<Void, Never>] = []
    /// Why capture failed, shown once the press turns out to be real.
    private var failure: String?
    /// Watches a recording for a minute without speech, from the first audio. It acts only while
    /// `settings.silenceAutoStop` is on, read when the minute is up.
    private var silence: SilenceWatch?
    /// Takes whose paste was cancelled with Esc during processing, finishing in the background,
    /// with `currentGeneration` at that moment.
    private var detached: [UUID: Int] = [:]
    private var background: [UUID: Task<Void, Never>] = [:]
    /// Bumped whenever a new record becomes `current` and whenever the user edits it, so a detached
    /// take never replaces a newer record, or one being edited.
    private var currentGeneration = 0
    /// A home-page edit not yet written to history, and the timer that writes it.
    private var unsavedEdit: DictationRecord?
    private var saveEdit: Task<Void, Never>?
    /// In-app learning: edits of one record compared with the text it was first shown with.
    private var edits: (recordID: UUID, tracker: EditTracker, events: [LearningEvent])?
    private var learnEdit: Task<Void, Never>?
    /// The ping sent when take `id` became a dictation for good (`checkHub`), and once it came back, whether the
    /// Neo answered: false skips the Neo when the recording stops (this Mac does it all at once); a ping still on
    /// its way is waited for then, for what is left of its own budget.
    private var hubPings: [UUID: Task<Bool, Never>] = [:]
    private var hubReachable: [UUID: Bool] = [:]
    /// Why that ping failed, when it says more than "out of reach" (Cloudflare Access stopped it, 双重锁).
    private var hubPingFailures: [UUID: HubError] = [:]
    /// When the Neo is next asked to get its speech model ready (`warmHub`).
    private var warmGate = HubWarmGate()

    init(settings: AppSettings, history: HistoryStore, vocabulary: VocabularyStore, account: ChatGPTAccount,
         learning: LearningStore, hub: HubConnection? = nil, usage: UsageStore? = nil) {
        self.settings = settings
        self.history = history
        self.vocabulary = vocabulary
        self.account = account
        self.learning = learning
        self.hub = hub
        self.usage = usage
        observer = CorrectionObserver(learning: learning)
        current = history.records.first
        // Load the recognizer at launch so the first dictation does not wait for it.
        SpeechSession.warmUp(localeID: settings.localeID)
    }

    /// The microphone is open: starting or recording, tentative included.
    var isCapturing: Bool { flow.isCapturing }

    // MARK: Commands

    /// A hotkey action. `tentative`: auto and hold styles, where `.start` comes on key-down before
    /// the press may turn out to be a shortcut.
    func handle(_ action: HotkeyAction, tentative: Bool) {
        switch action {
        case .start: send(.start(tentative: tentative))
        case .handsFree: send(.handsFree)
        case .stop: send(.stop)
        case .discard: send(.discard)
        case .escape: send(.escape)
        }
    }

    /// The window's round button, which shows × except while recording: idle → start; starting →
    /// cancel; recording → stop and process; recognizing or polishing → stop the paste and keep the
    /// result (the dictation is never thrown away).
    func toggle() { send(flow.buttonEvent) }

    /// What the menu-bar item offers now: 开始听写, 结束听写 (like ✓) or 取消输入 (like Esc).
    var menuCommand: CaptureFlow.MenuCommand { flow.menuCommand }

    /// The menu-bar item was chosen. Ignored if the dictation moved on while the menu was open.
    func menu(_ command: CaptureFlow.MenuCommand) {
        guard flow.menuCommand == command else { return }
        send(command.event)
    }

    /// ✓ on the capsule. While still starting, it finishes as soon as audio arrives.
    func finishRecording() { send(.confirmClicked) }

    /// × on the capsule, and quitting. While recognizing or polishing only the paste is cancelled.
    func cancel() { send(.cancelClicked) }

    /// Runs the polish step again on the current record's original transcript, in the record's mode.
    /// A 原样转写 record is polished as 自然整理 (asking for polish on it is asking for that) and is
    /// marked 自然整理 afterwards. A dictation the Neo made is polished again there; when the Neo cannot be
    /// reached, here. What the user types into the record meanwhile wins: a result asked for before it never
    /// replaces it.
    func repolishCurrent() {
        guard current != nil, !repolishing else { return }
        repolishing = true
        // What was typed reaches history (and the Neo's outbox) now, and is learned from now.
        settlePendingEdit()
        guard let record = current else {
            repolishing = false
            return
        }
        let mode: DictationMode = record.mode.polishes ? record.mode : .natural
        Task {
            defer { repolishing = false }
            /// The record as it is now, if its text is still what 重新整理 was asked for on.
            @MainActor func unchanged() -> DictationRecord? {
                guard let now = current, now.id == record.id, now.finalText == record.finalText else { return nil }
                return now
            }
            var hubNote: String?
            if let hubID = record.hubID, let client = hub?.dictationClient {
                // An edit of it still waiting would reach the Neo after the new text and replace it there.
                let waiting = await hubSync?.takeEdit(beforeRepolishing: hubID)
                do {
                    let result = try await client.repolish(id: hubID, mode: mode, polishModel: settings.model,
                                                           fastTier: settings.fastTier)
                    hub?.noteReached(client)
                    // Typed into meanwhile: the user's text stays, and reaches the Neo as their next edit.
                    guard var updated = unchanged() else { return }
                    updated.polished = result.polished ? result.text : nil
                    updated.finalText = result.text.isEmpty ? updated.finalText : result.text
                    updated.mode = result.mode
                    updated.model = nil
                    updated.polishSeconds = result.polished ? Double(result.timings.polishMs) / 1000 : updated.polishSeconds
                    updated.note = result.fallback.map { HubDictation.reason($0) }
                    // The wait it timed was for the text this replaces.
                    updated.timings = nil
                    replace(with: updated)
                    return
                } catch is CancellationError {
                    if let waiting { hubSync?.restore(waiting) }
                    return
                } catch {
                    hub?.note(error, from: client)
                    if let waiting { hubSync?.restore(waiting) }
                    hubNote = HubDictation.fallbackNote(error)
                    guard account.isReady else {
                        // Nothing was polished here either: the note says so, after the record's own.
                        if var updated = current, updated.id == record.id {
                            updated.note = Self.note(record.note, adding: HubDictation.notRepolishedNote(error))
                            current = updated
                        }
                        return
                    }
                }
            }
            do {
                let text = try await Polisher.polish(transcript: record.raw, vocabulary: vocabulary.promptWords,
                                                     appName: record.appName, account: account,
                                                     corrections: learning.promptPairs(for: record.raw),
                                                     extras: learning.promptExtras(for: record.raw), mode: mode)
                guard var updated = unchanged() else { return }
                updated.polished = text
                updated.finalText = text
                updated.mode = mode
                updated.model = settings.model
                updated.note = hubNote
                updated.timings = nil
                // Polished here, the Neo's copy no longer matches: its later edits stay here.
                updated.hubID = nil
                replace(with: updated)
            } catch {
                guard var updated = current, updated.id == record.id else { return }
                updated.note = PolishFailure.detail(error)
                current = updated
            }
        }
    }

    /// `note` with `addition` after its parts, without an earlier "…，没有重新整理".
    static func note(_ note: String?, adding addition: String) -> String {
        (RecordNote.parts(note).filter { !$0.hasSuffix(HubDictation.notRepolished) } + [addition]).joined(separator: "；")
    }

    /// The current record polished again: shown, kept, and nothing older about it waits to be saved or learned.
    private func replace(with updated: DictationRecord) {
        saveEdit?.cancel()
        saveEdit = nil
        unsavedEdit = nil
        learnEdit?.cancel()
        learnEdit = nil
        current = updated
        edits = nil
        history.update(updated)
    }

    /// Whether 重新整理 can work for `record`: on the Neo for its own dictations (unless it is known to be out of
    /// reach), else with this Mac's login.
    func canRepolish(_ record: DictationRecord) -> Bool {
        if account.isReady { return true }
        guard record.hubID != nil, let hub, hub.dictationClient != nil else { return false }
        if case .unreachable = hub.status { return false }
        return true
    }

    /// Home-page edits are saved to history shortly after typing stops, and learned from once they settle.
    func editCurrent(_ text: String) {
        guard var record = current, record.finalText != text else { return }
        // Edits made while 自动学习 is off are never learned: tracking restarts from the text at re-enable.
        if !learning.enabled { edits = nil }
        else if edits?.recordID != record.id { edits = (record.id, EditTracker(original: record.finalText), []) }
        record.finalText = text
        current = record
        // A take finishing in the background no longer replaces this record (see `deliver`).
        currentGeneration += 1
        // The record as edited, not whatever `current` is when the timer fires.
        unsavedEdit = record
        saveEdit?.cancel()
        saveEdit = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveUnsavedEdit()
        }
        learnEdit?.cancel()
        guard learning.enabled else { return }
        learnEdit = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.learnFromEdit()
        }
    }

    /// Writes a pending home-page edit to history now. The Neo keeps the text of its own dictation too (only the
    /// text: what it teaches goes to the Neo as this Mac learns it, `HubSync`).
    private func saveUnsavedEdit() {
        saveEdit?.cancel()
        saveEdit = nil
        guard let record = unsavedEdit else { return }
        unsavedEdit = nil
        history.update(record)
        if let hubID = record.hubID { hubSync?.edited(hubID, text: record.finalText) }
    }

    /// An edit still settling is saved and learned from now (before something replaces the text).
    private func settlePendingEdit() {
        saveUnsavedEdit()
        guard learnEdit != nil else { return }
        learnEdit?.cancel()
        learnEdit = nil
        learnFromEdit()
    }

    private func learnFromEdit() {
        guard learning.enabled, let record = current, var session = edits, session.recordID == record.id,
              (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        // A word learned alone that the text no longer shows was taken back, or was half of a name typed with
        // a pause: what taught it is undone, and the tracker compares again from before it.
        let gone = Set(session.tracker.withdrawn(from: record.finalText).map { $0.lowercased() })
        if !gone.isEmpty {
            for event in session.events.reversed() where event.aloneWords.contains(where: { gone.contains($0.lowercased()) }) {
                learning.undo(event)
                session.events.removeAll { $0.id == event.id }
            }
        }
        // What the text shows now that could be a habit (a stop taken off, a filler deleted), for the offer
        // on the dictionary page. Compared with the text as delivered, whatever the step below says.
        learning.notePatterns(original: session.tracker.original, edited: record.finalText, recordID: record.id, app: nil)
        switch session.tracker.settle(record.finalText) {
        case .none:
            // Only deleting teaches nothing: said (in the log), so it is not a silence.
            if session.tracker.removesOnly(record.finalText) {
                learning.noteNothing(.removedOnly, source: .inApp, recordID: record.id, app: nil)
            }
        case .retract:
            for event in session.events.reversed() { learning.undo(event) }
            session.events = []
        case let .extract(inserted, edited):
            let id = record.id
            // The dictionary goes along, as for edits made in other apps: a fix towards one of its words is
            // easier to accept (claude → Claude).
            let known = learning.knownTerms
            Task { [weak self] in
                let found = await Task.detached(priority: .utility) {
                    CorrectionExtractor().extract(inserted: inserted, edited: edited, knownTerms: known)
                }.value
                guard let self, self.edits?.recordID == id, self.learning.enabled else { return }
                // Only a step that taught something moves the baseline, and only by the stretches it learned from
                // (a swap that is only remembered moves nothing: it is compared again with what was delivered).
                if found.teaches {
                    self.edits?.tracker.commit(edited, over: inserted, understood: found.baseline, alone: found.alone)
                }
                // What it taught, or why it taught nothing (kept in the log; said once when a term was being fixed).
                let events = self.learning.learn(found, source: .inApp, recordID: id, app: nil, earlier: self.edits?.events ?? [])
                self.edits?.events += events
            }
        }
        edits = session
    }

    // MARK: Session

    /// Feeds the flow and carries out what it asks for, in order.
    private func send(_ event: CaptureFlow.Event) {
        let wasCapturing = flow.isCapturing, wasConsuming = flow.consumesEscape
        for effect in flow.handle(event) { perform(effect) }
        if flow.isCapturing != wasCapturing { onCaptureChange?(flow.isCapturing) }
        if flow.consumesEscape != wasConsuming { onConsumesEscapeChange?(flow.consumesEscape) }
    }

    private func perform(_ effect: CaptureFlow.Effect) {
        switch effect {
        case .beginCapture: beginCapture()
        case .reveal(let kind):
            holdToTalk = kind == .hold
            set(flow.stage == .recording ? .recording : .starting)
        case .restyle(let kind):
            holdToTalk = kind == .hold
            set(phase)
        case .showRecording:
            if phase == .starting { set(.recording) }
        case .commit:
            // A dictation for good (no longer a possible Fn+← or Fn+Delete): it ends the watch on the last one,
            // which first looks at the field once more, so a word fixed just before this press is still learned.
            observer.finish(.newDictation)
            // An app whose fields can be read only once it is asked (Chromium, Electron) is asked now, while the
            // user speaks, so the text can be found in it when it lands. Not before: a press that turns out to be
            // a shortcut asks nothing of anyone.
            observer.prepare(for: NSWorkspace.shared.frontmostApplication)
            checkHub()
        case .armLateStop:
            after(CaptureTiming.lateStopLimit) { $0.send(.lateStopElapsed) }
        case .finish(let reason): finishCapture(reason)
        case .discard:
            closeCapture()
            // A shortcut found out after the capsule showed (a hold, then ←): it just goes away.
            if phase == .starting || phase == .recording { set(.idle) }
        case .cancel:
            closeCapture()
            set(.cancelled)
        case .fail:
            closeCapture()
            set(.failed(failure ?? "麦克风出错"))
        case .nobodySpoke:
            closeCapture()
            set(.failed(CaptureText.nobodySpoke))
        case .keepWithoutPaste: keepWithoutPaste()
        }
    }

    private func beginCapture() {
        let id = UUID()
        session = id
        work?.cancel()
        work = nil
        failure = nil
        let front = NSWorkspace.shared.frontmostApplication
        let own = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let bundleID = own ? nil : front?.bundleIdentifier
        let appName = own ? nil : front?.localizedName
        take = Take(id: id, appName: appName, bundleID: bundleID, chosenMode: settings.mode,
                    autoStructured: settings.autoStructuredForAI,
                    mode: settings.effectiveMode(forBundleID: bundleID, appName: appName),
                    startTarget: TextInserter.currentTarget())
        silence = nil
        if flow.tentative {
            after(CaptureTiming.holdResolve) { $0.send(.holdElapsed) }
            after(CaptureTiming.shortcutWindow) { $0.send(.shortcutWindowElapsed) }
        }
        after(CaptureTiming.capWarning) { $0.showNotice(CaptureText.nearCap) }
        after(CaptureTiming.maxRecording) { $0.send(.capReached) }
        // Harmless while tentative: nothing shows the feeds until the phase does.
        resetFeeds()
        work = Task { [weak self] in await self?.begin(id) }
    }

    private func resetFeeds() {
        liveText = ""
        notice = nil
        startedAt = nil
        levels = Array(repeating: 0, count: levels.count)
    }

    /// Shows `text` above the capsule for `CaptureTiming.noticeDuration` (only while recording).
    private func showNotice(_ text: String) {
        notice = text
        after(CaptureTiming.noticeDuration) { $0.notice = nil }
    }

    /// Runs `body` after `seconds` if this capture is still the current one.
    private func after(_ seconds: TimeInterval, _ body: @escaping (DictationController) -> Void) {
        let id = session
        timers.append(Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.session == id else { return }
            body(self)
        })
    }

    private func cancelTimers() {
        timers.forEach { $0.cancel() }
        timers = []
    }

    /// Closes the microphone and drops the capture (discard, cancel, failure).
    private func closeCapture() {
        cancelTimers()
        hubPings[session] = nil
        hubReachable[session] = nil
        hubPingFailures[session] = nil
        session = UUID()
        take = nil
        silence = nil
        notice = nil
        work?.cancel()
        work = nil
        recorder?.stop()
        recorder = nil
        speech?.cancel()
        speech = nil
    }

    /// Recording ended with something to process: keep the tail, then recognize and deliver.
    private func finishCapture(_ reason: FinishReason) {
        guard var take, let recorder else {
            // Defensive: the flow says recording, but nothing is open.
            send(.delivered)
            set(.failed(failure ?? "麦克风出错"))
            return
        }
        cancelTimers()
        silence = nil
        notice = nil
        // The app to paste into: the one in front now, as the recording stops. A recording that
        // ended on its own goes only where it started: the user may have walked away or moved on.
        take.pasteTarget = reason.pastesOnlyWhereStarted ? (take.startTarget ?? TextInserter.currentTarget())
            : TextInserter.currentTarget()
        // Which field: read now, compared when pasting (another chat, the address bar, Spotlight…).
        take.stopFocus = TextInserter.markFocus()
        if let note = reason.note { take.notes.append(note) }
        take.stoppedAt = ContinuousClock.now
        self.take = take
        let id = session
        let speech = self.speech
        self.recorder = nil
        self.speech = nil
        set(.transcribing)
        let wait = CaptureTiming.tail(for: reason)
        let tail = Task {
            guard wait > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        self.tail = tail
        work = Task { [weak self] in
            await tail.value
            recorder.stop()
            guard let self, self.keeps(id) else { speech?.cancel(); return }
            let samples = recorder.recordedSamples()
            let duration = recorder.duration
            let finishing = LocalTranscript(speech: speech)
            let transcriptDeadline = Date().addingTimeInterval(CaptureTiming.hubTranscriptWait)
            // 用 Neo 处理: the recording is encoded while this Mac's recognizer finishes and the ping comes back. With
            // 本机识别 it is not: this Mac's transcript goes alone, and the recording only when that cannot stand alone.
            let tries = self.hubReachable[id] != false && self.hub?.dictationClient != nil
            let textFirst = tries && self.hub?.recognizesHere == true
            let upload = tries && !textFirst ? Task.detached(priority: .userInitiated) { AudioUpload.encode(samples) } : nil
            let neo = tries ? await self.hubClient(for: id) : nil
            guard self.keeps(id) else { return }
            var take = take
            // A call to the Neo this Mac waited for, and then did the work without (`DictationTimings.neoWaitMs`).
            var neoWait: Int?
            if let neo {
                // This Mac's transcript as it would use it, without a second look at the recording: one whose live
                // session restarted or lost audio is not handed over, so the Neo cannot type half of it.
                let hasSpeech = AudioMath.hasSpeech(samples)
                let whole: (String) -> Bool = { text in
                    SecondPass.budget(live: text, diedEarly: speech?.diedEarly == true, lostAudio: speech?.lostAudio == true,
                                      hasSpeech: hasSpeech, audioSeconds: duration) == nil
                }
                var outcome: HubOutcome?
                // 本机识别: this Mac's final transcript, when it could not stand alone.
                var turnedDown: String?
                if textFirst {
                    // 本机识别: once this Mac's transcript is final, it is what the Neo polishes. Missing, or too short
                    // for the recording (`LocalRecognition.usable`), or one this Mac would look at again: the recording
                    // goes to the Neo after all, as it would without the choice.
                    let heard = await finishing.value
                    guard self.keeps(id) else { return }
                    if LocalRecognition.usable(heard, audioSeconds: duration), whole(heard) {
                        outcome = await self.viaHubText(neo, text: heard, duration: duration, take: take)
                    } else {
                        turnedDown = heard
                    }
                }
                if outcome == nil {
                    let encoding = upload ?? Task.detached(priority: .userInitiated) { AudioUpload.encode(samples) }
                    // The request carries this Mac's transcript when it is ready in time; the Neo does not wait for it.
                    // Not one 本机识别 just turned down: the hub would polish it in place of the Neo's once its short
                    // wait for a transcript that can stand in is over, and with 本机识别 the Neo's model is cold (no
                    // warm-up). Without it the Neo hears the recording with all the time that takes; should it hear
                    // nothing, that transcript still follows to `/v1/polish` (`HubDictation.next`).
                    let early = textFirst ? nil
                        : await finishing.value(within: max(0, transcriptDeadline.timeIntervalSinceNow))
                    guard self.keeps(id) else { return }
                    // Silence that nothing here made words of is not worth sending.
                    if hasSpeech || (early ?? turnedDown)?.isEmpty == false {
                        outcome = await self.viaHub(neo, audio: await encoding.value, early: early, local: finishing,
                                                    whole: whole, duration: duration, take: take)
                    }
                }
                switch outcome {
                case .delivered?: return
                case .fallback(let note, let waited)?:
                    guard self.keeps(id) else { return }
                    if let note { take.notes.append(note) }
                    neoWait = waited
                case nil: break
                }
            } else if let note = self.hubSkipNote(id) {
                take.notes.append(note)
            }
            var raw = await finishing.value
            guard self.keeps(id) else { return }
            let diedEarly = speech?.diedEarly == true
            let lostAudio = speech?.lostAudio == true
            var secondWon = false, secondComplete = false
            if let budget = SecondPass.budget(live: raw, diedEarly: diedEarly, lostAudio: lostAudio,
                                              hasSpeech: AudioMath.hasSpeech(samples), audioSeconds: duration) {
                let again = await SpeechSession.recognize(samples: samples, localeID: self.settings.localeID,
                                                          hints: self.vocabulary.recognizerHints, timeout: budget)
                guard self.keeps(id) else { return }
                let chosen = SecondPass.choose(live: raw, second: again.text, liveDiedEarly: diedEarly || lostAudio)
                secondWon = chosen != raw
                secondComplete = again.complete
                raw = chosen
            }
            if SecondPass.incomplete(lostAudio: lostAudio, secondWon: secondWon, secondComplete: secondComplete) {
                take.notes.append(CaptureText.incomplete)
            }
            guard !raw.isEmpty else {
                let why = speech?.errorDescription.map { "识别出错：\($0)" }
                self.finished(id, .failed(why ?? (AudioMath.hasSpeech(samples) ? "没有识别出文字，请再说一次" : "没有听到声音，请检查麦克风")))
                return
            }
            await self.deliver(raw: raw, duration: duration, take: take, neoWaitMs: neoWait)
        }
    }

    /// Whether take `id` should keep going: still the current one, or detached by Esc.
    private func keeps(_ id: UUID) -> Bool { session == id || detached[id] != nil }

    /// Processing of take `id` is over. Shown only if it still is the current take.
    private func finished(_ id: UUID, _ phase: Phase) {
        hubPings[id] = nil
        hubReachable[id] = nil
        hubPingFailures[id] = nil
        if detached.removeValue(forKey: id) != nil {
            background[id] = nil
            return
        }
        guard session == id else { return }
        take = nil
        work = nil
        send(.delivered)
        set(phase)
    }

    /// Esc or × while recognizing or polishing: the take finishes in the background without pasting.
    private func keepWithoutPaste() {
        let id = session
        detached[id] = currentGeneration
        background[id] = work
        work = nil
        // A new dictation may start now; the tail of this one ends at once.
        tail?.cancel()
        tail = nil
        session = UUID()
        take = nil
        set(.done(DoneText.pasteCancelled(keepHistory: settings.keepHistory)))
    }

    // MARK: Steps

    private func begin(_ id: UUID) async {
        if Permissions.microphone == .notDetermined { _ = await Permissions.requestMicrophone() }
        guard session == id else { return }
        guard Permissions.microphone == .authorized else {
            return captureFailed("需要麦克风权限：系统设置 › 隐私与安全性 › 麦克风")
        }
        if Permissions.speech == .notDetermined { _ = await Permissions.requestSpeech() }
        guard session == id else { return }
        guard Permissions.speech == .authorized else {
            return captureFailed("需要语音识别权限：系统设置 › 隐私与安全性 › 语音识别")
        }
        let speech: SpeechSession
        do {
            speech = try await SpeechSession.prepare(localeID: settings.localeID, hints: vocabulary.recognizerHints)
        } catch {
            guard session == id else { return }
            return captureFailed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        guard session == id else { return }
        speech.onPartial = { [weak self] text in
            guard let self, self.session == id else { return }
            self.liveText = text
        }
        speech.start()

        let recorder = AudioRecorder()
        recorder.onBuffer = { [weak speech] buffer in speech?.append(buffer) }
        recorder.onLevel = { [weak self] level in
            guard let self, self.session == id else { return }
            self.levels.removeFirst()
            self.levels.append(level)
            if var watch = self.silence {
                let quiet = watch.level(level, at: ProcessInfo.processInfo.systemUptime)
                self.silence = watch
                // 静音一分钟自动结束 off: the recording runs until the user stops it (or the 10-minute cap).
                if quiet, self.settings.silenceAutoStop { self.send(.silenceElapsed(heardSpeech: watch.heardSpeech)) }
            }
        }
        recorder.onFirstAudio = { [weak self] in
            guard let self, self.session == id, self.flow.stage == .starting else { return }
            self.startedAt = Date()
            self.silence = SilenceWatch(startedAt: ProcessInfo.processInfo.systemUptime)
            self.send(.audioArrived)
        }
        recorder.onDeviceChange = { [weak self] name in
            guard let self, self.session == id else { return }
            self.deviceName = name
        }
        recorder.onFailure = { [weak self, weak recorder] failure in
            guard let self, self.session == id, let recorder, self.recorder === recorder, self.flow.isCapturing else { return }
            self.failure = failure.errorDescription ?? "麦克风出错"
            self.send(.captureFailed(heardSignal: recorder.heardSignal))
        }
        self.speech = speech
        self.recorder = recorder
        do {
            try recorder.start(preference: settings.microphoneUID)
            deviceName = recorder.deviceName
        } catch {
            captureFailed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// The microphone or recognizer could not start: nothing was recorded.
    private func captureFailed(_ message: String) {
        recorder?.stop()
        recorder = nil
        speech?.cancel()
        speech = nil
        failure = message
        send(.captureFailed(heardSignal: false))
    }

    /// What a take turned into, before it is typed.
    private struct Produced {
        var raw: String
        var final: String
        var polished: String?
        var polishSeconds: TimeInterval?
        var model: String?
        var mode: DictationMode
        /// Why the text is not polished, in a few words for the capsule ("整理超时").
        var reason: String?
        var hubID: UUID?
        var recognizer: String?
        /// The Neo's timings and this Mac's call for them; the wait itself is added as the text is typed.
        var timings = DictationTimings()
    }

    /// This Mac does the work: polish with its own ChatGPT login (in a mode that polishes), then type. `neoWaitMs`: how
    /// long a call to the Neo was waited for first, whose answer was not used.
    private func deliver(raw: String, duration: TimeInterval, take: Take, neoWaitMs: Int? = nil) async {
        let id = take.id
        let mode = take.mode
        var final = raw
        var polished: String?
        var polishSeconds: TimeInterval?
        var notes = take.notes
        var reason: String?

        if mode.polishes {
            if session == id { set(.polishing) }
            let started = Date()
            do {
                // No timeout of our own: Polisher's budget grows with the transcript.
                let text = try await Polisher.polish(transcript: raw, vocabulary: vocabulary.promptWords,
                                                     appName: take.appName, account: account,
                                                     corrections: learning.promptPairs(for: raw),
                                                     extras: learning.promptExtras(for: raw), mode: mode)
                polished = text
                final = text
                polishSeconds = Date().timeIntervalSince(started)
            } catch {
                // Details (and any error code) go to History; the HUD gets a few plain words.
                notes.append(PolishFailure.detail(error))
                reason = PolishFailure.short(error)
            }
            guard keeps(id) else { return }
        }
        // Typed as is (原样转写, or the original after a failed polish): apply what the user confirmed.
        if polished == nil { final = learning.applyConfirmed(raw) }
        await typeAndKeep(Produced(raw: raw, final: final, polished: polished, polishSeconds: polishSeconds,
                            model: polished == nil ? nil : settings.model, mode: mode, reason: reason,
                            timings: DictationTimings(neoWaitMs: neoWaitMs)),
                   notes: notes, duration: duration, take: take)
    }

    /// Types what the take turned into where it may go, keeps the record and ends the take.
    private func typeAndKeep(_ produced: Produced, notes: [String], duration: TimeInterval, take: Take) async {
        let id = take.id
        let final = produced.final
        var notes = notes
        var delivery = Delivery.notInserted
        var message = ""
        var capture = CorrectionObserver.Capture.skip
        if session == id {
            capture = await observer.capture(inserting: final)
        }
        if session == id {
            let mark = await take.stopFocus?.value
            let plan = await TextInserter.plan(for: take.pasteTarget, since: mark, restoreClipboard: settings.restoreClipboard)
            // Esc may have come while planning: then nothing is pasted.
            if session == id {
                let inserted = TextInserter.perform(plan, text: final)
                delivery = inserted.delivery
                message = inserted.message
                if let detail = inserted.detail { notes.append(detail) }
            }
        }
        guard keeps(id) else { return }
        let pastedLive = session == id
        if !pastedLive { notes.append(RecordNote.pasteCancelled) }
        if let reason = produced.reason {
            message = delivery == .pasted ? FailureText.typedRaw(reason: reason) : "\(message) · \(reason)"
        }

        var timings = produced.timings
        if let stopped = take.stoppedAt { timings.waitMs = DictationTimings.milliseconds(ContinuousClock.now - stopped) }
        let record = DictationRecord(duration: duration, raw: produced.raw, polished: produced.polished, finalText: final,
                                     appName: take.appName, mode: produced.mode, model: produced.model,
                                     polishSeconds: produced.polishSeconds,
                                     note: notes.isEmpty ? nil : notes.joined(separator: "；"),
                                     delivery: delivery, hubID: produced.hubID, recognizer: produced.recognizer,
                                     timings: timings)
        if settings.keepHistory { history.add(record) }
        // Counted whether or not it is kept: the overview's numbers do not depend on 保存历史. Text that
        // reached nowhere (`.notInserted`) is left out by the stats themselves.
        usage?.add(record)
        if pastedLive {
            show(record)
            if delivery == .pasted {
                observer.begin(capture, inserted: final, recordID: record.id, appName: take.appName)
            }
        } else if detached[id] == currentGeneration {
            // Cancelled with Esc: on the home page too, unless a newer dictation got there first
            // (with history off it is then gone, which is why the Esc message promises no place).
            show(record)
        }
        finished(id, .done(message))
    }

    // MARK: 用 Neo 处理

    private enum HubOutcome {
        /// The Neo's text was typed (or the take is over).
        case delivered
        /// This Mac does it itself, with this quiet note for the record (nil: nothing worth saying), after waiting
        /// `waitedMs` for the Neo (`DictationTimings.neoWaitMs`).
        case fallback(String?, waitedMs: Int)
    }

    /// The Neo's client for take `id`, or nil when this Mac does it itself: the Neo is not in use, or the ping sent
    /// when the press became a dictation did not come back. A ping still on its way (a short press, or a Neo that
    /// does not answer) is waited for, for what is left of its own budget (`HubTimeouts.ping`): a Neo out of reach
    /// then costs at most that, not a new probe of its own on top (`HubClient` gives every dictation one).
    private func hubClient(for id: UUID) async -> HubClient? {
        guard let client = hub?.dictationClient else { return nil }
        if let reached = hubReachable[id] { return reached ? client : nil }
        guard let ping = hubPings[id] else { return client }
        return await ping.value ? hub?.dictationClient : nil
    }

    /// 用 Neo 处理: finds out while the user speaks whether the Neo answers (`GET /v1/ping`), so a sleeping Neo
    /// costs little once the recording stops. Only once the press is a dictation for good (at once for a click or
    /// a toggle press; for Fn tap and hold on release or after `CaptureTiming.shortcutWindow`): a shortcut such as
    /// Fn+← sends nothing.
    private func checkHub() {
        guard let client = hub?.dictationClient else { return }
        let id = session
        hubPings[id] = Task { [weak self] in
            var refused: HubError?
            let reached: Bool
            do {
                _ = try await client.ping()
                reached = true
            } catch {
                // Cloudflare Access turning this Mac away is said as such, not as a Neo out of reach.
                if error as? HubError == .accessDenied { refused = .accessDenied }
                reached = false
            }
            guard let self else { return reached }
            if self.hubPings[id] != nil {
                self.hubReachable[id] = reached
                self.hubPingFailures[id] = refused
            }
            if reached { self.hub?.noteReached(client) } else { self.hub?.note(refused ?? HubError.unreachable, from: client) }
            return reached
        }
        warmHub(client)
    }

    /// 用 Neo 处理: asks the Neo, alongside the ping, to get the speech model this dictation will use ready
    /// (`POST /v1/warm`), so the recording does not wait for it to load once the user stops: after ten idle minutes
    /// the Neo has unloaded it, and loading it again takes seconds. At most once in `Hub.warmInterval`
    /// (`HubWarmGate`), and not with 本机识别. Fire and forget: whatever happens to it (an old hub's 404, a Neo out of
    /// reach, Cloudflare) changes nothing else; the ping says what is known about the Neo.
    private func warmHub(_ client: HubClient) {
        // 本机识别: the Neo polishes this Mac's text and does not hear the recording; its model stays as it is.
        guard hub?.recognizesHere != true, warmGate.take(at: ProcessInfo.processInfo.systemUptime) else { return }
        let model = hub?.askedModel
        Task { [weak self] in
            guard let supported = try? await client.warm(model: model) else { return }
            self?.warmGate.answered(supported: supported, at: ProcessInfo.processInfo.systemUptime)
        }
    }

    /// The note for a take that did not go to the Neo because the ping found it out of reach, or found Cloudflare
    /// Access turning this Mac away (the Neo then gets no more takes until it lets it through: `dictationClient`).
    private func hubSkipNote(_ id: UUID) -> String? {
        guard hubReachable[id] == false, hub?.isActive == true,
              hub?.dictationClient != nil || hubPingFailures[id] == .accessDenied else { return nil }
        return HubDictation.fallbackNote(hubPingFailures[id] ?? HubError.unreachable)
    }

    /// Sends the recording to the Neo and types its text. Gives up after the call's own budget (it grows with the
    /// recording, `HubTimeouts.interactive`): then this Mac carries on with its own transcript and whatever the
    /// Neo sends later is ignored. `early`: this Mac's transcript if it was ready when the upload started;
    /// `whole`: whether this Mac would use a transcript as it is (no second look at the recording first).
    private func viaHub(_ client: HubClient, audio: EncodedAudio, early: String?, local: LocalTranscript,
                        whole: (String) -> Bool, duration: TimeInterval, take: Take) async -> HubOutcome {
        let id = take.id
        if take.mode.polishes, session == id { set(.polishing) }
        let handed = early.flatMap { !$0.isEmpty && whole($0) ? $0 : nil }
        // 识别模型: the choice, on a Neo that has both models. Asking for the large one means waiting for it: this
        // Mac's transcript stays here and the call gets a longer budget (`DictationRequest.asking`). 整理模型 and
        // 快速模式 go along, so the Neo polishes as this Mac would (and so does a `/v1/polish` that follows).
        let request = DictationRequest(mode: take.chosenMode, autoStructured: take.autoStructured, appName: take.appName,
                                       bundleID: take.bundleID, locale: settings.localeID,
                                       localTranscript: handed, durationSeconds: duration,
                                       clientRecordingID: id, client: .mac, clientVersion: AppVersion.current,
                                       polishModel: settings.model, fastTier: settings.fastTier)
            .asking(for: hub?.askedModel)
        // A guard around the client's own budget, should anything in it hang: the budget, and the time a resend
        // after a dropped connection is given on top (`HubTimeouts.resend`).
        let timeouts = client.timeouts
        let budget = timeouts.dictation(durationSeconds: duration, audioBytes: audio.data.count, patient: request.waitsForNeo)
            + timeouts.resend(bytes: audio.data.count) + 5
        let result: DictationResult
        // How long the call whose answer is used took, sending included; and the one before it, when that answer was
        // not used (`DictationTimings.neoWaitMs`).
        var requestMs: Int?
        var unusedMs: Int?
        let began = ContinuousClock.now
        func since(_ start: ContinuousClock.Instant) -> Int { DictationTimings.milliseconds(ContinuousClock.now - start) }
        do {
            var answer: DictationResult
            var sent = began
            do {
                answer = try await withTimeout(seconds: budget) { try await client.dictate(audio, request: request) }
            } catch let error where HubDictation.transcriptFollows(error, request: request) {
                // The Neo could not recognise at all, and this Mac's transcript was held back for the large model:
                // it follows now and the Neo polishes it, as it would have had it come along.
                let heard = await local.value
                guard !heard.isEmpty, whole(heard) else { throw error }
                let polish = request.polishRequest(text: heard)
                let budget = timeouts.polish(characters: polish.text.count) + timeouts.resend(bytes: 0) + 5
                unusedMs = since(began)
                sent = ContinuousClock.now
                answer = try await withTimeout(seconds: budget) { try await client.polish(polish) }
            }
            requestMs = since(sent)
            // Heard nothing: had the request carried this Mac's transcript, the Neo would have used it (it may
            // have been left out of the header, or not been ready), so it follows under the same recording id.
            // One this Mac would look at again is left to this Mac's own path, second look included.
            var heard = answer.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? await local.value : ""
            if !heard.isEmpty, !whole(heard) { heard = "" }
            switch HubDictation.next(answer, request: request, localTranscript: heard) {
            case .use: break
            case .nothingHeard:
                hub?.noteReached(client)
                // Nothing here either (or nothing to hand over); this Mac's own look at the recording may find words.
                return .fallback(nil, waitedMs: since(began))
            case .polish(let polish):
                let budget = timeouts.polish(characters: polish.text.count) + timeouts.resend(bytes: 0) + 5
                unusedMs = since(began)
                let followed = ContinuousClock.now
                answer = try await withTimeout(seconds: budget) { try await client.polish(polish) }
                requestMs = since(followed)
            }
            result = answer
        } catch is CancellationError where Task.isCancelled {
            return .delivered
        } catch {
            // A cancellation this take did not ask for (something on the way ended the request) is a failed call.
            let error = error is CancellationError ? HubError.connectionLost : error
            hub?.note(error, from: client)
            return .fallback(HubDictation.fallbackNote(error), waitedMs: since(began))
        }
        hub?.noteReached(client)
        guard keeps(id) else { return .delivered }
        await deliverHub(result, requestMs: requestMs, neoWaitMs: unusedMs, duration: duration, take: take)
        return .delivered
    }

    /// 本机识别 (`NeoModelChoice.local`): this Mac's final transcript goes to the Neo as text (`POST /v1/polish`,
    /// which every hub has), and the recording is not sent. The Neo polishes it as it polishes what it heard itself
    /// (the mode and the AI-app rule, the dictionary, the corrections it learned, 我的习惯) and keeps it in its history
    /// under this take's id, so 重新整理 and edits go there as for any of its dictations. Gives up after the call's
    /// own budget: then this Mac polishes the same transcript itself, as when the Neo cannot be reached.
    private func viaHubText(_ client: HubClient, text: String, duration: TimeInterval, take: Take) async -> HubOutcome {
        let id = take.id
        if take.mode.polishes, session == id { set(.polishing) }
        let request = PolishRequest(text: text, mode: take.chosenMode, autoStructured: take.autoStructured,
                                    appName: take.appName, bundleID: take.bundleID, clientRecordingID: id, client: .mac,
                                    clientVersion: AppVersion.current, durationSeconds: duration,
                                    polishModel: settings.model, fastTier: settings.fastTier)
        let timeouts = client.timeouts
        let budget = timeouts.polish(characters: text.count) + timeouts.resend(bytes: 0) + 5
        let result: DictationResult
        let sent = ContinuousClock.now
        func waited() -> Int { DictationTimings.milliseconds(ContinuousClock.now - sent) }
        do {
            result = try await withTimeout(seconds: budget) { try await client.polish(request) }
        } catch is CancellationError where Task.isCancelled {
            return .delivered
        } catch {
            // A cancellation this take did not ask for (something on the way ended the request) is a failed call.
            let error = error is CancellationError ? HubError.connectionLost : error
            hub?.note(error, from: client)
            return .fallback(HubDictation.fallbackNote(error), waitedMs: waited())
        }
        hub?.noteReached(client)
        guard keeps(id) else { return .delivered }
        // Nothing to polish after all (the Neo trims it to nothing): this Mac's own path has the last word.
        guard !result.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .fallback(nil, waitedMs: waited())
        }
        await deliverHub(result, requestMs: waited(), duration: duration, take: take)
        return .delivered
    }

    /// Types the Neo's answer and keeps it, with its timings, how long `requestMs` the call for it took, and how long
    /// `neoWaitMs` a call before it whose answer was not used. When the Neo typed the original (its ChatGPT did not
    /// polish), this Mac's own login polishes it, as it would without the Neo.
    private func deliverHub(_ result: DictationResult, requestMs: Int?, neoWaitMs: Int? = nil, duration: TimeInterval,
                            take: Take) async {
        let id = take.id
        var notes = take.notes
        let timings = DictationTimings(result.timings, requestMs: requestMs, neoWaitMs: neoWaitMs)
        if let fallback = result.fallback, result.mode.polishes, account.isReady, !result.raw.isEmpty {
            // The Neo typed the original (its ChatGPT did not polish): this Mac's own login polishes it, as it would
            // without the Neo. Polished here, the Neo's copy no longer matches, so the record keeps no Neo id.
            let started = Date()
            if let text = try? await Polisher.polish(transcript: result.raw, vocabulary: vocabulary.promptWords,
                                                     appName: take.appName, account: account,
                                                     corrections: learning.promptPairs(for: result.raw),
                                                     extras: learning.promptExtras(for: result.raw), mode: result.mode) {
                guard keeps(id) else { return }
                notes.append(HubDictation.polishedHereNote(fallback))
                await typeAndKeep(Produced(raw: result.raw, final: text, polished: text,
                                           polishSeconds: Date().timeIntervalSince(started), model: settings.model,
                                           mode: result.mode, reason: nil, hubID: nil, recognizer: result.recognizer.rawValue,
                                           timings: timings),
                                  notes: notes, duration: duration, take: take)
                return
            }
            guard keeps(id) else { return }
        }
        // The Neo typed the original: why goes with the record, as when this Mac's polish fails.
        let reason = result.fallback.map { HubDictation.reason($0) }
        if let reason { notes.append(reason) }
        let text = result.text.isEmpty ? result.raw : result.text
        await typeAndKeep(Produced(raw: result.raw, final: text, polished: result.polished ? text : nil,
                                   polishSeconds: result.polished ? Double(result.timings.polishMs) / 1000 : nil,
                                   model: nil, mode: result.mode, reason: reason,
                                   hubID: result.id, recognizer: result.recognizer.rawValue, timings: timings),
                          notes: notes, duration: duration, take: take)
    }

    private func show(_ record: DictationRecord) {
        // Whatever the user typed into the record being replaced reaches history first.
        saveUnsavedEdit()
        currentGeneration += 1
        current = record
        edits = nil
    }

    /// Used only by `--snapshot` to render HUD states.
    func _debugSet(phase: Phase, levels: [Float], liveText: String = "", holdToTalk: Bool = false) {
        self.levels = levels
        self.liveText = liveText
        self.holdToTalk = holdToTalk
        startedAt = Date().addingTimeInterval(-7)
        self.phase = phase
    }

    private func set(_ next: Phase) {
        phase = next
        onPhaseChange?(next)
    }
}

/// This Mac's final transcript of a take, being finished in the background (`SpeechSession.finish`), so the
/// recording can go to the Neo without waiting for it all the way.
@MainActor
private final class LocalTranscript {
    private var result: String?
    private var waiting: [CheckedContinuation<String, Never>] = []

    init(speech: SpeechSession?) {
        Task { [weak self] in
            let text = await speech?.finish(timeout: 4) ?? ""
            self?.done(text)
        }
    }

    private func done(_ text: String) {
        result = text
        waiting.forEach { $0.resume(returning: text) }
        waiting = []
    }

    /// The transcript, once it is final.
    var value: String {
        get async {
            if let result { return result }
            return await withCheckedContinuation { waiting.append($0) }
        }
    }

    /// The transcript if it is final within `seconds`, else nil (it goes on being finished).
    func value(within seconds: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        while result == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return result
    }
}
