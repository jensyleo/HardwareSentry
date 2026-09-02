import AppKit
import Foundation
import IOKit
import IOKit.ps

/// Watches `IOPowerSources` for power source changes, `NSWorkspace` for system/display
/// sleep and wake, and `NSProcessInfo` for Low Power Mode.
///
/// Deliberately thin and untested, for the same reason `IOKitUSBDeviceSource` is: none of
/// it can run without a real power event. Everything worth reasoning about lives in
/// `PowerMonitor`, behind `PowerSource`.
public struct IOPSPowerSource: PowerSource {
    public init() {}

    public func changes() -> AsyncStream<PowerSourceEvent> {
        AsyncStream { continuation in
            let watcher = Watcher(continuation: continuation)
            continuation.onTermination = { _ in watcher.stop() }
            watcher.start()
        }
    }

    /// Read from `AppleSmartBattery` in the IO registry rather than through `IOPowerSources`.
    ///
    /// `IOPowerSources` is about what is powering the Mac now, and answers nothing about
    /// cycles, design capacity or named faults. Those live on the battery's own registry
    /// entry, which is a plain property dictionary — no plug-in interface, so unlike the
    /// NVMe SMART reads this needs no bridge in C.
    ///
    /// A desktop Mac has no such entry, and returns nothing. That is the honest answer:
    /// a Mac Studio has no battery health to report, and inventing a 100% would be worse
    /// than silence.
    public func readBatteryHealth() async -> BatteryHealthDetail? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }

        let designCapacity = properties["DesignCapacity"] as? Int
        // "NominalChargeCapacity" first, because that is the figure System Settings
        // divides by design capacity for the Maximum Capacity percentage it shows — and a
        // health figure that disagrees with the one macOS shows reads as a bug in this
        // application rather than as a second opinion. "AppleRawMaxCapacity" is the
        // fallback for Macs that do not publish the nominal figure.
        //
        // "MaxCapacity" is last and reluctantly: on Apple Silicon it is a normalised 100,
        // which would make every battery ever made look brand new. Verified on this Mac,
        // where the three read 4011, 3884 and 100 against a design capacity of 4629.
        let currentCapacity = properties["NominalChargeCapacity"] as? Int
            ?? properties["AppleRawMaxCapacity"] as? Int
            ?? properties["MaxCapacity"] as? Int

        var healthPercent: Int?
        if let currentCapacity, let designCapacity, designCapacity > 0 {
            // Capped at 100: a fresh battery routinely measures a little above its design
            // figure, and "Battery health: 103%" reads as a bug rather than as good news.
            healthPercent = min(100, Int((Double(currentCapacity) / Double(designCapacity) * 100).rounded()))
        }

        return BatteryHealthDetail(
            cycleCount: properties["CycleCount"] as? Int,
            designCycleCount: properties["DesignCycleCount9C"] as? Int ?? properties["DesignCycleCount"] as? Int,
            healthPercent: healthPercent,
            condition: properties["BatteryHealthCondition"] as? String,
            coarseHealth: properties["BatteryHealth"] as? String,
            failureModes: Self.failureModes(in: properties),
            hasInternalFailure: properties["PermanentFailureStatus"] as? Int ?? 0 != 0,
            currentCapacityMAh: currentCapacity,
            designCapacityMAh: designCapacity,
            maximumErrorPercent: properties["MaxErr"] as? Int
        )
    }

    /// The named faults, when the battery reports any.
    ///
    /// Two shapes, because the key has had both over the years: an array of strings on
    /// some machines and a single string on others. Read as only one of them, a real fault
    /// on the other kind of Mac would be silently dropped — which is the one failure mode
    /// this whole notification exists to catch.
    private static func failureModes(in properties: [String: Any]) -> [String] {
        if let list = properties["BatteryFailureModes"] as? [String] { return list }
        if let single = properties["BatteryFailureModes"] as? String, !single.isEmpty { return [single] }
        return []
    }
}

private final class Watcher: @unchecked Sendable {
    private let continuation: AsyncStream<PowerSourceEvent>.Continuation
    private var runLoopSource: CFRunLoopSource?
    private var tokens: [NSObjectProtocol] = []

    init(continuation: AsyncStream<PowerSourceEvent>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        emitSnapshot()
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<Watcher>.fromOpaque(context).takeUnretainedValue().emitSnapshot()
        }, context)?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.continuation.yield(.systemWillSleep)
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.continuation.yield(.systemDidWake)
        })
        tokens.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.continuation.yield(.screensDidSleep)
        })
        tokens.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.continuation.yield(.screensDidWake)
        })

        continuation.yield(.lowPowerModeChanged(ProcessInfo.processInfo.isLowPowerModeEnabled))
        tokens.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.continuation.yield(.lowPowerModeChanged(ProcessInfo.processInfo.isLowPowerModeEnabled))
        })
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode) }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let defaultCenter = NotificationCenter.default
        tokens.forEach { token in
            workspaceCenter.removeObserver(token)
            defaultCenter.removeObserver(token)
        }
        continuation.finish()
    }

    /// Rebuilt on every notification rather than watched separately: `IOPowerSources`
    /// raises one notification for anything power-related, and the adapter that is plugged
    /// in is part of the same picture as the source that is providing power.
    private func emitAdapter() {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: AnyObject] else {
            continuation.yield(.adapter(nil))
            return
        }

        // Serial arrives as a number on most adapters and a string on some; printed
        // either way rather than dropped for not matching the expected type.
        let serial: String?
        if let number = details[kIOPSPowerAdapterSerialNumberKey as String] as? Int {
            serial = String(number)
        } else {
            serial = details[kIOPSPowerAdapterSerialNumberKey as String] as? String
        }

        continuation.yield(.adapter(PowerAdapterDetail(
            watts: details[kIOPSPowerAdapterWattsKey as String] as? Int,
            family: (details[kIOPSPowerAdapterFamilyKey as String] as? Int).map { String(format: "0x%04X", $0) },
            adapterID: (details[kIOPSPowerAdapterIDKey as String] as? Int).map(String.init),
            serialNumber: serial
        )))
    }

    fileprivate func emitSnapshot() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }

        let providingType = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let kind: PowerSourceKind
        switch providingType {
        case "AC Power": kind = .ac
        case "Battery Power": kind = .battery
        case "UPS Power": kind = .ups
        default: kind = .unknown
        }

        var percentage: Int?
        var sources: [PowerSourceDetail] = []
        if let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for entry in list {
                guard let description = IOPSGetPowerSourceDescription(blob, entry)?.takeUnretainedValue() as? [String: AnyObject] else { continue }
                // A source that is not physically there reports stale numbers; asking it
                // for a charge level gives an answer about nothing.
                guard description[kIOPSIsPresentKey as String] as? Bool == true else { continue }
                // Worked out as a fraction of the source's own maximum rather than read
                // straight from CurrentCapacity: the internal battery happens to report a
                // max of 100, so the raw value looks like a percentage — but a UPS reports
                // milliamp-hours, and the raw value there is a four-digit number that
                // would be shown as a charge level of "4200%".
                guard let current = description[kIOPSCurrentCapacityKey as String] as? Double,
                      let maximum = description[kIOPSMaxCapacityKey as String] as? Double,
                      maximum > 0
                else { continue }
                let ownPercentage = Int((current / maximum * 100).rounded())
                percentage = max(percentage ?? 0, ownPercentage)
                sources.append(Self.describe(description, percentage: ownPercentage))
            }
        }

        let warningLevel = IOPSGetBatteryWarningLevel()
        let isLowWarning = warningLevel != kIOPSLowBatteryWarningNone

        continuation.yield(.snapshot(PowerSnapshot(
            kind: kind,
            percentage: percentage,
            isLowBatteryWarning: isLowWarning,
            sources: sources
        )))
        emitAdapter()
    }

    /// "InternalBattery" is what the key answers; nobody says that out loud.
    private static func typeName(_ raw: String?) -> String? {
        switch raw {
        case kIOPSInternalBatteryType: return "Battery"
        case kIOPSUPSType: return "UPS"
        case .some(let other) where !other.isEmpty: return other
        default: return nil
        }
    }

    /// Where the source is in its cycle.
    ///
    /// Built from the three booleans rather than read from `PowerSourceState`, which
    /// answers "AC Power" or "Battery Power" — the same thing the notification's own title
    /// already says, and not what "charge state" means to anyone reading it. "Finishing"
    /// is checked before "Charged" because a battery topping off the last percent reports
    /// both, and the more specific of the two is the informative one.
    private static func chargeState(_ description: [String: AnyObject]) -> String? {
        let flag = { (key: String) in description[key] as? Bool ?? false }
        if flag(kIOPSIsFinishingChargeKey as String) { return "Finishing charge" }
        if flag(kIOPSIsChargedKey as String) { return "Charged" }
        if flag(kIOPSIsChargingKey as String) { return "Charging" }
        return "Discharging"
    }

    private static func describe(_ description: [String: AnyObject], percentage: Int) -> PowerSourceDetail {
        let isCharging = description[kIOPSIsChargingKey as String] as? Bool ?? false
        // Charging and discharging each have their own key, and only one of them is
        // meaningful at a time — reading the wrong one gives a time that never moves.
        let minutes = isCharging
            ? description[kIOPSTimeToFullChargeKey as String] as? Int
            : description[kIOPSTimeToEmptyKey as String] as? Int

        return PowerSourceDetail(
            typeName: Self.typeName(description[kIOPSTypeKey as String] as? String),
            chargeState: Self.chargeState(description),
            percentage: percentage,
            // A negative figure is the system saying it has not worked it out yet, which
            // it always is for the first minute or two after anything changes.
            minutesRemaining: minutes.flatMap { $0 > 0 ? $0 : nil },
            isCharging: isCharging,
            millivolts: description[kIOPSVoltageKey as String] as? Int,
            milliamps: description[kIOPSCurrentKey as String] as? Int,
            // Reported in hundredths of a degree by every source that reports it at all.
            celsius: (description["Temperature"] as? Double).map { $0 / 100 },
            name: description[kIOPSNameKey as String] as? String,
            serialNumber: description[kIOPSHardwareSerialNumberKey as String] as? String,
            vendorID: description["Vendor ID"] as? Int,
            productID: description["Product ID"] as? Int
        )
    }
}
