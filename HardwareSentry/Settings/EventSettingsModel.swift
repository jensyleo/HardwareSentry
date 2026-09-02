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

    /// Bumped on every change so the whole screen redraws — a module being switched off
    /// greys out its events, so a row cannot only refresh itself.
    private var revision = 0

    init(preferences: NotificationPreferencesStore, registry: MonitorRegistry) {
        self.preferences = preferences
        self.registry = registry
    }

    func load() async {
        modules = await registry.describe()
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
