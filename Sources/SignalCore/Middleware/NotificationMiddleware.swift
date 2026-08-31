import Foundation

/// One stage of the dispatcher's pipeline.
///
/// Each stage independently decides whether an event proceeds, is dropped, or is
/// replaced by a transformed copy. Stages are applied in registration order by
/// `NotificationDispatcher`. Every stage is a self-contained, independently testable
/// unit — the legacy design this replaces inlined all of these concerns into a single
/// long method, which could not be exercised without launching the host application.
public protocol NotificationMiddleware: Sendable {
    func process(_ event: NotificationEvent, context: DispatchContext) async -> MiddlewareDecision
}

public enum MiddlewareDecision: Sendable {
    case deliver(NotificationEvent)
    case suppress(reason: String)
}
