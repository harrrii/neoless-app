import Foundation

// Decisions for the app around the dictation loop: the menu-bar warning, the Accessibility 允许
// button, which app gets focus when the window closes, the single-instance guard, the 🌐-key check
// and the corrupt-file notice. The app target gathers the facts; these decide.

// MARK: - Can dictation work right now?

/// The facts the menu-bar icon is decided from. Gathered by the app: permissions and the hotkey tap
/// every few seconds, the speech model and the ChatGPT login more slowly.
public struct ServiceFacts: Equatable, Sendable {
    public enum ChatGPT: Equatable, Sendable { case ready, signedOut }
    /// 用 Neo 处理: off (or not paired), working (or not checked yet), out of reach, no longer accepting
    /// this Mac, stopped by Cloudflare Access in front of it (双重锁), refusing what did not come through Access
    /// (its own check, with Access not set up right), reached but its recognition is down, or reached but its
    /// ChatGPT is down. All but the first two are soft: the Mac does (part of) the work itself meanwhile, and its
    /// own ChatGPT login counts again.
    public enum Hub: Equatable, Sendable {
        case off, connected, unreachable, revoked, accessDenied, accessRequired, cannotRecognize, cannotPolish
    }

    public var accessibility: Bool
    public var microphone: Bool
    public var speech: Bool
    /// The user's 用快捷键开始／结束 switch.
    public var hotkeyEnabled: Bool
    /// The event tap is up.
    public var hotkeyRunning: Bool
    /// The on-device model for the chosen recognition language is there.
    public var speechModel: Bool
    /// The chosen mode sends text to ChatGPT (natural, structured).
    public var polishes: Bool
    public var chatGPT: ChatGPT
    public var hub: Hub

    public init(accessibility: Bool, microphone: Bool, speech: Bool, hotkeyEnabled: Bool, hotkeyRunning: Bool,
                speechModel: Bool, polishes: Bool, chatGPT: ChatGPT, hub: Hub = .off) {
        self.accessibility = accessibility
        self.microphone = microphone
        self.speech = speech
        self.hotkeyEnabled = hotkeyEnabled
        self.hotkeyRunning = hotkeyRunning
        self.speechModel = speechModel
        self.polishes = polishes
        self.chatGPT = chatGPT
        self.hub = hub
    }
}

/// One reason dictation does not fully work. Ordered: the first one is what the menu says.
public enum ServiceProblem: Equatable, Sendable, CaseIterable {
    case accessibility, hotkey, microphone, speech, speechModel, hubRevoked, hubAccessDenied, hubAccessRequired,
         hubUnreachable, hubCannotRecognize, signedOut

    /// Dictation does not work at all (or Fn does nothing). The others still type: the Mac's own result
    /// when the Neo is out of reach, the raw transcript without a ChatGPT login.
    public var blocks: Bool {
        switch self {
        case .signedOut, .hubUnreachable, .hubRevoked, .hubAccessDenied, .hubAccessRequired,
             .hubCannotRecognize: return false
        default: return true
        }
    }

    /// One short sentence for the first line of the menu-bar menu and the icon's tooltip. The hotkey
    /// problems name the key the user picked (Fn, 右侧 Option…).
    public func message(for trigger: HotkeyTrigger) -> String {
        switch self {
        case .microphone: return "没有麦克风权限，无法录音"
        case .speech: return "没有语音识别权限，无法识别"
        case .speechModel: return "离线识别模型还没下载，无法识别"
        case .accessibility: return "没有辅助功能权限，\(trigger.keyName) 用不了"
        case .hotkey: return "快捷键没连上，\(trigger.keyName) 暂时用不了"
        case .signedOut: return "没有登录 ChatGPT，只输入原文"
        case .hubUnreachable: return "连不上 Neo，用本机处理"
        case .hubRevoked: return "Neo 配对已失效，用本机处理"
        case .hubAccessDenied: return "Cloudflare 门禁没放行，用本机处理"
        case .hubAccessRequired: return "Cloudflare 门禁没设好，用本机处理"
        case .hubCannotRecognize: return "Neo 的识别暂时不可用，先用本机识别"
        }
    }
}

public enum ServiceHealth: Equatable, Sendable {
    case ok
    /// Dictation works but types the raw transcript (ChatGPT login).
    case degraded(ServiceProblem)
    /// Dictation cannot work.
    case broken(ServiceProblem)

    public static func evaluate(_ f: ServiceFacts) -> ServiceHealth {
        guard let first = problems(f).first else { return .ok }
        return first.blocks ? .broken(first) : .degraded(first)
    }

    /// Every problem, most serious first.
    public static func problems(_ f: ServiceFacts) -> [ServiceProblem] {
        var out: [ServiceProblem] = []
        if !f.accessibility { out.append(.accessibility) }
        // A switched-off hotkey is the user's choice, not a problem.
        if f.accessibility && f.hotkeyEnabled && !f.hotkeyRunning { out.append(.hotkey) }
        if !f.microphone { out.append(.microphone) }
        if !f.speech { out.append(.speech) }
        // Without the speech permission the model state is not worth a second line.
        if f.speech && !f.speechModel { out.append(.speechModel) }
        switch f.hub {
        // The Neo's ChatGPT down is said only through this Mac's login below: with it, this Mac polishes.
        case .off, .connected, .cannotPolish: break
        case .unreachable: out.append(.hubUnreachable)
        case .revoked: out.append(.hubRevoked)
        case .accessDenied: out.append(.hubAccessDenied)
        case .accessRequired: out.append(.hubAccessRequired)
        case .cannotRecognize: out.append(.hubCannotRecognize)
        }
        // A working Neo polishes with its own login: the Mac's matters only when it does the work itself.
        if f.polishes && f.hub != .connected {
            if f.chatGPT == .signedOut { out.append(.signedOut) }
        }
        return out
    }

    public var problem: ServiceProblem? {
        switch self {
        case .ok: return nil
        case .degraded(let p), .broken(let p): return p
        }
    }
}

// MARK: - Accessibility 允许 button

/// What the Accessibility 允许 button does. The system alert ("neoless would like to control this
/// computer") comes first: it has its own 打开系统设置 button, and asking for it is what puts neoless
/// (back) into the Settings › Accessibility list. A second click opens the pane instead, so the two
/// never stack. Kept for this launch only and forgotten once access is seen granted: a rebuilt
/// (ad-hoc signed) app, a `tccutil reset` or an entry removed with − all need the alert again to be
/// listed, and macOS does not add the app any other way.
public struct AccessibilityAsk: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// Ask macOS for the alert (AXIsProcessTrustedWithOptions with prompt), and nothing else.
        case systemPrompt
        /// The alert was already asked for since access was last seen: open the pane.
        case openSettings
    }

    private var prompted = false

    public init() {}

    /// The button was clicked. nil when access is already granted: nothing to do.
    public mutating func click(trusted: Bool) -> Step? {
        guard !trusted else {
            prompted = false
            return nil
        }
        if prompted { return .openSettings }
        prompted = true
        return .systemPrompt
    }

    /// Access was seen granted. If it is lost later, the next click asks for the alert again.
    public mutating func granted() {
        prompted = false
    }
}

// MARK: - Giving focus back when the window closes

/// Which app gets focus when the window closes. neoless, an accessory app with no window, would
/// otherwise stay the active app and the next dictation would type nowhere.
public enum FocusHandBack {
    public struct App: Equatable, Sendable {
        public var pid: Int32
        /// A normal app with a Dock icon (activation policy .regular). Agents never get focus back:
        /// the accessibility alert's helper, launchers such as Raycast or Alfred, menu-bar tools.
        public var isRegular: Bool
        public var isTerminated: Bool

        public init(pid: Int32, isRegular: Bool, isTerminated: Bool = false) {
            self.pid = pid
            self.isRegular = isRegular
            self.isTerminated = isTerminated
        }
    }

    public enum Choice: Equatable, Sendable {
        case activate(Int32)
        /// Step aside and let macOS pick the next app. Never hide neoless: that hides the capsule too.
        case deactivate
    }

    /// Whether an app that just came to the front is the one to give focus back to later.
    public static func remembers(_ app: App, selfPID: Int32) -> Bool {
        app.pid != selfPID && app.isRegular && !app.isTerminated
    }

    /// The previous app while it still runs; else the owner of the frontmost window on screen
    /// (`windowOwners` front to back), the app the user sees behind neoless; else let macOS pick.
    public static func choose(previous: App?, windowOwners: [App], selfPID: Int32) -> Choice {
        if let p = previous, remembers(p, selfPID: selfPID) { return .activate(p.pid) }
        if let w = windowOwners.first(where: { remembers($0, selfPID: selfPID) }) { return .activate(w.pid) }
        return .deactivate
    }
}

// MARK: - One running copy

public enum SingleInstance {
    /// Command-line checks that run inside the same bundle (see the app's DebugCommands). A process
    /// started with one of them is never the running app and never makes the real app quit.
    public static let debugFlags: Set<String> = ["--test-polish", "--polish-eval", "--test-callback",
                                                 "--snapshot", "--snapshot-hud", "--check-keys"]

    public static func isDebugRun(_ arguments: [String]) -> Bool {
        arguments.contains { debugFlags.contains($0) }
    }

    /// Another process with the same bundle identifier.
    public struct Peer: Equatable, Sendable {
        public var pid: Int32
        public var launched: Date?
        /// Activation policy .prohibited (debug commands set it) or launched with a debug flag.
        public var isDebug: Bool

        public init(pid: Int32, launched: Date?, isDebug: Bool) {
            self.pid = pid
            self.launched = launched
            self.isDebug = isDebug
        }
    }

    /// The running app this launch should hand over to (show its window, then quit), or nil to keep
    /// running. The older copy wins; equal or unknown launch times fall back to the lower pid, so two
    /// copies started together never both quit.
    public static func yield(to peers: [Peer], selfPID: Int32, selfLaunched: Date?) -> Peer? {
        peers.filter { !$0.isDebug && $0.pid != selfPID }
            .filter { isOlder($0, than: selfPID, launched: selfLaunched) }
            .min { isOlder($0, than: $1.pid, launched: $1.launched) }
    }

    private static func isOlder(_ p: Peer, than pid: Int32, launched: Date?) -> Bool {
        if let a = p.launched, let b = launched, a != b { return a < b }
        return p.pid < pid
    }
}

// MARK: - 🌐 key

/// System Settings › Keyboard › "Press 🌐 key to" (`AppleFnUsageType` in com.apple.HIToolbox).
public enum GlobeKeyUsage: Equatable, Sendable {
    /// 不执行任何操作: Fn is free for neoless.
    case doNothing
    /// Emoji, input source or Apple Dictation: every Fn tap also does that.
    case action(Int)
    /// The key was never written: macOS uses its default, which is not 不执行任何操作 (switch input
    /// source or show emoji, depending on the Mac), so it fires too, but we cannot say which.
    case systemDefault

    public init(storedValue: Int?) {
        switch storedValue {
        case nil: self = .systemDefault
        case 0?: self = .doNothing
        case let v?: self = .action(v)
        }
    }

    /// Fn taps also trigger a system function.
    public var conflicts: Bool { self != .doNothing }

    /// One number per value, for remembering which value the user dismissed the advice for.
    public var token: Int {
        switch self {
        case .doNothing: return 0
        case .action(let v): return v
        case .systemDefault: return -1
        }
    }
}

// MARK: - Files set aside this launch

public enum RecoveredFiles {
    /// The data file a backup was made from: `history.json.corrupt-20261007-204500-2` → `history.json`.
    public static func original(of backup: String) -> String? {
        guard let r = backup.range(of: ".corrupt-") else { return nil }
        let name = String(backup[..<r.lowerBound])
        return name.isEmpty ? nil : name
    }

    /// One line for the window: which data could not be read and that a copy was kept. nil when nothing
    /// was set aside. `title` names a data file for people (`history.json` → 历史记录).
    public static func notice(_ backups: [String], title: (String) -> String) -> String? {
        var names: [String] = []
        for b in backups {
            guard let o = original(of: b) else { continue }
            let t = title(o)
            if !names.contains(t) { names.append(t) }
        }
        guard !names.isEmpty else { return nil }
        return names.joined(separator: "、") + "读不出来，已备份原文件"
    }
}
