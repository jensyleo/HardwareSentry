import Foundation

/// Which kind of GameController-framework device changed.
public enum GamepadDeviceKind: Sendable, Equatable {
    case controller
    case keyboard
    case mouse
    case racingWheel
}

/// A connect or disconnect of one device GameController.framework recognizes.
///
/// `name` is the device's own reported name where the framework offers one (game
/// controllers and racing wheels do; game-recognized keyboards/mice don't) — used as the
/// event's subject, the same "name, not a per-instance identifier" choice `USBMonitor`
/// made, so the same physical device connecting and disconnecting reads as one thing.
public struct GamepadDeviceChange: Sendable, Equatable {
    public let kind: GamepadDeviceKind
    public let connected: Bool
    public let name: String?

    public init(kind: GamepadDeviceKind, connected: Bool, name: String? = nil) {
        self.kind = kind
        self.connected = connected
        self.name = name
    }
}

/// Where news of game controllers, and the other device kinds GameController.framework
/// separately recognizes, comes from.
public protocol GamepadSource: Sendable {
    func changes() -> AsyncStream<GamepadDeviceChange>
}
