import Foundation

/// What kind of thing a network interface actually is, as far as a person cares.
///
/// macOS surfaces dozens of BSD interface names that mean nothing to anyone reading a
/// notification — `awdl0` (AirDrop/Continuity's own back channel), `llw0`, `utun*`, `lo0` —
/// alongside the handful a person would recognise from System Settings. This is what tells
/// the two apart, and what an interface should look like when it does show up.
public enum NetworkInterfaceKind: String, Sendable, Equatable, CaseIterable {
    case wifi
    case wired
    /// A real, user-facing interface (Thunderbolt Bridge, a VPN service, a modem) that is
    /// neither Wi-Fi nor plain Ethernet — worth reporting, just not with either of those
    /// two icons.
    case other

    var label: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .wired: return "Wired"
        case .other: return "Network"
        }
    }

    func icon(active: Bool) -> String {
        switch self {
        case .wifi: return active ? "Network-Wifi-4" : "Network-Wifi-Off"
        case .wired, .other: return active ? "Network-Ethernet-On" : "Network-Ethernet-Off"
        }
    }

    /// Sorts a `kSCNetworkInterfaceType` constant into one of the three kinds above.
    ///
    /// A pure function of the type string, so it can be tested against every constant
    /// `SCNetworkInterfaceGetInterfaceType` can return without a real interface to ask.
    static func classify(scInterfaceType type: String) -> NetworkInterfaceKind {
        switch type {
        case "IEEE80211": return .wifi
        case "Ethernet", "Bond", "VLAN", "FireWire": return .wired
        default: return .other
        }
    }
}

/// One interface's link state at a moment in time.
public struct LinkState: Sendable, Equatable {
    public let isActive: Bool
    public let kind: NetworkInterfaceKind

    public init(isActive: Bool, kind: NetworkInterfaceKind) {
        self.isActive = isActive
        self.kind = kind
    }
}
