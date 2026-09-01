import SignalCore

/// What this monitor can tell you about.
///
/// The experimental early-link-detection feature (`DisplayLinkDetected`, off by default in
/// HG4MAC — scrapes free-form kernel log text with no stability contract, see its own long
/// doc comment there) is deliberately not ported at all; see the porting notes for why.
public enum DisplayEvent: String, NotificationEventKey {
    case connected = "DisplayConnected"
    case disconnected = "DisplayDisconnected"
    case modeChanged = "DisplayModeChanged"
    case roleChanged = "DisplayRoleChanged"
    case sleepChanged = "DisplaySleepChanged"
    case colorProfileChanged = "DisplayColorProfileChanged"

    public static let category: NotificationCategory = "Display"
}

/// The optional details this monitor can add to a connect notification.
public enum DisplayField: String, CaseIterable {
    case resolution = "Resolution"
    case refreshRate = "RefreshRate"
    case rotation = "Rotation"
    case role = "Role"
}
