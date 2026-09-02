import Foundation

/// What the Wi-Fi interface said about the network it just joined.
public struct WiFiDetail: Sendable, Equatable {
    /// The access point's hardware address. Absent unless this app has been granted
    /// Location access — macOS treats a BSSID as a location, because it is one. This app
    /// does not ask for that permission, so in practice this line is usually empty; it is
    /// offered rather than removed so it works for anyone who grants it by hand.
    public let bssid: String?
    /// "5 GHz, channel 44 (80 MHz)".
    public let channel: String?
    /// "Wi-Fi 6 (802.11ax)" rather than the raw mode name.
    public let generation: String?
    public let security: String?
    /// Signal strength in dBm, with plain words alongside.
    public let rssi: Int?
    public let noise: Int?
    /// Negotiated rate in Mbps — what the link agreed to, not measured throughput.
    public let transmitRate: Double?
    public let countryCode: String?
    public let interfaceName: String?

    public init(
        bssid: String? = nil,
        channel: String? = nil,
        generation: String? = nil,
        security: String? = nil,
        rssi: Int? = nil,
        noise: Int? = nil,
        transmitRate: Double? = nil,
        countryCode: String? = nil,
        interfaceName: String? = nil
    ) {
        self.bssid = bssid
        self.channel = channel
        self.generation = generation
        self.security = security
        self.rssi = rssi
        self.noise = noise
        self.transmitRate = transmitRate
        self.countryCode = countryCode
        self.interfaceName = interfaceName
    }

    var rssiNote: String? {
        guard let rssi, rssi != 0 else { return nil }
        return "\(rssi) dBm (\(Self.strength(rssi)))"
    }

    /// Signal minus noise: the number that actually predicts whether the connection will
    /// be any good, and the one neither figure gives on its own.
    var qualityNote: String? {
        guard let rssi, let noise, rssi != 0, noise != 0 else { return nil }
        return "\(rssi - noise) dB signal-to-noise"
    }

    var rateNote: String? {
        // A rate of zero means the interface had not settled yet, not a dead link.
        guard let transmitRate, transmitRate > 0 else { return nil }
        return String(format: "%.0f Mbps", transmitRate)
    }

    static func strength(_ rssi: Int) -> String {
        switch rssi {
        case (-50)...: return "excellent"
        case (-60)..<(-50): return "good"
        case (-70)..<(-60): return "fair"
        default: return "weak"
        }
    }
}

/// What the system's own view of the network path said, at the moment reachability
/// changed.
///
/// These are the fields HG4MAC reports as four separate notifications. Offered here as
/// lines on the reachability message instead: "the Internet came back, over cellular, on a
/// connection you pay for by the megabyte" is one piece of news, and three notifications
/// arriving together for one change is the thing this app exists to avoid.
public struct NetworkPathDetail: Sendable, Equatable {
    /// "Wi-Fi", "Wired", "Cellular" — whichever carries the path.
    public let interfaceType: String?
    /// A connection billed by usage — cellular, or a personal hotspot.
    public let isExpensive: Bool
    /// Low Data Mode is on for this path.
    public let isConstrained: Bool
    public let supportsIPv4: Bool
    public let supportsIPv6: Bool
    public let supportsDNS: Bool

    public init(
        interfaceType: String? = nil,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        supportsIPv4: Bool = false,
        supportsIPv6: Bool = false,
        supportsDNS: Bool = false
    ) {
        self.interfaceType = interfaceType
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.supportsDNS = supportsDNS
    }

    /// Present-only: an ordinary connection is the unremarkable case.
    var expensiveNote: String? { isExpensive ? "Yes — billed by usage" : nil }
    var constrainedNote: String? { isConstrained ? "Yes — Low Data Mode" : nil }

    /// The two protocols read as one line, since the interesting cases are "one of them is
    /// missing" and reporting each separately would spend two lines saying "both fine".
    var protocolsNote: String? {
        switch (supportsIPv4, supportsIPv6) {
        case (true, true): return "IPv4 and IPv6"
        case (true, false): return "IPv4 only"
        case (false, true): return "IPv6 only"
        case (false, false): return nil
        }
    }

    /// Only said when it is missing. A path that reaches the Internet but cannot resolve
    /// names looks exactly like a broken Internet to whoever is using it, and that is
    /// worth calling out; the working case is not.
    var dnsNote: String? { supportsDNS ? nil : "No DNS on this path" }
}

/// The optional details this monitor can add.
public enum NetworkField: String, CaseIterable {
    // Wi-Fi
    case bssid = "BSSID"
    case channel = "Channel"
    case generation = "WiFiGeneration"
    case security = "Security"
    case signal = "Signal"
    case quality = "SignalQuality"
    case transmitRate = "TransmitRate"
    case countryCode = "CountryCode"
    case wifiInterface = "WiFiInterface"
    // Reachability
    case pathInterface = "PathInterface"
    case expensive = "Expensive"
    case constrained = "Constrained"
    case ipProtocols = "IPProtocols"
    case dns = "DNS"
    // Wired links
    case linkSpeed = "Speed"
    case linkMode = "Mode"
    case linkNegotiated = "Negotiated"
    // IP addresses
    case ipv6 = "IPv6"

    /// How the line is named in Settings → Events, under "Include in the message".
    var settingsTitle: String {
        switch self {
        case .bssid: return "Access point address (needs Location access)"
        case .channel: return "Band and channel"
        case .generation: return "Wi-Fi generation"
        case .security: return "Security"
        case .signal: return "Signal strength"
        case .quality: return "Signal-to-noise"
        case .transmitRate: return "Negotiated rate"
        case .countryCode: return "Country code"
        case .wifiInterface: return "Which Wi-Fi interface"
        case .pathInterface: return "Which connection carries the traffic"
        case .expensive: return "Connection is billed by usage"
        case .constrained: return "Low Data Mode is on"
        case .ipProtocols: return "IPv4 / IPv6"
        case .dns: return "Warn when the path has no DNS"
        case .linkSpeed: return "Negotiated speed"
        case .linkMode: return "Duplex mode"
        case .linkNegotiated: return "Warn when slower than the port supports"
        case .ipv6: return "Include IPv6 addresses"
        }
    }

    /// Three on by default. Signal and channel are what someone joining a network wants to
    /// know; the DNS warning is on because it only ever appears when something is wrong,
    /// so it costs nothing when everything works.
    var shownByDefault: Bool {
        [.signal, .channel, .dns, .ipv6, .linkSpeed, .linkMode].contains(self)
    }
}
