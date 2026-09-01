import SignalCore

/// What this monitor can tell you about.
///
/// Print job started/finished and toner/ink supply levels are not ported at all — both
/// require a hand-built IPP request beyond `cupsGetDests()`'s cached destination options,
/// and HG4MAC itself marks both experimental/off by default and, for job tracking,
/// explicitly untested against a real print job. See the porting notes.
public enum PrinterEvent: String, NotificationEventKey {
    case connected = "PrinterConnected"
    case disconnected = "PrinterDisconnected"
    case error = "PrinterError"
    case defaultChanged = "PrinterDefaultChanged"
    case rejectingJobs = "PrinterRejectingJobs"

    public static let category: NotificationCategory = "Printer"
}
