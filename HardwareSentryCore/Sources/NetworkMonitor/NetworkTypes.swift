import Foundation

/// What the system told this monitor just happened.
public enum NetworkSourceEvent: Sendable, Equatable {
    case reachability(isReachable: Bool, detail: NetworkPathDetail? = nil)
    case wifiConnected(ssid: String, detail: WiFiDetail? = nil)
    /// Carries the network that was left. Without it the banner says only that Wi-Fi
    /// dropped, and which network it dropped is the one thing worth knowing.
    case wifiDisconnected(ssid: String? = nil)
    /// The full current set of user-facing network interfaces with an active link — not a
    /// delta, same reasoning as `DisplaySourceEvent.snapshot`. Restricted to interfaces
    /// `SCNetworkInterfaceCopyAll` itself lists — the same set System Settings › Network
    /// shows — which is what keeps AirDrop's `awdl0`, `llw0`, and other interfaces nobody
    /// asked about out of the notification stream entirely.
    case linkSnapshot([String: LinkState])
    /// The BSD name of whichever interface currently carries default (Internet-bound)
    /// traffic — not a delta; the monitor diffs it.
    case primaryInterfaceSnapshot(String?)
    /// Every interface currently holding a DHCP lease, and when that lease started — not
    /// a delta. A *different* start time on an interface already seen is what a renewal
    /// looks like; the very first time an interface is seen holding a lease at all is
    /// just DHCP finishing normally, not a renewal of anything.
    case dhcpLeaseSnapshot([String: Date])
    /// The name set in System Settings › General › Sharing — not the same as the "AirDrop
    /// & Handoff"-style Bonjour name, and not the same as a DNS hostname.
    case computerNameSnapshot(String?)
    /// Every address the machine currently holds — not a delta. The monitor decides
    /// whether what would actually be shown has changed.
    case ipAddressSnapshot(IPAddressReport)
}

public protocol NetworkSource: Sendable {
    func changes() -> AsyncStream<NetworkSourceEvent>
}
