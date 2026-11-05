import Foundation

/// How the user (or the delivery system) resolved a presented notification.
public enum NotificationInteraction: Sendable, Equatable {
    case clicked
    case timedOut
    case dismissed
}

/// A typed handler a caller attaches directly to a `NotificationEvent`.
///
/// Replaces the string-parsed "<ClassName> : <context>" round-trip and
/// class-name reflection lookup used by the legacy delegate-based design —
/// the emitting module hands over its own closure, no lookup required.
public typealias NotificationInteractionHandler = @Sendable (NotificationInteraction) -> Void
