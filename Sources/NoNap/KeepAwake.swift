import Foundation
import Observation

/// The one source of truth for the switch: what the system says, and what was just asked of it.
@MainActor
@Observable
final class KeepAwake {
    /// Everything the model needs from the outside world, replaceable for tests and previews.
    struct System {
        var read: @MainActor () -> Bool?
        var write: @Sendable (Bool) async throws -> Void
        var launchesAtLogin: @MainActor () -> Bool
        var setLaunchesAtLogin: @MainActor (Bool) throws -> Void

        static let live = System(
            read: { Power.isSleepDisabled() },
            write: { value in
                // Runs a subprocess and can wait on a password dialog: never on the main thread.
                try await Task.detached { try Power.setSleepDisabled(value) }.value
            },
            launchesAtLogin: { LoginItem.isEnabled },
            setLaunchesAtLogin: { try LoginItem.setEnabled($0) }
        )
    }

    private(set) var actual: Bool?
    /// What the user asked for, until the system confirms it. While set, it wins over `actual`.
    private(set) var target: Bool?
    private(set) var problem: String?
    private(set) var launchesAtLogin = false

    @ObservationIgnored private let system: System
    @ObservationIgnored private let confirmAttempts: Int
    @ObservationIgnored private let confirmDelay: Duration
    @ObservationIgnored private let problemDuration: Duration
    @ObservationIgnored private var problemTask: Task<Void, Never>?

    init(
        system: System = .live,
        confirmAttempts: Int = 30,
        confirmDelay: Duration = .milliseconds(100),
        problemDuration: Duration = .seconds(4)
    ) {
        self.system = system
        self.confirmAttempts = confirmAttempts
        self.confirmDelay = confirmDelay
        self.problemDuration = problemDuration
        refresh()
        refreshLoginItem()
    }

    var isOn: Bool { target ?? actual ?? false }
    var isUnknown: Bool { target == nil && actual == nil }

    /// Picks up changes made anywhere: this app, a terminal, a restart. A read that lands while a
    /// change is being applied could still see the old value, so it waits for that to finish.
    func refresh() {
        guard target == nil else { return }
        store(system.read())
    }

    func refreshLoginItem() {
        let enabled = system.launchesAtLogin()
        if enabled != launchesAtLogin { launchesAtLogin = enabled }
    }

    func toggle() {
        guard target == nil else { return }
        let wanted = !isOn
        target = wanted
        clearProblem()

        Task {
            do {
                try await system.write(wanted)
                if await confirm(wanted) == false {
                    show(problem: "Your Mac didn't accept the change")
                }
            } catch Power.Failure.cancelled {
                // The user closed the password dialog. Nothing went wrong.
            } catch {
                NSLog("Could not change disablesleep: %@", error.localizedDescription)
                show(problem: "Couldn't change the setting")
            }
            store(system.read())
            target = nil
        }
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            try system.setLaunchesAtLogin(enabled)
        } catch {
            NSLog("Could not change the login item: %@", error.localizedDescription)
            show(problem: "Couldn't change the login item")
        }
        refreshLoginItem()
    }

    /// The system applies a change a moment after the command returns, so a read straight away
    /// can return the old value. Keep looking until it matches, up to a limit.
    private func confirm(_ wanted: Bool) async -> Bool {
        for attempt in 0..<confirmAttempts {
            if system.read() == wanted { return true }
            if attempt < confirmAttempts - 1 { try? await Task.sleep(for: confirmDelay) }
        }
        return false
    }

    private func store(_ value: Bool?) {
        if value != actual { actual = value }
    }

    private func show(problem message: String) {
        problemTask?.cancel()
        problem = message
        problemTask = Task { [problemDuration] in
            try? await Task.sleep(for: problemDuration)
            guard !Task.isCancelled else { return }
            problem = nil
        }
    }

    private func clearProblem() {
        problemTask?.cancel()
        problemTask = nil
        problem = nil
    }
}
