import Foundation

/// Drops events of a type the user has switched off.
///
/// Centralises a check that, in the design this replaces, was reimplemented inside every
/// emitting module — each one reading its own preference key just before firing. Here it
/// is one stage, exercised by one set of tests, applied uniformly.
///
/// This is why an event carries a `name` distinct from its `subject`: the name is what a
/// preference gates on, and it must survive into the pipeline for the gate to live here.
public struct EventEnabledFilter: NotificationMiddleware {
    private let preferences: any NotificationPreferences

    public init(preferences: any NotificationPreferences) {
        self.preferences = preferences
    }

    public func process(_ event: NotificationEvent, context: DispatchContext) async -> MiddlewareDecision {
        guard await preferences.isEventEnabled(event.name, in: event.category) else {
            return .suppress(reason: "event \(event.name) is switched off")
        }
        return .deliver(event)
    }
}
