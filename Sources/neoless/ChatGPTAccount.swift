import AppKit
import Foundation
import NeolessCloud
import NeolessCore

// The login, the token refresh and the polish request live in NeolessCloud (shared with the hub and the
// iPhone app). Here they are wired to the Mac app: its data folder, its settings and the browser.

extension ChatGPTAccount {
    /// The Mac app's login: ~/Library/Application Support/neoless/chatgpt-auth.json, the sign-in page in the
    /// default browser.
    convenience init() {
        self.init(store: AppFiles.store,
                  openURL: { NSWorkspace.shared.open($0) },
                  didSignIn: { NSApp.activate(ignoringOtherApps: true) })
    }
}

extension PolishOptions {
    /// 模型, 快速模式 and 整理超时 as Settings has them now.
    @MainActor
    static var current: PolishOptions {
        let settings = AppSettings.shared
        return PolishOptions(model: settings.model, fastTier: settings.fastTier, minimumTimeout: settings.polishTimeout)
    }
}

extension Polisher {
    /// `Polisher.polish` with the options Settings has now (`PolishOptions.current`) and the user's own
    /// instruction files, when there are some in the app's data folder (`PolishOverrides`).
    ///
    /// - Parameters:
    ///   - vocabulary: `VocabularyStore.promptWords`.
    ///   - corrections: learned pairs for this transcript, normally `LearningStore.promptPairs(for:)`.
    ///   - extras: the swaps made twice for this transcript and the user's habits, normally
    ///     `LearningStore.promptExtras(for:)`.
    ///   - mode: `AppSettings.effectiveMode(forBundleID:appName:)` for a new dictation, `record.mode` when
    ///     polishing a record again. `.raw` is polished as `.natural`.
    @MainActor
    static func polish(transcript: String, vocabulary: Vocabulary.PromptWords, appName: String?, account: ChatGPTAccount,
                       corrections: [CorrectionPair] = [], extras: PolishExtras = .none,
                       mode: DictationMode = .natural) async throws -> String {
        try await polish(transcript: transcript, vocabulary: vocabulary, appName: appName, account: account,
                         options: .current, corrections: corrections, extras: extras, mode: mode,
                         overrides: PolishOverrides(store: AppFiles.store))
    }
}
