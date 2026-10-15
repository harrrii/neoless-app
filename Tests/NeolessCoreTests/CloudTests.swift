import Foundation
import Testing
@testable import NeolessCore

@Suite struct StructuredModeTests {
    @Test func modesAndTitles() {
        #expect(DictationMode.allCases == [.natural, .structured, .raw])
        #expect(DictationMode.structured.title == "结构化（发给 AI）")
        #expect(DictationMode.natural.title == "自然整理")
        #expect(DictationMode.raw.title == "原样转写")
        #expect(DictationMode.structured.polishes && DictationMode.natural.polishes && !DictationMode.raw.polishes)
        #expect(DictationMode(rawValue: "structured") == .structured)
    }

    @Test func recognisesAIApps() {
        for id in ["com.openai.codex", "com.openai.chat", "com.anthropic.claudefordesktop", "com.todesktop.230313mzl4w4u92",
                   "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.exafunction.windsurf", "dev.zed.Zed",
                   "dev.zed.Zed-Preview", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable"] {
            #expect(AIApps.isAIApp(bundleID: id, name: nil), "\(id)")
        }
        for name in ["Codex", "Claude", "ChatGPT", "Cursor", "Code", "Visual Studio Code", "Visual Studio Code - Insiders",
                     "Code - Insiders", "Windsurf", "Zed", "Zed Preview", "Cursor Nightly", "Terminal", "终端", "iTerm2", "iTerm",
                     "Warp", " claude "] {
            #expect(AIApps.isAIApp(bundleID: nil, name: name), "\(name)")
        }
        for name in ["Mail", "微信", "Notes", "Codeshot", "Code Runner", "Cursorcerer", "Terminally Online", "ChatGPT Atlas",
                     "Claude Notes", "Zed Attack Proxy", ""] {
            #expect(!AIApps.isAIApp(bundleID: nil, name: name), "\(name)")
        }
        #expect(!AIApps.isAIApp(bundleID: "com.tencent.xinWeChat", name: "WeChat"))
        #expect(!AIApps.isAIApp(bundleID: nil, name: nil))
    }

    @Test func openAIsBrowserIsNotAnAIApp() {
        // Its bundle ID is not a prompting app's, and its name is not a ChatGPT build's.
        #expect(!AIApps.isAIApp(bundleID: "com.openai.atlas", name: "ChatGPT Atlas"))
        // Excluded by bundle ID even if it ever shows up as plain "ChatGPT".
        #expect(!AIApps.isAIApp(bundleID: "com.openai.atlas", name: "ChatGPT"))
        #expect(DictationMode.effective(.natural, autoStructured: true, bundleID: "com.openai.atlas", appName: "ChatGPT Atlas") == .natural)
        #expect(AIApps.isAIApp(bundleID: "com.openai.chat", name: "ChatGPT"))
    }

    @Test func effectiveModeOnlyUpgradesNatural() {
        #expect(DictationMode.effective(.natural, autoStructured: true, bundleID: "com.openai.codex", appName: "Codex") == .structured)
        #expect(DictationMode.effective(.natural, autoStructured: true, bundleID: nil, appName: "Claude") == .structured)
        #expect(DictationMode.effective(.natural, autoStructured: false, bundleID: "com.openai.codex", appName: "Codex") == .natural)
        #expect(DictationMode.effective(.natural, autoStructured: true, bundleID: "com.apple.mail", appName: "Mail") == .natural)
        #expect(DictationMode.effective(.raw, autoStructured: true, bundleID: "com.openai.codex", appName: "Codex") == .raw)
        #expect(DictationMode.effective(.structured, autoStructured: false, bundleID: nil, appName: "Mail") == .structured)
    }

    @Test func structuredInstructions() {
        let s = PolishPrompt.instructions(for: .structured)
        #expect(s == PolishPrompt.structuredStaticInstructions)
        #expect(PolishPrompt.instructions(for: .natural) == PolishPrompt.naturalInstructions)
        #expect(PolishPrompt.instructions(for: .raw) == PolishPrompt.naturalInstructions)
        #expect(PolishPrompt.instructions(for: .raw, vocabulary: ["硬币"]) == PolishPrompt.instructions(for: .natural, vocabulary: ["硬币"]))
        #expect(s != PolishPrompt.naturalInstructions)
        // The rules that matter: never answer, never invent, keep details, the user's own goal first (never a
        // made-up one) then numbered items, short stays short.
        for phrase in ["不回答、不执行", "不发明需求", "完全一致", "这句可以放在最前面当引子", "不要替他写一句目标或概括",
                       "“1. 2. 3.”", "保持一两句话", "不翻译"] {
            #expect(s.contains(phrase), "\(phrase)")
        }
        #expect(PolishPrompt.naturalInstructions.contains("标题只在原话自己要一个标题时才写"))
    }

    @Test func cleanDropsPromptPreambles() {
        #expect(PolishPrompt.clean("以下是整理后的提示词：\n帮我修复登录页的 bug。") == "帮我修复登录页的 bug。")
        #expect(PolishPrompt.clean("整理后的提示词：重构 `Stores.swift`。") == "重构 `Stores.swift`。")
    }

    @Test func cleanKeepsWhatTheUserSaid() {
        // A heading the user dictated is text, not a model's label.
        #expect(PolishPrompt.clean("提示词：你是一个资深的 iOS 工程师。") == "提示词：你是一个资深的 iOS 工程师。")
        #expect(PolishPrompt.clean("以下是整理后的提示词：\n提示词：先写测试。") == "提示词：先写测试。")
        // Only one label goes; a second one is part of the text.
        #expect(PolishPrompt.clean("整理后：整理结果：周五交。") == "整理结果：周五交。")
    }
}

@Suite struct PolishTimeoutTests {
    @Test func scalesWithLengthAndCaps() {
        #expect(PolishTimeout.seconds(forCharacters: 0) == 6)
        #expect(abs(PolishTimeout.seconds(forCharacters: 100) - 8) < 0.001)
        #expect(abs(PolishTimeout.seconds(forCharacters: 800) - 22) < 0.001)
        #expect(PolishTimeout.seconds(forCharacters: 5_000) == 25)
        #expect(PolishTimeout.seconds(forCharacters: -3) == 6)
    }

    @Test func userSettingIsAFloor() {
        #expect(PolishTimeout.seconds(forCharacters: 20, minimum: 10) == 10)
        #expect(abs(PolishTimeout.seconds(forCharacters: 800, minimum: 10) - 22) < 0.001)
        #expect(PolishTimeout.seconds(forCharacters: 5_000, minimum: 30) == 30)
    }

    @Test func stallLimits() {
        #expect(PolishTimeout.stallLimit(sawText: true) == 6)
        #expect(PolishTimeout.stallLimit(sawText: false) > PolishTimeout.stallLimit(sawText: true))
    }

    @Test func connectionTimeoutNeverDecides() {
        // URLSession's idle timer must outlast both stall limits and every whole-request budget.
        #expect(PolishTimeout.requestIdle > PolishTimeout.stallLimit(sawText: false))
        #expect(PolishTimeout.requestIdle >= PolishTimeout.cap)
        #expect(PolishTimeout.requestIdle >= PolishTimeout.seconds(forCharacters: 100_000,
                                                                   minimum: PolishTimeout.settingRange.upperBound))
    }
}

@Suite struct StreamCompletionTests {
    func feed(_ lines: [String]) -> ResponsesStreamParser {
        var p = ResponsesStreamParser()
        for line in lines { p.consume(line: line) }
        return p
    }

    @Test func cutOffStreamIsNotText() {
        let p = feed([#"data: {"type":"response.output_text.delta","delta":"前半段"}"#])
        #expect(p.text == "前半段")
        #expect(!p.completed)
        #expect(p.outcome == .cutOff)
    }

    @Test func completedStreamIsText() {
        let p = feed([#"data: {"type":"response.output_text.delta","delta":"好的。"}"#,
                      #"data: {"type":"response.completed","response":{}}"#])
        #expect(p.outcome == .text("好的。"))
        #expect(p.sawText)
    }

    @Test func incompleteResponseIsAFailure() {
        let p = feed([#"data: {"type":"response.output_text.delta","delta":"一半"}"#,
                      #"data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#])
        #expect(!p.completed)
        #expect(p.outcome == .failed("整理结果不完整（max_output_tokens）"))
    }

    @Test func failureWinsOverCompletion() {
        let p = feed([#"data: {"type":"error","message":"boom"}"#, #"data: {"type":"response.completed"}"#])
        #expect(p.outcome == .failed("boom"))
    }

    @Test func doneTextKeepsOtherParts() {
        let p = feed([
            #"data: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"1. 第一"}"#,
            #"data: {"type":"response.output_text.done","output_index":0,"content_index":0,"text":"1. 第一项\n"}"#,
            #"data: {"type":"response.output_text.delta","output_index":0,"content_index":1,"delta":"2. 第二项"}"#,
            #"data: {"type":"response.output_text.done","output_index":0,"content_index":1,"text":"2. 第二项"}"#,
            #"data: {"type":"response.completed"}"#,
        ])
        #expect(p.outcome == .text("1. 第一项\n2. 第二项"))
    }

    @Test func noTextYet() {
        let p = feed([#"data: {"type":"response.created","response":{}}"#])
        #expect(!p.sawText)
    }
}

@Suite struct TokenRotationTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func adoptsTokenRotatedElsewhere() {
        #expect(TokenRotation.preferStored(storedRefreshToken: "new", storedLastRefresh: t0.addingTimeInterval(60),
                                           currentRefreshToken: "old", currentLastRefresh: t0))
        #expect(!TokenRotation.preferStored(storedRefreshToken: "same", storedLastRefresh: t0.addingTimeInterval(60),
                                            currentRefreshToken: "same", currentLastRefresh: t0))
        // An older copy on disk (we refreshed after it was written) is not used.
        #expect(!TokenRotation.preferStored(storedRefreshToken: "older", storedLastRefresh: t0.addingTimeInterval(-60),
                                            currentRefreshToken: "ours", currentLastRefresh: t0))
    }

    @Test func onlyRevokedLoginsArePermanent() {
        #expect(TokenRotation.isPermanentRefreshFailure(status: 401, body: ""))
        #expect(TokenRotation.isPermanentRefreshFailure(status: 400, body: #"{"error":"invalid_grant"}"#))
        #expect(TokenRotation.isPermanentRefreshFailure(status: 400, body: #"{"error":{"code":"refresh_token_reused","message":"x"}}"#))
        #expect(!TokenRotation.isPermanentRefreshFailure(status: 400, body: #"{"error":"invalid_request"}"#))
        #expect(!TokenRotation.isPermanentRefreshFailure(status: 400, body: "<html>bad gateway</html>"))
        #expect(!TokenRotation.isPermanentRefreshFailure(status: 500, body: #"{"error":"invalid_grant"}"#))
        #expect(!TokenRotation.isPermanentRefreshFailure(status: 0, body: ""))
    }

    @Test func rejectedRefreshTriesTheSavedLogin() {
        // Another process rotated the token and its access token is still valid: just use it.
        #expect(TokenRotation.recovery(storedRefreshToken: "theirs", storedIsFresh: true, tried: ["ours"]) == .useStored)
        // Rotated elsewhere but expired as well: refresh with the saved refresh token instead of failing.
        #expect(TokenRotation.recovery(storedRefreshToken: "theirs", storedIsFresh: false, tried: ["ours"]) == .refreshStored)
        // The saved token is one we already sent, or there is none: the login is gone.
        #expect(TokenRotation.recovery(storedRefreshToken: "ours", storedIsFresh: false, tried: ["ours"]) == .signOut)
        #expect(TokenRotation.recovery(storedRefreshToken: "ours", storedIsFresh: true, tried: ["ours"]) == .signOut)
        #expect(TokenRotation.recovery(storedRefreshToken: "theirs", storedIsFresh: false, tried: ["ours", "theirs"]) == .signOut)
        #expect(TokenRotation.recovery(storedRefreshToken: nil, storedIsFresh: false, tried: ["ours"]) == .signOut)
        #expect(TokenRotation.recovery(storedRefreshToken: "", storedIsFresh: true, tried: ["ours"]) == .signOut)
        // Bounded: after a few tries in a row the saved copy is kept for next time, not refreshed again.
        let tried = (0..<TokenRotation.maxRefreshAttempts).map { "t\($0)" }
        #expect(TokenRotation.recovery(storedRefreshToken: "next", storedIsFresh: false, tried: tried) == .keepStored)
        #expect(TokenRotation.recovery(storedRefreshToken: "next", storedIsFresh: true, tried: tried) == .useStored)
    }
}

@Suite struct StorageSafetyTests {
    func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    @Test func lossyListKeepsGoodRecords() throws {
        let json = """
        [{"id":"7D1A4E5C-1111-4C7A-9E1B-000000000001","date":"2026-10-01T10:00:00Z","duration":2,"raw":"a","finalText":"a","mode":"raw","delivery":"pasted"},
         {"id":"7D1A4E5C-1111-4C7A-9E1B-000000000002","date":"2026-10-01T10:00:00Z","duration":2,"raw":"b","finalText":"b","mode":"shouty","delivery":"pasted"},
         "not even an object",
         {"id":"7D1A4E5C-1111-4C7A-9E1B-000000000003","date":"2026-10-01T10:00:00Z","duration":2,"raw":"c","finalText":"c","mode":"structured","delivery":"copied"}]
        """
        let list = try decoder().decode(LossyList<DictationRecord>.self, from: Data(json.utf8))
        #expect(list.elements.map(\.raw) == ["a", "c"])
        #expect(list.elements.last?.mode == .structured)
        #expect(list.dropped == 2)
        // A whole-file failure still throws, so the caller backs the file up.
        #expect(throws: (any Error).self) { try decoder().decode(LossyList<DictationRecord>.self, from: Data("{}".utf8)) }
    }

    @Test func backupName() {
        let date = Date(timeIntervalSince1970: 1_791_398_700)   // 2026-10-07 18:45:00 UTC
        #expect(DataFileBackup.name(for: "history.json", date: date) == "history.json.corrupt-20261007-184500")
        let taken: Set = ["a.json.corrupt-20261007-184500", "a.json.corrupt-20261007-184500-2"]
        #expect(DataFileBackup.name(for: "a.json", date: date) { taken.contains($0) } == "a.json.corrupt-20261007-184500-3")
        #expect(DataFileBackup.isBackup("a.json.corrupt-20261007-184500-3", of: "a.json"))
        #expect(!DataFileBackup.isBackup("a.json", of: "a.json"))
        #expect(!DataFileBackup.isBackup("ba.json.corrupt-20261007-184500", of: "a.json"))
    }

    /// A record as builds from before 结构化 decode it: the whole history fails on one unknown mode.
    struct OlderBuildRecord: Decodable {
        enum Mode: String, Decodable { case natural, raw }
        var id: UUID
        var raw: String
        var mode: Mode
    }

    func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    func record(_ mode: DictationMode) -> DictationRecord {
        DictationRecord(date: Date(timeIntervalSince1970: 1_791_398_700), duration: 2, raw: "r", polished: "p", finalText: "p",
                        appName: "Codex", mode: mode, model: "m", polishSeconds: 1.5, note: nil, delivery: .pasted)
    }

    @Test func structuredHistoryStaysReadableByOlderBuilds() throws {
        let records = [record(.natural), record(.structured), record(.raw)]
        let data = try encoder().encode(records)
        // An older build reads every record; 结构化 shows there as 自然整理.
        let older = try decoder().decode([OlderBuildRecord].self, from: data)
        #expect(older.map(\.mode) == [.natural, .natural, .raw])
        // This build gets every mode back, and every other field.
        #expect(try decoder().decode([DictationRecord].self, from: data) == records)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains(#""mode":"structured""#))
        #expect(json.components(separatedBy: #""exactMode":"structured""#).count == 2)
    }

    @Test func recordFieldsAreUnchangedForOtherModes() throws {
        let object = try #require(JSONSerialization.jsonObject(with: encoder().encode(record(.natural))) as? [String: Any])
        #expect(Set(object.keys) == ["id", "date", "duration", "raw", "polished", "finalText", "appName",
                                     "mode", "model", "polishSeconds", "delivery"])
        #expect(object["mode"] as? String == "natural")
    }

    @Test func hubFieldsRoundTripAndAreLeftOutWhenEmpty() throws {
        var fromNeo = record(.natural)
        fromNeo.hubID = UUID(uuidString: "7D1A4E5C-1111-4C7A-9E1B-000000000002")
        fromNeo.recognizer = "qwen3-asr"
        let local = record(.raw)
        let data = try encoder().encode([fromNeo, local])
        #expect(try decoder().decode([DictationRecord].self, from: data) == [fromNeo, local])
        // Older builds read it all the same.
        #expect(try decoder().decode([OlderBuildRecord].self, from: data).count == 2)
        let object = try #require(JSONSerialization.jsonObject(with: encoder().encode(fromNeo)) as? [String: Any])
        #expect(object["hubID"] as? String == "7D1A4E5C-1111-4C7A-9E1B-000000000002")
        #expect(object["recognizer"] as? String == "qwen3-asr")
        #expect(fromNeo.recognizedOnHub)
        // The Neo used this Mac's transcript: not its recognition.
        fromNeo.recognizer = "local"
        #expect(!fromNeo.recognizedOnHub)
        #expect(!record(.natural).recognizedOnHub)
    }

    @Test func aDamagedHubIDDoesNotLoseTheRecord() throws {
        let json = """
        {"id":"7D1A4E5C-1111-4C7A-9E1B-000000000001","date":"2026-10-01T10:00:00Z","duration":2,"raw":"a","finalText":"a",
         "mode":"natural","delivery":"pasted","hubID":"not-a-uuid","recognizer":7}
        """
        let r = try decoder().decode(DictationRecord.self, from: Data(json.utf8))
        #expect(r.hubID == nil && r.recognizer == nil)
        #expect(r.raw == "a")
    }

    @Test func unknownExactModeFallsBack() throws {
        let json = """
        {"id":"7D1A4E5C-1111-4C7A-9E1B-000000000001","date":"2026-10-01T10:00:00Z","duration":2,"raw":"a","finalText":"a",
         "mode":"natural","exactMode":"from-a-newer-build","delivery":"pasted"}
        """
        let r = try decoder().decode(DictationRecord.self, from: Data(json.utf8))
        #expect(r.mode == .natural)
        #expect(r.polished == nil && r.model == nil && r.note == nil)
    }
}

/// `DataFileStore` against a real temporary folder.
@Suite struct DataFileStoreTests {
    struct Login: Codable, Equatable {
        var accessToken: String
        var refreshToken: String
        var lastRefresh: Date
    }

    static let stamp = Date(timeIntervalSince1970: 1_791_398_700)   // 2026-10-07 18:45:00 UTC

    /// A fresh folder, removed (permissions restored first) when `body` returns.
    func withFolder(_ body: (URL) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neoless-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try body(dir)
    }

    func files(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    @Test func roundTripAndMissingFile() throws {
        try withFolder { dir in
            let store = DataFileStore(directory: dir, now: { Self.stamp })
            #expect(store.read(Login.self, from: "auth.json") == nil)
            #expect(files(dir).isEmpty)
            let login = Login(accessToken: "a", refreshToken: "r", lastRefresh: Self.stamp)
            #expect(store.write(login, to: "auth.json"))
            #expect(store.read(Login.self, from: "auth.json") == login)
            let mode = try FileManager.default.attributesOfItem(atPath: store.url("auth.json").path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
            #expect(store.recovered.isEmpty)
        }
    }

    @Test func undecodableLoginIsMovedAsideIntact() throws {
        try withFolder { dir in
            let store = DataFileStore(directory: dir, now: { Self.stamp })
            let original = Data(#"{"access":"from a newer build"}"#.utf8)
            try original.write(to: store.url("auth.json"))
            #expect(store.read(Login.self, from: "auth.json") == nil)
            let backup = "auth.json.corrupt-20261007-184500"
            #expect(files(dir) == [backup])
            #expect(try Data(contentsOf: store.url(backup)) == original)
            #expect(store.recovered == [backup])
            // Signing in again writes a new file; the backup stays.
            #expect(store.write(Login(accessToken: "a", refreshToken: "r", lastRefresh: Self.stamp), to: "auth.json"))
            #expect(try Data(contentsOf: store.url(backup)) == original)
            // A second bad file in the same second gets its own backup.
            try Data("garbage".utf8).write(to: store.url("auth.json"))
            #expect(store.read(Login.self, from: "auth.json") == nil)
            #expect(files(dir) == [backup, backup + "-2"])
            #expect(try Data(contentsOf: store.url(backup)) == original)
        }
    }

    @Test func unbackedUpFileIsNeverOverwrittenOrDeleted() throws {
        // Folder permissions do not stop root, so the setup below would not fail there.
        guard geteuid() != 0 else { return }
        try withFolder { dir in
            let store = DataFileStore(directory: dir, now: { Self.stamp })
            let original = Data("not json".utf8)
            try original.write(to: store.url("auth.json"))
            // A folder nothing can be added to or removed from: no backup is possible.
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            #expect(store.read(Login.self, from: "auth.json") == nil)
            #expect(files(dir) == ["auth.json"])
            #expect(!store.write(Login(accessToken: "a", refreshToken: "r", lastRefresh: Self.stamp), to: "auth.json"))
            #expect(!store.remove("auth.json"))
            #expect(try Data(contentsOf: store.url("auth.json")) == original)
            #expect(store.recovered.isEmpty)
            // Once a backup can be made, the next save makes it first.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let login = Login(accessToken: "a", refreshToken: "r", lastRefresh: Self.stamp)
            #expect(store.write(login, to: "auth.json"))
            #expect(store.read(Login.self, from: "auth.json") == login)
            #expect(try Data(contentsOf: store.url("auth.json.corrupt-20261007-184500")) == original)
            #expect(store.remove("auth.json"))
            #expect(files(dir) == ["auth.json.corrupt-20261007-184500"])
        }
    }

    @Test func lossyListKeepsTheOriginalBeforeTheNextSave() throws {
        try withFolder { dir in
            let store = DataFileStore(directory: dir, now: { Self.stamp })
            let original = Data(#"[{"accessToken":"a","refreshToken":"r","lastRefresh":"2026-10-07T18:45:00Z"},{"bad":1}]"#.utf8)
            try original.write(to: store.url("list.json"))
            let list = store.readList(Login.self, from: "list.json")
            #expect(list?.map(\.accessToken) == ["a"])
            #expect(files(dir) == ["list.json", "list.json.corrupt-20261007-184500"])
            #expect(store.write(list ?? [], to: "list.json"))
            #expect(try Data(contentsOf: store.url("list.json.corrupt-20261007-184500")) == original)
            // Not an array at all: moved aside, nothing returned.
            try Data("{}".utf8).write(to: store.url("list.json"))
            #expect(store.readList(Login.self, from: "list.json") == nil)
            #expect(!FileManager.default.fileExists(atPath: store.url("list.json").path))
            #expect(store.recovered.count == 2)
        }
    }

    @Test func purgeLeavesNoCopyOfTheLogin() throws {
        try withFolder { dir in
            let store = DataFileStore(directory: dir, now: { Self.stamp })
            // Two logins this build could not read were set aside, tokens and all; then the user signed in again.
            try Data(#"{"access":"still valid"}"#.utf8).write(to: store.url("auth.json"))
            #expect(store.read(Login.self, from: "auth.json") == nil)
            try Data("garbage".utf8).write(to: store.url("auth.json"))
            #expect(store.read(Login.self, from: "auth.json") == nil)
            #expect(store.write(Login(accessToken: "a", refreshToken: "r", lastRefresh: Self.stamp), to: "auth.json"))
            #expect(store.write(["x"], to: "history.json"))
            try Data("old".utf8).write(to: store.url("history.json.corrupt-20261001-000000"))
            #expect(files(dir) == ["auth.json", "auth.json.corrupt-20261007-184500", "auth.json.corrupt-20261007-184500-2",
                                   "history.json", "history.json.corrupt-20261001-000000"])
            // Signing out deletes the login and its backups; other files and their backups stay.
            #expect(store.purge("auth.json"))
            #expect(files(dir) == ["history.json", "history.json.corrupt-20261001-000000"])
            #expect(store.recovered.isEmpty)
            // Nothing left to delete is not a failure.
            #expect(store.purge("auth.json"))
        }
    }
}

@Suite struct VocabularyPriorityTests {
    @Test func manualWordsComeFirst() {
        let learned = (0..<150).map { "L\($0)" }
        let manual = ["WordPress", "Martin"]
        // The store keeps learned terms first in the old order; the hints must not.
        let hints = Vocabulary.recognizerHints(learned + manual, learned: learned)
        #expect(Array(hints.prefix(2)) == manual)
        #expect(hints.count == manual.count + Vocabulary.learnedHintLimit)
    }

    @Test func learnedOnlyFillWhatIsLeft() {
        let manual = (0..<95).map { "M\($0)" }
        let learned = (0..<20).map { "L\($0)" }
        let hints = Vocabulary.recognizerHints(manual + learned, learned: learned)
        #expect(hints.count == 100)
        #expect(Array(hints.prefix(95)) == manual)
        #expect(Array(hints.suffix(5)) == ["L0", "L1", "L2", "L3", "L4"])
        let full = Vocabulary.recognizerHints((0..<120).map { "M\($0)" } + learned, learned: learned)
        #expect(full.count == 100 && !full.contains("L0"))
    }

    @Test func learnedRankingDecidesWhichLearnedTermsGo() {
        let hints = Vocabulary.recognizerHints(["a", "rare", "often"], learned: ["often", "rare", "missing"])
        #expect(hints == ["a", "often", "rare"])
        // Case-insensitive, spelling from the dictionary.
        #expect(Vocabulary.recognizerHints(["OpenAI", "Max"], learned: ["max"]) == ["OpenAI", "Max"])
    }

    @Test func withoutLearnedBehavesAsBefore() {
        let words = (0..<300).map { "w\($0)" }
        #expect(Vocabulary.recognizerHints(words) == Array(words.prefix(100)))
        #expect(Vocabulary.promptWords(["a", "b"]) == Vocabulary.PromptWords(own: ["a", "b"]))
    }

    @Test func promptWordsCapLearnedShare() {
        let learned = (0..<300).map { "learned-term-\($0)" }   // 16–18 characters each
        let words = Vocabulary.promptWords(["Martin"] + learned, learned: learned)
        #expect(words.own == ["Martin"])
        #expect(words.all.first == "Martin")
        let learnedChars = words.learned.reduce(0) { $0 + $1.count + 1 }
        #expect(learnedChars <= Vocabulary.learnedPromptBudget)
        #expect(learnedChars > Vocabulary.learnedPromptBudget - 20)
        // Manual words still get the whole budget.
        let manual = (0..<300).map { "manual-word-\($0)" }
        let manualOut = Vocabulary.promptWords(["Late"] + manual, learned: ["Late"])
        #expect(manualOut.all.reduce(0) { $0 + $1.count + 1 } <= Vocabulary.promptCharacterBudget)
        #expect(manualOut.own.first == "manual-word-0")
        #expect(manualOut.learned == ["Late"])   // only the room manual words left over
    }

    @Test func promptWordsAreStableWhenCutAgain() {
        // Polisher cuts the list it is given to the budget once more; the store's list must survive that.
        let words = ["Martin"] + (0..<300).map { "manual-\($0)" } + (0..<100).map { "learned-\($0)" }
        let once = Vocabulary.promptWords(words, learned: (0..<100).map { "learned-\($0)" })
        #expect(Vocabulary.promptWords(once.all, learned: once.learned) == once)
    }

    /// The prompt lists the user's own words and the learned-only terms apart (it weighs them differently),
    /// so the split must survive: the defaults and typed words are the user's, learned ones are not.
    @Test func promptWordsKeepLearnedTermsApart() {
        let words = ["ZIP", "硬币"] + Vocabulary.defaults
        let split = Vocabulary.promptWords(words, learned: ["zip", "gone"])
        #expect(split.own == ["硬币"] + Vocabulary.defaults.filter { $0 != "硬币" })
        #expect(split.learned == ["ZIP"])
        #expect(split.all == split.own + split.learned)
        // Without a learned ranking, everything is the user's own.
        #expect(Vocabulary.promptWords(words).learned.isEmpty)
        #expect(Vocabulary.promptWords([], learned: ["ZIP"]) == Vocabulary.PromptWords())
    }

    @Test func learningNeverReordersTheList() {
        let words = ["WordPress", "OpenAI", "Martin"]
        // New terms go to the front; a word already listed keeps its place, whatever its case.
        #expect(Vocabulary.addingLearned(["硬币", "openai", " Figma "], to: words, learned: [])
                == ["硬币", "Figma", "WordPress", "OpenAI", "Martin"])
        #expect(Vocabulary.addingLearned(["Martin"], to: words, learned: []) == words)
        #expect(Vocabulary.addingLearned([], to: words, learned: []) == words)
    }

    @Test func typedWordsMoveUpAndStayTheUsers() {
        #expect(Vocabulary.adding(["Codex", "martin"], to: ["WordPress", "Martin"], learned: [])
                == ["Codex", "martin", "WordPress"])
        // A typed word that learning also taught counts as the user's own: it is not dropped as learned.
        let full = (0..<(Vocabulary.maxWords - 1)).map { "w\($0)" } + ["L1"]
        let out = Vocabulary.adding(["New", "l1"], to: full, learned: ["L1", "w5"])
        #expect(out.count == Vocabulary.maxWords)
        #expect(Array(out.prefix(2)) == ["New", "l1"])
        #expect(!out.contains("w5"))
        #expect(out.last == "w1998")
    }

    @Test func fullDictionaryDropsLearnedTermsFirst() {
        let manual = (0..<(Vocabulary.maxWords - 2)).map { "m\($0)" }
        let words = ["L-new"] + manual + ["L-old"]
        // Learning one more term drops the oldest learned term, not the user's oldest word.
        let learnedOut = Vocabulary.addingLearned(["L-next"], to: words, learned: ["L-new", "L-old"])
        #expect(learnedOut.count == Vocabulary.maxWords)
        #expect(Array(learnedOut.prefix(2)) == ["L-next", "L-new"])
        #expect(!learnedOut.contains("L-old"))
        #expect(learnedOut.last == manual.last)
        // Only the user's words left: a learned term is not added at their expense.
        let allManual = (0..<Vocabulary.maxWords).map { "m\($0)" }
        #expect(Vocabulary.addingLearned(["L-next"], to: allManual, learned: []) == allManual)
        // A word typed by hand into a full dictionary pushes out a learned term before the user's words.
        let typedOut = Vocabulary.adding(["Typed"], to: words, learned: ["L-new", "L-old"])
        #expect(typedOut.count == Vocabulary.maxWords)
        #expect(typedOut.first == "Typed" && !typedOut.contains("L-old") && typedOut.last == manual.last)
    }
}

@Suite struct LearnedTermOwnershipTests {
    @Test func undoKeepsAWordTypedByHandSince() {
        var book = LearningBook()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func learn(_ offset: TimeInterval) -> LearningEvent {
            book.record([p("Open Air", "OpenAI")], source: .otherApp, recordID: UUID(),
                        now: now.addingTimeInterval(offset), termExists: { _ in false })
        }
        _ = learn(0)
        let second = learn(60)
        #expect(book.items[0].addedTerm)
        // The user then types "OpenAI" into the dictionary by hand.
        book.markManualTerm("OpenAI")
        // Undoing the second fix restores the item's older copy, which still says learning added the word.
        var plain = book
        plain.undo(second)
        #expect(plain.items[0].addedTerm)
        book.undo(second, manualTerms: ["openai", "martin"])
        #expect(book.items[0].count == 1)
        #expect(!book.items[0].addedTerm)
    }

    @Test func undoLeavesLearnedTermsLearned() {
        var book = LearningBook()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        _ = book.record([p("金币", "硬币")], source: .otherApp, recordID: UUID(), now: now, termExists: { _ in false })
        let again = book.record([p("金币", "硬币")], source: .otherApp, recordID: UUID(), now: now.addingTimeInterval(60),
                                termExists: { _ in false })
        book.undo(again, manualTerms: ["martin"])
        #expect(book.items[0].addedTerm)
    }
}

@Suite struct ApplyConfirmedTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    func item(_ wrong: String, _ right: String, count: Int = 2, ago: TimeInterval = 0) -> LearnedCorrection {
        LearnedCorrection(pair: CorrectionPair(wrong: wrong, right: right), count: count,
                          firstSeen: Self.now.addingTimeInterval(-ago - 1), lastSeen: Self.now.addingTimeInterval(-ago),
                          source: .otherApp, addedTerm: true)
    }

    @Test func replacesConfirmedPairsOnly() {
        let book = LearningBook(items: [item("Open Air", "OpenAI"), item("引必", "音币", count: 1)])
        #expect(LearningPrompt.applyConfirmed("帮我看看 open air 的账单和引必", book: book) == "帮我看看 OpenAI 的账单和引必")
        #expect(LearningPrompt.applyConfirmed("OpenAir 和 Open  Air", book: book) == "OpenAI 和 OpenAI")
        #expect(LearningPrompt.applyConfirmed("没有相关内容", book: book) == "没有相关内容")
        #expect(LearningPrompt.applyConfirmed("看看引必", book: LearningBook()) == "看看引必")
    }

    @Test func respectsTokenBoundaries() {
        let book = LearningBook(items: [item("Mac Book", "MacBook"), item("Git hub", "GitHub"), item("iphone", "iPhone")])
        #expect(LearningPrompt.applyConfirmed("Mac Bookshelf 很大", book: book) == "Mac Bookshelf 很大")
        #expect(LearningPrompt.applyConfirmed("我的 iMac Book 满了", book: book) == "我的 iMac Book 满了")
        #expect(LearningPrompt.applyConfirmed("iphones 来了", book: book) == "iphones 来了")
        #expect(LearningPrompt.applyConfirmed("用Mac Book的时候", book: book) == "用MacBook的时候")
        #expect(LearningPrompt.applyConfirmed("Git hub, 你好，IPHONE 好用", book: book) == "GitHub, 你好，iPhone 好用")
        #expect(LearningPrompt.applyConfirmed("iphone", book: book) == "iPhone")
    }

    @Test func oneOrdinaryLatinWordIsNeverReplacedWithoutTheModel() {
        // Each fixed often, and each would rewrite everyday text: "upload to the cloud", "on my Mac", "Jon Snow".
        let book = LearningBook(items: [item("Mac", "Max", count: 5), item("Cloud", "Claude", count: 5), item("Jon", "John", count: 5),
                                        item("labels", "Lavoben", count: 5), item("claude", "Claude", count: 5)])
        let text = "upload to the cloud from my Mac, Jon and claude put the labels in"
        #expect(LearningPrompt.applyConfirmed(text, book: book) == text)
        // The model still gets them as hints, with the sentence to judge by.
        #expect(Set(LearningPrompt.pairs(for: text, from: book).map(\.wrong)) == ["Mac", "Cloud", "Jon", "labels", "claude"])
    }

    @Test func doesNotDoubleApplyOrChain() {
        // (Pairs that are written without the model: characters that make no word, heard for a name or for a
        // word that sounds the same.)
        let book = LearningBook(items: [item("欧盆爱", "欧盆爱I"), item("引必", "音币"), item("音币", "茵碧", count: 3)])
        // A match inside the corrected word is left alone: 欧盆爱I does not become 欧盆爱II.
        #expect(LearningPrompt.applyConfirmed("欧盆爱I 和欧盆爱来了", book: book) == "欧盆爱I 和欧盆爱I来了")
        // Replaced text is not matched again: 引必 → 音币 does not go on to 茵碧.
        #expect(LearningPrompt.applyConfirmed("引必 音币", book: book) == "音币 茵碧")
        // Already correct stays put.
        let openai = LearningBook(items: [item("openai", "OpenAI")])
        #expect(LearningPrompt.applyConfirmed("OpenAI 和 openai", book: openai) == "OpenAI 和 OpenAI")
    }

    @Test func latestRightWinsAndFrequentPairWinsOverlaps() {
        let book = LearningBook(items: [item("引必", "茵碧", ago: 100), item("引必", "音币", ago: 0),
                                        item("open air", "OpenAI", count: 5), item("air pod", "AirPod", count: 2)])
        #expect(LearningPrompt.applyConfirmed("两百引必", book: book) == "两百音币")
        #expect(LearningPrompt.applyConfirmed("open air pod 的 air pod", book: book) == "OpenAI pod 的 AirPod")
    }
}
