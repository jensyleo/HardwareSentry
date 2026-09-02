import SignalCore

/// What this monitor can raise.
///
/// Named as the original named them, so somebody moving between the two applications
/// finds the same rows, and so an exported profile from either is readable next to the
/// other.
public enum PowerEvent: String, NotificationEventKey {
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
