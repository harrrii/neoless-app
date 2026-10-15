import Foundation

// The home page's 完成设置 checklist and the sidebar's 还差 N 步: which rows show, which are done, and
// which ones count. The app gathers the facts; this decides.

/// One row of the checklist.
public enum SetupStep: String, Equatable, Sendable, CaseIterable {
    case microphone, speech
    /// The on-device recognizer for the chosen language (系统设置 › 键盘 › 听写).
    case speechModel
    case accessibility
    /// Accessibility is granted but the event tap is not up yet: shown with a spinner, nothing to click.
    case hotkey
    case chatGPT
    /// System Settings › Keyboard › "Press 🌐 key to" still does something, so every Fn tap does it too.
    case globeKey
}

public struct SetupFacts: Equatable, Sendable {
    public var microphone: Bool
    public var speech: Bool
    public var accessibility: Bool
    /// The user's 用快捷键开始／结束 switch.
    public var hotkeyEnabled: Bool
    /// The event tap is up.
    public var hotkeyRunning: Bool
    /// The on-device model for the recognition language is there. Only judged once speech is allowed.
    public var speechModel: Bool
    /// ChatGPT can polish: signed in.
    public var chatGPTReady: Bool
    /// The hotkey is Fn (🌐), the one key the 🌐 setting can get in the way of.
    public var triggerIsFn: Bool
    public var globeKey: GlobeKeyUsage
    /// The default mode sends text to ChatGPT (自然整理, 结构化). In 原样转写 the login is not needed.
    public var polishes: Bool
    /// The user said 不再提示 to the 🌐 advice for the value `globeKey` has now (`GlobeKeyUsage.token`).
    public var globeHintDismissed: Bool

    public init(microphone: Bool, speech: Bool, accessibility: Bool, hotkeyEnabled: Bool, hotkeyRunning: Bool,
                speechModel: Bool, chatGPTReady: Bool, triggerIsFn: Bool, globeKey: GlobeKeyUsage,
                polishes: Bool = true, globeHintDismissed: Bool = false) {
        self.microphone = microphone
        self.speech = speech
        self.accessibility = accessibility
        self.hotkeyEnabled = hotkeyEnabled
        self.hotkeyRunning = hotkeyRunning
        self.speechModel = speechModel
        self.chatGPTReady = chatGPTReady
        self.triggerIsFn = triggerIsFn
        self.globeKey = globeKey
        self.polishes = polishes
        self.globeHintDismissed = globeHintDismissed
    }
}

public struct SetupRow: Equatable, Sendable {
    public var step: SetupStep
    public var done: Bool
    /// Counted in 还差 N 步 while missing. False for advice that does not stop dictation: the 🌐 key,
    /// and ChatGPT while the mode is 原样转写.
    public var counts: Bool

    public init(step: SetupStep, done: Bool, counts: Bool = true) {
        self.step = step
        self.done = done
        self.counts = counts
    }
}

public enum SetupChecklist {
    /// The rows to show, in order. Rows that cannot be judged yet are left out: the speech model
    /// before speech recognition is allowed, the hotkey before Accessibility (and when it is switched
    /// off). ChatGPT counts only when the mode polishes. The 🌐 row shows only while it gets in the way and the user has not dismissed it, and
    /// never counts: Fn still dictates, it just also does the system's thing.
    public static func rows(_ f: SetupFacts) -> [SetupRow] {
        var rows = [SetupRow(step: .microphone, done: f.microphone), SetupRow(step: .speech, done: f.speech)]
        if f.speech { rows.append(SetupRow(step: .speechModel, done: f.speechModel)) }
        rows.append(SetupRow(step: .accessibility, done: f.accessibility))
        if hotkeyPending(f) { rows.append(SetupRow(step: .hotkey, done: false)) }
        rows.append(SetupRow(step: .chatGPT, done: f.chatGPTReady, counts: f.polishes))
        if globeKeyConflicts(f), !f.globeHintDismissed { rows.append(SetupRow(step: .globeKey, done: false, counts: false)) }
        return rows
    }

    /// 还差 N 步: missing rows that count.
    public static func remaining(_ f: SetupFacts) -> Int {
        rows(f).filter { !$0.done && $0.counts }.count
    }

    /// The checklist card shows while a step that counts is missing. Advice alone never keeps it up:
    /// the 🌐 key then gets one quiet line (`globeHint`), and ChatGPT in 原样转写 nothing.
    public static func shows(_ f: SetupFacts) -> Bool {
        remaining(f) > 0
    }

    /// Everything that counts is done, but Fn also does what "按下 🌐 键时" says, and the user has not
    /// said 不再提示: the home page shows one quiet line instead of the card.
    public static func globeHint(_ f: SetupFacts) -> Bool {
        !shows(f) && globeKeyConflicts(f) && !f.globeHintDismissed
    }

    /// Nothing can be recorded or recognized yet (a permission or the speech model is missing): the
    /// home page leads with the checklist instead of "按 fn 开始说话".
    public static func blocksDictation(_ f: SetupFacts) -> Bool {
        !f.microphone || !f.speech || !f.accessibility || !f.speechModel
    }

    /// Accessibility is granted and the hotkey is on, but the tap is not up yet.
    public static func hotkeyPending(_ f: SetupFacts) -> Bool {
        f.accessibility && f.hotkeyEnabled && !f.hotkeyRunning
    }

    /// Fn is the hotkey and every Fn tap also does what "按下 🌐 键时" says.
    public static func globeKeyConflicts(_ f: SetupFacts) -> Bool {
        f.triggerIsFn && f.hotkeyEnabled && f.globeKey.conflicts
    }
}

/// Words for "按下 🌐 键时", shared by the home page and Settings. The labels are the ones System
/// Settings › 键盘 shows in Chinese (按下🌐︎键时, 不执行任何操作, 显示表情与符号, 开始听写（连按两下🌐︎键）).
public enum GlobeKeyText {
    /// What Fn does besides dictating, as a short title: "fn 也会切换输入法".
    public static func title(_ usage: GlobeKeyUsage) -> String {
        switch usage {
        case .doNothing: return ""
        case .action(1): return "fn 也会切换输入法"
        case .action(2): return "fn 也会打开表情与符号"
        case .action(3): return "连按两下 fn 会打开系统听写"
        case .action: return "fn 也会触发系统功能"
        case .systemDefault: return "fn 可能也会切换输入法或打开表情"
        }
    }

    /// The same as one sentence for the home page's line: "每次按 fn，系统还会切换输入法。"
    public static func sentence(_ usage: GlobeKeyUsage) -> String {
        switch usage {
        case .doNothing: return ""
        case .action(1): return "每次按 fn，系统还会切换输入法。"
        case .action(2): return "每次按 fn，系统还会打开表情与符号。"
        // Only a double press: a quick start-and-stop with fn.
        case .action(3): return "连按两下 fn 会打开系统听写。"
        case .action: return "按 fn 时系统也会做别的事。"
        case .systemDefault: return "按 fn 时系统可能也会切换输入法或打开表情。"
        }
    }

    /// The fix, as a detail line (no full stop). The globe in its text style (U+FE0E), as System
    /// Settings draws it, not the colour emoji.
    public static let fix = "在键盘设置里" + change

    /// The change itself, for a sentence that already says where: "把“按下🌐键时”改成“不执行任何操作”",
    /// spaced exactly as System Settings writes the label (no spaces around the globe).
    public static let change = "把“按下🌐\u{FE0E}键时”改成“不执行任何操作”"
}
