import Foundation

/// Times as the window shows them: a zero-padded 24-hour clock ("00:53"), so a time never
/// reads like a recording length ("0:53").
public enum TimeText {
    public static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "00:53" today, "昨天", else "10月4日".
    public static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return clock(date, calendar: calendar) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天"
        }
        let c = calendar.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)月\(c.day ?? 0)日"
    }

    /// The day and the time, for a list that spans days: "00:53" on `today`, "昨天 00:53" the day before,
    /// else "10月4日 00:53". The day it is now is the caller's to give (`UsageStore.today`), never read from
    /// the clock here: a row that holds the day is drawn again when the day changes, so a time from before
    /// midnight does not go on reading as today's.
    public static func stamp(_ date: Date, today: UsageDate, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let time = clock(date, calendar: calendar)
        let day = UsageDate(date, timeZone: timeZone)
        switch day.days(until: today) {
        case 0: return time
        case 1: return "昨天 " + time
        default: return "\(day.month)月\(day.day)日 " + time
        }
    }
}

/// Plain Chinese for failures that would otherwise surface as English system text.
public enum FailureText {
    /// A short reason for an NSURLErrorDomain code ("网络中断"); nil for codes that are not failures.
    public static func network(code: Int) -> String? {
        switch code {
        case -999: return nil                                   // cancelled
        case -1009, -1018, -1020: return "没有网络"              // offline, roaming off, data not allowed
        case -1005: return "网络中断"                            // connection lost
        case -1001: return "网络超时"
        case -1003, -1004, -1006: return "连不上服务器"           // host not found, cannot connect, DNS
        case -1206 ... -1200: return "安全连接失败"            // TLS
        default: return "网络出错"
        }
    }

    /// The short reason for any error from the polish request, or nil to fall back to its own text.
    public static func short(_ error: Error) -> String? {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return network(code: ns.code) }
        return nil
    }

    /// History detail for a network error: the plain reason ("网络中断"). The domain and code are for
    /// the log, not for people.
    public static func detail(_ error: Error) -> String? {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return nil }
        return network(code: ns.code)
    }

    /// HUD line when the polish failed but the original text was still typed: "网络中断，已输入原文".
    public static func typedRaw(reason: String) -> String {
        "\(reason)，已输入原文"
    }

    /// A result that was typed but not polished ("网络中断，已输入原文", "已复制，按 ⌘V 粘贴 · 整理超时"),
    /// split into what happened and why, so the HUD can show it as a fallback rather than a success.
    public static func fallback(_ message: String) -> (title: String, reason: String)? {
        let typed = "，已输入原文"
        if message.hasSuffix(typed), message.count > typed.count {
            return ("已输入原文", String(message.dropLast(typed.count)))
        }
        if let dot = message.range(of: " · ") {
            let head = String(message[..<dot.lowerBound]), tail = String(message[dot.upperBound...])
            if !head.isEmpty, !tail.isEmpty { return (head, tail) }
        }
        return nil
    }
}

/// The main window's words for a finished dictation, from the controller's `.done` message, so the
/// headline never says 已输入 for text that was copied, kept or not pasted, and the line under it says
/// in a plain sentence what happened and what to do (the pill's short words are for the capsule).
public enum DoneText {
    /// Pill and window message after Esc or × stopped a dictation still processing from being typed.
    /// With history off a newer dictation may take the home page first, so it promises no place then.
    public static func pasteCancelled(keepHistory: Bool) -> String {
        keepHistory ? "已取消输入，结果在历史记录" : "已取消输入，历史记录已关闭"
    }

    /// What happened, for the headline: "已输入", "已输入原文", "已复制原文", "已取消输入"…
    public static func headline(_ message: String) -> String {
        if let fallback = FailureText.fallback(message) {
            guard let known = explained(fallback.title) else { return fallback.title }
            // Not polished and copied: what is on the clipboard is the original.
            return known.copied ? "已复制原文" : known.head
        }
        return explained(message)?.head ?? parts(message).head
    }

    /// The line under the headline: one or two short sentences, at most about 24 characters each, so
    /// the line fits beside the mode switch. The headline already says 原文, so a fallback names only
    /// the reason ("整理超时。").
    public static func subtitle(_ message: String) -> String {
        if let fallback = FailureText.fallback(message) {
            let why = "\(fallback.reason)。"
            // Not typed: the original is on the clipboard (or, in a password field, nowhere).
            switch fallback.title {
            case InsertResult.notInserted.message: return why + "光标在密码框里，没有输入。"
            case InsertResult.ownApp.message: return why + "原文在下面。"
            default: return explained(fallback.title)?.copied == true ? "\(fallback.reason)，按 ⌘V 粘贴。" : why
            }
        }
        return explained(message)?.line ?? parts(message).rest ?? message
    }

    /// The controller's known messages (`InsertResult.message`, `pasteCancelled`), told plainly. What
    /// neoless does is 输入; 粘贴 is only the user's own ⌘V.
    static func explained(_ message: String) -> (head: String, line: String, copied: Bool)? {
        switch message {
        case InsertResult.pasted.message:
            return ("已输入", "文字已经出现在光标处，可以在下面修改或复制。", false)
        case InsertResult.pastedKeptOnClipboard.message:
            return ("已输入", "原来的剪贴板没法完整放回，现在里面是这次的文字。", false)
        case InsertResult.ownApp.message:
            return ("没有输入", "neoless 窗口在最前面，结果在下面。", false)
        case InsertResult.copiedAppChanged.message:
            return ("已复制", "你换了应用，这次没有自动输入。按 ⌘V 粘贴。", true)
        case InsertResult.copiedFieldChanged.message:
            return ("已复制", "你换了输入框，这次没有自动输入。按 ⌘V 粘贴。", true)
        case InsertResult.copiedNoField.message:
            // Also secure input and no Accessibility: the record's note below says which.
            return ("已复制", "这次没法自动输入，按 ⌘V 粘贴。", true)
        case InsertResult.copiedWaiting.message:
            // Until the box takes it (`PasteRetry`), or the user does something first.
            return ("已复制", "当时不能输入，会自动再试，或按 ⌘V 粘贴。", true)
        case InsertResult.copiedNotTaken.message:
            return ("已复制", "输入框当时不让输入，按 ⌘V 粘贴。", true)
        case InsertResult.notInserted.message:
            return ("密码框里不输入", "光标在密码框里，没有输入也没有复制。", false)
        // True before the result arrives and after: it lands below (unless a newer dictation got
        // there first, which replaces this line too) and, with 保存历史 on, in History.
        case pasteCancelled(keepHistory: true):
            return ("已取消输入", "这次不输入，结果会留在这里和历史记录里。", false)
        case pasteCancelled(keepHistory: false):
            return ("已取消输入", "这次不输入。历史记录已关闭，结果不会保存。", false)
        default:
            return nil
        }
    }

    /// "已复制，按 ⌘V 粘贴" → ("已复制", "按 ⌘V 粘贴"): what happened, then the rest.
    static func parts(_ message: String) -> (head: String, rest: String?) {
        guard let comma = message.range(of: "，") else { return (message, nil) }
        let head = String(message[..<comma.lowerBound]), rest = String(message[comma.upperBound...])
        return head.isEmpty || rest.isEmpty ? (message, nil) : (head, rest)
    }
}
