import AudioMonitor
import BluetoothMonitor
import CameraMonitor
import DisplayMonitor
import Foundation
import GamepadMonitor
import NetworkMonitor
import PowerMonitor
import PrinterMonitor
import ScannerMonitor
import SentryContract
import SignalCore
import ThermalMonitor
import ThunderboltMonitor
import USBMonitor
import VolumeMonitor

/// Puts the monitors together and runs them.
///
/// The only place that knows the whole list. Adding, removing or reordering a monitor is
/// a change here and nowhere else — which is the job the plugin loader used to do,
/// settled at compile time instead.
///
/// Loading monitors written by other people was considered and rejected: a bundle loaded
/// into this process would inherit every permission the person granted this application —
/// Bluetooth, camera, microphone, location, local network — and could bring the whole
/// thing down by crashing. Anything new is added here, in the open, where it can be read.
public actor MonitorRegistry {
    private let dispatcher: NotificationDispatcher
    private let preferences: NotificationPreferencesStore
    private let announcesWhatIsAlreadyThere: Bool
    private let powerRefire: PowerRefireSettings
    private let powerHealthCheck: PowerHealthCheckSettings
    private let powerHealthNotify: PowerHealthNotifySettings
    private let powerHealthStore: any PowerHealthStore
    private let volumeLowSpacePercent: Double
    private let audioVolumeCriticalPercent: Int
    private let audioNotifiesVirtualDevices: Bool
    private let cameraNotifiesVirtualDevices: Bool
    /// "Notify for USB devices independently of USB Monitor", one per module.
    ///
    /// Camera and Audio always announce a device with their own, correctly-worded notice
    /// — that no longer depends on this. What this decides is whether USB Monitor's own
    /// generic notice *also* fires for a device kind one of them already covers: **on**
    /// means both fire, the full detail of a redundant pair; **off** means USB Monitor
    /// stays quiet about it and the specific notice is the only one. See
    /// `kindsCoveredElsewhere(cameraNotifiesUSBDevices:audioNotifiesUSBDevices:)`.
    private let audioNotifiesUSBDevices: Bool
    private let cameraNotifiesUSBDevices: Bool
    /// USB Monitor's own generic row, narrowed to devices nothing at all is known about —
    /// see `USBMonitor.ignoresIdentifiedGenericDevices`.
    private let usbIgnoresIdentifiedGenericDevices: Bool
    private let scannerStatusInterval: Duration
    private let networkSignalPolling: SystemNetworkSource.SignalPolling
    private let networkRadioPollInterval: TimeInterval
    private let networkSignalCooldown: TimeInterval
    private let videoLinkPollInterval: Duration
    private let connectionNaming: ConnectionNaming
    private let volumeExclusions: VolumeExclusions
    private let bluetoothPairedPollInterval: Duration
    private let bluetoothSignalPollInterval: Duration
    private let bluetoothBLEPollInterval: Duration
    private let printerPollInterval: Duration
    private let volumeFreeSpacePollInterval: Duration
    private var monitors: [any Monitor] = []

    /// Whether monitors announce what they find already there when they start.
    ///
    /// One switch for the whole application rather than one per module, because it is one
    /// decision: either launching tells you what this machine has plugged into it, or it
    /// stays quiet until something changes. On by default — a hardware notifier that says
    /// nothing when it starts looks like one that failed to start.
    public init(
        dispatcher: NotificationDispatcher,
        preferences: NotificationPreferencesStore,
        announcesWhatIsAlreadyThere: Bool = true,
        powerRefire: PowerRefireSettings = .off,
        powerHealthCheck: PowerHealthCheckSettings = PowerHealthCheckSettings(),
        powerHealthNotify: PowerHealthNotifySettings = .off,
        powerHealthStore: any PowerHealthStore = UserDefaultsPowerHealthStore(),
        volumeLowSpacePercent: Double = 5,
        audioVolumeCriticalPercent: Int = 90,
        audioNotifiesVirtualDevices: Bool = false,
        cameraNotifiesVirtualDevices: Bool = false,
        audioNotifiesUSBDevices: Bool = true,
        cameraNotifiesUSBDevices: Bool = true,
        usbIgnoresIdentifiedGenericDevices: Bool = false,
        scannerStatusInterval: Duration = .seconds(10),
        networkSignalPolling: SystemNetworkSource.SignalPolling = .init(),
        networkRadioPollInterval: TimeInterval = 30,
        networkSignalCooldown: TimeInterval = 10,
        videoLinkPollInterval: Duration = .seconds(5),
        connectionNaming: ConnectionNaming = .mediumAndType,
        volumeExclusions: VolumeExclusions = VolumeExclusions(),
        bluetoothPairedPollInterval: Duration = .seconds(15),
        bluetoothSignalPollInterval: Duration = .seconds(10),
        bluetoothBLEPollInterval: Duration = .seconds(30),
        printerPollInterval: Duration = .seconds(8),
        volumeFreeSpacePollInterval: Duration = .seconds(300)
    ) {
        self.dispatcher = dispatcher
        self.preferences = preferences
        self.announcesWhatIsAlreadyThere = announcesWhatIsAlreadyThere
        self.powerRefire = powerRefire
        self.powerHealthCheck = powerHealthCheck
        self.powerHealthNotify = powerHealthNotify
        self.powerHealthStore = powerHealthStore
        self.volumeLowSpacePercent = volumeLowSpacePercent
        self.audioVolumeCriticalPercent = audioVolumeCriticalPercent
        self.audioNotifiesVirtualDevices = audioNotifiesVirtualDevices
        self.cameraNotifiesVirtualDevices = cameraNotifiesVirtualDevices
        self.audioNotifiesUSBDevices = audioNotifiesUSBDevices
        self.cameraNotifiesUSBDevices = cameraNotifiesUSBDevices
        self.usbIgnoresIdentifiedGenericDevices = usbIgnoresIdentifiedGenericDevices
        self.scannerStatusInterval = scannerStatusInterval
        self.networkSignalPolling = networkSignalPolling
        self.networkRadioPollInterval = networkRadioPollInterval
        self.networkSignalCooldown = networkSignalCooldown
        self.videoLinkPollInterval = videoLinkPollInterval
        self.connectionNaming = connectionNaming
        self.volumeExclusions = volumeExclusions
        self.bluetoothPairedPollInterval = bluetoothPairedPollInterval
        self.bluetoothSignalPollInterval = bluetoothSignalPollInterval
        self.bluetoothBLEPollInterval = bluetoothBLEPollInterval
        self.printerPollInterval = printerPollInterval
        self.volumeFreeSpacePollInterval = volumeFreeSpacePollInterval
    }

    /// Passes changed tuning to the monitors that care about it, without rebuilding them.
    public func apply(
        powerRefire: PowerRefireSettings,
        powerHealthCheck: PowerHealthCheckSettings,
        powerHealthNotify: PowerHealthNotifySettings,
        volumeLowSpacePercent: Double,
        volumeExclusions: VolumeExclusions,
        audioVolumeCriticalPercent: Int,
        audioNotifiesVirtualDevices: Bool,
        cameraNotifiesVirtualDevices: Bool,
        audioNotifiesUSBDevices: Bool,
        cameraNotifiesUSBDevices: Bool,
        usbIgnoresIdentifiedGenericDevices: Bool
    ) async {
        for monitor in monitors {
            if let power = monitor as? PowerMonitor {
                await power.apply(refire: powerRefire, healthCheck: powerHealthCheck, healthNotify: powerHealthNotify)
            }
            if let audio = monitor as? AudioMonitor {
                await audio.apply(volumeCriticalThreshold: audioVolumeCriticalPercent, notifiesVirtualDevices: audioNotifiesVirtualDevices)
            }
            if let camera = monitor as? CameraMonitor {
                await camera.apply(notifiesVirtualDevices: cameraNotifiesVirtualDevices)
            }
            if let usb = monitor as? USBMonitor {
                await usb.apply(
                    kindsCoveredElsewhere: Self.kindsCoveredElsewhere(
                        cameraNotifiesUSBDevices: cameraNotifiesUSBDevices,
                        audioNotifiesUSBDevices: audioNotifiesUSBDevices
                    ),
                    ignoresIdentifiedGenericDevices: usbIgnoresIdentifiedGenericDevices
                )
            }
            if let volume = monitor as? VolumeMonitor {
                await volume.apply(
                    lowSpaceThresholdPercent: volumeLowSpacePercent,
                    exclusions: volumeExclusions
                )
            }
        }
    }

    /// Fires one thermal transition on demand, for the settings screen's Simulate button.
    public func simulateThermalTransition(from: ThermalState, to: ThermalState) async {
        for case let thermal as ThermalMonitor in monitors {
            await thermal.simulate(from: from, to: to)
        }
    }

    /// Reads the battery's condition right now, whatever the schedule says.
    ///
    /// What the "Check Now" button calls. Reached by asking the assembled monitors rather
    /// than by keeping a reference to the power monitor: this type's whole job is that
    /// nothing outside it knows which monitors exist, and one button is not a reason to
    /// give that up.
    public func checkBatteryHealthNow() async {
        for case let power as PowerMonitor in monitors {
            await power.checkBatteryHealthNow(force: true)
        }
    }

    /// Which USB device kinds USB Monitor should stay quiet about right now — see
    /// `USBMonitor.kindsCoveredElsewhere`.
    ///
    /// Inverted from how this reads at first glance, on purpose: "Notify for USB devices
    /// independently of USB Monitor" **off** is what asks for *fewer* notices, not more —
    /// Camera or Audio's own, correctly-worded one is enough, and USB Monitor's redundant
    /// generic one for the same physical device is what gets folded away. A kind is only
    /// ever folded away while its own module actually covers it; a kind neither module has
    /// an opinion on is never included, so it keeps its own notice regardless.
    private static func kindsCoveredElsewhere(
        cameraNotifiesUSBDevices: Bool,
        audioNotifiesUSBDevices: Bool
    ) -> Set<USBDeviceKind> {
        var kinds: Set<USBDeviceKind> = []
        if !cameraNotifiesUSBDevices { kinds.insert(.webcam) }
        if !audioNotifiesUSBDevices { kinds.insert(.audio) }
        // A device that is genuinely both — a webcam with a real microphone, not an
        // incidental one — reads as `.audioVideo` (`USBDeviceKind`'s own interface
        // fallback), and neither switch prevails over the other for it: only when both
        // say their own notice already covers it does USB Monitor's redundant one fold
        // away, so turning one module's switch off alone never silences the other's say.
        if !cameraNotifiesUSBDevices && !audioNotifiesUSBDevices { kinds.insert(.audioVideo) }
        return kinds
    }

    /// Builds every monitor. Each is handed only what it needs, and never a way to reach
    /// another one.
    public func assemble() {
        monitors = [
            USBMonitor(
                source: IOKitUSBDeviceSource(),
                context: MonitorContext(dispatcher: dispatcher, category: USBMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere, connectionNaming: connectionNaming),
                kindsCoveredElsewhere: Self.kindsCoveredElsewhere(
                    cameraNotifiesUSBDevices: cameraNotifiesUSBDevices,
                    audioNotifiesUSBDevices: audioNotifiesUSBDevices
                ),
                ignoresIdentifiedGenericDevices: usbIgnoresIdentifiedGenericDevices
            ),
            ThermalMonitor(
                source: SystemThermalStateSource(),
                context: MonitorContext(dispatcher: dispatcher, category: ThermalMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere, connectionNaming: connectionNaming)
            ),
            GamepadMonitor(
                source: GameControllerSource(),
                context: MonitorContext(dispatcher: dispatcher, category: GamepadMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere, connectionNaming: connectionNaming)
            ),
            ThunderboltMonitor(
                source: IOKitThunderboltDeviceSource(),
                context: MonitorContext(dispatcher: dispatcher, category: ThunderboltMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere, connectionNaming: connectionNaming)
            ),
            CameraMonitor(
                source: AVFoundationCameraSource(),
                context: MonitorContext(dispatcher: dispatcher, category: CameraMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere, connectionNaming: connectionNaming),
                notifiesVirtualDevices: cameraNotifiesVirtualDevices
            ),
            DisplayMonitor(
                // The experimental video-link poll runs only when its notification is
                // switched on: it reads undocumented kernel log text every few seconds,
                // and doing that for somebody who has not asked for it would be a real
                // cost for no news they wanted.
                source: CoreGraphicsDisplaySource(
                    videoLinkPolling: preferences.isEnabled(DisplayEvent.linkDetected.rawValue, in: DisplayMonitor.category)
                        ? videoLinkPollInterval
                        : nil
                ),
                context: MonitorContext(dispatcher: dispatcher, category: DisplayMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere, connectionNaming: connectionNaming)
            ),
            PrinterMonitor(
                source: CUPSPrinterSource(pollInterval: printerPollInterval),
                context: MonitorContext(dispatcher: dispatcher, category: PrinterMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere, connectionNaming: connectionNaming)
            ),
            BluetoothMonitor(
                source: IOBluetoothSource(
                    pairedPollInterval: bluetoothPairedPollInterval,
                    signalPollInterval: bluetoothSignalPollInterval,
                    blePollInterval: bluetoothBLEPollInterval
                ),
                context: MonitorContext(dispatcher: dispatcher, category: BluetoothMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere, connectionNaming: connectionNaming)
            ),
            AudioMonitor(
                source: CoreAudioSource(),
                context: MonitorContext(dispatcher: dispatcher, category: AudioMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere, connectionNaming: connectionNaming),
                volumeCriticalThreshold: audioVolumeCriticalPercent,
                notifiesVirtualDevices: audioNotifiesVirtualDevices
            ),
            VolumeMonitor(
                source: NSWorkspaceVolumeSource(freeSpacePollInterval: volumeFreeSpacePollInterval),
                context: MonitorContext(dispatcher: dispatcher, category: VolumeMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere, connectionNaming: connectionNaming),
                exclusions: volumeExclusions,
                lowSpaceThresholdPercent: volumeLowSpacePercent
            ),
            PowerMonitor(
                source: IOPSPowerSource(),
                context: MonitorContext(dispatcher: dispatcher, category: PowerMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere, connectionNaming: connectionNaming),
                refire: powerRefire,
                healthCheck: powerHealthCheck,
                healthNotify: powerHealthNotify,
                healthStore: powerHealthStore
            ),
            NetworkMonitor(
                source: SystemNetworkSource(signalPolling: networkSignalPolling, radioPollInterval: networkRadioPollInterval),
                context: MonitorContext(dispatcher: dispatcher, category: NetworkMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere, connectionNaming: connectionNaming),
                signalCooldown: networkSignalCooldown
            ),
            ScannerMonitor(
                source: BonjourScannerSource(),
                context: MonitorContext(dispatcher: dispatcher, category: ScannerMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere, connectionNaming: connectionNaming),
                statusReader: eSCLStatusReader(),
                statusInterval: scannerStatusInterval
            )
        ]
    }

    /// What every assembled monitor can raise and can optionally say, for a preferences
    /// screen to list. Built from each monitor's own declarations, so a monitor gaining an
    /// event or a field gains a row without this list being touched.
    public func describe() -> [MonitorDescription] { Self.catalogue }

    /// The same list without a registry to hold it.
    ///
    /// Wanted by the parity audit, which reads the whole catalogue but has no dispatcher
    /// to give a registry and no business starting one. Describing is a question about the
    /// types, not about a running instance, so it does not need one.
    public static let catalogue: [MonitorDescription] = [
            MonitorRegistry.describing(USBMonitor.self),
            MonitorRegistry.describing(ThermalMonitor.self),
            MonitorRegistry.describing(GamepadMonitor.self),
            MonitorRegistry.describing(ThunderboltMonitor.self),
            MonitorRegistry.describing(CameraMonitor.self),
            MonitorRegistry.describing(DisplayMonitor.self),
            MonitorRegistry.describing(PrinterMonitor.self),
            MonitorRegistry.describing(BluetoothMonitor.self),
            MonitorRegistry.describing(AudioMonitor.self),
            MonitorRegistry.describing(VolumeMonitor.self),
            MonitorRegistry.describing(PowerMonitor.self),
            MonitorRegistry.describing(NetworkMonitor.self),
            MonitorRegistry.describing(ScannerMonitor.self)
    ]

    private static func describing<M: Monitor>(_ monitor: M.Type) -> MonitorDescription {
        MonitorDescription(
            category: M.category,
            events: M.events,
            fields: M.fields,
            enabledByDefault: M.enabledByDefault,
            icon: M.icon,
            eventListHeading: M.eventListHeading
        )
    }

    /// Starts the monitors someone actually wants, and only those.
    ///
    /// A module switched off is not merely silenced: it does not run. That matters beyond
    /// tidiness — several monitors poll (printers every few seconds, paired Bluetooth
    /// devices, free disk space), and one of them cannot even begin without macOS asking
    /// the person for permission. Work nobody asked for should not be done.
    public func start() async {
        if monitors.isEmpty { assemble() }
        await matchRunningToWanted()
    }

    /// Called when the settings change, so switching a module on or off takes effect now
    /// rather than at the next launch.
    public func refresh() async {
        guard !monitors.isEmpty else { return }
        await matchRunningToWanted()
    }

    private func matchRunningToWanted() async {
        for monitor in monitors {
            // Both are safe to call again: starting a running monitor and stopping a
            // stopped one are no-ops, so this needs no record of what it did last time.
            if await preferences.isCategoryEnabled(monitor.category) {
                await monitor.start()
            } else {
                await monitor.stop()
            }
        }
    }

    public func stop() async {
        for monitor in monitors {
            await monitor.stop()
        }
    }

    var monitorCount: Int { monitors.count }
}
