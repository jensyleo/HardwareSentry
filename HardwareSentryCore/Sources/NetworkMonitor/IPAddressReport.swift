import Foundation

/// One interface's addresses at a moment in time.
public struct InterfaceAddresses: Sendable, Equatable {
    public let bsdName: String
    /// The name a person would recognise from System Settings — "Wi-Fi", "Thunderbolt
    /// Bridge" — falling back to the BSD name when the system has no friendlier one.
    public let friendlyName: String?
    /// IPv4 addresses with their prefix length — "192.168.1.42/24". The mask is what says
    /// how big the network is, which is half of what an address means.
    public let ipv4: [String]
    public let ipv6: [String]
    /// The router this interface sends everything else through.
    public let gateway: String?
    /// "DHCP", "Manual", "BOOTP" — how the address was arrived at. Worth knowing when an
    /// address is not what you expected: a manual one will not change on its own.
    public let configurationMethod: String?
    /// The largest packet the interface will carry.
    public let mtu: Int?
    /// The interface's own hardware address.
    public let macAddress: String?
    /// When the DHCP lease started, when it runs out, and which server granted it.
    public let dhcpLease: String?
    /// The line rate the kernel reports, for interfaces that have no Ethernet media to
    /// describe — a modem or a tunnel, where "1000baseT" would mean nothing.
    public let baudrate: Int?
    /// "Ethernet", "IEEE80211", "Loopback" — the kernel's own name for the interface type,
    /// which is a different fact from the friendly name and from the media.
    public let decodedType: String?

    public init(
        bsdName: String,
        friendlyName: String? = nil,
        ipv4: [String] = [],
        ipv6: [String] = [],
        gateway: String? = nil,
        configurationMethod: String? = nil,
        mtu: Int? = nil,
        macAddress: String? = nil,
        dhcpLease: String? = nil,
        baudrate: Int? = nil,
        decodedType: String? = nil
    ) {
        self.bsdName = bsdName
        self.friendlyName = friendlyName
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.gateway = gateway
        self.configurationMethod = configurationMethod
        self.mtu = mtu
        self.macAddress = macAddress
        self.dhcpLease = dhcpLease
        self.baudrate = baudrate
        self.decodedType = decodedType
    }

    var displayName: String { friendlyName ?? bsdName }
}

/// Every address the machine currently holds, turned into the one message that describes
/// them.
///
/// One notification for the whole machine rather than one per interface: addresses arrive
/// together — DHCP finishing hands out an IPv4 and one or more IPv6 addresses in the same
/// breath — and a separate banner for each would be the same event told four times.
public struct IPAddressReport: Sendable, Equatable {
    public let interfaces: [InterfaceAddresses]
    /// The suffixes the resolver appends to a bare name. Machine-wide, not per interface,
    /// so it appears once at the end rather than repeated under each.
    public let dnsSearchDomains: [String]

    public init(interfaces: [InterfaceAddresses], dnsSearchDomains: [String] = []) {
        self.interfaces = interfaces
        self.dnsSearchDomains = dnsSearchDomains
    }

    /// Whether the machine holds any address at all right now.
    public var hasAddresses: Bool {
        interfaces.contains { !$0.ipv4.isEmpty || !$0.ipv6.isEmpty }
    }

    /// Whether any address can actually reach the wider network, as opposed to the
    /// self-assigned 169.254.x.x an interface falls back to when DHCP never answered.
    /// A machine holding only those has an address and no connection, and the message
    /// should not look like success.
    public var hasRoutableAddress: Bool {
        interfaces.contains { interface in
            interface.ipv4.contains { !Self.isSelfAssigned($0) }
                || interface.ipv6.contains { !Self.isLinkLocalV6($0) }
        }
    }

    static func isSelfAssigned(_ address: String) -> Bool {
        address.hasPrefix("169.254.")
    }

    static func isLinkLocalV6(_ address: String) -> Bool {
        address.lowercased().hasPrefix("fe80:")
    }

    /// The body of the notification, one line per address.
    ///
    /// Sorted by interface name so the same machine reads the same way every time — the
    /// order `getifaddrs` returns them in is not stable enough to show to a person, and an
    /// unstable order would make an unchanged message look changed.
    /// Which of the per-interface extras to include, so the caller's preferences decide
    /// rather than this deciding for them.
    public struct Detail: Sendable, Equatable {
        public var ipv6 = true
        /// IPv4 addresses. Switchable like the rest — a Mac on an IPv6-only network has
        /// nothing to say here, and somebody who only cares about IPv6 should be able to
        /// say so.
        public var ipv4 = true
        /// The note that marks a 169.254 address as one macOS gave itself when nothing
        /// answered. Without it the address looks like any other, which is the one case
        /// where "you have an address" is misleading rather than reassuring.
        public var nonRoutableTag = true
        /// "Wi-Fi" and "USB 10/100/1000 LAN" rather than "en0" and "en5".
        public var friendlyNames = true
        public var gateway = false
        public var configurationMethod = false
        public var mtu = false
        public var macAddress = false
        public var searchDomains = false
        /// The address an interface used to hold, when it has just changed.
        public var previousAddress = false
        public var dhcpLease = false
        public var baudrate = false
        public var decodedType = false

        public init() {}
    }

    public func body(detail: Detail = Detail(), previous: IPAddressReport? = nil) -> String {
        var lines: [String] = []

        for interface in interfaces.sorted(by: { $0.bsdName < $1.bsdName }) {
            let before = previous?.interfaces.first { $0.bsdName == interface.bsdName }
            let name = detail.friendlyNames ? interface.displayName : interface.bsdName

            for address in interface.ipv4.sorted() where detail.ipv4 {
                let tag = detail.nonRoutableTag && Self.isSelfAssigned(address) ? "  (self-assigned)" : ""
                // Only the case where exactly one address replaced exactly one other:
                // "192.168.1.5 → 192.168.1.9" is useful, while pairing up two arbitrary
                // lists would be guessing at which replaced which.
                if detail.previousAddress,
                   let was = before?.ipv4.sorted(), was.count == 1, interface.ipv4.count == 1,
                   was[0] != address {
                    lines.append("\(name) — IPv4:\t\(was[0]) → \(address)\(tag)")
                } else {
                    lines.append("\(name) — IPv4:\t\(address)\(tag)")
                }
            }

            if detail.ipv6 {
                for address in interface.ipv6.sorted() {
                    lines.append("\(name) — IPv6:\t\(address)")
                }
            }

            // The per-interface extras sit under the addresses they describe, and only
            // for interfaces that actually have one — an interface with no address has
            // nothing worth saying about its gateway.
            guard !interface.ipv4.isEmpty || !interface.ipv6.isEmpty else { continue }
            if detail.gateway, let gateway = interface.gateway {
                lines.append("Gateway:\t\(gateway)")
            }
            if detail.configurationMethod, let method = interface.configurationMethod {
                lines.append("IP config method:\t\(method)")
            }
            if detail.mtu, let mtu = interface.mtu {
                lines.append("MTU:\t\(mtu)")
            }
            if detail.macAddress, let mac = interface.macAddress {
                lines.append("MAC address:\t\(mac)")
            }
            if detail.decodedType, let type = interface.decodedType {
                lines.append("Interface type:\t\(type)")
            }
            if detail.dhcpLease, let lease = interface.dhcpLease {
                lines.append("DHCP lease:\t\(lease)")
            }
            // Only for interfaces with no media to describe: on an Ethernet port the
            // Speed line already says it better, and two answers to one question is
            // worse than one.
            if detail.baudrate, let baudrate = interface.baudrate, interface.decodedType != "Ethernet" {
                lines.append("Baudrate:\t\(baudrate) bps")
            }
        }

        if detail.searchDomains, !dnsSearchDomains.isEmpty {
            lines.append("DNS search domains:\t\(dnsSearchDomains.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}
