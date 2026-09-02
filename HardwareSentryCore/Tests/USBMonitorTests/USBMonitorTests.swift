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

        #expect(events.first?.body == "Cruzer\nManufacturer:\tSanDisk")
    }

    @Test("a manufacturer line that only repeats the name is left out")
    func redundantManufacturerOmitted() {
        #expect(USBMonitor.manufacturerDetail(USBDevice(name: "SanDisk", vendorName: "SanDisk")) == nil)
        #expect(USBMonitor.manufacturerDetail(USBDevice(name: "Cruzer", vendorName: "")) == nil)
        #expect(USBMonitor.manufacturerDetail(USBDevice(name: "Cruzer", vendorName: nil)) == nil)
        #expect(USBMonitor.manufacturerDetail(USBDevice(name: "Cruzer", vendorName: "SanDisk")) == "SanDisk")
    }

    @Test("the manufacturer and the product name read as one line")
    func manufacturerAndProductCombine() {
        // Either alone is half an answer: "SanDisk" does not say which product, and
        // "Ultra Fit" does not say who made it.
        let device = USBDevice(
            name: "Cruzer", vendorName: "SanDisk",
            detail: USBDeviceDetail(productName: "Ultra Fit")
        )
        #expect(USBMonitor.manufacturerDetail(device) == "SanDisk Ultra Fit")
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

@Suite("USB device detail")
struct USBDeviceDetailTests {
    @Test("the vendor and product IDs read as the hex pair everyone quotes")
    func vidPidIsHex() {
        #expect(USBDeviceDetail(vendorID: 0x0781, productID: 0x5583).vidPidNote == "0781:5583")
        // Both halves or neither: half an identifier identifies nothing.
        #expect(USBDeviceDetail(vendorID: 0x0781).vidPidNote == nil)
    }

    @Test("the speed reads as the generation people recognise")
    func speedIsNamed() {
        #expect(USBDeviceDetail(speedCode: 2).speedNote == "USB 2.0 (High Speed)")
        #expect(USBDeviceDetail(speedCode: 5).speedNote == "USB 3.2 Gen 2x2 (SuperSpeed+, 20 Gb/s)")
        #expect(USBDeviceDetail(speedCode: 99).speedNote == nil)
    }

    @Test("a device drawing more than its port can give is warned about")
    func excessivePowerIsFlagged() {
        // This is the explanation for a drive that keeps dropping out, and nothing else
        // in macOS says so — which is why the line is on by default.
        let hungry = USBDeviceDetail(requiredCurrent: 900, availableCurrent: 500)
        #expect(hungry.powerNote == "900mA / 500mA available ⚠️ exceeds available")

        let fine = USBDeviceDetail(requiredCurrent: 200, availableCurrent: 500)
        #expect(fine.powerNote == "200mA / 500mA available")
    }

    @Test("a device whose port did not say what it offers still reports its own draw")
    func powerWithoutAvailable() {
        #expect(USBDeviceDetail(requiredCurrent: 500).powerNote == "500mA")
        #expect(USBDeviceDetail().powerNote == nil)
    }

    @Test("the refusal warning only ever appears when the port refused")
    func failedPowerIsPresentOnly() {
        // Telling somebody their device got the power it asked for is not news.
        #expect(USBDeviceDetail(requestedMoreThanAvailable: true).failedPowerNote != nil)
        #expect(USBDeviceDetail(requestedMoreThanAvailable: false).failedPowerNote == nil)
    }

    @Test("the storage medium says whether the disk inside spins")
    func mediumIsTranslated() {
        #expect(USBDeviceDetail(mediumType: "Solid State").mediumNote == "SSD / Flash")
        #expect(USBDeviceDetail(mediumType: "Rotational").mediumNote == "HDD (rotational)")
        // A device that is not storage at all has no medium to report.
        #expect(USBDeviceDetail(mediumType: nil).mediumNote == nil)
        #expect(USBDeviceDetail(mediumType: "Something Else").mediumNote == nil)
    }

    @Test("version words are read as the decimal halves they encode")
    func bcdVersionsAreDecoded() {
        // 0x0210 is version 2.10, not 528 — reading it as a plain number is meaningless.
        #expect(USBDeviceDetail(releaseVersion: 0x0210).firmwareNote == "2.10")
        #expect(USBDeviceDetail(specVersion: 0x0320).specVersionNote == "3.20")
        #expect(USBDeviceDetail(specVersion: 0x0200).specVersionNote == "2.00")
    }

    @Test("the port location reads as the hex the system uses")
    func locationIsHex() {
        #expect(USBDeviceDetail(locationID: 0x14300000).locationNote == "0x14300000")
    }

    @Test("the port line gathers whichever parts are known")
    func portLineIsBuiltFromParts() {
        #expect(USBDeviceDetail(isPortRemovable: true, connectorType: 3).portNote == "removable, connector type code 3")
        #expect(USBDeviceDetail(isPortRemovable: false).portNote == "built-in")
        #expect(USBDeviceDetail(connectorType: 0).portNote == "connector type code 0")
        #expect(USBDeviceDetail().portNote == nil)
    }

    @Test("arriving over a Thunderbolt tunnel is present-only")
    func tunnelIsPresentOnly() {
        #expect(USBDeviceDetail(isTunnelled: true).tunnelNote == "USB4/Thunderbolt tunnel")
        #expect(USBDeviceDetail(isTunnelled: false).tunnelNote == nil)
    }
}

@Suite("USB bus names")
struct USBBusNameTests {
    @Test("the Mac's own controllers are given names for people")
    func rootHubsAreRenamed() {
        // "XHCI Root Hub SS Simulation" is a name from the driver, not one for a
        // notification about the machine's own hardware.
        #expect(IOKitUSBDeviceSource.friendlyBusName("XHCI Root Hub SS Simulation") == "USB 3.0 Bus")
        #expect(IOKitUSBDeviceSource.friendlyBusName("XHCI Root Hub USB 2.0 Simulation") == "USB 2.0 Bus")
        #expect(IOKitUSBDeviceSource.friendlyBusName("EHCI Root Hub Simulation") == "USB 2.0 Bus")
        #expect(IOKitUSBDeviceSource.friendlyBusName("OHCI Root Hub Simulation") == "USB Bus")
        #expect(IOKitUSBDeviceSource.friendlyBusName("UHCI Root Hub Simulation") == "USB Bus")
    }

    @Test("a real device's name is left exactly as it is")
    func realDevicesAreUntouched() {
        #expect(IOKitUSBDeviceSource.friendlyBusName("SanDisk Cruzer") == "SanDisk Cruzer")
        #expect(IOKitUSBDeviceSource.friendlyBusName("") == "")
    }
}
