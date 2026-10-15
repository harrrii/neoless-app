import AppKit
import Combine
import Foundation
import NeolessCloud
import NeolessCore

/// 用 Neo 处理: the pairing with the Neo (its token in the login keychain), whether the Neo can be reached, and
/// the client every call goes through. While the Neo answers it recognises and polishes each recording; when it
/// does not, this Mac does the work itself (`DictationController`), so dictation never waits on it for long.
@MainActor
final class HubConnection: ObservableObject {
    struct Message: Equatable {
        let text: String
        let isError: Bool
    }

    private enum Reach: Equatable {
        case unknown
        case connected(HubHealth)
        case unreachable(String)
        case revoked
        /// Cloudflare Access (双重锁) stops this Mac's requests before the Neo.
        case accessDenied
        /// The Neo takes only what came through Cloudflare Access, and this Mac's requests did not.
        case accessRequired
    }

    /// How often the Neo is asked how it is, and how soon again while it cannot be reached.
    static let checkInterval: TimeInterval = 5 * 60
    static let retryInterval: TimeInterval = 60

    @Published private(set) var pairing: HubPairing?
    @Published private var reach: Reach = .unknown {
        didSet {
            // What the Neo says about its speech models, whenever it answers with recognition up. With it down and
            // no model named, the answer may come from a worker that is not running: nothing is learnt from it.
            if case .connected(let health) = reach, health.asr.ready || health.asr.largeModel != nil {
                models = NeoModelNames(large: health.asr.largeModel, small: health.asr.smallModel)
            }
        }
    }
    /// The Neo's large and small speech models as it last named them (`GET /v1/health`), nil until it has answered.
    /// Kept while it is out of reach, so 识别模型 goes on being sent as chosen; forgotten with the pairing.
    @Published private var models: NeoModelNames?
    /// A pairing link that was opened (`neoless://pair?…`), waiting for 配对 in Settings: a link on a web page must
    /// not be able to send this Mac's recordings to another server on its own.
    @Published var pending: HubPairing?
    /// What the last pairing attempt, or reading the Keychain, has to say.
    @Published private(set) var message: Message?
    /// Pairing right now.
    @Published private(set) var busy = false

    /// The Neo became usable: paired, 用 Neo 处理 switched on, or answering again after being out of reach. What
    /// waits for it can go now (`HubSync`).
    var onReady: (() -> Void)?
    /// The pairing was removed, or replaced by one with another Neo: what was kept for the old one goes.
    var onUnpaired: (() -> Void)?

    let settings: AppSettings
    private let store: HubPairingStore
    private let session: URLSession
    /// False for snapshots: no network, no Keychain.
    private let live: Bool
    private(set) var client: HubClient?
    private var checking: Task<Void, Never>?
    private var lastCheck: Date?
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []

    init(settings: AppSettings, store: HubPairingStore = HubPairingStore(), session: URLSession = HubClient.sharedSession) {
        self.settings = settings
        self.store = store
        self.session = session
        live = true
        do {
            pairing = try store.load()
        } catch {
            message = Message(text: Self.describe(error), isError: true)
        }
        client = pairing.map(makeClient)
        // The status depends on the switch too.
        settings.$hubEnabled.dropFirst().sink { [weak self] on in
            self?.objectWillChange.send()
            guard on else { return }
            DispatchQueue.main.async {
                self?.check()
                self?.onReady?()
            }
        }.store(in: &bag)
    }

    /// For `--snapshot`: a fixed state, nothing stored, nothing sent.
    init(preview pairing: HubPairing?, settings: AppSettings) {
        self.settings = settings
        // Never used: nothing is saved in a preview.
        store = HubPairingStore(defaults: .standard, secrets: MemorySecretStore())
        session = HubClient.sharedSession
        live = false
        self.pairing = pairing
    }

    /// Checks now and every few minutes, sooner while the Neo cannot be reached, and after the Mac wakes.
    func start() {
        guard live else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.retryInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // The network takes a moment to come back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                MainActor.assumeIsolated { self?.check() }
            }
        })
        check()
    }

    private func tick() {
        switch reach {
        case .connected: if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.checkInterval { return }
        default: break
        }
        check()
    }

    // MARK: State

    var status: HubStatus {
        guard settings.hubEnabled else { return .off }
        guard pairing != nil else { return .unpaired }
        switch reach {
        case .unknown: return .checking
        case .connected(let health): return .connected(health)
        case .unreachable(let why): return .unreachable(why)
        case .revoked: return .revoked
        case .accessDenied: return .accessDenied
        case .accessRequired: return .accessRequired
        }
    }

    /// 用 Neo 处理 is on and this Mac is paired.
    var isActive: Bool { settings.hubEnabled && pairing != nil }

    /// The client a dictation sends its recording to: nil when the Neo is not in use, no longer takes this Mac, or
    /// Cloudflare Access stops this Mac on the way (checked again every minute, so a fixed policy is seen soon).
    var dictationClient: HubClient? { isActive && reach != .revoked && reach != .accessDenied ? client : nil }

    /// The pairing must be renewed with a new link from the Neo: it refuses the token, or Cloudflare Access refuses
    /// the credentials. Settings then takes a new link while still paired (same Neo).
    var needsNewLink: Bool { isActive && (reach == .revoked || reach == .accessDenied) }

    /// The Neo does the work: it is in use, not known to be out of reach or to refuse this Mac, and it can
    /// recognise (`HubStatus.covers`). This Mac's own ChatGPT login then matters only for the dictations it ends
    /// up doing itself; otherwise it does them all.
    var covers: Bool { status.covers }

    /// What the Neo in use does with 识别模型, as far as it has said: only one that names a large and a small
    /// model is asked for either, and only then can the choice be made in Settings (`NeoModelRow`).
    var modelSupport: NeoModelSupport {
        guard isActive, let models else { return .unknown }
        return models.support
    }

    /// The Neo's speech models by name: its large and small one as it last named them, and the one it would use
    /// now for a recording that leaves the choice to it. That one only while it is connected with recognition up
    /// (otherwise the name is only its default).
    var modelNames: NeoModelNames {
        var current: String?
        if case .connected(let health) = status, health.asr.ready { current = health.asr.model }
        return NeoModelNames(current: current, large: models?.large, small: models?.small)
    }

    /// What a recording asks the Neo for: the choice in Settings, or nothing (自动) on a Neo that would not act
    /// on it (`NeoModelChoice.asked`).
    var askedModel: HubASRModel? { settings.asrModel.asked(of: modelSupport).requested }

    /// 本机识别: a dictation sends this Mac's own transcript to be polished, not the recording to be recognised
    /// (`NeoModelChoice.local`), so the Neo's speech model is not needed and not got ready for it.
    var recognizesHere: Bool { !settings.asrModel.usesNeoRecognition }

    /// Asks the Neo how it is (`GET /v1/health`), unless a check is already on its way.
    func check() {
        guard live, isActive, let client, checking == nil else { return }
        lastCheck = Date()
        checking = Task { [weak self] in
            let result: Result<HubHealth, Error>
            do { result = .success(try await client.health()) } catch { result = .failure(error) }
            guard let self else { return }
            self.checking = nil
            guard self.client === client else { return }
            switch result {
            case .success(let health):
                let back: Bool
                if case .connected = self.reach { back = false } else { back = true }
                self.reach = .connected(health)
                if back { self.onReady?() }
            case .failure(let error):
                if error is CancellationError { return }
                // Only what says the Neo was not reached, or refused this Mac, changes what is known. An answer of
                // its own (429 while this Mac sent a lot, its 500, a slow or garbled answer) says it is there:
                // the last state stays, and the next check asks again.
                switch HubStatus.after(error) {
                case .revoked?: self.reach = .revoked
                case .accessDenied?: self.reach = .accessDenied
                case .accessRequired?: self.reach = .accessRequired
                case .unreachable(let why)?: self.reach = .unreachable(why)
                default: break
                }
            }
        }
    }

    /// A call failed: what that says about the Neo (out of reach, refused this Mac) is kept for the status. A
    /// timeout or an error the Neo answered with says nothing about reaching it.
    func note(_ error: Error, from client: HubClient) {
        guard client === self.client, let next = HubStatus.after(error) else { return }
        switch next {
        case .revoked: reach = .revoked
        case .accessDenied: reach = .accessDenied
        case .accessRequired: reach = .accessRequired
        case .unreachable(let why): reach = .unreachable(why)
        default: break
        }
    }

    /// A call came back from the Neo: when it was thought out of reach, ask how it is now.
    func noteReached(_ client: HubClient) {
        guard client === self.client else { return }
        switch reach {
        case .connected: break
        case .unknown, .unreachable, .revoked, .accessDenied, .accessRequired: check()
        }
    }

    // MARK: Pairing

    /// The name this Mac pairs under when the link or token brings none.
    static var deviceName: String { Host.current().localizedName ?? "Mac" }

    /// 配对 with what was pasted: a `neoless://pair?…` link, or a device token for the address in Settings.
    @discardableResult
    func pair(pasted text: String) async -> Bool {
        // Nil when nothing is typed there: a link brings its own address, a bare token needs one.
        let server = HubPairing.server(from: settings.hubAddress)
        var new: HubPairing
        do {
            new = try HubPairing(pasted: text, server: server, name: Self.deviceName)
        } catch {
            message = Message(text: Self.describe(error), isError: true)
            return false
        }
        // A bare device token for the paired Neo keeps that Neo's Cloudflare Access credentials: they belong to the
        // server, not to the token. A link brings its own (or none).
        let bare = !text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix(HubPairing.scheme + ":")
        if bare, new.access == nil, let pairing, pairing.server == new.server { new.access = pairing.access }
        return await adopt(new)
    }

    /// What a link or token for another Neo gets while paired: the pairing changes only through 断开配对.
    static let anotherNeo = "已经和一台 Neo 配对。要换 Neo，先断开配对"

    /// The app was opened with a pairing link: hold it for 配对 in Settings. While paired, only a link for the
    /// same Neo (a new token after its device was removed there) is held: one for another server is refused.
    func open(_ url: URL) {
        do {
            var link = try HubPairing(url: url)
            if let pairing, pairing.server != link.server {
                pending = nil
                message = Message(text: Self.anotherNeo, isError: true)
                return
            }
            if link.name.isEmpty { link.name = Self.deviceName }
            pending = link
            message = nil
        } catch {
            pending = nil
            message = Message(text: Self.describe(error), isError: true)
        }
    }

    /// What the "和这台 Neo 配对？" row says about a link: where the recordings would go, in full, and to check it.
    /// There is no usual address to compare with: every hub is someone's own.
    static func pendingDetail(_ link: HubPairing) -> String {
        "录音会发到 \(link.server.absoluteString)。确认这是你自己的 Neo 再配对。"
    }

    func confirmPending() async {
        guard let link = pending else { return }
        pending = nil
        await adopt(link)
    }

    /// Checks a pairing with the Neo and keeps it. One the Neo refuses is not kept; one that cannot be checked
    /// now (the Neo is asleep, no network) is kept and checked again later.
    @discardableResult
    func adopt(_ new: HubPairing) async -> Bool {
        guard live, !busy else { return false }
        if let pairing, pairing.server != new.server {
            message = Message(text: Self.anotherNeo, isError: true)
            return false
        }
        busy = true
        defer { busy = false }
        message = nil
        let probe = makeClient(new)
        let checked: Result<HubHealth, Error>
        do { checked = .success(try await probe.health()) } catch { checked = .failure(error) }
        if case .failure(let error) = checked {
            if error is CancellationError { return false }
            if case .revoked? = HubStatus.after(error) {
                message = Message(text: "Neo 不认这个密钥，请在 Neo 上重新生成配对链接", isError: true)
                return false
            }
            // Cloudflare Access stops this link's requests: nothing would ever get through with it.
            if case .accessDenied? = HubStatus.after(error) {
                message = Message(text: Self.accessRefused(new), isError: true)
                return false
            }
        }
        var saved = new
        if case .success(let health) = checked, saved.name.isEmpty || saved.name == Self.deviceName, !health.device.isEmpty {
            saved.name = health.device
        }
        // The Neo this Mac's sync state (outbox, last sync) belongs to: the paired one, or the last one saved when the
        // Keychain could not be read at launch.
        let previous = pairing?.server ?? store.server
        do {
            try store.save(saved)
        } catch {
            message = Message(text: Self.describe(error), isError: true)
            return false
        }
        // Another Neo: none of what was kept is for this one.
        if let previous, previous != saved.server { onUnpaired?() }
        pairing = saved
        client = probe
        settings.hubAddress = saved.server.absoluteString
        lastCheck = Date()
        // Another Neo, or this one again: what it has is what it says now.
        models = nil
        // The rows say the rest: paired under this name, and whether the Neo answers (checked again later).
        switch checked {
        case .success(let health): reach = .connected(health)
        case .failure(let error):
            // Not reached, the Neo's own check of Cloudflare Access (to be fixed there, the link may be fine), or an
            // answer of the Neo's own that says nothing yet (checked again soon).
            switch HubStatus.after(error) {
            case .unreachable(let why)?: reach = .unreachable(why)
            case .accessRequired?: reach = .accessRequired
            default: reach = .unknown
            }
        }
        onReady?()
        return true
    }

    /// Why a link Cloudflare Access turns away is not kept: it has no Access credentials, or not the current ones.
    static func accessRefused(_ link: HubPairing) -> String {
        link.access == nil
            ? "Neo 开了 Cloudflare 门禁，这个链接里没有门禁凭据。在 Neo 上运行 neoless-hub access set，再重新生成配对链接"
            : "Cloudflare 门禁不认这个链接里的凭据。在 Neo 上用 neoless-hub access set 存入现在的凭据，再重新生成配对链接"
    }

    /// What the address field says when its text is not an address.
    static let badAddress = "地址要像 https://hub.example.com 这样"

    /// The address field changed: keep it for pairing with a bare device token. It never moves a pairing (a link
    /// brings its own address, and a slip of the keyboard must not send the recordings, and the token, somewhere
    /// else): the field shows the paired Neo's address and cannot be edited until 断开配对. False (and nothing
    /// kept) when the text is not an https address, or while paired.
    @discardableResult
    func setAddress(_ text: String) -> Bool {
        guard pairing == nil, let server = HubPairing.server(from: text) else { return false }
        settings.hubAddress = server.absoluteString
        return true
    }

    /// 断开配对: forgets the token. The Neo keeps its record of this Mac until it is revoked there.
    func unpair() {
        do {
            try store.clear()
        } catch {
            message = Message(text: Self.describe(error), isError: true)
            return
        }
        pairing = nil
        client = nil
        checking?.cancel()
        checking = nil
        reach = .unknown
        models = nil
        pending = nil
        message = nil
        onUnpaired?()
    }

    // MARK: Helpers

    private func makeClient(_ pairing: HubPairing) -> HubClient {
        HubClient(pairing: pairing, session: session, timeouts: .interactive)
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// `--snapshot` only.
    func _debugSet(pairing: HubPairing?, status: HubStatus, pending: HubPairing? = nil, message: Message? = nil) {
        self.pairing = pairing
        settings.hubEnabled = status != .off
        // Each state on its own: only a connected one says what the Neo has.
        models = nil
        switch status {
        case .connected(let health): reach = .connected(health)
        case .unreachable(let why): reach = .unreachable(why)
        case .revoked: reach = .revoked
        case .accessDenied: reach = .accessDenied
        case .accessRequired: reach = .accessRequired
        default: reach = .unknown
        }
        self.pending = pending
        self.message = message
    }
}

/// The app's version, as the hub's requests carry it.
enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
