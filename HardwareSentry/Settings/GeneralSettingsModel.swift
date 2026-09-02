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
            defaults.set(newValue.rawValue, forKey: Self.visibilityKey)
            revision += 1
            apply(newValue)
        }
    }

    /// Called at launch as well as on change, so the choice from last time is in force
    /// before anybody sees the application.
    func applyStoredIconVisibility() {
        apply(iconVisibility)
    }

    private func apply(_ visibility: IconVisibility) {
        // Switching to `.accessory` while the settings window is open would hide it and
        // leave somebody who just chose "no icon visible" with no way back, so the policy
        // change waits until the window they are looking at has gone.
        guard NSApplication.shared.keyWindow == nil else { return }
        NSApplication.shared.setActivationPolicy(visibility.activationPolicy)
    }

    /// Applied when the settings window closes, for the case above.
    func applyDeferredIconVisibility() {
        NSApplication.shared.setActivationPolicy(iconVisibility.activationPolicy)
    }

    private static let visibilityKey = "HardwareSentry.IconVisibility"

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
