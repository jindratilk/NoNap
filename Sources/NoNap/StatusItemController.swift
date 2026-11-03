import AppKit
import Observation
import SwiftUI

/// The menu bar presence: the icon always shows the live state, a click opens the panel.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: KeepAwake
    private var pollTimer: Timer?
    private var shownState: Bool?
    private var wakeObserver: NSObjectProtocol?
    /// App Nap would otherwise stretch the timer, leaving the icon out of date for minutes.
    /// This doesn't stop the Mac from sleeping: that's the setting's job, not the app's.
    private let activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep,
        reason: "Keeping the menu bar icon in step with the sleep setting"
    )

    init(model: KeepAwake) {
        self.model = model
        super.init()

        item.autosaveName = "\(App.executable).main"

        let hosting = NSHostingView(rootView: PanelView(quit: { NSApp.terminate(nil) }).environment(model))
        let size = hosting.fittingSize
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        let container = NSViewController()
        container.view = hosting
        popover.contentSize = size
        popover.contentViewController = container
        popover.behavior = .transient
        popover.delegate = self

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
        }

        observe()

        // Cheap enough to read often (see Power.isSleepDisabled), so nothing has to be refreshed by hand.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak model] _ in
            MainActor.assumeIsolated { model?.refresh() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak model] _ in
            MainActor.assumeIsolated { model?.refresh() }
        }
    }

    // MARK: - Rendering

    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render() {
        guard let button = item.button else { return }
        let isOn = model.isOn

        if shownState != nil, shownState != isOn, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            button.wantsLayer = true
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.3
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            button.layer?.add(fade, forKey: "state")
        }
        shownState = isOn

        let symbol = isOn ? "sun.max.fill" : "moon.zzz"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: App.name)?.withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
        button.setAccessibilityValue(isOn ? "Stays awake when closed" : "Sleeps when closed")
        button.toolTip = "\(App.name): \(isOn ? "stays awake when closed" : "sleeps when closed")"
    }

    // MARK: - Actions

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    func showPopover() {
        guard let button = item.button else { return }
        NSApp.activate()
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    #if DEBUG
    /// For looking at the panel from a script: stays open and doesn't take focus from other apps.
    func pinPopoverOpen() {
        popover.behavior = .applicationDefined
        guard let button = item.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    #endif

    func popoverWillShow(_ notification: Notification) {
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.refresh()
        model.refreshLoginItem()
    }

    private func showMenu() {
        let menu = NSMenu()
        let keepAwake = NSMenuItem(title: "Stay Awake When Closed", action: #selector(toggleKeepAwake), keyEquivalent: "")
        keepAwake.target = self
        keepAwake.state = model.isOn ? .on : .off
        menu.addItem(keepAwake)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(App.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func toggleKeepAwake() { model.toggle() }
}
