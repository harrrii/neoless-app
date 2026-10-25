import Foundation
import NeolessCloud
import NeolessCore

/// What the hub needs from ChatGPT (the shared `Polisher` with the hub's own login; tests stub it).
@MainActor
public protocol HubPolishing: AnyObject {
    /// The polished text, or an error (`PolishError`, a network error). The time limit is built in.
    /// `extras`: the swaps made twice for this transcript, and the user's habits (`PolishExtras`).
    /// `options`: the model, 快速模式 and time limit, the device's choice on the hub's settings
    /// (`HubConfig.polishOptions(model:fastTier:)`).
    func polish(_ transcript: String, mode: DictationMode, appName: String?, vocabulary: Vocabulary.PromptWords,
                corrections: [CorrectionPair], extras: PolishExtras, options: PolishOptions) async throws -> String
    /// Those of `pairs` ChatGPT judges misheard, given what the recognizer heard and what was delivered
    /// (`MisheardJudge`), or an error.
    func judge(heard: String, delivered: String, pairs: [CorrectionPair], options: PolishOptions) async throws -> [CorrectionPair]
    /// For `GET /v1/health`.
    var health: HubHealth.ChatGPT { get }
    /// Returns once no login token refresh is running. A polish that timed out stops waiting for its refresh,
    /// but the refresh goes on (`ChatGPTAccount.refresh`): `serve` waits for it before exiting, or the rotated
    /// refresh token might never be saved and the next refresh would sign the hub out.
    func waitForRefresh() async
}

/// Polishes with the hub's own ChatGPT login (chatgpt-auth.json in the data folder, made by `neoless-hub login`).
/// A login saved while the hub runs is picked up without a restart. The instructions are the built-in ones, or the user's own files in the data folder
/// (`PolishOverrides`: polish-natural.md, polish-structured.md).
@MainActor
public final class ChatGPTPolisher: HubPolishing {
    private let store: DataFileStore
    private let config: @MainActor () -> HubConfig
    private let session: URLSession
    private let authSession: URLSession
    private var account: ChatGPTAccount
    private var stamp: FileStamp?
    /// The user's own instruction files, looked for in the data folder at every polish.
    let overrides: PolishOverrides
    /// Accounts replaced by a newer login file, until a refresh they may still be running has finished.
    private var retiring: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - session: for the polish requests.
    ///   - authSession: for the token refreshes (tests stub it).
    public init(store: DataFileStore, config: @escaping @MainActor () -> HubConfig, session: URLSession = Polisher.session,
                authSession: URLSession = .shared) {
        self.store = store
        self.config = config
        self.session = session
        self.authSession = authSession
        overrides = PolishOverrides(store: store)
        stamp = FileStamp.of(store.url(ChatGPTAccount.fileName))
        account = Self.makeAccount(store: store, session: authSession)
    }

    static func makeAccount(store: DataFileStore, session: URLSession = .shared) -> ChatGPTAccount {
        // The hub never opens a browser while serving: signing in is `neoless-hub login`.
        ChatGPTAccount(store: store, openURL: { _ in }, session: session)
    }

    /// The account, made again when another process (`neoless-hub login`, a refresh) changed the login file.
    /// The account's own refresh logic copes with a refresh token rotated meanwhile.
    var current: ChatGPTAccount {
        let now = FileStamp.of(store.url(ChatGPTAccount.fileName))
        if now != stamp {
            stamp = now
            retire(account)
            account = Self.makeAccount(store: store, session: authSession)
        }
        return account
    }

    /// Keeps `old` until a refresh it may be running has finished, for `waitForRefresh`.
    private func retire(_ old: ChatGPTAccount) {
        let key = ObjectIdentifier(old)
        retiring[key] = Task { @MainActor [weak self] in
            await old.waitForRefresh()
            self?.retiring[key] = nil
        }
    }

    public func waitForRefresh() async {
        while true {
            if let old = retiring.values.first {
                await old.value
                continue
            }
            await account.waitForRefresh()
            if retiring.isEmpty { return }
        }
    }

    public func polish(_ transcript: String, mode: DictationMode, appName: String?, vocabulary: Vocabulary.PromptWords,
                       corrections: [CorrectionPair], extras: PolishExtras, options: PolishOptions) async throws -> String {
        try await Polisher.polish(transcript: transcript, vocabulary: vocabulary, appName: appName, account: current,
                                  options: options, corrections: corrections, extras: extras, mode: mode,
                                  overrides: overrides, session: session)
    }

    /// `neoless-hub eval`: one transcript with instructions already built, through the same request and login as a
    /// dictation, with `options` (the hub's settings).
    public func polish(_ transcript: String, instructions: String, appName: String?,
                       options: PolishOptions) async throws -> String {
        try await Polisher.polish(transcript: transcript, instructions: instructions, appName: appName, account: current,
                                  options: options, session: session)
    }

    public func judge(heard: String, delivered: String, pairs: [CorrectionPair],
                      options: PolishOptions) async throws -> [CorrectionPair] {
        let answer = try await Polisher.ask(instructions: MisheardJudge.instructions,
                                            question: MisheardJudge.question(heard: heard, delivered: delivered, pairs: pairs),
                                            account: current, options: options, session: session)
        return MisheardJudge.misheard(in: answer, asked: pairs)
    }

    public var health: HubHealth.ChatGPT { Self.health(of: current) }

    static func health(of account: ChatGPTAccount) -> HubHealth.ChatGPT {
        if account.isReady { return HubHealth.ChatGPT(ready: true, account: account.maskedEmail) }
        return HubHealth.ChatGPT(ready: false, problem: HubLoginText.notSignedIn)
    }
}

extension HubPolishing {
    /// A polisher that cannot judge (a test stub) judges nothing misheard.
    public func judge(heard: String, delivered: String, pairs: [CorrectionPair],
                      options: PolishOptions) async throws -> [CorrectionPair] { [] }
}

/// What the hub says about its ChatGPT login (`HubHealth.ChatGPT.problem`): the cause alone. What it means for a
/// dictation is the device's to say.
public enum HubLoginText {
    public static let notSignedIn = "Neo 还没登录 ChatGPT"
}
