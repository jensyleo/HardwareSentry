import Foundation

/// A USB device, as much of one as is worth telling someone about.
public struct USBDevice: Sendable, Equatable {
    public let name: String
    public let vendorName: String?
    public let isHub: Bool
    /// The USB-IF `bDeviceClass` byte. `0x00` means "look at the interfaces instead", and
    /// `0xEF` means the same thing for a different reason — it is the standard marker for
    /// a composite device (an Interface Association Descriptor) rather than a class of
    /// its own. Either way, a device saying one of those has told us nothing on its own.
    public let deviceClass: UInt8?
    /// Every interface's own `bInterfaceClass`, read for exactly the case above: a
    /// composite device — a webcam that is also a microphone, most often — names its real
    /// classes here instead. Empty for the ordinary device that already said what it is.
    public let interfaceClasses: [UInt8]

    /// Everything else the device says about itself.
    public let detail: USBDeviceDetail

    public init(
        name: String,
        vendorName: String? = nil,
        isHub: Bool = false,
        deviceClass: UInt8? = nil,
        interfaceClasses: [UInt8] = [],
        detail: USBDeviceDetail = USBDeviceDetail()
    ) {
        self.name = name
        self.vendorName = vendorName
        self.isHub = isHub
        self.deviceClass = deviceClass
        self.interfaceClasses = interfaceClasses
        self.detail = detail
    }

    /// What this device says it is, or nil when it has not said anything specific.
    ///
    /// Nil is less common than it used to be: a composite device that names nothing at
    /// the device level — the BRIO among them, reported live as showing up generic rather
    /// than as the webcam it is — still gets a kind from its interfaces, tried second. It
    /// stays nil only for a device that names nothing at either level.
    public var kind: USBDeviceKind? {
        if isHub { return .hub }
        // `0x00` carries the same "look at the interfaces" meaning `0xEF` does, so an
        // absent device class is treated the same way rather than skipping straight to
        // the interfaces without also giving `0x00` itself a chance to (harmlessly) fail.
        let resolved = USBDeviceKind(deviceClass: deviceClass ?? 0x00, interfaceClasses: interfaceClasses)
        // Mass Storage covers three different things somebody plugs in — a flash drive, an
        // SD card reader, a portable HDD/SSD enclosure — and the class byte alone cannot
        // tell them apart; it is one class for all of them. Refined only when a heuristic
        // read of the disk itself (borrowed from Volume Monitor's own, independently
        // reimplemented since a monitor may not import another monitor) recognised
        // something more specific. An enclosure or an unrecognised disk stays `.massStorage`,
        // which is the honest answer when the heuristic has nothing to say.
        guard resolved == .massStorage, let hint = detail.massStorageHint else { return resolved }
        switch hint {
        case .sdCard: return .sdCardReader
        case .usbDrive: return .usbDrive
        case .externalDisk: return .externalDisk
        }
    }

    /// The artwork for what this device says it is.
    public var iconBaseName: String? { kind?.iconBaseName }
}

/// The device classes that have artwork and a row of their own.
///
/// One row per class, as the original has it: a Mac with a hub, a keyboard and a webcam
/// permanently attached should be able to silence the hub without silencing the webcam,
/// and give each the icon its owner recognises. The USB-IF assigns many more class codes
/// than these; the ones without artwork fall back to the generic row, because an honest
/// generic icon beats a wrong specific one.
public enum USBDeviceKind: String, Sendable, Equatable, CaseIterable {
    case hub, massStorage, hid, webcam, scanner, printer, smartCard
    case audio, healthcare, audioVideo, typeCBridge, wireless, communications
    case usbDrive, sdCardReader, externalDisk

    /// The USB-IF base class code, as the device reports it.
    public init?(deviceClass: UInt8) {
        switch deviceClass {
        case 0x01: self = .audio
        case 0x02: self = .communications
        case 0x03: self = .hid
        case 0x06: self = .scanner
        case 0x07: self = .printer
        case 0x08: self = .massStorage
        case 0x09: self = .hub
        case 0x0B: self = .smartCard
        case 0x0E: self = .webcam
        case 0x0F: self = .healthcare
        case 0x10: self = .audioVideo
        case 0x12: self = .typeCBridge
        case 0xE0: self = .wireless
        default: return nil
        }
    }

    /// Tries the device's own class first, and only then what its interfaces declare.
    ///
    /// Most devices say what they are once, on the device itself. A composite device —
    /// one built from more than one function glued together, like a webcam that is also a
    /// microphone — instead declares `0xEF` ("Miscellaneous", the standard marker for an
    /// Interface Association Descriptor) at the device level and pushes the real classes
    /// onto its interfaces, one per function. Reading only the device class there answers
    /// nothing: a Logitech BRIO reports `0xEF` and was filed under the generic USB event
    /// rather than "USB Webcam Connected", never touching `USB-TypeWebcam`'s icon or its
    /// own row in Settings. Reported live, with the device's own descriptor confirming
    /// the shape: device class `0xEF`/`0x02`/`0x01` (Multi-Interface Function), interfaces
    /// `0x0E` (Video) and `0x01` (Audio) underneath.
    ///
    /// A device genuinely both is neither first — a webcam with a built-in microphone,
    /// the Logitech BRIO among them, is read as `.audioVideo`, the same kind a device
    /// that declares USB-IF's own class `0x10` for exactly this combination gets. Elected
    /// ahead of the single-function picks below because that is the one kind
    /// `kindsCoveredElsewhere` already knows how to treat as neither module's alone: it
    /// only folds USB Monitor's own notice away once *both* Camera's and Audio's own
    /// switches say they have it covered, so silencing one module's switch on this device
    /// never silences the other's say over it. Before this, the interfaces were searched
    /// for video first and the device filed as a plain webcam whenever it had one — right
    /// for a webcam that happens to also carry an incidental audio-control interface, but
    /// wrong for one whose audio interface is a real microphone: reported live, a BRIO
    /// left Audio's own "Notify for USB devices independently" switch with nothing to
    /// silence, because USB Monitor's redundant notice for it was already being decided
    /// by Camera's switch alone.
    ///
    /// Video wins next, when only one of the two is present — a composite webcam with an
    /// incidental non-audio interface is still a webcam first, whatever else it happens
    /// to carry. Audio wins after that, for the same reason on a device that is not also
    /// a webcam: a USB headset or audio interface commonly carries a second, incidental
    /// interface of its own — an HID one, for its volume/mute buttons, most often — and
    /// the registry does not promise to iterate interfaces in ascending interface-number
    /// order, so `interfaceClasses` can just as easily list that HID interface before the
    /// audio one. Reported live: an audio interface's own class picked up second, behind
    /// HID, resolved `kind` to `.hid` instead of `.audio` — a class `kindsCoveredElsewhere`
    /// never has an opinion about, so USB Monitor's own notice for it could never be
    /// folded away, whatever "Notify for USB devices independently of USB Monitor" was
    /// set to. A device that names nothing at all, at either level, is content to stay
    /// generic.
    public init?(deviceClass: UInt8, interfaceClasses: [UInt8]) {
        if let kind = USBDeviceKind(deviceClass: deviceClass) {
            self = kind
            return
        }
        let kinds = interfaceClasses.compactMap { USBDeviceKind(deviceClass: $0) }
        let isHybrid = kinds.contains(.webcam) && kinds.contains(.audio)
        guard let kind: USBDeviceKind = isHybrid ? .audioVideo
            : kinds.first(where: { $0 == .webcam })
            ?? kinds.first(where: { $0 == .audio })
            ?? kinds.first
        else { return nil }
        self = kind
    }

    public var iconBaseName: String {
        switch self {
        case .hub: return "USB-TypeHub"
        // Mass storage borrows the disk artwork rather than the generic USB glyph: a
        // flash drive is a disk, and that is what somebody expects to see.
        case .massStorage: return "Device-USBDrive"
        case .hid: return "USB-TypeHID"
        // Every one of this row's own icons is now the USB glyph paired with the
        // device's own silhouette — "USB, and specifically a webcam" reads as this
        // module's own composite rather than a second, competing picture of a camera,
        // which is what a plain camera glyph on its own would have been.
        case .webcam: return "USB-TypeWebcam"
        case .scanner: return "USB-TypeScanner"
        case .printer: return "USB-TypePrinter"
        case .smartCard: return "USB-TypeSmartCard"
        case .audio: return "USB-TypeAudio"
        case .healthcare: return "USB-TypeHealthcare"
        case .audioVideo: return "USB-TypeAudioVideo"
        case .typeCBridge: return "USB-TypeTypeCBridge"
        case .wireless: return "USB-TypeWireless"
        // Same composite as every other row, paired with the network-adapter artwork
        // already ported for Thunderbolt Monitor's own row of the same shape (H4) — one
        // asset, two monitors, rather than drawing a second one for the same device kind.
        case .communications: return "USB-TypeCommunications"
        // Volume Monitor's own disk artwork for the two mass-storage sub-kinds it
        // already tells apart, reused as-is rather than redrawn for a second time.
        case .usbDrive: return "Device-USBDrive"
        case .sdCardReader: return "Device-SDCard"
        case .externalDisk: return "Device-ExternalDisk"
        }
    }

    /// How the row is named in Settings, in the original's words.
    var settingsTitle: String {
        switch self {
        case .hub: return "Hub"
        case .massStorage: return "Mass Storage"
        case .hid: return "Keyboard/Mouse"
        case .webcam: return "Webcam"
        case .scanner: return "Scanner"
        case .printer: return "Printer"
        case .smartCard: return "Smart Card"
        case .audio: return "Audio"
        case .healthcare: return "Healthcare"
        case .audioVideo: return "Audio/Video"
        case .typeCBridge: return "Type-C Bridge"
        case .wireless: return "Wireless"
        // "Network Adapter", not the USB-IF's own "Communications": reported live, this
        // is what a hub's own internal LAN-over-USB chip enumerates as, and "Network
        // Adapter" says what somebody actually sees appear (an `enX` interface) — the
        // "Type" line in the body still says "Communications", the USB-IF's own name for
        // it, so neither wording is lost.
        case .communications: return "Network Adapter"
        case .usbDrive: return "USB Drive"
        case .sdCardReader: return "SD Card Reader"
        case .externalDisk: return "External Disk"
        }
    }

    /// The event raised when a device of this kind arrives.
    var connectedEvent: USBEvent {
        switch self {
        case .hub: return .connectedHub
        case .massStorage: return .connectedMassStorage
        case .hid: return .connectedHID
        case .webcam: return .connectedWebcam
        case .scanner: return .connectedScanner
        case .printer: return .connectedPrinter
        case .smartCard: return .connectedSmartCard
        case .audio: return .connectedAudio
        case .healthcare: return .connectedHealthcare
        case .audioVideo: return .connectedAudioVideo
        case .communications: return .connectedCommunications
        case .typeCBridge: return .connectedTypeCBridge
        case .wireless: return .connectedWireless
        case .usbDrive: return .connectedUSBDrive
        case .sdCardReader: return .connectedSDCard
        case .externalDisk: return .connectedExternalDisk
        }
    }
}

/// What the disk behind a Mass Storage device looks like, read off the disk itself rather
/// than the USB class byte — which cannot tell a flash drive from an SD card reader from a
/// portable HDD/SSD enclosure, since all three share the one class, `0x08`.
///
/// A disk the heuristic below does not recognise stays nil and therefore `.massStorage` —
/// the honest generic answer, not a wrong specific guess.
///
/// The heuristic itself is a scoped, independently reimplemented copy of Volume Monitor's
/// own `VolumeKind.infer` (a monitor may not import another monitor's types — see the
/// architecture's module-isolation rule), including its size-based fallback for an
/// enclosure that names itself nothing useful. It is admittedly imperfect there already;
/// see `KNOWN-ISSUES.md` for what is left to a future investigation — confirmed live,
/// 2026-09-05, against a real pendrive whose controller chip carries no product string
/// and no vendor registration at all (`idVendor` 0xABCD, the well-known unregistered
/// placeholder), which this heuristic — like Volume Monitor's own — has no text or size
/// signal to identify: too small for the enclosure-sized fallback below, and honestly
/// unidentifiable rather than wrongly guessed at.
public enum USBMassStorageHint: Sendable, Equatable {
    case sdCard, usbDrive, externalDisk

    /// Unnamed USB storage this size or larger is guessed to be an enclosure rather than a
    /// flash drive — the same threshold and the same reasoning as `VolumeKind`'s own.
    static let externalDiskThresholdBytes: UInt64 = 400 * 1024 * 1024 * 1024

    public static func infer(protocolName: String?, mediaName: String?, sizeBytes: UInt64? = nil) -> USBMassStorageHint? {
        if protocolName?.caseInsensitiveCompare("Secure Digital") == .orderedSame { return .sdCard }
        let text = (mediaName ?? "").lowercased()
        if ["secure digital", " sd/", "sd card", "sdxc", "sdhc", "mmc",
            "compactflash", " cf ", "cardreader", "card reader"].contains(where: text.contains) {
            return .sdCard
        }
        // An explicit name beats the size guess: checked first so a 1 TB drive that calls
        // itself a flash drive is not filed as an enclosure on size alone.
        if ["hdd", "ssd", "hard disk", "hard drive", "external"].contains(where: text.contains) {
            return .externalDisk
        }
        if ["flash", "thumb", "pen drive", "usb drive", "mass storage"].contains(where: text.contains) {
            return .usbDrive
        }
        if let sizeBytes, sizeBytes >= externalDiskThresholdBytes { return .externalDisk }
        return nil
    }
}

public enum USBDeviceChange: Sendable, Equatable {
    case attached(USBDevice)
    case detached(USBDevice)
}

/// Where news of USB devices comes from.
///
/// A protocol so the monitor's own behaviour — what it says, and about what — can be
/// exercised without any hardware being plugged in or unplugged. The implementation that
/// talks to the system is deliberately thin, for the same reason the notification service
/// sits behind a protocol in `SignalCore`.
public protocol USBDeviceSource: Sendable {
    /// Devices already attached when watching begins, followed by changes as they happen.
    func changes() -> AsyncStream<USBDeviceChange>
}

public extension USBDevice {
    /// The artwork for this device leaving.
    ///
    /// Almost always the connected name with `-Disconnected` on the end. Mass storage is
    /// the exception: it borrows Volume Monitor's disk artwork, whose "gone" variant is
    /// named `-Unmounted`, so the mechanical suffix would ask for a file that does not
    /// exist and the icon would silently fall back to nothing.
    var disconnectedIconName: String {
        guard let base = iconBaseName else { return "USB-Off" }
        switch base {
        case "Device-USBDrive": return "Device-USBDrive-Unmounted"
        case "Device-SDCard": return "Device-SDCard-Unmounted"
        case "Device-ExternalDisk": return "Device-ExternalDisk-Unmounted"
        case "USB-On": return "USB-Off"
        default: return "\(base)-Disconnected"
        }
    }
}

public extension USBDevice {
    /// What the device says it is, in words — "Mass Storage", "HID (Keyboard/Mouse)".
    ///
    /// The USB-IF's published base class codes. Nil for `0x00` with nothing recognised on
    /// its interfaces either: that is the common case, not an error, and there is nothing
    /// useful to say about it.
    ///
    /// `0xEF` gets the same "look at the interfaces instead" treatment as `0x00`, the same
    /// reasoning `USBDeviceKind`'s own fallback rests on: it is the standard marker for a
    /// composite device, not a description of one. Left as `className` describing a BRIO
    /// as "Miscellaneous" while `kind` had already worked out "Webcam" from the same
    /// interfaces — the notification's title and its own body line for "Type" disagreeing
    /// about what it was.
    var className: String? {
        if let deviceClass, deviceClass != 0x00, deviceClass != 0xEF {
            return Self.name(forClassByte: deviceClass)
        }
        let interfaceNames = interfaceClasses.compactMap(Self.name(forClassByte:))
        // Matches `USBDeviceKind`'s own priority exactly — a device genuinely both, then
        // video alone, then whatever else — so this line and the notification's title
        // never again disagree about what a composite device is, which is the mismatch
        // this whole fallback exists to prevent.
        if interfaceNames.contains("Video") && interfaceNames.contains("Audio") {
            return "Audio/Video"
        }
        if let name = interfaceNames.first(where: { $0 == "Video" }) ?? interfaceNames.first {
            return name
        }
        // Nothing recognised on the interfaces either: for 0xEF, naming "more than one
        // function" is at least honest, and better than falling silent about it.
        return deviceClass.flatMap(Self.name(forClassByte:))
    }

    private static func name(forClassByte deviceClass: UInt8) -> String? {
        switch deviceClass {
        case 0x01: return "Audio"
        case 0x02: return "Communications"
        case 0x03: return "HID (Keyboard/Mouse)"
        case 0x05: return "Physical"
        case 0x06: return "Still Imaging"
        case 0x07: return "Printer"
        case 0x08: return "Mass Storage"
        case 0x09: return "Hub"
        case 0x0A: return "CDC Data"
        case 0x0B: return "Smart Card"
        case 0x0D: return "Content Security"
        case 0x0E: return "Video"
        case 0x0F: return "Personal Healthcare"
        case 0x10: return "Audio/Video"
        case 0x11: return "Billboard"
        case 0x12: return "USB Type-C Bridge"
        case 0xDC: return "Diagnostic"
        case 0xE0: return "Wireless Controller"
        case 0xEF: return "Miscellaneous"
        case 0xFE: return "Application Specific"
        case 0xFF: return "Vendor Specific"
        default: return nil
        }
    }
}

/// What a USB device says about itself beyond its name and class.
public struct USBDeviceDetail: Sendable, Equatable {
    public let productName: String?
    public let vendorID: UInt16?
    public let productID: UInt16?
    /// The `Device Speed` the registry reports, 0-5.
    public let speedCode: UInt8?
    /// Milliamps the device asks for, and what the port has to give.
    public let requiredCurrent: Int?
    public let availableCurrent: Int?
    /// Whether the port refused the request outright.
    public let requestedMoreThanAvailable: Bool
    /// "Solid State" or "Rotational", for mass storage.
    public let mediumType: String?
    /// A flash drive or an SD card reader, read heuristically off the disk itself — see
    /// `USBMassStorageHint`. Nil for every device that is not Mass Storage, and for a Mass
    /// Storage device the heuristic did not recognise (most often a disk enclosure).
    public let massStorageHint: USBMassStorageHint?
    public let serialNumber: String?
    /// The device release number, as major and minor halves of a BCD word.
    public let releaseVersion: UInt16?
    public let locationID: UInt32?
    public let configurationCount: Int?
    /// The USB spec revision, also BCD — 0x0320 is USB 3.2.
    public let specVersion: UInt16?
    /// Arrived over a Thunderbolt/USB4 tunnel rather than a real USB port.
    public let isTunnelled: Bool
    public let isPortRemovable: Bool?
    /// The connector type code the port reports — 0 is Type-A, 3 is Type-C.
    public let connectorType: Int?

    /// A copy with only the mass-storage hint changed — for the arrival-time retry that
    /// re-reads a Mass Storage device once its BSD name/disk description has had time to
    /// attach, without having to repeat or guess at every other field already read.
    func withMassStorageHint(_ hint: USBMassStorageHint?) -> USBDeviceDetail {
        USBDeviceDetail(
            productName: productName, vendorID: vendorID, productID: productID,
            speedCode: speedCode, requiredCurrent: requiredCurrent, availableCurrent: availableCurrent,
            requestedMoreThanAvailable: requestedMoreThanAvailable, mediumType: mediumType,
            massStorageHint: hint, serialNumber: serialNumber, releaseVersion: releaseVersion,
            locationID: locationID, configurationCount: configurationCount, specVersion: specVersion,
            isTunnelled: isTunnelled, isPortRemovable: isPortRemovable, connectorType: connectorType
        )
    }

    /// A copy with only the storage medium changed — for departure falling back to what
    /// arrival already found, the same reasoning `withMassStorageHint` rests on.
    func withMediumType(_ medium: String?) -> USBDeviceDetail {
        USBDeviceDetail(
            productName: productName, vendorID: vendorID, productID: productID,
            speedCode: speedCode, requiredCurrent: requiredCurrent, availableCurrent: availableCurrent,
            requestedMoreThanAvailable: requestedMoreThanAvailable, mediumType: medium,
            massStorageHint: massStorageHint, serialNumber: serialNumber, releaseVersion: releaseVersion,
            locationID: locationID, configurationCount: configurationCount, specVersion: specVersion,
            isTunnelled: isTunnelled, isPortRemovable: isPortRemovable, connectorType: connectorType
        )
    }

    public init(
        productName: String? = nil,
        vendorID: UInt16? = nil,
        productID: UInt16? = nil,
        speedCode: UInt8? = nil,
        requiredCurrent: Int? = nil,
        availableCurrent: Int? = nil,
        requestedMoreThanAvailable: Bool = false,
        mediumType: String? = nil,
        massStorageHint: USBMassStorageHint? = nil,
        serialNumber: String? = nil,
        releaseVersion: UInt16? = nil,
        locationID: UInt32? = nil,
        configurationCount: Int? = nil,
        specVersion: UInt16? = nil,
        isTunnelled: Bool = false,
        isPortRemovable: Bool? = nil,
        connectorType: Int? = nil
    ) {
        self.productName = productName
        self.vendorID = vendorID
        self.productID = productID
        self.speedCode = speedCode
        self.requiredCurrent = requiredCurrent
        self.availableCurrent = availableCurrent
        self.requestedMoreThanAvailable = requestedMoreThanAvailable
        self.mediumType = mediumType
        self.massStorageHint = massStorageHint
        self.serialNumber = serialNumber
        self.releaseVersion = releaseVersion
        self.locationID = locationID
        self.configurationCount = configurationCount
        self.specVersion = specVersion
        self.isTunnelled = isTunnelled
        self.isPortRemovable = isPortRemovable
        self.connectorType = connectorType
    }

    var vidPidNote: String? {
        guard let vendorID, let productID else { return nil }
        return String(format: "%04X:%04X", vendorID, productID)
    }

    /// The speed as a generation people recognise rather than a bare number.
    var speedNote: String? {
        switch speedCode {
        case 0: return "USB 1.0 (Low Speed)"
        case 1: return "USB 1.1 (Full Speed)"
        case 2: return "USB 2.0 (High Speed)"
        case 3: return "USB 3.0/3.1 (SuperSpeed)"
        case 4: return "USB 3.2 (SuperSpeed+, 10 Gb/s)"
        case 5: return "USB 3.2 Gen 2x2 (SuperSpeed+, 20 Gb/s)"
        default: return nil
        }
    }

    /// What it wants against what the port has, with a warning when that does not add up.
    ///
    /// The warning is the reason this line is on by default: a device drawing more than
    /// its port can give is the explanation for a drive that keeps dropping out, and
    /// nothing else in macOS says so.
    var powerNote: String? {
        guard let requiredCurrent else { return nil }
        guard let availableCurrent else { return "\(requiredCurrent)mA" }

        let base = "\(requiredCurrent)mA / \(availableCurrent)mA available"
        return requiredCurrent > availableCurrent ? "\(base) ⚠️ exceeds available" : base
    }

    /// Whether the disk inside spins, which is what decides how it should be treated.
    var mediumNote: String? {
        switch mediumType {
        case "Solid State": return "SSD / Flash"
        case "Rotational": return "HDD (rotational)"
        default: return nil
        }
    }

    /// A BCD version word, decoded a nibble at a time: 0x0320 is 3.20.
    ///
    /// Each nibble is one decimal digit, which is the whole point of binary-coded decimal.
    /// Reading the low byte as an ordinary number instead gives 0x20 = 32, so USB 3.2
    /// comes out as "3.32" — a mistake the original makes and this deliberately does not.
    static func describeBCD(_ value: UInt16) -> String {
        let major = (value >> 12) * 10 + ((value >> 8) & 0xF)
        let minorTens = (value >> 4) & 0xF
        let minorUnits = value & 0xF
        return "\(major).\(minorTens)\(minorUnits)"
    }

    var firmwareNote: String? { releaseVersion.map(Self.describeBCD) }
    var specVersionNote: String? { specVersion.map(Self.describeBCD) }
    var locationNote: String? { locationID.map { String(format: "0x%08X", $0) } }
    var configurationsNote: String? { configurationCount.map(String.init) }
    var tunnelNote: String? { isTunnelled ? "USB4/Thunderbolt tunnel" : nil }

    /// Only ever shown when the port refused: telling somebody their device got the power
    /// it asked for is not news.
    var failedPowerNote: String? {
        requestedMoreThanAvailable ? "⚠️ Device requested more power than the port could provide" : nil
    }

    /// Whether the port is one you can reach, and what shape it is.
    var portNote: String? {
        var parts: [String] = []
        if let isPortRemovable { parts.append(isPortRemovable ? "removable" : "built-in") }
        if let connectorType { parts.append("connector type code \(connectorType)") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The manufacturer and the product name together, which is how the original reads —
    /// either alone is half an answer.
    func manufacturerNote(vendorName: String?) -> String? {
        let parts = [vendorName, productName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
