import Foundation

/// What a wired link actually negotiated: how fast, and in which duplex mode.
///
/// A plain value so the interesting part — deciding when a change is worth reporting, and
/// how the sentence reads — can be exercised without a cable to unplug.
public struct LinkMedia: Sendable, Equatable {
    /// "1000baseT", "100baseTX" — the media subtype's own name.
    public let speed: String?
    /// "full-duplex", "half-duplex".
    public let mode: String?
    /// The fastest the interface itself can do, when that is more than it negotiated.
    ///
    /// Only worth a line when the two disagree: a gigabit adapter that negotiated 100 Mb/s
    /// is usually a bad cable or a slow switch port, and that is a fact worth surfacing.
    /// When they match there is nothing to say.
    public let maximumSpeed: String?

    public init(speed: String? = nil, mode: String? = nil, maximumSpeed: String? = nil) {
        self.speed = speed
        self.mode = mode
        self.maximumSpeed = maximumSpeed
    }

    /// How the "you could be going faster" line reads, or nil when it is not true.
    var negotiatedNote: String? {
        guard let speed, let maximumSpeed, maximumSpeed != speed else { return nil }
        return "\(speed) (max \(maximumSpeed))"
    }
}
