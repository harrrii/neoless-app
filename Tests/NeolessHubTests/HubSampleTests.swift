import Foundation
import NeolessCloud
import NeolessCore
import Testing
@testable import NeolessHubKit

/// The commands that work on files the user brings: `import-samples` (a word list and fixes), `eval` (transcripts)
/// and `transcribe` (recordings). ChatGPT and the ASR worker are stubbed; every data folder is a temporary one, and
/// every word, pair and sentence here is made up.
@MainActor
@Suite struct HubSampleTests {
    private func folder() throws -> (HubDataFolder, URL) {
        let dir = temporaryDirectory()
        return (try HubDataFolder.at(dir), dir)
    }

    private func parse(_ line: String) throws -> HubCommandLine {
        try HubCommandLine.parse(line.split(separator: " ").map(String.init))
    }

    private func pair(_ wrong: String, _ right: String) -> CorrectionPair { CorrectionPair(wrong: wrong, right: right) }

    // MARK: Command line

    @Test func commands() throws {
        #expect(try parse("import-samples --vocabulary v.json --corrections c.json").command
                == .importSamples(.init(vocabulary: "v.json", corrections: "c.json")))
        #expect(try parse("import-samples --corrections c.json --vocabulary v.json --dry-run --force-offline --port 18860").command
                == .importSamples(.init(vocabulary: "v.json", corrections: "c.json", dryRun: true, forceOffline: true, port: 18_860)))
        #expect(try parse("eval --samples s.json").command == .eval(.run(.init(samples: "s.json"))))
        #expect(try parse("eval --samples s.json --natural-file n.txt --structured-file t.txt --out r.json --limit 3 --only s-001,s-003")
                    .command == .eval(.run(.init(samples: "s.json", naturalFile: "n.txt", structuredFile: "t.txt", out: "r.json",
                                                 limit: 3, only: ["s-001", "s-003"]))))
        #expect(try parse("eval --print-instructions natural").command == .eval(.printInstructions(.natural)))
        #expect(try parse("eval --print-instructions structured").command == .eval(.printInstructions(.structured)))
        #expect(try parse("transcribe a.wav b.m4a").command == .transcribe(files: ["a.wav", "b.m4a"], json: false))
        #expect(try parse("transcribe --json a.wav").command == .transcribe(files: ["a.wav"], json: true))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(try parse("eval --samples ~/s.json").command == .eval(.run(.init(samples: home + "/s.json"))))
    }

    @Test func mistakes() {
        for line in ["import-samples", "import-samples --vocabulary v.json", "import-samples --corrections c.json",
                     "import-samples --vocabulary v.json --corrections c.json --json", "eval", "eval --limit 2",
                     "eval --samples s.json --limit 0", "eval --samples s.json --limit x", "eval --samples s.json --only ,",
                     "eval --samples s.json --dry-run", "eval --print-instructions raw", "eval --print-instructions",
                     "eval --print-instructions natural --samples s.json", "transcribe", "transcribe --dry-run a.wav",
                     "serve --dry-run", "status --force-offline", "login --json", "eval --samples s.json extra",
                     "import-samples --vocabulary v.json --corrections c.json --out r.json"] {
            #expect(throws: HubCommandLine.Failure.self, "\(line)") { try parse(line) }
        }
    }

    // MARK: Sample files

    static let terms = [
        SampleImport.Term(term: "API Key", tier: 2, rank: 41), SampleImport.Term(term: "嗯那个", tier: 5, rank: 90),
        SampleImport.Term(term: "GitHub", tier: 1, rank: 1), SampleImport.Term(term: "Githup", tier: 1, rank: 36),
        SampleImport.Term(term: "权限", tier: 1, rank: 3), SampleImport.Term(term: "Token", tier: 4, rank: 70),
        SampleImport.Term(term: " 回滚 ", tier: 3, rank: 50), SampleImport.Term(term: "github", tier: 2, rank: 60),
    ]

    static let corrections = [
        SampleImport.Correction(wrong: "全线 / 全县", right: "权限", count: 2,
                                records: ["2026-01-02T03:04:05.678901+00:00", "2026-01-02T02:00:00.123456+00:00"], confidence: "high"),
        SampleImport.Correction(wrong: "Get Hub / Git Hop / Gitub / Githup", right: "GitHub", count: 3, records: [], confidence: "high"),
        SampleImport.Correction(wrong: "PR", right: "PRD", count: 2, confidence: "medium"),
        SampleImport.Correction(wrong: "实验", right: "时延", count: 1, confidence: "low"),
        SampleImport.Correction(wrong: "布署", right: "部署", confidence: "high"),
    ]

    @Test func planFollowsTheFilesOrderAndLeavesOutJunk() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let plan = SampleImport.plan(terms: Self.terms, corrections: Self.corrections, now: now)
        // Tier, then rank; a later spelling of the same word is the same word.
        #expect(plan.words == ["GitHub", "权限", "API Key", "回滚", "Token"])
        #expect(plan.junk == ["嗯那个"])
        // Githup is taught as a wrong form of GitHub, so it is no hotword.
        #expect(plan.misspelt == ["Githup"])
        #expect(plan.unsure == 2)
        #expect(plan.corrections.map(\.pair) == [pair("全线", "权限"), pair("全县", "权限"), pair("Get Hub", "GitHub"),
                                                 pair("Git Hop", "GitHub"), pair("Gitub", "GitHub"), pair("Githup", "GitHub"),
                                                 pair("布署", "部署")])
        let first = try #require(plan.corrections.first)
        #expect(first.count == 2)
        // Microseconds and an offset, as Python writes them.
        let early = try #require(HubJSON.date(from: "2026-01-02T02:00:00.123Z"))
        let late = try #require(HubJSON.date(from: "2026-01-02T03:04:05.678Z"))
        #expect(abs(first.firstSeen.timeIntervalSince(early)) < 0.002 && abs(first.lastSeen.timeIntervalSince(late)) < 0.002)
        // No dates that read: now.
        #expect(plan.corrections.last?.firstSeen == now && plan.corrections.last?.count == 1)
    }

    @Test func planReadsTheFiles() throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let vocabulary = dir.appendingPathComponent("vocabulary.json"), corrections = dir.appendingPathComponent("corrections.json")
        // Fields this import does not know are ignored.
        try Data((#"{"ordering": "x", "terms": [{"term": "权限", "tier": 1, "rank": 3, "aliases": ["全线"], "note": ""},"#
                  + #" {"term": "嗯那个", "tier": 5, "rank": 90}]}"#).utf8).write(to: vocabulary)
        try Data((#"{"source": "x", "corrections": [{"wrong": "全线", "right": "权限", "count": 2, "confidence": "high", "why": ""}],"#
                  + #" "other": []}"#).utf8).write(to: corrections)
        let plan = try SampleImport.plan(vocabulary: vocabulary, corrections: corrections)
        #expect(plan.words == ["权限"] && plan.corrections.map(\.pair) == [pair("全线", "权限")])
        #expect(throws: HubSetupError.self) {
            try SampleImport.plan(vocabulary: dir.appendingPathComponent("missing.json"), corrections: corrections)
        }
        #expect(throws: HubSetupError.self) { try SampleImport.plan(vocabulary: corrections, corrections: corrections) }
    }

    /// examples/ documents the three file formats: the files there must read as the commands read them.
    @Test func theExampleFilesRead() throws {
        let examples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("examples")
        let plan = try SampleImport.plan(vocabulary: examples.appendingPathComponent("vocabulary.example.json"),
                                         corrections: examples.appendingPathComponent("corrections.example.json"))
        #expect(plan.words == ["GitHub", "权限", "API Key", "回滚"])
        #expect(plan.junk == ["嗯那个"] && plan.misspelt == ["Githup"] && plan.unsure == 1)
        #expect(plan.corrections.map(\.pair) == [pair("全线", "权限"), pair("全县", "权限"), pair("Get Hub", "GitHub"),
                                                 pair("Githup", "GitHub"), pair("布署", "部署")])
        let samples = try HubEval.load(samples: examples.appendingPathComponent("polish-eval.example.json"))
        #expect(samples.map(\.id) == ["s-001", "s-002", "s-003"] && samples[2].app == nil)
        #expect(samples.compactMap { HubEval.mode(forHint: $0.modeHint) } == [.structured, .natural, .raw])
    }

    // MARK: Importing into the word store

    @Test func importKeepsTheUsersWordsAndAddsInOrder() throws {
        let (folder, dir) = try folder()
        defer { removeTemporary(dir) }
        let words = WordStore(store: folder.store)
        _ = try words.replace(words: ["Martin", "权限", "App Store"], expectedRevision: words.revision)
        // ZIP is in the dictionary only because it was learned.
        words.learn([pair("VIP", "ZIP")], source: .inApp, recordID: UUID())
        #expect(words.words == ["ZIP", "Martin", "权限", "App Store"])

        let plan = SampleImport.plan(terms: Self.terms + [SampleImport.Term(term: "zip", tier: 4, rank: 80)],
                                     corrections: Self.corrections)
        let result = words.importSamples(words: plan.words, corrections: plan.corrections, dryRun: false)
        #expect(result.added == ["GitHub", "API Key", "回滚", "Token"])
        #expect(result.present == ["权限"] && result.adopted == ["zip"])
        // The user's words keep their places; the file's follow in their order; terms only the corrections teach
        // are learned ones (at the front, as learning puts them).
        #expect(words.words == ["部署", "ZIP", "Martin", "权限", "App Store", "GitHub", "API Key", "回滚", "Token"])
        #expect(result.learnedTerms == ["部署"])
        #expect(words.book.items.first { $0.pair.right == "ZIP" }?.addedTerm == false)
        #expect(Set(words.book.items.filter { $0.source == .imported }.map(\.pair)) == Set(plan.corrections.map(\.pair)))
        #expect(words.book.items.filter { $0.source == .imported }.allSatisfy { $0.count >= LearningPrompt.confirmedCount })
        // 权限 and GitHub were the user's words before the corrections: forgetting those pairs leaves them.
        #expect(words.book.items.first { $0.pair == pair("全线", "权限") }?.addedTerm == false)
        #expect(words.book.items.first { $0.pair == pair("布署", "部署") }?.addedTerm == true)
        #expect(result.ownWords == 8 && result.addedInHints == 4 && result.addedInPrompt == 4)

        // Saved, and what a dictation gets from now on.
        let reloaded = WordStore(store: folder.store)
        #expect(reloaded.words == words.words && reloaded.book.items.map(\.pair) == words.book.items.map(\.pair))
        #expect(reloaded.book.items.map(\.source) == words.book.items.map(\.source))
        #expect(reloaded.recognizerHints.prefix(8) == ["ZIP", "Martin", "权限", "App Store", "GitHub", "API Key", "回滚", "Token"])
        #expect(reloaded.promptPairs(for: "这个账号全线不够") == [pair("全线", "权限")])
        #expect(reloaded.applyConfirmed("布署到线上") == "部署到线上")
        // Imported pairs can be deleted like any other, with the word only they added.
        reloaded.forget(wrong: "布署")
        #expect(!reloaded.words.contains("部署"))
        reloaded.forget(wrong: "全线")
        #expect(reloaded.words.contains("权限"))

        // A second import adds nothing.
        let again = reloaded.importSamples(words: plan.words, corrections: plan.corrections, dryRun: false)
        #expect(again.added.isEmpty && again.corrections.present.count == plan.corrections.count - 2)
        #expect(again.corrections.added.map(\.wrong).sorted() == ["全线", "布署"])
    }

    @Test func dryRunChangesNothing() throws {
        let (folder, dir) = try folder()
        defer { removeTemporary(dir) }
        let words = WordStore(store: folder.store)
        let before = try Data(contentsOf: folder.file(HubDataFolder.File.vocabulary))
        let plan = SampleImport.plan(terms: Self.terms, corrections: Self.corrections)
        let result = words.importSamples(words: plan.words, corrections: plan.corrections, dryRun: true)
        #expect(!result.added.isEmpty && result.corrections.added.count == plan.corrections.count)
        #expect(words.words == Vocabulary.defaults && words.book.items.isEmpty)
        #expect(try Data(contentsOf: folder.file(HubDataFolder.File.vocabulary)) == before)
        #expect(!FileManager.default.fileExists(atPath: folder.file(HubDataFolder.File.learning).path))
    }

    @Test func importKeepsTheDictionaryCap() throws {
        let (folder, dir) = try folder()
        defer { removeTemporary(dir) }
        let words = WordStore(store: folder.store)
        let full = (0..<(Vocabulary.maxWords - 1)).map { "词\($0)" }
        _ = try words.replace(words: full, expectedRevision: words.revision)
        let result = words.importSamples(words: ["权限", "回滚", "GitHub"], corrections: [], dryRun: false)
        #expect(result.added == ["权限"] && result.full == ["回滚", "GitHub"])
        #expect(words.words.count == Vocabulary.maxWords && words.words.prefix(full.count) == full[...])
        #expect(result.hintCount == Vocabulary.recognizerHintLimit && result.addedInHints == 0)
    }

    // MARK: The command

    @Test func importCommandWaitsForTheHubToStop() async throws {
        let (folder, dir) = try folder()
        defer { removeTemporary(dir) }
        // The two files, apart from the hub's data folder (which has a vocabulary.json of its own).
        let brought = temporaryDirectory()
        defer { removeTemporary(brought) }
        let vocabulary = brought.appendingPathComponent("vocabulary.json").path
        let corrections = brought.appendingPathComponent("corrections.json").path
        try Data((#"{"terms": [{"term": "权限", "tier": 1, "rank": 1}, {"term": "GitHub", "tier": 1, "rank": 2},"#
                  + #" {"term": "Githup", "tier": 1, "rank": 3}, {"term": "嗯那个", "tier": 5, "rank": 9}]}"#).utf8)
            .write(to: URL(fileURLWithPath: vocabulary))
        try Data((#"{"corrections": [{"wrong": "全线 / 全县", "right": "权限", "count": 2, "confidence": "high"},"#
                  + #" {"wrong": "Githup", "right": "GitHub", "confidence": "high"},"#
                  + #" {"wrong": "PR", "right": "PRD", "confidence": "medium"},"#
                  + #" {"wrong": "实验", "right": "时延", "confidence": "low"}]}"#).utf8)
            .write(to: URL(fileURLWithPath: corrections))
        let files = HubCommandLine.SampleFiles(vocabulary: vocabulary, corrections: corrections)
        var asked: [Int] = []
        await #expect(throws: HubSetupError.self) {
            try await HubCommands.importSamples(files, folder: folder) { port in asked.append(port); return true }
        }
        #expect(asked == [Hub.port])
        #expect(WordStore(store: folder.store).words == Vocabulary.defaults)

        // A dry run, or --force-offline, does not ask.
        var dry = files
        dry.dryRun = true
        #expect(try await HubCommands.importSamples(dry, folder: folder) { _ in Issue.record("asked"); return true } == 0)
        #expect(WordStore(store: folder.store).book.items.isEmpty)
        var forced = files
        forced.forceOffline = true
        #expect(try await HubCommands.importSamples(forced, folder: folder) { _ in Issue.record("asked"); return true } == 0)

        let words = WordStore(store: folder.store)
        #expect(words.words.contains("GitHub") && !words.words.contains("嗯那个") && !words.words.contains("Githup"))
        // Only the high-confidence corrections, split per wrong form.
        let imported = words.book.items.filter { $0.source == .imported }
        #expect(imported.count == 3 && words.book.items.count == 3)
        #expect(!imported.contains { $0.pair.wrong == "PR" || $0.pair.wrong == "实验" })
        // Hub not running: imported.
        #expect(try await HubCommands.importSamples(files, folder: folder) { _ in false } == 0)
    }

    // MARK: Eval

    @MainActor
    final class StubEval: HubEvalPolishing {
        struct Call: Equatable {
            let transcript: String
            let instructions: String
            let appName: String?
            let options: PolishOptions
        }

        var answer: (String) throws -> String = { "整理：" + $0 }
        private(set) var calls: [Call] = []
        private(set) var waited = 0

        func polish(_ transcript: String, instructions: String, appName: String?,
                    options: PolishOptions) async throws -> String {
            calls.append(Call(transcript: transcript, instructions: instructions, appName: appName, options: options))
            return try answer(transcript)
        }

        func waitForRefresh() async { waited += 1 }
    }

    static let samples = [
        HubEval.Sample(id: "s-000", app: "Claude", modeHint: "structured", raw: "数据是上周导出的那份布署日志"),
        HubEval.Sample(id: "s-001", app: "微信", modeHint: "light", raw: "那我开始了第一个是登录页的按钮太小第二个是"),
        HubEval.Sample(id: "s-048", app: "Google Chrome", modeHint: "raw", raw: "布署 文档"),
        HubEval.Sample(id: "s-049", app: nil, modeHint: "light", raw: "这个账号全线不够"),
    ]

    @Test func evalBuildsTheInstructionsADictationGets() async throws {
        let hub = try HubFixture()
        _ = hub.service.words.importSamples(words: ["权限"], corrections: SampleImport.plan(terms: [], corrections: Self.corrections).corrections,
                                        dryRun: false)
        // What the live pipeline hands ChatGPT for this transcript…
        _ = try await hub.service.polish(PolishRequest(text: "这个账号全线不够", mode: .natural, autoStructured: false, appName: "微信"))
        let call = try #require(hub.polisher.calls.last)
        let live = Polisher.instructions(vocabulary: call.vocabulary, corrections: call.corrections, mode: call.mode)
        #expect(call.corrections == [pair("全线", "权限")])
        // …is what the eval sends.
        #expect(HubEval.instructions(for: "这个账号全线不够", mode: .natural, words: hub.service.words, staticText: nil) == live)
        #expect(live.hasPrefix(PolishPrompt.naturalInstructions) && live.contains("- 全线 → 权限"))

        let stub = StubEval()
        let (results, stop) = await HubEval.run(Self.samples, words: hub.service.words, polisher: stub,
                                                overrides: [.structured: "# 结构化试验版"], pause: .zero)
        #expect(stop == nil)
        // 原样转写 never reaches ChatGPT.
        #expect(stub.calls.map(\.transcript) == ["数据是上周导出的那份布署日志", "那我开始了第一个是登录页的按钮太小第二个是",
                                                 "这个账号全线不够"])
        #expect(stub.calls.map(\.appName) == ["Claude", "微信", nil])
        #expect(stub.calls[0].instructions.hasPrefix("# 结构化试验版\n\n# neoless 热词表"))
        #expect(stub.calls[0].instructions.contains("- 布署 → 部署"))
        #expect(stub.calls[1].instructions == HubEval.instructions(for: Self.samples[1].raw, mode: .natural,
                                                                   words: hub.service.words, staticText: nil))
        #expect(stub.calls[2].instructions == live)
        #expect(results.map(\.id) == ["s-000", "s-001", "s-048", "s-049"])
        #expect(results.map(\.mode) == [.structured, .natural, .raw, .natural])
        #expect(results.map(\.polished) == [true, true, false, true])
        // The raw one is typed as a dictation types it: with the confirmed corrections.
        #expect(results[2].output == "部署 文档" && results[2].fallback == nil && results[2].ms == 0)
        #expect(results[3].output == "整理：这个账号全线不够" && results[3].app == nil)
        // Nothing went into the hub's history but the one dictation above.
        #expect(hub.service.history.entries.count == 1)
    }

    @Test func evalFallsBackAndStopsOnLoginFailures() async throws {
        let (folder, dir) = try folder()
        defer { removeTemporary(dir) }
        let words = WordStore(store: folder.store)
        let stub = StubEval()
        stub.answer = { text in
            if text.hasPrefix("数据") { throw PolishError.timeout }
            throw PolishError.http(401, "")
        }
        var lines: [String] = []
        let (results, stop) = await HubEval.run(Self.samples, words: words, polisher: stub, pause: .zero,
                                                progress: { lines.append($0) })
        // A timeout is one sample's problem; a refused login ends the run.
        #expect(results.count == 2 && stub.calls.count == 2)
        #expect(results.map(\.polished) == [false, false])
        #expect(results[0].output == Self.samples[0].raw && results[0].fallback == "整理超时")
        guard case .login(let why)? = stop else {
            Issue.record("no stop")
            return
        }
        #expect(why.contains("登录"))
        #expect(lines.count == 2 && lines[0].hasPrefix("[1/4] s-000"))

        for error in [PolishError.notSignedIn, .http(401, ""), .http(403, ""), .http(429, "")] {
            #expect(HubEval.stopsTheRun(error))
        }
        for error: Error in [PolishError.timeout, PolishError.http(500, ""), PolishError.empty, URLError(.notConnectedToInternet)] {
            #expect(!HubEval.stopsTheRun(error))
        }

        var asked = 0
        let (none, interrupted) = await HubEval.run(Self.samples, words: words, polisher: StubEval(), pause: .zero,
                                                    interrupted: { asked += 1; return asked > 2 })
        #expect(none.count == 1 && interrupted == .interrupted)
    }

    @Test func evalSamplesAndResults() throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let file = dir.appendingPathComponent("polish-eval.json")
        try Data((#"[{"id": "s-000", "app": "Claude", "mode_hint": "structured", "raw": "你好", "reference": null, "must": ["x"]},"#
                  + #" {"id": "s-001", "app": "微信", "mode_hint": "light", "raw": "好的"},"#
                  + #" {"id": "s-048", "app": null, "mode_hint": "raw", "raw": "搜索"}]"#).utf8).write(to: file)
        let samples = try HubEval.load(samples: file)
        #expect(samples.map(\.id) == ["s-000", "s-001", "s-048"] && samples[2].app == nil)
        #expect(samples.compactMap { HubEval.mode(forHint: $0.modeHint) } == [.structured, .natural, .raw])
        #expect(try HubEval.select(samples, only: ["s-048", "s-000"], limit: nil).map(\.id) == ["s-000", "s-048"])
        #expect(try HubEval.select(samples, only: nil, limit: 2).map(\.id) == ["s-000", "s-001"])
        #expect(try HubEval.select(samples, only: ["s-001", "s-048"], limit: 1).map(\.id) == ["s-001"])
        #expect(throws: HubSetupError.self) { try HubEval.select(samples, only: ["s-999"], limit: nil) }

        try Data(#"[{"id": "x", "app": null, "mode_hint": "fancy", "raw": "a"}]"#.utf8).write(to: file)
        #expect(throws: HubSetupError.self) { try HubEval.load(samples: file) }
        try Data("{}".utf8).write(to: file)
        #expect(throws: HubSetupError.self) { try HubEval.load(samples: file) }

        // Every key on every line; nothing missing for null.
        let data = try HubEval.encode([HubEval.Result(id: "s-048", mode: .raw, app: nil, raw: "搜索", output: "搜索", polished: false,
                                                      fallback: nil, ms: 0)])
        let object = try #require((try JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first)
        #expect(Set(object.keys) == ["id", "mode", "app", "raw", "output", "polished", "fallback", "ms", "model"])
        #expect(object["fallback"] is NSNull && object["app"] is NSNull && object["mode"] as? String == "raw")
        #expect(object["model"] is NSNull)
        #expect(try JSONDecoder().decode([HubEval.Result].self, from: data).first?.raw == "搜索")
    }

    /// `--print-instructions` output saved to a file reads back as the same static text.
    @Test func printedInstructionsReadBackUnchanged() throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        for mode in [DictationMode.natural, .structured] {
            let file = dir.appendingPathComponent("\(mode.rawValue).txt")
            try Data((PolishPrompt.staticInstructions(for: mode) + "\n").utf8).write(to: file)
            #expect(try HubEval.staticText(from: file) == PolishPrompt.staticInstructions(for: mode))
        }
        let empty = dir.appendingPathComponent("empty.txt")
        try Data("\n \n".utf8).write(to: empty)
        #expect(throws: HubSetupError.self) { try HubEval.staticText(from: empty) }
        #expect(throws: HubSetupError.self) { try HubEval.staticText(from: dir.appendingPathComponent("missing.txt")) }
    }

    @Test func evalCommandNeedsTheHubsLogin() async throws {
        let (folder, dir) = try folder()
        defer { removeTemporary(dir) }
        let file = dir.appendingPathComponent("polish-eval.json")
        try Data(#"[{"id": "s-001", "app": "微信", "mode_hint": "light", "raw": "好的"}]"#.utf8).write(to: file)
        let out = dir.appendingPathComponent("v0.json")
        await #expect(throws: HubSetupError(HubLoginText.notSignedIn + "：先运行 neoless-hub login")) {
            try await HubCommands.eval(.init(samples: file.path, out: out.path), folder: folder)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        await #expect(throws: HubSetupError.self) {
            try await HubCommands.eval(.init(samples: file.path, out: dir.appendingPathComponent("no/v0.json").path), folder: folder)
        }
        await #expect(throws: HubSetupError.self) {
            try await HubCommands.eval(.init(samples: file.path, naturalFile: dir.appendingPathComponent("none.txt").path), folder: folder)
        }
    }

    // MARK: Transcribe

    @Test func transcribeGoesThroughTheDictationPath() async throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let asr = StubASR()
        asr.reply = .text(" 下午三点开会 ")
        let wav = dir.appendingPathComponent("a.wav")
        try AudioFixture.wav.write(to: wav)
        let result = await HubCommands.transcribe(file: wav.path, asr: asr, hints: ["权限", "GitHub"])
        #expect(result.transcript == "下午三点开会" && result.status == "ok" && result.asrMs == 5 && result.error == nil)
        #expect(abs((result.seconds ?? 0) - 1) < 0.01)
        let call = try #require(asr.calls.first)
        #expect(call.hints == ["权限", "GitHub"] && abs(call.seconds - 1) < 0.01)
        // The worker gets what `/v1/dictations` sends it: 16 kHz mono 16-bit WAV.
        #expect(call.wav.prefix(4) == Data("RIFF".utf8))
        #expect(result.lines.contains("转写（识别 5 ms）：下午三点开会"))

        let m4a = dir.appendingPathComponent("b.m4a")
        try AudioFixture.m4a.write(to: m4a)
        #expect(await HubCommands.transcribe(file: m4a.path, asr: asr, hints: []).transcript == "下午三点开会")

        asr.reply = .silence
        #expect(await HubCommands.transcribe(file: wav.path, asr: asr, hints: []).lines.contains("转写（识别 0 ms）：（没听到话）"))
        asr.reply = .fail(.unreachable)
        #expect(await HubCommands.transcribe(file: wav.path, asr: asr, hints: []).error == "worker 没有响应")

        let calls = asr.calls.count
        let text = dir.appendingPathComponent("c.txt")
        try Data("hi".utf8).write(to: text)
        #expect(await HubCommands.transcribe(file: text.path, asr: asr, hints: []).error == "只认 .wav、.m4a 和 .caf")
        let broken = dir.appendingPathComponent("d.wav")
        try Data("not audio".utf8).write(to: broken)
        #expect(await HubCommands.transcribe(file: broken.path, asr: asr, hints: []).error == HubFailure.decodeFailed.body.error)
        #expect(await HubCommands.transcribe(file: dir.appendingPathComponent("e.wav").path, asr: asr, hints: []).error == "读不了这个文件")
        #expect(asr.calls.count == calls)
    }
}
