import Foundation
import Security
import Testing
@testable import NeolessCloud

/// The pairing store with secrets in memory and a throwaway defaults suite. The real Keychain is not
/// touched by tests (it is the user's login keychain); only the queries sent to it are checked.
@Suite struct HubPairingStoreTests {
    private func withStore(_ body: (HubPairingStore, MemorySecretStore, UserDefaults) throws -> Void) throws {
        try withTestDefaults { defaults in
            let secrets = MemorySecretStore()
            try body(HubPairingStore(defaults: defaults, secrets: secrets), secrets, defaults)
        }
    }

    @Test func saveLoadAndClear() throws {
        try withStore { store, secrets, defaults in
            #expect(try store.load() == nil)
            let pairing = try HubPairing(server: URL(string: "https://hub.example.com")!, token: HubToken.generate(), name: "iPhone")
            try store.save(pairing)
            #expect(try store.load() == pairing)
            // The server and the token are kept together in the Keychain.
            let stored = try HubJSON.decode(HubPairingStore.Stored.self,
                                            from: Data(try #require(try secrets.read(HubPairingStore.tokenAccount)).utf8))
            #expect(stored.server == "https://hub.example.com" && stored.token == pairing.token)
            // The token never lands in UserDefaults.
            #expect(defaults.dictionaryRepresentation().values.compactMap { $0 as? String }.allSatisfy { $0 != pairing.token })
            #expect(defaults.string(forKey: HubPairingStore.serverKey) == "https://hub.example.com")
            #expect(try store.client().server == pairing.server)

            try store.clear()
            #expect(try store.load() == nil && store.server == nil)
            #expect(try secrets.read(HubPairingStore.tokenAccount) == nil)
        }
    }

    @Test func halfAPairingIsNoPairing() throws {
        try withStore { store, secrets, defaults in
            defaults.set("https://hub.example.com", forKey: HubPairingStore.serverKey)
            #expect(try store.load() == nil)
            #expect(store.server?.absoluteString == "https://hub.example.com")
            try secrets.write("not a token!", for: HubPairingStore.tokenAccount)
            #expect(try store.load() == nil)
            defaults.removeObject(forKey: HubPairingStore.serverKey)
            try secrets.write(HubToken.generate(), for: HubPairingStore.tokenAccount)
            #expect(try store.load() == nil)
        }
    }

    @Test func rewritingTheServerSettingDoesNotMoveTheToken() throws {
        try withStore { store, _, defaults in
            let pairing = try HubPairing(server: URL(string: "https://hub.example.com")!, token: HubToken.generate(), name: "Mac")
            try store.save(pairing)
            // Any process of this user can rewrite the defaults (`defaults write … hubServer …`): the token still
            // goes only to the server it was paired with.
            defaults.set("https://evil.example", forKey: HubPairingStore.serverKey)
            #expect(try store.load()?.server.absoluteString == "https://hub.example.com")
            #expect(try store.client().server.absoluteString == "https://hub.example.com")
        }
    }

    @Test func keychainQueries() {
        let mac = KeychainStore()
        let query = mac.query("device-token")
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        // A test run is not a neoless app bundle: the service of the source's own identifier.
        #expect(query[kSecAttrService as String] as? String == "app.neoless.hub")
        #expect(query[kSecAttrAccount as String] as? String == "device-token")
        #expect(query[kSecAttrAccessGroup as String] == nil)
        let attributes = mac.attributes("abc")
        #expect(attributes[kSecValueData as String] as? Data == Data("abc".utf8))
        // The Mac's login keychain takes no data-protection class.
        #expect(attributes[kSecAttrAccessible as String] == nil)

        let phone = KeychainStore(accessGroup: "ABCDE12345.app.neoless")
        #expect(phone.query("device-token")[kSecAttrAccessGroup as String] as? String == "ABCDE12345.app.neoless")
    }

    /// The Keychain service follows the app's bundle identifier, so a build that keeps an installed app's
    /// identifier (scripts/build-app.sh) keeps its pairing too; anything that is not a neoless app gets the default.
    @Test func keychainServiceFollowsTheAppsIdentifier() {
        #expect(Hub.bundleID == "app.neoless")
        #expect(Hub.keychainService(bundleID: Hub.bundleID) == "app.neoless.hub")
        #expect(Hub.keychainService(bundleID: "org.example.neoless") == "org.example.neoless.hub")
        for other in [nil, "", "com.apple.dt.xctest.tool", "org.example.neoless-hub", "neoless"] as [String?] {
            #expect(Hub.keychainService(bundleID: other) == "app.neoless.hub", "\(other ?? "nil")")
        }
        #expect(Hub.keychainService == Hub.keychainService(bundleID: Bundle.main.bundleIdentifier))
        #expect(Hub.appGroup == "group.app.neoless")
    }

    @Test func unreadableKeychainIsNotUnpaired() throws {
        struct Locked: SecretStore {
            func read(_ account: String) throws -> String? { throw KeychainError.status(errSecInteractionNotAllowed) }
            func write(_ value: String, for account: String) throws {}
            func delete(_ account: String) throws {}
        }
        try withTestDefaults { defaults in
            defaults.set("https://hub.example.com", forKey: HubPairingStore.serverKey)
            let store = HubPairingStore(defaults: defaults, secrets: Locked())
            #expect(throws: KeychainError.status(errSecInteractionNotAllowed)) { try store.load() }
            #expect(throws: KeychainError.self) { try store.client() }
        }
    }

    @Test func keychainErrorsAreChinese() {
        #expect(KeychainError.status(-25300).errorDescription == "钥匙串出错（-25300）")
    }
}
