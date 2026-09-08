import Foundation
import MonitorRegistry
import PowerMonitor
import SentryContract
import ScannerMonitor
import USBMonitor
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
            Self.usbGamepadDevicesKey: true,
            Self.usbIgnoresIdentifiedGenericDevicesKey: false,
            Self.usbSerialVendorAutoUpdateKey: true,
            Self.usbSerialVendorUpdateDaysKey: 30.0,
            Self.usbSerialVendorUpdateURLKey: USBSerialVendorDatabase.updateURL.absoluteString,
            Self.massStorageDetectionEnabledKey: true,
            Self.massStoragePollMillisecondsKey: 250.0,
            Self.massStorageTimeoutSecondsKey: 8.0,
            Self.wifiSignalPollingEnabledKey: true,
            Self.usbDetectsBluetoothAdaptersKey: true,
            Self.usbDetectsWiFiAdaptersKey: true,
            Self.videoLinkSecondsKey: 5.0,
            Self.scannerStatusSecondsKey: 10.0,
            Self.wifiSignalSecondsKey: 12.0,
            Self.wifiSignalCooldownKey: 10.0,
            Self.wifiRadioSecondsKey: 30.0,
            Self.bluetoothPairedSecondsKey: 15.0,
            Self.bluetoothSignalSecondsKey: 10.0,
            Self.bluetoothBLESecondsKey: 30.0,
            Self.printerSecondsKey: 8.0,
            Self.volumeFreeSpaceSecondsKey: 300.0,
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
        notifiesBluetoothAudioDevices = defaults.bool(forKey: Self.bluetoothAudioDevicesKey)
        // On unless somebody has said otherwise, which is how it has always behaved.
        notifiesBluetoothGamepadDevices = defaults.object(forKey: Self.bluetoothGamepadDevicesKey) as? Bool ?? true
        notifiesUSBGamepadDevices = defaults.bool(forKey: Self.usbGamepadDevicesKey)
        usbIgnoresIdentifiedGenericDevices = defaults.bool(forKey: Self.usbIgnoresIdentifiedGenericDevicesKey)
        usbSerialVendorAutoUpdate = defaults.bool(forKey: Self.usbSerialVendorAutoUpdateKey)
        usbSerialVendorUpdateDays = defaults.double(forKey: Self.usbSerialVendorUpdateDaysKey)
        usbSerialVendorUpdateURLString = defaults.string(forKey: Self.usbSerialVendorUpdateURLKey)
            ?? USBSerialVendorDatabase.updateURL.absoluteString
        massStorageDetectionEnabled = defaults.bool(forKey: Self.massStorageDetectionEnabledKey)
        massStoragePollMilliseconds = defaults.double(forKey: Self.massStoragePollMillisecondsKey)
        massStorageTimeoutSeconds = defaults.double(forKey: Self.massStorageTimeoutSecondsKey)
        wifiSignalPollingEnabled = defaults.bool(forKey: Self.wifiSignalPollingEnabledKey)
        usbDetectsBluetoothAdapters = defaults.bool(forKey: Self.usbDetectsBluetoothAdaptersKey)
        usbDetectsWiFiAdapters = defaults.bool(forKey: Self.usbDetectsWiFiAdaptersKey)
        videoLinkSeconds = defaults.double(forKey: Self.videoLinkSecondsKey)
        scannerStatusSeconds = defaults.double(forKey: Self.scannerStatusSecondsKey)
        wifiSignalSeconds = defaults.double(forKey: Self.wifiSignalSecondsKey)
        wifiSignalCooldownSeconds = defaults.double(forKey: Self.wifiSignalCooldownKey)
        wifiRadioSeconds = defaults.double(forKey: Self.wifiRadioSecondsKey)
        bluetoothPairedSeconds = defaults.double(forKey: Self.bluetoothPairedSecondsKey)
        bluetoothSignalSeconds = defaults.double(forKey: Self.bluetoothSignalSecondsKey)
        bluetoothBLESeconds = defaults.double(forKey: Self.bluetoothBLESecondsKey)
        printerSeconds = defaults.double(forKey: Self.printerSecondsKey)
        volumeFreeSpaceSeconds = defaults.double(forKey: Self.volumeFreeSpaceSecondsKey)
        ignoredDrives = defaults.stringArray(forKey: Self.ignoredDrivesKey) ?? []
        namesReportingModule = defaults.bool(forKey: Self.namesReportingModuleKey)
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

    /// "Notify for USB devices independently of USB Monitor" for audio.
    ///
    /// Audio Monitor always announces a USB device with its own, correct notice — that no
    /// longer depends on this. What this decides is whether USB Monitor's own generic
    /// notice *also* fires for the same physical device: on (the default) is both, the
    /// full detail of a redundant pair, matching the improvement over HG4MAC's own
    /// behaviour asked for directly; off folds USB Monitor's notice away and leaves only
    /// Audio's own.
    var notifiesUSBAudioDevices: Bool {
        didSet { defaults.set(notifiesUSBAudioDevices, forKey: Self.usbAudioDevicesKey); onChange?() }
    }

    /// Same, for a camera arriving over USB.
    /// Whether Audio Monitor also announces a Bluetooth accessory that Bluetooth Monitor
    /// already announced. Off by default, as it has always behaved.
    var notifiesBluetoothAudioDevices: Bool {
        didSet { defaults.set(notifiesBluetoothAudioDevices, forKey: Self.bluetoothAudioDevicesKey); onChange?() }
    }

    /// Whether Bluetooth Monitor announces a controller Gamepad Monitor also speaks for.
    /// On by default, as it has always behaved.
    var notifiesBluetoothGamepadDevices: Bool {
        didSet { defaults.set(notifiesBluetoothGamepadDevices, forKey: Self.bluetoothGamepadDevicesKey); onChange?() }
    }

    var notifiesUSBCameraDevices: Bool {
        didSet { defaults.set(notifiesUSBCameraDevices, forKey: Self.usbCameraDevicesKey); onChange?() }
    }

    /// Same, for a gamepad/joystick arriving over USB — Gamepad Monitor's own notice
    /// always fires regardless (it comes from GameController framework, not this switch);
    /// off only folds away USB Monitor's now-correctly-labelled "Gamepad/Joystick" row.
    var notifiesUSBGamepadDevices: Bool {
        didSet { defaults.set(notifiesUSBGamepadDevices, forKey: Self.usbGamepadDevicesKey); onChange?() }
    }

    /// Whether USB Monitor's generic row narrows to devices nothing at all is known
    /// about — off by default, so a device with a real class name but no row of its own
    /// (a hub's internal Billboard/Communications interface, most often) keeps
    /// announcing there exactly as it always has.
    var usbIgnoresIdentifiedGenericDevices: Bool {
        didSet { defaults.set(usbIgnoresIdentifiedGenericDevices, forKey: Self.usbIgnoresIdentifiedGenericDevicesKey); onChange?() }
    }

    /// Off falls a `0xE0` device back to the plain "Wireless Controller" row, exactly as
    /// it read before this distinction existed — see `USBWirelessDetectionSettings`. On
    /// by default: this is a reliable USB-IF signature, not a guess.
    var usbDetectsBluetoothAdapters: Bool {
        didSet { defaults.set(usbDetectsBluetoothAdapters, forKey: Self.usbDetectsBluetoothAdaptersKey); onChange?() }
    }

    /// Off stops an unclassified device from ever reading as "WiFi Adapter" on a
    /// vendor-ID guess — see `USBWiFiVendorDatabase`'s own doc comment for why this
    /// earned a separate switch from Bluetooth's: these vendors also sell plenty that is
    /// not WiFi, so this can mislabel one of those. On by default.
    var usbDetectsWiFiAdapters: Bool {
        didSet { defaults.set(usbDetectsWiFiAdapters, forKey: Self.usbDetectsWiFiAdaptersKey); onChange?() }
    }

    /// Whether the serial/debug-adapter vendor list (see `USBSerialVendorDatabase`) checks
    /// itself against its own GitHub-hosted copy on a schedule, rather than only when
    /// somebody presses "Check Now".
    var usbSerialVendorAutoUpdate: Bool {
        didSet { defaults.set(usbSerialVendorAutoUpdate, forKey: Self.usbSerialVendorAutoUpdateKey); onChange?() }
    }

    var usbSerialVendorUpdateDays: Double {
        didSet { defaults.set(usbSerialVendorUpdateDays, forKey: Self.usbSerialVendorUpdateDaysKey); onChange?() }
    }

    /// Where the serial-vendor list is actually fetched from, as raw, user-editable text —
    /// shown and changeable rather than hidden, since this is a Settings screen asking to
    /// reach out to the network on a schedule, not something to take on faith. Restored to
    /// `USBSerialVendorDatabase.updateURL` (this application's own GitHub copy) by
    /// "Restore Defaults" on this section.
    var usbSerialVendorUpdateURLString: String {
        didSet { defaults.set(usbSerialVendorUpdateURLString, forKey: Self.usbSerialVendorUpdateURLKey); onChange?() }
    }

    /// The parsed form `checkSerialVendorUpdateNow`/the scheduled check actually use.
    /// Falls back to the built-in URL for anything that fails to parse, rather than
    /// refusing to check at all over a typo.
    var usbSerialVendorUpdateURL: URL {
        URL(string: usbSerialVendorUpdateURLString) ?? USBSerialVendorDatabase.updateURL
    }

    func restoreSerialVendorUpdateURLDefault() {
        usbSerialVendorUpdateURLString = USBSerialVendorDatabase.updateURL.absoluteString
    }

    /// Off skips the retry outright — an ambiguous disk is announced immediately, as
    /// generically classified as it would have been before this feature existed, and no
    /// background polling task ever runs for it. On by default, matching every prior
    /// behaviour.
    var massStorageDetectionEnabled: Bool {
        didSet { defaults.set(massStorageDetectionEnabled, forKey: Self.massStorageDetectionEnabledKey); onChange?() }
    }

    /// How often an unresolved Mass Storage device is re-checked while USB Monitor waits
    /// for its disk description — see `IOKitUSBDeviceSource`'s own retry. Mirrors Wi-Fi's
    /// two-slider shape (`wifiSignalSeconds`/`wifiSignalCooldownSeconds`) on purpose:
    /// same idea, a check interval and a bound on how long to keep checking. Takes effect
    /// the next time the application starts, like every other USB source setting here.
    var massStoragePollMilliseconds: Double {
        didSet { defaults.set(massStoragePollMilliseconds, forKey: Self.massStoragePollMillisecondsKey); onChange?() }
    }

    /// The backstop: a device that still has not resolved by this deadline stays as
    /// generically classified as it always would have been. Measured at 8s against a
    /// real slow enclosure — see `IOKitUSBDeviceSource.enrichedMassStorageHint`'s own
    /// comment — lowering it risks reintroducing that exact, already-fixed bug for a
    /// disk slower than whatever this is tested against.
    var massStorageTimeoutSeconds: Double {
        didSet { defaults.set(massStorageTimeoutSeconds, forKey: Self.massStorageTimeoutSecondsKey); onChange?() }
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

    /// Whether every message ends with the module that raised it. Off by default — see
    /// `MonitorContext.namesReportingModule`.
    var namesReportingModule: Bool {
        didSet { defaults.set(namesReportingModule, forKey: Self.namesReportingModuleKey); onChange?() }
    }

    var connectionNaming: ConnectionNaming {
        didSet { defaults.set(connectionNaming.rawValue, forKey: Self.connectionNamingKey) }
    }

    /// Off stops the signal-strength timer entirely — no signal read, no
    /// promiscuous-interface check, no bond-member check, since all three share this one
    /// cadence (see `SystemNetworkSource.startWiFiSignalPoll`). For whoever wants zero
    /// periodic work from this feature rather than a slower one. On by default.
    var wifiSignalPollingEnabled: Bool {
        didSet { defaults.set(wifiSignalPollingEnabled, forKey: Self.wifiSignalPollingEnabledKey); onChange?() }
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

    /// How often the Wi-Fi radio's own power state and interface mode are re-checked, as
    /// a backstop behind the push notification that usually reports a change immediately.
    /// Cheap (a single flag read) but a real, periodic wake-up, so it is a setting rather
    /// than an unconditional number.
    var wifiRadioSeconds: Double {
        didSet { defaults.set(wifiRadioSeconds, forKey: Self.wifiRadioSecondsKey) }
    }

    /// How often the paired-Bluetooth-device list is re-read. There is no push
    /// notification for pairing-list membership changing, only for one specific device
    /// connecting or disconnecting.
    var bluetoothPairedSeconds: Double {
        didSet { defaults.set(bluetoothPairedSeconds, forKey: Self.bluetoothPairedSecondsKey) }
    }

    /// How often connected Bluetooth devices' signal strength (RSSI) is re-read — the
    /// same question Wi-Fi's own signal poll answers, for the same reason: no
    /// notification exists for a signal moving.
    var bluetoothSignalSeconds: Double {
        didSet { defaults.set(bluetoothSignalSeconds, forKey: Self.bluetoothSignalSecondsKey) }
    }

    /// How often CoreBluetooth-connected BLE accessories are re-read. Slower than the
    /// other two by design — a BLE accessory does not come and go the way a cable does.
    var bluetoothBLESeconds: Double {
        didSet { defaults.set(bluetoothBLESeconds, forKey: Self.bluetoothBLESecondsKey) }
    }

    /// How often CUPS's destination and job lists are re-read. Neither libcups nor
    /// AppKit's printing API offers a push notification for "a printer was added" or "a
    /// job's state changed" — confirmed in HG4MAC's own history.
    var printerSeconds: Double {
        didSet { defaults.set(printerSeconds, forKey: Self.printerSecondsKey) }
    }

    /// How often free space is re-read for every mounted volume. There is no notification
    /// for free space changing, and this already defaults to five minutes precisely
    /// because a disk read on every mounted volume is the heaviest of these six.
    var volumeFreeSpaceSeconds: Double {
        didSet { defaults.set(volumeFreeSpaceSeconds, forKey: Self.volumeFreeSpaceSecondsKey) }
    }

    var wifiRadioPollInterval: TimeInterval { max(5, wifiRadioSeconds) }
    var bluetoothPairedPollInterval: Duration { .seconds(max(1, Int(bluetoothPairedSeconds))) }
    var bluetoothSignalPollInterval: Duration { .seconds(max(1, Int(bluetoothSignalSeconds))) }
    var bluetoothBLEPollInterval: Duration { .seconds(max(1, Int(bluetoothBLESeconds))) }
    var printerPollInterval: Duration { .seconds(max(1, Int(printerSeconds))) }
    var volumeFreeSpacePollInterval: Duration { .seconds(max(1, Int(volumeFreeSpaceSeconds))) }

    /// When the battery was last looked at, for the line under the "Check Now" button.
    /// Read fresh each time rather than observed: it changes once a week.
    var lastBatteryCheck: Date? {
        defaults.object(forKey: "Power.LastHealthCheck") as? Date
    }

    /// When the serial-vendor list was last checked against its remote copy — by the
    /// schedule or by "Check Now", either one. `nil` before the first check ever runs.
    var lastSerialVendorUpdate: Date? {
        get { defaults.object(forKey: "USB.LastSerialVendorUpdate") as? Date }
        set { defaults.set(newValue, forKey: "USB.LastSerialVendorUpdate") }
    }

    /// What the most recent "Check Now" actually did — new vendors merged in, nothing new
    /// to add, or the request itself failed. Session-only, on purpose: this is feedback
    /// for the button that was just pressed, not a durable setting, so it is never written
    /// to `UserDefaults` and starts `nil` again on every launch.
    var serialVendorUpdateStatus: String?

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
    private static let bluetoothAudioDevicesKey = "Audio.NotifiesBluetoothDevices"
    private static let bluetoothGamepadDevicesKey = "Bluetooth.NotifiesGamepadDevices"
    private static let usbGamepadDevicesKey = "Gamepad.NotifiesUSBDevices"
    private static let usbIgnoresIdentifiedGenericDevicesKey = "USB.IgnoresIdentifiedGenericDevices"
    private static let usbSerialVendorAutoUpdateKey = "USB.SerialVendorAutoUpdate"
    private static let usbSerialVendorUpdateDaysKey = "USB.SerialVendorUpdateDays"
    private static let usbSerialVendorUpdateURLKey = "USB.SerialVendorUpdateURL"
    private static let massStorageDetectionEnabledKey = "USB.MassStorageDetectionEnabled"
    private static let massStoragePollMillisecondsKey = "USB.MassStoragePollMilliseconds"
    private static let massStorageTimeoutSecondsKey = "USB.MassStorageTimeoutSeconds"
    private static let wifiSignalPollingEnabledKey = "Network.WiFiSignalPollingEnabled"
    private static let usbDetectsBluetoothAdaptersKey = "USB.DetectsBluetoothAdapters"
    private static let usbDetectsWiFiAdaptersKey = "USB.DetectsWiFiAdapters"
    private static let videoLinkSecondsKey = "Display.VideoLinkPollSeconds"
    private static let scannerStatusSecondsKey = "Scanner.StatusIntervalSeconds"
    private static let wifiSignalSecondsKey = "Network.WifiSignalPollSeconds"
    private static let wifiSignalCooldownKey = "Network.WifiSignalCooldownSeconds"
    private static let wifiRadioSecondsKey = "Network.WifiRadioPollSeconds"
    private static let bluetoothPairedSecondsKey = "Bluetooth.PairedPollSeconds"
    private static let bluetoothSignalSecondsKey = "Bluetooth.SignalPollSeconds"
    private static let bluetoothBLESecondsKey = "Bluetooth.BLEPollSeconds"
    private static let printerSecondsKey = "Printer.PollSeconds"
    private static let volumeFreeSpaceSecondsKey = "Volume.FreeSpacePollSeconds"
    private static let connectionNamingKey = "HardwareSentry.ConnectionNaming"
    private static let namesReportingModuleKey = "HardwareSentry.NamesReportingModule"
    private static let ignoredDrivesKey = "Volume.IgnoredDrives"
}
