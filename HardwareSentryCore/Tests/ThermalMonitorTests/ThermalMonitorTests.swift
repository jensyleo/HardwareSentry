import Foundation
import SignalCore
import SentryContract
import Testing
@testable import ThermalMonitor

/// Stands in for the system, so what the monitor says can be checked without forcing the
/// Mac to actually throttle.
struct ScriptedThermalSource: ThermalStateSource {
    let baseline: ThermalState
    let stateScript: [ThermalState]
    let darkWakeScript: [Void]

    init(baseline: ThermalState = .nominal, stateScript: [ThermalState] = [], darkWakeCount: Int = 0) {
        self.baseline = baseline
        self.stateScript = stateScript
        self.darkWakeScript = Array(repeating: (), count: darkWakeCount)
    }

    func currentState() -> ThermalState { baseline }

    func stateChanges() -> AsyncStream<ThermalState> {
        AsyncStream { continuation in
            for state in stateScript { continuation.yield(state) }
            continuation.finish()
        }
    }

    func darkWakeEmergencies() -> AsyncStream<Void> {
        AsyncStream { continuation in
            for _ in darkWakeScript { continuation.yield(()) }
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

@Suite("ThermalMonitor")
struct ThermalMonitorTests {
    private func run(baseline: ThermalState = .nominal, stateScript: [ThermalState] = [], darkWakeCount: Int = 0, expecting: Int) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = ThermalMonitor(
            source: ScriptedThermalSource(baseline: baseline, stateScript: stateScript, darkWakeCount: darkWakeCount),
            context: MonitorContext(dispatcher: dispatcher, category: ThermalMonitor.category)
        )

        await monitor.start()
        for _ in 0..<100 where await delivery.events.count < expecting {
            await Task.yield()
        }
        await monitor.stop()
        return await delivery.events
    }

    @Test("the baseline reading is silent")
    func baselineIsSilent() async {
        let events = await run(baseline: .serious, stateScript: [], expecting: 0)
        #expect(events.isEmpty)
    }

    @Test("a real transition is announced under the new level's own event name")
    func transitionIsAnnouncedUnderNewLevel() async {
        let events = await run(baseline: .nominal, stateScript: [.serious], expecting: 1)

        #expect(events.count == 1)
        #expect(events.first?.name == "ThermalSerious")
        #expect(events.first?.title == "Thermal State Changed")
        #expect(events.first?.category == ThermalEvent.category)
    }

    @Test("worsening and improving are both described, with an arrow")
    func transitionIsDescribed() {
        #expect(
            ThermalMonitor.describeTransition(from: .nominal, to: .critical)
                == "State:\tNominal → Critical — performance significantly reduced\n↑ Warming up (worsening)"
        )
        #expect(
            ThermalMonitor.describeTransition(from: .critical, to: .nominal)
                == "State:\tCritical → Nominal — running normally\n↓ Cooling down (improving)"
        )
    }

    @Test("repeating the same level twice only announces the first move")
    func repeatingLevelDoesNotReannounce() async {
        let events = await run(baseline: .nominal, stateScript: [.fair, .fair], expecting: 1)
        #expect(events.count == 1)
    }

    @Test("a dark wake emergency is announced under its own event, independent of the level ticks")
    func darkWakeEmergencyIsAnnounced() async {
        let events = await run(baseline: .nominal, darkWakeCount: 1, expecting: 1)

        #expect(events.count == 1)
        #expect(events.first?.name == "ThermalDarkWakeEmergency")
        #expect(events.first?.title == "Dark Wake Thermal Emergency")
    }

    @Test("every event it can raise is declared for preferences to find, with the right defaults")
    func eventsAreDeclaredWithDefaults() {
        let byName = Dictionary(uniqueKeysWithValues: ThermalMonitor.events.map { ($0.name, $0.enabledByDefault) })

        #expect(byName == [
            "ThermalNominal": false,
            "ThermalFair": false,
            "ThermalSerious": true,
            "ThermalCritical": true,
            "ThermalDarkWakeEmergency": true
        ])
    }

    @Test("stopping twice is harmless")
    func stoppingTwiceIsHarmless() async {
        let monitor = ThermalMonitor(
            source: ScriptedThermalSource(),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: CollectingDelivery()),
                category: ThermalMonitor.category
            )
        )

        await monitor.start()
        await monitor.stop()
        await monitor.stop()
    }
}
