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
        case .unknown: return "Unknown Power Source"
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
    /// What each attached power source says about itself. Usually one; a Mac with a UPS
    /// has two, and both are worth describing.
    public let sources: [PowerSourceDetail]

    public init(
        kind: PowerSourceKind,
        percentage: Int?,
        isLowBatteryWarning: Bool,
        sources: [PowerSourceDetail] = []
    ) {
        self.kind = kind
        self.percentage = percentage
        self.isLowBatteryWarning = isLowBatteryWarning
        self.sources = sources
    }
}

/// One power source, described.
public struct PowerSourceDetail: Sendable, Equatable {
    /// "Battery", "UPS" — what kind of thing this is, as distinct from what the Mac is
    /// currently running on.
    public let typeName: String?
    /// "Charged", "Charging", "Finishing" — where it is in its cycle.
    public let chargeState: String?
    public let percentage: Int?
    /// Minutes left, or minutes until full when charging. Nil while the system is still
    /// working it out, which it always is for the first minute or two after a change.
    public let minutesRemaining: Int?
    public let isCharging: Bool
    /// Voltage, current, temperature and identity — the numbers that only matter when
    /// something is wrong, which is why they are off by default.
    public let millivolts: Int?
    public let milliamps: Int?
    public let celsius: Double?
    public let name: String?
    public let serialNumber: String?
    public let vendorID: Int?
    public let productID: Int?

    public init(
        typeName: String? = nil,
        chargeState: String? = nil,
        percentage: Int? = nil,
        minutesRemaining: Int? = nil,
        isCharging: Bool = false,
        millivolts: Int? = nil,
        milliamps: Int? = nil,
        celsius: Double? = nil,
        name: String? = nil,
        serialNumber: String? = nil,
        vendorID: Int? = nil,
        productID: Int? = nil
    ) {
        self.typeName = typeName
        self.chargeState = chargeState
        self.percentage = percentage
        self.minutesRemaining = minutesRemaining
        self.isCharging = isCharging
        self.millivolts = millivolts
        self.milliamps = milliamps
        self.celsius = celsius
        self.name = name
        self.serialNumber = serialNumber
        self.vendorID = vendorID
        self.productID = productID
    }

    /// The source's own status sentence: "Battery: Charging at 85%".
    ///
    /// Assembled from whichever parts are known, and empty when none are. The parts are
    /// separately switchable, so somebody who wants only the percentage gets "85%" rather
    /// than a sentence with holes in it.
    public func statusLine(showType: Bool, showState: Bool, showPercentage: Bool) -> String? {
        var head: String?
        if showType, let typeName { head = typeName }

        var tail: [String] = []
        if showState, let chargeState { tail.append(chargeState) }
        if showPercentage, let percentage {
            tail.append(tail.isEmpty ? "\(percentage)%" : "at \(percentage)%")
        }

        let body = tail.joined(separator: " ")
        if let head { return body.isEmpty ? head : "\(head): \(body)" }
        return body.isEmpty ? nil : body
    }

    /// How long is left, worded for which direction it is going.
    var timeNote: String? {
        guard let minutesRemaining, minutesRemaining > 0 else { return nil }
        return isCharging
            ? "Time to charge: \(minutesRemaining) minutes"
            : "Time remaining: \(minutesRemaining) minutes"
    }

    /// The diagnostic numbers, joined. One line rather than seven, because they are read
    /// together or not at all.
    var diagnosticsNote: String? {
        var parts: [String] = []
        if let millivolts { parts.append("\(millivolts) mV") }
        if let milliamps { parts.append("\(milliamps) mA") }
        if let celsius { parts.append(String(format: "%.1f°C", celsius)) }
        if let chargeState { parts.append("State: \(chargeState)") }
        if let name { parts.append("Name: \(name)") }
        if let serialNumber { parts.append("Serial: \(serialNumber)") }
        if let vendorID, let productID {
            parts.append(String(format: "VID/PID: 0x%04X/0x%04X", vendorID, productID))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// What the power adapter says about itself.
public struct PowerAdapterDetail: Sendable, Equatable {
    public let watts: Int?
    public let family: String?
    public let adapterID: String?
    public let serialNumber: String?

    public init(watts: Int? = nil, family: String? = nil, adapterID: String? = nil, serialNumber: String? = nil) {
        self.watts = watts
        self.family = family
        self.adapterID = adapterID
        self.serialNumber = serialNumber
    }

    /// The wattage, or an honest admission when the adapter did not say.
    ///
    /// A third-party or passive adapter often reports nothing, and "0W" would read as a
    /// broken adapter rather than an unlabelled one.
    var wattageLabel: String { watts.map { "\($0)W" } ?? "Unknown wattage" }
}

/// What a battery says about its own condition.
public struct BatteryHealthDetail: Sendable, Equatable {
    public let cycleCount: Int?
    /// What Apple rates this battery for, when the system says.
    public let designCycleCount: Int?
    /// Current capacity as a percentage of what it held when new.
    public let healthPercent: Int?
    /// "Normal", "Service Recommended" — the system's own verdict.
    public let condition: String?
    /// "Good", "Fair", "Poor" — the coarser summary macOS shows in Settings.
    public let coarseHealth: String?
    /// Named faults, when the battery reports any.
    public let failureModes: [String]
    public let hasInternalFailure: Bool
    public let currentCapacityMAh: Int?
    public let designCapacityMAh: Int?
    /// How far off the capacity reading might be, as a percentage.
    public let maximumErrorPercent: Int?

    public init(
        cycleCount: Int? = nil,
        designCycleCount: Int? = nil,
        healthPercent: Int? = nil,
        condition: String? = nil,
        coarseHealth: String? = nil,
        failureModes: [String] = [],
        hasInternalFailure: Bool = false,
        currentCapacityMAh: Int? = nil,
        designCapacityMAh: Int? = nil,
        maximumErrorPercent: Int? = nil
    ) {
        self.cycleCount = cycleCount
        self.designCycleCount = designCycleCount
        self.healthPercent = healthPercent
        self.condition = condition
        self.coarseHealth = coarseHealth
        self.failureModes = failureModes
        self.hasInternalFailure = hasInternalFailure
        self.currentCapacityMAh = currentCapacityMAh
        self.designCapacityMAh = designCapacityMAh
        self.maximumErrorPercent = maximumErrorPercent
    }

    /// The cycle count with its rating alongside, because the number alone says nothing.
    /// A thousand cycles is worn out on one battery and half-used on another.
    var cycleNote: String? {
        guard let cycleCount else { return nil }
        guard let designCycleCount, designCycleCount > 0 else { return "Cycle count: \(cycleCount)" }
        return "Cycle count: \(cycleCount) (rated for ~\(designCycleCount))"
    }

    var healthNote: String? { healthPercent.map { "Battery health: \($0)%" } }
    var conditionNote: String? { condition.map { "Condition: \($0)" } }
    var coarseNote: String? { coarseHealth.map { "Health (overall): \($0)" } }

    var failuresNote: String? {
        failureModes.isEmpty ? nil : "Battery failures: \(failureModes.joined(separator: ", "))"
    }

    var internalFailureNote: String? {
        hasInternalFailure ? "⚠️ Internal battery failure reported" : nil
    }

    /// Now against new, which is the comparison that makes either number mean something.
    var capacityNote: String? {
        guard let currentCapacityMAh, let designCapacityMAh else { return nil }
        return "Capacity: \(currentCapacityMAh) mAh now vs. \(designCapacityMAh) mAh new"
    }

    var errorMarginNote: String? {
        // Zero is the battery saying it is confident, not saying nothing.
        guard let maximumErrorPercent, maximumErrorPercent > 0 else { return nil }
        return "Reporting error margin: ±\(maximumErrorPercent)%"
    }

    /// Whether there is anything at all worth reporting.
    public var isEmpty: Bool {
        cycleCount == nil && healthPercent == nil && condition == nil
            && coarseHealth == nil && failureModes.isEmpty && !hasInternalFailure
            && currentCapacityMAh == nil && maximumErrorPercent == nil
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
    /// The adapter that is plugged in, or nil when nothing is.
    case adapter(PowerAdapterDetail?)
}

public protocol PowerSource: Sendable {
    func changes() -> AsyncStream<PowerSourceEvent>

    /// Reads the battery's condition, now.
    ///
    /// Asked for rather than pushed, unlike everything else here: battery health does not
    /// change from one minute to the next, so there is no notification to subscribe to and
    /// nothing to react to. Whoever wants to know has to go and look, and deciding how
    /// often to look is a policy question that belongs with the monitor rather than with
    /// the plumbing that reads IOKit.
    func readBatteryHealth() async -> BatteryHealthDetail?
}

public extension PowerSource {
    /// A source with nothing to say about battery health — a test double, or a Mac with
    /// no battery in it.
    func readBatteryHealth() async -> BatteryHealthDetail? { nil }
}
