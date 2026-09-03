import Foundation
import SentryContract
import SignalCore

/// Says when USB devices come and go.
public actor USBMonitor: Monitor {
    public static let category = USBEvent.category

    /// Said outright rather than taken from the first event, which is now a hub.
    ///
    /// The same trap Network fell into: the module list takes the first event's artwork,
    /// so declaring one row per device class quietly turned the whole of USB into a hub.
    public static let icon: NotificationIcon = .asset("USB-On", in: .module)

    /// One row per device class, in the original's order, each with its own artwork and
    /// its own switch: a Mac with a hub, a keyboard and a webcam permanently attached
    /// should be able to silence the hub without silencing the webcam.
    public static let events: [MonitorEventDescription] = USBDeviceKind.allCases.map { kind in
        .init(
            name: kind.connectedEvent.rawValue,
            title: kind.settingsTitle,
            icon: .asset(kind.iconBaseName, in: .module)
        )
    } + [
        // The two the original calls "(generic)": a device that never said what it is,
        // which is most of them, and every disconnection.
        .init(name: USBEvent.connected.rawValue, title: "Connected (generic)", icon: .asset("USB-On", in: .module)),
        .init(name: USBEvent.disconnected.rawValue, title: "Disconnected (generic)", icon: .asset("USB-Off", in: .module))
    ]

    public static let fields: [MonitorFieldDescription] = USBField.allCases.map {
        .init(name: $0.rawValue, title: $0.settingsTitle, shownByDefault: $0.shownByDefault)
    }

    private let source: any USBDeviceSource
    private let context: MonitorContext
    private var watching: Task<Void, Never>?

    public init(source: any USBDeviceSource, context: MonitorContext) {
        self.source = source
        self.context = context
    }

    public func start() async {
        guard watching == nil else { return }

        watching = Task { [source, context] in
            for await change in source.changes() {
                guard !Task.isCancelled else { return }
                await Self.report(change, through: context)
            }
        }
    }

    public func stop() async {
        watching?.cancel()
        watching = nil
    }

    private static func report(_ change: USBDeviceChange, through context: MonitorContext) async {
        switch change {
        case .attached(let device):
            await context.notify(
                // The row this device's own class owns, so it can be silenced and
                // re-iconed on its own; the generic one only for a device that never
                // said what it is.
                (device.kind?.connectedEvent ?? USBEvent.connected).rawValue,
                subject: device.name,
                // The device's own class, when it said — "USB Hub Connected" — and the
                // generic wording when it did not, which is most of them.
                title: context.connectionTitle(
                    medium: "USB",
                    type: device.kind?.settingsTitle,
                    action: "Connected"
                ),
                body: await context.body([
                    .always(device.name),
                    // In the original's order: who made it, what identifies it, what it
                    // is, how fast, what it costs in power, and what is inside.
                    .field(USBField.vendor.rawValue, "Manufacturer", Self.manufacturerDetail(device)),
                    .field(USBField.vidPid.rawValue, "VID:PID", device.detail.vidPidNote),
                    .field(USBField.deviceClass.rawValue, "Type", device.className),
                    .field(USBField.speed.rawValue, "Speed", device.detail.speedNote),
                    .field(USBField.power.rawValue, "Power", device.detail.powerNote),
                    .field(USBField.medium.rawValue, "Medium", device.detail.mediumNote),
                    .field(USBField.serialNumber.rawValue, "Serial", device.detail.serialNumber),
                    .field(USBField.firmwareVersion.rawValue, "Firmware/Release", device.detail.firmwareNote),
                    .field(USBField.locationID.rawValue, "Port Location", device.detail.locationNote),
                    .field(USBField.configurations.rawValue, "Configurations", device.detail.configurationsNote),
                    .field(USBField.specVersion.rawValue, "USB spec", device.detail.specVersionNote),
                    .field(USBField.tunnel.rawValue, "Connection", device.detail.tunnelNote),
                    // No label: it is a warning sentence, not a value with a name.
                    .field(USBField.failedPower.rawValue, device.detail.failedPowerNote),
                    .field(USBField.portInfo.rawValue, "Port", device.detail.portNote)
                ]),
                icon: .asset(device.iconBaseName ?? "USB-On", in: .module)
            )
        case .detached(let device):
            await context.notify(
                USBEvent.disconnected.rawValue,
                subject: device.name,
                title: context.connectionTitle(
                    medium: "USB",
                    type: device.kind?.settingsTitle,
                    action: "Disconnected"
                ),
                // The name alone. Every detail line describes a device that is present —
                // its speed, its power draw, what is inside it — and none of it means
                // anything about one that has just left.
                body: device.name,
                icon: .asset(device.disconnectedIconName, in: .module)
            )
        }
    }

    /// Who made it and what they call it, on one line.
    ///
    /// Nil when it adds nothing — absent, empty, or just the device's own name again. A
    /// line that repeats the one above it is worse than no line at all.
    ///
    /// (The device's *name* is what the notification is subjected on, not any identifier
    /// the system hands out while enumerating. Those are assigned afresh every time a
    /// device appears, so they are never the same twice for the same physical thing —
    /// which would leave a device flapping in and out looking like an endless parade of
    /// different ones, and never be recognised as one that is misbehaving.)
    static func manufacturerDetail(_ device: USBDevice) -> String? {
        guard let combined = device.detail.manufacturerNote(vendorName: device.vendorName),
              combined != device.name
        else { return nil }
        return combined
    }
}
