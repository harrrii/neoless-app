import Foundation
import Testing
@testable import NeolessCore

/// Drives a state machine with readable key events.
private struct Keys {
    static let fnFlag: UInt64 = 0x0080_0000
    static let command: UInt64 = 0x0010_0000

    var m: HotkeyStateMachine

    init(_ style: HotkeyStyle, trigger: HotkeyTrigger = .fn) {
        m = HotkeyStateMachine(trigger: trigger, style: style)
    }

    mutating func down(_ t: TimeInterval, flags: UInt64 = 0, secure: Bool = false) -> HotkeyAction? {
        m.handle(KeyInput(kind: .flagsChanged, keyCode: 63, flags: Self.fnFlag | flags, timestamp: t, secureInput: secure))
    }

    mutating func up(_ t: TimeInterval, flags: UInt64 = 0, secure: Bool = false) -> HotkeyAction? {
        m.handle(KeyInput(kind: .flagsChanged, keyCode: 63, flags: flags, timestamp: t, secureInput: secure))
    }

    /// Down at `t`, up `held` later: both results.
    mutating func tap(_ t: TimeInterval, held: TimeInterval = 0.1, secure: Bool = false) -> [HotkeyAction?] {
        [down(t, secure: secure), up(t + held, secure: secure)]
    }

    mutating func key(_ code: Int64, _ t: TimeInterval, repeating: Bool = false) -> HotkeyAction? {
        m.handle(KeyInput(kind: .keyDown, keyCode: code, flags: Self.fnFlag, isRepeat: repeating, timestamp: t))
    }

    /// Volume up while Fn is held (F12 with "use F1, F2… as standard function keys").
    mutating func volumeUp(_ t: TimeInterval) -> HotkeyAction? {
        let input = KeyInput.systemDefined(subtype: 8, data1: (0 << 16) | (0x0A << 8), flags: Self.fnFlag, timestamp: t)!
        return m.handle(input)
    }
}

@Suite struct HotkeyToggleStyleTests {
    @Test func cleanTapStartsAndTheNextStops() {
        var k = Keys(.toggle)
        #expect(k.tap(0, held: 0.15) == [nil, .start])
        #expect(k.m.isRecording)
        #expect(k.tap(2) == [nil, .stop])
        #expect(!k.m.isRecording)
    }

    @Test func longPressIsNotATap() {
        var k = Keys(.toggle)
        #expect(k.tap(0, held: 0.8) == [nil, nil])
        #expect(!k.m.isRecording)
    }

    @Test func stoppingPressMayBeLong() {
        var k = Keys(.toggle)
        _ = k.tap(0)
        #expect(k.tap(2, held: 1.5) == [nil, .stop])
    }

    @Test func fnComboDoesNotStart() {
        var k = Keys(.toggle)
        #expect(k.down(0) == nil)
        #expect(k.key(126, 0.1) == nil) // Fn+↑
        #expect(k.up(0.2) == nil)
        #expect(!k.m.isRecording)
    }

    @Test func fnComboDuringRecordingDoesNotStop() {
        var k = Keys(.toggle)
        _ = k.tap(0)
        #expect(k.down(2) == nil)
        #expect(k.key(125, 2.1) == nil) // Fn+↓
        #expect(k.up(2.2) == nil)
        #expect(k.m.isRecording)
    }

    @Test func bounceIsIgnored() {
        var k = Keys(.toggle)
        #expect(k.tap(0, held: 0.05) == [nil, .start])
        #expect(k.tap(0.08, held: 0.02) == [nil, nil])
        #expect(k.m.isRecording)
        #expect(k.tap(1) == [nil, .stop])
    }

    @Test func cooldownAfterStop() {
        var k = Keys(.toggle)
        _ = k.tap(0)
        #expect(k.tap(1) == [nil, .stop])          // stopped at 1.1
        #expect(k.tap(1.3) == [nil, nil])          // a double tap: no new recording
        #expect(k.tap(1.7) == [nil, .start])
    }

    @Test func rightOptionTapButNotWithCommandChord() {
        var m = HotkeyStateMachine(trigger: .rightOption, style: .toggle)
        let alt: UInt64 = 0x0008_0000
        _ = m.handle(KeyInput(kind: .flagsChanged, keyCode: 61, flags: alt | 0x40, timestamp: 0))
        #expect(m.handle(KeyInput(kind: .flagsChanged, keyCode: 61, flags: 0, timestamp: 0.2)) == .start)
        _ = m.handle(KeyInput(kind: .flagsChanged, keyCode: 61, flags: alt | 0x40, timestamp: 1))
        #expect(m.handle(KeyInput(kind: .flagsChanged, keyCode: 61, flags: 0, timestamp: 1.2)) == .stop)
        // ⌘ held while tapping right Option: a shortcut, not dictation
        _ = m.handle(KeyInput(kind: .flagsChanged, keyCode: 61, flags: alt | 0x40 | 0x0010_0000, timestamp: 3))
        #expect(m.handle(KeyInput(kind: .flagsChanged, keyCode: 61, flags: 0x0010_0000, timestamp: 3.2)) == nil)
    }
}

@Suite struct HotkeyAutoStyleTests {
    @Test func quickTapStartsOnKeyDownThenGoesHandsFree() {
        var k = Keys(.auto)
        #expect(k.down(0) == .start)                 // no words lost while the key goes down
        #expect(k.up(0.15) == .handsFree)
        #expect(k.m.isRecording)
        #expect(k.tap(3) == [nil, .stop])
        #expect(!k.m.isRecording)
    }

    @Test func holdTalksUntilRelease() {
        var k = Keys(.auto)
        #expect(k.down(0) == .start)
        #expect(k.up(2) == .stop)
        #expect(!k.m.isRecording)
    }

    @Test func thresholdSeparatesTapFromHold() {
        var k = Keys(.auto)
        #expect(k.tap(0, held: 0.34) == [.start, .handsFree])
        _ = k.tap(2)
        #expect(k.tap(5, held: 0.36) == [.start, .stop])
    }

    @Test func fnArrowDiscardsTheRecording() {
        var k = Keys(.auto)
        #expect(k.down(0) == .start)
        #expect(k.key(126, 0.1) == .discard)         // Fn+↑ is Page Up, not dictation
        #expect(k.key(126, 0.3) == nil)
        #expect(k.up(0.5) == nil)
        #expect(!k.m.isRecording)
        #expect(k.down(0.9) == .start)                // no cooldown after a shortcut
    }

    @Test func mediaKeyDiscardsTheRecording() {
        var k = Keys(.auto)
        #expect(k.down(0) == .start)
        #expect(k.volumeUp(0.2) == .discard)          // input-7: Fn+F12 volume
        #expect(k.up(0.4) == nil)
        #expect(!k.m.isRecording)
    }

    @Test func otherModifierDiscards() {
        var k = Keys(.auto)
        #expect(k.down(0) == .start)
        // ⌃ pressed after Fn (Fn+⌃+arrow window tiling)
        #expect(k.m.handle(KeyInput(kind: .flagsChanged, keyCode: 59, flags: Keys.fnFlag | 0x0004_0000, timestamp: 0.1)) == .discard)
        #expect(k.up(0.3, flags: 0x0004_0000) == nil)
    }

    @Test func modifierAlreadyHeldNeverStarts() {
        var k = Keys(.auto)
        #expect(k.down(0, flags: Keys.command) == nil)
        #expect(k.up(0.1, flags: Keys.command) == nil)
        #expect(!k.m.isRecording)
    }

    @Test func strayKeyLateInALongHoldKeepsTalking() {
        var k = Keys(.auto)
        #expect(k.down(0) == .start)
        #expect(k.key(0, 1.5) == nil)
        #expect(k.up(3) == .stop)
    }

    @Test func shortcutDuringHandsFreeDoesNotStop() {
        var k = Keys(.auto)
        _ = k.tap(0)
        #expect(k.down(2) == nil)
        #expect(k.key(125, 2.1) == nil)
        #expect(k.up(2.2) == nil)
        #expect(k.m.isRecording)
        #expect(k.tap(4) == [nil, .stop])
    }

    @Test func doubleTapAfterStopDoesNotRestart() {
        var k = Keys(.auto)
        #expect(k.down(0) == .start)
        #expect(k.up(1) == .stop)
        #expect(k.tap(1.2) == [nil, nil])             // inside the 450 ms cooldown
        #expect(k.down(1.6) == .start)
    }

    @Test func bounceAfterTapDoesNotStop() {
        var k = Keys(.auto)
        #expect(k.tap(0, held: 0.05) == [.start, .handsFree])
        #expect(k.tap(0.07, held: 0.02) == [nil, nil])
        #expect(k.m.isRecording)
    }
}

@Suite struct HotkeyHoldStyleTests {
    @Test func talksWhileHeld() {
        var k = Keys(.hold)
        #expect(k.down(0) == .start)
        #expect(k.up(1) == .stop)
        #expect(!k.m.isRecording)
    }

    @Test func quickTapIsDiscarded() {
        var k = Keys(.hold)
        #expect(k.tap(0, held: 0.1) == [.start, .discard])
        #expect(!k.m.isRecording)
        #expect(k.down(0.5) == .start)
    }

    @Test func chordIsDiscarded() {
        var k = Keys(.hold)
        #expect(k.down(0) == .start)
        #expect(k.key(51, 0.2) == .discard)           // Fn+Delete
        #expect(k.up(0.6) == nil)
    }

    @Test func recordingStartedElsewhereStopsOnNextPress() {
        var k = Keys(.hold)
        k.m.sync(recording: true)                     // started from the menu
        #expect(k.tap(1, held: 0.1) == [nil, .stop])
    }
}

@Suite struct HotkeyEscapeTests {
    @Test func escapeReported() {
        var k = Keys(.auto)
        #expect(k.key(53, 1) == .escape)
        #expect(k.key(53, 1.1, repeating: true) == nil)
    }

    @Test func escapeDuringAHoldEndsThatPress() {
        var k = Keys(.auto)
        #expect(k.down(0) == .start)
        #expect(k.key(53, 0.5) == .escape)
        #expect(k.up(2) == nil)                       // the controller cancelled; release does nothing
    }
}

@Suite struct HotkeySyncTests {
    @Test func controllerEndingHandsFreeLetsTheNextPressStart() {
        var k = Keys(.auto)
        _ = k.tap(0)
        k.m.sync(recording: false)                    // cancelled, failed or stopped from the menu
        #expect(k.tap(2) == [.start, .handsFree])
    }

    @Test func ignoredStartSilencesTheRelease() {
        var k = Keys(.auto)
        #expect(k.down(0) == .start)
        k.m.sync(recording: false)                    // busy with the last dictation: did not start
        #expect(k.up(1) == nil)
        #expect(k.down(2) == .start)
    }

    @Test func externalStartMakesTheNextTapStop() {
        var k = Keys(.toggle)
        k.m.sync(recording: true)
        #expect(k.tap(1) == [nil, .stop])
    }

    @Test func externalStartDuringATogglePressTurnsItIntoStop() {
        var k = Keys(.toggle)
        #expect(k.down(0) == nil)
        k.m.sync(recording: true)
        #expect(k.up(0.1) == .stop)
    }
}

/// input-13: a missed Fn-up must not swallow the next tap.
@Suite struct HotkeyMissedEventTests {
    @Test func missedReleaseDoesNotBlockTheNextTap() {
        var k = Keys(.toggle)
        #expect(k.down(0) == nil)                     // its release never arrives
        #expect(k.down(30) == nil)
        #expect(k.up(30.1) == .start)
    }

    @Test func missedReleaseOfAHoldKeepsRecordingAndTheNextTapStops() {
        var k = Keys(.auto)
        #expect(k.down(0) == .start)
        #expect(k.down(30) == .handsFree)
        #expect(k.up(30.1) == .stop)
        #expect(k.tap(31) == [.start, .handsFree])
    }

    @Test func resyncAfterTheTapWasOff() {
        var k = Keys(.auto)
        #expect(k.down(0) == .start)
        #expect(k.m.resync(triggerIsDown: false, at: 5) == .handsFree)
        #expect(!k.m.isPressed)
        #expect(k.tap(6) == [nil, .stop])
    }

    @Test func resyncFinishesAStopPress() {
        var k = Keys(.toggle)
        _ = k.tap(0)
        #expect(k.down(2) == nil)
        #expect(k.m.resync(triggerIsDown: false, at: 9) == .stop)
        #expect(!k.m.isRecording)
    }

    @Test func pressSeenOnlyByResyncIsSatOut() {
        var k = Keys(.toggle)
        #expect(k.m.resync(triggerIsDown: true, at: 1) == nil)
        #expect(k.up(1.1) == nil)
        #expect(k.tap(2) == [nil, .start])
    }
}

/// life-secure-input-chord: under Secure Event Input the tap sees Fn but not the arrow of Fn+←, so a
/// shortcut looks like a clean tap. Only a hold dictates then.
@Suite struct HotkeySecureInputTests {
    @Test func aTapNeverStartsAHandsFreeRecording() {
        for style in HotkeyStyle.allCases {
            var k = Keys(style)
            let fx = k.tap(0, held: 0.2, secure: true)
            #expect(fx == [.start, .discard], "\(style)")
            #expect(!fx.contains(.handsFree))
            #expect(!k.m.isRecording)
        }
    }

    @Test func aHoldStillTalks() {
        for style in HotkeyStyle.allCases {
            var k = Keys(style)
            #expect(k.down(0, secure: true) == .start)
            #expect(k.m.startIsTentative, "\(style)")
            #expect(k.up(1.5, secure: true) == .stop)
        }
    }

    @Test func startsAreTentativeOnlyOnKeyDown() {
        var toggle = Keys(.toggle)
        #expect(toggle.down(0) == nil)
        #expect(toggle.up(0.1) == .start)
        #expect(!toggle.m.startIsTentative)
        var auto = Keys(.auto)
        #expect(auto.down(0) == .start)
        #expect(auto.m.startIsTentative)
    }

    @Test func aRecordingStartedBeforeStillStopsOnATap() {
        var k = Keys(.auto)
        #expect(k.tap(0) == [.start, .handsFree])
        // secure input came on meanwhile (a password field got focus)
        #expect(k.tap(3, secure: true) == [nil, .stop])
    }

    @Test func secureInputOffAgainTapsAsUsual() {
        var k = Keys(.auto)
        _ = k.tap(0, secure: true)
        #expect(k.tap(2) == [.start, .handsFree])
    }

    @Test func missedReleaseOfABlindPress() {
        var tap = Keys(.auto)
        #expect(tap.down(0, secure: true) == .start)
        #expect(tap.m.resync(triggerIsDown: false, at: 0.2) == .discard)
        #expect(!tap.m.isRecording)
        var hold = Keys(.auto)
        #expect(hold.down(0, secure: true) == .start)
        #expect(hold.m.resync(triggerIsDown: false, at: 3) == .stop)
        // a second down without the up of a blind tap
        var again = Keys(.auto)
        #expect(again.down(0, secure: true) == .start)
        #expect(again.down(0.2) == .discard)
    }
}

@Suite struct HotkeyInputDecodingTests {
    @Test func systemDefinedAuxKeys() {
        let volumeDown = KeyInput.systemDefined(subtype: 8, data1: (1 << 16) | (0x0A << 8), flags: 0, timestamp: 1)
        #expect(volumeDown?.kind == .auxKeyDown && volumeDown?.keyCode == 1)
        let keyLight = KeyInput.systemDefined(subtype: 8, data1: (21 << 16) | (0x0A << 8) | 1, flags: 0, timestamp: 1)
        #expect(keyLight?.keyCode == 21 && keyLight?.isRepeat == true)
        // key up, mouse buttons (subtype 7), and keys past the aux range are not shortcuts
        #expect(KeyInput.systemDefined(subtype: 8, data1: (1 << 16) | (0x0B << 8), flags: 0, timestamp: 1) == nil)
        #expect(KeyInput.systemDefined(subtype: 7, data1: 1, flags: 0, timestamp: 1) == nil)
        #expect(KeyInput.systemDefined(subtype: 8, data1: (25 << 16) | (0x0A << 8), flags: 0, timestamp: 1) == nil)
    }

    @Test func eventClockFallsBackToNow() {
        #expect(EventClock.seconds(eventTimestamp: 100_500_000_000, now: 101) == 100.5)
        #expect(EventClock.seconds(eventTimestamp: 0, now: 101) == 101)
        // mach ticks (24 MHz) instead of nanoseconds are far off: use now
        #expect(EventClock.seconds(eventTimestamp: 2_424_000_000, now: 101) == 101)
    }
}
