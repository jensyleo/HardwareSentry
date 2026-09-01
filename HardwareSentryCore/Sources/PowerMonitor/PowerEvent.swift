import SignalCore

/// What this monitor can tell you about.
///
/// `fullyCharged` is a deliberate deviation from HG4MAC: the original folds "battery fully
/// charged" into the same `PowerChange` note name, distinguished only by its
/// `identifierString` — this app's dispatch pipeline gates by event NAME, so it gets its
/// own name instead, the same choice already made for Thunderbolt Monitor's eGPU pair.
public enum PowerEvent: String, NotificationEventKey {
    case sourceChanged = "PowerChange"
    case fullyCharged = "PowerFullyCharged"
    case lowBatteryWarning = "PowerWarning"
    case systemSleep = "PowerSystemSleep"
    case systemWake = "PowerSystemWake"
    case screensSleep = "PowerScreensSleep"
    case screensWake = "PowerScreensWake"
    case lowPowerModeChanged = "PowerLowPowerMode"

    public static let category: NotificationCategory = "Power"
}

/// The optional details this monitor can add.
public enum PowerField: String, CaseIterable {
    case chargeLevel = "ChargeLevel"
}
