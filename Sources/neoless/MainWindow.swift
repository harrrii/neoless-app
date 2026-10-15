import AppKit
import Carbon.HIToolbox
import NeolessCloud
import NeolessCore
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home, history, dictionary, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "听写"
        case .history: return "历史记录"
        case .dictionary: return "个人词典"
        case .settings: return "设置"
        }
    }
    var icon: String {
        switch self {
        case .home: return "waveform"
        case .history: return "clock"
        case .dictionary: return "character.book.closed"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
final class Router: ObservableObject {
    @Published var section: Page? = .home
    /// A record the history page should select when it next appears (set by 最近听写 on the home page).
    @Published var historySelection: UUID?
    /// 今日概览's chart: which days it shows and what it counts. Remembered between launches.
    @Published var chartRange: ChartRange {
        didSet { UserDefaults.standard.set(chartRange.rawValue, forKey: "overview.range") }
    }
    @Published var chartMetric: UsageMetric {
        didSet { UserDefaults.standard.set(chartMetric.rawValue, forKey: "overview.metric") }
    }

    init() {
        chartRange = ChartRange(rawValue: UserDefaults.standard.integer(forKey: "overview.range")) ?? .week
        chartMetric = UsageMetric(rawValue: UserDefaults.standard.string(forKey: "overview.metric") ?? "") ?? .count
    }

    func openHistory(selecting id: UUID? = nil) {
        historySelection = id
        section = .history
    }
}

/// Permission and hotkey state, refreshed while the window is open (AppDelegate runs the timer only then).
@MainActor
final class SystemStatus: ObservableObject {
    @Published var microphone = false
    @Published var speech = false
    @Published var accessibility = false
    @Published var hotkeyRunning = false
    @Published var globeKey: GlobeKeyUsage = .doNothing
    /// The on-device recognizer for the chosen language is there (系统设置 › 键盘 › 听写). Read only once
    /// speech recognition is allowed; until then it stays true and the 语音识别 row speaks for it.
    @Published var speechModel = true
    /// Some app holds Secure Event Input (a password field, Terminal's 安全键盘输入): the hotkey then
    /// works only as hold-to-talk (`HotkeyStateMachine`), whatever 快捷键方式 says.
    @Published var secureInput = false
    @Published var microphones: [AudioInputDevice] = []
    /// Data files that did not read back this launch and were set aside (`AppFiles.recovered`).
    @Published var recoveredFiles: [String] = []

    var hotkeyMonitor: HotkeyMonitor?
    /// 用 Neo 处理: while the Neo is in use it polishes with its own ChatGPT login.
    weak var hub: HubConnection?
    /// Snapshot rendering only: keep the values that were set by hand.
    var frozen = false

    func refresh() {
        guard !frozen else { return }
        // Assign only what changed: every assignment re-renders the window.
        update(\.microphone, Permissions.microphone == .authorized)
        update(\.speech, Permissions.speech == .authorized)
        update(\.accessibility, Permissions.accessibility)
        update(\.hotkeyRunning, hotkeyMonitor?.isRunning ?? false)
        update(\.globeKey, Permissions.globeKey)
        update(\.speechModel, !speech || SpeechSession.onDeviceAvailable(localeID: AppSettings.shared.localeID))
        update(\.secureInput, IsSecureEventInputEnabled())
        update(\.microphones, AudioDevices.inputs())
        update(\.recoveredFiles, AppFiles.recovered)
    }

    private func update<T: Equatable>(_ key: ReferenceWritableKeyPath<SystemStatus, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    /// One line for the home page when a data file was set aside this launch, else nil.
    var recoveredNotice: String? {
        RecoveredFiles.notice(recoveredFiles) { name in
            switch name {
            case "history.json": return "历史记录"
            case "vocabulary.json": return "个人词典"
            case "learning.json": return "学习记录"
            case "usage.json": return "使用统计"
            case "chatgpt-auth.json": return "ChatGPT 登录"
            default: return name
            }
        }
    }

    var allGranted: Bool { microphone && speech && accessibility }

    /// What the setup checklist is decided from (`SetupChecklist`).
    func setupFacts(account: ChatGPTAccount, settings: AppSettings) -> SetupFacts {
        // While the Neo does the work, this Mac's own login is only for the dictations it does itself. Out of
        // reach, refusing this Mac or unable to recognise, it does none: this Mac does them all.
        let neo = hub?.covers == true
        return SetupFacts(microphone: microphone, speech: speech, accessibility: accessibility,
                   hotkeyEnabled: settings.hotkeyEnabled, hotkeyRunning: hotkeyRunning, speechModel: speechModel,
                   chatGPTReady: account.isReady || neo,
                   triggerIsFn: settings.trigger == .fn, globeKey: globeKey, polishes: settings.mode.polishes,
                   globeHintDismissed: settings.globeHintDismissed == globeKey.token)
    }

    /// Setup steps still missing (permissions, the speech model, ChatGPT, hotkey). The 🌐 key is advice, and
    /// so is ChatGPT in 原样转写.
    func remainingSteps(account: ChatGPTAccount, settings: AppSettings) -> Int {
        SetupChecklist.remaining(setupFacts(account: account, settings: settings))
    }

    /// Hold-to-talk is all the hotkey does right now: secure input is on and the hotkey is up.
    func holdOnly(_ settings: AppSettings) -> Bool {
        secureInput && settings.hotkeyEnabled && hotkeyRunning && settings.hotkeyStyle != .hold
    }
}

struct MainView: View {
    @EnvironmentObject var router: Router
    @EnvironmentObject var status: SystemStatus

    /// The smallest the window gets: the sidebar, and a page with its margins and nothing squeezed.
    static let minSize = CGSize(width: 860, height: 580)

    var body: some View {
        NavigationSplitView {
            SidebarColumn()
                .navigationSplitViewColumnWidth(min: 232, ideal: 248, max: 300)
        } detail: {
            Group {
                switch router.section ?? .home {
                case .home: HomeView()
                case .history: HistoryView()
                case .dictionary: DictionaryView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.page.ignoresSafeArea())
        }
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
        .onAppear { status.refresh() }
    }
}

// MARK: - Sidebar

/// The sidebar, given the one thing it says about a dictation under way. While it records, the controller
/// publishes the microphone's level some twenty times a second, and whatever observes the controller is
/// evaluated again each time. So only this view observes it: it reads one value and hands it on, and the
/// sidebar itself (four rows and the status line) is evaluated only when that value changes.
struct SidebarColumn: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        Sidebar(activity: Sidebar.Activity(controller.phase)).equatable()
    }
}

struct Sidebar: View, Equatable {
    /// What the status line says while a dictation is under way.
    enum Activity: Equatable {
        case listening, tidying

        init?(_ phase: Phase) {
            switch phase {
            case .starting, .recording: self = .listening
            case .transcribing, .polishing: self = .tidying
            default: return nil
            }
        }

        var title: String { self == .listening ? "正在听写" : "正在整理" }
    }

    /// Nil when no dictation is under way.
    let activity: Activity?
    @EnvironmentObject var router: Router
    @EnvironmentObject var account: ChatGPTAccount
    @EnvironmentObject var status: SystemStatus
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var hub: HubConnection

    /// Its one input from outside; the stores it reads say for themselves when they change.
    nonisolated static func == (a: Sidebar, b: Sidebar) -> Bool { a.activity == b.activity }

    /// From the sidebar's edges to a row.
    private static let edge: CGFloat = 12
    private static let brandSize: CGFloat = 32
    /// Where the rows' icons start: the brand row and the status line follow it, so the mark, the icons and
    /// the status dot share one column, and the three kinds of text one line.
    private static let iconColumn = edge + SidebarRow.inset

    var body: some View {
        // The four pages are the app's whole map, so the sidebar is theirs: the name large on top, a tall
        // row each with type well up from the system's sidebar, and a selection the rows draw themselves,
        // which looks the same whether or not the sidebar has the keyboard.
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SidebarRow.spacing - (Self.brandSize - SidebarRow.iconWidth) / 2) {
                BrandMark(size: Self.brandSize)
                Text("neoless")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            // Centred on the icons under it.
            .padding(.leading, Self.iconColumn - (Self.brandSize - SidebarRow.iconWidth) / 2)
            .padding(.top, Space.s)
            .padding(.bottom, Space.l)
            VStack(spacing: SidebarRow.gap) {
                // ⌘1 … ⌘4, in place of the arrow keys a system list would give: the 显示 menu takes the keys
                // (`PageMenu`), each row says its own.
                ForEach(Array(Page.allCases.enumerated()), id: \.element) { index, page in
                    SidebarRow(page: page, selected: (router.section ?? .home) == page,
                               shortcut: PageShortcut.label(at: index), help: PageShortcut.help(at: index)) {
                        router.section = page
                    }
                }
            }
            .padding(.horizontal, Self.edge)
            Spacer(minLength: Space.l)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// State-aware, unboxed: what is missing, or that everything is ready. On the
    /// 听写 page the hero already says what is missing and links to the fix, so the footer is only a
    /// status line there; on the other pages it links to where the fix is.
    private var footer: some View {
        let remaining = status.remainingSteps(account: account, settings: settings)
        let problem = remaining > 0
        // While a dictation runs the line says so, like the page beside it (not "可以开始听写" under 正在听…).
        let running: String? = problem ? nil : activity?.title
        let title = problem ? "还差 \(remaining) 步" : (running ?? "可以开始听写")
        let detail: String? = problem ? (router.section == .home ? nil : "完成设置") : accountLine
        return Button { router.section = problem ? .home : .settings } label: {
            HStack(alignment: .top, spacing: SidebarRow.spacing) {
                // Under the rows' icons, on the first line's centre.
                Circle()
                    .fill(problem ? Theme.attention : (running == nil ? Theme.ready : Theme.accent))
                    .frame(width: 8, height: 8)
                    .frame(width: SidebarRow.iconWidth, height: 17)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(problem ? Theme.accent : .secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(problem ? "打开听写页完成设置" : footerHelp)
        .padding(.leading, Self.iconColumn)
        .padding(.trailing, Space.s)
        .padding(.bottom, Space.xl)
    }

    /// With the Neo in use, how it is (it does the work); otherwise this Mac's ChatGPT login.
    private var accountLine: String {
        if hub.isActive, let neo = hub.status.short { return neo }
        if account.isReady { return "ChatGPT 已登录" }
        return settings.mode.polishes ? "ChatGPT 未登录，只输入原文" : "ChatGPT 未登录"
    }

    private var footerHelp: String {
        if hub.isActive { return "Neo 处理中心：" + hub.status.text }
        return account.status.text
    }
}

/// One page in the sidebar: a tall row, the icon in a column of its own, the name large beside it, and at the
/// far end, small and grey, the key that opens it (⌘1). The page being shown has a quiet tint of the accent
/// behind it, its icon in the accent and its name heavier; the row draws that itself, so it is the same with
/// the keyboard in the sidebar, in the page, or in another app.
private struct SidebarRow: View {
    static let iconWidth: CGFloat = 26
    /// Between the icon column and the name.
    static let spacing: CGFloat = 12
    /// From the row's edge to its icon column.
    static let inset: CGFloat = 12
    static let height: CGFloat = 44
    /// Between two rows.
    static let gap: CGFloat = 4
    let page: Page
    let selected: Bool
    /// "⌘1": the key that opens the page, as a hint. Nil shows none.
    var shortcut: String?
    /// The tooltip: the key again, and that the digit alone works too.
    var help: String?
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Self.spacing) {
                Image(systemName: page.icon)
                    .font(.system(size: 19, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    .frame(width: Self.iconWidth)
                Text(page.title)
                    .font(.system(size: 16, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: Space.xs)
                if let shortcut {
                    // A hint, not a control: the lightest text on the row, the same on every row.
                    Text(shortcut)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, Self.inset)
            .frame(height: Self.height)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
        .accessibilityLabel(page.title)
        .accessibilityHint(shortcut ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var fill: Color {
        if selected { return Theme.accent.opacity(scheme == .dark ? 0.28 : 0.15) }
        return hovering ? Theme.fill : .clear
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var controller: DictationController
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var status: SystemStatus
    @EnvironmentObject var account: ChatGPTAccount
    @EnvironmentObject var router: Router
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var learning: LearningStore
    @EnvironmentObject var hub: HubConnection
    @EnvironmentObject var usage: UsageStore
    @State private var showRaw = false
    /// A long result shows its first lines until the user expands it or starts editing.
    @State private var expanded = false
    @State private var textHeight: CGFloat = 0
    /// How tall the latest result is as the folded preview draws it (its blank lines left out).
    @State private var previewHeight: CGFloat = 0
    @State private var hoveringText = false
    /// How tall the top of 最近听写 is (what is being said, the latest result) before it is given any spare
    /// height: the rows under it get the rest.
    @State private var topRowsHeight: CGFloat = 0
    /// The detail area's size. Its width decides the overview's layout (roomy from `Dash.roomy` on), its
    /// height how tall the chart row is. Zero until the page has been laid out once; the overview
    /// waits for it rather than guess.
    @State private var detail: CGSize = .zero
    /// How tall the page's content and its chart row came out: the difference is everything else on the page.
    @State private var heights = PageHeights()
    @FocusState private var editing: Bool

    var body: some View {
        let width = Dash.contentWidth(in: detail.width)
        // What the window has for the chart row and the margin under the page, once everything else on the
        // page (whatever that is today: a checklist, a notice, a headline on two lines) has its height. A
        // window with height to spare gives it to the chart row, so the page fills the window instead of
        // ending in a blank band. A window without it (a 13-inch screen as the window opens) changes
        // nothing: every card keeps its room and the page scrolls to the last one.
        let room: CGFloat? = width >= Dash.roomy && heights.pair > 0
            ? detail.height - PageMetrics.top - (heights.content - heights.pair) : nil
        PageColumn(width: Dash.pageWidth, bottomPadding: room.map(Dash.fittedBottomMargin(room:)) ?? Dash.bottomMargin) {
            VStack(alignment: .leading, spacing: Space.xl) {
                hero
                // While a dictation runs the page is about that dictation; the checklist waits. The hero
                // already says how many steps are left while they block dictation, so the card does not.
                if SetupChecklist.shows(setupFacts), !controller.phase.isActive { SetupCard(showsCount: !setupBlocked) }
                if status.holdOnly(settings), !controller.phase.isActive, !setupBlocked { holdOnlyHint }
                if SetupChecklist.globeHint(setupFacts), !controller.phase.isActive { globeHint }
                if let neo = neoNotice, !controller.phase.isActive, !setupBlocked { neoLine(neo) }
                if let notice = status.recoveredNotice { recovered(notice) }
                if detail.width > 0 { overview(width: width, cardHeight: room.map(Dash.fittedCardHeight(room:)) ?? Dash.cardHeight) }
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: PageHeightsKey.self, value: PageHeights(content: g.size.height))
            })
        }
        .background(GeometryReader { g in Color.clear.preference(key: DetailSizeKey.self, value: g.size) })
        .onPreferenceChange(DetailSizeKey.self) { detail = $0 }
        .onPreferenceChange(PageHeightsKey.self) { heights = $0 }
        .onChange(of: shown?.id) { _, _ in showRaw = false; expanded = false }
    }

    private var setupFacts: SetupFacts { status.setupFacts(account: account, settings: settings) }
    private var remainingSteps: Int { SetupChecklist.remaining(setupFacts) }

    /// A permission or the speech model is missing and nothing is running: the page leads with the checklist.
    private var setupBlocked: Bool {
        guard SetupChecklist.blocksDictation(setupFacts) else { return false }
        switch controller.phase {
        case .idle, .cancelled: return true
        default: return false
        }
    }

    /// The latest result: the controller's, or the newest history entry after a relaunch.
    private var shown: DictationRecord? { controller.current ?? history.records.first }

    // MARK: Hero — editorial headline with the primary action

    private var hero: some View {
        // Wide: title block and mode switch side by side, subtitle on one line.
        // Narrower: the subtitle wraps under the title and the switch stays on the headline's row.
        // Narrowest: the switch moves under the subtitle.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Space.l) {
                recordButton
                titleBlock(subtitleLines: 1)
                Spacer(minLength: 0)
                heroTrailing
            }
            HStack(alignment: .top, spacing: Space.l) {
                recordButton
                HStack(alignment: .top, spacing: Space.m) {
                    titleBlock(subtitleLines: 2, subtitleWidth: 240)
                    Spacer(minLength: 0)
                    // Centred on the headline, not on the whole block.
                    heroTrailing.frame(height: Self.headlineHeight)
                }
            }
            HStack(alignment: .top, spacing: Space.l) {
                recordButton
                VStack(alignment: .leading, spacing: Space.s) {
                    titleBlock(subtitleLines: 2)
                    if !controller.phase.isActive, !setupBlocked { modePicker }
                }
                Spacer(minLength: Space.m)
                if controller.phase.isActive { heroTrailing.frame(height: Self.headlineHeight) }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controller.phase)
    }

    /// Line height of the 26pt headline (with its key cap), for lining things up with it.
    private static let headlineHeight: CGFloat = 32

    private var recordButton: some View {
        RecordButton(phase: controller.phase, neutral: setupBlocked) { controller.toggle() }
    }

    private func titleBlock(subtitleLines: Int, subtitleWidth: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: Space.xs - 2) {
            // Steps down a size before it would truncate in a narrow window.
            ViewThatFits(in: .horizontal) {
                headline(size: Typo.heroSize)
                headline(size: 22)
                headline(size: 19)
            }
            .foregroundStyle(.primary)
            .lineLimit(1)
            .frame(minHeight: Self.headlineHeight)
            Group {
                if !settings.hotkeyEnabled, idleReady {
                    fixLine(caution: false, text: "快捷键已关闭，", link: "在设置里打开",
                            help: "设置 › 快捷键 › 用快捷键听写") { router.section = .settings }
                } else if let caution {
                    if let link = caution.link {
                        fixLine(caution: true, text: caution.text, link: link, help: "在设置里登录 ChatGPT") {
                            router.section = .settings
                        }
                    } else {
                        cautionText(caution.text)
                    }
                } else {
                    Text(subtitle).foregroundStyle(.secondary)
                }
            }
            .font(Typo.heroSubtitle)
            .multilineTextAlignment(.leading)
            .lineLimit(subtitleLines)
            .lineSpacing(2)
            .fixedSize(horizontal: subtitleLines == 1, vertical: true)
            .frame(maxWidth: subtitleWidth, alignment: .leading)
        }
    }

    /// Recording: the voice level and the clock. Starting, recognizing and polishing keep their
    /// small spinner beside the headline, so this slot only ever means "recording" or "mode".
    @ViewBuilder private var heroTrailing: some View {
        if controller.phase == .recording {
            HStack(spacing: Space.s) {
                // Grey, like the capsule's white bars: the stop button is the page's one red thing.
                VoiceLevel(controller: controller, color: .secondary)
                RecordingClock(start: controller.startedAt)
            }
            .transition(.opacity)
        } else if !controller.phase.isActive, !setupBlocked {
            modePicker
        }
    }

    private var modePicker: some View {
        Picker("模式", selection: $settings.mode) {
            ForEach(DictationMode.allCases) { Text($0.shortTitle).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
        .fixedSize()
        .help(modeHelp)
    }

    private var modeHelp: String {
        let modes = DictationMode.allCases.map { "\($0.shortTitle)：\($0.summary)" }.joined(separator: "\n")
        guard settings.autoStructuredForAI else { return modes }
        return modes + "\n选自然整理时，在 \(AIAppExamples.text)里会自动用结构化。"
    }

    /// A step that takes a moment: its words with a small spinner 8pt after them.
    private func working(_ text: String, size: CGFloat) -> some View {
        HStack(spacing: Space.xs) {
            Text(text)
            ProgressView().controlSize(.small).frame(height: size)
        }
    }

    @ViewBuilder private func headline(size: CGFloat) -> some View {
        Group {
            switch controller.phase {
            case .starting: working("正在打开麦克风…", size: size)
            case .recording: Text("正在听…")
            case .transcribing: working("识别中…", size: size)
            case .polishing: working("整理中…", size: size)
            case .done(let message): Text(DoneText.headline(message))
            case .failed: Text("没有完成")
            case .idle, .cancelled:
                if setupBlocked {
                    Text("还差 \(remainingSteps) 步就能听写")
                } else if !settings.hotkeyEnabled {
                    // AppDelegate ignores the hotkey while it is switched off: the round button is the way.
                    Text("点麦克风开始说话")
                } else {
                    HStack(spacing: size * 0.29) {
                        Text("按")
                        KeyCap(trigger: settings.trigger, fontSize: (size * 0.6).rounded())
                        Text("开始说话")
                    }
                }
            }
        }
        .font(.system(size: size, weight: .bold))
        .fixedSize()
    }

    private var subtitle: String {
        let key = settings.trigger.keyName
        // The hotkey and Esc reach neoless through the hotkey's event tap: without it (switched off,
        // no Accessibility, still connecting) only the round button and the capsule's × work.
        let esc = settings.hotkeyEnabled && status.hotkeyRunning
        switch controller.phase {
        case .starting:
            return esc ? "按 Esc 取消。" : "点左边的按钮取消。"
        case .recording:
            let stop: String
            if !esc { stop = "点左边的按钮结束，点浮层上的 × 取消。" }
            else if controller.holdToTalk { stop = "松开 \(key) 结束，按 Esc 取消。" }
            else { stop = "再按一下 \(key) 结束，按 Esc 取消。" }
            let device = controller.deviceName.isEmpty ? "" : MixedText.join("正在用", controller.deviceName) + "。"
            return stop + device
        case .transcribing, .polishing:
            // Recording is over: the key no longer interrupts; Esc and the round button only stop the typing.
            let how = esc ? "按 Esc 取消输入" : "点左边的按钮取消输入"
            return how + (settings.keepHistory ? "，结果仍会存进历史记录。" : "。")
        case .failed(let why): return why
        case .done(let message): return DoneText.subtitle(message)
        case .idle, .cancelled:
            if setupBlocked {
                return settings.hotkeyEnabled ? "先完成下面的设置，之后按 \(key) 就能说话。" : "先完成下面的设置，之后点麦克风就能说话。"
            }
            // 本机识别: this Mac recognises, the Neo only polishes.
            return settings.mode.homeLine(autoStructured: settings.autoStructuredForAI,
                                          onNeo: hub.status.recognizes && !hub.recognizesHere)
        }
    }

    /// Idle with nothing in the way: the hero can say how to start.
    private var idleReady: Bool {
        switch controller.phase {
        case .idle, .cancelled: return !setupBlocked
        default: return false
        }
    }

    /// A failure, or a result typed or copied without polish: the line keeps its plain grey with one
    /// orange mark in front, and ends in the fix when the fix is signing in again.
    private var caution: (text: String, link: String?)? {
        switch controller.phase {
        case .failed(let why): return (why, nil)
        case .done(let message):
            guard let fallback = FailureText.fallback(message) else { return nil }
            let link: String?
            switch fallback.reason {
            case PolishError.http(401, "").short: link = "重新登录"
            case PolishError.notSignedIn.short: link = "登录"
            default: link = nil
            }
            return (DoneText.subtitle(message), link)
        default: return nil
        }
    }

    private func cautionText(_ text: String) -> Text {
        Text(Image(systemName: "exclamationmark.circle.fill")).foregroundColor(Theme.caution)
            + Text(" " + text).foregroundColor(.secondary)
    }

    /// A grey line that ends in an accent link, tappable as a whole: "ChatGPT 登录已失效。 重新登录".
    private func fixLine(caution: Bool, text: String, link: String, help: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            (caution ? cautionText(text) : Text(text).foregroundColor(.secondary))
                // Full-width punctuation already carries its own space.
                + Text("，。".contains(text.last ?? " ") ? "" : " ") + Text(link).foregroundColor(Theme.accent)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: 今日概览

    /// The figures, the chart beside the latest results (under them in a narrow window), and the year.
    /// `cardHeight` is how tall the chart and 最近听写 are when they sit side by side.
    private func overview(width: CGFloat, cardHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Dash.gap) {
            VStack(alignment: .leading, spacing: 14) {
                // On the cards' own edges, like the round button and the mode switch above and every card
                // below: one left edge and one right edge down the page.
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("今日概览").font(Typo.overviewTitle).foregroundStyle(.primary)
                    Spacer(minLength: Space.xs)
                    Text(UsageText.day(usage.today)).foregroundStyle(.secondary)
                    // What neoless has learned from the user's own fixes, in a number, with the way to the list.
                    if !learning.items.isEmpty {
                        Text(" · ").foregroundStyle(.secondary)
                        Button { router.section = .dictionary } label: {
                            Text("已学会 \(learning.items.count) 个词").foregroundStyle(Theme.accent).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("你改对的词，neoless 记住了这么多。点开在个人词典里看。")
                    }
                }
                .font(.system(size: 13))
                .lineLimit(1)
                StatTiles(width: width)
            }
            // One layout for both arrangements, so resizing the window across the threshold moves the two
            // cards without making them anew (an edit under way keeps its focus). A narrow window: what was
            // just said stays near the top, the chart follows.
            let wide = width >= Dash.roomy
            OverviewPair(sideBySide: wide, leadingWidth: Dash.chartWidth(in: width), gap: Dash.gap) {
                UsageChartCard(height: wide ? cardHeight : Dash.cardHeight)
                recentCard(height: wide ? cardHeight : nil)
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: PageHeightsKey.self, value: PageHeights(pair: g.size.height))
            })
            HeatmapCard(width: width)
        }
        // A section of its own under the headline: a little more air than between the lines above it.
        .padding(.top, Space.xs)
    }

    // MARK: 最近听写

    /// The card's title row: its centre on `Dash.firstLine`, like the chart's controls beside it.
    private static let recentHeader: CGFloat = 2 * Dash.firstLine
    /// Spare height whatever leads the card gets before the rows under it get any; under the latest
    /// result's text, the most there is between the text and its tools.
    private static let leadAir: CGFloat = 20
    /// Earlier results under the latest one when the card is as tall as it likes (a narrow window): one, so
    /// the chart under the card still shows its head in the smallest window.
    private static let earlierRowCount = 1
    /// The line that says history is off, under the rows.
    private static let historyOffHeight: CGFloat = 40

    /// The latest result with its tools on top (or what is being said right now), earlier ones under it.
    /// Beside the chart (`height`) the card is as tall as the chart and shows whole rows only: as many as
    /// fit under the latest result, never a row cut off by the card's edge. What is left over, less than a
    /// row, is shared out so the last row ends where the card ends: more lines of a folded result first,
    /// then a little air under the latest result and the same air in every row. The card only grows past
    /// the chart when the latest result itself needs the room.
    private func recentCard(height: CGFloat?) -> some View {
        let latest = shown
        let showsLive = controller.phase.isActive && !controller.liveText.isEmpty
        // While a new dictation runs, the latest result steps back to an ordinary row; so it does right
        // after Esc, until the cancelled dictation's own result arrives in its place.
        let steppedBack = latest.map { controller.phase.isActive || awaitingCancelled($0) } ?? false
        let earlier = Array(history.records.filter { $0.id != latest?.id }.prefix(6))
        let room = height.map { $0 - Self.recentHeader - 0.5 }
        let leads = !showsLive && latest != nil && !steppedBack
        let fit = earlierFit(earlier.count, room: room, hidden: leads ? hiddenHeight : 0)
        // The lead's share goes to whatever leads the card: what is being said, else the latest result.
        let liveSlack = showsLive ? fit.lead : 0
        let latestSlack = leads ? fit.lead : 0
        return Surface {
            HStack(spacing: Space.s) {
                Text("最近听写").font(Typo.cardTitle).foregroundStyle(.primary)
                Spacer(minLength: Space.s)
                if !history.records.isEmpty {
                    Button { router.openHistory(selecting: shown?.id) } label: {
                        HStack(spacing: 3) {
                            Text("历史记录")
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.accent)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("在历史记录里看全部")
                }
            }
            .padding(.horizontal, Dash.inset)
            .frame(height: Self.recentHeader)
            RowDivider(inset: 0)
            if latest == nil, !showsLive {
                // The figures beside the card count on their own: it only says nothing was dictated
                // when they say so too.
                nothingToShow(RecentCard.Empty(everDictated: !usage.stats.days.isEmpty, keepsHistory: settings.keepHistory))
                    .frame(maxWidth: .infinity)
                    .frame(height: room)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        if showsLive {
                            liveRow
                            if liveSlack > 0 { Color.clear.frame(height: liveSlack) }
                        }
                        if let latest {
                            if showsLive { RowDivider(inset: Dash.inset) }
                            if steppedBack {
                                RecentRow(record: latest, today: usage.today) { router.openHistory(selecting: latest.id) }
                            } else {
                                latestRow(latest, slack: latestSlack)
                            }
                        }
                    }
                    // Its own height, without the leftover it was just given (to the half point, so the
                    // sum that gave the leftover and this difference always agree).
                    .background(GeometryReader { g in
                        Color.clear.preference(key: TopRowsHeightKey.self,
                                               value: ((g.size.height - liveSlack - latestSlack) * 2).rounded() / 2)
                    })
                    ForEach(earlier.prefix(fit.rows)) { record in
                        RowDivider(inset: Dash.inset)
                        RecentRow(record: record, today: usage.today, height: RecentRow.height + fit.perRow) {
                            router.openHistory(selecting: record.id)
                        }
                    }
                    if !settings.keepHistory { historyOffLine }
                }
                .frame(minHeight: room, alignment: .top)
                .onPreferenceChange(TopRowsHeightKey.self) { topRowsHeight = $0 }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: steppedBack)
    }

    /// How many of `count` earlier results the card shows under what leads it, and where the height left
    /// over once they are in goes: `lead` under the leading row's text, `perRow` into each earlier row.
    /// With `room` (the card is as tall as the chart beside it): the rows that fit whole. The leftover is
    /// only handed out while it is less than a row; a card with more room than results keeps the rest under
    /// them. `hidden` is how much of a folded result does not show: it gets that first, as text.
    private func earlierFit(_ count: Int, room: CGFloat?, hidden: CGFloat) -> (rows: Int, lead: CGFloat, perRow: CGFloat) {
        guard let room else { return (min(count, Self.earlierRowCount), 0, 0) }
        // The top has not been measured yet: no rows for a moment, rather than rows that then go away.
        guard topRowsHeight > 0 else { return (0, 0, 0) }
        let step = RecentRow.height + 0.5
        let left = max(0, room - topRowsHeight - (settings.keepHistory ? 0 : Self.historyOffHeight))
        let rows = min(count, Int(left / step))
        let rest = left - CGFloat(rows) * step
        guard rest < step else { return (rows, 0, 0) }
        // To the half point, so the shares add up to the leftover exactly.
        let lead = min(rest, max(Self.leadAir, hidden))
        let perRow = rows > 0 ? min(RecentRow.maxExtra, ((rest - lead) / CGFloat(rows) * 2).rounded(.down) / 2) : 0
        return (rows, rest - perRow * CGFloat(rows), perRow)
    }

    /// What is being said right now, where its result will be.
    private var liveRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("这一次")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(height: RecordMeta<EmptyView>.height)
            Text(controller.liveText)
                .font(.system(size: Typo.resultSize))
                .lineSpacing(GrowingTextEditor.lineSpacing)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Dash.inset)
        .padding(.vertical, Space.s)
        .transition(.opacity)
    }

    /// The latest result: when and where it went, the text (a click edits it), its tools, and one quiet
    /// line when there is something to say about it. `slack` is spare height the card has for it. A folded
    /// result takes it as more of its text, in whole lines and as far as the text goes. What is left is
    /// air: a little under the text (`leadAir`), the rest half over the result and half under it, so the
    /// result sits in its room and never has a hollow band between its text and its tools.
    private func latestRow(_ record: DictationRecord, slack: CGFloat = 0) -> some View {
        let lines = foldedLines(slack: slack)
        let air = max(0, slack - CGFloat(lines - Self.previewLines) * GrowingTextEditor.linePitch)
        let under = min(air, Self.leadAir)
        // To the half point, so the three shares add up to the air exactly.
        let above = (air - under).rounded(.down) / 2
        let below = air - under - above
        return VStack(alignment: .leading, spacing: 0) {
            RecordMeta(record: record, today: usage.today, saysDestination: true) { EmptyView() }
                .padding(.horizontal, Dash.inset)
                .padding(.top, Space.s + 2 + above)
            resultText(record, lines: lines)
            if under > 0 { Color.clear.frame(height: under) }
            if let note = note(record) {
                NoticeLine(symbol: "exclamationmark.circle.fill", tint: Theme.caution, text: note, inset: false)
                    .padding(.horizontal, Dash.inset)
                    .padding(.bottom, Space.xs)
            }
            toolbar(record, hides: foldHides(lines: lines))
            if let line = footnote(record) {
                line.padding(.horizontal, Dash.inset)
                    .padding(.bottom, Space.s)
            }
            if below > 0 { Color.clear.frame(height: below) }
        }
    }

    /// No result to show, and why (`RecentCard.Empty`): nothing dictated yet (the headline above already
    /// says how to start, or what is missing, so this only says what will be here), 保存历史 off with
    /// nothing said since neoless started, or a history that was cleared or has run out.
    private func nothingToShow(_ empty: RecentCard.Empty) -> some View {
        VStack(spacing: Space.xs) {
            Image(systemName: empty == .firstUse ? "waveform" : "clock")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(height: 36)
            VStack(spacing: Space.xxs + 1) {
                Text(empty.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(empty.message)
                    .font(Typo.statDetail)
                    .foregroundStyle(.secondary)
            }
            if empty.linksToSettings {
                Button { router.section = .settings } label: {
                    Text("打开设置").font(.system(size: 13)).foregroundStyle(Theme.accent).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, Space.xxs)
                .help("设置 › 通用 › 保存历史。次数和字数照常统计，不存文字。")
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.xl)
    }

    /// 保存历史 is off: of new dictations only the latest stays, in memory (results from before the switch
    /// was turned off may still be listed above the line). The numbers above go on counting, and the
    /// tooltip says so.
    private var historyOffLine: some View {
        NoticeLine(symbol: "clock", text: RecentCard.historyOffLine, inset: false,
                   links: [("打开设置", { router.section = .settings })])
            .padding(.horizontal, Dash.inset)
            .frame(height: Self.historyOffHeight)
            .help("设置 › 通用 › 保存历史。次数和字数照常统计，不存文字。")
    }

    /// Esc stopped the paste of a dictation still processing, and its result has not replaced the one
    /// shown yet: under 已取消输入, the card is the previous dictation, not the cancelled one.
    private func awaitingCancelled(_ record: DictationRecord) -> Bool {
        guard case .done(let message) = controller.phase,
              [true, false].map({ DoneText.pasteCancelled(keepHistory: $0) }).contains(message) else { return false }
        return !RecordNote.parts(record.note).contains(RecordNote.pasteCancelled)
    }

    /// The record's note under the latest result. While the headline and the line under it describe this
    /// record, what they already say is left out (History keeps the whole note).
    private func note(_ record: DictationRecord) -> String? {
        if case .done(let message) = controller.phase, controller.current?.id == record.id {
            return RecordNote.beyond(doneMessage: message, note: record.note)
        }
        return RecordNote.display(record.note)
    }

    /// Results longer than this fold to a short preview until 展开全文 or 编辑.
    private static let foldLines = 4
    private static let previewLines = 3

    /// The latest result is longer than `foldLines` and has not been unfolded: only its first lines show.
    private var isFolded: Bool { !expanded && textHeight > GrowingTextEditor.height(lines: Self.foldLines) }
    /// How much of the folded result (as the preview draws it) is under its `previewLines`.
    private var hiddenHeight: CGFloat {
        isFolded && !showRaw ? max(0, previewHeight - GrowingTextEditor.clipHeight(lines: Self.previewLines)) : 0
    }
    /// How many lines of a folded result show when the card has `slack` to spare: whole lines only.
    private func foldedLines(slack: CGFloat) -> Int {
        let pitch = GrowingTextEditor.linePitch
        return Self.previewLines + max(0, min(Int(slack / pitch), Int((hiddenHeight / pitch).rounded())))
    }
    /// The folded preview leaves some of the text out, so there is something to unfold.
    private func foldHides(lines: Int) -> Bool {
        isFolded && !showRaw && previewHeight > GrowingTextEditor.clipHeight(lines: lines) + 1
    }
    /// Above and below the latest result's text, between its line of facts and its tools.
    private static let textInset: CGFloat = 8

    @ViewBuilder private func resultText(_ record: DictationRecord, lines: Int = HomeView.previewLines) -> some View {
        if showRaw {
            Text(record.raw)
                .font(.system(size: Typo.resultSize))
                .lineSpacing(GrowingTextEditor.lineSpacing)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Dash.inset)
                .padding(.vertical, Self.textInset)
        } else {
            // Fits: the editor at its own height. Too long: the first lines, faded, until 展开.
            Group {
                if isFolded {
                    folded(record, lines: lines)
                } else {
                    editor(record)
                }
            }
            .background(alignment: .top) {
                // Measures the whole text at the card's width, and the text as the folded preview draws it.
                ZStack(alignment: .top) {
                    measured(record.finalText)
                        .background(GeometryReader { g in Color.clear.preference(key: TextHeightKey.self, value: g.size.height) })
                    measured(Self.foldedText(record))
                        .background(GeometryReader { g in Color.clear.preference(key: PreviewHeightKey.self, value: g.size.height) })
                }
            }
            .onPreferenceChange(TextHeightKey.self) { textHeight = $0 }
            .onPreferenceChange(PreviewHeightKey.self) { previewHeight = $0 }
            // The text is a field: a soft well on hover, an accent focus ring while editing.
            .background {
                RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                    .fill(editing || hoveringText ? Theme.fill : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                        .strokeBorder(editing ? Theme.accent.opacity(0.6) : Color.clear, lineWidth: 1.5))
                    .padding(.horizontal, Dash.inset - Space.xs)
                    .padding(.vertical, 2)
            }
            .onHover { hoveringText = $0 }
            .animation(.easeOut(duration: 0.12), value: hoveringText)
            .animation(.easeOut(duration: 0.12), value: editing)
        }
    }

    private func editor(_ record: DictationRecord) -> some View {
        GrowingTextEditor(text: Binding(get: { controller.current?.finalText ?? record.finalText },
                                        set: { text in
                                            // Typing always happens in the full editor, never in the folded preview.
                                            expanded = true
                                            if controller.current == nil { controller.current = record }
                                            controller.editCurrent(text)
                                        }),
                          focus: $editing)
            .padding(.horizontal, Dash.inset - GrowingTextEditor.lineFragmentPadding)
            // The measured box already holds one line-spacing below the last line.
            .padding(.top, Self.textInset - 2)
            .padding(.bottom, Self.textInset - 2 - GrowingTextEditor.lineSpacing)
            .help(learning.enabled ? "点文字就能改，neoless 会记住你改对的词" : "点文字就能改")
    }

    /// `text` at the reading size and the card's width, invisible: only its height is wanted.
    private func measured(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Typo.resultSize))
            .lineSpacing(GrowingTextEditor.lineSpacing)
            .padding(.horizontal, Dash.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
    }

    /// The result as the folded preview draws it: blank lines between paragraphs would use up the few
    /// lines there are.
    private static func foldedText(_ record: DictationRecord) -> String {
        record.finalText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The first `lines` lines, clipped (never truncated, so no ellipsis and no squeezed punctuation) on a
    /// line's edge: the box is sized by that many lines of the same type, so nothing of the next line
    /// shows under it. When text is left out, the last line fades into the card.
    private func folded(_ record: DictationRecord, lines: Int) -> some View {
        let hides = foldHides(lines: lines)
        return Text(Array(repeating: "字", count: lines).joined(separator: "\n"))
            .font(.system(size: Typo.resultSize))
            .lineSpacing(GrowingTextEditor.lineSpacing)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                Text(Self.foldedText(record))
                    .font(.system(size: Typo.resultSize))
                    .lineSpacing(GrowingTextEditor.lineSpacing)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .clipped()
            .mask(VStack(spacing: 0) {
                Color.black
                if hides {
                    LinearGradient(colors: [.black, .black.opacity(0.25)], startPoint: .top, endPoint: .bottom)
                        .frame(height: GrowingTextEditor.linePitch - GrowingTextEditor.lineSpacing)
                }
            })
            .frame(height: GrowingTextEditor.clipHeight(lines: lines), alignment: .top)
            .padding(.horizontal, Dash.inset)
            // As tall as the same lines in the editor.
            .padding(.top, Self.textInset - 1)
            .padding(.bottom, Self.textInset - 2)
            .contentShape(Rectangle())
            .onTapGesture { expanded = true }
            .help(hides ? "点按展开全文" : "点文字就能改")
    }

    /// The latest result's tools: a quiet link, then 重新整理 and 复制 as two plain buttons (the text is
    /// already where the user wanted it; on this page the accent is for what was done: today's bar, the
    /// year, the links). No 编辑 button: a click on the text edits it (完成 shows while it does). As much
    /// as the card's width holds: both quiet links and buttons with symbols; then one link (展开全文 while
    /// the fold `hides` some of the text, else 查看原文); then the same with plain words on the buttons.
    private func toolbar(_ record: DictationRecord, hides: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            tools(record, hides: hides, bothLinks: true, symbols: true)
            tools(record, hides: hides, bothLinks: false, symbols: true)
            tools(record, hides: hides, bothLinks: true, symbols: false)
            tools(record, hides: hides, bothLinks: false, symbols: false)
        }
        .controlSize(.regular)
        // Both ends on the card's line, like the header and the rows below.
        .padding(.horizontal, Dash.inset)
        .padding(.top, Space.xxs)
        .padding(.bottom, Space.s + 2)
    }

    private func tools(_ record: DictationRecord, hides: Bool, bothLinks: Bool, symbols: Bool) -> some View {
        // Only when the fold leaves something out: a link that shows nothing more is not offered.
        let canUnfold = hides
        return HStack(spacing: Space.xs) {
            // Quiet text links on the left, all in the same grey.
            if record.polished != nil, bothLinks || !canUnfold {
                Button(showRaw ? "查看整理结果" : "查看原文") { showRaw.toggle() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            if canUnfold {
                Button { expanded = true } label: {
                    HStack(spacing: 3) {
                        Text("展开全文")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.s)
            if editing, !showRaw {
                Button { editing = false } label: {
                    ToolLabel(title: "完成", symbol: symbols ? "checkmark" : nil)
                }
                .buttonStyle(.pushButton)
                .help("改完了")
            }
            Button {
                if controller.current == nil { controller.current = record }
                controller.repolishCurrent()
            } label: {
                ToolLabel(title: controller.repolishing ? "整理中…" : "重新整理", symbol: symbols ? "arrow.clockwise" : nil)
            }
            .buttonStyle(.pushButton)
            .disabled(controller.repolishing || !controller.canRepolish(record))
            Button {
                TextInserter.copy(showRaw ? record.raw : (controller.current?.finalText ?? record.finalText))
            } label: {
                ToolLabel(title: "复制", symbol: symbols ? "doc.on.doc" : nil)
            }
            .buttonStyle(.pushButton)
            .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Quiet line under the latest result, only when there is something to say: what was just learned (with
    /// undo), that an app's edits cannot be learned from, or, until the first correction is learned,
    /// that the text can be edited (the text keeps that in its tooltip after). Which of them it is,
    /// `RecentCard.Footnote.pick` decides: a result typed where nothing can be read says so before
    /// news about another result.
    private func footnote(_ record: DictationRecord) -> NoticeLine? {
        let notice = learning.lastEvent, noted = learning.lastNoted
        switch RecentCard.Footnote.pick(for: record.id, learnedFrom: notice?.recordID,
                                        learnedAgo: notice.map { Date().timeIntervalSince($0.date) },
                                        unseen: learning.unsupportedRecordID, hasLearned: !learning.items.isEmpty,
                                        notedFrom: noted?.recordID, notedAgo: noted.map { Date().timeIntervalSince($0.date) }) {
        case .learned:
            return NoticeLine(symbol: "checkmark.circle.fill", text: "已记住：\(notice?.summary ?? "")", inset: false,
                              links: [("撤销", { learning.undoLastEvent() })])
        case .noted:
            // A word typed over another that does not sound like it: only remembered this first time.
            return NoticeLine(symbol: "circle.lefthalf.filled", text: LearningText.noted(pairs: noted?.pairs ?? []),
                              inset: false, links: [("撤销", { learning.forgetLastNoted() })])
        case .unseen:
            return NoticeLine(symbol: "info.circle",
                              text: MixedText.join("在", record.appName ?? "那个应用", "里改的字") + " neoless 看不到，在这里改才会记住。",
                              inset: false)
        case .editHint:
            // Said of this window only: what is fixed here is saved and learned from. (A fix made where the
            // text landed is learned only when that app lets its text be read, so nothing is promised of it.)
            return NoticeLine(text: learning.enabled ? "点上面的文字就能改。在这里改对的词，neoless 会记住。"
                                                     : "点上面的文字就能改，改动会存进历史记录。",
                              inset: false)
        case nil:
            return nil
        }
    }

    /// Secure input is on somewhere: a quick tap is ignored, only a hold dictates. One quiet line.
    private var holdOnlyHint: some View {
        NoticeLine(symbol: "lock.fill",
                   text: "有应用开着“安全键盘输入”，现在要按住 \(settings.trigger.keyName) 说话。", indent: Dash.inset)
            .help("离开密码框，或在终端里关掉“安全键盘输入”后，轻按又能用。")
    }

    /// Everything that counts is done, but fn also does what "按下🌐键时" says: one quiet line with
    /// the way to the fix, instead of a whole checklist card for advice (the change itself is in the
    /// tooltip and in Settings › 快捷键). 不再提示 holds until the value changes.
    private var globeHint: some View {
        NoticeLine(symbol: "globe",
                   text: GlobeKeyText.sentence(status.globeKey), indent: Dash.inset,
                   links: [("打开键盘设置", { Permissions.openKeyboardSettings() }),
                           ("不再提示", { settings.globeHintDismissed = status.globeKey.token })])
            .help(GlobeKeyText.fix)
    }

    /// The Neo is paired but cannot do its part, for longer than a nap: one quiet line (this Mac does the work
    /// meanwhile), with the way to Settings. A Neo out of reach only changes the line under the headline (本机识别)
    /// and the sidebar: it is usually asleep, and wakes.
    private var neoNotice: (text: String, link: String)? {
        guard hub.isActive else { return nil }
        switch hub.status {
        case .revoked: return ("Neo 配对已失效，现在用这台 Mac 识别和整理。", "重新配对")
        case .accessDenied: return ("Cloudflare 门禁没放行，现在用这台 Mac 识别和整理。", "重新配对")
        case .accessRequired: return ("Neo 只收经过 Cloudflare 门禁的请求，现在用这台 Mac 识别和整理。", "查看")
        case .connected(let health) where !health.asr.ready: return ("Neo 的识别暂时不可用，现在用这台 Mac 处理。", "查看")
        case .connected(let health) where !health.chatgpt.ready: return ("Neo 上的 ChatGPT 不可用，文字暂时不整理。", "查看")
        default: return nil
        }
    }

    private func neoLine(_ notice: (text: String, link: String)) -> some View {
        NoticeLine(symbol: "exclamationmark.circle", text: notice.text, indent: Dash.inset,
                   links: [(notice.link, { router.section = .settings })])
            .help("设置 › Neo 处理中心")
    }

    /// A data file did not read back this launch: one quiet line, with the folder that holds the copy.
    private func recovered(_ notice: String) -> some View {
        NoticeLine(symbol: "exclamationmark.circle.fill", tint: Theme.caution, text: notice + "。", indent: Dash.inset,
                   links: [("打开文件夹", { NSWorkspace.shared.activateFileViewerSelecting([AppFiles.directory]) })])
    }
}

private struct TextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct DetailSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}

/// How tall the home page's content is, and how tall the chart row in it: each is reported by its own view,
/// and the two arrive together.
private struct PageHeights: Equatable {
    var content: CGFloat = 0
    var pair: CGFloat = 0
}

private struct PageHeightsKey: PreferenceKey {
    static let defaultValue = PageHeights()
    static func reduce(value: inout PageHeights, nextValue: () -> PageHeights) {
        let next = nextValue()
        value = PageHeights(content: max(value.content, next.content), pair: max(value.pair, next.pair))
    }
}

private struct PreviewHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct TopRowsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Button label with a small symbol at the text's cap height and a tight 4pt gap; just the word where
/// there is no room for the symbol.
private struct ToolLabel: View {
    let title: String
    let symbol: String?
    var body: some View {
        HStack(spacing: Space.xxs) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 12)
            }
            Text(title)
        }
    }
}

extension DictationRecord {
    /// The text on one run for list previews: a 结构化 result's line breaks become spaces, so a row
    /// never shows a blank second line.
    var previewText: String {
        let lines = finalText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Full-width punctuation already carries its own space.
        return lines.dropFirst().reduce(lines.first ?? "") { text, line in
            text + ("。！？：；，、".contains(text.last ?? " ") ? "" : " ") + line
        }
    }
}

/// Icons of the apps text was typed into, looked up by name and cached.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage?] = [:]

    static func icon(named name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        var icon = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.icon
        if icon == nil {
            for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities"] {
                let path = "\(dir)/\(name).app"
                if FileManager.default.fileExists(atPath: path) { icon = NSWorkspace.shared.icon(forFile: path); break }
            }
        }
        cache[name] = icon
        return icon
    }
}

/// A result's line of facts: when, how it was written (the mode), where it went, how long the recording was.
/// `trailing` takes the place of the length while `showsTrailing` (a row's 复制, under the pointer), so a
/// row at rest is only facts and every row's right edge is the same.
private struct RecordMeta<Trailing: View>: View {
    let record: DictationRecord
    /// The day it is now (`UsageStore.today`). An input, not read from the clock in `body`: when the day
    /// changes the line is drawn again, and a time from before midnight then says 昨天.
    let today: UsageDate
    /// The latest result: the mode as a chip, and "输入到微信". The rows under it are one plain line,
    /// "15:04 · 结构化 · 终端", so the card has one chip, not one a row.
    var saysDestination = false
    var showsTrailing = false
    @ViewBuilder var trailing: Trailing

    /// The line's height (`Self` is generic: read it as `RecordMeta<EmptyView>.height`).
    static var height: CGFloat { 18 }

    var body: some View {
        HStack(alignment: .center, spacing: saysDestination ? 7 : 5) {
            Text(TimeText.stamp(record.date, today: today, timeZone: .autoupdatingCurrent)).monospacedDigit().fixedSize()
            if saysDestination {
                ModeChip(mode: record.mode)
            } else {
                Text("·").foregroundStyle(.tertiary)
                Text(record.mode.shortTitle).fixedSize()
            }
            if let app = record.appName {
                if !saysDestination { Text("·").foregroundStyle(.tertiary) }
                // The first to give way when the line is short of room.
                Text(saysDestination && record.delivery == .pasted ? MixedText.join("输入到", app) : app)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
            Spacer(minLength: Space.xxs)
            ZStack(alignment: .trailing) {
                Text(UsageText.recording(record.duration)).monospacedDigit().fixedSize()
                    .help("录音时长")
                    .opacity(showsTrailing ? 0 : 1)
                trailing.opacity(showsTrailing ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.12), value: showsTrailing)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(height: Self.height)
    }
}

/// The mode a result was written in, as a small quiet chip.
struct ModeChip: View {
    let mode: DictationMode

    var body: some View {
        Text(mode.shortTitle)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.fill))
            .fixedSize()
    }
}

/// An earlier result in 最近听写: its facts and the text on one line. A click opens it in History; under
/// the pointer, 复制 shows where the recording's length was.
private struct RecentRow: View {
    static let height: CGFloat = 62
    /// The most a row grows when the card has height to share out.
    static let maxExtra: CGFloat = 16
    let record: DictationRecord
    /// The day it is now, for the row's time (`RecordMeta.today`).
    let today: UsageDate
    var height = RecentRow.height
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let pointed = hovering || Dash._debugHoveredRow == record.id
        VStack(alignment: .leading, spacing: 5) {
            RecordMeta(record: record, today: today, showsTrailing: pointed) { CopyButton(text: record.finalText, size: 12) }
            Text(record.previewText)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, Dash.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .background(pointed ? Theme.fill : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .help("在历史记录中打开")
        .accessibilityAddTraits(.isButton)
    }
}

/// Text editor that is exactly as tall as its text (at least `minLines`); the page scrolls, not the editor.
struct GrowingTextEditor: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var minLines = 1

    static let fontSize = Typo.resultSize
    static let lineSpacing: CGFloat = 4
    /// NSTextView's default line fragment padding, matched by the measuring text.
    static let lineFragmentPadding: CGFloat = 5

    /// Height of `lines` lines of CJK text at the reading size.
    static func height(lines: Int) -> CGFloat {
        CGFloat(lines) * (ceil(fontSize * 1.32) + lineSpacing)
    }

    /// From one line of Chinese to the next at the reading size: a 19pt line and `lineSpacing`.
    static let linePitch: CGFloat = 23

    /// How tall `lines` lines of text are, from the top of the first to the bottom of the last.
    static func clipHeight(lines: Int) -> CGFloat {
        CGFloat(lines) * linePitch - lineSpacing
    }

    var body: some View {
        // The hidden text measures the content; the editor fills exactly that box.
        Text(text.isEmpty ? " " : text)
            .font(.system(size: Self.fontSize))
            .lineSpacing(Self.lineSpacing)
            .padding(.horizontal, Self.lineFragmentPadding)
            .padding(.bottom, Self.lineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .frame(minHeight: Self.height(lines: minLines), alignment: .top)
            .overlay {
                TextEditor(text: $text)
                    .focused(focus)
                    .font(.system(size: Self.fontSize))
                    .lineSpacing(Self.lineSpacing)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
            }
    }
}

/// Round record control. At rest it is a quiet neutral disc with a label-coloured mic (the accent
/// only on hover), so the accent on the page stays with what the user did (today's bar, the year). Recording turns
/// it system red with a white square, as in Voice Memos; while working it is a quiet cancel.
private struct RecordButton: View {
    static let size: CGFloat = 52
    let phase: Phase
    var neutral = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(fill)
                if !recording && !highlighted { Circle().strokeBorder(Theme.hairline, lineWidth: 0.5) }
                Image(systemName: symbol)
                    .font(.system(size: recording ? 16 : 20, weight: .semibold))
                    .foregroundStyle(glyph)
            }
            .frame(width: Self.size, height: Self.size)
            // A thin ring 3pt out while recording: present, not a glow.
            .background(
                Circle()
                    .strokeBorder(Theme.recording.opacity(0.25), lineWidth: 2)
                    .padding(-5)
                    .opacity(recording ? 1 : 0)
            )
            .brightness(hovering && recording ? 0.05 : 0)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(help)
    }

    private var recording: Bool { phase == .recording }

    private var help: String {
        switch phase {
        case .recording: return "结束并识别"
        case .starting: return "取消"
        case .transcribing, .polishing: return "取消输入"
        default: return neutral ? "完成设置后可以录音" : "开始录音"
        }
    }

    /// Ready to record and pointed at: the accent appears.
    private var highlighted: Bool { hovering && !neutral && !phase.isActive }

    private var symbol: String {
        if recording { return "stop.fill" }
        return phase.isActive ? "xmark" : "mic.fill"
    }

    private var fill: Color {
        if recording { return Theme.recording }
        if highlighted { return Theme.accent }
        return hovering && !neutral ? Theme.fill : Theme.quietFill
    }

    private var glyph: AnyShapeStyle {
        if recording || highlighted { return AnyShapeStyle(Color.white) }
        if neutral { return AnyShapeStyle(.tertiary) }
        return phase.isActive ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
    }
}

private struct RecordingClock: View {
    let start: Date?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let seconds = Int(max(0, context.date.timeIntervalSince(start ?? context.date)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// First-run checklist: only what is still missing, completed steps folded into one line. Shows
/// while a step that counts is missing and disappears once everything works. Missing steps carry the
/// same orange dot as Settings › 权限; advice that does not stop dictation (the 🌐 key, ChatGPT in
/// 原样转写) rides along without a dot and is not counted.
struct SetupCard: View {
    @EnvironmentObject var status: SystemStatus
    @EnvironmentObject var account: ChatGPTAccount
    @EnvironmentObject var router: Router
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var hub: HubConnection
    /// The header names how many steps are left, unless the hero above already does.
    var showsCount = true

    private struct Step: Identifiable {
        let row: SetupRow
        let title: String
        let icon: String
        let detail: String
        var button = PermissionRow.allowTitle
        let action: (() -> Void)?
        var id: SetupStep { row.step }
    }

    private var steps: [Step] {
        SetupChecklist.rows(status.setupFacts(account: account, settings: settings)).map(step)
    }

    private func step(_ row: SetupRow) -> Step {
        switch row.step {
        case .microphone:
            return Step(row: row, title: "麦克风", icon: "mic", detail: PermissionText.microphone) {
                Task { if await !Permissions.requestMicrophone() { Permissions.open(.microphone) }; status.refresh() }
            }
        case .speech:
            return Step(row: row, title: "语音识别", icon: "waveform", detail: PermissionText.speech) {
                Task { if await !Permissions.requestSpeech() { Permissions.open(.speech) }; status.refresh() }
            }
        case .speechModel:
            return Step(row: row, title: SpeechModelText.title, icon: "arrow.down.circle",
                        detail: "\(SpeechModelText.language(settings.localeID))还没下载，现在没法识别。\(SpeechModelText.howTo())",
                        button: "打开键盘设置") { Permissions.openKeyboardSettings() }
        case .accessibility:
            return Step(row: row, title: "辅助功能", icon: "accessibility",
                        detail: PermissionText.accessibility(settings.trigger)) {
                Permissions.requestAccessibility()
            }
        case .hotkey:
            return Step(row: row, title: "快捷键", icon: "keyboard", detail: "辅助功能已允许，正在连接快捷键…", action: nil)
        case .chatGPT:
            return Step(row: row, title: "ChatGPT", icon: "sparkles", detail: account.status.text, button: "去登录") {
                router.section = .settings
            }
        case .globeKey:
            return Step(row: row, title: GlobeKeyText.title(status.globeKey), icon: "globe", detail: GlobeKeyText.fix,
                        button: "打开键盘设置") { Permissions.openKeyboardSettings() }
        }
    }

    /// Where the voice is recognised: on the Neo, or with 本机识别 here, the Neo polishing the text.
    private var footer: String {
        guard hub.isActive else { return "声音只在这台 Mac 上识别，不会上传。" }
        if hub.recognizesHere { return "声音在这台 Mac 上识别，识别出的文字发到你自己的 Neo 整理；这台 Mac 没听清时录音交给 Neo。" }
        return "录音会发到你自己的 Neo 识别，连不上时在这台 Mac 上识别。"
    }

    var body: some View {
        let all = steps
        let missing = all.filter { !$0.row.done }
        let done = all.filter(\.row.done)
        let counted = missing.filter(\.row.counts).count
        GroupSection(title: "完成设置", footer: footer + "设置好后这里会自动收起。") {
            if showsCount { Text("还差 \(counted) 步") }
        } content: {
            ForEach(Array(missing.enumerated()), id: \.element.id) { i, step in
                if i > 0 { RowDivider(inset: RowDivider.afterIcon) }
                SettingRow(icon: step.icon, attention: step.row.counts, title: step.title, detail: step.detail) {
                    if let action = step.action {
                        Button(step.button, action: action).buttonStyle(.pushButton)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            if !done.isEmpty {
                RowDivider(inset: RowDivider.afterIcon)
                HStack(spacing: Space.s) {
                    // Grey, like 已记住 and 已允许: "done" looks the same everywhere.
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: IconTile.size)
                    Text("已完成 \(done.count) 项：" + done.map(\.title).joined(separator: "、"))
                        .font(Typo.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Inset.card)
                .frame(height: 36)
            }
        }
    }
}

/// What each permission is for, the same on the home checklist and in Settings › 权限.
enum PermissionText {
    static let microphone = "录下你的声音"
    static let speech = "在这台 Mac 上把声音转成文字"
    static func accessibility(_ trigger: HotkeyTrigger) -> String {
        "让 \(trigger.keyName) 能开始听写，并把文字输入到光标处"
    }
}

/// Words for the on-device speech model, shared by the checklist and Settings: named for what it is
/// (离线识别模型), not after the 识别语言 setting beside it. The labels are the ones System Settings ›
/// 键盘 shows: the 听写 section, its switch and its 语言 row, which works only while 听写 is on.
@MainActor
enum SpeechModelText {
    static let title = "离线识别模型"

    /// "在键盘设置 › 听写里打开听写，再在“语言”里加上它。" Steps and names stay whole when it wraps.
    static func howTo(_ language: String = "它") -> String {
        "在键盘设置 › 听写里\(Words.keep("打开听写"))，再在“语言”里加上\(Words.keep(language))。"
    }

    static func language(_ localeID: String) -> String {
        AppSettings.locales.first { $0.id == localeID }?.title ?? localeID
    }
}

/// One free-standing quiet line on a page: an 11pt glyph, 6pt, 11pt secondary text (the size of the
/// group footers beside it) and accent links right after the text. Links flow with the text, so a long line wraps as one paragraph. It sits on
/// the 16pt card line like section headers and footers (`inset`), or as far in as the page's own cards
/// put their text (`indent`).
struct NoticeLine: View {
    var symbol: String?
    var tint: Color = .secondary
    let text: String
    var inset = true
    var indent: CGFloat = Inset.card
    var links: [(title: String, action: () -> Void)] = []

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            paragraph
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in
                    if let i = Int(url.host ?? ""), links.indices.contains(i) { links[i].action() }
                    return .handled
                })
            Spacer(minLength: 0)
        }
        .font(Typo.caption)
        .padding(.horizontal, inset ? indent : 0)
    }

    private var paragraph: Text {
        var line = AttributedString(Words.keepQuotes(text))
        line.foregroundColor = .secondary
        for (i, link) in links.enumerated() {
            var gap = AttributedString(i == 0 ? " " : " · ")
            gap.foregroundColor = .secondary
            var run = AttributedString(Words.keep(link.title))
            run.link = URL(string: "neoless-notice://\(i)")
            run.foregroundColor = Theme.accent
            line += gap + run
        }
        return Text(line)
    }
}

/// Kept for callers that want a plain padded surface.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: Space.s) { content }.padding(Space.l)
        }
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var router: Router
    @State private var selection: UUID?
    @State private var confirmClear = false
    @State private var query = ""

    var body: some View {
        PageScaffold(title: "历史记录", subtitle: subtitle, scrolls: false, width: Dash.pageWidth) {
            // Only when there is something to clear: a neutral button; the dialog carries the red.
            if !history.records.isEmpty {
                Button("清空…") { confirmClear = true }
                    .buttonStyle(.pushButton)
                    .controlSize(.small)
            }
        } content: {
            if history.records.isEmpty {
                // No empty white slab: the message sits on the page, a little above the middle.
                GeometryReader { geo in
                    Group {
                        if settings.keepHistory {
                            EmptyState(symbol: "clock", title: "还没有记录", message: "说完一段话，这里会多一条记录。")
                        } else {
                            EmptyState(symbol: "clock", title: "历史记录已关闭",
                                       message: "在设置 › 通用里打开“保存历史”后，听写会保存在这里。",
                                       action: ("打开设置", { router.section = .settings }))
                        }
                    }
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.4)
                }
                .frame(maxHeight: .infinity)
            } else {
                Surface {
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            listColumn.frame(width: min(300, max(200, geo.size.width * 0.4)))
                            Rectangle().fill(Theme.separator).frame(width: 0.5)
                            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .confirmationDialog("清空全部历史记录？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { history.deleteAll(); selection = nil }
        } message: {
            Text("这个操作不能撤销。")
        }
        .onAppear {
            takeRouterSelection()
            if selection == nil { selection = history.records.first?.id }
        }
        .onChange(of: router.historySelection) { _, _ in takeRouterSelection() }
    }

    private func takeRouterSelection() {
        guard let id = router.historySelection else { return }
        if history.records.contains(where: { $0.id == id }) {
            query = ""
            selection = id
        }
        router.historySelection = nil
    }

    private var subtitle: String {
        if !settings.keepHistory { return "不会保存新的听写。" }
        return history.records.isEmpty ? "保存最近 30 天的听写。" : "\(history.records.count) 条 · 保存最近 30 天"
    }

    private var filtered: [DictationRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return history.records }
        return history.records.filter {
            $0.finalText.localizedCaseInsensitiveContains(q) || $0.raw.localizedCaseInsensitiveContains(q)
                || ($0.appName?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            SearchField(text: $query, prompt: "搜索")
                .padding(.horizontal, Space.xs)
                .padding(.top, Space.s)
                .padding(.bottom, Space.xxs)
            if filtered.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "没有找到", message: "换个关键词试试。")
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                list
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups(filtered), id: \.title) { group in
                        Section {
                            ForEach(group.records) { record in
                                HistoryRow(record: record, selected: selection == record.id)
                                    .id(record.id)
                                    .onTapGesture { selection = record.id }
                                    .contextMenu {
                                        Button("复制") { TextInserter.copy(record.finalText) }
                                        Divider()
                                        Button("删除", role: .destructive) { delete(record.id) }
                                    }
                            }
                        } header: {
                            Text(group.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Inset.card)
                                .padding(.top, Space.s)
                                .padding(.bottom, Space.xxs)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.surface)
                        }
                    }
                }
                .padding(.bottom, Space.l)
            }
            // Rows fade out at the bottom edge instead of being cut off hard.
            .mask(VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: Space.m)
            })
            // Keyboard, as in a list: ↑ ↓ move the selection, ⌫ deletes it. No focus ring: the
            // selection already shows where the keys act.
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                let records = filtered
                guard let i = records.firstIndex(where: { $0.id == selection }) else {
                    selection = records.first?.id
                    return
                }
                switch direction {
                case .up where i > 0: selection = records[i - 1].id
                case .down where i + 1 < records.count: selection = records[i + 1].id
                default: break
                }
            }
            .onDeleteCommand { if let selection { delete(selection) } }
            // The first row already shows under its pinned day header; scrolling to it would tuck it
            // under that header. Any other row is brought to the middle.
            .onAppear {
                if let selection, selection != filtered.first?.id { proxy.scrollTo(selection, anchor: .center) }
            }
            .onChange(of: selection) { _, id in
                guard let id, id != filtered.first?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = selection, let record = history.records.first(where: { $0.id == id }) {
            HistoryDetail(record: record, onDelete: { delete(record.id) })
        } else {
            EmptyState(symbol: "text.alignleft", title: "选择一条记录", message: "在左边选一条，查看整理结果和原文。")
                .frame(maxHeight: .infinity)
        }
    }

    private func delete(_ id: UUID) {
        let records = filtered
        if selection == id, let i = records.firstIndex(where: { $0.id == id }) {
            let next = i + 1 < records.count ? records[i + 1] : (i > 0 ? records[i - 1] : nil)
            selection = next?.id
        }
        history.delete(id)
    }

    private func groups(_ records: [DictationRecord]) -> [(title: String, records: [DictationRecord])] {
        let calendar = Calendar.current
        var result: [(title: String, records: [DictationRecord])] = []
        for record in records {
            let title = DayNames.relative(record.date, calendar: calendar)
                ?? record.date.formatted(.dateTime.month().day().weekday().locale(Locale(identifier: "zh_CN")))
            if result.last?.title == title { result[result.count - 1].records.append(record) }
            else { result.append((title, [record])) }
        }
        return result
    }
}

/// Rounded search field in the system style.
struct SearchField: View {
    @Binding var text: String
    var prompt = "搜索"

    var body: some View {
        HStack(spacing: Space.xs - 2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Typo.rowTitle)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除")
            }
        }
        .padding(.horizontal, Space.xs)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Theme.fill))
    }
}

/// A list row selected the way NSTableView does it: accent fill with white text while the window
/// is key, the unemphasised grey with ordinary text when it is not.
private struct HistoryRow: View {
    let record: DictationRecord
    let selected: Bool
    @Environment(\.controlActiveState) private var activeState

    private var emphasized: Bool { selected && activeState == .key }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.previewText)
                .font(Typo.rowTitle)
                .foregroundStyle(emphasized ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text([TimeText.clock(record.date), record.appName].compactMap { $0 }.joined(separator: " · "))
                .font(Typo.caption)
                .foregroundStyle(emphasized ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
        // 8pt highlight inset + 8pt text inset: the text sits on the 16pt card line.
        .padding(.horizontal, Inset.card - Space.xs)
        .padding(.vertical, Space.xs - 2)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(selected ? (emphasized ? Theme.selection : Theme.selectionInactive) : Color.clear)
        )
        .contentShape(Rectangle())
        .padding(.horizontal, Space.xs)
    }
}

struct HistoryDetail: View {
    let record: DictationRecord
    var onDelete: (() -> Void)?
    @EnvironmentObject var history: HistoryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(record.date.formatted(.dateTime.month().day().weekday().locale(Locale(identifier: "zh_CN")))
                             + " " + TimeText.clock(record.date))
                            .font(.system(size: 15, weight: .semibold))
                        Spacer(minLength: Space.s)
                        // Quiet, like the copy buttons below; the list's context menu and ⌫ delete too.
                        Button {
                            if let onDelete { onDelete() } else { history.delete(record.id) }
                        } label: {
                            Image(systemName: "trash").font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("删除这条记录")
                    }
                    // One quiet line: details drop off the end rather than wrap.
                    ViewThatFits(in: .horizontal) {
                        Text(meta(timing: true))
                        Text(meta(timing: false))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // Where the wait after the recording went, a size smaller: 识别 3.1 秒 · 整理 2.4 秒 · 共 6.0 秒.
                    // 传输 is the first to go in a narrow window.
                    if let wait = TimingText.breakdown(record) {
                        ViewThatFits(in: .horizontal) {
                            Text(wait)
                            Text(TimingText.breakdown(record, transfer: false) ?? wait)
                        }
                        .font(Typo.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("从松开说话键到文字输入完，每一步各花了多久")
                    }
                }

                block(title: "整理结果", text: record.finalText, copyHelp: "复制整理结果", boxed: false) {
                    BalancedWrap {
                        Text(record.finalText)
                            .font(.system(size: 15))
                            .lineSpacing(4)
                            .foregroundStyle(.primary)
                    }
                }

                if record.raw != record.finalText {
                    block(title: record.recognizedOnHub ? "原文 · Neo 识别" : "原文 · 本机识别", text: record.raw, copyHelp: "复制原文") {
                        BalancedWrap {
                            Text(record.raw)
                                .font(Typo.rowTitle)
                                .lineSpacing(3)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let note = RecordNote.display(record.note) {
                    NoticeLine(symbol: "exclamationmark.circle.fill", tint: Theme.caution, text: note, inset: false)
                }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A labelled text block with its own copy button.
    private func block<Body: View>(title: String, text: String, copyHelp: String, boxed: Bool = true,
                                   @ViewBuilder body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: Space.s)
                CopyButton(text: text, help: copyHelp)
            }
            body()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(boxed ? Space.s : 0)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(boxed ? Theme.fill : Color.clear))
    }

    /// "Codex · 录音 12.4 秒 · 自然整理 · 整理 1.9 秒" as one quiet line. The polish time only for a record without
    /// the line of timings under it (`TimingText`), which has it.
    private func meta(timing: Bool) -> String {
        var parts: [String] = []
        if let app = record.appName { parts.append(app) }
        parts.append(String(format: "录音 %.1f 秒", record.duration))
        parts.append(record.mode.shortTitle)
        if record.hubID != nil { parts.append("Neo 处理") }
        if timing, record.timings == nil, record.polished != nil, let s = record.polishSeconds {
            parts.append(String(format: "整理 %.1f 秒", s))
        }
        return parts.joined(separator: " · ")
    }
}

/// Small "复制" text button that confirms with "已复制" for a moment.
private struct CopyButton: View {
    let text: String
    var help = "复制"
    var size: CGFloat = 11
    @State private var copied = false

    var body: some View {
        Button {
            TextInserter.copy(text)
            copied = true
            Task { try? await Task.sleep(nanoseconds: 1_400_000_000); copied = false }
        } label: {
            // The symbol close to its word, so the two read as one control.
            HStack(spacing: 3) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: size - 1, weight: .medium))
                Text(copied ? "已复制" : "复制")
            }
            .font(.system(size: size))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(copied ? Theme.accent : .secondary)
        .help(help)
    }
}

// MARK: - Dictionary

struct DictionaryView: View {
    @EnvironmentObject var vocabulary: VocabularyStore
    @EnvironmentObject var learning: LearningStore
    @State private var input = ""
    @State private var confirmClear = false

    var body: some View {
        PageScaffold(title: "个人词典",
                     subtitle: "常用的人名、品牌和术语，让识别更准，也帮 ChatGPT 纠正同音错词。") {
            GroupSection(footer: "例如加入 OpenAI，被听成“Open Air”时也能改对。可以一次加多个，用逗号或顿号隔开。") {
                // A row like the others: 13pt text in a 40pt row.
                HStack(spacing: Space.s) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(trimmed.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.accent))
                    TextField("添加词语", text: $input)
                        .textFieldStyle(.plain)
                        .font(Typo.rowTitle)
                        .onSubmit(add)
                    if !trimmed.isEmpty {
                        Button("添加", action: add)
                            .buttonStyle(.prominent)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, Inset.card)
                .frame(height: 40)
                .animation(.easeOut(duration: 0.12), value: trimmed.isEmpty)
            }

            GroupSection(title: "已收录") {
                Text("\(vocabulary.words.count) 个词")
            } content: {
                if vocabulary.words.isEmpty {
                    EmptyState(symbol: "character.book.closed", title: "词典是空的",
                               message: "加入你常说的名字和术语，识别和整理会更准。")
                } else {
                    FlowLayout(spacing: Space.xs, lineSpacing: Space.xs) {
                        ForEach(vocabulary.words, id: \.self) { word in
                            WordChip(word: word, learned: learning.isLearnedTerm(word)) {
                                vocabulary.removeByUser(word)
                                // A correction learned towards this word is judged without it from now on.
                                learning.dictionaryChanged()
                            }
                        }
                    }
                    .padding(Inset.card)
                }
            }

            // What the user tells neoless in their own words, beside the words they gave it.
            HabitsSection()

            GroupSection(footer: "只记改动的词和改动的种类（比如删了句末的句号），不保存整段文字。") {
                LearningToggleRow()
            }

            GroupSection(title: "学到的纠正", footer: learnedFooter) {
                // Only when there is something to clear: a neutral button; the dialog carries the red.
                if !rows.isEmpty || !learning.hubItems.isEmpty {
                    Button("清空…") { confirmClear = true }
                        .buttonStyle(.pushButton)
                        .controlSize(.small)
                }
            } content: {
                if rows.isEmpty, learning.hubItems.isEmpty {
                    EmptyState(symbol: "wand.and.stars", title: "还没有学到纠正",
                               message: learning.enabled
                                   ? "在 neoless 输入的文字里改对一个词，这里会记下来。"
                                   : "打开上面的“自动学习”，改对的词会记在这里。")
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        if i > 0 { RowDivider(inset: Inset.card) }
                        switch row {
                        case .correction(let item):
                            LearnedRow(pair: item.pair, detail: Self.detail(item.lastSeen, count: item.count, repeated: item.isRepeated),
                                       tags: tags(for: item.pair, repeated: item.isRepeated, hub: false)) {
                                learning.remove(id: item.id)
                            }
                        case .waiting(let swap):
                            // Made once: remembered, and used for nothing until it is made again.
                            LearnedRow(pair: swap.pair, detail: LearnedRow.day(swap.seen), tags: [Self.waitingTag], waiting: true,
                                       removeTitle: "不记这一笔") {
                                learning.removeCandidate(swap.pair)
                            }
                        }
                    }
                    // What the Neo knows and this Mac did not learn itself (learned on another device, or imported there).
                    ForEach(Array(learning.hubItems.enumerated()), id: \.offset) { i, entry in
                        if i > 0 || !rows.isEmpty { RowDivider(inset: Inset.card) }
                        let repeated = entry.kind == .repeated
                        LearnedRow(pair: entry.pair, detail: Self.detail(entry.lastSeen, count: entry.count, repeated: repeated),
                                   tags: tags(for: entry.pair, repeated: repeated, hub: true)) {
                            learning.removeFromHub(wrong: entry.wrong)
                        }
                    }
                }
            }

            // What became of the latest edits: learned, or why not. So "it did not learn" has an answer.
            if !learning.log.isEmpty {
                GroupSection(title: "最近的修改",
                             footer: "只记结果，不记你改的文字。改标点、删字这类不是改词的修改不会自动记住，可以写进“我的习惯”。") {
                    Button("清除") { learning.clearLog() }
                        .buttonStyle(.pushButton)
                        .controlSize(.small)
                } content: {
                    ForEach(Array(learning.log.prefix(6).enumerated()), id: \.element.id) { i, entry in
                        if i > 0 { RowDivider(inset: Inset.card) }
                        LearningLogRow(entry: entry)
                    }
                }
            }
        }
        .confirmationDialog("清空学到的纠正？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { learning.clearAll() }
        } message: {
            Text("自动加入词典的词也会一起移除。这个操作不能撤销。")
        }
    }

    private var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// This Mac's corrections, and among them the swaps made once that wait for their second time.
    private var rows: [LearnedList.Row] {
        LearnedList.rows(items: learning.items, candidates: learning.candidates)
    }

    /// Under the list, only when a row needs explaining.
    private var learnedFooter: String? {
        var lines: [String] = []
        if let line = LearningText.tagFooter(waiting: !learning.candidates.isEmpty,
                                             repeated: learning.items.contains(where: \.isRepeated)
                                                 || learning.hubItems.contains { $0.kind == .repeated }) {
            lines.append(line)
        }
        if !learning.unused.isEmpty { lines.append("标着“已停用”的纠正不像是听错的词，现在不再使用，可以删掉。") }
        if !learning.notOnHub.isEmpty {
            lines.append("标着“仅本机”或“Neo 只记了词”的纠正，Neo 上没有。Neo 更新后会自动再发一次；也可以再改一次同样的词。")
        }
        return lines.isEmpty ? nil : lines.joined()
    }

    /// "今天 · 改过 3 次". A swap made twice says so on its tag, and here only once it was made more often.
    private static func detail(_ lastSeen: Date, count: Int, repeated: Bool) -> String {
        let day = LearnedRow.day(lastSeen)
        return repeated && count <= LearningBook.repeatedCount ? day : "\(day) · 改过 \(count) 次"
    }

    /// The badges after a stored correction. One that today's rules would not learn is not used at all: that
    /// is said, and nothing else. Otherwise how it was learned (a swap made twice), then where it is: the
    /// Neo's own (`hub`), or one of this Mac's that the Neo does not hold (as of the last sync), which is
    /// said because the Neo does the polishing.
    private func tags(for pair: CorrectionPair, repeated: Bool, hub: Bool) -> [LearnedRow.Tag] {
        if learning.isUnused(pair) { return [Self.unusedTag] }
        var tags: [LearnedRow.Tag] = repeated ? [Self.repeatedTag] : []
        if hub {
            tags.append(LearnedRow.Tag(text: "Neo", help: "Neo 上记着的纠正，用 Neo 处理时会用上"))
        } else if let holding = learning.hubHolding(of: pair) {
            tags.append(LearnedRow.Tag(text: Self.hubTag(holding), help: Self.hubTagHelp(holding)))
        }
        return tags
    }

    /// The badge on a stored correction that today's rules would not learn (`LearningStore.unused`).
    private static let unusedTag = LearnedRow.Tag(text: "已停用", help: "按现在的规则，这条不像是听错的词：不再用它改字，也不再提示。可以删掉。")
    /// On a swap made once (grey: it is not in use), and on one made twice.
    private static let waitingTag = LearnedRow.Tag(text: LearningText.waitingTag, help: LearningText.waitingHelp, quiet: true)
    private static let repeatedTag = LearnedRow.Tag(text: LearningText.repeatedTag, help: LearningText.repeatedHelp)

    /// The badge on a correction of this Mac's that the Neo does not hold.
    private static func hubTag(_ holding: HubLearning.Holding) -> String {
        switch holding {
        case .nothing: return "仅本机"
        case .wordOnly: return "Neo 只记了词"
        }
    }

    private static func hubTagHelp(_ holding: HubLearning.Holding) -> String {
        switch holding {
        case .nothing: return "只记在这台 Mac 上，Neo 没有：用 Neo 处理时不会用上。"
        case .wordOnly: return "Neo 只把正确的词记进了词典，没有记这条对应。"
        }
    }

    private func add() {
        guard !trimmed.isEmpty else { return }
        // A word typed by hand stays even if the pair that once taught it is forgotten.
        learning.markManual(input)
        vocabulary.add(input)
        // A correction towards a word just added counts as one towards the user's own word from now on.
        learning.dictionaryChanged()
        input = ""
    }
}

/// 我的习惯: the user's own writing preferences, one line each, which every polish follows. The list, a field
/// to add one, and, when neoless has seen the same edit that is no word fix often enough, one row offering
/// to write it down (it is added only when the user says so).
private struct HabitsSection: View {
    @EnvironmentObject var learning: LearningStore
    @State private var draft = ""
    /// Why the line just entered was not added; gone as soon as it is changed.
    @State private var problem: Habits.Problem?
    @FocusState private var typing: Bool

    var body: some View {
        GroupSection(title: "我的习惯", footer: footer) {
            if !learning.habits.isEmpty {
                Text("\(learning.habits.count) / \(Habits.maxItems) 条")
            }
        } content: {
            ForEach(Array(learning.habits.enumerated()), id: \.element) { i, habit in
                if i > 0 { RowDivider(inset: Inset.card) }
                HabitRow(text: habit) { learning.removeHabit(habit) }
            }
            if let offer = learning.suggestion {
                if !learning.habits.isEmpty { RowDivider(inset: Inset.card) }
                HabitOfferRow(offer: offer, full: full) {
                    learning.acceptSuggestion()
                } decline: {
                    learning.declineSuggestion()
                }
            }
            if !learning.habits.isEmpty || learning.suggestion != nil { RowDivider(inset: Inset.card) }
            if full {
                Text(HabitText.full)
                    .font(Typo.rowTitle)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Inset.card)
                    .frame(height: 40)
            } else {
                field
                if let problem {
                    note(HabitText.message(problem))
                } else if learning.habits.isEmpty, trimmed.isEmpty {
                    examples
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: learning.habits)
        .animation(.easeOut(duration: 0.15), value: learning.suggestion)
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var full: Bool { learning.habits.count >= Habits.maxItems }

    /// What the card is for and its limits; and, with habits written, what the Neo (which does the
    /// polishing) has of them when that is not simply "the same".
    private var footer: String {
        guard !learning.habits.isEmpty else { return HabitText.footer }
        switch learning.habitsOnHub {
        case .unknown, .same: return HabitText.footer
        case .waiting: return HabitText.footerWaiting
        case .unsupported: return HabitText.footerOldHub
        }
    }

    /// A row like the dictionary's own: 13pt text in a 40pt row.
    private var field: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(trimmed.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.accent))
            TextField(HabitText.placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(Typo.rowTitle)
                .focused($typing)
                .onSubmit(add)
                .onChange(of: draft) { _, text in
                    // No more than a habit holds, so nothing is cut off after it is added.
                    if text.count > Habits.maxLength { draft = String(text.prefix(Habits.maxLength)) }
                    problem = nil
                }
            // Close to the limit: how much room is left.
            if draft.count >= Habits.maxLength - 15 {
                Text("\(draft.count)/\(Habits.maxLength)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if !trimmed.isEmpty {
                Button("添加", action: add)
                    .buttonStyle(.prominent)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Inset.card)
        .frame(height: 40)
        .animation(.easeOut(duration: 0.12), value: trimmed.isEmpty)
    }

    /// While there is no habit yet: a few to start from. One click puts it in the field, to change or add.
    private var examples: some View {
        underField {
            FlowLayout(spacing: Space.xs, lineSpacing: Space.xs) {
                Text("比如")
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 22)
                ForEach(HabitText.examples, id: \.self) { example in
                    Button {
                        draft = example
                        typing = true
                    } label: {
                        Text(example)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Space.xs + 2)
                            .frame(height: 22)
                            .background(Capsule(style: .continuous).fill(Theme.fill))
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("填进上面的输入框，可以改了再添加")
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        underField {
            Text(Words.keepQuotes(text))
                .font(Typo.caption)
                .foregroundStyle(Theme.caution)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Under the field's text: past a hidden copy of the + in front of it, so the two start on one line.
    private func underField<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 15))
                .hidden()
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Inset.card)
        .padding(.bottom, Space.s)
    }

    private func add() {
        guard !trimmed.isEmpty else { return }
        if let why = Habits(learning.habits).problem(adding: draft) {
            problem = why
            return
        }
        if learning.addHabit(draft) { draft = "" }
    }
}

/// One habit: its text, and pointed at, a × after it (删除这条习惯 is in the context menu too).
private struct HabitRow: View {
    let text: String
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.xs) {
            // A habit of the full length runs to a second line in a narrow window.
            Text(text)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s)
            if hovering || LearnedRow._debugHovering {
                RowRemoveButton(help: "删除这条习惯", action: remove)
                    .transition(.opacity)
            }
        }
        .font(Typo.rowTitle)
        .padding(.horizontal, Inset.card)
        .padding(.vertical, Space.xs)
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu { Button("删除这条习惯", action: remove) }
    }
}

/// "看到你常删掉句末的句号 · 记成习惯？  记下  不用", and under it what taking it adds. neoless only asks:
/// the habit is added when the user presses 记下, and 不用 keeps the question away for a month.
private struct HabitOfferRow: View {
    let offer: HabitSuggestion
    /// The list is full: nothing can be added until a habit is deleted.
    let full: Bool
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            // In the box of the field's own +, so the two rows' texts start on one line.
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 15))
                .hidden()
                .overlay {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(Words.keepQuotes(offer.question))
                    .font(Typo.rowTitle)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Words.keepQuotes(HabitText.adds(offer.wording)))
                    .font(Typo.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.m)
            // With the list full, the line under this row says why it cannot be taken.
            Button("记下", action: accept)
                .buttonStyle(.prominent)
                .controlSize(.small)
                .disabled(full)
            Button("不用", action: decline)
                .buttonStyle(.pushButton)
                .controlSize(.small)
                .help("30 天内不再问这一条")
        }
        .padding(.horizontal, Inset.card)
        .padding(.vertical, Space.xs + 2)
        .frame(minHeight: 44)
    }
}

/// The 自动学习 switch, shared by the dictionary and settings pages.
struct LearningToggleRow: View {
    @EnvironmentObject var learning: LearningStore
    var detail = "修改 neoless 输入的文字后，自动记住改对的词"

    var body: some View {
        SettingRow(title: "自动学习", detail: detail) {
            Toggle("", isOn: $learning.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

/// One entry of the learning log: "Claude · 记住了 2 个词      今天 14:02".
private struct LearningLogRow: View {
    let entry: LearningLog.Entry

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(kept == .nothing ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.accent))
                .frame(width: 16)
            Text(entry.app.map { "\($0) · \(line)" } ?? line)
                .foregroundStyle(kept == .nothing ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: Space.s)
            Text("\(LearnedRow.day(entry.at)) \(entry.at.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .font(Typo.rowTitle)
        .padding(.horizontal, Inset.card)
        .frame(minHeight: 36)
    }

    /// What the edit left behind: a word learned, a swap remembered for its second time, or nothing.
    private enum Kept { case learned, noted, nothing }

    private var kept: Kept {
        switch LearningLog.Code(rawValue: entry.code) {
        case .learned, .repeated: return .learned
        case .candidate: return .noted
        default: return .nothing
        }
    }

    private var line: String { LearningText.line(code: entry.code, count: entry.count) }
    private var symbol: String {
        switch kept {
        case .learned: return "checkmark.circle.fill"
        case .noted: return "circle.lefthalf.filled"
        case .nothing: return LearningLog.Code(rawValue: entry.code)?.isUnwatched == true ? "eye.slash" : "minus.circle"
        }
    }
}

/// `--snapshot` only: the rows of 学到的纠正 and 我的习惯 drawn as if pointed at, to show their ×.
enum LearnedRowDebug {
    static var hovering = false
}

/// 今天 and 昨天 for the history list and the dictionary page, from the clock; `--snapshot` pins the moment to
/// its invented day, so a picture says nothing of when it was rendered.
enum DayNames {
    static var pinnedNow: Date?

    /// "今天" or "昨天", nil for any other day.
    static func relative(_ date: Date, calendar: Calendar = .current) -> String? {
        let now = pinnedNow ?? Date()
        if calendar.isDate(date, inSameDayAs: now) { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天"
        }
        return nil
    }
}

/// The × a row shows while it is pointed at.
private struct RowRemoveButton: View {
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(hovering ? Theme.fill : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// "Open Air → OpenAI      今天 · 改过 3 次". At rest the date ends on the card line; pointed at,
/// a × slides in after it (and 忘记这条纠正 is in the context menu). `tags`: small badges after the pair
/// (how it was learned, the Neo's own corrections, one the Neo did not take). `waiting`: a swap made once,
/// which is used for nothing yet, so its new word is not set off as a correction's is.
private struct LearnedRow: View {
    struct Tag: Equatable {
        var text: String
        var help = ""
        /// Grey instead of the accent: for what is not in use.
        var quiet = false
    }

    let pair: CorrectionPair
    /// "今天 · 改过 3 次"
    let detail: String
    var tags: [Tag] = []
    var waiting = false
    var removeTitle = "忘记这条纠正"
    let remove: () -> Void
    @State private var hovering = false

    /// `--snapshot` only: every row drawn as if pointed at, to show the ×.
    static var _debugHovering: Bool { LearnedRowDebug.hovering }

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(pair.wrong)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(pair.right)
                .fontWeight(waiting ? .regular : .medium)
                .foregroundStyle(waiting ? .secondary : .primary)
                .lineLimit(1)
            ForEach(tags, id: \.text) { tag in
                Text(tag.text)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tag.quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.badgeText))
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(Capsule(style: .continuous).fill(tag.quiet ? Theme.fill : Theme.badgeFill))
                    .fixedSize()
                    .help(tag.help)
            }
            Spacer(minLength: Space.s)
            Text(detail)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            if hovering || Self._debugHovering {
                RowRemoveButton(help: removeTitle, action: remove)
                    .transition(.opacity)
            }
        }
        .font(Typo.rowTitle)
        .padding(.horizontal, Inset.card)
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu { Button(removeTitle, action: remove) }
    }

    static func day(_ date: Date) -> String {
        DayNames.relative(date) ?? date.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN")))
    }
}

/// A word in the dictionary: a 24pt chip, its text centred. Pointed at, a small × badge appears on
/// its corner (移除 is also in its context menu), so a page of words is not a page of ×.
private struct WordChip: View {
    let word: String
    var learned = false
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.xs - 2) {
            Text(word)
                .font(Typo.rowTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if learned {
                Text("自动")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.badgeText)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(Capsule(style: .continuous).fill(Theme.badgeFill))
                    .help("自动学到的词")
            }
        }
        .padding(.horizontal, Space.s - 2)
        .frame(height: 24)
        .background(Capsule(style: .continuous).fill(Theme.fill))
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(Theme.pushFill).shadow(color: .black.opacity(0.12), radius: 1, y: 0.5))
                    .overlay(Circle().strokeBorder(Theme.pushBorder, lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("移除“\(word)”")
            // Mostly inside the chip, so moving onto it keeps the chip pointed at.
            .offset(x: 4, y: -4)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .contentShape(Capsule(style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu { Button("移除", action: remove) }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var account: ChatGPTAccount
    @EnvironmentObject var status: SystemStatus
    @EnvironmentObject var vocabulary: VocabularyStore
    @EnvironmentObject var hub: HubConnection
    @EnvironmentObject var learning: LearningStore
    /// Neo 处理中心: what is typed into the address and pairing fields.
    @State private var hubAddress = AppSettings.shared.hubAddress
    @State private var pairText = ""
    @State private var addressProblem = false
    @State private var confirmUnpair = false
    @FocusState private var editingAddress: Bool
    @State private var testResult: String?
    @State private var testing = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    /// ChatGPT 整理 › 高级 (fast mode, waiting time, test): folded until asked for.
    @State private var showAdvanced = SettingsView.advancedOpen

    /// Snapshots only: render 高级 open.
    static var advancedOpen = false

    var body: some View {
        // What people change day to day first; the ChatGPT setup, input rules and permissions after.
        PageScaffold(title: "设置", subtitle: "整理方式、快捷键、录音和权限，改动会立即生效。") {
            dictation
            neo
            hotkey
            recording
            chatGPT
            inputAndLearning
            permissions
            general
        }
    }

    // MARK: Sections
    // Rows are text only, as in System Settings: icons stay where they name a thing (权限). Pop-ups
    // are borderless, the value and ⌃⌄ hugging the trailing edge, as System Settings draws them.

    private var dictation: some View {
        GroupSection("听写", footer: dictationFooter) {
            SettingRow(title: "默认模式", detail: settings.mode.summary) {
                Picker("", selection: $settings.mode) {
                    ForEach(DictationMode.allCases) { Text($0.shortTitle).tag($0) }
                }
                .settingsPopUp()
            }
            RowDivider()
            SettingRow(title: "AI 应用里用结构化",
                       detail: settings.mode == .natural
                           ? "在 \(AIAppExamples.text)里，\(Words.keep("自然整理"))会换成结构化"
                           : "默认模式是自然整理时才起作用") {
                Toggle("", isOn: $settings.autoStructuredForAI).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(settings.mode != .natural)
            }
            RowDivider()
            SettingRow(title: "识别语言") {
                Picker("", selection: $settings.localeID) {
                    ForEach(AppSettings.locales, id: \.id) { Text($0.title).tag($0.id) }
                }
                .settingsPopUp()
            }
            if status.speech && !status.speechModel {
                RowDivider()
                // The dot marks it; the explanation stays secondary, as Apple does it.
                SettingRow(attention: true, title: SpeechModelText.title + "未下载",
                           detail: "现在没法识别。\(SpeechModelText.howTo(SpeechModelText.language(settings.localeID)))") {
                    Button("打开键盘设置") { Permissions.openKeyboardSettings() }
                }
            }
        }
    }

    /// The 听写 group's footer: who recognises and who polishes. With 本机识别 the Neo only polishes.
    private var dictationFooter: String {
        guard hub.isActive else { return "识别都在这台 Mac 上完成；自然整理和结构化会把识别出的文字发给 ChatGPT 整理。" }
        if hub.recognizesHere {
            return "这台 Mac 识别，文字发到你的 Neo 用 ChatGPT 整理；没听清时录音交给 Neo；连不上 Neo 时在这台 Mac 上完成。"
        }
        return "录音发到你的 Neo 识别，再由 Neo 上的 ChatGPT 整理；连不上 Neo 时在这台 Mac 上完成。"
    }

    // MARK: Neo 处理中心

    private var neo: some View {
        GroupSection("Neo 处理中心",
                     footer: "在 Neo 上运行 neoless-hub pair，把得到的链接粘贴到这里。连不上 Neo 时，自动用这台 Mac 处理，不会丢字。") {
            SettingRow(title: "用 Neo 处理（推荐）", detail: "录音发到你自己的 Neo（家里那台 Mac）识别和整理") {
                Toggle("", isOn: $settings.hubEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            RowDivider()
            // Which of the Neo's two speech models each recording asks for, or 本机识别 (this Mac's own transcript,
            // polished by the Neo). The line says what the choice does, with the model's name when the Neo told it;
            // on a Neo that has not said it has both, only 自动 and 本机识别 are offered and the line says what is
            // missing for the others.
            SettingRow(title: "识别模型", detail: modelRow.detail) {
                Picker("", selection: $settings.asrModel) {
                    ForEach(modelRow.choices) { Text($0.title).tag($0) }
                }
                .settingsPopUp()
                .disabled(!modelRow.enabled)
            }
            RowDivider()
            SettingRow(attention: addressProblem, title: "服务器地址", detail: addressProblem ? HubConnection.badAddress : nil) {
                if let pairing = hub.pairing {
                    // The pairing's own: a new address comes with a new pairing link.
                    Text(pairing.server.absoluteString)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 230, alignment: .trailing)
                        .textSelection(.enabled)
                        .help("换地址要先断开配对")
                } else {
                    TextField("", text: $hubAddress, prompt: Text(Hub.exampleServer.absoluteString))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 230)
                        .focused($editingAddress)
                        .onSubmit(saveAddress)
                        .onChange(of: editingAddress) { _, editing in if !editing { saveAddress() } }
                }
            }
            // Also while paired, so the field shows the latest address after 断开配对.
            .onChange(of: settings.hubAddress) { _, address in if !editingAddress { hubAddress = address } }
            if let link = hub.pending {
                RowDivider()
                // Opened from a link: nothing is paired until the user says so here. The whole address, said
                // plainly; the link's own name is not shown (a web page writes it).
                SettingRow(attention: true, title: "和这台 Neo 配对？",
                           detail: HubConnection.pendingDetail(link)) {
                    HStack(spacing: Space.xs) {
                        Button("取消") { hub.pending = nil }
                        Button("配对") { Task { await hub.confirmPending() } }
                            .buttonStyle(.prominent)
                            .disabled(hub.busy)
                    }
                }
            }
            if let pairing = hub.pairing {
                RowDivider()
                // With a new link waiting to be pasted below, what pairing has to say goes there.
                SettingRow(attention: !hub.needsNewLink && hub.message?.isError == true, title: "配对",
                           detail: (hub.needsNewLink ? nil : hub.message?.text) ?? "已配对，这台 Mac 在 Neo 上叫“\(pairing.name)”") {
                    Button("断开配对…") { confirmUnpair = true }
                }
                if hub.needsNewLink, hub.pending == nil {
                    RowDivider()
                    // The Neo refuses the token, or Cloudflare Access the credentials: a new link from the same Neo
                    // replaces the pairing, keeping what waits to be sent.
                    SettingRow(attention: true, title: "重新配对",
                               detail: hub.message?.text ?? "在 Neo 上运行 neoless-hub pair，把新链接粘贴到这里") {
                        pairField
                    }
                }
                RowDivider()
                // Whether the requests carry Cloudflare Access credentials. The credentials themselves are never shown.
                SettingRow(title: "双重锁",
                           detail: pairing.access == nil
                               ? "只用设备密钥。Neo 上设好 Cloudflare 门禁后，重新配对即可开启"
                               : "请求先过 Cloudflare 门禁，再凭设备密钥进 Neo") {
                    Text(pairing.access == nil ? "未开启" : "已开启")
                        .foregroundStyle(.secondary)
                }
            } else if hub.pending == nil {
                RowDivider()
                SettingRow(attention: hub.message?.isError == true, title: "配对",
                           detail: hub.message?.text ?? "粘贴 Neo 给的配对链接或设备密钥") {
                    pairField
                }
            }
            RowDivider()
            SettingRow(title: "状态", detail: hub.status.detail) {
                StatusDot(color: neoColor, text: hub.status.text)
            }
        }
        // What the status row says is at most a few minutes old otherwise.
        .onAppear { hub.check() }
        .confirmationDialog("断开和 Neo 的配对？", isPresented: $confirmUnpair) {
            Button("断开配对", role: .destructive) { hub.unpair() }
        } message: {
            Text("之后都用这台 Mac 处理。要再用 Neo，需要在 Neo 上重新生成配对链接。")
        }
    }

    /// 识别模型: whether the choice can be made, and what it does or what is missing for it to do anything.
    private var modelRow: NeoModelRow {
        NeoModelRow(choice: settings.asrModel, hubEnabled: settings.hubEnabled, paired: hub.pairing != nil,
                    support: hub.modelSupport, names: hub.modelNames)
    }

    /// Where a pairing link (or a bare device token) is pasted. A link with 双重锁 is long: the field scrolls it.
    private var pairField: some View {
        HStack(spacing: Space.xs) {
            TextField("", text: $pairText, prompt: Text("neoless://pair?…"))
                .textFieldStyle(.roundedBorder)
                .lineLimit(1)
                .frame(width: 170)
                .onSubmit(pair)
            Button(hub.busy ? "配对中…" : "配对", action: pair)
                .disabled(pairText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hub.busy)
        }
    }

    private var neoColor: Color {
        switch hub.status {
        case .off, .unpaired, .checking: return .secondary
        default: return hub.status.isProblem ? Theme.attention : Theme.ready
        }
    }

    private func saveAddress() {
        let text = hubAddress
        guard text != settings.hubAddress, hub.pairing == nil else {
            addressProblem = false
            return
        }
        addressProblem = !hub.setAddress(text)
        if !addressProblem { hubAddress = settings.hubAddress }
    }

    private func pair() {
        let text = pairText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !hub.busy else { return }
        Task {
            if await hub.pair(pasted: text) { pairText = "" }
        }
    }

    private var hotkey: some View {
        GroupSection("快捷键", footer: hotkeyFooter) {
            SettingRow(title: "用快捷键听写") {
                Toggle("", isOn: $settings.hotkeyEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            RowDivider()
            SettingRow(title: "按键") {
                Picker("", selection: $settings.trigger) {
                    ForEach(HotkeyTrigger.allCases) { Text($0.menuTitle).tag($0) }
                }
                .settingsPopUp()
                .disabled(!settings.hotkeyEnabled)
            }
            RowDivider()
            SettingRow(title: "按键方式", detail: settings.hotkeyStyle.usage(settings.trigger.keyName)) {
                Picker("", selection: $settings.hotkeyStyle) {
                    ForEach(HotkeyStyle.allCases) { Text($0.title).tag($0) }
                }
                .settingsPopUp()
                .disabled(!settings.hotkeyEnabled)
            }
            RowDivider()
            SettingRow(title: "状态") {
                HStack(spacing: Space.s) {
                    StatusDot(color: hotkeyColor, text: hotkeyStatus)
                    // The fix right where the problem is named, not five sections down.
                    if settings.hotkeyEnabled && !status.accessibility {
                        Button("去允许") { Permissions.requestAccessibility() }
                    }
                }
            }
            if status.holdOnly(settings) {
                RowDivider()
                SettingRow(title: "暂时只能按住 \(settings.trigger.keyName) 说话",
                           detail: "有应用开着“安全键盘输入”（密码框、终端），离开后恢复")
            }
            if SetupChecklist.globeKeyConflicts(status.setupFacts(account: account, settings: settings)) {
                RowDivider()
                // Advice, not a missing step: no orange dot.
                SettingRow(title: GlobeKeyText.title(status.globeKey), detail: GlobeKeyText.fix) {
                    Button("打开键盘设置") { Permissions.openKeyboardSettings() }
                }
            }
        }
    }

    /// Esc and the hotkey while a dictation runs, as the controller handles them (`CaptureFlow`). Esc
    /// reaches neoless only through the hotkey's event tap, which is off while the hotkey is.
    private var hotkeyFooter: String {
        guard settings.hotkeyEnabled else { return "快捷键关闭时，用窗口里的按钮或浮层上的 × / ✓ 控制听写。" }
        return "录音时按 Esc 取消；说完后再按 Esc，这次就不输入"
            + (settings.keepHistory ? "，结果仍会存进历史记录。" : "。")
    }

    private var recording: some View {
        GroupSection("录音") {
            SettingRow(title: "输入设备", detail: microphoneDetail) {
                Picker("", selection: $settings.microphoneUID) {
                    Text("自动").tag(AppSettings.microphoneAuto)
                    Text("跟随系统").tag(AppSettings.microphoneSystem)
                    ForEach(status.microphones) { Text($0.name).tag($0.uid) }
                }
                .settingsPopUp()
            }
            RowDivider()
            SettingRow(title: "录音浮层位置",
                       detail: settings.hudFollowsCaret ? "显示在光标附近；找不到光标时放在窗口或屏幕底部" : "屏幕底部居中，程序坞上方") {
                Picker("", selection: $settings.hudFollowsCaret) {
                    Text("底部居中").tag(false)
                    Text("跟随光标").tag(true)
                }
                .settingsPopUp()
            }
            RowDivider()
            // Under the caret the capsule can hang below the line, and the subtitle with it.
            SettingRow(title: "实时字幕",
                       detail: settings.hudFollowsCaret ? "录音时在浮层旁显示正在识别的文字" : "录音时在浮层上方显示正在识别的文字") {
                Toggle("", isOn: $settings.liveTranscript).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            RowDivider()
            SettingRow(title: "一分钟没说话就自动结束", detail: "说过的话照常输入；按住说话时不会自动结束") {
                Toggle("", isOn: $settings.silenceAutoStop).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private var microphoneDetail: String? {
        switch settings.microphoneUID {
        case AppSettings.microphoneAuto: return "优先用内置麦克风，AirPods 不会变成通话音质"
        case AppSettings.microphoneSystem: return "用系统设置里选的麦克风"
        default: return nil
        }
    }

    private var chatGPT: some View {
        GroupSection("ChatGPT 整理",
                     footer: hub.isActive ? "用 Neo 处理时，这里的登录只在连不上 Neo 时用。" : nil) {
            SettingRow(attention: !account.isReady && settings.mode.polishes && !hub.covers, title: "ChatGPT 账号",
                       detail: account.status.text) {
                HStack(spacing: Space.xs) {
                    if account.tokens == nil {
                        if account.signingIn { Button("取消") { account.cancelSignIn() } }
                        Button(account.signingIn ? "等待浏览器登录…" : "登录 ChatGPT") { Task { await account.signIn() } }
                            .disabled(account.signingIn)
                    } else {
                        Button("退出登录") { account.signOut() }
                    }
                }
            }
            if let message = account.message {
                RowDivider()
                SettingRow(title: "登录信息", detail: message)
            }
            RowDivider()
            // Out of 高级: the one choice here that changes every dictation, the Neo's polishing included (each
            // request names it), once the Neo's hub reads it: until then the line says the Neo uses its own.
            SettingRow(title: "整理模型", detail: hub.polishSupport.modelDetail(settings.model)) {
                Picker("", selection: $settings.model) {
                    ForEach(PolishModel.all) { Text($0.title).tag($0.id) }
                }
                .settingsPopUp()
            }
            RowDivider()
            // Rarely changed: one row until opened.
            Button { withAnimation(.easeInOut(duration: 0.2)) { showAdvanced.toggle() } } label: {
                SettingRow(title: "高级", detail: showAdvanced ? nil : "快速模式、等待时间、测试整理") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showAdvanced {
                RowDivider()
                SettingRow(title: "快速模式", detail: hub.polishSupport.fastTierDetail) {
                    Toggle("", isOn: $settings.fastTier).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                RowDivider()
                SettingRow(title: "整理等待时间", detail: "超时就输入原文；话长时会多等一会儿") {
                    HStack(spacing: Space.xs) {
                        Text("\(Int(settings.polishTimeout)) 秒")
                            .font(Typo.rowTitle.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Stepper("", value: $settings.polishTimeout, in: PolishTimeout.settingRange, step: 1).labelsHidden()
                    }
                }
                RowDivider()
                SettingRow(title: "测试整理", detail: testResult ?? "用一句示例口述试一下整理效果和速度") {
                    Button(testing ? "测试中…" : "测试") { test() }.disabled(testing || !account.isReady)
                }
            }
        }
    }

    private var inputAndLearning: some View {
        GroupSection("输入与学习",
                     footer: "文字会输入到你说完时的输入框；换了输入框或找不到时只复制，按 \(Words.cmdVPaste)。\(Words.keep("密码框里不输入。"))") {
            SettingRow(title: "恢复剪贴板", detail: "输入完放回你原来复制的内容") {
                Toggle("", isOn: $settings.restoreClipboard).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            RowDivider()
            LearningToggleRow(detail: "改字时会短暂读取那个输入框，只记\(Words.keep("“错词 → 正确词”"))，可在\(Words.keep("个人词典"))里删除")
            // Code editors of the VS Code family are asked to make their fields readable only when switched on
            // here, one by one: being asked can put them into their screen-reader mode.
            ForEach(editors, id: \.bundleID) { editor in
                RowDivider()
                SettingRow(title: "学习 \(editor.name) 里的修改", detail: WebAccessibility.editorWarning) {
                    Toggle("", isOn: Binding(get: { learning.editors.contains(editor.bundleID) },
                                             set: { learning.setEditor(editor.bundleID, on: $0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(!learning.enabled)
                }
            }
        }
    }

    /// The code editors on this Mac (and any switched on before), for the rows above.
    private var editors: [WebAccessibility.Editor] {
        WebAccessibility.editors.filter { editor in
            learning.editors.contains(editor.bundleID)
                || NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID) != nil
        }
    }

    private var permissions: some View {
        GroupSection("权限") {
            PermissionRow(icon: "mic", title: "麦克风", detail: PermissionText.microphone, ok: status.microphone) {
                Task { if await !Permissions.requestMicrophone() { Permissions.open(.microphone) }; status.refresh() }
            }
            RowDivider(inset: RowDivider.afterIcon)
            PermissionRow(icon: "waveform", title: "语音识别", detail: PermissionText.speech, ok: status.speech) {
                Task { if await !Permissions.requestSpeech() { Permissions.open(.speech) }; status.refresh() }
            }
            RowDivider(inset: RowDivider.afterIcon)
            PermissionRow(icon: "accessibility", title: "辅助功能", detail: PermissionText.accessibility(settings.trigger),
                          ok: status.accessibility) {
                Permissions.requestAccessibility()
            }
        }
    }

    private var general: some View {
        GroupSection("通用", footer: "关掉窗口或按 ⌘Q，neoless 仍在菜单栏运行；要退出，右键点菜单栏图标，选“退出 neoless”。") {
            SettingRow(title: "登录 Mac 时自动打开") {
                Toggle("", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .onChange(of: launchAtLogin) { _, on in LaunchAtLogin.set(on) }
            }
            RowDivider()
            SettingRow(title: "保存历史", detail: (hub.isActive ? "保存最近 30 天的听写在这台 Mac 上；Neo 也会留一份"
                                                                 : "保存最近 30 天的听写，只存在这台 Mac 上")
                                                  + "；次数和字数的统计不受影响") {
                Toggle("", isOn: $settings.keepHistory).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            RowDivider()
            SettingRow(title: "版本") {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                    .font(Typo.rowTitle)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Helpers

    private var hotkeyStatus: String {
        if !settings.hotkeyEnabled { return "已关闭" }
        if !status.accessibility { return "需要辅助功能权限" }
        return status.hotkeyRunning ? "可以使用" : "连接中…"
    }

    private var hotkeyColor: Color {
        if !settings.hotkeyEnabled { return .secondary }
        return status.hotkeyRunning ? Theme.ready : Theme.attention
    }

    private func test() {
        testing = true
        testResult = nil
        let sample = "嗯那个我明天，呃，下午三点吧不对四点，跟 Martin 开个会，讨论一下 Open Air 的订阅费用，大概是两百块一个月"
        let started = Date()
        Task {
            defer { testing = false }
            do {
                let text = try await Polisher.polish(transcript: sample, vocabulary: vocabulary.promptWords, appName: nil,
                                                     account: account, mode: settings.mode.polishes ? settings.mode : .natural)
                testResult = String(format: "%.1f 秒：", Date().timeIntervalSince(started)) + text
            } catch {
                testResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// Same tile and wording as the home checklist: an orange dot and 允许 while it is missing.
struct PermissionRow: View {
    static let allowTitle = "允许"

    var icon = "lock"
    let title: String
    var detail: String?
    let ok: Bool
    let action: () -> Void

    var body: some View {
        SettingRow(icon: icon, attention: !ok, title: title, detail: detail) {
            if ok {
                GrantedMark()
            } else {
                Button(Self.allowTitle, action: action).buttonStyle(.pushButton)
            }
        }
    }
}
