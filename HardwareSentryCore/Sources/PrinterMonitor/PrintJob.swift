import Foundation

/// Where a job is in its life.
public enum PrintJobState: Sendable, Equatable {
    case pending
    case held
    case processing
    case stopped
    case completed
    case canceled
    case aborted

    /// Whether the job is over, one way or another.
    var isFinal: Bool {
        switch self {
        case .completed, .canceled, .aborted: return true
        case .pending, .held, .processing, .stopped: return false
        }
    }
}

/// One print job, as CUPS describes it.
public struct PrintJob: Sendable, Equatable {
    public let id: Int
    /// The document's name, which is what somebody recognises a job by.
    public let title: String
    public let printerName: String
    public let user: String?
    /// The job's size in kilobytes, as CUPS accounts for it.
    ///
    /// No copy count sits beside it: `cups_job_t` does not carry one, so a field for it
    /// would be a switch in the settings window that could never produce a line.
    public let sizeKilobytes: Int?
    public let state: PrintJobState
    /// CUPS job priority, 1 to 100, 50 being the default nobody set.
    ///
    /// Only worth reading when several jobs are competing for the same queue, which is why
    /// the line it feeds is off unless asked for.
    public let priority: Int?

    public init(
        id: Int,
        title: String,
        printerName: String,
        user: String? = nil,
        sizeKilobytes: Int? = nil,
        state: PrintJobState = .pending,
        priority: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.printerName = printerName
        self.user = user
        self.sizeKilobytes = sizeKilobytes
        self.state = state
        self.priority = priority
    }

    /// "Untitled document" rather than an empty line: a job submitted without a name still
    /// needs to be identifiable in a notification.
    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled document" : title
    }

    /// Nothing for a job at the default priority: "priority 50" on every job would be a
    /// line that never says anything, and the setting exists for the case where one job
    /// was deliberately pushed ahead of another.
    var priorityNote: String? {
        guard let priority, (1...100).contains(priority), priority != 50 else { return nil }
        return "priority \(priority)"
    }

    var sizeNote: String? {
        guard let sizeKilobytes, sizeKilobytes > 0 else { return nil }
        guard sizeKilobytes >= 1024 else { return "\(sizeKilobytes) KB" }
        return String(format: "%.1f MB", Double(sizeKilobytes) / 1024)
    }
}
