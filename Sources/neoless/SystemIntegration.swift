import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import Foundation
import NeolessCore
import ServiceManagement
import Speech

// MARK: - Permissions

enum Permissions {
    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var speech: SFSpeechRecognizerAuthorizationStatus { SFSpeechRecognizer.authorizationStatus() }
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func requestSpeech() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    /// Asks macOS for the "allow accessibility" alert, which also puts neoless into the Settings list,
    /// and returns the current state.
    @discardableResult
    static func promptAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// In memory on purpose (see `AccessibilityAsk`): every launch, and every loss of access, asks
    /// for the alert again, so a rebuilt or removed neoless gets listed again.
    @MainActor private static var accessibilityAsk = AccessibilityAsk()

    /// The Accessibility 允许 button: the system alert first (it has its own 打开系统设置 button),
    /// the Settings pane on the next click, never both at once. Granting is noticed without a
    /// restart: the app checks again every 2 s and comes back to the front (AppDelegate).
    @MainActor
    static func requestAccessibility() {
        switch accessibilityAsk.click(trusted: accessibility) {
        case .systemPrompt?: promptAccessibility()
        case .openSettings?: open(.accessibility)
        case nil: break
        }
    }

    /// Access was seen granted (ServiceMonitor): if it is lost later, 允许 asks for the alert again.
    @MainActor
    static func accessibilityGranted() {
        accessibilityAsk.granted()
    }

    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case speech = "Privacy_SpeechRecognition"
        case accessibility = "Privacy_Accessibility"
    }

    static func open(_ pane: Pane) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!)
    }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    /// System Settings › Keyboard › "Press 🌐 key to". 0 means "Do Nothing"; anything else (emoji, input
    /// source, Apple Dictation) also fires on every Fn tap. A missing key is the macOS default, which is
    /// not "Do Nothing" either.
    static var globeKey: GlobeKeyUsage {
        let value = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType")
        return GlobeKeyUsage(storedValue: (value as? NSNumber)?.intValue)
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("neoless: launch at login: \(error)")
        }
    }
}

// MARK: - Inserting text at the cursor

/// Pastes a dictation into the app it belongs to, or leaves it on the clipboard when pasting is not
/// safe (another app is in front, another app's panel or another field has keyboard focus, nothing
/// editable has focus, secure input is on). Pasting works in native fields, browsers and Electron
/// chat boxes (Codex, ChatGPT, Slack…) alike. After a paste the user's own clipboard is put back.
@MainActor
enum TextInserter {
    /// What `plan` decided. Nothing has been changed yet.
    struct Plan {
        /// `.pasted` means "send ⌘V"; anything else is the final outcome.
        let result: InsertResult
        /// The frontmost app when the plan was made; `perform` pastes only if it is still in front.
        let pid: pid_t?
        let bundleID: String?
        /// Put the user's clipboard back after pasting (settings.restoreClipboard).
        let restoreClipboard: Bool
        /// The user's clipboard as read while planning, nil if it was not read.
        fileprivate let saved: SavedClipboard?
        /// The focused field as read while planning, and, in an app that says when it takes a paste
        /// (`PasteSignal`), how much text it held: `confirm` compares it with what it holds afterwards.
        fileprivate let field: AXUIElement?
        fileprivate let length: Int?
    }

    /// The last paste into an app that says when it takes one (`PasteSignal`), until a newer paste or copy
    /// takes the clipboard (it also keeps the item's data provider alive while the item may be on it).
    private static var watched: PasteWatch?
    /// Apps seen asking for `PasteSignal.type` since launch: a paste they do not ask about was not taken.
    private static var learned = Set<String>()
    /// The user pressed a key or clicked while `keepTrying` waited.
    private static var userActed = false

    /// The app to paste into later: the frontmost app now. Call it when recording stops.
    static func currentTarget() -> PasteTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return PasteTarget(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName)
    }

    /// Starts reading what has keyboard focus now (which app, which element), off the main thread
    /// with a deadline, for `plan` to compare with later. Call it when recording stops. nil when
    /// there is nothing to read: no Accessibility, or neoless itself is in front.
    static func markFocus() -> Task<FocusMark?, Never> {
        let own = ProcessInfo.processInfo.processIdentifier
        guard Permissions.accessibility, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != own else { return Task { nil } }
        let pid = app.processIdentifier
        return Task { await FocusProbe.mark(pid: pid) }
    }

    /// Step 1: decides how to deliver, reading the focused element off the main thread (gives up
    /// after about 0.25 s; no answer counts as pasteable). Changes nothing. When this may end in a
    /// paste with `restoreClipboard`, the user's clipboard is read here, before the wait: reading it
    /// can make the app that copied it render a big copy on the main thread, and the frontmost app
    /// must be checked after that, not before. `target` nil means the app frontmost as the plan starts.
    /// `mark`: what had keyboard focus when the recording stopped (`markFocus`); the paste goes ahead
    /// only if the same app and, where both reads answered, the same element still have it.
    static func plan(for target: PasteTarget?, since mark: FocusMark? = nil, restoreClipboard: Bool) async -> Plan {
        let own = ProcessInfo.processInfo.processIdentifier
        let trusted = Permissions.accessibility
        let atStart = NSWorkspace.shared.frontmostApplication
        let targetPID = target?.pid ?? atStart?.processIdentifier
        var saved: SavedClipboard?
        if restoreClipboard, ClipboardPolicy.restoreDelay(bundleID: atStart?.bundleIdentifier) != nil,
           InsertPolicy.decide(target: targetPID, frontmost: atStart?.processIdentifier, ownPID: own, accessibility: trusted,
                               secureInput: IsSecureEventInputEnabled(), focus: .unknown) == .pasted {
            saved = readClipboard()
        }
        var reading = FocusReading.none
        if trusted, let app = atStart, app.processIdentifier != own, app.processIdentifier == targetPID {
            reading = await FocusProbe.read(pid: app.processIdentifier,
                                            inBrowser: FocusedField.isBrowser(bundleID: app.bundleIdentifier),
                                            since: mark?.element)
        }
        // How much text the field holds, in an app that says when it takes a paste: what `confirm` compares
        // with when it does not say.
        var length: Int?
        if let field = reading.element, PasteSignal.offers(bundleID: atStart?.bundleIdentifier) {
            length = await FocusProbe.length(of: field)
        }
        // Read again: the user may have switched apps while we were asking.
        let front = NSWorkspace.shared.frontmostApplication
        let result = InsertPolicy.decide(target: targetPID, frontmost: front?.processIdentifier, ownPID: own,
                                         accessibility: trusted, secureInput: IsSecureEventInputEnabled(),
                                         focus: reading.field, targetFocusOwner: mark?.owner,
                                         focusOwner: reading.owner, field: reading.match)
        return Plan(result: result, pid: front?.processIdentifier, bundleID: front?.bundleIdentifier ?? target?.bundleID,
                    restoreClipboard: restoreClipboard, saved: saved, field: reading.element, length: length)
    }

    /// Step 2: carries the plan out at once and returns what happened. If a different app came to
    /// the front since `plan`, the text is copied instead of pasted. `confirming`: the caller asks
    /// `confirm` next whether the app took the text, then `keepTrying` or `giveUp` when it did not; in an
    /// app that says (`PasteSignal`), the user's clipboard goes back only once the app has taken it.
    static func perform(_ plan: Plan, text: String, confirming: Bool = false) -> InsertResult {
        var result = plan.result
        var restore = Restore.none
        if result == .pasted {
            // The clipboard first (reading it can be slow), then the last look at the app in front, then ⌘V.
            restore = prepareRestore(plan)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != plan.pid { result = .copiedAppChanged }
        }
        if result == .pasted {
            let watch = confirming && PasteSignal.offers(bundleID: plan.bundleID)
                ? PasteWatch(pid: plan.pid ?? 0, bundleID: plan.bundleID, text: text,
                             confirms: PasteSignal.confirms(bundleID: plan.bundleID, learned: learned),
                             field: plan.field, length: plan.length)
                : nil
            paste(text, restoreAfter: restore.delay, watch: watch)
            if case .impossible = restore { result = .pastedKeptOnClipboard }
        } else if result.isCopied {
            copy(text)
        }
        return result
    }

    /// Whether the app took the text of the last `perform(confirming: true)`: it asks for `PasteSignal.type`
    /// within `PasteSignal.wait`, or else the field it went to changed all the same (`PasteCheck.judge`).
    /// `.unknown` at once for an app that does not say.
    static func confirm() async -> PasteCheck {
        guard let watch = watched, watch.confirms else { return .unknown }
        var signaled = await watch.taken(within: PasteSignal.wait)
        var now: Int?
        var same = false
        if !signaled, let field = watch.field {
            let reading = await FocusProbe.measure(pid: watch.pid, field: field)
            same = reading.same
            now = reading.length
        }
        // Asked while the field was being read: taken all the same (its put-back is already on its way).
        signaled = signaled || watch.isTaken
        let check = PasteCheck.judge(signaled: signaled, confirms: true, before: watch.length, now: now, sameField: same,
                                     inserted: watch.text.utf16.count)
        // Taken without asking: the user's clipboard goes back as after any paste.
        if check == .taken, !signaled { release(watch) }
        return check
    }

    /// After `confirm` said `.notTaken(retries: true)`: ⌘V again every `PasteRetry.interval` until the app takes
    /// the text, for as long as `PasteRetry.check` lets it (a chat page's input box takes none while its AI is
    /// answering, and takes it once that is done). True when it was taken. Otherwise, or when the task is
    /// cancelled (a new dictation), the text stays on the clipboard (`giveUp`).
    static func keepTrying() async -> Bool {
        guard let watch = watched, let field = watch.field, let before = watch.length else {
            giveUp()
            return false
        }
        let started = Date()
        userActed = false
        // A key or a click is the user taking over: nothing is sent after it.
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            // neoless's own ⌘V is not the user.
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != SyntheticEvent.marker else { return }
            MainActor.assumeIsolated { TextInserter.userActed = true }
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        while true {
            try? await Task.sleep(for: .seconds(PasteRetry.interval))
            var same = true
            var now: Int? = before
            if !watch.isTaken {
                let reading = await FocusProbe.measure(pid: watch.pid, field: field)
                same = reading.same
                now = reading.length
            }
            let stop = PasteRetry.check(taken: watch.isTaken, cancelled: Task.isCancelled || watch !== watched,
                                        userActed: userActed,
                                        frontmostIsTarget: NSWorkspace.shared.frontmostApplication?.processIdentifier == watch.pid,
                                        clipboardOurs: NSPasteboard.general.changeCount == watch.changeCount,
                                        secureInput: IsSecureEventInputEnabled(),
                                        fieldUnchanged: same && now == before,
                                        elapsed: Date().timeIntervalSince(started))
            if let stop {
                if stop == .taken { return true }
                if watch === watched { giveUp() }
                return false
            }
            // Each try gets the whole wait before the next: a busy page that takes it late must not get two.
            watch.listen()
            sendCommandV()
            if await watch.taken(within: PasteSignal.wait) { return true }
        }
    }

    /// The last paste was not taken and is not sent again: the text stays on the clipboard for the user, as
    /// a copy does, and the user's own clipboard does not go back over it.
    static func giveUp() {
        guard let watch = watched else { return }
        watch.listening = .distantPast
        watch.restore = nil
        // Still ours on the clipboard: it becomes a plain copy, as every other 已复制 (no transient mark, so
        // clipboard managers keep it, and no type that answers for this watch).
        if NSPasteboard.general.changeCount == watch.changeCount {
            copy(watch.text)
        } else {
            pending.cancel()
        }
    }

    /// The app asked for `PasteSignal.type`: it took the text.
    fileprivate static func taken(_ watch: PasteWatch) {
        // Only an ask while neoless waits for this paste, with its app in front, is this paste being taken:
        // not the user's own ⌘V of it later, nor a clipboard tool reading every type.
        guard !watch.isTaken, Date() < watch.listening,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == watch.pid else { return }
        watch.isTaken = true
        if let bundleID = watch.bundleID { learned.insert(bundleID) }
        release(watch)
        watch.resume()
    }

    /// The app has the text: the user's clipboard goes back when it is due, for a paste whose put-back waited.
    private static func release(_ watch: PasteWatch) {
        guard watch === watched, let restore = watch.restore else { return }
        watch.restore = nil
        let due = max(PasteSignal.restoreAfterTaken, restore.delay - Date().timeIntervalSince(watch.sent))
        scheduleRestore(restore.token, after: due)
    }

    /// The user went to another app while the dictation was being worked on: brings `target`, the app the recording
    /// stopped in, back to the front, so the text still goes where it was dictated (`plan` then checks the field as
    /// usual). Returns the app to go back to afterwards (`returnTo`), or nil when nothing was switched: the target is
    /// already in front, it is gone, neoless itself is in front, there is no Accessibility, or it did not come up.
    static func bringBack(_ target: PasteTarget?) async -> NSRunningApplication? {
        let own = ProcessInfo.processInfo.processIdentifier
        guard let target, Permissions.accessibility, let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != target.pid, front.processIdentifier != own,
              let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else { return nil }
        activate(app)
        for _ in 0..<16 {
            try? await Task.sleep(for: .milliseconds(50))
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid {
                // Let it put its window and focused field back before the field is read.
                try? await Task.sleep(for: .milliseconds(150))
                return front
            }
        }
        activate(front)
        return nil
    }

    /// Back to the app the user had gone to (`bringBack`), once the paste has reached the target.
    static func returnTo(_ app: NSRunningApplication) async {
        try? await Task.sleep(for: .milliseconds(250))
        guard !app.isTerminated else { return }
        activate(app)
    }

    /// `activate()` alone may be refused to a background app (cooperative activation, macOS 14), so Accessibility
    /// asks too.
    private static func activate(_ app: NSRunningApplication) {
        app.activate()
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                     kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    /// Puts `text` on the clipboard for the user to paste; it stays there.
    static func copy(_ text: String) {
        watched = nil
        cancelRestore()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: Paste and restore

    private static var pending = PendingRestore<[[ClipEntry]]>()
    private static var restoreWork: DispatchWorkItem?
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// What happens to the user's clipboard after a paste.
    private enum Restore {
        /// Left with the dictation on it, as asked: restore is off, or the app is a remote desktop.
        case none
        /// Put back this long after ⌘V.
        case after(TimeInterval)
        /// Restore was asked for, but the clipboard cannot be kept whole: the dictation stays on it.
        case impossible

        var delay: TimeInterval? {
            if case .after(let delay) = self { return delay }
            return nil
        }
    }

    /// Readies the restore before anything is written: how long after ⌘V to put the user's
    /// clipboard back, or why it stays with the dictation (putting back a partial copy could change
    /// what they paste later, or empty the clipboard).
    private static func prepareRestore(_ plan: Plan) -> Restore {
        restoreWork?.cancel()
        restoreWork = nil
        let pb = NSPasteboard.general
        guard plan.restoreClipboard, let delay = ClipboardPolicy.restoreDelay(bundleID: plan.bundleID) else {
            pending.cancel()
            return .none
        }
        // Back-to-back pastes keep the copy of the user's own clipboard from the first one.
        guard pending.needsSnapshot(changeCount: pb.changeCount) else { return .after(delay) }
        // The copy read while planning, unless the clipboard changed since (then read it again).
        let items: [[ClipEntry]]?
        if let saved = plan.saved, saved.changeCount == pb.changeCount { items = saved.items } else { items = snapshot(pb) }
        guard let items else {
            pending.cancel()
            return .impossible
        }
        pending.keep(items)
        return .after(delay)
    }

    private static func paste(_ text: String, restoreAfter delay: TimeInterval?, watch: PasteWatch? = nil) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if delay != nil {
            // Tells clipboard managers not to record this temporary entry.
            item.setData(Data(), forType: transientType)
        }
        // Asked for only when the app takes the text (`PasteSignal`).
        if let watch { item.setDataProvider(watch, forTypes: [NSPasteboard.PasteboardType(PasteSignal.type)]) }
        pb.writeObjects([item])
        let ours = pb.changeCount
        watch?.changeCount = ours
        watch?.listen()
        watched = watch
        sendCommandV()

        guard let delay else { return }
        let token = pending.wrote(changeCount: ours)
        if let watch, watch.confirms {
            // Put back once the app has the text (`taken`), not on a clock: a page busy with an answer takes it
            // late, and one that takes none leaves it on the clipboard for the user (`giveUp`).
            watch.restore = (token, delay)
            return
        }
        scheduleRestore(token, after: delay)
    }

    private static func scheduleRestore(_ token: Int, after delay: TimeInterval) {
        let work = DispatchWorkItem { MainActor.assumeIsolated { restoreIfDue(token) } }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Puts the user's clipboard back, but only if the clipboard still holds our text.
    private static func restoreIfDue(_ token: Int) {
        let pb = NSPasteboard.general
        guard let items = pending.due(token: token, changeCount: pb.changeCount) else { return }
        restoreWork = nil
        // `items` is empty only when the user's clipboard was empty: this empties it again.
        pb.clearContents()
        let objects = items.map { kept -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for entry in kept { item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type)) }
            return item
        }
        if !objects.isEmpty { pb.writeObjects(objects) }
    }

    private static func cancelRestore() {
        restoreWork?.cancel()
        restoreWork = nil
        pending.cancel()
    }

    /// The user's clipboard now, or nil when a paste would reuse the pending copy of it anyway.
    private static func readClipboard() -> SavedClipboard? {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        if pending.reuses(changeCount: count) { return nil }
        return SavedClipboard(changeCount: count, items: snapshot(pb))
    }

    /// A bounded copy of the clipboard (see `ClipboardPolicy.snapshot`): common types only, never
    /// private app formats or file promises; nil when it cannot be kept whole (then nothing is read).
    private static func snapshot(_ pb: NSPasteboard) -> [[ClipEntry]]? {
        let items = pb.pasteboardItems ?? []
        return ClipboardPolicy.snapshot(itemTypes: items.map { $0.types.map(\.rawValue) }) { index, type in
            items[index].data(forType: NSPasteboard.PasteboardType(type))
        }
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // So neoless's own hotkey tap knows this ⌘V is not the user pressing a key while Fn is down.
        source?.userData = SyntheticEvent.marker
        let key = CGKeyCode(vKeyCode())
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// The key that types "v" with ⌘ held in the current keyboard layout (Dvorak puts it where
    /// QWERTY has "."); 9, the QWERTY position, when the layout cannot be read.
    private static func vKeyCode() -> UInt16 {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return PasteKey.qwertyV }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        return layoutData.withUnsafeBytes { buffer -> UInt16 in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return PasteKey.qwertyV }
            return PasteKey.keyCode { code in
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), commandState, keyboardType,
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys,
                                            chars.count, &length, &chars)
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: chars, count: length)
            }
        }
    }
}

/// The user's clipboard as `TextInserter.plan` read it, with the changeCount before reading.
/// `items` nil: it cannot be kept whole.
private struct SavedClipboard {
    let changeCount: Int
    let items: [[ClipEntry]]?
}

/// What had keyboard focus when a recording stopped (`TextInserter.markFocus`). AXUIElement is an
/// immutable reference to another app's element, safe to pass between threads.
struct FocusMark: @unchecked Sendable {
    /// The app with keyboard focus, nil when the system did not say.
    let owner: pid_t?
    /// Its focused element, nil when it did not answer.
    let element: AXUIElement?
}

/// What `FocusProbe.read` found when pasting.
private struct FocusReading: @unchecked Sendable {
    /// The app with keyboard focus now, nil when unknown.
    let owner: pid_t?
    let field: FocusedField
    /// Compared with the element marked when the recording stopped.
    let match: FieldMatch
    /// The focused element itself, nil when it did not answer.
    var element: AXUIElement?

    /// No answer (in time): nothing is known, the paste follows the pid checks alone.
    static let none = FocusReading(owner: nil, field: .unknown, match: .unknown)
}

/// A paste whose taking is watched (`PasteSignal`): the clipboard offers `PasteSignal.type` through this object,
/// and the app asks for it only when it takes the text. Main thread only, except the ask itself.
private final class PasteWatch: NSObject, NSPasteboardItemDataProvider {
    let pid: pid_t
    let bundleID: String?
    /// The dictation, to leave on the clipboard as a plain copy when it is not taken (`giveUp`).
    let text: String
    /// Until when an ask counts as this paste being taken: `PasteSignal.wait` after each ⌘V.
    var listening = Date.distantPast
    /// The app always asks when it takes a paste (`PasteSignal.confirms`): a paste it does not ask about was not
    /// taken.
    let confirms: Bool
    /// The focused field as read before ⌘V, and how much text it held then (`TextInserter.Plan`).
    let field: AXUIElement?
    let length: Int?
    let sent = Date()
    /// The pasteboard's changeCount with the dictation on it.
    var changeCount = 0
    /// The put-back of the user's clipboard, waiting for the app to take the text: the token `restoreIfDue`
    /// checks, and how long after ⌘V it was due.
    var restore: (token: Int, delay: TimeInterval)?
    var isTaken = false
    private var waiting: [CheckedContinuation<Bool, Never>] = []

    init(pid: pid_t, bundleID: String?, text: String, confirms: Bool, field: AXUIElement?, length: Int?) {
        self.pid = pid
        self.bundleID = bundleID
        self.text = text
        self.confirms = confirms
        self.field = field
        self.length = length
    }

    /// A ⌘V is on its way: an ask in the next `PasteSignal.wait` (and a moment for reading the field) is it
    /// being taken.
    func listen() { listening = Date().addingTimeInterval(PasteSignal.wait + 1) }

    /// Whether the app takes the text within `seconds` (true at once if it has).
    @MainActor func taken(within seconds: TimeInterval) async -> Bool {
        if isTaken { return true }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                MainActor.assumeIsolated { self?.resume() }
            }
        }
    }

    /// Tells whoever waits whether the text was taken.
    @MainActor func resume() {
        let waiters = waiting
        waiting = []
        for waiter in waiters { waiter.resume(returning: isTaken) }
    }

    /// The app asked for `PasteSignal.type`: it is taking the text. It is given nothing, as when the clipboard
    /// does not have the type.
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        DispatchQueue.main.async { MainActor.assumeIsolated { TextInserter.taken(self) } }
    }
}

/// Neoless's own synthetic key events carry this in `eventSourceUserData`.
enum SyntheticEvent {
    static let marker: Int64 = 0x6E65_6F6C   // "neol"
}

/// Reads what has keyboard focus, through Accessibility on a private queue with a hard deadline,
/// so a hung app can never stall the main thread.
private enum FocusProbe {
    static let queue = DispatchQueue(label: "neoless.focus-probe", qos: .userInitiated)
    static let messagingTimeout: Float = 0.1
    /// How far up from one focused element to look for the other.
    static let ancestorDepth = 40

    /// `pid` is the frontmost app. ⌘V goes to whatever has keyboard focus, which is usually in that
    /// app, but a non-activating panel of another app (Spotlight, a launcher) takes keyboard focus
    /// without becoming frontmost; then that panel and its focused element are read instead, and the
    /// owner reported, so the caller can see that it is not the app the recording stopped in.
    static func mark(pid: pid_t, timeout: TimeInterval = 0.25) async -> FocusMark? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce<FocusMark?>(continuation)
            queue.async {
                let owner = focusOwner()
                once.resume(FocusMark(owner: owner, element: focusedElement(of: owner ?? pid)))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
    }

    /// Like `mark`, and judges the element: `inBrowser` for `FocusedField.classify`; `since`, the
    /// element marked when the recording stopped, to compare with.
    static func read(pid: pid_t, inBrowser: Bool, since marked: AXUIElement?, timeout: TimeInterval = 0.25) async -> FocusReading {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            queue.async {
                let owner = focusOwner()
                let element = focusedElement(of: owner ?? pid)
                once.resume(FocusReading(owner: owner, field: element.map { classify($0, inBrowser: inBrowser) } ?? .unknown,
                                         match: compare(marked, element), element: element))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { once.resume(.none) }
        }
    }

    /// How much text `element` holds, nil when it does not say in time.
    static func length(of element: AXUIElement, timeout: TimeInterval = 0.25) async -> Int? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce<Int?>(continuation)
            queue.async { once.resume(characters(element)) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
    }

    /// Whether `field` still has keyboard focus (in the app `pid`, or the one the system says has it), and
    /// how much text it holds now: false and nil when that cannot be read in time.
    static func measure(pid: pid_t, field: AXUIElement, timeout: TimeInterval = 0.3) async -> (same: Bool, length: Int?) {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce<(same: Bool, length: Int?)>(continuation)
            queue.async {
                let same = focusedElement(of: focusOwner() ?? pid).map { CFEqual($0, field) } ?? false
                once.resume((same, same ? characters(field) : nil))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { once.resume((false, nil)) }
        }
    }

    /// The field's character count, or its value's length when it does not give one.
    private static func characters(_ element: AXUIElement) -> Int? {
        if let count = value(element, kAXNumberOfCharactersAttribute) as? Int { return count }
        return (value(element, kAXValueAttribute) as? String)?.utf16.count
    }

    /// The app that has keyboard focus, nil when the system does not say (or says neoless itself).
    /// No messaging timeout is set on the system-wide element: that would change every AX call neoless
    /// makes. The deadline in `read` keeps the caller from waiting on it.
    private static func focusOwner() -> pid_t? {
        guard let ref = value(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute),
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(ref as! AXUIElement, &pid) == .success, pid > 0,
              pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        return pid
    }

    private static func focusedElement(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let ref = value(app, kAXFocusedUIElementAttribute), CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = ref as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    private static func classify(_ element: AXUIElement, inBrowser: Bool) -> FocusedField {
        let role = value(element, kAXRoleAttribute) as? String
        var settable = DarwinBoolean(false)
        let valueSettable = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
        return FocusedField.classify(role: role, subrole: value(element, kAXSubroleAttribute) as? String,
                                     isProtected: (value(element, "AXProtectedContent") as? Bool) == true,
                                     hasEditableAncestor: value(element, "AXEditableAncestor") != nil,
                                     isValueSettable: valueSettable, inBrowser: inBrowser)
    }

    /// The same element, or one inside the other: an app that builds its accessibility tree on
    /// demand (Chrome, Electron) may report the page when first asked and the field a moment later.
    private static func compare(_ marked: AXUIElement?, _ now: AXUIElement?) -> FieldMatch {
        guard let marked, let now else { return .unknown }
        if CFEqual(marked, now) || isAncestor(marked, of: now) || isAncestor(now, of: marked) { return .same }
        return .moved
    }

    private static func isAncestor(_ ancestor: AXUIElement, of element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<ancestorDepth {
            guard let ref = value(current, kAXParentAttribute), CFGetTypeID(ref) == AXUIElementGetTypeID() else {
                return false
            }
            let parent = ref as! AXUIElement
            if CFEqual(parent, ancestor) { return true }
            AXUIElementSetMessagingTimeout(parent, messagingTimeout)
            current = parent
        }
        return false
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success else { return nil }
        return out
    }
}

/// Resumes a continuation exactly once, from whichever side finishes first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func resume(_ value: T) {
        let c = lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: value)
    }
}

// MARK: - Global hotkey

/// A keyboard event tap on its own thread, so Fn/Esc are never delayed by work on the main
/// thread. Needs the Accessibility permission. Feeds `HotkeyStateMachine` and delivers its
/// `HotkeyAction`s on the main thread; see `HotkeyAction` for what each one asks for.
final class HotkeyMonitor: @unchecked Sendable {
    /// Main thread. `tentative`: a `.start` that came on key-down, so the press may still turn out
    /// to be a shortcut (`HotkeyStateMachine.startIsTentative`).
    var onAction: ((_ action: HotkeyAction, _ tentative: Bool) -> Void)?
    /// Main thread: whether dictation is recording right now (starting or recording). Read after
    /// every delivered action, so the state machine follows what the controller really did.
    var recordingState: (() -> Bool)?

    private let lock = NSLock()
    private var trigger: HotkeyTrigger = .fn
    private var style: HotkeyStyle = .auto
    private var consumeEscape = false
    /// The controller's latest state, with how many `.start`s had reached the main thread then.
    private var pendingSync: (recording: Bool, starts: Int)?
    /// Events may have been missed (tap restarted or re-enabled): check the key's real state.
    private var needsResync = false

    /// Main thread only.
    private var startsDelivered = 0

    // Tap thread only.
    private var machine = HotkeyStateMachine(trigger: .fn)
    private var startsSent = 0
    /// The Esc key now down was taken from the app: its repeats and its release are taken too.
    private var swallowedEscape = false

    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    var isRunning: Bool { lock.withLock { tap != nil } }

    func setTrigger(_ t: HotkeyTrigger) { lock.withLock { trigger = t } }

    /// settings.hotkeyStyle: tap to toggle, hold to talk, or both (auto).
    func setStyle(_ s: HotkeyStyle) { lock.withLock { style = s } }

    /// While a dictation is under way (`CaptureFlow.consumesEscape`: starting, recording,
    /// recognizing, polishing), Esc goes to neoless only and never to the app underneath.
    func setConsumeEscape(_ on: Bool) { lock.withLock { consumeEscape = on } }

    /// Main thread: whether dictation is recording (phase starting or recording). Call it on every
    /// phase change. A state reported while a `.start` is still on its way to the main thread is
    /// ignored; the state read after that action wins.
    func syncRecording(_ recording: Bool) {
        let starts = startsDelivered
        lock.withLock { pendingSync = (recording, starts) }
    }

    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        lock.withLock { needsResync = true }
        let ready = DispatchSemaphore(value: 0)
        var created = false
        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventMask(KeyInput.systemDefinedEventType))
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: mask, callback: hotkeyCallback,
                                              userInfo: Unmanaged.passUnretained(self).toOpaque())
            else { ready.signal(); return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.lock.withLock { self.tap = tap; self.runLoop = loop }
            created = true
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "neoless.hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        if created { self.thread = thread }
        return created
    }

    func stop() {
        let (tap, loop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            defer { self.tap = nil; self.runLoop = nil }
            return (self.tap, self.runLoop)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let loop { CFRunLoopStop(loop) }
        thread = nil
    }

    /// macOS can silently disable a tap; turn it back on (and recheck the key: an Fn-up may be lost).
    func ensureEnabled() {
        guard let tap = lock.withLock({ self.tap }) else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            lock.withLock { needsResync = true }
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let now = ProcessInfo.processInfo.systemUptime
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Events were missed while the tap was off (a release among them stops a recording).
            let tap = lock.withLock { () -> CFMachPort? in
                needsResync = true
                return self.tap
            }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            _ = prepare(now: now, resync: true)
            return pass
        }
        // neoless's own ⌘V (a dictation's paste, 重新粘贴上一条) is not the user pressing a key: fed to
        // the machine while Fn is down it would turn a new dictation into a "shortcut".
        if event.getIntegerValueField(.eventSourceUserData) == SyntheticEvent.marker { return pass }
        let timestamp = EventClock.seconds(eventTimestamp: event.timestamp, now: now)
        let input: KeyInput
        switch type {
        case .flagsChanged, .keyDown, .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if keyCode == HotkeyStateMachine.escapeKeyCode, swallowedEscape, type != .flagsChanged {
                // The rest of an Esc press neoless took: the app never sees half a keystroke.
                if type == .keyUp {
                    swallowedEscape = false
                    return nil
                }
                if isRepeat { return nil }
            }
            let kind: KeyEventKind = type == .flagsChanged ? .flagsChanged : type == .keyDown ? .keyDown : .keyUp
            // Only a trigger change needs it (and the call is not free).
            let secure = kind == .flagsChanged && keyCode == machine.trigger.keyCode && IsSecureEventInputEnabled()
            input = KeyInput(kind: kind, keyCode: keyCode, flags: event.flags.rawValue, isRepeat: isRepeat,
                             timestamp: timestamp, secureInput: secure)
        default:
            // Volume, brightness, media and keyboard-light keys (NX_SYSDEFINED) only matter while the
            // trigger is down; mouse clicks arrive here too, so skip the decoding otherwise.
            guard type.rawValue == KeyInput.systemDefinedEventType, machine.isPressed,
                  let ns = NSEvent(cgEvent: event), ns.type == .systemDefined,
                  let aux = KeyInput.systemDefined(subtype: Int(ns.subtype.rawValue), data1: ns.data1,
                                                   flags: event.flags.rawValue, timestamp: timestamp)
            else { return pass }
            input = aux
        }
        let isTriggerEvent = input.kind == .flagsChanged && input.keyCode == machine.trigger.keyCode
        // A trigger event carries the key's real state itself; resync only on other events.
        let consume = prepare(now: now, resync: !isTriggerEvent)
        guard let action = machine.handle(input) else { return pass }
        if action == .escape {
            swallowedEscape = consume
            guard consume else { return pass }
            deliver(.escape)
            return nil
        }
        deliver(action, tentative: action == .start && machine.startIsTentative)
        return pass
    }

    /// Tap thread: picks up the settings and the controller's state before an event is handled.
    /// Returns whether Esc is consumed.
    private func prepare(now: TimeInterval, resync: Bool) -> Bool {
        let (trigger, style, consume, sync, resyncDue) = lock.withLock {
            defer { pendingSync = nil; if resync { needsResync = false } }
            return (self.trigger, self.style, self.consumeEscape, self.pendingSync, self.needsResync && resync)
        }
        if machine.trigger != trigger {
            var fresh = HotkeyStateMachine(trigger: trigger, style: style)
            fresh.sync(recording: machine.isRecording)
            machine = fresh
        }
        machine.style = style
        if let sync, sync.starts == startsSent { machine.sync(recording: sync.recording) }
        if resyncDue {
            let down = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(trigger.keyCode))
                || CGEventSource.flagsState(.combinedSessionState).rawValue & trigger.deviceFlagMask != 0
            if let action = machine.resync(triggerIsDown: down, at: now) { deliver(action) }
        }
        return consume
    }

    /// Tap thread: hands an action to the main thread, then reports the controller's state back.
    private func deliver(_ action: HotkeyAction, tentative: Bool = false) {
        if action == .start { startsSent += 1 }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if action == .start { self.startsDelivered += 1 }
            self.onAction?(action, tentative)
            if let recording = self.recordingState?() { self.syncRecording(recording) }
        }
    }
}

private func hotkeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
