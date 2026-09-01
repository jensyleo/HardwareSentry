import Foundation
import SignalCore
import SentryContract
import Testing
@testable import ThunderboltMonitor

struct ScriptedThunderboltSource: ThunderboltDeviceSource {
    let script: [ThunderboltDeviceChange]

    func changes() -> AsyncStream<ThunderboltDeviceChange> {
        AsyncStream { continuation in
            for change in script { continuation.yield(change) }
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

@Suite("ThunderboltMonitor")
struct ThunderboltMonitorTests {
    private func run(_ changes: [ThunderboltDeviceChange], expecting: Int) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = ThunderboltMonitor(
            source: ScriptedThunderboltSource(script: changes),
            context: MonitorContext(dispatcher: dispatcher, category: ThunderboltMonitor.category)
        )

        await monitor.start()
        for _ in 0..<100 where await delivery.events.count < expecting {
            await Task.yield()
        }
        await monitor.stop()
        return await delivery.events
    }

    @Test("an ordinary device only raises the generic pair")
    func ordinaryDeviceIsGeneric() async {
        let events = await run([.attached(ThunderboltDevice(name: "CalDigit Dock", baseClass: 0x06))], expecting: 1)

        #expect(events.count == 1)
        #expect(events.first?.name == "ThunderboltConnected")
        #expect(events.first?.subject == "CalDigit Dock")
    }

    @Test("a Display Controller also raises the eGPU pair, additively")
    func displayControllerAlsoRaisesEGPU() async {
        let events = await run([.attached(ThunderboltDevice(name: "Razer Core X", baseClass: 0x03))], expecting: 2)

        #expect(events.count == 2)
        #expect(events[0].name == "ThunderboltConnected")
        #expect(events[1].name == "ThunderboltEGPUConnected")
        #expect(events[1].subject == "eGPU-Razer Core X")
    }

    @Test("disconnecting an eGPU still fires the eGPU pair, from the class cached at connect")
    func disconnectStillKnowsItWasAnEGPU() async {
        let events = await run([
            .attached(ThunderboltDevice(name: "Razer Core X", baseClass: 0x03)),
            .detached(name: "Razer Core X")
        ], expecting: 4)

        #expect(events.count == 4)
        #expect(events[2].name == "ThunderboltDisconnected")
        #expect(events[3].name == "ThunderboltEGPUDisconnected")
    }

    @Test("a departure with no cached class is only the generic disconnect")
    func departureWithNoBaselineIsGenericOnly() async {
        let events = await run([.detached(name: "Unknown Device")], expecting: 1)

        #expect(events.count == 1)
        #expect(events.first?.name == "ThunderboltDisconnected")
    }

    @Test("every event it can raise is declared for preferences to find, with the right defaults")
    func eventsAreDeclaredWithDefaults() {
        let byName = Dictionary(uniqueKeysWithValues: ThunderboltMonitor.events.map { ($0.name, $0.enabledByDefault) })

        #expect(byName == [
            "ThunderboltConnected": true,
            "ThunderboltDisconnected": true,
            "ThunderboltEGPUConnected": false,
            "ThunderboltEGPUDisconnected": false
        ])
    }

    @Test("stopping twice is harmless")
    func stoppingTwiceIsHarmless() async {
        let monitor = ThunderboltMonitor(
            source: ScriptedThunderboltSource(script: []),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: CollectingDelivery()),
                category: ThunderboltMonitor.category
            )
        )

        await monitor.start()
        await monitor.stop()
        await monitor.stop()
    }
}
