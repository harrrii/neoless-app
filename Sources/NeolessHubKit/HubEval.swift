import Foundation
import NeolessCloud
import NeolessCore

/// ChatGPT for `neoless-hub eval`: one transcript with its instructions already built (`ChatGPTPolisher`, the hub's
/// own login and settings; tests stub it).
@MainActor
public protocol HubEvalPolishing: AnyObject {
    func polish(_ transcript: String, instructions: String, appName: String?, options: PolishOptions) async throws -> String
    /// Returns once no login token refresh is running: the command waits for it before exiting.
    func waitForRefresh() async
}

extension ChatGPTPolisher: HubEvalPolishing {}

/// `neoless-hub eval`: a file of transcripts the user brings (their own past dictations, say; the format is in
/// examples/polish-eval.example.json) through the polish a dictation gets on the hub (the same instructions with
/// the hub's vocabulary and learned corrections, the same request and login), optionally with another static text
/// for 自然整理 or 结构化, to compare prompt versions on real speech.
/// One sample at a time with a pause between ChatGPT calls; nothing is saved in the hub's history.
@MainActor
public enum HubEval {
    /// One entry of polish-eval.json; the other fields (`reference`, `must`, `notes`) are for whoever judges.
    public struct Sample: Decodable, Equatable, Sendable {
        public var id: String
        public var app: String?
        /// light, structured or raw.
        public var modeHint: String
        public var raw: String

        public init(id: String, app: String?, modeHint: String, raw: String) {
            self.id = id; self.app = app; self.modeHint = modeHint; self.raw = raw
        }

        enum CodingKeys: String, CodingKey { case id, app, modeHint = "mode_hint", raw }
    }

    /// One line of the results file.
    public struct Result: Codable, Equatable, Sendable {
        public var id: String
        public var mode: DictationMode
        public var app: String?
        public var raw: String
        /// What the dictation would type: the polished text, or after a failed polish the original with the
        /// confirmed corrections (as the hub types it).
        public var output: String
        public var polished: Bool
        /// Why it was not polished (nil when it was, or for 原样转写).
        public var fallback: String?
        /// How long the polish took (0 for 原样转写).
        public var ms: Int
        /// The ChatGPT model it was sent to (nil for 原样转写, which is not sent).
        public var model: String?

        public init(id: String, mode: DictationMode, app: String?, raw: String, output: String, polished: Bool,
                    fallback: String?, ms: Int, model: String? = nil) {
            self.id = id; self.mode = mode; self.app = app; self.raw = raw; self.output = output
            self.polished = polished; self.fallback = fallback; self.ms = ms; self.model = model
        }

        enum CodingKeys: String, CodingKey { case id, mode, app, raw, output, polished, fallback, ms, model }

        // Every key is written, an empty one as null, so each line has the same shape.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(mode, forKey: .mode)
            try c.encode(app, forKey: .app)
            try c.encode(raw, forKey: .raw)
            try c.encode(output, forKey: .output)
            try c.encode(polished, forKey: .polished)
            try c.encode(fallback, forKey: .fallback)
            try c.encode(ms, forKey: .ms)
            try c.encode(model, forKey: .model)
        }
    }

    /// The mode a sample's `mode_hint` stands for: light → 自然整理, structured → 结构化, raw → 原样转写.
    public static func mode(forHint hint: String) -> DictationMode? {
        switch hint.trimmingCharacters(in: .whitespaces).lowercased() {
        case "light", "natural": return .natural
        case "structured": return .structured
        case "raw": return .raw
        default: return nil
        }
    }

    public static func load(samples url: URL) throws -> [Sample] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw HubSetupError("读不了样本文件 \(url.path)")
        }
        let samples: [Sample]
        do {
            samples = try JSONDecoder().decode([Sample].self, from: data)
        } catch {
            throw HubSetupError("样本文件 \(url.path) 的格式不对（要一个列表，每条有 id、app、mode_hint、raw）")
        }
        if let odd = samples.first(where: { mode(forHint: $0.modeHint) == nil }) {
            throw HubSetupError("样本 \(odd.id) 的 mode_hint 是“\(odd.modeHint)”，只认 light、structured、raw")
        }
        return samples
    }

    /// `--only` (ids, in the file's order) then `--limit`. An id that is not in the file is an error.
    public static func select(_ samples: [Sample], only: [String]?, limit: Int?) throws -> [Sample] {
        var chosen = samples
        if let only {
            let ids = Set(only)
            if let missing = only.first(where: { id in !samples.contains { $0.id == id } }) {
                throw HubSetupError("样本文件里没有 \(missing)")
            }
            chosen = samples.filter { ids.contains($0.id) }
        }
        if let limit { chosen = Array(chosen.prefix(limit)) }
        return chosen
    }

    /// The static text a variant file holds: as `--print-instructions` printed it, without the trailing line breaks.
    public static func staticText(from url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw HubSetupError("读不了指令文件 \(url.path)（要 UTF-8 文本）")
        }
        let trimmed = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HubSetupError("指令文件 \(url.path) 是空的") }
        return trimmed
    }

    /// The instructions a dictation of `raw` in `mode` gets on the hub right now (its vocabulary, the learned pairs for
    /// this transcript), with `staticText` in place of the mode's static text when given.
    public static func instructions(for raw: String, mode: DictationMode, words: WordStore, staticText: String?) -> String {
        Polisher.instructions(vocabulary: words.promptWords, corrections: words.promptPairs(for: raw),
                              extras: words.promptExtras(for: raw), mode: mode, staticText: staticText)
    }

    /// Why a run ended early.
    public enum Stop: Equatable, Sendable {
        /// The login is missing, expired or refused, or the quota is used up: every other sample would fail the same way.
        case login(String)
        /// Interrupted (Ctrl-C).
        case interrupted
    }

    /// A ChatGPT failure after which the run stops (the same set `neoless --polish-eval` stops on).
    static func stopsTheRun(_ error: Error) -> Bool {
        switch error as? PolishError {
        case .notSignedIn?, .http(401, _)?, .http(403, _)?, .http(429, _)?: return true
        default: return false
        }
    }

    /// Runs `samples` one after another and returns the results so far and why it stopped early, if it did.
    /// - Parameters:
    ///   - options: the model, 快速模式 and time limit every sample is polished with (the hub's settings); each
    ///     result names the model.
    ///   - overrides: the static text to use for 自然整理 and 结构化 (`.natural`, `.structured`); missing ones are live.
    ///   - pause: between two ChatGPT calls.
    ///   - progress: one line per sample (for standard error).
    ///   - interrupted: checked before each sample.
    public static func run(_ samples: [Sample], words: WordStore, polisher: HubEvalPolishing,
                           options: PolishOptions = PolishOptions(), overrides: [DictationMode: String] = [:],
                           pause: Duration = .seconds(1),
                           progress: (String) -> Void = { _ in },
                           interrupted: () -> Bool = { false }) async -> (results: [Result], stop: Stop?) {
        var results: [Result] = []
        var calledBefore = false
        for (n, sample) in samples.enumerated() {
            if interrupted() { return (results, .interrupted) }
            let mode = mode(forHint: sample.modeHint) ?? .natural
            let raw = sample.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let tag = "[\(n + 1)/\(samples.count)] \(sample.id) \(mode.title)"
            guard mode.polishes, !raw.isEmpty else {
                // 原样转写 (and an empty transcript) never reaches ChatGPT: the original with the confirmed corrections.
                results.append(Result(id: sample.id, mode: mode, app: sample.app, raw: sample.raw,
                                      output: raw.isEmpty ? "" : words.applyConfirmed(raw), polished: false, fallback: nil, ms: 0))
                progress("\(tag)：不整理")
                continue
            }
            if calledBefore { try? await Task.sleep(for: pause) }
            calledBefore = true
            if interrupted() { return (results, .interrupted) }
            let text = instructions(for: raw, mode: mode, words: words, staticText: overrides[mode])
            let start = ContinuousClock.now
            do {
                let out = try await polisher.polish(raw, instructions: text, appName: sample.app, options: options)
                let ms = HubService.ms(since: start)
                results.append(Result(id: sample.id, mode: mode, app: sample.app, raw: sample.raw, output: out,
                                      polished: true, fallback: nil, ms: ms, model: options.model))
                progress("\(tag)：\(ms) ms")
            } catch {
                let ms = HubService.ms(since: start)
                let why = PolishFailure.detail(error)
                results.append(Result(id: sample.id, mode: mode, app: sample.app, raw: sample.raw,
                                      output: words.applyConfirmed(raw), polished: false, fallback: why, ms: ms,
                                      model: options.model))
                progress("\(tag)：没整理成（\(why)）")
                if stopsTheRun(error) { return (results, .login(why)) }
            }
        }
        return (results, nil)
    }

    /// The results file: a JSON list, one object per sample, readable by people too.
    public static func encode(_ results: [Result]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(results)
    }
}
