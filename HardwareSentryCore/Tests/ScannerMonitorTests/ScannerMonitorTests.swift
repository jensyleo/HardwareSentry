import Foundation
import SignalCore
import SentryContract
import Testing
@testable import ScannerMonitor

struct ScriptedScannerSource: ScannerSource {
    let script: [NetworkScannerChange]

    func changes() -> AsyncStream<NetworkScannerChange> {
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

@Suite("ScannerMonitor")
struct ScannerMonitorTests {
    private func run(_ changes: [NetworkScannerChange]) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = ScannerMonitor(
            source: ScriptedScannerSource(script: changes),
            context: MonitorContext(dispatcher: dispatcher, category: ScannerMonitor.category)
        )

        await monitor.start()
        for _ in 0..<100 where await delivery.events.count < changes.count {
            await Task.yield()
        }
        await monitor.stop()
        return await delivery.events
    }

    @Test("a scanner appearing is announced")
    func foundIsAnnounced() async {
        let events = await run([.found(name: "Brother MFC-L2750DW")])

        #expect(events.count == 1)
        #expect(events.first?.name == "ScannerFound")
        #expect(events.first?.title == "Network Scanner Found")
        #expect(events.first?.subject == "Brother MFC-L2750DW")
        #expect(events.first?.category == ScannerEvent.category)
    }

    @Test("a scanner disappearing is announced")
    func lostIsAnnounced() async {
        let events = await run([.lost(name: "Brother MFC-L2750DW")])

        #expect(events.first?.name == "ScannerLost")
        #expect(events.first?.title == "Network Scanner Lost")
    }

    @Test("every event it can raise is declared for preferences to find")
    func eventsAreDeclared() {
        let declared = Set(ScannerMonitor.events.map(\.name))
        #expect(declared == ["ScannerFound", "ScannerLost"])
    }

    @Test("stopping twice is harmless")
    func stoppingTwiceIsHarmless() async {
        let monitor = ScannerMonitor(
            source: ScriptedScannerSource(script: []),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: CollectingDelivery()),
                category: ScannerMonitor.category
            )
        )

        await monitor.start()
        await monitor.stop()
        await monitor.stop()
    }
}
