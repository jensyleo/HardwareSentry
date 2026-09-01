import Foundation

/// What the system told this monitor just happened.
public enum NetworkSourceEvent: Sendable, Equatable {
    case reachability(isReachable: Bool, detail: NetworkPathDetail? = nil)
    case wifiConnected(ssid: String, detail: WiFiDetail? = nil)
    case wifiDisconnected
    /// The full current set of network interfaces with an active link — not a delta, same
    /// reasoning as `DisplaySourceEvent.snapshot`.
    case linkSnapshot([String: Bool])
    /// The BSD name of whichever interface currently carries default (Internet-bound)
    /// traffic — not a delta; the monitor diffs it.
    case primaryInterfaceSnapshot(String?)
}

public protocol NetworkSource: Sendable {
    func changes() -> AsyncStream<NetworkSourceEvent>
}
