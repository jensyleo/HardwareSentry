import Foundation
import SignalCore
import SentryContract
import Testing
@testable import GamepadMonitor

struct ScriptedGamepadSource: GamepadSource {
    let script: [GamepadDeviceChange]

    func changes() -> AsyncStream<GamepadDeviceChange> {
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

@Suite("GamepadMonitor")
struct GamepadMonitorTests {
    private func run(_ changes: [GamepadDeviceChange]) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = GamepadMonitor(
            source: ScriptedGamepadSource(script: changes),
            context: MonitorContext(dispatcher: dispatcher, category: GamepadMonitor.category)
        )

        await monitor.start()
        for _ in 0..<100 where await delivery.events.count < changes.count {
            await Task.yield()
        }
        await monitor.stop()
        return await delivery.events
    }

    @Test("a controller connecting is announced with its own name as the subject")
    func controllerConnectIsAnnounced() async {
        let events = await run([.init(kind: .controller, connected: true, name: "DualSense Wireless Controller")])

        #expect(events.count == 1)
        #expect(events.first?.name == "GamepadConnected")
        #expect(events.first?.title == "Game Controller Connected")
        #expect(events.first?.subject == "DualSense Wireless Controller")
        #expect(events.first?.body == "DualSense Wireless Controller")
    }

    @Test("a controller with no reported name falls back to a generic one")
    func controllerWithNoNameFallsBack() async {
        let events = await run([.init(kind: .controller, connected: true, name: nil)])
        #expect(events.first?.body == "Game Controller")
    }

    @Test("a keyboard connecting and disconnecting use their own dedicated events")
    func keyboardUsesOwnEvents() async {
        let events = await run([
            .init(kind: .keyboard, connected: true),
            .init(kind: .keyboard, connected: false)
        ])

        #expect(events[0].name == "GamepadKeyboardConnected")
        #expect(events[1].name == "GamepadKeyboardDisconnected")
    }

    @Test("a mouse connecting and disconnecting use their own dedicated events")
    func mouseUsesOwnEvents() async {
        let events = await run([
            .init(kind: .mouse, connected: true),
            .init(kind: .mouse, connected: false)
        ])

        #expect(events[0].name == "GamepadMouseConnected")
        #expect(events[1].name == "GamepadMouseDisconnected")
    }

    @Test("a racing wheel connecting and disconnecting share a subject")
    func racingWheelSharesSubject() async {
        let events = await run([
            .init(kind: .racingWheel, connected: true, name: "Logitech G29"),
            .init(kind: .racingWheel, connected: false, name: "Logitech G29")
        ])

        #expect(events[0].name == "GamepadRacingWheelConnected")
        #expect(events[1].name == "GamepadRacingWheelDisconnected")
        #expect(events[0].subject == events[1].subject)
    }

    @Test("every event it can raise is declared for preferences to find, with the right defaults")
    func eventsAreDeclaredWithDefaults() {
        let byName = Dictionary(uniqueKeysWithValues: GamepadMonitor.events.map { ($0.name, $0.enabledByDefault) })

        #expect(byName == [
            "GamepadConnected": true,
            "GamepadDisconnected": true,
            "GamepadKeyboardConnected": false,
            "GamepadKeyboardDisconnected": false,
            "GamepadMouseConnected": false,
            "GamepadMouseDisconnected": false,
            "GamepadRacingWheelConnected": true,
            "GamepadRacingWheelDisconnected": true
        ])
    }

    @Test("stopping twice is harmless")
    func stoppingTwiceIsHarmless() async {
        let monitor = GamepadMonitor(
            source: ScriptedGamepadSource(script: []),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: CollectingDelivery()),
                category: GamepadMonitor.category
            )
        )

        await monitor.start()
        await monitor.stop()
        await monitor.stop()
    }
}
