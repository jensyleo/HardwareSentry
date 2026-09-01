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
                context: MonitorContext(dispatcher: dispatcher, category: USBMonitor.category)
            ),
            ThermalMonitor(
                source: SystemThermalStateSource(),
                context: MonitorContext(dispatcher: dispatcher, category: ThermalMonitor.category)
            ),
            GamepadMonitor(
                source: GameControllerSource(),
                context: MonitorContext(dispatcher: dispatcher, category: GamepadMonitor.category)
            ),
            ThunderboltMonitor(
                source: IOKitThunderboltDeviceSource(),
                context: MonitorContext(dispatcher: dispatcher, category: ThunderboltMonitor.category)
            ),
            CameraMonitor(
                source: AVFoundationCameraSource(),
                context: MonitorContext(dispatcher: dispatcher, category: CameraMonitor.category)
            ),
            DisplayMonitor(
                source: CoreGraphicsDisplaySource(),
                context: MonitorContext(dispatcher: dispatcher, category: DisplayMonitor.category)
            ),
            PrinterMonitor(
                source: CUPSPrinterSource(),
                context: MonitorContext(dispatcher: dispatcher, category: PrinterMonitor.category)
            ),
            BluetoothMonitor(
                source: IOBluetoothSource(),
                context: MonitorContext(dispatcher: dispatcher, category: BluetoothMonitor.category)
            ),
            AudioMonitor(
                source: CoreAudioSource(),
                context: MonitorContext(dispatcher: dispatcher, category: AudioMonitor.category)
            ),
            VolumeMonitor(
                source: NSWorkspaceVolumeSource(),
                context: MonitorContext(dispatcher: dispatcher, category: VolumeMonitor.category)
            ),
            PowerMonitor(
                source: IOPSPowerSource(),
                context: MonitorContext(dispatcher: dispatcher, category: PowerMonitor.category)
            ),
            NetworkMonitor(
                source: SystemNetworkSource(),
                context: MonitorContext(dispatcher: dispatcher, category: NetworkMonitor.category)
            )
            // ScannerMonitor is deliberately NOT assembled here — see its own doc comment.
        ]
    }

    /// What every assembled monitor can raise, for a preferences screen to list.
    public func describeEvents() -> [(category: NotificationCategory, events: [MonitorEventDescription])] {
        [
            (USBMonitor.category, USBMonitor.events),
            (ThermalMonitor.category, ThermalMonitor.events),
            (GamepadMonitor.category, GamepadMonitor.events),
            (ThunderboltMonitor.category, ThunderboltMonitor.events),
            (CameraMonitor.category, CameraMonitor.events),
            (DisplayMonitor.category, DisplayMonitor.events),
            (PrinterMonitor.category, PrinterMonitor.events),
            (BluetoothMonitor.category, BluetoothMonitor.events),
            (AudioMonitor.category, AudioMonitor.events),
            (VolumeMonitor.category, VolumeMonitor.events),
            (PowerMonitor.category, PowerMonitor.events),
            (NetworkMonitor.category, NetworkMonitor.events)
        ]
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
