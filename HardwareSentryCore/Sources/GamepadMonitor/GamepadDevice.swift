import Foundation

/// Which kind of GameController-framework device changed.
public enum GamepadDeviceKind: Sendable, Equatable {
    case controller
    case keyboard
    case mouse
    case racingWheel
}

/// What a game controller could be described as when it arrived.
///
/// Read at connect: most of this is only answerable while the controller is attached, and
/// by the time it leaves there is nothing left to ask.
public struct GamepadDetail: Sendable, Equatable {
    /// The framework's own words for the product family — "DualSense", "Xbox One", "MFi".
    public let productCategory: String?
    public let playerIndex: Int?
    public let batteryPercent: Int?
    public let batteryState: String?
    public let hasAdaptiveTriggers: Bool
    public let hasTouchpad: Bool
    public let hasMotionSensors: Bool
    /// Which actuators can rumble, in words — nil when the controller has none.
    public let hapticLocations: String?
    /// Physically docked to this Mac rather than connected wirelessly.
    public let isAttachedToDevice: Bool?
    public let lightColor: String?
    public let hasElitePaddles: Bool

    public init(
        productCategory: String? = nil,
        playerIndex: Int? = nil,
        batteryPercent: Int? = nil,
        batteryState: String? = nil,
        hasAdaptiveTriggers: Bool = false,
        hasTouchpad: Bool = false,
        hasMotionSensors: Bool = false,
        hapticLocations: String? = nil,
        isAttachedToDevice: Bool? = nil,
        lightColor: String? = nil,
        hasElitePaddles: Bool = false
    ) {
        self.productCategory = productCategory
        self.playerIndex = playerIndex
        self.batteryPercent = batteryPercent
        self.batteryState = batteryState
        self.hasAdaptiveTriggers = hasAdaptiveTriggers
        self.hasTouchpad = hasTouchpad
        self.hasMotionSensors = hasMotionSensors
        self.hapticLocations = hapticLocations
        self.isAttachedToDevice = isAttachedToDevice
        self.lightColor = lightColor
        self.hasElitePaddles = hasElitePaddles
    }

    /// Only worth a line when true — telling someone their controller does *not* have a
    /// touchpad is not news.
    var touchpadNote: String? { hasTouchpad ? "Yes" : nil }
    var adaptiveTriggersNote: String? { hasAdaptiveTriggers ? "Yes" : nil }
    var motionNote: String? { hasMotionSensors ? "Yes" : nil }
    var elitePaddlesNote: String? { hasElitePaddles ? "Yes" : nil }
    var batteryNote: String? { batteryPercent.map { "\($0)%" } }
    var playerNote: String? { playerIndex.map { "\($0)" } }
    var attachedNote: String? { isAttachedToDevice.map { $0 ? "Yes" : "No" } }
}

/// The optional details this monitor can add.
public enum GamepadField: String, CaseIterable {
    case category = "Category"
    case player = "Player"
    case battery = "Battery"
    case batteryState = "BatteryState"
    case adaptiveTriggers = "AdaptiveTriggers"
    case touchpad = "Touchpad"
    case motion = "Motion"
    case haptics = "Haptics"
    case attached = "Attached"
    case lightColor = "LightColor"
    case elitePaddles = "ElitePaddles"
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
    public let detail: GamepadDetail?

    public init(kind: GamepadDeviceKind, connected: Bool, name: String? = nil, detail: GamepadDetail? = nil) {
        self.kind = kind
        self.connected = connected
        self.name = name
        self.detail = detail
    }
}

/// Where news of game controllers, and the other device kinds GameController.framework
/// separately recognizes, comes from.
public protocol GamepadSource: Sendable {
    func changes() -> AsyncStream<GamepadDeviceChange>
}
