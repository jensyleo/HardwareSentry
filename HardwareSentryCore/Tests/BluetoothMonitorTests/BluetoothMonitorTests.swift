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
            "BluetoothUnpaired": false,
            "BluetoothSignalExcellent": false,
            "BluetoothSignalGood": false,
            "BluetoothSignalFair": false,
            "BluetoothSignalWeak": false,
            "BluetoothSignalNone": false
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
    @Test("signal strength is said in dBm and in bars, the way the original says it")
    func rssiIsSpelledOut() {
        #expect(BluetoothDetail(rssi: -45).rssiNote == "-45 dBm (4/4)")
        #expect(BluetoothDetail(rssi: -65).rssiNote == "-65 dBm (3/4)")
        #expect(BluetoothDetail(rssi: -75).rssiNote == "-75 dBm (1/4)")
        #expect(BluetoothDetail(rssi: -95).rssiNote == "-95 dBm (0/4)")
    }

    @Test("only 127 means no reading; zero is a real and rather good one")
    func zeroRSSIIsNotAPerfectSignal() {
        // IOBluetooth reports 0 for "no reading", which read literally is the strongest
        // possible signal — the one value that must not be shown.
        #expect(BluetoothDetail(rssi: 0).rssiNote == "0 dBm (4/4)")
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

    @Test("out of the box the message says what kind of thing connected, and how strong")
    func kindAndSignalAreOnByDefault() async {
        let defaults = Set(BluetoothMonitor.fields.filter(\.shownByDefault).map(\.name))
        // Three, as the original has them: what kind of thing it is, how strong the link
        // is, and how much battery is left.
        #expect(defaults == [
            BluetoothField.kind.rawValue,
            BluetoothField.signal.rawValue,
            BluetoothField.battery.rawValue
        ])

        let body = await body(
            .classicConnected(name: "WH-1000XM4", kind: .headphones, detail: Self.headphones),
            allowing: defaults
        )
        // The signal is on because it is the answer to "why does this keep cutting out",
        // and because the original has it on.
        #expect(body == "WH-1000XM4\nType:\tHeadphones\nSignal:\t-52 dBm (4/4)")
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
        Signal:\t-52 dBm (4/4)
        Link type:\tACL (data)
        Initiated by:\tThe device
        Services:\tAudio Sink, Handsfree
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

@Suite("Bluetooth icon artwork")
struct BluetoothIconTests {
    @Test("a device whose kind is unreadable falls back to the plain Bluetooth glyph")
    func unknownKindUsesTheGenericIcon() {
        // Class-of-Device values outside the table this app knows: the honest answer is
        // "a Bluetooth device", not a confident wrong picture.
        #expect(BluetoothDeviceKind.from(major: 0x1F, minor: 0x00) == nil)
        #expect(BluetoothDeviceKind.from(major: 0x05, minor: 0x00) == nil)
    }

    @Test("every kind has its own artwork, distinct from the generic one")
    func everyKindHasItsOwnArtwork() throws {
        // A specific icon that happened to be the generic icon would make "Bluetooth
        // Connection" and "Keyboard connected" indistinguishable at a glance.
        let generic = try #require(Bundle.module.url(forResource: "Bluetooth-On", withExtension: "png"))
        let genericBytes = try Data(contentsOf: generic)

        for kind in BluetoothDeviceKind.allCases {
            let connected = try #require(
                Bundle.module.url(forResource: kind.iconBaseName, withExtension: "png"),
                "missing artwork: \(kind.iconBaseName)"
            )
            #expect(try Data(contentsOf: connected) != genericBytes, "\(kind.iconBaseName) is the generic icon")

            #expect(
                Bundle.module.url(forResource: "\(kind.iconBaseName)-Disconnected", withExtension: "png") != nil,
                "missing artwork: \(kind.iconBaseName)-Disconnected"
            )
        }
    }

    @Test("the plain glyphs the fallback needs are shipped")
    func genericArtworkExists() {
        for name in ["Bluetooth-On", "Bluetooth-Off", "Bluetooth-Radio-On", "Bluetooth-Radio-Off"] {
            #expect(Bundle.module.url(forResource: name, withExtension: "png") != nil, "missing \(name)")
        }
    }
}

// MARK: - Signal strength, per device

@Suite("BluetoothSignalLevel")
struct BluetoothSignalLevelTests {
    @Test("the thresholds are the Wi-Fi ones, which is what the original uses")
    func thresholdsMatchWiFi() {
        #expect(BluetoothSignalLevel(rssi: -40) == .excellent)
        #expect(BluetoothSignalLevel(rssi: -55) == .excellent)
        #expect(BluetoothSignalLevel(rssi: -56) == .good)
        #expect(BluetoothSignalLevel(rssi: -65) == .good)
        #expect(BluetoothSignalLevel(rssi: -66) == .fair)
        #expect(BluetoothSignalLevel(rssi: -73) == .fair)
        #expect(BluetoothSignalLevel(rssi: -74) == .weak)
        #expect(BluetoothSignalLevel(rssi: -80) == .weak)
        #expect(BluetoothSignalLevel(rssi: -81) == .lost)
    }

    @Test("zero is a real reading here, unlike Wi-Fi")
    func zeroIsARealReading() {
        // The bug this fixes. Classic Bluetooth reports RSSI against its golden receive
        // range, so zero means "comfortably inside it" — which the original shows as
        // "0 dBm (4/4)". Suppressing it, as the Wi-Fi rule does, is why a Magic Keyboard
        // showed no signal line at all in this application.
        #expect(BluetoothSignalLevel(rssi: 0) == .excellent)
        #expect(BluetoothDetail(rssi: 0).rssiNote == "0 dBm (4/4)")
    }

    @Test("127 is the sentinel, and it is refused")
    func unavailableIsRefused() {
        #expect(BluetoothSignalLevel(rssi: 127) == nil)
        #expect(BluetoothDetail(rssi: 127).rssiNote == nil)
        #expect(BluetoothDetail().rssiNote == nil)
    }

    @Test("the note is worded as the original words it")
    func noteWording() {
        #expect(BluetoothDetail(rssi: -62).rssiNote == "-62 dBm (3/4)")
        #expect(BluetoothDetail(rssi: -90).rssiNote == "-90 dBm (0/4)")
    }

    @Test("each level has an event and an icon that exists")
    func everyLevelIsDeclared() {
        for level in BluetoothSignalLevel.allCases {
            let declared = BluetoothMonitor.events.first { $0.name == level.event.rawValue }
            #expect(declared != nil, "\(level) has no declared event")
            #expect(declared?.icon != .none, "\(level) has no icon")
            // Off by default, as in the original: an accessory's signal moves whenever it
            // is picked up.
            #expect(declared?.enabledByDefault == false)
        }
    }
}

@Suite("BluetoothSignalWatcher")
struct BluetoothSignalWatcherTests {
    private let mouse = "d0-c0-50-c3-25-7a"
    private let keyboard = "fc-a5-c8-0c-97-1b"

    @Test("the first reading for a device is a baseline, not news")
    func firstReadingIsSilent() {
        var watcher = BluetoothSignalWatcher(cooldown: 0)
        #expect(watcher.consider(address: mouse, name: "Magic Mouse", rssi: -50) == nil)
    }

    @Test("a level change is reported with the original's wording")
    func levelChangeIsReported() {
        var watcher = BluetoothSignalWatcher(cooldown: 0)
        watcher.consider(address: mouse, name: "Magic Mouse", rssi: -50)

        let change = watcher.consider(address: mouse, name: "Magic Mouse", rssi: -70)
        #expect(change?.level == .fair)
        #expect(change?.isImproving == false)
        #expect(change?.summary == "Signal ↓ degraded (2/4)")
        #expect(change?.name == "Magic Mouse")
    }

    @Test("drifting within one level says nothing")
    func sameLevelIsSilent() {
        var watcher = BluetoothSignalWatcher(cooldown: 0)
        watcher.consider(address: mouse, name: "Magic Mouse", rssi: -56)
        #expect(watcher.consider(address: mouse, name: "Magic Mouse", rssi: -64) == nil)
    }

    @Test("two devices are tracked apart")
    func devicesAreIndependent() {
        var watcher = BluetoothSignalWatcher(cooldown: 0)
        watcher.consider(address: mouse, name: "Magic Mouse", rssi: -50)
        watcher.consider(address: keyboard, name: "Magic Keyboard", rssi: -50)

        // The mouse moving is not the keyboard moving, and neither baseline is the other's.
        #expect(watcher.consider(address: mouse, name: "Magic Mouse", rssi: -78)?.level == .weak)
        #expect(watcher.consider(address: keyboard, name: "Magic Keyboard", rssi: -50) == nil)
    }

    @Test("the cooldown is per device, and delays news without swallowing it")
    func cooldownIsPerDevice() {
        var watcher = BluetoothSignalWatcher(cooldown: 15)
        let start = Date()
        watcher.consider(address: mouse, name: "Magic Mouse", rssi: -50, now: start)
        watcher.consider(address: keyboard, name: "Magic Keyboard", rssi: -50, now: start)

        #expect(watcher.consider(address: mouse, name: "Magic Mouse", rssi: -70, now: start) != nil)
        // The keyboard is not held back by the mouse having just spoken.
        #expect(watcher.consider(address: keyboard, name: "Magic Keyboard", rssi: -70, now: start) != nil)

        // And the mouse sliding further during its own cooldown is reported once it lifts,
        // measured against the level last announced rather than the one in between.
        #expect(watcher.consider(address: mouse, name: "Magic Mouse", rssi: -78, now: start.addingTimeInterval(5)) == nil)
        let resumed = watcher.consider(address: mouse, name: "Magic Mouse", rssi: -78, now: start.addingTimeInterval(16))
        #expect(resumed?.level == .weak)
    }

    @Test("a device that leaves is forgotten, so coming back baselines afresh")
    func forgettingOnDisconnect() {
        var watcher = BluetoothSignalWatcher(cooldown: 0)
        watcher.consider(address: mouse, name: "Magic Mouse", rssi: -50)
        watcher.keepOnly([])

        // Back in the room, weak: a baseline, not a collapse from excellent.
        #expect(watcher.consider(address: mouse, name: "Magic Mouse", rssi: -78) == nil)
    }

    @Test("an unavailable reading is not a level change")
    func unavailableIsNotAChange() {
        var watcher = BluetoothSignalWatcher(cooldown: 0)
        watcher.consider(address: mouse, name: "Magic Mouse", rssi: -50)
        #expect(watcher.consider(address: mouse, name: "Magic Mouse", rssi: 127) == nil)
    }
}

@Suite("BluetoothMonitor · signal notifications")
struct BluetoothSignalNotificationTests {
    private func run(_ snapshots: [[String: BluetoothSignalReading]]) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let monitor = BluetoothMonitor(
            source: ScriptedBluetoothSource(script: snapshots.map { .signalSnapshot($0) }),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: delivery),
                category: BluetoothMonitor.category,
                announcesWhatIsAlreadyThere: false
            ),
            signalCooldown: 0
        )
        await monitor.start()
        for _ in 0..<200 { await Task.yield() }
        await monitor.stop()
        return await delivery.events.filter { $0.name.hasPrefix("BluetoothSignal") }
    }

    @Test("the event raised is the level it landed on, and the subject is the device")
    func eventFollowsTheLevel() async {
        let events = await run([
            ["aa": BluetoothSignalReading(name: "Magic Mouse", rssi: -50)],
            ["aa": BluetoothSignalReading(name: "Magic Mouse", rssi: -70)]
        ])

        #expect(events.count == 1)
        #expect(events.first?.name == BluetoothEvent.signalFair.rawValue)
        #expect(events.first?.subject == "aa")
        #expect(events.first?.title == "Bluetooth Signal Changed")
        #expect(events.first?.body == "Magic Mouse\nSignal ↓ degraded (2/4)")
    }

    @Test("two accessories moving at once are two notifications, not one flapping thing")
    func perDeviceNotifications() async {
        let events = await run([
            [
                "aa": BluetoothSignalReading(name: "Magic Mouse", rssi: -50),
                "bb": BluetoothSignalReading(name: "Magic Keyboard", rssi: -50)
            ],
            [
                "aa": BluetoothSignalReading(name: "Magic Mouse", rssi: -70),
                "bb": BluetoothSignalReading(name: "Magic Keyboard", rssi: -78)
            ]
        ])

        #expect(events.count == 2)
        #expect(Set(events.compactMap(\.subject)) == ["aa", "bb"])
    }

    @Test("a device disappearing from the snapshot is not reported as a signal change")
    func vanishingIsSilent() async {
        let events = await run([
            ["aa": BluetoothSignalReading(name: "Magic Mouse", rssi: -50)],
            [:],
            ["aa": BluetoothSignalReading(name: "Magic Mouse", rssi: -78)]
        ])
        #expect(events.isEmpty)
    }
}

@Suite("BluetoothDetail · the seven fields the original had and this did not")
struct BluetoothExtraFieldTests {
    @Test("service class bits are read as the categories the device claims")
    func serviceClasses() {
        // A headset claiming Audio and Telephony is saying it can carry a call as well
        // as music — its own claim, rather than a guess from its name.
        let headset: UInt32 = (1 << 21) | (1 << 22)
        #expect(BluetoothDetail.describeServiceClasses(headset) == "Audio, Telephony")

        let keyboard: UInt32 = 1 << 23
        #expect(BluetoothDetail.describeServiceClasses(keyboard) == "Information")

        // A device that claims nothing gets no line rather than an empty one.
        #expect(BluetoothDetail.describeServiceClasses(0) == nil)
        // A real keyboard's Class of Device. Bit 13 is set on it — "limited discoverable
        // mode" — and is deliberately not reported: it describes how the device
        // advertises itself, not anything it can do, so it would put a line nobody can
        // act on into most notifications.
        #expect(BluetoothDetail.describeServiceClasses(0x2540) == nil)
    }

    @Test("hands-free features are read from the profile's own bitmask")
    func handsFreeFeatures() {
        let airpods = (1 << 2) | (1 << 8)   // voice recognition, wideband speech
        #expect(BluetoothDetail.describeHandsFreeFeatures(airpods) == "Voice recognition, Wideband speech")
        #expect(BluetoothDetail.describeHandsFreeFeatures(0) == nil)
    }

    @Test("the identity line says which registry the vendor number belongs to")
    func identityNote() {
        // Without the source the number is unlookupable: the Bluetooth SIG and the USB-IF
        // number vendors separately, so the same figure is two different companies.
        let apple = BluetoothDetail(
            vendorID: 0x004C, productID: 0x0269,
            productVersion: "1.2.3", vendorIDSource: "Bluetooth SIG"
        )
        #expect(apple.identityNote == "VID 0x004C / PID 0x0269 v1.2.3 (Bluetooth SIG)")

        // A device that published only half of it says nothing rather than half a line.
        #expect(BluetoothDetail(vendorID: 0x004C).identityNote == nil)
        #expect(BluetoothDetail().identityNote == nil)
    }

    @Test("the two radio numbers are one line, since neither means much alone")
    func linkDiagnostics() {
        #expect(BluetoothDetail(linkQuality: 200, transmitPower: 4).linkDiagnosticsNote == "Quality 200/255 · Tx 4 dBm")
        #expect(BluetoothDetail(linkQuality: 200).linkDiagnosticsNote == "Quality 200/255")
        #expect(BluetoothDetail().linkDiagnosticsNote == nil)
    }

    @Test("a battery level is shown as a percentage, and absent when nothing published one")
    func batteryNote() {
        #expect(BluetoothDetail(batteryPercent: 27).batteryNote == "27%")
        #expect(BluetoothDetail().batteryNote == nil)
    }

    @Test("addresses are matched whatever punctuation they were written with")
    func addressNormalisation() {
        // The registry writes one style and IOBluetooth another, and a lookup that missed
        // on a hyphen would report no battery for a device that publishes one.
        #expect(BluetoothAccessoryBattery.normalise("d0-c0-50-c3-25-7a") == "d0c050c3257a")
        #expect(BluetoothAccessoryBattery.normalise("D0:C0:50:C3:25:7A") == "d0c050c3257a")
        #expect(BluetoothAccessoryBattery.normalise(" fc-a5-c8-0c-97-1b ") == "fca5c80c971b")
    }

    @Test("every field it can add is declared for preferences to find")
    func fieldsAreDeclared() {
        #expect(Set(BluetoothMonitor.fields.map(\.name)) == Set(BluetoothField.allCases.map(\.rawValue)))
        // The original's fifteen: this now offers the same set, with favourite and last
        // used split into two where the original keeps them in one key.
        #expect(BluetoothField.allCases.count == 16)
    }
}
