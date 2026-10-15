import Foundation
import Testing
@testable import NeolessCloud

private func sine(seconds: Double, rate: Double = 16_000, frequency: Double = 440, amplitude: Float = 0.5) -> [Float] {
    (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
}

private func rms(_ samples: some Collection<Float>) -> Float {
    guard !samples.isEmpty else { return 0 }
    return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
}

@Suite struct AudioUploadTests {
    @Test func floatSamplesBecomeSmallAAC() throws {
        let samples = sine(seconds: 2.5)
        let encoded = AudioUpload.encode(samples)
        #expect(encoded.type == .m4a)
        #expect(encoded.durationSeconds == 2.5)
        // An MPEG-4 file ("ftyp" box first), about 32 kbit/s: far smaller than the 80 KB of WAV.
        #expect(encoded.data.count > 1_000)
        #expect(encoded.data.count < AudioUpload.wav(AudioUpload.int16(samples)).count / 4, "\(encoded.data.count)")
        #expect(String(decoding: encoded.data[4..<8], as: UTF8.self) == "ftyp")
        // Without the writer's padding.
        let top = try #require(MP4Boxes.boxes([UInt8](encoded.data), in: 0..<encoded.data.count)).map(\.type)
        #expect(top.contains("moov") && top.contains("mdat") && !top.contains("free"), "\(top)")

        let decoded = try AudioDecoding.samples(from: encoded.data, type: .m4a)
        let seconds = Double(decoded.count) / AudioUpload.sampleRate
        #expect(abs(seconds - 2.5) < 0.05, "\(seconds)")
        // Still the same tone: the energy survives the lossy round trip.
        let middle = decoded.dropFirst(4_000).prefix(30_000)
        #expect(abs(rms(middle) - rms(samples)) / rms(samples) < 0.2, "\(rms(middle)) vs \(rms(samples))")
    }

    @Test func int16SamplesToo() throws {
        let samples = AudioUpload.int16(sine(seconds: 1, frequency: 220, amplitude: 0.3))
        let encoded = AudioUpload.encode(samples)
        #expect(encoded.type == .m4a && encoded.durationSeconds == 1)
        let decoded = try AudioDecoding.samples(from: encoded.data, type: .m4a)
        #expect(abs(Double(decoded.count) / 16_000 - 1) < 0.05, "\(decoded.count)")
    }

    @Test func aMinuteIsAboutAQuarterMegabyte() throws {
        let encoded = AudioUpload.encode(sine(seconds: 60, amplitude: 0.2))
        #expect(encoded.type == .m4a)
        // 32 kbit/s × 60 s = 240 KB, give or take the encoder's rate control.
        #expect(encoded.data.count > 150_000 && encoded.data.count < 330_000, "\(encoded.data.count)")
        let decoded = try AudioDecoding.samples(from: encoded.data, type: .m4a)
        #expect(abs(Double(decoded.count) / 16_000 - 60) < 0.05)
    }

    @Test func wavHeaderAndExactRoundTrip() throws {
        let samples: [Int16] = [0, 1, -1, 32767, -32768, 1234, -4321]
        let data = AudioUpload.wav(samples)
        #expect(data.count == 44 + samples.count * 2)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")
        let rate = data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: rate) == 16_000)
        let first = data[44..<46].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        #expect(Int16(littleEndian: first) == 0)

        let decoded = try AudioDecoding.samples(from: data, type: .wav)
        #expect(decoded.count == samples.count)
        let back = decoded.map { Int16(max(-32768, min(32767, ($0 * 32768).rounded()))) }
        #expect(back == samples)
    }

    @Test func emptyRecordingIsAnEmptyWAV() throws {
        let encoded = AudioUpload.encode([Float]())
        #expect(encoded.type == .wav && encoded.durationSeconds == 0 && encoded.data.count == 44)
        #expect(try AudioDecoding.samples(from: encoded.data, type: .wav).isEmpty)
        #expect(AudioUpload.encode([Int16]()).type == .wav)
    }

    @Test func decodingResamplesToSixteenKilohertz() throws {
        let high = AudioUpload.int16(sine(seconds: 1, rate: 48_000, amplitude: 0.4))
        let data = AudioUpload.wav(high, sampleRate: 48_000)
        let decoded = try AudioDecoding.samples(from: data, type: .wav)
        #expect(abs(decoded.count - 16_000) < 200, "\(decoded.count)")
        #expect(abs(rms(decoded.dropFirst(1_000).prefix(14_000)) - 0.4 / 2.0.squareRoot().f) < 0.03)
    }

    @Test func garbageDoesNotDecode() {
        #expect(throws: AudioUploadError.self) {
            try AudioDecoding.samples(from: Data("not audio at all".utf8), type: .m4a)
        }
    }

    @Test func paddingRemovalMovesChunkOffsets() throws {
        func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let size = UInt32(8 + payload.count)
            return [UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)] + Array(type.utf8) + payload
        }
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func file(chunkOffset: Int, padding: Int) -> [UInt8] {
            let ftyp = box("ftyp", Array("M4A ".utf8) + [0, 0, 0, 0])
            let stco = box("stco", [0, 0, 0, 0] + be32(1) + be32(chunkOffset))
            let moov = box("moov", box("trak", box("mdia", box("minf", box("stbl", stco)))) + box("udta", [1, 2, 3]))
            let free = padding > 0 ? box("free", [UInt8](repeating: 0, count: padding)) : []
            return ftyp + moov + free + box("mdat", [9, 9, 9, 9])
        }
        let headerLength = file(chunkOffset: 0, padding: 0).count - 12
        let padded = file(chunkOffset: headerLength + 100 + 8 + 8, padding: 100)
        let compact = try #require(MP4Boxes.removingFreeSpace(Data(padded)))
        #expect([UInt8](compact) == file(chunkOffset: headerLength + 8, padding: 0))
        // Nothing to remove: unchanged. Not MPEG-4: nil, the caller keeps the original.
        #expect(MP4Boxes.removingFreeSpace(compact) == compact)
        #expect(MP4Boxes.removingFreeSpace(Data("not an mp4 file".utf8)) == nil)
        // An offset pointing into the padding: left alone.
        #expect(MP4Boxes.removingFreeSpace(Data(file(chunkOffset: headerLength + 20, padding: 100))) == nil)
    }

    @Test func conversions() {
        #expect(AudioUpload.int16([0, 1, -1, 2, -2, .nan, 0.5]) == [0, 32767, -32767, 32767, -32767, 0, 16384])
        #expect(AudioUpload.float([0, 32767, -32767]) == [0, 1, -1])
    }
}

private extension Double {
    var f: Float { Float(self) }
}
