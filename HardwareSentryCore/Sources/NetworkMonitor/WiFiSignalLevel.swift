import Foundation

/// A Wi-Fi signal reduced to the four bars macOS itself shows.
///
/// Reported in levels rather than in dBm because the raw number moves constantly: a
/// stationary laptop's RSSI wanders several dBm on its own, so notifying on the number
/// would notify forever. A level only changes when the signal has genuinely moved.
public enum WiFiSignalLevel: Int, Sendable, Equatable, Comparable, CaseIterable {
    case none = 0
    case weak = 1
    case fair = 2
    case good = 3
    case excellent = 4

    public static func < (lhs: WiFiSignalLevel, rhs: WiFiSignalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The thresholds macOS's own bars use.
    ///
    /// A reading of exactly 0 means the interface had no answer, not a perfect signal —
    /// the one value that must not be read literally.
    public init(rssi: Int) {
        switch rssi {
        case 0: self = .none
        case (-55)...: self = .excellent
        case (-65)..<(-55): self = .good
        case (-73)..<(-65): self = .fair
        case (-80)..<(-73): self = .weak
        default: self = .none
        }
    }

    public var iconName: String { "Network-Wifi-\(rawValue)" }

    /// The event raised when the signal settles at this level.
    public var event: NetworkEvent {
        switch self {
        case .none: return .wifiSignalNone
        case .weak: return .wifiSignalWeak
        case .fair: return .wifiSignalFair
        case .good: return .wifiSignalGood
        case .excellent: return .wifiSignalExcellent
        }
    }

    /// How the row is named in Settings.
    ///
    /// Both halves on purpose: the bars are what the menu bar shows, and the word is what
    /// somebody would say out loud. Either alone makes the list harder to scan.
    var settingsTitle: String {
        switch self {
        case .none: return "Signal lost (0 bars)"
        case .weak: return "Signal weak (1 bar)"
        case .fair: return "Signal fair (2 bars)"
        case .good: return "Signal good (3 bars)"
        case .excellent: return "Signal excellent (4 bars)"
        }
    }

    var label: String {
        switch self {
        case .none: return "no signal"
        case .weak: return "weak"
        case .fair: return "fair"
        case .good: return "good"
        case .excellent: return "excellent"
        }
    }
}

/// Decides when a change in signal is worth saying out loud.
///
/// Two guards, and they do different jobs. The level itself stops the constant dBm wander
/// from producing anything; the cooldown stops a signal sitting exactly on a threshold from
/// producing a notification every poll as it crosses back and forth.
///
/// The baseline is deliberately *not* advanced while the cooldown is in force. Advancing it
/// would mean a signal that drifted from excellent to weak during a quiet spell was never
/// reported at all — the cooldown is meant to delay news, not swallow it.
public struct WiFiSignalWatcher: Sendable {
    /// How long after saying something before saying anything again.
    public var cooldown: TimeInterval

    private var reported: WiFiSignalLevel?
    private var lastSpokeAt: Date?

    public init(cooldown: TimeInterval = 10) {
        self.cooldown = cooldown
    }

    /// What the notification should say, or nil to stay quiet.
    public struct Change: Sendable, Equatable {
        public let level: WiFiSignalLevel
        public let isImproving: Bool
        /// "Signal ↑ improved (3/4)", the original's shape.
        public var summary: String {
            "Signal \(isImproving ? "↑ improved" : "↓ degraded") (\(level.rawValue)/4)"
        }
    }

    /// Establishes the starting point without saying anything — used when a network is
    /// joined, so the first real movement is caught one poll sooner.
    public mutating func baseline(_ level: WiFiSignalLevel) {
        reported = level
        lastSpokeAt = nil
    }

    /// Forgets everything, so reconnecting starts fresh rather than comparing against a
    /// level from a different network.
    public mutating func reset() {
        reported = nil
        lastSpokeAt = nil
    }

    public mutating func consider(_ level: WiFiSignalLevel, now: Date = Date()) -> Change? {
        guard let previous = reported else {
            reported = level
            return nil
        }
        guard level != previous else { return nil }

        if let lastSpokeAt, cooldown > 0, now.timeIntervalSince(lastSpokeAt) < cooldown {
            return nil   // note the baseline is left alone on purpose
        }

        reported = level
        lastSpokeAt = now
        return Change(level: level, isImproving: level > previous)
    }
}
