import Foundation
import SentryTestSupport
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

/// A source driven event by event, for the cases where a setting has to change *between*
/// two events rather than before both of them.
final class LiveUSBSource: USBDeviceSource, @unchecked Sendable {
    private let continuation: AsyncStream<USBDeviceChange>.Continuation
    private let stream: AsyncStream<USBDeviceChange>

    init() {
        var escaped: AsyncStream<USBDeviceChange>.Continuation!
        stream = AsyncStream { escaped = $0 }
        continuation = escaped
    }

    func changes() -> AsyncStream<USBDeviceChange> { stream }
    func send(_ change: USBDeviceChange) { continuation.yield(change) }
    func finish() { continuation.finish() }
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
    private func run(
        _ changes: [USBDeviceChange],
        kindsCoveredElsewhere: Set<USBDeviceKind> = [],
        ignoresIdentifiedGenericDevices: Bool = false
    ) async -> [NotificationEvent] {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let monitor = USBMonitor(
            source: ScriptedSource(script: changes),
            context: MonitorContext(dispatcher: dispatcher, category: USBMonitor.category),
            kindsCoveredElsewhere: kindsCoveredElsewhere,
            ignoresIdentifiedGenericDevices: ignoresIdentifiedGenericDevices
        )

        await monitor.start()
        // The monitor consumes its source on its own task. Unconditional, rather than
        // waiting for a target event count: a suppressed change means fewer events than
        // changes, so there is no number to wait up to — which is why this settles for a
        // moment instead. See `settle()`.
        await settle()
        await monitor.stop()
        return await delivery.events
    }

    @Test("a device arriving is announced")
    func attachIsAnnounced() async {
        let events = await run([.attached(USBDevice(name: "SanDisk Cruzer"))])

        #expect(events.count == 1)
        #expect(events.first?.name == "USBConnected")
        #expect(events.first?.title == "USB Device Connected")
        #expect(events.first?.category == USBEvent.category)
    }

    @Test("a device leaving is announced")
    func detachIsAnnounced() async {
        let events = await run([.detached(USBDevice(name: "SanDisk Cruzer"))])

        #expect(events.first?.name == "USBDisconnected")
        #expect(events.first?.title == "USB Device Disconnected")
    }

    // Asked for directly, once independent USB notices for Camera and Audio made one
    // physical connect produce up to three separate banners: a way to fold this
    // module's own generic one away for whichever kinds another monitor already speaks
    // for, without losing the device from the log entirely if that other monitor is
    // switched off.

    @Test("a covered kind is silent here")
    func coveredKindIsQuiet() async {
        // The BRIO's real shape (video and audio both) reads as `.audioVideo` — covered
        // only once both Camera's and Audio's own switches have said so between them,
        // modelled here as the boundary this monitor sees: the kind already folded in.
        let events = await run(
            [
                .attached(USBDevice(name: "Logitech BRIO", deviceClass: 0xEF, interfaceClasses: [0x0E, 0x01])),
                .detached(USBDevice(name: "Logitech BRIO", deviceClass: 0xEF, interfaceClasses: [0x0E, 0x01]))
            ],
            kindsCoveredElsewhere: [.audioVideo]
        )
        #expect(events.isEmpty)
    }

    // Asked for directly, reported live: a physical hub enumerates its own internal
    // Billboard/Communications interfaces as separate devices alongside itself, each
    // with no `USBDeviceKind` of its own — so each reads as the same "USB Device
    // Connected" the truly unidentified case does, with nothing beyond the body's own
    // "Type:" line to tell the two apart.

    @Test("a device with a real class name but no row of its own is quiet once the switch is on")
    func identifiedGenericDeviceIsQuietWhenSwitchedOn() async {
        // 0x11 is Billboard — a real, named USB-IF class with no `USBDeviceKind` case and
        // so no row or icon of its own; exactly the shape a hub's internal interface takes.
        let events = await run(
            [.attached(USBDevice(name: "Hub Billboard Device", deviceClass: 0x11))],
            ignoresIdentifiedGenericDevices: true
        )
        #expect(events.isEmpty)
    }

    @Test("the same identified device still announces while the switch is off")
    func identifiedGenericDeviceStillAnnouncesByDefault() async {
        let events = await run(
            [.attached(USBDevice(name: "Hub Billboard Device", deviceClass: 0x11))],
            ignoresIdentifiedGenericDevices: false
        )
        #expect(events.count == 1)
    }

    @Test("a device nothing at all is known about still announces even with the switch on")
    func genuinelyUnidentifiedDeviceStillAnnouncesWhenSwitchedOn() async {
        // 0x00 with nothing on the interfaces either — the honest "device said nothing"
        // case `className` itself returns nil for, which is what the switch is supposed
        // to leave alone.
        let events = await run(
            [.attached(USBDevice(name: "Mystery Device", deviceClass: 0x00))],
            ignoresIdentifiedGenericDevices: true
        )
        #expect(events.count == 1)
    }

    @Test("a device with its own row is unaffected by the switch either way")
    func devicesWithTheirOwnKindAreUnaffectedBySwitch() async {
        let events = await run(
            [.attached(USBDevice(name: "Anker Hub", isHub: true))],
            ignoresIdentifiedGenericDevices: true
        )
        #expect(events.count == 1)
        #expect(events.first?.title == "USB Hub Connected")
    }

    @Test("a vendor-specific device still announces even with the switch on, and the sibling hub it enumerates alongside is unaffected")
    func vendorSpecificDeviceStillAnnouncesWhenSwitchedOn() async {
        // Reported live, 2026-09-06: a real FTDI USB-serial adapter — device class 0x00,
        // its interface class the FTDI chip's own 0xFF ("Vendor Specific", USB-IF's own
        // "ask the vendor" escape hatch, naming nothing about what the device actually
        // is) — went silent with the switch on, because `className` resolved to
        // "Vendor Specific" and the switch could not tell that apart from a device
        // naming a real class. A hub chip built into the same adapter enumerated
        // alongside it and, correctly, kept announcing as "USB Hub Connected" — which
        // is what made the FTDI's own silence read as "detected as a hub" instead of
        // "not detected at all".
        let events = await run(
            [
                .attached(USBDevice(name: "FT232R USB UART", deviceClass: 0x00, interfaceClasses: [0xFF])),
                .attached(USBDevice(name: "USB 2.0 Hub", isHub: true))
            ],
            ignoresIdentifiedGenericDevices: true
        )
        #expect(events.count == 2)
        #expect(events.contains { $0.title == "USB Device Connected" })
        #expect(events.contains { $0.title == "USB Hub Connected" })
    }

    @Test("a kind not covered elsewhere still gets its own notice")
    func uncoveredKindIsNeverSilenced() async {
        let events = await run(
            [.attached(USBDevice(name: "Anker Hub", isHub: true))],
            kindsCoveredElsewhere: [.webcam, .audio]
        )
        #expect(events.count == 1)
        #expect(events.first?.title == "USB Hub Connected")
    }

    @Test("a covered kind speaks once the monitor that covers it is switched off")
    func kindStopsBeingCoveredOnceTheOtherMonitorIsSwitchedOff() async {
        // `kindsCoveredElsewhere` is computed by whoever assembles this monitor, from
        // whether Camera/Audio's own switch is off — so it never lists a kind whose only
        // other announcer has gone quiet. Modelled here directly, at the boundary this
        // monitor actually sees, rather than through that computation.
        let events = await run(
            [.attached(USBDevice(name: "Logitech BRIO", deviceClass: 0xEF, interfaceClasses: [0x0E, 0x01]))],
            kindsCoveredElsewhere: []
        )
        #expect(events.count == 1, "with nothing covered, the device must not go unreported")
    }

    @Test("apply changes the setting live, without a relaunch")
    func applyTakesEffectLive() async {
        let delivery = CollectingDelivery()
        let dispatcher = NotificationDispatcher(delivery: delivery)
        let source = LiveUSBSource()
        let monitor = USBMonitor(
            source: source,
            context: MonitorContext(dispatcher: dispatcher, category: USBMonitor.category)
        )
        await monitor.start()

        source.send(.attached(USBDevice(name: "Logitech BRIO", deviceClass: 0xEF, interfaceClasses: [0x0E, 0x01])))
        await settle()
        #expect(await delivery.events.count == 1)

        await monitor.apply(kindsCoveredElsewhere: [.audioVideo], ignoresIdentifiedGenericDevices: false)
        source.send(.detached(USBDevice(name: "Logitech BRIO", deviceClass: 0xEF, interfaceClasses: [0x0E, 0x01])))
        await settle()
        source.finish()
        await monitor.stop()

        #expect(await delivery.events.count == 1, "the disconnect after apply() must stay silent")
    }

    @Test("a hub is called a hub")
    func hubIsNamed() async {
        let events = await run([.attached(USBDevice(name: "Anker Hub", isHub: true))])

        #expect(events.first?.title == "USB Hub Connected")
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

        #expect(events.first?.body == "Cruzer\nManufacturer/Product:\tSanDisk")
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

        // One per device class, plus the two the original calls "(generic)".
        #expect(declared == Set(USBEvent.allCases.map(\.rawValue)))
        #expect(declared.count == USBDeviceKind.allCases.count + 2)
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
        // A specific icon that happened to be the generic one would make "USB Device Connected"
        // and, say, "a printer arrived" indistinguishable at a glance. Webcam is the deliberate
        // exception: that notice is USB Monitor's own, redundant one for a device Camera already
        // names and iconed in its own notice, so it wears the plain USB glyph on purpose.
        let generic = try #require(Bundle.module.url(forResource: "USB-On", withExtension: "png"))
        let genericBytes = try Data(contentsOf: generic)

        var seen = Set<String>()
        for code in UInt8.min...UInt8.max {
            let dev = device(class: code)
            guard let base = dev.iconBaseName, seen.insert(base).inserted else { continue }
            guard dev.kind != .webcam else { continue }
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

    // Reported live: a Logitech BRIO's notification title already said "USB Webcam
    // Connected" (device class 0xEF resolved from its interfaces, see USBDeviceKindTests)
    // while its own body still said "Type: Miscellaneous" — the same fallback existing on
    // one side and not the other, so the title and the body disagreed about what had just
    // connected.
    @Test("a composite device is named from its interfaces too, matching its kind")
    func compositeDeviceClassNameMatchesKind() {
        let device = USBDevice(name: "Webcam", deviceClass: 0xEF, interfaceClasses: [0x0E, 0x01])
        #expect(device.className == "Audio/Video")
        #expect(device.kind == .audioVideo)
    }

    @Test("a composite device with nothing recognised on its interfaces keeps an honest generic name")
    func compositeDeviceWithNoRecognisedInterfaceStaysMiscellaneous() {
        // 0x04 and 0x42 have never been assigned a USB-IF base class; unlike 0x02
        // ("Communications"), neither names anything real for `className` to prefer.
        let device = USBDevice(name: "Thing", deviceClass: 0xEF, interfaceClasses: [0x04, 0x42])
        #expect(device.className == "Miscellaneous")
        // Same reasoning as "Vendor Specific"/"Application Specific": "more than one
        // function, none of them nameable" is not an answer either, and should not
        // silence this device's generic notice when the switch is on.
        #expect(device.isMeaningfullyIdentified == false)
    }

    @Test("a device whose own class already says something is never overridden by its interfaces")
    func ownClassNameWinsOverInterfaces() {
        #expect(USBDevice(name: "Thing", deviceClass: 0x08, interfaceClasses: [0x0E]).className == "Mass Storage")
    }

    @Test("\"Vendor Specific\"/\"Application Specific\" name something but are not meaningfully identified")
    func vendorAndApplicationSpecificAreNotMeaningfullyIdentified() {
        // Reported live: an FTDI USB-serial adapter's own interface class (0xFF) resolves
        // `className` to "Vendor Specific" — a real string, but one that says nothing
        // about what the device actually does. `isMeaningfullyIdentified` is what
        // `ignoresIdentifiedGenericDevices` actually checks, precisely so this class (and
        // 0xFE/"Application Specific" here, 0xEF/"Miscellaneous" covered alongside its
        // own `className` test above — USB-IF's three escape hatches) reads the same as
        // a device with no class at all, not the same as Billboard/Communications.
        let vendorSpecific = USBDevice(name: "FT232R USB UART", deviceClass: 0x00, interfaceClasses: [0xFF])
        #expect(vendorSpecific.className == "Vendor Specific")
        #expect(vendorSpecific.isMeaningfullyIdentified == false)

        let applicationSpecific = USBDevice(name: "Thing", deviceClass: 0xFE)
        #expect(applicationSpecific.className == "Application Specific")
        #expect(applicationSpecific.isMeaningfullyIdentified == false)

        // A real, named class — Billboard, the shape this whole switch exists for —
        // still counts as meaningfully identified.
        #expect(USBDevice(name: "Thing", deviceClass: 0x11).isMeaningfullyIdentified == true)

        // Nothing recognised anywhere is, as ever, not identified either.
        #expect(USBDevice(name: "Thing", deviceClass: 0x00).isMeaningfullyIdentified == false)
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

    @Test("the mass-storage heuristic recognises an SD card by protocol or by name")
    func massStorageHintRecognisesSDCard() {
        #expect(USBMassStorageHint.infer(protocolName: "Secure Digital", mediaName: nil) == .sdCard)
        #expect(USBMassStorageHint.infer(protocolName: nil, mediaName: "SDXC Card") == .sdCard)
        #expect(USBMassStorageHint.infer(protocolName: nil, mediaName: "Generic Card Reader") == .sdCard)
    }

    @Test("the mass-storage heuristic recognises a flash drive by name")
    func massStorageHintRecognisesUSBDrive() {
        #expect(USBMassStorageHint.infer(protocolName: nil, mediaName: "SanDisk Cruzer Flash Disk") == .usbDrive)
        #expect(USBMassStorageHint.infer(protocolName: nil, mediaName: "USB Mass Storage Device") == .usbDrive)
    }

    @Test("the mass-storage heuristic recognises a disk enclosure by name or, failing that, by size")
    func massStorageHintRecognisesExternalDisk() {
        #expect(USBMassStorageHint.infer(protocolName: "USB", mediaName: "Portable SSD") == .externalDisk)
        #expect(USBMassStorageHint.infer(protocolName: nil, mediaName: "External Hard Drive") == .externalDisk)
        // Confirmed live, 2026-09-05: a real 1 TB external HDD whose Disk Arbitration
        // media name is a bare Seagate model number ("D ST1000LM02") — no "hdd"/"external"
        // word to match — is still recognised, on size alone, the same fallback
        // `VolumeKind`'s own heuristic already relies on.
        let oneTerabyte: UInt64 = 1_000_000_000_000
        #expect(USBMassStorageHint.infer(protocolName: "USB", mediaName: "D ST1000LM02", sizeBytes: oneTerabyte) == .externalDisk)
        // An explicit name beats the size guess: a 1 TB drive naming itself a flash drive
        // is not filed as an enclosure on size alone.
        #expect(USBMassStorageHint.infer(protocolName: "USB", mediaName: "SanDisk Extreme Flash Drive", sizeBytes: oneTerabyte) == .usbDrive)
    }

    @Test("the mass-storage heuristic stays generic for a small, unnamed disk")
    func massStorageHintStaysGenericOtherwise() {
        // Confirmed live, 2026-09-05: a real pendrive whose controller chip carries no
        // product string and an unregistered placeholder vendor ID has nothing here to
        // go on — too small for the enclosure-sized fallback, honestly unidentifiable
        // rather than guessed at either way.
        #expect(USBMassStorageHint.infer(protocolName: "USB", mediaName: nil, sizeBytes: 15_700_000_000) == nil)
        #expect(USBMassStorageHint.infer(protocolName: nil, mediaName: nil) == nil)
    }

    @Test("a Mass Storage device is refined into USB Drive, SD Card Reader or External Disk by the heuristic, never without it")
    func kindIsRefinedByMassStorageHint() {
        let plain = USBDevice(name: "Disk", deviceClass: 0x08)
        #expect(plain.kind == .massStorage)

        let flashDrive = USBDevice(
            name: "Disk", deviceClass: 0x08, detail: USBDeviceDetail(massStorageHint: .usbDrive)
        )
        #expect(flashDrive.kind == .usbDrive)

        let sdCard = USBDevice(
            name: "Disk", deviceClass: 0x08, detail: USBDeviceDetail(massStorageHint: .sdCard)
        )
        #expect(sdCard.kind == .sdCardReader)

        let externalDisk = USBDevice(
            name: "Disk", deviceClass: 0x08, detail: USBDeviceDetail(massStorageHint: .externalDisk)
        )
        #expect(externalDisk.kind == .externalDisk)

        // The hint only ever refines a device the class byte already called Mass Storage —
        // it has no say over anything else.
        let webcam = USBDevice(name: "Cam", deviceClass: 0x0E, detail: USBDeviceDetail(massStorageHint: .usbDrive))
        #expect(webcam.kind == .webcam)
    }

    @Test("an empty card reader (no disk to read a hint from) is still told apart from a plain pendrive, by its own USB product name")
    func emptyCardReaderIsRecognisedByItsOwnName() {
        // Reported live, 2026-09-06: a genuine multi-card reader (VID 0x05E3, Genesys
        // Logic), part of a USB-C dock, with no card in any slot — `massStorageHint`
        // stays nil since an empty slot publishes no `IOMedia` for that heuristic to
        // read, so this fell all the way to the plain `.massStorage` row and wore the
        // same flash-drive icon a real pendrive gets, reading as "a pendrive is
        // connected" when nothing was. Its own USB product string names it outright.
        let emptyReader = USBDevice(
            name: "USB3.0 Card Reader", deviceClass: 0x08,
            detail: USBDeviceDetail(vendorID: 0x05E3, productID: 0x0749)
        )
        #expect(emptyReader.kind == .sdCardReader)

        // The disk-level heuristic still wins when it has something to say — this is an
        // additional, narrower fallback, not a replacement for it.
        let readerWithCard = USBDevice(
            name: "USB3.0 Card Reader", deviceClass: 0x08,
            detail: USBDeviceDetail(massStorageHint: .externalDisk)
        )
        #expect(readerWithCard.kind == .externalDisk)

        // A device whose name says nothing about being a card reader stays plain
        // `.massStorage` — this narrows, it never widens, what counts as one.
        let genericDisk = USBDevice(name: "External Storage Device", deviceClass: 0x08)
        #expect(genericDisk.kind == .massStorage)
    }

    @Test("a device with no informative class byte, but a known serial/debug vendor ID, resolves to Serial/Debug Adapter")
    func knownVendorResolvesUnclassifiedDeviceToSerialAdapter() {
        // FTDI's own VID — the same real FT232R adapter this suite's other test above,
        // `vendorSpecificDeviceStillAnnouncesWhenSwitchedOn`, keeps announcing generically
        // rather than silencing. Told apart here rather than there, since `kind` (not the
        // switch) is what now recognises it specifically.
        let ftdi = USBDevice(
            name: "FT232R USB UART", deviceClass: 0x00, interfaceClasses: [0xFF],
            detail: USBDeviceDetail(vendorID: 0x0403)
        )
        #expect(ftdi.kind == .serialAdapter)

        // An unrecognised vendor with the same uninformative class byte stays nil, exactly
        // as before this feature existed.
        let unknown = USBDevice(
            name: "Mystery UART", deviceClass: 0x00, interfaceClasses: [0xFF],
            detail: USBDeviceDetail(vendorID: 0xFFFF)
        )
        #expect(unknown.kind == nil)

        // A real, already-classified device is never second-guessed by its vendor ID, even
        // if that vendor also happens to make serial chips.
        let realClass = USBDevice(
            name: "Something Else", deviceClass: 0x03, detail: USBDeviceDetail(vendorID: 0x0403)
        )
        #expect(realClass.kind == .hid)
    }

    @Test("a device with a real class name but no row of its own is never second-guessed as a vendor-ID adapter")
    func namedClassWithNoRowIsNeverMistakenForAVendorAdapter() {
        // Reported live, 2026-09-06, right after the usb.ids widening: a VIA Labs USB
        // 2.0 BILLBOARD chip (device class 0x11, Billboard — real, named by `className`,
        // but with no `USBDeviceKind` row of its own) was misread as "Serial/Debug
        // Adapter" once VIA Labs' own VID became a "known vendor" via that update.
        // `resolved == nil` is true for this device too (no Billboard row exists), which
        // is exactly why the vendor-lookup guard needs `!isMeaningfullyIdentified`
        // alongside it, not `resolved == nil` alone.
        let billboard = USBDevice(
            name: "USB 2.0 BILLBOARD", deviceClass: 0x11,
            detail: USBDeviceDetail(vendorID: 0x2109, productID: 0x0102)
        )
        #expect(billboard.kind == nil, "a real, named class must never be reclassified by a vendor-ID guess")
    }

    @Test("0xE0/subclass 1/protocol 1 resolves to Bluetooth Adapter, confirmed against two real dongles, and the switch can fall it back to plain Wireless")
    func bluetoothSignatureResolvesToBluetoothAdapter() {
        defer { USBWirelessDetectionSettings.shared.detectsBluetoothAdapters = true }

        // Read live via `ioreg -p IOUSB -l`, 2026-09-06, from two actual Bluetooth dongles
        // connected at once — a Broadcom and a CSR8510, different vendors, same USB-IF
        // signature.
        let broadcom = USBDevice(
            name: "Broadcom Bluetooth 3.0 Dongle", deviceClass: 0xE0, deviceSubClass: 0x01, deviceProtocol: 0x01,
            detail: USBDeviceDetail(vendorID: 0x0A5C, productID: 0x218C)
        )
        let csr = USBDevice(
            name: "CSR8510 A10", deviceClass: 0xE0, deviceSubClass: 0x01, deviceProtocol: 0x01,
            detail: USBDeviceDetail(vendorID: 0x0A12, productID: 0x0001)
        )
        #expect(broadcom.kind == .bluetoothAdapter)
        #expect(csr.kind == .bluetoothAdapter)

        // A `0xE0` device that is not this exact subclass/protocol pair stays the plain,
        // original "Wireless Controller" row — this only narrows, never widens, what
        // `0xE0` can mean.
        let genericWireless = USBDevice(name: "Some Dongle", deviceClass: 0xE0, deviceSubClass: 0x02, deviceProtocol: 0x01)
        #expect(genericWireless.kind == .wireless)

        USBWirelessDetectionSettings.shared.detectsBluetoothAdapters = false
        #expect(broadcom.kind == .wireless, "switched off, a Bluetooth dongle must read exactly as it did before this feature existed")
    }

    @Test("a device with no informative class byte, but a known WiFi-chip vendor ID, resolves to WiFi Adapter, gated by its own switch")
    func knownWiFiVendorResolvesUnclassifiedDeviceToWiFiAdapter() {
        defer { USBWirelessDetectionSettings.shared.detectsWiFiAdapters = true }

        let realtek = USBDevice(
            name: "802.11ac NIC", deviceClass: 0xFF,
            detail: USBDeviceDetail(vendorID: 0x0BDA)
        )
        #expect(realtek.kind == .wifiAdapter)

        // Not asserted as `nil`: `USBSerialVendorDatabase.shared` is a live, process-wide
        // singleton that a real "Check Now" (this machine's own, or another test) may
        // already have widened with a `usb.ids` download, in which case a real, widely
        // registered vendor like Realtek can legitimately fall back to `.serialAdapter`
        // instead — that is correct behaviour, not something this test owns. What this
        // switch alone promises is narrower: WiFi Adapter specifically stops being
        // reachable.
        USBWirelessDetectionSettings.shared.detectsWiFiAdapters = false
        #expect(realtek.kind != .wifiAdapter, "switched off, WiFi Adapter must never be the answer")
    }

    @Test("a wired Ethernet adapter is never claimed by the WiFi vendor guess, even from the same vendor")
    func wiredAdapterIsNotMistakenForWiFi() {
        // Read live via `ioreg -p IOUSB -l`, 2026-09-07, from the Realtek USB Ethernet
        // adapter in this machine's dock: device class 0x00 ("ask the interfaces"),
        // vendor 0x0BDA — which is on the WiFi-chip vendor list. Its interfaces say
        // Communications/ECM + CDC Data, but those are read on a bounded retry; this is
        // the shape it arrives in when that retry times out.
        let lan = USBDevice(
            name: "USB 10_100_1000 LAN", deviceClass: 0x00,
            detail: USBDeviceDetail(vendorID: 0x0BDA, productID: 0x8153)
        )
        #expect(lan.kind == .communications)

        // Once the interfaces did arrive, the ordinary path answers the same thing.
        let enriched = USBDevice(
            name: "USB 10_100_1000 LAN", deviceClass: 0x00, interfaceClasses: [0x02, 0x0A],
            detail: USBDeviceDetail(vendorID: 0x0BDA, productID: 0x8153)
        )
        #expect(enriched.kind == .communications)
    }

    @Test("\"WLAN\" is not read as \"LAN\" — a wireless dongle stays wireless")
    func wirelessNameIsNotReadAsWired() {
        defer { USBWirelessDetectionSettings.shared.detectsWiFiAdapters = true }
        USBWirelessDetectionSettings.shared.detectsWiFiAdapters = true

        // The trap this ordering exists for: the wired check would match "lan" inside
        // "WLAN" and announce a WiFi dongle as a wired Ethernet adapter.
        for name in ["802.11n WLAN Adapter", "Wireless-AC Dongle", "Wi-Fi 6 Adapter"] {
            let dongle = USBDevice(
                name: name, deviceClass: 0xFF,
                detail: USBDeviceDetail(vendorID: 0x0BDA)
            )
            #expect(dongle.kind == .wifiAdapter, "\(name) must not be read as wired")
        }

        // A name that says neither is left to the vendor guess, as before.
        let mystery = USBDevice(name: "USB Device", deviceClass: 0xFF)
        #expect(mystery.kind != .communications)
    }

    @Test("the HID sub-kinds have pictures of their own, not the keyboard's")
    func hidSubKindsDoNotWearTheKeyboardsPicture() {
        // The ported HID artwork is a picture of a keyboard, and `.keyboard` took it as
        // its own when that row was split out. Anything else that borrowed it was then
        // being announced with a picture of a keyboard — a gamepad, a remote and a
        // graphics tablet all were.
        let keyboardArt = USBDeviceKind.keyboard.iconBaseName
        for kind in [USBDeviceKind.gamepad, .remoteControl, .graphicsTablet, .mouse] {
            #expect(kind.iconBaseName != keyboardArt, "\(kind) still wears the keyboard's picture")
        }
        // And each is distinct from the others, not one shared "not a keyboard" glyph.
        let art = [USBDeviceKind.gamepad, .remoteControl, .graphicsTablet, .mouse, .keyboard]
            .map(\.iconBaseName)
        #expect(Set(art).count == art.count)
    }

    @Test("a keyboard and a mouse are told apart, not both filed under Keyboard/Mouse")
    func keyboardAndMouseAreToldApart() {
        // Both read live via `ioreg -c IOHIDDevice -l`, 2026-09-07, plugged in together
        // and both announced as an identical "USB Keyboard/Mouse Connected".
        let keyboard = USBDevice(
            name: "usb keyboard", vendorName: "USB", deviceClass: 0x03,
            detail: USBDeviceDetail(vendorID: 0xC0F4, productID: 0x01E0,
                                    hidUsagePage: 0x01, hidUsage: 0x06)
        )
        #expect(keyboard.kind == .keyboard)
        #expect(keyboard.kind?.settingsTitle == "Keyboard")

        let mouse = USBDevice(
            name: "USB Optical Mouse", vendorName: "Genius", deviceClass: 0x03,
            detail: USBDeviceDetail(vendorID: 0x0458, productID: 0x003A,
                                    hidUsagePage: 0x01, hidUsage: 0x02)
        )
        #expect(mouse.kind == .mouse)
        #expect(mouse.kind?.settingsTitle == "Mouse")

        // The combined row stays for a HID leading with neither.
        let combo = USBDevice(
            name: "Wireless Receiver", deviceClass: 0x03,
            detail: USBDeviceDetail(hidUsagePage: 0x01, hidUsage: 0x00)
        )
        #expect(combo.kind == .hid)
        // And for one that says nothing about its usage at all.
        #expect(USBDevice(name: "Some HID", deviceClass: 0x03).kind == .hid)
    }

    @Test("a device publishing several HID usages is read by the most telling one, not the first")
    func multipleUsagesArePrioritised() {
        // The real shape of the keyboard above: two HID interfaces, Generic
        // Desktop/Keyboard and Consumer Control for its media keys. Whichever the
        // registry hands over first, the keyboard must win — read the other way round it
        // would have been announced as a remote control.
        let keyboardFirst = HIDUsagePriority.preferred(from: [(0x01, 0x06), (0x0C, 0x01)])
        #expect(keyboardFirst?.page == 0x01 && keyboardFirst?.usage == 0x06)
        let consumerFirst = HIDUsagePriority.preferred(from: [(0x0C, 0x01), (0x01, 0x06)])
        #expect(consumerFirst?.page == 0x01 && consumerFirst?.usage == 0x06)

        // A tablet that also publishes Consumer Control stays a tablet.
        let tablet = HIDUsagePriority.preferred(from: [(0x0C, 0x01), (0x0D, 0x02)])
        #expect(tablet?.page == 0x0D && tablet?.usage == 0x02)

        // A device publishing only Consumer Control really is one.
        let remote = HIDUsagePriority.preferred(from: [(0x0C, 0x01)])
        #expect(remote?.page == 0x0C)

        // Nothing recognised: the first is kept, exactly as before this ordering existed.
        let unknown = HIDUsagePriority.preferred(from: [(0xFF00, 0x01), (0x0B, 0x05)])
        #expect(unknown?.page == 0xFF00)

        #expect(HIDUsagePriority.preferred(from: []) == nil)
    }

    @Test("the Mass Storage retry schedule starts fast and backs off, capped at one second")
    func massStoragePollScheduleBacksOff() {
        // The defaults: 250ms starting interval, 8s worst case.
        let schedule = MassStoragePollSchedule.backoff(pollInterval: 0.25, timeout: 8.0)
        #expect(schedule.first == 0.25, "the very first wait must still be the fast one")
        #expect(schedule.dropFirst().first == 0.5, "doubles on the second try")
        #expect(schedule.dropFirst(2).first == 1.0, "doubles again")
        // Capped at one second from here on, except the very last wait, which is
        // trimmed to land exactly on the deadline rather than overrun it.
        #expect(schedule.dropFirst(3).dropLast().allSatisfy { $0 == 1.0 })
        #expect(schedule.last! <= 1.0)
        #expect(schedule.reduce(0, +) == 8.0, "never runs past the deadline, and never short of it either")

        // Reported live, 2026-09-06: a real enclosure whose disk description was not
        // readable until 4.4 seconds in. Confirm it is still caught inside the schedule,
        // not merely inside the 8-second total.
        let elapsedBeforeCatch = schedule.reduce(into: 0.0) { total, wait in
            if total < 4.4 { total += wait }
        }
        #expect(elapsedBeforeCatch >= 4.4, "a check must land at or after the real device resolved")
        #expect(elapsedBeforeCatch < 5.0, "and not much later — this is the cost of backing off, not free")
    }

    @Test("the schedule never overruns its deadline, at any starting interval")
    func massStoragePollScheduleRespectsDeadline() {
        for pollInterval in [0.1, 0.25, 0.5, 1.0, 2.0] {
            for timeout in [2.0, 5.0, 8.0, 20.0] {
                let schedule = MassStoragePollSchedule.backoff(pollInterval: pollInterval, timeout: timeout)
                let total = schedule.reduce(0, +)
                #expect(abs(total - timeout) < 0.0001, "pollInterval=\(pollInterval) timeout=\(timeout)")
                #expect(schedule.allSatisfy { $0 <= max(pollInterval, 1.0) + 0.0001 })
            }
        }
    }

    @Test("a starting interval already at or above the one-second cap stays flat")
    func massStoragePollScheduleNeverShrinksTheStartingInterval() {
        // The slider's own range goes up to 2000ms — above the cap that exists to keep
        // a *short* interval from growing unboundedly. It must never grow past what
        // somebody explicitly configured, nor shrink below it.
        let schedule = MassStoragePollSchedule.backoff(pollInterval: 2.0, timeout: 8.0)
        #expect(schedule.allSatisfy { $0 == 2.0 || $0 < 2.0 }, "no wait may exceed the configured interval")
        #expect(schedule.dropLast().allSatisfy { $0 == 2.0 }, "every wait but the last, trimmed to the deadline, is flat")
    }

    @Test("an invalid interval or timeout yields an empty schedule, never a hang")
    func massStoragePollScheduleRefusesNonsense() {
        #expect(MassStoragePollSchedule.backoff(pollInterval: 0, timeout: 8.0) == [])
        #expect(MassStoragePollSchedule.backoff(pollInterval: 0.25, timeout: 0) == [])
        #expect(MassStoragePollSchedule.backoff(pollInterval: -1, timeout: 8.0) == [])
    }

    @Test("a HID device leading with Consumer or Digitizer usage is named, not filed under Keyboard/Mouse")
    func consumerAndDigitizerUsagesAreNamed() {
        // Consumer (0x0C) / Consumer Control (0x01) — a media remote or volume knob.
        let remote = USBDevice(
            name: "Media Remote", deviceClass: 0x03,
            detail: USBDeviceDetail(hidUsagePage: 0x0C, hidUsage: 0x01)
        )
        #expect(remote.kind == .remoteControl)

        // Digitizers (0x0D), usages Digitizer and Pen.
        for usage in [0x01, 0x02] {
            let tablet = USBDevice(
                name: "Pen Tablet", deviceClass: 0x03,
                detail: USBDeviceDetail(hidUsagePage: 0x0D, hidUsage: usage)
            )
            #expect(tablet.kind == .graphicsTablet, "digitizer usage \(usage)")
        }

        // A touch screen and a touch pad really are pointing devices; they stay put.
        for usage in [0x04, 0x05] {
            let touch = USBDevice(
                name: "Touch Pad", deviceClass: 0x03,
                detail: USBDeviceDetail(hidUsagePage: 0x0D, hidUsage: usage)
            )
            #expect(touch.kind == .hid, "touch usage \(usage) must stay HID")
        }

        // An ordinary keyboard leads with Generic Desktop/Keyboard, and is read as the
        // keyboard it is rather than as a remote — even though nearly all of them also
        // carry a Consumer Control collection for their media keys.
        let keyboard = USBDevice(
            name: "USB Keyboard", deviceClass: 0x03,
            detail: USBDeviceDetail(hidUsagePage: 0x01, hidUsage: 0x06)
        )
        #expect(keyboard.kind == .keyboard)
    }

    @Test("a HID device with Generic Desktop's Joystick/Gamepad/Multi-axis Controller usage resolves to Gamepad/Joystick, not Keyboard/Mouse")
    func gamepadUsageResolvesToGamepad() {
        // Read live via `ioreg -c IOHIDDevice -l`, 2026-09-06, from a real generic USB
        // gamepad (idVendor 0x0810, idProduct 0x0001) reported live as showing up as
        // "Keyboard/Mouse" — its interface is plain HID (class 3, subclass 0, protocol
        // 0, indistinguishable from a keyboard by class byte alone), but macOS's own HID
        // family already read its Report Descriptor as Generic Desktop (page 1) usage 4
        // (Joystick) — confirmed by `GamepadHIDServiceSupport = Yes` in the same dump.
        let gamepad = USBDevice(
            name: "USB Gamepad", deviceClass: 0x00, interfaceClasses: [0x03],
            detail: USBDeviceDetail(vendorID: 0x0810, productID: 0x0001, hidUsagePage: 0x01, hidUsage: 0x04)
        )
        #expect(gamepad.kind == .gamepad)

        // Gamepad (0x05) and Multi-axis Controller (0x08) are the other two Generic
        // Desktop usages a real controller commonly reports.
        let alsoGamepad = USBDevice(name: "Thing", deviceClass: 0x03, detail: USBDeviceDetail(hidUsagePage: 0x01, hidUsage: 0x05))
        #expect(alsoGamepad.kind == .gamepad)
        let flightStick = USBDevice(name: "Thing", deviceClass: 0x03, detail: USBDeviceDetail(hidUsagePage: 0x01, hidUsage: 0x08))
        #expect(flightStick.kind == .gamepad)

        // A real keyboard (Generic Desktop usage 6) is not a gamepad; it has its own row
        // now. A device with no HID usage read at all still stays exactly `.hid`.
        let keyboard = USBDevice(name: "Thing", deviceClass: 0x03, detail: USBDeviceDetail(hidUsagePage: 0x01, hidUsage: 0x06))
        #expect(keyboard.kind == .keyboard)
        let plainHID = USBDevice(name: "Thing", deviceClass: 0x03)
        #expect(plainHID.kind == .hid)
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

@Suite("USBMonitor · one row per device class")
struct USBDeviceKindRowTests {
    @Test("every class the original lists has a row, an icon that exists, and its own event")
    func everyKindIsDeclared() throws {
        // The original's fourteen rows — twelve classes plus the two generics — plus
        // Communications (0x02, "Network Adapter"), added after this device class turned
        // out to matter: a hub's own internal LAN-over-USB chip enumerates under it, and
        // was going through the generic row with nothing to tell it apart from a
        // genuinely unidentified device — plus USB Drive, SD Card Reader and External
        // Disk, Mass Storage's own sub-kinds told apart heuristically (see
        // `USBMassStorageHint`) — plus Serial/Debug Adapter, told apart by vendor ID
        // rather than class byte (see `USBSerialVendorDatabase`) — plus Bluetooth Adapter
        // and WiFi Adapter, `0xE0`'s own two sub-kinds (see `USBWirelessDetectionSettings`)
        // — plus Gamepad/Joystick, HID's own sub-kind told apart by Usage Page/Usage
        // rather than by class byte (see `USBDeviceDetail.hidUsagePage`/`hidUsage`).
        #expect(USBDeviceKind.allCases.count == 24)

        for kind in USBDeviceKind.allCases {
            let declared = USBMonitor.events.first { $0.name == kind.connectedEvent.rawValue }
            #expect(declared != nil, "\(kind) has no row")
            // `.asset` gives no icon for a name that resolves to nothing, so this catches
            // a typo in an artwork name as well as a missing row.
            #expect(declared?.icon != NotificationIcon.none, "\(kind) has no icon")
            #expect(declared?.title == kind.settingsTitle)
        }
    }

    @Test("the class codes are the USB-IF's own, and an unlisted one falls back to generic")
    func classCodesAreDecoded() {
        #expect(USBDeviceKind(deviceClass: 0x09) == .hub)
        #expect(USBDeviceKind(deviceClass: 0x08) == .massStorage)
        #expect(USBDeviceKind(deviceClass: 0x03) == .hid)
        #expect(USBDeviceKind(deviceClass: 0x0E) == .webcam)
        #expect(USBDeviceKind(deviceClass: 0xE0) == .wireless)
        #expect(USBDeviceKind(deviceClass: 0x02) == .communications)
        // 0x0A (CDC Data) has no artwork of its own: an honest generic icon beats a
        // wrong specific one.
        #expect(USBDeviceKind(deviceClass: 0x0A) == nil)
        #expect(USBDeviceKind(deviceClass: 0x00) == nil)
    }

    // Reported live: a hub's own internal network interface (a LAN-over-USB chip, seen on
    // the system as `en5`) enumerated as a plain "USB Device Connected" — no different
    // from a device nothing at all is known about — because Communications (0x02) had no
    // `USBDeviceKind` case of its own.
    @Test("a hub's internal network-adapter chip gets its own row, not the generic one")
    func communicationsDeviceIsNamedNetworkAdapter() {
        #expect(USBDeviceKind(deviceClass: 0x02) == .communications)
        #expect(USBDeviceKind.communications.settingsTitle == "Network Adapter")
        #expect(USBDeviceKind.communications.connectedEvent.rawValue == "USBConnectedCommunications")
        #expect(USBDeviceKind.communications.iconBaseName == "USB-TypeCommunications")
    }

    // Reported live: a Logitech BRIO showed up as a generic USB device rather than a
    // webcam. Its own descriptor, read back from the device: device class 0xEF/0x02/0x01
    // (the standard "Multi-Interface Function" marker, not a class of its own) with
    // interfaces 0x0E (Video) and 0x01 (Audio) underneath — the shape reproduced here.
    // Read as `.audioVideo`, not `.webcam`: a real microphone alongside the camera, not
    // an incidental interface, so neither Camera's nor Audio's own switch prevails over
    // the other for it.
    @Test("a composite device with no class of its own is read from its interfaces")
    func compositeDeviceFallsBackToInterfaces() {
        #expect(USBDeviceKind(deviceClass: 0xEF, interfaceClasses: [0x0E, 0x01]) == .audioVideo)
        // Order does not decide it.
        #expect(USBDeviceKind(deviceClass: 0xEF, interfaceClasses: [0x01, 0x0E]) == .audioVideo)
    }

    @Test("a webcam with only an incidental non-audio interface is still read as a webcam")
    func compositeWebcamWithoutAudioStaysWebcam() {
        #expect(USBDeviceKind(deviceClass: 0xEF, interfaceClasses: [0x0E, 0x03]) == .webcam)
    }

    // Reported live: a USB audio interface with a volume/mute-button HID interface
    // alongside its audio one resolved to `.hid` instead of `.audio` whenever the
    // registry happened to list that HID interface first — a class `kindsCoveredElsewhere`
    // has no opinion about, so "Notify for USB devices independently of USB Monitor" could
    // never fold USB Monitor's own notice away for it, whichever way it was set.
    @Test("a composite audio device is read as audio whichever order its interfaces list in")
    func compositeAudioDeviceIsNeverMistakenForHID() {
        #expect(USBDeviceKind(deviceClass: 0xEF, interfaceClasses: [0x01, 0x03]) == .audio)
        #expect(USBDeviceKind(deviceClass: 0xEF, interfaceClasses: [0x03, 0x01]) == .audio)
    }

    @Test("a device whose own class already says something is never overridden by its interfaces")
    func ownClassWinsOverInterfaces() {
        #expect(USBDeviceKind(deviceClass: 0x08, interfaceClasses: [0x0E]) == .massStorage)
    }

    @Test("interfaces that name nothing recognised still leave the device generic")
    func unrecognisedInterfacesStayGeneric() {
        #expect(USBDeviceKind(deviceClass: 0xEF, interfaceClasses: [0x0A, 0xFF]) == nil)
    }

    @Test("USBDevice reads its kind from interfaces too, not only USBDeviceKind directly")
    func deviceKindUsesInterfacesAsWell() {
        let device = USBDevice(name: "Webcam", deviceClass: 0xEF, interfaceClasses: [0x0E, 0x01])
        #expect(device.kind == .audioVideo)
        #expect(device.iconBaseName == USBDeviceKind.audioVideo.iconBaseName)
    }

    @Test("a hub is a hub even when its class code says otherwise")
    func hubFlagWins() {
        // Some hubs report a per-interface class and nothing on the device itself; the
        // registry knows they are hubs regardless, and that is the better answer.
        let device = USBDevice(name: "Hub", isHub: true, deviceClass: nil)
        #expect(device.kind == .hub)
        #expect(device.iconBaseName == "USB-TypeHub")
    }

    @Test("a device that never said what it is uses the generic row")
    func unclassifiedUsesGeneric() {
        let device = USBDevice(name: "Something", isHub: false, deviceClass: nil)
        #expect(device.kind == nil)
        #expect(device.iconBaseName == nil)
    }

    @Test("the fields the original ships on are on here too")
    func defaultsMatchTheOriginal() {
        let defaults = Set(USBMonitor.fields.filter(\.shownByDefault).map(\.name))
        #expect(defaults == [
            "Vendor", "Type", "VIDPID", "Speed", "Power", "Medium",
            "Serial", "Firmware", "LocationID"
        ])
        // And the five it ships off stay off.
        #expect(!defaults.contains(USBField.configurations.rawValue))
        #expect(!defaults.contains(USBField.specVersion.rawValue))
        #expect(!defaults.contains(USBField.tunnel.rawValue))
        #expect(!defaults.contains(USBField.failedPower.rawValue))
        #expect(!defaults.contains(USBField.portInfo.rawValue))
    }
}

@Suite("USBMonitor · module icon")
struct USBModuleIconTests {
    @Test("the module's icon is the plain USB glyph, not whichever class comes first")
    func moduleIconIsDeclared() {
        // Declaring one row per device class put a hub first, and the module list takes
        // the first event's artwork — so the whole of USB briefly became a hub. Network
        // fell into the same trap; this is the test that stops either happening again.
        #expect(USBMonitor.icon == .asset("USB-On", in: .module))
        #expect(USBMonitor.icon != USBMonitor.events.first?.icon)
    }
}

@Suite("USBMonitor · serial/debug vendor database")
struct USBSerialVendorDatabaseTests {
    @Test("the built-in list recognises FTDI and rejects an unassigned vendor ID")
    func builtInListLooksUpKnownAndUnknownVendors() {
        let db = USBSerialVendorDatabase()
        #expect(db.isKnownVendor(0x0403), "FTDI should be seeded in the built-in list")
        #expect(db.isKnownVendor(0x10C4), "Silicon Labs should be seeded in the built-in list")
        #expect(!db.isKnownVendor(0xFFFF), "an unassigned VID must never read as known")
    }

    @Test("refreshing from a source with nothing useful leaves the list exactly as it was")
    func refreshFromBadSourceChangesNothing() async {
        let db = USBSerialVendorDatabase()
        let before = db.vendorCount
        // Loopback address with nothing listening: the request itself fails, which is the
        // point — a network hiccup must never wipe out what was already known.
        let outcome = await db.refresh(from: URL(string: "http://127.0.0.1:1/nonexistent.json")!)
        #expect(outcome == .failed)
        #expect(db.vendorCount == before)
        #expect(db.isKnownVendor(0x0403))
    }

    @Test("usb.ids' own format is parsed: vendor lines kept, comments and indented sub-entries skipped")
    func decodesUSBIDsFormat() throws {
        // A tiny excerpt in the Linux USB ID Repository's real shape: a comment line, two
        // vendor lines, and — indented under the second with a leading tab, the way every
        // device/interface sub-entry is — one line that must NOT be read as its own vendor.
        let sample = """
        # List of USB ID's
        #
        0001  Fry's Electronics
        0403  Future Technology Devices International, Ltd
        \t6001  FT8U232AM USB-Serial Converter
        """
        let data = try #require(sample.data(using: .utf8))
        let parsed = try #require(USBSerialVendorDatabase.decode(data))
        #expect(parsed[0x0001] == "Fry's Electronics")
        #expect(parsed[0x0403] == "Future Technology Devices International, Ltd")
        #expect(parsed.count == 2, "the indented device sub-entry must not be read as its own vendor")
    }
}
