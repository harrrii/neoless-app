import AVFoundation
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NeolessCloud
import NeolessCore
import Testing
@testable import NeolessHubKit

/// What keeps one device (or anyone with its token) from crowding out dictation or filling the Neo: the two rate
/// limits, size limits, checks on what arrives without its text, and the worker's errors as devices see them.
@MainActor
@Suite struct HubLimitTests {
    // MARK: Rate limits

    @Test func dictationsHaveTheirOwnAllowance() async throws {
        let hub = try HubFixture(rateLimit: 3)
        for _ in 0..<3 { #expect(try await hub.send(.get, HubPath.vocabulary).status == .ok) }
        #expect(try await hub.send(.get, HubPath.health).status == .tooManyRequests)
        // Background syncing used up its minute: a dictation still goes through.
        for _ in 0..<3 {
            let polish = PolishRequest(text: "明天开会", mode: .natural, autoStructured: true, clientRecordingID: UUID())
            #expect(try await hub.post(HubPath.polish, polish).status == .ok)
        }
        let fourth = PolishRequest(text: "明天开会", mode: .natural, autoStructured: true, clientRecordingID: UUID())
        #expect(try await hub.post(HubPath.polish, fourth).status == .tooManyRequests)
        #expect(HubService.RequestKind.of(route: HubPath.dictations) == .dictation)
        #expect(HubService.RequestKind.of(route: "/v1/dictations/:id/repolish") == .dictation)
        #expect(HubService.RequestKind.of(route: "/v1/dictations/:id/edit") == .other)
        #expect(HubService.RequestKind.of(route: HubPath.sync) == .other)
    }

    @Test func aRefusedRequestIsLoggedWithItsDevice() async throws {
        let hub = try HubFixture(rateLimit: 1)
        let token = try hub.service.devices.pair(name: "限额测试").token
        let headers: HTTPFields = [.authorization: "Bearer \(token)"]
        _ = try await hub.send(.get, HubPath.sync, headers: headers)
        #expect(try await hub.send(.get, HubPath.sync, headers: headers).status == .tooManyRequests)
        #expect(TestLog.shared.all.contains { $0.contains("GET /v1/sync 429") && $0.hasSuffix(" 限额测试") })
    }

    // MARK: Sizes

    @Test func overlongTextIsRefused() async throws {
        let hub = try HubFixture()
        let long = String(repeating: "a", count: Hub.maxTextCharacters + 1)
        let polish = try await hub.post(HubPath.polish, PolishRequest(text: long, mode: .natural, autoStructured: true))
        #expect(polish.status == .contentTooLarge && errorBody(polish)?.code == HubErrorCode.tooLarge)
        let app = String(repeating: "x", count: Hub.maxNameCharacters + 1)
        let named = try await hub.post(HubPath.polish, PolishRequest(text: "明天开会", mode: .natural, autoStructured: true, appName: app))
        #expect(named.status == .contentTooLarge)
        #expect(hub.polisher.calls.isEmpty && hub.service.history.entries.isEmpty)

        let original = try decode(DictationResult.self, try await hub.dictate(dictation()))
        #expect(try await hub.post(HubPath.edit(original.id), EditRequest(text: long)).status == .contentTooLarge)
        #expect(hub.service.history.entry(id: original.id)?.result.text == original.text)
    }

    @Test func aWholeDictionaryAtItsLimitsFitsInOnePut() async throws {
        let hub = try HubFixture()
        let first = try decode(VocabularySnapshot.self, try await hub.send(.get, HubPath.vocabulary))
        // Vocabulary.maxWords words of Vocabulary.maxWordLength Chinese characters: about 480 KB of JSON.
        let words = (0..<Vocabulary.maxWords).map { n in
            String(format: "%04d", n) + String(repeating: "长", count: Vocabulary.maxWordLength - 4)
        }
        let body = try json(VocabularyUpdate(words: words, expectedRevision: first.revision))
        #expect(body.readableBytes > Hub.maxJSONBytes)
        let response = try await hub.send(.put, HubPath.vocabulary, body: body)
        #expect(response.status == .ok)
        #expect(try decode(VocabularySnapshot.self, response).words.count == Vocabulary.maxWords)
        // Other bodies keep the smaller limit.
        let big = try await hub.post(HubPath.learningObservations,
                                     LearningObservations(pairs: Array(repeating: CorrectionPair(wrong: words[0], right: words[1]), count: 2_000)))
        #expect(big.status == .contentTooLarge)
    }

    @Test func historyKeepsAtMostSoMuchText() throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let folder = try HubDataFolder.at(dir)
        let history = HubHistory(store: folder.store, byteLimit: 100)
        for n in 0..<5 {
            let text = String(repeating: "\(n)", count: 20)
            history.add(HubHistoryEntry(result: DictationResult(clientRecordingID: UUID(), raw: text, text: text, mode: .raw,
                                                                polished: false, recognizer: .qwen3ASR)))
        }
        // 40 bytes each: the two newest fit.
        #expect(history.entries.map { $0.result.raw.first } == ["4", "3"])
        #expect(HubHistory(store: folder.store, byteLimit: 100).entries.count == 2)
    }

    // MARK: Learning that arrives without its text

    @Test func observationsMustLookLikeTermFixes() async throws {
        let hub = try HubFixture(words: ["音币"])
        let harmful = LearningObservations(pairs: [CorrectionPair(wrong: "6222 0210 0112 3456", right: "6222 0299 8877 6655"),
                                                   CorrectionPair(wrong: "不同意", right: "同意"),
                                                   CorrectionPair(wrong: "我的密码", right: "我的密吗")])
        for _ in 0..<2 {
            let response = try decode(LearningObservationsResponse.self, try await hub.post(HubPath.learningObservations, harmful))
            #expect(response.accepted == 0)
        }
        #expect(hub.service.learning.pairs.isEmpty)
        let fine = LearningObservations(pairs: [CorrectionPair(wrong: "金币", right: "音币")])
        #expect(try decode(LearningObservationsResponse.self, try await hub.post(HubPath.learningObservations, fine)).accepted == 1)
        // Its reverse (a device counting it down) is taken too.
        let reverse = LearningObservations(pairs: [CorrectionPair(wrong: "音币", right: "金币")])
        _ = try await hub.post(HubPath.learningObservations, reverse)
        #expect(hub.service.learning.pairs.isEmpty)
    }

    @Test func anEditCanCarryTheTextOnly() async throws {
        let hub = try HubFixture()
        hub.polisher.answer = { text, _ in text }
        hub.asr.reply = .text("我的 I phone 坏了")
        let original = try decode(DictationResult.self, try await hub.dictate(dictation()))
        let edited = try decode(EditResponse.self, try await hub.post(HubPath.edit(original.id),
                                                                     EditRequest(text: "我的 iPhone 坏了", learn: false)))
        // The device sends what it learned itself: nothing is learned here, the text is kept.
        #expect(edited.learned.isEmpty && edited.result.text == "我的 iPhone 坏了")
        #expect(hub.service.learning.pairs.isEmpty)
        #expect(hub.service.history.entry(id: original.id)?.edited == true)
    }

    @Test func forgettingManyAtOnce() async throws {
        let hub = try HubFixture(words: ["音币"])
        let pairs = [CorrectionPair(wrong: "金币", right: "音币"), CorrectionPair(wrong: "You Tube", right: "YouTube"),
                     CorrectionPair(wrong: "Cloud", right: "Claude")]
        _ = try await hub.post(HubPath.learningObservations, LearningObservations(pairs: pairs))
        #expect(hub.service.learning.pairs.count == 3)
        // Matched as one DELETE matches: ignoring case and spacing. Missing ones are not an error.
        let after = try decode(LearningList.self, try await hub.post(HubPath.learningForget,
                                                                    LearningForget(wrongs: ["金币", "you  tube", "不存在"])))
        #expect(after.pairs.map(\.wrong) == ["Cloud"])
        #expect(!(try decode(VocabularySnapshot.self, try await hub.send(.get, HubPath.vocabulary)).words.contains("YouTube")))
        let tooMany = LearningForget(wrongs: (0...Hub.maxForgetWrongs).map { "w\($0)" })
        #expect(try await hub.post(HubPath.learningForget, tooMany).status == .badRequest)
    }

    // MARK: Errors

    @Test func workerErrorsByTheirCode() {
        func mapped(_ status: Int, _ code: String?) -> HubFailure {
            HubService.failure(forASR: ASRFailure.rejected(status: status, code: code))
        }
        // Only audio the worker cannot read is 422; only one over its limit is 413.
        #expect(mapped(400, "bad_audio") == .decodeFailed)
        #expect(mapped(415, "unsupported_audio") == .decodeFailed)
        #expect(mapped(413, "too_long") == .audioTooLong)
        #expect(mapped(413, "too_large") == .audioTooLong)
        // Everything else is the worker's trouble: retryable 503.
        for (status, code) in [(400, "upload_timeout"), (400, "bad_hints"), (415, "unsupported_type"), (503, "busy"),
                               (404, "not_found"), (405, "method_not_allowed"), (500, "internal"), (500, "asr_failed"),
                               (503, "model_unavailable"), (502, nil)] {
            #expect(mapped(status, code) == .asrUnavailable, "\(status) \(code ?? "-")")
        }
        #expect(HubService.failure(forASR: ASRFailure.timeout) == .asrUnavailable)
    }

    @Test func frameworkErrorsKeepTheContractsCodes() {
        #expect(HubServer.failure(for: HTTPError(.badRequest)) == .badRequest())
        #expect(HubServer.failure(for: HTTPError(.requestTimeout)) == .badRequest())
        #expect(HubServer.failure(for: HTTPError(.notFound)) == .noRoute)
        #expect(HubServer.failure(for: HTTPError(.methodNotAllowed)) == .noRoute)
        #expect(HubServer.failure(for: HTTPError(.contentTooLarge)) == .jsonTooLarge)
        let serverError = HubServer.failure(for: HTTPError(.internalServerError))
        #expect(serverError == .internalError && serverError.body.retryable && serverError.body.code == HubErrorCode.internalError)
        #expect(HubServer.failure(for: HTTPError(.serviceUnavailable)) == .internalError)
    }

    // MARK: Health

    @Test func healthSaysThePolishFloor() async throws {
        let hub = try HubFixture()
        #expect(try decode(HubHealth.self, try await hub.send(.get, HubPath.health)).polishTimeout == 10)
        #expect(hub.folder.store.write(HubConfig(polishTimeout: 30), to: HubDataFolder.File.settings))
        #expect(await eventually { hub.service.config.polishTimeout == 30 })
        #expect(try decode(HubHealth.self, try await hub.send(.get, HubPath.health)).polishTimeout == 30)
    }

    // MARK: Dictionary generations

    @Test func theDictionaryGenerationChangesOnlyWhenItStartsOver() throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let folder = try HubDataFolder.at(dir)
        let first = WordStore(store: folder.store)
        // Nothing saved yet: it starts over with the defaults.
        _ = try first.replace(words: ["Neo"] + first.words, expectedRevision: first.revision)
        let again = WordStore(store: folder.store)
        #expect(again.generation == first.generation && again.snapshot.generation == first.generation)
        // vocabulary.json unreadable: set aside, back to the defaults, and a new generation.
        try Data("not json".utf8).write(to: folder.file(HubDataFolder.File.vocabulary))
        let reset = WordStore(store: folder.store)
        #expect(reset.words == Vocabulary.defaults && reset.generation != first.generation)
        #expect(WordStore(store: folder.store).generation == reset.generation)
    }

    // MARK: Log

    @Test func requestsWithoutADeviceAreCountedNotLogged() async throws {
        let hub = try HubFixture()
        let path = "/v1/quiet-\(UUID().uuidString)"
        let response = try await hub.send(.get, path, headers: HTTPFields())
        #expect(response.status == .unauthorized)
        #expect(!TestLog.shared.all.contains { $0.contains(path) })

        let clock = Clock(Date(timeIntervalSince1970: 1_000))
        let quiet = QuietRequests(now: { clock.now })
        quiet.count(ping: true, status: 200)
        quiet.count(ping: false, status: 401)
        quiet.count(ping: false, status: 401)
        clock.now = clock.now.addingTimeInterval(QuietRequests.window + 1)
        quiet.count(ping: false, status: 404)
        #expect(TestLog.shared.all.contains { $0.hasSuffix("没有设备的请求：401 2，ping 1") })
    }

    // MARK: Audio

    @Test func audioThatDevicesDoNotRecordIsRefusedBeforeDecoding() throws {
        func facts(_ format: AudioFormatID = kAudioFormatMPEG4AAC, rate: Double = 16_000, channels: Int = 1,
                   seconds: Double = 10) -> AudioDecoding.Facts {
            AudioDecoding.Facts(formatID: format, sampleRate: rate, channels: channels, frames: Int64(seconds * rate))
        }
        #expect(throws: Never.self) { try AudioPrep.check(facts()) }
        #expect(throws: Never.self) { try AudioPrep.check(facts(kAudioFormatLinearPCM, rate: 44_100, channels: 2)) }
        // A small file that claims 8 channels of 192 kHz, or a codec no device records, is never decoded.
        #expect(throws: AudioPrep.Failure.undecodable) { try AudioPrep.check(facts(kAudioFormatAppleLossless)) }
        #expect(throws: AudioPrep.Failure.undecodable) { try AudioPrep.check(facts(kAudioFormatFLAC)) }
        #expect(throws: AudioPrep.Failure.undecodable) { try AudioPrep.check(facts(channels: 8)) }
        #expect(throws: AudioPrep.Failure.undecodable) { try AudioPrep.check(facts(rate: 192_000)) }
        #expect(throws: AudioPrep.Failure.tooLong) { try AudioPrep.check(facts(seconds: 602)) }
    }

    @Test func aSixChannelRecordingIsRefused() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("neoless-hub-test-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 48_000.0,
                                       AVNumberOfChannelsKey: 6, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            try file.write(from: buffer)
            if #available(macOS 15.0, *) { file.close() }
        }
        await #expect(throws: AudioPrep.Failure.undecodable) {
            try await AudioPrep.workerWAV(from: try Data(contentsOf: url), type: .caf)
        }
    }

    @Test func aRecordingJustOverTenMinutesIsCutToTheWorkersLimit() async throws {
        // The device's 10-minute cap plus its tail: a little over 600 s. The worker takes 600 s exactly.
        let rate = 8_000.0
        let wav = AudioUpload.wav([Int16](repeating: 0, count: Int(rate * 600.5)), sampleRate: rate)
        let prepared = try await AudioPrep.workerWAV(from: wav, type: .wav)
        #expect(prepared.seconds == AudioPrep.maxSeconds)
        #expect(prepared.wav.count == 44 + Int(AudioPrep.maxSeconds * AudioUpload.sampleRate) * 2)
    }
}

/// A clock tests move by hand.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
