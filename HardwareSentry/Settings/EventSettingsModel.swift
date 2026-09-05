import Foundation
import MonitorRegistry
import Observation
import SentryContract
import SignalCore

/// What the events screen shows and edits.
///
/// The list is asked of the monitors rather than written out here, so a monitor gaining
/// an event gains a row without anyone remembering to add one — the same reason
/// `MonitorRegistry` is the only place that knows the whole list.
///
/// Exists because `NotificationPreferencesStore` is a plain store, not an observable one:
/// it is read by the dispatch pipeline from inside an actor, where SwiftUI's observation
/// has no business. This wraps it for the one place that does need to redraw when a
/// setting changes.
@MainActor
@Observable
final class EventSettingsModel {
    private(set) var modules: [MonitorDescription] = []

    @ObservationIgnored private let preferences: NotificationPreferencesStore
    @ObservationIgnored private let registry: MonitorRegistry
    @ObservationIgnored private let defaults: UserDefaults

    /// Bumped on every change so the whole screen redraws — a module being switched off
    /// greys out its events, so a row cannot only refresh itself.
    private var revision = 0

    init(
        preferences: NotificationPreferencesStore,
        registry: MonitorRegistry,
        defaults: UserDefaults = .standard
    ) {
        self.preferences = preferences
        self.registry = registry
        self.defaults = defaults
        // Everything, so this control can never silently stop a module somebody already
        // had running before it existed.
        defaults.register(defaults: [Self.performanceModeKey: PerformanceMode.all.rawValue])
    }

    func load() async {
        modules = await registry.describe()
        // The stored choice is put into force here, not only when somebody clicks it.
        //
        // Without this the presets were a label and nothing more: choosing "Minimal
        // elements" wrote the choice down, and the next launch read it back, showed it
        // selected, and ran every module anyway. A preset that describes the application
        // rather than deciding it is worse than no preset, because it says something
        // untrue every time the window is opened.
        applyPerformanceMode()
    }

    // MARK: - Reading and writing
    //
    // Each read touches `revision` so that a view rendering it is re-rendered when
    // anything here is written.

    /// Whether launching the application announces what is already plugged in.
    ///
    /// Takes effect at the next launch, not this one: the announcement happens as each
    /// monitor starts, and by the time anyone can reach this switch that has already
    /// happened. Said plainly in the settings rather than left to be discovered.
    var announcesWhatIsAlreadyThere: Bool {
        get {
            _ = revision
            return preferences.announcesWhatIsAlreadyThere
        }
        set {
            preferences.announcesWhatIsAlreadyThere = newValue
            revision += 1
        }
    }

    func isEnabled(_ category: NotificationCategory) -> Bool {
        _ = revision
        return preferences.isEnabled(category)
    }

    func setEnabled(_ enabled: Bool, for category: NotificationCategory) {
        preferences.setEnabled(enabled, for: category)
        // Touching one module by hand means the preset no longer describes what is
        // running, so the preset stops claiming to.
        fallIntoCustom()
        revision += 1
        // A module switched off stops watching, not just stops talking — so the registry
        // has to hear about it now rather than at the next launch.
        let registry = self.registry
        Task { await registry.refresh() }
    }

    func isEnabled(_ event: MonitorEventDescription, in category: NotificationCategory) -> Bool {
        _ = revision
        return preferences.isEnabled(event.name, in: category)
    }

    func setEnabled(_ enabled: Bool, for event: MonitorEventDescription, in category: NotificationCategory) {
        preferences.setEnabled(enabled, for: event.name, in: category)
        revision += 1
    }

    func isShown(_ field: MonitorFieldDescription, in category: NotificationCategory) -> Bool {
        _ = revision
        return preferences.isFieldEnabled(field.name, in: category)
    }

    func setShown(_ shown: Bool, for field: MonitorFieldDescription, in category: NotificationCategory) {
        preferences.setFieldEnabled(shown, for: field.name, in: category)
        revision += 1
    }

    // MARK: - How much of it runs

    /// Which modules run, as one choice rather than thirteen.
    ///
    /// Every module watching costs something — a few of them poll — and somebody who only
    /// wants to know when a disk is plugged in should not have to switch off twelve things
    /// one at a time to get there. The sets are the original's, and so is the default:
    /// everything, so that this control can never silently stop a module somebody already
    /// had running before it existed.
    enum PerformanceMode: Int, CaseIterable, Identifiable {
        case minimal = 0
        case all = 1
        case custom = 2
        /// Numbered last on purpose, as in the original: renumbering the others would make
        /// an already-stored choice mean something different.
        case recommended = 3

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .minimal: return "Minimal elements"
            case .recommended: return "Recommended"
            case .all: return "All elements"
            case .custom: return "Custom"
            }
        }

        var explanation: String {
            switch self {
            case .minimal: return "Only what the original HardwareGrowler shipped with: volumes, USB, Thunderbolt, Bluetooth, power and network."
            case .recommended: return "Minimal, plus the two most people want day to day: displays and audio devices. Leaves out the ones that poll or are niche."
            case .all: return "Every module. What you get if you never touch this."
            case .custom: return "Whatever you switch on yourself in the list below. Your arrangement is remembered if you try one of the others."
            }
        }

        /// Which categories run. Nil for custom, which is whatever is already stored.
        var categories: Set<String>? {
            switch self {
            case .minimal: return Self.minimalSet
            case .recommended: return Self.minimalSet.union(["Display", "Audio"])
            case .all: return nil
            case .custom: return nil
            }
        }

        private static let minimalSet: Set<String> = [
            "Volume", "USB", "Thunderbolt", "Bluetooth", "Power", "Network"
        ]
    }

    var performanceMode: PerformanceMode {
        _ = revision
        return PerformanceMode(rawValue: defaults.integer(forKey: Self.performanceModeKey)) ?? .all
    }

    /// Applies a preset, remembering the custom arrangement first.
    ///
    /// The snapshot is the original's own bug fix, and worth keeping: without it, going
    /// Custom → Minimal → Custom silently lost the arrangement, because applying a preset
    /// overwrites the same switches with no memory of what was there.
    func setPerformanceMode(_ mode: PerformanceMode) {
        let previous = performanceMode
        if previous == .custom, mode != .custom {
            // Captured on the way out, which is the original's own fix: applying a preset
            // overwrites the same switches, so without a copy taken first, Custom →
            // Minimal → Custom silently loses the arrangement somebody built by hand.
            let disabled = modules.filter { !isEnabled($0.category) }.map(\.category.rawValue)
            defaults.set(disabled, forKey: Self.customSnapshotKey)
        }

        defaults.set(mode.rawValue, forKey: Self.performanceModeKey)
        applyPerformanceMode(restoringCustom: mode == .custom)
    }

    /// Puts the stored mode into force.
    ///
    /// - Parameter restoringCustom: whether a return to Custom should bring back the
    ///   arrangement that was saved on the way out. True when somebody has just chosen
    ///   Custom; false at launch, where the switches on disk already *are* the custom
    ///   arrangement and re-applying an older snapshot over them would undo whatever has
    ///   been changed since.
    private func applyPerformanceMode(restoringCustom: Bool = false) {
        switch performanceMode {
        case .custom:
            guard restoringCustom,
                  let disabled = defaults.array(forKey: Self.customSnapshotKey) as? [String]
            else { break }
            let off = Set(disabled)
            for module in modules {
                preferences.setEnabled(!off.contains(module.category.rawValue), for: module.category)
            }
        case .all:
            // "All elements" was reported live as not actually meaning all: it only put
            // each module back to whatever it declares by default, leaving individual
            // notification and field checkboxes exactly where a person had last set
            // them — Scanner off, and a notification or field somebody had switched off
            // earlier stayed off. "Full" means every module, every one of its
            // notifications, and every optional field it can include, without exception —
            // Scanner included, which does mean accepting its Local Network permission
            // prompt; choosing this preset is the person asking for exactly that.
            for module in modules {
                preferences.setEnabled(true, for: module.category)
                for event in module.events {
                    preferences.setEnabled(true, for: event.name, in: module.category)
                }
                for field in module.fields {
                    preferences.setFieldEnabled(true, for: field.name, in: module.category)
                }
            }
        case .minimal, .recommended:
            guard let wanted = performanceMode.categories else { break }
            for module in modules {
                preferences.setEnabled(wanted.contains(module.category.rawValue), for: module.category)
            }
        }

        revision += 1
        let registry = self.registry
        Task { await registry.refresh() }
    }

    /// Switching one module by hand is what "custom" means, so it selects itself.
    private func fallIntoCustom() {
        guard performanceMode != .custom else { return }
        defaults.set(PerformanceMode.custom.rawValue, forKey: Self.performanceModeKey)
    }

    private static let performanceModeKey = "HardwareSentry.PerformanceMode"
    private static let customSnapshotKey = "HardwareSentry.PerformanceCustomSnapshot"

    /// Puts every module, event and field back to what its monitor declared, by forgetting
    /// the choices rather than by writing today's defaults over them.
    /// Switching everything back also brings the running monitors in line — including
    /// stopping any that default to off.
    func resetAll() {
        for module in modules {
            preferences.reset(module.category)
            for event in module.events {
                preferences.reset(event.name, in: module.category)
            }
            for field in module.fields {
                preferences.resetField(field.name, in: module.category)
            }
        }
        revision += 1
        let registry = self.registry
        Task { await registry.refresh() }
    }
}
