import Foundation
import GameController

/// Watches the real system for game controllers and the racing wheels GameController
/// framework separately recognizes.
///
/// Deliberately thin and untested, for the same reason `IOKitUSBDeviceSource` is: none of
/// it can run without a real device connecting. Everything worth reasoning about lives in
/// `GamepadMonitor`, behind `GamepadSource`.
public final class GameControllerSource: GamepadSource, @unchecked Sendable {
    public init() {}

    /// Holds the notification tokens across the `@Sendable` termination closure —
    /// `NSObjectProtocol` itself isn't `Sendable`, but the box that owns them, and only
    /// ever touches them, can be. Same shape as `ThermalMonitor`'s `ObserverBox`, kept
    /// local to each module rather than shared, since a monitor depends on nothing but
    /// `SentryContract`.
    private final class ObserverBox: @unchecked Sendable {
        var tokens: [NSObjectProtocol] = []
    }

    public func changes() -> AsyncStream<GamepadDeviceChange> {
        AsyncStream { continuation in
            let center = NotificationCenter.default
            let box = ObserverBox()

            func observe(_ name: Notification.Name, kind: GamepadDeviceKind, connected: Bool, name nameOf: @escaping @Sendable (Notification) -> String?) {
                box.tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { note in
                    // Details only on the way in. A controller that has just disconnected
                    // still answers these properties, but with values frozen at whatever
                    // they were — a stale battery percentage read as current is worse than
                    // no battery line, so the disconnect notification simply doesn't carry one.
                    let detail = (connected ? note.object as? GCController : nil)
                        .map(GamepadDetail.init(controller:))
                    continuation.yield(
                        GamepadDeviceChange(kind: kind, connected: connected, name: nameOf(note), detail: detail)
                    )
                })
            }

            observe(.GCControllerDidConnect, kind: .controller, connected: true) { ($0.object as? GCController)?.vendorName }
            observe(.GCControllerDidDisconnect, kind: .controller, connected: false) { ($0.object as? GCController)?.vendorName }
            // No GCKeyboardDidConnect/GCMouseDidConnect observers — see GamepadEvent's own
            // doc comment: reported live, these fire for an ordinary keyboard/mouse, not
            // only a dedicated gaming one, which the switch that used to gate them promised.
            observe(.GCRacingWheelDidConnect, kind: .racingWheel, connected: true) { ($0.object as? GCRacingWheel)?.vendorName }
            observe(.GCRacingWheelDidDisconnect, kind: .racingWheel, connected: false) { ($0.object as? GCRacingWheel)?.vendorName }

            // Without this, a controller connecting after launch is never reported: the
            // framework doesn't route connect events to a background/menu-bar-only app
            // unless it has actively asked to search for wireless controllers — confirmed
            // in HG4MAC's own history, and true even for a wired controller.
            GCController.startWirelessControllerDiscovery(completionHandler: nil)

            continuation.onTermination = { _ in
                box.tokens.forEach(center.removeObserver)
                GCController.stopWirelessControllerDiscovery()
            }
        }
    }
}
