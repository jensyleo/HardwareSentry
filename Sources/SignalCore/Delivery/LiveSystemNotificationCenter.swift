import Foundation
import UserNotifications

/// Talks to the operating system's real notification service.
///
/// Deliberately thin. Everything here needs a genuine application bundle to run, so none
/// of it can be covered by tests — which is precisely why the decision-making lives in
/// `SystemDelivery` behind `SystemNotificationScheduling`, and only the translation to
/// and from the system's own types lives here.
public struct LiveSystemNotificationCenter: SystemNotificationScheduling {
    public init() {}

    public func authorizationStatus() async -> SystemAuthorizationStatus {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    public func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    public func schedule(_ request: SystemNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        let interruptionLevel: UNNotificationInterruptionLevel = switch request.interruptionLevel {
        case .passive: .passive
        case .active: .active
        case .timeSensitive: .timeSensitive
        }
        content.interruptionLevel = interruptionLevel

        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil)
        )
    }
}

/// Receives the system's callbacks and forwards them to `SystemDelivery`.
///
/// This is a separate object, isolated to nothing, on purpose. The system's delegate
/// protocol declares its methods without actor isolation and hands over types that
/// cannot cross an isolation boundary, so an actor cannot satisfy it directly. Pulling
/// out the few values that *can* cross, and only then awaiting the actor, keeps the
/// boundary honest instead of fighting it.
///
/// A host installs it with
/// `UNUserNotificationCenter.current().delegate = responder`, keeping a strong reference
/// of its own — the system holds the delegate weakly.
public final class SystemNotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    private let delivery: SystemDelivery

    public init(delivery: SystemDelivery) {
        self.delivery = delivery
        super.init()
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        let interaction: NotificationInteraction =
            response.actionIdentifier == UNNotificationDismissActionIdentifier ? .dismissed : .clicked
        await delivery.handleResponse(identifier: identifier, interaction: interaction)
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Without this the system withholds notifications while the host is frontmost.
        [.banner, .list]
    }
}
