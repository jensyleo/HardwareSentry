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
        .init(name: GamepadEvent.controllerConnected.rawValue, title: "Game controller connected"),
        .init(name: GamepadEvent.controllerDisconnected.rawValue, title: "Game controller disconnected"),
        .init(name: GamepadEvent.keyboardConnected.rawValue, title: "Game-recognized keyboard connected", enabledByDefault: false),
        .init(name: GamepadEvent.keyboardDisconnected.rawValue, title: "Game-recognized keyboard disconnected", enabledByDefault: false),
        .init(name: GamepadEvent.mouseConnected.rawValue, title: "Game-recognized mouse connected", enabledByDefault: false),
        .init(name: GamepadEvent.mouseDisconnected.rawValue, title: "Game-recognized mouse disconnected", enabledByDefault: false),
        .init(name: GamepadEvent.racingWheelConnected.rawValue, title: "Racing wheel connected"),
        .init(name: GamepadEvent.racingWheelDisconnected.rawValue, title: "Racing wheel disconnected")
    ]

    // Only what the framework will answer about a controller that is actually here. The
    // capability lines (touchpad, adaptive triggers, motion, paddles) are off by default:
    // they never change for a given controller, so after the first connect they are the
    // same sentence every time.
    public static let fields: [MonitorFieldDescription] = [
        .init(name: GamepadField.category.rawValue, title: "Product category", shownByDefault: true),
        .init(name: GamepadField.player.rawValue, title: "Player index", shownByDefault: true),
        .init(name: GamepadField.battery.rawValue, title: "Battery level", shownByDefault: true),
        .init(name: GamepadField.batteryState.rawValue, title: "Charging state", shownByDefault: true),
        .init(name: GamepadField.attached.rawValue, title: "Attached to this Mac", shownByDefault: false),
        .init(name: GamepadField.adaptiveTriggers.rawValue, title: "Has adaptive triggers", shownByDefault: false),
        .init(name: GamepadField.touchpad.rawValue, title: "Has a touchpad", shownByDefault: false),
        .init(name: GamepadField.motion.rawValue, title: "Has motion sensors", shownByDefault: false),
        .init(name: GamepadField.haptics.rawValue, title: "Haptic locations", shownByDefault: false),
        .init(name: GamepadField.elitePaddles.rawValue, title: "Has rear paddles", shownByDefault: false),
        .init(name: GamepadField.lightColor.rawValue, title: "Light colour", shownByDefault: false)
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
        await context.notify(
            event.rawValue,
            subject: change.name ?? String(describing: change.kind),
            title: title,
            body: await context.body([
                .always(headline),
                .field(GamepadField.category.rawValue, "Category", detail?.productCategory),
                .field(GamepadField.player.rawValue, "Player", detail?.playerNote),
                .field(GamepadField.battery.rawValue, "Battery", detail?.batteryNote),
                .field(GamepadField.batteryState.rawValue, "Charging", detail?.batteryState),
                .field(GamepadField.attached.rawValue, "Attached", detail?.attachedNote),
                .field(GamepadField.adaptiveTriggers.rawValue, "Adaptive Triggers", detail?.adaptiveTriggersNote),
                .field(GamepadField.touchpad.rawValue, "Touchpad", detail?.touchpadNote),
                .field(GamepadField.motion.rawValue, "Motion", detail?.motionNote),
                .field(GamepadField.haptics.rawValue, "Haptics", detail?.hapticLocations),
                .field(GamepadField.elitePaddles.rawValue, "Rear Paddles", detail?.elitePaddlesNote),
                .field(GamepadField.lightColor.rawValue, "Light", detail?.lightColor)
            ]),
            icon: .asset("GamepadMonitor-Icon", in: .module)
        )
    }

    private static func describe(_ change: GamepadDeviceChange) -> (title: String, headline: String) {
        switch change.kind {
        case .controller:
            let name = change.name ?? "Game Controller"
            return (change.connected ? "Game Controller Connected" : "Game Controller Disconnected", name)
        case .keyboard:
            return (
                change.connected ? "Game-Recognized Keyboard Connected" : "Game-Recognized Keyboard Disconnected",
                change.connected ? "A keyboard is now available to GameController-based games/apps" : ""
            )
        case .mouse:
            return (
                change.connected ? "Game-Recognized Mouse Connected" : "Game-Recognized Mouse Disconnected",
                change.connected ? "A mouse is now available to GameController-based games/apps" : ""
            )
        case .racingWheel:
            let name = change.name ?? "Racing Wheel"
            return (change.connected ? "Racing Wheel Connected" : "Racing Wheel Disconnected", name)
        }
    }
}
