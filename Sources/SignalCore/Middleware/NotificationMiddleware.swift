import Foundation

/// One stage of the dispatcher's pipeline.
///
/// Each stage independently decides whether an event proceeds, is dropped, or is
/// replaced (e.g. a dedup stage tagging a modified copy). Stages are applied in
/// registration order by `NotificationDispatcher`. Every stage is a self-contained,
/// independently testable unit — the legacy design mixed all of this into a single
/// 186-line method.
public protocol NotificationMiddleware: Sendable {
    func process(_ event: NotificationEvent) async -> MiddlewareDecision
}

public enum MiddlewareDecision: Sendable {
    case deliver(NotificationEvent)
    case suppress(reason: String)
}
