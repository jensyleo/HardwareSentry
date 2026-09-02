import Foundation
import GameController

/// Reads a connected controller for everything the framework will answer about it.
///
/// Read at connect and never again: a controller that has just left answers `nil`, `0`, or
/// a stale cached value to most of this, and a stale battery reading presented as current
/// is worse than no battery line at all.
///
/// Untested for the same reason `GameControllerSource` is — every branch needs a physical
/// controller of a specific make plugged into a real Mac. The parts worth reasoning about
/// (which lines appear, in what order, under which preferences) live in `GamepadMonitor`
/// and are tested there against a `GamepadDetail` built by hand.
extension GamepadDetail {
    init(controller: GCController) {
        let profile = controller.extendedGamepad

        self.init(
            productCategory: controller.productCategory.isEmpty ? nil : controller.productCategory,
            // `.indexUnset` is the framework's "nobody assigned one", not player 0.
            playerIndex: controller.playerIndex == .indexUnset ? nil : controller.playerIndex.rawValue,
            // A controller with no reading reports a negative level; shown literally that
            // becomes a charge of "-100%", which is worse than saying nothing.
            batteryPercent: controller.battery
                .map { Int(($0.batteryLevel * 100).rounded()) }
                .flatMap { $0 >= 0 ? $0 : nil },
            batteryState: controller.battery.flatMap { Self.describe($0.batteryState) },
            hasAdaptiveTriggers: profile is GCDualSenseGamepad,
            hasTouchpad: profile is GCDualSenseGamepad || profile is GCDualShockGamepad,
            hasMotionSensors: controller.motion != nil,
            hapticLocations: controller.haptics.flatMap { Self.describe($0.supportedLocalities) },
            isAttachedToDevice: controller.isAttachedToDevice,
            lightColor: controller.light.map { Self.describe($0.color) },
            // The Elite/Series X paddles are the only optional buttons the Xbox profile
            // exposes; a plain Xbox controller reports them as nil.
            hasElitePaddles: (profile as? GCXboxGamepad)?.paddleButton1 != nil
        )
    }

    private static func describe(_ state: GCDeviceBattery.State) -> String? {
        switch state {
        case .charging: return "Charging"
        case .full: return "Full"
        case .discharging: return "Discharging"
        case .unknown: return "Unknown"
        @unknown default: return nil
        }
    }

    private static func describe(_ localities: Set<GCHapticsLocality>) -> String? {
        // `.all` is present on essentially every controller that has haptics at all, so on
        // its own it says nothing; the specific places are what is worth reading.
        let named = localities
            .filter { $0 != .all && $0 != .default }
            .compactMap { Self.hapticNames[$0] }
            .sorted()
        if !named.isEmpty { return named.joined(separator: ", ") }
        return localities.isEmpty ? nil : "Supported"
    }

    /// The lightbar's own 0-255 channel values, not percentages: that is the scale
    /// anyone setting a controller's colour works in.
    private static func describe(_ color: GCColor) -> String {
        String(
            format: "R%.0f G%.0f B%.0f",
            color.red * 255, color.green * 255, color.blue * 255
        )
    }

    /// The actuator positions in ordinary words, rather than the framework's raw
    /// identifiers.
    private static let hapticNames: [GCHapticsLocality: String] = [
        .leftHandle: "Left Handle",
        .rightHandle: "Right Handle",
        .leftTrigger: "Left Trigger",
        .rightTrigger: "Right Trigger"
    ]
}
