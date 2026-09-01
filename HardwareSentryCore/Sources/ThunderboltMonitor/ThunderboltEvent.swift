import SignalCore

/// What this monitor can tell you about.
///
/// The eGPU pair is separate from, and additive to, the generic connect/disconnect pair —
/// a hot-plugged Display Controller PCI function fires both. Off by default, same as
/// HG4MAC: it's new behaviour on top of an already-firing notice, not a visibility toggle.
public enum ThunderboltEvent: String, NotificationEventKey {
    case connected = "ThunderboltConnected"
    case disconnected = "ThunderboltDisconnected"
    case egpuConnected = "ThunderboltEGPUConnected"
    case egpuDisconnected = "ThunderboltEGPUDisconnected"

    public static let category: NotificationCategory = "Thunderbolt"
}
