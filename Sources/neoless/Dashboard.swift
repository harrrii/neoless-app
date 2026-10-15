import AppKit
import NeolessCore
import SwiftUI

// 今日概览: how much neoless was used. Four figures, a bar chart of the last days, and the year as a grid
// of squares. The numbers come from `UsageStore`; nothing here knows what was said.

/// Sizes the page is laid out with. One grid for the whole page: every card ends on the same two edges, the
/// same gap lies between any two of them, and every card's content starts the same distance in.
enum Dash {
    /// The page's column, margins included: it goes on growing past the other pages' width
    /// (`PageMetrics.width`), because four figures and two cards side by side make use of the room.
    static let pageWidth: CGFloat = 1120
    /// A tile at least this wide gets larger numerals (a large window), so the figures stay the page's lead.
    static let wideTile: CGFloat = 220
    /// Between cards, across and down.
    static let gap = Space.l
    /// From a card's edge to its content. 今日概览's heading over the cards sits as far in.
    static let inset = Space.l
    /// From this content width on the page is laid out roomy: the four figures in one row, the chart beside
    /// 最近听写. Under it nothing is squeezed: the figures are two by two and the chart goes under 最近听写.
    static let roomy: CGFloat = 660
    /// The chart card when it is under 最近听写 (a narrow window).
    static let cardHeight: CGFloat = 320
    /// Side by side the two follow the window: a window with height to spare gets a taller chart and more
    /// of 最近听写 instead of a blank band. A shorter window keeps the least height, and the page scrolls.
    /// The least is what lets the whole page show in the window as it opens on a 13-inch display
    /// (`AppDelegate.openingSize`), with nothing of 过去一年 under the fold.
    static let cardHeights: ClosedRange<CGFloat> = 300...460
    /// From a card's top to the centre of its first line (a title, or the chart's controls): the same in
    /// every card, so the first lines of two cards side by side are one line.
    static let firstLine: CGFloat = 28
    /// Under the last card.
    static let bottomMargin = Space.xxxl
    /// The tallest bar gets what the chart card's controls, figures and labels leave, up to this.
    static let tallestBar: CGFloat = 260

    /// How tall the chart row is when the window has `room` for it and the margin under the page.
    static func fittedCardHeight(room: CGFloat) -> CGFloat {
        min(cardHeights.upperBound, max(cardHeights.lowerBound, (room - bottomMargin).rounded(.down)))
    }

    /// The margin under the page: `bottomMargin`, or what there is in a window a few points too short
    /// for it (which would otherwise scroll by those few points).
    static func fittedBottomMargin(room: CGFloat) -> CGFloat {
        let left = room - fittedCardHeight(room: room)
        return left >= Space.xs + 1 && left < bottomMargin ? left - 1 : bottomMargin
    }

    /// The width the cards have in a detail area `available` wide.
    static func contentWidth(in available: CGFloat) -> CGFloat {
        max(0, min(available, pageWidth) - 2 * PageMetrics.margin)
    }

    /// The chart's width when it sits beside 最近听写: half, so the gap between the two is the gap between
    /// the second and third figure above them, one grid of four columns down the page. Never too narrow
    /// for its controls.
    static func chartWidth(in content: CGFloat) -> CGFloat {
        max(300, ((content - gap) / 2).rounded())
    }

    /// Snapshots only: a bar, a day and a row drawn as if the pointer were on them. (The rows' times need
    /// no such hold: they are told from the store's own day, which a snapshot sets.)
    static var _debugHoveredBar: Int?
    static var _debugHoveredDay: UsageDate?
    static var _debugHoveredRow: UUID?
}

/// The days the chart shows.
enum ChartRange: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30

    var id: Int { rawValue }
    var title: String { self == .week ? "近 7 天" : "近 30 天" }
}

extension UsageMetric {
    var title: String {
        switch self {
        case .count: return "次数"
        case .characters: return "字数"
        case .seconds: return "时长"
        }
    }
}

/// The chart and 最近听写 (in that order): side by side with the chart on the left at `leadingWidth`, or,
/// in a narrow window, one above the other with 最近听写 on top.
struct OverviewPair: Layout {
    var sideBySide: Bool
    var leadingWidth: CGFloat
    var gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2, let width = proposal.width else {
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }
        let heights = heights(width, subviews)
        return CGSize(width: width, height: sideBySide ? max(heights.0, heights.1) : heights.0 + gap + heights.1)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if sideBySide {
            let trailing = max(0, bounds.width - leadingWidth - gap)
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: leadingWidth, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX + leadingWidth + gap, y: bounds.minY),
                              proposal: ProposedViewSize(width: trailing, height: nil))
        } else {
            let heights = heights(bounds.width, subviews)
            subviews[1].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + heights.1 + gap),
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }

    /// How tall each of the two is at the width it gets.
    private func heights(_ width: CGFloat, _ subviews: Subviews) -> (CGFloat, CGFloat) {
        let widths = sideBySide ? (leadingWidth, max(0, width - leadingWidth - gap)) : (width, width)
        return (subviews[0].sizeThatFits(ProposedViewSize(width: widths.0, height: nil)).height,
                subviews[1].sizeThatFits(ProposedViewSize(width: widths.1, height: nil)).height)
    }
}

// MARK: - Figures

/// A figure with its unit: the numerals large, the unit small and grey beside them ("6 分 12 秒"). One line;
/// it shrinks a little before it would be cut off.
struct StatFigure: View {
    let parts: [UsageText.Part]
    var size = Typo.statSize
    var unitSize = Typo.statUnitSize
    /// Nothing counted yet: the figure steps back.
    var dimmed = false

    var body: some View {
        text
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityLabel(UsageText.plain(parts))
    }

    private var text: Text {
        var line = Text("")
        for (i, part) in parts.enumerated() {
            if i > 0 { line = line + Text("\u{2009}").font(.system(size: unitSize)) }
            line = line + (part.isUnit
                // A unit never outweighs its figure: stepped back, it is as faint and lighter still.
                ? Text(part.text).font(.system(size: unitSize, weight: dimmed ? .regular : .medium))
                    .foregroundColor(dimmed ? Color(nsColor: .tertiaryLabelColor) : .secondary)
                // Proportional figures: tabular ones look loose at this size.
                : Text(part.text).font(.system(size: size, weight: .semibold))
                    .foregroundColor(dimmed ? Color(nsColor: .tertiaryLabelColor) : .primary))
        }
        return line
    }
}

/// One figure of the overview: what it is, the figure, and one quiet line under it, with room around them.
struct StatTile: View {
    let title: String
    let value: [UsageText.Part]
    /// The line under the figure, longest wording first: the first that fits the tile is shown.
    var detail: [String] = []
    var dimmed = false
    /// A wide tile (`Dash.wideTile`): the figure a size up.
    var large = false
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Typo.statLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            StatFigure(parts: value, size: large ? Typo.statSizeLarge : Typo.statSize,
                       unitSize: large ? Typo.statUnitSize + 1 : Typo.statUnitSize, dimmed: dimmed)
                .frame(height: large ? 44 : 40, alignment: .bottomLeading)
            ViewThatFits(in: .horizontal) {
                ForEach(detail.isEmpty ? [" "] : detail, id: \.self) { line in
                    Text(line).lineLimit(1)
                }
            }
            .font(Typo.statDetail)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
        .padding(.horizontal, Dash.inset)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }
}

/// 今日字数 · 今日说话 · 累计听写 · 累计省时. Under each figure, one line that says what it is worth: the
/// time today's text saved, how fast it was said against typing, since when 累计 counts, how the saving is
/// reckoned (always as an estimate).
/// Four in a row where there is room for each (`Dash.roomy`), two by two in a narrow window.
struct StatTiles: View {
    @EnvironmentObject var usage: UsageStore
    /// The width the four tiles share.
    let width: CGFloat

    var body: some View {
        let today = usage.stats[usage.today]
        let yesterday = usage.stats[usage.today.adding(days: -1)]
        let total = usage.stats.total
        let speed = Int(UsageStats.typingCharactersPerMinute)
        // 累计 counts from the first day there are numbers for, and the tooltips say which day that is.
        let since: String? = usage.stats.firstDay.map { "从 " + UsageText.date($0, asOf: usage.today) + "开始算" }
        let average: String = today.averageSeconds.map { "，平均每次 " + UsageText.plain(UsageText.duration($0)) } ?? ""
        let speakingHelp: String = "今天说话的时间加起来" + average + "。和打字比，是按每分钟打 \(speed) 个字算的。"
        let totalCharacters: String = UsageText.plain(UsageText.number(total.characters, unit: "字"))
        let totalSpoken: String = UsageText.plain(UsageText.duration(total.seconds))
        let totalHelp: String = since.map { $0 + "：一共 " + totalCharacters + "，说了 " + totalSpoken + "。" } ?? "从第一次听写开始算。"
        let savedHelp: String = "和打字相比省下的时间：按每分钟打 \(speed) 个字估算，再减去说话用的时间。" + (since.map { $0 + "。" } ?? "")
        let perRow = width >= Dash.roomy ? 4 : 2
        let large = (width - CGFloat(perRow - 1) * Dash.gap) / CGFloat(perRow) >= Dash.wideTile
        let tiles: [StatTile] = [
            StatTile(title: "今日字数", value: UsageText.number(today.characters),
                     detail: wordsDetail(today, yesterday: yesterday), dimmed: today.isEmpty, large: large,
                     help: "今天输入的字数：中文按字算，英文按词算。"),
            StatTile(title: "今日说话", value: UsageText.duration(today.seconds),
                     detail: speakingDetail(today, yesterday: yesterday), dimmed: today.isEmpty, large: large,
                     help: speakingHelp),
            StatTile(title: "累计听写", value: UsageText.number(total.count, unit: "次"),
                     detail: totalDetail(total), dimmed: total.isEmpty, large: large,
                     help: totalHelp),
            // Every wording says it is an estimate, however narrow the tile.
            StatTile(title: "累计省时", value: UsageText.saved(UsageStats.timeSaved(total)),
                     detail: ["按每分钟打 \(speed) 字估算", "每分钟 \(speed) 字估算", "估算值"],
                     dimmed: total.isEmpty, large: large, help: savedHelp),
        ]
        VStack(spacing: Dash.gap) {
            ForEach(Array(stride(from: 0, to: tiles.count, by: perRow)), id: \.self) { first in
                HStack(spacing: Dash.gap) {
                    ForEach(first..<min(first + perRow, tiles.count), id: \.self) { tiles[$0] }
                }
            }
        }
    }

    /// Under 今日字数: how many dictations, and the time they saved once that is a minute or more. Before the
    /// day's first one, what yesterday came to, so the tile is not a bare zero every morning (and with
    /// nothing yesterday either, words instead of a second zero).
    private func wordsDetail(_ today: UsageDay, yesterday: UsageDay) -> [String] {
        guard !today.isEmpty else {
            return [yesterday.isEmpty ? "今天还没听写" : "昨天 " + UsageText.plain(UsageText.number(yesterday.characters, unit: "字"))]
        }
        let count = "\(today.count) 次"
        let saved = UsageStats.timeSaved(today)
        return saved >= 60 ? ["\(count) · 约省 " + UsageText.plain(UsageText.saved(saved)), count] : [count]
    }

    /// Under 今日说话: how fast that was against typing; when it was no faster, the average length instead.
    private func speakingDetail(_ today: UsageDay, yesterday: UsageDay) -> [String] {
        guard !today.isEmpty else {
            return [yesterday.isEmpty ? "说一句就有了" : "昨天 " + UsageText.plain(UsageText.duration(yesterday.seconds))]
        }
        let pace = UsageText.pace(today)
        if !pace.isEmpty { return pace }
        return today.averageSeconds.map { ["平均每次 " + UsageText.plain(UsageText.duration($0))] } ?? []
    }

    /// Under 累计听写: since when it counts (the first day there are numbers for, which for a long-time
    /// user is where the history kept on this Mac begins), and the total 字数. The streak is with the days,
    /// in 过去一年: between two totals it read as "that many in so few days".
    private func totalDetail(_ total: UsageDay) -> [String] {
        guard !total.isEmpty else { return ["从第一次听写算起"] }
        let characters = "共 " + UsageText.plain(UsageText.number(total.characters, unit: "字"))
        guard let first = usage.stats.firstDay else { return [characters] }
        return [UsageText.date(first, asOf: usage.today) + "起 · " + characters, characters]
    }
}

// MARK: - Bar chart

/// 近 7 天 / 近 30 天, by 次数, 字数 or 时长: one bar a day, today's in the accent colour.
struct UsageChartCard: View {
    @EnvironmentObject var usage: UsageStore
    @EnvironmentObject var router: Router
    /// The card's height. The bars take what the controls and figures leave, so a taller card is a taller chart.
    var height: CGFloat = Dash.cardHeight
    @State private var hovered: Int?

    /// Everything in the card but the bars: its insets, the controls, the figures, and the labels over and
    /// under the bars, with a few points to spare.
    private static let chrome: CGFloat = 176
    private static let controlsHeight: CGFloat = 24

    var body: some View {
        let range = router.chartRange, metric = router.chartMetric
        let points = usage.stats.series(days: range.rawValue, endingOn: usage.today)
        let summary = usage.stats.summary(metric, of: points)
        let pointed = (Dash._debugHoveredBar ?? hovered).flatMap { points.indices.contains($0) ? $0 : nil }
        Surface {
            VStack(alignment: .leading, spacing: 0) {
                controls
                HStack(alignment: .top, spacing: Space.xs) {
                    VStack(alignment: .leading, spacing: 2) {
                        // A clear step under the tiles' figures (30).
                        StatFigure(parts: UsageText.amount(summary.total, metric: metric), size: 24, unitSize: 13,
                                   dimmed: summary.total == 0)
                            .frame(height: 30, alignment: .bottomLeading)
                        // Nothing in these days: no average of nothing.
                        Text(summary.total > 0 ? UsageText.dailyAverage(summary.dailyAverage, metric: metric) : " ")
                            .font(Typo.statDetail)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Space.xs)
                    // The bar under the pointer, spelled out: the day and its amount.
                    if let pointed {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(UsageText.day(points[pointed].date))
                            Text(points[pointed].usage.isEmpty ? "没有听写"
                                 : UsageText.plain(UsageText.amount(metric.value(of: points[pointed].usage), metric: metric)))
                                .foregroundStyle(.primary)
                        }
                        .font(Typo.statDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                    }
                }
                .padding(.top, Space.m)
                Spacer(minLength: Space.s)
                BarPlot(points: points, metric: metric, today: usage.today, pointed: pointed, hovered: $hovered,
                        barsHeight: min(Dash.tallestBar, max(48, height - Self.chrome)), emptyHint: emptyHint(range))
            }
            // The controls' centre is 28pt under the card's top: the line 最近听写 and 过去一年 have their titles on.
            .padding(.horizontal, Dash.inset)
            .padding(.top, Dash.firstLine - Self.controlsHeight / 2)
            .padding(.bottom, Dash.inset)
            .frame(height: height, alignment: .top)
        }
    }

    /// Which days, and what is counted: full-size controls where the card is wide enough for both, small
    /// ones beside 最近听写 in a narrow window. The row is the same height either way.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            pickers.controlSize(.regular)
            pickers.controlSize(.small)
        }
        .frame(height: Self.controlsHeight)
    }

    private var pickers: some View {
        HStack(spacing: Space.xs) {
            Picker("时间范围", selection: $router.chartRange) {
                ForEach(ChartRange.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Spacer(minLength: Space.s)
            Picker("统计内容", selection: $router.chartMetric) {
                ForEach(UsageMetric.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// Said where the bars would be when these days have none; for a new user, what will be drawn there.
    private func emptyHint(_ range: ChartRange) -> String? {
        usage.stats.days.isEmpty ? "每天的听写量会显示在这里" : "\(range.title)没有听写"
    }
}

/// The bars: one slot a day, oldest on the left. Seven days are all labelled with their value; thirty
/// label the busiest day and today, and the rest answer to the pointer.
private struct BarPlot: View {
    let points: [UsagePoint]
    let metric: UsageMetric
    let today: UsageDate
    let pointed: Int?
    @Binding var hovered: Int?
    /// How tall the busiest day's bar is.
    let barsHeight: CGFloat
    let emptyHint: String?

    private static let valueHeight: CGFloat = 16
    private static let axisHeight: CGFloat = 20

    var body: some View {
        let values = points.map { metric.value(of: $0.usage) }
        let peak = values.max() ?? 0
        let labelled = labelledBars(values, peak: peak)
        GeometryReader { geo in
            let slot = geo.size.width / CGFloat(max(1, points.count))
            // Bars are never thicker than this, however few there are: the rest of the slot is air. A
            // taller chart has thicker bars, so they keep their proportions.
            let widest = max(24, (barsHeight / 5).rounded())
            let bar = min(widest, max(3, (slot * 0.62).rounded()))
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(points.enumerated()), id: \.element.id) { i, point in
                    let value = values[i]
                    let isToday = point.date == today
                    // A label wider than its slot (a month's bars are thin) stays inside the plot at both ends.
                    let anchor: Alignment = i == 0 ? .leading : (i == points.count - 1 ? .trailing : .center)
                    VStack(spacing: 0) {
                        Text(labelled.contains(i) ? UsageText.compact(value, metric: metric) : " ")
                            .font(Typo.chartLabel)
                            .foregroundStyle(isToday || pointed == i ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.chartLabel))
                            .fixedSize()
                            .frame(width: slot, alignment: slot < 28 ? anchor : .center)
                            .frame(height: Self.valueHeight, alignment: .top)
                        ZStack(alignment: .bottom) {
                            Color.clear
                            if value > 0 {
                                // Rounded where the value ends, square on the baseline.
                                UnevenRoundedRectangle(topLeadingRadius: min(4, bar / 2), topTrailingRadius: min(4, bar / 2))
                                    .fill(isToday ? Theme.accent : (pointed == i ? Theme.chartBarHover : Theme.chartBar))
                                    .frame(width: bar, height: max(2, barsHeight * value / peak))
                            } else {
                                // A day without dictation keeps its place: a faint stub on the baseline.
                                UnevenRoundedRectangle(topLeadingRadius: 1, topTrailingRadius: 1)
                                    .fill(Theme.chartEmpty)
                                    .frame(width: bar, height: 2)
                            }
                        }
                        .frame(height: barsHeight)
                        Text(axisLabel(i, point.date) ?? " ")
                            .font(Typo.chartLabel)
                            .fontWeight(isToday ? .medium : .regular)
                            .foregroundStyle(isToday ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.chartLabel))
                            .fixedSize()
                            .frame(width: slot, alignment: slot < 28 ? anchor : .center)
                            .frame(height: Self.axisHeight, alignment: .bottom)
                    }
                    .frame(width: slot)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(UsageText.day(point.date))
                    .accessibilityValue(UsageText.plain(UsageText.amount(value, metric: metric)))
                }
            }
            // The day under the pointer: a soft band behind its slot, so a day without a bar shows too.
            .background(alignment: .topLeading) {
                if let pointed {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Theme.fill)
                        .frame(width: slot, height: Self.valueHeight + barsHeight)
                        .offset(x: CGFloat(pointed) * slot)
                }
            }
            // The baseline every bar grows from.
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.separator).frame(height: 0.5)
                    .offset(y: Self.valueHeight + barsHeight)
            }
            .overlay(alignment: .top) {
                if peak == 0, let emptyHint {
                    Text(emptyHint)
                        .font(Typo.statDetail)
                        .foregroundStyle(.secondary)
                        .frame(height: barsHeight)
                        .offset(y: Self.valueHeight - Space.xs)
                }
            }
            // The whole slot answers to the pointer, not just the bar.
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let i = min(points.count - 1, max(0, Int(location.x / max(1, slot))))
                    if hovered != i { hovered = i }
                case .ended:
                    hovered = nil
                }
            }
        }
        .frame(height: Self.valueHeight + barsHeight + Self.axisHeight)
    }

    /// Which bars carry their value. Every one of a week. Of a month (thirty numbers in a row would be read
    /// by nobody, and each is wider than its bar): the busiest day and today; only the busiest when the two
    /// are so close their numbers would run together (今天 under the axis still says which bar is today's);
    /// and only the bar under the pointer while there is one, since the line above spells that day out.
    private func labelledBars(_ values: [Double], peak: Double) -> Set<Int> {
        guard peak > 0, let last = values.indices.last else { return [] }
        if values.count <= 7 { return Set(values.indices.filter { values[$0] > 0 }) }
        if let pointed { return values[pointed] > 0 ? [pointed] : [] }
        if values[last] == peak { return [last] }
        guard let busiest = values.firstIndex(of: peak) else { return [] }
        return busiest >= values.count - 5 || values[last] == 0 ? [busiest] : [busiest, last]
    }

    /// Under a week's bars: the weekday, and 今天. Under a month's: a date every seventh day back from today.
    private func axisLabel(_ i: Int, _ date: UsageDate) -> String? {
        if date == today { return "今天" }
        if points.count <= 7 { return UsageText.weekdayCharacter(date.weekday) }
        return (points.count - 1 - i) % 7 == 0 ? "\(date.month)/\(date.day)" : nil
    }
}

// MARK: - Year

/// 过去一年: a square a day, a column a week, ending with this week. The more dictations that day, the
/// stronger the accent. The narrower the window, the fewer weeks, so the squares stay a size one can point
/// at; the card's title then says how many months are drawn.
struct HeatmapCard: View {
    @EnvironmentObject var usage: UsageStore
    @Environment(\.colorScheme) private var scheme
    /// The card's width.
    let width: CGFloat
    @State private var hovered: UsageDate?

    /// The least room the weekday names get; what the columns do not use is added to it.
    private static let weekdayWidth: CGFloat = 32
    private static let monthHeight: CGFloat = 18
    private static let maxWeeks = 53
    /// From this many columns on, the grid is a year.
    private static let yearWeeks = 52
    /// Today's ring is drawn just outside its square, in the last column: this much past the grid is drawn too.
    private static let ringRoom: CGFloat = 2

    var body: some View {
        let inner = width - 2 * Dash.inset
        let fit = Self.fit(inner - Self.weekdayWidth)
        let map = usage.stats.heatmap(weeks: fit.weeks, endingOn: usage.today, firstWeekday: usage.firstWeekday)
        let ramp = Theme.heatRamp(dark: scheme == .dark)
        let pointed = (Dash._debugHoveredDay ?? hovered).flatMap { day in map.cells.first { $0.date == day } }
        let title = Self.title(weeks: fit.weeks)
        Surface {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(title).font(Typo.cardTitle).foregroundStyle(.primary)
                    Spacer(minLength: Space.xs)
                    // The day under the pointer, else the summary in the longest wording that fits beside the scale.
                    let lines = pointed.map { [readout($0)] } ?? summaries(map)
                    ViewThatFits(in: .horizontal) {
                        ForEach(lines, id: \.self) { line in
                            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                                Text(line).lineLimit(1)
                                legend(ramp)
                            }
                        }
                        Text(lines.last ?? "").lineLimit(1)
                        legend(ramp)
                    }
                    .font(Typo.statDetail)
                    .foregroundStyle(.secondary)
                }
                grid(map, fit: fit, width: inner, ramp: ramp, pointed: pointed?.date)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title)
                    .accessibilityValue(summaries(map).first ?? "")
            }
            .padding(.horizontal, Dash.inset)
            // The title's centre on `Dash.firstLine`.
            .padding(.top, Dash.firstLine - 9)
            .padding(.bottom, Dash.inset)
        }
    }

    /// What the grid covers, said as it is drawn: a year from 52 columns on, else the months that fit.
    static func title(weeks: Int) -> String {
        weeks >= yearWeeks ? "过去一年" : "近 \(max(1, Int((Double(weeks) * 7 / 30.4).rounded()))) 个月"
    }

    /// How many weeks to draw in `width`, and how large a square with its gap is: up to a year of columns,
    /// each at least 11pt wide, in half points so every square lands on whole pixels at 2x. Of the counts
    /// that fit, the one that leaves the least width unused (a few weeks fewer can fill the card better),
    /// but a year stays a year.
    static func fit(_ width: CGFloat) -> (weeks: Int, pitch: CGFloat, gap: CGFloat) {
        let minPitch: CGFloat = 11, maxPitch: CGFloat = 18
        func gap(_ pitch: CGFloat) -> CGFloat { pitch >= 13 ? 3 : 2.5 }
        /// The largest square (with its gap) at which `weeks` columns fit.
        func pitch(_ weeks: Int) -> CGFloat {
            let roomy = ((width + 3) / CGFloat(weeks) * 2).rounded(.down) / 2
            let fitted = roomy >= 13 ? roomy : ((width + 2.5) / CGFloat(weeks) * 2).rounded(.down) / 2
            return max(minPitch, min(maxPitch, fitted))
        }
        let most = max(4, min(maxWeeks, Int((width + 2.5) / minPitch)))
        let fewest = most >= yearWeeks ? yearWeeks : max(4, most - 3)
        var best = (weeks: most, pitch: pitch(most), gap: gap(pitch(most)))
        var unused = CGFloat.infinity
        for weeks in stride(from: most, through: fewest, by: -1) {
            let size = pitch(weeks)
            let left = width - (CGFloat(weeks) * size - gap(size))
            if left >= 0, left < unused - 0.01 {
                best = (weeks, size, gap(size))
                unused = left
            }
        }
        return best
    }

    /// What the grid adds up to, longest wording first: the run of days still going (once it is two or
    /// more), the longest run, the days in use. The last two are about the days drawn, so they do not
    /// change meaning with the window's width; a run still going that is the longest is said once.
    private func summaries(_ map: UsageHeatmap) -> [String] {
        let active = map.activeDays
        guard active > 0 else { return ["还没有记录"] }
        let used = "用了 \(active) 天"
        let longest = map.longestStreak
        guard longest >= 2 else { return [used] }
        let short = "\(used) · 最长连续 \(longest) 天"
        let streak = usage.stats.streak(asOf: usage.today)
        guard streak >= 2 else { return [short, used] }
        // A run as long as the days drawn or longer (a narrow window draws a few months): only the run is said, not
        // a count of days that is smaller than it.
        if streak >= map.cells.count { return ["已连续 \(streak) 天"] }
        if streak >= longest { return ["已连续 \(streak) 天 · \(used)", used] }
        return ["已连续 \(streak) 天 · 最长 \(longest) 天 · \(used)", short, used]
    }

    private func readout(_ cell: UsageHeatmap.Cell) -> String {
        let day = UsageText.day(cell.date)
        guard !cell.usage.isEmpty else { return "\(day) · 没有听写" }
        return "\(day) · \(cell.usage.count) 次 · " + UsageText.plain(UsageText.number(cell.usage.characters, unit: "字"))
    }

    /// The scale, lightest to strongest.
    private func legend(_ ramp: [Color]) -> some View {
        HStack(spacing: 3) {
            Text("少").padding(.trailing, 2)
            ForEach(ramp.indices, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(ramp[level]).frame(width: 10, height: 10)
            }
            Text("多").padding(.leading, 2)
        }
        .accessibilityHidden(true)
    }

    /// The grid, `width` wide: the columns end on the card's right inset, under the legend, and the weekday
    /// names start on its left inset, under the title. Whatever width the columns do not use lies between
    /// the two.
    private func grid(_ map: UsageHeatmap, fit: (weeks: Int, pitch: CGFloat, gap: CGFloat), width: CGFloat, ramp: [Color],
                      pointed: UsageDate?) -> some View {
        let pitch = fit.pitch, cell = fit.pitch - fit.gap
        let size = CGSize(width: width, height: Self.monthHeight + 7 * pitch - fit.gap)
        // Where the first column starts, on a half point.
        let left = max(Self.weekdayWidth, ((width - (CGFloat(map.weeks.count) * pitch - fit.gap)) * 2).rounded(.down) / 2)
        let today = map.today
        return Canvas { context, _ in
            func label(_ text: String) -> GraphicsContext.ResolvedText {
                context.resolve(Text(text).font(Typo.chartLabel).foregroundColor(Theme.chartLabel))
            }
            // Months along the top, over the column their first week starts in.
            for mark in map.months {
                let text = label("\(mark.month)月")
                let x = left + CGFloat(mark.column) * pitch
                context.draw(text, at: CGPoint(x: min(x, size.width - text.measure(in: size).width), y: 0), anchor: .topLeading)
            }
            // Every other weekday down the side: 周一, 周三, 周五.
            for row in 0..<7 where [2, 4, 6].contains(map.weekday(row: row)) {
                context.draw(label(UsageText.weekday(map.weekday(row: row))),
                             at: CGPoint(x: 0, y: Self.monthHeight + CGFloat(row) * pitch + cell / 2), anchor: .leading)
            }
            for (column, week) in map.weeks.enumerated() {
                for (row, day) in week.enumerated() {
                    guard let day else { continue }
                    let rect = CGRect(x: left + CGFloat(column) * pitch, y: Self.monthHeight + CGFloat(row) * pitch,
                                      width: cell, height: cell)
                    let square = Path(roundedRect: rect, cornerRadius: min(3, cell * 0.25), style: .continuous)
                    context.fill(square, with: .color(ramp[min(day.level, ramp.count - 1)]))
                    // Today wears a thin ring; the day under the pointer a quieter one.
                    if day.date == today || day.date == pointed {
                        let ring = Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: min(3, cell * 0.25) + 1, style: .continuous)
                        context.stroke(ring, with: .color(Theme.heatRing.opacity(day.date == today ? 1 : 0.55)), lineWidth: 1)
                    }
                }
            }
        }
        // Room for today's ring past the last column and the last row, without moving anything around it.
        .frame(width: size.width + Self.ringRoom, height: size.height + Self.ringRoom, alignment: .topLeading)
        .padding(.trailing, -Self.ringRoom)
        .padding(.bottom, -Self.ringRoom)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let column = Int((location.x - left) / pitch), row = Int((location.y - Self.monthHeight) / pitch)
                let day = location.x >= left && location.y >= Self.monthHeight
                    && map.weeks.indices.contains(column) && (0..<7).contains(row) ? map.weeks[column][row]?.date : nil
                if hovered != day { hovered = day }
            case .ended:
                hovered = nil
            }
        }
    }
}
