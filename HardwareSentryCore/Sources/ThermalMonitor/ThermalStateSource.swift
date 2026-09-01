import Foundation

/// Where news of the Mac's thermal state comes from.
///
/// A protocol so the monitor's own behaviour can be exercised without needing to actually
/// force the machine to throttle.
public protocol ThermalStateSource: Sendable {
    /// The state right now, read once at startup to establish a baseline.
    func currentState() -> ThermalState

    /// Every state the Mac moves through after that baseline.
    func stateChanges() -> AsyncStream<ThermalState>

    /// A ping each time the Mac overheats badly enough, during a brief maintenance wake,
    /// that it may go straight back to sleep to cool down. Distinct from the ordinary
    /// state levels above — this can happen and resolve between two `stateChanges` ticks.
    func darkWakeEmergencies() -> AsyncStream<Void>
}
