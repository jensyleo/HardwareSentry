import SignalCore

/// What this monitor can tell you about.
public enum ScannerEvent: String, NotificationEventKey {
    case found = "ScannerFound"
    case lost = "ScannerLost"
    /// The scanner started or finished scanning, or stopped needing attention.
    case scanStatus = "ScannerScanStatus"
    /// The document feeder was loaded, emptied, jammed, or its door opened.
    case adfStateChanged = "ScannerAdfStateChanged"

    public static let category: NotificationCategory = "Scanner"
}
