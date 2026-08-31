import Foundation

/// A single notification request, as described by the module that fired it.
///
/// A value type by design: no shared mutable state, trivially `Sendable`, and safe
/// to hand across actor boundaries without synchronization.
///
/// Every field here is caller-supplied. Metadata the system stamps at dispatch time
/// (when it was fired, which startup phase it belongs to) lives in `DispatchContext`
/// instead, so there is no field a caller is expected to leave alone.
public struct NotificationEvent: Sendable {
    /// What happened — the event *type*, stable across instances.
    ///
    /// Load-bearing beyond display: per-event user preferences and per-event icon
    /// overrides are both keyed off this, and it forms part of the deduplication key.
    /// Example: `"USBConnected"`.
    public var name: String

    /// What it happened *to* — the specific instance, stable across event types.
    ///
    /// Example: the device name, so that a connect and a later disconnect of the same
    /// device share a subject. Deduplication and instability detection key off this.
    /// For events with no meaningful instance (a radio toggling, a hostname changing)
    /// this defaults to `name`.
    public var subject: String

    /// Which module emitted the event.
    public var category: NotificationCategory

    public var title: String
    public var body: String
    public var icon: NotificationIcon
    public var priority: Priority
    public var isSticky: Bool
    public var onInteraction: NotificationInteractionHandler?

    public enum Priority: Int, Sendable, Comparable {
        case low = -1
        case normal = 0
        case high = 1

        public static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public init(
        name: String,
        subject: String? = nil,
        category: NotificationCategory,
        title: String,
        body: String,
        icon: NotificationIcon = .none,
        priority: Priority = .normal,
        isSticky: Bool = false,
        onInteraction: NotificationInteractionHandler? = nil
    ) {
        self.name = name
        self.subject = subject ?? name
        self.category = category
        self.title = title
        self.body = body
        self.icon = icon
        self.priority = priority
        self.isSticky = isSticky
        self.onInteraction = onInteraction
    }
}
