import Foundation

/// One CUPS destination's state, as of one poll — enough to notice a connect/disconnect,
/// an OK↔problem transition, a rejecting-jobs transition, or the default printer changing.
public struct PrinterSnapshot: Sendable, Equatable {
    public let name: String
    public let isDefault: Bool
    /// Raw IPP `printer-state-reasons`, e.g. `"none"` or `"media-empty-warning,toner-low-warning"`.
    public let stateReasons: String
    public let isRejectingJobs: Bool
    public let location: String?
    public let makeAndModel: String?
    /// Derived from the device URI's scheme: how the printer is actually reached.
    public let connection: String?
    public let isShared: Bool
    /// The capabilities worth naming, already in words — e.g. "Color, Duplex, Scanner (MFP)".
    public let capabilities: String?

    public init(
        name: String,
        isDefault: Bool,
        stateReasons: String,
        isRejectingJobs: Bool,
        location: String? = nil,
        makeAndModel: String? = nil,
        connection: String? = nil,
        isShared: Bool = false,
        capabilities: String? = nil
    ) {
        self.name = name
        self.isDefault = isDefault
        self.stateReasons = stateReasons
        self.isRejectingJobs = isRejectingJobs
        self.location = location
        self.makeAndModel = makeAndModel
        self.connection = connection
        self.isShared = isShared
        self.capabilities = capabilities
    }
}

/// The optional details this monitor can add to a connect notification.
public enum PrinterField: String, CaseIterable {
    case location = "Location"
    case model = "Model"
    case connection = "Connection"
    case shared = "Shared"
    case capabilities = "Capabilities"
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
