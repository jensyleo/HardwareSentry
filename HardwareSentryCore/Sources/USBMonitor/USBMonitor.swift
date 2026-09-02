import Foundation
import SentryContract
import SignalCore

/// Says when USB devices come and go.
public actor USBMonitor: Monitor {
    public static let category = USBEvent.category

    public static let events: [MonitorEventDescription] = [
        .init(name: USBEvent.connected.rawValue, title: "Device connected", icon: .asset("USB-On", in: .module)),
        .init(name: USBEvent.disconnected.rawValue, title: "Device disconnected", icon: .asset("USB-Off", in: .module))
    ]

    public static let fields: [MonitorFieldDescription] = [
        .init(name: USBField.vendor.rawValue, title: "Vendor")
    ]

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
                USBEvent.connected.rawValue,
                subject: device.name,
                title: device.isHub ? "USB Hub/Dock Connection" : "USB Connection",
                body: await context.body([
                    .always(device.name),
                    .field(USBField.vendor.rawValue, vendorDetail(device))
                ]),
                icon: .asset(device.iconBaseName ?? "USB-On", in: .module)
            )
        case .detached(let device):
            await context.notify(
                USBEvent.disconnected.rawValue,
                subject: device.name,
                title: device.isHub ? "USB Hub/Dock Disconnection" : "USB Disconnection",
                body: await context.body([
                    .always(device.name),
                    .field(USBField.vendor.rawValue, vendorDetail(device))
                ]),
                icon: .asset(device.disconnectedIconName, in: .module)
            )
        }
    }

    /// The device's name is used as the subject, not any identifier the system hands out
    /// as it enumerates. Those are assigned afresh every time a device appears, so they
    /// are never the same twice for the same physical thing — which would leave a device
    /// flapping in and out looking like an endless parade of different devices, and never
    /// be recognised as one that is misbehaving.
    /// Nil when the vendor adds nothing — absent, empty, or just the device's own name
    /// again. A line that repeats what is already on the one above it is worse than no
    /// line at all.
    static func vendorDetail(_ device: USBDevice) -> String? {
        guard let vendor = device.vendorName, !vendor.isEmpty, vendor != device.name else {
            return nil
        }
        return vendor
    }
}
