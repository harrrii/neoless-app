import Foundation
import NeolessCloud
import NeolessCore

/// User preferences. Everything is stored in UserDefaults and takes effect immediately.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var mode: DictationMode { didSet { d.set(mode.rawValue, forKey: "mode") } }
    @Published var trigger: HotkeyTrigger { didSet { d.set(trigger.rawValue, forKey: "trigger") } }
    @Published var hotkeyEnabled: Bool { didSet { d.set(hotkeyEnabled, forKey: "hotkeyEnabled") } }
    @Published var localeID: String {
        didSet {
            d.set(localeID, forKey: "localeID")
            // Load the new language's recognizer now, not on the next dictation.
            SpeechSession.warmUp(localeID: localeID)
        }
    }
    @Published var microphoneUID: String { didSet { d.set(microphoneUID, forKey: "microphoneUID") } }
    @Published var model: String { didSet { d.set(model, forKey: "model") } }
    @Published var fastTier: Bool { didSet { d.set(fastTier, forKey: "fastTier") } }
    @Published var polishTimeout: Double { didSet { d.set(polishTimeout, forKey: "polishTimeout") } }
    @Published var restoreClipboard: Bool { didSet { d.set(restoreClipboard, forKey: "restoreClipboard") } }
    @Published var keepHistory: Bool { didSet { d.set(keepHistory, forKey: "keepHistory") } }
    /// 录音浮层位置 › 跟随光标: show the recording pill under the text caret. Off (the default) keeps it
    /// at the bottom centre of the screen, like Typeless and OpenLess.
    @Published var hudFollowsCaret: Bool { didSet { d.set(hudFollowsCaret, forKey: "hudFollowsCaret") } }
    /// One line of live transcript above the recording pill.
    @Published var liveTranscript: Bool { didSet { d.set(liveTranscript, forKey: "liveTranscript") } }
    /// Use the structured (prompt-style) polish automatically when dictating into AI apps (Codex, Claude, ChatGPT…).
    @Published var autoStructuredForAI: Bool { didSet { d.set(autoStructuredForAI, forKey: "autoStructuredForAI") } }
    @Published var hotkeyStyle: HotkeyStyle { didSet { d.set(hotkeyStyle.rawValue, forKey: "hotkeyStyle") } }
    /// End a hands-free recording after `SilenceWatch.limit` without speech (DictationController).
    @Published var silenceAutoStop: Bool { didSet { d.set(silenceAutoStop, forKey: "silenceAutoStop") } }
    /// The 🌐-key value (`GlobeKeyUsage.token`) the user said 不再提示 for on the home page. Another
    /// value (they changed the setting) brings the line back; Settings › 快捷键 always shows the row.
    /// 用 Neo 处理: send the recording to the paired Neo (`HubConnection`), this Mac's own path as the fallback.
    @Published var hubEnabled: Bool { didSet { d.set(hubEnabled, forKey: "hubEnabled") } }
    /// The Neo's address, for pairing with a bare token (a pairing link brings its own).
    @Published var hubAddress: String { didSet { d.set(hubAddress, forKey: "hubAddress") } }
    /// 识别模型: which of the Neo's two speech models each recording asks for (`NeoModelChoice.requested`), or 本机识别:
    /// this Mac's own transcript, polished by the Neo without the recording (`NeoModelChoice.local`).
    @Published var asrModel: NeoModelChoice { didSet { d.set(asrModel.rawValue, forKey: "asrModel") } }
    @Published var globeHintDismissed: Int? {
        didSet {
            if let globeHintDismissed { d.set(globeHintDismissed, forKey: "globeHintDismissed") }
            else { d.removeObject(forKey: "globeHintDismissed") }
        }
    }

    static let models: [(id: String, title: String)] = [
        ("gpt-6.1-sol", "GPT-6.1-Sol（推荐）"),
        ("gpt-6-luna", "GPT-6-Luna（更快）"),
        ("gpt-5.6-luna", "GPT-5.6-Luna"),
    ]

    static let locales: [(id: String, title: String)] = [
        ("zh-CN", "中文（普通话）"),
        ("en-US", "English (US)"),
    ]

    /// Empty: prefer the built-in microphone (so AirPods keep high-quality playback);
    /// "system": follow the macOS default input; otherwise a device UID.
    static let microphoneAuto = AppSettingsKeys.microphoneAuto
    static let microphoneSystem = AppSettingsKeys.microphoneSystem

    private init() {
        d.register(defaults: [
            "mode": DictationMode.natural.rawValue, "trigger": HotkeyTrigger.fn.rawValue, "hotkeyEnabled": true,
            "localeID": "zh-CN", "microphoneUID": Self.microphoneAuto, "model": "gpt-6.1-sol", "fastTier": true,
            "polishTimeout": 10.0, "restoreClipboard": true, "keepHistory": true,
            "hudFollowsCaret": false, "liveTranscript": true, "autoStructuredForAI": true,
            "hotkeyStyle": HotkeyStyle.auto.rawValue, "silenceAutoStop": true,
            "hubEnabled": true, "hubAddress": "",
        ])
        mode = DictationMode(rawValue: d.string(forKey: "mode") ?? "") ?? .natural
        trigger = HotkeyTrigger(rawValue: d.string(forKey: "trigger") ?? "") ?? .fn
        hotkeyEnabled = d.bool(forKey: "hotkeyEnabled")
        localeID = d.string(forKey: "localeID") ?? "zh-CN"
        microphoneUID = d.string(forKey: "microphoneUID") ?? Self.microphoneAuto
        model = d.string(forKey: "model") ?? "gpt-6.1-sol"
        fastTier = d.bool(forKey: "fastTier")
        polishTimeout = d.double(forKey: "polishTimeout")
        restoreClipboard = d.bool(forKey: "restoreClipboard")
        keepHistory = d.bool(forKey: "keepHistory")
        hudFollowsCaret = d.bool(forKey: "hudFollowsCaret")
        liveTranscript = d.bool(forKey: "liveTranscript")
        autoStructuredForAI = d.bool(forKey: "autoStructuredForAI")
        hotkeyStyle = HotkeyStyle(rawValue: d.string(forKey: "hotkeyStyle") ?? "") ?? .auto
        silenceAutoStop = d.bool(forKey: "silenceAutoStop")
        hubEnabled = d.bool(forKey: "hubEnabled")
        hubAddress = d.string(forKey: "hubAddress") ?? ""
        asrModel = NeoModelChoice(stored: d.string(forKey: "asrModel"))
        globeHintDismissed = d.object(forKey: "globeHintDismissed") as? Int
    }

    /// The mode for one dictation into this app: 自然整理 becomes 结构化 in AI apps when autoStructuredForAI is on.
    /// Pass the app that was frontmost when recording started (`bundleIdentifier`, `localizedName`); polish
    /// when the result `.polishes`, hand it to `Polisher.polish(mode:)` and keep it in the record's `mode`.
    func effectiveMode(forBundleID bundleID: String?, appName: String?) -> DictationMode {
        DictationMode.effective(mode, autoStructured: autoStructuredForAI, bundleID: bundleID, appName: appName)
    }
}

extension NeoModelChoice {
    /// What a recording's request carries (`DictationRequest.asrModel`). 自动 sends nothing: a request without
    /// the field means just that, and it is all a hub from before the field knows. Nor does 本机识别, whose recording
    /// goes to the Neo only when this Mac's transcript cannot stand alone, and is then a recording like any other.
    var requested: HubASRModel? {
        switch self {
        case .auto, .local: return nil
        case .large: return .large
        case .small: return .small
        }
    }
}
