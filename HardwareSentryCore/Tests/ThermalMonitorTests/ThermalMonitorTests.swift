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
        await waitUntil { await delivery.events.count >= expecting }
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
            "ThermalDarkWakeEmergency": false
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

/// A source that also reports Low Power Mode, without needing the Mac to be in it.
private struct LowPowerThermalSource: ThermalStateSource {
    let lowPower: Bool
    let script: [ThermalState]

    func currentState() -> ThermalState { .nominal }
    func isLowPowerModeEnabled() -> Bool { lowPower }
    func stateChanges() -> AsyncStream<ThermalState> {
        AsyncStream { c in
            for state in script { c.yield(state) }
            c.finish()
        }
    }
    func darkWakeEmergencies() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

private struct ChosenFields: NotificationPreferences {
    let allowed: Set<String>
    func isFieldEnabled(_ name: String, in category: NotificationCategory) async -> Bool {
        allowed.contains(name)
    }
}

@Suite("ThermalMonitor Low Power Mode note")
struct ThermalLowPowerFieldTests {
    private func body(lowPower: Bool, allowing allowed: Set<String>) async -> String? {
        let delivery = CollectingDelivery()
        let monitor = ThermalMonitor(
            source: LowPowerThermalSource(lowPower: lowPower, script: [.serious]),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: ThermalMonitor.category,
                preferences: ChosenFields(allowed: allowed)
            )
        )
        await monitor.start()
        await waitUntil { await delivery.events.isEmpty == false }
        await monitor.stop()
        return await delivery.events.first?.body
    }

    @Test("when asked for, the note appears alongside the state change")
    func noteAppearsWhenBothAreTrue() async {
        let body = await body(lowPower: true, allowing: [ThermalField.lowPowerMode.rawValue])
        #expect(body?.contains("Low Power Mode is also currently on") == true)
    }

    @Test("Low Power Mode off means no line at all, not a line saying it is off")
    func noNoteWhenLowPowerIsOff() async {
        let body = await body(lowPower: false, allowing: [ThermalField.lowPowerMode.rawValue])
        #expect(body?.contains("Low Power Mode") == false)
    }

    @Test("the note is off by default, so nobody is told about it unasked")
    func offByDefault() async {
        #expect(ThermalMonitor.fields.first(where: { $0.name == ThermalField.lowPowerMode.rawValue })?.shownByDefault == false)
        let body = await body(lowPower: true, allowing: [])
        #expect(body?.contains("Low Power Mode") == false)
    }
}

/// Waits until `isReady` answers true, or a couple of seconds pass.
///
/// Bounded by the clock rather than by a number of turns. How many turns a scripted
/// source needs depends on how the runtime schedules and how busy the machine is, so a
/// fixed count is a guess that holds until the next toolchain: the counts this replaced
/// began failing at random under Swift 6.4. Sleeping rather than spinning on `yield`
/// also lets the monitor's own task run instead of competing with it.
private func waitUntil(_ isReady: () async -> Bool) async {
    let deadline = Date().addingTimeInterval(2)
    while await isReady() == false, Date() < deadline {
        try? await Task.sleep(nanoseconds: 200_000)
    }
}
