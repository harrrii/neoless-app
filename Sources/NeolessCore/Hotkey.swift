import Foundation

/// Which key starts and stops dictation. Fn+arrow, ⌥+letter and other shortcuts keep working:
/// a press that turns into a shortcut never dictates.
public enum HotkeyTrigger: String, CaseIterable, Codable, Sendable, Identifiable {
    case fn, rightOption, rightCommand

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fn: return "fn（🌐）"
        case .rightOption: return "右侧 Option"
        case .rightCommand: return "右侧 Command"
        }
    }

    /// The key alone, for sentences such as "fn 用不了". Lowercase, as macOS writes it (按下fn键时).
    public var keyName: String {
        switch self {
        case .fn: return "fn"
        case .rightOption: return "右侧 Option"
        case .rightCommand: return "右侧 Command"
        }
    }

    public var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        }
    }

    /// Device-dependent flag bits for the specific physical key (IOLLEvent.h).
    public var deviceFlagMask: UInt64 {
        switch self {
        case .fn: return 0x0080_0000          // NX_SECONDARYFNMASK
        case .rightOption: return 0x0000_0040 // NX_DEVICERALTKEYMASK
        case .rightCommand: return 0x0000_0010 // NX_DEVICERCMDKEYMASK
        }
    }
}

/// How the hotkey drives dictation. `auto`: a quick tap toggles (tap to start, tap to stop),
/// holding the key talks while held. `toggle` and `hold` force one behaviour.
public enum HotkeyStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case auto, toggle, hold
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .auto: return "自动"
        case .toggle: return "轻按"
        case .hold: return "按住"
        }
    }
}

public enum KeyEventKind: Sendable {
    case flagsChanged, keyDown, keyUp
    /// A volume, brightness, media or keyboard-light key went down: an NX_SYSDEFINED event
    /// (CGEvent type 14). `keyCode` is its NX_KEYTYPE. Build it with `KeyInput.systemDefined`.
    case auxKeyDown
}

public struct KeyInput: Sendable {
    public var kind: KeyEventKind
    public var keyCode: Int64
    public var flags: UInt64
    public var isRepeat: Bool
    public var timestamp: TimeInterval
    /// Secure Event Input is on (`IsSecureEventInputEnabled()`, read for trigger events only): the
    /// tap still sees modifier changes such as Fn, but no other key, so a shortcut cannot be told
    /// from a tap.
    public var secureInput: Bool

    public init(kind: KeyEventKind, keyCode: Int64, flags: UInt64, isRepeat: Bool = false, timestamp: TimeInterval,
                secureInput: Bool = false) {
        self.kind = kind; self.keyCode = keyCode; self.flags = flags; self.isRepeat = isRepeat; self.timestamp = timestamp
        self.secureInput = secureInput
    }

    /// CGEvent type of NX_SYSDEFINED, which `CGEventType` does not name.
    public static let systemDefinedEventType: UInt32 = 14
    static let auxControlSubtype = 8          // NX_SUBTYPE_AUX_CONTROL_BUTTONS
    static let auxKeyCount = 24               // NX_NUMSPECIALKEYS: volume … keyboard light

    /// Reads an NX_SYSDEFINED event from its NSEvent `subtype` and `data1`. Only an aux control
    /// button going down (volume, brightness, media, keyboard light: NX_KEYTYPE 0…23) becomes an
    /// `.auxKeyDown` input; key-ups, mouse-button events and the rest return nil.
    public static func systemDefined(subtype: Int, data1: Int, flags: UInt64, timestamp: TimeInterval) -> KeyInput? {
        guard subtype == auxControlSubtype else { return nil }
        let key = (data1 >> 16) & 0xFFFF
        let state = (data1 >> 8) & 0xFF        // 0x0A down, 0x0B up
        guard key < auxKeyCount, state == 0x0A else { return nil }
        return KeyInput(kind: .auxKeyDown, keyCode: Int64(key), flags: flags, isRepeat: data1 & 0x1 != 0,
                        timestamp: timestamp)
    }
}

/// What the hotkey asks the dictation controller to do. Every press that sends `.start` is later
/// resolved by exactly one of `.handsFree`, `.stop` or `.discard`, unless the controller ends the
/// recording first (see `HotkeyStateMachine.sync(recording:)`).
public enum HotkeyAction: Equatable, Sendable {
    /// Start recording now. In `auto` and `hold` this comes on key-down, before it is known whether
    /// the press is a tap, a hold or a shortcut: start at once so the first words are not lost, and
    /// keep the pill low-key until the press resolves. Leave everything of the last dictation alone
    /// until then: its pasted passage is still watched for corrections, and Fn+← or Fn+Delete is
    /// how the user fixes it. `.handsFree` or `.stop` confirms the press, `.discard` drops it. In
    /// `toggle` it comes when a clean tap is released and is final. Under Secure Event Input every
    /// style starts on key-down and only a hold dictates (see `HotkeyStateMachine.startIsTentative`).
    /// If you cannot start (still busy with the last dictation), ignore it: the monitor reads the
    /// controller's real state after every action and the machine follows it.
    case start
    /// `auto` only: the press that sent `.start` was a quick tap, so keep recording hands-free.
    /// The next clean tap sends `.stop`. Nothing to do except, optionally, show the hands-free state.
    case handsFree
    /// Stop recording and process what was said: a hold was released, or the tap that ends a
    /// hands-free / toggle recording. If audio has not arrived yet, finish as soon as it does (or cancel).
    case stop
    /// The press that sent `.start` turned out to be a keyboard shortcut (Fn+arrow, Fn+volume,
    /// ⌘ held…), or, in `hold`, was too short to be speech. Throw the recording away silently:
    /// no pill message, no history, no paste, and nothing of the last dictation ended.
    case discard
    /// Esc went down (not a key repeat). Only delivered while the monitor consumes Esc.
    case escape
}

/// Turns raw key events into `HotkeyAction`s. Pure and synchronous; runs on the event-tap thread.
public struct HotkeyStateMachine: Sendable {
    public static let escapeKeyCode: Int64 = 53
    /// Shift, Control, Option, Command (device-independent masks).
    static let standardModifiers: UInt64 = 0x0002_0000 | 0x0004_0000 | 0x0008_0000 | 0x0010_0000

    public var trigger: HotkeyTrigger
    public var style: HotkeyStyle
    /// `auto`: a press shorter than this is a tap (hands-free), a longer one is hold-to-talk.
    /// `hold`: a shorter press is discarded, too short to hold any speech.
    public var holdThreshold: TimeInterval = 0.35
    /// `toggle`: the longest press that still counts as a tap.
    public var maxTapDuration: TimeInterval = 0.5
    /// Another key this soon after a press began makes it a shortcut and discards the recording it
    /// started. Later in a long hold a stray key is ignored and the hold keeps talking.
    public var chordWindow: TimeInterval = 1.0
    /// After a stop, a new recording cannot start for this long (a bounce or a double tap).
    public var cooldown: TimeInterval = 0.45
    /// A press that begins this soon after the previous release is contact bounce.
    public var debounce: TimeInterval = 0.08

    /// Whether the machine believes a recording is running (started by the hotkey or synced in).
    public private(set) var isRecording = false
    /// Whether the trigger key is down as far as the machine knows.
    public var isPressed: Bool { press != nil }
    /// The `.start` just returned came on key-down, so the press may still turn out to be a shortcut
    /// (`auto` and `hold`, and every style under Secure Event Input); false for a toggle tap's start.
    public var startIsTentative: Bool { press?.role == .owner }

    private struct Press: Sendable {
        var downAt: TimeInterval
        var role: Role
        /// Started under Secure Event Input, where no other key can be seen: a shortcut looks like a
        /// tap, so only a hold dictates and a quick release discards.
        var blind = false
    }

    private enum Role: Sendable {
        /// `toggle`, idle: a clean quick release starts recording.
        case starter
        /// `auto`/`hold`: this press sent `.start`; its release or a shortcut resolves it.
        case owner
        /// A recording is running: a clean release stops it.
        case stopper
        /// A shortcut, a bounce, a press in the cooldown, after Esc: nothing until it is released.
        case ignored
    }

    private var press: Press?
    private var lastReleaseAt: TimeInterval = -.infinity
    private var lastStopAt: TimeInterval = -.infinity

    public init(trigger: HotkeyTrigger, style: HotkeyStyle = .auto) {
        self.trigger = trigger
        self.style = style
    }

    public mutating func handle(_ e: KeyInput) -> HotkeyAction? {
        switch e.kind {
        case .flagsChanged:
            if e.keyCode == trigger.keyCode {
                return e.flags & trigger.deviceFlagMask != 0 ? triggerDown(e) : triggerUp(at: e.timestamp)
            }
            return interrupt(at: e.timestamp)
        case .keyDown:
            if e.keyCode == Self.escapeKeyCode {
                // Esc during a press cancels whatever that press would have done; the controller
                // cancels the recording itself and `sync` catches up.
                press?.role = .ignored
                return e.isRepeat ? nil : .escape
            }
            return interrupt(at: e.timestamp)
        case .auxKeyDown:
            return interrupt(at: e.timestamp)
        case .keyUp:
            return nil
        }
    }

    /// Follow the controller: `recording` is true while it is starting or recording. Call it with
    /// the controller's state whenever that changes for any reason (cancelled, failed, stopped from
    /// the menu, started from the window) and after every action it handled.
    public mutating func sync(recording: Bool) {
        guard recording != isRecording else { return }
        isRecording = recording
        guard var p = press else { return }
        switch p.role {
        case .owner, .stopper: if !recording { p.role = .ignored }
        case .starter: if recording { p.role = .stopper }
        case .ignored: break
        }
        press = p
    }

    /// Events may have been missed (the tap was off: timeout, screen lock, secure input). Line the
    /// machine up with the key's real state `triggerIsDown` at time `now`.
    public mutating func resync(triggerIsDown: Bool, at now: TimeInterval) -> HotkeyAction? {
        if triggerIsDown {
            // Pressed while we were not looking: sit this press out.
            if press == nil { press = Press(downAt: now, role: .ignored) }
            return nil
        }
        guard let p = press else { return nil }
        press = nil
        lastReleaseAt = now
        switch p.role {
        case .owner where p.blind:
            // Released unseen under secure input, where a tap may have been a shortcut.
            if now - p.downAt >= holdThreshold { return stop(at: now) }
            isRecording = false
            return .discard
        case .owner: return .handsFree        // released unseen: keep the recording, a tap stops it
        case .stopper: return stop(at: now)
        case .starter, .ignored: return nil
        }
    }

    // MARK: Steps

    private mutating func triggerDown(_ e: KeyInput) -> HotkeyAction? {
        let t = e.timestamp
        var result: HotkeyAction?
        if let old = press {
            // A second down without an up: the release was missed. A recording that press started
            // keeps going hands-free and this press can stop it; anything else is dropped. Under
            // secure input that press may have been a shortcut: a hold stops, a tap discards.
            if old.role == .owner, old.blind {
                if t - old.downAt < holdThreshold {
                    // That tap is dropped, and this press with it: one action per event.
                    isRecording = false
                    press = Press(downAt: t, role: .ignored)
                    return .discard
                }
                result = stop(at: t)    // the cooldown then sits this press out
            } else if old.role == .owner {
                result = .handsFree
            }
            press = nil
        }
        if t - lastReleaseAt < debounce || otherModifiersHeld(e.flags) {
            press = Press(downAt: t, role: .ignored)
            return result
        }
        if isRecording {
            press = Press(downAt: t, role: .stopper)
            return result
        }
        if t - lastStopAt < cooldown {
            press = Press(downAt: t, role: .ignored)
            return result
        }
        if e.secureInput {
            // Fn+← in a Terminal with 安全键盘输入 would look like a clean tap: hold to talk only.
            press = Press(downAt: t, role: .owner, blind: true)
            isRecording = true
            return .start
        }
        switch style {
        case .toggle:
            press = Press(downAt: t, role: .starter)
            return result
        case .auto, .hold:
            press = Press(downAt: t, role: .owner)
            isRecording = true
            return .start
        }
    }

    private mutating func triggerUp(at t: TimeInterval) -> HotkeyAction? {
        guard let p = press else { return nil }
        press = nil
        lastReleaseAt = t
        let held = t - p.downAt
        switch p.role {
        case .ignored:
            return nil
        case .starter:
            guard held <= maxTapDuration else { return nil }
            isRecording = true
            return .start
        case .stopper:
            return stop(at: t)
        case .owner:
            if held >= holdThreshold { return stop(at: t) }
            if style == .hold || p.blind {
                isRecording = false
                return .discard
            }
            return .handsFree
        }
    }

    /// Another key, modifier or media key while the trigger is down.
    private mutating func interrupt(at t: TimeInterval) -> HotkeyAction? {
        guard var p = press else { return nil }
        switch p.role {
        case .ignored:
            return nil
        case .starter, .stopper:
            p.role = .ignored
            press = p
            return nil
        case .owner:
            guard t - p.downAt < chordWindow else { return nil }
            p.role = .ignored
            press = p
            isRecording = false
            return .discard
        }
    }

    private mutating func stop(at t: TimeInterval) -> HotkeyAction {
        isRecording = false
        lastStopAt = t
        return .stop
    }

    private func otherModifiersHeld(_ flags: UInt64) -> Bool {
        var mask = Self.standardModifiers
        switch trigger {
        case .fn: break
        case .rightOption: mask &= ~0x0008_0000
        case .rightCommand: mask &= ~0x0010_0000
        }
        return flags & mask != 0
    }
}

/// Event times for the state machine, in seconds since boot.
public enum EventClock {
    /// A CGEvent timestamp (documented as nanoseconds since boot) in seconds, or `now` when the
    /// stamp is missing or clearly in another unit (more than `tolerance` away from `now`).
    public static func seconds(eventTimestamp: UInt64, now: TimeInterval, tolerance: TimeInterval = 5) -> TimeInterval {
        let t = Double(eventTimestamp) / 1_000_000_000
        return abs(t - now) <= tolerance ? t : now
    }
}
