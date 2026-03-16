import Foundation
import Combine
import IOKit.ps
import os.log

private let log = Logger(subsystem: "com.opendente.app", category: "BatteryService")

/// Monitors battery state using IOKit power source APIs + SMC for detailed data.
/// Reading does not require root.
@MainActor
final class BatteryService: ObservableObject {

    static let shared = BatteryService()

    @Published private(set) var batteryState: BatteryState = .unknown
    @Published private(set) var smcAvailable = false

    private var timer: Timer?
    private var runLoopSource: CFRunLoopSource?
    private let smc = SMCService.shared
    private var isPopoverVisible = false
    private var lastPollingInterval: TimeInterval = 30

    // MARK: - Lifecycle

    func start() {
        // Open SMC connection (for temperature, power, detailed data)
        do {
            try smc.open()
            smcAvailable = true
            log.info("SMC connected successfully")
        } catch {
            log.error("SMC not available: \(error.localizedDescription)")
            smcAvailable = false
        }

        // Initial read
        update()

        // Start smart polling
        scheduleTimer()

        // Register for power source change notifications
        registerPowerSourceNotification()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        smc.close()
    }

    /// Call when popover visibility changes to adjust polling frequency
    func setPopoverVisible(_ visible: Bool) {
        isPopoverVisible = visible
        scheduleTimer()
        if visible {
            update() // Immediate refresh when opening popover
        }
    }

    // MARK: - Data Collection

    func update() {
        let ioKitState = readIOKitPowerSource()
        let smcState = smcAvailable ? readSMCData() : SMCData()

        let state = BatteryState(
            percentage: ioKitState.percentage,
            isCharging: ioKitState.isCharging,
            isPluggedIn: ioKitState.isPluggedIn,
            currentCapacity: smcState.fullChargeCapacity.map { $0 * ioKitState.percentage / 100 },
            maxCapacity: smcState.fullChargeCapacity,
            designCapacity: smcState.designCapacity,
            cycleCount: smcState.cycleCount ?? ioKitState.cycleCount,
            temperature: smcState.temperature,
            voltage: smcState.voltage,
            amperage: smcState.amperage,
            systemPower: smcState.systemPower,
            adapterPower: smcState.adapterPower,
            batteryPower: smcState.batteryPower,
            timeToEmpty: ioKitState.timeToEmpty,
            timeToFull: ioKitState.timeToFull
        )

        batteryState = state
    }

    // MARK: - IOKit Power Source (no root needed)

    private struct IOKitData {
        var percentage: Int = 0
        var isCharging: Bool = false
        var isPluggedIn: Bool = false
        var currentCapacity: Int?
        var maxCapacity: Int?
        var designCapacity: Int?
        var cycleCount: Int?
        var timeToEmpty: Int?
        var timeToFull: Int?
    }

    private func readIOKitPowerSource() -> IOKitData {
        var data = IOKitData()

        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first as CFTypeRef)?.takeUnretainedValue() as? [String: Any]
        else {
            return data
        }

        data.percentage = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        data.isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
        data.maxCapacity = desc[kIOPSMaxCapacityKey] as? Int
        data.designCapacity = desc[kIOPSDesignCapacityKey] as? Int

        if let powerSource = desc[kIOPSPowerSourceStateKey] as? String {
            data.isPluggedIn = (powerSource == kIOPSACPowerValue)
        }

        if let timeToEmpty = desc[kIOPSTimeToEmptyKey] as? Int, timeToEmpty >= 0 {
            data.timeToEmpty = timeToEmpty
        }
        if let timeToFull = desc[kIOPSTimeToFullChargeKey] as? Int, timeToFull >= 0 {
            data.timeToFull = timeToFull
        }

        // IOKit sometimes reports cycle count
        data.cycleCount = desc["CycleCount"] as? Int

        return data
    }

    // MARK: - SMC Data (detailed, no root for reads)

    private struct SMCData {
        var temperature: Double?
        var voltage: Double?
        var amperage: Double?
        var systemPower: Double?
        var adapterPower: Double?
        var batteryPower: Double?
        var cycleCount: Int?
        var fullChargeCapacity: Int?
        var designCapacity: Int?
    }

    private func readSMCData() -> SMCData {
        var data = SMCData()

        // Temperature: prefer TB0T/TB1T (flt on Apple Silicon) over B0AT (ui16 deci-Kelvin)
        if let val = smc.readKeyOptional("TB0T") {
            if val.dataType.hasPrefix("flt"), let f = val.floatValue {
                data.temperature = Double(f)
            } else if let sp = val.sp78Value {
                data.temperature = sp
            }
        }
        // Fallback to B0AT if TB0T didn't work
        if data.temperature == nil, let val = smc.readKeyOptional("B0AT") {
            if val.dataType == "ui16", let raw = val.uint16Value {
                let celsius = (Double(raw) - 2732.0) / 10.0
                if celsius > -20 && celsius < 100 {
                    data.temperature = celsius
                }
            }
        }

        // Voltage: B0AV in mV
        if let raw = smc.readUInt16("B0AV") {
            data.voltage = Double(raw) / 1000.0
        }

        // Current: B0AC in mA (signed)
        if let raw = smc.readInt16("B0AC") {
            data.amperage = Double(raw) / 1000.0
        }

        // System power: PSTR
        if let val = smc.readKeyOptional("PSTR") {
            if let f = val.floatValue, val.dataType.hasPrefix("flt") {
                data.systemPower = Double(f)
            } else if let sp = val.sp78Value {
                data.systemPower = sp
            }
        }

        // Adapter power: PDTR
        if let val = smc.readKeyOptional("PDTR") {
            if let f = val.floatValue, val.dataType.hasPrefix("flt") {
                data.adapterPower = Double(f)
            } else if let sp = val.sp96Value {
                data.adapterPower = sp
            }
        }

        // Battery power from voltage * current (positive = charging, negative = discharging)
        if let v = data.voltage, let a = data.amperage {
            data.batteryPower = v * a
        }

        // Cycle count
        if let raw = smc.readUInt16("B0CT") {
            data.cycleCount = Int(raw)
        }

        // Capacity (B0RM byte order is unreliable, compute remaining from percentage)
        if let raw = smc.readUInt16("B0FC") {
            data.fullChargeCapacity = Int(raw)
        }
        if let raw = smc.readUInt16("B0DC") {
            data.designCapacity = Int(raw)
        }

        return data
    }

    // MARK: - Smart Polling

    private func scheduleTimer() {
        timer?.invalidate()

        let interval = pollingInterval()
        if interval != lastPollingInterval {
            log.debug("Polling interval: \(interval)s")
        }
        lastPollingInterval = interval

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.update()
                let newInterval = self.pollingInterval()
                if newInterval != self.lastPollingInterval {
                    self.scheduleTimer()
                }
            }
        }
    }

    private func pollingInterval() -> TimeInterval {
        let state = batteryState
        let settings = AppSettings.shared

        // When popover is visible, user is actively looking
        if isPopoverVisible {
            return 2
        }

        // On battery - conserve energy
        if state.isOnBattery {
            return 60
        }

        // Near the charge limit (within ±3%)
        let nearLimit = abs(state.percentage - settings.chargeLimit) <= 3
        if nearLimit && state.isCharging {
            return 3
        }

        // Actively charging
        if state.isCharging {
            return 10
        }

        // Plugged in, limit reached - minimal polling
        return 30
    }

    // MARK: - Power Source Notifications

    private func registerPowerSourceNotification() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let ctx = context else { return }
            let service = Unmanaged<BatteryService>.fromOpaque(ctx).takeUnretainedValue()
            // Callback fires on main RunLoop — use assumeIsolated for Swift 6 safety
            MainActor.assumeIsolated {
                service.update()
                service.scheduleTimer()
            }
        }, context)?.takeRetainedValue() {
            self.runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }
}
