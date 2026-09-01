import SignalCore

/// What this monitor can tell you about.
///
/// Only discovery — "Scan Started/Finished" and "Feeder State Changed" are not ported at
/// all, not just left unwired to a preferences UI; see the porting notes for why.
public enum ScannerEvent: String, NotificationEventKey {
    case found = "ScannerFound"
    case lost = "ScannerLost"

    public static let category: NotificationCategory = "Scanner"
}
