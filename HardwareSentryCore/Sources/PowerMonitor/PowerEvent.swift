import SignalCore

/// What this monitor can raise.
///
/// Named as the original named them, so somebody moving between the two applications
/// finds the same rows, and so an exported profile from either is readable next to the
/// other.
public enum PowerEvent: String, NotificationEventKey, CaseIterable {
    case sourceChanged = "PowerChange"
    case fullyCharged = "PowerFullyCharged"
    case lowBatteryWarning = "PowerWarning"
    case systemSleep = "PowerSystemSleep"
    case systemWake = "PowerSystemWake"
    case screensSleep = "PowerScreensSleep"
    case screensWake = "PowerScreensWake"
    case lowPowerModeChanged = "PowerLowPowerMode"
    /// A different power adapter, or a different wattage from the same one.
    case adapterChanged = "PowerAdapterChanged"
    /// How the battery is holding up, on a schedule rather than on a change.
    case batteryHealth = "PowerBatteryHealth"
    // One row per battery rung, as the original has it: the icon each level shows, and a
    // switch for whether crossing into it is worth saying.
    case pluggedIn = "PowerPluggedIn"
    case batteryLevel0 = "PowerBattery0"
    case batteryLevel10 = "PowerBattery10"
    case batteryLevel20 = "PowerBattery20"
    case batteryLevel30 = "PowerBattery30"
    case batteryLevel40 = "PowerBattery40"
    case batteryLevel50 = "PowerBattery50"
    case batteryLevel60 = "PowerBattery60"
    case batteryLevel70 = "PowerBattery70"
    case batteryLevel80 = "PowerBattery80"
    case batteryLevel90 = "PowerBattery90"
    case batteryLevel100 = "PowerBattery100"
    case charging0 = "PowerCharging0"
    case charging10 = "PowerCharging10"
    case charging20 = "PowerCharging20"
    case charging30 = "PowerCharging30"
    case charging40 = "PowerCharging40"
    case charging50 = "PowerCharging50"
    case charging60 = "PowerCharging60"
    case charging70 = "PowerCharging70"
    case charging80 = "PowerCharging80"
    case charging90 = "PowerCharging90"
    case charging100 = "PowerCharging100"
    case batteryFailure = "PowerBatteryFailure"
    case noBattery = "PowerNoBattery"

    public static let category: NotificationCategory = "Power"
}

/// The optional details this monitor can add.
public enum PowerField: String, CaseIterable {
    case chargeLevel = "ChargeLevel"
    /// "Battery", "UPS" — what the source is, rather than what the Mac runs on.
    case sourceType = "SourceType"
    /// "Charged", "Charging", "Finishing".
    case chargeState = "ChargeState"
    /// Minutes left, or minutes until full.
    case timeRemaining = "TimeRemaining"
    /// Voltage, current, temperature and identity, on one line.
    case diagnostics = "Diagnostics"
    /// The adapter's wattage.
    case adapterWattage = "AdapterWattage"
    /// Family, ID and serial of the adapter.
    case adapterIdentity = "AdapterIdentity"
    case cycleCount = "CycleCount"
    case batteryHealthPercent = "BatteryHealthPercent"
    case batteryCondition = "BatteryCondition"
    case batteryCapacity = "BatteryCapacity"
    case batteryErrorMargin = "BatteryErrorMargin"
    /// The coarse "Good/Fair/Poor" verdict, apart from the precise condition.
    case batteryHealthCoarse = "BatteryHealthCoarse"
    /// Named faults the battery reports.
    case batteryFailureModes = "BatteryFailureModes"
    /// The battery's own internal-failure flag.
    case batteryInternalFailure = "BatteryInternalFailure"
    /// The "AC Power → Battery Power" line on a source change.
    case sourceChangeArrow = "SourceChangeArrow"

    /// How the line is named in Settings → Events, under "Include in the message".
    var settingsTitle: String {
        switch self {
        case .chargeLevel: return "Charge level"
        case .sourceType: return "Which kind of source"
        case .chargeState: return "Charging state"
        case .timeRemaining: return "Time remaining or to charge"
        case .diagnostics: return "Voltage, current, temperature, identity"
        case .adapterWattage: return "Adapter wattage"
        case .adapterIdentity: return "Adapter family, ID and serial"
        case .cycleCount: return "Cycle count"
        case .batteryHealthPercent: return "Health percentage"
        case .batteryCondition: return "Condition and overall health"
        case .batteryCapacity: return "Capacity now vs. new"
        case .batteryErrorMargin: return "Reporting error margin"
        case .batteryHealthCoarse: return "Overall health (Good/Fair/Poor)"
        case .batteryFailureModes: return "Named battery faults"
        case .batteryInternalFailure: return "Internal failure warning"
        case .sourceChangeArrow: return "Show which source it changed from"
        }
    }

    /// The ones that answer "what is this machine running on, and for how long".
    ///
    /// The diagnostics line is off because it is seven numbers that only mean something
    /// when a battery is misbehaving, and the adapter's serial is off for the same reason.
    /// On the health notification the four that make up the verdict are on, since that
    /// notification exists to carry them — a health report with its numbers switched off
    /// would say "checked your battery" and nothing else.
    var shownByDefault: Bool {
        switch self {
        case .chargeLevel, .sourceType, .chargeState, .timeRemaining,
             .adapterWattage, .cycleCount, .batteryHealthPercent,
             .batteryCondition, .batteryCapacity, .batteryHealthCoarse,
             // The two fault lines are on, and they are the only optional lines in the
             // application that only ever appear when something is wrong — so they cost
             // nothing when everything is fine. They used to be unswitchable, which was
             // the wrong call: it is not this application's place to decide that somebody
             // may not turn a line off.
             .batteryFailureModes, .batteryInternalFailure, .sourceChangeArrow:
            return true
        case .diagnostics, .adapterIdentity, .batteryErrorMargin:
            return false
        }
    }
}


/// One rung of the battery gauge.
///
/// Eleven rungs of ten per cent, which is the granularity the artwork comes in, times two
/// because a battery charging and a battery draining are not the same picture. The
/// original gives each its own row so the icon can be changed and, separately, so crossing
/// into that level can be silenced — somebody who only wants to hear about the bottom two
/// rungs should not have to hear about the other nine.
public struct PowerRung: Sendable, Equatable, Hashable {
    public let percentage: Int
    public let isCharging: Bool

    public init(percentage: Int, isCharging: Bool) {
        self.percentage = percentage
        self.isCharging = isCharging
    }

    /// Every rung, draining first and then charging, as the original lists them.
    public static let all: [PowerRung] =
        stride(from: 0, through: 100, by: 10).map { PowerRung(percentage: $0, isCharging: false) }
        + stride(from: 0, through: 100, by: 10).map { PowerRung(percentage: $0, isCharging: true) }

    public var iconBaseName: String {
        isCharging ? "Power-Charging-\(percentage)" : "Power-\(percentage)"
    }

    var settingsTitle: String {
        isCharging ? "Charging \(percentage)%" : "Battery \(percentage)%"
    }

    /// Rounded to the nearest ten, which is the granularity the artwork comes in.
    public static func rung(forPercentage percentage: Int, isCharging: Bool) -> PowerRung {
        let rounded = min(100, max(0, Int((Double(percentage) / 10).rounded()) * 10))
        return PowerRung(percentage: rounded, isCharging: isCharging)
    }

    var event: PowerEvent {
        if isCharging {
            switch percentage {
            case 0: return .charging0
            case 10: return .charging10
            case 20: return .charging20
            case 30: return .charging30
            case 40: return .charging40
            case 50: return .charging50
            case 60: return .charging60
            case 70: return .charging70
            case 80: return .charging80
            case 90: return .charging90
            default: return .charging100
            }
        }
        switch percentage {
        case 0: return .batteryLevel0
        case 10: return .batteryLevel10
        case 20: return .batteryLevel20
        case 30: return .batteryLevel30
        case 40: return .batteryLevel40
        case 50: return .batteryLevel50
        case 60: return .batteryLevel60
        case 70: return .batteryLevel70
        case 80: return .batteryLevel80
        case 90: return .batteryLevel90
        default: return .batteryLevel100
        }
    }
}
