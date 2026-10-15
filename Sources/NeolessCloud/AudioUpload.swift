import AVFoundation
import Foundation

/// A recording ready to send to the hub.
public struct EncodedAudio: Equatable, Sendable {
    public var data: Data
    public var type: HubAudioType
    public var durationSeconds: Double

    public init(data: Data, type: HubAudioType, durationSeconds: Double) {
        self.data = data; self.type = type; self.durationSeconds = durationSeconds
    }
}

public enum AudioUploadError: LocalizedError, Equatable, Sendable {
    case encodeFailed(String)
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .encodeFailed: return "录音编码失败"
        case .decodeFailed: return "录音解码失败"
        }
    }
}

/// Encodes 16 kHz mono recordings for upload: AAC-LC in .m4a at about 32 kbit/s (a minute is about 240 KB,
/// a tenth of the WAV), and 16-bit WAV when AAC does not work. AVFoundation, macOS and iOS.
public enum AudioUpload {
    public static let sampleRate: Double = 16_000
    public static let bitRate = 32_000

    /// AAC m4a, or WAV when the AAC encoder fails. Never fails: WAV always works.
    public static func encode(_ samples: [Float], sampleRate: Double = AudioUpload.sampleRate) -> EncodedAudio {
        let duration = Double(samples.count) / sampleRate
        if !samples.isEmpty, let data = try? aac(samples, sampleRate: sampleRate) {
            return EncodedAudio(data: data, type: .m4a, durationSeconds: duration)
        }
        return EncodedAudio(data: wav(int16(samples), sampleRate: sampleRate), type: .wav, durationSeconds: duration)
    }

    public static func encode(_ samples: [Int16], sampleRate: Double = AudioUpload.sampleRate) -> EncodedAudio {
        let duration = Double(samples.count) / sampleRate
        if !samples.isEmpty, let data = try? aac(float(samples), sampleRate: sampleRate) {
            return EncodedAudio(data: data, type: .m4a, durationSeconds: duration)
        }
        return EncodedAudio(data: wav(samples, sampleRate: sampleRate), type: .wav, durationSeconds: duration)
    }

    /// AAC-LC in an MPEG-4 container (.m4a), mono.
    public static func aac(_ samples: [Float], sampleRate: Double = AudioUpload.sampleRate,
                           bitRate: Int = AudioUpload.bitRate) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoless-upload-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try writeAAC(samples, to: url, sampleRate: sampleRate, bitRate: bitRate)
            let data = try Data(contentsOf: url)
            return MP4Boxes.removingFreeSpace(data) ?? data
        } catch {
            throw AudioUploadError.encodeFailed(error.localizedDescription)
        }
    }

    /// Writes and closes the file (the encoder finishes the last packets and the container on close).
    private static func writeAAC(_ samples: [Float], to url: URL, sampleRate: Double, bitRate: Int) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk)),
              let channel = buffer.floatChannelData?[0]
        else { throw AudioUploadError.encodeFailed("no buffer") }
        var start = 0
        while start < samples.count {
            let count = min(chunk, samples.count - start)
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress! + start, count: count)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            start += count
        }
        if #available(macOS 15.0, iOS 18.0, *) { file.close() }
    }

    /// 16-bit little-endian PCM WAV, mono.
    public static func wav(_ samples: [Int16], sampleRate: Double = AudioUpload.sampleRate) -> Data {
        let rate = UInt32(sampleRate.rounded())
        let bytes = UInt32(samples.count * 2)
        var data = Data(capacity: 44 + Int(bytes))
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append32(36 + bytes); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1); append32(rate); append32(rate * 2); append16(2); append16(16)
        append("data"); append32(bytes)
        samples.withUnsafeBufferPointer { source in
            for sample in source { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
        }
        return data
    }

    /// Floats in -1…1 to 16-bit samples, clipped.
    public static func int16(_ samples: [Float]) -> [Int16] {
        samples.map { sample in
            let value = sample.isFinite ? max(-1, min(1, sample)) : 0
            return Int16((value * 32767).rounded())
        }
    }

    public static func float(_ samples: [Int16]) -> [Float] {
        samples.map { Float($0) / 32767 }
    }
}

/// The MPEG-4 writer leaves about 24 KB of padding (a `free` box) between the header and the audio, as much
/// as six seconds of speech. Removing it, and moving the chunk offsets that point past it, gives the same
/// file without the padding.
enum MP4Boxes {
    struct Box {
        let type: String
        let start: Int
        let headerSize: Int
        let end: Int
        var payload: Range<Int> { (start + headerSize)..<end }
        var size: Int { end - start }
    }

    /// Containers on the way from `moov` to the chunk offsets.
    static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]

    /// The file without top-level `free` / `skip` boxes; nil when it does not parse (then keep the original).
    static func removingFreeSpace(_ data: Data) -> Data? {
        var bytes = [UInt8](data)
        guard let top = boxes(bytes, in: 0..<bytes.count) else { return nil }
        let removed = top.filter { $0.type == "free" || $0.type == "skip" }
        guard !removed.isEmpty else { return data }
        guard let moov = top.first(where: { $0.type == "moov" }), patchOffsets(&bytes, in: moov.payload, removed: removed)
        else { return nil }
        for box in removed.sorted(by: { $0.start > $1.start }) { bytes.removeSubrange(box.start..<box.end) }
        return Data(bytes)
    }

    /// The boxes directly inside `range`; nil when a size does not fit.
    static func boxes(_ bytes: [UInt8], in range: Range<Int>) -> [Box]? {
        var found: [Box] = []
        var i = range.lowerBound
        while i < range.upperBound {
            guard i + 8 <= range.upperBound else { return nil }
            var size = Int(read32(bytes, at: i))
            var header = 8
            if size == 1 {
                guard i + 16 <= range.upperBound else { return nil }
                size = Int(clamping: read64(bytes, at: i + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - i
            }
            guard size >= header, i + size <= range.upperBound else { return nil }
            found.append(Box(type: String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self), start: i, headerSize: header, end: i + size))
            i += size
        }
        return found
    }

    /// Moves every chunk offset (`stco`, `co64`) back by the removed bytes before it.
    private static func patchOffsets(_ bytes: inout [UInt8], in range: Range<Int>, removed: [Box]) -> Bool {
        guard let children = boxes(bytes, in: range) else { return false }
        for box in children {
            if containers.contains(box.type) {
                guard patchOffsets(&bytes, in: box.payload, removed: removed) else { return false }
            } else if box.type == "stco" || box.type == "co64" {
                let width = box.type == "stco" ? 4 : 8
                let payload = box.payload
                guard payload.count >= 8 else { return false }
                let count = Int(read32(bytes, at: payload.lowerBound + 4))
                guard payload.count >= 8 + count * width else { return false }
                for n in 0..<count {
                    let at = payload.lowerBound + 8 + n * width
                    let offset = width == 4 ? UInt64(read32(bytes, at: at)) : read64(bytes, at: at)
                    // An offset inside removed space would point at nothing: leave the file alone.
                    guard !removed.contains(where: { UInt64($0.start) <= offset && offset < UInt64($0.end) }) else { return false }
                    let shift = removed.filter { UInt64($0.end) <= offset }.reduce(0) { $0 + $1.size }
                    let moved = offset - UInt64(shift)
                    if width == 4 { write32(&bytes, UInt32(moved), at: at) } else { write64(&bytes, moved, at: at) }
                }
            }
        }
        return true
    }

    static func read32(_ bytes: [UInt8], at i: Int) -> UInt32 {
        bytes[i..<(i + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func read64(_ bytes: [UInt8], at i: Int) -> UInt64 {
        bytes[i..<(i + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func write32(_ bytes: inout [UInt8], _ value: UInt32, at i: Int) {
        for k in 0..<4 { bytes[i + k] = UInt8(truncatingIfNeeded: value >> (8 * (3 - k))) }
    }

    private static func write64(_ bytes: inout [UInt8], _ value: UInt64, at i: Int) {
        for k in 0..<8 { bytes[i + k] = UInt8(truncatingIfNeeded: value >> (8 * (7 - k))) }
    }
}

/// Reads any recording AVFoundation knows (m4a, WAV, CAF) back as mono Float samples at one rate:
/// how the hub turns an upload into what its recognizer takes, and how tests check an encoding.
public enum AudioDecoding {
    public static func samples(from data: Data, type: HubAudioType, sampleRate: Double = AudioUpload.sampleRate) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoless-decode-\(UUID().uuidString).\(type.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url)
        } catch {
            throw AudioUploadError.decodeFailed(error.localizedDescription)
        }
        return try samples(contentsOf: url, sampleRate: sampleRate)
    }

    /// What a recording says about itself, read from its header before anything is decoded.
    public struct Facts: Equatable, Sendable {
        /// The codec (`kAudioFormatMPEG4AAC`, `kAudioFormatLinearPCM`, …).
        public var formatID: AudioFormatID
        public var sampleRate: Double
        public var channels: Int
        public var frames: Int64
        public var seconds: Double { sampleRate > 0 ? Double(frames) / sampleRate : .infinity }

        public init(formatID: AudioFormatID, sampleRate: Double, channels: Int, frames: Int64) {
            self.formatID = formatID; self.sampleRate = sampleRate; self.channels = channels; self.frames = frames
        }
    }

    public static func facts(contentsOf url: URL) throws -> Facts {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioUploadError.decodeFailed(error.localizedDescription)
        }
        let format = file.fileFormat
        return Facts(formatID: format.streamDescription.pointee.mFormatID, sampleRate: format.sampleRate,
                     channels: Int(format.channelCount), frames: file.length)
    }

    /// How many frames are read and converted at a time: memory stays at a few of these plus the output.
    static let chunkFrames: AVAudioFrameCount = 32_768

    /// The recording as mono samples at `sampleRate`, decoded and converted a chunk at a time, so memory grows with
    /// the output (16 kHz mono) and not with the file's own rate and channels.
    public static func samples(contentsOf url: URL, sampleRate: Double = AudioUpload.sampleRate) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AudioUploadError.decodeFailed(error.localizedDescription)
        }
        let source = file.processingFormat
        guard file.length > 0 else { return [] }
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunkFrames) else {
            throw AudioUploadError.decodeFailed("no buffer")
        }
        /// The next chunk, or false at the end of the file.
        func readChunk() throws -> Bool {
            guard file.framePosition < file.length else { return false }
            do {
                try file.read(into: input, frameCount: chunkFrames)
            } catch {
                throw AudioUploadError.decodeFailed(error.localizedDescription)
            }
            return input.frameLength > 0
        }
        var out: [Float] = []
        if source.sampleRate == sampleRate && source.channelCount == 1 {
            out.reserveCapacity(Int(file.length))
            while try readChunk() {
                guard let channel = input.floatChannelData?[0] else { throw AudioUploadError.decodeFailed("no channel") }
                out.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(input.frameLength)))
            }
            return out
        }
        // Mixes down to mono and resamples, a chunk at a time.
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target)
        else { throw AudioUploadError.decodeFailed("no converter") }
        converter.downmix = true
        let capacity = AVAudioFrameCount(Double(chunkFrames) * sampleRate / source.sampleRate) + 4_096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw AudioUploadError.decodeFailed("no buffer")
        }
        out.reserveCapacity(Int(Double(file.length) * sampleRate / source.sampleRate) + 4_096)
        var ended = false
        var readFailure: Error?
        while true {
            output.frameLength = 0
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { _, state in
                do {
                    if !ended, try readChunk() {
                        state.pointee = .haveData
                        return input
                    }
                } catch {
                    readFailure = error
                }
                ended = true
                state.pointee = .endOfStream
                return nil
            }
            if let readFailure { throw readFailure }
            guard status != .error, let channel = output.floatChannelData?[0] else {
                throw AudioUploadError.decodeFailed(failure?.localizedDescription ?? "convert")
            }
            out.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            if status == .endOfStream || (status == .inputRanDry && ended) { return out }
        }
    }
}
