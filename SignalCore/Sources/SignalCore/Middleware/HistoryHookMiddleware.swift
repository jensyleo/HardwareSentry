import Foundation

/// Hands every notification that survived the pipeline to somewhere that can remember it.
///
/// A hook rather than a store: where history is kept, how much of it, and whether it
/// outlives the process are all decisions belonging to the application, not to this
/// package. All this does is say when something happened.
///
/// **Where to put it matters.** Placed last in the pipeline — after the filters and the
/// duplicate suppression — it records what a person was actually shown, which is what a
/// history is for. Placed first it would record what was *raised*, including everything
/// deliberately silenced, which is a debugging log wearing a history's clothes.
public struct HistoryHookMiddleware: NotificationMiddleware {
    private let record: @Sendable (NotificationEvent, DispatchContext) -> Void

    public init(record: @escaping @Sendable (NotificationEvent, DispatchContext) -> Void) {
        self.record = record
    }

    public func process(_ event: NotificationEvent, context: DispatchContext) async -> MiddlewareDecision {
        record(event, context)
        // Never the one to stop a notification: a hook that could swallow what it was
        // asked to observe would be a filter, and this is not one.
        return .deliver(event)
    }
}
