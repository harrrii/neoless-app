import Foundation
import NeolessCore

/// The settings one polish request runs with. The Mac app reads them from its settings; the hub from its own, with
/// the model and 快速模式 the device asked for (`HubConfig.polishOptions(model:fastTier:)`).
public struct PolishOptions: Equatable, Sendable {
    public var model: String
    /// The Fast tier (`service_tier: priority`).
    public var fastTier: Bool
    /// The user's 整理超时 setting: the floor of the length-scaled budget (`PolishTimeout.seconds`).
    public var minimumTimeout: TimeInterval

    /// The hub's model when its settings.json names none, and so what it polishes with for a device that does not
    /// say (`DictationRequest.polishModel` left out: an app from before the field). The app's own default is
    /// `PolishModel.recommended`.
    public static let defaultModel = "gpt-6.1-sol"

    public init(model: String = PolishOptions.defaultModel, fastTier: Bool = true, minimumTimeout: TimeInterval = 10) {
        self.model = model; self.fastTier = fastTier; self.minimumTimeout = minimumTimeout
    }
}

/// The ChatGPT models text is polished with, one list for everyone: the app's 整理模型 picker shows them, and the hub
/// polishes with the model a device asks for (`DictationRequest.polishModel`) only when it is one of them.
public struct PolishModel: Equatable, Identifiable, Sendable {
    /// What a request names (`PolishOptions.model`), and what the app stores.
    public let id: String
    /// What Settings shows.
    public let title: String

    public init(id: String, title: String) { self.id = id; self.title = title }

    /// In the order the picker shows them, the recommended one first.
    public static let all: [PolishModel] = [
        PolishModel(id: "gpt-6-luna", title: "GPT-6-Luna（更快，推荐）"),
        PolishModel(id: "gpt-6.1-sol", title: "GPT-6.1-Sol（更细致，慢一些）"),
        PolishModel(id: "gpt-5.6-luna", title: "GPT-5.6-Luna"),
    ]

    /// The app's 整理模型 until the user picks one: quicker than `PolishOptions.defaultModel`, a little less careful.
    public static let recommended = "gpt-6-luna"

    /// Whether `id` is one of `all`, exactly as written there.
    public static func isKnown(_ id: String?) -> Bool {
        guard let id else { return false }
        return all.contains { $0.id == id }
    }
}

/// What the Neo in use does with the device's 整理模型 and 快速模式, as far as its `GET /v1/health` says
/// (`HubHealth.polishModels`), and what Settings says under the two rows. Requests carry both whatever it says: a hub
/// that does not read them passes over them, and one updated in the meantime follows them from the next request on.
public enum NeoPolishSupport: Equatable, Sendable {
    /// It has not answered since the app started, or the Neo is not in use.
    case unknown
    /// Its hub is from before 整理模型: it polishes with its own settings.json model and 快速模式, whatever is asked.
    case outdated
    /// It polishes with any of these models when asked for one, and with the 快速模式 asked for.
    case listed([String])

    /// What a Neo that answered with `health` does.
    public init(health: HubHealth) {
        self = health.polishModels.map(Self.listed) ?? .outdated
    }

    /// Whether a Neo that has said so polishes with `model` when asked: nil while it has not said.
    public func follows(_ model: String) -> Bool? {
        switch self {
        case .unknown: return nil
        case .outdated: return false
        case .listed(let models): return models.contains(model)
        }
    }

    /// The line under 整理模型 with `model` chosen. Until the Neo has said, what a hub that reads the choice does.
    public func modelDetail(_ model: String) -> String {
        switch self {
        case .outdated: return "Neo 更新后才按这里，现在 Neo 用它自己设的模型"
        case .listed where follows(model) == false: return "这台 Neo 没有这个模型，用它自己设的模型整理"
        case .unknown, .listed: return "用 Neo 处理时也按这里"
        }
    }

    /// The line under 快速模式 (a Neo that lists models takes the device's 快速模式 even with a model it does not have).
    public var fastTierDetail: String {
        self == .outdated ? "优先处理，消耗更多额度；Neo 更新后才对 Neo 生效" : "优先处理，消耗更多额度；用 Neo 时也生效"
    }
}

/// One polishing request to the model service (a streamed response).
public enum Polisher {
    public static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        // A backstop only: the budget and the stall watchdog below always end a request first.
        c.timeoutIntervalForRequest = PolishTimeout.requestIdle
        c.httpShouldUsePipelining = true
        return URLSession(configuration: c)
    }()

    /// Polishes `transcript` in `mode` (自然整理 or 结构化). The text is returned only when the response
    /// completed; a cut-off, stalled or over-long stream throws, so the caller types the original instead.
    ///
    /// The time limit is built in: `PolishTimeout.seconds` for this transcript (`options.minimumTimeout` is the
    /// floor), plus the stall watchdog. Callers must not wrap this in a shorter timeout of their own.
    ///
    /// The vocabulary and corrections go at the end of the instructions (`PolishPrompt.instructions`), after
    /// the long fixed text, so that text is the same in every request; the user message holds only the app
    /// name and the transcript.
    ///
    /// - Parameters:
    ///   - vocabulary: the dictionary words to list: the user's own words, and the learned-only terms the
    ///     prompt lists apart with less weight. They are cut to the prompt budget again here, which leaves
    ///     those lists unchanged.
    ///   - corrections: learned pairs for this transcript (`LearningPrompt.pairs(for:from:)`).
    ///   - extras: the swaps the user made twice for this transcript (`LearningPrompt.repeated(for:from:)`) and
    ///     their habits (我的习惯).
    ///   - mode: the mode this dictation runs in (`DictationMode.effective` for a new dictation, the record's
    ///     mode when polishing it again). `.raw` is polished as `.natural`.
    ///   - overrides: where the user's own instruction files are looked for (the data folder); nil is the
    ///     built-in text.
    ///   - session: the connection to use (tests stub it).
    @MainActor
    public static func polish(transcript: String, vocabulary: Vocabulary.PromptWords, appName: String?,
                              account: ChatGPTAccount, options: PolishOptions, corrections: [CorrectionPair] = [],
                              extras: PolishExtras = .none, mode: DictationMode = .natural,
                              overrides: PolishOverrides? = nil,
                              session: URLSession = Polisher.session) async throws -> String {
        try await polish(transcript: transcript,
                         instructions: instructions(vocabulary: vocabulary, corrections: corrections, extras: extras,
                                                    mode: mode, staticText: overrides?.staticText(for: mode),
                                                    compact: PolishPrompt.usesCompact(transcript)),
                         appName: appName, account: account, options: options, session: session)
    }

    /// The instructions `polish(transcript:vocabulary:…)` sends: the vocabulary cut to the prompt budget again, then
    /// `PolishPrompt.instructions`. `staticText` replaces the mode's static text (the user's own instruction
    /// file, `PolishOverrides`, or `neoless-hub eval` trying a variant); nil is the built-in text. `compact`: the
    /// short-transcript text (`PolishPrompt.usesCompact`), unless the user's own instruction file replaces it.
    public static func instructions(vocabulary: Vocabulary.PromptWords, corrections: [CorrectionPair] = [],
                                    extras: PolishExtras = .none, mode: DictationMode = .natural,
                                    staticText: String? = nil, compact: Bool = false) -> String {
        let words = Vocabulary.promptWords(vocabulary.all, learned: vocabulary.learned)
        return PolishPrompt.instructions(for: mode, vocabulary: words.own, learned: words.learned,
                                         corrections: corrections, extras: extras, staticText: staticText, compact: compact)
    }

    /// Polishes `transcript` with instructions already built (`instructions(vocabulary:corrections:mode:staticText:)`),
    /// with the same request, time limit and checks as every dictation.
    @MainActor
    public static func polish(transcript: String, instructions: String, appName: String?, account: ChatGPTAccount,
                              options: PolishOptions, session: URLSession = Polisher.session) async throws -> String {
        let body = ResponsesRequest.body(
            model: options.model,
            instructions: instructions,
            userText: PolishPrompt.userMessage(transcript: transcript, appName: appName),
            fast: options.fastTier)
        // Grows with the transcript; the user's setting is the floor.
        let budget = PolishTimeout.seconds(forCharacters: transcript.count, minimum: options.minimumTimeout)
        return try await withTimeout(seconds: budget) { @MainActor in
            try await Self.request(body: body, account: account, session: session)
        }
    }

    /// One question with instructions of its own (`MisheardJudge`), through the same request, login and checks
    /// as a polish, under the time limit of a short polish. The answer as `PolishPrompt.clean` leaves it.
    @MainActor
    public static func ask(instructions: String, question: String, account: ChatGPTAccount, options: PolishOptions,
                           session: URLSession = Polisher.session) async throws -> String {
        let body = ResponsesRequest.body(model: options.model, instructions: instructions, userText: question,
                                         fast: options.fastTier)
        let budget = PolishTimeout.seconds(forCharacters: 200, minimum: options.minimumTimeout)
        return try await withTimeout(seconds: budget) { @MainActor in
            try await Self.request(body: body, account: account, session: session)
        }
    }

    @MainActor
    private static func request(body: Data, account: ChatGPTAccount, session: URLSession) async throws -> String {
        var credential = try await account.credential()
        for attempt in 0..<2 {
            var request = URLRequest(url: ChatGPTOAuth.responsesURL)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(credential.accountID, forHTTPHeaderField: "chatgpt-account-id")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
            request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "session_id")

            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 {
                bytes.task.cancel()
                try await account.refresh()
                credential = try await account.credential()
                continue
            }
            guard status == 200 else {
                var detail = ""
                for try await line in bytes.lines {
                    detail += line
                    if detail.count > 1_000 { break }
                }
                throw PolishError.http(status, detail)
            }
            var parser = ResponsesStreamParser()
            let task = bytes.task
            let watchdog = StallWatchdog(limit: PolishTimeout.stallLimit(sawText: false)) { task.cancel() }
            defer { watchdog.stop() }
            do {
                for try await line in bytes.lines {
                    parser.consume(line: line)
                    watchdog.touch(limit: PolishTimeout.stallLimit(sawText: parser.sawText))
                    if parser.completed || parser.failure != nil { break }
                }
            } catch {
                if watchdog.fired { throw PolishError.timeout }
                throw error
            }
            watchdog.stop()
            // A stall that fired just as the last event arrived does not spoil a completed response.
            if watchdog.fired && !parser.completed { throw PolishError.timeout }
            switch parser.outcome {
            case .failed(let why): throw PolishError.failed(why)
            case .cutOff: throw PolishError.incomplete
            case .text(let raw):
                let text = PolishPrompt.clean(raw)
                guard !text.isEmpty else { throw PolishError.empty }
                return text
            }
        }
        throw PolishError.notSignedIn
    }
}

/// Cancels a stream that has gone quiet: no event within the current limit.
public final class StallWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: Date
    private var didFire = false
    private var timer: Task<Void, Never>?

    public init(limit: TimeInterval, onStall: @escaping @Sendable () -> Void) {
        deadline = Date().addingTimeInterval(limit)
        timer = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                if self.expire() { onStall(); return }
            }
        }
    }

    deinit { timer?.cancel() }

    /// An event arrived: the next one is due within `limit`.
    public func touch(limit: TimeInterval) {
        lock.withLock { deadline = Date().addingTimeInterval(limit) }
    }

    public var fired: Bool { lock.withLock { didFire } }

    public func stop() { timer?.cancel() }

    private func expire() -> Bool {
        lock.withLock {
            guard !didFire, Date() >= deadline else { return false }
            didFire = true
            return true
        }
    }
}
