import SignalCore

/// What this monitor can tell you about.
///
/// Declared here rather than in a table somewhere central: a monitor owns its own events,
/// so gaining one is a change to this module and to nothing else.
public enum USBEvent: String, NotificationEventKey, CaseIterable {
    /// A device that did not say what it is — the generic row.
    case connected = "USBConnected"
    case disconnected = "USBDisconnected"
    // One row per device class, as the original has it.
    case connectedHub = "USBConnectedHub"
    case connectedMassStorage = "USBConnectedMassStorage"
    case connectedHID = "USBConnectedHID"
    case connectedWebcam = "USBConnectedWebcam"
    case connectedScanner = "USBConnectedScanner"
    case connectedPrinter = "USBConnectedPrinter"
    case connectedSmartCard = "USBConnectedSmartCard"
    case connectedAudio = "USBConnectedAudio"
    case connectedHealthcare = "USBConnectedHealthcare"
    case connectedAudioVideo = "USBConnectedAudioVideo"
    case connectedTypeCBridge = "USBConnectedTypeCBridge"
    case connectedWireless = "USBConnectedWireless"

    public static let category: NotificationCategory = "USB"
}

/// The optional details this monitor can add.
public enum USBField: String, CaseIterable {
    case vendor = "Vendor"
    case deviceClass = "Type"
    case vidPid = "VIDPID"
    case speed = "Speed"
    case power = "Power"
    case medium = "Medium"
    case serialNumber = "Serial"
    case firmwareVersion = "Firmware"
    case locationID = "LocationID"
    case configurations = "Configurations"
    case specVersion = "SpecVersion"
    case tunnel = "Tunnel"
    case failedPower = "FailedPower"
    case portInfo = "PortInfo"

    /// How the line is named in Settings → Events, under "Include in the message".
    var settingsTitle: String {
        switch self {
        case .vendor: return "Manufacturer / product name"
        case .deviceClass: return "Device class (Mass Storage, HID, Hub…)"
        case .vidPid: return "Vendor/product ID (VID:PID)"
        case .speed: return "USB speed / generation"
        case .power: return "Power draw (mA required vs. available)"
        case .medium: return "Storage medium (SSD/Flash vs. HDD, Mass Storage only)"
        case .serialNumber: return "Serial number"
        case .firmwareVersion: return "Firmware/release number"
        case .locationID: return "Port location ID"
        case .configurations: return "Number of USB configurations"
        case .specVersion: return "USB specification version (bcdUSB)"
        case .tunnel: return "USB4/Thunderbolt tunnel indicator"
        case .failedPower: return "Warn if device requested more power than the port could provide"
        case .portInfo: return "Port info (removable/built-in, connector type code)"
        }
    }

    /// The six the original shows without being asked. They describe what arrived and
    /// whether it will work; the rest are for somebody diagnosing a specific problem.
    var shownByDefault: Bool {
        // The original's nine. Serial and firmware are on there too, and the reason holds:
        // two identical drives on one desk are told apart by their serial and by nothing
        // else, and a firmware number is the first thing anybody is asked for when a
        // device misbehaves.
        [
            .vendor, .deviceClass, .vidPid, .speed, .power, .medium,
            .serialNumber, .firmwareVersion, .locationID
        ].contains(self)
    }
}
