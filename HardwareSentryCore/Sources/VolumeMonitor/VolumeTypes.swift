import Foundation

/// What the system told this monitor just happened.
public enum VolumeSourceEvent: Sendable, Equatable {
    case mounted(path: String, name: String)
    /// Finder is about to eject this volume gracefully. Distinct from `.unmounted` so the
    /// monitor can tell a graceful eject apart from a surprise removal — a volume that
    /// disappears with no matching `.willUnmount` first was pulled out, not ejected.
    case willUnmount(path: String, name: String)
    case unmounted(path: String, name: String)
    /// Percent free space per currently-mounted local volume — not a delta; the monitor
    /// applies the threshold/hysteresis.
    case freeSpaceSnapshot([String: Double])
}

public protocol VolumeSource: Sendable {
    func changes() -> AsyncStream<VolumeSourceEvent>
}
