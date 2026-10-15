import Foundation
import NeolessCloud
import NeolessCore

/// The hub's own settings (settings.json in the data folder). Devices send their mode with every dictation;
/// these are what only the Neo decides: how it polishes, and how it is reached.
public struct HubConfig: Codable, Equatable, Sendable {
    /// What `GET /v1/sync` tells devices to use while they cannot reach the hub.
    public var autoStructured: Bool
    /// The model and 快速模式 for a request that does not name its own (`polishOptions(model:fastTier:)`).
    public var model: String
    public var fastTier: Bool
    /// The floor of the length-scaled polish budget (`PolishTimeout.seconds`), as the app's 整理超时.
    public var polishTimeout: Double
    /// 双重锁, checked on the hub too: every request but `/v1/ping` must carry the `Cf-Access-Jwt-Assertion` that
    /// Cloudflare Access adds to what it lets through, or it is refused (403 `access_required`). Only whether it is
    /// there is checked, not its signature: it catches Access in front of the hub being switched off or set up
    /// wrong, it is not a lock of its own. Off by default (`neoless-hub access require on`).
    public var requireAccess: Bool
    /// The address devices reach this hub at (the tunnel's hostname, "https://hub.example.com"): what pairing links
    /// carry. Nil until `neoless-hub server <地址>` or `pair --server <地址>` gave one; the hub itself only listens
    /// on 127.0.0.1 and cannot know it.
    public var server: String?

    public init(autoStructured: Bool = true, model: String = PolishOptions.defaultModel, fastTier: Bool = true,
                polishTimeout: Double = HubTimeouts.standard.hubPolishFloor, requireAccess: Bool = false,
                server: String? = nil) {
        self.autoStructured = autoStructured; self.model = model
        self.fastTier = fastTier; self.polishTimeout = polishTimeout; self.requireAccess = requireAccess
        self.server = server
    }

    public var polishOptions: PolishOptions {
        let floor = min(max(polishTimeout, PolishTimeout.settingRange.lowerBound), PolishTimeout.settingRange.upperBound)
        return PolishOptions(model: model.isEmpty ? PolishOptions.defaultModel : model, fastTier: fastTier, minimumTimeout: floor)
    }

    /// What one device's request polishes with: the model it asked for when that is one of `PolishModel.all` (an
    /// unknown name, from a newer or a broken device, is not sent to ChatGPT), its 快速模式 when it said; the hub's
    /// own `polishOptions` for whatever it left out. The time limit is always the hub's.
    public func polishOptions(model asked: String?, fastTier askedFast: Bool?) -> PolishOptions {
        var options = polishOptions
        if let asked, PolishModel.isKnown(asked) { options.model = asked }
        if let askedFast { options.fastTier = askedFast }
        return options
    }

    public var settings: HubSettings { HubSettings(autoStructured: autoStructured) }

    // Every key is optional and unknown ones are skipped, so a file from an older or newer hub still reads.
    private enum CodingKeys: String, CodingKey {
        case autoStructured, model, fastTier, polishTimeout, requireAccess, server
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = HubConfig()
        autoStructured = (try? c.decodeIfPresent(Bool.self, forKey: .autoStructured)) ?? base.autoStructured
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? base.model
        fastTier = (try? c.decodeIfPresent(Bool.self, forKey: .fastTier)) ?? base.fastTier
        polishTimeout = (try? c.decodeIfPresent(Double.self, forKey: .polishTimeout)) ?? base.polishTimeout
        requireAccess = (try? c.decodeIfPresent(Bool.self, forKey: .requireAccess)) ?? base.requireAccess
        server = (try? c.decodeIfPresent(String.self, forKey: .server)) ?? base.server
    }
}
