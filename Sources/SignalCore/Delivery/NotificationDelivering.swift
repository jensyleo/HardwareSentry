import Foundation

/// What became of an attempt to present a notification.
public enum DeliveryOutcome: Sendable, Equatable {
    case presented
    case failed(reason: String)

    public var didPresent: Bool { self == .presented }
}

/// A channel capable of actually presenting a notification to the user.
///
/// Conformers are expected to include one backed by the system notification service and
/// one backed by a self-contained floating banner, with a composite that prefers the
/// former and falls back to the latter. The fallback is why presenting reports an
/// outcome rather than returning nothing: a composite cannot know to try its second
/// channel unless the first one can say it failed.
///
/// The dispatch context is passed through because presentation policy depends on it —
/// a banner stack queues differently during a startup burst than in steady state.
public protocol NotificationDelivering: Sendable {
    @discardableResult
    func present(_ event: NotificationEvent, context: DispatchContext) async -> DeliveryOutcome
}
