import Foundation
import SignalCore
import SentryContract
import Testing
@testable import PowerMonitor

struct ScriptedPowerSource: PowerSource {
    let script: [PowerSourceEvent]

    func changes() -> AsyncStream<PowerSourceEvent> {
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

private func snapshot(_ kind: PowerSourceKind, percent: Int? = nil, warning: Bool = false) -> PowerSnapshot {
    PowerSnapshot(kind: kind, percentage: percent, isLowBatteryWarning: warning)
}

@Suite("PowerMonitor")
struct PowerMonitorTests {
    private func run(_ script: [PowerSourceEvent]) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = PowerMonitor(
            source: ScriptedPowerSource(script: script),
            context: MonitorContext(dispatcher: dispatcher, category: PowerMonitor.category)
        )

        await monitor.start()
        for _ in 0..<100 { await Task.yield() }
        await monitor.stop()
        return await delivery.events
    }

    @Test("the first snapshot is a silent baseline")
    func firstSnapshotIsSilent() async {
        let events = await run([.snapshot(snapshot(.battery, percent: 80))])
        #expect(events.isEmpty)
    }

    @Test("a real source change is announced with old and new")
    func sourceChangeIsAnnounced() async {
        let events = await run([
            .snapshot(snapshot(.battery, percent: 80)),
            .snapshot(snapshot(.ac, percent: 82))
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "PowerChange")
        #expect(events.first?.body.hasPrefix("Source:\tBattery Power → AC Power") == true)
        #expect(events.first?.body.contains("Charge:\t82%") == true)
    }

    @Test("reaching 100% on AC after the baseline announces fully charged exactly once")
    func fullyChargedFiresOnce() async {
        let events = await run([
            .snapshot(snapshot(.ac, percent: 90)),
            .snapshot(snapshot(.ac, percent: 100)),
            .snapshot(snapshot(.ac, percent: 100))
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "PowerFullyCharged")
    }

    @Test("already full at the very first reading is not announced")
    func alreadyFullAtBaselineIsSilent() async {
        let events = await run([.snapshot(snapshot(.ac, percent: 100))])
        #expect(events.isEmpty)
    }

    @Test("dropping below full and reaching it again re-announces")
    func fullyChargedReArmsAfterDropping() async {
        let events = await run([
            .snapshot(snapshot(.ac, percent: 100)),
            .snapshot(snapshot(.battery, percent: 95)),
            .snapshot(snapshot(.ac, percent: 100))
        ])

        #expect(events.filter { $0.name == "PowerFullyCharged" }.count == 1)
    }

    @Test("a low battery warning fires once on the rising edge, not every poll")
    func lowBatteryWarningIsEdgeTriggered() async {
        let events = await run([
            .snapshot(snapshot(.battery, percent: 20, warning: false)),
            .snapshot(snapshot(.battery, percent: 10, warning: true)),
            .snapshot(snapshot(.battery, percent: 9, warning: true))
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "PowerWarning")
    }

    @Test("the warning can fire again after recovering and dropping low a second time")
    func lowBatteryWarningRearmsAfterRecovery() async {
        let events = await run([
            .snapshot(snapshot(.battery, percent: 20, warning: false)),
            .snapshot(snapshot(.battery, percent: 10, warning: true)),
            .snapshot(snapshot(.ac, percent: 50, warning: false)),
            .snapshot(snapshot(.battery, percent: 10, warning: true))
        ])

        #expect(events.filter { $0.name == "PowerWarning" }.count == 2)
    }

    @Test("system and display sleep/wake are announced under their own distinct events")
    func sleepWakeEventsAreDistinct() async {
        let events = await run([.systemWillSleep, .systemDidWake, .screensDidSleep, .screensDidWake])

        #expect(events.map(\.name) == ["PowerSystemSleep", "PowerSystemWake", "PowerScreensSleep", "PowerScreensWake"])
    }

    @Test("the first Low Power Mode reading is a silent baseline, a real toggle is announced")
    func lowPowerModeBaselineThenToggle() async {
        let events = await run([.lowPowerModeChanged(false), .lowPowerModeChanged(true)])

        #expect(events.count == 1)
        #expect(events.first?.title == "Low Power Mode Enabled")
    }

    @Test("every event it can raise is declared for preferences to find, with the right defaults")
    func eventsAreDeclaredWithDefaults() {
        let byName = Dictionary(uniqueKeysWithValues: PowerMonitor.events.map { ($0.name, $0.enabledByDefault) })

        #expect(byName == [
            "PowerChange": true,
            "PowerFullyCharged": true,
            "PowerWarning": true,
            "PowerSystemSleep": false,
            "PowerSystemWake": false,
            "PowerScreensSleep": false,
            "PowerScreensWake": false,
            "PowerLowPowerMode": false
        ])
    }

    @Test("a Mac with no battery is not told a charge level it does not have")
    func noBatteryMeansNoChargeLine() async {
        let events = await run([
            .snapshot(snapshot(.ac, percent: nil)),
            .snapshot(snapshot(.unknown, percent: nil))
        ])

        #expect(events.first?.body.contains("Charge:") == false)
    }

    @Test("stopping twice is harmless")
    func stoppingTwiceIsHarmless() async {
        let monitor = PowerMonitor(
            source: ScriptedPowerSource(script: []),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: CollectingDelivery()),
                category: PowerMonitor.category
            )
        )

        await monitor.start()
        await monitor.stop()
        await monitor.stop()
    }
}
