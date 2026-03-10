import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    static private(set) var instance: AppDelegate?

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var eventMonitor: Any?
    private var lastIconName: String?

    private let battery = BatteryService.shared
    private let charging = ChargingManager.shared
    private let settings = AppSettings.shared

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.instance = self
        NSApp.setActivationPolicy(.accessory)

        battery.start()
        charging.start()

        setupStatusItem()
        setupPopover()
        setupEventMonitor()

        // Update status bar text periodically
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusBarText()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        charging.resetToDefaults()
        battery.stop()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            button.image = NSImage(systemSymbolName: "battery.75percent", accessibilityDescription: "OpenDente")?.withSymbolConfiguration(config)
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
            updateStatusBarText()
        }
    }

    private func updateStatusBarText() {
        guard let button = statusItem?.button else { return }

        let state = battery.batteryState

        let iconName: String
        if state.isPluggedIn {
            if state.isCharging {
                iconName = "battery.100percent.bolt"
            } else {
                iconName = "battery.100percent"
            }
        } else {
            if state.percentage > 75 { iconName = "battery.100percent" }
            else if state.percentage > 50 { iconName = "battery.75percent" }
            else if state.percentage > 25 { iconName = "battery.50percent" }
            else { iconName = "battery.25percent" }
        }
        if iconName != lastIconName {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            lastIconName = iconName
        }

        var parts: [String] = []

        if settings.statusBarShowPercentage {
            parts.append("\(state.percentage)%")
        }

        if settings.statusBarShowTemperature, let temp = state.temperature {
            parts.append(String(format: "%.0f°", temp))
        }

        if settings.statusBarShowPower, let power = state.systemPower, power > 0 {
            parts.append(String(format: "%.0fW", power))
        }

        button.title = parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: PopoverView())
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Settings Window

    func openSettingsWindow() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "OpenDente Settings"
        window.styleMask = [.titled, .closable]
        window.center()
        window.setFrameAutosaveName("OpenDenteSettings")
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
    }

    // MARK: - Event Monitor

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let self = self, self.popover.isShown {
                self.popover.performClose(nil)
            }
        }
    }
}
