import Foundation

/// How hard the Mac is throttling itself to stay cool, least to most severe.
public enum ThermalState: Int, Sendable, Equatable, Comparable, CaseIterable {
    case nominal
    case fair
    case serious
    case critical

    public static func < (lhs: ThermalState, rhs: ThermalState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// What this level means for the Mac's performance right now.
    public var meaning: String {
        switch self {
        case .nominal: return "running normally"
        case .fair: return "slightly elevated"
        case .serious: return "performance reduced"
        case .critical: return "performance significantly reduced"
        }
    }

    public var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }
}
