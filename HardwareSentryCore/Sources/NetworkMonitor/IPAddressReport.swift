import Foundation

/// One interface's addresses at a moment in time.
public struct InterfaceAddresses: Sendable, Equatable {
    public let bsdName: String
    /// The name a person would recognise from System Settings — "Wi-Fi", "Thunderbolt
    /// Bridge" — falling back to the BSD name when the system has no friendlier one.
    public let friendlyName: String?
    public let ipv4: [String]
    public let ipv6: [String]

    public init(bsdName: String, friendlyName: String? = nil, ipv4: [String] = [], ipv6: [String] = []) {
        self.bsdName = bsdName
        self.friendlyName = friendlyName
        self.ipv4 = ipv4
        self.ipv6 = ipv6
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

    public init(interfaces: [InterfaceAddresses]) {
        self.interfaces = interfaces
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
    public func body(showIPv6: Bool = true) -> String {
        var lines: [String] = []
        for interface in interfaces.sorted(by: { $0.bsdName < $1.bsdName }) {
            for address in interface.ipv4.sorted() {
                let tag = Self.isSelfAssigned(address) ? "  (self-assigned)" : ""
                lines.append("\(interface.displayName) — IPv4:\t\(address)\(tag)")
            }
            guard showIPv6 else { continue }
            for address in interface.ipv6.sorted() {
                lines.append("\(interface.displayName) — IPv6:\t\(address)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
