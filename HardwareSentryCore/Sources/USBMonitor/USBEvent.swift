import SignalCore

/// What this monitor can tell you about.
///
/// Declared here rather than in a table somewhere central: a monitor owns its own events,
/// so gaining one is a change to this module and to nothing else.
public enum USBEvent: String, NotificationEventKey {
    case connected = "USBConnected"
    case disconnected = "USBDisconnected"

    public static let category: NotificationCategory = "USB"
}

/// The optional details this monitor can add.
public enum USBField: String, CaseIterable {
    case vendor = "Vendor"
    case deviceClass = "Type"
}
