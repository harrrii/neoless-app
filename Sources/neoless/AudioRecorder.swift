import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import IOKit
import NeolessCore

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let kind: CaptureHealth.Device
    /// Software devices (loopback drivers, meeting-app mics, aggregates): never picked automatically.
    let isVirtual: Bool

    var isBuiltIn: Bool { kind == .builtIn }
}

/// CoreAudio device lookup, so neoless can record from the built-in mic while
/// AirPods stay in high-quality playback mode. The choices themselves are
/// `InputChoice` (NeolessCore, unit-tested).
enum AudioDevices {
    static func inputs() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? uid
            let type = transport(id)
            let isVirtual = type == kAudioDeviceTransportTypeVirtual || type == kAudioDeviceTransportTypeAggregate
                || type == kAudioDeviceTransportTypeAutoAggregate
            return AudioInputDevice(id: id, uid: uid, name: name, kind: kind(transport: type), isVirtual: isVirtual)
        }
    }

    static func defaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    /// nil means "leave AVAudioEngine on the system default input".
    /// Auto skips the built-in mic while it cannot hear anything (lid closed, or it
    /// delivered only zeros a moment ago), so it never stalls on a dead mic; the rules
    /// are `InputChoice.auto`.
    static func resolve(preference: String) -> AudioInputDevice? {
        let all = inputs()
        switch preference {
        case AppSettingsKeys.microphoneSystem: return nil
        case AppSettingsKeys.microphoneAuto: break
        default:
            if let chosen = all.first(where: { $0.uid == preference }) { return chosen }
        }
        let lid = lidState(all)
        let uid = InputChoice.auto(candidates(all), defaultUID: defaultInput().flatMap(uid(of:)), lidClosed: lid)
        return all.first { $0.uid == uid }
    }

    /// Where to go when `failed` produced nothing (see `InputChoice.fallback`).
    static func fallback(from failed: AudioDeviceID?) -> AudioInputDevice? {
        let all = inputs()
        let lid = lidState(all)
        let uid = InputChoice.fallback(candidates(all), from: failed.flatMap(uid(of:)),
                                       defaultUID: defaultInput().flatMap(uid(of:)), lidClosed: lid)
        return all.first { $0.uid == uid }
    }

    private static func candidates(_ all: [AudioInputDevice]) -> [InputChoice.Candidate] {
        all.filter { !$0.isVirtual }.map { InputChoice.Candidate(uid: $0.uid, kind: $0.kind, markedSilent: isSilent($0.uid)) }
    }

    // MARK: Devices that recently delivered only digital silence

    private static let memoryLock = NSLock()
    nonisolated(unsafe) private static var silentSince: [String: Date] = [:]

    /// Remembered for 10 minutes, or until the device produces sound again. Never set
    /// because of a closed lid: that mic works again as soon as the lid opens.
    static func markSilent(_ uid: String) { memoryLock.withLock { silentSince[uid] = Date() } }
    static func markHeard(_ uid: String) { _ = memoryLock.withLock { silentSince.removeValue(forKey: uid) } }
    static func isSilent(_ uid: String) -> Bool {
        memoryLock.withLock {
            guard let since = silentSince[uid] else { return false }
            return Date().timeIntervalSince(since) < 600
        }
    }

    /// The lid state, also clearing the built-in mic's silent mark whenever the lid is seen
    /// closed: a mark made while the lid was closing (before IOKit reported it) would
    /// otherwise keep Auto away from the built-in mic for 10 minutes after it opens.
    static func lidState(_ all: [AudioInputDevice]) -> Bool {
        let closed = lidClosed()
        if closed {
            for device in all where device.isBuiltIn { markHeard(device.uid) }
        }
        return closed
    }

    // MARK: Properties

    /// MacBook lid closed (clamshell mode): the built-in mic is disconnected but still listed.
    static func lidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }

    static func name(of id: AudioDeviceID) -> String? { string(id, kAudioObjectPropertyName) }
    static func uid(of id: AudioDeviceID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }

    static func kind(of id: AudioDeviceID) -> CaptureHealth.Device { kind(transport: transport(id)) }

    private static func kind(transport: UInt32) -> CaptureHealth.Device {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        default: return .other
        }
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, value > 0 else { return nil }
        return value
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// Keys shared with AppSettings without making this file main-actor bound.
enum AppSettingsKeys {
    static let microphoneAuto = ""
    static let microphoneSystem = "system"
}

/// Microphone capture with AVAudioEngine. Every buffer is converted to 16 kHz
/// mono Float32, so a device or format change mid-recording (AirPods
/// connecting, FaceTime starting) only needs a new converter.
///
/// A watchdog checks the capture for the whole recording (`CaptureHealth`): no
/// buffers, only digital zeros, or buffers that stop arriving all restart the
/// engine, keeping what was recorded so far. Call `start`/`stop` on the main thread.
///
/// DictationController.begin wires it all: `onDeviceChange` keeps the shown device name
/// current, and `onFailure` mid-recording with `heardSignal` finishes with what was recorded
/// (`CaptureFlow` `.captureFailed(heardSignal:)` → `.finish(.salvage)`).
final class AudioRecorder: @unchecked Sendable {
    enum Failure: LocalizedError {
        case noInput, startFailed(String), noAudio
        var errorDescription: String? {
            switch self {
            case .noInput: return "没有可用的麦克风"
            // Our own reasons are Chinese; a system error's text may be English, so it gets the advice instead.
            case .startFailed(let why) where why.unicodeScalars.contains(where: { $0.properties.isIdeographic }):
                return "麦克风启动失败：\(why)"
            case .startFailed: return "麦克风启动失败，请换一个麦克风再试"
            case .noAudio: return "麦克风没有声音进来，请在设置里换一个麦克风再试"
            }
        }
    }

    static let sampleRate = 16_000.0

    /// Called on the audio thread with 16 kHz mono buffers.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Main thread, ~20 times a second, 0...1.
    var onLevel: ((Float) -> Void)?
    /// Main thread, once per recording: the first buffer that is not pure digital silence.
    var onFirstAudio: (() -> Void)?
    /// Main thread. Capture has already stopped; `recordedSamples()` still holds everything
    /// recorded before the failure, and `heardSignal` says whether any of it is sound.
    var onFailure: ((Failure) -> Void)?
    /// Main thread, whenever capture moves to another device (fallback or restart).
    var onDeviceChange: ((String) -> Void)?
    /// The device actually being recorded from; follows fallbacks.
    private(set) var deviceName = ""

    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var watchdog: DispatchSourceTimer?
    private var preference = ""
    private var silentRestartsLeft = 2
    private var stallRestartsLeft = 3
    private var deviceRestartsLeft = 6
    private var zeroRetries = 0         // reopened a gating device because it sent only zeros
    private var running = false
    private var currentChoice: AudioInputDevice?   // what the engine was opened with; nil: system default
    private var currentDevice: AudioDeviceID?
    private var currentKind = CaptureHealth.Device.other
    private var tapFormat: AVAudioFormat?

    private let lock = NSLock()
    private var samples: [Float] = []
    private var signalled = false       // this recording has produced a non-zero buffer
    private var engineStartedAt: Double = 0
    private var firstBufferAt: Double?
    private var lastBufferAt: Double?
    private var lastSignalAt: Double?
    private var levelPeak: Float = 0
    private var lastLevelAt: CFAbsoluteTime = 0

    var duration: TimeInterval { lock.withLock { Double(samples.count) / Self.sampleRate } }
    func recordedSamples() -> [Float] { lock.withLock { samples } }
    /// This recording has produced at least one buffer that is not digital silence.
    var heardSignal: Bool { lock.withLock { signalled } }

    func start(preference: String) throws {
        self.preference = preference
        silentRestartsLeft = 2
        stallRestartsLeft = 3
        deviceRestartsLeft = 6
        zeroRetries = 0
        lock.withLock { samples.removeAll(keepingCapacity: true); signalled = false }
        running = true
        do {
            try startEngine(device: AudioDevices.resolve(preference: preference))
        } catch {
            running = false
            throw error
        }
        startWatchdog()
    }

    func stop() {
        running = false
        watchdog?.cancel()
        watchdog = nil
        teardown()
    }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// Opens `device` (nil: system default). If the input node still reports another
    /// device's format after the switch, installing a tap would raise an uncatchable
    /// Objective-C exception, so that case falls back to the system default instead.
    private func startEngine(device: AudioInputDevice?) throws {
        let (engine, format, used) = try makeEngine(device: device)
        let converter = try makeConverter(from: format)
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer, converter: converter)
        }
        lock.withLock {
            engineStartedAt = Self.now()
            firstBufferAt = nil; lastBufferAt = nil; lastSignalAt = nil
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure.startFailed(error.localizedDescription)
        }
        self.engine = engine
        tapFormat = format
        currentChoice = used

        let id = used?.id ?? AudioDevices.defaultInput()
        currentDevice = id
        currentKind = id.map(AudioDevices.kind(of:)) ?? .other
        let name = used?.name ?? id.flatMap(AudioDevices.name(of:)) ?? "系统默认麦克风"
        if name != deviceName {
            let changed = !deviceName.isEmpty
            deviceName = name
            if changed { onDeviceChange?(name) }
        }

        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self, weak engine] _ in
            guard let self, let engine else { return }
            self.configurationChanged(engine)
        }
    }

    /// Main thread. Our own device switch and start can post a change right after the
    /// observer is registered; restarting for it would make each restart trigger the next.
    private func configurationChanged(_ changed: AVAudioEngine) {
        // A late notification from an engine that a restart already replaced.
        guard running, changed === engine else { return }
        let since = Self.now() - lock.withLock { engineStartedAt }
        let format = changed.inputNode.outputFormat(forBus: 0)
        let formatChanged = tapFormat.map { $0.sampleRate != format.sampleRate || $0.channelCount != format.channelCount } ?? true
        switch CaptureHealth.configurationChange(secondsSinceStart: since, engineRunning: changed.isRunning,
                                                 formatChanged: formatChanged) {
        case .ignore: break
        case .resume:
            do { try changed.start() } catch { restart(.deviceChanged) }
        case .restart: restart(.deviceChanged)
        }
    }

    private func makeEngine(device: AudioInputDevice?) throws -> (AVAudioEngine, AVAudioFormat, AudioInputDevice?) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        var used = device
        if let device, let unit = input.audioUnit {
            var id = device.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { used = nil }
        }
        let hardware = input.inputFormat(forBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            if device != nil { return try makeEngine(device: nil) }
            throw Failure.noInput
        }
        var consistent = hardware.sampleRate <= 0 || hardware.sampleRate == format.sampleRate
        if let used, let nominal = AudioDevices.nominalSampleRate(used.id), nominal != format.sampleRate {
            consistent = false
        }
        guard consistent else {
            if device != nil { return try makeEngine(device: nil) }
            throw Failure.startFailed("音频格式不一致")
        }
        return (engine, format, used)
    }

    private func makeConverter(from format: AVAudioFormat) throws -> AVAudioConverter {
        guard let converter = AVAudioConverter(from: format, to: target) else { throw Failure.startFailed("音频格式不支持") }
        if format.channelCount > 2 {
            // Audio interfaces: the mic is usually on input 1. Averaging it with silent
            // inputs would make it 6-18 dB quieter.
            converter.channelMap = [0]
        } else if format.channelCount == 2 {
            converter.downmix = true
        }
        return converter
    }

    private func teardown() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    // MARK: Watchdog

    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        watchdog = timer
        timer.resume()
    }

    private func checkHealth() {
        guard running, engine != nil else { return }
        let snapshot = lock.withLock {
            CaptureHealth.Snapshot(engineStartedAt: engineStartedAt, firstBufferAt: firstBufferAt,
                                   lastBufferAt: lastBufferAt, lastSignalAt: lastSignalAt, now: Self.now(),
                                   heard: signalled, zeroRetries: zeroRetries)
        }
        // IOKit is only asked when it matters: a built-in mic delivering zeros.
        switch CaptureHealth.check(snapshot, device: currentKind, lidClosed: AudioDevices.lidClosed()) {
        case .healthy: break
        case .noBuffers: restart(.silent)
        case .digitalSilence(switchDevice: false): restart(.gatedZeros)
        case .digitalSilence(switchDevice: true):
            if let id = currentDevice, let uid = AudioDevices.uid(of: id) { AudioDevices.markSilent(uid) }
            restart(.deadDevice)
        case .lidClosed:
            // Not remembered as dead: the built-in mic works again once the lid opens.
            if let id = currentDevice, let uid = AudioDevices.uid(of: id) { AudioDevices.markHeard(uid) }
            restart(.deadDevice)
        case .stalled: restart(.stalled)
        case .neverHeard: fail(.noAudio)
        }
    }

    private enum RestartReason { case silent, gatedZeros, deadDevice, stalled, deviceChanged }

    /// Restarts capture without dropping the samples recorded so far.
    /// - silent: no buffers yet. First retry the same device, then the fallback.
    /// - gatedZeros: a device that may gate silence sent only zeros; reopen it once.
    /// - deadDevice: the device is disconnected (zeros); go straight to the fallback.
    /// - stalled: buffers stopped mid-recording; reopen the preferred device.
    /// - deviceChanged: the audio hardware changed under us.
    private func restart(_ reason: RestartReason) {
        guard running else { return }
        let budget: Int
        switch reason {
        case .silent, .deadDevice: budget = silentRestartsLeft
        case .gatedZeros: budget = 1   // CaptureHealth asks for it at most once per recording
        case .stalled: budget = stallRestartsLeft
        case .deviceChanged: budget = deviceRestartsLeft
        }
        guard budget > 0 else {
            fail(.noAudio)
            return
        }
        let failed = currentDevice
        var device: AudioInputDevice?
        switch reason {
        case .silent:
            silentRestartsLeft -= 1
            // Last silent retry: fall back to whatever macOS considers the default input.
            device = silentRestartsLeft == 0 ? AudioDevices.fallback(from: failed) : AudioDevices.resolve(preference: preference)
        case .gatedZeros:
            zeroRetries += 1
            device = currentChoice
        case .deadDevice:
            silentRestartsLeft -= 1
            device = AudioDevices.fallback(from: failed)
        case .stalled:
            stallRestartsLeft -= 1
            device = AudioDevices.resolve(preference: preference)
        case .deviceChanged:
            deviceRestartsLeft -= 1
            device = AudioDevices.resolve(preference: preference)
        }
        teardown()
        do {
            try startEngine(device: device)
        } catch {
            fail(error as? Failure ?? .startFailed(error.localizedDescription))
        }
    }

    /// Stops capture and reports; what was recorded stays in `recordedSamples()`.
    private func fail(_ failure: Failure) {
        stop()
        onFailure?(failure)
    }

    // MARK: Audio thread

    private func process(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
        let frames = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))

        var sum: Float = 0
        var nonZero = false
        for s in frames {
            sum += s * s
            if s != 0 { nonZero = true }
        }
        let rms = (sum / Float(frames.count)).squareRoot()

        var first = false
        var emitLevel: Float?
        let now = Self.now()
        let wall = CFAbsoluteTimeGetCurrent()
        lock.withLock {
            samples.append(contentsOf: frames)
            if firstBufferAt == nil { firstBufferAt = now }
            lastBufferAt = now
            if nonZero {
                lastSignalAt = now
                if !signalled { signalled = true; first = true }
            }
            levelPeak = max(levelPeak, rms)
            if wall - lastLevelAt >= 0.05 {
                emitLevel = levelPeak
                levelPeak = 0
                lastLevelAt = wall
            }
        }
        onBuffer?(out)
        if first {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let id = self.currentDevice, let uid = AudioDevices.uid(of: id) { AudioDevices.markHeard(uid) }
                self.onFirstAudio?()
            }
        }
        if let level = emitLevel {
            let normalized = AudioMath.normalizedLevel(rms: level)
            DispatchQueue.main.async { [weak self] in self?.onLevel?(normalized) }
        }
    }
}
