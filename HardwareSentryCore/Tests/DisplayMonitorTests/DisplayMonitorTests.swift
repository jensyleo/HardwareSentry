import Foundation
import SignalCore
import SentryContract
import Testing
@testable import DisplayMonitor

struct ScriptedDisplaySource: DisplaySource {
    let script: [DisplaySourceEvent]

    func changes() -> AsyncStream<DisplaySourceEvent> {
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

private func display(
    id: String, name: String = "Display", width: Int = 1920, height: Int = 1080,
    hz: Double = 60, rotation: Double = 0, role: DisplayRole = .main, asleep: Bool = false
) -> DisplaySnapshot {
    DisplaySnapshot(id: id, name: name, width: width, height: height, refreshHz: hz, rotation: rotation, role: role, isAsleep: asleep)
}

@Suite("DisplayMonitor")
struct DisplayMonitorTests {
    private func run(_ script: [DisplaySourceEvent]) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = DisplayMonitor(
            source: ScriptedDisplaySource(script: script),
            context: MonitorContext(dispatcher: dispatcher, category: DisplayMonitor.category)
        )

        await monitor.start()
        for _ in 0..<100 { await Task.yield() }
        await monitor.stop()
        return await delivery.events
    }

    @Test("the first snapshot is a silent baseline")
    func firstSnapshotIsSilent() async {
        let events = await run([.snapshot([display(id: "1")])])
        #expect(events.isEmpty)
    }

    @Test("a display appearing after the baseline is announced")
    func newDisplayIsAnnounced() async {
        let events = await run([
            .snapshot([display(id: "1")]),
            .snapshot([display(id: "1"), display(id: "2", name: "LG UltraFine")])
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "DisplayConnected")
        #expect(events.first?.subject == "2")
        #expect(events.first?.body == "LG UltraFine")
    }

    @Test("a display disappearing keeps its last known name")
    func removedDisplayKeepsLastKnownName() async {
        let events = await run([
            .snapshot([display(id: "1"), display(id: "2", name: "LG UltraFine")]),
            .snapshot([display(id: "1")])
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "DisplayDisconnected")
        #expect(events.first?.body == "LG UltraFine")
    }

    @Test("a resolution change on a still-online display is a mode change, not a reconnect")
    func resolutionChangeIsModeChange() async {
        let events = await run([
            .snapshot([display(id: "1", width: 1920, height: 1080, hz: 60)]),
            .snapshot([display(id: "1", width: 3840, height: 2160, hz: 60)])
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "DisplayModeChanged")
        #expect(events.first?.body.contains("1920×1080 → 3840×2160") == true)
    }

    @Test("a role change is reported separately from a mode change")
    func roleChangeIsSeparate() async {
        let events = await run([
            .snapshot([display(id: "1", role: .extended)]),
            .snapshot([display(id: "1", role: .main)])
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "DisplayRoleChanged")
        #expect(events.first?.body.contains("Extended → Main display") == true)
    }

    @Test("sleeping and waking use distinct titles")
    func sleepAndWakeHaveDistinctTitles() async {
        let events = await run([
            .snapshot([display(id: "1", asleep: false)]),
            .snapshot([display(id: "1", asleep: true)]),
            .snapshot([display(id: "1", asleep: false)])
        ])

        #expect(events.count == 2)
        #expect(events[0].title == "Display Slept")
        #expect(events[1].title == "Display Woke")
    }

    @Test("a color profile change is its own event, with no specific display")
    func colorProfileChangeIsAnnounced() async {
        let events = await run([.colorProfileChanged])

        #expect(events.count == 1)
        #expect(events.first?.name == "DisplayColorProfileChanged")
    }

    @Test("mode and role can both change at once and both are reported")
    func modeAndRoleCanBothChange() async {
        let events = await run([
            .snapshot([display(id: "1", width: 1920, height: 1080, role: .extended)]),
            .snapshot([display(id: "1", width: 3840, height: 2160, role: .mirrored)])
        ])

        #expect(events.count == 2)
        #expect(Set(events.map(\.name)) == ["DisplayModeChanged", "DisplayRoleChanged"])
    }

    @Test("every event it can raise is declared for preferences to find, with the right defaults")
    func eventsAreDeclaredWithDefaults() {
        let byName = Dictionary(uniqueKeysWithValues: DisplayMonitor.events.map { ($0.name, $0.enabledByDefault) })

        #expect(byName == [
            "DisplayConnected": true,
            "DisplayDisconnected": true,
            "DisplayModeChanged": true,
            "DisplayRoleChanged": true,
            "DisplaySleepChanged": true,
            "DisplayColorProfileChanged": false
        ])
    }

    @Test("stopping twice is harmless")
    func stoppingTwiceIsHarmless() async {
        let monitor = DisplayMonitor(
            source: ScriptedDisplaySource(script: []),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: CollectingDelivery()),
                category: DisplayMonitor.category
            )
        )

        await monitor.start()
        await monitor.stop()
        await monitor.stop()
    }
}
