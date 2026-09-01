import Foundation
import SignalCore
import SentryContract
import Testing
@testable import BluetoothMonitor

struct ScriptedBluetoothSource: BluetoothSource {
    let script: [BluetoothSourceEvent]

    func changes() -> AsyncStream<BluetoothSourceEvent> {
        AsyncStream { continuation in
            for event in script { continuation.yield(event) }
            continuation.finish()
        }
    }
}

actor CollectingDelivery: NotificationDelivering {
    private(set) var events: [NotificationEvent] = []

    func present(_ event: NotificationEvent, context: DispatchContext) async -> DeliveryOutcome {
        events.append(event)
        return .presented
    }
}

@Suite("BluetoothMonitor")
struct BluetoothMonitorTests {
    private func run(_ script: [BluetoothSourceEvent]) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = BluetoothMonitor(
            source: ScriptedBluetoothSource(script: script),
            context: MonitorContext(dispatcher: dispatcher, category: BluetoothMonitor.category)
        )

        await monitor.start()
        for _ in 0..<100 { await Task.yield() }
        await monitor.stop()
        return await delivery.events
    }

    @Test("a classic device connecting and disconnecting is announced")
    func classicConnectDisconnect() async {
        let events = await run([
            .classicConnected(name: "Magic Keyboard", kind: .keyboard),
            .classicDisconnected(name: "Magic Keyboard")
        ])

        #expect(events.count == 2)
        #expect(events[0].name == "BluetoothConnected")
        #expect(events[0].subject == "Magic Keyboard")
        #expect(events[1].name == "BluetoothDisconnected")
    }

    @Test("the first radio power reading is a silent baseline")
    func radioPowerBaselineIsSilent() async {
        let events = await run([.radioPower(isOn: true)])
        #expect(events.isEmpty)
    }

    @Test("a real radio power transition fires the right event")
    func radioPowerTransitionFires() async {
        let events = await run([.radioPower(isOn: false), .radioPower(isOn: true)])

        #expect(events.count == 1)
        #expect(events.first?.name == "BluetoothRadioOn")
        #expect(events.first?.title == "Bluetooth Turned On")
    }

    @Test("subsystem trouble is announced with its own title per state")
    func subsystemTroubleIsAnnounced() async {
        let events = await run([.subsystemState(.unauthorized)])

        #expect(events.count == 1)
        #expect(events.first?.name == "BluetoothSubsystemStateChanged")
        #expect(events.first?.body == "This app is no longer authorized to use Bluetooth")
    }

    @Test("the first paired snapshot is a silent baseline")
    func pairedBaselineIsSilent() async {
        let events = await run([.pairedSnapshot(["AA:BB": "AirPods"])])
        #expect(events.isEmpty)
    }

    @Test("a newly-paired device is announced, and losing one is announced separately")
    func pairedAndUnpaired() async {
        let events = await run([
            .pairedSnapshot(["AA:BB": "AirPods"]),
            .pairedSnapshot(["AA:BB": "AirPods", "CC:DD": "Magic Mouse"]),
            .pairedSnapshot(["CC:DD": "Magic Mouse"])
        ])

        #expect(events.count == 2)
        #expect(events[0].name == "BluetoothPaired")
        #expect(events[0].subject == "CC:DD")
        #expect(events[1].name == "BluetoothUnpaired")
        #expect(events[1].subject == "AA:BB")
    }

    @Test("every event it can raise is declared for preferences to find, with the right defaults")
    func eventsAreDeclaredWithDefaults() {
        let byName = Dictionary(uniqueKeysWithValues: BluetoothMonitor.events.map { ($0.name, $0.enabledByDefault) })

        #expect(byName == [
            "BluetoothConnected": true,
            "BluetoothDisconnected": true,
            "BluetoothRadioOn": false,
            "BluetoothRadioOff": false,
            "BluetoothSubsystemStateChanged": false,
            "BluetoothPaired": false,
            "BluetoothUnpaired": false
        ])
    }

    @Test("stopping twice is harmless")
    func stoppingTwiceIsHarmless() async {
        let monitor = BluetoothMonitor(
            source: ScriptedBluetoothSource(script: []),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: CollectingDelivery()),
                category: BluetoothMonitor.category
            )
        )

        await monitor.start()
        await monitor.stop()
        await monitor.stop()
    }
}
