import Foundation

// 今日概览: how much neoless was used, as numbers per day. Nothing here holds a word of what was said: a
// day is three numbers (dictations, 字数, seconds of speech). The stats count on their own, so they keep
// growing when history is trimmed to 30 days, cleared, or switched off.

// MARK: - Days

/// A day on the wall calendar (Gregorian): the date where the user was when they dictated. Kept as
/// year-month-day, so a day means the same after a trip or a daylight-saving change, and going from one
/// day to the next is plain arithmetic (never "add 24 hours", which skips or repeats a day twice a year).
public struct UsageDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }

    /// The day `date` falls on for someone in `timeZone`. 23:59 and 00:01 are different days there,
    /// whatever day it is in UTC.
    public init(_ date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// From "2026-10-10" (`key`). Nil for anything else, a date that does not exist included ("2026-02-30").
    public init?(key: String) {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        let candidate = UsageDate(year: y, month: m, day: d)
        guard UsageDate(ordinal: candidate.ordinal) == candidate else { return nil }
        self = candidate
    }

    /// "2026-10-10": how the store names a day.
    public var key: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { key }

    /// Days since 1970-01-01, negative before it (the civil-date arithmetic every calendar library uses).
    public var ordinal: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    public init(ordinal: Int) {
        let z = ordinal + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let month = mp < 10 ? mp + 3 : mp - 9
        self.init(year: yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month: month, day: dayOfYear - (153 * mp + 2) / 5 + 1)
    }

    public func adding(days: Int) -> UsageDate { UsageDate(ordinal: ordinal + days) }

    /// How many days from this day to `other` (negative when `other` is earlier).
    public func days(until other: UsageDate) -> Int { other.ordinal - ordinal }

    /// 1 = Sunday … 7 = Saturday, as `Calendar` numbers them.
    public var weekday: Int {
        let r = (ordinal + 4) % 7          // 1970-01-01 was a Thursday
        return (r < 0 ? r + 7 : r) + 1
    }

    /// The first day of this day's week, for a week that starts on `firstWeekday` (1 = Sunday, 2 = Monday).
    public func startOfWeek(firstWeekday: Int) -> UsageDate {
        adding(days: -((weekday - firstWeekday + 7) % 7))
    }

    public static func < (a: UsageDate, b: UsageDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

// MARK: - One day

/// What one day adds up to. Numbers only.
public struct UsageDay: Codable, Equatable, Sendable {
    /// Dictations whose text reached the user (typed, copied or shown in neoless).
    public var count: Int
    /// 字数 of the text as it was delivered (`TextCount.characters`).
    public var characters: Int
    /// Seconds of speech recorded.
    public var seconds: Double

    public init(count: Int = 0, characters: Int = 0, seconds: Double = 0) {
        self.count = count; self.characters = characters; self.seconds = seconds
    }

    public static let zero = UsageDay()

    public var isEmpty: Bool { count == 0 }

    /// Seconds of speech per dictation; nil on a day without one.
    public var averageSeconds: Double? { count > 0 ? seconds / Double(count) : nil }

    public static func + (a: UsageDay, b: UsageDay) -> UsageDay {
        UsageDay(count: a.count + b.count, characters: a.characters + b.characters, seconds: a.seconds + b.seconds)
    }
}

/// What the chart can show per day.
public enum UsageMetric: String, CaseIterable, Sendable, Identifiable {
    case count, characters, seconds
    public var id: String { rawValue }

    public func value(of day: UsageDay) -> Double {
        switch self {
        case .count: return Double(day.count)
        case .characters: return Double(day.characters)
        case .seconds: return day.seconds
        }
    }
}

/// One day of a series.
public struct UsagePoint: Equatable, Sendable, Identifiable {
    public let date: UsageDate
    public let usage: UsageDay
    public var id: UsageDate { date }

    public init(date: UsageDate, usage: UsageDay) {
        self.date = date; self.usage = usage
    }
}

// MARK: - The stats

public struct UsageStats: Equatable, Sendable {
    /// The store format this build writes, and the newest it reads. A new key that older builds can
    /// ignore does not change it; a change in what an existing key means does.
    public static let formatVersion = 1

    /// The typing speed 省下的时间 compares with: 60 字 a minute, an ordinary pace for typing Chinese with
    /// pinyin (and close to 40 English words a minute plus corrections). An estimate, said as one in the window.
    public static let typingCharactersPerMinute = 60.0

    public private(set) var days: [UsageDate: UsageDay]
    /// History from before the stats existed has been counted (or there was none): never done twice.
    public private(set) var backfilled: Bool

    public init(days: [UsageDate: UsageDay] = [:], backfilled: Bool = false) {
        self.days = days.filter { !$0.value.isEmpty }
        self.backfilled = backfilled
    }

    public subscript(day: UsageDate) -> UsageDay { days[day] ?? .zero }

    // MARK: Counting

    /// One more dictation on `day`.
    public mutating func add(characters: Int, seconds: Double, on day: UsageDate) {
        let seconds = seconds.isFinite ? max(0, seconds) : 0
        days[day] = self[day] + UsageDay(count: 1, characters: max(0, characters), seconds: seconds)
    }

    /// One more dictation: `text` as it was delivered, `seconds` of speech, on the day `date` is in `timeZone`.
    public mutating func add(text: String, seconds: Double, at date: Date, timeZone: TimeZone) {
        add(characters: TextCount.characters(text), seconds: seconds, on: UsageDate(date, timeZone: timeZone))
    }

    /// One more dictation, if its text reached the user: typed, copied or shown in neoless. One that went
    /// nowhere (the paste stopped with Esc, a password field) is not counted, so 字数 and 省下的时间 are
    /// only ever about text that was used. Returns whether it counted.
    @discardableResult
    public mutating func add(_ record: DictationRecord, timeZone: TimeZone) -> Bool {
        guard record.delivery != .notInserted else { return false }
        add(text: record.finalText, seconds: record.duration, at: record.date, timeZone: timeZone)
        return true
    }

    /// Counts the dictations already in history, once: the first launch of a build that has stats. Returns
    /// whether anything changed (so the caller saves). `timeZone` is today's: where those days were lived
    /// is not recorded.
    @discardableResult
    public mutating func backfill(from records: [DictationRecord], timeZone: TimeZone) -> Bool {
        guard !backfilled else { return false }
        for record in records { add(record, timeZone: timeZone) }
        backfilled = true
        return true
    }

    // MARK: Reading

    /// `count` days ending on `today`, oldest first; a day without dictation is there with zeros.
    public func series(days count: Int, endingOn today: UsageDate) -> [UsagePoint] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            let date = today.adding(days: i - (count - 1))
            return UsagePoint(date: date, usage: self[date])
        }
    }

    /// Everything ever counted.
    public var total: UsageDay { days.values.reduce(.zero, +) }

    /// Days with at least one dictation.
    public var activeDays: Int { days.count }

    /// The first day anything was counted.
    public var firstDay: UsageDate? { days.keys.min() }

    /// Days in a row with at least one dictation, up to `today`. A day that has not seen one yet does not
    /// break the run: until it is over, yesterday's streak still stands.
    public func streak(asOf today: UsageDate) -> Int {
        var day = self[today].isEmpty ? today.adding(days: -1) : today
        var run = 0
        while !self[day].isEmpty {
            run += 1
            day = day.adding(days: -1)
        }
        return run
    }

    /// The longest run of days in a row, ever.
    public var longestStreak: Int {
        var best = 0, run = 0
        var previous: Int?
        for ordinal in days.keys.map(\.ordinal).sorted() {
            run = previous == ordinal - 1 ? run + 1 : 1
            best = max(best, run)
            previous = ordinal
        }
        return best
    }

    /// Total and daily average of `metric` over a series. The average is over the days since the first
    /// dictation ever, not over days before neoless was in use: someone who started the day before
    /// yesterday has a three-day average in a seven-day chart.
    public func summary(_ metric: UsageMetric, of points: [UsagePoint]) -> (total: Double, dailyAverage: Double) {
        let total = points.reduce(0) { $0 + metric.value(of: $1.usage) }
        guard let first = firstDay else { return (total, 0) }
        let inUse = points.filter { $0.date >= first }.count
        return (total, total / Double(max(1, inUse)))
    }

    /// 省下的时间, in seconds: what typing the same text would have taken at `typingCharactersPerMinute`,
    /// less the time spent speaking it. Never negative (a slow, short dictation saves nothing).
    public static func timeSaved(_ usage: UsageDay) -> TimeInterval {
        max(0, Double(usage.characters) / typingCharactersPerMinute * 60 - usage.seconds)
    }

    /// 字 a minute while speaking: the delivered text over the time spent saying it. Nil without a second
    /// of speech to divide by.
    public static func speakingRate(_ usage: UsageDay) -> Double? {
        usage.seconds >= 1 && usage.characters > 0 ? Double(usage.characters) / usage.seconds * 60 : nil
    }

    /// The year at a glance: `weeks` columns ending with the week `today` is in.
    public func heatmap(weeks: Int, endingOn today: UsageDate, firstWeekday: Int,
                        metric: UsageMetric = .count) -> UsageHeatmap {
        UsageHeatmap(stats: self, weeks: weeks, today: today, firstWeekday: firstWeekday, metric: metric)
    }
}

// MARK: - Store format

/// `usage.json`: `{"version": 1, "backfilled": true, "days": {"2026-10-10": {"count": 3, "characters": 120, "seconds": 35.2}}}`.
/// A file from a newer format, or one with a day that is not a date, does not decode: `DataFileStore` then
/// sets it aside untouched instead of overwriting it.
extension UsageStats: Codable {
    private enum CodingKeys: String, CodingKey { case version, backfilled, days }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        guard (1...Self.formatVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c,
                                                   debugDescription: "usage stats format \(version) is not one this build reads")
        }
        var days: [UsageDate: UsageDay] = [:]
        for (key, value) in try c.decode([String: UsageDay].self, forKey: .days) {
            guard let day = UsageDate(key: key) else {
                throw DecodingError.dataCorruptedError(forKey: .days, in: c, debugDescription: "\(key) is not a day")
            }
            days[day] = UsageDay(count: max(0, value.count), characters: max(0, value.characters),
                                 seconds: value.seconds.isFinite ? max(0, value.seconds) : 0)
        }
        self.init(days: days, backfilled: try c.decodeIfPresent(Bool.self, forKey: .backfilled) ?? true)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .version)
        try c.encode(backfilled, forKey: .backfilled)
        // Seconds to a tenth: sums of recording lengths would otherwise drag a tail of digits along.
        let rounded = days.reduce(into: [String: UsageDay]()) { out, entry in
            var day = entry.value
            day.seconds = (day.seconds * 10).rounded() / 10
            out[entry.key.key] = day
        }
        try c.encode(rounded, forKey: .days)
    }
}

// MARK: - Heatmap

/// 过去一年: weeks as columns (oldest first), the days of a week as rows, each day shaded by how much it was
/// used compared with the user's own busy days.
public struct UsageHeatmap: Equatable, Sendable {
    public struct Cell: Equatable, Sendable {
        public let date: UsageDate
        public let usage: UsageDay
        /// 0 = nothing that day, 1...`UsageHeatmap.levels` = lightest to strongest.
        public let level: Int
    }

    /// Where a month's label goes: over the first column whose week starts in that month.
    public struct MonthMark: Equatable, Sendable {
        public let column: Int
        public let month: Int
    }

    /// Shades above "nothing".
    public static let levels = 4
    /// A day needs at least this many dictations (or the equal in another metric) for the strongest shade,
    /// so a new user's first day with one dictation is a light square, not the darkest.
    public static let fullLevelFloor = 4.0
    /// The strongest shade starts at this share of the user's active days, ranked: one day far busier than
    /// the rest does not turn every other day pale.
    public static let fullLevelPercentile = 0.9
    /// Month labels closer than this many columns would run into each other: the earlier one is dropped.
    public static let monthLabelSpacing = 3

    /// `weeks[column][row]`: row 0 is the week's first day. Nil for the days after today.
    public let weeks: [[Cell?]]
    public let months: [MonthMark]
    /// 1 = Sunday, 2 = Monday: the weekday of row 0.
    public let firstWeekday: Int
    public let today: UsageDate

    init(stats: UsageStats, weeks count: Int, today: UsageDate, firstWeekday: Int, metric: UsageMetric) {
        let count = max(1, count)
        let firstWeekday = (1...7).contains(firstWeekday) ? firstWeekday : 1
        let start = today.startOfWeek(firstWeekday: firstWeekday).adding(days: -7 * (count - 1))
        let dates = (0..<count * 7).map { start.adding(days: $0) }.filter { $0 <= today }
        let reference = Self.reference(for: dates.map { metric.value(of: stats[$0]) })
        weeks = (0..<count).map { column in
            (0..<7).map { row in
                let date = start.adding(days: column * 7 + row)
                guard date <= today else { return nil }
                let usage = stats[date]
                return Cell(date: date, usage: usage, level: Self.level(metric.value(of: usage), reference: reference))
            }
        }
        var marks: [MonthMark] = []
        for column in 0..<count {
            let month = start.adding(days: column * 7).month
            guard column == 0 || month != start.adding(days: (column - 1) * 7).month else { continue }
            // The first column is usually the tail of a month: its label gives way to the next one.
            if let last = marks.last, column - last.column < Self.monthLabelSpacing { marks.removeLast() }
            marks.append(MonthMark(column: column, month: month))
        }
        months = marks
        self.firstWeekday = firstWeekday
        self.today = today
    }

    /// The weekday (1 = Sunday … 7 = Saturday) of a row.
    public func weekday(row: Int) -> Int { (firstWeekday - 1 + row) % 7 + 1 }

    /// Every day shown, oldest first.
    public var cells: [Cell] { weeks.flatMap { $0.compactMap { $0 } } }

    /// Days with at least one dictation, among the days shown.
    public var activeDays: Int { cells.filter { !$0.usage.isEmpty }.count }

    /// The longest run of days in a row with a dictation, among the days shown: the same days `activeDays`
    /// counts, so the two figures beside the grid are about one stretch of time.
    public var longestStreak: Int {
        var best = 0, run = 0
        for cell in cells {
            run = cell.usage.isEmpty ? 0 : run + 1
            best = max(best, run)
        }
        return best
    }

    /// The value that earns the strongest shade: the `fullLevelPercentile` of the active days' values
    /// (nearest rank), and at least `fullLevelFloor`.
    public static func reference(for values: [Double]) -> Double {
        let active = values.filter { $0 > 0 }.sorted()
        guard !active.isEmpty else { return fullLevelFloor }
        let rank = Int((fullLevelPercentile * Double(active.count)).rounded(.up))
        return max(fullLevelFloor, active[min(active.count - 1, max(0, rank - 1))])
    }

    /// 0 for nothing; otherwise 1...`levels`, in equal steps up to `reference`.
    public static func level(_ value: Double, reference: Double) -> Int {
        guard value > 0, reference > 0 else { return 0 }
        return min(levels, max(1, Int((value / reference * Double(levels)).rounded(.up))))
    }
}

// MARK: - 字数

/// 字数 the way a word processor counts mixed text: every Chinese character (and kana, and Hangul
/// syllable) is one, every run of Latin letters and digits is one ("OpenAI", "3.5", "don't"), and
/// punctuation, spaces and emoji are none. So an English sentence counts its words, a Chinese one its
/// characters, and one typing speed (`UsageStats.typingCharactersPerMinute`) is fair to both.
public enum TextCount {
    public static func characters(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for character in text {
            if isWide(character) {
                count += 1
                inWord = false
            } else if character.isLetter || character.isNumber {
                if !inWord { count += 1 }
                inWord = true
            } else if !wordJoiners.contains(character) {
                inWord = false
            }
            // A joiner keeps a word going ("3.5", "don't", "gpt-6"); between words it counts for nothing.
        }
        return count
    }

    private static let wordJoiners: Set<Character> = ["'", "’", "-", ".", "_"]

    /// Written without spaces between words: Han, kana, Bopomofo, Hangul.
    private static func isWide(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if scalar.properties.isIdeographic { return true }
        switch scalar.value {
        case 0x3040...0x30FF, 0x3100...0x312F, 0x31F0...0x31FF, 0xAC00...0xD7AF: return true
        default: return false
        }
    }
}

// MARK: - Words for the numbers

/// The dashboard's numbers as the window writes them: a figure and its unit apart, so the figure can be
/// large and the unit small ("6 分 12 秒", "3.2 小时", "12.4 万").
public enum UsageText {
    public struct Part: Equatable, Sendable {
        public let text: String
        /// A unit or a word ("分", "小时", "不到"), drawn small; otherwise a figure, drawn large.
        public let isUnit: Bool

        public init(_ text: String, unit: Bool = false) {
            self.text = text; self.isUnit = unit
        }
    }

    /// The parts on one line: figures and units a space apart ("6 分 12 秒").
    public static func plain(_ parts: [Part]) -> String {
        parts.map(\.text).joined(separator: " ")
    }

    /// "0", "1,284", "12,345"; from 100,000 on, in 万 with one decimal ("12.4 万"). `unit` follows the
    /// figure ("1,284 次", "12.4 万次").
    public static func number(_ value: Int, unit: String = "") -> [Part] {
        if value >= 100_000 { return [Part(decimal(Double(value) / 10_000)), Part("万" + unit, unit: true)] }
        return unit.isEmpty ? [Part(grouped(value))] : [Part(grouped(value)), Part(unit, unit: true)]
    }

    /// A length of speech added up: "0 秒", "42 秒", "6 分 12 秒", "6 分钟", "1 小时 5 分", "128 小时".
    public static func duration(_ seconds: Double) -> [Part] {
        let total = Int((seconds.isFinite ? max(0, seconds) : 0).rounded())
        if total < 60 { return [Part("\(total)"), Part("秒", unit: true)] }
        if total < 3_600 {
            let m = total / 60, s = total % 60
            return s == 0 ? [Part("\(m)"), Part("分钟", unit: true)]
                : [Part("\(m)"), Part("分", unit: true), Part("\(s)"), Part("秒", unit: true)]
        }
        let h = total / 3_600, m = total % 3_600 / 60
        if h >= 100 || m == 0 { return [Part(grouped(h)), Part("小时", unit: true)] }
        return [Part("\(h)"), Part("小时", unit: true), Part("\(m)"), Part("分", unit: true)]
    }

    /// 省下的时间, rounded the way one would say it: "0 分钟", "不到 1 分钟", "15 分钟", "3.2 小时", "128 小时".
    public static func saved(_ seconds: Double) -> [Part] {
        let seconds = seconds.isFinite ? max(0, seconds) : 0
        if seconds == 0 { return [Part("0"), Part("分钟", unit: true)] }
        if seconds < 60 { return [Part("不到", unit: true), Part("1"), Part("分钟", unit: true)] }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return [Part("\(minutes)"), Part("分钟", unit: true)] }
        let hours = seconds / 3_600
        return [Part(hours >= 100 ? grouped(Int(hours.rounded())) : decimal(hours)), Part("小时", unit: true)]
    }

    /// A day's or a period's amount with its unit: "39 次", "4,280 字", "6 分 12 秒".
    public static func amount(_ value: Double, metric: UsageMetric) -> [Part] {
        switch metric {
        case .count: return number(Int(value.rounded()), unit: "次")
        case .characters: return number(Int(value.rounded()), unit: "字")
        case .seconds: return duration(value)
        }
    }

    /// "日均 5.6 次", "日均 611 字", "日均 1 分 47 秒".
    public static func dailyAverage(_ value: Double, metric: UsageMetric) -> String {
        switch metric {
        case .count: return "日均 \(decimal(value)) 次"
        case .characters: return "日均 \(grouped(Int(value.rounded()))) 字"
        case .seconds: return "日均 " + plain(duration(value))
        }
    }

    /// One recording's length, for a list row: "8.4 秒", "45.0 秒", "1 分 05 秒".
    public static func recording(_ seconds: Double) -> String {
        let seconds = seconds.isFinite ? max(0, seconds) : 0
        if seconds < 59.95 { return String(format: "%.1f 秒", seconds) }
        let total = Int(seconds.rounded())
        return String(format: "%d 分 %02d 秒", total / 60, total % 60)
    }

    /// A bar's value, as short as it can be said, and written like the figures above the chart: "12",
    /// "1,284", "1.2万" for counts and 字数. A length of speech under an hour is minutes and seconds as a
    /// clock shows them ("0:45", "6:12"), which reads straight across to the "6 分 12 秒" above the chart
    /// (a decimal, "6.2分", does not); from an hour on, "1.5小时".
    public static func compact(_ value: Double, metric: UsageMetric) -> String {
        switch metric {
        case .count, .characters:
            let n = Int(value.rounded())
            return n >= 10_000 ? decimal(Double(n) / 10_000) + "万" : grouped(n)
        case .seconds:
            let total = Int((value.isFinite ? max(0, value) : 0).rounded())
            if total < 3_600 { return String(format: "%d:%02d", total / 60, total % 60) }
            return decimal(Double(total) / 3_600) + "小时"
        }
    }

    /// Under 今日说话: how fast the speaking was, and what that is against typing at
    /// `UsageStats.typingCharactersPerMinute`. Longest wording first (the tile shows the first that fits):
    /// "每分钟 207 字 · 打字的 3.5 倍", "速度是打字的 3.5 倍", "每分钟 207 字". Empty when there is no speech
    /// to measure, or when it was no faster than typing: nothing to show off then.
    public static func pace(_ usage: UsageDay) -> [String] {
        guard let rate = UsageStats.speakingRate(usage) else { return [] }
        let times = rate / UsageStats.typingCharactersPerMinute
        guard times >= 1.05 else { return [] }
        let speed = "每分钟 \(grouped(Int(rate.rounded()))) 字"
        return ["\(speed) · 打字的 \(decimal(times)) 倍", "速度是打字的 \(decimal(times)) 倍", speed]
    }

    /// A day in a sentence: "9月11日", with its year when that is not `today`'s ("2025年11月3日").
    public static func date(_ date: UsageDate, asOf today: UsageDate) -> String {
        (date.year == today.year ? "" : "\(date.year)年") + "\(date.month)月\(date.day)日"
    }

    /// "10月8日 周四".
    public static func day(_ date: UsageDate) -> String {
        "\(date.month)月\(date.day)日 \(weekday(date.weekday))"
    }

    /// "周一" … "周日" for `Calendar`'s 1 = Sunday … 7 = Saturday.
    public static func weekday(_ weekday: Int) -> String {
        "周" + weekdayCharacter(weekday)
    }

    /// "一" … "日".
    public static func weekdayCharacter(_ weekday: Int) -> String {
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        return names[((weekday - 1) % 7 + 7) % 7]
    }

    /// One decimal, without a trailing ".0": "3.2", "12".
    static func decimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? grouped(Int(rounded)) : String(format: "%.1f", rounded)
    }

    /// "1,284": thousands apart, the same on every Mac whatever its region.
    static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = ""
        for (i, digit) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return value < 0 ? "-" + out : out
    }
}
