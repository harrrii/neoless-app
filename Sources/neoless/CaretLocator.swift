import AppKit
import ApplicationServices
import NeolessCore

/// Finds where the user is typing in the frontmost app, through Accessibility.
/// All AX calls run on a private serial queue under a hard deadline; the main thread
/// only snapshots screen geometry and converts the result.
@MainActor
enum CaretLocator {
    enum Source: String, Sendable { case caret, textMarker, element, window, mouseScreen }

    struct Location: Sendable {
        /// AppKit global coordinates.
        var anchor: PillAnchor
        /// visibleFrame of the screen the pill should live on.
        var visibleFrame: CGRect
        var source: Source
    }

    /// Caret -> text marker -> focused element -> focused window -> bottom-centre of the
    /// screen with the mouse. Never blocks the main thread and returns within about `timeout`.
    static func locateAnchor(timeout: TimeInterval = 0.15) async -> Location {
        guard let ctx = Context.capture() else { return mouseScreen() }
        let deadline = Deadline(seconds: timeout)
        let once = Once()
        let probe: Probe? = await withCheckedContinuation { cont in
            queue.async {
                let p = Self.probe(pid: ctx.pid, deadline: deadline, screensAX: ctx.screensAX)
                if once.claim() { cont.resume(returning: p) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout + 0.02) {
                if once.claim() { cont.resume(returning: nil) }
            }
        }
        return probe.map(ctx.resolve) ?? mouseScreen()
    }

    /// Bottom-centre of the screen with the mouse: the classic position.
    static func mouseScreen() -> Location {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        return Location(anchor: .none, visibleFrame: screen?.visibleFrame ?? .zero, source: .mouseScreen)
    }

    // MARK: Main-thread context

    private struct Context: Sendable {
        let pid: pid_t
        let primaryHeight: CGFloat
        let screenFrames: [CGRect]      // AppKit
        let visibleFrames: [CGRect]     // AppKit
        let screensAX: [CGRect]         // AX, for sanity checks off the main thread

        /// nil: skip AX entirely (not trusted, no frontmost app, or it is neoless itself, whose
        /// AX server runs on the main thread we would be waiting on).
        @MainActor static func capture() -> Context? {
            guard AXIsProcessTrusted(),
                  let app = NSWorkspace.shared.frontmostApplication,
                  app.processIdentifier != getpid(),
                  let primary = NSScreen.screens.first else { return nil }
            let screens = NSScreen.screens
            let h = primary.frame.maxY   // the primary screen's origin is (0,0)
            return Context(pid: app.processIdentifier, primaryHeight: h,
                           screenFrames: screens.map(\.frame), visibleFrames: screens.map(\.visibleFrame),
                           screensAX: screens.map { PillPlacement.axRect(fromAppKit: $0.frame, primaryHeight: h) })
        }

        @MainActor func resolve(_ p: Probe) -> Location {
            func appKit(_ r: CGRect) -> CGRect { PillPlacement.appKitRect(fromAX: r, primaryHeight: primaryHeight) }
            func visibleFrame(for r: CGRect) -> CGRect? {
                PillPlacement.screenIndex(for: r, screenFrames: screenFrames).map { visibleFrames[$0] }
            }
            if let c = p.caret {
                let r = appKit(c)
                if let vf = visibleFrame(for: r) { return Location(anchor: .caret(r), visibleFrame: vf, source: p.caretSource) }
            }
            if let e = p.element {
                let r = appKit(e)
                if let vf = visibleFrame(for: r) {
                    // A single-line field behaves like a caret line; a big text area is a container.
                    let visible = p.window.map { r.intersection(appKit($0)) }.flatMap { $0.isNull ? nil : $0 } ?? r
                    let anchor: PillAnchor = r.height <= 120 ? .caret(r) : .container(visible)
                    return Location(anchor: anchor, visibleFrame: vf, source: .element)
                }
            }
            if let w = p.window {
                let r = appKit(w)
                if let vf = visibleFrame(for: r) { return Location(anchor: .container(r), visibleFrame: vf, source: .window) }
            }
            return CaretLocator.mouseScreen()
        }
    }

    // MARK: Background AX probe (AX coordinates throughout)

    private struct Probe: Sendable {
        var caret: CGRect?
        var caretSource: Source = .caret
        var element: CGRect?
        var window: CGRect?
    }

    private nonisolated static let queue = DispatchQueue(label: "neoless.caret-locator", qos: .userInitiated)

    private nonisolated static func probe(pid: pid_t, deadline: Deadline, screensAX: [CGRect]) -> Probe {
        var out = Probe()
        // Timeouts are set per element: on the system-wide element they would change every AX call neoless makes.
        let app = AXUIElementCreateApplication(pid)
        deadline.arm(app)
        let focused = element(copy(app, kAXFocusedUIElementAttribute))
        if let focused { deadline.arm(focused) }

        // Window first: it is the reference frame for sanity-checking everything else.
        if !deadline.expired,
           let win = focused.flatMap({ element(copy($0, kAXWindowAttribute)) }) ?? element(copy(app, kAXFocusedWindowAttribute)) {
            deadline.arm(win)
            if let f = frame(of: win), PillPlacement.isPlausibleFrame(f, screensAX: screensAX, minSize: CGSize(width: 80, height: 40)) {
                out.window = f
            }
        }
        guard let focused, !deadline.expired else { return out }

        let window = out.window
        let ok: (CGRect) -> Bool = { PillPlacement.isPlausibleLine($0, within: window, screensAX: screensAX) }

        // 1. Selected range + bounds for range (Cocoa text, most Chromium text fields).
        deadline.arm(focused)
        if let sel = unpackRange(copy(focused, kAXSelectedTextRangeAttribute)) {
            out.caret = caretRect(in: focused, selection: sel, deadline: deadline, ok: ok)
        }
        // 2. WebKit/Chromium text markers (contenteditable: Gmail, Notion, Slack composer).
        if out.caret == nil, !deadline.expired {
            deadline.arm(focused)
            if let marker = copy(focused, "AXSelectedTextMarkerRange"),
               let r = unpackRect(copyParam(focused, "AXBoundsForTextMarkerRange", marker)) {
                // Keep the first line of a multi-line selection.
                let line = CGRect(x: r.minX, y: r.minY, width: 0, height: min(r.height, 60))
                if ok(line) { out.caret = line; out.caretSource = .textMarker }
            }
        }
        // 3. The focused element's frame.
        if out.caret == nil, !deadline.expired {
            deadline.arm(focused)
            if let f = frame(of: focused), PillPlacement.isPlausibleFrame(f, screensAX: screensAX),
               window.map({ $0.insetBy(dx: -4, dy: -4).intersects(f) }) ?? true {
                out.element = f
            }
        }
        return out
    }

    /// A zero-width rect at the insertion point (AX coordinates), or nil.
    private nonisolated static func caretRect(in el: AXUIElement, selection sel: CFRange, deadline: Deadline,
                                              ok: (CGRect) -> Bool) -> CGRect? {
        guard sel.location != kCFNotFound, sel.location >= 0, sel.length >= 0 else { return nil }
        let loc = sel.location
        func bounds(_ loc: Int, _ len: Int) -> CGRect? {
            guard !deadline.expired else { return nil }
            deadline.arm(el)
            var range = CFRange(location: loc, length: len)
            guard let v = AXValueCreate(.cfRange, &range) else { return nil }
            return unpackRect(copyParam(el, kAXBoundsForRangeParameterizedAttribute, v))
        }
        func edge(_ r: CGRect, x: CGFloat) -> CGRect? {
            let line = CGRect(x: x, y: r.minY, width: 0, height: r.height)
            return ok(line) ? line : nil
        }

        if sel.length > 0 {
            // The first selected character is where dictated text will land. (The bounds of a
            // multi-line range is one box around every line: useless as a line.)
            if let r = bounds(loc, 1), let line = edge(r, x: r.minX) { return line }
            if let r = bounds(loc, sel.length) { return edge(CGRect(x: r.minX, y: r.minY, width: 0, height: min(r.height, 40)), x: r.minX) }
            return nil
        }
        // a) Many Cocoa views answer a collapsed range with the caret rect itself.
        if let r = bounds(loc, 0), let line = edge(r, x: r.minX) { return line }
        // b) Trailing edge of the character before the caret, unless it is a newline (then it is on the previous line).
        if loc > 0, !isNewline(el, at: loc - 1, deadline: deadline), let r = bounds(loc - 1, 1), let line = edge(r, x: r.maxX) {
            return line
        }
        // c) Leading edge of the character after the caret (also covers the start of the text).
        let count = (copy(el, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
        if loc < (count ?? Int.max), let r = bounds(loc, 1) { return edge(r, x: r.minX) }
        return nil
    }

    private nonisolated static func isNewline(_ el: AXUIElement, at index: Int, deadline: Deadline) -> Bool {
        guard !deadline.expired else { return false }
        var range = CFRange(location: index, length: 1)
        guard let v = AXValueCreate(.cfRange, &range),
              let s = copyParam(el, kAXStringForRangeParameterizedAttribute, v) as? String else { return false }
        return s == "\n" || s == "\r" || s == "\u{2028}" || s == "\u{2029}"
    }

    // MARK: AX plumbing

    private nonisolated static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    private nonisolated static func copyParam(_ el: AXUIElement, _ attr: String, _ param: CFTypeRef) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(el, attr as CFString, param, &v) == .success ? v : nil
    }

    private nonisolated static func element(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// The AXValue inside `v` if it holds `type`.
    private nonisolated static func axValue(_ v: CFTypeRef?, _ type: AXValueType) -> AXValue? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let ax = v as! AXValue
        return AXValueGetType(ax) == type ? ax : nil
    }

    private nonisolated static func unpackRect(_ v: CFTypeRef?) -> CGRect? {
        var o = CGRect.zero
        guard let ax = axValue(v, .cgRect), AXValueGetValue(ax, .cgRect, &o) else { return nil }
        return o
    }

    private nonisolated static func unpackRange(_ v: CFTypeRef?) -> CFRange? {
        var o = CFRange()
        guard let ax = axValue(v, .cfRange), AXValueGetValue(ax, .cfRange, &o) else { return nil }
        return o
    }

    private nonisolated static func frame(of el: AXUIElement) -> CGRect? {
        var pos = CGPoint.zero, size = CGSize.zero
        guard let p = axValue(copy(el, kAXPositionAttribute), .cgPoint), AXValueGetValue(p, .cgPoint, &pos),
              let s = axValue(copy(el, kAXSizeAttribute), .cgSize), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    // MARK: Concurrency helpers

    private struct Deadline: Sendable {
        let end: DispatchTime
        init(seconds: TimeInterval) { end = .now() + seconds }
        var expired: Bool { DispatchTime.now() >= end }
        /// Per-element messaging timeout = the remaining budget, capped (never 0: that means "global default").
        func arm(_ el: AXUIElement) {
            let now = DispatchTime.now().uptimeNanoseconds
            let remaining = Double(end.uptimeNanoseconds > now ? end.uptimeNanoseconds - now : 0) / 1e9
            AXUIElementSetMessagingTimeout(el, Float(max(0.02, min(remaining, 0.1))))
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }
}
