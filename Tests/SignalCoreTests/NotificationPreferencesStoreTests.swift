import Foundation
import Testing
@testable import SignalCore

private enum PowerEvent: String, NotificationEventKey {
    case lowPowerMode
    case adapterChanged
    static let category: NotificationCategory = "Power"
}

private enum USBEvent: String, NotificationEventKey {
    case connected
    static let category: NotificationCategory = "USB"
}

@Suite("NotificationPreferencesStore")
struct NotificationPreferencesStoreTests {
    /// Each test gets its own defaults, so nothing leaks between them or onto the machine.
    private func makeStore() -> (NotificationPreferencesStore, UserDefaults, String) {
        // A distinct key prefix as well as a distinct suite: registered defaults live in
        // a process-wide domain, so tests running side by side would otherwise see each
        // other's registrations.
        let suite = "SignalCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = NotificationPreferencesStore(defaults: defaults, keyPrefix: suite)
        return (store, defaults, suite)
    }

    private func tearDown(_ defaults: UserDefaults, _ suite: String) {
        defaults.removePersistentDomain(forName: suite)
    }

    // A notification a module bothered to raise should not disappear because nobody ever
    // said it was allowed.
    @Test("anything never chosen counts as wanted")
    func unsetMeansWanted() async {
        let (store, defaults, suite) = makeStore()
        defer { tearDown(defaults, suite) }

        #expect(store.isEnabled(PowerEvent.lowPowerMode))
        #expect(await store.isEventEnabled("lowPowerMode", in: "Power"))
        #expect(await store.isCategoryEnabled("Power"))
    }

    @Test("switching an event off is remembered")
    func settingIsRemembered() async {
        let (store, defaults, suite) = makeStore()
        defer { tearDown(defaults, suite) }

        store.setEnabled(false, for: PowerEvent.lowPowerMode)

        #expect(!store.isEnabled(PowerEvent.lowPowerMode))
        #expect(!(await store.isEventEnabled("lowPowerMode", in: "Power")))
    }

    // The pipeline asks by name and a preferences screen asks with a typed event; both
    // have to be talking about the same thing.
    @Test("the typed and by-name views agree")
    func typedAndByNameAgree() async {
        let (store, defaults, suite) = makeStore()
        defer { tearDown(defaults, suite) }

        store.setEnabled(false, for: USBEvent.connected)

        #expect(!(await store.isEventEnabled("connected", in: "USB")))
        #expect(await store.isEventEnabled("connected", in: "Power")) // a different module
    }

    @Test("switching one event off leaves its siblings alone")
    func siblingsUnaffected() {
        let (store, defaults, suite) = makeStore()
        defer { tearDown(defaults, suite) }

        store.setEnabled(false, for: PowerEvent.lowPowerMode)

        #expect(store.isEnabled(PowerEvent.adapterChanged))
    }

    @Test("switching a whole module off is separate from its events")
    func categoryIsSeparateFromEvents() async {
        let (store, defaults, suite) = makeStore()
        defer { tearDown(defaults, suite) }

        store.setEnabled(false, for: NotificationCategory("Power"))

        #expect(!(await store.isCategoryEnabled("Power")))
        #expect(store.isEnabled(PowerEvent.lowPowerMode)) // the event itself was not touched
    }

    @Test("a registered default applies until the user chooses")
    func registeredDefaultApplies() {
        let (store, defaults, suite) = makeStore()
        defer { tearDown(defaults, suite) }

        store.registerDefaults([PowerEvent.lowPowerMode: false])

        #expect(!store.isEnabled(PowerEvent.lowPowerMode))
        #expect(store.isEnabled(PowerEvent.adapterChanged)) // nothing registered for this one
    }

    @Test("a choice takes precedence over a registered default")
    func choiceBeatsDefault() {
        let (store, defaults, suite) = makeStore()
        defer { tearDown(defaults, suite) }

        store.registerDefaults([PowerEvent.lowPowerMode: false])
        store.setEnabled(true, for: PowerEvent.lowPowerMode)

        #expect(store.isEnabled(PowerEvent.lowPowerMode))
    }

    // Forgetting a choice must fall back to what was registered, not to nothing.
    @Test("clearing a choice falls back to the registered default")
    func resetFallsBackToDefault() {
        let (store, defaults, suite) = makeStore()
        defer { tearDown(defaults, suite) }

        store.registerDefaults([PowerEvent.lowPowerMode: false])
        store.setEnabled(true, for: PowerEvent.lowPowerMode)
        store.reset(PowerEvent.lowPowerMode)

        #expect(!store.isEnabled(PowerEvent.lowPowerMode))
    }

    @Test("two modules naming an event alike stay independent")
    func modulesAreIndependent() {
        let (store, defaults, suite) = makeStore()
        defer { tearDown(defaults, suite) }

        #expect(store.key(for: "connected", in: "USB") != store.key(for: "connected", in: "Bluetooth"))
    }

    @Test("a module's own switch is a different key from its events")
    func categoryKeyDiffersFromEventKey() {
        let (store, defaults, suite) = makeStore()
        defer { tearDown(defaults, suite) }

        #expect(store.key(for: "Power") != store.key(for: "", in: "Power"))
    }

    @Test("the store drives the pipeline filters")
    func drivesTheFilters() async {
        let (store, defaults, suite) = makeStore()
        defer { tearDown(defaults, suite) }

        store.setEnabled(false, for: USBEvent.connected)

        let filter = EventEnabledFilter(preferences: store)
        let blocked = await filter.process(
            makeEvent(name: "connected", category: "USB"),
            context: makeContext()
        )
        let allowed = await filter.process(
            makeEvent(name: "disconnected", category: "USB"),
            context: makeContext()
        )

        #expect(blocked.isSuppress)
        #expect(allowed.isDeliver)
    }
}
