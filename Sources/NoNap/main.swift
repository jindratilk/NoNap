import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let model = KeepAwake(system: Self.system())
        let status = StatusItemController(model: model)
        self.status = status

        #if DEBUG
        if CommandLine.arguments.contains("--show-panel") {
            // The menu bar lays out the item a moment after launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { status.pinPopoverOpen() }
        }
        if CommandLine.arguments.contains("--auto-toggle") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { model.toggle() }
        }
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        status?.showPopover()
        return false
    }

    private static func system() -> KeepAwake.System {
        #if DEBUG
        // Try the app without touching the real power setting.
        if CommandLine.arguments.contains("--preview") { return .preview(on: CommandLine.arguments.contains("--on")) }
        #endif
        return .live
    }
}

#if DEBUG
extension KeepAwake.System {
    @MainActor static func preview(on: Bool) -> Self {
        final class Fake: @unchecked Sendable { var on = false, login = false }
        let fake = Fake()
        fake.on = on
        return Self(
            read: { fake.on },
            write: { value in
                if CommandLine.arguments.contains("--fail") { throw Power.Failure.command("Simulated failure") }
                try await Task.sleep(for: .milliseconds(60))
                fake.on = value
            },
            launchesAtLogin: { fake.login },
            setLaunchesAtLogin: { fake.login = $0 }
        )
    }
}
#endif

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
    withExtendedLifetime(delegate) {}
}
