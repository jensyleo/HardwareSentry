import Foundation

/// Suppresses an event that repeats the same category/id/title/body within a
/// short window. Replaces the legacy design's static `NSMutableDictionary`
/// guarded by `@synchronized` — here the dedup table is actor-isolated state,
/// so there's no lock to forget.
///
/// `-started`/`-stopped`-suffixed identifiers are exempt by default, mirroring
/// the legacy behavior for in-use state transitions (e.g. camera/mic) that are
/// already debounced upstream by their own monitor.
public actor DuplicateSuppressionMiddleware: NotificationMiddleware {
    private var lastFired: [String: Date] = [:]
    private let window: TimeInterval
    private let exemptSuffixes: [String]
    private let now: @Sendable () -> Date

    public init(
        window: TimeInterval = 3,
        exemptIdentifierSuffixes: [String] = ["-started", "-stopped"],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.window = window
        self.exemptSuffixes = exemptIdentifierSuffixes
        self.now = now
    }

    public func process(_ event: NotificationEvent) async -> MiddlewareDecision {
        if exemptSuffixes.contains(where: { event.id.hasSuffix($0) }) {
            return .deliver(event)
        }

        let key = "\(event.category.rawValue)|\(event.id)|\(event.title)|\(event.body)"
        let currentTime = now()

        if let last = lastFired[key], currentTime.timeIntervalSince(last) < window {
            return .suppress(reason: "duplicate of \"\(key)\" within \(window)s window")
        }

        lastFired[key] = currentTime
        return .deliver(event)
    }
}
