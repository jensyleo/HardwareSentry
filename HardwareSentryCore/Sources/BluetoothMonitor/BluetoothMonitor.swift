import Foundation
import SentryContract
import SignalCore

/// Says when a classic Bluetooth device connects or disconnects, the radio itself powers
/// on/off, the Bluetooth subsystem hits trouble (resetting/unauthorized/unsupported), or a
/// device is paired/unpaired.
public actor BluetoothMonitor: Monitor {
    public static let category = BluetoothEvent.category

    /// One row per device kind first, in the original's order, then presence, the radio,
    /// pairing, Low Energy and the signal levels.
    public static let events: [MonitorEventDescription] = BluetoothDeviceKind.allCases.map { kind in
        .init(
            name: kind.connectedEvent.rawValue,
            title: kind.settingsTitle,
            icon: .asset(kind.iconBaseName, in: .module),
            group: Group.device
        )
    } + [
        .init(name: BluetoothEvent.connected.rawValue, title: "Connected (generic)", icon: .asset("Bluetooth-On", in: .module), group: Group.device),
        .init(name: BluetoothEvent.disconnected.rawValue, title: "Disconnected (generic)", icon: .asset("Bluetooth-Off", in: .module), group: Group.device),
        .init(name: BluetoothEvent.radioOn.rawValue, title: "Bluetooth Radio On", enabledByDefault: false, icon: .asset("Bluetooth-Radio-On", in: .module), group: Group.device),
        .init(name: BluetoothEvent.radioOff.rawValue, title: "Bluetooth Radio Off", enabledByDefault: false, icon: .asset("Bluetooth-Radio-Off", in: .module), group: Group.device),
        .init(name: BluetoothEvent.subsystemStateChanged.rawValue, title: "Bluetooth Status Changed", enabledByDefault: false, icon: .asset("Bluetooth-Off", in: .module), group: Group.device),
        .init(name: BluetoothEvent.paired.rawValue, title: "Paired", enabledByDefault: false, icon: .asset("Bluetooth-On", in: .module), group: Group.device),
        .init(name: BluetoothEvent.unpaired.rawValue, title: "Unpaired", enabledByDefault: false, icon: .asset("Bluetooth-Off", in: .module), group: Group.device),

        // Off by default, as in the original, and unlike the Wi-Fi ones. An accessory's
        // signal moves whenever it is picked up or carried to the next room, so on a Mac
        // with a keyboard, a mouse and a headset this is a notification about somebody
        // reaching across their desk.
        .init(name: BluetoothEvent.signalExcellent.rawValue, title: BluetoothSignalLevel.excellent.settingsTitle, enabledByDefault: false, icon: .asset(BluetoothSignalLevel.excellent.iconName, in: .module), group: Group.signal),
        .init(name: BluetoothEvent.signalGood.rawValue, title: BluetoothSignalLevel.good.settingsTitle, enabledByDefault: false, icon: .asset(BluetoothSignalLevel.good.iconName, in: .module), group: Group.signal),
        .init(name: BluetoothEvent.signalFair.rawValue, title: BluetoothSignalLevel.fair.settingsTitle, enabledByDefault: false, icon: .asset(BluetoothSignalLevel.fair.iconName, in: .module), group: Group.signal),
        .init(name: BluetoothEvent.signalWeak.rawValue, title: BluetoothSignalLevel.weak.settingsTitle, enabledByDefault: false, icon: .asset(BluetoothSignalLevel.weak.iconName, in: .module), group: Group.signal),
        // Off by default, as in the original: a BLE accessory is discovered as already
        // connected rather than connecting, so this fires for whatever is on the desk
        // every time the radio comes back — which is not an event anybody caused.
        .init(name: BluetoothEvent.leConnected.rawValue, title: "BLE Accessory Connected", enabledByDefault: false, icon: .asset("Bluetooth-On", in: .module), group: Group.device),
        .init(name: BluetoothEvent.leDisconnected.rawValue, title: "BLE Accessory Disconnected", enabledByDefault: false, icon: .asset("Bluetooth-Off", in: .module), group: Group.device),
        .init(name: BluetoothEvent.signalNone.rawValue, title: BluetoothSignalLevel.lost.settingsTitle, enabledByDefault: false, icon: .asset(BluetoothSignalLevel.lost.iconName, in: .module), group: Group.signal)
    ]

    /// Said outright: the first event is now a computer, and this module is about more.
    public static let icon: NotificationIcon = .asset("Bluetooth-On", in: .module)

    public static let fields: [MonitorFieldDescription] = BluetoothField.allCases.map {
        .init(name: $0.rawValue, title: $0.settingsTitle, shownByDefault: $0.shownByDefault, group: $0.group)
    }

    /// The headings its rows sit under.
    enum Group {
        static let device = "Devices and radio"
        static let signal = "Signal strength"
    }

    private let source: any BluetoothSource
    private let context: MonitorContext
    private var watching: Task<Void, Never>?

    /// The artwork each device was last seen with, so a disconnect can still show what
    /// kind of thing left rather than a generic Bluetooth glyph.
    private var lastKindByName: [String: BluetoothDeviceKind] = [:]
    private var signalWatcher: BluetoothSignalWatcher
    private var lastKnownRadioOn: Bool?
    private var lastKnownPaired: [String: String]?
    private var hasPairedBaseline = false

    /// - Parameter signalCooldown: how long after reporting one device's signal level
    ///   before reporting it again. Fifteen seconds, the original's figure.
    public init(
        source: any BluetoothSource,
        context: MonitorContext,
        signalCooldown: TimeInterval = 15
    ) {
        self.source = source
        self.context = context
        self.signalWatcher = BluetoothSignalWatcher(cooldown: signalCooldown)
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
                // The row this device's own kind owns; the generic one only for a kind
                // this application has no artwork for.
                (kind?.connectedEvent ?? BluetoothEvent.connected).rawValue, subject: name,
                title: await context.connectionTitle(
                    medium: "Bluetooth",
                    type: kind?.label,
                    action: "Connected"
                ),
                body: await context.body([
                    .always(name),
                    .field(BluetoothField.kind.rawValue, "Type", detail?.kindNote),
                    .field(BluetoothField.address.rawValue, "Address", detail?.address),
                    .field(BluetoothField.paired.rawValue, "Paired", detail?.pairedNote),
                    .field(BluetoothField.signal.rawValue, "Signal", detail?.rssiNote),
                    .field(BluetoothField.battery.rawValue, "Battery", detail?.batteryNote),
                    .field(BluetoothField.linkType.rawValue, "Link type", detail?.linkType),
                    .field(BluetoothField.initiator.rawValue, "Initiated by", detail?.initiatorNote),
                    .field(BluetoothField.services.rawValue, "Services", detail?.services),
                    .field(BluetoothField.favorite.rawValue, "Favourite", detail?.favoriteNote),
                    .field(BluetoothField.lastSeen.rawValue, "Last used", detail?.lastSeen.map(Self.describe(lastSeen:))),
                    .field(BluetoothField.encryption.rawValue, "Encryption", detail?.encryption),
                    .field(BluetoothField.serviceClass.rawValue, "Service classes", detail?.serviceClasses),
                    .field(BluetoothField.identity.rawValue, "Identity", detail?.identityNote),
                    .field(BluetoothField.handsFree.rawValue, "Hands-free", detail?.handsFreeFeatures),
                    .field(BluetoothField.hidDetail.rawValue, "HID", detail?.hidDetail),
                    .field(BluetoothField.linkDiagnostics.rawValue, "Link", detail?.linkDiagnosticsNote)
                ]),
                icon: .asset(kind?.iconBaseName ?? "Bluetooth-On", in: .module)
            )

        case .classicDisconnected(let name):
            let kind = lastKindByName.removeValue(forKey: name)
            await context.notify(
                BluetoothEvent.disconnected.rawValue, subject: name,
                title: await context.connectionTitle(
                    medium: "Bluetooth",
                    type: lastKindByName[name]?.label,
                    action: "Disconnected"
                ),
                body: name,
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

        case .signalSnapshot(let readings):
            await handleSignalSnapshot(readings)

        case .bleConnected(let name, let detail):
            await context.notify(
                BluetoothEvent.leConnected.rawValue,
                subject: name,
                title: "Bluetooth LE Accessory",
                body: await context.body([
                    .always(name),
                    .field(BluetoothField.battery.rawValue, "Battery", detail.batteryNote),
                    .field(BluetoothField.identity.rawValue, "Identity", detail.identityNote),
                    .field(BluetoothField.address.rawValue, "Serial", detail.serialNumber)
                ]),
                icon: .asset("Bluetooth-On", in: .module)
            )

        case .bleDisconnected(let name):
            await context.notify(
                BluetoothEvent.leDisconnected.rawValue,
                subject: name,
                title: "Bluetooth LE Accessory Disconnected",
                body: name,
                icon: .asset("Bluetooth-Off", in: .module)
            )
        }
    }

    /// Reports each device whose signal has moved between bars.
    ///
    /// The deciding lives in `BluetoothSignalWatcher`, which is where the per-device
    /// baseline, the level comparison and the cooldown are written down and tested.
    private func handleSignalSnapshot(_ readings: [String: BluetoothSignalReading]) async {
        // Devices that have gone are forgotten, so one coming back baselines afresh
        // rather than being compared against a level from before it left the room.
        signalWatcher.keepOnly(Set(readings.keys))

        // Sorted so a Mac with three accessories reports them in a stable order rather
        // than in whatever order the dictionary happened to iterate.
        for (address, reading) in readings.sorted(by: { $0.key < $1.key }) {
            guard let change = signalWatcher.consider(
                address: address,
                name: reading.name,
                rssi: reading.rssi
            ) else { continue }

            await context.notify(
                change.level.event.rawValue,
                // Per device, so two accessories drifting at once do not read as one
                // thing flapping.
                subject: address,
                title: "Bluetooth Signal Changed",
                body: "\(change.name)\n\(change.summary)",
                icon: .asset(change.level.iconName, in: .module)
            )
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
