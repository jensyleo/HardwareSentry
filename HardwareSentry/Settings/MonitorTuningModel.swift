import Foundation
import MonitorRegistry
import PowerMonitor
import SentryContract
import ScannerMonitor
import Observation

/// The handful of numbers that change how often a monitor speaks, rather than whether it
/// speaks at all.
///
/// Kept apart from the event and field switches because they are a different kind of
/// setting: those decide what is worth saying, these decide when. Stored in the ordinary
/// preferences file under readable keys, so an exported profile carries them along with
/// everything else.
@MainActor
@Observable
final class MonitorTuningModel {
    @ObservationIgnored private let defaults: UserDefaults
    /// Called after any change, so the running monitors take it immediately rather than
    /// at the next launch — a slider that needs a restart to mean anything is a slider
    /// that looks broken.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Self.refireMinutesKey: 30.0,
            Self.refireOnlyOnBatteryKey: true,
            Self.healthEnabledKey: true,
            Self.healthDaysKey: 7.0,
            Self.lowSpacePercentKey: 5.0,
            Self.scannerStatusSecondsKey: 10.0,
            Self.wifiSignalSecondsKey: 12.0,
            Self.wifiSignalCooldownKey: 10.0,
            Self.connectionNamingKey: ConnectionNaming.mediumAndType.rawValue
        ])

        // Assigned here rather than through the observers below, which do not fire during
        // initialisation — so reading the stored values cannot write them back.
        repeatsPowerStatus = defaults.bool(forKey: Self.refireEnabledKey)
        refireMinutes = defaults.double(forKey: Self.refireMinutesKey)
        refireOnlyOnBattery = defaults.bool(forKey: Self.refireOnlyOnBatteryKey)
        checksBatteryHealth = defaults.bool(forKey: Self.healthEnabledKey)
        healthCheckDays = defaults.double(forKey: Self.healthDaysKey)
        lowSpacePercent = defaults.double(forKey: Self.lowSpacePercentKey)
        scannerStatusSeconds = defaults.double(forKey: Self.scannerStatusSecondsKey)
        wifiSignalSeconds = defaults.double(forKey: Self.wifiSignalSecondsKey)
        wifiSignalCooldownSeconds = defaults.double(forKey: Self.wifiSignalCooldownKey)
        connectionNaming = defaults.string(forKey: Self.connectionNamingKey)
            .flatMap(ConnectionNaming.init(rawValue:)) ?? .mediumAndType
    }

    var repeatsPowerStatus: Bool {
        didSet { defaults.set(repeatsPowerStatus, forKey: Self.refireEnabledKey); onChange?() }
    }

    var refireMinutes: Double {
        didSet { defaults.set(refireMinutes, forKey: Self.refireMinutesKey); onChange?() }
    }

    var refireOnlyOnBattery: Bool {
        didSet { defaults.set(refireOnlyOnBattery, forKey: Self.refireOnlyOnBatteryKey); onChange?() }
    }

    var checksBatteryHealth: Bool {
        didSet { defaults.set(checksBatteryHealth, forKey: Self.healthEnabledKey); onChange?() }
    }

    var healthCheckDays: Double {
        didSet { defaults.set(healthCheckDays, forKey: Self.healthDaysKey); onChange?() }
    }

    var lowSpacePercent: Double {
        didSet { defaults.set(lowSpacePercent, forKey: Self.lowSpacePercentKey); onChange?() }
    }

    /// How often a network scanner is asked what it is doing.
    ///
    /// Read at launch only, unlike the rest: the interval is handed to each scanner's own
    /// polling task when that scanner is discovered, and changing it mid-flight would mean
    /// tearing those down and rebuilding them — which would re-announce every scanner on
    /// the network as newly found.
    var scannerStatusSeconds: Double {
        didSet { defaults.set(scannerStatusSeconds, forKey: Self.scannerStatusSecondsKey) }
    }

    var scannerStatusInterval: Duration { .seconds(scannerStatusSeconds) }

    /// How connection notifications name what arrived, for USB, Bluetooth and
    /// Thunderbolt. Read at launch, since it is handed to each monitor when it is built.
    var connectionNaming: ConnectionNaming {
        didSet { defaults.set(connectionNaming.rawValue, forKey: Self.connectionNamingKey) }
    }

    /// How often the Wi-Fi signal is read, and how long to leave between saying anything
    /// about it. Both read at launch: they are handed to the source and the monitor when
    /// those are built.
    var wifiSignalSeconds: Double {
        didSet { defaults.set(wifiSignalSeconds, forKey: Self.wifiSignalSecondsKey) }
    }

    var wifiSignalCooldownSeconds: Double {
        didSet { defaults.set(wifiSignalCooldownSeconds, forKey: Self.wifiSignalCooldownKey) }
    }

    /// When the battery was last looked at, for the line under the "Check Now" button.
    /// Read fresh each time rather than observed: it changes once a week.
    var lastBatteryCheck: Date? {
        defaults.object(forKey: "Power.LastHealthCheck") as? Date
    }

    // MARK: - What the monitors are given

    var powerRefire: PowerRefireSettings {
        PowerRefireSettings(
            isEnabled: repeatsPowerStatus,
            minutes: refireMinutes,
            onlyOnBattery: refireOnlyOnBattery
        )
    }

    var powerHealthCheck: PowerHealthCheckSettings {
        PowerHealthCheckSettings(isEnabled: checksBatteryHealth, days: healthCheckDays)
    }

    private static let refireEnabledKey = "Power.EnableRefire"
    private static let refireMinutesKey = "Power.RefireMinutes"
    private static let refireOnlyOnBatteryKey = "Power.RefireOnBatteryOnly"
    private static let healthEnabledKey = "Power.EnableHealthCheck"
    private static let healthDaysKey = "Power.HealthCheckDays"
    private static let lowSpacePercentKey = "Volume.LowSpacePercent"
    private static let scannerStatusSecondsKey = "Scanner.StatusIntervalSeconds"
    private static let wifiSignalSecondsKey = "Network.WifiSignalPollSeconds"
    private static let wifiSignalCooldownKey = "Network.WifiSignalCooldownSeconds"
    private static let connectionNamingKey = "HardwareSentry.ConnectionNaming"
}
