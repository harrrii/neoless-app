import Foundation
import NeolessCore

/// The settings one polish request runs with. The Mac app reads them from its settings, the hub from its own.
public struct PolishOptions: Equatable, Sendable {
    public var model: String
    /// The Fast tier (`service_tier: priority`).
    public var fastTier: Bool
    /// The user's 整理超时 setting: the floor of the length-scaled budget (`PolishTimeout.seconds`).
    public var minimumTimeout: TimeInterval

    public static let defaultModel = "gpt-6.1-sol"

    public init(model: String = PolishOptions.defaultModel, fastTier: Bool = true, minimumTimeout: TimeInterval = 10) {
        self.model = model; self.fastTier = fastTier; self.minimumTimeout = minimumTimeout
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
                                                    mode: mode, staticText: overrides?.staticText(for: mode)),
                         appName: appName, account: account, options: options, session: session)
    }

    /// The instructions `polish(transcript:vocabulary:…)` sends: the vocabulary cut to the prompt budget again, then
    /// `PolishPrompt.instructions`. `staticText` replaces the mode's static text (the user's own instruction
    /// file, `PolishOverrides`, or `neoless-hub eval` trying a variant); nil is the built-in text.
    public static func instructions(vocabulary: Vocabulary.PromptWords, corrections: [CorrectionPair] = [],
                                    extras: PolishExtras = .none, mode: DictationMode = .natural,
                                    staticText: String? = nil) -> String {
        let words = Vocabulary.promptWords(vocabulary.all, learned: vocabulary.learned)
        return PolishPrompt.instructions(for: mode, vocabulary: words.own, learned: words.learned,
                                         corrections: corrections, extras: extras, staticText: staticText)
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
