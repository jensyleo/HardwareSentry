import AudioMonitor
import BluetoothMonitor
import CameraMonitor
import DisplayMonitor
import Foundation
import GamepadMonitor
import NetworkMonitor
import PowerMonitor
import PrinterMonitor
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
    private var monitors: [any Monitor] = []

    public init(dispatcher: NotificationDispatcher, preferences: NotificationPreferencesStore) {
        self.dispatcher = dispatcher
        self.preferences = preferences
    }

    /// Builds every monitor. Each is handed only what it needs, and never a way to reach
    /// another one.
    public func assemble() {
        monitors = [
            USBMonitor(
                source: IOKitUSBDeviceSource(),
                context: MonitorContext(dispatcher: dispatcher, category: USBMonitor.category, preferences: preferences)
            ),
            ThermalMonitor(
                source: SystemThermalStateSource(),
                context: MonitorContext(dispatcher: dispatcher, category: ThermalMonitor.category, preferences: preferences)
            ),
            GamepadMonitor(
                source: GameControllerSource(),
                context: MonitorContext(dispatcher: dispatcher, category: GamepadMonitor.category, preferences: preferences)
            ),
            ThunderboltMonitor(
                source: IOKitThunderboltDeviceSource(),
                context: MonitorContext(dispatcher: dispatcher, category: ThunderboltMonitor.category, preferences: preferences)
            ),
            CameraMonitor(
                source: AVFoundationCameraSource(),
                context: MonitorContext(dispatcher: dispatcher, category: CameraMonitor.category, preferences: preferences)
            ),
            DisplayMonitor(
                source: CoreGraphicsDisplaySource(),
                context: MonitorContext(dispatcher: dispatcher, category: DisplayMonitor.category, preferences: preferences)
            ),
            PrinterMonitor(
                source: CUPSPrinterSource(),
                context: MonitorContext(dispatcher: dispatcher, category: PrinterMonitor.category, preferences: preferences)
            ),
            BluetoothMonitor(
                source: IOBluetoothSource(),
                context: MonitorContext(dispatcher: dispatcher, category: BluetoothMonitor.category, preferences: preferences)
            ),
            AudioMonitor(
                source: CoreAudioSource(),
                context: MonitorContext(dispatcher: dispatcher, category: AudioMonitor.category, preferences: preferences)
            ),
            VolumeMonitor(
                source: NSWorkspaceVolumeSource(),
                context: MonitorContext(dispatcher: dispatcher, category: VolumeMonitor.category, preferences: preferences)
            ),
            PowerMonitor(
                source: IOPSPowerSource(),
                context: MonitorContext(dispatcher: dispatcher, category: PowerMonitor.category, preferences: preferences)
            ),
            NetworkMonitor(
                source: SystemNetworkSource(),
                context: MonitorContext(dispatcher: dispatcher, category: NetworkMonitor.category, preferences: preferences)
            )
            // ScannerMonitor is deliberately NOT assembled here — see its own doc comment.
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
            Self.describing(NetworkMonitor.self)
        ]
    }

    private static func describing<M: Monitor>(_ monitor: M.Type) -> MonitorDescription {
        MonitorDescription(category: M.category, events: M.events, fields: M.fields)
    }

    public func start() async {
        if monitors.isEmpty { assemble() }
        for monitor in monitors {
            await monitor.start()
        }
    }

    public func stop() async {
        for monitor in monitors {
            await monitor.stop()
        }
    }

    var monitorCount: Int { monitors.count }
}
