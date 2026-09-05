import SignalCore

/// What this monitor can tell you about.
///
/// No keyboard/mouse row on purpose. HG4MAC has one (`GCKeyboardDidConnect`/
/// `GCMouseDidConnect`), on the belief that these only fire for a "Made for Game
/// Controllers"-recognized keyboard or mouse, not an ordinary one — its own comment says
/// so directly. Reported live, 2026-09-05: with that switch on, a completely ordinary
/// keyboard and mouse — nothing marketed as gaming hardware — announced themselves through
/// it. macOS's GameController framework does not expose a way to tell "an app opted a
/// dedicated gaming peripheral into game input" apart from "any keyboard/mouse the system
/// already has", so a switch promising the former cannot honestly be built from this API.
/// Removed rather than kept and mislabelled — see `PARITY.md` for how this is recorded
/// against HG4MAC.
public enum GamepadEvent: String, NotificationEventKey {
    case controllerConnected = "GamepadConnected"
    case controllerDisconnected = "GamepadDisconnected"
    case racingWheelConnected = "GamepadRacingWheelConnected"
    case racingWheelDisconnected = "GamepadRacingWheelDisconnected"

    public static let category: NotificationCategory = "Gamepad"

    static func forChange(_ change: GamepadDeviceChange) -> GamepadEvent {
        switch (change.kind, change.connected) {
        case (.controller, true): return .controllerConnected
        case (.controller, false): return .controllerDisconnected
        case (.racingWheel, true): return .racingWheelConnected
        case (.racingWheel, false): return .racingWheelDisconnected
        }
    }
}
