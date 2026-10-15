import AppKit
import Combine
import Darwin
import NeolessCloud
import NeolessCore

/// Whether dictation can work right now, for the menu-bar icon and the first line of its menu,
/// independent of the window. Permissions and the hotkey tap are cheap and checked on every `refresh()`
/// (the app's 2 s hotkey tick); the speech model and the ChatGPT login (which may read a file)
/// only on a `full` refresh: on app activation, after wake, when a related setting changes, and once a minute.
@MainActor
final class ServiceMonitor {
    private(set) var health: ServiceHealth = .ok
    var onChange: ((ServiceHealth) -> Void)?
    /// Accessibility went from missing to granted while running (the user just switched it on).
    var onAccessibilityGranted: (() -> Void)?
    /// 用 Neo 处理, as `HubConnection` knows it (soft: this Mac does the work while the Neo is out of reach).
    var hubFact: () -> ServiceFacts.Hub = { .off }

    private let settings: AppSettings
    private let account: ChatGPTAccount
    private let hotkey: HotkeyMonitor
    private var speechModel = true
    private var chatGPT: ServiceFacts.ChatGPT = .ready
    private var lastAccessibility: Bool?
    private var lastSpeech: Bool?
    private var slowTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var bag = Set<AnyCancellable>()

    init(settings: AppSettings, account: ChatGPTAccount, hotkey: HotkeyMonitor) {
        self.settings = settings
        self.account = account
        self.hotkey = hotkey
    }

    func start() {
        let full: (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.refresh(full: true) } }
        let app = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            (app, app.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: full)),
            (workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: full)),
            (workspace, workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: full)),
        ]
        // @Published fires before the value changes: look on the next turn of the run loop.
        let later: () -> Void = { [weak self] in DispatchQueue.main.async { self?.refresh(full: true) } }
        settings.$localeID.dropFirst().sink { _ in later() }.store(in: &bag)
        settings.$mode.dropFirst().sink { _ in later() }.store(in: &bag)
        settings.$hotkeyEnabled.dropFirst().sink { _ in later() }.store(in: &bag)
        account.objectWillChange.sink { _ in later() }.store(in: &bag)
        slowTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(full: true) }
        }
        refresh(full: true)
    }

    func refresh(full: Bool = false) {
        let accessibility = Permissions.accessibility
        let speech = Permissions.speech == .authorized
        // The model check is only meaningful once speech recognition is allowed.
        if full || (speech && lastSpeech == false) {
            speechModel = SpeechSession.onDeviceAvailable(localeID: settings.localeID)
            chatGPT = account.isReady ? .ready : .signedOut
        }
        if accessibility && lastAccessibility != true { Permissions.accessibilityGranted() }
        if lastAccessibility == false && accessibility { onAccessibilityGranted?() }
        lastAccessibility = accessibility
        lastSpeech = speech

        let next = ServiceHealth.evaluate(ServiceFacts(
            accessibility: accessibility, microphone: Permissions.microphone == .authorized, speech: speech,
            hotkeyEnabled: settings.hotkeyEnabled, hotkeyRunning: hotkey.isRunning, speechModel: speechModel,
            polishes: settings.mode.polishes, chatGPT: chatGPT, hub: hubFact()))
        guard next != health else { return }
        health = next
        onChange?(next)
    }
}

/// The single-instance guard: hand over to the copy that is already running (it shows its window)
/// instead of starting a second one. Debug runs (`--snapshot` and friends) are never "the running app".
enum InstanceGuard {
    private static var showWindowName: Notification.Name {
        Notification.Name((Bundle.main.bundleIdentifier ?? "neoless") + ".showMainWindow")
    }

    /// The running copy to hand over to, if any. Call before setting anything up.
    static func runningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { $0 != me && !$0.isTerminated }
        let peers = others.map { app in
            SingleInstance.Peer(pid: app.processIdentifier, launched: app.launchDate,
                                isDebug: app.activationPolicy == .prohibited
                                    || SingleInstance.isDebugRun(arguments(of: app.processIdentifier) ?? []))
        }
        guard let winner = SingleInstance.yield(to: peers, selfPID: me.processIdentifier, selfLaunched: me.launchDate) else {
            return nil
        }
        return others.first { $0.processIdentifier == winner.pid }
    }

    /// Asks `app` to show its window and lets it come to the front.
    static func handOver(to app: NSRunningApplication) {
        NSApp.yieldActivation(to: app)
        DistributedNotificationCenter.default().postNotificationName(showWindowName, object: String(app.processIdentifier),
                                                                     userInfo: nil, deliverImmediately: true)
    }

    /// Runs `show` whenever a later launch hands over to this one.
    static func listen(_ show: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: showWindowName, object: String(getpid()),
                                                            queue: .main) { _ in
            MainActor.assumeIsolated { show() }
        }
    }

    /// Another process's launch arguments (KERN_PROCARGS2), nil when they cannot be read.
    private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        // The executable path, then padding, then argv.
        while i < size && buffer[i] != 0 { i += 1 }
        while i < size && buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
