import Foundation
import SentryContract
import SignalCore

/// Says when game controllers — and the keyboards/mice/racing wheels GameController.framework
/// separately recognizes — come and go.
///
/// Deliberately NOT suppressed when USB/Bluetooth Monitor also reports the same physical
/// connect: the framework exposes no transport type to tell the two apart, and this
/// notification carries genuinely new information (recognized as a game controller
/// specifically, its category, player index, battery) even when the underlying connect
/// event is the same one another monitor already announced.
public actor GamepadMonitor: Monitor {
    public static let category = GamepadEvent.category

    public static let events: [MonitorEventDescription] = [
        .init(name: GamepadEvent.controllerConnected.rawValue, title: "Game controller connected", icon: .asset("GamepadMonitor-Icon", in: .module)),
        .init(name: GamepadEvent.controllerDisconnected.rawValue, title: "Game controller disconnected", icon: .asset("GamepadMonitor-Icon", in: .module)),
        .init(name: GamepadEvent.racingWheelConnected.rawValue, title: "Racing wheel connected", icon: .asset("GamepadMonitor-Icon", in: .module)),
        .init(name: GamepadEvent.racingWheelDisconnected.rawValue, title: "Racing wheel disconnected", icon: .asset("GamepadMonitor-Icon", in: .module))
    ]

    // Only what the framework will answer about a controller that is actually here. The
    // capability lines (touchpad, adaptive triggers, motion, paddles) are off by default:
    // they never change for a given controller, so after the first connect they are the
    // same sentence every time.
    /// In the original's order, with its words and its defaults. Eight on, four off: what
    /// the controller is and what it can do, without the three capability lines that only
    /// matter to somebody who already knows their own hardware.
    public static let fields: [MonitorFieldDescription] = [
        .init(name: GamepadField.category.rawValue, title: "Controller type (DualSense/Xbox/MFi/etc.)", shownByDefault: true),
        .init(name: GamepadField.player.rawValue, title: "Player index", shownByDefault: true),
        .init(name: GamepadField.battery.rawValue, title: "Battery level", shownByDefault: true),
        .init(name: GamepadField.adaptiveTriggers.rawValue, title: "Adaptive Triggers (DualSense)", shownByDefault: true),
        .init(name: GamepadField.batteryState.rawValue, title: "Battery state (Charging/Full/Discharging)", shownByDefault: true),
        .init(name: GamepadField.touchpad.rawValue, title: "Touchpad presence (DualSense/DualShock)", shownByDefault: true),
        .init(name: GamepadField.haptics.rawValue, title: "Haptics support", shownByDefault: true),
        .init(name: GamepadField.motion.rawValue, title: "Motion sensors presence", shownByDefault: true),
        .init(name: GamepadField.lightColor.rawValue, title: "Lightbar color (read-only)", shownByDefault: false),
        .init(name: GamepadField.elitePaddles.rawValue, title: "Xbox Elite paddles presence", shownByDefault: false),
        .init(name: GamepadField.hapticLocalities.rawValue, title: "Haptic actuator locations", shownByDefault: false),
        .init(name: GamepadField.attached.rawValue, title: "Attached-to-device flag", shownByDefault: false)
    ]

    private let source: any GamepadSource
    private let context: MonitorContext
    private var watching: Task<Void, Never>?

    public init(source: any GamepadSource, context: MonitorContext) {
        self.source = source
        self.context = context
    }

    public func start() async {
        guard watching == nil else { return }

        watching = Task { [source, context] in
            for await change in source.changes() {
                guard !Task.isCancelled else { return }
                await Self.report(change, through: context)
            }
        }
    }

    public func stop() async {
        watching?.cancel()
        watching = nil
    }

    private static func report(_ change: GamepadDeviceChange, through context: MonitorContext) async {
        let event = GamepadEvent.forChange(change)
        let (title, headline) = describe(change)
        let detail = change.detail
        let icon = iconAssetName(for: change.kind, productCategory: detail?.productCategory)
        await context.notify(
            event.rawValue,
            subject: change.name ?? String(describing: change.kind),
            title: title,
            body: await context.body([
                .always(headline),
                .field(GamepadField.category.rawValue, "Type", detail?.productCategory),
                .field(GamepadField.player.rawValue, "Player", detail?.playerNote),
                .field(GamepadField.battery.rawValue, "Battery", detail?.batteryNote),
                .field(GamepadField.batteryState.rawValue, "Battery State", detail?.batteryState),
                .field(GamepadField.attached.rawValue, "Attached to device", detail?.attachedNote),
                .field(GamepadField.adaptiveTriggers.rawValue, "Adaptive Triggers", detail?.adaptiveTriggersNote),
                .field(GamepadField.touchpad.rawValue, "Touchpad", detail?.touchpadNote),
                .field(GamepadField.motion.rawValue, "Motion Sensors", detail?.motionNote),
                .field(GamepadField.haptics.rawValue, "Haptics", detail?.hapticsNote),
                .field(GamepadField.hapticLocalities.rawValue, "Haptic Actuators", detail?.hapticLocations),
                .field(GamepadField.elitePaddles.rawValue, "Elite Paddles", detail?.elitePaddlesNote),
                .field(GamepadField.lightColor.rawValue, "Lightbar Color", detail?.lightColor)
            ]),
            icon: .asset(icon, in: .module)
        )
    }

    /// Which of this module's icons matches what actually connected, keyed off
    /// `GCController.productCategory` — the same string this notification's own "Type"
    /// field already shows in words. Matched by keyword rather than an exact constant:
    /// confirmed live, a real Joy-Con (R) reports the category as "Nintendo Switch
    /// Joy-Con (R)", not the bare "Switch Joy-Con (R)" Apple's own constant name would
    /// suggest, so this looks for the word that identifies the family rather than the
    /// exact sentence. Anything unrecognised — a generic MFi controller, most
    /// third-party pads among them — keeps the original plain glyph, honest for a
    /// controller this module knows nothing more specific about. Racing wheels get their
    /// own generic icon regardless of `productCategory`: too rare a category, so far, to
    /// be worth telling apart by brand the way controllers are.
    static func iconAssetName(for kind: GamepadDeviceKind, productCategory: String?) -> String {
        guard kind == .controller, let category = productCategory?.lowercased() else {
            return "GamepadMonitor-Icon"
        }
        if category.contains("xbox") { return "GamepadMonitor-Icon-Xbox" }
        if category.contains("dualsense") || category.contains("dualshock") || category.contains("playstation") {
            return "GamepadMonitor-Icon-PlayStation"
        }
        if category.contains("joy-con") || category.contains("joycon") { return "GamepadMonitor-Icon-JoyCon" }
        if category.contains("switch pro") { return "GamepadMonitor-Icon-SwitchPro" }
        return "GamepadMonitor-Icon"
    }

    private static func describe(_ change: GamepadDeviceChange) -> (title: String, headline: String) {
        switch change.kind {
        case .controller:
            let name = change.name ?? "Game Controller"
            return (change.connected ? "Game Controller Connected" : "Game Controller Disconnected", name)
        case .racingWheel:
            let name = change.name ?? "Racing Wheel"
            return (change.connected ? "Racing Wheel Connected" : "Racing Wheel Disconnected", name)
        }
    }
}
