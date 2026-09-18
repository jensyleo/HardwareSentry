import Foundation
import SentryTestSupport
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
            context: MonitorContext(
                dispatcher: dispatcher,
                category: DisplayMonitor.category,
                // These exercise what happens when something *changes*, so the startup
                // sweep is switched off: with it on, the first snapshot is announced and
                // every count below would be measuring the sweep as well as the change.
                announcesWhatIsAlreadyThere: false
            )
        )

        await monitor.start()
        await settle()
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
        // The name leads; the declared details follow it.
        #expect(events.first?.body.hasPrefix("LG UltraFine") == true)
    }

    @Test("the details a display can report show up when it connects")
    func connectCarriesDeclaredDetails() async {
        // Baselined against a different display rather than an empty list: an empty list
        // now means "ask again", the way the framework means it.
        let events = await run([
            .snapshot([display(id: "0", name: "Built-in")]),
            .snapshot([
                display(id: "0", name: "Built-in"),
                display(id: "1", name: "Studio Display", width: 5120, height: 2880, hz: 60, role: .main)
            ])
        ])

        let body = events.first?.body ?? ""
        #expect(body.contains("Resolution:\t5120×2880"))
        #expect(body.contains("Refresh rate:\t60 Hz"))
        #expect(body.contains("Role:\tMain display"))
        // A display the right way up has nothing to say about rotation.
        #expect(!body.contains("Rotation:"))
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
            "DisplayColorProfileChanged": false,
            // Off, and it should stay off for anybody who does not want it: it reads
            // undocumented kernel log text, works only on Apple Silicon, and has to poll.
            "DisplayLinkDetected": false
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

@Suite("DisplayMonitor startup sweep")
struct DisplayMonitorStartupTests {
    private func run(_ script: [DisplaySourceEvent], announcing: Bool, expecting: Int) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let monitor = DisplayMonitor(
            source: ScriptedDisplaySource(script: script),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: DisplayMonitor.category,
                announcesWhatIsAlreadyThere: announcing
            )
        )
        await monitor.start()
        await waitUntil { await delivery.events.count >= expecting }
        await monitor.stop()
        return await delivery.events
    }

    private static let attached = [
        display(id: "1", name: "Built-in Display", width: 1470, height: 956),
        display(id: "2", name: "Studio Display", width: 2560, height: 1440, role: .extended)
    ]

    @Test("what is already plugged in is announced when the application starts")
    func existingDisplaysAreAnnounced() async {
        // Launching and being told nothing at all about the machine you are sitting at is
        // the thing this exists to fix.
        let events = await run([.snapshot(Self.attached)], announcing: true, expecting: 2)

        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.name == DisplayEvent.connected.rawValue })
        #expect(Set(events.map(\.subject)) == ["1", "2"])
    }

    @Test("the sweep is a baseline too, so nothing is announced twice")
    func sweepDoesNotRepeatOnTheNextSnapshot() async {
        let events = await run(
            [.snapshot(Self.attached), .snapshot(Self.attached)],
            announcing: true,
            expecting: 2
        )
        #expect(events.count == 2)
    }

    @Test("switched off, the first snapshot is remembered in silence as before")
    func silentBaselineStillAvailable() async {
        let events = await run([.snapshot(Self.attached)], announcing: false, expecting: 0)
        #expect(events.isEmpty)
    }
}

// MARK: - What a display says about itself

private struct ChosenFields: NotificationPreferences {
    let allowed: Set<String>
    func isFieldEnabled(_ name: String, in category: NotificationCategory) async -> Bool {
        allowed.contains(name)
    }
}

@Suite("DisplayDetail")
struct DisplayDetailTests {
    private let studioDisplay = DisplayDetail(
        widthMillimetres: 597,
        heightMillimetres: 336,
        colorSpaceName: "Display P3",
        vendorNumber: 0x0610,
        modelNumber: 0xA038,
        serialNumber: 0,
        backingScaleFactor: 2,
        pointWidth: 2560,
        pointHeight: 1440,
        coversDisplayP3: true
    )

    @Test("physical size is given on the diagonal, the way displays are sold")
    func physicalSizeIsDiagonalInches() {
        #expect(studioDisplay.physicalSizeNote == "27.0-inch (597 × 336 mm)")
    }

    @Test("a display that does not report a size is not called 0-inch")
    func zeroSizeIsSilent() {
        #expect(DisplayDetail(widthMillimetres: 0, heightMillimetres: 0).physicalSizeNote == nil)
        #expect(DisplayDetail().physicalSizeNote == nil)
    }

    @Test("density is worked out from the pixels and the physical size")
    func densityIsComputed() {
        #expect(studioDisplay.densityNote(pixelWidth: 5120, pixelHeight: 2880) == "218 ppi")
    }

    @Test("density needs both halves of the sum")
    func densityNeedsPixelsAndSize() {
        #expect(studioDisplay.densityNote(pixelWidth: 0, pixelHeight: 0) == nil)
        #expect(DisplayDetail().densityNote(pixelWidth: 5120, pixelHeight: 2880) == nil)
    }

    @Test("a serial nobody published is not reported as serial zero")
    func zeroSerialIsOmitted() {
        #expect(studioDisplay.identityNote == "Vendor 0x0610 · Model 0xA038")
        let withSerial = DisplayDetail(vendorNumber: 0x0610, serialNumber: 12_345)
        #expect(withSerial.identityNote == "Vendor 0x0610 · Serial 12345")
        #expect(DisplayDetail().identityNote == nil)
    }

    @Test("a fixed-rate panel is not dressed up as variable")
    func fixedRefreshIsNotARange() {
        #expect(DisplayDetail(minimumRefreshHz: 60, maximumRefreshHz: 60).refreshRangeNote == nil)
        #expect(DisplayDetail(minimumRefreshHz: 0, maximumRefreshHz: 120).refreshRangeNote == nil)
        #expect(DisplayDetail(minimumRefreshHz: 47.95, maximumRefreshHz: 120).refreshRangeNote == "48–120 Hz variable")
    }

    @Test("no dynamic range headroom is left unsaid rather than reported as 1×")
    func edrHeadroom() {
        #expect(DisplayDetail(currentEDRHeadroom: 1.0, potentialEDRHeadroom: 1.0).edrNote == nil)
        #expect(DisplayDetail(currentEDRHeadroom: 4.0, potentialEDRHeadroom: 4.0).edrNote == "4.0× brighter than white")
        #expect(DisplayDetail(currentEDRHeadroom: 1.6, potentialEDRHeadroom: 16.0).edrNote == "1.6× brighter than white (up to 16.0×)")
    }

    @Test("a panel that could do more than it is allowed to says so")
    func edrPotentialWithoutCurrent() {
        #expect(DisplayDetail(currentEDRHeadroom: 1.0, potentialEDRHeadroom: 16.0).edrNote == "None right now, up to 16.0× available")
    }

    @Test("HiDPI, scaled and plain modes are told apart")
    func scalingNote() {
        // 5K panel driven at its native 2× mode: points times two equals pixels.
        #expect(studioDisplay.scalingNote(pixelWidth: 5120, pixelHeight: 2880) == "2× (HiDPI)")

        // The same panel at a scaled "looks like 3008×1692" mode: the desktop is rendered
        // at one size and resampled to the panel's own.
        let scaled = DisplayDetail(backingScaleFactor: 2, pointWidth: 3008, pointHeight: 1692)
        #expect(scaled.scalingNote(pixelWidth: 5120, pixelHeight: 2880) == "Scaled — 3008 × 1692 desktop on 5120 × 2880 pixels")

        let plain = DisplayDetail(backingScaleFactor: 1, pointWidth: 1920, pointHeight: 1080)
        #expect(plain.scalingNote(pixelWidth: 1920, pixelHeight: 1080) == "1× (no scaling)")
    }

    @Test("the present-only lines say nothing about the ordinary case")
    func presentOnlyLines() {
        let plain = DisplayDetail()
        #expect(plain.builtInNote == nil)
        #expect(plain.notchNote == nil)
        #expect(plain.stereoNote == nil)
        #expect(plain.displayP3Note == nil)
        #expect(plain.mirrorNote == nil)

        let laptop = DisplayDetail(isBuiltIn: true, hasNotch: true, coversDisplayP3: true)
        #expect(laptop.builtInNote == "Yes")
        #expect(laptop.notchNote?.hasPrefix("Yes") == true)
        #expect(laptop.displayP3Note == "Covers Display P3")
    }
}

@Suite("DisplayMonitor · fields")
struct DisplayFieldTests {
    private func run(_ script: [DisplaySourceEvent], allowing allowed: Set<String>) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = DisplayMonitor(
            source: ScriptedDisplaySource(script: script),
            context: MonitorContext(
                dispatcher: dispatcher,
                category: DisplayMonitor.category,
                preferences: ChosenFields(allowed: allowed),
                announcesWhatIsAlreadyThere: false
            )
        )
        await monitor.start()
        await settle()
        await monitor.stop()
        return await delivery.events
    }

    private func snapshot(_ hz: Double, width: Int = 1920) -> DisplaySourceEvent {
        .snapshot([DisplaySnapshot(
            id: "1", name: "Studio Display", width: width, height: 1080,
            refreshHz: hz, rotation: 0, role: .main, isAsleep: false
        )])
    }

    @Test("a mode change reports only the parts that are switched on")
    func modeChangeRespectsFields() async {
        let events = await run(
            [snapshot(60), snapshot(120, width: 2560)],
            allowing: [DisplayField.refreshRate.rawValue]
        )

        #expect(events.count == 1)
        #expect(events.first?.body.contains("Refresh rate:\t60 Hz → 120 Hz") == true)
        // The resolution moved too, and was asked not to be mentioned.
        #expect(events.first?.body.contains("1920") == false)
    }

    @Test("a mode change with every part switched off says nothing at all")
    func modeChangeWithNoFieldsIsSilent() async {
        let events = await run([snapshot(60), snapshot(120, width: 2560)], allowing: [])
        #expect(events.isEmpty)
    }

    @Test("every field it can add is declared for preferences to find")
    func fieldsAreDeclared() {
        let declared = Set(DisplayMonitor.fields.map(\.name))
        #expect(declared == Set(DisplayField.allCases.map(\.rawValue)))
        #expect(DisplayMonitor.fields.count == 17)

        // The identifiers are off: they exist to tell two identical monitors apart, which
        // is a real need and a rare one.
        let byName = Dictionary(uniqueKeysWithValues: DisplayMonitor.fields.map { ($0.name, $0.shownByDefault) })
        #expect(byName[DisplayField.uuid.rawValue] == false)
        #expect(byName[DisplayField.identity.rawValue] == false)
        #expect(byName[DisplayField.resolution.rawValue] == true)
    }

    @Test("a display with nothing extra to say still announces itself")
    func detailIsOptional() async {
        let events = await run(
            [snapshot(60), .snapshot([
                DisplaySnapshot(id: "1", name: "Studio Display", width: 1920, height: 1080, refreshHz: 60, rotation: 0, role: .main, isAsleep: false),
                DisplaySnapshot(id: "2", name: "External Display", width: 3840, height: 2160, refreshHz: 60, rotation: 0, role: .extended, isAsleep: false)
            ])],
            allowing: Set(DisplayField.allCases.map(\.rawValue))
        )

        let connected = events.filter { $0.name == DisplayEvent.connected.rawValue }
        #expect(connected.count == 1)
        #expect(connected.first?.body == "External Display\nResolution:\t3840×2160\nRefresh rate:\t60 Hz\nRole:\tExtended")
    }
}
