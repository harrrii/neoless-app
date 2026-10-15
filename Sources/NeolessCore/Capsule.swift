import CoreGraphics
import Foundation

/// What the recording capsule shows, which decides its size. Its look follows the floating bars of
/// Typeless and OpenLess in spirit (see CREDITS.md). The sizes:
/// a thin line it grows out of and shrinks back into, a small pill while the microphone
/// opens, 70 × 34 for hold to talk, 116 × 34 for hands-free (each 40pt wider while the last minute
/// counts down), 92 × 34 while processing, and one short line for a result (a plain paste shows
/// none: the capsule just collapses). Always fully rounded.
public enum CapsuleLook: Equatable, Sendable {
    /// Hidden: the 40 × 6 line the capsule grows out of and shrinks back into, at opacity 0.
    case idle
    /// The microphone is opening: a small half-black pill that grows into the recording capsule.
    case starting
    /// Hold to talk: the wave alone (then the countdown, in the last minute).
    case hold(countdown: Bool)
    /// Hands-free: [× | wave | ✓] (with the countdown before ✓ in the last minute).
    case handsFree(countdown: Bool)
    /// Recognizing or polishing: one shimmering word whose natural width is `textWidth`.
    case processing(textWidth: CGFloat)
    /// A result or a failure: a glyph and one line of text whose natural width is `textWidth`.
    case status(textWidth: CGFloat)

    public var size: CGSize {
        let h = CapsuleMetrics.height
        switch self {
        case .idle: return CapsuleMetrics.idleSize
        case .starting: return CapsuleMetrics.startingSize
        case .hold(let countdown):
            return CGSize(width: CapsuleMetrics.holdWidth + (countdown ? CapsuleMetrics.countdownExtra : 0), height: h)
        case .handsFree(let countdown):
            return CGSize(width: CapsuleMetrics.handsFreeWidth + (countdown ? CapsuleMetrics.countdownExtra : 0), height: h)
        case .processing(let w): return CGSize(width: CapsuleMetrics.processingWidth(textWidth: w), height: h)
        case .status(let w): return CGSize(width: CapsuleMetrics.statusWidth(textWidth: w), height: h)
        }
    }

    /// Opaque black. The line and the starting pill are half black; every look has the rim.
    public var isSolid: Bool {
        switch self {
        case .idle, .starting: return false
        default: return true
        }
    }

    /// Whether the capsule has buttons that take clicks.
    public var hasButtons: Bool {
        if case .handsFree = self { return true }
        return false
    }
}

/// Fixed geometry of the recording capsule, its live transcript rail and the panel around them, in points.
public enum CapsuleMetrics {
    /// Shell height in every look except idle and starting.
    public static let height: CGFloat = 34
    /// The rim: 1pt of white at 32 %.
    public static let rim: CGFloat = 1
    /// Hidden: the line the capsule grows out of (the idle bar).
    public static let idleSize = CGSize(width: 40, height: 6)
    /// The microphone is opening.
    public static let startingSize = CGSize(width: 54, height: 12)

    /// Round × and ✓, `inset` from the ends: the 102pt row (24 + 8 + 38 + 8 + 24)
    /// sits centred in the 116pt capsule.
    public static let button: CGFloat = 24
    public static let inset: CGFloat = 7
    /// The waveform's box, and its distance to each button.
    public static let waveBox: CGFloat = 38
    public static let gap: CGFloat = 8

    /// Waveform: `bars` rounded bars of `barWidth`, `barSpacing` apart, at most `waveHeight` tall.
    /// Ten 2pt bars 2pt apart fill the 38pt box exactly.
    public static let bars = 10
    public static let barWidth: CGFloat = 2
    public static let barSpacing: CGFloat = 2
    public static let waveHeight: CGFloat = 18
    public static var waveWidth: CGFloat { CGFloat(bars) * barWidth + CGFloat(bars - 1) * barSpacing }

    /// Hold to talk: the wave alone.
    public static let holdWidth: CGFloat = 70
    /// Hands-free: [× | wave | ✓]. Placement uses it.
    public static var handsFreeWidth: CGFloat { 2 * (inset + button + gap) + waveBox }

    /// The last minute: mm:ss after the wave in a 32pt slot, which "00:59" fills (spilling under a
    /// point each side into the gaps), with 8pt after it; the capsule grows by both.
    public static let countdownSlot: CGFloat = 32
    public static let countdownGap: CGFloat = 8
    public static var countdownExtra: CGFloat { countdownSlot + countdownGap }

    /// Recognizing / polishing: a fixed 92pt, wider only if a word ever needs it.
    public static let thinkingWidth: CGFloat = 92
    public static let processingPadding: CGFloat = 20
    public static func processingWidth(textWidth: CGFloat) -> CGFloat {
        even(max(thinkingWidth, 2 * processingPadding + ceil(textWidth)))
    }

    /// Status line (copied / fallback / failed…): the 14pt glyph disc sits concentric with the
    /// rounded end, `(height - glyph) / 2` in; the text ends `statusTrailing` from the other end,
    /// which with the type's own side bearing balances the disc's 10pt.
    public static let glyph: CGFloat = 14
    public static var statusLeading: CGFloat { (height - glyph) / 2 }
    public static let statusTrailing: CGFloat = 12
    public static let glyphGap: CGFloat = 6
    public static let minStatusWidth: CGFloat = 84
    /// Small: twelve Chinese characters at 13pt still fit.
    public static let maxStatusWidth: CGFloat = 204
    /// Text room in the widest status capsule.
    public static var maxStatusText: CGFloat { maxStatusWidth - statusLeading - statusTrailing - glyph - glyphGap }

    /// Capsule width for a status message whose natural one-line width is `textWidth`.
    public static func statusWidth(textWidth: CGFloat) -> CGFloat {
        let natural = even(statusLeading + glyph + glyphGap + ceil(textWidth) + statusTrailing)
        return min(max(natural, minStatusWidth), maxStatusWidth)
    }

    /// The one-line live transcript rail above (or below) the capsule.
    public static let railHeight: CGFloat = 26
    public static let railGap: CGFloat = 8
    public static let railPadding: CGFloat = 12
    public static let railMaxWidth: CGFloat = 240
    /// A rail wider than the capsule under it overhangs it by at least this much on each side.
    public static let railOverhang: CGFloat = 10
    /// Overflowing text starts to dissolve this far in from the rail's left end, over `railFade`.
    public static let railFadeStart: CGFloat = 6
    public static let railFade: CGFloat = 36
    /// A notice's leading timer glyph and the gap after it.
    public static let noticeGlyph: CGFloat = 12
    public static let noticeGap: CGFloat = 5

    /// Rail width for text of natural width `textWidth` stacked on a capsule `capsuleWidth` wide:
    /// the capsule's own width, or clearly wider (by `railOverhang` a side at least), since two
    /// near-equal pills that do not line up look like a mistake; never wider than `railMaxWidth`
    /// (the text overflows past it).
    public static func railWidth(textWidth: CGFloat, capsuleWidth: CGFloat = 0) -> CGFloat {
        let natural = even(2 * railPadding + ceil(textWidth))
        let capsule = even(capsuleWidth)
        let width: CGFloat
        if natural <= capsule {
            width = capsule
        } else if capsule > 0, natural < capsule + 2 * railOverhang {
            width = capsule + 2 * railOverhang
        } else {
            width = natural
        }
        return min(width, railMaxWidth)
    }

    /// Whether the rail text is wider than the rail (so it is right-anchored and fades on the left).
    public static func railOverflows(textWidth: CGFloat) -> Bool {
        2 * railPadding + ceil(textWidth) > railMaxWidth
    }

    /// Rounded up to an even number of points, so a centred capsule lands on whole points even on
    /// a non-Retina screen.
    public static func even(_ width: CGFloat) -> CGFloat {
        2 * ceil(width / 2 - 0.000_001)
    }

    /// Placement box for a dictation: the hands-free capsule, plus the rail when it is on, so the
    /// side chosen (below or above the caret) has room for both.
    public static func stackSize(rail: Bool) -> CGSize {
        CGSize(width: handsFreeWidth, height: height + (rail ? railGap + railHeight : 0))
    }

    /// Half the panel's content width. The panel is centred on the hands-free capsule's (clamped)
    /// centre; anything wider may shift sideways to stay on screen, by at most the difference of
    /// half-widths, so this is the furthest any content can reach from that centre.
    public static var panelHalfWidth: CGFloat {
        max(railMaxWidth, maxStatusWidth, handsFreeWidth + countdownExtra) - handsFreeWidth / 2
    }

    public static var panelContentSize: CGSize {
        CGSize(width: 2 * panelHalfWidth, height: height + railGap + railHeight)
    }

    /// Transparent room around the content for the two shadows (a halo and a long one),
    /// which fall mostly below the capsule.
    public static let shadowTop: CGFloat = 24
    public static let shadowSide: CGFloat = 36
    public static let shadowBottom: CGFloat = 64

    /// The HUD panel: the content and its shadow room.
    public static var panelSize: CGSize {
        CGSize(width: panelContentSize.width + 2 * shadowSide,
               height: panelContentSize.height + shadowTop + shadowBottom)
    }

    /// Bottom-left of the panel for a placement box (`stackSize`) whose bottom-left is `origin`, in
    /// screen coordinates (y up). Hanging below a caret the capsule is at the top of the box (rail
    /// underneath); otherwise at the bottom (rail above).
    public static func panelOrigin(stack origin: CGPoint, size: CGSize, hangsBelow: Bool) -> CGPoint {
        let x = origin.x + size.width / 2 - panelSize.width / 2
        let y = hangsBelow ? origin.y + size.height + shadowTop - panelSize.height : origin.y - shadowBottom
        return CGPoint(x: x, y: y)
    }

    /// A capsule `width` × `capsuleHeight` inside the panel, y up as AppKit lays out a window,
    /// centred on its 34pt row. `offset` is its sideways shift. Only the hands-free capsule's frame
    /// may take clicks; the rest of the panel passes them through.
    public static func capsuleFrame(width: CGFloat, height capsuleHeight: CGFloat = height, offset: CGFloat,
                                    hangsBelow: Bool) -> CGRect {
        let x = shadowSide + panelHalfWidth + offset - width / 2
        let row = hangsBelow ? shadowBottom + railGap + railHeight : shadowBottom
        return CGRect(x: x, y: row + (height - capsuleHeight) / 2, width: width, height: capsuleHeight)
    }
}

/// Horizontal placement of capsule content that is wider or narrower than the hands-free capsule.
public enum CapsuleLayout {
    /// A button's tooltip keeps at least this far inside the screen's visible frame.
    public static let tipMargin: CGFloat = 4

    /// Sideways offset, from the capsule's centre, of the tooltip `tipWidth` wide for the × (`cancel`)
    /// or the ✓ of a hands-free capsule `capsuleWidth` wide whose centre is at `capsuleX` on screen:
    /// centred on its button, unless that would put it within `tipMargin` of the edge of `vf`
    /// (a capsule pinned to the screen's edge). A null `vf` has no edges.
    public static func tipOffset(cancel: Bool, capsuleWidth: CGFloat, tipWidth: CGFloat, capsuleX: CGFloat,
                                 in vf: CGRect) -> CGFloat {
        let reach = capsuleWidth / 2 - CapsuleMetrics.inset - CapsuleMetrics.button / 2
        let x = cancel ? -reach : reach
        guard !vf.isNull, vf.width > tipWidth + 2 * tipMargin else { return x }
        let lowest = vf.minX + tipMargin + tipWidth / 2 - capsuleX
        let highest = vf.maxX - tipMargin - tipWidth / 2 - capsuleX
        return min(max(x, lowest), highest)
    }

    /// Centre x for content `width` wide that wants to sit centred on `anchorX`, kept inside `vf`
    /// with `PillPlacement.margin` (centred on the screen if it cannot fit).
    public static func centreX(anchorX: CGFloat, width: CGFloat, in vf: CGRect) -> CGFloat {
        let origin = PillPlacement.clamp(CGPoint(x: anchorX - width / 2, y: vf.midY), size: CGSize(width: width, height: 0), in: vf)
        return origin.x + width / 2
    }

    /// Offset from the panel centre for content `width` wide (the panel is centred on `anchorX`).
    public static func offset(anchorX: CGFloat, width: CGFloat, in vf: CGRect) -> CGFloat {
        guard vf.width > 0 else { return 0 }
        return centreX(anchorX: anchorX, width: width, in: vf) - anchorX
    }
}

/// A cubic Bézier timing curve: `value(at:)` maps time 0...1 to progress 0...1.
public struct CubicBezier: Equatable, Sendable {
    public let x1: Double, y1: Double, x2: Double, y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }

    /// The usual ease-out and ease-in-out.
    public static let easeOut = CubicBezier(0, 0, 0.58, 1)
    public static let easeInOut = CubicBezier(0.42, 0, 0.58, 1)

    private static func point(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }

    public func value(at x: Double) -> Double {
        guard x.isFinite else { return 1 }
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        // x(t) is monotone for control points in 0...1: bisect for t, then read y.
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if Self.point(mid, x1, x2) < x { lo = mid } else { hi = mid }
        }
        return Self.point((lo + hi) / 2, y1, y2)
    }
}

/// One amplitude for the whole waveform: a noise gate, a gamma lift so normal speech fills the
/// bars, then fast-attack / slow-release smoothing so it reads as a voice, not a jittery chart.
/// Input is the recorder's 0...1 level (-55 dBFS ... -12 dBFS, linear in dB).
public struct AmplitudeSmoother: Sendable, Equatable {
    /// Below this level (about -50 dBFS, a quiet room) the bars stay still.
    public static let gate: Float = 0.12
    /// At or above this level (about -18 dBFS, a firm voice) the bars are full.
    public static let full: Float = 0.86
    public static let gamma: Float = 0.55
    /// Time constants: rise quickly with the voice, fall back gently.
    public static let attack: Double = 0.04
    public static let release: Double = 0.16

    public private(set) var value: Float = 0

    public init(value: Float = 0) { self.value = value }

    /// Gated, gamma-lifted target for a raw level.
    public static func target(level: Float) -> Float {
        guard level.isFinite else { return 0 }
        let voice = min(1, max(0, (level - gate) / (full - gate)))
        return voice > 0 ? pow(voice, gamma) : 0
    }

    /// Advances by `dt` seconds towards the target for `level` and returns the new amplitude.
    @discardableResult
    public mutating func step(level: Float, dt: Double) -> Float {
        let target = Self.target(level: level)
        let tau = target > value ? Self.attack : Self.release
        let k = Float(1 - exp(-max(0, dt) / tau))
        value += (target - value) * k
        if value < 0.002 { value = 0 }
        return value
    }

    public mutating func reset() { value = 0 }
}

/// The last few smoothed amplitudes, newest first, one per meter frame (30 Hz). Bars further from
/// the peak show a slightly older one, so the voice spreads outwards from the middle.
public struct WaveTrail: Equatable, Sendable {
    public static let length = 8
    public private(set) var values: [Float]

    public init(values: [Float] = []) {
        self.values = Array(values.prefix(Self.length))
    }

    public mutating func push(_ value: Float) {
        values.insert(value.isFinite ? min(1, max(0, value)) : 0, at: 0)
        if values.count > Self.length { values.removeLast(values.count - Self.length) }
    }

    /// Every bar is a still dot: nothing to redraw.
    public var isSilent: Bool { values.allSatisfy { $0 == 0 } }

    public mutating func reset() { values = [] }
}

/// A small seeded random generator (SplitMix64), so the wave's randomness is repeatable in tests
/// and snapshots.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// One frame's randomness for the wave, rolled for every new volume: which of the
/// two middle bars takes it, and per bar how steeply it falls off, a small wobble, and how much of
/// the new height wins when a bar falls. Without it the wave is a machine-made symmetric shape.
public struct WaveShape: Equatable, Sendable {
    /// −1 or 0: the volume lands on bar `count / 2` or the one left of it.
    public var peakOffset: Int
    /// Per bar, added to `CapsuleWave.falloff`: 0 ... 0.08.
    public var decay: [Double]
    /// Per bar volume wobble: 0.9 ... 1.1 (0.95 ... 1.05 on the peak).
    public var wobble: [Double]
    /// Per bar: how much of the new height wins over the old one as a bar falls, 0.65 ... 0.75.
    public var blend: [Double]

    public init(peakOffset: Int = 0, decay: [Double] = [], wobble: [Double] = [], blend: [Double] = []) {
        self.peakOffset = peakOffset
        self.decay = decay
        self.wobble = wobble
        self.blend = blend
    }

    /// No randomness: the peak on bar `count / 2`, the mean fall-off, no wobble.
    public static let even = WaveShape()

    /// A fresh roll: the peak moves a bar or so off centre, and each bar gets its own fall-off,
    /// wobble and blend.
    public static func random<G: RandomNumberGenerator>(count: Int, using g: inout G) -> WaveShape {
        let reach = min(Double(count) * 0.15, 3)
        let offset = Int(((Double.random(in: 0..<1, using: &g) - 0.5) * reach).rounded(.down))
        let peak = CapsuleWave.peak(count: count, offset: offset)
        var shape = WaveShape(peakOffset: offset)
        for i in 0..<max(0, count) {
            shape.decay.append(Double.random(in: 0...CapsuleWave.decayJitter, using: &g))
            shape.wobble.append(i == peak ? Double.random(in: 0.95...1.05, using: &g) : Double.random(in: 0.9...1.1, using: &g))
            shape.blend.append(Double.random(in: 0.65...0.75, using: &g))
        }
        return shape
    }

    func decay(_ i: Int) -> Double { i < decay.count ? decay[i] : CapsuleWave.decayJitter / 2 }
    func wobble(_ i: Int) -> Double { i < wobble.count ? wobble[i] : 1 }
    func blend(_ i: Int) -> Double { i < blend.count ? blend[i] : 0.7 }
}

/// Bar levels for the capsule waveform and the home-page meter. The
/// newest volume lands on one of the two middle bars; every other bar takes it scaled down in a
/// straight line towards the ends (to about a third there), with a little randomness per frame, so
/// the wave is a lively, slightly lopsided peak. Silence is a row of white dots.
public enum CapsuleWave {
    /// Fall-off from the peak to the far end of its side, plus up to `decayJitter`.
    public static let falloff = 0.65
    public static let decayJitter = 0.08
    /// No bar falls below this share of the peak while a voice is on.
    public static let minFalloff = 0.12

    /// The bar that takes the newest volume.
    public static func peak(count: Int, offset: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(count - 1, max(0, count / 2 + offset))
    }

    /// How many frames old the amplitude a bar `distance` from the peak shows: the spread
    /// is delayed by half a 30 Hz frame a bar.
    public static func lag(distance: Int) -> Int { distance / 2 }

    /// Target level 0...1 per bar for `trail` (newest amplitude first).
    public static func levels(trail: [Float], count: Int, shape: WaveShape) -> [Double] {
        guard count > 0 else { return [] }
        let peak = peak(count: count, offset: shape.peakOffset)
        return (0..<count).map { i in
            let d = abs(i - peak)
            let span = i < peak ? peak : count - 1 - peak
            let scale = d == 0 ? 1 : max(minFalloff, 1 - Double(d) / Double(max(span, 1)) * (falloff + shape.decay(i)))
            let raw = trail.isEmpty ? 0 : trail[min(lag(distance: d), trail.count - 1)]
            let amp = raw.isFinite ? Double(min(1, max(0, raw))) : 0
            return min(1, amp * scale * shape.wobble(i))
        }
    }

    /// Per-bar smoothing: a bar rises at once and falls most of the way per frame.
    public static func blend(previous: [Double], target: [Double], shape: WaveShape) -> [Double] {
        target.indices.map { i in
            let old = i < previous.count && previous[i].isFinite ? previous[i] : 0
            let b = shape.blend(i)
            let next = max(target[i], old * (1 - b) + target[i] * b)
            return next < 0.001 ? 0 : next
        }
    }

    /// Bar heights in points: a level of 1 is `maxHeight`, and nothing is shorter than a round dot
    /// (`minHeight`). Whole points, so bars stay crisp.
    public static func heights(levels: [Double], count: Int, minHeight: CGFloat, maxHeight: CGFloat) -> [CGFloat] {
        (0..<max(0, count)).map { i in
            let level = i < levels.count && levels[i].isFinite ? min(1, max(0, levels[i])) : 0
            return max(minHeight, (maxHeight * CGFloat(level)).rounded())
        }
    }
}

/// The faint glint that crosses the 识别中 / 整理中 word: a 24pt band, solid over its middle 8pt,
/// laid over the half-white word at 30 %. It crosses in `sweep` seconds, easing out, then rests
/// until the period ends.
public enum CapsuleShimmer {
    public static let period: Double = 1.55
    public static let sweep: Double = 1.25
    public static let band: CGFloat = 24
    public static let core: CGFloat = 8

    /// 0: the band is just left of the word, 1: just right of it (and resting there).
    public static func progress(time t: Double) -> Double {
        guard t.isFinite else { return 1 }
        let local = t - (t / period).rounded(.down) * period
        guard local < sweep else { return 1 }
        return CubicBezier.easeOut.value(at: local / sweep)
    }
}

/// The soft light that slides across the starting pill while the microphone opens: a
/// 27pt blurred disc, from just off its left end to just off its right end every half second.
public enum CapsuleGlint {
    public static let diameter: CGFloat = 27
    public static let period: Double = 0.5

    /// Left edge of the disc in the pill at time `t`.
    public static func x(time t: Double, pillWidth: CGFloat = CapsuleMetrics.startingSize.width) -> CGFloat {
        guard t.isFinite else { return -diameter }
        let local = t - (t / period).rounded(.down) * period
        let p = CubicBezier.easeInOut.value(at: local / period)
        return -diameter + (pillWidth + diameter) * CGFloat(p)
    }
}

/// The faint light fill behind 识别中 / 整理中: it keeps moving through a usual one to
/// five second polish and slows so it never quite arrives; when the result is ready it completes,
/// then fades out, so whatever comes next starts on plain black. Its leading edge is soft.
public enum CapsuleProgress {
    /// (seconds, fraction), linear in between; the last fraction holds after the last time.
    public static let keyframes: [(time: Double, fraction: Double)] = [
        (0, 0), (1, 0.45), (2, 0.65), (4, 0.82), (8, 0.92), (15, 0.97),
    ]
    /// The soft leading edge: the fill fades to nothing over this width.
    public static let feather: CGFloat = 10
    /// Once complete, the fill fades out over this long.
    public static let fade: Double = 0.2

    public static func fraction(elapsed: Double) -> Double {
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        for (a, b) in zip(keyframes, keyframes.dropFirst()) where elapsed < b.time {
            return a.fraction + (elapsed - a.time) / (b.time - a.time) * (b.fraction - a.fraction)
        }
        return keyframes[keyframes.count - 1].fraction
    }

    /// Completing: from `from` to full in `CapsuleTiming.fillFinish`, `elapsed` seconds in.
    public static func finishing(from: Double, elapsed: Double) -> Double {
        guard elapsed.isFinite, elapsed > 0 else { return min(1, max(0, from)) }
        let k = min(1, elapsed / CapsuleTiming.fillFinish)
        return min(1, max(0, from)) + (1 - min(1, max(0, from))) * k
    }

    /// The fill's opacity `elapsed` seconds after the result arrived (nil: still working): whole
    /// while it completes, then easing out over `fade`, well before the result shows.
    public static func opacity(sinceCompleted elapsed: Double?) -> Double {
        guard let elapsed else { return 1 }
        guard elapsed.isFinite else { return 0 }
        return 1 - CubicBezier.easeOut.value(at: (elapsed - CapsuleTiming.fillFinish) / fade)
    }

    /// Width of the fill (its soft edge included) for `fraction` of a capsule `capsuleWidth` wide:
    /// nothing at 0; at 1 the soft edge lies just past the capsule's end, so it is full.
    public static func width(fraction: Double, capsuleWidth: CGFloat) -> CGFloat {
        let f = fraction.isFinite ? min(1, max(0, fraction)) : 0
        return (max(0, capsuleWidth) + feather) * CGFloat(f)
    }

    /// Where, from 0 to 1 along a fill `width` wide, the solid part ends and the soft edge begins.
    public static func solidStop(width: CGFloat) -> Double {
        width > 0 ? Double(max(0, (width - feather) / width)) : 0
    }
}

/// The last minute of a recording, counted down in the capsule as mm:ss.
public enum CapsuleCountdown {
    /// From the near-cap notice to the cap.
    public static var length: TimeInterval { CaptureTiming.maxRecording - CaptureTiming.capWarning }

    /// "00:59" for 58.3 s left: rounded up, so it starts on 01:00 and shows 00:01 in the last second.
    public static func text(remaining: TimeInterval) -> String {
        let s = remaining.isFinite ? max(0, Int(remaining.rounded(.up))) : 0
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// What a result in the capsule is about, which picks its glyph and how long it stays.
public enum CapsuleStatusKind: Equatable, Sendable {
    /// Typed as usual (which shows nothing: `CapsuleTiming.collapsesQuietly`), or left in neoless's window.
    case done
    /// Typed, but the user's clipboard could not be put back.
    case kept
    /// Copied, not pasted: the user still has to press ⌘V.
    case copied
    /// Esc or × stopped the paste.
    case cancelled
    /// A password field: nothing typed.
    case secure
    /// Typed or copied, but not polished.
    case fallback
    case failed
    /// Outside a dictation: a word the user fixed was remembered (`LearningText.learned`).
    case learned
    /// Outside a dictation: a fix was not remembered, or cannot be seen in this app (`LearningText.missed`,
    /// `LearningText.unwatched`).
    case note
}

/// When the capsule moves on after a result, in seconds.
public enum CapsuleTiming {
    /// After processing, the fill completes in `fillFinish` and holds `fillHold` before the result shows.
    public static let fillFinish: Double = 0.1
    public static let fillHold: Double = 0.35
    public static var resultDelay: Double { fillFinish + fillHold }

    /// Typed as usual: the capsule just completes its fill and collapses, since the
    /// text at the cursor says it all. Anything else gets a line that says what happened.
    public static func collapsesQuietly(done message: String) -> Bool {
        message == InsertResult.pasted.message
    }

    /// How long a result stays up once it shows: a plain one (没有输入，结果在窗口里) just confirms; anything
    /// the user has to read or act on (copied, so press ⌘V; a fallback; a failure) stays longer, and
    /// a little longer again for each character past twelve.
    public static func linger(_ kind: CapsuleStatusKind, text: String) -> TimeInterval {
        let base: TimeInterval
        switch kind {
        case .done: base = 1.0
        case .kept, .copied, .cancelled, .secure, .learned: base = 2.6
        case .fallback, .note: base = 2.8
        case .failed: base = 3.2
        }
        return min(3.6, base + Double(max(0, text.count - 12)) * 0.08)
    }

    /// Whether the result follows a completed fill (it was produced), rather than replacing the
    /// processing word at once (cancelled, failed).
    public static func completesFill(_ kind: CapsuleStatusKind) -> Bool {
        kind != .cancelled && kind != .failed
    }
}

/// A result as the capsule says it: what it is about and one short line.
public struct CapsuleStatus: Equatable, Sendable {
    public let kind: CapsuleStatusKind
    public let text: String

    public init(kind: CapsuleStatusKind, text: String) {
        self.kind = kind
        self.text = text
    }

    /// For a `.done` message (`InsertResult.message`, `DoneText.pasteCancelled`, or a fallback).
    public static func done(_ message: String, inserted: String?, fits: (String) -> Bool) -> CapsuleStatus {
        if let line = CapsuleText.fallback(message, fits: fits) { return CapsuleStatus(kind: .fallback, text: line) }
        return CapsuleStatus(kind: CapsuleText.kind(done: message), text: CapsuleText.done(message, inserted: inserted, fits: fits))
    }

    public static func failed(_ message: String, fits: (String) -> Bool) -> CapsuleStatus {
        CapsuleStatus(kind: .failed, text: CapsuleText.failure(message, fits: fits))
    }
}

/// Short words for the capsule. The full message stays in the main window and history.
public enum CapsuleText {
    /// Characters typed, counted the way Chinese text is: one per Chinese character or full-width
    /// mark (and per emoji), one per English word or number; spaces and ASCII punctuation do not count.
    public static func typedCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for ch in text {
            if ch.isWhitespace { inWord = false; continue }
            if isWordCharacter(ch) {
                if !inWord { count += 1 }
                inWord = true
                continue
            }
            // "GPT-5", "OpenAI's", "3.5" stay one word.
            if inWord, "-'’._".contains(ch) { continue }
            inWord = false
            if ch.isASCII { continue }
            count += 1
        }
        return count
    }

    /// A letter or digit of a word written with spaces (Latin, Cyrillic…), not a Chinese,
    /// Japanese or Korean character, each of which counts on its own.
    private static func isWordCharacter(_ ch: Character) -> Bool {
        guard ch.isLetter || ch.isNumber, let v = ch.unicodeScalars.first?.value else { return false }
        let cjk = (0x2E80...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0x20000...0x3FFFF).contains(v)
        return !cjk
    }

    /// The capsule's own wording for messages written for the main window, where it says the same
    /// in fewer words.
    static let shortWording: [String: String] = [
        CaptureText.nearCap: "还剩 1 分钟，满 10 分钟自动结束",
        InsertResult.copiedNoField.message: "已复制，⌘V 粘贴",
        InsertResult.pastedKeptOnClipboard.message: "已输入，原剪贴板没放回",
        InsertResult.notInserted.message: "密码框不输入，在窗口里看",
        DoneText.pasteCancelled(keepHistory: true): "已取消，结果在历史记录",
        DoneText.pasteCancelled(keepHistory: false): "已取消，历史记录已关闭",
        CaptureText.nobodySpoke: "没听到说话，已自动结束",
        "没有识别出文字，请再说一次": "没听清，请再说一次",
        "没有听到声音，请检查麦克风": "没有声音，请检查麦克风",
    ]

    /// What a `.done` message is about.
    public static func kind(done message: String) -> CapsuleStatusKind {
        if FailureText.fallback(message) != nil { return .fallback }
        if message.hasPrefix("已复制") { return .copied }
        if message == DoneText.pasteCancelled(keepHistory: true) || message == DoneText.pasteCancelled(keepHistory: false) {
            return .cancelled
        }
        if message.hasPrefix("密码框") { return .secure }
        if message.hasPrefix("已输入，") { return .kept }
        if message.hasPrefix(LearningText.learnedPrefix) { return .learned }
        if message.hasPrefix(LearningText.missedPrefix) || message.hasPrefix(LearningText.unwatchedPrefix)
            || message.hasPrefix(LearningText.notedPrefix) || message == LearningText.notedRest { return .note }
        return .done
    }

    /// The done label: "已输入 23 字" for a plain paste of `inserted`; otherwise the controller's
    /// message in the capsule's wording. If that does not `fit`, a copy says why and what to do
    /// ("应用已切换，⌘V 粘贴"); otherwise the "（…）" aside goes.
    public static func done(_ message: String, inserted: String?, fits: (String) -> Bool = { _ in true }) -> String {
        if message == InsertResult.pasted.message, let inserted {
            let n = typedCount(inserted)
            return n > 0 ? "已输入 \(n) 字" : message
        }
        let line = shortWording[message] ?? message
        if fits(line) { return line }
        if let why = reasonFirst(line), fits(why) { return why }
        let bare = removingAside(line)
        return bare != line && fits(bare) ? bare : line
    }

    /// One line for a failure, the first of these that `fits`. After a short heading such as
    /// 识别出错, the cause says it best, like every other failure ("需要打开听写", as
    /// "需要麦克风权限"), then its first clause ("本机识别还没准备好"); an error code keeps its
    /// heading ("识别出错：错误代码 1700"). Then the whole message; without a trailing settings
    /// path; the heading ("需要麦克风权限"); the first clause ("麦克风没有声音进来"). Otherwise the
    /// message, which the capsule truncates.
    public static func failure(_ message: String, fits: (String) -> Bool) -> String {
        let line = shortWording[message] ?? message
        let bare = removingPath(line)
        var candidates: [String] = []
        var causes: [String] = []
        if let (head, cause) = split(bare), head.count <= 6 {
            causes.append(cause)
            if let clause = firstClause(cause) { causes.append(clause) }
        }
        let code = causes.first?.contains(where: { $0.isASCII && $0.isNumber }) == true
        if !code { candidates += causes }
        candidates += [line, bare]
        if code { candidates += causes }
        if let (head, _) = split(line), !head.isEmpty { candidates.append(head) }
        if let clause = firstClause(line) { candidates.append(clause) }
        return candidates.first(where: fits) ?? line
    }

    /// One line for a result that was typed (or copied) but not polished, or nil when `message` is
    /// not one: what happened and why ("已输入原文，网络中断") if it `fits`; else the same without
    /// a "（…）" aside or a product name in the reason ("已输入原文，额度暂时用完"); else what
    /// happened alone, saying it is the original text ("已复制原文，⌘V 粘贴").
    public static func fallback(_ message: String, fits: (String) -> Bool) -> String? {
        guard let (title, reason) = FailureText.fallback(message) else { return nil }
        let head = shortWording[title] ?? title
        let bareHead = removingAside(head)
        let bareReason = removingProductNames(reason)
        let alone = title.hasPrefix("已复制") ? "已复制原文，⌘V 粘贴" : bareHead
        let candidates = ["\(head)，\(reason)", "\(bareHead)，\(reason)", "\(bareHead)，\(bareReason)", alone, bareHead]
        return candidates.first(where: fits) ?? alone
    }

    /// A notice above the capsule, in the capsule's wording ("还剩 1 分钟，满 10 分钟自动结束"):
    /// whole if it `fits`, else its last clause (the capsule's countdown already says how long is
    /// left), which just fits the hands-free capsule counting down under it.
    public static func notice(_ text: String, fits: (String) -> Bool) -> String {
        let line = shortWording[text] ?? text
        guard !fits(line), let comma = line.lastIndex(of: "，") else { return line }
        let tail = String(line[line.index(after: comma)...])
        return tail.isEmpty ? line : tail
    }

    /// How the live transcript changed: the part already on screen (`stable`, the common prefix)
    /// and the newly recognised tail (`fresh`), which fades in. A revision of earlier words just
    /// shortens the stable part.
    public static func railSplit(old: String, new: String) -> (stable: String, fresh: String) {
        var end = new.startIndex
        var o = old.startIndex
        while end < new.endIndex, o < old.endIndex, new[end] == old[o] {
            end = new.index(after: end)
            o = old.index(after: o)
        }
        return (String(new[..<end]), String(new[end...]))
    }

    /// "需要麦克风权限：系统设置 › 隐私与安全性 › 麦克风" → ("需要麦克风权限", "系统设置 › …").
    public static func split(_ message: String) -> (head: String, tail: String)? {
        guard let colon = message.firstIndex(of: "：") else { return nil }
        let head = String(message[..<colon])
        let tail = message[message.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return tail.isEmpty ? nil : (head, tail)
    }

    /// "识别出错：需要打开听写：系统设置 › 键盘 › 听写" → "识别出错：需要打开听写": a settings
    /// path after the last "：" goes (the main window shows it).
    static func removingPath(_ message: String) -> String {
        guard let colon = message.lastIndex(of: "："), message[colon...].contains("›") else { return message }
        let head = String(message[..<colon])
        return head.isEmpty ? message : head
    }

    /// "麦克风没有声音进来，请在设置里换一个麦克风再试" → "麦克风没有声音进来", if at least four characters.
    static func firstClause(_ message: String) -> String? {
        guard let comma = message.firstIndex(of: "，") else { return nil }
        let clause = String(message[..<comma])
        return clause.count >= 4 ? clause : nil
    }

    /// "已复制（应用已切换），⌘V 粘贴" → "应用已切换，⌘V 粘贴": why it was only copied, then what to
    /// do (⌘V says it is on the clipboard). Nil for anything else.
    static func reasonFirst(_ message: String) -> String? {
        let open = "已复制（"
        guard message.hasPrefix(open), let close = message.firstIndex(of: "）") else { return nil }
        let why = message[message.index(message.startIndex, offsetBy: open.count)..<close]
        var rest = message[message.index(after: close)...]
        if rest.hasPrefix("，") { rest = rest.dropFirst() }
        guard !why.isEmpty, !rest.isEmpty else { return nil }
        return "\(why)，\(rest)"
    }

    /// "已复制（应用已切换），⌘V 粘贴" → "已复制，⌘V 粘贴".
    static func removingAside(_ message: String) -> String {
        message.replacingOccurrences(of: "（[^）]*）", with: "", options: .regularExpression)
    }

    /// "ChatGPT 额度暂时用完" → "额度暂时用完", "未登录 ChatGPT" → "未登录": Latin product names go
    /// when Chinese words remain to say what happened. "Neo" stays: it says where ("Neo 上 ChatGPT 登录已失效"
    /// → "Neo 上登录已失效").
    static func removingProductNames(_ reason: String) -> String {
        let words = reason.split(separator: " ").map(String.init)
        let kept = words.filter { word in word == "Neo" || !word.allSatisfy { $0.isASCII && $0.isLetter } }
        guard kept.contains(where: { $0 != "Neo" }) else { return reason }
        return MixedText.join(kept)
    }
}
