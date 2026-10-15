import Foundation
import NeolessCloud
import NeolessCore
import Testing
@testable import NeolessHubKit

/// The data files: devices, dictionary and learning, history, settings, the worker secret, and audio decoding.
@MainActor
@Suite struct HubStoreTests {
    private func folder() throws -> (HubDataFolder, URL) {
        let dir = temporaryDirectory()
        return (try HubDataFolder.at(dir), dir)
    }

    private func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
    }

    @Test func dataFolderIsOwnerOnly() throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        let folder = try HubDataFolder.at(dir)
        #expect(mode(dir.path) == 0o700)
        folder.store.write(["a"], to: "x.json")
        #expect(mode(folder.file("x.json").path) == 0o600)
    }

    // MARK: Devices

    @Test func devicesKeepOnlyTheHash() throws {
        let (folder, dir) = try folder()
        defer { removeTemporary(dir) }
        let registry = DeviceRegistry(folder: folder)
        let (token, replaced) = try registry.pair(name: "  iPhone  ")
        #expect(!replaced && token.count == 43)
        let file = try String(contentsOf: folder.file(HubDataFolder.File.devices), encoding: .utf8)
        #expect(!file.contains(token) && file.contains(HubToken.hash(token)))
        #expect(mode(folder.file(HubDataFolder.File.devices).path) == 0o600)
        #expect(registry.lookup(token: token) == .device(registry.all[0]))
        #expect(registry.all[0].name == "iPhone")
        #expect(throws: DeviceRegistry.Failure.badName) { try registry.pair(name: " ") }
        #expect(throws: DeviceRegistry.Failure.badName) { try registry.pair(name: "a\nb") }
        #expect(throws: DeviceRegistry.Failure.notFound("Mac")) { try registry.revoke(name: "Mac") }
    }

    /// `pair` and `revoke` run in another process while `serve` keeps its registry: it sees their changes.
    @Test func anotherProcessesChangesAreSeen() throws {
        let (folder, dir) = try folder()
        defer { removeTemporary(dir) }
        let serving = DeviceRegistry(folder: folder)
        let token = try DeviceRegistry(folder: folder).pair(name: "Mac").token
        guard case .device(let device) = serving.lookup(token: token) else {
            Issue.record("a device paired elsewhere is not seen")
            return
        }
        // The server notes a request; the command then revokes without losing that.
        let seen = Date(timeIntervalSince1970: 1_800_000_000)
        serving.touch(device, now: seen)
        try DeviceRegistry(folder: folder).revoke(name: "mac", now: seen.addingTimeInterval(5))
        guard case .revoked(let revoked) = serving.lookup(token: token) else {
            Issue.record("a device revoked elsewhere still works")
            return
        }
        #expect(revoked.lastSeenAt == seen)
        #expect(serving.lookup(token: HubToken.generate()) == .unknown)
        #expect(serving.lookup(token: "short") == .unknown)
    }

    @Test func lastSeenIsWrittenAtMostOnceAMinute() throws {
        let (folder, dir) = try folder()
        defer { removeTemporary(dir) }
        let registry = DeviceRegistry(folder: folder)
        let token = try registry.pair(name: "iPhone").token
        guard case .device(let device) = registry.lookup(token: token) else { return }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        registry.touch(device, now: start)
        let stamp = FileStamp.of(folder.file(HubDataFolder.File.devices))
        registry.touch(device, now: start.addingTimeInterval(30))
        #expect(FileStamp.of(folder.file(HubDataFolder.File.devices)) == stamp)
        #expect(registry.all[0].lastSeenAt == start.addingTimeInterval(30))
        #expect(DeviceRegistry(folder: folder).all[0].lastSeenAt == start)
        registry.touch(device, now: start.addingTimeInterval(61))
        #expect(DeviceRegistry(folder: folder).all[0].lastSeenAt == start.addingTimeInterval(61))
    }

    @Test func rateLimiterWindow() {
        var limiter = RateLimiter(limit: 2, window: 60)
        let t = Date(timeIntervalSince1970: 0)
        let answers = [limiter.allow("a", now: t), limiter.allow("a", now: t.addingTimeInterval(1)),
                       limiter.allow("a", now: t.addingTimeInterval(2)), limiter.allow("b", now: t.addingTimeInterval(2)),
                       limiter.allow("a", now: t.addingTimeInterval(60.5))]
        #expect(answers == [true, true, false, true, true])
    }

    // MARK: Words

    @Test func dictionaryAndLearningSurviveARestart() throws {
        let (folder, dir) = try folder()
        defer { removeTemporary(dir) }
        let words = WordStore(store: folder.store)
        #expect(words.words == Vocabulary.defaults)
        let snapshot = try words.replace(words: ["Neo"] + words.words, expectedRevision: words.revision)
        #expect(throws: HubFailure.conflict) { try words.replace(words: [], expectedRevision: "old") }
        words.learn([CorrectionPair(wrong: "I phone", right: "iPhone")], source: .inApp, recordID: UUID())
        #expect(words.snapshot.learned == ["iPhone"] && words.revision != snapshot.revision)
        #expect(words.recognizerHints.contains("iPhone"))

        let again = WordStore(store: folder.store)
        #expect(again.words == words.words && again.revision == words.revision)
        // (learning.json keeps whole seconds, as in the Mac app)
        #expect(again.book.items.map(\.pair) == words.book.items.map(\.pair))
        #expect(again.book.items.map(\.addedTerm) == [true] && again.book.items.map(\.count) == [1])

        // The user puts the learned word back by hand after forgetting the pair: it is theirs now.
        again.forget(wrong: "i  PHONE")
        #expect(!again.words.contains("iPhone"))
        again.learn([CorrectionPair(wrong: "I phone", right: "iPhone")], source: .inApp, recordID: UUID())
        let manual = try again.replace(words: again.words.filter { $0 != "iPhone" }, expectedRevision: again.revision)
        _ = try again.replace(words: ["iPhone"] + manual.words, expectedRevision: manual.revision)
        #expect(again.book.items.first?.addedTerm == false)
        again.forget(wrong: "I phone")
        #expect(again.words.contains("iPhone"))
    }

    // MARK: History

    @Test func historyTimesAreUniqueAndExact() throws {
        let (folder, dir) = try folder()
        defer { removeTemporary(dir) }
        let history = HubHistory(store: folder.store)
        let at = Date(timeIntervalSince1970: 1_800_000_000.1234)
        var saved: [HubHistoryEntry] = []
        for i in 0..<3 {
            let result = DictationResult(clientRecordingID: UUID(), raw: "第\(i)", text: "第\(i)", mode: .raw, polished: false,
                                         recognizer: .local, createdAt: at)
            saved.append(history.add(HubHistoryEntry(result: result, client: .mac)))
        }
        #expect(Set(saved.map(\.result.createdAt)).count == 3)
        #expect(saved.map { HubJSON.string(from: $0.result.createdAt) }
                == ["2027-01-15T08:00:00.123Z", "2027-01-15T08:00:00.124Z", "2027-01-15T08:00:00.125Z"])
        let reloaded = HubHistory(store: folder.store)
        #expect(reloaded.entries == history.entries)
        #expect(reloaded.entries.map(\.result.id) == saved.reversed().map(\.result.id))
        // A recording is kept once.
        var replacement = saved[0]
        replacement.result.id = UUID()
        history.add(replacement)
        #expect(history.entries.count == 3 && history.entry(id: saved[0].result.id) == nil)
    }

    @Test func historyIsBounded() throws {
        let (folder, dir) = try folder()
        defer { removeTemporary(dir) }
        let history = HubHistory(store: folder.store, limit: 50)
        let first = history.add(HubHistoryEntry(result: DictationResult(clientRecordingID: UUID(), raw: "a", text: "a", mode: .raw,
                                                                         polished: false, recognizer: .local)))
        for _ in 0..<50 {
            history.add(HubHistoryEntry(result: DictationResult(clientRecordingID: UUID(), raw: "b", text: "b", mode: .raw,
                                                                 polished: false, recognizer: .local)))
        }
        #expect(history.entries.count == 50)
        #expect(history.entry(id: first.result.id) == nil)
        #expect(HubHistory(store: folder.store, limit: 10).entries.count == 10)
        #expect(HubHistory.maxItems == 2_000)
    }

    // MARK: Settings

    @Test func settingsReadWithMissingKeys() throws {
        // A key this hub does not know (one an older or a newer hub wrote) is skipped.
        let config = try HubJSON.decode(HubConfig.self, from: Data(#"{"fastTier": false, "retiredSetting": true, "unknown": 1}"#.utf8))
        #expect(config == HubConfig(fastTier: false))
        #expect(HubConfig(polishTimeout: 1000).polishOptions.minimumTimeout == PolishTimeout.settingRange.upperBound)
        #expect(HubConfig().polishOptions == PolishOptions(minimumTimeout: 10))
    }

    @Test func settingsChangedByAnotherProcessAreSeen() throws {
        let (folder, dir) = try folder()
        defer { removeTemporary(dir) }
        let serving = WatchedFile(store: folder.store, name: HubDataFolder.File.settings, fallback: HubConfig())
        #expect(!serving.value.requireAccess)
        let command = WatchedFile(store: folder.store, name: HubDataFolder.File.settings, fallback: HubConfig())
        var next = command.value
        next.requireAccess = true
        #expect(command.write(next))
        #expect(serving.value.requireAccess)
    }

    // MARK: Worker secret

    @Test func workerSecretIsMadeOnceAndKept() throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let secret = try WorkerSecret.loadOrCreate(in: dir)
        #expect(secret.count == 43 && HubToken.isWellFormed(secret))
        let path = WorkerSecret.url(in: dir).path
        #expect(mode(path) == 0o600)
        #expect(try WorkerSecret.loadOrCreate(in: dir) == secret)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [Hub.workerSecretFileName])

        // Made by the worker with a newline and loose permissions: read trimmed, tightened.
        try "abcdefghijklmnopqrstuvwxyz\n".write(toFile: path, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        #expect(try WorkerSecret.loadOrCreate(in: dir) == "abcdefghijklmnopqrstuvwxyz")
        #expect(mode(path) == 0o600)

        try "short".write(toFile: path, atomically: false, encoding: .utf8)
        #expect(throws: HubSetupError.self) { try WorkerSecret.loadOrCreate(in: dir) }

        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "/etc/hosts")
        #expect(throws: HubSetupError.self) { try WorkerSecret.loadOrCreate(in: dir) }
    }

    // MARK: Audio

    @Test func uploadsBecomeWorkerWAV() async throws {
        let prepared = try await AudioPrep.workerWAV(from: AudioFixture.m4a, type: .m4a)
        #expect(abs(prepared.seconds - 1) < 0.1)
        let wav = prepared.wav
        #expect(wav.prefix(4) == Data("RIFF".utf8) && wav[8..<12] == Data("WAVE".utf8))
        func u16(_ at: Int) -> Int { Int(wav[at]) | Int(wav[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        #expect(u16(20) == 1 && u16(22) == 1 && u32(24) == 16_000 && u16(34) == 16)   // PCM, mono, 16 kHz, 16-bit
        #expect(u32(40) == wav.count - 44 && u32(4) == wav.count - 8)                    // complete header

        await #expect(throws: AudioPrep.Failure.undecodable) {
            try await AudioPrep.workerWAV(from: Data("nope".utf8), type: .wav)
        }
        await #expect(throws: AudioPrep.Failure.undecodable) { try await AudioPrep.workerWAV(from: Data(), type: .m4a) }
    }

    @Test func overTenMinutesIsRefusedBeforeDecoding() async throws {
        // 10 minutes and 5 seconds of silence at 8 kHz, 8-bit… as 16-bit WAV at a low rate to keep it small.
        let rate = 8_000.0
        let samples = [Int16](repeating: 0, count: Int(rate * 605))
        let wav = AudioUpload.wav(samples, sampleRate: rate)
        await #expect(throws: AudioPrep.Failure.tooLong) { try await AudioPrep.workerWAV(from: wav, type: .wav) }
    }
}
