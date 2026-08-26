import Foundation

/// A single notification request, as fired by a module before it enters the pipeline.
///
/// A value type by design: no shared mutable state, trivially `Sendable`, and safe
/// to hand across actor boundaries without synchronization. Every field the legacy
/// design hardcoded (priority, sticky) is a real, settable property here instead.
public struct NotificationEvent: Sendable, Identifiable {
    public var id: String
    public var category: NotificationCategory
    public var title: String
    public var body: String
    public var icon: NotificationIcon
    public var priority: Priority
    public var isSticky: Bool
    public var createdAt: Date
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
        id: String,
        category: NotificationCategory,
        title: String,
        body: String,
        icon: NotificationIcon = .none,
        priority: Priority = .normal,
        isSticky: Bool = false,
        createdAt: Date = .distantPast,
        onInteraction: NotificationInteractionHandler? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.body = body
        self.icon = icon
        self.priority = priority
        self.isSticky = isSticky
        self.createdAt = createdAt
        self.onInteraction = onInteraction
    }
}
