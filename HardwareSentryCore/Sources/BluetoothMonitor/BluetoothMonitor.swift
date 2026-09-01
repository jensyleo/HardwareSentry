import Foundation
import SentryContract
import SignalCore

/// Says when a classic Bluetooth device connects or disconnects, the radio itself powers
/// on/off, the Bluetooth subsystem hits trouble (resetting/unauthorized/unsupported), or a
/// device is paired/unpaired.
public actor BluetoothMonitor: Monitor {
    public static let category = BluetoothEvent.category

    public static let events: [MonitorEventDescription] = [
        .init(name: BluetoothEvent.connected.rawValue, title: "Device connected"),
        .init(name: BluetoothEvent.disconnected.rawValue, title: "Device disconnected"),
        .init(name: BluetoothEvent.radioOn.rawValue, title: "Radio turned on", enabledByDefault: false),
        .init(name: BluetoothEvent.radioOff.rawValue, title: "Radio turned off", enabledByDefault: false),
        .init(name: BluetoothEvent.subsystemStateChanged.rawValue, title: "Subsystem trouble (resetting/unauthorized/unsupported)", enabledByDefault: false),
        .init(name: BluetoothEvent.paired.rawValue, title: "Device paired", enabledByDefault: false),
        .init(name: BluetoothEvent.unpaired.rawValue, title: "Device unpaired", enabledByDefault: false)
    ]

    private let source: any BluetoothSource
    private let context: MonitorContext
    private var watching: Task<Void, Never>?

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
        case .classicConnected(let name, _):
            await context.notify(BluetoothEvent.connected.rawValue, subject: name, title: "Bluetooth Connection", body: name)

        case .classicDisconnected(let name):
            await context.notify(BluetoothEvent.disconnected.rawValue, subject: name, title: "Bluetooth Disconnection", body: name)

        case .radioPower(let isOn):
            let previous = lastKnownRadioOn
            lastKnownRadioOn = isOn
            guard let previous, previous != isOn else { return } // first sighting — baseline only
            await context.notify(
                isOn ? BluetoothEvent.radioOn.rawValue : BluetoothEvent.radioOff.rawValue,
                subject: "Radio",
                title: isOn ? "Bluetooth Turned On" : "Bluetooth Turned Off",
                body: ""
            )

        case .subsystemState(let state):
            await context.notify(
                BluetoothEvent.subsystemStateChanged.rawValue,
                subject: "Subsystem",
                title: "Bluetooth Status",
                body: state.title
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
            await context.notify(BluetoothEvent.paired.rawValue, subject: address, title: "Bluetooth Device Paired", body: name)
        }
        for address in previousAddresses.subtracting(currentAddresses) {
            let name = previous[address] ?? address
            await context.notify(BluetoothEvent.unpaired.rawValue, subject: address, title: "Bluetooth Device Unpaired", body: name)
        }

        lastKnownPaired = current
    }
}
