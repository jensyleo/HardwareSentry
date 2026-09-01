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
        for _ in 0..<100 where await delivery.events.isEmpty { await Task.yield() }
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
        #expect(defaults == [ScannerField.model.rawValue, ScannerField.location.rawValue])

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
