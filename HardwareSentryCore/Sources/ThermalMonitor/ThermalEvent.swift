import SignalCore

/// What this monitor can tell you about.
///
/// One event per severity level, not one shared "ThermalStateChanged" — that is what lets
/// the dispatch pipeline's own per-event enablement do the "notify when entering Serious
/// but not Fair" gating, with no monitor-specific preferences code needed.
public enum ThermalEvent: String, NotificationEventKey {
    case nominal = "ThermalNominal"
    case fair = "ThermalFair"
    case serious = "ThermalSerious"
    case critical = "ThermalCritical"
    case darkWakeEmergency = "ThermalDarkWakeEmergency"

    public static let category: NotificationCategory = "Thermal"

    var state: ThermalState? {
        switch self {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        case .darkWakeEmergency: return nil
        }
    }

    static func forState(_ state: ThermalState) -> ThermalEvent {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        }
    }
}
