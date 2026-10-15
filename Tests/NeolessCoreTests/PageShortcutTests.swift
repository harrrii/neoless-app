import Foundation
import Testing
@testable import NeolessCore

@Suite struct PageShortcutTests {
    @Test func pagesAreNumberedFromOneInSidebarOrder() {
        #expect((0..<4).map { PageShortcut.key(at: $0) } == ["1", "2", "3", "4"])
        #expect((0..<4).map { PageShortcut.label(at: $0) } == ["⌘1", "⌘2", "⌘3", "⌘4"])
        #expect(PageShortcut.key(at: 8) == "9")
    }

    @Test func thereAreOnlyNineDigits() {
        #expect(PageShortcut.key(at: 9) == nil)
        #expect(PageShortcut.label(at: 9) == nil)
        #expect(PageShortcut.help(at: 9) == nil)
        #expect(PageShortcut.key(at: -1) == nil)
    }

    @Test func theTooltipNamesBothWays() {
        #expect(PageShortcut.help(at: 0) == "⌘1；没在输入文字时，直接按 1 也行")
        #expect(PageShortcut.help(at: 3) == "⌘4；没在输入文字时，直接按 4 也行")
    }

    @Test func aDigitOnItsOwnOpensItsPage() {
        for (key, index) in [("1", 0), ("2", 1), ("3", 2), ("4", 3)] {
            #expect(PageShortcut.plainIndex(characters: key, modified: false, typing: false, pages: 4) == index)
        }
    }

    @Test func aDigitTypedIntoTextStaysText() {
        for key in ["1", "2", "3", "4"] {
            #expect(PageShortcut.plainIndex(characters: key, modified: false, typing: true, pages: 4) == nil)
        }
    }

    @Test func onlyThePagesThereAre() {
        #expect(PageShortcut.plainIndex(characters: "5", modified: false, typing: false, pages: 4) == nil)
        #expect(PageShortcut.plainIndex(characters: "0", modified: false, typing: false, pages: 4) == nil)
        #expect(PageShortcut.plainIndex(characters: "9", modified: false, typing: false, pages: 12) == 8)
        #expect(PageShortcut.plainIndex(characters: "1", modified: false, typing: false, pages: 0) == nil)
    }

    @Test func otherKeysAreNotPages() {
        for key in ["", "a", "!", "12", "-", "+", " ", "\r", "１", "一", "\u{F700}"] {
            #expect(PageShortcut.plainIndex(characters: key, modified: false, typing: false, pages: 4) == nil)
        }
    }

    @Test func withAModifierItIsTheMenusToHandle() {
        // ⌘1 is the 显示 menu's key; ⌃1 and ⌥1 are not ours.
        #expect(PageShortcut.plainIndex(characters: "1", modified: true, typing: false, pages: 4) == nil)
    }

    @Test func aKeyHeldDownOpensThePageOnce() {
        // The press opens the page; the repeats that follow are used up and open nothing (left to the window,
        // nothing would take them and the Mac would beep).
        #expect(PageShortcut.plainKey(characters: "2", modified: false, typing: false, isRepeat: false, pages: 4) == .open(1))
        #expect(PageShortcut.plainKey(characters: "2", modified: false, typing: false, isRepeat: true, pages: 4) == .held)
    }

    @Test func aHeldKeyThatIsNoPagesIsLeftAlone() {
        // Typed into text, it repeats there; with a modifier or without a page, it is not ours either way.
        for isRepeat in [false, true] {
            #expect(PageShortcut.plainKey(characters: "2", modified: false, typing: true, isRepeat: isRepeat, pages: 4) == nil)
            #expect(PageShortcut.plainKey(characters: "2", modified: true, typing: false, isRepeat: isRepeat, pages: 4) == nil)
            #expect(PageShortcut.plainKey(characters: "5", modified: false, typing: false, isRepeat: isRepeat, pages: 4) == nil)
            #expect(PageShortcut.plainKey(characters: "a", modified: false, typing: false, isRepeat: isRepeat, pages: 4) == nil)
        }
    }
}
