import Foundation

/// Whether the user has allowed system notifications.
public enum SystemAuthorizationStatus: Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
}

/// How insistently a notification should be presented.
public enum SystemInterruptionLevel: Sendable, Equatable {
    /// Delivered quietly, without waking the screen.
    case passive
    /// The ordinary level.
    case active
    /// Breaks through Focus/Do Not Disturb the way a call or a timer does, for the
    /// handful of events worth interrupting someone over.
    case timeSensitive
}

/// A notification described in terms this package owns, ready to be handed to the
/// operating system.
public struct SystemNotificationRequest: Sendable, Equatable {
    public let identifier: String
    public let title: String
    public let body: String
    public let interruptionLevel: SystemInterruptionLevel

    public init(
        identifier: String,
        title: String,
        body: String,
        interruptionLevel: SystemInterruptionLevel
    ) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.interruptionLevel = interruptionLevel
    }
}

/// The seam between this package and the operating system's notification service.
///
/// It exists so the delivery logic — composing identifiers, tracking which notification
/// belongs to which handler, deciding what counts as a failure — can be exercised in
/// tests. The system's own notification centre cannot be instantiated outside a real
/// application bundle, so anything that touched it directly would be untestable.
public protocol SystemNotificationScheduling: Sendable {
    func authorizationStatus() async -> SystemAuthorizationStatus
    /// Asks the user for permission. Returns whether it was granted.
    func requestAuthorization() async -> Bool
    func schedule(_ request: SystemNotificationRequest) async throws
}
