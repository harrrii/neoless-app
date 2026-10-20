import AppKit
import Testing
@testable import NeolessCore

@Suite struct CapsuleMetricsTests {
    @Test func looksHaveTheirSizes() {
        #expect(CapsuleLook.idle.size == CGSize(width: 40, height: 6))
        #expect(CapsuleLook.starting.size == CGSize(width: 54, height: 12))
        #expect(CapsuleLook.hold(countdown: false).size == CGSize(width: 70, height: 34))
        #expect(CapsuleLook.handsFree(countdown: false).size == CGSize(width: 116, height: 34))
        // The last minute's countdown adds a 32pt slot and 8pt after it.
        #expect(CapsuleLook.hold(countdown: true).size == CGSize(width: 110, height: 34))
        #expect(CapsuleLook.handsFree(countdown: true).size == CGSize(width: 156, height: 34))
        // 识别中 at 14pt is about 42pt: the fixed 92pt holds it with room to spare.
        #expect(CapsuleLook.processing(textWidth: 42).size == CGSize(width: 92, height: 34))
        #expect(CapsuleLook.processing(textWidth: 10).size.width == CapsuleMetrics.thinkingWidth)
        // Only a much longer word would widen it, and then to an even width.
        #expect(CapsuleLook.processing(textWidth: 60.5).size.width == 102)
        #expect(CapsuleLook.status(textWidth: 1_000).size == CGSize(width: CapsuleMetrics.maxStatusWidth, height: 34))
        // The line and the starting pill are half black; only hands-free takes clicks.
        #expect(!CapsuleLook.idle.isSolid && !CapsuleLook.starting.isSolid)
        #expect(CapsuleLook.hold(countdown: false).isSolid && CapsuleLook.status(textWidth: 50).isSolid)
        #expect(CapsuleLook.handsFree(countdown: false).hasButtons && CapsuleLook.handsFree(countdown: true).hasButtons)
        #expect(!CapsuleLook.hold(countdown: false).hasButtons && !CapsuleLook.processing(textWidth: 42).hasButtons
            && !CapsuleLook.starting.hasButtons && !CapsuleLook.status(textWidth: 50).hasButtons && !CapsuleLook.idle.hasButtons)
    }

    @Test func handsFreeRowIsCentred() {
        // [7 | × 24 | 8 | wave 38 | 8 | ✓ 24 | 7]: the 102pt row centred in 116.
        #expect(CapsuleMetrics.inset == 7 && CapsuleMetrics.gap == 8 && CapsuleMetrics.button == 24)
        #expect(CapsuleMetrics.handsFreeWidth == 2 * (CapsuleMetrics.inset + CapsuleMetrics.button + CapsuleMetrics.gap)
            + CapsuleMetrics.waveBox)
        #expect(CapsuleMetrics.handsFreeWidth == 116)
        // Ten 2pt bars 2pt apart fill the 38pt wave box exactly; at most 18pt tall.
        #expect(CapsuleMetrics.bars == 10)
        #expect(CapsuleMetrics.waveWidth == CapsuleMetrics.waveBox)
        #expect(CapsuleMetrics.waveHeight == 18)
        // Hold to talk centres the wave with 16pt either side.
        #expect((CapsuleMetrics.holdWidth - CapsuleMetrics.waveBox) / 2 == 16)
        #expect(CapsuleMetrics.waveHeight < CapsuleMetrics.height - 2 * 4)
    }

    @Test func statusWidthFitsTheTextBetweenLimits() {
        #expect(CapsuleMetrics.statusWidth(textWidth: 0) == CapsuleMetrics.minStatusWidth)
        // The glyph disc is concentric with the rounded end.
        #expect(CapsuleMetrics.statusLeading + CapsuleMetrics.glyph / 2 == CapsuleMetrics.height / 2)
        let w = CapsuleMetrics.statusWidth(textWidth: 80.2)
        #expect(w == CapsuleMetrics.statusLeading + CapsuleMetrics.glyph + CapsuleMetrics.glyphGap + 81
            + CapsuleMetrics.statusTrailing + 1)
        #expect(CapsuleMetrics.statusWidth(textWidth: 1_000) == CapsuleMetrics.maxStatusWidth)
        // The widest text that still fits exactly fills the widest capsule.
        #expect(CapsuleMetrics.statusWidth(textWidth: CapsuleMetrics.maxStatusText) == CapsuleMetrics.maxStatusWidth)
        // Small: under twice the hands-free capsule, with room for twelve Chinese characters.
        #expect(CapsuleMetrics.maxStatusWidth <= 2 * CapsuleMetrics.handsFreeWidth - 28)
        #expect(CapsuleMetrics.maxStatusText >= 12 * 13 + 1)
    }

    @Test func everyWidthIsEven() {
        for t in stride(from: CGFloat(0), through: 400, by: 0.7) {
            #expect(CapsuleMetrics.statusWidth(textWidth: t).truncatingRemainder(dividingBy: 2) == 0)
            #expect(CapsuleMetrics.processingWidth(textWidth: t).truncatingRemainder(dividingBy: 2) == 0)
            #expect(CapsuleMetrics.railWidth(textWidth: t, capsuleWidth: 70).truncatingRemainder(dividingBy: 2) == 0)
        }
        for look in [CapsuleLook.idle, .starting, .hold(countdown: false), .hold(countdown: true),
                     .handsFree(countdown: false), .handsFree(countdown: true)] {
            #expect(look.size.width.truncatingRemainder(dividingBy: 2) == 0)
        }
        #expect(CapsuleMetrics.even(116) == 116 && CapsuleMetrics.even(115.2) == 116 && CapsuleMetrics.even(0) == 0)
    }

    @Test func railGrowsWithTextThenOverflows() {
        #expect(CapsuleMetrics.railWidth(textWidth: 100) == 100 + 2 * CapsuleMetrics.railPadding)
        #expect(!CapsuleMetrics.railOverflows(textWidth: 100))
        #expect(CapsuleMetrics.railWidth(textWidth: 900) == CapsuleMetrics.railMaxWidth)
        #expect(CapsuleMetrics.railOverflows(textWidth: 900))
        // Never wider than about twice the hands-free capsule.
        #expect(CapsuleMetrics.railMaxWidth <= 240)
    }

    @Test func railNeverEndsUpNarrowerThanTheCapsuleUnderIt() {
        let hf = CapsuleMetrics.handsFreeWidth
        // 114pt of text and padding over the 116pt capsule: the rail takes the capsule's width.
        #expect(CapsuleMetrics.railWidth(textWidth: 114 - 2 * CapsuleMetrics.railPadding, capsuleWidth: hf) == hf)
        #expect(CapsuleMetrics.railWidth(textWidth: 10, capsuleWidth: CapsuleMetrics.holdWidth) == CapsuleMetrics.holdWidth)
        // Wider text keeps its own width.
        #expect(CapsuleMetrics.railWidth(textWidth: 150, capsuleWidth: hf) == 150 + 2 * CapsuleMetrics.railPadding)
        #expect(CapsuleMetrics.railWidth(textWidth: 900, capsuleWidth: hf) == CapsuleMetrics.railMaxWidth)
    }

    @Test func railIsTheCapsulesWidthOrClearlyWider() {
        let hf = CapsuleMetrics.handsFreeWidth, pad = 2 * CapsuleMetrics.railPadding
        let overhang = 2 * CapsuleMetrics.railOverhang
        // A few points wider than the capsule (the 10-minute notice on the counting-down capsule,
        // a transcript growing past 116pt): wider by a deliberate step, never by a sliver.
        let countdown = CapsuleLook.handsFree(countdown: true).size.width
        #expect(CapsuleMetrics.railWidth(textWidth: 168 - pad, capsuleWidth: countdown) == countdown + overhang)
        #expect(CapsuleMetrics.railWidth(textWidth: 120 - pad, capsuleWidth: hf) == hf + overhang)
        #expect(CapsuleMetrics.railWidth(textWidth: hf + overhang - pad, capsuleWidth: hf) == hf + overhang)
        #expect(CapsuleMetrics.railWidth(textWidth: hf + overhang + 6 - pad, capsuleWidth: hf) == hf + overhang + 6)
        // Equal stays equal.
        #expect(CapsuleMetrics.railWidth(textWidth: countdown - pad, capsuleWidth: countdown) == countdown)
        for t in stride(from: CGFloat(0), through: 300, by: 0.7) {
            for capsule in [CapsuleMetrics.holdWidth, hf, countdown] {
                let w = CapsuleMetrics.railWidth(textWidth: t, capsuleWidth: capsule)
                #expect(w == capsule || w >= capsule + overhang || w == CapsuleMetrics.railMaxWidth, "\(t) on \(capsule)")
            }
        }
        // Not stacked on anything: just the text.
        #expect(CapsuleMetrics.railWidth(textWidth: 30) == 30 + pad)
    }

    @Test func tooltipStaysCentredOnItsButtonUnlessAtTheScreenEdge() {
        let hf = CapsuleMetrics.handsFreeWidth
        let reach = hf / 2 - CapsuleMetrics.inset - CapsuleMetrics.button / 2
        // In the middle of a screen (or with no screen): centred on × or ✓.
        let vf = CGRect(x: 0, y: 0, width: 1440, height: 875)
        #expect(CapsuleLayout.tipOffset(cancel: true, capsuleWidth: hf, tipWidth: 70, capsuleX: 720, in: vf) == -reach)
        #expect(CapsuleLayout.tipOffset(cancel: false, capsuleWidth: hf, tipWidth: 70, capsuleX: 720, in: vf) == reach)
        #expect(CapsuleLayout.tipOffset(cancel: true, capsuleWidth: hf, tipWidth: 70, capsuleX: 0, in: .null) == -reach)
        // The capsule pinned to the left margin: the × tip slides right to stay on screen.
        let left = PillPlacement.margin + hf / 2
        let x = CapsuleLayout.tipOffset(cancel: true, capsuleWidth: hf, tipWidth: 70, capsuleX: left, in: vf)
        #expect(abs(left + x - 35 - CapsuleLayout.tipMargin) < 0.001)
        // And the ✓ tip at the right edge slides left.
        let right = vf.maxX - PillPlacement.margin - hf / 2
        let y = CapsuleLayout.tipOffset(cancel: false, capsuleWidth: hf, tipWidth: 70, capsuleX: right, in: vf)
        #expect(abs(right + y + 35 - (vf.maxX - CapsuleLayout.tipMargin)) < 0.001)
        // A short tip that fits is never moved.
        #expect(CapsuleLayout.tipOffset(cancel: true, capsuleWidth: hf, tipWidth: 30, capsuleX: left, in: vf) == -reach)
    }

    @Test func stackIncludesTheRailOnlyWhenOn() {
        #expect(CapsuleMetrics.stackSize(rail: false) == CGSize(width: CapsuleMetrics.handsFreeWidth, height: CapsuleMetrics.height))
        #expect(CapsuleMetrics.stackSize(rail: true).height
            == CapsuleMetrics.height + CapsuleMetrics.railGap + CapsuleMetrics.railHeight)
    }

    @Test func panelHoldsTheWidestContentShiftedToTheEdge() {
        // Worst case: the hands-free capsule pinned at the left margin, the widest content clamped
        // to the same margin, so its far edge is width - handsFreeWidth/2 from the anchor.
        let vf = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let anchorX = PillPlacement.margin + CapsuleMetrics.handsFreeWidth / 2
        for width in [CapsuleMetrics.railMaxWidth, CapsuleMetrics.maxStatusWidth, CapsuleMetrics.minStatusWidth,
                      CapsuleMetrics.holdWidth, CapsuleLook.handsFree(countdown: true).size.width] {
            let centre = CapsuleLayout.centreX(anchorX: anchorX, width: width, in: vf)
            #expect(abs(centre + width / 2 - anchorX) <= CapsuleMetrics.panelHalfWidth + 0.001)
            #expect(abs(centre - width / 2 - anchorX) <= CapsuleMetrics.panelHalfWidth + 0.001)
        }
    }

    @Test func panelLeavesRoomForTheLongShadow() {
        // The long shadow falls 25pt below with a 30pt blur: it needs more room below than above.
        #expect(CapsuleMetrics.shadowBottom >= 25 + 30)
        #expect(CapsuleMetrics.shadowSide >= 30)
        #expect(CapsuleMetrics.shadowTop >= 20)
        #expect(CapsuleMetrics.panelSize.width == CapsuleMetrics.panelContentSize.width + 2 * CapsuleMetrics.shadowSide)
        #expect(CapsuleMetrics.panelSize.height
            == CapsuleMetrics.panelContentSize.height + CapsuleMetrics.shadowTop + CapsuleMetrics.shadowBottom)
    }

    @Test func panelOriginPutsTheCapsuleOnThePlacement() {
        let w = CapsuleMetrics.handsFreeWidth
        for rail in [false, true] {
            let size = CapsuleMetrics.stackSize(rail: rail)
            let origin = CGPoint(x: 600, y: 18)
            // Standing at the bottom of the screen: the capsule's bottom edge is the placement's.
            let up = CapsuleMetrics.panelOrigin(stack: origin, size: size, hangsBelow: false)
            let upCapsule = CapsuleMetrics.capsuleFrame(width: w, offset: 0, hangsBelow: false).offsetBy(dx: up.x, dy: up.y)
            #expect(upCapsule.minY == origin.y)
            #expect(upCapsule.midX == origin.x + size.width / 2)
            // Hanging below a caret: the capsule's top edge is the top of the placement box.
            let down = CapsuleMetrics.panelOrigin(stack: origin, size: size, hangsBelow: true)
            let downCapsule = CapsuleMetrics.capsuleFrame(width: w, offset: 0, hangsBelow: true).offsetBy(dx: down.x, dy: down.y)
            #expect(downCapsule.maxY == origin.y + size.height)
            #expect(downCapsule.midX == origin.x + size.width / 2)
        }
    }

    @Test func clickableFrameIsOnlyTheCapsule() {
        let panel = CGRect(origin: .zero, size: CapsuleMetrics.panelSize)
        let w = CapsuleMetrics.handsFreeWidth
        // Rail above: the capsule stands on the bottom of the content, centred on the panel.
        let up = CapsuleMetrics.capsuleFrame(width: w, offset: 0, hangsBelow: false)
        #expect(up.midX == panel.midX)
        #expect(up.minY == CapsuleMetrics.shadowBottom)
        #expect(up.size == CGSize(width: w, height: CapsuleMetrics.height))
        // Hanging below a caret: the capsule is at the top of the content, the rail underneath.
        let down = CapsuleMetrics.capsuleFrame(width: w, offset: 0, hangsBelow: true)
        #expect(down.maxY == panel.maxY - CapsuleMetrics.shadowTop)
        #expect(down.minX == up.minX)
        // The starting pill is centred on the same row.
        let starting = CapsuleMetrics.capsuleFrame(width: 54, height: 12, offset: 0, hangsBelow: false)
        #expect(starting.midY == up.midY && starting.midX == up.midX)
        // A sideways shift moves it by exactly that much, and it stays inside the panel.
        let widest = CapsuleMetrics.maxStatusWidth
        let shifted = CapsuleMetrics.capsuleFrame(width: widest, offset: (widest - w) / 2, hangsBelow: false)
        #expect(shifted.midX == panel.midX + (widest - w) / 2)
        #expect(panel.contains(shifted))
        // Most of the panel is not the capsule.
        #expect(up.width * up.height < panel.width * panel.height / 8)
    }
}

@Suite struct CapsuleLayoutTests {
    let vf = CGRect(x: 0, y: 0, width: 1440, height: 875)

    @Test func staysCentredWhenThereIsRoom() {
        #expect(CapsuleLayout.centreX(anchorX: 720, width: 280, in: vf) == 720)
        #expect(CapsuleLayout.offset(anchorX: 720, width: 360, in: vf) == 0)
    }

    @Test func slidesInsideNearAnEdge() {
        // A hands-free capsule clamped at the left margin; the failure line is wider and must slide right.
        let anchorX = PillPlacement.margin + CapsuleMetrics.handsFreeWidth / 2
        #expect(CapsuleLayout.offset(anchorX: anchorX, width: CapsuleMetrics.handsFreeWidth, in: vf) == 0)
        let shift = CapsuleLayout.offset(anchorX: anchorX, width: 200, in: vf)
        #expect(shift == (200 - CapsuleMetrics.handsFreeWidth) / 2)
        #expect(anchorX + shift - 100 == PillPlacement.margin)
        // Right edge, the other way.
        let right = vf.maxX - PillPlacement.margin - CapsuleMetrics.handsFreeWidth / 2
        #expect(CapsuleLayout.offset(anchorX: right, width: 200, in: vf) == -(200 - CapsuleMetrics.handsFreeWidth) / 2)
    }

    @Test func narrowerContentNeverShifts() {
        let anchorX = PillPlacement.margin + CapsuleMetrics.handsFreeWidth / 2
        #expect(CapsuleLayout.offset(anchorX: anchorX, width: CapsuleMetrics.minStatusWidth, in: vf) == 0)
        #expect(CapsuleLayout.offset(anchorX: anchorX, width: CapsuleMetrics.holdWidth, in: vf) == 0)
    }

    @Test func secondScreenWithNegativeOrigin() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1050)
        let anchorX = left.minX + PillPlacement.margin + CapsuleMetrics.handsFreeWidth / 2
        let c = CapsuleLayout.centreX(anchorX: anchorX, width: 360, in: left)
        #expect(c - 180 == left.minX + PillPlacement.margin)
    }

    @Test func placementUsesTheRealCapsuleSize() {
        // Caret near the right edge: the 340pt box used to push the pill ~50pt off the caret.
        let line = CGRect(x: 1300, y: 500, width: 0, height: 18)
        let size = CapsuleMetrics.stackSize(rail: false)
        let p = PillPlacement.placePill(size: size, caret: line, screenVisibleFrame: vf)
        #expect(p.x + size.width / 2 == 1300)
        #expect(p.y == 500 - PillPlacement.gap - CapsuleMetrics.height)
    }

    @Test func withoutACaretItSitsBottomCentreAboveTheDock() {
        // The visible frame already excludes the Dock: the capsule stands just above it, centred.
        let withDock = CGRect(x: 0, y: 80, width: 1440, height: 795)
        let size = CapsuleMetrics.stackSize(rail: true)
        let p = PillPlacement.placePill(size: size, anchor: .none, screenVisibleFrame: withDock)
        #expect(p.x + size.width / 2 == withDock.midX)
        #expect(p.y == withDock.minY + PillPlacement.bottomInset)
        #expect(!PillPlacement.isBelow(p, size: size, anchor: .none))
    }

    @Test func railMakesRoomOnTheChosenSide() {
        // Just enough room below for the capsule alone, not for capsule + rail: it goes above.
        let size = CapsuleMetrics.stackSize(rail: true)
        let line = CGRect(x: 700, y: CapsuleMetrics.height + PillPlacement.gap + PillPlacement.margin + 2, width: 0, height: 18)
        let p = PillPlacement.placePill(size: size, caret: line, screenVisibleFrame: vf)
        #expect(!PillPlacement.isBelow(p, size: size, anchor: .caret(line)))
        #expect(p.y == line.maxY + PillPlacement.gap)
    }
}

@Suite struct AmplitudeSmootherTests {
    @Test func gateKeepsRoomNoiseStill() {
        #expect(AmplitudeSmoother.target(level: 0) == 0)
        #expect(AmplitudeSmoother.target(level: 0.1) == 0)
        #expect(AmplitudeSmoother.target(level: AmplitudeSmoother.gate) == 0)
        #expect(AmplitudeSmoother.target(level: .nan) == 0)
        var s = AmplitudeSmoother()
        for _ in 0..<60 { s.step(level: 0.11, dt: 1.0 / 30) }
        #expect(s.value == 0)
    }

    @Test func gammaLiftsNormalSpeech() {
        let mid = (AmplitudeSmoother.gate + AmplitudeSmoother.full) / 2
        let t = AmplitudeSmoother.target(level: mid)
        #expect(t > 0.6 && t < 0.75)            // 0.5^0.55 ≈ 0.68
        #expect(AmplitudeSmoother.target(level: 0.95) == 1)
        #expect(AmplitudeSmoother.target(level: 2) == 1)
    }

    @Test func fastAttackSlowRelease() {
        var s = AmplitudeSmoother()
        let up = s.step(level: 1, dt: 1.0 / 30)
        #expect(up > 0.5 && up < 0.65)          // about 0.56 of the way in one 30 Hz frame
        for _ in 0..<10 { s.step(level: 1, dt: 1.0 / 30) }
        #expect(s.value > 0.99)
        let down = s.step(level: 0, dt: 1.0 / 30)
        #expect(down > 0.78 && down < 0.85)     // only about 0.19 of the way back
        for _ in 0..<60 { s.step(level: 0, dt: 1.0 / 30) }
        #expect(s.value == 0)                    // settles fully: silence is calm dots
    }

    @Test func frameRateIndependent() {
        var a = AmplitudeSmoother(), b = AmplitudeSmoother()
        for _ in 0..<3 { a.step(level: 0.7, dt: 1.0 / 30) }
        b.step(level: 0.7, dt: 0.1)
        #expect(abs(a.value - b.value) < 0.0001)
    }

    @Test func monotoneAndBounded() {
        var s = AmplitudeSmoother()
        var last: Float = 0
        for level in stride(from: Float(0), through: 1, by: 0.05) {
            let v = s.step(level: level, dt: 1.0 / 30)
            #expect(v >= last && v <= 1)
            last = v
        }
        s.reset()
        #expect(s.value == 0)
    }
}

@Suite struct CapsuleWaveTests {
    let n = CapsuleMetrics.bars
    let steady = Array(repeating: Float(1), count: WaveTrail.length)

    func heights(_ levels: [Double]) -> [CGFloat] {
        CapsuleWave.heights(levels: levels, count: n, minHeight: CapsuleMetrics.barWidth, maxHeight: CapsuleMetrics.waveHeight)
    }

    @Test func silenceIsARowOfDots() {
        for trail in [[], [0, 0, 0], [Float.nan]] as [[Float]] {
            let levels = CapsuleWave.levels(trail: trail, count: n, shape: .even)
            #expect(heights(levels) == Array(repeating: CapsuleMetrics.barWidth, count: n))
        }
        // No levels at all (the meter's resting state) is the same row of dots.
        #expect(heights([]) == Array(repeating: CapsuleMetrics.barWidth, count: n))
    }

    @Test func peakIsOneOfTheTwoMiddleBars() {
        #expect(CapsuleWave.peak(count: 10, offset: 0) == 5)
        #expect(CapsuleWave.peak(count: 10, offset: -1) == 4)
        #expect(CapsuleWave.peak(count: 13, offset: 0) == 6)
        #expect(CapsuleWave.peak(count: 1, offset: -1) == 0)
        var g = SeededGenerator(seed: 1)
        var seen = Set<Int>()
        for _ in 0..<200 {
            let shape = WaveShape.random(count: n, using: &g)
            #expect(shape.peakOffset == 0 || shape.peakOffset == -1)
            seen.insert(shape.peakOffset)
            #expect(shape.decay.allSatisfy { (0...CapsuleWave.decayJitter).contains($0) })
            #expect(shape.wobble.allSatisfy { (0.9...1.1).contains($0) })
            #expect(shape.blend.allSatisfy { (0.65...0.75).contains($0) })
        }
        #expect(seen == [0, -1])
    }

    @Test func steadyVoiceIsAPeakFallingOffInAStraightLine() {
        let levels = CapsuleWave.levels(trail: steady, count: n, shape: .even)
        #expect(levels[5] == 1)
        // Down both sides to about a third at the ends (1 − 0.69).
        for i in 0..<5 { #expect(levels[i] < levels[i + 1]) }
        for i in 5..<(n - 1) { #expect(levels[i] > levels[i + 1]) }
        #expect(abs(levels[0] - 0.31) < 0.01 && abs(levels[n - 1] - 0.31) < 0.01)
        let h = heights(levels)
        #expect(h[5] == CapsuleMetrics.waveHeight)
        #expect(h.allSatisfy { $0 >= CapsuleMetrics.barWidth && $0 <= CapsuleMetrics.waveHeight })
        // Whole points, so the bars stay crisp.
        #expect(h.allSatisfy { $0 == $0.rounded() })
        // Over-range input is clamped.
        #expect(CapsuleWave.levels(trail: [5, 5, 5, 5, 5, 5, 5, 5], count: n, shape: .even) == levels)
    }

    @Test func randomnessMakesItLopsidedButRepeatable() {
        var a = SeededGenerator(seed: 42), b = SeededGenerator(seed: 42)
        let first = WaveShape.random(count: n, using: &a)
        #expect(first == WaveShape.random(count: n, using: &b))
        let levels = CapsuleWave.levels(trail: steady, count: n, shape: first)
        #expect(levels.allSatisfy { $0 >= 0 && $0 <= 1 })
        // Not a mirror image any more.
        let even = CapsuleWave.levels(trail: steady, count: n, shape: .even)
        #expect(levels != even)
        // The tallest bar is one of the middle two.
        let tallest = levels.indices.max { levels[$0] < levels[$1] }!
        #expect(tallest == 4 || tallest == 5)
    }

    @Test func aNewSoundStartsAtThePeakAndSpreads() {
        // Just arrived: the peak and its neighbours have it, the far bars not yet.
        let fresh = CapsuleWave.levels(trail: [1, 0, 0, 0, 0], count: n, shape: .even)
        #expect(fresh[5] == 1 && fresh[4] > 0 && fresh[6] > 0)
        #expect(fresh[0] == 0 && fresh[n - 1] == 0)
        // A frame or two later it reaches the ends.
        let later = CapsuleWave.levels(trail: [0, 0, 1, 0, 0], count: n, shape: .even)
        #expect(later[5] == 0 && later[0] > 0)
        // A short trail holds its oldest value outwards.
        let short = CapsuleWave.levels(trail: [0.5], count: n, shape: .even)
        #expect(short[0] > 0)
    }

    @Test func barsRiseAtOnceAndFallPartway() {
        let shape = WaveShape.even
        let up = CapsuleWave.blend(previous: [0.2], target: [0.9], shape: shape)
        #expect(up == [0.9])
        let down = CapsuleWave.blend(previous: [1], target: [0], shape: shape)
        #expect(abs(down[0] - 0.3) < 0.0001)
        // A missing or broken previous value starts from nothing; tiny values settle to zero.
        #expect(CapsuleWave.blend(previous: [], target: [0.4, 0.5], shape: shape) == [0.4, 0.5])
        #expect(CapsuleWave.blend(previous: [.nan], target: [0.4], shape: shape) == [0.4])
        #expect(CapsuleWave.blend(previous: [0.002], target: [0], shape: shape) == [0])
    }

    @Test func trailKeepsTheNewestFirst() {
        var trail = WaveTrail()
        #expect(trail.isSilent)
        for v in 1...10 { trail.push(Float(v) / 10) }
        #expect(trail.values.count == WaveTrail.length)
        #expect(trail.values.first == 1 && trail.values.last == 0.3)
        trail.push(.nan)
        #expect(trail.values.first == 0)
        trail.push(3)
        #expect(trail.values.first == 1)
        trail.reset()
        #expect(trail.isSilent && trail.values.isEmpty)
        #expect(WaveTrail(values: Array(repeating: 0, count: 20)).values.count == WaveTrail.length)
        // The home page's 13 bars reach 6 from the peak: the trail is long enough.
        #expect(CapsuleWave.lag(distance: 6) < WaveTrail.length)
    }
}

@Suite struct CapsuleMotionTests {
    @Test func bezierEasesAsExpected() {
        #expect(CubicBezier.easeOut.value(at: 0) == 0)
        #expect(CubicBezier.easeOut.value(at: 1) == 1)
        // ease-out is ahead of linear, ease-in-out symmetric about the middle.
        #expect(CubicBezier.easeOut.value(at: 0.5) > 0.65)
        #expect(abs(CubicBezier.easeInOut.value(at: 0.5) - 0.5) < 0.001)
        #expect(abs(CubicBezier.easeInOut.value(at: 0.25) + CubicBezier.easeInOut.value(at: 0.75) - 1) < 0.001)
        #expect(CubicBezier.easeOut.value(at: .nan) == 1)
        var last = -1.0
        for x in stride(from: 0.0, through: 1, by: 0.02) {
            let y = CubicBezier.easeOut.value(at: x)
            #expect(y >= last)
            last = y
        }
    }

    @Test func shimmerSweepsEasingOutThenRests() {
        #expect(CapsuleShimmer.period == 1.55 && CapsuleShimmer.sweep == 1.25)
        #expect(CapsuleShimmer.band == 24 && CapsuleShimmer.core == 8)
        #expect(CapsuleShimmer.progress(time: 0) == 0)
        #expect(CapsuleShimmer.progress(time: CapsuleShimmer.sweep) == 1)
        #expect(CapsuleShimmer.progress(time: CapsuleShimmer.period - 0.01) == 1)
        // Ease-out: fast at first.
        #expect(CapsuleShimmer.progress(time: CapsuleShimmer.sweep / 2) > 0.65)
        var last = -1.0
        for t in stride(from: 0.0, to: CapsuleShimmer.sweep, by: 0.05) {
            let p = CapsuleShimmer.progress(time: t)
            #expect(p >= last && p >= 0 && p <= 1)
            last = p
        }
    }

    @Test func shimmerRepeatsEveryPeriod() {
        for t in [0.1, 0.6, 1.1, 1.5] {
            #expect(abs(CapsuleShimmer.progress(time: t) - CapsuleShimmer.progress(time: t + 3 * CapsuleShimmer.period)) < 0.0001)
        }
        // Clock time since 2001 is large; negative or broken times stay in range.
        #expect((0...1).contains(CapsuleShimmer.progress(time: 781_000_000.37)))
        #expect((0...1).contains(CapsuleShimmer.progress(time: -0.4)))
        #expect(CapsuleShimmer.progress(time: .nan) == 1)
    }

    @Test func glintCrossesTheStartingPill() {
        #expect(CapsuleGlint.x(time: 0) == -27)
        #expect(abs(CapsuleGlint.x(time: 0.25) - (54 - 27) / 2) < 0.01)
        #expect(abs(CapsuleGlint.x(time: 0.4999) - 54) < 0.1)
        #expect(CapsuleGlint.x(time: 0.5) == -27)
        #expect(CapsuleGlint.x(time: .infinity) == -27)
    }

    @Test func progressKeepsMovingThroughAPolish() {
        #expect(CapsuleProgress.fraction(elapsed: 0) == 0)
        #expect(CapsuleProgress.fraction(elapsed: -1) == 0)
        #expect(abs(CapsuleProgress.fraction(elapsed: 0.5) - 0.225) < 0.0001)
        #expect(abs(CapsuleProgress.fraction(elapsed: 1) - 0.45) < 0.0001)
        #expect(abs(CapsuleProgress.fraction(elapsed: 3) - 0.735) < 0.0001)
        #expect(abs(CapsuleProgress.fraction(elapsed: 6) - 0.87) < 0.0001)
        #expect(CapsuleProgress.fraction(elapsed: 15) == 0.97)
        #expect(CapsuleProgress.fraction(elapsed: 600) == 0.97)
        #expect(CapsuleProgress.fraction(elapsed: .nan) == 0)
        // A usual one to five second polish ends with the fill still visibly moving, not parked
        // in the capsule's end cap.
        #expect(CapsuleProgress.fraction(elapsed: 5) < 0.9)
        var last = 0.0
        for t in stride(from: 0.0, through: 20, by: 0.1) {
            let f = CapsuleProgress.fraction(elapsed: t)
            #expect(f >= last && f < 1)
            last = f
        }
    }

    @Test func fillHasASoftEdgeAndFadesOnceComplete() {
        let w: CGFloat = 92
        #expect(CapsuleProgress.width(fraction: 0, capsuleWidth: w) == 0)
        #expect(CapsuleProgress.width(fraction: -1, capsuleWidth: w) == 0)
        #expect(CapsuleProgress.width(fraction: .nan, capsuleWidth: w) == 0)
        // Full: the soft edge lies past the capsule's end, so the solid part covers it all.
        let full = CapsuleProgress.width(fraction: 1, capsuleWidth: w)
        #expect(full == w + CapsuleProgress.feather)
        #expect(abs(CapsuleProgress.solidStop(width: full) * Double(full) - Double(w)) < 0.0001)
        // Half way: solid up to 10pt before its front.
        let half = CapsuleProgress.width(fraction: 0.5, capsuleWidth: w)
        #expect(abs(CapsuleProgress.solidStop(width: half) * Double(half) - Double(half - CapsuleProgress.feather)) < 0.0001)
        #expect(CapsuleProgress.solidStop(width: 4) == 0)
        #expect(CapsuleProgress.solidStop(width: 0) == 0)
        // Whole while working and while completing; gone before the result shows.
        #expect(CapsuleProgress.opacity(sinceCompleted: nil) == 1)
        #expect(CapsuleProgress.opacity(sinceCompleted: 0) == 1)
        #expect(CapsuleProgress.opacity(sinceCompleted: CapsuleTiming.fillFinish) == 1)
        let midFade = CapsuleProgress.opacity(sinceCompleted: CapsuleTiming.fillFinish + CapsuleProgress.fade / 2)
        #expect(midFade > 0 && midFade < 1)
        #expect(CapsuleProgress.opacity(sinceCompleted: CapsuleTiming.fillFinish + CapsuleProgress.fade) == 0)
        #expect(CapsuleTiming.fillFinish + CapsuleProgress.fade < CapsuleTiming.resultDelay)
        #expect(CapsuleProgress.opacity(sinceCompleted: .infinity) == 0)
    }

    @Test func progressCompletesThenHolds() {
        #expect(CapsuleProgress.finishing(from: 0.8, elapsed: 0) == 0.8)
        #expect(abs(CapsuleProgress.finishing(from: 0.8, elapsed: CapsuleTiming.fillFinish / 2) - 0.9) < 0.0001)
        #expect(CapsuleProgress.finishing(from: 0.8, elapsed: CapsuleTiming.fillFinish) == 1)
        #expect(CapsuleProgress.finishing(from: 0.8, elapsed: 5) == 1)
        #expect(abs(CapsuleTiming.resultDelay - 0.45) < 0.0001)
    }

    @Test func countdownReadsMinutesAndSeconds() {
        #expect(CapsuleCountdown.length == 60)
        #expect(CapsuleCountdown.text(remaining: 60) == "01:00")
        #expect(CapsuleCountdown.text(remaining: 59.2) == "01:00")
        #expect(CapsuleCountdown.text(remaining: 58.3) == "00:59")
        #expect(CapsuleCountdown.text(remaining: 9) == "00:09")
        #expect(CapsuleCountdown.text(remaining: 0.2) == "00:01")
        #expect(CapsuleCountdown.text(remaining: -3) == "00:00")
        #expect(CapsuleCountdown.text(remaining: .nan) == "00:00")
    }

    @Test func countdownFitsItsSlot() {
        // 12pt with monospaced digits, as the capsule draws it: "00:59" fills the 32pt slot,
        // spilling under a point each side into the 8pt gaps around it.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        for s in [60.0, 58.3, 9, 0.2] {
            let w = (CapsuleCountdown.text(remaining: s) as NSString).size(withAttributes: [.font: font]).width
            #expect(w >= CapsuleMetrics.countdownSlot - 2 && w <= CapsuleMetrics.countdownSlot + 2, "\(s): \(w)")
        }
    }
}

/// The capsule's text measured as the HUD draws it: 13pt regular in the widest status capsule.
private let statusFont = NSFont.systemFont(ofSize: 13, weight: .regular)
private func fits(_ s: String) -> Bool {
    (s as NSString).size(withAttributes: [.font: statusFont]).width + 1 <= CapsuleMetrics.maxStatusText
}

@Suite struct CapsuleTextTests {
    @Test func doneCountsCharactersTheChineseWay() {
        #expect(CapsuleText.typedCount("我明天下午四点开会。") == 10)
        #expect(CapsuleText.typedCount("push it to Friday") == 4)
        #expect(CapsuleText.typedCount("Hello world") == 2)
        #expect(CapsuleText.typedCount("我明天跟 Martin 开会") == 7)
        #expect(CapsuleText.typedCount("下午4点，GPT-5 和 OpenAI's 3.5 版") == 10)
        #expect(CapsuleText.typedCount("Hi, there.") == 2)
        #expect(CapsuleText.typedCount("第一行\n第二行") == 6)
        #expect(CapsuleText.typedCount("👍🏽好") == 2)
        #expect(CapsuleText.done("已输入", inserted: "我明天下午四点开会。") == "已输入 10 字")
        #expect(CapsuleText.done("已输入", inserted: nil) == "已输入")
        #expect(CapsuleText.done("已输入", inserted: "  ") == "已输入")
        #expect(CapsuleText.done(InsertResult.ownApp.message, inserted: "x") == InsertResult.ownApp.message)
    }

    @Test func doneUsesTheCapsulesShortWording() {
        #expect(CapsuleText.done("已复制，按 ⌘V 粘贴", inserted: "x", fits: fits) == "已复制，⌘V 粘贴")
        #expect(CapsuleText.done("已输入，剪贴板未恢复", inserted: "x", fits: fits) == "已输入，原剪贴板没放回")
        #expect(CapsuleText.done(DoneText.pasteCancelled(keepHistory: true), inserted: nil, fits: fits) == "已取消，结果在历史记录")
        #expect(CapsuleText.done(DoneText.pasteCancelled(keepHistory: false), inserted: nil, fits: fits) == "已取消，历史记录已关闭")
        #expect(CapsuleText.done(InsertResult.notInserted.message, inserted: nil, fits: fits) == "密码框不输入，在窗口里看")
        #expect(CapsuleText.kind(done: DoneText.pasteCancelled(keepHistory: false)) == .cancelled)
        // The aside goes only when the line would not fit.
        let switched = InsertResult.copiedAppChanged.message
        #expect(CapsuleText.done(switched, inserted: nil, fits: { _ in true }) == switched)
        // A copy that does not fit says why, then what to do; without room for that, just what to do.
        #expect(CapsuleText.done(switched, inserted: nil, fits: fits) == "应用已切换，⌘V 粘贴")
        #expect(CapsuleText.done(InsertResult.copiedFieldChanged.message, inserted: nil, fits: fits) == "输入框已切换，⌘V 粘贴")
        #expect(CapsuleText.done(switched, inserted: nil, fits: { $0.count <= 10 }) == "已复制，⌘V 粘贴")
        #expect(CapsuleText.reasonFirst("已复制（应用已切换），⌘V 粘贴") == "应用已切换，⌘V 粘贴")
        #expect(CapsuleText.reasonFirst("已复制，按 ⌘V 粘贴") == nil)
        #expect(CapsuleText.reasonFirst("已输入，剪贴板未恢复") == nil)
    }

    @Test func aPlainPasteCollapsesQuietly() {
        // The text at the cursor says it all.
        #expect(CapsuleTiming.collapsesQuietly(done: InsertResult.pasted.message))
        // Anything else says what happened.
        for message in [InsertResult.ownApp.message, InsertResult.pastedKeptOnClipboard.message,
                        InsertResult.copiedNoField.message, InsertResult.copiedAppChanged.message,
                        InsertResult.notInserted.message, DoneText.pasteCancelled(keepHistory: true),
                        FailureText.typedRaw(reason: "网络中断"), "\(InsertResult.copiedNoField.message) · 整理超时"] {
            #expect(!CapsuleTiming.collapsesQuietly(done: message), "\(message)")
        }
    }

    @Test func doneKindsPickTheGlyph() {
        #expect(CapsuleText.kind(done: InsertResult.pasted.message) == .done)
        #expect(CapsuleText.kind(done: InsertResult.ownApp.message) == .done)
        #expect(CapsuleText.kind(done: InsertResult.pastedKeptOnClipboard.message) == .kept)
        #expect(CapsuleText.kind(done: InsertResult.copiedNoField.message) == .copied)
        #expect(CapsuleText.kind(done: InsertResult.copiedAppChanged.message) == .copied)
        #expect(CapsuleText.kind(done: InsertResult.notInserted.message) == .secure)
        #expect(CapsuleText.kind(done: DoneText.pasteCancelled(keepHistory: true)) == .cancelled)
        #expect(CapsuleText.kind(done: FailureText.typedRaw(reason: "网络中断")) == .fallback)
        #expect(CapsuleStatus.done(FailureText.typedRaw(reason: "网络中断"), inserted: "x", fits: fits)
            == CapsuleStatus(kind: .fallback, text: "已输入原文，网络中断"))
        #expect(CapsuleStatus.done("已输入", inserted: "好", fits: fits) == CapsuleStatus(kind: .done, text: "已输入 1 字"))
        #expect(CapsuleStatus.failed("麦克风出错", fits: fits) == CapsuleStatus(kind: .failed, text: "麦克风出错"))
    }

    @Test func failureKeepsTheCause() {
        let path = "需要麦克风权限：系统设置 › 隐私与安全性 › 麦克风"
        #expect(CapsuleText.failure(path) { _ in true } == path)
        #expect(CapsuleText.failure(path, fits: fits) == "需要麦克风权限")
        // After 识别出错 the cause says it, like every other failure; an error code keeps the heading.
        #expect(CapsuleText.failure("识别出错：需要打开听写：系统设置 › 键盘 › 听写", fits: fits) == "需要打开听写")
        #expect(CapsuleText.failure("识别出错：需要打开听写：系统设置 › 键盘 › 听写") { _ in true } == "需要打开听写")
        #expect(CapsuleText.failure("识别出错：本机识别还没准备好，请稍后再试", fits: fits) == "本机识别还没准备好")
        #expect(CapsuleText.failure("识别出错：本机语音识别服务没有响应，请再试一次", fits: fits) == "本机语音识别服务没有响应")
        #expect(CapsuleText.failure("识别出错：错误代码 1700", fits: fits) == "识别出错：错误代码 1700")
        #expect(CapsuleText.failure("识别出错：错误代码 1700") { !$0.hasPrefix("识别出错") } == "错误代码 1700")
        // No "：" to cut at: the first clause, never a truncated sentence.
        #expect(CapsuleText.failure("麦克风没有声音进来，请在设置里换一个麦克风再试", fits: fits) == "麦克风没有声音进来")
        #expect(CapsuleText.failure("麦克风启动失败：音频格式不一致", fits: fits) == "麦克风启动失败")
        // The capsule's own wording for the long ones.
        #expect(CapsuleText.failure(CaptureText.nobodySpoke, fits: fits) == "没听到说话，已自动结束")
        #expect(CapsuleText.failure("没有识别出文字，请再说一次", fits: fits) == "没听清，请再说一次")
        #expect(CapsuleText.failure("没有听到声音，请检查麦克风", fits: fits) == "没有声音，请检查麦克风")
        // Nothing fits at all: the message, which the capsule truncates.
        #expect(CapsuleText.failure("没有识别出文字") { _ in false } == "没有识别出文字")
    }

    @Test func fallbackSaysWhyWhenItFits() {
        let typed = FailureText.typedRaw(reason: "ChatGPT 登录已过期")
        #expect(CapsuleText.fallback(typed) { _ in true } == "已输入原文，ChatGPT 登录已过期")
        #expect(CapsuleText.fallback(typed) { _ in false } == "已输入原文")
        let copied = "已复制，按 ⌘V 粘贴 · 整理超时"
        #expect(CapsuleText.fallback(copied) { _ in true } == "已复制，⌘V 粘贴，整理超时")
        #expect(CapsuleText.fallback(copied) { _ in false } == "已复制原文，⌘V 粘贴")
        // Plain successes are not fallbacks.
        #expect(CapsuleText.fallback("已输入") { _ in true } == nil)
        #expect(CapsuleText.fallback(InsertResult.notInserted.message) { _ in true } == nil)
    }

    @Test func fallbackKeepsItsReasonInTheSmallCapsule() {
        // Every polish reason still shows beside 已输入原文, a product name dropped if need be.
        for reason in ["网络中断", "没有网络", "网络超时", "连不上服务器", "安全连接失败", "网络出错",
                       "未登录 ChatGPT", "ChatGPT 登录已过期", "ChatGPT 登录已失效", "ChatGPT 额度暂时用完",
                       "ChatGPT 出错", "整理失败", "整理结果为空", "整理超时", "整理中断"] {
            let line = CapsuleText.fallback(FailureText.typedRaw(reason: reason), fits: fits)
            #expect(line.map(fits) == true, "\(reason)")
            #expect(line?.hasPrefix("已输入原文，") == true, "\(reason)")
            #expect(line?.hasSuffix(CapsuleText.removingProductNames(reason)) == true, "\(reason)")
        }
        #expect(CapsuleText.fallback(FailureText.typedRaw(reason: "ChatGPT 额度暂时用完"), fits: fits) == "已输入原文，额度暂时用完")
        #expect(CapsuleText.fallback(FailureText.typedRaw(reason: "网络中断"), fits: fits) == "已输入原文，网络中断")
        // The Neo typed the original (`HubDictation.reason`): with where it happened, or (too long for the
        // capsule) 已输入原文 alone, never half a reason ("上 登录已过期").
        for reason in ["Neo 上 ChatGPT 登录已过期", "Neo 上未登录 ChatGPT", "Neo 上 ChatGPT 额度暂时用完", "Neo 上整理超时",
                       "Neo 上整理失败", "Neo 上没有整理"] {
            let line = CapsuleText.fallback(FailureText.typedRaw(reason: reason), fits: fits)
            #expect(line.map(fits) == true, "\(reason)")
            #expect(line == "已输入原文" || line?.hasPrefix("已输入原文，Neo 上") == true, "\(reason) → \(line ?? "")")
        }
        #expect(CapsuleText.fallback(FailureText.typedRaw(reason: "Neo 上整理超时")) { _ in true } == "已输入原文，Neo 上整理超时")
        #expect(CapsuleText.removingProductNames("Neo 上 ChatGPT 登录已过期") == "Neo 上登录已过期")
        #expect(CapsuleText.removingProductNames("Neo") == "Neo")
        // A copy drops the "（…）" aside first; when the reason still does not fit, it says the
        // copy is the original text, so the amber glyph is never left unexplained.
        #expect(CapsuleText.fallback("\(InsertResult.copiedAppChanged.message) · 网络中断", fits: { $0.count <= 14 })
            == "已复制，⌘V 粘贴，网络中断")
        #expect(CapsuleText.fallback("\(InsertResult.copiedAppChanged.message) · 网络中断", fits: fits) == "已复制原文，⌘V 粘贴")
        #expect(CapsuleText.fallback("\(InsertResult.copiedFieldChanged.message) · ChatGPT 额度暂时用完", fits: fits)
            == "已复制原文，⌘V 粘贴")
        // A longer title drops the reason rather than truncating.
        #expect(CapsuleText.fallback("\(InsertResult.notInserted.message) · ChatGPT 额度暂时用完", fits: fits) == "密码框不输入，在窗口里看")
    }

    @Test func noticeKeepsItsLastClauseWhenLong() {
        #expect(CapsuleText.notice(CaptureText.nearCap) { _ in true } == "还剩 1 分钟，满 10 分钟自动结束")
        #expect(CapsuleText.notice(CaptureText.nearCap) { _ in false } == "满 10 分钟自动结束")
        #expect(CapsuleText.notice("一句话") { _ in false } == "一句话")
        #expect(CapsuleText.notice("还剩一会，结束") { _ in true } == "还剩一会，结束")
    }

    /// Every message the controller can show in the capsule comes out whole, on one line.
    @Test func everyRealMessageFitsTheSmallCapsule() {
        let inserts: [InsertResult] = [.pasted, .ownApp, .copiedAppChanged, .copiedFieldChanged, .copiedNoField,
                                       .copiedSecureInput, .copiedNoAccessibility, .notInserted, .pastedKeptOnClipboard,
                                       .copiedWaiting, .copiedNotTaken]
        let reasons = ["网络中断", "没有网络", "网络超时", "连不上服务器", "安全连接失败", "网络出错", "未登录 ChatGPT",
                       "ChatGPT 登录已过期", "ChatGPT 登录已失效", "ChatGPT 额度暂时用完", "ChatGPT 出错", "整理失败",
                       "整理结果为空", "整理超时", "整理中断"]
        var done = inserts.map(\.message) + [DoneText.pasteCancelled(keepHistory: true), DoneText.pasteCancelled(keepHistory: false)]
        for insert in inserts where insert != .pasted && insert != .pastedKeptOnClipboard {
            done += reasons.map { "\(insert.message) · \($0)" }
        }
        done += reasons.map(FailureText.typedRaw(reason:))
        for message in done {
            let status = CapsuleStatus.done(message, inserted: "我明天下午四点跟 Martin 开个会，讨论一下订阅费用", fits: fits)
            #expect(fits(status.text), "\(message) → \(status.text)")
        }
        let speech = [("kLSRErrorDomain", 201), ("kAFAssistantErrorDomain", 1101), ("kAFAssistantErrorDomain", 1700),
                      ("kAFAssistantErrorDomain", 1234)].compactMap {
            SpeechErrorText.message(domain: $0.0, code: $0.1, description: "")
        }
        let failures = speech.map { "识别出错：\($0)" } + [
            CaptureText.nobodySpoke, "没有识别出文字，请再说一次", "没有听到声音，请检查麦克风", "麦克风出错",
            "需要麦克风权限：系统设置 › 隐私与安全性 › 麦克风", "需要语音识别权限：系统设置 › 隐私与安全性 › 语音识别",
            "需要下载识别语言：系统设置 › 键盘 › 听写 › 语言",
            // AudioRecorder's errors.
            "没有可用的麦克风", "麦克风启动失败：音频格式不一致", "麦克风启动失败：音频格式不支持",
            "麦克风没有声音进来，请在设置里换一个麦克风再试",
        ]
        for message in failures {
            let status = CapsuleStatus.failed(message, fits: fits)
            #expect(fits(status.text), "\(message) → \(status.text)")
            #expect(!status.text.isEmpty)
        }
    }

    @Test func splitsAtTheColon() {
        let parts = CapsuleText.split("需要麦克风权限：系统设置 › 隐私与安全性 › 麦克风")
        #expect(parts?.head == "需要麦克风权限")
        #expect(parts?.tail == "系统设置 › 隐私与安全性 › 麦克风")
        #expect(CapsuleText.split("网络中断，已输入原文") == nil)
        #expect(CapsuleText.split("需要权限：") == nil)
        #expect(CapsuleText.removingPath("识别出错：需要打开听写：系统设置 › 键盘 › 听写") == "识别出错：需要打开听写")
        #expect(CapsuleText.removingPath("麦克风启动失败：音频格式不一致") == "麦克风启动失败：音频格式不一致")
        #expect(CapsuleText.removingAside("已复制（应用已切换），⌘V 粘贴") == "已复制，⌘V 粘贴")
        #expect(CapsuleText.removingProductNames("未登录 ChatGPT") == "未登录")
        #expect(CapsuleText.removingProductNames("网络中断") == "网络中断")
    }

    @Test func railSplitFindsTheNewTail() {
        #expect(CapsuleText.railSplit(old: "", new: "我明天") == ("", "我明天"))
        #expect(CapsuleText.railSplit(old: "我明天", new: "我明天下午") == ("我明天", "下午"))
        // The recognizer revised an earlier word: only the common prefix stays put.
        #expect(CapsuleText.railSplit(old: "我明天下午三点", new: "我明天下午四点开会") == ("我明天下午", "四点开会"))
        #expect(CapsuleText.railSplit(old: "我明天下午", new: "我明天") == ("我明天", ""))
        #expect(CapsuleText.railSplit(old: "abc", new: "abc") == ("abc", ""))
    }
}

@Suite struct CapsuleTimingTests {
    @Test func plainResultsLeaveQuicklyOthersStay() {
        #expect(CapsuleTiming.linger(.done, text: "已输入 34 字") == 1.0)
        #expect(CapsuleTiming.linger(.copied, text: "已复制，⌘V 粘贴") == 2.6)
        #expect(CapsuleTiming.linger(.kept, text: "已输入，原剪贴板没放回") == 2.6)
        #expect(CapsuleTiming.linger(.fallback, text: "已输入原文，网络中断") == 2.8)
        #expect(CapsuleTiming.linger(.failed, text: "麦克风出错") == 3.2)
        // A little longer per character past twelve, never more than 3.6 s.
        #expect(abs(CapsuleTiming.linger(.copied, text: String(repeating: "字", count: 15)) - (2.6 + 3 * 0.08)) < 0.0001)
        #expect(CapsuleTiming.linger(.failed, text: String(repeating: "字", count: 40)) == 3.6)
        for kind in [CapsuleStatusKind.kept, .copied, .cancelled, .secure, .fallback, .failed] {
            #expect(CapsuleTiming.linger(kind, text: "x") > CapsuleTiming.linger(.done, text: "x"))
        }
    }

    @Test func onlyProducedResultsCompleteTheFill() {
        #expect(CapsuleTiming.completesFill(.done) && CapsuleTiming.completesFill(.copied) && CapsuleTiming.completesFill(.fallback))
        #expect(!CapsuleTiming.completesFill(.cancelled) && !CapsuleTiming.completesFill(.failed))
    }
}
