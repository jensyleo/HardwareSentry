import Foundation

/// Suppresses an event that repeats the same notification, for the same subject, with
/// the same body, within a short window.
///
/// The key deliberately combines category, event name, subject and body. Title is
/// excluded because it is derived from the other three for display — two events that
/// agree on category, name, subject and body are the same notification regardless of
/// how their title happens to be phrased.
///
/// Subjects carrying one of the exempt suffixes bypass suppression entirely. These mark
/// paired state transitions (something started, something stopped) which are already
/// debounced by the module that emits them, and which would otherwise be collapsed into
/// each other when a device flips state quickly.
///
/// The dedup table is actor-isolated state rather than a lock-guarded global, so there
/// is no lock to forget, and it is pruned lazily so a long-running host does not
/// accumulate an entry per device seen since launch.
public actor DuplicateSuppressionMiddleware: NotificationMiddleware {
    private var lastFired: [String: Date] = [:]
    private let window: TimeInterval
    private let exemptSuffixes: [String]
    private let pruneThreshold: Int

    public init(
        window: TimeInterval = 3,
        exemptSubjectSuffixes: [String] = ["-started", "-stopped"],
        pruneThreshold: Int = 256
    ) {
        self.window = window
        self.exemptSuffixes = exemptSubjectSuffixes
        self.pruneThreshold = pruneThreshold
    }

    public func process(_ event: NotificationEvent, context: DispatchContext) async -> MiddlewareDecision {
        if exemptSuffixes.contains(where: { event.subject.hasSuffix($0) }) {
            return .deliver(event)
        }

        let key = Self.key(for: event)

        if let last = lastFired[key], context.firedAt.timeIntervalSince(last) < window {
            return .suppress(reason: "duplicate of \(key) within \(window)s")
        }

        if lastFired.count >= pruneThreshold {
            prune(before: context.firedAt)
        }

        lastFired[key] = context.firedAt
        return .deliver(event)
    }

    /// Number of entries currently held in the dedup table. Exposed for tests that
    /// verify pruning keeps the table bounded.
    var trackedKeyCount: Int { lastFired.count }

    private static func key(for event: NotificationEvent) -> String {
        "\(event.category.rawValue)|\(event.name)|\(event.subject)|\(event.body)"
    }

    /// Drops entries that can no longer suppress anything, so the table stays bounded
    /// by how many distinct notifications occur within one window rather than by how
    /// many have ever occurred.
    private func prune(before instant: Date) {
        lastFired = lastFired.filter { instant.timeIntervalSince($0.value) < window }
    }
}
