import Foundation

/// A Bluetooth signal reduced to four bars.
///
/// The same dBm thresholds the Wi-Fi bars use, because both are raw receiver strength in
/// dBm — the original makes the same choice and says outright that it is a reasonable
/// assumption rather than a documented one: Bluetooth firmwares do not publish a standard
/// range the way Wi-Fi chipsets do.
///
/// Zero is **not** treated as "no reading" here, which is where this differs from Wi-Fi
/// and is the whole reason the signal line was going missing. A Wi-Fi interface answers
/// zero when it has nothing to say; classic Bluetooth reports RSSI relative to its golden
/// receive range, where zero means "comfortably inside it" — a real and rather good
/// reading. The sentinel for "not available" is 127, and that is the only value to refuse.
/// The weakest case is `lost` rather than `none` on purpose: this type is handed back as
/// an optional, and a case called `none` inside an `Optional` is ambiguous with the
/// absence of a value — `== .none` silently means "is nil" instead of "is zero bars".
/// Caught by a test that asserted a real reading was nil and passed.
public enum BluetoothSignalLevel: Int, Sendable, Equatable, Comparable, CaseIterable {
    case lost = 0
    case weak = 1
    case fair = 2
    case good = 3
    case excellent = 4

    /// What IOBluetooth answers when it has no reading. A real device never reports it.
    public static let unavailableRSSI = 127

    public static func < (lhs: BluetoothSignalLevel, rhs: BluetoothSignalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Nil for the "not available" sentinel, which is not a level.
    public init?(rssi: Int) {
        guard rssi != Self.unavailableRSSI else { return nil }
        switch rssi {
        case (-55)...: self = .excellent
        case (-65)..<(-55): self = .good
        case (-73)..<(-65): self = .fair
        case (-80)..<(-73): self = .weak
        default: self = .lost
        }
    }

    public var iconName: String { "Bluetooth-Signal-\(rawValue)" }

    var event: BluetoothEvent {
        switch self {
        case .lost: return .signalNone
        case .weak: return .signalWeak
        case .fair: return .signalFair
        case .good: return .signalGood
        case .excellent: return .signalExcellent
        }
    }

    var settingsTitle: String {
        switch self {
        case .lost: return "Signal lost (0 bars)"
        case .weak: return "Signal weak (1 bar)"
        case .fair: return "Signal fair (2 bars)"
        case .good: return "Signal good (3 bars)"
        case .excellent: return "Signal excellent (4 bars)"
        }
    }
}

/// Decides when one device's signal moving is worth saying out loud.
///
/// Per device, not per radio: two accessories on the same Mac drift independently, and a
/// keyboard on the desk should not have its level compared with a headset in another room.
/// The rest of the reasoning is the Wi-Fi watcher's, deliberately — baseline the first
/// reading without speaking, report only when the level changes, and hold off for a
/// cooldown afterwards without advancing the baseline, so a signal that keeps sliding
/// during the quiet spell is still reported when it lifts.
public struct BluetoothSignalWatcher: Sendable {
    public var cooldown: TimeInterval

    private var reported: [String: BluetoothSignalLevel] = [:]
    private var lastSpokeAt: [String: Date] = [:]

    /// Fifteen seconds, the original's figure.
    public init(cooldown: TimeInterval = 15) {
        self.cooldown = max(0, cooldown)
    }

    public struct Change: Sendable, Equatable {
        public let address: String
        public let name: String
        public let level: BluetoothSignalLevel
        public let isImproving: Bool

        /// "Signal ↑ improved (3/4)", the original's shape.
        public var summary: String {
            "Signal \(isImproving ? "↑ improved" : "↓ degraded") (\(level.rawValue)/4)"
        }
    }

    public mutating func consider(
        address: String,
        name: String,
        rssi: Int,
        now: Date = Date()
    ) -> Change? {
        guard let level = BluetoothSignalLevel(rssi: rssi) else { return nil }

        guard let previous = reported[address] else {
            reported[address] = level
            return nil
        }
        guard level != previous else { return nil }

        if let last = lastSpokeAt[address], cooldown > 0, now.timeIntervalSince(last) < cooldown {
            return nil   // the baseline is left alone on purpose
        }

        reported[address] = level
        lastSpokeAt[address] = now
        return Change(address: address, name: name, level: level, isImproving: level > previous)
    }

    /// A device that has gone is forgotten, so reconnecting baselines afresh rather than
    /// comparing against a level from before it left the room.
    public mutating func forget(_ address: String) {
        reported.removeValue(forKey: address)
        lastSpokeAt.removeValue(forKey: address)
    }

    /// Keeps only the devices still connected.
    public mutating func keepOnly(_ addresses: Set<String>) {
        reported = reported.filter { addresses.contains($0.key) }
        lastSpokeAt = lastSpokeAt.filter { addresses.contains($0.key) }
    }
}
