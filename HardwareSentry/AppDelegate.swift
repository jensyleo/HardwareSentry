import AppKit
import MonitorRegistry
import SentryContract
import ThermalMonitor
import SignalCore
import SystemIcons
import USBMonitor

/// Puts the application together and runs it.
///
/// Everything that knows about everything else lives here, on purpose: the monitors know
/// only their own contract, the notification core knows nothing of hardware, and this is
/// the one place where those are introduced to each other.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var preferences: NotificationPreferencesStore!
    private(set) var appearance: BannerAppearanceStore!
    private(set) var bannerThemes: BannerThemeStore!
    private(set) var eventSettings: EventSettingsModel!
    private(set) var history: NotificationHistoryStore!
    private(set) var iconOverrides: IconOverrideStore!
    private(set) var iconSources: IconSourceStore!
    private(set) var iconSourceModel: IconSourceModel!
    private(set) var general: GeneralSettingsModel!
    private(set) var tuning: MonitorTuningModel!

    /// Mirrors the General tab's icon choice for the menu bar scene, which needs a binding
    /// it can write to even though nothing ever writes back through it.
    var menuBarIconIsVisible: Bool = true
    private var dispatcher: NotificationDispatcher!
    private(set) var registry: MonitorRegistry!
    private var bannerDelivery: BannerDelivery!
    private var iconOverrideMiddleware: IconOverrideMiddleware!
    private var systemIconMiddleware: SystemIconMiddleware!
    private var systemIconCatalog: SystemIconCatalog!

    /// Everything is built here rather than in `applicationDidFinishLaunching`, because
    /// the settings scene may be asked for its content before that runs — and a delegate
    /// is not observable, so a scene that found these missing would have no way to learn
    /// they had since arrived.
    override init() {
        super.init()
        assemble()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard terminateIfAlreadyRunning() else { return }

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
            checkSerialVendorUpdateIfDue()
        }
    }

    /// Refreshes `USBSerialVendorDatabase` from its remote copy if auto-update is on and
    /// enough days have passed since the last check — or since ever, if there is no last
    /// check yet. Silent either way: a Mac that never gets asked still stays current, and
    /// one with no network on a given day just tries again next launch.
    func checkSerialVendorUpdateIfDue() {
        guard tuning.usbSerialVendorAutoUpdate else { return }
        let dueSince = tuning.lastSerialVendorUpdate.map {
            $0.addingTimeInterval(tuning.usbSerialVendorUpdateDays * 86400)
        }
        guard dueSince == nil || dueSince! <= Date() else { return }
        let url = tuning.usbSerialVendorUpdateURL
        Task {
            await USBSerialVendorDatabase.shared.refresh(from: url)
            tuning.lastSerialVendorUpdate = Date()
        }
    }

    /// The "Check Now" button in Settings — runs regardless of the auto-update toggle or
    /// the schedule, since asking outright is always allowed. Unlike the scheduled check,
    /// this one reports what actually happened: somebody who pressed a button is owed an
    /// answer, not silence indistinguishable from the button having done nothing at all.
    func checkSerialVendorUpdateNow() {
        let url = tuning.usbSerialVendorUpdateURL
        tuning.serialVendorUpdateStatus = "Checking…"
        Task {
            let outcome = await USBSerialVendorDatabase.shared.refresh(from: url)
            tuning.lastSerialVendorUpdate = Date()
            switch outcome {
            case .updated(let count):
                tuning.serialVendorUpdateStatus = "Updated — \(count) vendor\(count == 1 ? "" : "s") added or renamed."
            case .upToDate:
                tuning.serialVendorUpdateStatus = "Already up to date — nothing new."
            case .failed:
                tuning.serialVendorUpdateStatus = "Check failed — no connection, or the URL did not respond."
            }
        }
    }

    /// Quits this process immediately if another copy of this application is already
    /// running, and returns whether the caller should continue starting up.
    ///
    /// Nothing else in the process guards against this — an accessory app with no Dock
    /// icon and no window to glance at is exactly the shape that gets double-launched
    /// without anyone noticing: `open`-ing it again while it is already running, a stale
    /// process a previous quit didn't actually terminate, or a build script relaunching
    /// it without confirming the old one exited first. Two copies do not fight visibly —
    /// each has its own `BannerDelivery` drawing into the same screen corner with no idea
    /// the other exists, so what shows up looks like a single, badly broken stacking bug:
    /// banners from one process never move to make room for the other's, because nothing
    /// in either one is watching for it. Confirmed live, reproduced by two overlapping
    /// banners that carried different wording from two different builds.
    private func terminateIfAlreadyRunning() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier
        let pid = ProcessInfo.processInfo.processIdentifier
        let olderInstance = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != pid
        }

        guard let olderInstance else { return true }

        olderInstance.activate()
        NSApp.terminate(nil)
        return false
    }

    private func assemble() {
        preferences = NotificationPreferencesStore(keyPrefix: "HardwareSentry")
        appearance = BannerAppearanceStore(keyPrefix: "HardwareSentry.Appearance")
        bannerThemes = BannerThemeStore(key: "HardwareSentry.Appearance.Themes")
        bannerThemes.onAutomaticThemeChange = { [weak self] in self?.applyAutomaticTheme() }
        // The look follows macOS's light and dark modes when a theme is chosen for them. Only
        // on a change of mode (and at launch), so a tweak made by hand is not undone by the
        // next unrelated setting.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.applyAutomaticTheme() } }
        applyAutomaticTheme()
        iconOverrides = IconOverrideStore(keyPrefix: "HardwareSentry.IconOverride")
        adoptCustomIconFiles()
        iconOverrideMiddleware = IconOverrideMiddleware(overrides: iconOverrides.overrides)
        iconSources = IconSourceStore(keyPrefix: "HardwareSentry.IconSource")
        // One catalogue for the notifications and the settings preview alike, so a picture
        // read for one is already there for the other.
        let systemIcons = SystemIconCatalog()
        systemIconCatalog = systemIcons
        systemIconMiddleware = SystemIconMiddleware(choices: iconSources.choices, catalog: systemIcons)
        iconSourceModel = IconSourceModel(store: iconSources, catalog: systemIcons)

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
                //
                // Hand-picked icons first, then the operating system's pictures. A choice
                // made for one notification — a symbol, a file, or "keep the app's own" —
                // marks that icon as decided, and the System stage leaves decided icons
                // alone; so a single choice always beats a module-wide "System".
                iconOverrideMiddleware!,
                systemIconMiddleware!,
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
            powerHealthNotify: tuning.powerHealthNotify,
            volumeLowSpacePercent: tuning.lowSpacePercent,
            audioVolumeCriticalPercent: Int(tuning.audioVolumeCriticalPercent),
            audioNotifiesVirtualDevices: tuning.notifiesVirtualAudioDevices,
            cameraNotifiesVirtualDevices: tuning.notifiesVirtualCameraDevices,
            audioNotifiesUSBDevices: tuning.notifiesUSBAudioDevices,
            cameraNotifiesUSBDevices: tuning.notifiesUSBCameraDevices,
            gamepadNotifiesUSBDevices: tuning.notifiesUSBGamepadDevices,
            audioNotifiesBluetoothDevices: tuning.notifiesBluetoothAudioDevices,
            bluetoothNotifiesGamepadDevices: tuning.notifiesBluetoothGamepadDevices,
            usbIgnoresIdentifiedGenericDevices: tuning.usbIgnoresIdentifiedGenericDevices,
            scannerStatusInterval: tuning.scannerStatusInterval,
            networkSignalPolling: .init(interval: tuning.wifiSignalSeconds, enabled: tuning.wifiSignalPollingEnabled),
            networkRadioPollInterval: tuning.wifiRadioPollInterval,
            networkSignalCooldown: tuning.wifiSignalCooldownSeconds,
            videoLinkPollInterval: tuning.videoLinkPollInterval,
            connectionNaming: tuning.connectionNaming,
            namesReportingModule: tuning.namesReportingModule,
            volumeExclusions: tuning.volumeExclusions,
            bluetoothPairedPollInterval: tuning.bluetoothPairedPollInterval,
            bluetoothSignalPollInterval: tuning.bluetoothSignalPollInterval,
            bluetoothBLEPollInterval: tuning.bluetoothBLEPollInterval,
            printerPollInterval: tuning.printerPollInterval,
            volumeFreeSpacePollInterval: tuning.volumeFreeSpacePollInterval,
            volumeReachabilityInterval: tuning.volumeReachabilityInterval,
            massStorageDetectionEnabled: tuning.massStorageDetectionEnabled,
            massStoragePollInterval: tuning.massStoragePollMilliseconds / 1000,
            massStorageTimeout: tuning.massStorageTimeoutSeconds
        )
        // Consulted directly by `USBDevice.kind`, not threaded through `MonitorRegistry` —
        // there is nothing here for a source to rebuild, so this can just be set, both
        // now and again below on every change.
        USBWirelessDetectionSettings.shared.detectsBluetoothAdapters = tuning.usbDetectsBluetoothAdapters
        USBWirelessDetectionSettings.shared.detectsWiFiAdapters = tuning.usbDetectsWiFiAdapters
        // Changed numbers reach the running monitors rather than waiting for a relaunch.
        tuning.onChange = { [weak self] in
            guard let self, let registry else { return }
            USBWirelessDetectionSettings.shared.detectsBluetoothAdapters = tuning.usbDetectsBluetoothAdapters
            USBWirelessDetectionSettings.shared.detectsWiFiAdapters = tuning.usbDetectsWiFiAdapters
            Task {
                await registry.apply(
                    powerRefire: tuning.powerRefire,
                    powerHealthCheck: tuning.powerHealthCheck,
                    powerHealthNotify: tuning.powerHealthNotify,
                    volumeLowSpacePercent: tuning.lowSpacePercent,
                    volumeExclusions: tuning.volumeExclusions,
                    audioVolumeCriticalPercent: Int(tuning.audioVolumeCriticalPercent),
                    audioNotifiesVirtualDevices: tuning.notifiesVirtualAudioDevices,
                    cameraNotifiesVirtualDevices: tuning.notifiesVirtualCameraDevices,
                    audioNotifiesUSBDevices: tuning.notifiesUSBAudioDevices,
                    cameraNotifiesUSBDevices: tuning.notifiesUSBCameraDevices,
                    gamepadNotifiesUSBDevices: tuning.notifiesUSBGamepadDevices,
                    audioNotifiesBluetoothDevices: tuning.notifiesBluetoothAudioDevices,
                    bluetoothNotifiesGamepadDevices: tuning.notifiesBluetoothGamepadDevices,
                    usbIgnoresIdentifiedGenericDevices: tuning.usbIgnoresIdentifiedGenericDevices
                )
            }
        }
        eventSettings = EventSettingsModel(preferences: preferences, registry: registry)
        general = GeneralSettingsModel(preferences: preferences)
        general.applyStoredIconVisibility()
        menuBarIconIsVisible = general.iconVisibility.showsMenuBarIcon
        trackIconVisibilityChanges()
        trackAppearanceChanges()
        trackIconOverrideChanges()
        trackIconSourceChanges()

    }

    /// Fires one thermal transition on demand, for the Simulate button.
    func simulateThermal(from: ThermalState, to: ThermalState) {
        guard let registry else { return }
        Task { await registry.simulateThermalTransition(from: from, to: to) }
    }

    /// Fires one of a module's own declared events, for the generic "Simulate a
    /// Notification" section every module's settings tab offers.
    ///
    /// Raised with the event's own declared title and icon, straight through the same
    /// dispatcher a real monitor uses — so it passes through every filter and middleware
    /// a real one would (icon overrides, the event's own on/off switch included), the
    /// same way `simulateThermal` above already does for Thermal's own, more particular
    /// simulator. A module whose events need more than a name and an icon to mean
    /// anything — Thermal's "from which state to which" chief among them — gets its own,
    /// as Thermal already has; this is what the rest can share.
    func simulateEvent(_ event: MonitorEventDescription, category: NotificationCategory) {
        Task {
            await dispatcher.fire(
                NotificationEvent(
                    name: event.name,
                    category: category,
                    title: event.title,
                    body: "Simulated — nothing on this Mac actually changed.",
                    icon: event.icon
                )
            )
        }
    }

    private func applyAutomaticTheme() {
        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        let updated = bannerThemes.automaticallyApplied(to: appearance.appearance, isDark: isDark)
        if updated != appearance.appearance { appearance.appearance = updated }
    }

    /// A real banner, with the look and placement as they stand, for the Appearance tab.
    func showTestBanner() {
        Task {
            let notification = NotificationEvent(
                name: "AppearanceTest", category: "Preview", title: "This is how a notification looks",
                body: "Nothing on this Mac changed.\nAdjust the settings and try again.",
                icon: .symbol("bell.badge"), iconBadge: .positive, showsIconBadge: true
            )
            _ = await bannerDelivery.present(notification, context: DispatchContext(phase: .steady, firedAt: Date()))
        }
    }

    /// Puts a real banner on screen for the Preview tab.
    ///
    /// Through the two icon stages only, then straight to the screen: the choices that decide
    /// how the picture looks (a picture chosen for this notification, macOS's own for the
    /// module) apply exactly as they do to a live one, while the stages that decide *whether*
    /// something is said — switched off, a duplicate, unstable — are skipped, so a preview
    /// always shows. Nor does it reach the history: nothing happened.
    func previewNotification(_ event: MonitorEventDescription, category: NotificationCategory, badge: IconBadge?, source: IconSource) {
        Task {
            var notification = NotificationEvent(
                name: event.name,
                category: category,
                title: event.title,
                body: "Preview — nothing on this Mac actually changed.",
                icon: event.icon,
                iconKind: event.iconKind?.rawValue,
                iconBadge: badge,
                showsIconBadge: badge != nil
            )
            let context = DispatchContext(phase: .steady, firedAt: Date())
            // The picture source is the one chosen on the Preview tab, not the saved one, so
            // either can be judged without changing a setting.
            var choices = IconSourceChoices()
            choices[category] = source
            let stages: [any NotificationMiddleware] = [
                iconOverrideMiddleware, SystemIconMiddleware(choices: choices, catalog: systemIconCatalog)
            ]
            for stage in stages {
                guard case .deliver(let next) = await stage.process(notification, context: context) else { return }
                notification = next
            }
            _ = await bannerDelivery.present(notification, context: context)
        }
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
        // Deferred: when the window is being created rather than raised, it does not
        // exist yet at this point, and neither does the toolbar being adjusted.
        DispatchQueue.main.async { [weak self] in self?.tidySettingsToolbar() }
    }

    /// Takes the toolbar's own right-click menu out of the settings window.
    ///
    /// SwiftUI builds a real `NSToolbar` for a tabbed settings window, and every
    /// `NSToolbar` offers "Icon and Text / Icon Only / Text Only" on right-click for
    /// free. Here it is an offer with nothing behind it: these tabs are the settings
    /// window's own navigation, not a toolbar somebody assembled, and "Icon Only" on tabs
    /// that carry no icons just hides their names. The mode is pinned rather than merely
    /// locked, so a stored "Icon Only" from before this cannot leave the tabs nameless.
    private func tidySettingsToolbar() {
        guard let window = NSApplication.shared.windows.first(where: {
            $0.identifier?.rawValue == HardwareSentryApp.settingsWindowID
        }), let toolbar = window.toolbar else { return }
        toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
        toolbar.displayMode = .iconAndLabel
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
                self.removeUnusedCustomIcons()
                self.trackIconOverrideChanges()
            }
        }
    }

    /// Every picture an icon choice points at.
    private var customIconPaths: Set<String> {
        Set(iconOverrides.overrides.allChoices.compactMap { choice in
            if case .file(let path) = choice { return path }
            return nil
        })
    }

    /// Brings icons chosen before this application kept its own copies into its keeping:
    /// each one still pointing at somebody's own file is copied in and repointed, so it
    /// stops depending on that file staying where it is. A file already gone is left
    /// alone — the notification falls back to its own icon, and the Icons tab says so.
    private func adoptCustomIconFiles() {
        guard let library = CustomIconLibrary.standard() else { return }
        // By path rather than by event: one picture chosen for several notifications is
        // copied once and they all point at the same copy.
        for path in customIconPaths where !library.contains(path: path) {
            guard FileManager.default.fileExists(atPath: path),
                  let stored = try? library.importImage(from: URL(fileURLWithPath: path))
            else { continue }
            iconOverrides.repointFile(from: path, to: stored)
        }
        removeUnusedCustomIcons()
    }

    /// Deletes the copies no icon uses any more — what was left behind by a reset or by
    /// choosing a different picture.
    private func removeUnusedCustomIcons() {
        CustomIconLibrary.standard()?.removeUnreferenced(keeping: customIconPaths)
    }

    /// The same again for each module's icon source.
    private func trackIconSourceChanges() {
        withObservationTracking {
            _ = iconSources.revision
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.systemIconMiddleware.update(self.iconSources.choices)
                self.trackIconSourceChanges()
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
