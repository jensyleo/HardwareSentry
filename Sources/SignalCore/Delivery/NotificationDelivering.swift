import Foundation

/// A channel capable of actually presenting a notification to the user.
///
/// Two conformers are planned: one backed by the system notification centre, and one
/// backed by a self-contained floating banner for when system delivery is unavailable.
/// Both are implemented behind this protocol so `NotificationDispatcher` never needs to
/// know which one it is using.
///
/// The dispatch context is passed through because presentation policy depends on it —
/// a banner stack queues differently during a startup burst than in steady state.
public protocol NotificationDelivering: Sendable {
    func present(_ event: NotificationEvent, context: DispatchContext) async
}
