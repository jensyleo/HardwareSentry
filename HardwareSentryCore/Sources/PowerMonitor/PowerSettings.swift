import Foundation

/// How often, if at all, the current power status should be said again.
///
/// A notifier that speaks only on change is silent for hours on a laptop nobody unplugs,
/// which is fine — until the one time you want to know how the battery is doing without
/// going to look. Off by default all the same: a message that arrives when nothing has
/// happened is the definition of noise for anyone who did not ask for it.
public struct PowerRefireSettings: Sendable, Equatable {
    public let isEnabled: Bool
    public let interval: Duration
    /// Repeat only while running on battery.
    ///
    /// The usual reason to want this at all is to keep an eye on a charge that is going
    /// down; plugged in, the same message every ten minutes says the same thing every
    /// ten minutes.
    public let onlyOnBattery: Bool

    /// Clamped rather than trusted: a stored interval of zero would be a message every
    /// time round the loop, which reads as a stuck application rather than as a setting
    /// somebody chose badly.
    public init(isEnabled: Bool = false, minutes: Double = 30, onlyOnBattery: Bool = true) {
        self.isEnabled = isEnabled
        self.interval = .seconds(min(24 * 60 * 60, max(60, minutes * 60)))
        self.onlyOnBattery = onlyOnBattery
    }

    public static let off = PowerRefireSettings()
}

/// How often the battery's condition is read.
public struct PowerHealthCheckSettings: Sendable, Equatable {
    public let isEnabled: Bool
    public let interval: Duration

    /// Weekly, and on by default: a battery losing capacity is exactly the kind of slow
    /// change nobody notices until it strands them, and a check that costs one IOKit read
    /// a week is not a cost worth a switch being off for.
    public init(isEnabled: Bool = true, days: Double = 7) {
        self.isEnabled = isEnabled
        self.interval = .seconds(min(365, max(1, days)) * 24 * 60 * 60)
    }

    public static let off = PowerHealthCheckSettings(isEnabled: false)
}

/// A more frequent, optional reminder of the same health numbers — in hours rather than
/// days, and independent of "Check every".
///
/// The weekly check above answers "has anything changed"; this answers "remind me what
/// the numbers are" on its own schedule, for someone who wants to see the figure more
/// often than the battery is likely to have moved. Off by default: repeating an unchanged
/// number is the more surprising of the two behaviours, so it is the one that has to be
/// asked for.
public struct PowerHealthNotifySettings: Sendable, Equatable {
    public let isEnabled: Bool
    public let interval: Duration

    public init(isEnabled: Bool = false, hours: Double = 8) {
        self.isEnabled = isEnabled
        self.interval = .seconds(min(31 * 24, max(1, hours)) * 60 * 60)
    }

    public static let off = PowerHealthNotifySettings()
}

/// Remembers what the last battery check found, across launches.
///
/// Needed because the interesting thing about battery health is that it changed, and a
/// value held only in memory makes every launch look like the first reading — which
/// would either announce the same health figure forever or never announce it at all.
public protocol PowerHealthStore: Sendable {
    func lastCheck() async -> Date?
    func lastReportedSummary() async -> String?
    func record(summary: String, at date: Date) async
    /// Only the date moves: the check happened, and found nothing new to say.
    func recordCheck(at date: Date) async
}

/// The default: one date and one string in the ordinary preferences file.
///
/// Two keys rather than an archived struct, so a stored value stays readable — and so a
/// future field can be added without a stored blob from an older version becoming
/// undecodable and silently resetting somebody's history.
public actor UserDefaultsPowerHealthStore: PowerHealthStore {
    private let defaults: UserDefaults
    private static let dateKey = "Power.LastHealthCheck"
    private static let summaryKey = "Power.LastHealthSummary"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func lastCheck() async -> Date? {
        defaults.object(forKey: Self.dateKey) as? Date
    }

    public func lastReportedSummary() async -> String? {
        defaults.string(forKey: Self.summaryKey)
    }

    public func record(summary: String, at date: Date) async {
        defaults.set(summary, forKey: Self.summaryKey)
        defaults.set(date, forKey: Self.dateKey)
    }

    public func recordCheck(at date: Date) async {
        defaults.set(date, forKey: Self.dateKey)
    }
}

/// Keeps it in memory. For tests, and for a host that would rather not persist anything.
public actor EphemeralPowerHealthStore: PowerHealthStore {
    private var date: Date?
    private var summary: String?

    public init() {}

    public func lastCheck() async -> Date? { date }
    public func lastReportedSummary() async -> String? { summary }

    public func record(summary: String, at date: Date) async {
        self.summary = summary
        self.date = date
    }

    public func recordCheck(at date: Date) async { self.date = date }
}
