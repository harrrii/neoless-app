import AppKit
import Carbon.HIToolbox
import NeolessCloud
import NeolessCore
import SwiftUI

/// Command-line checks that need no microphone, keyboard or permission prompts:
///   neoless --test-polish "逐字稿"     one real polish request, prints result and time
///   neoless --polish-eval [--mode natural|structured] [--dry-run]
///                                      a fixed set of transcripts through the real polish, input and output
///   neoless --test-callback            OAuth loopback listener; prints the code it receives
///   neoless --snapshot <dir>           renders every page and HUD state to PNG
///                                      (NEOLESS_SNAPSHOT_ONLY=home-ready,overview-* renders only those pages)
///   neoless --snapshot-hud <dir>       renders only the HUD capsule states
///   neoless --check-keys               the page keys (⌘1 … ⌘4, 1 … 4) against the real menu and pages, off screen
@MainActor
enum DebugCommands {
    static func wants(_ args: [String]) -> Bool {
        SingleInstance.isDebugRun(args)
    }

    static func run(_ args: [String]) async {
        if let i = args.firstIndex(of: "--test-polish") {
            let text = i + 1 < args.count ? args[i + 1] : "嗯那个我明天下午三点吧不对四点跟 Martin 开个会"
            let started = Date()
            let account = ChatGPTAccount()
            do {
                let out = try await Polisher.polish(transcript: text, vocabulary: Vocabulary.promptWords(Vocabulary.defaults),
                                                    appName: "Codex", account: account)
                print(String(format: "OK %.2fs (model %@, fast %@)", Date().timeIntervalSince(started), AppSettings.shared.model, AppSettings.shared.fastTier ? "on" : "off"))
                print(out)
            } catch {
                print("ERROR", (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
            // A polish timeout stops waiting for a token refresh but not the refresh: let it save before exit(0).
            await account.waitForRefresh()
        } else if args.contains("--polish-eval") {
            await polishEval(args)
        } else if args.contains("--test-callback") {
            let server = OAuthCallbackServer()
            do {
                try server.start(port: ChatGPTOAuth.callbackPort)
                print("listening on \(ChatGPTOAuth.redirectURI)")
                fflush(stdout)
                let code = try await server.waitForCode(state: "teststate", timeout: 20)
                print("CODE", code)
            } catch {
                print("ERROR", error)
            }
        } else if let i = args.firstIndex(of: "--snapshot-hud"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let vocabulary = VocabularyStore(preview: sampleWords)
            let controller = DictationController(settings: AppSettings.shared, history: HistoryStore(preview: sampleRecords()),
                                                 vocabulary: vocabulary, account: ChatGPTAccount(),
                                                 learning: LearningStore(preview: [], vocabulary: vocabulary))
            controller.current = sampleRecords().first
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                await snapshotHUD(controller: controller, appearanceName: name, appearance: appearance, to: dir)
            }
            print("snapshots in \(dir.path)")
        } else if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            await snapshot(to: URL(fileURLWithPath: args[i + 1]))
        } else if args.contains("--check-keys") {
            let passed = await checkKeys()
            fflush(stdout)
            exit(passed ? 0 : 1)
        }
        fflush(stdout)
        exit(0)
    }

    /// The dictionary the shots draw: product names anyone might add, none of them the user's own words.
    /// (`sampleLearned` marks Claude as learned, so it has to be in the list.)
    static let sampleWords = ["OpenAI", "ChatGPT", "Codex", "Claude", "neoless", "GitHub", "App Store", "SSH"]

    /// The invented moment every page shot is drawn at (Saturday 10 October 2026, 15:30 on this Mac's clock): the
    /// sample rows are dated back from it and the window names 今天 and 昨天 from it, so a picture says nothing of
    /// the day, the hour or the time zone it was rendered in.
    static let sampleNow = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 15, minute: 30)) ?? Date()

    /// Sample data used only for rendering: an invented day of dictation (nobody said any of it). The one
    /// into Claude (an AI app) came out as 结构化, as it would with the default settings.
    static func sampleRecords(now: Date = Date()) -> [DictationRecord] {
        func r(_ minutesAgo: Double, _ raw: String, _ final: String, _ app: String, _ secs: Double,
               mode: DictationMode = .natural) -> DictationRecord {
            DictationRecord(date: now.addingTimeInterval(-minutesAgo * 60), duration: secs, raw: raw, polished: final, finalText: final,
                            appName: app, mode: mode, model: "gpt-6.1-sol", polishSeconds: 1.9, note: nil, delivery: .pasted)
        }
        return [
            r(2, "嗯那个我明天，呃，下午三点吧不对四点，跟 Martin 开个会，讨论一下 Open Air 的订阅费用",
              "我明天下午四点跟 Martin 开个会，讨论一下 OpenAI 的订阅费用。", "微信", 12.4),
            r(18, "帮我看一下这个登录的部分为什么跑不起来就是点了按钮之后没有反应",
              "帮我查一下登录为什么跑不起来。\n\n现象：点了登录按钮之后没有任何反应。", "Claude", 8.1, mode: .structured),
            r(55, "然后打印机墨盒的这个事情也帮我放在办公用品里面吧算耗材也算这个月的支出",
              "打印机墨盒这笔也帮我放进办公用品里，算耗材，也算这个月的支出。", "Numbers", 9.6),
            r(130, "好的没问题那我们周四下午两点在咖啡店见",
              "好的，没问题，那我们周四下午两点在咖啡店见。", "微信", 4.2),
            r(60 * 26, "so I think we should push the release to Friday because QA still needs more time",
              "I think we should push the release to Friday because QA still needs more time.", "Slack", 6.0),
            r(60 * 50, "提醒我下周一之前把场地的报价单整理一下然后发给大家",
              "提醒我下周一之前把场地的报价单整理好，发给大家。", "备忘录", 5.3),
        ]
    }

    /// Sample learned corrections; Claude is marked as learned-only so the 自动 tag renders.
    static func sampleLearned(now: Date = Date()) -> [LearnedCorrection] {
        func l(_ wrong: String, _ right: String, _ count: Int, _ daysAgo: Double, _ source: LearnedCorrection.Source,
               added: Bool = false) -> LearnedCorrection {
            let last = now.addingTimeInterval(-daysAgo * 86_400)
            return LearnedCorrection(pair: CorrectionPair(wrong: wrong, right: right), count: count,
                                     firstSeen: last.addingTimeInterval(-Double(count - 1) * 86_400 * 2), lastSeen: last,
                                     source: source, addedTerm: added)
        }
        return [
            l("Open Air", "OpenAI", 3, 0.1, .otherApp),
            l("Cloud", "Claude", 2, 1, .inApp, added: true),
            l("全线", "权限", 1, 3, .otherApp),
        ]
    }

    private static func snapshot(to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SnapshotWindow.drawAsActiveApp()
        let settings = AppSettings.shared
        // Every shot starts from the same fixed settings; the debug build's own are put back at the end.
        let savedSettings = SnapshotSettings(settings)
        SnapshotSettings.defaults.apply(to: settings)
        // One invented moment for every shot (put back at the end): no clock time of the render shows anywhere.
        let now = sampleNow
        DayNames.pinnedNow = now
        let records = sampleRecords(now: now)
        let history = HistoryStore(preview: records)
        let emptyHistory = HistoryStore(preview: [])
        // In memory, like the stores around it: no shot reads (or could move aside) the user's own dictionary.
        let vocabulary = VocabularyStore(preview: sampleWords)
        let account = snapshotAccount()
        let learning = LearningStore(preview: sampleLearned(now: now), vocabulary: vocabulary)
        let emptyLearning = LearningStore(preview: [], vocabulary: vocabulary)
        // Not paired (the default) until the Neo shots below; never stored, never sent.
        let hub = HubConnection(preview: nil, settings: settings)
        let controller = DictationController(settings: settings, history: history, vocabulary: vocabulary,
                                             account: account, learning: learning, hub: hub)
        // 今日概览's numbers for the sample day: counted from the sample records, as a first launch would. In
        // memory only (the controller above has no usage store, so nothing here is ever saved).
        var sampleStats = UsageStats()
        sampleStats.backfill(from: records, timeZone: .current)
        let usage = UsageStore(preview: sampleStats, today: UsageDate(now, timeZone: .current))
        let router = Router()
        // The chart as a new user sees it, whatever this build's own defaults remember; put back at the end.
        let savedChart = (router.chartRange, router.chartMetric)
        router.chartRange = .week
        router.chartMetric = .count
        let status = SystemStatus()
        status.hub = hub
        status.refresh()
        let levels: [Float] = (0..<24).map { i in Float(0.15 + 0.7 * abs(sin(Double(i) * 0.7))) }
        /// NEOLESS_SNAPSHOT_ONLY=home-ready,settings-full renders just those pages (and no capsule);
        /// a name ending in * takes every page that starts with it (overview-*).
        let only = ProcessInfo.processInfo.environment["NEOLESS_SNAPSHOT_ONLY"].map { $0.split(separator: ",").map(String.init) }
        func wanted(_ name: String) -> Bool {
            guard let only else { return true }
            return only.contains { $0.hasSuffix("*") ? name.hasPrefix(String($0.dropLast())) : $0 == name }
        }

        /// A Mac that has just installed neoless: nothing granted yet, the 🌐 key at the system default …
        func useFreshStatus() {
            status.refresh()
            status.microphone = false; status.speech = false; status.accessibility = false
            status.hotkeyRunning = false; status.globeKey = .systemDefault
            status.speechModel = true; status.secureInput = false; status.recoveredFiles = []
            status.frozen = true
        }
        /// … or the steady state once everything has been granted.
        func useReadyStatus() {
            status.refresh()
            status.microphone = true; status.speech = true; status.accessibility = true
            status.hotkeyRunning = true; status.globeKey = .doNothing
            status.speechModel = true; status.secureInput = false; status.recoveredFiles = []
            status.frozen = true
        }
        /// The record a finished dictation leaves, matching what its done line says.
        func result(_ base: DictationRecord, delivery: Delivery, polished: Bool = true, notes: [String] = []) -> DictationRecord {
            var record = base
            record.date = now.addingTimeInterval(-20)
            record.delivery = delivery
            if !polished { record.polished = nil; record.finalText = record.raw; record.polishSeconds = nil; record.model = nil }
            record.note = notes.isEmpty ? nil : notes.joined(separator: "；")
            return record
        }

        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            func main(_ store: HistoryStore = history, _ learned: LearningStore = learning, _ used: UsageStore = usage) -> some View {
                MainView()
                    .environmentObject(controller).environmentObject(settings).environmentObject(store)
                    .environmentObject(vocabulary).environmentObject(learned).environmentObject(account)
                    .environmentObject(router).environmentObject(status).environmentObject(hub)
                    .environmentObject(used)
            }
            func shot(_ name: String, _ store: HistoryStore = history, learned: LearningStore = learning,
                      usage used: UsageStore = usage, size: NSSize = NSSize(width: 1000, height: 680)) async {
                guard wanted(name) else { return }
                await render(main(store, learned, used), size: size, appearance: appearance, chrome: true,
                             to: dir.appendingPathComponent("\(appearanceName)-page-\(name).png"))
            }
            let tall = NSSize(width: 1000, height: 2300)

            useFreshStatus()
            controller.current = records.first
            for page in Page.allCases {
                controller.debugShow(phase: .idle, levels: levels)
                router.section = page
                await shot(page.rawValue)
            }
            router.section = .home

            // Steady state: every permission granted, hotkey running. (Recording needs the microphone,
            // so it is only ever shown with permissions in place.)
            useReadyStatus()
            controller.debugShow(phase: .starting, levels: levels)
            await shot("home-starting")
            controller.debugShow(phase: .recording, levels: levels, liveText: "我明天下午四点跟 Martin 开个会，讨论一下")
            await shot("home-recording")
            controller._debugSet(phase: .recording, levels: levels, liveText: "我明天下午四点跟 Martin 开个会", holdToTalk: true)
            await shot("home-recording-hold")
            controller.debugShow(phase: .idle, levels: levels)
            await shot("home-ready")
            controller.debugShow(phase: .polishing, levels: levels, liveText: "我明天下午四点跟 Martin 开个会，讨论一下 OpenAI 的订阅费用")
            await shot("home-polishing")
            controller.debugShow(phase: .done(InsertResult.pasted.message), levels: levels)
            await shot("home-done")
            // What the line under the headline says when the text was not simply typed, each over the
            // record that outcome leaves (copied, not polished, with its note).
            let first = records[0]
            let outcomes: [(String, String, DictationRecord)] = [
                ("done-copied", InsertResult.copiedAppChanged.message,
                 result(first, delivery: .copied, notes: [InsertResult.copiedAppChanged.detail ?? ""])),
                ("done-clipboard", InsertResult.pastedKeptOnClipboard.message,
                 result(first, delivery: .pasted, notes: [InsertResult.pastedKeptOnClipboard.detail ?? ""])),
                ("done-copied-fallback", "\(InsertResult.copiedNoField.message) · \(PolishError.timeout.short)",
                 result(first, delivery: .copied, polished: false,
                        notes: [PolishFailure.detail(PolishError.timeout), InsertResult.copiedNoField.detail ?? ""])),
                // Esc while polishing: first the previous result stays (上一次), then the cancelled one lands.
                ("paste-cancelled-waiting", DoneText.pasteCancelled(keepHistory: true), first),
                ("paste-cancelled", DoneText.pasteCancelled(keepHistory: true),
                 result(records[1], delivery: .notInserted, notes: [RecordNote.pasteCancelled])),
            ]
            for (name, message, record) in outcomes {
                controller.current = record
                controller.debugShow(phase: .done(message), levels: levels)
                await shot("home-\(name)")
            }
            controller.current = records.first
            controller.debugShow(phase: .idle, levels: levels)
            // Secure input somewhere: the hotkey is hold-to-talk only for now.
            status.secureInput = true
            await shot("home-secure-input")
            // The checklist's newer rows: everything granted, but the language is not downloaded and
            // the 🌐 key still does something …
            status.speechModel = false
            status.globeKey = .systemDefault
            await shot("home-setup-model")
            router.section = .settings
            await shot("settings-attention", size: tall)
            router.section = .home
            // … and the 🌐 key alone (switching input sources), which is one quiet line, not a card.
            status.secureInput = false
            status.speechModel = true
            status.globeKey = .action(1)
            await shot("home-globe-only")
            status.globeKey = .doNothing
            // Learning notice with undo, then the hint for an app that cannot be observed.
            learning._debugSet(notice: [CorrectionPair(wrong: "Open Air", right: "OpenAI")], recordID: records.first?.id)
            await shot("home-learned")
            learning._debugSet(notice: nil, recordID: nil, unsupported: records.first?.id)
            await shot("home-unsupported")
            learning._debugSet(notice: nil, recordID: nil)
            // A data file that did not read back this launch.
            status.recoveredFiles = ["history.json.corrupt-20261007-204500"]
            await shot("home-recovered")
            status.recoveredFiles = []
            // ChatGPT refused the login: a fallback result (typed, not polished) that ends in signing in again.
            let refused = PolishError.http(401, "")
            controller.current = result(first, delivery: .pasted, polished: false, notes: [PolishFailure.detail(refused)])
            controller.debugShow(phase: .done(FailureText.typedRaw(reason: PolishFailure.short(refused))), levels: levels)
            await shot("home-done-fallback")
            controller.current = records.first
            controller.debugShow(phase: .idle, levels: levels)
            // A long result: the editor grows to eight lines, then scrolls.
            if var long = records.first {
                long.finalText = Array(repeating: long.finalText + "然后把上个月的报销单也整理一下，周五之前发给大家。", count: 5).joined(separator: "\n")
                controller.current = long
                await shot("home-long")
            }
            controller.current = records.first
            // The other two modes: the line under the headline, and a 结构化 result saying so.
            settings.mode = .structured
            controller.current = records[1]
            await shot("home-mode-structured")
            settings.mode = .raw
            controller.current = records.first
            await shot("home-mode-raw")
            router.section = .settings
            await shot("settings-mode-raw", size: tall)
            settings.mode = .natural
            // The capsule following the caret: both overlay rows say where it goes.
            settings.hudFollowsCaret = true
            await shot("settings-follow-caret", size: tall)
            settings.hudFollowsCaret = false
            router.section = .home
            // No hotkey: the round button is the way to start, and the only way to stop.
            settings.hotkeyEnabled = false
            await shot("home-hotkey-off-idle")
            controller.debugShow(phase: .recording, levels: levels, liveText: "我明天下午四点跟 Martin 开个会")
            await shot("home-hotkey-off")
            controller.debugShow(phase: .idle, levels: levels)
            router.section = .settings
            await shot("settings-hotkey-off", size: tall)
            router.section = .home
            settings.hotkeyEnabled = true
            router.section = .dictionary
            await shot("dictionary-nolearned", learned: emptyLearning)
            router.section = .home
            await learningShots(router: router, controller: controller, vocabulary: vocabulary, records: records,
                                light: appearanceName == "light") { name, store, size in
                await shot(name, learned: store, size: size)
            }
            // With no result in memory (after the app was reopened) the newest history entry is shown …
            controller.current = nil
            await shot("home-from-history")
            // … and the empty card shows only when there is no history at all.
            await shot("home-empty", emptyHistory)
            router.section = .history
            await shot("history-empty", emptyHistory)
            settings.keepHistory = false
            await shot("history-off", emptyHistory)
            settings.keepHistory = true
            await neoShots(hub: hub, router: router, controller: controller, records: records, levels: levels) { name, store, size in
                await shot(name, store ?? history, size: size)
            }
            await overviewShots(router: router, controller: controller, settings: settings, learning: learning, levels: levels) { name, store, used, size in
                // A new user has learned nothing yet (the hint under the result shows); months in, they have.
                await shot(name, store, learned: used.stats.activeDays > 3 ? learning : emptyLearning, usage: used, size: size)
            }
            controller.current = records.first
            router.section = .settings
            await shot("settings-ready")
            // Whole settings page in one picture, to review every section, then with 高级 open.
            await shot("settings-full-ready", size: tall)
            SettingsView.advancedOpen = true
            await shot("settings-advanced", size: tall)
            SettingsView.advancedOpen = false
            useFreshStatus()
            await shot("settings-full", size: tall)
            useReadyStatus()
            if appearanceName == "light" {
                // Smallest allowed window, to catch truncation and awkward wrapping.
                controller.current = records.first
                for page in Page.allCases {
                    router.section = page
                    await shot("\(page.rawValue)-compact", size: NSSize(width: 860, height: 580))
                }
                // Every settings row at the narrowest width, and the longest home lines there.
                status.speechModel = false
                status.globeKey = .systemDefault
                status.secureInput = true
                await shot("settings-compact-full", size: NSSize(width: 860, height: 2500))
                status.speechModel = true
                status.globeKey = .doNothing
                status.secureInput = false
                router.section = .home
                controller.current = result(first, delivery: .copied, notes: [InsertResult.copiedFieldChanged.detail ?? ""])
                controller.debugShow(phase: .done(InsertResult.copiedFieldChanged.message), levels: levels)
                await shot("home-compact-copied", size: NSSize(width: 860, height: 580))
                controller.current = records.first
                controller.debugShow(phase: .polishing, levels: levels)
                await shot("home-compact-polishing", size: NSSize(width: 860, height: 580))
                controller.debugShow(phase: .idle, levels: levels)
                status.globeKey = .action(1)
                await shot("home-compact-globe-only", size: NSSize(width: 860, height: 580))
                status.globeKey = .doNothing
            }
            controller.current = records.first
            useFreshStatus()

            if only == nil {
                await snapshotHUD(controller: controller, appearanceName: appearanceName, appearance: appearance, to: dir)
            }
        }
        controller.debugShow(phase: .idle, levels: levels)
        savedSettings.apply(to: settings)
        (router.chartRange, router.chartMetric) = savedChart
        DayNames.pinnedNow = nil
        print("snapshots in \(dir.path)")
    }

    /// 个人词典 with what an edit can become besides a correction, and 我的习惯: a swap made once (待确认 1/2) and
    /// one made twice (改过两次) among the corrections, with the lines 最近的修改 has for them; the habits card
    /// empty, with three habits, with an offer (alone, and after habits), full, and not yet on the Neo; every
    /// row as if pointed at, to show its ×; the narrowest window; and the home page's line after a swap was
    /// remembered. Every word and line is invented. Stores are preview ones: nothing is read or written.
    private static func learningShots(router: Router, controller: DictationController, vocabulary: VocabularyStore,
                                      records: [DictationRecord], light: Bool,
                                      shot: (String, LearningStore, NSSize) async -> Void) async {
        let now = sampleNow
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        func entry(_ code: LearningLog.Code, _ app: String?, minutesAgo: Double, count: Int = 0) -> LearningLog.Entry {
            LearningLog.Entry(at: now.addingTimeInterval(-minutesAgo * 60), app: app, code: code, count: count)
        }
        // Among the sample corrections, one learned because the same swap was made twice.
        var learned = sampleLearned(now: now)
        learned.insert(LearnedCorrection(pair: LearningSamples.learnedSwap, count: 2, firstSeen: ago(0.3), lastSeen: ago(0.3),
                                         source: .otherApp, addedTerm: false, kind: .repeated), at: 0)
        // Made once: one a moment ago (it leads the list), one the day before yesterday (down among the older ones).
        let swaps = [LearningBook.Candidate(pair: LearningSamples.swap, seen: ago(0.002), recordID: nil),
                     LearningBook.Candidate(pair: LearningSamples.earlierSwap, seen: ago(2), recordID: nil)]
        let log = [entry(.candidate, "备忘录", minutesAgo: 3, count: 1), entry(.repeated, "邮件", minutesAgo: 40, count: 1),
                   entry(.formatOnly, "信息", minutesAgo: 95), entry(.removedOnly, "信息", minutesAgo: 180),
                   entry(.learned, nil, minutesAgo: 60 * 26, count: 1)]
        let three = [HabitText.placeholderExample] + HabitText.examples.prefix(2)
        let offer = HabitSuggestion(key: HabitPattern.noFinalStop.key, wording: HabitPattern.noFinalStop.wording(app: "信息"),
                                    count: 3, app: "信息")
        func store(habits: [String], offer: HabitSuggestion? = nil, swaps: [LearningBook.Candidate] = swaps,
                   onHub: LearningStore.HabitsOnHub = .unknown, log entries: [LearningLog.Entry] = log,
                   items: [LearnedCorrection]? = nil, noted: UUID? = nil) -> LearningStore {
            let store = LearningStore(preview: items ?? learned, vocabulary: vocabulary)
            store._debugSet(habits: habits, suggestion: offer, candidates: swaps, onHub: onHub, noted: noted, log: entries)
            return store
        }
        let page = NSSize(width: 1000, height: 1340)
        controller.current = records.first
        router.section = .dictionary
        await shot("dictionary-learning", store(habits: three), page)
        await shot("dictionary-habits-empty", store(habits: []), page)
        await shot("dictionary-habits-offer", store(habits: three, offer: offer), page)
        // The offer before any habit was written, and nothing else learned yet: a new user's page.
        await shot("dictionary-habits-offer-first", store(habits: [], offer: offer, swaps: [], log: [], items: []), page)
        // Twelve habits, the longest a habit may be among them: no field, and the offer cannot be taken.
        let many = three + ["回复尽量短，一两句话说完", "数字用阿拉伯数字", "称呼别人时不加“您好”",
                            "列清单时每条不超过一行", "中文里的引号用直角引号", "不要加表情符号",
                            "提到时间时写清上午还是下午", "英文缩写保持大写",
                            "写给同事的话直接一点，先说结论，再说原因，最后说需要对方做什么，不要客套话，也不要用感叹号和反问句，结尾不加祝好"]
        await shot("dictionary-habits-full", store(habits: many, offer: offer), NSSize(width: 1000, height: 1760))
        // Written here and not on the Neo yet; and a Neo from before habits.
        await shot("dictionary-habits-waiting", store(habits: three, onHub: .waiting), page)
        await shot("dictionary-habits-old-neo", store(habits: three, onHub: .unsupported), page)
        // Every row as if pointed at.
        LearnedRowDebug.hovering = true
        await shot("dictionary-learning-pointer", store(habits: three), page)
        LearnedRowDebug.hovering = false
        if light {
            await shot("dictionary-learning-compact", store(habits: three, offer: offer), NSSize(width: 860, height: 1400))
        }
        // The home page a moment after a word was typed over another there: remembered, with its undo.
        router.section = .home
        if let latest = records.first {
            await shot("home-noted", store(habits: three, noted: latest.id), NSSize(width: 1000, height: 680))
        }
        controller.current = records.first
    }

    /// Invented, neutral dictations for the overview shots: no names, no places, nothing anyone said.
    static func overviewRecords(now: Date = Date()) -> [DictationRecord] {
        func r(_ minutesAgo: Double, _ text: String, _ app: String, _ secs: Double, mode: DictationMode = .natural) -> DictationRecord {
            DictationRecord(date: now.addingTimeInterval(-minutesAgo * 60), duration: secs, raw: text,
                            polished: mode.polishes ? text : nil, finalText: text, appName: app, mode: mode,
                            model: mode.polishes ? "gpt-6.1-sol" : nil, polishSeconds: mode.polishes ? 1.8 : nil,
                            note: nil, delivery: .pasted)
        }
        return [
            r(3, "周五下午三点开项目周会，请大家提前把这周的进度更新到共享文档里。", "备忘录", 9.8),
            r(26, "帮我检查一下这个函数。\n\n要求：\n1. 先找出列表为空时为什么会出错。\n2. 修好之后补上测试。", "终端", 12.6, mode: .structured),
            r(64, "晚上七点在公园门口见，记得带上羽毛球拍和水。", "信息", 6.1),
            r(150, "The quarterly report is ready for review. Please send your comments by Thursday.", "邮件", 7.4),
            r(60 * 22, "明天上午先把预算表核对一遍，下午再和供应商确认交货时间。", "备忘录", 8.9),
            r(60 * 27, "这张图的配色太重了换成浅一点的灰色标题再大一号", "信息", 7.2, mode: .raw),
            r(60 * 49, "提醒我周三之前把报销单交上去。", "提醒事项", 3.8),
        ]
    }

    /// Some eight months of invented daily numbers ending today: weekdays busier than weekends, days off, a
    /// week away, lighter use at the start. Today is a fixed, busy day.
    static func overviewStats(today: UsageDate) -> UsageStats {
        var random = SeededGenerator(seed: 2_026_1010)
        var days: [UsageDate: UsageDay] = [:]
        for back in 1..<236 {
            let date = today.adding(days: -back)
            let weekend = date.weekday == 1 || date.weekday == 7
            let dayOff = Double.random(in: 0..<1, using: &random) < (weekend ? 0.45 : 0.1)
            let lively = Double.random(in: 0.35...1.9, using: &random)
            let length = Int.random(in: 38...74, using: &random)
            let pace = Double.random(in: 3.2...4.1, using: &random)
            if dayOff || (61...67).contains(back) { continue }
            let count = max(1, Int(((weekend ? 4 : 11) * (back > 150 ? 0.5 : 1) * lively).rounded()))
            days[date] = UsageDay(count: count, characters: count * length, seconds: Double(count * length) / pace)
        }
        days[today] = UsageDay(count: 12, characters: 1_284, seconds: 372)
        return UsageStats(days: days, backfilled: true)
    }

    /// The account the pages are drawn with: a made-up login kept in a temporary folder, so no shot shows the
    /// real account or depends on this Mac (never used: a render asks for no credential).
    private static func snapshotAccount() -> ChatGPTAccount {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neoless-snapshot-login")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DataFileStore(directory: dir)
        _ = store.write(ChatGPTTokens(idToken: "", accessToken: "", refreshToken: "", accountID: "snapshot", lastRefresh: Date()),
                        to: ChatGPTAccount.fileName)
        return ChatGPTAccount(store: store, openURL: { _ in })
    }

    /// 今日概览 on its own data, each in light and dark: a new user, the second day, the morning before the
    /// day's first dictation, and a busy few months at the sizes the window is used at (1180 × 839 as it opens
    /// on a 13-inch display with the Dock hidden, the whole page in view; 1180 × 870 as it opens on a larger
    /// one; 1180 × 690, short, where the page scrolls to the last card; taller and larger ones; 1000 × 680,
    /// which is the narrow arrangement; the smallest, 860 × 580), the chart's other views, a dictation
    /// under way and just done, a fix just learned and an app that cannot be learned from, history switched
    /// off (with the latest result, with older ones still listed, and with nothing to show) and history
    /// emptied, a bar, a day and a row under the pointer, and the sidebar with another page chosen. Every
    /// number and sentence is invented, and the day is a fixed one (the stores are given it, and the rows
    /// tell their times from it), so a render does not change with the hour it was made at.
    private static func overviewShots(router: Router, controller: DictationController, settings: AppSettings,
                                      learning: LearningStore, levels: [Float],
                                      shot: (String, HistoryStore, UsageStore, NSSize) async -> Void) async {
        let now = sampleNow
        let today = UsageDate(now, timeZone: .current)
        let opens = NSSize(width: 1180, height: 839), whole = NSSize(width: 1180, height: 870)
        let wide = NSSize(width: 1000, height: 680), smallest = NSSize(width: 860, height: 580)
        let records = overviewRecords(now: now)
        router.section = .home
        controller.debugShow(phase: .idle, levels: levels)

        // A new user: everything allowed, nothing said yet.
        controller.current = nil
        let nothing = UsageStore(preview: UsageStats(backfilled: true), today: today)
        let noHistory = HistoryStore(preview: [])
        await shot("overview-empty", noHistory, nothing, opens)
        await shot("overview-empty-whole", noHistory, nothing, whole)
        await shot("overview-empty-smallest", noHistory, nothing, NSSize(width: 860, height: 1180))

        // The second day: five dictations so far.
        let firstDays = Array(records.prefix(3)) + [records[4], records[5]]
        var little = UsageStats(backfilled: true)
        for record in firstDays { little.add(record, timeZone: .current) }
        let secondDay = UsageStore(preview: little, today: today)
        controller.current = firstDays.first
        await shot("overview-second-day", HistoryStore(preview: firstDays), secondDay, opens)
        await shot("overview-second-day-whole", HistoryStore(preview: firstDays), secondDay, whole)

        // Months in: a busy day in a busy month.
        let busy = UsageStore(preview: overviewStats(today: today), today: today)
        let history = HistoryStore(preview: records)
        controller.current = records.first
        await shot("overview-busy", history, busy, opens)
        await shot("overview-busy-whole", history, busy, whole)
        // A short window (the Dock showing on a small display): every card keeps its room, the page scrolls.
        await shot("overview-busy-short", history, busy, NSSize(width: 1180, height: 690))
        // Height to spare goes to the chart row; a larger display gets wider cards up to the page's width.
        await shot("overview-busy-tall", history, busy, NSSize(width: 1180, height: 1000))
        await shot("overview-busy-large", history, busy, NSSize(width: 1440, height: 900))
        await shot("overview-busy-wide", history, busy, wide)
        await shot("overview-busy-smallest", history, busy, smallest)
        await shot("overview-busy-smallest-whole", history, busy, NSSize(width: 860, height: 1330))
        // A week that starts on Monday (the system setting decides).
        await shot("overview-busy-monday", history, UsageStore(preview: busy.stats, today: today, firstWeekday: 2), whole)
        // The sidebar with another page chosen.
        router.section = .history
        await shot("overview-sidebar-history", history, busy, opens)
        router.section = .home
        // The chart's other views.
        router.chartRange = .month
        await shot("overview-busy-30-days", history, busy, opens)
        router.chartMetric = .characters
        await shot("overview-busy-30-days-characters", history, busy, opens)
        router.chartRange = .week
        await shot("overview-busy-characters", history, busy, opens)
        router.chartMetric = .seconds
        await shot("overview-busy-seconds", history, busy, opens)
        router.chartMetric = .count
        // A bar, a day and a row under the pointer.
        Dash._debugHoveredBar = 3
        Dash._debugHoveredDay = today.adding(days: -9)
        Dash._debugHoveredRow = records[2].id
        await shot("overview-busy-pointer", history, busy, whole)
        Dash._debugHoveredRow = nil
        // A month: a day without dictation under the pointer, then the busiest day. Both at the size the
        // window opens at: at 1000 wide the page is in its narrow arrangement and the chart is under the fold.
        router.chartRange = .month
        Dash._debugHoveredBar = 12
        await shot("overview-busy-pointer-30-days", history, busy, opens)
        Dash._debugHoveredBar = 24
        await shot("overview-busy-pointer-30-days-bar", history, busy, opens)
        router.chartRange = .week
        Dash._debugHoveredBar = nil
        Dash._debugHoveredDay = nil
        // The morning: months of use, nothing said yet today. The two 今日 tiles say what yesterday came to.
        let morning = UsageStore(preview: UsageStats(days: busy.stats.days.filter { $0.key != today }, backfilled: true), today: today)
        let before = Array(records.dropFirst(4))
        controller.current = before.first
        await shot("overview-morning", HistoryStore(preview: before), morning, opens)
        controller.current = records.first
        // A dictation under way (what is being said takes the top of 最近听写), then done.
        controller.debugShow(phase: .recording, levels: levels, liveText: "下周一上午十点去取打印好的材料，顺路把")
        await shot("overview-recording", history, busy, opens)
        controller.debugShow(phase: .polishing, levels: levels, liveText: "下周一上午十点去取打印好的材料，顺路把钥匙还回去")
        await shot("overview-polishing", history, busy, opens)
        controller.debugShow(phase: .done(InsertResult.pasted.message), levels: levels)
        await shot("overview-done", history, busy, opens)
        controller.debugShow(phase: .done(InsertResult.copiedAppChanged.message), levels: levels)
        if var copied = records.first {
            copied.delivery = .copied
            copied.note = InsertResult.copiedAppChanged.detail
            controller.current = copied
        }
        await shot("overview-done-copied", history, busy, opens)
        controller.debugShow(phase: .idle, levels: levels)
        controller.current = records.first
        // A word fixed where the text landed was just learned (with its undo); then a result typed into an
        // app whose text cannot be read, so nothing fixed there is learned.
        learning._debugSet(notice: [CorrectionPair(wrong: "共想", right: "共享")], recordID: records[0].id)
        await shot("overview-learned", history, busy, opens)
        if var typed = records.first {
            typed.appName = "终端"
            controller.current = typed
            learning._debugSet(notice: nil, recordID: nil, unsupported: typed.id)
            await shot("overview-learn-unsupported", history, busy, opens)
            // The same, a moment after a word fixed in an earlier result was learned: the line is still
            // about this result (看不到), not the news from the other one.
            learning._debugSet(notice: [CorrectionPair(wrong: "共想", right: "共享")], recordID: records[2].id, unsupported: typed.id)
            await shot("overview-learn-unsupported-after-learned", history, busy, opens)
        }
        controller.current = records.first
        learning._debugSet(notice: nil, recordID: nil)
        // A long result: folded to its first lines, and the card still ends with the chart.
        if var long = records.first {
            long.finalText = [long.finalText + "会后把结论整理成三条，发到群里，有问题的地方单独标出来。",
                              "下周的安排也一起定下来：周一先过一遍需求，周三看第一版，周五之前把修改意见收齐。",
                              "还有一件事，会议室换到了三楼靠窗的那一间，投影已经试过，可以直接用。"].joined(separator: "\n")
            long.polished = long.finalText
            controller.current = long
            await shot("overview-long-result", history, busy, opens)
        }
        // The 结构化 result on top (its lines run together in a row, apart in the editor): the two newest
        // trade places, times and all, so the list still runs from the newest down.
        var structured = records[1], earlier = records[0]
        (structured.date, earlier.date) = (records[0].date, records[1].date)
        controller.current = structured
        await shot("overview-structured-result", HistoryStore(preview: [structured, earlier] + records.dropFirst(2)), busy, opens)
        // 保存历史 off: the numbers go on, the list keeps only the result in memory.
        controller.current = records.first
        settings.keepHistory = false
        await shot("overview-history-off", noHistory, busy, opens)
        // Switched off with results still in history: they stay listed, and the line under them is about
        // new dictations.
        await shot("overview-history-off-rows", history, busy, opens)
        // Off, and nothing said since neoless started: the card says why it is empty, beside figures
        // that go on counting.
        controller.current = nil
        await shot("overview-history-off-empty", noHistory, busy, opens)
        await shot("overview-history-off-empty-smallest", noHistory, busy, NSSize(width: 860, height: 1180))
        settings.keepHistory = true
        // History on and empty (cleared, or the last dictation is over 30 days old), months of figures.
        await shot("overview-history-cleared", noHistory, busy, opens)
        controller.current = records.first
    }

    /// Neo 处理中心: the settings section in each state (paired and working, with and without 双重锁, the Neo's
    /// ChatGPT or recognition down, out of reach, refused, stopped by Cloudflare Access, a link waiting for 配对, a
    /// pasted text that is not one, switched off), and the home page and sidebar with the Neo working, out of reach
    /// and stopped by Access. Ends unpaired.
    private static func neoShots(hub: HubConnection, router: Router, controller: DictationController,
                                 records: [DictationRecord], levels: [Float],
                                 shot: (String, HistoryStore?, NSSize) async -> Void) async {
        let pairing = try? HubPairing(server: Hub.exampleServer, token: "snapshot-token-0123456789abcdef", name: "我的 Mac")
        // 双重锁: placeholder credentials, never shown (the row only says whether there are some).
        let locked = try? HubPairing(server: Hub.exampleServer, token: "snapshot-token-0123456789abcdef", name: "我的 Mac",
                                     access: HubAccess(clientID: "snapshot0123456789abcdef.access", clientSecret: "snapshot-secret-value"))
        let large = "Qwen3-ASR-1.7B-4bit", small = "Qwen3-ASR-0.6B-4bit"
        let asr = HubHealth.ASR(ready: true, model: large, largeModel: large, smallModel: small, autoUses: .large)
        // A hub that polishes with the model a device asks for says which ones it has.
        let listed = PolishModel.all.map(\.id)
        let working = HubHealth(version: "1.3.0", asr: asr, chatgpt: .init(ready: true, account: "y***@example.com"),
                                device: "我的 Mac", polishModels: listed)
        // A busy Neo, on its small model for a while.
        let busy = HubHealth(version: "1.3.0", asr: .init(ready: true, model: small, largeModel: large, smallModel: small,
                                                          autoUses: .small),
                             chatgpt: .init(ready: true, account: "y***@example.com"), device: "我的 Mac",
                             polishModels: listed)
        // A Neo whose hub is from before 识别模型 (it names neither model) and 整理模型 (it lists no models), and one
        // that runs a single model.
        let outdated = HubHealth(version: "1.2.0", asr: .init(ready: true, model: large),
                                 chatgpt: .init(ready: true, account: "y***@example.com"), device: "我的 Mac")
        let single = HubHealth(version: "1.3.0", asr: .init(ready: true, model: large, largeModel: large, autoUses: .large),
                               chatgpt: .init(ready: true, account: "y***@example.com"), device: "我的 Mac",
                               polishModels: listed)
        let noChatGPT = HubHealth(version: "1.3.0", asr: asr, chatgpt: .init(ready: false, problem: "Neo 还没登录 ChatGPT"),
                                  device: "我的 Mac", polishModels: listed)
        let size = NSSize(width: 1000, height: 1000)
        let compact = NSSize(width: 860, height: 900)
        controller.current = records.first
        controller.debugShow(phase: .idle, levels: levels)
        router.section = .settings
        hub._debugSet(pairing: pairing, status: .connected(working))
        await shot("settings-neo-connected", nil, size)
        await shot("settings-neo-connected-compact", nil, compact)
        // 识别模型: 自动 above (and in every other shot); the two fixed choices, whose lines name the model (in one
        // piece at the narrowest window too); 本机识别, whose long title widens the pop-up; then 自动 on a busy Neo, on
        // its small model for now.
        hub.settings.asrModel = .large
        await shot("settings-neo-model-large", nil, size)
        await shot("settings-neo-model-large-compact", nil, compact)
        hub.settings.asrModel = .small
        await shot("settings-neo-model-small", nil, size)
        await shot("settings-neo-model-small-compact", nil, compact)
        hub.settings.asrModel = .local
        await shot("settings-neo-model-local", nil, size)
        await shot("settings-neo-model-local-compact", nil, compact)
        hub.settings.asrModel = .auto
        hub._debugSet(pairing: pairing, status: .connected(busy))
        await shot("settings-neo-model-auto-busy", nil, size)
        // A Neo that would not act on a model choice: the pop-up offers 自动 and 本机识别 only, and the line says why.
        // (The Neo out of reach since the app started is "settings-neo-unreachable" below.)
        hub._debugSet(pairing: pairing, status: .connected(outdated))
        await shot("settings-neo-model-outdated", nil, size)
        // 整理模型 and 快速模式 (高级 open, the whole page): on a Neo that follows them, then on one whose hub is from
        // before them, where both lines say it uses its own until it is updated.
        let page = NSSize(width: 1000, height: 2300)
        SettingsView.advancedOpen = true
        await shot("settings-neo-polish-outdated", nil, page)
        await shot("settings-neo-polish-outdated-compact", nil, NSSize(width: 860, height: 2500))
        hub._debugSet(pairing: pairing, status: .connected(working))
        await shot("settings-neo-polish-follows", nil, page)
        SettingsView.advancedOpen = false
        hub._debugSet(pairing: pairing, status: .connected(single))
        await shot("settings-neo-model-single", nil, size)
        hub._debugSet(pairing: pairing, status: .connected(noChatGPT))
        await shot("settings-neo-no-chatgpt", nil, size)
        hub._debugSet(pairing: pairing, status: .unreachable("Neo 没有响应，可能在睡眠或断网"))
        await shot("settings-neo-unreachable", nil, size)
        hub._debugSet(pairing: pairing, status: .revoked)
        await shot("settings-neo-revoked", nil, size)
        hub._debugSet(pairing: locked, status: .connected(working))
        await shot("settings-neo-access-on", nil, size)
        // The README's picture of Settings (screenshots/settings-model.png, 1400 px wide): the same page in a window
        // that ends under the 快捷键 section, so the next section's header does not stand alone at the bottom.
        await shot("settings-neo-access-on-readme", nil, NSSize(width: 1000, height: 960))
        await shot("settings-neo-access-on-compact", nil, compact)
        hub._debugSet(pairing: locked, status: .accessDenied)
        await shot("settings-neo-access-denied", nil, size)
        await shot("settings-neo-access-denied-compact", nil, compact)
        hub._debugSet(pairing: locked, status: .accessDenied,
                      message: HubConnection.Message(text: HubConnection.accessRefused(pairing!), isError: true))
        await shot("settings-neo-access-refused-link", nil, size)
        hub._debugSet(pairing: nil, status: .unpaired, pending: pairing)
        await shot("settings-neo-pending", nil, size)
        await shot("settings-neo-pending-compact", nil, compact)
        hub._debugSet(pairing: nil, status: .unpaired,
                      message: HubConnection.Message(text: HubProtocolError.notPairingText.errorDescription ?? "", isError: true))
        await shot("settings-neo-bad-paste", nil, size)
        hub._debugSet(pairing: nil, status: .unpaired)
        await shot("settings-neo-unpaired", nil, size)
        hub._debugSet(pairing: pairing, status: .off)
        await shot("settings-neo-off", nil, size)
        router.section = .home
        hub._debugSet(pairing: pairing, status: .connected(working))
        if var fromNeo = records.first {
            fromNeo.hubID = UUID()
            fromNeo.recognizer = "qwen3-asr"
            controller.current = fromNeo
        }
        await shot("home-neo-connected", nil, NSSize(width: 1000, height: 680))
        hub._debugSet(pairing: pairing, status: .unreachable("连不上 Neo"))
        controller.current = records.first.map { record in
            var record = record
            record.note = HubDictation.fallbackNote(HubError.unreachable)
            return record
        }
        await shot("home-neo-unreachable", nil, NSSize(width: 1000, height: 680))
        hub._debugSet(pairing: locked, status: .accessDenied)
        controller.current = records.first.map { record in
            var record = record
            record.note = HubDictation.fallbackNote(HubError.accessDenied)
            return record
        }
        await shot("home-neo-access-denied", nil, NSSize(width: 1000, height: 680))
        // History: the Neo's dictation says so (Neo 识别, Neo 处理), with where the wait went under it; then one
        // that 本机识别 sent as text (made-up timings). The Neo is working again, so the sidebar says what the
        // entry does (用 Neo 处理), not the refusal of the shot before.
        hub._debugSet(pairing: locked, status: .connected(working))
        var fromNeo = records[0]
        fromNeo.hubID = UUID()
        fromNeo.recognizer = "qwen3-asr"
        fromNeo.polishSeconds = 2.4
        fromNeo.timings = DictationTimings(waitMs: 6_000, requestMs: 5_520, decodeMs: 20, asrMs: 3_100, polishMs: 2_400,
                                           totalMs: 5_240)
        router.section = .history
        await shot("history-neo", HistoryStore(preview: [fromNeo] + records.dropFirst()), NSSize(width: 1000, height: 680))
        fromNeo.recognizer = "local"
        fromNeo.timings = DictationTimings(waitMs: 3_000, requestMs: 2_650, decodeMs: 0, asrMs: 0, polishMs: 2_400, totalMs: 2_410)
        await shot("history-neo-local", HistoryStore(preview: [fromNeo] + records.dropFirst()), NSSize(width: 1000, height: 680))
        controller.current = records.first
        hub._debugSet(pairing: nil, status: .unpaired)
        router.section = .home
    }

    /// Every capsule state at the real panel size and 2x, over desktops the capsule must read on:
    /// the light call renders a light, a mid-grey and a busy wallpaper backdrop, the dark call a dark
    /// one. Each state is one PNG per backdrop (`<backdrop>-hud-<state>.png`), and each backdrop gets
    /// a contact sheet of all of them (`sheet-<backdrop>.png`). The meter is held on a steady voice
    /// (or silence), so a shot never catches the wave still rising from zero; the clocks (processing
    /// fill and glint, the starting glint, the countdown) are held at fixed points. A shot placed
    /// against the screen's edge marks that edge with a thin red line.
    private static func snapshotHUD(controller: DictationController, appearanceName: String,
                                    appearance: NSAppearance.Name, to dir: URL) async {
        let backdrops: [HUDBackdrop] = appearanceName == "dark" ? [.dark] : [.light, .grey, .wallpaper]
        let voice: [Float] = [0.82, 0.9, 0.74, 0.86, 0.66, 0.78, 0.7, 0.6]
        // Long enough to overflow the rail, cut mid-character at its left end.
        let speech = "我明天下午四点跟 Martin 开个会，讨论一下 OpenAI 的订阅费用，然后再把上个月的报销单也整理一下"
        let edge = HUDPlacement(anchorX: PillPlacement.margin + CapsuleMetrics.handsFreeWidth / 2,
                                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875), hangsBelow: false)
        let below = HUDPlacement(anchorX: 0, visibleFrame: .null, hangsBelow: true)
        let typed = { (error: Error) in FailureText.typedRaw(reason: PolishFailure.short(error)) }
        let speechError = { (domain: String, code: Int) in
            "识别出错：" + (SpeechErrorText.message(domain: domain, code: code, description: "") ?? "")
        }
        var shots: [HUDShot] = [
            HUDShot("1-starting", .starting, glint: 0.2),
            HUDShot("2-hold", .recording, hold: true, trail: voice),
            HUDShot("2-hold-quiet", .recording, hold: true),
            HUDShot("2-handsfree", .recording, trail: voice),
            HUDShot("2-handsfree-quiet", .recording),
            HUDShot("2-handsfree-tooltip", .recording, trail: voice, tip: .cancel),
            HUDShot("2-handsfree-tooltip-finish", .recording, trail: voice, tip: .confirm),
            // The rail (实时字幕) steps aside while a tooltip shows where it is.
            HUDShot("2-handsfree-tooltip-rail", .recording, trail: voice, live: "我明天下午四点跟 Martin 开个会", tip: .cancel),
            HUDShot("2-handsfree-tooltip-below", .recording, trail: voice, live: "我明天下午四点跟 Martin 开个会",
                    placement: below, tip: .cancel),
            HUDShot("2-handsfree-tooltip-edge", .recording, trail: voice, placement: edge, tip: .cancel),
            HUDShot("3-rail-short", .recording, trail: voice, live: "我明天下午四点"),
            HUDShot("3-rail-long", .recording, trail: voice, live: speech),
            HUDShot("3-rail-hold", .recording, hold: true, trail: voice, live: "我明天下午四点跟 Martin 开个会"),
            HUDShot("3-rail-below-caret", .recording, trail: voice, live: "我明天下午四点跟 Martin 开个会", placement: below),
            HUDShot("3-rail-edge", .recording, trail: voice, live: speech, placement: edge),
            HUDShot("3-countdown-notice", .recording, trail: voice, notice: CaptureText.nearCap, countdown: 59),
            HUDShot("3-countdown-hold", .recording, hold: true, trail: voice, countdown: 42),
            HUDShot("3-countdown-handsfree", .recording, trail: voice, countdown: 8),
            HUDShot("4-transcribing", .transcribing, fill: CapsuleProgress.fraction(elapsed: 0.6), shimmer: 0.3),
            HUDShot("4-polishing", .polishing, fill: CapsuleProgress.fraction(elapsed: 1.8), shimmer: 0.55),
            HUDShot("4-polishing-late", .polishing, fill: CapsuleProgress.fraction(elapsed: 4.5), shimmer: 0.9),
            HUDShot("4-polishing-reduce-motion", .polishing, fill: CapsuleProgress.fraction(elapsed: 1.8), shimmer: 0.55,
                    reduceMotion: true),
            // The result is ready: the fill completes, then fades. A plain paste collapses from
            // there; any other result shows its line on black.
            HUDShot("4-polishing-done", .polishing, fill: 1, shimmer: 1.4),
            HUDShot("4-polishing-done-faded", .polishing, fill: 1, fillOpacity: 0, shimmer: 1.4),
            HUDShot("5-done-clipboard-kept", .done(InsertResult.pastedKeptOnClipboard.message)),
            HUDShot("5-done-copied", .done(InsertResult.copiedNoField.message)),
            HUDShot("5-done-copied-secure-input", .done(InsertResult.copiedSecureInput.message)),
            HUDShot("5-done-copied-app-changed", .done(InsertResult.copiedAppChanged.message)),
            HUDShot("5-done-copied-field-changed", .done(InsertResult.copiedFieldChanged.message)),
            HUDShot("5-done-home", .done(InsertResult.ownApp.message)),
            HUDShot("5-done-secure", .done(InsertResult.notInserted.message)),
            HUDShot("5-paste-cancelled", .done(DoneText.pasteCancelled(keepHistory: true))),
            HUDShot("5-paste-cancelled-no-history", .done(DoneText.pasteCancelled(keepHistory: false))),
            HUDShot("6-fallback", .done(typed(PolishError.http(401, "")))),
            HUDShot("6-fallback-network", .done(typed(URLError(.networkConnectionLost)))),
            HUDShot("6-fallback-quota", .done(FailureText.typedRaw(reason: "ChatGPT 额度暂时用完"))),
            // The Neo typed the original: its own login, not this Mac's.
            HUDShot("6-fallback-neo", .done(FailureText.typedRaw(reason: HubDictation.reason(
                HubFallback(title: "已输入原文", reason: PolishError.http(401, "").short))))),
            HUDShot("6-fallback-copied", .done("\(InsertResult.copiedNoField.message) · 整理超时")),
            HUDShot("6-fallback-copied-app-changed", .done("\(InsertResult.copiedAppChanged.message) · 网络中断")),
            HUDShot("7-failed", .failed("没有识别出文字，请再说一次")),
            HUDShot("7-failed-silent", .failed("没有听到声音，请检查麦克风")),
            HUDShot("7-failed-nobody-spoke", .failed(CaptureText.nobodySpoke)),
            HUDShot("7-failed-no-audio", .failed(AudioRecorder.Failure.noAudio.errorDescription ?? "")),
            HUDShot("7-failed-dictation-off", .failed(speechError("kLSRErrorDomain", 201))),
            HUDShot("7-failed-not-ready", .failed(speechError("kAFAssistantErrorDomain", 1700))),
            HUDShot("7-failed-path", .failed("需要麦克风权限：系统设置 › 隐私与安全性 › 麦克风")),
            HUDShot("7-failed-edge", .failed("需要下载识别语言：系统设置 › 键盘 › 听写 › 语言"), placement: edge),
        ]
        shots += learningLines.map { HUDShot("8-\($0.name)", .done($0.text)) }
        let panel = HUDController.panelSize
        var sheets: [HUDBackdrop: [(String, CGImage)]] = [:]
        for shot in shots {
            controller._debugSet(phase: shot.phase, levels: Array(repeating: 0.6, count: 24), liveText: shot.live,
                                 holdToTalk: shot.hold)
            let feeds = HUDFeeds(controller: controller, railAlwaysOn: true)
            feeds._debugHold(trail: shot.trail)
            if let notice = shot.notice { feeds._debugRail(notice, notice: true) }
            if shot.countdown != nil { feeds._debugCountdown() }
            HUDText._debugCountdown = shot.countdown
            HUDText._debugProcessing = (fill: shot.fill, opacity: shot.fillOpacity, shimmer: shot.shimmer)
            HUDText._debugGlintTime = shot.glint
            HUDText._debugTip = shot.tip
            // The real panel, once per backdrop: anything outside it is clipped as it would be on screen.
            let stack = VStack(spacing: 0) {
                ForEach(backdrops, id: \.self) { backdrop in
                    HUDView(controller: controller, feeds: feeds, placement: shot.placement)
                        .padding(HUDView.shadowInsets)
                        .frame(width: panel.width, height: panel.height)
                        .background(backdrop.view)
                        .overlay(alignment: .topLeading) { screenEdge(shot.placement, height: panel.height) }
                        .clipped()
                        .environment(\.colorScheme, backdrop == .dark ? .dark : .light)
                        .environment(\._accessibilityReduceMotion, shot.reduceMotion)
                }
            }
            guard let image = renderImage(stack, size: NSSize(width: panel.width, height: panel.height * CGFloat(backdrops.count)))
            else { continue }
            let scale = CGFloat(image.width) / panel.width
            for (i, backdrop) in backdrops.enumerated() {
                let rect = CGRect(x: 0, y: CGFloat(i) * panel.height * scale, width: panel.width * scale, height: panel.height * scale)
                guard let crop = image.cropping(to: rect.integral) else { continue }
                writePNG(crop, to: dir.appendingPathComponent("\(backdrop.rawValue)-hud-\(shot.name).png"))
                sheets[backdrop, default: []].append((shot.name, crop))
            }
        }
        HUDText._debugProcessing = nil
        HUDText._debugGlintTime = nil
        HUDText._debugCountdown = nil
        HUDText._debugTip = nil
        controller.debugShow(phase: .idle, levels: Array(repeating: 0, count: 24))
        // One contact sheet per backdrop, three panels to a row, for reviewing every state at once.
        for backdrop in backdrops {
            guard let cells = sheets[backdrop], let first = cells.first?.1 else { continue }
            let scale = CGFloat(first.width) / panel.width
            let columns = 3, rows = (cells.count + columns - 1) / columns
            let label: CGFloat = 22
            let sheet = VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<columns, id: \.self) { column in
                            let index = row * columns + column
                            VStack(alignment: .leading, spacing: 0) {
                                Text(index < cells.count ? cells[index].0 : "")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color(white: 0.35))
                                    .padding(.leading, 8)
                                    .frame(height: label, alignment: .leading)
                                if index < cells.count {
                                    Image(decorative: cells[index].1, scale: scale)
                                } else {
                                    Color.clear.frame(width: panel.width, height: panel.height)
                                }
                            }
                            .frame(width: panel.width, alignment: .leading)
                        }
                    }
                }
            }
            .background(Color.white)
            let size = NSSize(width: panel.width * CGFloat(columns), height: (panel.height + label) * CGFloat(rows))
            if let image = renderImage(sheet, size: size) {
                writePNG(image, to: dir.appendingPathComponent("sheet-\(backdrop.rawValue).png"))
            }
        }
    }

    /// The capsule's lines about learning, as it says them (`HUDController.lines`): a word remembered, a swap
    /// remembered for its second time (said in two parts, since the capsule is narrow) and learned at that
    /// second time, with short words, long ones and two swaps at once; a fix that could not be learned, and
    /// an app whose edits cannot be seen. Invented words.
    private static var learningLines: [(name: String, text: String)] {
        func pair(_ wrong: String, _ right: String) -> CorrectionPair { CorrectionPair(wrong: wrong, right: right) }
        func lines(_ name: String, _ announcement: LearningStore.Announcement) -> [(name: String, text: String)] {
            let said = HUDController.lines(for: announcement)
            return said.enumerated().map { i, text in (said.count > 1 ? "\(name)-\(i + 1)" : name, text) }
        }
        // What is shown as remembered is what the rules do remember (`LearningSamples`, checked by a test).
        return lines("learned", .learned(pairs: [pair("共想", "共享")], terms: []))
            + lines("noted", .noted(pairs: [LearningSamples.swap]))
            + lines("noted-long", .noted(pairs: [LearningSamples.longSwap]))
            + lines("noted-two", .noted(pairs: [LearningSamples.swap, LearningSamples.earlierSwap]))
            + lines("learned-again", .learned(pairs: [LearningSamples.swap], terms: []))
            + lines("missed", .missed(.unlikeName))
            + lines("unwatched", .unwatched(app: "终端"))
    }

    /// For a shot placed against the screen: a thin red line on the visible frame's left edge, so a
    /// capsule clamped to the margin reads as placed, not misaligned. Nothing for a centred shot.
    @ViewBuilder private static func screenEdge(_ placement: HUDPlacement, height: CGFloat) -> some View {
        if !placement.visibleFrame.isNull {
            // The panel is centred on the anchor: the frame's left edge, in panel points.
            let x = CapsuleMetrics.shadowSide + CapsuleMetrics.panelHalfWidth - (placement.anchorX - placement.visibleFrame.minX)
            Rectangle()
                .fill(Color.red.opacity(0.7))
                .frame(width: 1, height: height)
                .offset(x: x - 0.5)
        }
    }

    /// Renders `view` at 2x with SwiftUI's own renderer. (An off-screen window's `cacheDisplay`
    /// draws SwiftUI shadows with their offset flipped, so the capsule's long shadow would point up.)
    private static func renderImage<V: View>(_ view: V, size: NSSize) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 2
        return renderer.cgImage
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// `chrome` mirrors the real main window: transparent, full-size-content title bar. The window
    /// draws as the active one (`SnapshotWindow`), so the accent shows where it does on screen.
    static func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name = .aqua, chrome: Bool = false, to url: URL) async {
        let window = SnapshotWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
                                    styleMask: chrome ? [.titled, .fullSizeContentView] : [.titled], backing: .buffered, defer: false)
        if chrome {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        }
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 500_000_000)
        // As the app does on opening its window: nothing starts focused (no caret in the result).
        window.makeFirstResponder(nil)
        // A second display pass lets AppKit-backed controls (pop-up buttons) draw their titles.
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try? await Task.sleep(nanoseconds: 250_000_000)
        host.layoutSubtreeIfNeeded()
        // cacheDisplay draws every view's own drawing and skips the layer state that keeps an idle
        // caret invisible on screen, so an unfocused text view's (zero-size) insertion indicator would
        // come out as a stray accent dot. Nothing is focused here: hide them all.
        func hideCarets(_ view: NSView) {
            if view is NSTextInsertionIndicator { view.isHidden = true }
            view.subviews.forEach(hideCarets)
        }
        hideCarets(host)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        // Written as sRGB, so pixel values read straight from the PNG are the sRGB colours
        // (the display profile would otherwise shift them, e.g. #007AFF reading as #3478F6).
        let out = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
        try? out.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}

extension DictationController {
    func debugShow(phase: Phase, levels: [Float], liveText: String = "") {
        self._debugSet(phase: phase, levels: levels, liveText: liveText)
    }
}

/// An off-screen window that draws as the key, main window. Never key for real (snapshots run with
/// the app inactive), it would otherwise draw every page as an inactive window: grey sidebar icons
/// and selection, grey switches, a grey 复制 button.
private final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    // AppKit controls ask these (private, debug renders only) rather than isKeyWindow, and they also
    // check that the app is active, which a snapshot run never is.
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasActiveControls() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }

    /// The sidebar tints its icons with the accent only while the app is active, which a snapshot run
    /// (activation policy .prohibited) never is. This process only renders, so it may say it is.
    static func drawAsActiveApp() {
        let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
        for name in ["isActive", "_isActiveApp"] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(NSApplication.self, selector) else { continue }
            method_setImplementation(method, imp_implementationWithBlock(yes))
        }
    }
}

/// The settings the page snapshots depend on: set to the defaults for the renders, then put back
/// (the debug build keeps its own defaults, apart from the installed app's).
@MainActor
private struct SnapshotSettings {
    var mode = DictationMode.natural
    var trigger = HotkeyTrigger.fn
    var hotkeyEnabled = true
    var hotkeyStyle = HotkeyStyle.auto
    var microphoneUID = AppSettings.microphoneAuto
    var model = PolishModel.recommended
    var fastTier = true
    var polishTimeout = 10.0
    var restoreClipboard = true
    var keepHistory = true
    var hudFollowsCaret = false
    var liveTranscript = true
    var autoStructuredForAI = true
    var silenceAutoStop = true
    var globeHintDismissed: Int?
    var hubEnabled = true
    var hubAddress = ""
    var asrModel = NeoModelChoice.auto

    static let defaults = SnapshotSettings()

    private init() {}

    init(_ s: AppSettings) {
        mode = s.mode; trigger = s.trigger; hotkeyEnabled = s.hotkeyEnabled; hotkeyStyle = s.hotkeyStyle
        microphoneUID = s.microphoneUID; model = s.model; fastTier = s.fastTier; polishTimeout = s.polishTimeout
        restoreClipboard = s.restoreClipboard; keepHistory = s.keepHistory
        hudFollowsCaret = s.hudFollowsCaret; liveTranscript = s.liveTranscript
        autoStructuredForAI = s.autoStructuredForAI; silenceAutoStop = s.silenceAutoStop
        globeHintDismissed = s.globeHintDismissed
        hubEnabled = s.hubEnabled; hubAddress = s.hubAddress; asrModel = s.asrModel
    }

    func apply(to s: AppSettings) {
        s.mode = mode; s.trigger = trigger; s.hotkeyEnabled = hotkeyEnabled; s.hotkeyStyle = hotkeyStyle
        s.microphoneUID = microphoneUID; s.model = model; s.fastTier = fastTier; s.polishTimeout = polishTimeout
        s.restoreClipboard = restoreClipboard; s.keepHistory = keepHistory
        s.hudFollowsCaret = hudFollowsCaret; s.liveTranscript = liveTranscript
        s.autoStructuredForAI = autoStructuredForAI; s.silenceAutoStop = silenceAutoStop
        s.globeHintDismissed = globeHintDismissed
        s.hubEnabled = hubEnabled; s.hubAddress = hubAddress; s.asrModel = asrModel
    }
}

extension DebugCommands {
    /// `--polish-eval`: every `PolishEval` case through the real `Polisher`, one after another, with this
    /// Mac's vocabulary and learned corrections, exactly as a dictation sends them, plus the learned terms
    /// and pairs a case adds of its own. Prints each transcript and result, a prompt example's expected
    /// text when the result differs, and any failed check.
    /// `--mode structured` uses the 结构化 instructions (default: 自然整理) and skips what only 自然整理 asks
    /// for: the expected text and the numbering and paragraph checks (`PolishEval.Check.naturalOnly`).
    /// `--dry-run` prints what would be sent instead and touches no login.
    static func polishEval(_ args: [String]) async {
        var mode = DictationMode.natural
        if let i = args.firstIndex(of: "--mode") {
            guard i + 1 < args.count, let chosen = DictationMode(rawValue: args[i + 1]), chosen.polishes else {
                print("--mode 只能是 natural 或 structured")
                return
            }
            mode = chosen
        }
        let dryRun = args.contains("--dry-run")
        let settings = AppSettings.shared
        let vocabulary = VocabularyStore()
        let learning = LearningStore(vocabulary: vocabulary)
        let words = vocabulary.promptWords
        let cases = PolishEval.all
        print("整理测试：\(mode.title)，\(cases.count) 条，提示词 \(PolishPrompt.version)，模型 \(settings.model)，"
              + "快速模式\(settings.fastTier ? "开" : "关")，词表 \(words.own.count) 个词，自动学到的词 \(words.learned.count) 个")
        if mode == .structured {
            print("结构化有自己的分段和编号方式，这里不检查分段和编号")
        }
        if dryRun {
            print("\n── 指令（每条的纠正另列）──")
            print(PolishPrompt.instructions(for: mode, vocabulary: words.own, learned: words.learned))
        }
        let account: ChatGPTAccount? = dryRun ? nil : ChatGPTAccount()
        var passed = 0, failedChecks = 0
        var seconds: [TimeInterval] = []
        for (n, item) in cases.enumerated() {
            let corrections = item.corrections(adding: LearningPrompt.pairs(for: item.transcript, from: learning.book))
            let itemWords = item.words(adding: words)
            print("\n── \(n + 1)/\(cases.count) \(item.title)（\(item.appName ?? "未知应用")）")
            print("原：\(item.transcript)")
            if !item.learned.isEmpty {
                print("本条另加的自动学到的词：" + item.learned.joined(separator: "、"))
            }
            if !corrections.isEmpty {
                print("纠正：" + corrections.map { "\($0.wrong)→\($0.right)" }.joined(separator: "；"))
            }
            guard let account else {
                print("── 用户消息 ──")
                print(PolishPrompt.userMessage(transcript: item.transcript, appName: item.appName))
                continue
            }
            let started = Date()
            do {
                let out = try await Polisher.polish(transcript: item.transcript, vocabulary: itemWords, appName: item.appName,
                                                    account: account, corrections: corrections, mode: mode)
                let took = Date().timeIntervalSince(started)
                seconds.append(took)
                print(String(format: "出（%.2f 秒）：", took))
                print(out)
                if mode == .natural, let expected = item.expected {
                    print(PolishEval.matchesExpected(out, expected) ? "与示例一致" : "示例：\n\(expected)")
                }
                let problems = item.problems(in: out, mode: mode)
                if problems.isEmpty { passed += 1 } else { failedChecks += 1 }
                print(problems.isEmpty ? "检查：通过" : "检查：" + problems.joined(separator: "；"))
            } catch {
                print("错误：" + PolishFailure.detail(error))
                // Without a working login every other case would fail the same way.
                if let e = error as? PolishError {
                    switch e {
                    case .notSignedIn, .http(401, _), .http(403, _), .http(429, _):
                        print("停止：先在设置里登录 ChatGPT（或等额度恢复）再试")
                        await account.waitForRefresh()
                        return
                    default: break
                    }
                }
            }
            fflush(stdout)
        }
        if let account {
            let average = seconds.isEmpty ? 0 : seconds.reduce(0, +) / Double(seconds.count)
            print(String(format: "\n完成 %d/%d 条，检查全部通过 %d 条，有问题 %d 条，平均 %.2f 秒",
                         seconds.count, cases.count, passed, failedChecks, average))
            // A polish timeout stops waiting for a token refresh but not the refresh: let it save before exit(0).
            await account.waitForRefresh()
        }
    }
}

/// One capsule state for `--snapshot-hud`.
private struct HUDShot {
    let name: String
    let phase: Phase
    var hold = false
    /// Meter amplitudes, newest first; empty is silence.
    var trail: [Float] = []
    var live = ""
    /// A notice in the rail instead of the transcript.
    var notice: String?
    /// Seconds left in the last minute's countdown.
    var countdown: TimeInterval?
    var placement = HUDPlacement.centred
    /// The processing fill (0...1), its opacity, and the shimmer's clock, in seconds.
    var fill = 0.0
    var fillOpacity = 1.0
    var shimmer = 0.3
    /// Rendered with Reduce Motion on.
    var reduceMotion = false
    /// The starting pill's glint clock, in seconds.
    var glint = 0.2
    /// A button's tooltip showing.
    var tip: HUDButton?

    init(_ name: String, _ phase: Phase, hold: Bool = false, trail: [Float] = [], live: String = "",
         notice: String? = nil, countdown: TimeInterval? = nil, placement: HUDPlacement = .centred,
         fill: Double = 0, fillOpacity: Double = 1, shimmer: Double = 0.3, reduceMotion: Bool = false,
         glint: Double = 0.2, tip: HUDButton? = nil) {
        self.name = name; self.phase = phase; self.hold = hold; self.trail = trail; self.live = live
        self.notice = notice; self.countdown = countdown; self.placement = placement
        self.fill = fill; self.fillOpacity = fillOpacity; self.shimmer = shimmer; self.reduceMotion = reduceMotion
        self.glint = glint; self.tip = tip
    }
}

/// Desktops behind the capsule in snapshots.
private enum HUDBackdrop: String, Hashable {
    case light, dark, grey, wallpaper

    @ViewBuilder var view: some View {
        switch self {
        case .light: Color(white: 0.95)
        case .dark: Color(white: 0.11)
        case .grey: Color(white: 0.5)
        case .wallpaper: BusyWallpaper()
        }
    }
}

/// A loud, wallpaper-like backdrop: a saturated gradient, soft blobs and light and dark stripes, so
/// the rim and the shadow are checked against both.
private struct BusyWallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.30, blue: 0.72), Color(red: 0.52, green: 0.30, blue: 0.70),
                                    Color(red: 0.98, green: 0.56, blue: 0.32)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 1.0, green: 0.86, blue: 0.45)).frame(width: 180).blur(radius: 24).offset(x: 150, y: -10)
            Circle().fill(Color(red: 0.12, green: 0.12, blue: 0.30)).frame(width: 200).blur(radius: 26).offset(x: -170, y: 40)
            HStack(spacing: 26) {
                ForEach(0..<16, id: \.self) { i in
                    Rectangle()
                        .fill(i.isMultiple(of: 2) ? Color.white.opacity(0.45) : Color.black.opacity(0.35))
                        .frame(width: 10)
                }
            }
            .rotationEffect(.degrees(24))
            .frame(width: 900, height: 600)
        }
        .clipped()
    }
}

extension DebugCommands {
    /// `--check-keys`: the page keys against the real 显示 menu and the real pages, in a window off screen (the app
    /// itself is not started, nothing is stored or sent). ⌘1 … ⌘4 through the menu, with the check mark following;
    /// a digit on its own while nothing is typed into; and, page by page with clicks as the window gets them,
    /// that a click beside the fields leaves the digits to the pages, a click into a text field or an editor
    /// gives them to it, and a click beside the editor gives them back. One line per check; false when any
    /// failed. What it cannot show: a key or a click on real hardware reaching the menu and the watchers, which
    /// is AppKit's part.
    static func checkKeys() async -> Bool {
        SnapshotWindow.drawAsActiveApp()
        // The fixed sample login and stores of the page shots: nothing of this Mac's is read.
        let settings = AppSettings.shared
        let records = sampleRecords()
        let history = HistoryStore(preview: records)
        let vocabulary = VocabularyStore(preview: sampleWords)
        let account = snapshotAccount()
        let learning = LearningStore(preview: sampleLearned(), vocabulary: vocabulary)
        let hub = HubConnection(preview: nil, settings: settings)
        let controller = DictationController(settings: settings, history: history, vocabulary: vocabulary,
                                             account: account, learning: learning, hub: hub)
        var stats = UsageStats()
        stats.backfill(from: records, timeZone: .current)
        let usage = UsageStore(preview: stats, today: UsageDate(Date(), timeZone: .current))
        let router = Router()
        let status = SystemStatus()
        status.hub = hub
        status.microphone = true; status.speech = true; status.accessibility = true; status.hotkeyRunning = true
        status.frozen = true
        controller.current = records.first

        let size = NSSize(width: 1000, height: 2300)
        let window = SnapshotWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
                                    styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        let root = MainView()
            .environmentObject(controller).environmentObject(settings).environmentObject(history)
            .environmentObject(vocabulary).environmentObject(learning).environmentObject(account)
            .environmentObject(router).environmentObject(status).environmentObject(hub).environmentObject(usage)
            .environment(\.controlActiveState, .key)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        /// Lets the page that was just chosen be laid out.
        func settle() async {
            try? await Task.sleep(nanoseconds: 400_000_000)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        await settle()
        window.makeFirstResponder(nil)

        let pages = PageMenu(router: router, window: { window }) { router.section = $0 }
        let main = NSMenu()
        let item = pages.makeItem()
        main.addItem(item)
        NSApp.mainMenu = main
        defer { NSApp.mainMenu = nil }
        let entries = item.submenu?.items ?? []

        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print((ok ? "通过  " : "没过  ") + what)
        }
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags = [], repeated: Bool = false) -> NSEvent? {
            let codes: [String: Int] = ["1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5,
                                        "a": kVK_ANSI_A]
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: repeated, keyCode: UInt16(codes[characters] ?? kVK_ANSI_A))
        }

        // The menu as people see it.
        let shown = entries.map { "\($0.title) \($0.keyEquivalentModifierMask == .command ? "⌘" : "?")\($0.keyEquivalent)" }
        check(item.submenu?.title == "显示" && shown == ["听写 ⌘1", "历史记录 ⌘2", "个人词典 ⌘3", "设置 ⌘4"],
              "显示菜单：" + shown.joined(separator: "、"))

        // ⌘1 … ⌘4 through the menu, last to first so each press changes the page; the check mark follows.
        for (index, page) in Page.allCases.enumerated().reversed() {
            guard let event = key(String(index + 1), .command) else { check(false, "造不出 ⌘\(index + 1)"); continue }
            let handled = main.performKeyEquivalent(with: event)
            item.submenu?.update()
            let marks = entries.map { $0.state == .on }
            check(handled && router.section == page && marks == Page.allCases.map { $0 == page },
                  "⌘\(index + 1) → \(page.title)，菜单里打勾的是 " + entries.filter { $0.state == .on }.map(\.title).joined(separator: "、"))
        }
        // A key the menu has no page for is not taken.
        if let event = key("5", .command) { check(!main.performKeyEquivalent(with: event), "⌘5 没有页面，菜单不收") }

        // A digit on its own, nothing typed into: the same pages.
        for (index, page) in Page.allCases.enumerated().reversed() {
            guard let event = key(String(index + 1)) else { continue }
            let handled = pages.handlePlainKey(event)
            check(handled && router.section == page, "直接按 \(index + 1) → \(page.title)")
        }
        // Not ours: another digit, a letter, the digit with ⌃ or ⌥, a key from another window.
        router.section = .home
        for (name, event) in [("5", key("5")), ("a", key("a")), ("⌃2", key("2", .control)), ("⌥2", key("2", .option))] {
            guard let event else { continue }
            check(!pages.handlePlainKey(event) && router.section == .home, "\(name) 不换页")
        }
        // A digit still held down: the key is used up (nothing else gets it, so the Mac does not beep) and no
        // page opens again.
        if let held = key("2", repeated: true) {
            check(pages.handlePlainKey(held) && router.section == .home, "按住不放的 2：按键收下，不再换页")
        }
        if let elsewhere = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                            context: nil, characters: "2", charactersIgnoringModifiers: "2",
                                            isARepeat: false, keyCode: UInt16(kVK_ANSI_2)) {
            check(!pages.handlePlainKey(elsewhere) && router.section == .home, "别的窗口里的 2 不换页")
        }

        // Page by page, with clicks as the window gets them. After a click on the page's margin or on its content
        // the digits still open pages; after a click into a text field or an editor they are text. A text field
        // keeps the keyboard when the next click lands beside it, so they stay text; the editor (the latest result
        // on 听写) gives it up, and they open pages again.
        func click(_ point: NSPoint) async {
            func mouse(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            guard let down = mouse(.leftMouseDown), let up = mouse(.leftMouseUp) else { return }
            // A text field follows the mouse until it comes up: the release waits in the queue before the press goes in.
            // The page keys' own watcher sees both, as in the app (`AppDelegate.pageClicks`).
            NSApp.postEvent(up, atStart: false)
            pages.noteMouse(down)
            window.sendEvent(down)
            pages.noteMouse(up)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        func inputs(_ view: NSView) -> [NSView] {
            var found: [NSView] = []
            if let field = view as? NSTextField, field.isEditable, !field.isHiddenOrHasHiddenAncestor { found.append(field) }
            if let text = view as? NSTextView, text.isEditable, !text.isFieldEditor, !text.isHiddenOrHasHiddenAncestor { found.append(text) }
            return view.subviews.reduce(found) { $0 + inputs($1) }
        }
        func sidebarWidth(_ view: NSView) -> CGFloat? {
            if let split = view as? NSSplitView, let first = split.arrangedSubviews.first { return first.frame.width }
            return view.subviews.lazy.compactMap(sidebarWidth).first
        }
        // Window coordinates count from the bottom. The margin point is inside the page's own margin, left of
        // anything on it; the content point is wherever the page has something 200pt in.
        let side = sidebarWidth(host) ?? 248
        let margin = NSPoint(x: side + 16, y: host.bounds.height - 300)
        let content = NSPoint(x: side + 200, y: host.bounds.height - 230)
        for page in Page.allCases {
            router.section = page
            await settle()
            window.makeFirstResponder(nil)
            check(!PageMenu.isTyping(in: window), "\(page.title)页：没点进输入框时，数字键用来换页")
            await click(margin)
            check(!PageMenu.isTyping(in: window), "\(page.title)页：点一下页面空白处，数字键照常换页")
            await click(content)
            // Wherever that landed: only an editor of text may keep the digits.
            check(!PageMenu.isTyping(in: window) || window.firstResponder is NSText, "\(page.title)页：点一下页面里的内容，数字键没被别的东西收走")
            // The click may have opened another page (a row of 最近听写 does).
            router.section = page
            await settle()
            let found = inputs(host)
            let editors = found.filter { $0 is NSTextView }.count
            let fields = found.count - editors
            var kept = 0, left = 0
            for index in found.indices {
                // The page as it is laid out now (an editor's turn ends on another page and comes back).
                let now = inputs(host)
                guard now.indices.contains(index) else { continue }
                let input = now[index]
                let inside = input.convert(NSPoint(x: input.bounds.midX, y: input.bounds.midY), to: nil)
                window.makeFirstResponder(nil)
                await click(inside)
                let typing = PageMenu.isTyping(in: window)
                let taken = key("2").map(pages.handlePlainKey) ?? true
                guard typing, !taken, router.section == page else { continue }
                if input is NSTextView {
                    // Another click into the text changes nothing; one beside it ends the typing, and 2 is 历史记录 again.
                    await click(inside)
                    let still = PageMenu.isTyping(in: window)
                    await click(margin)
                    let ended = !PageMenu.isTyping(in: window)
                    let opened = key("2").map(pages.handlePlainKey) ?? false
                    if still && ended && opened && router.section == .history { left += 1 }
                    router.section = page
                    await settle()
                } else {
                    await click(margin)
                    if router.section == page && PageMenu.isTyping(in: window) { kept += 1 }
                }
            }
            window.makeFirstResponder(nil)
            // 听写 has its latest result, an editor; the others each have a field (搜索, 添加词语, 服务器地址 and 配对).
            if page == .home {
                check(editors == 1 && left == editors && fields == 0,
                      "\(page.title)页：结果点进去后数字照常输入，再点一下旁边就不再输入，数字键又换页（\(left)/\(editors)）")
            } else {
                check(kept == fields && fields > 0 && left == editors,
                      "\(page.title)页：\(fields) 个输入框，点进去后数字照常输入，再点旁边也一样（\(kept)/\(fields)）")
            }
        }
        router.section = .home
        print(failures == 0 ? "页面快捷键检查全部通过" : "页面快捷键检查有 \(failures) 项没过")
        return failures == 0
    }
}
