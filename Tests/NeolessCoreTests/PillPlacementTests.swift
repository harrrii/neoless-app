import CoreGraphics
import Testing
@testable import NeolessCore

@Suite struct PillPlacementTests {
    /// AppKit visibleFrame: Dock at the bottom, menu bar on top.
    let vf = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let size = CGSize(width: 220, height: 40)

    @Test func belowCaretCentred() {
        let line = CGRect(x: 700, y: 500, width: 0, height: 18)
        let p = PillPlacement.placePill(size: size, caret: line, screenVisibleFrame: vf)
        #expect(p == CGPoint(x: 590, y: 452))
        #expect(PillPlacement.isBelow(p, size: size, anchor: .caret(line)))
    }

    @Test func flipsAboveNearBottom() {
        let line = CGRect(x: 700, y: 30, width: 0, height: 18)
        let p = PillPlacement.placePill(size: size, caret: line, screenVisibleFrame: vf)
        #expect(p.y == 56)
        #expect(!PillPlacement.isBelow(p, size: size, anchor: .caret(line)))
    }

    @Test func clampsHorizontally() {
        let left = PillPlacement.placePill(size: size, caret: CGRect(x: 5, y: 500, width: 0, height: 18), screenVisibleFrame: vf)
        #expect(left.x == 10)
        let right = PillPlacement.placePill(size: size, caret: CGRect(x: 1439, y: 500, width: 0, height: 18), screenVisibleFrame: vf)
        #expect(right.x == 1210)
    }

    @Test func noCaretBottomCentre() {
        #expect(PillPlacement.placePill(size: size, caret: nil, screenVisibleFrame: vf) == CGPoint(x: 610, y: 18))
    }

    @Test func containerBottomCentreInside() {
        let window = CGRect(x: 100, y: 200, width: 800, height: 500)
        let p = PillPlacement.placePill(size: size, anchor: .container(window), screenVisibleFrame: vf)
        #expect(p == CGPoint(x: 390, y: 224))
        #expect(!PillPlacement.isBelow(p, size: size, anchor: .container(window)))
    }

    @Test func secondaryScreenNegativeOrigin() {
        let left = CGRect(x: -1920, y: -200, width: 1920, height: 1055)
        let p = PillPlacement.placePill(size: size, caret: CGRect(x: -1900, y: -150, width: 0, height: 18), screenVisibleFrame: left)
        #expect(p.x == -1910 && p.y == -150 + 18 + 8)
    }

    @Test func tooBigIsCentred() {
        let tiny = CGRect(x: 0, y: 0, width: 200, height: 50)
        let p = PillPlacement.placePill(size: size, caret: nil, screenVisibleFrame: tiny)
        #expect(p == CGPoint(x: -10, y: 5))
    }

    @Test func axFlip() {
        // Primary 900 tall; AX rect at the top-left, 20 tall -> AppKit y = 880.
        #expect(PillPlacement.appKitRect(fromAX: CGRect(x: 10, y: 0, width: 2, height: 20), primaryHeight: 900)
                == CGRect(x: 10, y: 880, width: 2, height: 20))
        // A screen above the primary has a negative AX y.
        #expect(PillPlacement.appKitRect(fromAX: CGRect(x: 0, y: -1080, width: 1920, height: 1080), primaryHeight: 900)
                == CGRect(x: 0, y: 900, width: 1920, height: 1080))
        let r = CGRect(x: 3, y: 4, width: 5, height: 6)
        #expect(PillPlacement.axRect(fromAppKit: PillPlacement.appKitRect(fromAX: r, primaryHeight: 900), primaryHeight: 900) == r)
    }

    @Test func picksScreen() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        #expect(PillPlacement.screenIndex(for: CGRect(x: 2000, y: 500, width: 0, height: 18), screenFrames: screens) == 1)
        // Centre on neither screen: the larger overlap wins.
        #expect(PillPlacement.screenIndex(for: CGRect(x: 1300, y: 880, width: 200, height: 40), screenFrames: screens) == 0)
        #expect(PillPlacement.screenIndex(for: CGRect(x: 9000, y: 9000, width: 2, height: 18), screenFrames: screens) == nil)
    }

    @Test func rejectsGarbage() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        let window = CGRect(x: 400, y: 400, width: 500, height: 300)
        #expect(!PillPlacement.isPlausibleLine(.zero, within: nil, screensAX: screens))
        #expect(!PillPlacement.isPlausibleLine(CGRect(x: 0, y: 900, width: 0, height: 0), within: nil, screensAX: screens))
        #expect(!PillPlacement.isPlausibleLine(CGRect(x: 100, y: 100, width: 800, height: 700), within: nil, screensAX: screens))
        #expect(!PillPlacement.isPlausibleLine(CGRect(x: 5000, y: 100, width: 2, height: 18), within: nil, screensAX: screens))
        #expect(!PillPlacement.isPlausibleLine(CGRect(x: 50, y: 50, width: 2, height: 18), within: window, screensAX: screens))
        #expect(!PillPlacement.isPlausibleLine(CGRect(x: CGFloat.nan, y: 500, width: 2, height: 18), within: nil, screensAX: screens))
        #expect(PillPlacement.isPlausibleLine(CGRect(x: 500, y: 500, width: 2, height: 18), within: window, screensAX: screens))
        #expect(!PillPlacement.isPlausibleFrame(CGRect(x: 10, y: 10, width: 4, height: 4), screensAX: screens))
        #expect(PillPlacement.isPlausibleFrame(window, screensAX: screens))
    }
}
