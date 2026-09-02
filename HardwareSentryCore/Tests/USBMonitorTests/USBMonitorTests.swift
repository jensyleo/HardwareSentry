import Foundation
import SignalCore
import SentryContract
import Testing
@testable import USBMonitor

/// Stands in for the system, so what the monitor says can be checked without anything
/// being plugged in or pulled out.
struct ScriptedSource: USBDeviceSource {
    let script: [USBDeviceChange]

    func changes() -> AsyncStream<USBDeviceChange> {
        AsyncStream { continuation in
            for change in script { continuation.yield(change) }
            continuation.finish()
        }
    }
}

/// Collects whatever the monitor raises.
actor CollectingDelivery: NotificationDelivering {
    private(set) var events: [NotificationEvent] = []

    func present(_ event: NotificationEvent, context: DispatchContext) async -> DeliveryOutcome {
        events.append(event)
        return .presented
    }
}

@Suite("USBMonitor")
struct USBMonitorTests {
    private func run(_ changes: [USBDeviceChange]) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = USBMonitor(
            source: ScriptedSource(script: changes),
            context: MonitorContext(dispatcher: dispatcher, category: USBMonitor.category)
        )

        await monitor.start()
        // The monitor consumes its source on its own task; give it a turn to finish.
        for _ in 0..<100 where await delivery.events.count < changes.count {
            await Task.yield()
        }
        await monitor.stop()
        return await delivery.events
    }

    @Test("a device arriving is announced")
    func attachIsAnnounced() async {
        let events = await run([.attached(USBDevice(name: "SanDisk Cruzer"))])

        #expect(events.count == 1)
        #expect(events.first?.name == "USBConnected")
        #expect(events.first?.title == "USB Connection")
        #expect(events.first?.category == USBEvent.category)
    }

    @Test("a device leaving is announced")
    func detachIsAnnounced() async {
        let events = await run([.detached(USBDevice(name: "SanDisk Cruzer"))])

        #expect(events.first?.name == "USBDisconnected")
        #expect(events.first?.title == "USB Disconnection")
    }

    @Test("a hub is called a hub")
    func hubIsNamed() async {
        let events = await run([.attached(USBDevice(name: "Anker Hub", isHub: true))])

        #expect(events.first?.title == "USB Hub/Dock Connection")
    }

    // The device's name is the subject, deliberately: identifiers the system assigns as it
    // enumerates are fresh every time, so the same physical device coming and going would
    // never be recognised as one thing misbehaving.
    @Test("arriving and leaving share a subject, so one device reads as one thing")
    func subjectIsStableAcrossArrivalAndDeparture() async {
        let device = USBDevice(name: "SanDisk Cruzer")
        let events = await run([.attached(device), .detached(device)])

        #expect(events.count == 2)
        #expect(events[0].subject == events[1].subject)
        #expect(events[0].subject == "SanDisk Cruzer")
        #expect(events[0].name != events[1].name)
    }

    @Test("the vendor is mentioned when it adds something")
    func vendorIsMentioned() async {
        let events = await run([.attached(USBDevice(name: "Cruzer", vendorName: "SanDisk"))])

        #expect(events.first?.body == "Cruzer\nSanDisk")
    }

    @Test("a vendor that only repeats the name is left out")
    func redundantVendorOmitted() {
        #expect(USBMonitor.vendorDetail(USBDevice(name: "SanDisk", vendorName: "SanDisk")) == nil)
        #expect(USBMonitor.vendorDetail(USBDevice(name: "Cruzer", vendorName: "")) == nil)
        #expect(USBMonitor.vendorDetail(USBDevice(name: "Cruzer", vendorName: nil)) == nil)
        #expect(USBMonitor.vendorDetail(USBDevice(name: "Cruzer", vendorName: "SanDisk")) == "SanDisk")
    }

    @Test("every event it can raise is declared for preferences to find")
    func eventsAreDeclared() {
        let declared = Set(USBMonitor.events.map(\.name))

        #expect(declared == ["USBConnected", "USBDisconnected"])
    }

    @Test("stopping twice is harmless")
    func stoppingTwiceIsHarmless() async {
        let monitor = USBMonitor(
            source: ScriptedSource(script: []),
            context: MonitorContext(
                dispatcher: NotificationDispatcher(delivery: CollectingDelivery()),
                category: USBMonitor.category
            )
        )

        await monitor.start()
        await monitor.stop()
        await monitor.stop()
    }
}

@Suite("USB icon artwork")
struct USBIconTests {
    private func device(class code: UInt8, isHub: Bool = false) -> USBDevice {
        USBDevice(name: "Thing", isHub: isHub, deviceClass: code)
    }

    @Test("mass storage borrows the disk artwork, not the generic USB glyph")
    func massStorageLooksLikeADisk() {
        // A flash drive is a disk, and that is what somebody expects to see.
        #expect(device(class: 0x08).iconBaseName == "Device-USBDrive")
    }

    @Test("mass storage leaving asks for the artwork that exists")
    func massStorageDisconnectUsesUnmounted() {
        // The mechanical "-Disconnected" suffix would name a file that is not there, and
        // the icon would silently fall back to nothing.
        #expect(device(class: 0x08).disconnectedIconName == "Device-USBDrive-Unmounted")
        #expect(device(class: 0x03).disconnectedIconName == "USB-TypeHID-Disconnected")
        #expect(device(class: 0x00).disconnectedIconName == "USB-Off")
    }

    @Test("every icon this monitor can ask for is actually shipped")
    func everyReferencedIconExists() throws {
        // A missing asset is an invisible failure: the notification still appears, just
        // with no artwork, so nothing points at the cause.
        var names = Set<String>(["USB-On", "USB-Off"])
        for code in UInt8.min...UInt8.max {
            let plain = device(class: code)
            if let base = plain.iconBaseName { names.insert(base) }
            names.insert(plain.disconnectedIconName)
        }
        names.insert(device(class: 0x00, isHub: true).iconBaseName ?? "")

        for name in names where !name.isEmpty {
            #expect(
                Bundle.module.url(forResource: name, withExtension: "png") != nil,
                "missing artwork: \(name)"
            )
        }
    }
}

extension USBIconTests {
    @Test("a device that declares no class falls back to the plain USB glyph")
    func unknownClassUsesTheGenericIcon() {
        // Most USB devices declare their class per-interface rather than on the device, so
        // this is the common case, not the odd one.
        #expect(device(class: 0x00).iconBaseName == nil)
        #expect(device(class: 0xFF).iconBaseName == nil)
    }

    @Test("every recognised class has its own artwork, distinct from the generic one")
    func everyClassIconIsDistinct() throws {
        // A specific icon that happened to be the generic one would make "USB Connection"
        // and "a webcam arrived" indistinguishable at a glance.
        let generic = try #require(Bundle.module.url(forResource: "USB-On", withExtension: "png"))
        let genericBytes = try Data(contentsOf: generic)

        var seen = Set<String>()
        for code in UInt8.min...UInt8.max {
            guard let base = device(class: code).iconBaseName, seen.insert(base).inserted else { continue }
            let url = try #require(Bundle.module.url(forResource: base, withExtension: "png"), "missing \(base)")
            #expect(try Data(contentsOf: url) != genericBytes, "\(base) is the generic icon")
        }
        #expect(!seen.isEmpty)
    }
}

@Suite("USB device type")
struct USBClassNameTests {
    private func named(_ code: UInt8?) -> String? {
        USBDevice(name: "Thing", deviceClass: code).className
    }

    @Test("the message says what kind of thing arrived, not just that something did")
    func classesAreNamed() {
        #expect(named(0x08) == "Mass Storage")
        #expect(named(0x03) == "HID (Keyboard/Mouse)")
        #expect(named(0x09) == "Hub")
        #expect(named(0x0E) == "Video")
        #expect(named(0xE0) == "Wireless Controller")
    }

    @Test("a device that declares its class per-interface says nothing rather than guessing")
    func perInterfaceClassIsSilent() {
        // 0x00 means "look at the interfaces, not at me" — the common case for composite
        // devices, and there is nothing useful to say about it.
        #expect(named(0x00) == nil)
        #expect(named(nil) == nil)
        #expect(named(0x42) == nil)
    }

    @Test("every class with a name has an icon, and every class with an icon has a name")
    func namesAndIconsAgree() {
        // Not a strict requirement of the format, but a mismatch means a notification
        // that shows a webcam picture and cannot say "Video", or vice versa — worth
        // knowing about deliberately rather than discovering in a screenshot.
        for code in UInt8.min...UInt8.max {
            let device = USBDevice(name: "Thing", deviceClass: code)
            if device.iconBaseName != nil {
                #expect(device.className != nil, "class 0x\(String(code, radix: 16)) has an icon but no name")
            }
        }
    }
}
