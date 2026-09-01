import Foundation
import SignalCore

/// What a monitor is given so it can do its job.
///
/// Handed over at construction rather than reached for globally, so a monitor can be
/// built in a test with somewhere harmless to send its notifications.
public struct MonitorContext: Sendable {
    private let dispatcher: NotificationDispatcher
    private let category: NotificationCategory

    public init(dispatcher: NotificationDispatcher, category: NotificationCategory) {
        self.dispatcher = dispatcher
        self.category = category
    }

    /// Raises a notification, already stamped with the monitor's own category so it
    /// cannot accidentally speak for another module.
    public func notify(
        _ name: String,
        subject: String? = nil,
        title: String,
        body: String,
        icon: NotificationIcon = .none,
        priority: NotificationEvent.Priority = .normal,
        onInteraction: NotificationInteractionHandler? = nil
    ) async {
        await dispatcher.fire(
            NotificationEvent(
                name: name,
                subject: subject,
                category: category,
                title: title,
                body: body,
                icon: icon,
                priority: priority,
                onInteraction: onInteraction
            )
        )
    }
}
