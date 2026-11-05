import Foundation

/// Drops events from a module the user has switched off entirely.
///
/// The coarse gate: cheapest check available, so it belongs first in the pipeline. Kept
/// separate from `EventEnabledFilter` so a host with no concept of per-module switching
/// can simply not register it.
public struct CategoryEnabledFilter: NotificationMiddleware {
    private let preferences: any NotificationPreferences

    public init(preferences: any NotificationPreferences) {
        self.preferences = preferences
    }

    public func process(_ event: NotificationEvent, context: DispatchContext) async -> MiddlewareDecision {
        guard await preferences.isCategoryEnabled(event.category) else {
            return .suppress(reason: "category \(event.category.rawValue) is switched off")
        }
        return .deliver(event)
    }
}
