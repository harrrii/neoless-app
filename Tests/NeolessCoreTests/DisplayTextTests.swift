import AppKit
import Testing
@testable import NeolessCore

@Suite struct DisplayTextTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func clockIsZeroPadded24Hour() {
        #expect(TimeText.clock(date(2026, 10, 6, 0, 53), calendar: calendar) == "00:53")
        #expect(TimeText.clock(date(2026, 10, 6, 0, 0), calendar: calendar) == "00:00")
        #expect(TimeText.clock(date(2026, 10, 6, 23, 5), calendar: calendar) == "23:05")
    }

    @Test func shortUsesClockTodayThenYesterdayThenDate() {
        let now = date(2026, 10, 6, 1, 10)
        #expect(TimeText.short(date(2026, 10, 6, 0, 37), now: now, calendar: calendar) == "00:37")
        #expect(TimeText.short(date(2026, 10, 5, 23, 0), now: now, calendar: calendar) == "昨天")
        #expect(TimeText.short(date(2026, 10, 4, 9, 0), now: now, calendar: calendar) == "10月4日")
    }

    @Test func networkErrorsBecomeShortChinese() {
        let lost = URLError(.networkConnectionLost)
        #expect(FailureText.short(lost) == "网络中断")
        // History says it plainly too: no NSURLErrorDomain and no code.
        #expect(FailureText.detail(lost) == "网络中断")
        #expect(FailureText.detail(NSError(domain: "other", code: 1)) == nil)
        #expect(FailureText.short(URLError(.notConnectedToInternet)) == "没有网络")
        #expect(FailureText.short(URLError(.timedOut)) == "网络超时")
        #expect(FailureText.short(URLError(.cannotFindHost)) == "连不上服务器")
        #expect(FailureText.short(URLError(.badServerResponse)) == "网络出错")
        #expect(FailureText.short(NSError(domain: "other", code: 1)) == nil)
    }

    @Test func hudLineSaysWhatWasTyped() {
        #expect(FailureText.typedRaw(reason: "网络中断") == "网络中断，已输入原文")
        // The capsule's own line for every reason: CapsuleTextTests.fallbackKeepsItsReasonInTheSmallCapsule.
    }

    @Test func fallbackResultsSplitIntoWhatHappenedAndWhy() {
        let typed = FailureText.fallback(FailureText.typedRaw(reason: "ChatGPT 登录已过期"))
        #expect(typed?.title == "已输入原文")
        #expect(typed?.reason == "ChatGPT 登录已过期")
        let copied = FailureText.fallback("已复制，按 ⌘V 粘贴 · 整理超时")
        #expect(copied?.title == "已复制，按 ⌘V 粘贴")
        #expect(copied?.reason == "整理超时")
        // Plain successes and other notes are not fallbacks.
        #expect(FailureText.fallback("已输入") == nil)
        #expect(FailureText.fallback(InsertResult.notInserted.message) == nil)
        #expect(FailureText.fallback(InsertResult.ownApp.message) == nil)
        #expect(FailureText.fallback("，已输入原文") == nil)
    }

    @Test func doneHeadlineNeverClaimsTypedTextThatWasNot() {
        // Esc or × while processing: nothing was typed.
        for keep in [true, false] {
            let message = DoneText.pasteCancelled(keepHistory: keep)
            #expect(DoneText.headline(message) == "已取消输入")
            #expect(!DoneText.subtitle(message).isEmpty)
        }
        #expect(DoneText.subtitle(DoneText.pasteCancelled(keepHistory: true)).contains("历史记录"))
        #expect(DoneText.subtitle(DoneText.pasteCancelled(keepHistory: false)).contains("不会保存"))
        // Copies and the password field are not typing either.
        #expect(DoneText.headline(InsertResult.copiedNoField.message) == "已复制")
        #expect(DoneText.headline(InsertResult.copiedSecureInput.message) == "已复制")
        #expect(DoneText.headline(InsertResult.copiedAppChanged.message) == "已复制")
        #expect(DoneText.headline(InsertResult.copiedFieldChanged.message) == "已复制")
        #expect(DoneText.headline(InsertResult.notInserted.message) == "密码框里不输入")
        #expect(DoneText.headline(InsertResult.ownApp.message) == "没有输入")
        // The window is not called 主页 anywhere: the sidebar names the page 听写.
        for result in [InsertResult.ownApp, .notInserted] {
            #expect(!result.message.contains("主页"))
            #expect(!DoneText.headline(result.message).contains("主页"))
            #expect(!DoneText.subtitle(result.message).contains("主页"))
        }
    }

    @Test func doneSubtitlesAreSentencesThatSayWhatToDo() {
        // Every message the controller can show gets a sentence, never the pill's clipped words.
        let results: [InsertResult] = [.pasted, .ownApp, .copiedAppChanged, .copiedFieldChanged, .copiedNoField,
                                       .copiedSecureInput, .copiedNoAccessibility, .notInserted, .pastedKeptOnClipboard,
                                       .copiedWaiting, .copiedNotTaken]
        let messages = results.map(\.message) + [true, false].map { DoneText.pasteCancelled(keepHistory: $0) }
        for message in messages {
            let line = DoneText.subtitle(message)
            #expect(line.hasSuffix("。"), "\(message) → \(line)")
            #expect(line != message && !message.hasSuffix(line), "\(message) → \(line)")
            // Short enough to sit beside the mode switch on one or two lines.
            #expect(line.count <= 24, "\(message) → \(line)")
            // 粘贴 is only what the user does with ⌘V; what neoless does is 输入.
            #expect(!line.replacingOccurrences(of: "按 ⌘V 粘贴", with: "").contains("粘贴"), "\(message) → \(line)")
        }
        // Copied: how to get it in.
        for result in results where result.isCopied && result != .pastedKeptOnClipboard {
            #expect(DoneText.subtitle(result.message).contains("⌘V"))
        }
        #expect(DoneText.subtitle(InsertResult.copiedAppChanged.message).contains("换了应用"))
        #expect(DoneText.subtitle(InsertResult.copiedFieldChanged.message).contains("换了输入框"))
        // Typed, but the user's old clipboard could not be put back.
        #expect(DoneText.headline(InsertResult.pastedKeptOnClipboard.message) == "已输入")
        #expect(DoneText.subtitle(InsertResult.pastedKeptOnClipboard.message).contains("剪贴板"))
    }

    @Test func doneHeadlineForTypedText() {
        #expect(DoneText.headline("已输入") == "已输入")
        #expect(DoneText.subtitle("已输入").contains("光标处"))
        // Typed without polishing: the fallback title and its reason, as before.
        let raw = FailureText.typedRaw(reason: "网络中断")
        #expect(DoneText.headline(raw) == "已输入原文")
        #expect(DoneText.subtitle(raw) == "网络中断。")
        // Copied without polishing: the headline says it is the original, the line why and what to do.
        let copied = "\(InsertResult.copiedNoField.message) · 整理超时"
        #expect(DoneText.headline(copied) == "已复制原文")
        #expect(DoneText.subtitle(copied) == "整理超时，按 ⌘V 粘贴。")
        #expect(DoneText.headline("\(InsertResult.copiedAppChanged.message) · 整理超时") == "已复制原文")
        let password = "\(InsertResult.notInserted.message) · 网络中断"
        #expect(DoneText.headline(password) == "密码框里不输入")
        #expect(DoneText.subtitle(password) == "网络中断。光标在密码框里，没有输入。")
        let own = "\(InsertResult.ownApp.message) · 整理超时"
        #expect(DoneText.headline(own) == "没有输入")
        #expect(DoneText.subtitle(own) == "整理超时。原文在下面。")
        // An unknown message still splits at its first comma.
        #expect(DoneText.headline("已暂停，稍后再试") == "已暂停")
        #expect(DoneText.subtitle("已暂停，稍后再试") == "稍后再试")
        // A comma at either end is not a split.
        #expect(DoneText.headline("，已取消") == "，已取消")
        #expect(DoneText.subtitle("已取消，") == "已取消，")
    }
}
