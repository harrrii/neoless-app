import CoreGraphics
import Foundation

/// Where the recording pill should be anchored. Rects are AppKit global coordinates.
public enum PillAnchor: Equatable, Sendable {
    /// A text line (caret or first selected character). The pill goes below it, or above if there is no room.
    case caret(CGRect)
    /// A large container (big text area, focused window). The pill sits bottom-centre inside it.
    case container(CGRect)
    /// Nothing usable. The pill sits bottom-centre of the screen.
    case none
}

/// Pure geometry for the recording pill. All rects are AppKit global coordinates
/// (bottom-left origin, y grows upward) unless a name says "AX" (top-left origin, y grows downward).
public enum PillPlacement {
    /// Caret line to pill.
    public static let gap: CGFloat = 8
    /// Pill to the edge of the visible frame.
    public static let margin: CGFloat = 10
    /// Distance from the bottom of the visible frame for the classic bottom-centre position.
    public static let bottomInset: CGFloat = 18
    /// Distance from the bottom of a container.
    public static let containerInset: CGFloat = 24

    /// AX/Quartz global rect -> AppKit global rect. `primaryHeight` is the height of the display
    /// with the menu bar (`NSScreen.screens[0]`, not `NSScreen.main`). Correct for screens with
    /// negative origins too, since both systems flip y around the same line.
    public static func appKitRect(fromAX r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.minY - r.height, width: r.width, height: r.height)
    }

    /// Inverse of `appKitRect(fromAX:)` (the flip is its own inverse).
    public static func axRect(fromAppKit r: CGRect, primaryHeight: CGFloat) -> CGRect {
        appKitRect(fromAX: r, primaryHeight: primaryHeight)
    }

    /// The screen that should host a pill anchored at `rect`: the one containing its centre,
    /// else the one it overlaps most, else nil.
    public static func screenIndex(for rect: CGRect, screenFrames: [CGRect]) -> Int? {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        if let i = screenFrames.firstIndex(where: { $0.contains(centre) }) { return i }
        var best: (index: Int, area: CGFloat)?
        for (i, frame) in screenFrames.enumerated() {
            let overlap = frame.intersection(rect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? -1) { best = (i, area) }
        }
        return best?.index
    }

    /// Bottom-left origin of the visible pill. `caret` nil means bottom-centre of the screen.
    public static func placePill(size: CGSize, caret: CGRect?, screenVisibleFrame vf: CGRect) -> CGPoint {
        placePill(size: size, anchor: caret.map(PillAnchor.caret) ?? .none, screenVisibleFrame: vf)
    }

    /// Bottom-left origin of the visible pill (`size` excludes any shadow padding), kept inside `vf`.
    public static func placePill(size: CGSize, anchor: PillAnchor, screenVisibleFrame vf: CGRect) -> CGPoint {
        switch anchor {
        case .none:
            return clamp(CGPoint(x: vf.midX - size.width / 2, y: vf.minY + bottomInset), size: size, in: vf)
        case .container(let c):
            return clamp(CGPoint(x: c.midX - size.width / 2, y: c.minY + containerInset), size: size, in: vf)
        case .caret(let line):
            let below = line.minY - gap - size.height
            let above = line.maxY + gap
            let need = size.height + gap + margin
            let roomBelow = line.minY - vf.minY
            let roomAbove = vf.maxY - line.maxY
            let y: CGFloat
            if roomBelow >= need {
                y = below
            } else if roomAbove >= need {
                y = above
            } else {
                // Neither fits cleanly (tiny screen or a huge line): take the roomier side, then clamp.
                y = roomBelow >= roomAbove ? below : above
            }
            return clamp(CGPoint(x: line.midX - size.width / 2, y: y), size: size, in: vf)
        }
    }

    /// True when a pill at `origin` sits under `anchor`'s line (so it should grow downward, away from the text).
    public static func isBelow(_ origin: CGPoint, size: CGSize, anchor: PillAnchor) -> Bool {
        guard case .caret(let line) = anchor else { return false }
        return origin.y + size.height <= line.minY + 0.5
    }

    /// Keeps the whole pill inside `vf` with `margin`. If the pill does not fit on an axis,
    /// it is centred on that axis instead of pinned to one edge.
    public static func clamp(_ p: CGPoint, size: CGSize, in vf: CGRect) -> CGPoint {
        func axis(_ v: CGFloat, _ length: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            let minV = lo + margin, maxV = hi - margin - length
            return maxV < minV ? (lo + hi - length) / 2 : min(max(v, minV), maxV)
        }
        return CGPoint(x: axis(p.x, size.width, vf.minX, vf.maxX), y: axis(p.y, size.height, vf.minY, vf.maxY))
    }

    /// Whether an AX caret/line rect is believable. Rejects NaN/inf, (0,0) origins, Electron's
    /// "x=0, y=screen height", zero-height and page-sized rects (Chromium returning the whole
    /// element), and anything outside the focused window or every screen.
    public static func isPlausibleLine(_ r: CGRect, within container: CGRect?, screensAX: [CGRect],
                                       maxLineHeight: CGFloat = 200, maxWidth: CGFloat = 600) -> Bool {
        guard isFinite(r), r.height >= 4, r.height <= maxLineHeight, r.width >= 0, r.width <= maxWidth else { return false }
        if r.minX == 0 && r.minY == 0 { return false }
        let probe = r.insetBy(dx: -2, dy: -2)
        if let container, container.width > 0, container.height > 0,
           !container.insetBy(dx: -4, dy: -4).intersects(probe) { return false }
        if !screensAX.isEmpty, !screensAX.contains(where: { $0.intersects(probe) }) { return false }
        return true
    }

    /// Whether an AX element/window frame is believable.
    public static func isPlausibleFrame(_ r: CGRect, screensAX: [CGRect], minSize: CGSize = CGSize(width: 8, height: 8)) -> Bool {
        guard isFinite(r), r.width >= minSize.width, r.height >= minSize.height else { return false }
        return screensAX.isEmpty || screensAX.contains { $0.intersects(r) }
    }

    private static func isFinite(_ r: CGRect) -> Bool {
        r.origin.x.isFinite && r.origin.y.isFinite && r.width.isFinite && r.height.isFinite
    }
}
