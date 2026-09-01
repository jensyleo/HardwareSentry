import AppKit
import MonitorRegistry
import SignalCore

/// Puts the application together and runs it.
///
/// Everything that knows about everything else lives here, on purpose: the monitors know
/// only their own contract, the notification core knows nothing of hardware, and this is
/// the one place where those are introduced to each other.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var preferences: NotificationPreferencesStore!
    private(set) var appearance: BannerAppearanceStore!
    private(set) var eventSettings: EventSettingsModel!
    private(set) var history: NotificationHistoryStore!
    private(set) var iconOverrides: IconOverrideStore!
    private var dispatcher: NotificationDispatcher!
    private var registry: MonitorRegistry!
    private var bannerDelivery: BannerDelivery!
    private var iconOverrideMiddleware: IconOverrideMiddleware!

    /// Everything is built here rather than in `applicationDidFinishLaunching`, because
    /// the settings scene may be asked for its content before that runs — and a delegate
    /// is not observable, so a scene that found these missing would have no way to learn
    /// they had since arrived.
    override init() {
        super.init()
        assemble()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await registerEventDefaults()
            await registry.start()
            await settleAfterStartupSweep()
        }
    }

    private func assemble() {
        preferences = NotificationPreferencesStore(keyPrefix: "HardwareSentry")
        appearance = BannerAppearanceStore(keyPrefix: "HardwareSentry.Appearance")
        iconOverrides = IconOverrideStore(keyPrefix: "HardwareSentry.IconOverride")
        iconOverrideMiddleware = IconOverrideMiddleware(overrides: iconOverrides.overrides)

        // This application draws its own notifications and does not hand them to macOS.
        //
        // Deliberate, and the reason the notification package exists at all. Handing a
        // notification to the system means giving up everything the appearance settings
        // control — corner, size, how long it stays, what it is drawn on — because macOS
        // then decides all of it. It would also make the application's own notifications
        // depend on a permission the person has to grant, and stop working if they ever
        // said no. `SystemDelivery` stays in the package for hosts that want the opposite;
        // this one does not.
        bannerDelivery = BannerDelivery(appearance: appearance.appearance)
        let delivery = bannerDelivery!
        history = NotificationHistoryStore()

        dispatcher = NotificationDispatcher(
            pipeline: [
                CategoryEnabledFilter(preferences: preferences),
                EventEnabledFilter(preferences: preferences),
                DuplicateSuppressionMiddleware(),
                FlapDetectionMiddleware(),
                // After the filters: there is no point resolving an icon, let alone
                // reading a file from disk, for an event that is about to be dropped.
                // Before the history hook, so what is remembered carries the icon that
                // was actually shown.
                iconOverrideMiddleware!,
                // Last on purpose: what gets remembered is what a person was actually
                // shown, not everything the monitors raised and the filters then dropped.
                HistoryHookMiddleware { [history] event, context in
                    Task { @MainActor in history?.record(event, at: context.firedAt) }
                }
            ],
            delivery: delivery,
            // Everything already plugged in is announced first, and a burst of that is
            // not the same situation as news arriving one at a time.
            phase: .launching
        )

        registry = MonitorRegistry(dispatcher: dispatcher, preferences: preferences)
        eventSettings = EventSettingsModel(preferences: preferences, registry: registry)
        trackAppearanceChanges()
        trackIconOverrideChanges()

    }

    func applicationWillTerminate(_ notification: Notification) {
        let registry = self.registry
        Task { await registry?.stop() }
    }

    /// Hands appearance changes to the banners as they are made, so a person adjusting
    /// the settings sees the result rather than being told to relaunch.
    ///
    /// `withObservationTracking` fires once and then forgets, so this re-arms itself each
    /// time — the standard way to follow an observable object from outside SwiftUI, which
    /// does this re-arming on your behalf as part of rendering.
    private func trackAppearanceChanges() {
        withObservationTracking {
            _ = appearance.appearance
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.bannerDelivery.appearance = self.appearance.appearance
                self.trackAppearanceChanges()
            }
        }
    }

    /// The same re-arming trick as `trackAppearanceChanges`, for the icon choices: the
    /// middleware runs inside an actor and cannot observe a main-actor store, so the
    /// change is pushed to it instead.
    private func trackIconOverrideChanges() {
        withObservationTracking {
            _ = iconOverrides.revision
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let overrides = self.iconOverrides.overrides
                await self.iconOverrideMiddleware.update(overrides)
                self.trackIconOverrideChanges()
            }
        }
    }

    /// Asks each monitor what it can raise, and what those should be for someone who has
    /// never touched the settings. No central table to keep in step.
    private func registerEventDefaults() async {
        for module in await registry.describe() {
            preferences.registerDefaults([module.category: module.enabledByDefault])

            let overrides = module.events
                .filter { !$0.enabledByDefault }
                .reduce(into: [String: Bool]()) { $0[$1.name] = false }
            if !overrides.isEmpty {
                preferences.registerDefaults(overrides, in: module.category)
            }

            // Fields are registered whichever way they default: unlike events, a field
            // that defaults to off is common enough that leaving it unregistered would
            // mean "never chosen" reads as wanted, which is the opposite of declared.
            let fields = module.fields.reduce(into: [String: Bool]()) { $0[$1.name] = $1.shownByDefault }
            if !fields.isEmpty {
                preferences.registerFieldDefaults(fields, in: module.category)
            }
        }
    }

    /// Raises a notification on demand, so someone can see for themselves that they are
    /// working, and what the appearance settings currently look like on a real one.
    func sendTestNotification() {
        Task {
            await dispatcher.fire(
                NotificationEvent(
                    name: "TestNotification",
                    category: "HardwareSentry",
                    title: "HardwareSentry",
                    body: "Notifications are working.",
                    icon: .symbol("checkmark.circle")
                )
            )
        }
    }

    /// Nothing tells us when the opening sweep is finished, so this waits for it to go
    /// quiet rather than guessing at a duration: how long the sweep takes depends on how
    /// much hardware is attached, and a fixed wait is wrong on both a busy machine and an
    /// idle one.
    private func settleAfterStartupSweep() async {
        await dispatcher.settleToSteady()
    }
}
