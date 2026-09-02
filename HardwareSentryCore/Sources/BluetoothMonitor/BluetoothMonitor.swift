import Foundation
import SentryContract
import SignalCore

/// Says when a classic Bluetooth device connects or disconnects, the radio itself powers
/// on/off, the Bluetooth subsystem hits trouble (resetting/unauthorized/unsupported), or a
/// device is paired/unpaired.
public actor BluetoothMonitor: Monitor {
    public static let category = BluetoothEvent.category

    public static let events: [MonitorEventDescription] = [
        .init(name: BluetoothEvent.connected.rawValue, title: "Device connected", icon: .asset("Bluetooth-On", in: .module)),
        .init(name: BluetoothEvent.disconnected.rawValue, title: "Device disconnected", icon: .asset("Bluetooth-Off", in: .module)),
        .init(name: BluetoothEvent.radioOn.rawValue, title: "Radio turned on", enabledByDefault: false, icon: .asset("Bluetooth-Radio-On", in: .module)),
        .init(name: BluetoothEvent.radioOff.rawValue, title: "Radio turned off", enabledByDefault: false, icon: .asset("Bluetooth-Radio-Off", in: .module)),
        .init(name: BluetoothEvent.subsystemStateChanged.rawValue, title: "Subsystem trouble (resetting/unauthorized/unsupported)", enabledByDefault: false, icon: .asset("Bluetooth-Off", in: .module)),
        .init(name: BluetoothEvent.paired.rawValue, title: "Device paired", enabledByDefault: false, icon: .asset("Bluetooth-On", in: .module)),
        .init(name: BluetoothEvent.unpaired.rawValue, title: "Device unpaired", enabledByDefault: false, icon: .asset("Bluetooth-Off", in: .module))
    ]

    public static let fields: [MonitorFieldDescription] = BluetoothField.allCases.map {
        .init(name: $0.rawValue, title: $0.settingsTitle, shownByDefault: $0.shownByDefault)
    }

    private let source: any BluetoothSource
    private let context: MonitorContext
    private var watching: Task<Void, Never>?

    /// The artwork each device was last seen with, so a disconnect can still show what
    /// kind of thing left rather than a generic Bluetooth glyph.
    private var lastKindByName: [String: BluetoothDeviceKind] = [:]
    private var lastKnownRadioOn: Bool?
    private var lastKnownPaired: [String: String]?
    private var hasPairedBaseline = false

    public init(source: any BluetoothSource, context: MonitorContext) {
        self.source = source
        self.context = context
    }

    public func start() async {
        guard watching == nil else { return }

        watching = Task { [source] in
            for await event in source.changes() {
                guard !Task.isCancelled else { return }
                await self.handle(event)
            }
        }
    }

    public func stop() async {
        watching?.cancel()
        watching = nil
    }

    private func handle(_ event: BluetoothSourceEvent) async {
        switch event {
        case .classicConnected(let name, let kind, let detail):
            if let kind { lastKindByName[name] = kind }
            await context.notify(
                BluetoothEvent.connected.rawValue, subject: name,
                title: "Bluetooth Connection",
                body: await context.body([
                    .always(name),
                    .field(BluetoothField.kind.rawValue, "Type", detail?.kindNote),
                    .field(BluetoothField.address.rawValue, "Address", detail?.address),
                    .field(BluetoothField.paired.rawValue, "Paired", detail?.pairedNote),
                    .field(BluetoothField.signal.rawValue, "Signal", detail?.rssiNote),
                    .field(BluetoothField.linkType.rawValue, "Link type", detail?.linkType),
                    .field(BluetoothField.initiator.rawValue, "Initiated by", detail?.initiatorNote),
                    .field(BluetoothField.services.rawValue, "Services", detail?.services),
                    .field(BluetoothField.favorite.rawValue, "Favourite", detail?.favoriteNote),
                    .field(BluetoothField.lastSeen.rawValue, "Last used", detail?.lastSeen.map(Self.describe(lastSeen:)))
                ]),
                icon: .asset(kind?.iconBaseName ?? "Bluetooth-On", in: .module)
            )

        case .classicDisconnected(let name):
            let kind = lastKindByName.removeValue(forKey: name)
            await context.notify(
                BluetoothEvent.disconnected.rawValue, subject: name,
                title: "Bluetooth Disconnection", body: name,
                icon: .asset(kind.map { "\($0.iconBaseName)-Disconnected" } ?? "Bluetooth-Off", in: .module)
            )

        case .radioPower(let isOn):
            let previous = lastKnownRadioOn
            lastKnownRadioOn = isOn
            guard let previous, previous != isOn else { return } // first sighting — baseline only
            await context.notify(
                isOn ? BluetoothEvent.radioOn.rawValue : BluetoothEvent.radioOff.rawValue,
                subject: "Radio",
                title: isOn ? "Bluetooth Turned On" : "Bluetooth Turned Off",
                body: "",
                icon: .asset(isOn ? "Bluetooth-Radio-On" : "Bluetooth-Radio-Off", in: .module)
            )

        case .subsystemState(let state):
            await context.notify(
                BluetoothEvent.subsystemStateChanged.rawValue,
                subject: "Subsystem",
                title: "Bluetooth Status",
                body: state.title,
                icon: .asset("Bluetooth-Off", in: .module)
            )

        case .pairedSnapshot(let current):
            await handlePairedSnapshot(current)
        }
    }

    private func handlePairedSnapshot(_ current: [String: String]) async {
        if !hasPairedBaseline {
            hasPairedBaseline = true
            lastKnownPaired = current
            return
        }

        let previous = lastKnownPaired ?? [:]
        let currentAddresses = Set(current.keys)
        let previousAddresses = Set(previous.keys)

        for address in currentAddresses.subtracting(previousAddresses) {
            let name = current[address] ?? address
            await context.notify(BluetoothEvent.paired.rawValue, subject: address, title: "Bluetooth Device Paired", body: name, icon: .asset("Bluetooth-On", in: .module))
        }
        for address in previousAddresses.subtracting(currentAddresses) {
            let name = previous[address] ?? address
            await context.notify(BluetoothEvent.unpaired.rawValue, subject: address, title: "Bluetooth Device Unpaired", body: name, icon: .asset("Bluetooth-Off", in: .module))
        }

        lastKnownPaired = current
    }

    /// Relative rather than absolute: "3 days ago" is what someone actually wants from
    /// this line, and a full timestamp for something that happened minutes ago is noise.
    private static func describe(lastSeen: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: lastSeen, relativeTo: Date())
    }

}
