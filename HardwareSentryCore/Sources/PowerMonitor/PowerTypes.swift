import Foundation

public enum PowerSourceKind: Sendable, Equatable {
    case ac
    case battery
    case ups
    case unknown

    var label: String {
        switch self {
        case .ac: return "AC Power"
        case .battery: return "Battery Power"
        case .ups: return "UPS Power"
        case .unknown: return "Unknown Power"
        }
    }
}

/// One read of `IOPSCopyPowerSourcesInfo()` — which power source is providing power right
/// now, the highest percentage across every power source found (there can be more than one
/// with a UPS attached), and whether the system's own low-battery warning is active.
public struct PowerSnapshot: Sendable, Equatable {
    public let kind: PowerSourceKind
    public let percentage: Int?
    public let isLowBatteryWarning: Bool

    public init(kind: PowerSourceKind, percentage: Int?, isLowBatteryWarning: Bool) {
        self.kind = kind
        self.percentage = percentage
        self.isLowBatteryWarning = isLowBatteryWarning
    }
}

/// What the system told this monitor just happened.
public enum PowerSourceEvent: Sendable, Equatable {
    case snapshot(PowerSnapshot)
    case systemWillSleep
    case systemDidWake
    case screensDidSleep
    case screensDidWake
    case lowPowerModeChanged(Bool)
}

public protocol PowerSource: Sendable {
    func changes() -> AsyncStream<PowerSourceEvent>
}
