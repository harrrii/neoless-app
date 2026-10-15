import AppKit
import Combine
import NeolessCore
import SwiftUI

// MARK: - Tokens

/// Neutral, system-native palette: the user's macOS accent colour for actions and selection,
/// greys for everything else, and system orange only for things that need attention. Nothing is
/// tinted; the window and the HUD look like they ship with macOS.
enum Theme {
    /// The system accent (blue unless the user picked another in System Settings): links,
    /// text buttons, focus rings and the record button, like first-party apps.
    static let accent = Color(nsColor: .controlAccentColor)

    /// App-icon tile, matching the shipped icon (Resources/icon, the blue variant): white fading to
    /// a cool light grey. In dark appearance the mark sits on a graphite tile instead, so it is not
    /// the brightest thing in the window.
    static let brandTile = dynamic(light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                                   dark: NSColor(srgbRed: 0.173, green: 0.173, blue: 0.180, alpha: 1))
    static let brandTileShade = dynamic(light: NSColor(srgbRed: 0.914, green: 0.929, blue: 0.953, alpha: 1),
                                        dark: NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1))
    /// The icon's system-blue sound wave, lighter at the top (#40A2FF to #0A78F5).
    static let brandInk = Color(red: 0.251, green: 0.635, blue: 1.0)
    static let brandInkShade = Color(red: 0.039, green: 0.471, blue: 0.961)
    static let brandRim = dynamic(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.10))

    /// The HUD capsule: opaque pure black with a 1pt rim of white at 32 %,
    /// the same in light and dark appearance (it floats over any desktop, not over our window).
    static let hud = Color(.sRGB, white: 0, opacity: 1)
    static let hudRim = Color(.sRGB, white: 1, opacity: 0.32)
    /// × on the capsule: a dark grey disc (rgb 66, 66, 66), a little lighter under the pointer.
    static let hudButton = Color(.sRGB, red: 66 / 255, green: 66 / 255, blue: 66 / 255)
    static let hudButtonHover = Color(.sRGB, red: 84 / 255, green: 84 / 255, blue: 84 / 255)
    /// Ink on the white ✓ disc and on the done glyph.
    static let hudInk = Color(.sRGB, white: 0, opacity: 1)
    /// A warm white, the base of the capsule's quieter whites.
    static let hudWarm = Color(.sRGB, red: 242 / 255, green: 241 / 255, blue: 240 / 255)
    /// 识别中 / 整理中: the warm white at half strength, with a faint glint (30 %, laid over the
    /// word, not replacing it) passing across.
    static let hudThinking = hudWarm.opacity(0.5)
    static let hudThinkingHighlight = hudWarm.opacity(0.30)
    /// The fill behind 识别中 / 整理中 as the work progresses: faint, so the capsule stays near-black
    /// (about #1D1D1D where it has passed) and the word keeps its contrast.
    static let hudFill = hudWarm.opacity(0.12)
    /// The soft light crossing the starting pill: the warm white at 25 %, blurred.
    static let hudGlint = hudWarm.opacity(0.25)
    /// Tooltips over the capsule's buttons: near-black with warm white text.
    static let hudTooltip = Color(.sRGB, red: 29 / 255, green: 26 / 255, blue: 26 / 255)
    /// Amber glyph on the black capsule for a degraded result (system orange, dark variant).
    static let warning = Color(red: 1.0, green: 0.624, blue: 0.039)
    /// Red glyph on the black capsule for a blocking failure (system red, dark variant #FF453A).
    static let failure = Color(red: 1.0, green: 0.271, blue: 0.227)
    /// Recording, as in Voice Memos: system red for the stop button and the live level meter.
    static let recording = Color(nsColor: .systemRed)

    /// Detail-area background: a quiet grey so white groups read as surfaces.
    static let page = dynamic(light: NSColor(white: 0.962, alpha: 1), dark: NSColor(white: 0.118, alpha: 1))
    /// Grouped-section surface.
    static let surface = dynamic(light: .white, dark: NSColor(white: 0.172, alpha: 1))
    /// Hairline around surfaces.
    static let hairline = dynamic(light: NSColor(white: 0, alpha: 0.075), dark: NSColor(white: 1, alpha: 0.075))
    /// Row separators inside a surface.
    static let separator = dynamic(light: NSColor(white: 0, alpha: 0.085), dark: NSColor(white: 1, alpha: 0.085))
    /// Soft fill for chips, quiet buttons and inset wells.
    static let fill = dynamic(light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.07))
    /// Selected row in custom lists, as NSTableView draws it: the accent with white text while the
    /// window is key, the unemphasised grey otherwise.
    static let selection = Color(nsColor: .selectedContentBackgroundColor)
    static let selectionInactive = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    /// Quiet neutral fill for the idle record button (quaternary system fill).
    static let quietFill = dynamic(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.08))
    /// Push buttons: white with a hairline in light, #3A3A3C with a hairline in dark.
    static let pushFill = dynamic(light: .white, dark: NSColor(srgbRed: 0.227, green: 0.227, blue: 0.235, alpha: 1))
    static let pushFillPressed = dynamic(light: NSColor(white: 0.93, alpha: 1), dark: NSColor(srgbRed: 0.28, green: 0.28, blue: 0.29, alpha: 1))
    static let pushBorder = dynamic(light: NSColor(white: 0, alpha: 0.14), dark: NSColor(white: 1, alpha: 0.10))
    /// Small accent badge text (自动): darker blue on light, lighter blue on dark, both >= 4.5:1 on the tint.
    static let badgeText = dynamic(light: NSColor(srgbRed: 0.0, green: 0.40, blue: 0.85, alpha: 1),
                                   dark: NSColor(srgbRed: 0.392, green: 0.659, blue: 1.0, alpha: 1))
    static let badgeFill = dynamic(light: NSColor(srgbRed: 0.0, green: 0.478, blue: 1.0, alpha: 0.10),
                                   dark: NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 0.20))

    /// Amber text and glyphs for degraded results (typed the original, login expired, failures).
    static let caution = dynamic(light: NSColor(srgbRed: 0.80, green: 0.46, blue: 0.04, alpha: 1),
                                 dark: NSColor(srgbRed: 1.0, green: 0.72, blue: 0.36, alpha: 1))

    /// Row icons: plain SF Symbols in secondary label, no tile.
    static let tileGlyph = Color(nsColor: .secondaryLabelColor)
    /// Status only: a small orange dot on something that still needs attention …
    static let attention = Color(nsColor: .systemOrange)
    /// … and system green for "working / granted".
    static let ready = Color(nsColor: .systemGreen)

    // 今日概览. One hue (the accent) for what the user did, greys for everything around it.

    /// The chart's bars for the days before today: a quiet neutral, so today's accent bar is the one that
    /// stands out. Below 3:1 on the card on purpose; the bars carry their values as labels.
    static let chartBar = dynamic(light: NSColor(white: 0, alpha: 0.32), dark: NSColor(white: 1, alpha: 0.30))
    /// The same bar under the pointer.
    static let chartBarHover = dynamic(light: NSColor(white: 0, alpha: 0.46), dark: NSColor(white: 1, alpha: 0.46))
    /// A day without dictation: the chart's stub on the baseline and 过去一年's empty square.
    static let chartEmpty = dynamic(light: emptyDay(dark: false), dark: emptyDay(dark: true))
    private static func emptyDay(dark: Bool) -> NSColor {
        dark ? NSColor(white: 1, alpha: 0.085) : NSColor(white: 0, alpha: 0.065)
    }
    /// The thin ring around today (and, fainter, the day under the pointer) in 过去一年.
    static let heatRing = dynamic(light: NSColor(white: 0, alpha: 0.42), dark: NSColor(white: 1, alpha: 0.5))
    /// Axis, month and value labels: small, so secondary rather than tertiary.
    static let chartLabel = Color(nsColor: .secondaryLabelColor)

    /// 过去一年's shades, lightest to strongest, after the empty square: the accent at 55 %, 76 % and 97 %
    /// over the card, then the accent pushed a fifth further away from the card (towards black in light
    /// appearance, towards white in dark). More is always further from the card, in both appearances.
    /// With the default blue the steps are at least 0.06 apart in OKLCH lightness and the lightest clears
    /// 2:1 on the card (checked with the dataviz validator, light and dark).
    static let heatSteps: [CGFloat] = [0.55, 0.76, 0.97, 1.2]

    /// `chartEmpty` followed by the `heatSteps` shades of the system accent, for one appearance. Plain
    /// sRGB colours, so a `Canvas` draws them as they are.
    static func heatRamp(dark: Bool) -> [Color] {
        var accent = NSColor.systemBlue
        (NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? accent
        }
        // The card is `surface`: white, or the raised dark grey.
        let card = dark ? NSColor(srgbRed: 0.172, green: 0.172, blue: 0.172, alpha: 1) : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let far = dark ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        return [Color(nsColor: emptyDay(dark: dark))] + heatSteps.map { step in
            let shade = step <= 1 ? card.blended(withFraction: step, of: accent) : accent.blended(withFraction: step - 1, of: far)
            return Color(nsColor: shade ?? accent)
        }
    }

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// 4pt-based spacing scale. Everything in the main window snaps to these.
enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 40
}

/// Type ramp. Body text is the macOS 13pt; titles step up in clear jumps.
enum Typo {
    /// macOS title scale (22pt bold), not the iOS large title.
    static let pageTitle = Font.system(size: 22, weight: .bold)
    static let pageSubtitle = Font.system(size: 13)
    static let headline = Font.system(size: 17, weight: .semibold)
    static let sectionHeader = Font.system(size: 13, weight: .semibold)
    static let rowTitle = Font.system(size: 13)
    static let rowDetail = Font.system(size: 11)
    static let reading = Font.system(size: 15)
    /// Home hero headline: a step above the other pages' titles, with the round button beside it.
    static let heroSize: CGFloat = 26
    /// The line under the hero headline.
    static let heroSubtitle = Font.system(size: 14)
    /// The latest result in 最近听写: the reading size, a step above the 13pt rows under it.
    static let resultSize: CGFloat = 15
    static let caption = Font.system(size: 11)
    /// 今日概览's figures: large numerals, their unit small beside them (the same face as everything else).
    static let statSize: CGFloat = 30
    static let statUnitSize: CGFloat = 14
    /// The figures in a wide tile (a large window).
    static let statSizeLarge: CGFloat = 34
    /// What a figure is, over it, and the quiet line under it.
    static let statLabel = Font.system(size: 13)
    static let statDetail = Font.system(size: 12)
    /// 今日概览's own heading: the size of "neoless" in the sidebar, a clear step between the headline (26)
    /// and the titles of the cards under it (15).
    static let overviewTitle = Font.system(size: 20, weight: .semibold)
    static let cardTitle = Font.system(size: 15, weight: .semibold)
    /// Axis, month and value labels in the charts.
    static let chartLabel = Font.system(size: 11)
}

enum Radius {
    /// Cards and tiles: they are a hundred points tall and more, with 20pt insets.
    static let surface: CGFloat = 12
    static let tile: CGFloat = 6
    static let control: CGFloat = 7
    /// Editable text well inside a card.
    static let field: CGFloat = 8
}

// MARK: - Page scaffold

/// The frame every page is set in, so a page's title and cards start on the same lines whichever page is
/// showing.
enum PageMetrics {
    /// From the top of the detail area (under the title bar) to the page's first line.
    static let top = Space.s
    /// On each side of a page's column.
    static let margin: CGFloat = 48
    /// A page's column, margins included: as wide as the detail area of the window as it opens, so every
    /// page there starts and ends on the same two lines. 今日概览 and 历史记录 go on growing with a wider
    /// window (`Dash.pageWidth`); pages of settings stop here, so a row's switch stays near its title.
    static let width: CGFloat = 900
}

/// Scrolling (or fixed) page body: generous margins and a centred column.
struct PageColumn<Content: View>: View {
    var scrolls = true
    /// The column's width, margins included.
    var width: CGFloat = PageMetrics.width
    /// The margin on each side of the column.
    var margin: CGFloat = PageMetrics.margin
    var spacing: CGFloat = Space.xl
    /// Under the last section of a page that scrolls.
    var bottomPadding: CGFloat = Space.xxxl
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if scrolls {
                ScrollView {
                    column.padding(.bottom, bottomPadding)
                }
            } else {
                column.padding(.bottom, Space.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.page.ignoresSafeArea())
        // Plain `Button`s on every page draw as push buttons; explicit styles still win.
        .buttonStyle(.pushButton)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(.horizontal, margin)
        .padding(.top, PageMetrics.top)
        .frame(maxWidth: width, maxHeight: scrolls ? nil : .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
    }
}

/// A page with a large title and one-line subtitle; trailing controls sit centred on the title block.
struct PageScaffold<Accessory: View, Content: View>: View {
    let title: String
    var subtitle: String?
    var scrolls = true
    /// The column's width, margins included.
    var width: CGFloat = PageMetrics.width
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        PageColumn(scrolls: scrolls, width: width) {
            header
            content
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs - 2) {
                Text(title)
                    .font(Typo.pageTitle)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(Typo.pageSubtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }
            }
            Spacer(minLength: Space.m)
            accessory
        }
        .padding(.bottom, Space.xxs)
    }
}

extension PageScaffold where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, scrolls: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, scrolls: scrolls, accessory: { EmptyView() }, content: content)
    }
}

// MARK: - Grouped sections

/// System Settings style inset group: optional header and footer around a rounded surface.
struct GroupSection<Trailing: View, Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if title != nil || Trailing.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title).font(Typo.sectionHeader).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Space.xs)
                    trailing.font(Typo.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, Space.m)
            }
            Surface { content }
            if let footer {
                // A footer that wraps does not end on a lonely word.
                BalancedWrap {
                    Text(Words.keepQuotes(footer))
                        .font(Typo.caption)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.m)
            }
        }
    }
}

extension GroupSection where Trailing == EmptyView {
    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, footer: footer, trailing: { EmptyView() }, content: content)
    }
}

/// White (or raised dark) rounded surface with a hairline.
struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
    }
}

/// Every card puts its content 16pt in from the edge: rows, chips, text and section headers.
enum Inset {
    static let card: CGFloat = Space.m
}

/// Hairline between rows, inset to line up with the row text: the card line for text-only rows,
/// `afterIcon` where rows lead with an icon (权限, the home checklist).
struct RowDivider: View {
    static let afterIcon: CGFloat = Inset.card + IconTile.size + Space.s
    var inset: CGFloat = Inset.card
    var body: some View {
        Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, inset)
    }
}

/// A plain SF Symbol in secondary label, like the sidebar: no tile, one consistent size and
/// width so row titles line up. `attention` adds the orange dot.
struct IconTile: View {
    static let size: CGFloat = 24
    let symbol: String
    var attention = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .regular))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(Theme.tileGlyph)
            .frame(width: Self.size, height: Self.size)
            .overlay(alignment: .topTrailing) {
                if attention {
                    Circle()
                        .fill(Theme.attention)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 1.5))
                        .offset(x: 2, y: -1)
                }
            }
    }
}

/// One line in a grouped section: optional icon, title, optional detail, trailing control. Text-only
/// rows (most of Settings) mark `attention` with a small orange dot hanging in the margin before the
/// title, so the title stays on the card line; rows with an icon carry it on the icon. The detail
/// always stays secondary.
struct SettingRow<Trailing: View>: View {
    var icon: String?
    var attention = false
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Space.s) {
            if let icon { IconTile(symbol: icon, attention: attention) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.rowTitle).foregroundStyle(.primary)
                    .overlay(alignment: .leading) {
                        if attention, icon == nil {
                            Circle().fill(Theme.attention).frame(width: 7, height: 7)
                                .offset(x: -(7 + Self.dotGap))
                        }
                    }
                if let detail, !detail.isEmpty {
                    // Uses the width it has; only a short last line is evened out. Quotes stay whole.
                    BalancedWrap(maxNarrowing: 40) {
                        Text(Words.keepQuotes(detail))
                            .font(Typo.rowDetail)
                            .foregroundStyle(.secondary)
                            .lineSpacing(1)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520, alignment: .leading)
                    .textSelection(.enabled)
                }
            }
            Spacer(minLength: Space.m)
            // Controls are sized first; the description wraps into what is left.
            trailing.layoutPriority(2)
        }
        .padding(.horizontal, Inset.card)
        .padding(.vertical, Space.xs + 2)
        .frame(minHeight: 44)
    }

    /// Between the hanging attention dot and the title.
    private static var dotGap: CGFloat { 4.5 }
}

extension View {
    /// A Settings pop-up as System Settings draws it: borderless, the selected value and ⌃⌄ hugging
    /// the row's trailing edge, so the column of controls ends on one line whatever the values' widths.
    func settingsPopUp() -> some View {
        labelsHidden().buttonStyle(.borderless).fixedSize()
            // The borderless cell keeps ~5pt of its bezel's inset after the ⌃⌄: let the chevron end
            // where the switches and buttons in the other rows end.
            .padding(.trailing, -5)
    }
}

extension SettingRow where Trailing == EmptyView {
    init(icon: String? = nil, attention: Bool = false, title: String, detail: String? = nil) {
        self.init(icon: icon, attention: attention, title: title, detail: detail, trailing: { EmptyView() })
    }
}

/// Phrases that must not break across lines: "按 ⌘V 粘贴", "“错词 → 正确词”". Word joiners between
/// the characters and no-break spaces keep them on one line wherever the text wraps.
enum Words {
    static func keep(_ phrase: String) -> String {
        phrase.map { $0 == " " ? "\u{00A0}" : String($0) }.joined(separator: "\u{2060}")
    }

    /// "⌘V 粘贴" kept together.
    static let cmdVPaste = keep("⌘V 粘贴")

    /// Every “quoted” label kept on one line (they are short: “听写”, “不执行任何操作”), so a
    /// System Settings label is never split across lines.
    static func keepQuotes(_ text: String) -> String {
        var out = "", quote = ""
        var inQuote = false
        for c in text {
            if c == "“" { inQuote = true; quote = "“"; continue }
            if inQuote {
                quote.append(c)
                if c == "”" { out += keep(quote); inQuote = false }
            } else {
                out.append(c)
            }
        }
        return inQuote ? out + quote : out
    }
}

/// "Done" mark used by permission and setup rows.
struct GrantedMark: View {
    var text = "已允许"
    var body: some View {
        HStack(spacing: 5) {
            // Grey, like every other "done" mark; green is kept for the status dot.
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }
}

/// Coloured dot plus short status text.
struct StatusDot: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// Graceful empty state: a quiet symbol, a title, one helpful sentence and, where there is a place
/// to fix it, one accent text button that goes there.
struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String?
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(height: 34)
            VStack(spacing: Space.xxs) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                if let message {
                    Text(message)
                        .font(Typo.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 320)
                }
            }
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(Space.xxxl)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Brand

/// The app icon redrawn as a vector: the system-blue n-shaped sound wave on a white tile (a
/// graphite tile in dark appearance). Same wave, proportions and stroke as Resources/icon.
struct BrandMark: View {
    var size: CGFloat = 22

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [Theme.brandTile, Theme.brandTileShade], startPoint: .top, endPoint: .bottom))
            WaveN()
                .stroke(LinearGradient(colors: [Theme.brandInk, Theme.brandInkShade], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: size * 0.125, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .overlay(shape.strokeBorder(Theme.brandRim, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 0.5, y: 0.5)
    }
}

/// The icon's wave in tile units (Resources/icon/draw-icon.swift: scaled 0.84, nudged down 6).
private struct WaveN: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var path = Path()
        path.move(to: p(0.2696, 0.6842))
        path.addLine(to: p(0.2696, 0.4262))
        path.addCurve(to: p(0.4837, 0.4262), control1: p(0.2696, 0.2825), control2: p(0.4409, 0.2825))
        path.addLine(to: p(0.5387, 0.6046))
        path.addCurve(to: p(0.7304, 0.5710), control1: p(0.5795, 0.7382), control2: p(0.7304, 0.7259))
        path.addLine(to: p(0.7304, 0.4894))
        return path
    }
}

// MARK: - Buttons

/// The standard push button, drawn so dark mode matches system dark buttons (#3A3A3C with a
/// hairline) rather than the lighter raised fill, and a disabled title stays readable as a
/// disabled control (tertiary label) instead of fading away.
struct PushButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let small = controlSize == .small || controlSize == .mini
        let shape = RoundedRectangle(cornerRadius: small ? 5 : 6, style: .continuous)
        configuration.label
            .font(.system(size: small ? 11 : 13))
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .lineLimit(1)
            .padding(.horizontal, small ? 8 : 10)
            .frame(minHeight: small ? 18 : 22)
            .background(shape.fill(configuration.isPressed && isEnabled ? Theme.pushFillPressed : Theme.pushFill)
                .shadow(color: .black.opacity(isEnabled ? 0.06 : 0.03), radius: 0, y: 0.5))
            .overlay(shape.strokeBorder(Theme.pushBorder, lineWidth: 0.5))
            .contentShape(shape)
    }
}

extension ButtonStyle where Self == PushButtonStyle {
    static var pushButton: PushButtonStyle { PushButtonStyle() }
}

/// The one filled accent action on a screen (复制, 添加): the push button's size, corners and
/// padding, filled with the accent and a white title, so it lines up with the buttons beside it.
struct ProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let small = controlSize == .small || controlSize == .mini
        let shape = RoundedRectangle(cornerRadius: small ? 5 : 6, style: .continuous)
        configuration.label
            .font(.system(size: small ? 11 : 13))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .padding(.horizontal, small ? 8 : 10)
            .frame(minHeight: small ? 18 : 22)
            .background(shape.fill(Theme.accent.opacity(isEnabled ? 1 : 0.4))
                .shadow(color: .black.opacity(isEnabled ? 0.08 : 0), radius: 0, y: 0.5))
            .brightness(configuration.isPressed && isEnabled ? -0.08 : 0)
            .contentShape(shape)
    }
}

extension ButtonStyle where Self == ProminentButtonStyle {
    static var prominent: ProminentButtonStyle { ProminentButtonStyle() }
}

/// Keyboard key as it appears on the keycap, instead of the emoji in the trigger title.
struct KeyCap: View {
    let trigger: HotkeyTrigger
    var fontSize: CGFloat = 12

    var body: some View {
        HStack(spacing: 3) {
            switch trigger {
            case .fn:
                Image(systemName: "globe")
                Text("fn")
            case .rightOption:
                Text("右")
                Text("⌥")
            case .rightCommand:
                Text("右")
                Text("⌘")
            }
        }
        .font(.system(size: fontSize, weight: .medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, fontSize * 0.55)
        .frame(height: fontSize * 1.9)
        .background(
            RoundedRectangle(cornerRadius: fontSize * 0.42, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.10), radius: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: fontSize * 0.42, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
    }
}

extension HotkeyTrigger {
    /// The 按键 pop-up: the key as printed on the keyboard, nothing more (sentences use `keyName`).
    var menuTitle: String {
        switch self {
        case .fn: return "fn 🌐\u{FE0E}"
        case .rightOption: return "右侧 Option"
        case .rightCommand: return "右侧 Command"
        }
    }
}

extension HotkeyStyle {
    /// How the key is used in this style, for Settings: "轻按 fn 开始，说完再轻按一下结束".
    func usage(_ key: String) -> String {
        switch self {
        case .auto: return "轻按 \(key) 开始、再按一下结束；按住 \(key) 说话、松开结束"
        case .toggle: return "轻按 \(key) 开始，说完再轻按一下结束"
        case .hold: return "按住 \(key) 说话，松开就结束"
        }
    }
}

extension DictationMode {
    /// The home page's segmented control, History and Settings: short, without the core title's note.
    var shortTitle: String {
        switch self {
        case .natural: return "自然整理"
        case .structured: return "结构化"
        case .raw: return "原样转写"
        }
    }

    /// What the mode does, in one line.
    var summary: String {
        switch self {
        case .natural: return "去掉口头禅和重复，修正错词，内容多时分段、编号"
        case .structured: return "整理成发给 AI 的清晰请求：先写目标，再逐条列出要求"
        case .raw: return "直接输入识别出的文字，不经过 ChatGPT"
        }
    }

    /// The home page's line under "按 fn 开始说话". With `autoStructured`, 自然整理 also says that AI
    /// apps get 结构化, so a numbered request in Codex is no surprise; it stays short enough to share
    /// the hero row with the mode switch. `onNeo`: the Neo recognises (用 Neo 处理, and it is not out of reach).
    func homeLine(autoStructured: Bool, onNeo: Bool = false) -> String {
        let where_ = onNeo ? "Neo 识别" : "本机识别"
        switch self {
        case .natural where autoStructured: return "\(where_)，ChatGPT 整理，AI\u{00A0}应用里自动用结构化。"
        case .natural: return "\(where_)，ChatGPT 帮你去掉口头禅、修正错词。"
        case .structured: return "\(where_)，ChatGPT 整理成发给 AI 的清晰请求。"
        case .raw: return "\(where_)，原样输入，不经过 ChatGPT。"
        }
    }
}

/// Apps where 自然整理 turns into 结构化 (`AIApps`), named for people: the ones they will meet (the
/// code also knows Windsurf, Zed, iTerm and Warp). ChatGPT in a browser is not one of them.
enum AIAppExamples {
    static let text = "Codex、Claude、ChatGPT、Cursor、VS Code、终端"
}

// MARK: - Flow layout

/// Wraps children onto new lines, keeping each at its natural width (for word chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = Space.xs
    var lineSpacing: CGFloat = Space.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Balanced wrapping

/// Wraps its text a little narrower when that keeps the same number of lines, so the last line
/// picks up a few more characters and a paragraph does not end on a lonely "用。". The measure
/// shrinks by at most `maxNarrowing`, which keeps the ragged edge calm (unlike full balancing).
struct BalancedWrap: Layout {
    var maxNarrowing: CGFloat = 36

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let size = view.sizeThatFits(ProposedViewSize(width: width(view, proposal.width), height: nil))
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        view.place(at: bounds.origin, anchor: .topLeading,
                   proposal: ProposedViewSize(width: width(view, bounds.width), height: nil))
    }

    private func width(_ view: LayoutSubview, _ available: CGFloat?) -> CGFloat? {
        guard let available, available.isFinite, available > 0 else { return available }
        func height(_ w: CGFloat) -> CGFloat { view.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }
        let target = height(available)
        // One line stays as it is; otherwise search the narrowest width (within the budget) with
        // the same height.
        guard target > height(.infinity) + 0.5 else { return available }
        var lo = max(available * 0.6, available - maxNarrowing), hi = available
        if height(lo) <= target + 0.5 { return ceil(lo) }
        for _ in 0..<8 {
            let mid = (lo + hi) / 2
            if height(mid) <= target + 0.5 { hi = mid } else { lo = mid }
        }
        return ceil(hi)
    }
}

// MARK: - Live waveform (shared by the home page and the HUD)

/// The voice, stepped at 30 Hz from the controller's latest level while a dictation is active (and
/// only then): one smoothed amplitude, kept as a short trail, turned into `count` bar levels,
/// with a little fresh randomness every frame (`WaveShape`). Only the small
/// `VoiceWave` that shows it should observe it; its owner keeps it as a plain reference, so nothing
/// else re-renders at 30 Hz.
@MainActor
final class VoiceMeter: ObservableObject {
    /// One level (0...1) per bar; empty is silence, a row of still dots.
    @Published private(set) var levels: [Double] = []
    let count: Int

    private weak var controller: DictationController?
    private var smoother = AmplitudeSmoother()
    private var trail = WaveTrail()
    private var random = SeededGenerator(seed: UInt64.random(in: 0...UInt64.max))
    private var timer: Timer?
    private var last: CFAbsoluteTime = 0
    private var subscription: AnyCancellable?
    /// Snapshots: fixed values, never ticking.
    private var held = false

    init(_ controller: DictationController, count: Int = CapsuleMetrics.bars) {
        self.controller = controller
        self.count = count
        subscription = controller.$phase.removeDuplicates().sink { [weak self] phase in
            // The sink runs before the new phase is stored, so pass it along.
            self?.follow(phase)
        }
    }

    private func follow(_ phase: Phase) {
        if phase.isActive { start() } else { stop() }
    }

    private func start() {
        guard timer == nil, !held else { return }
        last = CFAbsoluteTimeGetCurrent()
        // Scheduled on the main run loop, so the block always runs on the main thread. It holds the
        // meter weakly and retires itself once the meter is gone, so there is no deinit to write.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        guard !held else { return }
        smoother.reset()
        trail.reset()
        if !levels.isEmpty { levels = [] }
    }

    private func tick() {
        guard let controller else { return stop() }
        let now = CFAbsoluteTimeGetCurrent()
        let dt = min(0.1, now - last)
        last = now
        let level = controller.phase == .recording ? (controller.levels.last ?? 0) : 0
        let next = smoother.step(level: level, dt: dt)
        // Silence (and the warm-up, and processing) is a row of still dots: nothing to redraw
        // until a voice arrives.
        guard next > 0 || !trail.isSilent || !levels.isEmpty else { return }
        trail.push(next)
        let shape = WaveShape.random(count: count, using: &random)
        let target = CapsuleWave.levels(trail: trail.values, count: count, shape: shape)
        let blended = CapsuleWave.blend(previous: levels, target: target, shape: shape)
        levels = trail.isSilent && blended.allSatisfy({ $0 == 0 }) ? [] : blended
    }

    /// Snapshots only: shows `trail` (newest first) without ticking, shaped by a fixed seed.
    func _debugHold(trail values: [Float], seed: UInt64 = 7) {
        held = true
        timer?.invalidate()
        timer = nil
        var random = SeededGenerator(seed: seed)
        let shape = WaveShape.random(count: count, using: &random)
        let target = CapsuleWave.levels(trail: values, count: count, shape: shape)
        levels = target.allSatisfy { $0 == 0 } ? [] : target
    }
}

/// A row of rounded bars driven by the meter: still white dots in silence; a voice lands on one
/// of the middle bars and falls off towards the ends, a little differently every frame.
struct VoiceWave: View {
    @ObservedObject var meter: VoiceMeter
    var barWidth = CapsuleMetrics.barWidth
    var spacing = CapsuleMetrics.barSpacing
    var maxHeight = CapsuleMetrics.waveHeight
    var color: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let count = meter.count
        let heights = CapsuleWave.heights(levels: meter.levels, count: count, minHeight: barWidth, maxHeight: maxHeight)
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: barWidth, height: heights[i])
            }
        }
        .frame(height: maxHeight)
        // Each 30 Hz step glides into the next, so the bars move without stepping.
        .animation(reduceMotion ? nil : .linear(duration: 1.0 / 30), value: meter.levels)
    }
}

/// The home page's level display while recording: the same voice shape as the HUD.
struct VoiceLevel: View {
    @StateObject private var meter: VoiceMeter
    var barWidth: CGFloat
    var spacing: CGFloat
    var maxHeight: CGFloat
    var color: Color

    init(controller: DictationController, count: Int = 13, barWidth: CGFloat = 3, spacing: CGFloat = 2.5,
         maxHeight: CGFloat = 22, color: Color = Theme.recording) {
        _meter = StateObject(wrappedValue: VoiceMeter(controller, count: count))
        self.barWidth = barWidth
        self.spacing = spacing
        self.maxHeight = maxHeight
        self.color = color
    }

    var body: some View {
        VoiceWave(meter: meter, barWidth: barWidth, spacing: spacing, maxHeight: maxHeight, color: color)
    }
}
