import AppKit
import Combine
import NeolessCore
import SwiftUI

/// The floating recording capsule (and its live transcript rail), whose look follows the floating bars of
/// Typeless and OpenLess in spirit (see CREDITS.md): a small
/// opaque black pill with a hairline rim, at the bottom centre of the screen with the mouse, just
/// above the Dock (or under the text caret with 跟随光标). It never takes keyboard focus, so the
/// field you are dictating into stays focused. Its position is chosen once per dictation and stays
/// put until it hides; a wider state only slides sideways if it would leave the screen.
@MainActor
final class HUDController {
    static let panelSize = NSSize(width: CapsuleMetrics.panelSize.width, height: CapsuleMetrics.panelSize.height)
    /// A new dictation lets the previous capsule leave this quickly before it re-places.
    private static let handoff: TimeInterval = 0.12

    private let panel: NSPanel
    private let host: HUDHostingView<HUDPanelContent>
    private let presentation = HUDPresentation()
    /// Phase, level and transcript feeds, owned here so the capsule body never re-renders with them.
    private let feeds: HUDFeeds
    private let settings: AppSettings
    private weak var controller: DictationController?
    private var hideWork: DispatchWorkItem?
    /// Bumped on every placement and every hide, so a late caret lookup or fade-out does nothing.
    private var generation = 0
    /// Placed (or being placed) for the current dictation.
    private var placed = false
    /// When the exit animation now playing ends; a new placement waits for it instead of snapping.
    private var exitEnds: CFAbsoluteTime = 0
    /// The hands-free [× | wave | ✓] capsule is up, so its buttons may take clicks.
    private var interactive = false
    /// The last minute's countdown widens the hands-free capsule (and so its clickable frame).
    private var countingDown = false
    private var pointerMonitors: [Any] = []
    private var lastPhase = Phase.idle
    /// A learning line that came while a dictation had the capsule: said once the capsule is free again.
    private var heldLine = HeldLine<LearningStore.Announcement>()
    private var subscriptions = Set<AnyCancellable>()

    init(controller: DictationController) {
        self.controller = controller
        settings = controller.settings
        feeds = HUDFeeds(controller: controller)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Stays up while neoless is hidden (隐藏 neoless, ⌘H): a hidden app's windows only come back
        // once it is unhidden, and the capsule must show over whatever app the user dictates into.
        panel.canHide = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        // Clicks pass straight through unless the pointer is on the capsule's buttons (see `followPointer`).
        panel.ignoresMouseEvents = true
        let host = HUDHostingView(rootView: HUDPanelContent(controller: controller, feeds: feeds, presentation: presentation))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.host = host
        host.onPointer = { [weak self] in self?.followPointer() }
        // The sink runs before the new value is stored, so it carries the value along.
        feeds.countdown.$endsAt.map { $0 != nil }.removeDuplicates().sink { [weak self] on in
            self?.countingDown = on
            self?.followPointer()
        }.store(in: &subscriptions)
    }

    /// `buttons`: false for hold to talk, whose capsule is the wave alone.
    func update(_ phase: Phase, buttons: Bool = true) {
        hideWork?.cancel()
        // Only the hands-free recording capsule has buttons; nothing else ever blocks what is underneath.
        setInteractive(phase == .recording && buttons)
        // A dictation becomes visible at .starting, or straight at .recording when its press
        // resolved after the audio arrived: either way it gets a fresh placement.
        let previous = lastPhase
        let fresh = phase.isActive && !previous.isActive
        lastPhase = phase
        switch phase {
        case .idle, .cancelled: hide(); return
        case .starting: place(followCaret: settings.hudFollowsCaret && Permissions.accessibility)
        case .recording where fresh: place(followCaret: settings.hudFollowsCaret && Permissions.accessibility)
        default: if !placed { place(followCaret: false) }
        }
        // A plain paste shows nothing: the fill completes and fades, then the capsule
        // collapses. Any other result stays up long enough to read (and act on); after processing
        // it shows only once the fill has completed.
        if HUDFlow.collapsesQuietly(from: previous, to: phase) {
            hide(after: CapsuleTiming.resultDelay)
        } else if let status = Status(phase: phase, inserted: controller?.current?.finalText) {
            let lead = HUDFlow.completesFill(from: previous, to: phase) ? CapsuleTiming.resultDelay : 0
            hide(after: lead + CapsuleTiming.linger(status.kind, text: status.text))
        }
    }

    /// One line outside a dictation: what neoless just learned from an edit, or why it could not. The capsule
    /// shows it like a result, where the user is looking (by the caret with 跟随光标), and goes. Never over a
    /// dictation: while one is recording or being processed, or its result is still up, the line waits and is
    /// said when the capsule has gone (the fix made just before pressing the key is the one learned then). It
    /// waits at most `HeldLine.maxAge`, and says "已记住" only for what is still remembered by then.
    func announce(_ announcement: LearningStore.Announcement) {
        guard let controller else { return }
        guard !controller.phase.isActive, !controller.isCapturing, !lastPhase.isActive, !showsResult else {
            // The newest waits; a word remembered is not pushed out by a line about something that was not.
            heldLine.hold(announcement, at: ProcessInfo.processInfo.systemUptime) { waiting in
                if case .learned = waiting, case .learned = announcement { return false }
                if case .learned = waiting { return true }
                // Nor is a swap that was remembered pushed out by one, except by a word that was learned.
                if case .noted = waiting, case .learned = announcement { return false }
                if case .noted = waiting, case .noted = announcement { return false }
                if case .noted = waiting { return true }
                return false
            }
            return
        }
        let lines = Self.lines(for: announcement)
        guard let first = lines.first else { return }
        say(first, then: lines.dropFirst().first)
    }

    /// What the capsule says for `announcement`, in its own width: one line, or two said one after the other
    /// when a swap was remembered and the whole of that does not fit ("记下了：米线 → 曲线", then
    /// "再这样改一次就记住"). Empty when there is nothing worth a line.
    static func lines(for announcement: LearningStore.Announcement) -> [String] {
        switch announcement {
        case let .learned(pairs, terms): return [LearningText.learned(pairs: pairs, terms: terms, fits: Status.fits)]
        case .noted(let pairs): return LearningText.notedParts(pairs: pairs, fits: Status.fits)
        case .missed(let nothing): return LearningText.missed(nothing).map { [$0] } ?? []
        case .unwatched(let app): return [LearningText.unwatched(app: app, fits: Status.fits)]
        }
    }

    /// How long the first part of a line said in two stays before the second takes its place.
    private static let firstPart: TimeInterval = 1.5

    /// Shows `message` like a result. With `next`, that line takes its place after `firstPart` and stays as a
    /// line of its own does, unless a dictation or another line has the capsule by then.
    private func say(_ message: String, then next: String? = nil) {
        let phase = Phase.done(message)
        guard let status = Status(phase: phase, inserted: nil) else { return }
        hideWork?.cancel()
        setInteractive(false)
        lastPhase = phase
        feeds.phase.announce(phase)
        // A line still on screen is replaced where it stands; otherwise the capsule arrives as for a dictation.
        if !placed { place(followCaret: settings.hudFollowsCaret && Permissions.accessibility) }
        guard let next else { return hide(after: CapsuleTiming.linger(status.kind, text: status.text)) }
        // One work item, like every other hide: whatever takes the capsule next cancels it.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.lastPhase == phase else { return }
            guard self.placed, let controller = self.controller, !controller.phase.isActive, !controller.isCapturing else {
                return self.hide()
            }
            self.say(next)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstPart, execute: work)
    }

    /// A dictation's own result (or its failure) is on the capsule: a learning line waits for it to go.
    private var showsResult: Bool {
        guard placed, let controller else { return false }
        switch lastPhase {
        case .done, .failed: return lastPhase == controller.phase
        default: return false
        }
    }

    /// The capsule has gone: the line that waited for it is said now, if it is still true and still recent.
    private func sayHeldLine() {
        guard !heldLine.isEmpty, let controller, !controller.phase.isActive, !controller.isCapturing,
              let waiting = heldLine.take(at: ProcessInfo.processInfo.systemUptime),
              let line = controller.learning.current(waiting) else { return }
        announce(line)
    }

    /// Starts a fresh placement. With `followCaret`, the caret is looked up off the main
    /// thread (at most ~0.15 s) before the capsule first appears.
    private func place(followCaret: Bool) {
        generation += 1
        placed = true
        let current = generation
        if presentation.stage == .shown, panel.isVisible {
            // A new dictation while the last capsule is still up: let it go before re-placing.
            leave(HUDMotion.collapse(Self.handoff), duration: Self.handoff)
        }
        // Whatever exit is playing (this one, or a hide that was under way) finishes first.
        let settle = panel.isVisible ? max(0, exitEnds - CFAbsoluteTimeGetCurrent()) : 0
        guard followCaret || settle > 0 else { return reveal(at: CaretLocator.mouseScreen()) }
        let started = CFAbsoluteTimeGetCurrent()
        Task { @MainActor [weak self] in
            let location = followCaret ? await CaretLocator.locateAnchor(timeout: 0.15) : CaretLocator.mouseScreen()
            let wait = settle - (CFAbsoluteTimeGetCurrent() - started)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let self, self.generation == current else { return }
            self.reveal(at: location)
        }
    }

    private func reveal(at location: CaretLocator.Location) {
        let vf = location.visibleFrame
        // Placed from the real hands-free capsule (plus the rail when it is on), not a worst-case box.
        let stack = CapsuleMetrics.stackSize(rail: settings.liveTranscript)
        let origin = PillPlacement.placePill(size: stack, anchor: location.anchor, screenVisibleFrame: vf)
        let below = PillPlacement.isBelow(origin, size: stack, anchor: location.anchor)
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            presentation.stage = .hidden
            presentation.placement = HUDPlacement(anchorX: origin.x + stack.width / 2, visibleFrame: vf, hangsBelow: below)
        }
        panel.setFrameOrigin(CapsuleMetrics.panelOrigin(stack: origin, size: stack, hangsBelow: below))
        panel.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        followPointer()
        // Animate on the next turn, once the hidden line has been drawn at the new position: the
        // capsule grows out of it, or just fades in with Reduce Motion.
        let current = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == current else { return }
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            withAnimation(reduceMotion ? HUDMotion.fade : HUDMotion.morph) {
                self.presentation.stage = .shown
            }
        }
    }

    private func hide(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func hide() {
        generation += 1
        placed = false
        setInteractive(false)
        let current = generation
        guard panel.isVisible else {
            presentation.stage = .hidden
            feeds.phase.settle()
            sayHeldLine()
            return
        }
        let duration = HUDMotion.exitDuration
        if presentation.stage != .leaving {
            leave(HUDMotion.collapse(duration), duration: duration)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { [weak self] in
            guard let self, self.generation == current else { return }
            self.panel.orderOut(nil)
            self.presentation.stage = .hidden
            self.feeds.phase.settle()
            self.sayHeldLine()
        }
    }

    private func leave(_ animation: Animation, duration: TimeInterval) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? .easeOut(duration: duration) : animation) { presentation.stage = .leaving }
        exitEnds = CFAbsoluteTimeGetCurrent() + duration
        followPointer()
    }

    // MARK: Click-through

    /// While the buttons are up, follows the pointer so the panel takes the mouse only over the
    /// capsule itself; otherwise the panel ignores the mouse entirely.
    private func setInteractive(_ on: Bool) {
        interactive = on
        if on, pointerMonitors.isEmpty {
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                               .leftMouseUp, .rightMouseUp, .otherMouseUp]
            // While the panel ignores the mouse, moves reach other apps and arrive through the global
            // monitor; once it takes the mouse, through the host's tracking area and the local monitor.
            // Either way the panel re-checks at once.
            // Both handlers run on the main thread, from the app's event loop.
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
                self?.followPointer()
            }) { pointerMonitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
                self?.followPointer()
                return event
            }) { pointerMonitors.append(local) }
        } else if !on {
            pointerMonitors.forEach(NSEvent.removeMonitor)
            pointerMonitors = []
        }
        followPointer()
    }

    /// The hands-free capsule's frame in the panel while its buttons can be clicked; empty otherwise.
    private var buttonsFrame: NSRect {
        guard interactive, panel.isVisible, presentation.stage == .shown else { return .zero }
        let p = presentation.placement, w = CapsuleLook.handsFree(countdown: countingDown).size.width
        return CapsuleMetrics.capsuleFrame(width: w, offset: p.offset(width: w), hangsBelow: p.hangsBelow)
    }

    /// Takes the mouse only while the pointer is over the capsule, so the panel's large transparent
    /// area (and the rail) never blocks a click on the app underneath.
    private func followPointer() {
        let frame = buttonsFrame
        host.hitFrame = frame
        // Mid-press (a click on × dragged off it, or a drag in another app) keep things as they
        // are; the mouse-up re-checks.
        if !frame.isEmpty, NSEvent.pressedMouseButtons != 0 { return }
        let over = !frame.isEmpty && panel.convertToScreen(frame).contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
    }
}

/// Timing of the capsule: every change of size, its entrance (growing out of a
/// thin line) and its exit (collapsing back into it as it fades) ease out quickly, in
/// 0.2 s on one curve. Reduce Motion keeps the fades and drops the movement.
enum HUDMotion {
    static let morph = collapse(0.2)
    static func collapse(_ duration: TimeInterval) -> Animation {
        .timingCurve(0.05, 0.6, 0.4, 0.95, duration: duration)
    }
    /// Contents cross-fade while the shell changes size.
    static let contents = Animation.easeOut(duration: 0.14)
    static let exitDuration: TimeInterval = 0.2
    static let fade = Animation.easeOut(duration: 0.15)
}

/// Where the current dictation's capsule lives, in screen coordinates.
struct HUDPlacement: Equatable {
    /// Centre x of the hands-free capsule (the panel is centred on it).
    var anchorX: CGFloat
    var visibleFrame: CGRect
    /// Hanging below a caret line: the capsule is on top and the rail goes underneath.
    var hangsBelow: Bool

    /// For snapshots: the middle of a screen, nothing to clamp against.
    static let centred = HUDPlacement(anchorX: 0, visibleFrame: .null, hangsBelow: false)

    /// Sideways shift of content `width` wide so it stays on screen.
    func offset(width: CGFloat) -> CGFloat {
        visibleFrame.isNull ? 0 : CapsuleLayout.offset(anchorX: anchorX, width: width, in: visibleFrame)
    }
}

extension Phase {
    /// 识别中 or 整理中.
    var isProcessing: Bool { self == .transcribing || self == .polishing }
}

enum HUDFlow {
    /// Whether going from `old` to `new` first completes the processing fill and holds it a moment:
    /// only for a result that was produced, not for a cancelled paste or a failure.
    static func completesFill(from old: Phase, to new: Phase) -> Bool {
        guard old.isProcessing, case .done(let message) = new else { return false }
        return CapsuleTiming.completesFill(CapsuleText.kind(done: message))
    }

    /// Whether the result after processing is a plain paste, which shows no line of its own: the
    /// capsule completes its fill and collapses (`CapsuleTiming.collapsesQuietly`).
    static func collapsesQuietly(from old: Phase, to new: Phase) -> Bool {
        guard completesFill(from: old, to: new), case .done(let message) = new else { return false }
        return CapsuleTiming.collapsesQuietly(done: message)
    }
}

/// Entrance/exit state of the capsule inside the panel.
@MainActor
private final class HUDPresentation: ObservableObject {
    enum Stage { case hidden, shown, leaving }
    @Published var stage: Stage = .hidden
    @Published var placement = HUDPlacement.centred
}

/// What the capsule watches: the phase alone, the 30 Hz voice level, the live transcript and the
/// last minute's countdown. Its owner (the panel, or a snapshot) creates it once and hands it down,
/// so the level and the transcript re-render only the small wave and rail views, never the
/// capsule around them.
@MainActor
final class HUDFeeds {
    fileprivate let phase: HUDPhase
    fileprivate let meter: VoiceMeter
    fileprivate let rail: HUDRail
    fileprivate let countdown: HUDCountdown

    /// `railAlwaysOn`: snapshots show the rail whatever the 实时字幕 setting is.
    init(controller: DictationController, railAlwaysOn: Bool = false) {
        phase = HUDPhase(controller)
        meter = VoiceMeter(controller, count: CapsuleMetrics.bars)
        rail = HUDRail(controller, alwaysOn: railAlwaysOn)
        countdown = HUDCountdown(controller)
    }

    /// Snapshots only: a steady wave (amplitudes newest first) instead of one still rising from silence.
    func _debugHold(trail: [Float]) {
        meter._debugHold(trail: trail)
    }

    /// Snapshots only: the rail shows `text` (a notice about the recording, or a transcript)
    /// whatever the phase.
    func _debugRail(_ text: String, notice: Bool) {
        rail._debugShow(text, notice: notice)
    }

    /// Snapshots only: the last minute is counting down.
    func _debugCountdown() {
        countdown._debugStart()
    }
}

/// The panel's root: the capsule stack, which grows out of a thin line as it arrives and collapses
/// back into it as it leaves.
private struct HUDPanelContent: View {
    let controller: DictationController
    let feeds: HUDFeeds
    @ObservedObject var presentation: HUDPresentation

    var body: some View {
        HUDView(controller: controller, feeds: feeds, placement: presentation.placement,
                visible: presentation.stage == .shown)
            .padding(HUDView.shadowInsets)
    }
}

/// The panel's view. Buttons work with one click without activating neoless, and only the
/// capsule's own frame is hit-testable: a click anywhere else in the panel is never handled here.
final class HUDHostingView<Content: View>: NSHostingView<Content> {
    /// The clickable capsule, in window coordinates (y up); empty when it shows no buttons.
    var hitFrame: NSRect = .zero
    /// Called when the pointer moves within or leaves the panel while it takes the mouse, even
    /// with neoless in the background, so leaving the capsule hands clicks back at once.
    var onPointer: (() -> Void)?
    private lazy var pointerArea = NSTrackingArea(rect: .zero,
                                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                  owner: self, userInfo: nil)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(pointerArea) { addTrackingArea(pointerArea) }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointer?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointer?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates; `hitFrame` in the window's.
        let p = superview?.convert(point, to: nil) ?? point
        return hitFrame.contains(p) ? super.hitTest(point) : nil
    }
}

/// The capsule and its rail, filling the panel's content area. One black shell whose size eases
/// between looks while its contents cross-fade. It observes the phase and the
/// countdown; the wave and the rail observe their own feeds.
struct HUDView: View {
    /// The panel's transparent room around the content, for the shadow.
    static let shadowInsets = EdgeInsets(top: CapsuleMetrics.shadowTop, leading: CapsuleMetrics.shadowSide,
                                         bottom: CapsuleMetrics.shadowBottom, trailing: CapsuleMetrics.shadowSide)

    let controller: DictationController
    var placement = HUDPlacement.centred
    /// Up: when not, the capsule is the thin transparent line it grows out of.
    var visible = true
    private let feeds: HUDFeeds
    @ObservedObject private var state: HUDPhase
    @ObservedObject private var countdown: HUDCountdown
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The button whose tooltip shows, after a short hover.
    @State private var tip: HUDButton?
    @State private var hoverToken = 0

    init(controller: DictationController, feeds: HUDFeeds, placement: HUDPlacement = .centred, visible: Bool = true) {
        self.controller = controller
        self.feeds = feeds
        self.placement = placement
        self.visible = visible
        _state = ObservedObject(wrappedValue: feeds.phase)
        _countdown = ObservedObject(wrappedValue: feeds.countdown)
    }

    var body: some View {
        let face = Face(phase: state.phase, hold: state.hold, countdown: countdown.endsAt != nil,
                        inserted: controller.current?.finalText)
        let below = placement.hangsBelow
        // A button's tooltip shows where the rail is: the rail steps aside while it does (the
        // pointer is on the capsule then, not reading the transcript).
        let tipShown = face.look.hasButtons && (tip ?? HUDText._debugTip) != nil
        VStack(spacing: CapsuleMetrics.railGap) {
            if below { capsule(face) }
            RailView(rail: feeds.rail, placement: placement, capsuleWidth: face.look.size.width, dimmed: tipShown)
                .frame(height: CapsuleMetrics.railHeight)
            if !below { capsule(face) }
        }
        .frame(width: CapsuleMetrics.panelContentSize.width, height: CapsuleMetrics.panelContentSize.height)
        .opacity(visible ? 1 : 0)
        .onChange(of: face.key) { tip = nil }
    }

    private func capsule(_ face: Face) -> some View {
        let look = visible || reduceMotion ? face.look : .idle
        let size = look.size
        return ZStack {
            face.contents(controller: controller, feeds: feeds, hover: hover)
                .id(face.key)
                .transition(.opacity)
        }
        .animation(HUDMotion.contents, value: face.key)
        .frame(width: size.width, height: size.height)
        .clipShape(Capsule(style: .circular))
        .background(CapsuleShell(solid: look.isSolid))
        .overlay(alignment: placement.hangsBelow ? .bottom : .top) { buttonTip(look: look) }
        // Starting is a 12pt pill centred on the capsule's row.
        .frame(height: CapsuleMetrics.height)
        .offset(x: placement.offset(width: size.width))
        .animation(reduceMotion ? nil : HUDMotion.morph, value: look)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(face.accessibilityLabel)
    }

    /// The dark tooltip, 14pt above the hovered button (below it when the capsule hangs
    /// under a caret, where the panel has no room above), centred on it unless that would take it
    /// off the screen's edge.
    @ViewBuilder private func buttonTip(look: CapsuleLook) -> some View {
        if look.hasButtons, let kind = tip ?? HUDText._debugTip {
            let w = look.size.width
            let label = ButtonTip.Label(kind: kind, settings: controller.settings)
            let x = CapsuleLayout.tipOffset(cancel: kind == .cancel, capsuleWidth: w, tipWidth: label.width,
                                            capsuleX: placement.anchorX + placement.offset(width: w),
                                            in: placement.visibleFrame)
            // 14pt from the button, which sits 5pt inside the capsule's edge.
            let clearance = 14 - (CapsuleMetrics.height - CapsuleMetrics.button) / 2
            let below = placement.hangsBelow
            // A zero-height frame on the capsule's edge, the tip hanging off it outwards.
            ButtonTip(label: label)
                .frame(height: 0, alignment: below ? .top : .bottom)
                .offset(x: x, y: below ? clearance : -clearance)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func hover(_ kind: HUDButton, _ inside: Bool) {
        hoverToken += 1
        guard inside else {
            withAnimation(.easeOut(duration: 0.1)) { tip = nil }
            return
        }
        let token = hoverToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard hoverToken == token else { return }
            withAnimation(.easeOut(duration: 0.12)) { tip = kind }
        }
    }
}

/// What the capsule shows for a phase.
private enum Face: Equatable {
    case starting
    case hold(countdown: Bool)
    case handsFree(countdown: Bool)
    case processing(String)
    case status(Status)

    init(phase: Phase, hold: Bool, countdown: Bool, inserted: String?) {
        switch phase {
        case .recording: self = hold ? .hold(countdown: countdown) : .handsFree(countdown: countdown)
        case .transcribing: self = .processing("识别中")
        case .polishing: self = .processing("整理中")
        case .done, .failed: self = Status(phase: phase, inserted: inserted).map(Face.status) ?? .starting
        case .starting, .idle, .cancelled: self = .starting
        }
    }

    var look: CapsuleLook {
        switch self {
        case .starting: return .starting
        case .hold(let countdown): return .hold(countdown: countdown)
        case .handsFree(let countdown): return .handsFree(countdown: countdown)
        case .processing(let label): return .processing(textWidth: HUDText.width(label, HUDText.thinking))
        case .status(let status): return .status(textWidth: status.textWidth)
        }
    }

    /// A change of key cross-fades the contents. The countdown joining the recording capsule does
    /// not: the wave stays put while the capsule widens. Nor does 识别中 turning into 整理中: only
    /// the word changes, over a fill that carries on.
    var key: String {
        switch self {
        case .starting: return "starting"
        case .hold: return "hold"
        case .handsFree: return "handsFree"
        case .processing: return "processing"
        case .status(let status): return "status " + status.text
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .starting: return "正在打开麦克风"
        case .hold, .handsFree: return "正在听写"
        case .processing(let label): return label
        case .status(let status): return status.text
        }
    }

    @MainActor @ViewBuilder
    func contents(controller: DictationController, feeds: HUDFeeds, hover: @escaping (HUDButton, Bool) -> Void) -> some View {
        switch self {
        case .starting:
            StartingGlint()
        case .hold(let countdown):
            HStack(spacing: CapsuleMetrics.countdownGap) {
                wave(feeds)
                if countdown { CountdownLabel(countdown: feeds.countdown) }
            }
        case .handsFree(let countdown):
            HStack(spacing: CapsuleMetrics.gap) {
                RoundButton(kind: .cancel, hover: hover) { controller.cancel() }
                wave(feeds)
                if countdown { CountdownLabel(countdown: feeds.countdown) }
                RoundButton(kind: .confirm, hover: hover) { controller.finishRecording() }
            }
            .padding(.horizontal, CapsuleMetrics.inset)
        case .processing(let label):
            ProcessingFace(text: label, phase: feeds.phase)
        case .status(let status):
            status.view
        }
    }

    @MainActor private func wave(_ feeds: HUDFeeds) -> some View {
        VoiceWave(meter: feeds.meter)
            .frame(width: CapsuleMetrics.waveBox)
            .accessibilityHidden(true)
    }
}

/// The shell: black with the hairline rim of white at 32 % and two soft shadows (a halo
/// and a long one falling below), drawn only outside the shape, so the
/// half-black starting pill never shows its own shadow through it. No blur.
private struct CapsuleShell: View {
    var solid = true
    /// The rail: a light halo only, so the gap between it and the capsule stays clean.
    var rail = false

    var body: some View {
        let shape = Capsule(style: .circular)
        ZStack {
            ZStack {
                // Each shadow on its own layer, so the second is not a shadow of the first.
                shape.fill(.black).shadow(color: .black.opacity(rail ? 0.10 : 0.15), radius: rail ? 6 : 10)
                if !rail { shape.fill(.black).shadow(color: .black.opacity(0.25), radius: 15, y: 25) }
            }
            .compositingGroup()
            .mask(OutsideCapsule().fill(style: FillStyle(eoFill: true)))
            shape.fill(Theme.hud.opacity(solid ? 1 : 0.5))
            shape.strokeBorder(Theme.hudRim, lineWidth: CapsuleMetrics.rim)
        }
    }
}

/// Everything around a capsule (well past its shadow), but not the capsule itself. The hole is 1pt
/// larger than the capsule, so the soft edge of the mask never lets the shadow layer's own black
/// fill show as a dark seam around the rounded ends; the blurred shadows hide the missing band.
private struct OutsideCapsule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -120, dy: -120))
        path.addPath(Capsule(style: .circular).path(in: rect.insetBy(dx: -1, dy: -1)))
        return path
    }
}

/// The capsule's two buttons.
enum HUDButton { case cancel, confirm }

/// × (dark grey disc, white cross) and ✓ (white disc, black check), 24pt, their marks 9pt across
/// and of the same weight.
private struct RoundButton: View {
    let kind: HUDButton
    let hover: (HUDButton, Bool) -> Void
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(fill)
                Image(systemName: kind == .cancel ? "xmark" : "checkmark")
                    .font(.system(size: kind == .cancel ? 11.5 : 10, weight: .semibold))
                    .foregroundStyle(kind == .cancel ? Color.white : Theme.hudInk)
            }
            .frame(width: CapsuleMetrics.button, height: CapsuleMetrics.button)
            .contentShape(Circle())
        }
        .buttonStyle(PressDim())
        .onHover { inside in
            hovering = inside
            hover(kind, inside)
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(kind == .cancel ? "取消（Esc）" : "完成")
    }

    private var fill: Color {
        switch kind {
        case .cancel: return hovering ? Theme.hudButtonHover : Theme.hudButton
        case .confirm: return Color.white.opacity(hovering ? 0.86 : 1)
        }
    }
}

/// 取消 Esc / 完成 fn, in a tooltip: near-black, radius 8, 12pt warm white on an 18pt
/// line, the key that does the same in a quieter white; a faint warm edge and a soft drop shadow
/// instead of a stroke.
private struct ButtonTip: View {
    /// What the tip says, and its width as drawn.
    struct Label {
        static let font = NSFont.systemFont(ofSize: 12)
        static let spacing: CGFloat = 6
        static let padding: CGFloat = 10

        let text: String
        /// The key that does the same: Esc cancels; the dictation key (when it is on) finishes.
        let key: String?

        @MainActor init(kind: HUDButton, settings: AppSettings) {
            text = kind == .cancel ? "取消" : "完成"
            key = kind == .cancel ? "Esc" : (settings.hotkeyEnabled ? settings.trigger.keyName : nil)
        }

        var width: CGFloat {
            let keyWidth = key.map { Self.spacing + ceil(HUDText.width($0, Self.font)) } ?? 0
            return ceil(HUDText.width(text, Self.font)) + keyWidth + 2 * Self.padding
        }
    }

    let label: Label

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(spacing: Label.spacing) {
            Text(label.text)
            if let key = label.key {
                Text(key).foregroundStyle(Theme.hudWarm.opacity(0.55))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.hudWarm)
        .frame(height: 18)
        .padding(.vertical, 6)
        .padding(.horizontal, Label.padding)
        .background(
            shape.fill(Theme.hudTooltip)
                // A hairline of warm white, so it keeps an edge on a dark desktop, and a soft
                // drop shadow.
                .shadow(color: Theme.hudWarm.opacity(0.55), radius: 0.5)
                .shadow(color: .black.opacity(0.10), radius: 8, y: 8)
        )
        .fixedSize()
    }
}

/// Dims a capsule button while it is held down.
private struct PressDim: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// The starting pill's soft light, sliding across it every half second while the microphone opens,
/// so the pill reads as busy even on a dark desktop. Still with Reduce Motion.
private struct StartingGlint: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let time = HUDText._debugGlintTime {
            glint(at: time)
        } else if reduceMotion {
            Color.clear
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                glint(at: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func glint(at time: Double) -> some View {
        // Blurred: a soft light rather than a highlight.
        Circle()
            .fill(Theme.hudGlint)
            .frame(width: CapsuleGlint.diameter, height: CapsuleGlint.diameter)
            .blur(radius: 10)
            .offset(x: CapsuleGlint.x(time: time))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// 识别中 / 整理中 over the progress fill, which keeps moving and slows, completes when the
/// result is ready, then fades so what follows starts on black. One 30 Hz clock drives the fill and
/// the glint. 识别中 turning into 整理中 swaps just the word.
private struct ProcessingFace: View {
    let text: String
    @ObservedObject var phase: HUDPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let debug = HUDText._debugProcessing {
                face(fill: debug.fill, opacity: debug.opacity, time: debug.shimmer)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let (fill, opacity) = progress(at: context.date)
                    face(fill: fill, opacity: opacity, time: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: text)
    }

    /// The fill's fraction and opacity now.
    private func progress(at now: Date) -> (Double, Double) {
        guard let started = phase.processingStarted else { return (0, 1) }
        guard let completed = phase.completedAt else { return (CapsuleProgress.fraction(elapsed: now.timeIntervalSince(started)), 1) }
        let from = CapsuleProgress.fraction(elapsed: completed.timeIntervalSince(started))
        let since = now.timeIntervalSince(completed)
        return (CapsuleProgress.finishing(from: from, elapsed: since), CapsuleProgress.opacity(sinceCompleted: since))
    }

    private func face(fill: Double, opacity: Double, time: Double) -> some View {
        ZStack {
            // Inside the rim, clipped to the capsule's rounded ends, with a soft leading edge.
            GeometryReader { geo in
                let width = CapsuleProgress.width(fraction: fill, capsuleWidth: geo.size.width)
                LinearGradient(stops: [.init(color: Theme.hudFill, location: 0),
                                       .init(color: Theme.hudFill, location: CapsuleProgress.solidStop(width: width)),
                                       .init(color: Theme.hudFill.opacity(0), location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: width)
            }
            .clipShape(Capsule(style: .circular))
            .padding(CapsuleMetrics.rim)
            .opacity(opacity)
            ShimmerLabel(text: text, time: time, still: reduceMotion)
                .id(text)
                .transition(.opacity)
        }
    }
}

/// 识别中 / 整理中: one word in half-strength warm white, with a faint glint passing
/// over it (`CapsuleShimmer`). With Reduce Motion the word breathes instead.
private struct ShimmerLabel: View {
    let text: String
    let time: Double
    let still: Bool

    var body: some View {
        let word = Text(text).font(.system(size: 14, weight: .medium))
        Group {
            if still {
                // Between half and 85 % strength and back, every 2.4 s.
                let breath = 0.5 - 0.5 * cos(2 * Double.pi * time / 2.4)
                word.foregroundStyle(Theme.hudWarm.opacity(0.5 + 0.35 * breath))
            } else {
                word
                    .foregroundStyle(Theme.hudThinking)
                    .overlay {
                        GeometryReader { geo in
                            let band = CapsuleShimmer.band, core = CapsuleShimmer.core
                            let centre = -band / 2 + (geo.size.width + band) * CapsuleShimmer.progress(time: time)
                            let light = Theme.hudThinkingHighlight
                            LinearGradient(stops: [.init(color: light.opacity(0), location: 0),
                                                   .init(color: light, location: (band - core) / 2 / band),
                                                   .init(color: light, location: (band + core) / 2 / band),
                                                   .init(color: light.opacity(0), location: 1)],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: band, height: geo.size.height)
                                .offset(x: centre - band / 2)
                        }
                        .mask(word)
                    }
            }
        }
        .lineLimit(1)
        .fixedSize()
        // PingFang sits a little low in its line box, and its last character's side bearing pulls
        // the ink left: centre the ink on the capsule.
        .offset(x: 0.5, y: -0.5)
    }
}

/// The last minute, counted down in the capsule as m:ss, white 12pt in a 32pt slot.
private struct CountdownLabel: View {
    @ObservedObject var countdown: HUDCountdown

    var body: some View {
        if let remaining = HUDText._debugCountdown {
            label(remaining)
        } else if let ends = countdown.endsAt {
            TimelineView(.periodic(from: ends.addingTimeInterval(-CapsuleCountdown.length), by: 1)) { context in
                label(ends.timeIntervalSince(context.date))
            }
        }
    }

    private func label(_ remaining: TimeInterval) -> some View {
        Text(CapsuleCountdown.text(remaining: remaining))
            .font(.system(size: 12, weight: .regular).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .frame(width: CapsuleMetrics.countdownSlot)
            .accessibilityLabel("还剩 \(max(0, Int(remaining.rounded(.up)))) 秒")
    }
}

/// The capsule's type, measured the way SwiftUI draws it, so a width fits its words.
enum HUDText {
    /// 识别中 / 整理中.
    static let thinking = NSFont.systemFont(ofSize: 14, weight: .medium)
    /// Done / copied / fallback / failed: regular, so white on black stays light.
    static let status = NSFont.systemFont(ofSize: 13, weight: .regular)
    /// The live transcript.
    static let rail = NSFont.systemFont(ofSize: 13, weight: .regular)
    /// A notice about the recording itself, set apart from the transcript.
    static let notice = NSFont.systemFont(ofSize: 13, weight: .medium)

    static func width(_ s: String, _ font: NSFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    /// Snapshots only: fixed clocks instead of the real ones.
    @MainActor static var _debugProcessing: (fill: Double, opacity: Double, shimmer: Double)?
    @MainActor static var _debugGlintTime: Double?
    @MainActor static var _debugCountdown: TimeInterval?
    @MainActor static var _debugTip: HUDButton?
}

/// A terminal state's one line: what it says, what it is about and its natural width.
private struct Status: Equatable {
    let kind: CapsuleStatusKind
    let text: String
    let textWidth: CGFloat

    /// Whether `s` fits the widest status capsule on one line (with the 1pt `textWidth` adds).
    static func fits(_ s: String) -> Bool {
        HUDText.width(s, HUDText.status) + 1 <= CapsuleMetrics.maxStatusText
    }

    init?(phase: Phase, inserted: String?) {
        let status: CapsuleStatus
        switch phase {
        case .done(let message): status = CapsuleStatus.done(message, inserted: inserted, fits: Self.fits)
        case .failed(let message): status = CapsuleStatus.failed(message, fits: Self.fits)
        default: return nil
        }
        kind = status.kind
        text = status.text
        textWidth = HUDText.width(text, HUDText.status) + 1
    }

    var view: some View {
        HStack(spacing: CapsuleMetrics.glyphGap) {
            icon.frame(width: CapsuleMetrics.glyph, height: CapsuleMetrics.glyph)
            Text(text)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                // PingFang sits a little low in its line box: centre the ink on the capsule (the
                // glyph disc already is).
                .offset(y: -0.5)
        }
        .padding(.leading, CapsuleMetrics.statusLeading)
        .padding(.trailing, CapsuleMetrics.statusTrailing)
    }

    /// Always a 14pt disc: white for done, grey for neutral, amber for a fallback, red for a failure.
    @ViewBuilder private var icon: some View {
        switch kind {
        case .done, .kept, .copied, .learned:
            disc("checkmark.circle.fill", Theme.hudInk, .white)
        case .note:
            disc("info.circle.fill", .white, Theme.hudButtonHover)
        case .cancelled:
            disc("xmark.circle.fill", .white, Theme.hudButtonHover)
        case .secure:
            disc("lock.circle.fill", .white, Theme.hudButtonHover)
        case .fallback:
            disc("exclamationmark.circle.fill", Theme.hudInk, Theme.warning)
        case .failed:
            disc("exclamationmark.circle.fill", .white, Theme.failure)
        }
    }

    private func disc(_ symbol: String, _ mark: Color, _ fill: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(mark, fill)
    }
}

/// The controller's phase alone, so level and transcript updates do not re-render the capsule. A
/// result that ends processing waits until the fill has completed (`HUDFlow.completesFill`); a plain
/// paste never shows (`HUDFlow.collapsesQuietly`).
@MainActor
private final class HUDPhase: ObservableObject {
    @Published private(set) var phase: Phase
    /// Hold to talk (`DictationController.holdToTalk`).
    @Published private(set) var hold: Bool
    /// When this dictation's processing (识别中, then 整理中) began: the fill runs from it.
    private(set) var processingStarted: Date?
    /// When the result arrived: the fill completes from then, and the result shows a moment later.
    @Published private(set) var completedAt: Date?
    private var pending: DispatchWorkItem?
    private var subscriptions = Set<AnyCancellable>()

    init(_ controller: DictationController) {
        phase = controller.phase
        hold = controller.holdToTalk
        if controller.phase.isProcessing { processingStarted = Date() }
        controller.$phase.removeDuplicates().sink { [weak self] phase in
            // Idle and cancelled only hide the capsule: on its way out it keeps what it showed.
            guard phase != .idle, phase != .cancelled else { return }
            self?.take(phase)
        }.store(in: &subscriptions)
        controller.$holdToTalk.removeDuplicates().sink { [weak self] in self?.hold = $0 }.store(in: &subscriptions)
    }

    private func take(_ next: Phase) {
        pending?.cancel()
        pending = nil
        guard next != phase else { return }
        guard HUDFlow.completesFill(from: phase, to: next) else { return show(next) }
        completedAt = Date()
        // A plain paste: the processing word stays while the fill completes, until the capsule collapses.
        if HUDFlow.collapsesQuietly(from: phase, to: next) { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.show(next)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + CapsuleTiming.resultDelay, execute: work)
    }

    /// A line outside a dictation (`HUDController.announce`): shown at once, whatever was there.
    func announce(_ next: Phase) {
        pending?.cancel()
        pending = nil
        completedAt = nil
        processingStarted = nil
        phase = next
    }

    private func show(_ next: Phase) {
        if next.isProcessing, !phase.isProcessing || completedAt != nil {
            processingStarted = Date()
        }
        completedAt = nil
        phase = next
    }

    /// The panel is gone: the next dictation starts from the starting pill, so its entrance never
    /// shows the last result shrinking away. Not animated.
    func settle() {
        pending?.cancel()
        pending = nil
        processingStarted = nil
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            completedAt = nil
            phase = .idle
        }
    }
}

/// The last minute of a recording: from the near-cap notice (`CaptureTiming.capWarning`) to the cap.
@MainActor
private final class HUDCountdown: ObservableObject {
    @Published private(set) var endsAt: Date?
    private var subscription: AnyCancellable?

    init(_ controller: DictationController) {
        subscription = Publishers.CombineLatest(controller.$phase, controller.$notice).sink { [weak self] phase, notice in
            guard let self else { return }
            if phase != .recording {
                if self.endsAt != nil { self.endsAt = nil }
            } else if notice == CaptureText.nearCap, self.endsAt == nil {
                self.endsAt = Date().addingTimeInterval(CapsuleCountdown.length)
            }
        }
    }

    /// Snapshots only.
    func _debugStart() {
        subscription = nil
        endsAt = Date().addingTimeInterval(CapsuleCountdown.length)
    }
}

// MARK: - Live transcript rail

/// What the rail shows while recording: the live transcript (when 实时字幕 is on), split into the
/// part already on screen and the newly recognised tail that fades in; or, for a few seconds, a
/// notice about the recording itself (the 10-minute cap is near), whatever the setting.
@MainActor
private final class HUDRail: ObservableObject {
    @Published private(set) var stable = ""
    @Published private(set) var fresh = ""
    /// Bumped whenever a new tail arrives, to restart its fade.
    @Published private(set) var freshID = 0
    @Published private(set) var visible = false
    /// A notice, not the transcript: drawn apart so it is never taken for recognised words.
    @Published private(set) var isNotice = false
    private var bag = Set<AnyCancellable>()

    init(_ controller: DictationController, alwaysOn: Bool = false) {
        let settings = controller.settings
        isNotice = controller.notice != nil
        stable = controller.notice ?? controller.liveText
        Publishers.CombineLatest(controller.$liveText, controller.$notice)
            .map { text, notice in Line(text: notice ?? text, notice: notice != nil) }
            .removeDuplicates()
            .sink { [weak self] in self?.take($0) }
            .store(in: &bag)
        Publishers.CombineLatest4(controller.$phase, controller.$liveText, controller.$notice, settings.$liveTranscript)
            .map { phase, text, notice, on in phase == .recording && (notice != nil || ((on || alwaysOn) && !text.isEmpty)) }
            .removeDuplicates()
            .sink { [weak self] in self?.visible = $0 }
            .store(in: &bag)
    }

    private struct Line: Equatable {
        var text: String
        var notice: Bool
    }

    private func take(_ line: Line) {
        // A notice replaces the transcript outright (and the transcript comes back whole after it).
        if line.notice || isNotice {
            isNotice = line.notice
            stable = line.text
            fresh = ""
            return
        }
        let split = CapsuleText.railSplit(old: stable + fresh, new: line.text)
        stable = split.stable
        fresh = split.fresh
        if !split.fresh.isEmpty { freshID += 1 }
    }

    /// Snapshots only.
    func _debugShow(_ text: String, notice: Bool) {
        bag.removeAll()
        isNotice = notice
        stable = text
        fresh = ""
        visible = true
    }

    var text: String { stable + fresh }
}

/// The rail: the same black shell and rim as the capsule, never narrower than the capsule under it,
/// 13pt, centred while it fits and then right-anchored so the newest words stay in view while
/// older ones dissolve past a soft fade on the left (OpenLess's transcript rail). A notice has a
/// timer glyph and medium white type, so it never reads as recognised words.
private struct RailView: View {
    @ObservedObject var rail: HUDRail
    let placement: HUDPlacement
    /// Width of the capsule the rail stacks on.
    let capsuleWidth: CGFloat
    /// A button's tooltip is showing where the rail is: the rail fades out meanwhile.
    var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let noticeExtra = CapsuleMetrics.noticeGlyph + CapsuleMetrics.noticeGap

    private static func noticeFits(_ s: String) -> Bool {
        !CapsuleMetrics.railOverflows(textWidth: HUDText.width(s, HUDText.notice) + 1 + noticeExtra)
    }

    var body: some View {
        let notice = rail.isNotice
        let text = notice ? CapsuleText.notice(rail.text, fits: Self.noticeFits) : rail.text
        let textWidth = notice ? HUDText.width(text, HUDText.notice) + 1 + Self.noticeExtra : HUDText.width(text, HUDText.rail) + 1
        let width = CapsuleMetrics.railWidth(textWidth: textWidth, capsuleWidth: capsuleWidth)
        let overflows = CapsuleMetrics.railOverflows(textWidth: textWidth)
        ZStack {
            if rail.visible {
                railBody(text: text, notice: notice, width: width, overflows: overflows)
                    .offset(x: placement.offset(width: width))
                    .transition(reduceMotion ? .opacity
                                : .opacity.combined(with: .offset(y: placement.hangsBelow ? -4 : 4)))
            }
        }
        .opacity(dimmed ? 0 : 1)
        .animation(.easeOut(duration: 0.12), value: dimmed)
        .animation(HUDMotion.contents, value: rail.visible)
        .animation(reduceMotion ? nil : HUDMotion.morph, value: width)
    }

    @ViewBuilder private func line(text: String, notice: Bool) -> some View {
        if notice {
            HStack(spacing: CapsuleMetrics.noticeGap) {
                Image(systemName: "timer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .frame(width: CapsuleMetrics.noticeGlyph)
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }
        } else {
            HStack(spacing: 0) {
                Text(rail.stable)
                FreshText(text: rail.fresh, id: rail.freshID, animated: !reduceMotion)
            }
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.white.opacity(0.92))
        }
    }

    private func railBody(text: String, notice: Bool, width: CGFloat, overflows: Bool) -> some View {
        let pad = CapsuleMetrics.railPadding
        let start = CapsuleMetrics.railFadeStart / width
        let fade = CapsuleMetrics.railFade / width
        let stops: [Gradient.Stop] = overflows
            ? [.init(color: .clear, location: 0),
               .init(color: .clear, location: start),
               .init(color: .black.opacity(0.35), location: start + 14 / width),
               .init(color: .black, location: start + fade),
               .init(color: .black, location: 1)]
            : [.init(color: .black, location: 0), .init(color: .black, location: 1)]
        return line(text: text, notice: notice)
            .lineLimit(1)
            .fixedSize()
            // PingFang sits a little low in its line box: centre the ink on the rail.
            .offset(y: -0.5)
            .frame(width: max(0, width - 2 * pad), alignment: overflows ? .trailing : .center)
            .padding(.horizontal, pad)
            .frame(width: width, height: CapsuleMetrics.railHeight, alignment: .trailing)
            .clipped()
            // Overflowing text dissolves over about three characters before the rounded end.
            .mask(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
            .background(CapsuleShell(rail: true))
            .accessibilityLabel(notice ? text : rail.text)
    }
}

/// The newly recognised tail: fades (and lifts) in each time `id` changes.
private struct FreshText: View {
    let text: String
    let id: Int
    let animated: Bool
    @State private var shown = true

    var body: some View {
        Text(text)
            .opacity(shown ? 1 : 0)
            .offset(y: shown || !animated ? 0 : 3)
            .onChange(of: id) {
                guard animated else { return }
                shown = false
                withAnimation(.easeOut(duration: 0.18)) { shown = true }
            }
    }
}
