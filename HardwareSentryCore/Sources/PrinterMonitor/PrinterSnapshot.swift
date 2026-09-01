import Foundation

/// One CUPS destination's state, as of one poll — enough to notice a connect/disconnect,
/// an OK↔problem transition, a rejecting-jobs transition, or the default printer changing.
public struct PrinterSnapshot: Sendable, Equatable {
    public let name: String
    public let isDefault: Bool
    /// Raw IPP `printer-state-reasons`, e.g. `"none"` or `"media-empty-warning,toner-low-warning"`.
    public let stateReasons: String
    public let isRejectingJobs: Bool

    public init(name: String, isDefault: Bool, stateReasons: String, isRejectingJobs: Bool) {
        self.name = name
        self.isDefault = isDefault
        self.stateReasons = stateReasons
        self.isRejectingJobs = isRejectingJobs
    }
}

public enum PrinterSourceEvent: Sendable, Equatable {
    /// The full current CUPS destination list — not a delta. There is no push notification
    /// for CUPS's printer list changing, so this is always the result of a poll; the
    /// monitor is what turns it into connect/disconnect/error/default/rejecting events.
    case snapshot([PrinterSnapshot])
}

public protocol PrinterSource: Sendable {
    func changes() -> AsyncStream<PrinterSourceEvent>
}
