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
    /// When something was last raised, which is how `settleToSteady` knows the opening
    /// rush is over.
    private var lastFiredAt: Date?

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

    /// Waits for the opening rush to die down, then switches to `.steady`.
    ///
    /// Everything already attached is announced at launch, and how long that takes depends
    /// on how much is attached — a Mac with twenty things plugged in is still going when
    /// one with two has finished. A fixed wait is therefore either too short on a busy
    /// machine or wasted time on a quiet one; waiting for quiet fits both.
    ///
    /// `timeout` is the backstop for a machine where something genuinely never stops
    /// talking: better to declare the start-up over and treat the rest as ordinary news
    /// than to stay in the opening phase forever, where duplicate suppression and the
    /// larger queue are tuned for a burst rather than for daily use.
    public func settleToSteady(
        afterQuiet quiet: Duration = .seconds(2),
        timeout: Duration = .seconds(30),
        checkingEvery interval: Duration = .milliseconds(250)
    ) async {
        let quietSeconds = TimeInterval(quiet.components.seconds) + Double(quiet.components.attoseconds) / 1e18
        let startedAt = now()
        let deadline = startedAt.addingTimeInterval(
            TimeInterval(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        )

        while now() < deadline {
            // Counted from the later of "the last thing raised" and "when this started
            // waiting". Counting only from the last event would call it settled the
            // instant this is entered, before the monitors have had a chance to say
            // anything — nothing raised *yet* is not the same as nothing left to raise.
            let reference = max(lastFiredAt ?? .distantPast, startedAt)
            if now().timeIntervalSince(reference) >= quietSeconds { break }
            try? await Task.sleep(for: interval)
        }

        phase = .steady
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
        let firedAt = now()
        lastFiredAt = firedAt
        let context = DispatchContext(phase: phase, firedAt: firedAt)
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
