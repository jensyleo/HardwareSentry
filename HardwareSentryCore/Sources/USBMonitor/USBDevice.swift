import Foundation

/// A USB device, as much of one as is worth telling someone about.
public struct USBDevice: Sendable, Equatable {
    public let name: String
    public let vendorName: String?
    public let isHub: Bool
    /// The USB-IF `bDeviceClass` byte. `0x00` means "look at the interfaces instead", so a
    /// device saying that has told us nothing about what it is.
    public let deviceClass: UInt8?

    /// Everything else the device says about itself.
    public let detail: USBDeviceDetail

    public init(
        name: String,
        vendorName: String? = nil,
        isHub: Bool = false,
        deviceClass: UInt8? = nil,
        detail: USBDeviceDetail = USBDeviceDetail()
    ) {
        self.name = name
        self.vendorName = vendorName
        self.isHub = isHub
        self.deviceClass = deviceClass
        self.detail = detail
    }

    /// The artwork for what this device says it is, or nil when it has not said anything
    /// specific — most USB devices declare their class per-interface rather than on the
    /// device, so falling back to the plain USB icon is the common case, not a failure.
    public var iconBaseName: String? {
        if isHub { return "USB-TypeHub" }
        switch deviceClass {
        case 0x01: return "USB-TypeAudio"
        case 0x03: return "USB-TypeHID"
        case 0x06: return "USB-TypeScanner"
        case 0x07: return "USB-TypePrinter"
        // Mass storage borrows the disk artwork rather than the generic USB glyph: a
        // flash drive is a disk, and that is what somebody expects to see.
        case 0x08: return "Device-USBDrive"
        case 0x09: return "USB-TypeHub"
        case 0x0B: return "USB-TypeSmartCard"
        case 0x0E: return "USB-TypeWebcam"
        case 0x0F: return "USB-TypeHealthcare"
        case 0x10: return "USB-TypeAudioVideo"
        case 0x12: return "USB-TypeTypeCBridge"
        case 0xE0: return "USB-TypeWireless"
        default: return nil
        }
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
        return base == "Device-USBDrive" ? "Device-USBDrive-Unmounted" : "\(base)-Disconnected"
    }
}

public extension USBDevice {
    /// What the device says it is, in words — "Mass Storage", "HID (Keyboard/Mouse)".
    ///
    /// The USB-IF's published base class codes. Nil for `0x00`, which means the device
    /// declares its class per-interface rather than on itself: that is the common case,
    /// not an error, and there is nothing useful to say about it.
    var className: String? {
        guard let deviceClass else { return nil }
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

    public init(
        productName: String? = nil,
        vendorID: UInt16? = nil,
        productID: UInt16? = nil,
        speedCode: UInt8? = nil,
        requiredCurrent: Int? = nil,
        availableCurrent: Int? = nil,
        requestedMoreThanAvailable: Bool = false,
        mediumType: String? = nil,
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
