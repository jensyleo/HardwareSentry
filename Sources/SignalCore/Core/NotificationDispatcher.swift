import Foundation

/// The central actor every emitting module talks to.
///
/// Being an `actor` gives data-race safety at the type-system level — no lock blocks,
/// no static mutable globals, no manually guarded dictionaries. It replaces a legacy
/// design in which the disabled-module check, deduplication, instability detection,
/// history recording and final dispatch were all inlined into one method, with an
/// ordered pipeline of independently testable stages plus a pluggable delivery channel.
public actor NotificationDispatcher {
    private var pipeline: [any NotificationMiddleware]
    private var delivery: any NotificationDelivering
    private var phase: DispatchPhase
    private let now: @Sendable () -> Date

    public init(
        pipeline: [any NotificationMiddleware] = [],
        delivery: any NotificationDelivering,
        phase: DispatchPhase = .steady,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.pipeline = pipeline
        self.delivery = delivery
        self.phase = phase
        self.now = now
    }

    public func setPipeline(_ pipeline: [any NotificationMiddleware]) {
        self.pipeline = pipeline
    }

    public func setDelivery(_ delivery: any NotificationDelivering) {
        self.delivery = delivery
    }

    /// Switches the phase stamped onto subsequent events.
    ///
    /// A host announcing pre-existing state at startup sets `.launching` before it
    /// begins and `.steady` once that sweep is done.
    public func setPhase(_ phase: DispatchPhase) {
        self.phase = phase
    }

    /// Runs `event` through every registered stage in order, then hands the (possibly
    /// transformed) result to the delivery channel — unless a stage suppresses it first.
    @discardableResult
    public func fire(_ event: NotificationEvent) async -> FireResult {
        let context = DispatchContext(phase: phase, firedAt: now())
        var current = event

        for stage in pipeline {
            switch await stage.process(current, context: context) {
            case .deliver(let updated):
                current = updated
            case .suppress(let reason):
                return .suppressed(reason: reason)
            }
        }

        let outcome = await delivery.present(current, context: context)
        return .delivered(current, outcome: outcome)
    }

    public enum FireResult: Sendable {
        /// The event cleared the pipeline and was handed to the delivery channel, which
        /// reported the enclosed outcome. Reaching delivery and being shown are separate
        /// things: a channel can accept an event and still fail to present it.
        case delivered(NotificationEvent, outcome: DeliveryOutcome)
        case suppressed(reason: String)

        public var isDelivered: Bool {
            if case .delivered = self { return true }
            return false
        }

        /// The event as it reached delivery, after any stage transformed it.
        public var deliveredEvent: NotificationEvent? {
            if case .delivered(let event, _) = self { return event }
            return nil
        }

        public var deliveryOutcome: DeliveryOutcome? {
            if case .delivered(_, let outcome) = self { return outcome }
            return nil
        }

        public var suppressionReason: String? {
            if case .suppressed(let reason) = self { return reason }
            return nil
        }
    }
}
