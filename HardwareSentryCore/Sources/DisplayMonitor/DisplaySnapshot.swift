import Foundation

public enum DisplayRole: Sendable, Equatable {
    case main
    case mirrored
    case extended
}

/// A display's state as of one read of `CGGetOnlineDisplayList` — enough to notice a
/// connect/disconnect, a mode change (resolution/refresh rate/rotation — folded into one
/// signature the way HG4MAC does, since a physical rotation already changes the reported
/// pixel width/height), a role change, or it falling asleep/waking, all without the
/// display having gone offline in between.
public struct DisplaySnapshot: Sendable, Equatable {
    public let id: String
    public let name: String
    public let width: Int
    public let height: Int
    public let refreshHz: Double
    public let rotation: Double
    public let role: DisplayRole
    public let isAsleep: Bool
    /// What the display could be described as, read once when it appeared. Absent for a
    /// display seen only through a scripted snapshot in a test.
    public let detail: DisplayDetail?

    public init(id: String, name: String, width: Int, height: Int, refreshHz: Double, rotation: Double, role: DisplayRole, isAsleep: Bool, detail: DisplayDetail? = nil) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.refreshHz = refreshHz
        self.rotation = rotation
        self.role = role
        self.isAsleep = isAsleep
        self.detail = detail
    }

    /// Resolution + refresh rate + rotation, compared at the precision actually shown
    /// (nearest whole Hz/degree) — what the user would read is what should decide whether
    /// this counts as a real change.
    var modeSignature: String {
        "\(width)x\(height)@\(refreshHz.rounded())@r\(rotation.rounded())"
    }
}

/// What the system told this monitor just happened.
public enum DisplaySourceEvent: Sendable, Equatable {
    /// The full current set of online displays — not a delta. `CGDisplayRegisterReconfigurationCallback`
    /// carries no per-display detail either; every callback means "go re-read what's online
    /// now", and the monitor is what turns that into connect/disconnect/mode/role/sleep.
    case snapshot([DisplaySnapshot])
    /// A display's ICC color profile changed somewhere on the system (System Settings,
    /// Night Shift/True Tone, or a calibration tool) — not tied to any specific display ID.
    case colorProfileChanged
}

public protocol DisplaySource: Sendable {
    func changes() -> AsyncStream<DisplaySourceEvent>
}
