import Foundation
import SignalCore

/// Something that watches one part of the hardware and says when it changes.
///
/// The whole contract, on purpose. A monitor depends on this and on `SignalCore`, and on
/// nothing else — not on the application, and above all not on another monitor. Anything
/// two monitors both need moves into a shared module rather than one importing the other.
///
/// Monitors live in separate modules so this stays true by construction: what is internal
/// to one is invisible to the rest, and the compiler says so rather than a convention
/// that erodes.
public protocol Monitor: Sendable {
    /// Which module this is. Groups its notifications and namespaces its preferences.
    static var category: NotificationCategory { get }

    /// Every event this monitor can raise.
    ///
    /// Listed so a preferences screen can offer them without the monitor running, and so
    /// their defaults can be registered at startup.
    static var events: [MonitorEventDescription] { get }

    /// Whether this monitor runs for someone who has never touched the settings.
    ///
    /// Almost all of them should: a monitor that watches quietly costs little and is the
    /// reason the application was installed. The exception is one whose mere running has
    /// a cost of its own — asking for a system permission, say — which should wait to be
    /// asked for.
    static var enabledByDefault: Bool { get }

    /// Optional details this monitor can put in the body of its notifications.
    ///
    /// Declared for the same reason as `events`, and answering a different question: an
    /// event is whether a notification arrives, a field is how much it says once it has.
    /// A monitor with nothing optional to say leaves this alone.
    static var fields: [MonitorFieldDescription] { get }

    /// Begins watching. Anything already present is announced through `context`, which
    /// knows whether that counts as a startup sweep.
    func start() async

    /// Stops watching and lets go of whatever it was holding.
    func stop() async
}

/// One event a monitor can raise, described well enough to put in front of a person.
public struct MonitorEventDescription: Sendable, Hashable {
    /// Matches the `name` of the notifications raised for it.
    public let name: String
    /// Shown in preferences.
    public let title: String
    /// Whether it is on for someone who has never touched the setting.
    public let enabledByDefault: Bool

    public init(name: String, title: String, enabledByDefault: Bool = true) {
        self.name = name
        self.title = title
        self.enabledByDefault = enabledByDefault
    }
}

/// One optional line a monitor can add to a notification's body.
public struct MonitorFieldDescription: Sendable, Hashable {
    /// Matches the name the monitor asks about when building a body.
    public let name: String
    /// Shown in preferences.
    public let title: String
    /// Whether it is included for someone who has never touched the setting.
    public let shownByDefault: Bool

    public init(name: String, title: String, shownByDefault: Bool = true) {
        self.name = name
        self.title = title
        self.shownByDefault = shownByDefault
    }
}

public extension Monitor {
    var category: NotificationCategory { Self.category }

    /// Most monitors say the same thing every time.
    static var fields: [MonitorFieldDescription] { [] }

    /// Watching is what this application is for.
    static var enabledByDefault: Bool { true }
}

/// Everything a preferences screen needs to know about one monitor, without running it.
public struct MonitorDescription: Sendable, Identifiable {
    public let category: NotificationCategory
    public let events: [MonitorEventDescription]
    public let fields: [MonitorFieldDescription]
    public let enabledByDefault: Bool

    public var id: String { category.rawValue }

    public init(
        category: NotificationCategory,
        events: [MonitorEventDescription],
        fields: [MonitorFieldDescription],
        enabledByDefault: Bool = true
    ) {
        self.category = category
        self.events = events
        self.fields = fields
        self.enabledByDefault = enabledByDefault
    }
}
