import SignalCore

/// What this monitor can tell you about.
public enum GamepadEvent: String, NotificationEventKey {
    case controllerConnected = "GamepadConnected"
    case controllerDisconnected = "GamepadDisconnected"
    case keyboardConnected = "GamepadKeyboardConnected"
    case keyboardDisconnected = "GamepadKeyboardDisconnected"
    case mouseConnected = "GamepadMouseConnected"
    case mouseDisconnected = "GamepadMouseDisconnected"
    case racingWheelConnected = "GamepadRacingWheelConnected"
    case racingWheelDisconnected = "GamepadRacingWheelDisconnected"

    public static let category: NotificationCategory = "Gamepad"

    static func forChange(_ change: GamepadDeviceChange) -> GamepadEvent {
        switch (change.kind, change.connected) {
        case (.controller, true): return .controllerConnected
        case (.controller, false): return .controllerDisconnected
        case (.keyboard, true): return .keyboardConnected
        case (.keyboard, false): return .keyboardDisconnected
        case (.mouse, true): return .mouseConnected
        case (.mouse, false): return .mouseDisconnected
        case (.racingWheel, true): return .racingWheelConnected
        case (.racingWheel, false): return .racingWheelDisconnected
        }
    }
}
