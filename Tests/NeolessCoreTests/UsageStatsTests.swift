import Foundation
import Testing
@testable import NeolessCore

private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
private let chicago = TimeZone(identifier: "America/Chicago")!
private let honolulu = TimeZone(identifier: "Pacific/Honolulu")!

/// A moment on a wall clock: `at(2026, 10, 10, 23, 59, in: shanghai)`.
private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0,
                in zone: TimeZone) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}

private func day(_ year: Int, _ month: Int, _ day: Int) -> UsageDate {
    UsageDate(year: year, month: month, day: day)
}

private func record(_ text: String, seconds: Double, at date: Date) -> DictationRecord {
    DictationRecord(date: date, duration: seconds, raw: text, polished: nil, finalText: text, appName: nil,
                    mode: .natural, model: nil, polishSeconds: nil, note: nil, delivery: .pasted)
}

@Suite struct UsageDateTests {
    @Test func keysRoundTrip() {
        #expect(day(2026, 10, 10).key == "2026-10-10")
        #expect(day(2026, 1, 5).key == "2026-01-05")
        #expect(UsageDate(key: "2026-10-10") == day(2026, 10, 10))
        #expect(UsageDate(key: "2024-02-29") == day(2024, 2, 29))
    }

    @Test func whatIsNotADayIsRefused() {
        for key in ["", "2026-10", "2026-10-10-1", "2026-13-01", "2026-00-10", "2026-02-30", "2025-02-29",
                    "2026-10-00", "26-10-10", "2026-1-5", "2026/10/10", "abcd-ef-gh", "２０２６-10-10", " 2026-10-10"] {
            #expect(UsageDate(key: key) == nil, "\(key)")
        }
    }

    @Test func daysStepThroughMonthsYearsAndLeapDays() {
        #expect(day(2026, 10, 31).adding(days: 1) == day(2026, 11, 1))
        #expect(day(2026, 12, 31).adding(days: 1) == day(2027, 1, 1))
        #expect(day(2027, 1, 1).adding(days: -1) == day(2026, 12, 31))
        #expect(day(2024, 2, 28).adding(days: 1) == day(2024, 2, 29))
        #expect(day(2024, 2, 29).adding(days: 1) == day(2024, 3, 1))
        #expect(day(2026, 2, 28).adding(days: 1) == day(2026, 3, 1))
        #expect(day(2026, 10, 10).adding(days: -365) == day(2025, 10, 10))
        #expect(day(2026, 10, 1).days(until: day(2026, 10, 10)) == 9)
        #expect(day(2026, 10, 10).days(until: day(2026, 10, 1)) == -9)
        #expect(day(1970, 1, 1).ordinal == 0)
        #expect(UsageDate(ordinal: -1) == day(1969, 12, 31))
        // Every day of four years comes back from its own number, one after the other.
        var date = day(2023, 12, 31)
        for _ in 0..<1_500 {
            let next = date.adding(days: 1)
            #expect(next.ordinal == date.ordinal + 1)
            #expect(UsageDate(ordinal: next.ordinal) == next)
            #expect(next > date)
            date = next
        }
    }

    @Test func weekdaysMatchTheCalendar() {
        // 1 = Sunday … 7 = Saturday.
        #expect(day(1970, 1, 1).weekday == 5)        // a Thursday
        #expect(day(2026, 10, 10).weekday == 7)      // a Saturday
        #expect(day(2026, 10, 11).weekday == 1)
        #expect(day(2026, 10, 12).weekday == 2)
        #expect(day(1969, 12, 28).weekday == 1)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai
        for offset in stride(from: -900, to: 900, by: 37) {
            let date = day(2026, 10, 10).adding(days: offset)
            let noon = at(date.year, date.month, date.day, in: shanghai)
            #expect(date.weekday == calendar.component(.weekday, from: noon), "\(date)")
        }
    }

    @Test func weeksStartWhereTheUserSaysTheyDo() {
        let saturday = day(2026, 10, 10)
        #expect(saturday.startOfWeek(firstWeekday: 2) == day(2026, 10, 5))    // Monday
        #expect(saturday.startOfWeek(firstWeekday: 1) == day(2026, 10, 4))    // Sunday
        #expect(saturday.startOfWeek(firstWeekday: 7) == saturday)
        #expect(day(2026, 10, 5).startOfWeek(firstWeekday: 2) == day(2026, 10, 5))
        #expect(day(2026, 10, 4).startOfWeek(firstWeekday: 2) == day(2026, 9, 28))
    }

    @Test func aDayIsTheOneOnTheUsersWallClock() {
        // One minute apart, two different days.
        #expect(UsageDate(at(2026, 10, 10, 23, 59, 59, in: shanghai), timeZone: shanghai) == day(2026, 10, 10))
        #expect(UsageDate(at(2026, 10, 11, 0, 0, 1, in: shanghai), timeZone: shanghai) == day(2026, 10, 11))
        // The same moment is a different day in another part of the world.
        let moment = at(2026, 10, 11, 8, 30, in: shanghai)
        #expect(UsageDate(moment, timeZone: shanghai) == day(2026, 10, 11))
        #expect(UsageDate(moment, timeZone: chicago) == day(2026, 10, 10))
        #expect(UsageDate(moment, timeZone: honolulu) == day(2026, 10, 10))
        #expect(UsageDate(moment, timeZone: TimeZone(identifier: "UTC")!) == day(2026, 10, 11))
    }
}

@Suite struct UsageCountingTests {
    @Test func aDictationAddsToItsDay() {
        var stats = UsageStats()
        stats.add(text: "明天下午三点开会。", seconds: 4.5, at: at(2026, 10, 10, 9, in: shanghai), timeZone: shanghai)
        stats.add(text: "好的，收到。", seconds: 1.5, at: at(2026, 10, 10, 21, in: shanghai), timeZone: shanghai)
        stats.add(text: "the report is ready", seconds: 3, at: at(2026, 10, 9, 21, in: shanghai), timeZone: shanghai)
        #expect(stats[day(2026, 10, 10)] == UsageDay(count: 2, characters: 12, seconds: 6))
        #expect(stats[day(2026, 10, 9)] == UsageDay(count: 1, characters: 4, seconds: 3))
        #expect(stats[day(2026, 10, 8)] == .zero)
        #expect(stats.total == UsageDay(count: 3, characters: 16, seconds: 9))
        #expect(stats.activeDays == 2)
        #expect(stats.firstDay == day(2026, 10, 9))
        #expect(stats[day(2026, 10, 10)].averageSeconds == 3)
        #expect(UsageDay.zero.averageSeconds == nil)
    }

    @Test func midnightSplitsTwoDictationsIntoTwoDays() {
        var stats = UsageStats()
        stats.add(text: "晚安", seconds: 1, at: at(2026, 10, 10, 23, 59, 30, in: chicago), timeZone: chicago)
        stats.add(text: "早安", seconds: 1, at: at(2026, 10, 11, 0, 0, 30, in: chicago), timeZone: chicago)
        #expect(stats[day(2026, 10, 10)].count == 1)
        #expect(stats[day(2026, 10, 11)].count == 1)
    }

    @Test func aDayKeepsItsDateAfterATrip() {
        // Dictated in Shanghai on the evening of the 10th; looked at the next day in Honolulu, where that moment was
        // still the early morning of the 10th.
        var stats = UsageStats()
        stats.add(text: "明天见", seconds: 2, at: at(2026, 10, 10, 22, in: shanghai), timeZone: shanghai)
        let series = stats.series(days: 3, endingOn: UsageDate(at(2026, 10, 11, 9, in: honolulu), timeZone: honolulu))
        #expect(series.map(\.date) == [day(2026, 10, 9), day(2026, 10, 10), day(2026, 10, 11)])
        #expect(series.map(\.usage.count) == [0, 1, 0])
    }

    @Test func daylightSavingNeitherSkipsNorRepeatsADay() {
        // Chicago: clocks go back on 2026-11-01 (a 25-hour day) and forward on 2026-03-08 (23 hours).
        var stats = UsageStats()
        stats.add(text: "一", seconds: 1, at: at(2026, 10, 31, 23, 30, in: chicago), timeZone: chicago)
        stats.add(text: "二", seconds: 1, at: at(2026, 11, 1, 0, 30, in: chicago), timeZone: chicago)
        stats.add(text: "三", seconds: 1, at: at(2026, 11, 1, 23, 30, in: chicago), timeZone: chicago)
        stats.add(text: "四", seconds: 1, at: at(2026, 11, 2, 0, 30, in: chicago), timeZone: chicago)
        let autumn = stats.series(days: 4, endingOn: day(2026, 11, 3))
        #expect(autumn.map(\.date) == [day(2026, 10, 31), day(2026, 11, 1), day(2026, 11, 2), day(2026, 11, 3)])
        #expect(autumn.map(\.usage.count) == [1, 2, 1, 0])
        #expect(stats.streak(asOf: day(2026, 11, 2)) == 3)

        var spring = UsageStats()
        spring.add(text: "一", seconds: 1, at: at(2026, 3, 7, 23, 30, in: chicago), timeZone: chicago)
        spring.add(text: "二", seconds: 1, at: at(2026, 3, 8, 3, 30, in: chicago), timeZone: chicago)
        spring.add(text: "三", seconds: 1, at: at(2026, 3, 9, 0, 30, in: chicago), timeZone: chicago)
        #expect(spring.series(days: 3, endingOn: day(2026, 3, 9)).map(\.usage.count) == [1, 1, 1])
        #expect(spring.streak(asOf: day(2026, 3, 9)) == 3)
    }

    @Test func nonsenseNumbersCountAsNothing() {
        var stats = UsageStats()
        stats.add(characters: -5, seconds: -3, on: day(2026, 10, 10))
        stats.add(characters: 7, seconds: .nan, on: day(2026, 10, 10))
        stats.add(characters: 1, seconds: .infinity, on: day(2026, 10, 10))
        #expect(stats[day(2026, 10, 10)] == UsageDay(count: 3, characters: 8, seconds: 0))
    }

    @Test func historyIsCountedOnce() {
        let history = [
            record("周五交报告。", seconds: 3, at: at(2026, 10, 9, 10, in: shanghai)),
            record("好的。", seconds: 1, at: at(2026, 10, 9, 11, in: shanghai)),
            record("see you then", seconds: 2, at: at(2026, 9, 20, 8, in: shanghai)),
        ]
        var stats = UsageStats()
        #expect(!stats.backfilled)
        let counted = stats.backfill(from: history, timeZone: shanghai)
        #expect(counted)
        #expect(stats.backfilled)
        #expect(stats.total == UsageDay(count: 3, characters: 10, seconds: 6))
        #expect(stats[day(2026, 10, 9)].count == 2)
        // A second launch, or history read again: nothing is added twice.
        let again = stats.backfill(from: history, timeZone: shanghai)
        #expect(!again)
        #expect(stats.total.count == 3)
        // No history at all still counts as done, so records made later are not counted again.
        var fresh = UsageStats()
        let nothingToCount = fresh.backfill(from: [], timeZone: shanghai)
        #expect(nothingToCount)
        fresh.add(history[0], timeZone: shanghai)
        let later = fresh.backfill(from: history, timeZone: shanghai)
        #expect(!later)
        #expect(fresh.total.count == 1)
    }

    @Test func textThatWentNowhereIsNotCounted() {
        // The paste stopped with Esc, or the cursor was in a password field: the text was never used.
        var nowhere = record("这段没有输入到任何地方", seconds: 4, at: at(2026, 10, 10, 9, in: shanghai))
        nowhere.delivery = .notInserted
        var stats = UsageStats()
        let counted = stats.add(nowhere, timeZone: shanghai)
        #expect(!counted)
        #expect(stats.total.isEmpty)
        // Typed, copied or shown in neoless all count.
        for delivery in [Delivery.pasted, .copied, .inApp] {
            var used = nowhere
            used.delivery = delivery
            let added = stats.add(used, timeZone: shanghai)
            #expect(added)
        }
        #expect(stats.total.count == 3)
        // The same when history is counted at first launch.
        var fresh = UsageStats()
        fresh.backfill(from: [nowhere, record("好的。", seconds: 1, at: at(2026, 10, 9, 11, in: shanghai))], timeZone: shanghai)
        #expect(fresh.total == UsageDay(count: 1, characters: 2, seconds: 1))
    }

    @Test func theStatsOutliveTheHistory() {
        // Counted as dictations happen; trimming or clearing history afterwards takes nothing away.
        var stats = UsageStats()
        stats.backfill(from: [], timeZone: shanghai)
        var history: [DictationRecord] = []
        for n in 0..<40 {
            let item = record("第 \(n) 天的记录", seconds: 2, at: at(2026, 10, 10, 9, in: shanghai).addingTimeInterval(Double(-n) * 86_400))
            history.append(item)
            stats.add(item, timeZone: shanghai)
        }
        history = HistoryRetention.prune(history, now: at(2026, 10, 10, 10, in: shanghai))
        #expect(history.count == 30)
        #expect(stats.total.count == 40)
        #expect(stats.activeDays == 40)
    }
}

@Suite struct UsageSeriesTests {
    private func stats(_ counts: [UsageDate: Int]) -> UsageStats {
        UsageStats(days: counts.mapValues { UsageDay(count: $0, characters: $0 * 20, seconds: Double($0) * 6) }, backfilled: true)
    }

    @Test func aSeriesEndsTodayAndFillsTheGaps() {
        let today = day(2026, 10, 10)
        let s = stats([today: 3, day(2026, 10, 8): 5, day(2026, 10, 3): 9, day(2026, 9, 12): 2])
        let week = s.series(days: 7, endingOn: today)
        #expect(week.count == 7)
        #expect(week.first?.date == day(2026, 10, 4))
        #expect(week.last?.date == today)
        #expect(week.map(\.usage.count) == [0, 0, 0, 0, 5, 0, 3])
        let month = s.series(days: 30, endingOn: today)
        #expect(month.count == 30)
        #expect(month.first?.date == day(2026, 9, 11))
        #expect(month.map(\.usage.count).reduce(0, +) == 19)
        #expect(s.series(days: 1, endingOn: today).map(\.usage.count) == [3])
        #expect(s.series(days: 0, endingOn: today).isEmpty)
        // A day after today (a clock that was wrong) is in the totals but in no series.
        let future = stats([today: 1, day(2026, 10, 12): 4])
        #expect(future.series(days: 7, endingOn: today).map(\.usage.count).reduce(0, +) == 1)
        #expect(future.total.count == 5)
    }

    @Test func everyMetricReadsTheSameDays() {
        let today = day(2026, 10, 10)
        let s = stats([today: 3, day(2026, 10, 9): 1])
        let points = s.series(days: 2, endingOn: today)
        #expect(points.map { UsageMetric.count.value(of: $0.usage) } == [1, 3])
        #expect(points.map { UsageMetric.characters.value(of: $0.usage) } == [20, 60])
        #expect(points.map { UsageMetric.seconds.value(of: $0.usage) } == [6, 18])
    }

    @Test func theDailyAverageStartsWithTheFirstDictation() {
        let today = day(2026, 10, 10)
        // In use for three days: 12 over those three, not over the chart's seven.
        let recent = stats([today: 3, day(2026, 10, 9): 4, day(2026, 10, 8): 5])
        let week = recent.summary(.count, of: recent.series(days: 7, endingOn: today))
        #expect(week.total == 12)
        #expect(week.dailyAverage == 4)
        // In use for longer than the chart shows: over all its days, quiet ones included.
        let longer = stats([today: 7, day(2026, 8, 1): 2])
        #expect(longer.summary(.count, of: longer.series(days: 7, endingOn: today)).dailyAverage == 1)
        #expect(longer.summary(.characters, of: longer.series(days: 7, endingOn: today)).total == 140)
        // Nothing yet.
        let empty = UsageStats()
        let none = empty.summary(.count, of: empty.series(days: 7, endingOn: today))
        #expect(none.total == 0 && none.dailyAverage == 0)
    }

    @Test func aStreakRunsUpToTodayAndWaitsForIt() {
        let today = day(2026, 10, 10)
        #expect(UsageStats().streak(asOf: today) == 0)
        #expect(stats([today: 1]).streak(asOf: today) == 1)
        #expect(stats([today: 1, day(2026, 10, 9): 2, day(2026, 10, 8): 1]).streak(asOf: today) == 3)
        // Nothing yet today: yesterday's run still stands.
        #expect(stats([day(2026, 10, 9): 2, day(2026, 10, 8): 1]).streak(asOf: today) == 2)
        // A missed day ends it.
        #expect(stats([day(2026, 10, 8): 2, day(2026, 10, 7): 1]).streak(asOf: today) == 0)
        #expect(stats([today: 1, day(2026, 10, 8): 2, day(2026, 10, 7): 1]).streak(asOf: today) == 1)
        // Across a month and a year.
        #expect(stats([day(2027, 1, 1): 1, day(2026, 12, 31): 1, day(2026, 12, 30): 1]).streak(asOf: day(2027, 1, 1)) == 3)
    }

    @Test func theLongestStreakIsRemembered() {
        #expect(UsageStats().longestStreak == 0)
        let s = stats([day(2026, 10, 10): 1, day(2026, 9, 30): 1, day(2026, 10, 1): 1, day(2026, 10, 2): 1,
                       day(2026, 10, 3): 1, day(2026, 8, 1): 1, day(2026, 8, 2): 1])
        #expect(s.longestStreak == 4)
        #expect(s.streak(asOf: day(2026, 10, 10)) == 1)
    }

    @Test func timeSavedIsTypingTimeLessSpeakingTime() {
        #expect(UsageStats.typingCharactersPerMinute == 60)
        // 120 字 would take two minutes to type; saying them took 35 seconds.
        #expect(UsageStats.timeSaved(UsageDay(count: 3, characters: 120, seconds: 35)) == 85)
        // A slow, short one saves nothing, never a negative amount.
        #expect(UsageStats.timeSaved(UsageDay(count: 1, characters: 3, seconds: 10)) == 0)
        #expect(UsageStats.timeSaved(.zero) == 0)
    }
}

@Suite struct UsageHeatmapTests {
    private func stats(_ counts: [UsageDate: Int]) -> UsageStats {
        UsageStats(days: counts.mapValues { UsageDay(count: $0, characters: $0 * 10, seconds: Double($0)) }, backfilled: true)
    }

    @Test func weeksAreColumnsEndingWithThisWeek() {
        let today = day(2026, 10, 10)   // a Saturday
        let map = stats([today: 2, day(2026, 10, 5): 1]).heatmap(weeks: 53, endingOn: today, firstWeekday: 2)
        #expect(map.weeks.count == 53)
        #expect(map.weeks.allSatisfy { $0.count == 7 })
        // Monday first: the last column is Mon 5 … Sat 10, and Sunday the 11th has not happened yet.
        let last = map.weeks[52]
        #expect(last.map { $0?.date.day } == [5, 6, 7, 8, 9, 10, nil])
        #expect(last[0]?.usage.count == 1)
        #expect(last[5]?.usage.count == 2)
        #expect(map.weeks[0][0]?.date == day(2026, 10, 5).adding(days: -52 * 7))
        #expect(map.weeks.dropLast().allSatisfy { week in week.allSatisfy { $0 != nil } })
        #expect(map.cells.count == 52 * 7 + 6)
        #expect(map.cells.last?.date == today)
        #expect((0..<7).map(map.weekday(row:)) == [2, 3, 4, 5, 6, 7, 1])
    }

    @Test func aSundayWeekPutsSundayOnTop() {
        let today = day(2026, 10, 10)
        let map = stats([today: 1]).heatmap(weeks: 2, endingOn: today, firstWeekday: 1)
        #expect(map.weeks[1].map { $0?.date.day } == [4, 5, 6, 7, 8, 9, 10])
        #expect(map.weeks[0][0]?.date == day(2026, 9, 27))
        #expect((0..<7).map(map.weekday(row:)) == [1, 2, 3, 4, 5, 6, 7])
        // Today alone in its week, the day it starts.
        let monday = stats([:]).heatmap(weeks: 1, endingOn: day(2026, 10, 5), firstWeekday: 2)
        #expect(monday.weeks[0].map { $0 == nil } == [false, true, true, true, true, true, true])
        // Out of range is read as Sunday rather than crashing.
        #expect(stats([:]).heatmap(weeks: 0, endingOn: today, firstWeekday: 9).weeks.count == 1)
    }

    @Test func monthsAreMarkedWhereTheirFirstWeekStarts() {
        let map = UsageStats().heatmap(weeks: 53, endingOn: day(2026, 10, 10), firstWeekday: 2)
        // The first column is the week of Monday 2025-10-06; November's first Monday is the 3rd, four columns on.
        #expect(map.months.first == UsageHeatmap.MonthMark(column: 0, month: 10))
        #expect(map.months[1] == UsageHeatmap.MonthMark(column: 4, month: 11))
        #expect(map.months.map(\.month) == [10, 11, 12, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        #expect(map.months.last == UsageHeatmap.MonthMark(column: 52, month: 10))
        for (a, b) in zip(map.months, map.months.dropFirst()) {
            #expect(b.column - a.column >= UsageHeatmap.monthLabelSpacing)
        }
        // A first column at the end of a month gives its label up to the month that follows.
        let tail = UsageStats().heatmap(weeks: 10, endingOn: day(2026, 10, 30), firstWeekday: 2)
        #expect(tail.weeks[0][0]?.date == day(2026, 8, 24))
        #expect(tail.months.map(\.month) == [9, 10])
        #expect(tail.months.first?.column == 2)
    }

    @Test func theFiguresBesideTheGridAreAboutTheDaysShown() {
        let today = day(2026, 10, 10)   // a Saturday
        // Four days in a row long ago, three in a row up to today, one on its own.
        let s = stats([day(2026, 3, 2): 1, day(2026, 3, 3): 2, day(2026, 3, 4): 1, day(2026, 3, 5): 1,
                       day(2026, 9, 20): 1, day(2026, 10, 8): 1, day(2026, 10, 9): 3, today: 2])
        // A year of columns shows all of it.
        let year = s.heatmap(weeks: 53, endingOn: today, firstWeekday: 2)
        #expect(year.activeDays == 8)
        #expect(year.longestStreak == 4)
        // Four columns do not reach March: the figures are about what is drawn, not about all time.
        let month = s.heatmap(weeks: 4, endingOn: today, firstWeekday: 2)
        #expect(month.cells.first?.date == day(2026, 9, 14))
        #expect(month.activeDays == 4)
        #expect(month.longestStreak == 3)
        #expect(s.longestStreak == 4)
        // A run goes on across a week's edge (Sunday 4th to Monday 5th, Monday first).
        let across = stats([day(2026, 10, 3): 1, day(2026, 10, 4): 1, day(2026, 10, 5): 1, day(2026, 10, 6): 1])
            .heatmap(weeks: 2, endingOn: today, firstWeekday: 2)
        #expect(across.longestStreak == 4)
        let empty = UsageStats().heatmap(weeks: 4, endingOn: today, firstWeekday: 2)
        #expect(empty.activeDays == 0 && empty.longestStreak == 0)
    }

    @Test func shadesFollowTheUsersOwnBusyDays() {
        #expect(UsageHeatmap.levels == 4)
        // A new user: one dictation is the lightest shade, four or more the strongest.
        #expect(UsageHeatmap.reference(for: []) == 4)
        #expect(UsageHeatmap.reference(for: [0, 0, 1]) == 4)
        #expect(UsageHeatmap.level(0, reference: 4) == 0)
        #expect(UsageHeatmap.level(1, reference: 4) == 1)
        #expect(UsageHeatmap.level(2, reference: 4) == 2)
        #expect(UsageHeatmap.level(3, reference: 4) == 3)
        #expect(UsageHeatmap.level(4, reference: 4) == 4)
        #expect(UsageHeatmap.level(40, reference: 4) == 4)
        // A regular user: the scale stretches to their busy days, and one extreme day does not flatten the rest.
        let values: [Double] = [2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 200]
        #expect(UsageHeatmap.reference(for: values) == 20)
        #expect(UsageHeatmap.level(5, reference: 20) == 1)
        #expect(UsageHeatmap.level(6, reference: 20) == 2)
        #expect(UsageHeatmap.level(15, reference: 20) == 3)
        #expect(UsageHeatmap.level(16, reference: 20) == 4)
        #expect(UsageHeatmap.level(200, reference: 20) == 4)

        let today = day(2026, 10, 10)
        let map = stats([today: 8, day(2026, 10, 9): 1, day(2026, 10, 8): 3]).heatmap(weeks: 2, endingOn: today, firstWeekday: 2)
        let levels = Dictionary(uniqueKeysWithValues: map.cells.map { ($0.date, $0.level) })
        #expect(levels[today] == 4)
        #expect(levels[day(2026, 10, 9)] == 1)
        #expect(levels[day(2026, 10, 8)] == 2)
        #expect(levels[day(2026, 10, 7)] == 0)
        // Shaded by 字数 instead.
        let byCharacters = stats([today: 8, day(2026, 10, 9): 1]).heatmap(weeks: 1, endingOn: today, firstWeekday: 2, metric: .characters)
        #expect(byCharacters.cells.last?.level == 4)
        #expect(byCharacters.cells.dropLast().last?.level == 1)
    }
}

@Suite struct TextCountTests {
    @Test func chineseCountsCharactersAndLatinCountsWords() {
        #expect(TextCount.characters("") == 0)
        #expect(TextCount.characters("明天下午三点开会。") == 8)
        #expect(TextCount.characters("The report is ready for review.") == 6)
        #expect(TextCount.characters("周五之前把 report 发给我，谢谢！") == 11)
        #expect(TextCount.characters("用SSH连接") == 4)
        #expect(TextCount.characters("こんにちは") == 5)
        #expect(TextCount.characters("한국어") == 3)
    }

    @Test func aWordWithMarksInsideIsOneWord() {
        #expect(TextCount.characters("don't") == 1)
        #expect(TextCount.characters("版本 3.5 发布") == 5)
        #expect(TextCount.characters("well-known file_name v2.0.1") == 3)
        #expect(TextCount.characters("a - b") == 2)
        #expect(TextCount.characters("一. 二") == 2)
        #expect(TextCount.characters("2026 年 10 月") == 4)
    }

    @Test func punctuationSpacesAndEmojiCountForNothing() {
        #expect(TextCount.characters("，。！？；：“”（）…—") == 0)
        #expect(TextCount.characters("  \n\t ") == 0)
        #expect(TextCount.characters("好的 👍") == 2)
        #expect(TextCount.characters("1. 第一点\n2. 第二点") == 8)
        #expect(TextCount.characters("... --- ...") == 0)
    }
}

@Suite struct UsageTextTests {
    private func words(_ parts: [UsageText.Part]) -> String { UsageText.plain(parts) }

    @Test func numbersAreGroupedAndLargeOnesUseWan() {
        #expect(words(UsageText.number(0)) == "0")
        #expect(words(UsageText.number(62)) == "62")
        #expect(words(UsageText.number(1_284)) == "1,284")
        #expect(words(UsageText.number(99_999)) == "99,999")
        #expect(words(UsageText.number(100_000)) == "10 万")
        #expect(words(UsageText.number(123_456)) == "12.3 万")
        #expect(words(UsageText.number(1_204, unit: "次")) == "1,204 次")
        #expect(words(UsageText.number(250_000, unit: "次")) == "25 万次")
        #expect(UsageText.number(1_204, unit: "次") == [.init("1,204"), .init("次", unit: true)])
    }

    @Test func lengthsOfSpeechReadAsTime() {
        #expect(words(UsageText.duration(0)) == "0 秒")
        #expect(words(UsageText.duration(11.7)) == "12 秒")
        #expect(words(UsageText.duration(59.4)) == "59 秒")
        #expect(words(UsageText.duration(59.6)) == "1 分钟")
        #expect(words(UsageText.duration(372)) == "6 分 12 秒")
        #expect(words(UsageText.duration(360)) == "6 分钟")
        #expect(words(UsageText.duration(3_900)) == "1 小时 5 分")
        #expect(words(UsageText.duration(7_200)) == "2 小时")
        #expect(words(UsageText.duration(128 * 3_600 + 1_800)) == "128 小时")
        #expect(words(UsageText.duration(-5)) == "0 秒")
        #expect(words(UsageText.duration(.nan)) == "0 秒")
        #expect(UsageText.duration(372).map(\.isUnit) == [false, true, false, true])
    }

    @Test func savedTimeIsRoundedTheWayOneSaysIt() {
        #expect(words(UsageText.saved(0)) == "0 分钟")
        #expect(words(UsageText.saved(20)) == "不到 1 分钟")
        #expect(words(UsageText.saved(60)) == "1 分钟")
        #expect(words(UsageText.saved(15 * 60 + 10)) == "15 分钟")
        #expect(words(UsageText.saved(59 * 60 + 40)) == "1 小时")
        #expect(words(UsageText.saved(3.2 * 3_600)) == "3.2 小时")
        #expect(words(UsageText.saved(12 * 3_600)) == "12 小时")
        #expect(words(UsageText.saved(1_234.4 * 3_600)) == "1,234 小时")
        #expect(UsageText.saved(20).map(\.isUnit) == [true, false, true])
    }

    @Test func oneRecordingsLength() {
        #expect(UsageText.recording(8.44) == "8.4 秒")
        #expect(UsageText.recording(45) == "45.0 秒")
        #expect(UsageText.recording(59.96) == "1 分 00 秒")
        #expect(UsageText.recording(65.2) == "1 分 05 秒")
        #expect(UsageText.recording(600) == "10 分 00 秒")
    }

    @Test func barLabelsStayShort() {
        #expect(UsageText.compact(12, metric: .count) == "12")
        // Written like the figures above the chart.
        #expect(UsageText.compact(1_284, metric: .characters) == "1,284")
        #expect(UsageText.compact(9_999, metric: .characters) == "9,999")
        #expect(UsageText.compact(12_345, metric: .characters) == "1.2万")
        // A length of speech, as a clock shows it: "6:12" under the tile's "6 分 12 秒".
        #expect(UsageText.compact(0, metric: .seconds) == "0:00")
        #expect(UsageText.compact(45.2, metric: .seconds) == "0:45")
        #expect(UsageText.compact(185, metric: .seconds) == "3:05")
        #expect(UsageText.compact(216, metric: .seconds) == "3:36")
        #expect(UsageText.compact(360, metric: .seconds) == "6:00")
        #expect(UsageText.compact(372, metric: .seconds) == "6:12")
        #expect(UsageText.compact(598, metric: .seconds) == "9:58")
        #expect(UsageText.compact(754, metric: .seconds) == "12:34")
        #expect(UsageText.compact(3_599.4, metric: .seconds) == "59:59")
        #expect(UsageText.compact(3_599.6, metric: .seconds) == "1小时")
        #expect(UsageText.compact(5_400, metric: .seconds) == "1.5小时")
    }

    @Test func speakingIsComparedWithTyping() {
        // 1,284 字 in 6 分 12 秒: 207 字 a minute, 3.5 times typing at 60.
        let day = UsageDay(count: 12, characters: 1_284, seconds: 372)
        #expect(UsageStats.speakingRate(day).map { Int($0.rounded()) } == 207)
        #expect(UsageText.pace(day) == ["每分钟 207 字 · 打字的 3.5 倍", "速度是打字的 3.5 倍", "每分钟 207 字"])
        // Twice as fast, said without a decimal.
        #expect(UsageText.pace(UsageDay(count: 1, characters: 120, seconds: 60)).first == "每分钟 120 字 · 打字的 2 倍")
        // No faster than typing: nothing to show off. Nothing said: nothing to measure.
        #expect(UsageText.pace(UsageDay(count: 1, characters: 60, seconds: 60)).isEmpty)
        #expect(UsageText.pace(UsageDay(count: 2, characters: 20, seconds: 45)).isEmpty)
        #expect(UsageStats.speakingRate(.zero) == nil)
        #expect(UsageStats.speakingRate(UsageDay(count: 1, characters: 4, seconds: 0.4)) == nil)
        #expect(UsageText.pace(.zero).isEmpty)
    }

    @Test func aDaySaysItsYearOnlyWhenItIsAnother() {
        #expect(UsageText.date(day(2026, 9, 11), asOf: day(2026, 10, 10)) == "9月11日")
        #expect(UsageText.date(day(2025, 11, 3), asOf: day(2026, 10, 10)) == "2025年11月3日")
    }

    @Test func amountsCarryTheirUnit() {
        #expect(words(UsageText.amount(39, metric: .count)) == "39 次")
        #expect(words(UsageText.amount(4_280, metric: .characters)) == "4,280 字")
        #expect(words(UsageText.amount(372, metric: .seconds)) == "6 分 12 秒")
        #expect(words(UsageText.amount(0, metric: .count)) == "0 次")
        #expect(UsageText.dailyAverage(39.0 / 7, metric: .count) == "日均 5.6 次")
        #expect(UsageText.dailyAverage(4, metric: .count) == "日均 4 次")
        #expect(UsageText.dailyAverage(611.4, metric: .characters) == "日均 611 字")
        #expect(UsageText.dailyAverage(1_234.6, metric: .characters) == "日均 1,235 字")
        #expect(UsageText.dailyAverage(107, metric: .seconds) == "日均 1 分 47 秒")
        #expect(UsageText.dailyAverage(0, metric: .seconds) == "日均 0 秒")
    }

    @Test func aListThatSpansDaysSaysTheDay() {
        let today = day(2026, 10, 10)
        #expect(TimeText.stamp(at(2026, 10, 10, 0, 53, in: shanghai), today: today, timeZone: shanghai) == "00:53")
        #expect(TimeText.stamp(at(2026, 10, 9, 23, 54, in: shanghai), today: today, timeZone: shanghai) == "昨天 23:54")
        #expect(TimeText.stamp(at(2026, 10, 4, 8, 5, in: shanghai), today: today, timeZone: shanghai) == "10月4日 08:05")
        // Across a new year the month and the day still say which day it was.
        #expect(TimeText.stamp(at(2025, 12, 31, 22, 10, in: shanghai), today: day(2026, 1, 1), timeZone: shanghai) == "昨天 22:10")
        #expect(TimeText.stamp(at(2025, 12, 28, 9, 0, in: shanghai), today: day(2026, 1, 3), timeZone: shanghai) == "12月28日 09:00")
    }

    @Test func aTimeFromBeforeMidnightSaysYesterdayOnceTheDayChanges() {
        // Dictated at 23:40 and left on screen: the same moment reads differently the next morning, and
        // the only thing that changed is the day the row is given.
        let dictated = at(2026, 10, 9, 23, 40, in: shanghai)
        #expect(TimeText.stamp(dictated, today: day(2026, 10, 9), timeZone: shanghai) == "23:40")
        #expect(TimeText.stamp(dictated, today: day(2026, 10, 10), timeZone: shanghai) == "昨天 23:40")
        #expect(TimeText.stamp(dictated, today: day(2026, 10, 11), timeZone: shanghai) == "10月9日 23:40")
    }

    @Test func aStampIsToldWhereTheUserIs() {
        // 23:40 in Shanghai is 10:40 the same morning in Chicago: there it is today's, on the 9th.
        let dictated = at(2026, 10, 9, 23, 40, in: shanghai)
        #expect(TimeText.stamp(dictated, today: day(2026, 10, 9), timeZone: chicago) == "10:40")
        // A clock set back, or a flight west: a day that has not come yet is said as a date, not as today.
        #expect(TimeText.stamp(dictated, today: day(2026, 10, 8), timeZone: shanghai) == "10月9日 23:40")
    }

    @Test func daysAreNamedInChinese() {
        #expect(UsageText.day(day(2026, 10, 8)) == "10月8日 周四")
        #expect(UsageText.day(day(2026, 10, 11)) == "10月11日 周日")
        #expect((1...7).map(UsageText.weekdayCharacter) == ["日", "一", "二", "三", "四", "五", "六"])
        #expect(UsageText.weekday(2) == "周一")
    }
}

@Suite struct UsageStoreFormatTests {
    private func withFolder(_ body: (URL) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neoless-usage-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func sample() -> UsageStats {
        var stats = UsageStats()
        stats.backfill(from: [], timeZone: shanghai)
        stats.add(characters: 120, seconds: 35.24, on: day(2026, 10, 10))
        stats.add(characters: 40, seconds: 0.1 + 0.2, on: day(2026, 10, 9))
        return stats
    }

    @Test func theFileIsSmallAndHoldsOnlyNumbers() throws {
        let data = try JSONEncoder().encode(sample())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["version", "backfilled", "days"])
        #expect(json["version"] as? Int == 1)
        #expect(json["backfilled"] as? Bool == true)
        let days = try #require(json["days"] as? [String: [String: Any]])
        #expect(Set(days.keys) == ["2026-10-10", "2026-10-09"])
        #expect(Set(days["2026-10-10"]!.keys) == ["count", "characters", "seconds"])
        #expect(days["2026-10-10"]?["count"] as? Int == 1)
        #expect(days["2026-10-10"]?["characters"] as? Int == 120)
        // Seconds to a tenth, without the tail a sum of doubles drags along.
        #expect(days["2026-10-10"]?["seconds"] as? Double == 35.2)
        #expect(days["2026-10-09"]?["seconds"] as? Double == 0.3)
        #expect(String(decoding: data, as: UTF8.self).contains("0.3,") || String(decoding: data, as: UTF8.self).contains("0.3}"))
    }

    @Test func aWrittenFileReadsBack() throws {
        try withFolder { dir in
            let store = DataFileStore(directory: dir)
            #expect(store.read(UsageStats.self, from: "usage.json") == nil)
            #expect(store.write(sample(), to: "usage.json"))
            let back = try #require(store.read(UsageStats.self, from: "usage.json"))
            #expect(back.backfilled)
            #expect(back[day(2026, 10, 10)] == UsageDay(count: 1, characters: 120, seconds: 35.2))
            #expect(back.total.count == 2)
            #expect(store.recovered.isEmpty)
            // Read, added to and written again: the same file, no backups.
            var next = back
            next.add(characters: 5, seconds: 2, on: day(2026, 10, 10))
            #expect(store.write(next, to: "usage.json"))
            #expect(store.read(UsageStats.self, from: "usage.json")?[day(2026, 10, 10)].count == 2)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["usage.json"])
        }
    }

    @Test func aHandWrittenFileInTheDocumentedShapeReads() throws {
        let json = #"{"version": 1, "backfilled": true, "days": {"2026-10-10": {"count": 3, "characters": 120, "seconds": 35.2}}}"#
        let stats = try JSONDecoder().decode(UsageStats.self, from: Data(json.utf8))
        #expect(stats[day(2026, 10, 10)] == UsageDay(count: 3, characters: 120, seconds: 35.2))
        #expect(stats.backfilled)
        // A key a later build adds is ignored; a missing `backfilled` means the file was already in use.
        let extra = #"{"version": 1, "days": {}, "note": "added later"}"#
        let read = try JSONDecoder().decode(UsageStats.self, from: Data(extra.utf8))
        #expect(read.backfilled && read.days.isEmpty)
        // Numbers that cannot be true are read as nothing.
        let odd = #"{"version": 1, "days": {"2026-10-10": {"count": -2, "characters": -9, "seconds": -1}}}"#
        #expect(try JSONDecoder().decode(UsageStats.self, from: Data(odd.utf8)).days.isEmpty)
    }

    @Test func aFileThisBuildCannotReadIsSetAsideNotOverwritten() throws {
        let unreadable = [
            #"{"version": 2, "days": {}}"#,                                                           // a newer format
            #"{"version": 0, "days": {}}"#,
            #"{"days": {}}"#,                                                                           // no version
            #"{"version": 1, "days": {"yesterday": {"count": 1, "characters": 1, "seconds": 1}}}"#,    // not a day
            #"{"version": 1, "days": {"2026-02-30": {"count": 1, "characters": 1, "seconds": 1}}}"#,
            #"{"version": 1, "days": [1, 2, 3]}"#,
            "not json",
        ]
        for text in unreadable {
            #expect(throws: (any Error).self, "\(text)") { _ = try JSONDecoder().decode(UsageStats.self, from: Data(text.utf8)) }
        }
        try withFolder { dir in
            let store = DataFileStore(directory: dir, now: { Date(timeIntervalSince1970: 1_791_398_700) })
            try Data(unreadable[0].utf8).write(to: store.url("usage.json"))
            #expect(store.read(UsageStats.self, from: "usage.json") == nil)
            let backup = try #require(store.recovered.first)
            #expect(DataFileBackup.isBackup(backup, of: "usage.json"))
            // The newer file is intact under its backup name, and a fresh one can be started beside it.
            #expect(try Data(contentsOf: store.url(backup)) == Data(unreadable[0].utf8))
            #expect(store.write(sample(), to: "usage.json"))
            #expect(try Data(contentsOf: store.url(backup)) == Data(unreadable[0].utf8))
        }
    }
}
