import SignalCore

/// What this monitor can tell you about.
///
/// The experimental early-link business aside, this is the full set the original had.
public enum PrinterEvent: String, NotificationEventKey {
    case connected = "PrinterConnected"
    case disconnected = "PrinterDisconnected"
    case error = "PrinterError"
    case defaultChanged = "PrinterDefaultChanged"
    case rejectingJobs = "PrinterRejectingJobs"
    /// A job reached the printer.
    case jobStarted = "PrintJobStarted"
    /// A job finished printing.
    case jobFinished = "PrintJobFinished"
    /// A job was cancelled or aborted before it finished.
    case jobCanceled = "PrintJobCanceled"
    /// Toner, ink or another consumable is running out.
    case supplyLow = "PrinterSupplyLow"

    public static let category: NotificationCategory = "Printer"
}

/// The optional details this monitor can add.
public enum PrinterField: String, CaseIterable {
    case location = "Location"
    case model = "Model"
    case connection = "Connection"
    case shared = "Shared"
    case capabilities = "Capabilities"
    /// Which printer a job went to.
    case jobPrinter = "JobPrinter"
    case jobOwner = "JobOwner"
    case jobSize = "JobSize"
    /// Where this job sits in the queue's ordering.
    case jobPriority = "JobPriority"
    /// Every consumable and its level, on the supply warning.
    case supplyLevels = "SupplyLevels"

    /// How the line is named in Settings → Events, under "Include in the message".
    var settingsTitle: String {
        switch self {
        case .location: return "Location"
        case .model: return "Make and model"
        case .connection: return "How it is reached"
        case .shared: return "Is shared"
        case .capabilities: return "Capabilities"
        case .jobPrinter: return "Which printer the job went to"
        case .jobOwner: return "Who submitted it"
        case .jobSize: return "Job size"
        case .jobPriority: return "Job priority (on Print Job Started)"
        case .supplyLevels: return "Every supply and its level"
        }
    }

    /// Two on, and only two.
    ///
    /// The printer's name is on because a Mac with two printers makes "which one" the
    /// first question about any job. The supply levels are on because they are the entire
    /// content of the warning they belong to — a "toner is low" with its levels switched
    /// off would not say which cartridge or how low.
    ///
    /// The five that describe the printer itself stay off, as they already were: they are
    /// specification, and they never change for a given queue.
    var shownByDefault: Bool {
        switch self {
        case .jobPrinter, .supplyLevels: return true
        case .location, .model, .connection, .shared, .capabilities,
             .jobOwner, .jobSize, .jobPriority:
            return false
        }
    }
}
