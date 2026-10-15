import Foundation

public enum AudioMath {
    /// RMS of a 100 ms window that counts as someone talking: about -50 dBFS. Quiet or
    /// distant speech sits around -45 dBFS; a quiet room on a laptop mic is near -60.
    public static let speechRMS: Float = 0.003

    /// Maps RMS to 0...1 over roughly -55 dBFS (quiet room) to -12 dBFS (loud speech).
    public static func normalizedLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 55) / 43))
    }

    /// True when some 100 ms window (at 16 kHz) is louder than a quiet room, i.e. worth a
    /// second recognition pass. Exact digital silence never counts.
    public static func hasSpeech(_ samples: [Float], threshold: Float = speechRMS) -> Bool {
        let window = 1_600
        let limit = threshold * threshold * Float(window)
        var i = 0
        while i + window <= samples.count {
            var sum: Float = 0
            for j in i..<(i + window) { sum += samples[j] * samples[j] }
            if sum > limit { return true }
            i += window
        }
        return false
    }
}

/// Decides, from buffer timestamps alone, whether the microphone is really delivering
/// audio. The recorder polls it for the whole recording, not just at start.
public enum CaptureHealth {
    public enum Device: Equatable, Sendable {
        case builtIn, bluetooth, other
    }

    public enum Verdict: Equatable, Sendable {
        case healthy
        /// No buffer at all since the engine started.
        case noBuffers
        /// Buffers arrive but are exact zeros. `switchDevice`: the device is disconnected
        /// (the built-in mic has no noise gate), go to another input. Otherwise the device
        /// may gate silence: reopen it once in case it is stuck.
        case digitalSilence(switchDevice: Bool)
        /// The built-in mic hears nothing because the lid is closed. Go to another input,
        /// but do not remember the mic as dead: it works again once the lid opens.
        case lidClosed
        /// Buffers were arriving and then stopped.
        case stalled
        /// A device that may gate silence delivered only exact zeros for `gatedPatience`
        /// although it was reopened, and nobody has been heard in this recording: give up.
        case neverHeard
    }

    /// Times are seconds on one monotonic clock. `firstSignalAt`/`lastSignalAt` are the
    /// first and latest buffers of the current engine that contained a non-zero sample.
    public struct Snapshot: Equatable, Sendable {
        public var engineStartedAt: Double
        public var firstBufferAt: Double?
        public var lastBufferAt: Double?
        public var lastSignalAt: Double?
        public var now: Double
        /// This recording already produced signal, on any device or engine.
        public var heard: Bool
        /// Times this recording reopened a device because it delivered only zeros.
        public var zeroRetries: Int

        public init(engineStartedAt: Double, firstBufferAt: Double? = nil, lastBufferAt: Double? = nil,
                    lastSignalAt: Double? = nil, now: Double, heard: Bool = false, zeroRetries: Int = 0) {
            self.engineStartedAt = engineStartedAt
            self.firstBufferAt = firstBufferAt
            self.lastBufferAt = lastBufferAt
            self.lastSignalAt = lastSignalAt
            self.now = now
            self.heard = heard
            self.zeroRetries = zeroRetries
        }
    }

    /// Waiting for the very first buffer. Bluetooth headsets switching to their
    /// microphone profile routinely take a few seconds.
    public static func firstBufferTimeout(_ device: Device) -> Double { device == .bluetooth ? 4.5 : 2.5 }
    /// Buffers stop arriving mid-recording.
    public static let stallTimeout = 1.5
    /// Exact zeros from the start. The built-in mic has no noise gate, so zeros there mean
    /// it is disconnected (lid closed); other devices may gate silence, so give them longer.
    public static func zeroTimeout(_ device: Device) -> Double { device == .builtIn ? 0.8 : 2.5 }
    /// A built-in mic that had signal and then turned to exact zeros while the lid is closed.
    public static let lidClosedZeroTimeout = 1.5
    /// A gating device (USB, Bluetooth) that was reopened once and still delivers only
    /// zeros: the user may simply not have started talking, so wait this long before failing.
    public static let gatedPatience = 30.0

    /// - Parameter lidClosed: only evaluated when it matters (a built-in mic delivering zeros).
    public static func check(_ s: Snapshot, device: Device, lidClosed: @autoclosure () -> Bool) -> Verdict {
        guard let first = s.firstBufferAt, let last = s.lastBufferAt else {
            return s.now - s.engineStartedAt >= firstBufferTimeout(device) ? .noBuffers : .healthy
        }
        if s.now - last >= stallTimeout { return .stalled }
        guard let signal = s.lastSignalAt else {
            // Only zeros from this engine so far.
            let zeros = s.now - first
            if device == .builtIn {
                guard zeros >= zeroTimeout(device) else { return .healthy }
                return lidClosed() ? .lidClosed : .digitalSilence(switchDevice: true)
            }
            // A gating device: zeros are the user not talking. Once anyone was heard in this
            // recording (even on another device before a restart) the device works, the user
            // is pausing. Before that, reopen it once, then wait for the first word.
            if s.heard { return .healthy }
            if s.zeroRetries == 0 { return zeros >= zeroTimeout(device) ? .digitalSilence(switchDevice: false) : .healthy }
            return zeros >= gatedPatience ? .neverHeard : .healthy
        }
        if device == .builtIn && s.now - signal >= lidClosedZeroTimeout && lidClosed() {
            return .lidClosed
        }
        return .healthy
    }

    /// What to do about `AVAudioEngineConfigurationChange`.
    public enum ConfigurationChange: Equatable, Sendable {
        /// Posted by our own (re)start and the engine still runs: nothing changed.
        case ignore
        /// Posted by our own (re)start, the engine stopped, but the input format is the one
        /// the tap was installed with: start the same engine again, no restart counted.
        case resume
        /// The audio hardware really changed: build a new engine.
        case restart
    }

    /// Switching the input device and starting the engine can post a configuration change
    /// shortly after the observer is registered. Treating that as a hardware change would
    /// make every restart trigger the next one.
    public static let ownChangeGrace = 1.0

    public static func configurationChange(secondsSinceStart: Double, engineRunning: Bool,
                                           formatChanged: Bool) -> ConfigurationChange {
        guard secondsSinceStart < ownChangeGrace, !formatChanged else { return .restart }
        return engineRunning ? .ignore : .resume
    }
}

/// Which microphone to record from when the user has not picked a specific one, and
/// where to go when one fails. Pure: the recorder supplies the devices.
public enum InputChoice {
    public struct Candidate: Equatable, Sendable {
        public var uid: String
        public var kind: CaptureHealth.Device
        /// Delivered only digital silence recently (with the lid open).
        public var markedSilent: Bool

        public init(uid: String, kind: CaptureHealth.Device, markedSilent: Bool = false) {
            self.uid = uid
            self.kind = kind
            self.markedSilent = markedSilent
        }
    }

    /// Auto: the built-in mic, so AirPods keep high-quality playback.
    /// - Lid closed (or no built-in mic): use the system default unless that is the built-in
    ///   mic itself or a virtual device (`inputs` lists only real ones: a loopback driver
    ///   delivers silence), then an external mic (wired/USB before Bluetooth). A virtual
    ///   default stays only when there is nothing else.
    /// - Built-in mic marked silent (lid open): the mark may be stale, so only a wired/USB
    ///   mic replaces it, never a Bluetooth headset, which would drop to low-quality
    ///   headset mode; without one the built-in mic is tried again.
    /// - Returns: the uid to record from; nil for the system default input.
    public static func auto(_ inputs: [Candidate], defaultUID: String?, lidClosed: Bool) -> String? {
        let defaultDevice = inputs.first { $0.uid == defaultUID }
        guard let builtIn = inputs.first(where: { $0.kind == .builtIn }), !lidClosed else {
            if let defaultDevice, defaultDevice.kind != .builtIn { return nil }
            let external = inputs.first { $0.kind == .other } ?? inputs.first { $0.kind == .bluetooth }
            return external?.uid ?? defaultDevice?.uid
        }
        guard builtIn.markedSilent else { return builtIn.uid }
        if let defaultDevice, defaultDevice.kind == .other, !defaultDevice.markedSilent { return nil }
        return inputs.first { $0.kind == .other && !$0.markedSilent }?.uid ?? builtIn.uid
    }

    /// Where to go when `failedUID` delivered nothing: the system default if that is
    /// another usable device, else a wired/USB mic, the built-in one, and a Bluetooth
    /// headset last. nil: the system default (also when nothing else is usable).
    public static func fallback(_ inputs: [Candidate], from failedUID: String?, defaultUID: String?,
                                lidClosed: Bool) -> String? {
        func usable(_ c: Candidate) -> Bool {
            c.uid != failedUID && !c.markedSilent && !(c.kind == .builtIn && lidClosed)
        }
        if let d = inputs.first(where: { $0.uid == defaultUID }), usable(d) { return nil }
        let others = inputs.filter(usable)
        let pick = others.first { $0.kind == .other } ?? others.first { $0.kind == .builtIn } ?? others.first
        return pick?.uid
    }
}
