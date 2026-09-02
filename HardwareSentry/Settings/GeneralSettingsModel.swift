import AppKit
import Observation
import ServiceManagement
import SignalCore

/// Where the application puts its own icon.
///
/// Four states rather than two switches, because "menu bar" and "dock" are not independent
/// in practice: hiding both is a real choice somebody makes deliberately, and offering it
/// as two checkboxes invites arriving at it by accident and then not knowing how to get
/// the application back.
enum IconVisibility: Int, CaseIterable, Identifiable {
    case menuBar = 0
    case dock = 1
    case both = 2
    case none = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .menuBar: return "Show icon in the menubar"
        case .dock: return "Show icon in the dock"
        case .both: return "Show icon in both"
        case .none: return "No icon visible"
        }
    }

    var showsMenuBarIcon: Bool { self == .menuBar || self == .both }
    var showsDockIcon: Bool { self == .dock || self == .both }

    /// A dock icon is what makes an application "regular"; without one it is an accessory
    /// that lives entirely in the menu bar.
    var activationPolicy: NSApplication.ActivationPolicy {
        showsDockIcon ? .regular : .accessory
    }
}

/// The General tab: where the application shows itself, whether it starts with the Mac,
/// what it says at launch, and backing all of that up.
@MainActor
@Observable
final class GeneralSettingsModel {
    @ObservationIgnored private let preferences: NotificationPreferencesStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let iconOverrides: IconOverrideStore

    private var revision = 0

    init(preferences: NotificationPreferencesStore, iconOverrides: IconOverrideStore, defaults: UserDefaults = .standard) {
        self.preferences = preferences
        self.iconOverrides = iconOverrides
        self.defaults = defaults
    }

    // MARK: - Where the icon lives

    var iconVisibility: IconVisibility {
        get {
            _ = revision
            return IconVisibility(rawValue: defaults.integer(forKey: Self.visibilityKey)) ?? .menuBar
        }
        set {
            // Hiding every way of reaching the application is worth one question. The
            // answer can be suppressed, because somebody who meant it the first time does
            // not need asking again.
            if newValue == .none, !defaults.bool(forKey: Self.suppressNoIconWarningKey), !confirmHidingEverything() {
                revision += 1   // redraws the picker back to what it was
                return
            }
            defaults.set(newValue.rawValue, forKey: Self.visibilityKey)
            revision += 1
            apply(newValue)
        }
    }

    /// - Returns: whether to go ahead.
    private func confirmHidingEverything() -> Bool {
        let alert = NSAlert()
        alert.messageText = "HardwareSentry will keep running with no icon anywhere."
        alert.informativeText = """
            It will carry on watching your hardware and showing notifications, but there             will be no menu bar item and no dock icon to click.

            To get back to these settings, open HardwareSentry again from Applications or             Launchpad.
            """
        alert.addButton(withTitle: "Hide the Icon")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        NSApplication.shared.activate()

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on {
            defaults.set(true, forKey: Self.suppressNoIconWarningKey)
        }
        return true
    }

    /// Called at launch as well as on change, so the choice from last time is in force
    /// before anybody sees the application.
    func applyStoredIconVisibility() {
        apply(iconVisibility)
    }

    /// Applies the choice at once, so picking one has a visible result.
    ///
    /// With one exception: dropping to `.accessory` while these settings are open would
    /// pull the window out from under whoever is reading it. So the application stays
    /// `.regular` for as long as the window is up, and `applyOnSettingsWindowClose()`
    /// finishes the job. Opening the window does the same in reverse — a menu-bar-only
    /// application has to become `.regular` briefly to take focus at all.
    private func apply(_ visibility: IconVisibility) {
        guard !isSettingsWindowOpen else { return }
        NSApplication.shared.setActivationPolicy(visibility.activationPolicy)
    }

    /// Called as the settings window appears and disappears, so the policy can be held at
    /// `.regular` while it is on screen.
    private(set) var isSettingsWindowOpen = false

    func settingsWindowOpened() {
        isSettingsWindowOpen = true
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    func settingsWindowClosed() {
        isSettingsWindowOpen = false
        NSApplication.shared.setActivationPolicy(iconVisibility.activationPolicy)
        // Focus goes back to whatever was in front before, which for a menu-bar
        // application is what somebody expects when they close its settings.
        if !iconVisibility.showsDockIcon { NSApplication.shared.hide(nil) }
    }

    private static let visibilityKey = "HardwareSentry.IconVisibility"
    private static let suppressNoIconWarningKey = "HardwareSentry.SuppressNoIconWarning"

    // MARK: - Starting with the Mac

    /// Read from the system rather than from a stored flag: somebody can turn a login item
    /// off in System Settings, and a remembered "yes" would then be a lie.
    var startsAtLogin: Bool {
        get {
            _ = revision
            return SMAppService.mainApp.status == .enabled
        }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Registration can be refused — most often because the application is not
                // in /Applications. Nothing to do but leave the switch reflecting reality,
                // which reading the real status already does.
            }
            revision += 1
        }
    }

    // MARK: - What launching says

    var showsConnectedDevicesAtLaunch: Bool {
        get {
            _ = revision
            return preferences.announcesWhatIsAlreadyThere
        }
        set {
            preferences.announcesWhatIsAlreadyThere = newValue
            revision += 1
        }
    }
}
