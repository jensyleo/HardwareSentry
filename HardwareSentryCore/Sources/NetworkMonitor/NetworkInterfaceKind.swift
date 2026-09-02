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
    /// What a wired link negotiated. Nil for Wi-Fi and for anything that does not answer.
    public let media: LinkMedia?

    public init(isActive: Bool, kind: NetworkInterfaceKind, media: LinkMedia? = nil) {
        self.isActive = isActive
        self.kind = kind
        self.media = media
    }
}

/// Remembers what each interface was, so one that has already gone can still be described.
///
/// Exists because of a specific failure. Unplugging a USB-Ethernet adapter — or the dock it
/// lives in — tears the interface out of `SCNetworkInterfaceCopyAll` almost immediately,
/// often *before* its Link key changes. A live lookup at that moment finds nothing, the
/// disconnect is dropped, and the stale "was active" state then surfaces on the next
/// plug-in as a phantom disconnect followed by the real connect.
///
/// The live answer is always tried first, so a genuinely different device later reusing the
/// same BSD name is classified afresh. This is consulted only when the interface has
/// already vanished, which is exactly when the remembered answer is the right one.
public struct InterfaceKindCache: Sendable {
    private var remembered: [String: NetworkInterfaceKind] = [:]

    public init() {}

    /// Records what the live registry currently says, and returns the same set with
    /// anything it has forgotten filled back in.
    public mutating func reconcile(live: [String: NetworkInterfaceKind]) -> [String: NetworkInterfaceKind] {
        remembered.merge(live) { _, fresh in fresh }
        return remembered
    }

    /// Forgets an interface for good — used when it has been reported gone, so a BSD name
    /// reused by different hardware much later starts from nothing.
    public mutating func forget(_ bsdName: String) {
        remembered.removeValue(forKey: bsdName)
    }

    public func kind(of bsdName: String) -> NetworkInterfaceKind? {
        remembered[bsdName]
    }
}

/// Whether a BSD interface name is one of the tunnels macOS gives a VPN.
///
/// A heuristic, and named as one: there is no public API that says "this interface is a
/// VPN". These three prefixes are what macOS actually uses — `utun` for modern tunnels,
/// `ppp` for the older ones, `ipsec` for IKEv2 — and nothing else on a Mac uses them.
public func isVPNInterfaceName(_ bsdName: String) -> Bool {
    ["utun", "ppp", "ipsec"].contains { bsdName.hasPrefix($0) }
}
