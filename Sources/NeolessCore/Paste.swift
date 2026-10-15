import Foundation

/// The app a dictation belongs to: the frontmost app when recording stopped.
public struct PasteTarget: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String?
    public var name: String?

    public init(pid: Int32, bundleID: String?, name: String?) {
        self.pid = pid; self.bundleID = bundleID; self.name = name
    }
}

/// What has keyboard focus in the target app, as read through Accessibility.
public enum FocusedField: Equatable, Sendable {
    /// A text field, text area, combo box or rich-text editor.
    case editable
    /// A password field (AXSecureTextField or protected content).
    case secure
    /// The app answered and a control that takes no text has focus (a file list, a button, a link…).
    case notEditable
    /// No answer, nothing focused, or an element we cannot judge (Electron apps often expose
    /// nothing, custom editors, spreadsheet cells): treated as pasteable. "Nothing focused" stays
    /// here on purpose: terminals and editors without accessibility (Alacritty, kitty, Emacs) answer
    /// exactly that and still take ⌘V.
    case unknown

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    /// Controls that never take typed text. Left out on purpose, so they stay pasteable: tables,
    /// cells, groups and scroll areas (spreadsheets, custom editors), web areas outside browsers
    /// (Electron apps without an accessibility tree) and windows (such apps may report the window
    /// itself).
    static let nonTextRoles: Set<String> = [
        "AXList", "AXOutline", "AXBrowser", "AXImage", "AXButton", "AXCheckBox", "AXRadioButton",
        "AXRadioGroup", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle", "AXSlider",
        "AXIncrementor", "AXScrollBar", "AXSplitter", "AXLink", "AXStaticText", "AXToolbar",
        "AXTabGroup", "AXMenuBar", "AXMenu", "AXMenuItem", "AXMenuBarItem", "AXColorWell",
        "AXValueIndicator", "AXProgressIndicator", "AXBusyIndicator", "AXLevelIndicator",
        "AXRelevanceIndicator", "AXDockItem",
    ]

    /// Judges the focused element from its attributes. `inBrowser`: the app is a web browser
    /// (`isBrowser`), whose pages always have an accessibility tree.
    public static func classify(role: String?, subrole: String?, isProtected: Bool = false,
                                hasEditableAncestor: Bool = false, isValueSettable: Bool = false,
                                inBrowser: Bool = false) -> FocusedField {
        if isProtected || subrole?.range(of: "secure", options: .caseInsensitive) != nil { return .secure }
        guard let role else { return .unknown }
        if textRoles.contains(role) || hasEditableAncestor { return .editable }
        if nonTextRoles.contains(role) { return .notEditable }
        if isValueSettable { return .editable }
        // The page itself has focus (a click on an article): nothing there takes text. An editable
        // document (Google Docs' editing frame) is its own editable ancestor, so it never gets here.
        if inBrowser, role == "AXWebArea" { return .notEditable }
        return .unknown
    }

    static let browserBundles: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.beta",
        "com.google.Chrome.dev", "com.google.Chrome.canary", "org.chromium.Chromium", "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "company.thebrowser.Browser",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition", "app.zen-browser.zen", "com.kagi.kagimacOS",
    ]

    /// Whether the app is a web browser (not an Electron app, which may expose a bare web area).
    public static func isBrowser(bundleID: String?) -> Bool {
        bundleID.map(browserBundles.contains) ?? false
    }
}

/// Whether the focused element when pasting is the one that had focus when recording stopped.
public enum FieldMatch: Equatable, Sendable {
    /// Not read on one side (no answer, nothing focused): nothing to compare.
    case unknown
    /// The same element, or one inside the other (an app that built its accessibility tree late
    /// reports the page first and the field later).
    case same
    /// Another element: the user moved to another field, chat or window of the same app.
    case moved
}

/// How one dictation reached (or did not reach) the user. Everything except `.pasted`, `.ownApp`
/// and `.notInserted` leaves the text on the clipboard for a manual ⌘V.
public enum InsertResult: Equatable, Sendable, CaseIterable {
    /// ⌘V was sent into the app the recording stopped in.
    case pasted
    /// neoless itself was frontmost: nothing sent, the result is on the home page.
    case ownApp
    /// Another app is frontmost now than when the recording stopped, or another app's panel
    /// (Spotlight, a launcher) has keyboard focus: copied, not pasted.
    case copiedAppChanged
    /// The same app, but keyboard focus moved to another field, chat or window since the recording
    /// stopped: copied, not pasted.
    case copiedFieldChanged
    /// The app answered Accessibility and nothing editable has focus: copied, not pasted.
    case copiedNoField
    /// Secure input is on (some app holds it) but the focused field is not a password field:
    /// copied, not pasted.
    case copiedSecureInput
    /// No Accessibility permission, so ⌘V cannot be sent: copied.
    case copiedNoAccessibility
    /// The focused field is a real password field: nothing pasted, nothing copied (history only).
    case notInserted
    /// ⌘V was sent, but the user's clipboard could not be kept whole to put back (a private app
    /// format such as Excel cells, or too big): the dictation stays on it. Never from `decide`.
    case pastedKeptOnClipboard

    /// Whether the text is on the clipboard for the user afterwards.
    public var isCopied: Bool {
        switch self {
        case .copiedAppChanged, .copiedFieldChanged, .copiedNoField, .copiedSecureInput, .copiedNoAccessibility,
             .pastedKeptOnClipboard: return true
        case .pasted, .ownApp, .notInserted: return false
        }
    }

    public var delivery: Delivery {
        switch self {
        case .pasted, .pastedKeptOnClipboard: return .pasted
        case .ownApp: return .inApp
        case .notInserted: return .notInserted
        case .copiedAppChanged, .copiedFieldChanged, .copiedNoField, .copiedSecureInput, .copiedNoAccessibility:
            return .copied
        }
    }

    /// The short pill message.
    public var message: String {
        switch self {
        case .pasted: return "已输入"
        case .pastedKeptOnClipboard: return "已输入，剪贴板未恢复"
        case .ownApp: return "没有输入，结果在窗口里"
        case .copiedAppChanged: return "已复制（应用已切换），⌘V 粘贴"
        case .copiedFieldChanged: return "已复制（输入框已切换），⌘V 粘贴"
        case .copiedNoField, .copiedSecureInput, .copiedNoAccessibility: return "已复制，按 ⌘V 粘贴"
        case .notInserted: return "密码框里不输入，结果在 neoless"
        }
    }

    /// Why it was not pasted (or what else happened), in plain words for the main window and
    /// history; nil when all went as usual.
    public var detail: String? {
        switch self {
        case .pasted, .ownApp: return nil
        case .pastedKeptOnClipboard: return "原来的剪贴板放不回去，现在是这次的文字"
        case .copiedAppChanged: return "说完后换了应用，所以只复制了"
        case .copiedFieldChanged: return "说完后换了输入框，所以只复制了"
        case .copiedNoField: return "没找到输入框，只复制了"
        case .copiedSecureInput: return "有应用开着“安全键盘输入”，只复制了"
        case .copiedNoAccessibility: return "没有辅助功能权限，只复制了"
        case .notInserted: return "光标在密码框里，没有输入也没有复制"
        }
    }
}

/// Decides how to deliver a dictation. Pure; the app gathers the facts.
public enum InsertPolicy {
    /// - target: the pid of the app the recording stopped in, nil when unknown (no check).
    /// - frontmost: the pid of the frontmost app now.
    /// - secureInput: `IsSecureEventInputEnabled()` (session-wide, any app can hold it).
    /// - focus: the focused element of the app that has keyboard focus.
    /// - targetFocusOwner: the app that had keyboard focus when the recording stopped (nil: unknown,
    ///   then `target`). ⌘V goes to the keyboard focus, and a non-activating panel of another app
    ///   (Spotlight, Raycast, Alfred) takes it without becoming frontmost.
    /// - focusOwner: the app that has keyboard focus now, nil when unknown (no check).
    /// - field: whether the focused element is still the one from when the recording stopped.
    /// Returns `.pasted` when ⌘V should be sent.
    public static func decide(target: Int32?, frontmost: Int32?, ownPID: Int32, accessibility: Bool,
                              secureInput: Bool, focus: FocusedField, targetFocusOwner: Int32? = nil,
                              focusOwner: Int32? = nil, field: FieldMatch = .unknown) -> InsertResult {
        guard let frontmost else { return target == nil ? .copiedNoField : .copiedAppChanged }
        if let target, target != frontmost { return .copiedAppChanged }
        if frontmost == ownPID { return .ownApp }
        guard accessibility else { return .copiedNoAccessibility }
        if let expected = targetFocusOwner ?? target, let focusOwner, focusOwner != expected { return .copiedAppChanged }
        if field == .moved { return .copiedFieldChanged }
        if focus == .secure { return .notInserted }
        if secureInput { return .copiedSecureInput }
        if focus == .notEditable { return .copiedNoField }
        return .pasted
    }
}

/// One clipboard type kept to be put back after a paste.
public struct ClipEntry: Equatable, Sendable {
    public var type: String
    public var data: Data

    public init(type: String, data: Data) {
        self.type = type; self.data = data
    }
}

/// What to keep of the user's clipboard while a dictation borrows it, and when to put it back.
public enum ClipboardPolicy {
    /// Wait this long after ⌘V before putting the old clipboard back.
    public static let restoreDelay: TimeInterval = 1.5
    /// A clipboard type larger than this cannot be kept.
    public static let maxTypeBytes = 16 << 20
    /// More than this in all cannot be kept.
    public static let maxTotalBytes = 32 << 20
    /// Above this much plain text, only one plain-text copy is read: no second text encoding and no
    /// rich-text (RTF, HTML) or picture copies, which are renditions of the same text, bigger still
    /// and often rendered on demand by the source app.
    public static let longTextBytes = 1 << 20

    static let textTypes = ["public.utf8-plain-text", "public.utf16-external-plain-text", "public.utf16-plain-text"]
    static let urlTypes = ["public.file-url", "public.url", "public.url-name"]
    static let richTypes = ["public.rtf", "public.html", "com.apple.flat-rtfd"]
    /// What a web page or a Chromium/Electron app put there for itself (Google Docs and Sheets,
    /// VS Code): written at copy time, so reading it is cheap.
    static let webDataTypes = ["org.chromium.web-custom-data"]
    static let imageTypes = ["public.png", "public.tiff", "public.jpeg"]
    /// Marker types from nspasteboard.org (password managers, clipboard tools): tiny, keep them.
    static let markerTypes = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                              "org.nspasteboard.AutoGeneratedType", "org.nspasteboard.source"]
    /// Other copies of what the kept types already hold, or notes about it: the old text
    /// encoding, Safari's web archive of the same HTML, Finder's icon and reference for a file
    /// whose URL is kept, a browser's note of the page it came from. Not kept, and losing them
    /// loses nothing. Legacy pasteboard names (`dyn.…`) count too.
    static let renditionTypes: Set<String> = [
        "com.apple.traditional-mac-plain-text", "com.apple.webarchive", "com.apple.icns", "com.apple.finder.node",
        "org.chromium.source-url", "org.chromium.internal.source-rfh-token", "org.chromium.chromium-renderer-taint",
    ]
    /// A file the source app promises to write on paste (Photos, Mail): the picture or URL kept
    /// next to it is the same thing.
    static let promiseTypes: Set<String> = [
        "com.apple.pasteboard.promised-file-url", "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-suggested-file-name", "NSFilePromiseItemMetaData",
        "com.apple.NSFilePromiseItemMetaData",
    ]

    /// The types of one clipboard item worth keeping, cheap ones first. Private app formats,
    /// file promises and dynamic types are skipped (reading them can make the source app render
    /// everything). One image format at most (PNG first), and only for the first item, so a big
    /// screenshot or many copied files stay cheap.
    public static func typesToKeep(_ types: [String], itemIndex: Int = 0) -> [String] {
        let present = Set(types)
        var kept = [markerTypes, textTypes, urlTypes, richTypes, webDataTypes].flatMap { $0.filter(present.contains) }
        if itemIndex == 0, let image = imageTypes.first(where: present.contains) { kept.append(image) }
        return kept
    }

    /// Whether putting back `typesToKeep` gives this item back whole: every other type is a marker
    /// or another copy of what is kept (`renditionTypes`, `dyn.…`; another picture format or a
    /// promised file once something is kept). False for a private app format (Excel or Numbers
    /// cells with their formulas, Keynote shapes), a PDF or a contact card: putting back only the
    /// text, HTML or picture next to it would quietly change what the user pastes later.
    public static func keepsWhole(_ types: [String], itemIndex: Int = 0) -> Bool {
        let kept = Set(typesToKeep(types, itemIndex: itemIndex))
        let keepsContent = kept.contains(where: isContent)
        return types.allSatisfy { type in
            kept.contains(type) || !isContent(type) || renditionTypes.contains(type) || type.hasPrefix("dyn.")
                || (keepsContent && (isImage(type) || promiseTypes.contains(type)))
        }
    }

    public static func isRichText(_ type: String) -> Bool { richTypes.contains(type) }
    public static func isPlainText(_ type: String) -> Bool { textTypes.contains(type) }
    public static func isImage(_ type: String) -> Bool { imageTypes.contains(type) }
    /// Anything but an nspasteboard.org marker.
    static func isContent(_ type: String) -> Bool { !markerTypes.contains(type) }

    /// A copy of the clipboard to put back after a paste, or nil when it cannot be kept whole: an
    /// item holds something that would not come back (`keepsWhole`: a private app format, a PDF, a
    /// contact card, a second picture…) or something worth keeping is over the size limits. Then the
    /// dictation is left on the clipboard and the user is told (`InsertResult.pastedKeptOnClipboard`):
    /// putting back a partial copy would quietly change what they paste later (cells without their
    /// formulas), or empty the clipboard. An empty clipboard gives `[]`.
    ///
    /// `itemTypes` are the types of each clipboard item. `read(item, type)` reads one type (nil if
    /// it is not available); it can make the source app render that type there and then, so as
    /// little as possible is read: nothing at all when an item cannot come back whole, else the types
    /// `typesToKeep` picks, one plain-text copy of a long text and no renditions of it (see
    /// `longTextBytes`), and nothing more once something is too big.
    public static func snapshot(itemTypes: [[String]], maxTypeBytes: Int = maxTypeBytes,
                                maxTotalBytes: Int = maxTotalBytes, longTextBytes: Int = longTextBytes,
                                read: (_ item: Int, _ type: String) -> Data?) -> [[ClipEntry]]? {
        for (index, types) in itemTypes.enumerated() where !keepsWhole(types, itemIndex: index) { return nil }
        var total = 0
        var items: [[ClipEntry]] = []
        for (index, types) in itemTypes.enumerated() {
            var kept: [ClipEntry] = []
            var longText = false
            for type in typesToKeep(types, itemIndex: index) {
                if longText, isPlainText(type) || isRichText(type) || isImage(type) { continue }
                guard let data = read(index, type) else { continue }
                total += data.count
                guard data.count <= maxTypeBytes, total <= maxTotalBytes else { return nil }
                if isPlainText(type), data.count > longTextBytes { longText = true }
                kept.append(ClipEntry(type: type, data: data))
            }
            if types.contains(where: isContent), !kept.contains(where: { isContent($0.type) }) { return nil }
            if !kept.isEmpty { items.append(kept) }
        }
        return items
    }

    static let noRestoreBundles: Set<String> = [
        "com.microsoft.rdc.macos", "com.microsoft.rdc.mac", "com.microsoft.rdc.osx.beta",
        "com.parallels.desktop.console", "com.vmware.fusion", "com.utmapp.UTM",
        "com.citrix.receiver.icaviewer.mac", "com.citrix.receiver.nomas", "com.teamviewer.TeamViewer",
        "com.realvnc.vncviewer", "com.apple.ScreenSharing", "com.philandro.anydesk", "com.p5sys.jump.mac.viewer",
    ]

    /// How long to wait before restoring the old clipboard after pasting into this app, or nil to
    /// leave the dictation on the clipboard: remote desktops and virtual machines sync the
    /// clipboard late and would paste the old one.
    public static func restoreDelay(bundleID: String?) -> TimeInterval? {
        if let bundleID, noRestoreBundles.contains(bundleID) { return nil }
        return restoreDelay
    }
}

/// The one pending clipboard restore. Two dictations pasted back to back reuse the snapshot of the
/// user's real clipboard taken before the first, so the second never snapshots the first's text.
public struct PendingRestore<Snapshot> {
    public private(set) var snapshot: Snapshot?
    /// The pasteboard changeCount right after our last write.
    private var ours: Int?
    private var generation = 0

    public init() {}

    /// Before writing a dictation for a paste with restore. True: take a fresh snapshot now and
    /// `keep` it (nothing pending, or the user copied something since our last write). False: the
    /// pending snapshot of the user's clipboard is reused.
    public mutating func needsSnapshot(changeCount: Int) -> Bool {
        if reuses(changeCount: changeCount) { return false }
        snapshot = nil
        ours = nil
        return true
    }

    /// Whether a paste now would reuse the pending snapshot (the clipboard still holds our last
    /// write), so there is nothing to read. Changes nothing.
    public func reuses(changeCount: Int) -> Bool {
        snapshot != nil && ours == changeCount
    }

    public mutating func keep(_ snapshot: Snapshot) { self.snapshot = snapshot }

    /// Our text was written and the pasteboard now has `changeCount`. Returns the token the
    /// restore timer passes to `due`.
    public mutating func wrote(changeCount: Int) -> Int {
        ours = changeCount
        generation += 1
        return generation
    }

    /// The restore timer fired. Returns the snapshot to write back, or nil when a newer paste took
    /// over (it restores later) or someone else wrote to the clipboard (keep theirs).
    public mutating func due(token: Int, changeCount: Int) -> Snapshot? {
        guard token == generation else { return nil }
        defer { snapshot = nil; ours = nil }
        return ours == changeCount ? snapshot : nil
    }

    /// Drop any pending restore: the dictation was left on the clipboard for the user.
    public mutating func cancel() {
        snapshot = nil
        ours = nil
        generation += 1
    }
}

/// Which key sends ⌘V.
public enum PasteKey {
    public static let qwertyV: UInt16 = 9

    /// The virtual key code that types "v" with ⌘ held in the current layout (`translate` gives a
    /// key code's character, nil if none), preferring the QWERTY position, falling back to it.
    public static func keyCode(translate: (UInt16) -> String?) -> UInt16 {
        func isV(_ code: UInt16) -> Bool { translate(code)?.lowercased() == "v" }
        if isV(qwertyV) { return qwertyV }
        return (0..<128).map(UInt16.init).first(where: isV) ?? qwertyV
    }
}
