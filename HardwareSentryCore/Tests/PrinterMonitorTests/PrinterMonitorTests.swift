import CCUPS
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
            context: MonitorContext(
                dispatcher: dispatcher,
                category: PrinterMonitor.category,
                // These exercise what happens when something *changes*, so the startup
                // sweep is switched off: with it on, the first snapshot is announced and
                // every count below would be measuring the sweep as well as the change.
                announcesWhatIsAlreadyThere: false
            )
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
            "PrinterRejectingJobs": false,
            "PrinterSupplyLow": true,
            "PrintJobStarted": false,
            "PrintJobFinished": false,
            "PrintJobCanceled": false
        ])
    }

    @Test("the details a printer can report show up when it connects")
    func connectCarriesDeclaredDetails() async {
        let events = await run([
            .snapshot([]),
            .snapshot([PrinterSnapshot(
                name: "HP LaserJet", isDefault: false, stateReasons: "none", isRejectingJobs: false,
                location: "Office", makeAndModel: "HP LaserJet Pro M404",
                connection: "Network", isShared: true, capabilities: "Color, Duplex"
            )])
        ])

        let body = events.first?.body ?? ""
        #expect(body.hasPrefix("HP LaserJet"))
        #expect(body.contains("Location: Office"))
        #expect(body.contains("Model: HP LaserJet Pro M404"))
        #expect(body.contains("Connection: Network"))
        #expect(body.contains("Shared: Yes"))
        #expect(body.contains("Capabilities: Color, Duplex"))
    }

    @Test("a printer that reports none of the extra detail says only its name")
    func missingDetailsAreOmitted() async {
        let events = await run([
            .snapshot([]),
            .snapshot([printer("Bare Printer")])
        ])

        // "Shared" still has something to say — no is an answer — but the rest do not.
        let body = events.first?.body ?? ""
        #expect(body.hasPrefix("Bare Printer"))
        #expect(!body.contains("Location:"))
        #expect(!body.contains("Model:"))
        #expect(!body.contains("Capabilities:"))
    }

    @Test("a device URI's scheme is turned into how the printer is reached")
    func connectionKindFromURI() {
        #expect(CUPSPrinterSource.connectionKind(fromDeviceURI: "usb://HP/LaserJet") == "USB")
        #expect(CUPSPrinterSource.connectionKind(fromDeviceURI: "dnssd://Printer._ipp._tcp") == "Network")
        #expect(CUPSPrinterSource.connectionKind(fromDeviceURI: "ipps://printer.local") == "Network")
        // Something unrecognised is still shown, rather than swallowed.
        #expect(CUPSPrinterSource.connectionKind(fromDeviceURI: "weird://thing") == "WEIRD")
    }

    @Test("only capabilities a person would recognise are named")
    func capabilitiesAreNamed() {
        let colorAndDuplex = CUPS_PRINTER_COLOR.rawValue | CUPS_PRINTER_DUPLEX.rawValue
        #expect(CUPSPrinterSource.capabilities(colorAndDuplex) == "Color, Duplex")
        #expect(CUPSPrinterSource.capabilities(0) == nil)
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

// MARK: - Supplies and jobs

private struct ChosenFields: NotificationPreferences {
    let allowed: Set<String>
    func isFieldEnabled(_ name: String, in category: NotificationCategory) async -> Bool {
        allowed.contains(name)
    }
}

@Suite("PrinterSupply · reading CUPS's parallel lists")
struct PrinterSupplyParsingTests {
    @Test("the four lists are read into supplies, in order")
    func parsesFourLists() {
        let supplies = PrinterSupply.parse(
            names: "Black Toner,Cyan Toner,Waste Toner Box",
            levels: "8,64,90",
            types: "toner,toner,waste-toner",
            lowLevels: "10,10,5"
        )

        #expect(supplies.count == 3)
        #expect(supplies[0] == PrinterSupply(name: "Black Toner", type: "toner", percentage: 8, lowMark: 10))
        #expect(supplies[2].type == "waste-toner")
    }

    @Test("a level CUPS declines to give is not shown as a negative percentage")
    func unknownLevelsAreNil() {
        let supplies = PrinterSupply.parse(names: "Ink,Drum,Fuser", levels: "-1,-2,-3", types: nil, lowLevels: nil)
        #expect(supplies.allSatisfy { $0.percentage == nil })
        #expect(supplies.allSatisfy { $0.levelNote == nil })
    }

    @Test("a supply with a comma in its name stays one supply")
    func quotedNamesSurvive() {
        let supplies = PrinterSupply.parse(
            names: "'Black, High Yield',Cyan",
            levels: "20,80",
            types: nil,
            lowLevels: nil
        )
        #expect(supplies.map(\.name) == ["Black, High Yield", "Cyan"])
        #expect(supplies[1].percentage == 80)
    }

    @Test("lists of different lengths do not invent supplies or crash")
    func mismatchedLists() {
        // More levels than names: the extra numbers have nothing to attach to.
        let extraLevels = PrinterSupply.parse(names: "Black", levels: "10,20,30", types: nil, lowLevels: nil)
        #expect(extraLevels.count == 1)
        #expect(extraLevels[0].percentage == 10)

        // More names than levels: the named supplies survive, without a level each.
        let extraNames = PrinterSupply.parse(names: "Black,Cyan,Magenta", levels: "10", types: nil, lowLevels: nil)
        #expect(extraNames.count == 3)
        #expect(extraNames[1].percentage == nil)
    }

    @Test("nothing reported means no supplies, not one empty one")
    func emptyLists() {
        #expect(PrinterSupply.parse(names: nil, levels: nil, types: nil, lowLevels: nil).isEmpty)
        #expect(PrinterSupply.parse(names: "", levels: "", types: nil, lowLevels: nil).isEmpty)
    }

    @Test("the printer's own low mark wins over the fallback")
    func printerLowMarkWins() {
        // A printer that considers 30% low, because the last of its toner prints badly.
        let fussy = PrinterSupply(name: "Black", percentage: 25, lowMark: 30)
        #expect(fussy.isLow(fallbackThreshold: 10))

        // And one that does not publish a mark falls back.
        let plain = PrinterSupply(name: "Black", percentage: 25)
        #expect(!plain.isLow(fallbackThreshold: 10))
        #expect(PrinterSupply(name: "Black", percentage: 9).isLow(fallbackThreshold: 10))
    }

    @Test("recovery is a higher bar than the warning")
    func recoveryHasMargin() {
        let supply = PrinterSupply(name: "Black", percentage: 12)
        #expect(!supply.hasRecovered(fallbackThreshold: 10, margin: 5))
        #expect(PrinterSupply(name: "Black", percentage: 15).hasRecovered(fallbackThreshold: 10, margin: 5))
    }

    @Test("a supply with no reading is neither low nor recovered")
    func unknownIsNeither() {
        let unknown = PrinterSupply(name: "Black")
        #expect(!unknown.isLow(fallbackThreshold: 10))
        #expect(!unknown.hasRecovered(fallbackThreshold: 10, margin: 5))
    }
}

@Suite("PrinterMonitor · supply warnings")
struct PrinterSupplyWarningTests {
    private func run(
        _ script: [PrinterSourceEvent],
        allowing allowed: Set<String> = Set(PrinterField.allCases.map(\.rawValue))
    ) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = PrinterMonitor(
            source: ScriptedPrinterSource(script: script),
            context: MonitorContext(
                dispatcher: dispatcher,
                category: PrinterMonitor.category,
                preferences: ChosenFields(allowed: allowed),
                announcesWhatIsAlreadyThere: false
            )
        )
        await monitor.start()
        for _ in 0..<100 { await Task.yield() }
        await monitor.stop()
        return await delivery.events.filter { $0.name == PrinterEvent.supplyLow.rawValue }
    }

    private func laser(black: Int, cyan: Int = 80) -> PrinterSourceEvent {
        .snapshot([PrinterSnapshot(
            name: "Office Laser",
            isDefault: true,
            stateReasons: "none",
            isRejectingJobs: false,
            supplies: [
                PrinterSupply(name: "Black Toner", type: "toner", percentage: black, lowMark: 10),
                PrinterSupply(name: "Cyan Toner", type: "toner", percentage: cyan, lowMark: 10)
            ]
        )])
    }

    @Test("a cartridge running low is reported once, not on every poll")
    func warnsOnceWhileLow() async {
        let events = await run([laser(black: 8), laser(black: 7), laser(black: 6)])

        #expect(events.count == 1)
        #expect(events.first?.title == "Black Toner Low (8%)")
        #expect(events.first?.subject == "Office Laser")
        // Every supply is listed, not just the low one: while the printer is open anyway,
        // what else is nearly out is worth knowing.
        #expect(events.first?.body.contains("Black Toner: 8%, Cyan Toner: 80%") == true)
    }

    @Test("replacing the cartridge arms the warning again without announcing the refill")
    func recoveryIsSilentButRearms() async {
        let events = await run([
            laser(black: 8),
            laser(black: 100),   // replaced — nothing to say
            laser(black: 9)      // and it runs low again, months later
        ])

        #expect(events.count == 2)
        #expect(events.map(\.title) == ["Black Toner Low (8%)", "Black Toner Low (9%)"])
    }

    @Test("a supply hovering on the line is not reported over and over")
    func hysteresisHolds() async {
        let events = await run([
            laser(black: 10),
            laser(black: 11),   // above the mark, but not by the margin
            laser(black: 12),
            laser(black: 9)
        ])
        #expect(events.count == 1)
    }

    @Test("a printer that says nothing about its supplies gets no warning")
    func silentPrinterIsSilent() async {
        let events = await run([.snapshot([PrinterSnapshot(
            name: "AirPrint Printer", isDefault: false, stateReasons: "none", isRejectingJobs: false
        )])])
        #expect(events.isEmpty)
    }

    @Test("a printer unplugged while low warns again when it comes back")
    func forgottenWithThePrinter() async {
        let events = await run([laser(black: 8), .snapshot([]), laser(black: 8)])
        #expect(events.count == 2)
    }

    @Test("two printers low at once are two warnings, not one")
    func warningsArePerPrinter() async {
        let both = PrinterSourceEvent.snapshot([
            PrinterSnapshot(name: "Laser", isDefault: true, stateReasons: "none", isRejectingJobs: false,
                            supplies: [PrinterSupply(name: "Black Toner", percentage: 5)]),
            PrinterSnapshot(name: "Inkjet", isDefault: false, stateReasons: "none", isRejectingJobs: false,
                            supplies: [PrinterSupply(name: "Black Ink", percentage: 4)])
        ])
        let events = await run([both, both])

        #expect(events.count == 2)
        #expect(Set(events.compactMap(\.subject)) == ["Laser", "Inkjet"])
    }

    @Test("the levels line can be switched off, and then the warning still says which supply")
    func levelsFieldCanBeOff() async {
        let events = await run([laser(black: 8)], allowing: [])
        #expect(events.count == 1)
        #expect(events.first?.title == "Black Toner Low (8%)")
        #expect(events.first?.body == "Office Laser")
    }
}

@Suite("PrinterMonitor · jobs")
struct PrintJobTests {
    private func run(_ script: [PrinterSourceEvent]) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = PrinterMonitor(
            source: ScriptedPrinterSource(script: script),
            context: MonitorContext(
                dispatcher: dispatcher,
                category: PrinterMonitor.category,
                announcesWhatIsAlreadyThere: false
            )
        )
        await monitor.start()
        for _ in 0..<100 { await Task.yield() }
        await monitor.stop()
        return await delivery.events
    }

    private func job(_ id: Int, _ title: String = "Report.pdf", state: PrintJobState = .processing) -> PrintJob {
        PrintJob(id: id, title: title, printerName: "Office Laser", user: "jensyleo", sizeKilobytes: 2048, state: state)
    }

    @Test("the jobs already queued when it starts are not announced")
    func firstJobListIsBaseline() async {
        let events = await run([.jobs(active: [job(1), job(2)], recentlyEnded: [])])
        #expect(events.isEmpty)
    }

    @Test("a new job is announced by its document name")
    func newJobIsAnnounced() async {
        let events = await run([
            .jobs(active: [], recentlyEnded: []),
            .jobs(active: [job(7, "Invoice.pdf")], recentlyEnded: [])
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == PrinterEvent.jobStarted.rawValue)
        #expect(events.first?.title == "Printing Invoice.pdf")
        #expect(events.first?.subject == "Office Laser#7")
        #expect(events.first?.body.contains("Printer:\tOffice Laser") == true)
    }

    @Test("a job that printed and one that was cancelled are told apart")
    func endingsAreDistinguished() async {
        let events = await run([
            .jobs(active: [job(1), job(2)], recentlyEnded: []),
            .jobs(active: [], recentlyEnded: [
                job(1, "Printed.pdf", state: .completed),
                job(2, "Abandoned.pdf", state: .canceled)
            ])
        ])

        #expect(events.count == 2)
        let byName = Dictionary(uniqueKeysWithValues: events.map { ($0.name, $0.title) })
        #expect(byName[PrinterEvent.jobFinished.rawValue] == "Finished printing Printed.pdf")
        #expect(byName[PrinterEvent.jobCanceled.rawValue] == "Cancelled printing Abandoned.pdf")
    }

    @Test("a job the printer gave up on is worded as a failure, not a cancellation")
    func abortedIsAFailure() async {
        let events = await run([
            .jobs(active: [job(3)], recentlyEnded: []),
            .jobs(active: [], recentlyEnded: [job(3, "Big.pdf", state: .aborted)])
        ])

        #expect(events.first?.name == PrinterEvent.jobCanceled.rawValue)
        #expect(events.first?.title == "Print job failed: Big.pdf")
    }

    @Test("a job that leaves the queue without a final state is not guessed at")
    func unknownEndingIsSilent() async {
        let events = await run([
            .jobs(active: [job(4)], recentlyEnded: []),
            // Gone from the active list and absent from the finished one.
            .jobs(active: [], recentlyEnded: [])
        ])
        #expect(events.isEmpty)
    }

    @Test("a job still pending in the finished list is not called finished")
    func nonFinalStateInEndedListIsIgnored() async {
        let events = await run([
            .jobs(active: [job(5)], recentlyEnded: []),
            .jobs(active: [], recentlyEnded: [job(5, state: .held)])
        ])
        #expect(events.isEmpty)
    }

    @Test("a job submitted without a name is still identifiable")
    func untitledJob() async {
        let events = await run([
            .jobs(active: [], recentlyEnded: []),
            .jobs(active: [job(9, "   ")], recentlyEnded: [])
        ])
        #expect(events.first?.title == "Printing Untitled document")
    }

    @Test("a job's size reads in the unit that suits it")
    func sizeWording() {
        #expect(PrintJob(id: 1, title: "a", printerName: "p", sizeKilobytes: 512).sizeNote == "512 KB")
        #expect(PrintJob(id: 1, title: "a", printerName: "p", sizeKilobytes: 2048).sizeNote == "2.0 MB")
        #expect(PrintJob(id: 1, title: "a", printerName: "p", sizeKilobytes: 0).sizeNote == nil)
        #expect(PrintJob(id: 1, title: "a", printerName: "p").sizeNote == nil)
    }

    @Test("a job's priority is only mentioned when somebody set it")
    func priorityWording() {
        // 50 is what CUPS gives every job nobody prioritised, so a line saying it would
        // appear on every job and distinguish nothing.
        #expect(PrintJob(id: 1, title: "a", printerName: "p", priority: 50).priorityNote == nil)
        #expect(PrintJob(id: 1, title: "a", printerName: "p", priority: 90).priorityNote == "priority 90")
        #expect(PrintJob(id: 1, title: "a", printerName: "p", priority: 1).priorityNote == "priority 1")
        // Out of range means CUPS gave nothing useful, not a job of priority zero.
        #expect(PrintJob(id: 1, title: "a", printerName: "p", priority: 0).priorityNote == nil)
        #expect(PrintJob(id: 1, title: "a", printerName: "p").priorityNote == nil)
    }

    @Test("every event and field it can raise is declared for preferences to find")
    func eventsAndFieldsAreDeclared() {
        let events = Dictionary(uniqueKeysWithValues: PrinterMonitor.events.map { ($0.name, $0.enabledByDefault) })
        #expect(events.count == 9)
        // Toner low is on; the per-document job notifications are not.
        #expect(events[PrinterEvent.supplyLow.rawValue] == true)
        #expect(events[PrinterEvent.jobStarted.rawValue] == false)
        #expect(events[PrinterEvent.jobFinished.rawValue] == false)
        #expect(events[PrinterEvent.jobCanceled.rawValue] == false)

        #expect(Set(PrinterMonitor.fields.map(\.name)) == Set(PrinterField.allCases.map(\.rawValue)))
    }
}
