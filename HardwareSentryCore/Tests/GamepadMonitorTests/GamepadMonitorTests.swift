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

/// Lets a test say which optional lines this person has asked to see.
private struct ChosenFields: NotificationPreferences {
    let allowed: Set<String>

    func isFieldEnabled(_ name: String, in category: NotificationCategory) async -> Bool {
        allowed.contains(name)
    }
}

@Suite("GamepadMonitor optional fields")
struct GamepadMonitorFieldTests {
    private static let fullDetail = GamepadDetail(
        productCategory: "DualSense",
        playerIndex: 1,
        batteryPercent: 74,
        batteryState: "Charging",
        hasAdaptiveTriggers: true,
        hasTouchpad: true,
        hasMotionSensors: true,
        hapticLocations: "Handles, Triggers",
        isAttachedToDevice: false,
        lightColor: "R255 G0 B0",
        hasElitePaddles: false
    )

    private func body(
        _ change: GamepadDeviceChange,
        allowing allowed: Set<String>
    ) async -> String? {
        let delivery = CollectingDelivery()
        let monitor = GamepadMonitor(
            source: ScriptedGamepadSource(script: [change]),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: GamepadMonitor.category,
                preferences: ChosenFields(allowed: allowed)
            )
        )
        await monitor.start()
        for _ in 0..<100 where await delivery.events.isEmpty { await Task.yield() }
        await monitor.stop()
        return await delivery.events.first?.body
    }

    @Test("with everything switched on, the details read in the declared order")
    func fullDetailReadsInOrder() async {
        let body = await body(
            .init(kind: .controller, connected: true, name: "DualSense", detail: Self.fullDetail),
            allowing: Set(GamepadField.allCases.map(\.rawValue))
        )

        #expect(body == """
        DualSense
        Type:\tDualSense
        Player:\t1
        Battery:\t74%
        Battery State:\tCharging
        Attached to device:\tNo
        Adaptive Triggers:\tYes
        Touchpad:\tYes
        Motion Sensors:\tYes
        Haptics:\tYes
        Haptic Actuators:\tHandles, Triggers
        Lightbar Color:\tR255 G0 B0
        """)
    }

    @Test("a field nobody asked for costs nothing and says nothing")
    func unwantedFieldsAreLeftOut() async {
        let body = await body(
            .init(kind: .controller, connected: true, name: "DualSense", detail: Self.fullDetail),
            allowing: [GamepadField.battery.rawValue]
        )

        #expect(body == "DualSense\nBattery:\t74%")
    }

    @Test("a capability the controller does not have is not reported as absent")
    func absentCapabilitiesAreSilent() async {
        // Telling someone their Xbox pad has no touchpad is noise, not news, so the
        // capability lines are present-only rather than Yes/No.
        let plain = GamepadDetail(productCategory: "Xbox One", hasTouchpad: false)
        let body = await body(
            .init(kind: .controller, connected: true, name: "Xbox Wireless Controller", detail: plain),
            allowing: Set(GamepadField.allCases.map(\.rawValue))
        )

        #expect(body == "Xbox Wireless Controller\nType:\tXbox One")
    }

    @Test("a disconnect carries no details, so it cannot quote a stale battery level")
    func disconnectHasNoDetail() async {
        let body = await body(
            .init(kind: .controller, connected: false, name: "DualSense"),
            allowing: Set(GamepadField.allCases.map(\.rawValue))
        )

        #expect(body == "DualSense")
    }

    @Test("player zero is a real player, unlike an unset index")
    func playerZeroIsReported() async {
        #expect(GamepadDetail(playerIndex: 0).playerNote == "0")
        #expect(GamepadDetail().playerNote == nil)
    }
}
