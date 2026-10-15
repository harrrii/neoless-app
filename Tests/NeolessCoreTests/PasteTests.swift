import Foundation
import Testing
@testable import NeolessCore

@Suite struct InsertPolicyTests {
    let own: Int32 = 1, notes: Int32 = 200, terminal: Int32 = 300

    let spotlight: Int32 = 400

    func decide(target: Int32? = 200, frontmost: Int32? = 200, accessibility: Bool = true,
                secureInput: Bool = false, focus: FocusedField = .editable, targetFocusOwner: Int32? = nil,
                focusOwner: Int32? = nil, field: FieldMatch = .unknown) -> InsertResult {
        InsertPolicy.decide(target: target, frontmost: frontmost, ownPID: own, accessibility: accessibility,
                            secureInput: secureInput, focus: focus, targetFocusOwner: targetFocusOwner,
                            focusOwner: focusOwner, field: field)
    }

    @Test func pastesIntoTheSameAppsEditableField() {
        #expect(decide() == .pasted)
        #expect(decide(focus: .unknown) == .pasted)            // Electron that exposes nothing
        #expect(decide(target: nil) == .pasted)
    }

    @Test func switchedAppIsCopiedNotPasted() {
        // input-2: stopped in Notes, Terminal came to the front while polishing
        #expect(decide(frontmost: terminal) == .copiedAppChanged)
        #expect(decide(frontmost: own) == .copiedAppChanged)
        #expect(decide(frontmost: nil) == .copiedAppChanged)
        #expect(decide(target: nil, frontmost: nil) == .copiedNoField)
    }

    @Test func anotherAppsPanelWithKeyboardFocusIsCopiedNotPasted() {
        // life-focus-owner-panel: ⌘Space while polishing; Notes stays frontmost, Spotlight has the keys
        #expect(decide(focusOwner: spotlight) == .copiedAppChanged)
        #expect(decide(targetFocusOwner: notes, focusOwner: spotlight) == .copiedAppChanged)
        // ...and the other way round: dictated into Spotlight, which closed meanwhile
        #expect(decide(targetFocusOwner: spotlight, focusOwner: notes) == .copiedAppChanged)
    }

    @Test func dictatingIntoAPanelPastesBackIntoIt() {
        #expect(decide(targetFocusOwner: spotlight, focusOwner: spotlight) == .pasted)
    }

    @Test func unknownFocusOwnerKeepsThePidRule() {
        #expect(decide(focusOwner: nil) == .pasted)
        #expect(decide(targetFocusOwner: spotlight, focusOwner: nil) == .pasted)
        #expect(decide(target: nil, focusOwner: spotlight) == .pasted)
        #expect(decide(focusOwner: notes) == .pasted)
    }

    @Test func anotherFieldOfTheSameAppIsCopiedNotPasted() {
        // life-same-app-other-field: another WeChat chat, Chrome's address bar
        #expect(decide(field: .moved) == .copiedFieldChanged)
        #expect(decide(field: .same) == .pasted)
        #expect(decide(field: .unknown) == .pasted)        // Electron without an accessibility tree
        // an app switch says so first
        #expect(decide(frontmost: terminal, field: .moved) == .copiedAppChanged)
        #expect(decide(focusOwner: spotlight, field: .moved) == .copiedAppChanged)
        #expect(decide(target: own, frontmost: own, field: .moved) == .ownApp)
    }

    @Test func ownWindowKeepsTheResultAtHome() {
        #expect(decide(target: own, frontmost: own) == .ownApp)
        #expect(decide(target: nil, frontmost: own) == .ownApp)
    }

    @Test func secureInputOnlyCopies() {
        // input-4: another app holds Secure Input, the field here is an ordinary one
        #expect(decide(secureInput: true) == .copiedSecureInput)
        #expect(decide(secureInput: true, focus: .unknown) == .copiedSecureInput)
        // a real password field: nothing pasted, nothing copied
        #expect(decide(secureInput: true, focus: .secure) == .notInserted)
        #expect(decide(focus: .secure) == .notInserted)
    }

    @Test func noFieldIsCopied() {
        // input-8
        #expect(decide(focus: .notEditable) == .copiedNoField)
    }

    @Test func withoutAccessibilityOnlyCopies() {
        #expect(decide(accessibility: false) == .copiedNoAccessibility)
        #expect(decide(accessibility: false, focus: .secure) == .copiedNoAccessibility)
    }

    @Test func resultsMapToDeliveryAndClipboard() {
        #expect(InsertResult.pasted.delivery == .pasted && !InsertResult.pasted.isCopied)
        #expect(InsertResult.ownApp.delivery == .inApp)
        #expect(InsertResult.notInserted.delivery == .notInserted && !InsertResult.notInserted.isCopied)
        for r in [InsertResult.copiedAppChanged, .copiedFieldChanged, .copiedNoField, .copiedSecureInput,
                  .copiedNoAccessibility] {
            #expect(r.delivery == .copied && r.isCopied)
            #expect(r.message.contains("⌘V"))
            #expect(r.detail != nil)
        }
        #expect(InsertResult.copiedSecureInput.message == "已复制，按 ⌘V 粘贴")
        // fits the widest status capsule (about 232 pt of text at 13 pt)
        #expect(InsertResult.copiedAppChanged.message.count <= 18)
        #expect(InsertResult.copiedFieldChanged.message.count <= 18)
        #expect(InsertResult.pasted.detail == nil)
    }

    @Test func aPasteThatCouldNotKeepTheClipboardSaysSo() {
        // input-6: the dictation stays on the clipboard, and the pill and history say why
        let r = InsertResult.pastedKeptOnClipboard
        #expect(r.delivery == .pasted && r.isCopied)
        #expect(r.message.hasPrefix("已输入") && r.message.contains("剪贴板"))
        #expect(r.message.count <= 18)
        #expect(r.detail?.contains("剪贴板") == true)
        #expect(DoneText.headline(r.message) == "已输入")
        #expect(FailureText.fallback(r.message) == nil)    // polished as usual: no "这次没有整理"
    }
}

@Suite struct FocusedFieldTests {
    @Test func textRolesAreEditable() {
        #expect(FocusedField.classify(role: "AXTextField", subrole: nil) == .editable)
        #expect(FocusedField.classify(role: "AXTextArea", subrole: nil) == .editable)
        #expect(FocusedField.classify(role: "AXComboBox", subrole: nil) == .editable)
        // contenteditable inside a web page
        #expect(FocusedField.classify(role: "AXGroup", subrole: nil, hasEditableAncestor: true) == .editable)
        #expect(FocusedField.classify(role: "AXStaticText", subrole: nil, hasEditableAncestor: true) == .editable)
        #expect(FocusedField.classify(role: "AXLayoutArea", subrole: nil, isValueSettable: true) == .editable)
    }

    @Test func passwordFieldsAreSecure() {
        #expect(FocusedField.classify(role: "AXTextField", subrole: "AXSecureTextField") == .secure)
        #expect(FocusedField.classify(role: "AXTextField", subrole: nil, isProtected: true) == .secure)
    }

    @Test func controlsThatTakeNoTextAreNotEditable() {
        #expect(FocusedField.classify(role: "AXList", subrole: nil) == .notEditable)        // Finder desktop
        #expect(FocusedField.classify(role: "AXOutline", subrole: nil) == .notEditable)     // Finder list view
        #expect(FocusedField.classify(role: "AXButton", subrole: nil) == .notEditable)
        #expect(FocusedField.classify(role: "AXLink", subrole: nil) == .notEditable)
        #expect(FocusedField.classify(role: "AXSlider", subrole: nil, isValueSettable: true) == .notEditable)
    }

    @Test func aBrowserPageWithNothingEditableIsNotAField() {
        // input-8: a click on an article in Safari or Chrome
        #expect(FocusedField.classify(role: "AXWebArea", subrole: nil, inBrowser: true) == .notEditable)
        // an editable document (Google Docs' editing frame) is its own editable ancestor
        #expect(FocusedField.classify(role: "AXWebArea", subrole: nil, hasEditableAncestor: true, inBrowser: true) == .editable)
        #expect(FocusedField.classify(role: "AXWebArea", subrole: nil, isValueSettable: true, inBrowser: true) == .editable)
        // fields in the page as before
        #expect(FocusedField.classify(role: "AXTextArea", subrole: nil, inBrowser: true) == .editable)
        #expect(FocusedField.classify(role: "AXGroup", subrole: nil, inBrowser: true) == .unknown)
        #expect(FocusedField.isBrowser(bundleID: "com.apple.Safari"))
        #expect(FocusedField.isBrowser(bundleID: "com.google.Chrome"))
        #expect(!FocusedField.isBrowser(bundleID: "com.tinyspeck.slackmacgap"))   // Electron
        #expect(!FocusedField.isBrowser(bundleID: nil))
    }

    @Test func unclearFocusStaysPasteable() {
        #expect(FocusedField.classify(role: nil, subrole: nil) == .unknown)
        // outside a browser a web area may be an Electron app without an accessibility tree
        #expect(FocusedField.classify(role: "AXWebArea", subrole: nil) == .unknown)
        #expect(FocusedField.classify(role: "AXWindow", subrole: nil) == .unknown)
        // spreadsheets, custom editors
        #expect(FocusedField.classify(role: "AXCell", subrole: nil) == .unknown)
        #expect(FocusedField.classify(role: "AXTable", subrole: nil) == .unknown)
        #expect(FocusedField.classify(role: "AXGroup", subrole: nil) == .unknown)
        #expect(FocusedField.classify(role: "AXScrollArea", subrole: nil) == .unknown)
    }
}

@Suite struct ClipboardPolicyTests {
    @Test func keepsCommonTypesCheapOnesFirst() {
        let types = ["public.tiff", "public.html", "com.microsoft.Excel.sheet", "public.utf8-plain-text",
                     "dyn.ah62d4rv4gu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn", "com.apple.pasteboard.promised-file-url",
                     "org.nspasteboard.ConcealedType", "public.file-url"]
        #expect(ClipboardPolicy.typesToKeep(types) ==
                ["org.nspasteboard.ConcealedType", "public.utf8-plain-text", "public.file-url", "public.html", "public.tiff"])
    }

    @Test func oneImageFormatPngFirst() {
        #expect(ClipboardPolicy.typesToKeep(["public.tiff", "public.png"]) == ["public.png"])
        #expect(ClipboardPolicy.typesToKeep(["public.jpeg", "public.tiff"]) == ["public.tiff"])
    }

    @Test func imagesOnlyForTheFirstItem() {
        let types = ["public.file-url", "public.utf8-plain-text", "public.tiff"]
        #expect(ClipboardPolicy.typesToKeep(types, itemIndex: 3) == ["public.utf8-plain-text", "public.file-url"])
    }

    @Test func privateFormatsAloneKeepNothing() {
        #expect(ClipboardPolicy.typesToKeep(["com.figma.clipboard", "NSFilePromiseItemMetaData"]).isEmpty)
    }

    @Test func everydayCopiesComeBackWhole() {
        let safari = ["public.rtf", "com.apple.webarchive", "public.utf8-plain-text", "public.utf16-external-plain-text",
                      "public.html", "dyn.ah62d4rv4gu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn"]
        let chrome = ["public.html", "public.utf8-plain-text", "org.chromium.source-url", "org.chromium.web-custom-data"]
        let finder = ["public.file-url", "public.utf8-plain-text", "public.utf16-external-plain-text", "com.apple.icns",
                      "com.apple.finder.node"]
        let photo = ["public.jpeg", "public.tiff", "com.apple.pasteboard.promised-file-url", "NSFilePromiseItemMetaData"]
        let marked = ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]
        for types in [safari, chrome, finder, photo, marked] {
            #expect(ClipboardPolicy.keepsWhole(types), "\(types)")
        }
        // Chromium's own data for Google Docs and VS Code is kept, not dropped
        #expect(ClipboardPolicy.typesToKeep(chrome).contains("org.chromium.web-custom-data"))
        // a later item's picture is the file's icon when its URL is kept
        #expect(ClipboardPolicy.keepsWhole(["public.file-url", "public.tiff"], itemIndex: 2))
    }

    @Test func privateFormatsNextToTextDoNotComeBackWhole() {
        // input-6: Excel cells with formulas, Numbers tables, Keynote shapes, a PDF next to its text
        let excel = ["com.microsoft.Excel.sheet.binary.12", "public.html", "public.rtf", "public.utf16-plain-text",
                     "com.adobe.pdf", "public.tiff"]
        let numbers = ["com.apple.iWork.TSPNativeData", "com.apple.iWork.TSPNativeMetadata", "public.utf8-plain-text",
                       "public.html"]
        for types in [excel, numbers, ["public.utf8-plain-text", "com.adobe.pdf"], ["public.vcard", "public.utf8-plain-text"]] {
            #expect(!ClipboardPolicy.keepsWhole(types), "\(types)")
        }
        // nothing kept but a picture: a second format of it is not a stand-in for something else
        #expect(!ClipboardPolicy.keepsWhole(["public.png", "com.apple.pasteboard.promised-file-url"], itemIndex: 1))
    }

    @Test func remoteDesktopsKeepTheDictation() {
        #expect(ClipboardPolicy.restoreDelay(bundleID: "com.microsoft.rdc.macos") == nil)
        #expect(ClipboardPolicy.restoreDelay(bundleID: "com.parallels.desktop.console") == nil)
        #expect(ClipboardPolicy.restoreDelay(bundleID: "com.apple.Notes") == ClipboardPolicy.restoreDelay)
        #expect(ClipboardPolicy.restoreDelay(bundleID: nil) == ClipboardPolicy.restoreDelay)
        #expect(ClipboardPolicy.restoreDelay >= 1.5)
    }

    @Test func textKinds() {
        #expect(ClipboardPolicy.isPlainText("public.utf8-plain-text"))
        #expect(ClipboardPolicy.isRichText("public.rtf") && ClipboardPolicy.isRichText("public.html"))
        #expect(!ClipboardPolicy.isRichText("public.png"))
        #expect(ClipboardPolicy.isImage("public.png") && !ClipboardPolicy.isImage("public.rtf"))
    }
}

/// A fake clipboard for `ClipboardPolicy.snapshot`: each item maps its types to a data size (nil:
/// not available), and every read is logged, like a source app asked to render that type.
private final class Source {
    let items: [[(String, Int?)]]
    var reads: [String] = []

    init(_ items: [[(String, Int?)]]) { self.items = items }

    /// Limits small enough for tests: 100 bytes a type, 150 in all, long text above 10.
    func snapshot() -> [[ClipEntry]]? {
        ClipboardPolicy.snapshot(itemTypes: items.map { $0.map(\.0) }, maxTypeBytes: 100, maxTotalBytes: 150,
                                 longTextBytes: 10) { index, type in
            self.reads.append(type)
            return self.items[index].first { $0.0 == type }?.1.map { Data(repeating: 1, count: $0) }
        }
    }
}

@Suite struct ClipboardSnapshotTests {
    let text = "public.utf8-plain-text", utf16 = "public.utf16-external-plain-text", rtf = "public.rtf",
        html = "public.html", png = "public.png", fileURL = "public.file-url"

    @Test func keepsAShortCopyWhole() {
        let s = Source([[(text, 5), (utf16, 10), (html, 30), (rtf, 20), (png, 40), ("com.apple.webarchive", 50)]])
        let kept = s.snapshot()
        #expect(kept?.count == 1)
        #expect(kept?.first?.map(\.type) == [text, utf16, rtf, html, png])
        #expect(kept?.first?.first == ClipEntry(type: text, data: Data(repeating: 1, count: 5)))
        #expect(!s.reads.contains("com.apple.webarchive"))
    }

    @Test func emptyClipboardIsEmptyNotLost() {
        #expect(Source([]).snapshot() == [])
        #expect(Source([[]]).snapshot() == [])
    }

    @Test func onlyPrivateFormatsCannotBeKept() {
        // a Figma frame, a PDF or a contact card: nothing could be put back, so the restore must not
        // empty the clipboard; nothing is read either
        for types in [["com.figma.clipboard", "NSFilePromiseItemMetaData"], ["com.adobe.pdf"], ["public.vcard"]] {
            let s = Source([types.map { ($0, 10) }])
            #expect(s.snapshot() == nil)
            #expect(s.reads.isEmpty)
        }
        // a marker alone does not make it keepable
        #expect(Source([[("org.nspasteboard.source", 1), ("com.figma.clipboard", 10)]]).snapshot() == nil)
    }

    @Test func markersAloneAreKept() {
        let kept = Source([[("org.nspasteboard.ConcealedType", 0)]]).snapshot()
        #expect(kept?.first?.map(\.type) == ["org.nspasteboard.ConcealedType"])
    }

    @Test func hugeTextStopsAtTheFirstRead() {
        // a whole plain-text file: its text is over the limit, so nothing else is asked for
        let s = Source([[(text, 120), (utf16, 240), (rtf, 300), (html, 300), (png, 90)]])
        #expect(s.snapshot() == nil)
        #expect(s.reads == [text])
    }

    @Test func aPrivateFormatNextToTheTextIsNotRestoredAndNothingIsRead() {
        // input-6: putting back only the text of Excel cells would lose their formulas; Excel is
        // not even asked to render anything
        let s = Source([[("com.microsoft.Excel.sheet", 10), (text, 5), (html, 30), (rtf, 20)]])
        #expect(s.snapshot() == nil)
        #expect(s.reads.isEmpty)
        // one such item spoils the whole clipboard
        let two = Source([[(text, 5)], [(text, 5), ("com.apple.iWork.TSPNativeData", 10)]])
        #expect(two.snapshot() == nil)
        #expect(two.reads.isEmpty)
    }

    @Test func renditionsAreNotReadButDoNotSpoilTheCopy() {
        let s = Source([[(text, 5), (html, 10), ("org.chromium.source-url", 3), ("org.chromium.web-custom-data", 8),
                         ("dyn.ah62d4rv4gu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn", 5)]])
        #expect(s.snapshot()?.first?.map(\.type) == [text, html, "org.chromium.web-custom-data"])
        #expect(!s.reads.contains("org.chromium.source-url"))
    }

    @Test func longTextKeepsOnePlainCopyOnly() {
        // RTF, HTML and pictures of a long text are bigger still: not read, the text is put back
        let s = Source([[(text, 50), (utf16, 100), (rtf, 90), (html, 90), (png, 90)]])
        #expect(s.snapshot()?.first?.map(\.type) == [text])
        #expect(s.reads == [text])
    }

    @Test func unreadableFirstTextFallsBackToTheNext() {
        let s = Source([[(text, nil), (utf16, 50), (rtf, 30)]])
        #expect(s.snapshot()?.first?.map(\.type) == [utf16])
    }

    @Test func oversizeImageCannotBeKept() {
        // a big screenshot: putting back only its file URL would lose the picture
        #expect(Source([[(fileURL, 5), (png, 101)]]).snapshot() == nil)
    }

    @Test func tooMuchInAllCannotBeKept() {
        let s = Source([[(text, 5), (rtf, 70), (html, 80), (png, 10)]])
        #expect(s.snapshot() == nil)
        #expect(!s.reads.contains(png))
    }

    @Test func unavailableContentCannotBeKept() {
        #expect(Source([[(text, nil)]]).snapshot() == nil)
    }

    @Test func everyItemMustKeepSomething() {
        // several copied files: each keeps its URL, a picture only for the first
        let files = Source([[(fileURL, 5), ("public.tiff", 20)], [(fileURL, 5), ("public.tiff", 20)]])
        #expect(files.snapshot()?.map { $0.map(\.type) } == [[fileURL, "public.tiff"], [fileURL]])
        // several copied pictures: only the first could be kept, so none is put back
        #expect(Source([[(png, 10)], [(png, 10)]]).snapshot() == nil)
    }
}

/// A fake pasteboard: every write bumps the change count, like NSPasteboard.
private struct Board {
    var changeCount = 0
    var contents = "user's own"
    var restore = PendingRestore<String>()

    /// What `TextInserter.paste` does with restore on; returns the timer token.
    mutating func paste(_ text: String) -> Int {
        if restore.needsSnapshot(changeCount: changeCount) { restore.keep(contents) }
        write(text)
        return restore.wrote(changeCount: changeCount)
    }

    mutating func write(_ text: String) {
        contents = text
        changeCount += 1
    }

    mutating func fire(_ token: Int) {
        if let old = restore.due(token: token, changeCount: changeCount) { write(old) }
    }
}

@Suite struct PendingRestoreTests {
    @Test func restoresAfterOnePaste() {
        var b = Board()
        let t = b.paste("A")
        b.fire(t)
        #expect(b.contents == "user's own")
        #expect(b.restore.snapshot == nil)
    }

    @Test func twoPastesInARowKeepTheUsersClipboard() {
        // input-11: the second paste must not snapshot the first dictation
        var b = Board()
        let first = b.paste("A")
        let second = b.paste("B")
        b.fire(first)                                 // superseded: does nothing
        #expect(b.contents == "B")
        b.fire(second)
        #expect(b.contents == "user's own")
    }

    @Test func somethingCopiedMeanwhileIsKept() {
        // input-5: never overwrite what someone else put on the clipboard
        var b = Board()
        let t = b.paste("A")
        b.write("copied by the user")
        b.fire(t)
        #expect(b.contents == "copied by the user")
    }

    @Test func userCopyBetweenPastesBecomesTheNewOriginal() {
        var b = Board()
        let first = b.paste("A")
        b.write("new copy")
        let second = b.paste("B")
        b.fire(first)
        b.fire(second)
        #expect(b.contents == "new copy")
    }

    @Test func reusesOnlyWhileOurTextIsThere() {
        var b = Board()
        #expect(!b.restore.reuses(changeCount: b.changeCount))
        _ = b.paste("A")
        #expect(b.restore.reuses(changeCount: b.changeCount))
        #expect(b.restore.reuses(changeCount: b.changeCount))        // asking changes nothing
        b.write("copied by the user")
        #expect(!b.restore.reuses(changeCount: b.changeCount))
        #expect(b.restore.snapshot == "user's own")
    }

    @Test func cancelLeavesTheDictation() {
        var b = Board()
        let t = b.paste("A")
        b.restore.cancel()                            // left on the clipboard for the user
        b.fire(t)
        #expect(b.contents == "A")
    }
}

@Suite struct PasteKeyTests {
    static let qwerty: [UInt16: String] = [0: "a", 9: "v", 47: ".", 8: "c"]
    static let dvorak: [UInt16: String] = [0: "a", 9: "k", 47: "v", 8: "j"]

    @Test func qwertyUsesNine() {
        #expect(PasteKey.keyCode { Self.qwerty[$0] } == 9)
    }

    @Test func dvorakFindsTheVKey() {
        // input-14: on Dvorak key 9 types "k" and ⌘K would not paste
        #expect(PasteKey.keyCode { Self.dvorak[$0] } == 47)
        #expect(PasteKey.keyCode { $0 == 30 ? "V" : nil } == 30)
    }

    @Test func unreadableLayoutFallsBackToNine() {
        #expect(PasteKey.keyCode { _ in nil } == 9)
        #expect(PasteKey.keyCode { _ in "ж" } == 9)
    }
}
