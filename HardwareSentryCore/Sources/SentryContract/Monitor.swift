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

    /// The artwork to show next to this event in preferences.
    ///
    /// Declared rather than discovered, because a monitor that picks its icon from the
    /// device — a headset gets headphones, a hub gets a hub — has no single icon until
    /// something actually connects, and preferences has to show *something* before that
    /// ever happens. So this is the representative one: what the event looks like in the
    /// ordinary case, which is what somebody scanning the list needs in order to recognise
    /// the row they came to change.
    public let icon: NotificationIcon
    /// Which heading this row sits under in preferences.
    ///
    /// Nil for a monitor whose events are few enough to read as one list, which is most of
    /// them. A monitor covering genuinely separate things — Wi-Fi and wired networking are
    /// one module because they are one subsystem, not because anybody thinks of them as
    /// one topic — says so here, and the settings screen grows headings rather than the
    /// module being split into two with two switches and two preference namespaces.
    ///
    /// Order comes from the declaration order of the events themselves, so a group appears
    /// where its first event does.
    public let group: String?

    public init(
        name: String,
        title: String,
        enabledByDefault: Bool = true,
        icon: NotificationIcon = .none,
        group: String? = nil
    ) {
        self.name = name
        self.title = title
        self.enabledByDefault = enabledByDefault
        self.icon = icon
        self.group = group
    }

    /// Hashed by name alone. The name is already unique within a monitor, and the icon can
    /// be a hundred kilobytes of PNG — hashing that on every row of a redrawing list would
    /// be paying a great deal for a value that adds nothing to the distinction.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
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
    /// Which heading this row sits under, on the same terms as an event's.
    public let group: String?

    public init(name: String, title: String, shownByDefault: Bool = true, group: String? = nil) {
        self.name = name
        self.title = title
        self.shownByDefault = shownByDefault
        self.group = group
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

    /// The events under their headings, in the order they were declared.
    ///
    /// A monitor that declared no groups comes back as one unnamed run, so a screen can
    /// render every module the same way without asking whether this one bothered.
    public var eventGroups: [MonitorRowGroup<MonitorEventDescription>] {
        MonitorRowGroup.grouping(events, by: \.group)
    }

    public var fieldGroups: [MonitorRowGroup<MonitorFieldDescription>] {
        MonitorRowGroup.grouping(fields, by: \.group)
    }

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

/// A run of rows under one heading.
public struct MonitorRowGroup<Row: Sendable>: Sendable, Identifiable {
    /// Nil for rows that asked for no heading.
    public let title: String?
    public let rows: [Row]

    public var id: String { title ?? "" }

    /// Groups while preserving declaration order — both of the groups themselves and of
    /// the rows inside them.
    ///
    /// Sorting either would be worse: these lists are written in the order somebody should
    /// read them, with the common things first, and alphabetical order would scatter that.
    static func grouping(_ rows: [Row], by key: (Row) -> String?) -> [MonitorRowGroup<Row>] {
        var order: [String?] = []
        var byGroup: [String?: [Row]] = [:]

        for row in rows {
            let group = key(row)
            if byGroup[group] == nil { order.append(group) }
            byGroup[group, default: []].append(row)
        }

        return order.map { MonitorRowGroup(title: $0, rows: byGroup[$0] ?? []) }
    }
}
