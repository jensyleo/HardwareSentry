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
    /// How full the accessory's battery is, for the Apple accessories macOS publishes it
    /// for. Nil for everything else, which is most Bluetooth devices.
    public let batteryPercent: Int?
    /// The three levels an accessory with separate earpieces and a case reports.
    public let multipartBattery: BluetoothAccessoryBattery.MultipartLevel?
    /// "Encrypted (AES-CCM)", "Not encrypted" — whether the link itself is protected.
    public let encryption: String?
    /// The broad things the device's Class of Device record claims it does: "Audio",
    /// "Rendering", "Telephony".
    public let serviceClasses: String?
    /// Vendor and product identifiers from the device's own PnP record.
    public let vendorID: Int?
    public let productID: Int?
    public let productVersion: String?
    /// Which registry the vendor ID belongs to — the two are numbered separately, so the
    /// same number means two different companies depending on which.
    public let vendorIDSource: String?
    /// What a hands-free device says it can do — "Voice recognition, Wideband speech".
    public let handsFreeFeatures: String?
    /// A keyboard or mouse's own description of itself, from its HID record.
    public let hidDetail: String?
    /// The radio's own numbers for this link, for when a connection is misbehaving.
    public let linkQuality: Int?
    public let transmitPower: Int?

    public init(
        kind: BluetoothDeviceKind? = nil,
        address: String? = nil,
        isPaired: Bool = false,
        rssi: Int? = nil,
        linkType: String? = nil,
        isIncoming: Bool = false,
        services: String? = nil,
        isFavorite: Bool = false,
        lastSeen: Date? = nil,
        batteryPercent: Int? = nil,
        multipartBattery: BluetoothAccessoryBattery.MultipartLevel? = nil,
        encryption: String? = nil,
        serviceClasses: String? = nil,
        vendorID: Int? = nil,
        productID: Int? = nil,
        productVersion: String? = nil,
        vendorIDSource: String? = nil,
        handsFreeFeatures: String? = nil,
        hidDetail: String? = nil,
        linkQuality: Int? = nil,
        transmitPower: Int? = nil
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
        self.batteryPercent = batteryPercent
        self.multipartBattery = multipartBattery
        self.encryption = encryption
        self.serviceClasses = serviceClasses
        self.vendorID = vendorID
        self.productID = productID
        self.productVersion = productVersion
        self.vendorIDSource = vendorIDSource
        self.handsFreeFeatures = handsFreeFeatures
        self.hidDetail = hidDetail
        self.linkQuality = linkQuality
        self.transmitPower = transmitPower
    }

    /// One figure when the accessory has one battery, three when it has three.
    ///
    /// The single figure wins where both exist: a device that publishes a level the
    /// supported way is better read that way, and the split reading is for the accessories
    /// that publish nothing else.
    var batteryNote: String? {
        if let batteryPercent { return "\(batteryPercent)%" }
        return multipartBattery?.note
    }

    /// Vendor, product and version as one line, in hex as well as decimal because that is
    /// how every specification sheet and every other tool prints them.
    var identityNote: String? {
        guard let vendorID, let productID else { return nil }
        var note = String(format: "VID 0x%04X / PID 0x%04X", vendorID, productID)
        if let productVersion { note += " v\(productVersion)" }
        // Only when it is known: the Bluetooth SIG and the USB-IF number vendors
        // separately, so the same figure means two different companies depending on
        // which registry it came from.
        if let vendorIDSource { note += " (\(vendorIDSource))" }
        return note
    }

    /// The two radio numbers together, since neither means much alone.
    var linkDiagnosticsNote: String? {
        var parts: [String] = []
        if let linkQuality { parts.append("Quality \(linkQuality)/255") }
        if let transmitPower { parts.append("Tx \(transmitPower) dBm") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var kindNote: String? { kind?.label }

    /// Reported with its unit, because a bare "-58" is not obviously a signal strength,
    /// and with the plain-words strength alongside, because most people do not read dBm.
    /// "-62 dBm (3/4)", the original's wording.
    ///
    /// Zero is reported, not suppressed. That guard was copied from the Wi-Fi detail,
    /// where zero means the interface declined to answer — but classic Bluetooth reports
    /// RSSI against its golden receive range, so zero means "comfortably inside it", which
    /// is a real reading and a good one. Suppressing it is why a Magic Keyboard and a
    /// Magic Mouse showed no signal line here while the original showed "0 dBm (4/4)".
    /// The sentinel to refuse is 127.
    var rssiNote: String? {
        guard let rssi, let level = BluetoothSignalLevel(rssi: rssi) else { return nil }
        return "\(rssi) dBm (\(level.rawValue)/4)"
    }

    /// Present-only, the same rule the other monitors' capability lines follow.
    var favoriteNote: String? { isFavorite ? "Yes" : nil }

    /// Said in full both ways: unlike a capability, which of the two reached out first is
    /// genuinely news either way — an accessory waking up on its own and this Mac
    /// deciding to connect are different things.
    var initiatorNote: String { isIncoming ? "The device" : "This Mac" }

    var pairedNote: String { isPaired ? "Yes" : "No" }

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
    case battery = "Battery"
    case encryption = "Encryption"
    case serviceClass = "ServiceClass"
    case identity = "Identity"
    case handsFree = "HandsFree"
    case hidDetail = "HIDDetail"
    case linkDiagnostics = "LinkDiagnostics"

    /// How the line is named in Settings → Events, under "Include in the message".
    var settingsTitle: String {
        switch self {
        case .kind: return "Device type (Keyboard, Mouse, Headphones…)"
        case .address: return "MAC address"
        case .paired: return "Paired state"
        case .signal: return "Signal strength (RSSI, while connected)"
        case .linkType: return "Link type (ACL/SCO/eSCO)"
        case .initiator: return "Who initiated the connection"
        case .services: return "Advertised services (SDP)"
        case .favorite: return "Favourite flag"
        case .lastSeen: return "Last used date"
        case .battery: return "Battery level (Apple accessories: AirPods, Magic Mouse/Keyboard/Trackpad)"
        case .encryption: return "Link encryption state"
        case .serviceClass: return "Service class bits (Audio/Telephony/Rendering/etc.)"
        case .identity: return "Device ID (VID/PID/version, via SDP)"
        case .handsFree: return "Hands-Free supported features (via SDP)"
        case .hidDetail: return "HID detail: country code, remote wake (via SDP)"
        case .linkDiagnostics: return "Link diagnostics (quality, transmit power)"
        }
    }

    /// Two on. The kind of device is the one line that turns "Bluetooth Connection:
    /// WH-1000XM4" into something you can read without knowing your own gadgets by model
    /// number; the signal is on because it is the answer to "why does this keep cutting
    /// out", and the original has it on too. The rest are for people who want them.
    var shownByDefault: Bool {
        // The original's six: what kind of thing it is, whether it is paired, its
        // address, how much battery is left, how strong the link is, and what it says it
        // can do. The rest are for somebody diagnosing a specific accessory.
        [.kind, .paired, .address, .battery, .signal, .services].contains(self)
    }

    /// Which heading this line sits under, matching the event groups.
    var group: String {
        self == .signal ? BluetoothMonitor.Group.signal : BluetoothMonitor.Group.device
    }

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
        case .gamepad: return "Gamepad"
        case .remote: return "Remote control"
        case .tablet: return "Graphics tablet"
        case .cardReader: return "Card reader"
        case .barcodeScanner: return "Handheld scanner"
        case .sensor: return "Sensor"
        }
    }
}
