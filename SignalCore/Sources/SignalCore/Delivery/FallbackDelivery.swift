import Foundation

/// Prefers one channel and falls back to another when it declines.
///
/// The arrangement this exists for: prefer the system's own notification service, and
/// draw banners when it will not have us. An application without a stable signing
/// identity is refused by the system service, and one whose user has said no is refused
/// permanently — in either case the alternative is not "no notifications".
///
/// Because the preferred channel declines rather than waits while the permission
/// question is still open, notifications raised during that window are drawn rather than
/// lost, and the system takes over by itself once the answer is in.
public struct FallbackDelivery: NotificationDelivering {
    private let preferred: any NotificationDelivering
    private let fallback: any NotificationDelivering

    public init(preferred: any NotificationDelivering, fallback: any NotificationDelivering) {
        self.preferred = preferred
        self.fallback = fallback
    }

    @discardableResult
    public func present(_ event: NotificationEvent, context: DispatchContext) async -> DeliveryOutcome {
        let outcome = await preferred.present(event, context: context)
        guard !outcome.didPresent else { return outcome }
        return await fallback.present(event, context: context)
    }
}
