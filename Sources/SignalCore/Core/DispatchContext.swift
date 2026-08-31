import Foundation

/// Which phase of the host application's lifetime an event belongs to.
///
/// The distinction is not cosmetic. At startup an application typically announces the
/// existing state of everything it monitors at once — dozens of events within a few
/// milliseconds — whereas during normal operation events trickle in. Stages that
/// coalesce, rate-limit or queue need to tell those situations apart: during a startup
/// burst the priority is not to lose anything, while in steady state the priority is to
/// surface things promptly.
public enum DispatchPhase: Sendable, Equatable {
    /// The host is announcing pre-existing state at startup.
    case launching
    /// Normal operation: events reflect changes that just happened.
    case steady
}

/// Metadata the dispatcher stamps onto every event as it enters the pipeline.
///
/// Kept separate from `NotificationEvent` so that the event stays purely "what the
/// module said", with no fields a caller is expected to leave untouched.
public struct DispatchContext: Sendable, Equatable {
    public let phase: DispatchPhase
    public let firedAt: Date

    public init(phase: DispatchPhase, firedAt: Date) {
        self.phase = phase
        self.firedAt = firedAt
    }
}
