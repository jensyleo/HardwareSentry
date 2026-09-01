import Foundation
import SignalCore
import SentryContract
import Testing
@testable import BluetoothMonitor

struct ScriptedBluetoothSource: BluetoothSource {
    let script: [BluetoothSourceEvent]

    func changes() -> AsyncStream<BluetoothSourceEvent> {
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

@Suite("BluetoothMonitor")
struct BluetoothMonitorTests {
    private func run(_ script: [BluetoothSourceEvent]) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = BluetoothMonitor(
            source: ScriptedBluetoothSource(script: script),
            context: MonitorContext(dispatcher: dispatcher, category: BluetoothMonitor.category)
        )

        await monitor.start()
        for _ in 0..<100 { await Task.yield() }
        await monitor.stop()
        return await delivery.events
    }

    @Test("a classic device connecting and disconnecting is announced")
    func classicConnectDisconnect() async {
        let events = await run([
            .classicConnected(name: "Magic Keyboard", kind: .keyboard),
            .classicDisconnected(name: "Magic Keyboard")
        ])

        #expect(events.count == 2)
        #expect(events[0].name == "BluetoothConnected")
        #expect(events[0].subject == "Magic Keyboard")
        #expect(events[1].name == "BluetoothDisconnected")
    }

    @Test("the first radio power reading is a silent baseline")
    func radioPowerBaselineIsSilent() async {
        let events = await run([.radioPower(isOn: true)])
        #expect(events.isEmpty)
    }

    @Test("a real radio power transition fires the right event")
    func radioPowerTransitionFires() async {
        let events = await run([.radioPower(isOn: false), .radioPower(isOn: true)])

        #expect(events.count == 1)
        #expect(events.first?.name == "BluetoothRadioOn")
        #expect(events.first?.title == "Bluetooth Turned On")
    }

    @Test("subsystem trouble is announced with its own title per state")
    func subsystemTroubleIsAnnounced() async {
        let events = await run([.subsystemState(.unauthorized)])

        #expect(events.count == 1)
        #expect(events.first?.name == "BluetoothSubsystemStateChanged")
        #expect(events.first?.body == "This app is no longer authorized to use Bluetooth")
    }

    @Test("the first paired snapshot is a silent baseline")
    func pairedBaselineIsSilent() async {
        let events = await run([.pairedSnapshot(["AA:BB": "AirPods"])])
        #expect(events.isEmpty)
    }

    @Test("a newly-paired device is announced, and losing one is announced separately")
    func pairedAndUnpaired() async {
        let events = await run([
            .pairedSnapshot(["AA:BB": "AirPods"]),
            .pairedSnapshot(["AA:BB": "AirPods", "CC:DD": "Magic Mouse"]),
            .pairedSnapshot(["CC:DD": "Magic Mouse"])
        ])

        #expect(events.count == 2)
        #expect(events[0].name == "BluetoothPaired")
        #expect(events[0].subject == "CC:DD")
        #expect(events[1].name == "BluetoothUnpaired")
        #expect(events[1].subject == "AA:BB")
    }

    @Test("every event it can raise is declared for preferences to find, with the right defaults")
    func eventsAreDeclaredWithDefaults() {
        let byName = Dictionary(uniqueKeysWithValues: BluetoothMonitor.events.map { ($0.name, $0.enabledByDefault) })

        #expect(byName == [
            "BluetoothConnected": true,
            "BluetoothDisconnected": true,
            "BluetoothRadioOn": false,
            "BluetoothRadioOff": false,
            "BluetoothSubsystemStateChanged": false,
            "BluetoothPaired": false,
            "BluetoothUnpaired": false
        ])
    }

    @Test("stopping twice is harmless")
    func stoppingTwiceIsHarmless() async {
        let monitor = BluetoothMonitor(
            source: ScriptedBluetoothSource(script: []),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: CollectingDelivery()),
                category: BluetoothMonitor.category
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

@Suite("BluetoothDetail")
struct BluetoothDetailTests {
    @Test("signal strength is said in dBm and in words, because most people do not read dBm")
    func rssiIsSpelledOut() {
        #expect(BluetoothDetail(rssi: -45).rssiNote == "-45 dBm (excellent)")
        #expect(BluetoothDetail(rssi: -65).rssiNote == "-65 dBm (good)")
        #expect(BluetoothDetail(rssi: -75).rssiNote == "-75 dBm (fair)")
        #expect(BluetoothDetail(rssi: -95).rssiNote == "-95 dBm (weak)")
    }

    @Test("a controller with no reading says nothing rather than a perfect signal")
    func zeroRSSIIsNotAPerfectSignal() {
        // IOBluetooth reports 0 for "no reading", which read literally is the strongest
        // possible signal — the one value that must not be shown.
        #expect(BluetoothDetail(rssi: 0).rssiNote == nil)
        #expect(BluetoothDetail().rssiNote == nil)
    }

    @Test("which side connected is said both ways, unlike the capability lines")
    func initiatorIsSaidBothWays() {
        // An accessory waking up on its own and this Mac deciding to connect are
        // different things; neither is the boring default.
        #expect(BluetoothDetail(isIncoming: true).initiatorNote == "The device")
        #expect(BluetoothDetail(isIncoming: false).initiatorNote == "This Mac")
    }

    @Test("a favourite is worth a line, not being a favourite is not")
    func favouriteIsPresentOnly() {
        #expect(BluetoothDetail(isFavorite: true).favoriteNote == "Yes")
        #expect(BluetoothDetail(isFavorite: false).favoriteNote == nil)
    }

    @Test("every device kind has words for it, not just artwork")
    func everyKindHasALabel() {
        for kind in BluetoothDeviceKind.allCases {
            #expect(!kind.label.isEmpty)
        }
    }
}

@Suite("BluetoothMonitor optional fields")
struct BluetoothMonitorFieldTests {
    private static let headphones = BluetoothDetail(
        kind: .headphones,
        address: "00-11-22-33-44-55",
        isPaired: true,
        rssi: -52,
        linkType: "ACL (data)",
        isIncoming: true,
        services: "Audio Sink, Handsfree",
        isFavorite: true,
        lastSeen: nil
    )

    private func body(_ event: BluetoothSourceEvent, allowing allowed: Set<String>) async -> String? {
        let delivery = CollectingDelivery()
        let monitor = BluetoothMonitor(
            source: ScriptedBluetoothSource(script: [event]),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: BluetoothMonitor.category,
                preferences: ChosenFields(allowed: allowed)
            )
        )
        await monitor.start()
        for _ in 0..<100 where await delivery.events.isEmpty { await Task.yield() }
        await monitor.stop()
        return await delivery.events.first?.body
    }

    @Test("out of the box the message says what kind of thing connected, and nothing more")
    func onlyTheKindIsOnByDefault() async {
        let defaults = Set(BluetoothMonitor.fields.filter(\.shownByDefault).map(\.name))
        #expect(defaults == [BluetoothField.kind.rawValue])

        let body = await body(
            .classicConnected(name: "WH-1000XM4", kind: .headphones, detail: Self.headphones),
            allowing: defaults
        )
        #expect(body == "WH-1000XM4\nType:\tHeadphones")
    }

    @Test("with everything switched on, the details read in the declared order")
    func fullDetailReadsInOrder() async {
        let body = await body(
            .classicConnected(name: "WH-1000XM4", kind: .headphones, detail: Self.headphones),
            allowing: Set(BluetoothField.allCases.map(\.rawValue))
        )

        #expect(body == """
        WH-1000XM4
        Type:\tHeadphones
        Address:\t00-11-22-33-44-55
        Paired:\tYes
        Signal:\t-52 dBm (excellent)
        Link:\tACL (data)
        Connected by:\tThe device
        Profiles:\tAudio Sink, Handsfree
        Favourite:\tYes
        """)
    }

    @Test("a device that answered nothing still produces a usable message")
    func noDetailIsFine() async {
        let body = await body(
            .classicConnected(name: "Some Device", kind: nil),
            allowing: Set(BluetoothField.allCases.map(\.rawValue))
        )
        #expect(body == "Some Device")
    }

    @Test("turning everything off leaves the device name, which is the point of the message")
    func nameSurvivesEverythingBeingOff() async {
        let body = await body(
            .classicConnected(name: "WH-1000XM4", kind: .headphones, detail: Self.headphones),
            allowing: []
        )
        #expect(body == "WH-1000XM4")
    }

    @Test("the disconnect message is left short on purpose")
    func disconnectStaysShort() async {
        // Everything in the detail describes a live connection — signal strength, link
        // type, which side connected. None of it means anything once the device is gone.
        let body = await body(
            .classicDisconnected(name: "WH-1000XM4"),
            allowing: Set(BluetoothField.allCases.map(\.rawValue))
        )
        #expect(body == "WH-1000XM4")
    }
}
