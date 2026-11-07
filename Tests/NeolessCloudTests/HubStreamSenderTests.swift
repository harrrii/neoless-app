import Foundation
import Testing
@testable import NeolessCloud
import NeolessCore

/// The device's half of 边说边传: sending pieces, sending again what the hub lacks, and a hub from before it.
@Suite struct HubStreamSenderTests {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [Int] = []
        private var _failures: [Int: [Error]] = [:]
        var sent: [Int] { lock.withLock { _sent } }
        func fail(_ index: Int, with errors: [Error]) { lock.withLock { _failures[index] = errors } }
        func send(_ index: Int) throws {
            try lock.withLock {
                if var errors = _failures[index], !errors.isEmpty {
                    let error = errors.removeFirst()
                    _failures[index] = errors
                    throw error
                }
                _sent.append(index)
            }
        }
    }

    static func result() -> DictationResult {
        DictationResult(clientRecordingID: UUID(), raw: "听到的话", text: "听到的话", mode: .natural, polished: true,
                        recognizer: .qwen3ASR, timings: HubTimings(), createdAt: Date(timeIntervalSince1970: 0))
    }

    static func sender(_ log: Log) -> HubStreamSender {
        HubStreamSender(encode: { EncodedAudio(data: Data(count: $0.count), type: .wav, durationSeconds: 1) },
                        send: { _, index in try log.send(index) })
    }

    @Test func piecesAreSentAndTheRecordingFinished() async throws {
        let log = Log()
        let sender = Self.sender(log)
        await sender.add([0, 0], index: 0)
        await sender.add([0], index: 1)
        let result = try await sender.finish(chunks: 2) { chunks in
            #expect(chunks == 2)
            return Self.result()
        }
        #expect(result.raw == "听到的话" && log.sent == [0, 1])
    }

    @Test func aPassingHiccupIsTriedAgain() async throws {
        let log = Log()
        log.fail(0, with: [HubError.connectionLost, HubError.server(status: 503, body: nil)])
        await Self.sender(log).add([0], index: 0)
        #expect(log.sent == [0])
    }

    @Test func whatTheHubLacksIsSentAgain() async throws {
        let log = Log()
        log.fail(1, with: [HubError.timeout, HubError.timeout, HubError.timeout])   // gave up while the user spoke
        let sender = Self.sender(log)
        await sender.add([0], index: 0)
        await sender.add([0], index: 1)
        #expect(log.sent == [0])
        let asked = Asked()
        let result = try await sender.finish(chunks: 2) { _ in
            if asked.next() == 0 {
                throw HubError.server(status: 409, body: HubErrorBody(error: "缺", code: HubErrorCode.missingChunks,
                                                                      retryable: true, missing: [1]))
            }
            return Self.result()
        }
        #expect(result.raw == "听到的话" && log.sent == [0, 1])
    }

    @Test func aHubFromBeforePiecesIsLeftAlone() async throws {
        let log = Log()
        log.fail(0, with: [HubError.server(status: 404, body: nil)])
        let sender = Self.sender(log)
        await sender.add([0], index: 0)
        await sender.add([0], index: 1)   // not even tried
        #expect(await sender.isUnsupported && log.sent.isEmpty)
        await #expect(throws: HubStreamSender.Failure.unsupported) {
            try await sender.finish(chunks: 2) { _ in Self.result() }
        }
    }

    @Test func aTimeoutAtTheFinishIsTheCallersToAskAgain() async throws {
        let sender = Self.sender(Log())
        await sender.add([0], index: 0)
        await #expect(throws: HubError.timeout) {
            try await sender.finish(chunks: 1) { _ in throw HubError.timeout }
        }
    }

    @Test func aHubThatKeepsLosingPiecesIsGivenUpOn() async throws {
        let sender = Self.sender(Log())
        await sender.add([0], index: 0)
        await #expect(throws: HubStreamSender.Failure.incomplete) {
            try await sender.finish(chunks: 1) { _ in
                throw HubError.server(status: 409, body: HubErrorBody(error: "缺", code: HubErrorCode.missingChunks,
                                                                      retryable: true, missing: [0]))
            }
        }
    }

    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { defer { count += 1 }; return count } }
    }
}
