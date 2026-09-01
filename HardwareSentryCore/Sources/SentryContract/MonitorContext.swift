import Foundation
import SignalCore

/// What a monitor is given so it can do its job.
///
/// Handed over at construction rather than reached for globally, so a monitor can be
/// built in a test with somewhere harmless to send its notifications.
public struct MonitorContext: Sendable {
    private let dispatcher: NotificationDispatcher
    private let category: NotificationCategory
    private let preferences: any NotificationPreferences

    /// Whether a monitor should announce what it finds already there when it starts.
    ///
    /// The alternative — reading the current state silently and only speaking up when
    /// something changes — is quieter, but it means launching the application tells you
    /// nothing at all about the machine you are sitting at. The startup sweep is the one
    /// moment where "here is everything that is plugged in" is genuinely the news, which is
    /// why the dispatcher tracks a `.launching` phase separately in the first place: it is
    /// what lets that burst be treated as a burst — no sounds, no flap detection — rather
    /// than mistaken for a dozen things happening at once.
    public let announcesWhatIsAlreadyThere: Bool

    public init(
        dispatcher: NotificationDispatcher,
        category: NotificationCategory,
        preferences: any NotificationPreferences = AlwaysWanted(),
        announcesWhatIsAlreadyThere: Bool = true
    ) {
        self.dispatcher = dispatcher
        self.category = category
        self.preferences = preferences
        self.announcesWhatIsAlreadyThere = announcesWhatIsAlreadyThere
    }

    /// Builds a body from lines, leaving out the optional ones nobody asked for.
    ///
    /// A monitor lists everything it *could* say and lets this decide what actually gets
    /// said, rather than each monitor growing its own tangle of checks — the same reason
    /// the events themselves are declared rather than gated by hand.
    public func body(_ lines: [BodyLine]) async -> String {
        var kept: [String] = []
        for line in lines {
            if let field = line.field {
                guard await preferences.isFieldEnabled(field, in: category) else { continue }
            }
            if let text = line.text(), !text.isEmpty { kept.append(text) }
        }
        return kept.joined(separator: "\n")
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

/// Stands in when a monitor is built without preferences — in a test, or by a host that
/// does not offer the choice. Everything a monitor can say, it says.
public struct AlwaysWanted: NotificationPreferences {
    public init() {}
}
