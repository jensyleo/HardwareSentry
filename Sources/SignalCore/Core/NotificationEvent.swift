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

    /// What the icon depicts, as a stable identifier the host defines — `"usb.keyboard"`,
    /// `"volume.nas"`. Nil when the icon depicts an idea rather than a thing (a signal
    /// level, a VPN, a temperature), which is most of what is not a device.
    ///
    /// Lets a later stage swap the picture for another of the same thing — the operating
    /// system's own, say — without knowing anything about the module that raised it.
    /// Nothing in this library reads it; it is carried, not interpreted.
    public var iconKind: String?

    /// Which model the device is, as `"vvvv:pppp"` — vendor and product ID in lowercase
    /// hex — when it said. Lets a later stage find a picture of that exact model rather
    /// than of its kind. Carried, not interpreted, like `iconKind`.
    public var iconModel: String?

    /// The state the icon stands for, when the picture alone might not show it. See
    /// `IconBadge`. Nil for an icon that has no state to show.
    public var iconBadge: IconBadge?

    /// Whether whatever draws the icon should mark `iconBadge` on it.
    ///
    /// Off by default because a host's own artwork usually paints the state into the
    /// picture already — a device with a cross through it — and a second mark on top would
    /// say the same thing twice. Switched on by a stage that swaps that artwork for a
    /// picture with no state in it: the operating system's own, or one somebody chose.
    public var showsIconBadge: Bool

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
        iconKind: String? = nil,
        iconModel: String? = nil,
        iconBadge: IconBadge? = nil,
        showsIconBadge: Bool = false,
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
        self.iconKind = iconKind
        self.iconModel = iconModel
        self.iconBadge = iconBadge
        self.showsIconBadge = showsIconBadge
        self.priority = priority
        self.isSticky = isSticky
        self.onInteraction = onInteraction
    }
}
