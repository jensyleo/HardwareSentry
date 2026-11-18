import Foundation

/// Which notices may be held back to be grouped, and what the group says.
///
/// Kept as plain functions of events, apart from the delivery that uses them, so the two
/// decisions with judgement in them can be checked without a screen: that nothing which
/// needs attention is ever swallowed into a list, and that the list says what it holds.
public enum BurstSummary {
    /// Plain news only. A warning or a critical notice is acted on, so it is shown at once
    /// and on its own; a sticky one asked to stay until closed and is left alone too.
    public static func isGroupable(_ event: NotificationEvent) -> Bool {
        guard !event.isSticky, event.priority < .high else { return false }
        switch BannerSeverity(badge: event.iconBadge) {
        case .info, .connected, .gone: return true
        case .attention, .critical: return false
        }
    }

    /// The most notices the banner lists before it says how many more there were.
    public static let listedLimit = 5
    /// Longest stretch of a notice's first body line shown beside its title.
    static let subjectLimit = 28

    /// One notice standing for all of `events`, which must be more than one.
    public static func summary(of events: [NotificationEvent]) -> NotificationEvent {
        precondition(events.count > 1, "a summary stands for several notices")
        let first = events[0]
        let modules = Set(events.map { $0.category.rawValue })

        var lines = events.prefix(listedLimit).map { event in
            var subject = event.body.split(separator: "\n").first.map(String.init) ?? ""
            if subject.count > subjectLimit { subject = String(subject.prefix(subjectLimit)) + "…" }
            return subject.isEmpty || subject == event.title ? event.title : "\(event.title) — \(subject)"
        }
        if events.count > listedLimit {
            lines.append("and \(events.count - listedLimit) more")
        }

        let title = modules.count == 1
            ? "\(events.count) notices from \(first.category.rawValue)"
            : "\(events.count) notices at once"

        return NotificationEvent(
            name: "BurstSummary",
            subject: "BurstSummary",
            category: first.category,
            title: title,
            body: lines.joined(separator: "\n"),
            icon: first.icon,
            priority: .normal,
            onInteraction: { interaction in
                // Whoever raised each notice still hears how it ended.
                for event in events { event.onInteraction?(interaction) }
            }
        )
    }
}
