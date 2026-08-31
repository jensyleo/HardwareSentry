import Foundation

/// Answers whether the user wants a given notification at all.
///
/// SignalCore deliberately does not know how preferences are stored, named or presented —
/// a host supplies that. Both requirements have defaults that answer "yes", so a host that
/// only gates at one level (or does not gate at all) conforms with just the part it cares
/// about.
public protocol NotificationPreferences: Sendable {
    /// Whether an entire emitting module is switched on.
    func isCategoryEnabled(_ category: NotificationCategory) async -> Bool

    /// Whether one specific event type within a module is switched on.
    func isEventEnabled(_ name: String, in category: NotificationCategory) async -> Bool
}

public extension NotificationPreferences {
    func isCategoryEnabled(_ category: NotificationCategory) async -> Bool { true }
    func isEventEnabled(_ name: String, in category: NotificationCategory) async -> Bool { true }
}
