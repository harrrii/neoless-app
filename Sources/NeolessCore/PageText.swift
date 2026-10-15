import Foundation

/// Chinese and Latin text side by side, spaced the way Chinese typesetting wants it: a space only
/// where a Latin word (or a number) meets other text, "输入到 Claude", "在 VS Code 里", but none
/// between Han characters, "输入到微信", "在微信里".
public enum MixedText {
    /// Joins the pieces in order, with a space only where a Latin letter or digit touches a letter
    /// of the next piece (or of the one before). Empty pieces are skipped; punctuation and spaces
    /// already at a seam get nothing more.
    public static func join(_ pieces: String...) -> String {
        join(pieces)
    }

    public static func join(_ pieces: [String]) -> String {
        var out = ""
        for piece in pieces where !piece.isEmpty {
            if let last = out.last, let first = piece.first, spaced(last, first) { out.append(" ") }
            out += piece
        }
        return out
    }

    /// A space between `a` and `b`: both are letters or digits, and at least one is Latin.
    static func spaced(_ a: Character, _ b: Character) -> Bool {
        let ka = kind(a), kb = kind(b)
        guard ka != .other, kb != .other else { return false }
        return ka == .latin || kb == .latin
    }

    private enum Kind { case latin, wide, other }

    private static func kind(_ c: Character) -> Kind {
        guard c.isLetter || c.isNumber else { return .other }
        guard let scalar = c.unicodeScalars.first else { return .other }
        // Latin letters with or without accents, and the digits: everything a Latin word is made of.
        if scalar.value < 0x0250 || (0x1E00...0x1EFF).contains(scalar.value) { return .latin }
        return .wide
    }
}

/// A dictation record's note, as the window shows it. The controller keeps the reasons in one
/// string joined with "；" (what the recording, the polish and the paste each had to say).
public enum RecordNote {
    /// What a take whose paste was cancelled with Esc (or ×) adds to its note.
    public static let pasteCancelled = "按了 Esc，没有输入"

    /// The separate reasons in a stored note.
    public static func parts(_ note: String?) -> [String] {
        guard let note else { return [] }
        return note.components(separatedBy: CharacterSet(charactersIn: "；;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasSuffix("。") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty }
    }

    /// The reasons as sentences, each ending in "。": "整理超时。没找到输入框，只复制了。". Nil when there are none.
    public static func sentences(_ parts: [String]) -> String? {
        guard !parts.isEmpty else { return nil }
        return parts.map { "。！？".contains($0.last ?? " ") ? $0 : $0 + "。" }.joined()
    }

    /// The whole note as sentences (History, and the home page after a relaunch).
    public static func display(_ note: String?) -> String? {
        sentences(parts(note))
    }

    /// The note under a result while the home page's headline and the line under it describe that same
    /// result (`doneMessage`, the controller's `.done` message): what they already say is left out, so one
    /// event is told once. Gone: why it was copied or not typed (`InsertResult.detail`), the Esc note, and
    /// for a result typed or copied without polish, the polish failure the line names. Kept: anything the
    /// line does not say (the microphone failed, the recording hit 10 minutes, a later 重新整理 failed
    /// for another reason).
    public static func beyond(doneMessage: String, note: String?) -> String? {
        let said = Set(InsertResult.allCases.compactMap(\.detail)).union([pasteCancelled])
        let reason = FailureText.fallback(doneMessage)?.reason
        return sentences(parts(note).filter { part in
            if said.contains(part) { return false }
            if let reason, part.contains(reason) { return false }
            return true
        })
    }
}
