import Foundation
import SentryTestSupport
import SignalCore
import SentryContract
import Testing
@testable import ThunderboltMonitor

struct ScriptedThunderboltSource: ThunderboltDeviceSource {
    let script: [ThunderboltDeviceChange]

    func changes() -> AsyncStream<ThunderboltDeviceChange> {
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

@Suite("ThunderboltMonitor")
struct ThunderboltMonitorTests {
    private func run(_ changes: [ThunderboltDeviceChange], expecting: Int) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = ThunderboltMonitor(
            source: ScriptedThunderboltSource(script: changes),
            context: MonitorContext(dispatcher: dispatcher, category: ThunderboltMonitor.category)
        )

        await monitor.start()
        await waitUntil { await delivery.events.count >= expecting }
        await monitor.stop()
        return await delivery.events
    }

    @Test("an ordinary device only raises the generic pair")
    func ordinaryDeviceIsGeneric() async {
        let events = await run([.attached(ThunderboltDevice(name: "CalDigit Dock", baseClass: 0x06))], expecting: 1)

        #expect(events.count == 1)
        // A dock is a dock: its own row, so it can be silenced and re-iconed apart from
        // an external disk on the same Mac.
        #expect(events.first?.name == "ThunderboltConnectedDock")
        #expect(events.first?.subject == "CalDigit Dock")
    }

    @Test("a Display Controller also raises the eGPU pair, additively")
    func displayControllerAlsoRaisesEGPU() async {
        let events = await run([.attached(ThunderboltDevice(name: "Razer Core X", baseClass: 0x03))], expecting: 2)

        #expect(events.count == 2)
        #expect(events[0].name == "ThunderboltConnectedEGPU")
        #expect(events[1].name == "ThunderboltEGPUConnected")
        #expect(events[1].subject == "eGPU-Razer Core X")
    }

    @Test("disconnecting an eGPU still fires the eGPU pair, from the class cached at connect")
    func disconnectStillKnowsItWasAnEGPU() async {
        let events = await run([
            .attached(ThunderboltDevice(name: "Razer Core X", baseClass: 0x03)),
            .detached(name: "Razer Core X")
        ], expecting: 4)

        #expect(events.count == 4)
        #expect(events[2].name == "ThunderboltDisconnected")
        #expect(events[3].name == "ThunderboltEGPUDisconnected")
    }

    @Test("a departure with no cached class is only the generic disconnect")
    func departureWithNoBaselineIsGenericOnly() async {
        let events = await run([.detached(name: "Unknown Device")], expecting: 1)

        #expect(events.count == 1)
        #expect(events.first?.name == "ThunderboltDisconnected")
    }

    @Test("every event it can raise is declared for preferences to find, with the right defaults")
    func eventsAreDeclaredWithDefaults() {
        let byName = Dictionary(uniqueKeysWithValues: ThunderboltMonitor.events.map { ($0.name, $0.enabledByDefault) })

        // One row per PCI class, then the two generics and the two eGPU notices.
        #expect(Set(byName.keys) == Set(ThunderboltEvent.allCases.map(\.rawValue)))
        #expect(byName["ThunderboltConnected"] == true)
        #expect(byName["ThunderboltDisconnected"] == true)
        #expect(byName["ThunderboltEGPUConnected"] == false)
        #expect(byName["ThunderboltEGPUDisconnected"] == false)
        #expect(ThunderboltDeviceKind.allCases.allSatisfy { byName[$0.connectedEvent.rawValue] == true })
    }

    @Test("the optional details a monitor declares show up in the message")
    func declaredFieldsAppearInBody() async {
        let events = await run([.attached(ThunderboltDevice(
            name: "CalDigit Dock", baseClass: 0x06, vendorID: 0x0FD9, deviceID: 0x1234
        ))], expecting: 1)

        let body = events.first?.body ?? ""
        #expect(body.contains("CalDigit Dock"))
        #expect(body.contains("Type:\tBridge / Dock"))
        #expect(body.contains("VID:PID:\t0FD9:1234"))
        #expect(body.contains("Vendor:\tCalDigit"))
    }

    @Test("a detail the monitor cannot fill in is left out, not shown blank")
    func unknownDetailsAreOmitted() async {
        // An unrecognised vendor still shows its hex ID; it just has no name to give.
        let events = await run([.attached(ThunderboltDevice(
            name: "Mystery Box", baseClass: 0xFF, vendorID: 0xABCD, deviceID: 0x0001
        ))], expecting: 1)

        let body = events.first?.body ?? ""
        #expect(body.contains("VID:PID:\tABCD:0001"))
        #expect(!body.contains("Type:"))
        #expect(!body.contains("Vendor:"))
    }

    @Test("every optional detail it can add is declared for preferences to find")
    func fieldsAreDeclared() {
        #expect(Set(ThunderboltMonitor.fields.map(\.name)) == ["Type", "VIDPID", "Vendor"])
    }

    @Test("stopping twice is harmless")
    func stoppingTwiceIsHarmless() async {
        let monitor = ThunderboltMonitor(
            source: ScriptedThunderboltSource(script: []),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: CollectingDelivery()),
                category: ThunderboltMonitor.category
            )
        )

        await monitor.start()
        await monitor.stop()
        await monitor.stop()
    }
}

@Suite("Thunderbolt icon artwork")
struct ThunderboltIconTests {
    @Test("a device whose PCI class says nothing falls back to the plain Thunderbolt glyph")
    func unknownClassUsesTheGenericIcon() {
        #expect(ThunderboltDevice(name: "Thing", baseClass: 0x99).iconBaseName == nil)
    }

    @Test("every recognised class has its own artwork, distinct from the generic one")
    func everyClassHasItsOwnArtwork() throws {
        let generic = try #require(Bundle.module.url(forResource: "Thunderbolt-On", withExtension: "png"))
        let genericBytes = try Data(contentsOf: generic)

        var seen = Set<String>()
        for code in UInt8.min...UInt8.max {
            guard let base = ThunderboltDevice(name: "Thing", baseClass: code).iconBaseName else { continue }
            guard seen.insert(base).inserted else { continue }

            let url = try #require(
                Bundle.module.url(forResource: base, withExtension: "png"),
                "missing artwork: \(base)"
            )
            #expect(try Data(contentsOf: url) != genericBytes, "\(base) is the generic icon")
            #expect(
                Bundle.module.url(forResource: "\(base)-Disconnected", withExtension: "png") != nil,
                "missing artwork: \(base)-Disconnected"
            )
        }
        #expect(!seen.isEmpty)
    }

    @Test("the plain glyphs the fallback needs are shipped")
    func genericArtworkExists() {
        #expect(Bundle.module.url(forResource: "Thunderbolt-On", withExtension: "png") != nil)
        #expect(Bundle.module.url(forResource: "Thunderbolt-Off", withExtension: "png") != nil)
    }
}
