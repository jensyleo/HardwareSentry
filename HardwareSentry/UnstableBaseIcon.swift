import SentryContract
import SignalCore

/// Gives an "unstable" notice a picture with no state of its own.
///
/// The notice is raised from whichever notification tipped a device over — often a "gone" one
/// — and borrows its picture. Drawn as it is, that is a device with a cross through it beside
/// the unstable mark, which says two things at once. The device's plain picture is the honest
/// one: the mark says what is wrong with it.
struct UnstableBaseIconMiddleware: NotificationMiddleware {
    func process(_ event: NotificationEvent, context: DispatchContext) async -> MiddlewareDecision {
        guard event.name == "FlapDetected" else { return .deliver(event) }
        var event = event
        event.icon = AssetOrigin.neutralIcon(of: event.icon)
        return .deliver(event)
    }
}
