import CoreImage
import Foundation
import NeolessCloud
import NeolessCore
import Testing
@testable import NeolessHubKit

/// `neoless-hub` arguments and the pairing QR code.
@Suite struct HubCommandTests {
    private func parse(_ line: String) throws -> HubCommandLine {
        try HubCommandLine.parse(line.split(separator: " ").map(String.init))
    }

    @Test func commands() throws {
        #expect(try parse("serve").command == .serve(port: 18_800))
        #expect(try parse("serve --port 18860").command == .serve(port: 18_860))
        #expect(try parse("serve --port=18861").command == .serve(port: 18_861))
        // No address of its own: the one remembered in settings.json is used when the command runs.
        #expect(try parse("pair --name iPhone").command == .pair(name: "iPhone", server: nil, qr: nil))
        #expect(try parse("pair --name Mac --server http://127.0.0.1:18800 --qr /tmp/q.png").command
                == .pair(name: "Mac", server: URL(string: "http://127.0.0.1:18800")!, qr: "/tmp/q.png"))
        #expect(try HubCommandLine.parse(["pair", "--name", "小明的 iPhone"]).command
                == .pair(name: "小明的 iPhone", server: nil, qr: nil))
        #expect(try parse("server").command == .server(address: nil))
        #expect(try parse("server https://hub.example.com").command == .server(address: Hub.exampleServer))
        #expect(try parse("devices").command == .devices)
        #expect(try HubCommandLine.parse(["revoke", "旧 iPhone"]).command == .revoke(name: "旧 iPhone"))
        #expect(try parse("login").command == .login)
        #expect(try parse("status --port 18860").command == .status(port: 18_860))
        #expect(try HubCommandLine.parse([]).command == .help)
        #expect(try parse("serve --help").command == .help)

        let custom = try parse("serve --data-dir /tmp/hub --worker http://127.0.0.1:18861")
        #expect(custom.dataDirectory == "/tmp/hub" && custom.workerURL == URL(string: "http://127.0.0.1:18861"))
    }

    @Test func mistakes() {
        for line in ["fly", "serve --port", "serve --port 0", "serve --port abc", "pair", "pair --name", "revoke",
                     "revoke a b", "devices extra", "serve --json", "login --foo", "serve --qr x.png", "serve --worker http://example.com:1",
                     "serve --unknown", "server hub.example.com", "server https://a.example https://b.example",
                     "server --name x"] {
            #expect(throws: HubCommandLine.Failure.self, "\(line)") { try parse(line) }
        }
    }

    @Test func pairingQRCodeScansBackToTheLink() throws {
        let link = try HubPairing(server: Hub.exampleServer, token: HubToken.generate(), name: "小明的 iPhone & Mac").url.absoluteString
        let png = try PairingQR.png(for: link)
        let image = try #require(CIImage(data: png))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let found = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(found == [link])
        #expect(try HubPairing(link: found[0]).name == "小明的 iPhone & Mac")

        let terminal = try PairingQR.terminal(for: link)
        let modules = try PairingQR.modules(for: link)
        #expect(terminal.split(separator: "\n").count == (modules.count + 2 * PairingQR.quietZone + 1) / 2)
    }

    /// `pair` end to end through the command, into a temporary folder.
    @Test @MainActor func pairCommandSavesTheDeviceAndTheCode() async throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let qr = dir.appendingPathComponent("pair.png").path
        let status = try await HubCommands.run(HubCommandLine(command: .pair(name: "iPhone", server: Hub.exampleServer, qr: qr),
                                                              dataDirectory: dir.path))
        #expect(status == 0)
        #expect(FileManager.default.fileExists(atPath: qr))
        let devices = DeviceRegistry(folder: try HubDataFolder.at(dir)).all
        #expect(devices.map(\.name) == ["iPhone"])
        // An http server other than this Mac is refused before anything is saved.
        await #expect(throws: HubProtocolError.badServer) {
            try await HubCommands.run(HubCommandLine(command: .pair(name: "Mac", server: URL(string: "http://example.com")!, qr: nil),
                                                     dataDirectory: dir.path))
        }
        #expect(DeviceRegistry(folder: try HubDataFolder.at(dir)).all.count == 1)
    }

    /// The hub has no address of its own: `pair` needs one once (`--server`, or `server <地址>`), then remembers it.
    @Test @MainActor func pairUsesTheRememberedAddress() async throws {
        let dir = temporaryDirectory()
        defer { removeTemporary(dir) }
        let folder = try HubDataFolder.at(dir)
        func run(_ command: HubCommandLine.Command) async throws -> Int32 {
            try await HubCommands.run(HubCommandLine(command: command, dataDirectory: dir.path))
        }
        // Nothing remembered: no link, no device, and the reason says what to type.
        await #expect(throws: HubSetupError(HubCommands.noServer)) { try await run(.pair(name: "iPhone", server: nil, qr: nil)) }
        #expect(try await run(.server(address: nil)) == 1)
        #expect(DeviceRegistry(folder: folder).all.isEmpty)
        #expect(throws: HubSetupError.self) { try HubCommands.pairingServer(given: nil, folder: folder) }

        // `--server` once: used, normalised and remembered.
        #expect(try await run(.pair(name: "iPhone", server: URL(string: "HTTPS://Hub.Example.com/")!, qr: nil)) == 0)
        #expect(try HubCommands.pairingServer(given: nil, folder: folder) == Hub.exampleServer)
        #expect(try await run(.pair(name: "Mac", server: nil, qr: nil)) == 0)
        #expect(try await run(.server(address: nil)) == 0)
        #expect(DeviceRegistry(folder: folder).all.map(\.name) == ["iPhone", "Mac"])

        // `server <地址>` replaces it; one that is not https is refused and changes nothing.
        let other = URL(string: "https://other.example.org")!
        #expect(try await run(.server(address: other)) == 0)
        #expect(try HubCommands.pairingServer(given: nil, folder: folder) == other)
        await #expect(throws: HubSetupError.self) { try await run(.server(address: URL(string: "http://example.com")!)) }
        #expect(try HubCommands.pairingServer(given: nil, folder: folder) == other)
        // The other settings are kept, and the address survives a change of theirs.
        #expect(try await run(.access(.require(true))) == 0)
        let config = try #require(folder.store.read(HubConfig.self, from: HubDataFolder.File.settings))
        #expect(config.requireAccess && config.server == other.absoluteString)
    }
}
