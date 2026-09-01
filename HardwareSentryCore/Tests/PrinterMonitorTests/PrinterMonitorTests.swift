import Foundation
import SignalCore
import SentryContract
import Testing
@testable import PrinterMonitor

struct ScriptedPrinterSource: PrinterSource {
    let script: [PrinterSourceEvent]

    func changes() -> AsyncStream<PrinterSourceEvent> {
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

private func printer(
    _ name: String, isDefault: Bool = false, reasons: String = "none", rejecting: Bool = false
) -> PrinterSnapshot {
    PrinterSnapshot(name: name, isDefault: isDefault, stateReasons: reasons, isRejectingJobs: rejecting)
}

@Suite("PrinterMonitor")
struct PrinterMonitorTests {
    private func run(_ script: [PrinterSourceEvent]) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = PrinterMonitor(
            source: ScriptedPrinterSource(script: script),
            context: MonitorContext(dispatcher: dispatcher, category: PrinterMonitor.category)
        )

        await monitor.start()
        for _ in 0..<100 { await Task.yield() }
        await monitor.stop()
        return await delivery.events
    }

    @Test("the first snapshot is a silent baseline")
    func firstSnapshotIsSilent() async {
        let events = await run([.snapshot([printer("HP LaserJet")])])
        #expect(events.isEmpty)
    }

    @Test("a printer appearing after the baseline is announced")
    func newPrinterIsAnnounced() async {
        let events = await run([
            .snapshot([]),
            .snapshot([printer("HP LaserJet")])
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "PrinterConnected")
        #expect(events.first?.subject == "HP LaserJet")
    }

    @Test("a printer disappearing is announced")
    func removedPrinterIsAnnounced() async {
        let events = await run([
            .snapshot([printer("HP LaserJet")]),
            .snapshot([])
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "PrinterDisconnected")
    }

    @Test("an informational -report reason is not a problem (no false Needs Attention)")
    func reportReasonIsNotAProblem() async {
        let events = await run([
            .snapshot([printer("HP LaserJet", reasons: "none")]),
            .snapshot([printer("HP LaserJet", reasons: "connecting-to-device")])
        ])
        #expect(events.isEmpty)
    }

    @Test("an -error reason transitions to Needs Attention, and clearing it transitions back to OK")
    func errorTransitionsBothWays() async {
        let events = await run([
            .snapshot([printer("HP LaserJet", reasons: "none")]),
            .snapshot([printer("HP LaserJet", reasons: "media-empty-error")]),
            .snapshot([printer("HP LaserJet", reasons: "none")])
        ])

        #expect(events.count == 2)
        #expect(events[0].title == "Printer Needs Attention")
        #expect(events[0].body.contains("Out of paper"))
        #expect(events[1].title == "Printer OK")
    }

    @Test("rejecting jobs is tracked independently of state reasons")
    func rejectingJobsIsIndependent() async {
        let events = await run([
            .snapshot([printer("HP LaserJet", reasons: "none", rejecting: false)]),
            .snapshot([printer("HP LaserJet", reasons: "none", rejecting: true)])
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "PrinterRejectingJobs")
        #expect(events.first?.title == "Printer Is Rejecting Jobs")
    }

    @Test("the default printer changing is reported, but never on the first baseline")
    func defaultChangeIsReported() async {
        let events = await run([
            .snapshot([printer("A", isDefault: true), printer("B")]),
            .snapshot([printer("A"), printer("B", isDefault: true)])
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == "PrinterDefaultChanged")
        #expect(events.first?.body == "A → B")
    }

    @Test("every event it can raise is declared for preferences to find, with the right defaults")
    func eventsAreDeclaredWithDefaults() {
        let byName = Dictionary(uniqueKeysWithValues: PrinterMonitor.events.map { ($0.name, $0.enabledByDefault) })

        #expect(byName == [
            "PrinterConnected": true,
            "PrinterDisconnected": true,
            "PrinterError": false,
            "PrinterDefaultChanged": false,
            "PrinterRejectingJobs": false
        ])
    }

    @Test("stopping twice is harmless")
    func stoppingTwiceIsHarmless() async {
        let monitor = PrinterMonitor(
            source: ScriptedPrinterSource(script: []),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: CollectingDelivery()),
                category: PrinterMonitor.category
            )
        )

        await monitor.start()
        await monitor.stop()
        await monitor.stop()
    }
}

@Suite("PrinterStateReasons")
struct PrinterStateReasonsTests {
    @Test("none and empty are not problems")
    func noneIsNotAProblem() {
        #expect(!PrinterStateReasons.indicatesProblem("none"))
        #expect(!PrinterStateReasons.indicatesProblem(""))
    }

    @Test("a -report reason alone is not a problem")
    func reportAloneIsNotAProblem() {
        #expect(!PrinterStateReasons.indicatesProblem("connecting-to-device"))
    }

    @Test("a mix of -report and -warning is a problem, and only the warning is described")
    func mixedReasonsOnlyDescribesTheRealOnes() {
        let reasons = "connecting-to-device,toner-low-warning"
        #expect(PrinterStateReasons.indicatesProblem(reasons))
        #expect(PrinterStateReasons.friendlyDescription(reasons) == "Toner low")
    }

    @Test("an unrecognized reason still reads reasonably")
    func unknownReasonFallsBackToASpacedCapitalizedLabel() {
        #expect(PrinterStateReasons.friendlyLabel(for: "some-vendor-thing-error") == "Some vendor thing")
    }
}
