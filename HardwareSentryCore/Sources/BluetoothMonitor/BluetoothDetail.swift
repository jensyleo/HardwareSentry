import Foundation

/// What a classic Bluetooth device could be described as when it connected.
///
/// Everything here comes from public `IOBluetoothDevice` API. The parts of HG4MAC's list
/// that need undocumented selectors (accessory battery) or hand-parsing of SDP attribute
/// records (VID:PID, HFP features, HID country code) are deliberately absent rather than
/// half-done — see the pendings document.
public struct BluetoothDetail: Sendable, Equatable {
    /// What the device says it is, from its Class of Device record.
    public let kind: BluetoothDeviceKind?
    /// The hardware address, as `00-11-22-33-44-55`.
    public let address: String?
    public let isPaired: Bool
    /// Signal strength in dBm, as reported at the moment of connection.
    public let rssi: Int?
    /// "ACL", "SCO", "eSCO" — the kind of radio link, which is what tells a data
    /// connection apart from a voice one on the same headset.
    public let linkType: String?
    /// Whether the device reached out to this Mac, rather than the other way round.
    public let isIncoming: Bool
    /// The Bluetooth profiles it advertises — "Handsfree", "A2DP Sink", and so on.
    public let services: String?
    /// Marked as a favourite in the system's own Bluetooth settings.
    public let isFavorite: Bool
    /// When it was last used, for a device that has been seen before.
    public let lastSeen: Date?

    public init(
        kind: BluetoothDeviceKind? = nil,
        address: String? = nil,
        isPaired: Bool = false,
        rssi: Int? = nil,
        linkType: String? = nil,
        isIncoming: Bool = false,
        services: String? = nil,
        isFavorite: Bool = false,
        lastSeen: Date? = nil
    ) {
        self.kind = kind
        self.address = address
        self.isPaired = isPaired
        self.rssi = rssi
        self.linkType = linkType
        self.isIncoming = isIncoming
        self.services = services
        self.isFavorite = isFavorite
        self.lastSeen = lastSeen
    }

    var kindNote: String? { kind?.label }

    /// Reported with its unit, because a bare "-58" is not obviously a signal strength,
    /// and with the plain-words strength alongside, because most people do not read dBm.
    var rssiNote: String? {
        guard let rssi, rssi != 0 else { return nil }
        return "\(rssi) dBm (\(Self.strength(rssi)))"
    }

    /// Present-only, the same rule the other monitors' capability lines follow.
    var favoriteNote: String? { isFavorite ? "Yes" : nil }

    /// Said in full both ways: unlike a capability, which of the two reached out first is
    /// genuinely news either way — an accessory waking up on its own and this Mac
    /// deciding to connect are different things.
    var initiatorNote: String { isIncoming ? "The device" : "This Mac" }

    var pairedNote: String { isPaired ? "Yes" : "No" }

    static func strength(_ rssi: Int) -> String {
        switch rssi {
        case (-60)...: return "excellent"
        case (-70)..<(-60): return "good"
        case (-80)..<(-70): return "fair"
        default: return "weak"
        }
    }
}

/// The optional details this monitor can add.
public enum BluetoothField: String, CaseIterable {
    case kind = "Type"
    case address = "Address"
    case paired = "Paired"
    case signal = "Signal"
    case linkType = "LinkType"
    case initiator = "Initiator"
    case services = "Services"
    case favorite = "Favorite"
    case lastSeen = "LastSeen"

    /// How the line is named in Settings → Events, under "Include in the message".
    var settingsTitle: String {
        switch self {
        case .kind: return "What kind of device it is"
        case .address: return "Hardware address"
        case .paired: return "Whether it is paired"
        case .signal: return "Signal strength"
        case .linkType: return "Kind of radio link"
        case .initiator: return "Which side connected"
        case .services: return "Bluetooth profiles it offers"
        case .favorite: return "Marked as a favourite"
        case .lastSeen: return "When it was last used"
        }
    }

    /// The kind of device is on because it is the one line that turns "Bluetooth
    /// Connection: WH-1000XM4" into something you can read without knowing your own
    /// gadgets by model number. The rest are for people who want them.
    var shownByDefault: Bool { self == .kind }
}

public extension BluetoothDeviceKind {
    /// The device kind in ordinary words, for the body of a message.
    var label: String {
        switch self {
        case .computer: return "Computer"
        case .phone: return "Phone"
        case .accessPoint: return "Access point"
        case .wearable: return "Wearable"
        case .health: return "Health device"
        case .keyboard: return "Keyboard"
        case .mouse: return "Mouse"
        case .combo: return "Keyboard and mouse"
        case .headset: return "Headset"
        case .microphone: return "Microphone"
        case .speaker: return "Speaker"
        case .headphones: return "Headphones"
        }
    }
}
