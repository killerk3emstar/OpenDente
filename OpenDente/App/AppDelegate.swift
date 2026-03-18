import AppKit
import Combine
import SwiftUI
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    static private(set) var instance: AppDelegate?

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var lastIconName: String?

    private let battery = BatteryService.shared
    private let charging = ChargingManager.shared
    private let settings = AppSettings.shared

    // MARK: - App Lifecycle

    /// True when the app is launched as a test host by Xcode.
    /// Tests load into the app process for symbol access, but we skip real services
    /// to avoid SMC commands and UserDefaults pollution from the test host.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.instance = self
        NSApp.setActivationPolicy(.accessory)

        guard !Self.isRunningTests else { return }

        battery.start()
        charging.start()

        setupStatusItem()
        setupPopover()
        setupEventMonitor()
        setupSleepWakeNotifications()

        // Check helper status and prompt for registration if needed
        checkHelperStatus()

        // Update status bar reactively when battery state or mode changes
        battery.$batteryState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusBarText() }
            .store(in: &cancellables)

        charging.$mode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusBarText() }
            .store(in: &cancellables)

        // Notifications
        NotificationService.shared.requestPermission()
        setupNotifications()
    }

    private func setupNotifications() {
        var previousMode: ChargingMode = charging.mode

        charging.$mode
            .receive(on: RunLoop.main)
            .sink { [weak self] newMode in
                guard let self else { return }
                switch (previousMode, newMode) {
                case (.charging, .paused), (.sailing, .paused):
                    NotificationService.shared.send(.chargeLimitReached, settings: self.settings)
                case (_, .heatProtection):
                    NotificationService.shared.send(.heatProtection, settings: self.settings)
                case (.discharging, .paused), (.discharging, .idle):
                    NotificationService.shared.send(.dischargeComplete, settings: self.settings)
                default:
                    break
                }
                if newMode == .charging || newMode == .onBattery || newMode == .discharging {
                    NotificationService.shared.clearLastEvent()
                }
                previousMode = newMode
            }
            .store(in: &cancellables)

        battery.$batteryState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                let pct = state.effectivePercentage(useHardware: self.settings.useHardwareBatteryPercentage)
                if self.charging.mode == .topUp && pct >= 100 {
                    NotificationService.shared.send(.topUpComplete, settings: self.settings)
                }
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        // Synchronous reset with timeout to ensure charging is re-enabled before exit
        charging.resetToDefaultsSync()
        HelperClient.shared.disconnect()
        battery.stop()
        cancellables.removeAll()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        // Remove sleep/wake observers to avoid stale callbacks
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
            updateStatusBarText()
        }
    }

    private func updateStatusBarText() {
        guard let button = statusItem?.button else { return }

        let state = battery.batteryState
        let pct = state.effectivePercentage(useHardware: settings.useHardwareBatteryPercentage)

        let iconName = settings.statusBarShowMode
            ? charging.mode.batteryIconName(percentage: pct, isCharging: state.isCharging)
            : ChargingMode.idle.batteryIconName(percentage: pct, isCharging: false)
        if iconName != lastIconName {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Battery \(pct)%")?.withSymbolConfiguration(config)
            lastIconName = iconName
        }

        let text = state.statusBarText(
            effectivePercentage: pct,
            showPercentage: settings.statusBarShowPercentage,
            showTemperature: settings.statusBarShowTemperature,
            showPower: settings.statusBarShowPower
        )
        button.title = text.isEmpty ? "" : " " + text
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
            .padding(.top, 8)
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

    // MARK: - Helper

    private func checkHelperStatus() {
        let status = HelperInstaller.status
        NSLog("[OpenDente] Helper status: \(HelperInstaller.statusDescription) (raw: \(String(describing: status)))")

        switch status {
        case .notRegistered:
            NSLog("[OpenDente] Attempting to register helper daemon...")
            HelperInstaller.register()
        case .requiresApproval:
            // Don't call register() — it always fails. User must toggle in System Settings.
            NSLog("[OpenDente] Helper needs approval in System Settings > Login Items")
        case .enabled:
            NSLog("[OpenDente] Helper is enabled")
        case .notFound:
            NSLog("[OpenDente] Helper binary not found in app bundle")
        @unknown default:
            break
        }

        charging.isHelperInstalled = HelperInstaller.isRegistered
        NSLog("[OpenDente] Helper registered: \(charging.isHelperInstalled)")
    }

    // MARK: - Sleep/Wake

    private func setupSleepWakeNotifications() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(
            self,
            selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        ws.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func willSleep(_ notification: Notification) {
        HelperClient.shared.suspendWatchdog()
    }

    @objc private func didWake(_ notification: Notification) {
        HelperClient.shared.sendHeartbeat()
        // Refresh battery state immediately — it may have changed during sleep
        // (e.g. charger unplugged, battery drained). This triggers evaluateState
        // via the Combine publisher, avoiding a stale-state gap until the next poll.
        battery.update()
    }

}
