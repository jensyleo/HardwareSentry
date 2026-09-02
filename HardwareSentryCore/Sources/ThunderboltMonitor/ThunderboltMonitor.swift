import Foundation
import SentryContract
import SignalCore

/// Says when Thunderbolt/PCI devices come and go, and separately when one of them looks
/// like an external GPU.
public actor ThunderboltMonitor: Monitor {
    public static let category = ThunderboltEvent.category

    /// One row per PCI class, in the original's order, then the two it calls "(generic)"
    /// and the two eGPU notices that are separate from a device connecting.
    public static let events: [MonitorEventDescription] = ThunderboltDeviceKind.allCases.map { kind in
        .init(
            name: kind.connectedEvent.rawValue,
            title: kind.settingsTitle,
            icon: .asset(kind.iconBaseName, in: .module)
        )
    } + [
        .init(name: ThunderboltEvent.connected.rawValue, title: "Connected (generic)", icon: .asset("Thunderbolt-On", in: .module)),
        .init(name: ThunderboltEvent.disconnected.rawValue, title: "Disconnected (generic)", icon: .asset("Thunderbolt-Off", in: .module)),
        .init(name: ThunderboltEvent.egpuConnected.rawValue, title: "External GPU connected", enabledByDefault: false, icon: .asset("TB-TypeEGPU", in: .module)),
        .init(name: ThunderboltEvent.egpuDisconnected.rawValue, title: "External GPU disconnected", enabledByDefault: false, icon: .asset("TB-TypeEGPU-Disconnected", in: .module))
    ]

    /// Said outright: the first event is now an eGPU, and this module is about more.
    public static let icon: NotificationIcon = .asset("Thunderbolt-On", in: .module)

    /// In the original's order and its words.
    public static let fields: [MonitorFieldDescription] = [
        .init(name: ThunderboltField.identifier.rawValue, title: "Vendor/device ID (VID:PID)"),
        .init(name: ThunderboltField.type.rawValue, title: "Device type (Storage, Display, Bridge/Dock…)"),
        .init(name: ThunderboltField.vendor.rawValue, title: "Vendor name")
    ]

    private let source: any ThunderboltDeviceSource
    private let context: MonitorContext
    private var watching: Task<Void, Never>?
    /// Remembers each device's PCI base class by name, captured at connect — a departing
    /// registry entry is frequently unreadable by the time it's reported, so this is the
    /// only way to still know a disconnecting device was an eGPU.
    private var lastBaseClassByName: [String: UInt8] = [:]
    /// Also remembered at connect: by the time a device leaves, its registry entry is
    /// usually unreadable, so the type-specific artwork has to come from what was seen
    /// when it arrived rather than from the dying entry.
    private var lastIconBaseByName: [String: String] = [:]

    public init(source: any ThunderboltDeviceSource, context: MonitorContext) {
        self.source = source
        self.context = context
    }

    public func start() async {
        guard watching == nil else { return }

        watching = Task { [source] in
            for await change in source.changes() {
                guard !Task.isCancelled else { return }
                await self.report(change)
            }
        }
    }

    public func stop() async {
        watching?.cancel()
        watching = nil
    }

    private func report(_ change: ThunderboltDeviceChange) async {
        switch change {
        case .attached(let device):
            if let baseClass = device.baseClass { lastBaseClassByName[device.name] = baseClass }
            if let iconBase = device.iconBaseName { lastIconBaseByName[device.name] = iconBase }
            await context.notify(
                // The row this device's own class owns; the generic one only for a class
                // with no artwork of its own.
                (device.kind?.connectedEvent ?? ThunderboltEvent.connected).rawValue,
                subject: device.name,
                title: await context.connectionTitle(
                    medium: "Thunderbolt",
                    type: device.typeLabel,
                    action: "Connected"
                ),
                body: await context.body([
                    .always(device.name),
                    .field(ThunderboltField.type.rawValue, "Type", device.typeLabel),
                    .field(ThunderboltField.identifier.rawValue, "VID:PID", device.identifierLabel),
                    .field(ThunderboltField.vendor.rawValue, "Vendor", device.vendorName)
                ]),
                icon: .asset(device.iconBaseName ?? "Thunderbolt-On", in: .module)
            )
            if device.isDisplayController {
                await context.notify(
                    ThunderboltEvent.egpuConnected.rawValue,
                    subject: "eGPU-\(device.name)",
                    title: "eGPU Connected",
                    body: device.name,
                    icon: .asset("TB-TypeEGPU", in: .module)
                )
            }

        case .detached(let name):
            let baseClass = lastBaseClassByName.removeValue(forKey: name)
            let iconBase = lastIconBaseByName.removeValue(forKey: name)
            await context.notify(
                ThunderboltEvent.disconnected.rawValue,
                subject: name,
                title: await context.connectionTitle(
                    medium: "Thunderbolt",
                    type: ThunderboltDevice.label(forBaseClass: baseClass),
                    action: "Disconnected"
                ),
                body: name,
                icon: .asset(iconBase.map { "\($0)-Disconnected" } ?? "Thunderbolt-Off", in: .module)
            )
            if baseClass == 0x03 {
                await context.notify(
                    ThunderboltEvent.egpuDisconnected.rawValue,
                    subject: "eGPU-\(name)",
                    title: "eGPU Disconnected",
                    body: name,
                    icon: .asset("TB-TypeEGPU-Disconnected", in: .module)
                )
            }
        }
    }
}
