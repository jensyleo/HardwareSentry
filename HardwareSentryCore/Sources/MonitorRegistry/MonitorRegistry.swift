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
        announcesWhatIsAlreadyThere: Bool = true
    ) {
        self.dispatcher = dispatcher
        self.preferences = preferences
        self.announcesWhatIsAlreadyThere = announcesWhatIsAlreadyThere
    }

    /// Builds every monitor. Each is handed only what it needs, and never a way to reach
    /// another one.
    public func assemble() {
        monitors = [
            USBMonitor(
                source: IOKitUSBDeviceSource(),
                context: MonitorContext(dispatcher: dispatcher, category: USBMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere)
            ),
            ThermalMonitor(
                source: SystemThermalStateSource(),
                context: MonitorContext(dispatcher: dispatcher, category: ThermalMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere)
            ),
            GamepadMonitor(
                source: GameControllerSource(),
                context: MonitorContext(dispatcher: dispatcher, category: GamepadMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere)
            ),
            ThunderboltMonitor(
                source: IOKitThunderboltDeviceSource(),
                context: MonitorContext(dispatcher: dispatcher, category: ThunderboltMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere)
            ),
            CameraMonitor(
                source: AVFoundationCameraSource(),
                context: MonitorContext(dispatcher: dispatcher, category: CameraMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere)
            ),
            DisplayMonitor(
                source: CoreGraphicsDisplaySource(),
                context: MonitorContext(dispatcher: dispatcher, category: DisplayMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere)
            ),
            PrinterMonitor(
                source: CUPSPrinterSource(),
                context: MonitorContext(dispatcher: dispatcher, category: PrinterMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere)
            ),
            BluetoothMonitor(
                source: IOBluetoothSource(),
                context: MonitorContext(dispatcher: dispatcher, category: BluetoothMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere)
            ),
            AudioMonitor(
                source: CoreAudioSource(),
                context: MonitorContext(dispatcher: dispatcher, category: AudioMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere)
            ),
            VolumeMonitor(
                source: NSWorkspaceVolumeSource(),
                context: MonitorContext(dispatcher: dispatcher, category: VolumeMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere)
            ),
            PowerMonitor(
                source: IOPSPowerSource(),
                context: MonitorContext(dispatcher: dispatcher, category: PowerMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere)
            ),
            NetworkMonitor(
                source: SystemNetworkSource(),
                context: MonitorContext(dispatcher: dispatcher, category: NetworkMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere)
            ),
            ScannerMonitor(
                source: BonjourScannerSource(),
                context: MonitorContext(dispatcher: dispatcher, category: ScannerMonitor.category, preferences: preferences, announcesWhatIsAlreadyThere: announcesWhatIsAlreadyThere)
            )
        ]
    }

    /// What every assembled monitor can raise and can optionally say, for a preferences
    /// screen to list. Built from each monitor's own declarations, so a monitor gaining an
    /// event or a field gains a row without this list being touched.
    public func describe() -> [MonitorDescription] {
        [
            Self.describing(USBMonitor.self),
            Self.describing(ThermalMonitor.self),
            Self.describing(GamepadMonitor.self),
            Self.describing(ThunderboltMonitor.self),
            Self.describing(CameraMonitor.self),
            Self.describing(DisplayMonitor.self),
            Self.describing(PrinterMonitor.self),
            Self.describing(BluetoothMonitor.self),
            Self.describing(AudioMonitor.self),
            Self.describing(VolumeMonitor.self),
            Self.describing(PowerMonitor.self),
            Self.describing(NetworkMonitor.self),
            Self.describing(ScannerMonitor.self)
        ]
    }

    private static func describing<M: Monitor>(_ monitor: M.Type) -> MonitorDescription {
        MonitorDescription(
            category: M.category,
            events: M.events,
            fields: M.fields,
            enabledByDefault: M.enabledByDefault
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
