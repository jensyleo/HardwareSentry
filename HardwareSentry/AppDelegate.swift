import AppKit
import MonitorRegistry
import ThermalMonitor
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
    private(set) var general: GeneralSettingsModel!
    private(set) var tuning: MonitorTuningModel!

    /// Mirrors the General tab's icon choice for the menu bar scene, which needs a binding
    /// it can write to even though nothing ever writes back through it.
    var menuBarIconIsVisible: Bool = true
    private var dispatcher: NotificationDispatcher!
    private(set) var registry: MonitorRegistry!
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
            // Before the monitors start, and before anything opens the settings window.
            //
            // This is where the performance preset is put into force. It used to happen
            // when the Notifications tab first appeared, which meant a Mac that launched
            // and was never asked for its settings ran every module regardless of what
            // the preset said — the choice was recorded, shown back correctly, and
            // ignored. Defaults have to be registered first, so "All elements" can put
            // each module back to what it declared rather than to nothing.
            await eventSettings.load()
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

        let tuning = MonitorTuningModel()
        self.tuning = tuning
        registry = MonitorRegistry(
            dispatcher: dispatcher,
            preferences: preferences,
            announcesWhatIsAlreadyThere: preferences.announcesWhatIsAlreadyThere,
            powerRefire: tuning.powerRefire,
            powerHealthCheck: tuning.powerHealthCheck,
            volumeLowSpacePercent: tuning.lowSpacePercent,
            audioVolumeCriticalPercent: Int(tuning.audioVolumeCriticalPercent),
            scannerStatusInterval: tuning.scannerStatusInterval,
            networkSignalPolling: .init(interval: tuning.wifiSignalSeconds),
            networkSignalCooldown: tuning.wifiSignalCooldownSeconds,
            videoLinkPollInterval: tuning.videoLinkPollInterval,
            connectionNaming: tuning.connectionNaming,
            volumeExclusions: tuning.volumeExclusions
        )
        // Changed numbers reach the running monitors rather than waiting for a relaunch.
        tuning.onChange = { [weak self] in
            guard let self, let registry else { return }
            Task {
                await registry.apply(
                    powerRefire: tuning.powerRefire,
                    powerHealthCheck: tuning.powerHealthCheck,
                    volumeLowSpacePercent: tuning.lowSpacePercent,
                    volumeExclusions: tuning.volumeExclusions,
                    audioVolumeCriticalPercent: Int(tuning.audioVolumeCriticalPercent)
                )
            }
        }
        eventSettings = EventSettingsModel(preferences: preferences, registry: registry)
        general = GeneralSettingsModel(preferences: preferences, iconOverrides: iconOverrides)
        general.applyStoredIconVisibility()
        menuBarIconIsVisible = general.iconVisibility.showsMenuBarIcon
        trackIconVisibilityChanges()
        trackAppearanceChanges()
        trackIconOverrideChanges()

    }

    /// Fires one thermal transition on demand, for the Simulate button.
    func simulateThermal(from: ThermalState, to: ThermalState) {
        guard let registry else { return }
        Task { await registry.simulateThermalTransition(from: from, to: to) }
    }

    /// Reads the battery's condition on demand, for the "Check Now" button.
    func checkBatteryHealthNow() {
        guard let registry else { return }
        Task { await registry.checkBatteryHealthNow() }
    }

    /// Launching the application again while it is already running opens the settings.
    ///
    /// Without this, a second launch of a menu-bar-only application does nothing visible at
    /// all — the icon is already up there, so double-clicking it in Applications looks
    /// exactly like a program that failed to start. Settings is what somebody going back to
    /// a background application almost always wants.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }

    /// Brings the settings window up and the application forward with it — without the
    /// second part a menu-bar-only application puts the window behind whatever was already
    /// on screen.
    func openSettings() {
        // Raised if it already exists rather than opened again, so a second launch does not
        // leave two of them.
        if let existing = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == HardwareSentryApp.settingsWindowID }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            openSettingsWindow?()
        }
        NSApplication.shared.activate()
    }

    /// Handed in by the scene, which is the only thing that can open a SwiftUI `Window`.
    var openSettingsWindow: (() -> Void)?

    /// A menu-bar application outlives its windows: the banners it draws are windows, and
    /// the last of them going away is the normal state of things, not a reason to quit.
    /// Without this, the application ends a few seconds after launch as soon as the
    /// startup banners expire — which looks exactly like a crash.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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

    /// Keeps the menu bar item in step with the General tab, the same re-arming way the
    /// appearance and icon settings are followed.
    private func trackIconVisibilityChanges() {
        withObservationTracking {
            _ = general.iconVisibility
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.menuBarIconIsVisible = self.general.iconVisibility.showsMenuBarIcon
                self.trackIconVisibilityChanges()
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
