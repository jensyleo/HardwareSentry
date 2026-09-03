import Foundation
import MonitorRegistry
import PowerMonitor
import SentryContract
import ScannerMonitor
import VolumeMonitor
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
            Self.healthNotifyHoursKey: 8.0,
            Self.lowSpacePercentKey: 5.0,
            Self.audioVolumeCriticalKey: 90.0,
            Self.virtualAudioDevicesKey: false,
            Self.virtualCameraDevicesKey: false,
            Self.usbAudioDevicesKey: true,
            Self.usbCameraDevicesKey: true,
            Self.videoLinkSecondsKey: 5.0,
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
        notifiesHealthReminder = defaults.bool(forKey: Self.healthNotifyEnabledKey)
        healthNotifyHours = defaults.double(forKey: Self.healthNotifyHoursKey)
        lowSpacePercent = defaults.double(forKey: Self.lowSpacePercentKey)
        audioVolumeCriticalPercent = defaults.double(forKey: Self.audioVolumeCriticalKey)
        notifiesVirtualAudioDevices = defaults.bool(forKey: Self.virtualAudioDevicesKey)
        notifiesVirtualCameraDevices = defaults.bool(forKey: Self.virtualCameraDevicesKey)
        notifiesUSBAudioDevices = defaults.bool(forKey: Self.usbAudioDevicesKey)
        notifiesUSBCameraDevices = defaults.bool(forKey: Self.usbCameraDevicesKey)
        videoLinkSeconds = defaults.double(forKey: Self.videoLinkSecondsKey)
        scannerStatusSeconds = defaults.double(forKey: Self.scannerStatusSecondsKey)
        wifiSignalSeconds = defaults.double(forKey: Self.wifiSignalSecondsKey)
        wifiSignalCooldownSeconds = defaults.double(forKey: Self.wifiSignalCooldownKey)
        ignoredDrives = defaults.stringArray(forKey: Self.ignoredDrivesKey) ?? []
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

    /// A more frequent, optional repeat of the same health numbers — hours rather than
    /// days, and separate from "Check every" above: this one is about hearing the figure
    /// again, not about whether it has moved.
    var notifiesHealthReminder: Bool {
        didSet { defaults.set(notifiesHealthReminder, forKey: Self.healthNotifyEnabledKey); onChange?() }
    }

    var healthNotifyHours: Double {
        didSet { defaults.set(healthNotifyHours, forKey: Self.healthNotifyHoursKey); onChange?() }
    }

    var lowSpacePercent: Double {
        didSet { defaults.set(lowSpacePercent, forKey: Self.lowSpacePercentKey); onChange?() }
    }

    /// How often the log is asked whether a video link appeared.
    ///
    /// Read at launch: the interval is handed to the detector's polling task when the
    /// module starts.
    var videoLinkSeconds: Double {
        didSet { defaults.set(videoLinkSeconds, forKey: Self.videoLinkSecondsKey); onChange?() }
    }

    var videoLinkPollInterval: Duration { .seconds(max(1, Int(videoLinkSeconds))) }

    /// Above this output level the "Volume Critical" warning fires.
    ///
    /// Adjustable because what counts as dangerously loud depends on what is plugged in:
    /// ninety percent into studio headphones is not ninety percent into a laptop speaker.
    var audioVolumeCriticalPercent: Double {
        didSet { defaults.set(audioVolumeCriticalPercent, forKey: Self.audioVolumeCriticalKey); onChange?() }
    }

    /// A Multi-Output/Aggregate device, or a driver an app like Zoom or Teams installs to
    /// capture what is playing, is software rather than something that arrived or left —
    /// off by default so it does not read as a plugged-in device.
    var notifiesVirtualAudioDevices: Bool {
        didSet { defaults.set(notifiesVirtualAudioDevices, forKey: Self.virtualAudioDevicesKey); onChange?() }
    }

    /// Same reasoning, for a camera an app makes up (OBS, a video-call plugin) rather
    /// than one that is actually plugged in or built in.
    var notifiesVirtualCameraDevices: Bool {
        didSet { defaults.set(notifiesVirtualCameraDevices, forKey: Self.virtualCameraDevicesKey); onChange?() }
    }

    /// On by default: the improvement over HG4MAC's own behaviour asked for directly — a
    /// USB audio device used to be left to USB Monitor's generic notice alone, and this is
    /// what lets whoever preferred that quieter pairing go back to it.
    var notifiesUSBAudioDevices: Bool {
        didSet { defaults.set(notifiesUSBAudioDevices, forKey: Self.usbAudioDevicesKey); onChange?() }
    }

    /// Same, for a camera arriving over USB.
    var notifiesUSBCameraDevices: Bool {
        didSet { defaults.set(notifiesUSBCameraDevices, forKey: Self.usbCameraDevicesKey); onChange?() }
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
    /// Volumes whose comings and goings are not worth a notification.
    ///
    /// A Time Machine disk that mounts on a schedule, or a virtual-machine image that
    /// mounts every time a VM starts, is a notification nobody caused and nobody wants.
    /// Held as one string per line, which is what a list somebody edits by hand should be.
    var ignoredDrives: [String] {
        didSet {
            defaults.set(ignoredDrives, forKey: Self.ignoredDrivesKey)
            onChange?()
        }
    }

    var volumeExclusions: VolumeExclusions { VolumeExclusions(patterns: ignoredDrives) }

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

    var powerHealthNotify: PowerHealthNotifySettings {
        PowerHealthNotifySettings(isEnabled: notifiesHealthReminder, hours: healthNotifyHours)
    }

    var powerHealthCheck: PowerHealthCheckSettings {
        PowerHealthCheckSettings(isEnabled: checksBatteryHealth, days: healthCheckDays)
    }

    private static let refireEnabledKey = "Power.EnableRefire"
    private static let refireMinutesKey = "Power.RefireMinutes"
    private static let refireOnlyOnBatteryKey = "Power.RefireOnBatteryOnly"
    private static let healthEnabledKey = "Power.EnableHealthCheck"
    private static let healthDaysKey = "Power.HealthCheckDays"
    private static let healthNotifyEnabledKey = "Power.HealthNotifyEnabled"
    private static let healthNotifyHoursKey = "Power.HealthNotifyHours"
    private static let lowSpacePercentKey = "Volume.LowSpacePercent"
    private static let audioVolumeCriticalKey = "Audio.VolumeCriticalPercent"
    private static let virtualAudioDevicesKey = "Audio.NotifiesVirtualDevices"
    private static let virtualCameraDevicesKey = "Camera.NotifiesVirtualDevices"
    private static let usbAudioDevicesKey = "Audio.NotifiesUSBDevices"
    private static let usbCameraDevicesKey = "Camera.NotifiesUSBDevices"
    private static let videoLinkSecondsKey = "Display.VideoLinkPollSeconds"
    private static let scannerStatusSecondsKey = "Scanner.StatusIntervalSeconds"
    private static let wifiSignalSecondsKey = "Network.WifiSignalPollSeconds"
    private static let wifiSignalCooldownKey = "Network.WifiSignalCooldownSeconds"
    private static let connectionNamingKey = "HardwareSentry.ConnectionNaming"
    private static let ignoredDrivesKey = "Volume.IgnoredDrives"
}
