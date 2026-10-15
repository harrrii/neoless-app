import Foundation
import Testing
@testable import NeolessCore

@Suite struct ServiceHealthTests {
    private func facts(accessibility: Bool = true, microphone: Bool = true, speech: Bool = true,
                       hotkeyEnabled: Bool = true, hotkeyRunning: Bool = true, speechModel: Bool = true,
                       polishes: Bool = true, chatGPT: ServiceFacts.ChatGPT = .ready,
                       hub: ServiceFacts.Hub = .off) -> ServiceFacts {
        ServiceFacts(accessibility: accessibility, microphone: microphone, speech: speech, hotkeyEnabled: hotkeyEnabled,
                     hotkeyRunning: hotkeyRunning, speechModel: speechModel, polishes: polishes, chatGPT: chatGPT, hub: hub)
    }

    @Test func aNeoOutOfReachIsSoft() {
        #expect(ServiceHealth.evaluate(facts(hub: .unreachable)) == .degraded(.hubUnreachable))
        #expect(ServiceHealth.evaluate(facts(hub: .revoked)) == .degraded(.hubRevoked))
        #expect(!ServiceProblem.hubUnreachable.blocks && !ServiceProblem.hubRevoked.blocks)
        #expect(ServiceProblem.hubUnreachable.message(for: .fn) == "连不上 Neo，用本机处理")
        // Cloudflare Access (双重锁) stopping this Mac on the way: soft too, said as such, not as a Neo out of reach.
        #expect(ServiceHealth.evaluate(facts(hub: .accessDenied)) == .degraded(.hubAccessDenied))
        #expect(!ServiceProblem.hubAccessDenied.blocks)
        #expect(ServiceProblem.hubAccessDenied.message(for: .fn) == "Cloudflare 门禁没放行，用本机处理")
        #expect(ServiceHealth.problems(facts(chatGPT: .signedOut, hub: .accessDenied)) == [.hubAccessDenied, .signedOut])
        // The Neo answered but takes only what came through Access, which is not set up right: not "out of reach".
        #expect(ServiceHealth.evaluate(facts(hub: .accessRequired)) == .degraded(.hubAccessRequired))
        #expect(!ServiceProblem.hubAccessRequired.blocks)
        #expect(ServiceProblem.hubAccessRequired.message(for: .fn) == "Cloudflare 门禁没设好，用本机处理")
        #expect(ServiceHealth.problems(facts(chatGPT: .signedOut, hub: .accessRequired)) == [.hubAccessRequired, .signedOut])
        // Also in 原样转写: the Neo recognises too.
        #expect(ServiceHealth.evaluate(facts(polishes: false, hub: .unreachable)) == .degraded(.hubUnreachable))
        #expect(ServiceHealth.evaluate(facts(hub: .off)) == .ok)
        #expect(ServiceHealth.evaluate(facts(hub: .connected)) == .ok)
    }

    @Test func aWorkingNeoPolishesWithItsOwnLogin() {
        // This Mac's login matters only when it does the work itself.
        #expect(ServiceHealth.evaluate(facts(chatGPT: .signedOut, hub: .connected)) == .ok)
        #expect(ServiceHealth.problems(facts(chatGPT: .signedOut, hub: .unreachable)) == [.hubUnreachable, .signedOut])
        #expect(ServiceHealth.problems(facts(chatGPT: .signedOut, hub: .off)) == [.signedOut])
        // A blocking problem still comes first.
        #expect(ServiceHealth.evaluate(facts(microphone: false, hub: .unreachable)) == .broken(.microphone))
    }

    @Test func aNeoThatCannotRecognizeLeavesTheWorkToThisMac() {
        // Every recording is turned away there, so this Mac polishes them all with its own login.
        #expect(ServiceHealth.evaluate(facts(hub: .cannotRecognize)) == .degraded(.hubCannotRecognize))
        #expect(!ServiceProblem.hubCannotRecognize.blocks)
        #expect(ServiceProblem.hubCannotRecognize.message(for: .fn) == "Neo 的识别暂时不可用，先用本机识别")
        #expect(ServiceHealth.problems(facts(chatGPT: .signedOut, hub: .cannotRecognize)) == [.hubCannotRecognize, .signedOut])
        #expect(ServiceHealth.problems(facts(chatGPT: .signedOut, hub: .revoked)) == [.hubRevoked, .signedOut])
    }

    @Test func aNeoThatCannotPolishLeavesThePolishToThisMacsLogin() {
        // This Mac polishes what the Neo typed as the original: fine with its login, said only without it.
        #expect(ServiceHealth.evaluate(facts(hub: .cannotPolish)) == .ok)
        #expect(ServiceHealth.problems(facts(chatGPT: .signedOut, hub: .cannotPolish)) == [.signedOut])
    }

    @Test func allGoodIsOK() {
        #expect(ServiceHealth.evaluate(facts()) == .ok)
        #expect(ServiceHealth.evaluate(facts()).problem == nil)
    }

    @Test func lostAccessibilityBreaksAndHidesTheTapLine() {
        let f = facts(accessibility: false, hotkeyRunning: false)
        #expect(ServiceHealth.evaluate(f) == .broken(.accessibility))
        #expect(ServiceHealth.problems(f) == [.accessibility])
    }

    @Test func tapThatDidNotStartBreaks() {
        #expect(ServiceHealth.evaluate(facts(hotkeyRunning: false)) == .broken(.hotkey))
    }

    @Test func switchedOffHotkeyIsNotAProblem() {
        #expect(ServiceHealth.evaluate(facts(hotkeyEnabled: false, hotkeyRunning: false)) == .ok)
    }

    @Test func deniedMicOrSpeechBreaks() {
        #expect(ServiceHealth.evaluate(facts(microphone: false)) == .broken(.microphone))
        #expect(ServiceHealth.evaluate(facts(speech: false)) == .broken(.speech))
    }

    @Test func missingModelBreaksOnlyWithSpeechPermission() {
        #expect(ServiceHealth.evaluate(facts(speechModel: false)) == .broken(.speechModel))
        #expect(ServiceHealth.problems(facts(speech: false, speechModel: false)) == [.speech])
    }

    @Test func loginIsSoftAndOnlyWhenPolishing() {
        #expect(ServiceHealth.evaluate(facts(chatGPT: .signedOut)) == .degraded(.signedOut))
        #expect(ServiceHealth.evaluate(facts(polishes: false, chatGPT: .signedOut)) == .ok)
        #expect(!ServiceProblem.signedOut.blocks)
    }

    @Test func blockingProblemOutranksLogin() {
        let f = facts(microphone: false, chatGPT: .signedOut)
        #expect(ServiceHealth.evaluate(f) == .broken(.microphone))
        #expect(ServiceHealth.problems(f) == [.microphone, .signedOut])
    }

    @Test func messagesAreShortSentences() {
        for p in ServiceProblem.allCases {
            for trigger in HotkeyTrigger.allCases {
                let m = p.message(for: trigger)
                #expect(!m.isEmpty)
                #expect(m.count <= 24)
                #expect(!m.hasSuffix("。"))
            }
        }
    }

    @Test func hotkeyMessagesNameTheChosenKey() {
        #expect(ServiceProblem.accessibility.message(for: .fn) == "没有辅助功能权限，fn 用不了")
        #expect(ServiceProblem.accessibility.message(for: .rightOption) == "没有辅助功能权限，右侧 Option 用不了")
        #expect(ServiceProblem.hotkey.message(for: .rightCommand) == "快捷键没连上，右侧 Command 暂时用不了")
        #expect(!ServiceProblem.accessibility.message(for: .rightCommand).contains("fn"))
        #expect(ServiceProblem.microphone.message(for: .fn) == ServiceProblem.microphone.message(for: .rightOption))
    }
}

@Suite struct AccessibilityAskTests {
    @Test func promptFirstThenSettings() {
        var ask = AccessibilityAsk()
        #expect(ask.click(trusted: false) == .systemPrompt)
        #expect(ask.click(trusted: false) == .openSettings)
        #expect(ask.click(trusted: false) == .openSettings)
    }

    @Test func eachLaunchPromptsAgain() {
        // Nothing is stored: a new launch (a rebuilt app, a reset entry) starts with the alert,
        // which is what lists neoless in System Settings again.
        var first = AccessibilityAsk()
        _ = first.click(trusted: false)
        var next = AccessibilityAsk()
        #expect(next.click(trusted: false) == .systemPrompt)
    }

    @Test func losingAccessAfterGrantPromptsAgain() {
        var ask = AccessibilityAsk()
        #expect(ask.click(trusted: false) == .systemPrompt)
        ask.granted()
        // Removed with − in System Settings, or `tccutil reset`, while running.
        #expect(ask.click(trusted: false) == .systemPrompt)
        #expect(ask.click(trusted: false) == .openSettings)
    }

    @Test func trustedClickDoesNothingAndResets() {
        var ask = AccessibilityAsk()
        _ = ask.click(trusted: false)
        #expect(ask.click(trusted: true) == nil)
        #expect(ask.click(trusted: false) == .systemPrompt)
    }
}

@Suite struct FocusHandBackTests {
    private let me: Int32 = 50
    private let wechat = FocusHandBack.App(pid: 10, isRegular: true)
    private let chrome = FocusHandBack.App(pid: 11, isRegular: true)
    private let alertHelper = FocusHandBack.App(pid: 20, isRegular: false)

    @Test func remembersOnlyOtherNormalApps() {
        #expect(FocusHandBack.remembers(wechat, selfPID: me))
        #expect(!FocusHandBack.remembers(alertHelper, selfPID: me))
        #expect(!FocusHandBack.remembers(FocusHandBack.App(pid: me, isRegular: true), selfPID: me))
        #expect(!FocusHandBack.remembers(FocusHandBack.App(pid: 12, isRegular: true, isTerminated: true), selfPID: me))
    }

    @Test func previousAppWins() {
        #expect(FocusHandBack.choose(previous: wechat, windowOwners: [chrome], selfPID: me) == .activate(10))
    }

    @Test func quitPreviousFallsBackToTheTopWindow() {
        // System Settings was quit after granting access; WeChat's window is right behind.
        let settings = FocusHandBack.App(pid: 30, isRegular: true, isTerminated: true)
        let owners = [FocusHandBack.App(pid: me, isRegular: true), alertHelper, wechat, chrome]
        #expect(FocusHandBack.choose(previous: settings, windowOwners: owners, selfPID: me) == .activate(10))
    }

    @Test func agentPreviousIsSkipped() {
        #expect(FocusHandBack.choose(previous: alertHelper, windowOwners: [chrome], selfPID: me) == .activate(11))
    }

    @Test func nothingLeftDeactivatesInsteadOfHiding() {
        #expect(FocusHandBack.choose(previous: nil, windowOwners: [], selfPID: me) == .deactivate)
        #expect(FocusHandBack.choose(previous: nil, windowOwners: [alertHelper], selfPID: me) == .deactivate)
    }
}

@Suite struct SingleInstanceTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func noPeersKeepsRunning() {
        #expect(SingleInstance.yield(to: [], selfPID: 50, selfLaunched: t0) == nil)
    }

    @Test func olderAppWins() {
        let old = SingleInstance.Peer(pid: 90, launched: t0, isDebug: false)
        #expect(SingleInstance.yield(to: [old], selfPID: 50, selfLaunched: t0.addingTimeInterval(5)) == old)
    }

    @Test func newerPeerDoesNotMakeUsQuit() {
        let newer = SingleInstance.Peer(pid: 30, launched: t0.addingTimeInterval(5), isDebug: false)
        #expect(SingleInstance.yield(to: [newer], selfPID: 50, selfLaunched: t0) == nil)
    }

    @Test func debugRunsAreIgnored() {
        let snapshot = SingleInstance.Peer(pid: 10, launched: t0.addingTimeInterval(-60), isDebug: true)
        #expect(SingleInstance.yield(to: [snapshot], selfPID: 50, selfLaunched: t0) == nil)
    }

    @Test func sameLaunchTimeFallsBackToPID() {
        let a = SingleInstance.Peer(pid: 40, launched: t0, isDebug: false)
        #expect(SingleInstance.yield(to: [a], selfPID: 50, selfLaunched: t0) == a)
        let b = SingleInstance.Peer(pid: 60, launched: nil, isDebug: false)
        #expect(SingleInstance.yield(to: [b], selfPID: 50, selfLaunched: t0) == nil)
    }

    @Test func picksTheOldestOfSeveral() {
        let a = SingleInstance.Peer(pid: 70, launched: t0.addingTimeInterval(1), isDebug: false)
        let b = SingleInstance.Peer(pid: 80, launched: t0, isDebug: false)
        #expect(SingleInstance.yield(to: [a, b], selfPID: 50, selfLaunched: t0.addingTimeInterval(9)) == b)
    }

    @Test func debugFlags() {
        #expect(SingleInstance.isDebugRun(["neoless", "--snapshot", "/tmp/x"]))
        #expect(SingleInstance.isDebugRun(["neoless", "--snapshot-hud", "/tmp/x"]))
        #expect(SingleInstance.isDebugRun(["neoless", "--polish-eval"]))
        #expect(SingleInstance.isDebugRun(["neoless", "--check-keys"]))
        #expect(!SingleInstance.isDebugRun(["neoless", "--show"]))
    }
}

@Suite struct GlobeKeyTests {
    @Test func missingKeyMeansTheSystemDefaultWhichConflicts() {
        #expect(GlobeKeyUsage(storedValue: nil) == .systemDefault)
        #expect(GlobeKeyUsage(storedValue: nil).conflicts)
    }

    @Test func zeroIsFree() {
        #expect(GlobeKeyUsage(storedValue: 0) == .doNothing)
        #expect(!GlobeKeyUsage(storedValue: 0).conflicts)
    }

    @Test func anyOtherValueConflicts() {
        for v in 1...3 { #expect(GlobeKeyUsage(storedValue: v) == .action(v)) }
        #expect(GlobeKeyUsage(storedValue: 2).conflicts)
    }
}

@Suite struct RecoveredFilesTests {
    @Test func originalName() {
        #expect(RecoveredFiles.original(of: "history.json.corrupt-20261007-204500") == "history.json")
        #expect(RecoveredFiles.original(of: "history.json.corrupt-20261007-204500-2") == "history.json")
        #expect(RecoveredFiles.original(of: "history.json") == nil)
        #expect(RecoveredFiles.original(of: ".corrupt-1") == nil)
    }

    @Test func noticeNamesEachFileOnce() {
        let title: (String) -> String = { $0 == "history.json" ? "历史记录" : "个人词典" }
        #expect(RecoveredFiles.notice([], title: title) == nil)
        let line = RecoveredFiles.notice(["history.json.corrupt-1", "history.json.corrupt-2", "vocabulary.json.corrupt-3"],
                                         title: title)
        #expect(line == "历史记录、个人词典读不出来，已备份原文件")
    }
}
