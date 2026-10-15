import AppKit
import NeolessCore

/// The window's four pages from the keyboard. The 显示 menu lists them in sidebar order with ⌘1 … ⌘4 and a
/// check mark on the one showing; the sidebar rows carry the same keys as a hint (`PageShortcut`). A digit on
/// its own does the same while nothing is being typed into: with a text field or an editor holding the
/// keyboard it is text, and never reaches here. The latest result on the 听写 page is such an editor, and it
/// does not look like a field: a click beside it ends the typing (`noteMouse`), so the digits are the pages'
/// again.
@MainActor
final class PageMenu: NSObject, NSMenuItemValidation {
    private let router: Router
    /// The main window, while there is one.
    private let window: () -> NSWindow?
    /// Shows a page (and the window, when it is closed).
    private let open: (Page) -> Void
    /// The editor a click went down beside, until the button comes up (`noteMouse`).
    private weak var leaving: NSTextView?

    init(router: Router, window: @escaping () -> NSWindow?, open: @escaping (Page) -> Void) {
        self.router = router
        self.window = window
        self.open = open
    }

    /// The 显示 item for the main menu. Its entries point at this object, which the caller keeps.
    func makeItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "显示")
        for (index, page) in Page.allCases.enumerated() {
            // ⌘ is the modifier a menu item's key gets when none is named.
            guard let key = PageShortcut.key(at: index) else { break }
            let entry = menu.addItem(withTitle: page.title, action: #selector(pick(_:)), keyEquivalent: key)
            entry.target = self
            entry.tag = index
        }
        item.submenu = menu
        return item
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard Page.allCases.indices.contains(sender.tag) else { return }
        open(Page.allCases[sender.tag])
    }

    /// The check mark follows the page showing. Under a sheet (断开配对？) the pages stay where they are.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(pick(_:)), Page.allCases.indices.contains(item.tag) else { return true }
        item.state = (router.section ?? .home) == Page.allCases[item.tag] ? .on : .off
        return window()?.attachedSheet == nil
    }

    /// A key that went down in the app, before anything else sees it: true when it was a digit on its own for
    /// a page, and the key is used up. The page is now showing; a digit still held down opens nothing more.
    /// Everything else (a digit typed into text, a key with ⌃ ⌥ ⌘, a key in another window or a sheet) is left
    /// alone.
    func handlePlainKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let window = window(), event.window === window, window.attachedSheet == nil,
              let characters = event.charactersIgnoringModifiers else { return false }
        let modified = !event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        switch PageShortcut.plainKey(characters: characters, modified: modified, typing: Self.isTyping(in: window),
                                     isRepeat: event.isARepeat, pages: Page.allCases.count) {
        case .open(let index)?: open(Page.allCases[index])
        case .held?: break
        case nil: return false
        }
        return true
    }

    /// The left mouse button went down or came up in the app, before anything else sees it. A click beside the
    /// editor being typed into (the latest result on the 听写 page) ends the typing: the editor gives up the
    /// keyboard, its caret and 完成 go, and the digits open pages again. A text field keeps the keyboard as
    /// everywhere on the Mac: its caret shows where a digit would go. The editor lets go only once the button is
    /// up and what was clicked has done its part: a button on the result's own toolbar still gets its click
    /// (the toolbar changes when the typing ends). A click into the editor, or one that moved the keyboard
    /// somewhere else, changes nothing.
    func noteMouse(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            leaving = nil
            guard let window = window(), event.window === window, window.attachedSheet == nil,
                  let editor = window.firstResponder as? NSTextView, editor.isEditable, !editor.isFieldEditor else { return }
            let box: NSView = editor.enclosingScrollView ?? editor
            if !box.bounds.contains(box.convert(event.locationInWindow, from: nil)) { leaving = editor }
        case .leftMouseUp:
            guard let editor = leaving else { return }
            leaving = nil
            DispatchQueue.main.async { [weak self, weak editor] in
                guard let editor, let window = self?.window(), window.firstResponder === editor else { return }
                window.makeFirstResponder(nil)
            }
        default: break
        }
    }

    /// Whether what holds the keyboard in `window` takes text: a text field's editor or a text view that can be
    /// edited (one that only lets its text be selected and copied takes none), or any other view the input
    /// system types into. When in doubt it does, and the digit goes to it.
    static func isTyping(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder, responder !== window else { return false }
        if let text = responder as? NSText { return text.isEditable }
        return responder is NSTextInputClient
    }
}
