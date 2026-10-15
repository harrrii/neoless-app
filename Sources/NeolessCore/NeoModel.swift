import Foundation

// 设置 › Neo 处理中心 › 识别模型: which of the Neo's two speech models a dictation asks for, or none of them
// (本机识别: this Mac's own transcript is polished as it is), and what the row says about the choice. The app keeps
// the choice and sends it with each recording; the Neo decides when it is too busy for the large model. A Neo that
// has not said it has two models is asked for nothing, and the row says why the choice does nothing there.

/// The Neo's speech models by name, as far as its `GET /v1/health` says. Any of them may be missing (an older
/// hub names only the model it would use right now), and a name that is not one short line counts as missing.
/// Which of them are named says what the Neo does with a choice (`support`).
public struct NeoModelNames: Equatable, Sendable {
    /// The model the Neo uses now for a recording that leaves the choice to it.
    public let current: String?
    public let large: String?
    public let small: String?

    /// The longest name shown. Model names are short ("Qwen3-ASR-1.7B-4bit"); anything longer is not one.
    public static let maxLength = 48

    public init(current: String? = nil, large: String? = nil, small: String? = nil) {
        self.current = Self.clean(current)
        self.large = Self.clean(large)
        self.small = Self.clean(small)
    }

    /// A name fit for a line of text, or nil: trimmed, not empty, one line, no control characters, not too long.
    static func clean(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              name.count <= maxLength,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) })
        else { return nil }
        return name
    }

    /// What a Neo that answered with these names does with a choice.
    public var support: NeoModelSupport {
        guard let large else { return .outdated }
        guard let small, small != large else { return .single }
        return .both
    }

    /// A name as a line shows it: with hyphens that do not break, so "Qwen3-ASR-1.7B-4bit" stays in one piece
    /// when the line wraps.
    static func shown(_ name: String) -> String {
        name.replacingOccurrences(of: "-", with: "\u{2011}")
    }
}

/// What a Neo does with 识别模型, as far as it has said.
public enum NeoModelSupport: Equatable, Sendable {
    /// It has not answered yet (out of reach since the app started, or its recognition is down).
    case unknown
    /// Its hub or worker is from before the choice: it names neither model and reads no choice.
    case outdated
    /// One model for every recording, whatever is asked for.
    case single
    /// A large and a small one: it uses the one a recording asks for.
    case both
}

/// The 识别模型 setting. The raw values are what is stored; those of the Neo's models (`neoModels`) are also the names
/// the hub's request field uses.
public enum NeoModelChoice: String, CaseIterable, Identifiable, Sendable {
    /// The large model, the small one while the Neo is too busy for it. What a request without the field means.
    case auto
    /// Always the large model.
    case large
    /// Always the small model.
    case small
    /// None of the Neo's models: this Mac's own transcript (the live caption it makes while the user speaks) goes to
    /// the Neo as text to be polished, and the recording is not sent at all, so nothing waits for the Neo to hear it
    /// again. Fastest; English names are more often wrong. When this Mac's transcript is missing or too short for the
    /// recording (`LocalRecognition.usable`), the recording goes to the Neo as with 自动, but without that transcript:
    /// one that cannot stand alone cannot stand in for the Neo's either. An older version reads the stored value as
    /// 自动.
    case local

    public var id: String { rawValue }

    /// The choices that are one of the Neo's speech models: what the hub's request field can name.
    public static let neoModels: [NeoModelChoice] = [.auto, .large, .small]

    /// What was stored: anything unknown (nothing yet, a value from a newer version) is 自动.
    public init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? .auto
    }

    /// The pop-up's entry: the choice, and in a word or two what it is for.
    public var title: String {
        switch self {
        case .auto: return "自动（推荐）"
        case .large: return "大模型（更准，慢一些）"
        case .small: return "小模型（更快）"
        case .local: return "本机识别（最快）"
        }
    }

    /// The Neo hears the recording: false for 本机识别, whose recordings go to the Neo only as this Mac's text.
    public var usesNeoRecognition: Bool { self != .local }

    /// The line under the row while the choice does nothing: 用 Neo 处理 is off …
    public static let off = "用 Neo 处理时才起作用"
    /// … or on, with no Neo paired yet …
    public static let unpaired = "和 Neo 配对后才起作用"
    /// … or, for one of the Neo's models, the Neo has not said yet what it has (`NeoModelSupport.unknown`) …
    public static let unknown = "连上 Neo 后才能选大模型、小模型"
    /// … or its hub is from before the choice (`.outdated`) …
    public static let outdated = "Neo 更新后才能选大模型、小模型"
    /// … or it runs one model for everything (`.single`).
    public static let single = "这台 Neo 只有一个识别模型"

    /// What a recording asks a Neo with `support` for. A Neo that would not act on the choice is asked for
    /// nothing (自动), so nothing is waited for, or left out of the request, for a model it would not use. One
    /// that has not said yet is asked for the choice: the choice could only be made while a Neo had both.
    /// 本机识别 asks for no model either when its recording does go to the Neo (the request field cannot name it).
    public func asked(of support: NeoModelSupport) -> NeoModelChoice {
        switch support {
        case .both, .unknown: return self
        case .outdated, .single: return .auto
        }
    }

    /// The line under the row: what this choice does, with the models' names where the Neo told them.
    public func detail(_ names: NeoModelNames = NeoModelNames()) -> String {
        switch self {
        case .auto:
            let rule = "平时用大模型，Neo 忙时自动换小模型"
            guard let current = names.current else { return rule }
            if current == names.large { return rule + "。现在用的是大模型" }
            if current == names.small { return rule + "。现在用的是小模型" }
            return rule + "。现在用的是 \(NeoModelNames.shown(current))"
        case .large:
            return "一直用大模型" + Self.named(names.large) + "，Neo 忙时要多等一会儿"
        case .small:
            return "一直用小模型" + Self.named(names.small) + "，没有大模型准"
        case .local:
            return Self.localDetail
        }
    }

    /// The line under the row for 本机识别, whatever the Neo has.
    public static let localDetail = "说完直接整理这台 Mac 识别的文字，不等 Neo 再识别一遍；英文专有名词可能不准，本机没听清时照常交给 Neo"

    private static func named(_ name: String?) -> String {
        name.map { "（\(NeoModelNames.shown($0))）" } ?? ""
    }
}

/// The 识别模型 row in Settings: whether the choice can be made, which entries the pop-up offers, and the line under
/// it. With 用 Neo 处理 on and a Neo paired the pop-up works; the large and the small model are offered only while
/// that Neo has said it has both (otherwise the line says what is missing, so no line promises a model the Neo would
/// not use), 自动 and 本机识别 always. A stored large or small choice stays in the list so the pop-up can show it.
public struct NeoModelRow: Equatable, Sendable {
    public let enabled: Bool
    public let detail: String
    /// The pop-up's entries, in menu order.
    public let choices: [NeoModelChoice]

    /// `hubEnabled`: 用 Neo 处理 is on; `paired`: with a Neo; `support` and `names`: what that Neo last said.
    public init(choice: NeoModelChoice, hubEnabled: Bool, paired: Bool, support: NeoModelSupport,
                names: NeoModelNames = NeoModelNames()) {
        guard hubEnabled else { self.init(enabled: false, detail: NeoModelChoice.off, choices: NeoModelChoice.allCases); return }
        guard paired else { self.init(enabled: false, detail: NeoModelChoice.unpaired, choices: NeoModelChoice.allCases); return }
        guard support != .both else { self.init(enabled: true, detail: choice.detail(names), choices: NeoModelChoice.allCases); return }
        let offered = NeoModelChoice.allCases.filter { $0 == .auto || $0 == .local || $0 == choice }
        switch (choice, support) {
        case (.local, _): self.init(enabled: true, detail: NeoModelChoice.localDetail, choices: offered)
        case (_, .unknown): self.init(enabled: true, detail: NeoModelChoice.unknown, choices: offered)
        case (_, .outdated): self.init(enabled: true, detail: NeoModelChoice.outdated, choices: offered)
        default: self.init(enabled: true, detail: NeoModelChoice.single, choices: offered)
        }
    }

    private init(enabled: Bool, detail: String, choices: [NeoModelChoice]) {
        self.enabled = enabled
        self.detail = detail
        self.choices = choices
    }
}

/// 本机识别: whether this Mac's own transcript of a recording is worth polishing as it is, without the Neo hearing the
/// recording (`NeoModelChoice.local`). Otherwise the recording goes to the Neo as usual.
public enum LocalRecognition {
    /// A recording up to this long is taken with any transcript that has a letter or a digit in it ("好").
    public static let checkedFrom: TimeInterval = 6
    /// A longer one needs at least one letter or digit per this many seconds of it. People say 4–5 Chinese
    /// characters a second; a long recording with a word or two in its transcript is one the live recognizer mostly
    /// missed (the Neo's model is asked instead, which costs the time 本机识别 saves, never the words).
    public static let secondsPerLetter: TimeInterval = 3

    public static func usable(_ text: String, audioSeconds: Double) -> Bool {
        let letters = text.reduce(0) { $0 + ($1.isLetter || $1.isNumber ? 1 : 0) }
        guard letters > 0 else { return false }
        let seconds = audioSeconds.isFinite ? max(0, audioSeconds) : 0
        return seconds <= checkedFrom || Double(letters) >= seconds / secondsPerLetter
    }
}
