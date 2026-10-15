import Foundation
import NeolessCore

/// Your own instructions for 自然整理 or 结构化: a UTF-8 text file in the data folder (`polish-natural.md`,
/// `polish-structured.md`) that takes the place of that mode's built-in static text (`PolishPrompt.staticInstructions`).
/// The word lists still follow it as the last section, so the file should speak of them as the built-in text does
/// (`neoless-hub eval --print-instructions natural` prints that text to start from).
///
/// The hub looks in its data folder, the Mac app in its own. A file is read again for every polish, so an edit
/// takes effect at once; a file that is missing, empty, too long or not text leaves the built-in instructions
/// in use.
public struct PolishOverrides: Sendable, Equatable {
    /// Longest file used: several times the built-in text. Longer is taken for a mistake (the wrong file).
    public static let maxBytes = 64 * 1024

    /// The file of `mode`; 原样转写, when it is polished at all, is polished as 自然整理.
    public static func fileName(for mode: DictationMode) -> String {
        mode == .structured ? "polish-structured.md" : "polish-natural.md"
    }

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public init(store: DataFileStore) { self.init(directory: store.directory) }

    public func url(for mode: DictationMode) -> URL {
        directory.appendingPathComponent(Self.fileName(for: mode))
    }

    public enum State: Equatable, Sendable {
        /// No file: the built-in text.
        case builtIn
        /// The file's text, without the white space around it.
        case custom(String)
        /// A file that is not used, and why (in Chinese): the built-in text.
        case unusable(String)
    }

    public func state(for mode: DictationMode) -> State {
        let url = url(for: mode)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .builtIn }
        guard !isDirectory.boolValue else { return .unusable("不是文件") }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        guard let size else { return .unusable("读不了") }
        guard size <= Self.maxBytes else { return .unusable("太长（最多 \(Self.maxBytes / 1024) KB）") }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return .unusable("读不了（要 UTF-8 文本）")
        }
        let trimmed = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .unusable("是空的") : .custom(trimmed)
    }

    /// The text to use in place of `mode`'s built-in static text, or nil for the built-in one.
    public func staticText(for mode: DictationMode) -> String? {
        if case .custom(let text) = state(for: mode) { return text }
        return nil
    }

    /// One line for a status listing: which instructions each mode gets.
    public var summary: String {
        func part(_ mode: DictationMode) -> String {
            let name = Self.fileName(for: mode), title = mode == .structured ? "结构化" : "自然整理"
            switch state(for: mode) {
            case .builtIn: return "\(title)用内置的"
            case .custom: return "\(title)用你自己的 \(name)"
            case .unusable(let why): return "\(title)用内置的（\(name) \(why)，没有用它）"
            }
        }
        return "整理指令（内置版本 \(PolishPrompt.version)）：\(part(.natural))；\(part(.structured))"
    }
}
