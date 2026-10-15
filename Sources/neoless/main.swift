import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if DebugCommands.wants(CommandLine.arguments) {
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in await DebugCommands.run(CommandLine.arguments) }
        app.run()
    } else {
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
