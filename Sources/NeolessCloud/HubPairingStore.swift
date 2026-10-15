import Foundation
import Security

/// Small secrets by name: the device token.
public protocol SecretStore: Sendable {
    func read(_ account: String) throws -> String?
    func write(_ value: String, for account: String) throws
    func delete(_ account: String) throws
}

public enum KeychainError: LocalizedError, Equatable, Sendable {
    case status(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .status(let code): return "钥匙串出错（\(code)）"
        }
    }
}

/// The pairing in the Keychain is there but cannot be used as it is.
public enum HubPairingStoreError: LocalizedError, Equatable, Sendable {
    /// The item has Cloudflare Access credentials (双重锁) that do not read back: sending without them would quietly
    /// drop to the device token alone, so nothing is sent until a new pairing link brings them again.
    case accessUnreadable

    public var errorDescription: String? {
        switch self {
        case .accessUnreadable: return "钥匙串里的 Cloudflare 门禁凭据读不出来，请粘贴 Neo 上新生成的配对链接，重新配对"
        }
    }
}

/// Generic passwords in the Keychain (kSecClassGenericPassword), one per account under `service`.
///
/// On the Mac this is the login keychain: the app is signed without entitlements, which the data-protection
/// keychain needs. On iOS it is the data-protection keychain, readable after the first unlock (the keyboard
/// runs while the phone is locked too), shared with the keyboard through `accessGroup`. Items are never synced to
/// iCloud (no kSecAttrSynchronizable, so the default: this device only).
public struct KeychainStore: SecretStore {
    public var service: String
    /// iOS: the keychain access group the app and its keyboard share. nil on the Mac.
    public var accessGroup: String?

    public init(service: String = Hub.keychainService, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    /// The attributes that find the item.
    func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    /// The attributes a new item gets besides `query`.
    func attributes(_ value: String) -> [String: Any] {
        var attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        #if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        return attributes
    }

    public func read(_ account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String, for account: String) throws {
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.status(update) }
        let add = SecItemAdd(query(account).merging(attributes(value)) { $1 } as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainError.status(add) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}

/// Secrets in memory only (tests, previews).
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    public init(_ values: [String: String] = [:]) { self.values = values }

    public func read(_ account: String) throws -> String? { lock.withLock { values[account] } }
    public func write(_ value: String, for account: String) throws { lock.withLock { values[account] = value } }
    public func delete(_ account: String) throws { lock.withLock { values[account] = nil } }
}

/// Where a device keeps its pairing: the server, the token and the Cloudflare Access service token (双重锁, when
/// the pairing has one) together in one Keychain item (JSON `{"server", "token", "access"?: {"clientID",
/// "clientSecret"}}`), so the secrets are only ever handed out with the server they were paired with: rewriting a
/// setting cannot send them somewhere else. The name, and a copy of the server for display, are in UserDefaults
/// (the App Group's suite on iOS, so the keyboard sees them too); no secret ever is.
public final class HubPairingStore: @unchecked Sendable {
    public static let tokenAccount = "device-token"
    public static let serverKey = "hubServer"
    public static let nameKey = "hubDeviceName"

    public let defaults: UserDefaults
    public let secrets: SecretStore

    public init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainStore()) {
        self.defaults = defaults
        self.secrets = secrets
    }

    /// `suiteName`: `Hub.appGroup` on iOS, nil (the app's own defaults) on the Mac.
    public convenience init(suiteName: String?, secrets: SecretStore = KeychainStore()) {
        self.init(defaults: suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard, secrets: secrets)
    }

    /// The Keychain item's value. An item saved before 双重锁 has no `access`.
    struct Stored: Codable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        var server: String
        var token: String
        var access: HubAccess?
        /// The item has an `access` that does not decode (written by hand, cut short, or by a version that checked
        /// less): not the same as none.
        var accessUnreadable = false

        init(server: String, token: String, access: HubAccess?) {
            self.server = server; self.token = token; self.access = access
        }

        private enum CodingKeys: String, CodingKey { case server, token, access }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            server = try c.decode(String.self, forKey: .server)
            token = try c.decode(String.self, forKey: .token)
            // Absent (or null): an item from before 双重锁. There but unreadable: kept as such, never as none.
            if c.contains(.access), try !c.decodeNil(forKey: .access) {
                do {
                    access = try c.decode(HubAccess.self, forKey: .access)
                } catch {
                    access = nil
                    accessUnreadable = true
                }
            } else {
                access = nil
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(server, forKey: .server)
            try c.encode(token, forKey: .token)
            try c.encodeIfPresent(access, forKey: .access)
        }

        // Never the token or the secret, in a log or a debugger's dump.
        var description: String { "HubPairingStore.Stored(\(server))" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: ["server": server], displayStyle: .struct) }
    }

    /// The saved pairing; nil when there is none or it is not valid (a bare token without its server is none).
    /// Throws when the Keychain cannot be read (an iPhone not unlocked since it started): that is not the same as
    /// unpaired. Throws `HubPairingStoreError.accessUnreadable` when the item has Cloudflare Access credentials that
    /// do not read back: a client without them would send every request with the token alone.
    public func load() throws -> HubPairing? {
        guard let value = try secrets.read(Self.tokenAccount),
              let stored = try? HubJSON.decode(Stored.self, from: Data(value.utf8)),
              let server = URL(string: stored.server),
              let pairing = try? HubPairing(server: server, token: stored.token,
                                            name: defaults.string(forKey: Self.nameKey) ?? "", access: stored.access)
        else { return nil }
        if stored.accessUnreadable { throw HubPairingStoreError.accessUnreadable }
        return pairing
    }

    /// Saves the server, the token and the Access credentials in the Keychain, then the name and the server's
    /// display copy.
    public func save(_ pairing: HubPairing) throws {
        let stored = try HubJSON.encode(Stored(server: pairing.server.absoluteString, token: pairing.token,
                                               access: pairing.access))
        try secrets.write(String(decoding: stored, as: UTF8.self), for: Self.tokenAccount)
        defaults.set(pairing.server.absoluteString, forKey: Self.serverKey)
        defaults.set(pairing.name, forKey: Self.nameKey)
    }

    /// Forgets the pairing (unpairing, or the hub revoked this device).
    public func clear() throws {
        defaults.removeObject(forKey: Self.serverKey)
        defaults.removeObject(forKey: Self.nameKey)
        try secrets.delete(Self.tokenAccount)
    }

    /// The saved server's display copy, also when the token is missing (to show it in Settings). Never used to
    /// send anything: `load` takes the server from the Keychain.
    public var server: URL? { defaults.string(forKey: Self.serverKey).flatMap(URL.init(string:)) }

    /// A client for the saved pairing; throws `HubError.notPaired` when there is none, `KeychainError` when the
    /// token cannot be read, `HubPairingStoreError.accessUnreadable` when its Access credentials cannot.
    public func client(session: URLSession = HubClient.sharedSession, timeouts: HubTimeouts = .standard) throws -> HubClient {
        guard let pairing = try load() else { throw HubError.notPaired }
        return HubClient(pairing: pairing, session: session, timeouts: timeouts)
    }
}
