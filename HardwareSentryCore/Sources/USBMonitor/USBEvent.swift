import SignalCore

/// What this monitor can tell you about.
///
/// Declared here rather than in a table somewhere central: a monitor owns its own events,
/// so gaining one is a change to this module and to nothing else.
public enum USBEvent: String, NotificationEventKey {
    case connected = "USBConnected"
    case disconnected = "USBDisconnected"

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
        case .vendor: return "Manufacturer and product name"
        case .deviceClass: return "What kind of device it is"
        case .vidPid: return "Vendor and product ID (VID:PID)"
        case .speed: return "USB speed and generation"
        case .power: return "Power draw against what the port offers"
        case .medium: return "Storage medium (SSD/flash or spinning disk)"
        case .serialNumber: return "Serial number"
        case .firmwareVersion: return "Firmware version"
        case .locationID: return "Port location ID"
        case .configurations: return "Number of USB configurations"
        case .specVersion: return "USB specification version"
        case .tunnel: return "Whether it arrived over a Thunderbolt tunnel"
        case .failedPower: return "Warn when the port could not supply the power asked for"
        case .portInfo: return "Port detail (removable or built-in, connector type)"
        }
    }

    /// The six the original shows without being asked. They describe what arrived and
    /// whether it will work; the rest are for somebody diagnosing a specific problem.
    var shownByDefault: Bool {
        [.vendor, .deviceClass, .vidPid, .speed, .power, .medium].contains(self)
    }
}
