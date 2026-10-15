import Foundation

/// How the press that started a recording turned out, which decides what the capsule shows.
public enum PressKind: Equatable, Sendable {
    /// Still down and not resolved: it may yet be a tap, a hold or a keyboard shortcut.
    case pending
    /// A quick tap (or toggle style, or a start from the window or menu): [× | wave | ✓].
    case handsFree
    /// Hold to talk: the wave alone, no buttons; releasing the key stops.
    case hold
}

/// Why a recording ended with something to process.
public enum FinishReason: Equatable, Sendable {
    /// The hotkey, ✓ or the menu.
    case user
    /// A stop came before any audio; it ran as soon as the first audio arrived.
    case lateStop
    /// The microphone failed after it had recorded sound: keep what it recorded.
    case salvage
    /// `CaptureTiming.maxRecording` reached.
    case cap
    /// A hands-free recording went quiet for `SilenceWatch.limit` after the user had spoken.
    case silence

    /// For the record's note; nil when nothing unusual happened.
    public var note: String? {
        switch self {
        case .user, .lateStop: return nil
        case .salvage: return "麦克风中途出错，只保留了出错前的录音"
        case .cap: return "录音满 10 分钟，已自动结束"
        case .silence: return "一分钟没听到说话，已自动结束"
        }
    }

    /// The recording ended on its own, maybe long after the user walked away or moved to another
    /// app: it is pasted only into the app recording started in (and copied anywhere else), never
    /// into whatever happens to be in front by then.
    public var pastesOnlyWhereStarted: Bool {
        switch self {
        case .cap, .silence: return true
        case .user, .lateStop, .salvage: return false
        }
    }
}

/// The session state of one dictation, as a pure reducer: the controller feeds it hotkey actions,
/// clicks, timers and microphone events, and carries out the effects it returns in order.
///
/// - A hotkey `.start` in auto/hold is *tentative*: capture starts at once so no speech is lost, but
///   nothing is shown until the press resolves: `.handsFree`, `.stop`, or the hold passing
///   `CaptureTiming.holdResolve`. `.discard` (a shortcut) or Esc before that drops it silently.
/// - Until the hotkey can no longer turn the press into a shortcut (`.handsFree`, `.stop`, ✓, or
///   `CaptureTiming.shortcutWindow`), nothing of the last dictation is touched: its correction watch
///   keeps running, and a `.discard` stays quiet even once the capsule shows (`.commit` ends it).
/// - Once recording has ended (`processing`) nothing throws the dictation away: a new `.start` is
///   ignored and Esc / × only stops the paste (`.keepWithoutPaste`).
/// - Esc belongs to neoless for the whole dictation (`consumesEscape`), so one Esc never both stops
///   neoless and reaches the app underneath (where it might interrupt a reply being generated).
public struct CaptureFlow: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        case idle
        /// Capture is starting: no audio yet.
        case starting
        case recording
        /// Recording ended; recognizing, polishing, pasting.
        case processing
    }

    public enum Event: Equatable, Sendable {
        /// Hotkey `.start`; `tentative` in auto and hold, where it comes on key-down.
        case start(tentative: Bool)
        /// Start from the window or the menu: final, hands-free.
        case startClicked
        case handsFree
        case stop
        case discard
        /// Esc, taken from the app underneath while `consumesEscape`.
        case escape
        /// ✓ on the capsule, the window's stop button, or 结束听写 in the menu.
        case confirmClicked
        /// × on the capsule (recording only), the window's × button, or 取消输入 in the menu.
        case cancelClicked
        /// `CaptureTiming.holdResolve` after a tentative start, with no `.handsFree`/`.stop`/`.discard`.
        case holdElapsed
        /// `CaptureTiming.shortcutWindow` after a tentative start: the hotkey no longer sends
        /// `.discard` for this press.
        case shortcutWindowElapsed
        /// The first buffer that is not digital silence.
        case audioArrived
        /// `CaptureTiming.lateStopLimit` after a stop that came before any audio.
        case lateStopElapsed
        /// The microphone or recognizer could not start, or the microphone failed mid-recording.
        /// `heardSignal`: what it recorded so far contains sound.
        case captureFailed(heardSignal: Bool)
        /// `CaptureTiming.maxRecording` reached.
        case capReached
        /// `SilenceWatch` saw no speech for `SilenceWatch.limit`. `heardSpeech`: someone spoke
        /// earlier in this recording. Acts only on a hands-free recording that is a dictation for good.
        case silenceElapsed(heardSpeech: Bool)
        /// Processing is over (delivered, failed, or handed off after `.keepWithoutPaste`).
        case delivered
    }

    public enum Effect: Equatable, Sendable {
        /// Open the microphone and the recognizer.
        case beginCapture
        /// Show the capsule in this style. The last dictation is still left alone (see `.commit`).
        case reveal(PressKind)
        /// Already shown; switch the capsule to this style.
        case restyle(PressKind)
        /// Audio arrived and the capsule is (or may now be) shown: recording.
        case showRecording
        /// The press can no longer turn out to be a shortcut: it is a dictation for good, so end the
        /// watch on the last pasted text.
        case commit
        /// Arm `lateStopElapsed`.
        case armLateStop
        /// Stop recording (after the tail, unless salvaging) and process it.
        case finish(FinishReason)
        /// Throw the capture away without a trace: no message, no history, the last dictation
        /// untouched. A capsule already shown for it just goes away.
        case discard
        /// The user cancelled a shown recording.
        case cancel
        /// Capture failed with nothing worth keeping: show the error.
        case fail
        /// A hands-free recording nobody spoke into for `SilenceWatch.limit`: close the microphone
        /// and say so (`CaptureText.nobodySpoke`). Nothing is kept: nothing was said.
        case nobodySpoke
        /// Processing goes on, but nothing is pasted; the result is kept in history with a note.
        case keepWithoutPaste
    }

    /// What the menu-bar item offers. Raw values are for `NSMenuItem.tag`.
    public enum MenuCommand: Int, Equatable, Sendable {
        /// Idle: start hands-free.
        case start
        /// Starting or recording: finish, like ✓ (while starting, as soon as audio arrives).
        case finish
        /// Recognizing or polishing: stop the paste and keep the result, like Esc.
        case cancelPaste

        public var title: String {
            switch self {
            case .start: return "开始听写"
            case .finish: return "结束听写"
            case .cancelPaste: return "取消输入"
            }
        }

        public var event: Event {
            switch self {
            case .start: return .startClicked
            case .finish: return .confirmClicked
            case .cancelPaste: return .cancelClicked
            }
        }
    }

    public private(set) var stage: Stage = .idle
    /// Started by a press that has not resolved yet; nothing is shown.
    public private(set) var tentative = false
    /// The hotkey may still turn this press into a shortcut: `.discard` is quiet and the last
    /// dictation's correction watch keeps running, even after the capsule shows.
    public private(set) var shortcutPossible = false
    public private(set) var kind: PressKind = .handsFree
    /// A stop came while starting (no audio yet).
    public private(set) var stopRequested = false
    /// Capture failed while the press was still tentative: shown only if the press turns out real.
    public private(set) var failedTentatively = false
    /// The microphone failed after recording sound while the press could still be a shortcut: what
    /// it recorded is processed (`.finish(.salvage)`) once the press is a dictation for good, and
    /// dropped quietly if it turns out to be a shortcut.
    public private(set) var salvagePending = false

    public init() {}

    /// Microphone open: what the hotkey monitor calls "recording".
    public var isCapturing: Bool { stage == .starting || stage == .recording }
    /// Whether Esc is taken from the app underneath: for the whole dictation, recognizing and
    /// polishing included, like an input method while its candidate window is open (OpenLess does
    /// the same). Otherwise one Esc would both stop neoless and act in the app (cancel a reply being
    /// generated, close a popup), and an Esc meant for the app would stop the paste.
    public var consumesEscape: Bool { stage != .idle }

    /// The window's round button, which shows ■ while recording and × while starting or processing.
    public var buttonEvent: Event {
        switch stage {
        case .idle: return .startClicked
        case .recording: return .confirmClicked
        case .starting, .processing: return .cancelClicked
        }
    }

    /// The menu-bar item for the current stage.
    public var menuCommand: MenuCommand {
        switch stage {
        case .idle: return .start
        case .starting, .recording: return .finish
        case .processing: return .cancelPaste
        }
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch stage {
        case .idle: return idle(event)
        case .starting, .recording: return capturing(event)
        case .processing: return processing(event)
        }
    }

    // MARK: Stages

    private mutating func idle(_ event: Event) -> [Effect] {
        switch event {
        case .start(let t):
            begin(tentative: t)
            return t ? [.beginCapture] : [.beginCapture, .reveal(.handsFree), .commit]
        case .startClicked:
            begin(tentative: false)
            return [.beginCapture, .reveal(.handsFree), .commit]
        default:
            return []
        }
    }

    private mutating func capturing(_ event: Event) -> [Effect] {
        switch event {
        case .start, .startClicked, .delivered:
            return []
        case .handsFree:
            // Released as a tap: the press is over and can no longer be a shortcut.
            if tentative { return resolve(.handsFree) + commit() + salvageIfPending() }
            var fx: [Effect] = []
            if kind != .handsFree {
                kind = .handsFree
                fx.append(.restyle(.handsFree))
            }
            return fx + commit() + salvageIfPending()
        case .holdElapsed:
            // Shown, but still possibly a shortcut: a pending salvage waits for the commit.
            guard tentative else { return [] }
            return resolve(.hold)
        case .shortcutWindowElapsed:
            // Still unresolved this late (a missed timer): a hold.
            let fx = tentative ? resolve(.hold) : []
            return fx + commit() + salvageIfPending()
        case .stop, .confirmClicked:
            var fx = tentative ? resolve(.hold) : []
            if stage == .idle { return fx }    // resolved into a failure
            fx += commit()
            if salvagePending { return fx + salvageIfPending() }
            if stage == .starting {
                if !stopRequested { fx.append(.armLateStop) }
                stopRequested = true
                return fx
            }
            return fx + finish(.user)
        case .discard:
            // A shortcut: dropped without a trace while the press could still be one, shown or not.
            let quiet = shortcutPossible
            reset()
            return [quiet ? .discard : .cancel]
        case .escape, .cancelClicked:
            let quiet = tentative
            reset()
            return [quiet ? .discard : .cancel]
        case .audioArrived:
            guard stage == .starting, !failedTentatively else { return [] }
            stage = .recording
            if stopRequested {
                stage = .processing
                return [.showRecording, .finish(.lateStop)]
            }
            return tentative ? [] : [.showRecording]
        case .lateStopElapsed:
            guard stage == .starting, stopRequested else { return [] }
            reset()
            return [.cancel]
        case .captureFailed(let heard):
            if stage == .recording, heard {
                // Keep what was recorded, but touch nothing until the press is a dictation for good.
                if shortcutPossible {
                    salvagePending = true
                    return []
                }
                return finish(.salvage)
            }
            if tentative {
                failedTentatively = true
                return []
            }
            reset()
            return [.fail]
        case .capReached:
            guard stage == .recording, !salvagePending else { return [] }
            return finish(.cap)
        case .silenceElapsed(let heard):
            // A held key is someone still there; a press that may be a shortcut is not ours yet.
            guard stage == .recording, kind == .handsFree, !shortcutPossible, !salvagePending else { return [] }
            if heard { return finish(.silence) }
            reset()
            return [.nobodySpoke]
        }
    }

    private mutating func processing(_ event: Event) -> [Effect] {
        switch event {
        case .escape, .cancelClicked:
            reset()
            return [.keepWithoutPaste]
        case .delivered:
            reset()
            return []
        default:
            return []
        }
    }

    // MARK: Helpers

    private mutating func begin(tentative t: Bool) {
        stage = .starting
        tentative = t
        shortcutPossible = t
        kind = t ? .pending : .handsFree
        stopRequested = false
        failedTentatively = false
        salvagePending = false
    }

    /// Recording ends with something to process (revealing and committing a tentative press first).
    private mutating func finish(_ reason: FinishReason) -> [Effect] {
        var fx = tentative ? resolve(.hold) : []
        if stage == .idle { return fx }    // resolved into a failure
        fx += commit()
        stage = .processing
        salvagePending = false
        return fx + [.finish(reason)]
    }

    /// The press is a dictation for good: process what a failed microphone recorded before it failed.
    private mutating func salvageIfPending() -> [Effect] {
        guard salvagePending, stage == .recording else { return [] }
        return finish(.salvage)
    }

    /// The tentative press is real: show it. A capture that already failed shows its error instead.
    private mutating func resolve(_ k: PressKind) -> [Effect] {
        tentative = false
        kind = k
        if failedTentatively {
            reset()
            return [.fail]
        }
        return stage == .recording ? [.reveal(k), .showRecording] : [.reveal(k)]
    }

    /// The press can no longer be a shortcut; `.commit` once per capture.
    private mutating func commit() -> [Effect] {
        guard shortcutPossible, stage != .idle else { return [] }
        shortcutPossible = false
        return [.commit]
    }

    private mutating func reset() {
        stage = .idle
        tentative = false
        shortcutPossible = false
        kind = .handsFree
        stopRequested = false
        failedTentatively = false
        salvagePending = false
    }
}

/// Timing of one capture.
public enum CaptureTiming {
    /// A tentative press still down this long after its `.start` is a hold. A little over
    /// `HotkeyStateMachine.holdThreshold`, so a tap released right at the threshold still reports
    /// `.handsFree` first.
    public static let holdResolve: TimeInterval = 0.38
    /// A tentative press is a dictation for good this long after its `.start`: a little over
    /// `HotkeyStateMachine.chordWindow`, after which another key no longer makes it a shortcut.
    public static let shortcutWindow: TimeInterval = 1.1
    /// After a stop that came before any audio, wait this long for the microphone, then cancel.
    public static let lateStopLimit: TimeInterval = 1.5
    /// Keep recording this long after a stop: people stop on the last syllable.
    public static let tail: TimeInterval = 0.25
    /// The longest recording; it then finishes on its own.
    public static let maxRecording: TimeInterval = 600
    /// A minute before `maxRecording`, the capsule says the recording will end soon.
    public static let capWarning: TimeInterval = 540
    /// How long that warning stays up.
    public static let noticeDuration: TimeInterval = 6
    /// 用 Neo 处理: how long the upload waits for this Mac's final transcript to go with it. Usually it is there
    /// sooner; when it is not, the recording goes without it (the Neo recognises it anyway, and this Mac's
    /// transcript follows only if the Neo heard nothing).
    public static let hubTranscriptWait: TimeInterval = 0.8

    /// How long to keep capturing after the recording ends for `reason`. A failed microphone has
    /// nothing more to give; the others keep the tail.
    public static func tail(for reason: FinishReason) -> TimeInterval {
        reason == .salvage ? 0 : tail
    }
}

/// Short words the capsule shows about the recording itself.
public enum CaptureText {
    /// `CaptureTiming.capWarning` reached: shown above the capsule for `CaptureTiming.noticeDuration`.
    public static let nearCap = "还剩 1 分钟，满 10 分钟会自动结束"
    /// A hands-free recording nobody spoke into for `SilenceWatch.limit`.
    public static let nobodySpoke = "一分钟没听到说话，已自动结束"
    /// The record's note when part of a long recording may not have been recognized.
    public static let incomplete = "识别可能不完整，后面一部分没有转出来"
}

/// Notices a hands-free recording nobody is talking into any more (Fn tapped by accident, then the
/// user walked away): no speech for `limit`. Fed the recorder's levels (0...1, about 20 a second).
public struct SilenceWatch: Equatable, Sendable {
    /// This long without speech ends a hands-free recording.
    public static let limit: TimeInterval = 60
    /// A level at least this loud is a voice: about -50 dBFS (`AudioMath.speechRMS`), louder than a
    /// quiet room.
    public static let speechLevel: Float = AudioMath.normalizedLevel(rms: AudioMath.speechRMS)
    /// Loud levels in a row (about 50 ms each) that count as speech, so a click or a bump does not.
    public static let speechTicks = 3

    /// Someone spoke in this recording.
    public private(set) var heardSpeech = false
    private var quietSince: TimeInterval
    private var loudTicks = 0

    /// `startedAt`: when the audio started arriving.
    public init(startedAt: TimeInterval) {
        quietSince = startedAt
    }

    /// One level reading at time `t`. True while it has been quiet for `limit` or longer.
    public mutating func level(_ level: Float, at t: TimeInterval) -> Bool {
        if level >= Self.speechLevel {
            loudTicks += 1
            if loudTicks >= Self.speechTicks {
                heardSpeech = true
                quietSince = t
            }
        } else {
            loudTicks = 0
        }
        return t - quietSince >= Self.limit
    }
}

/// Chooses between the live transcript and a second pass over the whole recording.
///
/// The second pass wins only when it is clearly better: the live text is empty, or the live session
/// died early and the second pass is longer, or the second pass contains the whole live text and
/// more. A second pass that says a passage twice in a row where the live text does not (the
/// recognizer replayed a segment) never wins; the same words again after other words are just speech.
public enum SecondPass {
    /// A live session that only restarted (and stitched its pieces) gets a second pass up to this
    /// length of recording, which `RecognitionTiming.secondPass` can cover; a longer one keeps the
    /// live text rather than wait for a pass that cannot finish.
    public static let restartCheckLimit: TimeInterval = 120

    /// How long a second pass may take, or nil to skip it.
    /// - live: the live transcript. Empty: nothing came through live, recover all of it.
    /// - diedEarly: the live session restarted or did not finalize in time; a few words may be missing.
    /// - lostAudio: the live session gave up while audio was still coming: the rest was never recognized.
    public static func budget(live: String, diedEarly: Bool, lostAudio: Bool, hasSpeech: Bool,
                              audioSeconds: TimeInterval) -> TimeInterval? {
        guard hasSpeech else { return nil }
        if live.isEmpty || lostAudio { return RecognitionTiming.recovery(audioSeconds: audioSeconds) }
        guard diedEarly, audioSeconds <= restartCheckLimit else { return nil }
        return RecognitionTiming.secondPass(audioSeconds: audioSeconds)
    }

    /// Whether the text kept may be missing part of the recording: the live session lost audio and
    /// no complete second pass replaced it, or the second pass that won ran out of time.
    public static func incomplete(lostAudio: Bool, secondWon: Bool, secondComplete: Bool) -> Bool {
        if secondWon { return !secondComplete }
        return lostAudio
    }

    /// Splits a recording into pieces of at most `maxSeconds` for the second pass, each recognized
    /// by its own task (a task may stop at the end of an utterance, and all audio is already queued,
    /// so it cannot hand the rest to a new one). Each cut is made at the quietest 100 ms of the
    /// piece's last `searchSeconds`, between words where possible.
    public static func pieces(_ samples: [Float], sampleRate: Double, maxSeconds: Double = 30,
                              searchSeconds: Double = 10) -> [Range<Int>] {
        let maxLength = max(1, Int(maxSeconds * sampleRate))
        let search = min(maxLength, max(1, Int(searchSeconds * sampleRate)))
        let window = max(1, Int(0.1 * sampleRate))
        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxLength {
            let end = start + maxLength
            var cut = end
            var quietest = Float.infinity
            var w = end - search
            while w + window <= end {
                var energy: Float = 0
                for i in w..<(w + window) { energy += samples[i] * samples[i] }
                if energy < quietest {
                    quietest = energy
                    cut = w + window / 2
                }
                w += window
            }
            if cut <= start { cut = end }
            ranges.append(start..<cut)
            start = cut
        }
        if start < samples.count { ranges.append(start..<samples.count) }
        return ranges
    }

    public static func choose(live: String, second: String, liveDiedEarly: Bool) -> String {
        let l = letters(live), s = letters(second)
        if l.isEmpty { return s.isEmpty ? live : second }
        guard !s.isEmpty, s.count > l.count else { return live }
        if repeatsPassage(s) && !repeatsPassage(l) { return live }
        if isSubsequence(l, of: s) { return second }
        // A dead live session lost audio; a second pass clearly longer recovers it.
        if liveDiedEarly, Double(s.count) >= Double(l.count) * 1.1 { return second }
        return live
    }

    /// Letters, digits and CJK, lowercased: punctuation and spacing differ between passes.
    static func letters(_ text: String) -> [Character] {
        text.lowercased().filter { $0.isLetter || $0.isNumber }.map { $0 }
    }

    static func isSubsequence(_ a: [Character], of b: [Character]) -> Bool {
        var i = 0
        for c in b where i < a.count && c == a[i] { i += 1 }
        return i == a.count
    }

    /// A passage of at least max(6, a quarter of the text) characters followed at once by itself,
    /// as when the recognizer replays a segment. Punctuation is already gone, so "A，A" counts.
    static func repeatsPassage(_ t: [Character]) -> Bool {
        let n = t.count
        let m = max(6, n / 4)
        guard n >= 2 * m else { return false }
        // Small integers compare much faster than Characters.
        var ids: [Character: Int] = [:]
        let codes = t.map { c -> Int in
            if let id = ids[c] { return id }
            ids[c] = ids.count
            return ids.count - 1
        }
        // A passage of length p repeated back to back: p equal pairs in a row, p apart.
        for p in m...(n / 2) {
            var run = 0
            for k in 0..<(n - p) {
                run = codes[k] == codes[k + p] ? run + 1 : 0
                if run >= p { return true }
            }
        }
        return false
    }
}
