import Foundation

/// A channel capable of actually presenting a notification to the user.
///
/// Two conformers are planned: a `UNUserNotificationCenter`-backed system delivery,
/// and a custom floating-banner delivery (for when system permission isn't granted —
/// see the ad-hoc-signing note in the design doc). Both are implemented separately
/// from this protocol so `NotificationDispatcher` never needs to know which one it's using.
public protocol NotificationDelivering: Sendable {
    func present(_ event: NotificationEvent) async
}
