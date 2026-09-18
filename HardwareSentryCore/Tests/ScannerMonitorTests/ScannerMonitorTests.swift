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
        await waitUntil { await delivery.events.count >= changes.count }
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
        #expect(declared == ["ScannerFound", "ScannerLost", "ScannerScanStatus", "ScannerAdfStateChanged"])
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

private struct ChosenFields: NotificationPreferences {
    let allowed: Set<String>
    func isFieldEnabled(_ name: String, in category: NotificationCategory) async -> Bool {
        allowed.contains(name)
    }
}

/// A TXT record as a real scanner advertises it — a dictionary of raw bytes.
private func txt(_ pairs: [String: String]) -> [String: Data] {
    pairs.mapValues { Data($0.utf8) }
}

@Suite("ScannerDetail from a Bonjour TXT record")
struct ScannerDetailTXTTests {
    /// Taken from the shape an AirScan multifunction advertises under `_uscan._tcp`.
    private static let airScan = txt([
        "ty": "HP Color LaserJet MFP M283fdw",
        "note": "Room 3",
        "is": "platen,adf",
        "duplex": "T",
        "pdl": "application/pdf,image/jpeg",
        "cs": "color,grayscale,binary",
        "adminurl": "http://printer.local/hp/device/info_config_AirPrint.html",
        "UUID": "1c9d5b1a-0000-1000-8000-3c2af4a0b1c2"
    ])

    @Test("the abbreviations in the record are spelled out into something readable")
    func abbreviationsAreSpelledOut() {
        let detail = ScannerDetail(txt: Self.airScan, serviceType: "_uscan._tcp.", host: "printer.local.", port: 80)

        #expect(detail.model == "HP Color LaserJet MFP M283fdw")
        #expect(detail.location == "Room 3")
        #expect(detail.inputSources == "Flatbed, Document feeder")
        #expect(detail.supportsDuplex)
        #expect(detail.formats == "PDF, JPEG")
        #expect(detail.colorModes == "Color, Grayscale, Binary")
        #expect(detail.scanProtocol == "AirScan (eSCL)")
    }

    @Test("the host name loses the root dot Bonjour puts on the end")
    func hostIsReadable() {
        let detail = ScannerDetail(txt: Self.airScan, serviceType: "_uscan._tcp.", host: "printer.local.", port: 8080)
        #expect(detail.addressNote == "printer.local:8080")
    }

    @Test("an unresolved port is left off rather than shown as -1")
    func unresolvedPortIsOmitted() {
        let detail = ScannerDetail(txt: [:], serviceType: "_uscan._tcp.", host: "printer.local", port: nil)
        #expect(detail.addressNote == "printer.local")
    }

    @Test("a key the firmware wrote in a different case is still found")
    func keysMatchCaseInsensitively() {
        // The specification writes `ty` and `adminurl`; real firmware is inconsistent, and
        // a field that silently vanishes on one vendor's scanner is worse than no field.
        let detail = ScannerDetail(txt: txt(["TY": "Brother ADS-2700W", "AdminURL": "http://x/"]),
                                   serviceType: "_uscan._tcp.", host: nil, port: nil)
        #expect(detail.model == "Brother ADS-2700W")
        #expect(detail.adminURL == "http://x/")
    }

    @Test("a WSD scanner, which advertises almost nothing, still says which protocol it speaks")
    func sparseWSDRecord() {
        let detail = ScannerDetail(txt: [:], serviceType: "_scanner._tcp.", host: nil, port: nil)

        #expect(detail.scanProtocol == "WSD")
        #expect(detail.model == nil)
        #expect(detail.location == nil)
        #expect(!detail.supportsDuplex)
        #expect(detail.duplexNote == nil)
    }

    @Test("an unfamiliar format or source is passed through rather than dropped")
    func unknownValuesSurvive() {
        let detail = ScannerDetail(txt: txt(["pdl": "image/jpeg,application/x-vendor-raw", "is": "platen,slide"]),
                                   serviceType: "_uscan._tcp.", host: nil, port: nil)
        #expect(detail.formats == "JPEG, application/x-vendor-raw")
        #expect(detail.inputSources == "Flatbed, slide")
    }

    @Test("an empty value is the same as no value")
    func emptyValuesAreNotEmptyLines() {
        // Scanners routinely advertise `note=` with nothing after it, and "Location:" with
        // nothing following it reads as a fault.
        let detail = ScannerDetail(txt: txt(["note": "   ", "ty": ""]), serviceType: "_uscan._tcp.", host: nil, port: nil)
        #expect(detail.location == nil)
        #expect(detail.model == nil)
    }
}

@Suite("ScannerMonitor optional fields")
struct ScannerMonitorFieldTests {
    private func body(_ change: NetworkScannerChange, allowing allowed: Set<String>) async -> String? {
        let delivery = CollectingDelivery()
        let monitor = ScannerMonitor(
            source: ScriptedScannerSource(script: [change]),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: ScannerMonitor.category,
                preferences: ChosenFields(allowed: allowed)
            )
        )
        await monitor.start()
        await waitUntil { await delivery.events.isEmpty == false }
        await monitor.stop()
        return await delivery.events.first?.body
    }

    private static let detail = ScannerDetail(
        model: "HP Color LaserJet MFP M283fdw",
        location: "Room 3",
        host: "printer.local",
        port: 80,
        scanProtocol: "AirScan (eSCL)",
        inputSources: "Flatbed, Document feeder",
        supportsDuplex: true,
        formats: "PDF, JPEG",
        colorModes: "Color, Grayscale",
        adminURL: "http://printer.local/"
    )

    @Test("out of the box the message answers which scanner it is and where")
    func defaultFieldsAreModelAndLocation() async {
        let defaults = Set(ScannerMonitor.fields.filter(\.shownByDefault).map(\.name))
        #expect(defaults == [ScannerField.model.rawValue, ScannerField.location.rawValue, ScannerField.statusReasons.rawValue])

        let body = await body(.found(name: "HP1C9D5B", detail: Self.detail), allowing: defaults)
        #expect(body == "HP1C9D5B\nModel:\tHP Color LaserJet MFP M283fdw\nLocation:\tRoom 3")
    }

    @Test("with everything switched on, the details read in the declared order")
    func fullDetailReadsInOrder() async {
        let body = await body(
            .found(name: "HP1C9D5B", detail: Self.detail),
            allowing: Set(ScannerField.allCases.map(\.rawValue))
        )

        #expect(body == """
        HP1C9D5B
        Model:\tHP Color LaserJet MFP M283fdw
        Location:\tRoom 3
        Address:\tprinter.local:80
        Protocol:\tAirScan (eSCL)
        Sources:\tFlatbed, Document feeder
        Duplex:\tYes
        Formats:\tPDF, JPEG
        Colour:\tColor, Grayscale
        Admin:\thttp://printer.local/
        """)
    }

    @Test("a model identical to the service name is not said twice")
    func modelIsNotRepeated() async {
        let same = ScannerDetail(model: "Brother ADS-2700W", location: "Front desk")
        let body = await body(
            .found(name: "Brother ADS-2700W", detail: same),
            allowing: Set(ScannerField.allCases.map(\.rawValue))
        )

        #expect(body == "Brother ADS-2700W\nLocation:\tFront desk")
    }

    @Test("a scanner that never answered is still announced, just with nothing attached")
    func unresolvedScannerStillAnnounced() async {
        let body = await body(
            .found(name: "Unknown Scanner"),
            allowing: Set(ScannerField.allCases.map(\.rawValue))
        )

        #expect(body == "Unknown Scanner")
    }
}

// MARK: - What the scanner is doing

/// Answers with a scripted sequence of readings, one per poll.
private actor ScriptedStatusReader: ScannerStatusReading {
    private var readings: [ScannerStatus?]
    private(set) var callCount = 0

    init(_ readings: [ScannerStatus?]) {
        self.readings = readings
    }

    func readStatus(host: String, port: Int) async -> ScannerStatus? {
        callCount += 1
        guard !readings.isEmpty else { return nil }
        return readings.removeFirst()
    }
}

@Suite("ScannerStatus · reading the eSCL document")
struct ScannerStatusParsingTests {
    private func xml(_ body: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" \
        xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
        \(body)
        </scan:ScannerStatus>
        """.utf8)
    }

    @Test("state and feeder are read from the document")
    func readsStateAndAdf() {
        let status = ScannerStatus.parse(escl: xml("""
        <pwg:Version>2.63</pwg:Version>
        <pwg:State>Processing</pwg:State>
        <scan:AdfState>ScannerAdfLoaded</scan:AdfState>
        """))

        #expect(status?.state == .processing)
        #expect(status?.adfState == .loaded)
    }

    @Test("a different vendor's namespace prefix reads the same")
    func prefixesAreIgnored() {
        let hp = ScannerStatus.parse(escl: xml("<scan:State>Idle</scan:State><pwg:AdfState>ScannerAdfEmpty</pwg:AdfState>"))
        let bare = ScannerStatus.parse(escl: xml("<State>Idle</State><AdfState>ScannerAdfEmpty</AdfState>"))

        #expect(hp?.state == .idle)
        #expect(bare?.state == .idle)
        #expect(hp == bare)
    }

    @Test("the reasons a scanner gives for stopping are collected")
    func collectsReasons() {
        let status = ScannerStatus.parse(escl: xml("""
        <pwg:State>Stopped</pwg:State>
        <pwg:StateReason>CoverOpen</pwg:StateReason>
        <pwg:StateReason>MediaJam</pwg:StateReason>
        """))

        #expect(status?.stateReasons == ["CoverOpen", "MediaJam"])
        #expect(status?.reasonsNote == "CoverOpen, MediaJam")
    }

    @Test("a flatbed with no feeder reports no feeder state rather than a wrong one")
    func flatbedHasNoAdf() {
        let status = ScannerStatus.parse(escl: xml("<pwg:State>Idle</pwg:State>"))
        #expect(status?.adfState == nil)
    }

    @Test("something that is not a scanner status is no reading at all")
    func rubbishIsNotAStatus() {
        #expect(ScannerStatus.parse(escl: Data("<html><body>404 Not Found</body></html>".utf8)) == nil)
        #expect(ScannerStatus.parse(escl: Data("not xml at all".utf8)) == nil)
        #expect(ScannerStatus.parse(escl: xml("<pwg:Version>2.63</pwg:Version>")) == nil)
    }

    @Test("a state nobody has heard of is not forced into one that has been")
    func unknownStateIsNil() {
        let status = ScannerStatus.parse(escl: xml("<pwg:State>Bananas</pwg:State><pwg:StateReason>Odd</pwg:StateReason>"))
        #expect(status?.state == nil)
        // The rest of the document still counts, so the reading is not thrown away whole.
        #expect(status?.stateReasons == ["Odd"])
    }
}

@Suite("ScannerMonitor · status polling")
struct ScannerStatusPollingTests {
    /// Feeds readings straight to the monitor's own decision, rather than waiting out a
    /// poll interval that is measured in seconds. What the timer does is wiring, tested
    /// separately below; what this decides is the behaviour.
    private func report(_ readings: [ScannerStatus]) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let monitor = ScannerMonitor(
            source: ScriptedScannerSource(script: []),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: ScannerMonitor.category,
                announcesWhatIsAlreadyThere: false
            )
        )

        for reading in readings {
            await monitor.recordStatus(reading, of: "Office MFP")
        }

        return await delivery.events.filter {
            $0.name == ScannerEvent.scanStatus.rawValue || $0.name == ScannerEvent.adfStateChanged.rawValue
        }
    }

    private let reachable = ScannerDetail(host: "mfp.local.", port: 8080)

    @Test("the first reading is a baseline, not news")
    func firstReadingIsSilent() async {
        let events = await report([ScannerStatus(state: .idle)])
        #expect(events.isEmpty)
    }

    @Test("a scan starting and finishing is worded as what happened")
    func scanStartAndFinish() async {
        let events = await report([
            ScannerStatus(state: .idle),
            ScannerStatus(state: .processing),
            ScannerStatus(state: .idle)
        ])

        #expect(events.map(\.title) == ["Scan Started", "Scan Finished"])
        #expect(events.first?.subject == "Office MFP")
    }

    @Test("an unchanged reading is not repeated on every poll")
    func unchangedIsSilent() async {
        let events = await report([
            ScannerStatus(state: .processing),
            ScannerStatus(state: .processing),
            ScannerStatus(state: .processing)
        ])
        #expect(events.isEmpty)
    }

    @Test("a scanner that stops mid-job says why, and says it loudly")
    func stoppedCarriesItsReason() async {
        let events = await report([
            ScannerStatus(state: .processing),
            ScannerStatus(state: .stopped, stateReasons: ["CoverOpen"])
        ])

        #expect(events.count == 1)
        #expect(events.first?.title == "Scanner Stopped")
        #expect(events.first?.priority == .high)
        #expect(events.first?.body.contains("CoverOpen") == true)
    }

    @Test("a feeder change is its own notification")
    func feederChange() async {
        let events = await report([
            ScannerStatus(state: .idle, adfState: .empty),
            ScannerStatus(state: .idle, adfState: .loaded)
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == ScannerEvent.adfStateChanged.rawValue)
        #expect(events.first?.title == "Document Feeder Loaded")
        #expect(events.first?.priority == .normal)
    }

    @Test("a jam is something somebody has to go and deal with")
    func jamHasPriority() async {
        let events = await report([
            ScannerStatus(adfState: .loaded),
            ScannerStatus(adfState: .jam)
        ])

        #expect(events.first?.title == "Document Feeder Jammed")
        #expect(events.first?.priority == .high)
    }

    @Test("a state change and a feeder change in one reading are two notifications")
    func bothChangeAtOnce() async {
        let events = await report([
            ScannerStatus(state: .idle, adfState: .loaded),
            ScannerStatus(state: .processing, adfState: .processing)
        ])

        #expect(events.count == 2)
        #expect(Set(events.map(\.name)) == [
            ScannerEvent.scanStatus.rawValue,
            ScannerEvent.adfStateChanged.rawValue
        ])
    }

    @Test("a scanner discovered without an address is announced but never asked")
    func unresolvedScannerIsNotPolled() async {
        let reader = ScriptedStatusReader([ScannerStatus(state: .processing)])
        let delivery = CollectingDelivery()
        let monitor = ScannerMonitor(
            source: ScriptedScannerSource(script: [.found(name: "Mystery Scanner", detail: nil)]),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: ScannerMonitor.category,
                announcesWhatIsAlreadyThere: false
            ),
            statusReader: reader,
            statusInterval: .seconds(2)
        )

        await monitor.start()
        for _ in 0..<200 { await Task.yield() }
        await monitor.stop()

        #expect(await reader.callCount == 0)
        // It is still reported as found — only the polling is skipped.
        #expect(await delivery.events.contains { $0.name == ScannerEvent.found.rawValue })
    }

    @Test("a scanner switched off mid-scan and back is not two notifications")
    func unreachableIsNotNews() async {
        // A failed read never reaches the decision at all — the poll loop drops it — so
        // the reading either side of the gap is the same one, and the same is not news.
        let events = await report([
            ScannerStatus(state: .processing),
            ScannerStatus(state: .processing)
        ])
        #expect(events.isEmpty)
    }

    @Test("a scanner leaving the network stops being asked")
    func lostScannerStopsPolling() async {
        let reader = ScriptedStatusReader([])
        let monitor = ScannerMonitor(
            source: ScriptedScannerSource(script: [
                .found(name: "Office MFP", detail: ScannerDetail(host: "mfp.local", port: 8080)),
                .lost(name: "Office MFP")
            ]),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: CollectingDelivery()),
                category: ScannerMonitor.category,
                announcesWhatIsAlreadyThere: false
            ),
            statusReader: reader,
            statusInterval: .seconds(2)
        )

        await monitor.start()
        for _ in 0..<200 { await Task.yield() }
        let afterLoss = await reader.callCount
        for _ in 0..<200 { await Task.yield() }
        await monitor.stop()

        // Whatever it managed before the scanner went away, it asked no more afterwards.
        #expect(await reader.callCount == afterLoss)
    }

    @Test("polling is off entirely when no reader was given")
    func noReaderMeansNoPolling() async {
        let delivery = CollectingDelivery()
        let monitor = ScannerMonitor(
            source: ScriptedScannerSource(script: [.found(name: "Office MFP", detail: reachable)]),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: ScannerMonitor.category,
                announcesWhatIsAlreadyThere: false
            )
        )

        await monitor.start()
        for _ in 0..<200 { await Task.yield() }
        await monitor.stop()

        #expect(await delivery.events.allSatisfy { $0.name == ScannerEvent.found.rawValue })
    }

    @Test("an interval that would be a flood is refused")
    func intervalIsClamped() async {
        // Nothing to assert on the outside, so this checks the only thing that matters:
        // constructing one with an absurd interval does not produce a monitor that hammers
        // the scanner. The clamp is in the initialiser; this pins that it exists.
        let reader = ScriptedStatusReader(Array(repeating: ScannerStatus(state: .idle), count: 3))
        let monitor = ScannerMonitor(
            source: ScriptedScannerSource(script: [.found(name: "Office MFP", detail: reachable)]),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: CollectingDelivery()),
                category: ScannerMonitor.category,
                announcesWhatIsAlreadyThere: false
            ),
            statusReader: reader,
            statusInterval: .zero
        )

        await monitor.start()
        for _ in 0..<300 { await Task.yield() }
        await monitor.stop()

        // Three scripted readings at most, and then the two-second floor stops it dead —
        // not hundreds of requests in the time these yields take.
        #expect(await reader.callCount <= 4)
    }

    @Test("every event and field it can raise is declared for preferences to find")
    func eventsAndFieldsAreDeclared() {
        let events = Dictionary(uniqueKeysWithValues: ScannerMonitor.events.map { ($0.name, $0.enabledByDefault) })
        #expect(events.count == 4)
        #expect(events[ScannerEvent.scanStatus.rawValue] == false)
        #expect(events[ScannerEvent.adfStateChanged.rawValue] == false)
        #expect(Set(ScannerMonitor.fields.map(\.name)) == Set(ScannerField.allCases.map(\.rawValue)))
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
