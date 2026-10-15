import AVFoundation
import Foundation
import NeolessCloud

/// Turns an upload (m4a, WAV, CAF) into what the ASR worker takes: 16 kHz mono 16-bit PCM WAV, built in memory
/// with a complete header (`AudioUpload.wav`).
///
/// An upload is looked at before it is decoded: only the codecs devices record (AAC, PCM), one or two channels,
/// 8–48 kHz and at most `maxSeconds` (+1). Decoding then goes a chunk at a time straight to 16 kHz mono
/// (`AudioDecoding.samples`), and at most `concurrentDecodes` run at once: a small file that claims hours of
/// 8-channel 192 kHz audio cannot make the hub claim gigabytes.
public enum AudioPrep {
    /// The worker recognizes at most this much (docs/hub.md); longer uploads are not decoded at all. A recording
    /// that ends a little over it (the device's 10-minute cap plus its tail) is cut to it.
    public static let maxSeconds: Double = 600
    /// How much over `maxSeconds` is still taken (and cut).
    static let slackSeconds: Double = 1
    /// The codecs devices send: AAC (m4a, CAF) and PCM (WAV, CAF).
    static let codecs: Set<AudioFormatID> = [
        kAudioFormatLinearPCM, kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
        kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD,
    ]
    static let sampleRates: ClosedRange<Double> = 8_000...48_000
    static let maxChannels = 2
    /// Decodes running at once; more wait their turn.
    static let concurrentDecodes = 2

    public enum Failure: Error, Equatable {
        /// AVFoundation could not read it, or it is not audio a device records.
        case undecodable
        /// Longer than `maxSeconds`.
        case tooLong
    }

    public struct Prepared: Sendable {
        public var wav: Data
        public var seconds: Double
    }

    private static let slots = DecodeSlots(concurrentDecodes)

    /// Runs off the caller's actor: decoding a long recording takes a moment.
    public static func workerWAV(from data: Data, type: HubAudioType) async throws -> Prepared {
        await slots.acquire()
        defer { Task { await slots.release() } }
        return try await Task.detached(priority: .userInitiated) { try prepare(data, type: type) }.value
    }

    static func prepare(_ data: Data, type: HubAudioType) throws -> Prepared {
        guard !data.isEmpty else { throw Failure.undecodable }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoless-hub-\(UUID().uuidString).\(type.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw Failure.undecodable
        }
        // What the file says it is, before anything is decoded into memory.
        let facts: AudioDecoding.Facts
        do {
            facts = try AudioDecoding.facts(contentsOf: url)
        } catch {
            throw Failure.undecodable
        }
        try check(facts)
        let samples: [Float]
        do {
            samples = try AudioDecoding.samples(contentsOf: url, sampleRate: AudioUpload.sampleRate)
        } catch {
            throw Failure.undecodable
        }
        let limit = Int(maxSeconds * AudioUpload.sampleRate)
        guard samples.count <= limit + Int(slackSeconds * AudioUpload.sampleRate) else { throw Failure.tooLong }
        // The worker takes at most `maxSeconds` exactly.
        let kept = samples.count > limit ? Array(samples.prefix(limit)) : samples
        let seconds = Double(kept.count) / AudioUpload.sampleRate
        return Prepared(wav: AudioUpload.wav(AudioUpload.int16(kept), sampleRate: AudioUpload.sampleRate), seconds: seconds)
    }

    /// Refuses what devices never record (other codecs, more channels, odd rates) and what is too long.
    static func check(_ facts: AudioDecoding.Facts) throws {
        guard codecs.contains(facts.formatID), (1...maxChannels).contains(facts.channels),
              sampleRates.contains(facts.sampleRate), facts.frames >= 0 else { throw Failure.undecodable }
        if facts.seconds > maxSeconds + slackSeconds { throw Failure.tooLong }
    }
}

/// At most `count` holders at once; the others wait in order.
actor DecodeSlots {
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) { free = count }

    func acquire() async {
        if free > 0 {
            free -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
    }
}
