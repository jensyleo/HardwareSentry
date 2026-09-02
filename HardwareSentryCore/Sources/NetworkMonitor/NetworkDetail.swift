import Foundation

/// What the Wi-Fi interface said about the network it just joined.
public struct WiFiDetail: Sendable, Equatable {
    /// The access point's hardware address. Empty unless Location access has been
    /// granted — macOS treats a BSSID as a location, because it is one.
    public let bssid: String?
    /// "5 GHz" on its own. Kept apart from the channel because they answer different
    /// questions: the band is about interference and range, the channel about which slot
    /// inside it — and somebody watching for a 2.4 GHz fallback wants only the first.
    public let band: String?
    /// "channel 44 (80 MHz)".
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
    /// How hard the radio is transmitting, in dBm.
    public let transmitPower: Int?
    /// The Wi-Fi card's own hardware address, as distinct from the access point's.
    public let hardwareAddress: String?
    /// "Station (normal client)", "Host AP (Internet Sharing)", "Ad-hoc (IBSS)".
    public let interfaceMode: String?

    public init(
        bssid: String? = nil,
        band: String? = nil,
        channel: String? = nil,
        generation: String? = nil,
        security: String? = nil,
        rssi: Int? = nil,
        noise: Int? = nil,
        transmitRate: Double? = nil,
        countryCode: String? = nil,
        interfaceName: String? = nil,
        transmitPower: Int? = nil,
        hardwareAddress: String? = nil,
        interfaceMode: String? = nil
    ) {
        self.bssid = bssid
        self.band = band
        self.channel = channel
        self.generation = generation
        self.security = security
        self.rssi = rssi
        self.noise = noise
        self.transmitRate = transmitRate
        self.countryCode = countryCode
        self.interfaceName = interfaceName
        self.transmitPower = transmitPower
        self.hardwareAddress = hardwareAddress
        self.interfaceMode = interfaceMode
    }

    var transmitPowerNote: String? {
        // Zero is the interface declining to answer, not a radio that is silent.
        guard let transmitPower, transmitPower != 0 else { return nil }
        return "\(transmitPower) dBm"
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
/// Offered two ways, because they answer two questions. As lines on the reachability
/// message they describe the path at the moment connectivity moved — "the Internet came
/// back, over cellular, on a connection you pay for by the megabyte" is one piece of news.
/// As events of their own they report one of these moving while connectivity stays put,
/// which the reachability message would never mention. Both are off by default.
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
    /// Why the path cannot be used, when something is blocking it — cellular denied, VPN
    /// inactive. `NWPath` exposes usability only this way round, so a working path has
    /// nothing here rather than a made-up "Good".
    public let linkQuality: String?

    public init(
        interfaceType: String? = nil,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        supportsIPv4: Bool = false,
        supportsIPv6: Bool = false,
        supportsDNS: Bool = false,
        linkQuality: String? = nil
    ) {
        self.interfaceType = interfaceType
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.supportsDNS = supportsDNS
        self.linkQuality = linkQuality
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
    case band = "Band"
    case channel = "Channel"
    case generation = "WiFiGeneration"
    case security = "Security"
    case signal = "Signal"
    case quality = "SignalQuality"
    case transmitRate = "TransmitRate"
    case countryCode = "CountryCode"
    case wifiInterface = "WiFiInterface"
    case transmitPower = "TransmitPower"
    case wifiHardwareAddress = "WiFiHardwareAddress"
    case interfaceMode = "InterfaceMode"
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
    case gateway = "Gateway"
    case ipConfigMethod = "IPConfigMethod"
    case mtu = "MTU"
    case macAddress = "MACAddress"
    case dnsSearchDomains = "DNSSearchDomains"
    case previousAddress = "PreviousAddress"
    case dhcpLease = "DHCPLease"
    case baudrate = "Baudrate"
    case decodedType = "DecodedType"

    /// How the line is named in Settings → Events, under "Include in the message".
    var settingsTitle: String {
        switch self {
        case .bssid: return "Access point address (needs Location access)"
        case .band: return "Band (2.4/5/6 GHz)"
        case .channel: return "Channel number and width"
        case .generation: return "Wi-Fi generation"
        case .security: return "Security"
        case .signal: return "Signal strength"
        case .quality: return "Signal-to-noise"
        case .transmitRate: return "Negotiated rate"
        case .countryCode: return "Country code"
        case .wifiInterface: return "Which Wi-Fi interface"
        case .transmitPower: return "Transmit power"
        case .wifiHardwareAddress: return "Wi-Fi hardware address"
        case .interfaceMode: return "Interface mode (Station/IBSS/Host AP)"
        case .pathInterface: return "Which connection carries the traffic"
        case .expensive: return "Connection is billed by usage"
        case .constrained: return "Low Data Mode is on"
        case .ipProtocols: return "IPv4 / IPv6"
        case .dns: return "Warn when the path has no DNS"
        case .linkSpeed: return "Negotiated speed"
        case .linkMode: return "Duplex mode"
        case .linkNegotiated: return "Warn when slower than the port supports"
        case .ipv6: return "Include IPv6 addresses"
        case .gateway: return "Gateway"
        case .ipConfigMethod: return "How the address was assigned"
        case .mtu: return "MTU"
        case .macAddress: return "Hardware (MAC) address"
        case .dnsSearchDomains: return "DNS search domains"
        case .previousAddress: return "Show the address it replaced"
        case .dhcpLease: return "DHCP lease detail (start, expiry, server)"
        case .baudrate: return "Line rate (interfaces without Ethernet media)"
        case .decodedType: return "Decoded interface type"
        }
    }

    /// Three on by default. Signal and channel are what someone joining a network wants to
    /// know; the DNS warning is on because it only ever appears when something is wrong,
    /// so it costs nothing when everything works.
    var shownByDefault: Bool {
        [.signal, .band, .channel, .dns, .ipv6, .linkSpeed, .linkMode, .gateway, .previousAddress].contains(self)
    }
}
