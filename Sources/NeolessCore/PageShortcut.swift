import Foundation

// The window's pages by number, in sidebar order: ⌘1 for the first, ⌘2 for the second… The 显示 menu, the hint
// beside each sidebar row and the key handling all ask here, so they name and take the same keys.

public enum PageShortcut {
    /// One digit key each: a tenth page would have none.
    public static let limit = 9

    /// The key for the page at `index` (0 for the first): "1" … "9", nil beyond.
    public static func key(at index: Int) -> String? {
        (0..<limit).contains(index) ? String(index + 1) : nil
    }

    /// "⌘1": the quiet hint beside a sidebar row, and what the menu shows.
    public static func label(at index: Int) -> String? {
        key(at: index).map { "⌘" + $0 }
    }

    /// The sidebar row's tooltip: both ways to get there.
    public static func help(at index: Int) -> String? {
        key(at: index).map { "⌘\($0)；没在输入文字时，直接按 \($0) 也行" }
    }

    /// What a key pressed without ⌘ does, when it is a page's.
    public enum PlainKey: Equatable, Sendable {
        /// Opens the page at this index.
        case open(Int)
        /// A page's digit still held down: its page is open already. The key is used up and does nothing more
        /// (passed on, nothing would take it and the Mac would beep for every repeat).
        case held
    }

    /// A key pressed without ⌘: the page it opens (its index among `pages` pages), or nil when the key is not
    /// for a page. A digit on its own is a page only while nothing is being typed into; with a text field or an
    /// editor holding the keyboard (`typing`) it is text, and ⌘ with the digit is the way. `characters` is the
    /// key without ⌃ ⌥ ⌘ applied (Shift stays in: keyboards that need it for digits give the digit, the others
    /// give "!" and the like).
    public static func plainIndex(characters: String, modified: Bool, typing: Bool, pages: Int) -> Int? {
        guard !modified, !typing, characters.count == 1, let digit = Int(characters),
              characters.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        let index = digit - 1
        return (0..<min(pages, limit)).contains(index) ? index : nil
    }

    /// The same key as the window gets it, repeats included: held down, it opens its page once and the repeats
    /// are used up without doing anything. Nil: not a page's key, and whatever would have had it gets it.
    public static func plainKey(characters: String, modified: Bool, typing: Bool, isRepeat: Bool, pages: Int) -> PlainKey? {
        guard let index = plainIndex(characters: characters, modified: modified, typing: typing, pages: pages) else { return nil }
        return isRepeat ? .held : .open(index)
    }
}
