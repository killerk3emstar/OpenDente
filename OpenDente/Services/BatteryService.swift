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
        let ioRegState = readIORegistryBattery()

        // Hardware SoC: B0RM/B0FC gives the raw fuel gauge percentage.
        // BUIC is "Battery UI Charge" — the smoothed value macOS shows, same as IOKit.
        // BRSC is "Battery Remaining State of Charge" (ui16, high byte = %).
        // We want the raw ratio for an independent reading.
        let hwPercent: Int? = {
            // Primary: raw capacity ratio from fuel gauge
            if let rem = smcState.remainingCapacity,
               let full = smcState.fullChargeCapacity,
               full > 0, rem >= 0 {
                let ratio = Double(rem) / Double(full)
                if ratio <= 1.1 {
                    return max(0, min(100, Int(round(ratio * 100.0))))
                }
            }
            // Fallback: BRSC (if available)
            if let brsc = smcState.brscPercentage { return brsc }
            return nil
        }()

        // Always build AdapterInfo from IORegistry when available.
        // SMC VD0R/ID0R override negotiated voltage/current with live readings.
        // Views decide visibility using isPluggedIn + mode (IORegistry caches stale data after unplug).
        let adapterInfo: AdapterInfo? = ioRegState.adapterInfo.map { info in
            AdapterInfo(
                name: info.name,
                description: info.description,
                manufacturer: info.manufacturer,
                model: info.model,
                watts: info.watts,
                voltage: smcState.adapterVoltage ?? info.voltage,
                current: smcState.adapterCurrent ?? info.current,
                serial: info.serial,
                firmware: info.firmware,
                isWireless: info.isWireless,
                usbPDProfiles: info.usbPDProfiles,
                activeProfileIndex: info.activeProfileIndex
            )
        }

        let state = BatteryState(
            percentage: ioKitState.percentage,
            hardwarePercentage: hwPercent,
            isCharging: ioKitState.isCharging,
            isPluggedIn: ioKitState.isPluggedIn,
            // B0RM for mAh display when available, otherwise estimate from B0FC
            currentCapacity: smcState.remainingCapacity ?? smcState.fullChargeCapacity.map { $0 * ioKitState.percentage / 100 },
            maxCapacity: smcState.fullChargeCapacity,
            designCapacity: smcState.designCapacity,
            cycleCount: smcState.cycleCount ?? ioKitState.cycleCount,
            temperature: smcState.temperature,
            voltage: smcState.voltage,
            amperage: smcState.amperage,
            systemPower: smcState.systemPower,
            adapterPower: smcState.adapterPower,
            adapterInfo: adapterInfo,
            batteryPower: smcState.batteryPower,
            notChargingReason: ioRegState.notChargingReason,
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
        var adapterVoltage: Double?  // VD0R (live adapter voltage)
        var adapterCurrent: Double?  // ID0R (live adapter current)
        var batteryPower: Double?
        var cycleCount: Int?
        var buicPercentage: Int?        // BUIC: UI-smoothed SoC (same as macOS %)
        var brscPercentage: Int?        // BRSC: Battery Remaining State of Charge
        var remainingCapacity: Int?
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

        // Adapter voltage: VD0R (Apple Silicon — flt or uint16 mV)
        if let val = smc.readKeyOptional("VD0R") {
            if val.dataType.hasPrefix("flt"), let f = val.floatValue {
                data.adapterVoltage = Double(f)
            } else if let raw = val.uint16Value {
                data.adapterVoltage = Double(raw) / 1000.0
            }
        }

        // Adapter current: ID0R (Apple Silicon — flt or uint16 mA)
        if let val = smc.readKeyOptional("ID0R") {
            if val.dataType.hasPrefix("flt"), let f = val.floatValue {
                data.adapterCurrent = Double(f)
            } else if let raw = val.uint16Value {
                data.adapterCurrent = Double(raw) / 1000.0
            }
        }

        // Battery power: prefer B0AP (direct hardware measurement in mW) over V*A calculation
        if let val = smc.readKeyOptional("B0AP") {
            if let f = val.floatValue, val.dataType.hasPrefix("flt") {
                data.batteryPower = Double(f)
            } else if let raw = val.int32Value {
                data.batteryPower = Double(raw) / 1000.0  // mW -> W
            }
        }
        // Fallback to V*A if B0AP unavailable
        if data.batteryPower == nil, let v = data.voltage, let a = data.amperage {
            data.batteryPower = v * a
        }

        // Cycle count
        if let raw = smc.readUInt16("B0CT") {
            data.cycleCount = Int(raw)
        }

        // BUIC: "Battery UI Charge" — smoothed percentage macOS shows to users.
        // Kept for diagnostics, but NOT used as hardware SoC (it matches IOKit exactly).
        if let raw = smc.readUInt8("BUIC"), raw <= 100 {
            data.buicPercentage = Int(raw)
        }

        // BRSC: "Battery Remaining State of Charge" — ui16, high byte = percentage.
        // May not exist on all Apple Silicon models.
        if let raw = smc.readUInt16("BRSC") {
            let pct = Int(raw >> 8)
            if pct >= 0 && pct <= 100 {
                data.brscPercentage = pct
            }
        }

        // Capacity
        if let raw = smc.readUInt16("B0FC") {
            data.fullChargeCapacity = Int(raw)
        }
        if let raw = smc.readUInt16("B0DC") {
            data.designCapacity = Int(raw)
        }

        // B0RM uses big-endian byte order per Asahi Linux docs, but try both.
        // Use whichever gives a plausible ratio against B0FC.
        if let val = smc.readKeyOptional("B0RM"), let fc = data.fullChargeCapacity, fc > 0 {
            let be = val.uint16BigEndian.map(Int.init) ?? -1
            let le = val.uint16Value.map(Int.init) ?? -1
            let beRatio = Double(be) / Double(fc)
            let leRatio = Double(le) / Double(fc)
            if be >= 0 && beRatio <= 1.1 {
                data.remainingCapacity = be
            } else if le >= 0 && leRatio <= 1.1 {
                data.remainingCapacity = le
            }
        }

        return data
    }

    // MARK: - IORegistry (adapter details, not-charging reason)

    private func readIORegistryBattery() -> (adapterInfo: AdapterInfo?, notChargingReason: UInt64?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return (nil, nil) }
        defer { IOObjectRelease(service) }

        // Read only the keys we need — NOT CreateCFProperties which copies the entire 16KB+ dict
        // (PortControllerInfo alone is 9KB of data we never use)
        let adapterDict = IORegistryEntryCreateCFProperty(service, "AdapterDetails" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        let chargerDict = IORegistryEntryCreateCFProperty(service, "ChargerData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]

        // Parse AdapterDetails
        var adapterInfo: AdapterInfo?
        if let adapter = adapterDict {
            let name = adapter["Name"] as? String
                ?? adapter["Description"] as? String
                ?? "Unknown Adapter"
            let description = adapter["Description"] as? String
            let manufacturer = adapter["Manufacturer"] as? String
            let model = adapter["Model"] as? String
            let watts = adapter["Watts"] as? Int ?? 0

            // AdapterVoltage in mV, Current in mA
            let voltage: Double = {
                if let v = adapter["AdapterVoltage"] as? Int { return Double(v) / 1000.0 }
                return 0
            }()
            let current: Double = {
                if let a = adapter["Current"] as? Int { return Double(a) / 1000.0 }
                return 0
            }()

            let serial = adapter["SerialString"] as? String
            let firmware = adapter["FwVersion"] as? String
            let isWireless = adapter["IsWireless"] as? Bool ?? false

            // USB-PD profiles (keys: MaxVoltage/MaxCurrent in mV/mA)
            var profiles: [USBPDProfile] = []
            if let menu = adapter["UsbHvcMenu"] as? [[String: Any]] {
                for entry in menu {
                    if let v = entry["MaxVoltage"] as? Int, let a = entry["MaxCurrent"] as? Int {
                        profiles.append(USBPDProfile(
                            voltage: Double(v) / 1000.0,
                            current: Double(a) / 1000.0
                        ))
                    }
                }
            }
            let activeIndex = adapter["UsbHvcHvcIndex"] as? Int

            adapterInfo = AdapterInfo(
                name: name,
                description: description,
                manufacturer: manufacturer,
                model: model,
                watts: watts,
                voltage: voltage,
                current: current,
                serial: serial,
                firmware: firmware,
                isWireless: isWireless,
                usbPDProfiles: profiles,
                activeProfileIndex: activeIndex
            )
        }

        // NotChargingReason from ChargerData (CF bridges as Int or UInt64)
        var notChargingReason: UInt64?
        if let chargerData = chargerDict,
           let raw = chargerData["NotChargingReason"] {
            if let val = raw as? UInt64 {
                notChargingReason = val
            } else if let val = raw as? Int {
                notChargingReason = UInt64(bitPattern: Int64(val))
            }
        }

        return (adapterInfo, notChargingReason)
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

        // IOKit may return incomplete data at startup — retry quickly
        if state.percentage == 0 && !state.isPluggedIn && !state.isCharging
           && state.timeToEmpty == nil && state.timeToFull == nil {
            return 2
        }

        // On battery - conserve energy
        if state.isOnBattery {
            return 60
        }

        // Near the charge limit (within ±3%)
        let pct = state.effectivePercentage(useHardware: settings.useHardwareBatteryPercentage)
        let nearLimit = abs(pct - settings.chargeLimit) <= 3
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
