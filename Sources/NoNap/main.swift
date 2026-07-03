import Cocoa
import Foundation

enum DurationChoice: Int, CaseIterable {
    case none
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case twoHours
    case fourHours

    var title: String {
        switch self {
        case .none:
            return "Never"
        case .fifteenMinutes:
            return "15 minutes"
        case .thirtyMinutes:
            return "30 minutes"
        case .oneHour:
            return "1 hour"
        case .twoHours:
            return "2 hours"
        case .fourHours:
            return "4 hours"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .none:
            return nil
        case .fifteenMinutes:
            return 15 * 60
        case .thirtyMinutes:
            return 30 * 60
        case .oneHour:
            return 60 * 60
        case .twoHours:
            return 2 * 60 * 60
        case .fourHours:
            return 4 * 60 * 60
        }
    }
}

struct PanelSnapshot {
    let keepAwakeEnabled: Bool
    let launchAtLogin: Bool
    let duration: DurationChoice
    let statusText: String
    let isBusy: Bool
}

enum AppError: LocalizedError {
    case commandFailed(String)
    case appleScriptFailed(String)
    case stateUnavailable

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message
        case .appleScriptFailed(let message):
            return message
        case .stateUnavailable:
            return "Could not read power settings."
        }
    }
}

enum PowerManager {
    static func currentSleepDisabled() -> Bool? {
        guard let output = try? runProcess("/usr/bin/pmset", arguments: ["-g"]) else {
            return nil
        }

        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }

            if parts[0] == "SleepDisabled" || parts[0] == "disablesleep" {
                return parts[1] == "1"
            }
        }

        return false
    }

    static func setSleepDisabled(_ disabled: Bool) throws {
        let value = disabled ? "1" : "0"
        let source = """
        do shell script "/usr/bin/pmset -a disablesleep \(value)" with administrator privileges
        """

        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw AppError.appleScriptFailed("Could not prepare the administrator command.")
        }

        script.executeAndReturnError(&error)

        if let error {
            let message = (error["NSAppleScriptErrorMessage"] as? String)
                ?? "The administrator command could not be run."
            throw AppError.appleScriptFailed(message)
        }
    }

    private static func runProcess(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let message = errorOutput.isEmpty ? "Command \(executable) failed." : errorOutput
            throw AppError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return output
    }
}

enum LoginItemManager {
    private static let label = "app.nonap.NoNap.login"

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func isEnabled(for bundlePath: String) -> Bool {
        guard
            let data = try? Data(contentsOf: agentURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dictionary = plist as? [String: Any],
            let arguments = dictionary["ProgramArguments"] as? [String]
        else {
            return false
        }

        return arguments.contains(bundlePath)
    }

    static func setEnabled(_ enabled: Bool, bundlePath: String) throws {
        if enabled {
            try FileManager.default.createDirectory(
                at: agentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-gj", bundlePath],
                "RunAtLoad": true
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            try data.write(to: agentURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: agentURL.path) {
            try FileManager.default.removeItem(at: agentURL)
        }
    }
}

protocol PanelViewControllerDelegate: AnyObject {
    func panelDidRequestLidSleep(enabled: Bool)
    func panelDidRequestRefresh()
    func panelDidRequestQuit()
    func panelDidChangeLoginItem(enabled: Bool)
    func panelDidChangeDuration(_ choice: DurationChoice)
}

final class PanelViewController: NSViewController {
    weak var delegate: PanelViewControllerDelegate?

    private let lidSwitch = NSSwitch()
    private let durationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let loginSwitch = NSSwitch()
    private let statusLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    private var applyingSnapshot = false

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        durationPopup.removeAllItems()
        DurationChoice.allCases.forEach { durationPopup.addItem(withTitle: $0.title) }
        durationPopup.target = self
        durationPopup.action = #selector(durationChanged(_:))
        durationPopup.controlSize = .regular
        durationPopup.widthAnchor.constraint(equalToConstant: 156).isActive = true

        lidSwitch.target = self
        lidSwitch.action = #selector(lidSwitchChanged(_:))
        lidSwitch.controlSize = .regular
        lidSwitch.toolTip = "Prevent this Mac from sleeping when the lid is closed"

        loginSwitch.target = self
        loginSwitch.action = #selector(loginSwitchChanged(_:))
        loginSwitch.controlSize = .regular
        loginSwitch.toolTip = "Launch NoNap when you sign in"

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked(_:))
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .regular
        refreshButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true

        quitButton.target = self
        quitButton.action = #selector(quitClicked(_:))
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .regular
        quitButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 82).isActive = true

        let lidRow = makeRow(
            title: "Keep awake",
            subtitle: "Prevent sleep when the lid closes",
            control: lidSwitch
        )
        let durationRow = makeRow(
            title: "Auto-restore",
            subtitle: "Turn lid sleep back on after",
            control: durationPopup
        )
        let loginRow = makeRow(title: "Launch at login", subtitle: nil, control: loginSwitch)
        let buttonRow = makeButtonRow()

        stack.addArrangedSubview(lidRow)
        stack.addArrangedSubview(durationRow)
        stack.addArrangedSubview(loginRow)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(buttonRow)

        root.addSubview(stack)
        view = root

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 348),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 212),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    func apply(_ snapshot: PanelSnapshot) {
        applyingSnapshot = true
        lidSwitch.state = snapshot.keepAwakeEnabled ? .on : .off
        loginSwitch.state = snapshot.launchAtLogin ? .on : .off
        durationPopup.selectItem(at: snapshot.duration.rawValue)
        statusLabel.stringValue = snapshot.statusText

        let enabled = !snapshot.isBusy
        lidSwitch.isEnabled = enabled
        durationPopup.isEnabled = enabled
        loginSwitch.isEnabled = enabled
        refreshButton.isEnabled = enabled
        quitButton.isEnabled = enabled
        applyingSnapshot = false
    }

    private func makeLabelStack(title: String, subtitle: String?) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(titleLabel)

        if let subtitle {
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 12)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(subtitleLabel)
        }

        return stack
    }

    private func makeRow(title: String, subtitle: String?, control: NSView) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        let labels = makeLabelStack(title: title, subtitle: subtitle)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(labels)
        row.addArrangedSubview(control)
        row.widthAnchor.constraint(equalToConstant: 308).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: subtitle == nil ? 32 : 42).isActive = true

        return row
    }

    private func makeButtonRow() -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(refreshButton)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(quitButton)

        return row
    }

    @objc private func lidSwitchChanged(_ sender: NSSwitch) {
        guard !applyingSnapshot else { return }
        delegate?.panelDidRequestLidSleep(enabled: sender.state == .on)
    }

    @objc private func durationChanged(_ sender: NSPopUpButton) {
        guard !applyingSnapshot else { return }
        let choice = DurationChoice(rawValue: sender.indexOfSelectedItem) ?? .none
        delegate?.panelDidChangeDuration(choice)
    }

    @objc private func loginSwitchChanged(_ sender: NSSwitch) {
        guard !applyingSnapshot else { return }
        delegate?.panelDidChangeLoginItem(enabled: sender.state == .on)
    }

    @objc private func refreshClicked(_ sender: NSButton) {
        delegate?.panelDidRequestRefresh()
    }

    @objc private func quitClicked(_ sender: NSButton) {
        delegate?.panelDidRequestQuit()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, PanelViewControllerDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let panel = PanelViewController()
    private var selectedDuration: DurationChoice = .none
    private var sleepDisabled: Bool?
    private var launchAtLogin = false
    private var isBusy = false
    private var lastMessage: String?
    private var restoreTimer: Timer?
    private var restoreDeadline: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        panel.delegate = self
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 348, height: 212)
        popover.contentViewController = panel

        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.imagePosition = .imageOnly
        }

        refreshState(clearMessage: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        restoreTimer?.invalidate()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            refreshState(clearMessage: false)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func panelDidRequestLidSleep(enabled: Bool) {
        setBusy(true)

        DispatchQueue.main.async {
            do {
                let shouldDisableSleep = enabled
                try PowerManager.setSleepDisabled(shouldDisableSleep)
                self.sleepDisabled = shouldDisableSleep
                self.lastMessage = nil

                if shouldDisableSleep {
                    self.scheduleRestoreIfNeeded()
                } else {
                    self.cancelRestoreTimer()
                }

                self.refreshState(clearMessage: false)
            } catch {
                self.lastMessage = "Could not change the setting: \(error.localizedDescription)"
                self.refreshState(clearMessage: false)
            }

            self.setBusy(false)
        }
    }

    func panelDidRequestRefresh() {
        refreshState(clearMessage: true)
    }

    func panelDidRequestQuit() {
        NSApp.terminate(nil)
    }

    func panelDidChangeLoginItem(enabled: Bool) {
        setBusy(true)

        do {
            try LoginItemManager.setEnabled(enabled, bundlePath: Bundle.main.bundlePath)
            launchAtLogin = enabled
            lastMessage = enabled ? "Launch at login is on." : "Launch at login is off."
        } catch {
            lastMessage = "Could not change login item: \(error.localizedDescription)"
        }

        refreshState(clearMessage: false)
        setBusy(false)
    }

    func panelDidChangeDuration(_ choice: DurationChoice) {
        selectedDuration = choice

        if sleepDisabled == true {
            scheduleRestoreIfNeeded()
        }

        refreshState(clearMessage: false)
    }

    private func refreshState(clearMessage: Bool) {
        sleepDisabled = PowerManager.currentSleepDisabled()
        launchAtLogin = LoginItemManager.isEnabled(for: Bundle.main.bundlePath)

        if clearMessage {
            lastMessage = nil
        }

        updateStatusItem()
        panel.apply(currentSnapshot())
    }

    private func currentSnapshot() -> PanelSnapshot {
        return PanelSnapshot(
            keepAwakeEnabled: sleepDisabled ?? false,
            launchAtLogin: launchAtLogin,
            duration: selectedDuration,
            statusText: statusText(),
            isBusy: isBusy
        )
    }

    private func statusText() -> String {
        if let lastMessage {
            return lastMessage
        }

        guard let sleepDisabled else {
            return "Could not read power settings."
        }

        if sleepDisabled {
            if let restoreDeadline {
                let minutes = max(1, Int(ceil(restoreDeadline.timeIntervalSinceNow / 60)))
                return "Keeping awake. Lid sleep returns in \(minutes) min."
            }

            return "Keeping awake. Closing the lid will not sleep this Mac."
        }

        return "Normal lid sleep is on."
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        panel.apply(currentSnapshot())
    }

    private func scheduleRestoreIfNeeded() {
        cancelRestoreTimer()

        guard let interval = selectedDuration.interval else {
            restoreDeadline = nil
            return
        }

        restoreDeadline = Date().addingTimeInterval(interval)
        restoreTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.restoreLidSleepFromTimer()
        }
    }

    private func cancelRestoreTimer() {
        restoreTimer?.invalidate()
        restoreTimer = nil
        restoreDeadline = nil
    }

    private func restoreLidSleepFromTimer() {
        setBusy(true)

        do {
            try PowerManager.setSleepDisabled(false)
            sleepDisabled = false
            selectedDuration = .none
            lastMessage = "Lid sleep returned to normal."
            cancelRestoreTimer()
        } catch {
            lastMessage = "Could not restore lid sleep: \(error.localizedDescription)"
        }

        refreshState(clearMessage: false)
        setBusy(false)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let isDisabled = sleepDisabled == true
        let symbolName = isDisabled ? "lock.open" : "moon"

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "NoNap") {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = isDisabled ? "NoSleep" : "Sleep"
        }

        button.toolTip = isDisabled ? "NoNap: keeping awake" : "NoNap: normal lid sleep"
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
