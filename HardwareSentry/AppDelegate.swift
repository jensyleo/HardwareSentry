import AppKit
import MonitorRegistry
import SignalCore
import UserNotifications

/// Puts the application together and runs it.
///
/// Everything that knows about everything else lives here, on purpose: the monitors know
/// only their own contract, the notification core knows nothing of hardware, and this is
/// the one place where those are introduced to each other.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var preferences: NotificationPreferencesStore!
    private var dispatcher: NotificationDispatcher!
    private var registry: MonitorRegistry!
    private var systemDelivery: SystemDelivery!
    private var responder: SystemNotificationResponder!

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences = NotificationPreferencesStore(keyPrefix: "HardwareSentry")

        // Prefer the system's own notification service; draw banners when it will not
        // have us, which is the case for an application without a stable signing
        // identity, and for anyone who has said no.
        systemDelivery = SystemDelivery(scheduler: LiveSystemNotificationCenter())
        let delivery = FallbackDelivery(preferred: systemDelivery, fallback: BannerDelivery())

        dispatcher = NotificationDispatcher(
            pipeline: [
                CategoryEnabledFilter(preferences: preferences),
                EventEnabledFilter(preferences: preferences),
                DuplicateSuppressionMiddleware(),
                FlapDetectionMiddleware()
            ],
            delivery: delivery,
            // Everything already plugged in is announced first, and a burst of that is
            // not the same situation as news arriving one at a time.
            phase: .launching
        )

        responder = SystemNotificationResponder(delivery: systemDelivery)
        UNUserNotificationCenter.current().delegate = responder

        registry = MonitorRegistry(dispatcher: dispatcher, preferences: preferences)

        Task {
            await registerEventDefaults()
            await systemDelivery.prepare()
            await registry.start()
            await settleAfterStartupSweep()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let registry = self.registry
        Task { await registry?.stop() }
    }

    /// Asks each monitor what it can raise, and what those should be for someone who has
    /// never touched the settings. No central table to keep in step.
    private func registerEventDefaults() async {
        for (category, events) in await registry.describeEvents() {
            preferences.registerDefaults([category: true])

            let overrides = events
                .filter { !$0.enabledByDefault }
                .reduce(into: [String: Bool]()) { $0[$1.name] = false }
            if !overrides.isEmpty {
                preferences.registerDefaults(overrides, in: category)
            }
        }
    }

    /// Raises a notification on demand, so someone can see for themselves that they are
    /// working — and which way they are being delivered, since an application the system
    /// will not have falls back to drawing its own.
    func sendTestNotification() {
        Task {
            await dispatcher.fire(
                NotificationEvent(
                    name: "TestNotification",
                    category: "HardwareSentry",
                    title: "HardwareSentry",
                    body: "Notifications are working.\nDelivery: system → checking",
                    icon: .symbol("checkmark.circle")
                )
            )
        }
    }

    /// Nothing tells us when the opening sweep is finished, so this waits for things to
    /// go quiet. A cruder rule than it deserves — see D1 in the deferred notes, which
    /// weighs this against having each monitor say when it is done.
    private func settleAfterStartupSweep() async {
        try? await Task.sleep(for: .seconds(5))
        await dispatcher.setPhase(.steady)
    }
}
