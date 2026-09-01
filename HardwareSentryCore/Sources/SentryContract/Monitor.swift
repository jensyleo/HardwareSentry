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

public extension Monitor {
    var category: NotificationCategory { Self.category }
}
