import AppKit
import Combine
import NeolessCloud
import NeolessCore
import SwiftUI

/// Menu-bar app: lives in the status bar, shows a Dock icon only while a window is open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settings = AppSettings.shared
    private let history = HistoryStore()
    private let vocabulary = VocabularyStore()
    private let account = ChatGPTAccount()
    private lazy var learning = LearningStore(vocabulary: vocabulary)
    private let router = Router()
    private let status = SystemStatus()
    private let hotkey = HotkeyMonitor()
    private lazy var hub = HubConnection(settings: settings)
    private lazy var hubSync = HubSync(hub: hub, vocabulary: vocabulary, learning: learning)
    private lazy var usage = UsageStore(history: history.records)
    private lazy var controller = DictationController(settings: settings, history: history, vocabulary: vocabulary,
                                                         account: account, learning: learning, hub: hub, usage: usage)
    private lazy var hud = HUDController(controller: controller)
    private lazy var monitor = ServiceMonitor(settings: settings, account: account, hotkey: hotkey)
    /// 显示 › 听写 / 历史记录 / 个人词典 / 设置, ⌘1 … ⌘4 (and the digits on their own, `pageKeys`).
    private lazy var pageMenu = PageMenu(router: router, window: { [weak self] in self?.window }) { [weak self] page in
        self?.show(page)
    }
    /// Watches for a digit pressed on its own in the window (`PageMenu.handlePlainKey`).
    private var pageKeys: Any?
    /// Watches for a click beside the result being edited (`PageMenu.noteMouse`).
    private var pageClicks: Any?

    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var bag = Set<AnyCancellable>()
    private var hotkeyTimer: Timer?
    /// Refreshes the window's permission rows; runs only while the window is open.
    private var windowTimer: Timer?
    /// The last other normal app that was in front, so closing the window can give it focus back.
    /// Agents (the accessibility alert's helper, Raycast, menu-bar tools) are never remembered.
    private var previousApp: NSRunningApplication?
    private var observers: [NSObjectProtocol] = []
    /// Pairing links that arrived before launching finished.
    private var openedEarly: [URL] = []
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Already running: that copy shows its window, this one quits. Debug runs never count.
        if let running = InstanceGuard.runningInstance() {
            InstanceGuard.handOver(to: running)
            NSApp.terminate(nil)
            return
        }
        observers.append(InstanceGuard.listen { [weak self] in self?.showMainWindow() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, Self.remembers(app) { self?.previousApp = app }
            }
        })
        if let front = NSWorkspace.shared.frontmostApplication, Self.remembers(front) { previousApp = front }

        // One window, never tabs: macOS then adds no tab commands of its own to the 显示 and 窗口 menus.
        NSWindow.allowsAutomaticWindowTabbing = false
        buildMainMenu()
        // 1 … 4 without ⌘, while nothing is being typed into: the key is used up only when it was a page's.
        pageKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.pageMenu.handlePlainKey(event) == true ? nil : event
        }
        // A click beside the result being edited ends the typing, so the digits are the pages' again.
        pageClicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.pageMenu.noteMouse(event)
            return event
        }
        buildStatusItem()
        status.hotkeyMonitor = hotkey
        status.hub = hub

        // 用 Neo 处理: the controller sends recordings there, the sync keeps the dictionary and corrections in step.
        controller.hubSync = hubSync
        hubSync.hubID = { [weak self] id in
            guard let self else { return nil }
            if let current = self.controller.current, current.id == id { return current.hubID }
            return self.history.records.first { $0.id == id }?.hubID
        }
        monitor.hubFact = { [weak self] in self?.hub.status.serviceFact ?? .off }
        hub.objectWillChange.sink { [weak self] _ in
            // @Published fires before the value changes.
            DispatchQueue.main.async { self?.monitor.refresh() }
        }.store(in: &bag)
        hub.start()
        hubSync.start()

        controller.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            self.hud.update(phase, buttons: !self.controller.holdToTalk)
            self.updateStatusIcon(phase)
        }
        // The microphone state, tentative presses included (they show no phase): the hotkey follows it.
        controller.onCaptureChange = { [weak self] capturing in
            self?.hotkey.syncRecording(capturing)
        }
        // Esc belongs to neoless for the whole dictation, recognizing and polishing included: there it
        // stops the paste and keeps the result, and the app underneath never sees it.
        controller.onConsumesEscapeChange = { [weak self] consumes in
            self?.hotkey.setConsumeEscape(consumes)
        }
        // What an edit taught, or why it could not: one line in the capsule, where the user is.
        learning.onAnnounce = { [weak self] announcement in self?.hud.announce(announcement) }
        hotkey.recordingState = { [weak self] in self?.controller.isCapturing ?? false }
        hotkey.onAction = { [weak self] action, tentative in
            guard let self, self.settings.hotkeyEnabled else { return }
            // A start on key-down may still turn out to be Fn+←, Fn+Delete…
            self.controller.handle(action, tentative: tentative)
        }
        hotkey.setTrigger(settings.trigger)
        settings.$trigger.sink { [weak self] trigger in
            self?.hotkey.setTrigger(trigger)
            // The warning names the key; @Published fires before the value changes.
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateStatusIcon(self.controller.phase)
            }
        }.store(in: &bag)
        hotkey.setStyle(settings.hotkeyStyle)
        settings.$hotkeyStyle.sink { [weak self] in self?.hotkey.setStyle($0) }.store(in: &bag)
        settings.$hotkeyEnabled.sink { [weak self] on in
            DispatchQueue.main.async { self?.syncHotkey(enabled: on) }
        }.store(in: &bag)

        // Accessibility can be granted at any time; keep trying until the tap is up,
        // and re-enable it if macOS ever switches it off.
        hotkeyTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncHotkey(enabled: self?.settings.hotkeyEnabled ?? false)
                self?.monitor.refresh()
            }
        }
        syncHotkey(enabled: settings.hotkeyEnabled)

        // The menu-bar icon warns when dictation cannot work, window or not.
        monitor.onChange = { [weak self] _ in
            guard let self else { return }
            self.updateStatusIcon(self.controller.phase)
        }
        // Just switched on in System Settings: come back so the checklist can be seen turning green.
        monitor.onAccessibilityGranted = { [weak self] in
            guard let self else { return }
            self.syncHotkey(enabled: self.settings.hotkeyEnabled)
            if self.window?.isVisible == true { self.showMainWindow() }
        }
        monitor.start()

        let firstRun = !UserDefaults.standard.bool(forKey: "launchedBefore")
        UserDefaults.standard.set(true, forKey: "launchedBefore")
        status.refresh()
        if firstRun || !status.allGranted || CommandLine.arguments.contains("--show") {
            showMainWindow()
        }
        launched = true
        let early = openedEarly
        openedEarly = []
        if !early.isEmpty { application(NSApp, open: early) }
    }

    /// `neoless://pair?server=…&token=…&name=…`, from the Neo's pairing QR code or link: Settings opens with the
    /// pairing waiting for 配对 (nothing is paired from a link alone).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else {
            openedEarly += urls
            return
        }
        guard let url = urls.last(where: { $0.scheme?.lowercased() == HubPairing.scheme }) else { return }
        hub.open(url)
        router.section = .settings
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        controller.cancel()
        controller.observer.shutdown()
        hotkey.stop()
    }

    private func syncHotkey(enabled: Bool) {
        if enabled && Permissions.accessibility {
            if !hotkey.isRunning { hotkey.start() } else { hotkey.ensureEnabled() }
        } else if hotkey.isRunning {
            hotkey.stop()
        }
    }

    // MARK: Windows

    /// The window as it opens on a display with room for it: 今日概览 at its roomy width, and tall enough
    /// for the whole page, down to the last row of 过去一年.
    private static let windowSize = NSSize(width: 1180, height: 870)

    /// The size to open with on `screen`: `windowSize`, or as much of it as the screen holds. In height
    /// nearly all of it: a 13-inch display is some 850pt tall under the menu bar, and the page fits in a
    /// little under 830 (`Dash.cardHeights`), so it opens whole there too. With the Dock showing, the page
    /// scrolls to its last card.
    private static func openingSize(on screen: NSScreen?) -> NSSize {
        guard let visible = screen?.visibleFrame.size else { return windowSize }
        return NSSize(width: max(MainView.minSize.width, min(windowSize.width, visible.width - 48)),
                      height: max(MainView.minSize.height, min(windowSize.height, visible.height - 12)))
    }

    /// 今日概览 needs more room than the page it replaced. A window whose size was saved before it existed
    /// is made as large as a new one would open, once (its top left corner stays put where the screen
    /// allows); after that the size is the user's to choose.
    private func fitOverviewOnce(_ w: NSWindow, to size: NSSize) {
        let key = "overview.windowFitted"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let content = w.contentRect(forFrameRect: w.frame).size
        let grow = NSSize(width: max(0, size.width - content.width), height: max(0, size.height - content.height))
        guard grow.width > 0 || grow.height > 0 else { return }
        var frame = w.frame
        frame.size.width += grow.width
        frame.size.height += grow.height
        frame.origin.y -= grow.height
        if let visible = (w.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
            frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
        }
        w.setFrame(frame, display: false)
    }

    @objc func showMainWindow() {
        if window == nil {
            let root = MainView()
                .environmentObject(controller)
                .environmentObject(settings)
                .environmentObject(history)
                .environmentObject(vocabulary)
                .environmentObject(learning)
                .environmentObject(account)
                .environmentObject(router)
                .environmentObject(status)
                .environmentObject(hub)
                .environmentObject(usage)
            let size = Self.openingSize(on: NSScreen.main)
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "neoless"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.backgroundColor = .windowBackgroundColor
            w.contentViewController = NSHostingController(rootView: root)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setContentSize(size)
            w.center()
            w.setFrameAutosaveName("neoless.main")
            fitOverviewOnce(w, to: size)
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let opening = window?.isVisible != true
        window?.makeKeyAndOrderFront(nil)
        // Nothing starts focused: the result on the 听写 page is an editor, and typing right after
        // opening the window must not change it (nor draw its caret). It takes focus on a click or 编辑.
        if opening {
            window?.makeFirstResponder(nil)
            DispatchQueue.main.async { [weak self] in
                if self?.window?.firstResponder is NSTextView { self?.window?.makeFirstResponder(nil) }
            }
        }
        status.refresh()
        // The day may have changed while the window was closed (or the Mac asleep).
        usage.refreshToday()
        if windowTimer == nil {
            windowTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.status.refresh() }
            }
        }
    }

    /// ⌘Q and ⌘W: close the window, keep dictation running in the menu bar.
    @objc func closeMainWindow() {
        window?.performClose(nil)
    }

    @objc func showSettings() {
        show(.settings)
    }

    /// Opens the window on `page` (⌘1 … ⌘4, ⌘, and the menu-bar menu).
    private func show(_ page: Page) {
        router.section = page
        // Already in front with the keyboard: only the page changes.
        if window?.isKeyWindow != true { showMainWindow() }
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        if closing === window {
            windowTimer?.invalidate()
            windowTimer = nil
        }
        DispatchQueue.main.async {
            let visible = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && $0 !== closing }
            guard !visible else { return }
            NSApp.setActivationPolicy(.accessory)
            self.handFocusBack()
        }
    }

    /// An accessory app with no window stays the active app, so the next Fn would find neoless in front
    /// and type nowhere. Give focus back to the app that was in front before, else to the app whose
    /// window is now on top. Never `NSApp.hide`: a hidden app keeps the capsule hidden too.
    private func handFocusBack() {
        guard NSApp.isActive else { return }
        let choice = FocusHandBack.choose(previous: previousApp.map(Self.describe),
                                          windowOwners: Self.windowOwnersFrontToBack().map(Self.describe),
                                          selfPID: ProcessInfo.processInfo.processIdentifier)
        if case .activate(let pid) = choice, let app = NSRunningApplication(processIdentifier: pid) {
            NSApp.yieldActivation(to: app)
            app.activate()
        } else {
            NSApp.deactivate()
        }
    }

    private static func describe(_ app: NSRunningApplication) -> FocusHandBack.App {
        FocusHandBack.App(pid: app.processIdentifier, isRegular: app.activationPolicy == .regular,
                          isTerminated: app.isTerminated)
    }

    private static func remembers(_ app: NSRunningApplication) -> Bool {
        FocusHandBack.remembers(describe(app), selfPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// The apps that own normal windows on this Space, frontmost first (no screen-recording permission
    /// needed for owners and layers).
    private static func windowOwnersFrontToBack() -> [NSRunningApplication] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        let windows = list as? [[String: Any]] ?? []
        var seen = Set<pid_t>()
        var owners: [NSRunningApplication] = []
        for info in windows {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  seen.insert(pid).inserted,
                  let app = NSRunningApplication(processIdentifier: pid) else { continue }
            owners.append(app)
        }
        return owners
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon(.idle)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// The dictation phase while one runs; otherwise whether dictation can work (`ServiceMonitor`).
    private func updateStatusIcon(_ phase: Phase) {
        let name: String
        switch phase {
        case .recording, .starting: name = "waveform.circle.fill"
        case .transcribing, .polishing: name = "ellipsis.circle"
        default:
            switch monitor.health {
            case .ok: name = "waveform"
            case .degraded: name = "waveform.badge.exclamationmark"
            case .broken: name = "waveform.slash"
            }
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "neoless")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = monitor.health.problem?.message(for: settings.trigger) ?? "neoless"
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = statusMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            showMainWindow()
        }
    }

    private func statusMenu() -> NSMenu {
        monitor.refresh(full: true)
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let problem = monitor.health.problem {
            let item = menu.addItem(withTitle: problem.message(for: settings.trigger), action: #selector(fixProblem),
                                    keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            item.toolTip = problem == .speechModel ? "打开键盘设置，下载离线识别模型" : "打开 neoless 设置"
            menu.addItem(.separator())
        }
        let active = dictationRunning
        // 开始听写 / 结束听写 (like ✓) / 取消输入 while recognizing or polishing (like Esc).
        let command = controller.menuCommand
        let dictation = menu.addItem(withTitle: command.title, action: #selector(dictationItem(_:)), keyEquivalent: "")
        dictation.target = self
        dictation.tag = command.rawValue

        let modeItem = menu.addItem(withTitle: "模式", action: nil, keyEquivalent: "")
        let modes = NSMenu(title: "模式")
        for mode in DictationMode.allCases {
            let item = modes.addItem(withTitle: mode.shortTitle, action: #selector(pickMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = settings.mode == mode ? .on : .off
        }
        modeItem.submenu = modes

        // What the last edit taught, said here as well (the capsule says it once and goes).
        if let line = learningLine {
            let item = menu.addItem(withTitle: line, action: #selector(showDictionary), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: nil)
            item.toolTip = "打开个人词典"
        }

        let last = lastResult
        let repaste = menu.addItem(withTitle: "重新输入上一条", action: #selector(repasteLast), keyEquivalent: "")
        repaste.target = self
        repaste.isEnabled = last != nil && !active
        let copy = menu.addItem(withTitle: "复制上一条", action: #selector(copyLast), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = last != nil
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开 neoless", action: #selector(showMainWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 neoless", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    /// The newest entry of the learning log, when it is recent enough to be about what the user just did.
    private var learningLine: String? {
        guard learning.enabled, let entry = learning.log.first, Date().timeIntervalSince(entry.at) < 30 * 60 else { return nil }
        if entry.code == LearningLog.Code.learned.rawValue, let notice = learning.lastEvent {
            return "\(LearningText.learnedPrefix)：\(notice.summary)"
        }
        let what = LearningText.line(code: entry.code, count: entry.count)
        return entry.app.map { "\($0)：\(what)" } ?? what
    }

    @objc private func showDictionary() {
        show(.dictionary)
    }

    @objc private func dictationItem(_ sender: NSMenuItem) {
        guard let command = CaptureFlow.MenuCommand(rawValue: sender.tag) else { return }
        controller.menu(command)
    }

    @objc private func fixProblem() {
        if monitor.health.problem == .speechModel { Permissions.openKeyboardSettings() } else { showSettings() }
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = DictationMode(rawValue: raw) { settings.mode = mode }
    }

    /// A dictation is under way, a tentative hotkey press included: it records with no phase showing
    /// until it turns out not to be a shortcut, and a ⌘V now would land in the middle of it.
    private var dictationRunning: Bool { controller.phase.isActive || controller.isCapturing }

    /// The latest result: the one on the home page (with the user's edits), else the newest history entry.
    private var lastResult: String? {
        let text = (controller.current ?? history.records.first)?.finalText
        return text?.isEmpty == false ? text : nil
    }

    @objc private func copyLast() {
        if let text = lastResult { TextInserter.copy(text) }
    }

    /// Types the latest result again into the app in front, the same way a dictation does: pasted when
    /// it is safe, otherwise left on the clipboard. Dropped if a dictation starts meanwhile (Fn pressed
    /// right after choosing it): a ⌘V then would land in the middle of it.
    @objc private func repasteLast() {
        guard let text = lastResult, !dictationRunning else { return }
        Task { @MainActor in
            // Let the menu finish closing so ⌘V reaches the app, not the menu.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !dictationRunning else { return }
            let plan = await TextInserter.plan(for: TextInserter.currentTarget(), restoreClipboard: settings.restoreClipboard)
            guard !dictationRunning else { return }
            let result = TextInserter.perform(plan, text: text)
            // neoless itself is in front (the window): nothing to paste into, so copy it.
            if result == .ownApp { TextInserter.copy(text) }
        }
    }

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 neoless", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 neoless", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        // Like OpenLess and Typeless, ⌘Q only closes the window: Fn keeps working from the menu bar.
        // Quitting for real is in the menu-bar menu (and here, without a shortcut).
        appMenu.addItem(withTitle: "关闭窗口（继续在后台运行）", action: #selector(closeMainWindow), keyEquivalent: "q").target = self
        appMenu.addItem(withTitle: "退出 neoless", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        // 显示: the four pages, ⌘1 … ⌘4, a check mark on the one showing.
        main.addItem(pageMenu.makeItem())

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}
