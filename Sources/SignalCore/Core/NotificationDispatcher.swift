import Foundation

/// The central actor every emitting module talks to.
///
/// Being an `actor` gives data-race safety for free at the type-system level —
/// no `@synchronized` blocks, no static globals, no manually-guarded dictionaries.
/// Replaces the legacy design's single delegate method (disabled-plugin check,
/// dedup, flap-detection, history recording and final dispatch all inlined
/// together) with an ordered, independently-testable pipeline plus a pluggable
/// delivery channel.
public actor NotificationDispatcher {
    private var pipeline: [any NotificationMiddleware]
    private var delivery: any NotificationDelivering

    public init(pipeline: [any NotificationMiddleware] = [], delivery: any NotificationDelivering) {
        self.pipeline = pipeline
        self.delivery = delivery
    }

    public func setPipeline(_ pipeline: [any NotificationMiddleware]) {
        self.pipeline = pipeline
    }

    public func setDelivery(_ delivery: any NotificationDelivering) {
        self.delivery = delivery
    }

    /// Runs `event` through every registered middleware stage in order, then
    /// hands the (possibly transformed) result to the delivery channel — unless
    /// any stage suppresses it first.
    @discardableResult
    public func fire(_ event: NotificationEvent) async -> FireResult {
        var current = event
        for stage in pipeline {
            switch await stage.process(current) {
            case .deliver(let updated):
                current = updated
            case .suppress(let reason):
                return .suppressed(reason: reason)
            }
        }
        await delivery.present(current)
        return .delivered(current)
    }

    public enum FireResult: Sendable, Equatable {
        case delivered(NotificationEvent)
        case suppressed(reason: String)

        public static func == (lhs: FireResult, rhs: FireResult) -> Bool {
            switch (lhs, rhs) {
            case (.delivered(let a), .delivered(let b)):
                return a.id == b.id
            case (.suppressed(let a), .suppressed(let b)):
                return a == b
            default:
                return false
            }
        }
    }
}
