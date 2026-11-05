import Foundation
import Testing
@testable import SignalCore

@Suite("IconOverride")
struct IconOverrideTests {
    @Test("a choice survives being written down and read back")
    func roundTrips() {
        for override: IconOverride in [.symbol("bolt.fill"), .file("/Users/x/My Icons/thing.png")] {
            #expect(IconOverride(storedValue: override.storedValue) == override)
        }
    }

    @Test("a stored value that means nothing is no choice, not a broken one")
    func unreadableValuesAreIgnored() {
        // Written by hand, or by a version that meant something different by it.
        #expect(IconOverride(storedValue: "bolt.fill") == nil)
        #expect(IconOverride(storedValue: "symbol:") == nil)
        #expect(IconOverride(storedValue: "file:") == nil)
        #expect(IconOverride(storedValue: "") == nil)
    }

    @Test("a path with a colon in it survives, since colons are legal in file names")
    func pathsWithColonsSurvive() {
        let override = IconOverride.file("/Users/x/a:b/icon.png")
        #expect(IconOverride(storedValue: override.storedValue) == override)
    }

    @Test("two monitors can both have an event called Connected")
    func keysAreScopedToTheirCategory() {
        var overrides = IconOverrides()
        overrides["Connected", in: "USB"] = .symbol("cable.connector")
        overrides["Connected", in: "Bluetooth"] = .symbol("wave.3.right")

        #expect(overrides["Connected", in: "USB"] == .symbol("cable.connector"))
        #expect(overrides["Connected", in: "Bluetooth"] == .symbol("wave.3.right"))
    }
}

@Suite("IconOverrideStore")
struct IconOverrideStoreTests {
    @MainActor
    private func makeStore(_ id: String) -> (IconOverrideStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "IconOverrideStoreTests.\(id)")!
        return (IconOverrideStore(defaults: defaults, keyPrefix: "Test.\(id)"), defaults)
    }

    @Test("a fresh store has nobody's choices in it")
    @MainActor
    func freshStoreIsEmpty() {
        let (store, _) = makeStore(UUID().uuidString)
        #expect(store.overrides.isEmpty)
    }

    @Test("a choice comes back next launch")
    @MainActor
    func choicesSurviveARelaunch() {
        let id = UUID().uuidString
        let (store, defaults) = makeStore(id)
        store.setOverride(.symbol("bolt.fill"), for: "USBConnected", in: "USB")
        store.setOverride(.file("/tmp/x.png"), for: "ThermalCritical", in: "Thermal")

        let reopened = IconOverrideStore(defaults: defaults, keyPrefix: "Test.\(id)")

        #expect(reopened.override(for: "USBConnected", in: "USB") == .symbol("bolt.fill"))
        #expect(reopened.override(for: "ThermalCritical", in: "Thermal") == .file("/tmp/x.png"))
    }

    @Test("clearing a choice removes the key rather than writing an empty one")
    @MainActor
    func clearingRemovesTheKey() {
        // "No choice" and "chose nothing" must not be indistinguishable next launch.
        let id = UUID().uuidString
        let (store, defaults) = makeStore(id)
        store.setOverride(.symbol("bolt.fill"), for: "USBConnected", in: "USB")
        store.setOverride(nil, for: "USBConnected", in: "USB")

        #expect(defaults.object(forKey: "Test.\(id).USB.USBConnected") == nil)
        let reopened = IconOverrideStore(defaults: defaults, keyPrefix: "Test.\(id)")
        #expect(reopened.override(for: "USBConnected", in: "USB") == nil)
    }

    @Test("one unreadable key costs one icon, not all of them")
    @MainActor
    func garbageCostsOneEntryOnly() {
        let id = UUID().uuidString
        let (store, defaults) = makeStore(id)
        store.setOverride(.symbol("bolt.fill"), for: "USBConnected", in: "USB")
        defaults.set("nonsense", forKey: "Test.\(id).Thermal.ThermalCritical")

        let reopened = IconOverrideStore(defaults: defaults, keyPrefix: "Test.\(id)")

        #expect(reopened.override(for: "USBConnected", in: "USB") == .symbol("bolt.fill"))
        #expect(reopened.override(for: "ThermalCritical", in: "Thermal") == nil)
    }

    @Test("resetting puts every event back to the icon its monitor picked")
    @MainActor
    func resetForgetsEverything() {
        let id = UUID().uuidString
        let (store, defaults) = makeStore(id)
        store.setOverride(.symbol("bolt.fill"), for: "USBConnected", in: "USB")
        store.setOverride(.symbol("wave.3.right"), for: "BluetoothConnected", in: "Bluetooth")

        store.resetAll()

        #expect(store.overrides.isEmpty)
        let reopened = IconOverrideStore(defaults: defaults, keyPrefix: "Test.\(id)")
        #expect(reopened.overrides.isEmpty)
    }

    @Test("repointing a file moves every choice that used it, and survives a relaunch")
    @MainActor func repointFile() {
        let defaults = UserDefaults(suiteName: "repoint-\(UUID().uuidString)")!
        let store = IconOverrideStore(defaults: defaults, keyPrefix: "T")
        store.setOverride(.file("/old.png"), for: "A", in: "USB")
        store.setOverride(.file("/old.png"), for: "B", in: "Audio")
        store.setOverride(.file("/other.png"), for: "C", in: "USB")
        let before = store.revision

        store.repointFile(from: "/old.png", to: "/new.png")

        #expect(store.override(for: "A", in: "USB") == .file("/new.png"))
        #expect(store.override(for: "B", in: "Audio") == .file("/new.png"))
        #expect(store.override(for: "C", in: "USB") == .file("/other.png"))
        #expect(store.revision > before)
        let reloaded = IconOverrideStore(defaults: defaults, keyPrefix: "T")
        #expect(reloaded.override(for: "B", in: "Audio") == .file("/new.png"))
        #expect(Set(reloaded.overrides.allChoices.map(\.storedValue)) == ["file:/new.png", "file:/other.png"])
    }

    @Test("the revision moves on every edit, so a host has one thing to watch")
    @MainActor
    func revisionAdvances() {
        let (store, _) = makeStore(UUID().uuidString)
        let start = store.revision
        store.setOverride(.symbol("bolt.fill"), for: "USBConnected", in: "USB")
        store.setOverride(nil, for: "USBConnected", in: "USB")
        #expect(store.revision == start + 2)
    }
}

@Suite("IconOverrideMiddleware")
struct IconOverrideMiddlewareTests {
    private let event = NotificationEvent(
        name: "USBConnected", category: "USB",
        title: "Connected", body: "A thing", icon: .symbol("default.icon")
    )

    private func icon(after middleware: IconOverrideMiddleware, _ event: NotificationEvent) async -> NotificationIcon? {
        guard case .deliver(let out) = await middleware.process(event, context: DispatchContext(phase: .steady, firedAt: Date()))
        else { return nil }
        return out.icon
    }

    private func badgeShown(after middleware: IconOverrideMiddleware, _ event: NotificationEvent) async -> Bool? {
        guard case .deliver(let out) = await middleware.process(event, context: DispatchContext(phase: .steady, firedAt: Date()))
        else { return nil }
        return out.showsIconBadge
    }

    @Test("keeping the original survives being written down and read back")
    func originalRoundTrips() {
        #expect(IconOverride(storedValue: IconOverride.original.storedValue) == .original)
        #expect(IconOverride.original.storedValue == "original")
    }

    @Test("keeping the original leaves the icon alone, unmarked, and stops later stages swapping it")
    func originalIsFinal() async {
        var overrides = IconOverrides()
        overrides["USBConnected", in: "USB"] = .original
        var event = self.event
        event.iconKind = "usb.generic"
        event.iconModel = "05ac:0001"
        guard case .deliver(let out) = await IconOverrideMiddleware(overrides: overrides)
            .process(event, context: DispatchContext(phase: .steady, firedAt: Date()))
        else { Issue.record("dropped"); return }
        #expect(out.icon == .symbol("default.icon"))
        #expect(out.showsIconBadge == false)
        #expect(out.iconKind == nil)
        #expect(out.iconModel == nil)
    }

    @Test("any choice made by hand clears what the icon depicts; no choice keeps it")
    func choiceClearsKind() async {
        var event = self.event
        event.iconKind = "usb.generic"
        var overrides = IconOverrides()
        overrides["USBConnected", in: "USB"] = .symbol("star")
        let context = DispatchContext(phase: .steady, firedAt: Date())
        if case .deliver(let out) = await IconOverrideMiddleware(overrides: overrides).process(event, context: context) {
            #expect(out.iconKind == nil)
        }
        if case .deliver(let out) = await IconOverrideMiddleware().process(event, context: context) {
            #expect(out.iconKind == "usb.generic")
        }
    }

    @Test("a chosen picture has the state marked on it; the monitor's own does not")
    func badgeFollowsTheChoice() async {
        var overrides = IconOverrides()
        overrides["USBConnected", in: "USB"] = .symbol("star")
        #expect(await badgeShown(after: IconOverrideMiddleware(overrides: overrides), event) == true)
        #expect(await badgeShown(after: IconOverrideMiddleware(), event) == false)
    }

    @Test("a chosen file that has gone missing falls back unmarked, since the fallback carries its own state")
    func missingFileIsUnmarked() async {
        var overrides = IconOverrides()
        overrides["USBConnected", in: "USB"] = .file("/nope.png")
        let middleware = IconOverrideMiddleware(overrides: overrides, readFile: { _ in nil })
        #expect(await badgeShown(after: middleware, event) == false)
    }

    @Test("an event nobody chose an icon for keeps the one its monitor picked")
    func untouchedEventsAreLeftAlone() async {
        let middleware = IconOverrideMiddleware()
        #expect(await icon(after: middleware, event) == .symbol("default.icon"))
    }

    @Test("a chosen symbol replaces the monitor's own")
    func symbolIsSubstituted() async {
        var overrides = IconOverrides()
        overrides["USBConnected", in: "USB"] = .symbol("bolt.fill")
        let middleware = IconOverrideMiddleware(overrides: overrides)

        #expect(await icon(after: middleware, event) == .symbol("bolt.fill"))
    }

    @Test("a chosen file is read and sent as image data")
    func fileIsRead() async {
        var overrides = IconOverrides()
        overrides["USBConnected", in: "USB"] = .file("/tmp/icon.png")
        let middleware = IconOverrideMiddleware(overrides: overrides, readFile: { _ in Data([1, 2, 3]) })

        #expect(await icon(after: middleware, event) == .imageData(Data([1, 2, 3])))
    }

    @Test("a file that has moved falls back rather than losing the notification")
    func missingFileFallsBack() async {
        // The monitor's own icon is a better answer than no icon, and far better than
        // refusing to show the notification over a decoration.
        var overrides = IconOverrides()
        overrides["USBConnected", in: "USB"] = .file("/tmp/gone.png")
        let middleware = IconOverrideMiddleware(overrides: overrides, readFile: { _ in nil })

        #expect(await icon(after: middleware, event) == .symbol("default.icon"))
    }

    @Test("a file is read once, not on every notification")
    func fileIsCached() async {
        let counter = ReadCounter()
        var overrides = IconOverrides()
        overrides["USBConnected", in: "USB"] = .file("/tmp/icon.png")
        let middleware = IconOverrideMiddleware(overrides: overrides, readFile: { _ in counter.read() })

        for _ in 0..<3 { _ = await icon(after: middleware, event) }
        #expect(counter.count == 1)
    }

    @Test("editing the choices re-reads the picture, in case that is what changed")
    func editingClearsTheCache() async {
        // Whoever has just been editing icons is also the likeliest to have edited the
        // picture itself; a stale image would look like the setting did not take.
        let counter = ReadCounter()
        var overrides = IconOverrides()
        overrides["USBConnected", in: "USB"] = .file("/tmp/icon.png")
        let middleware = IconOverrideMiddleware(overrides: overrides, readFile: { _ in counter.read() })

        _ = await icon(after: middleware, event)
        overrides["ThermalCritical", in: "Thermal"] = .symbol("flame")
        await middleware.update(overrides)
        _ = await icon(after: middleware, event)

        #expect(counter.count == 2)
    }

    @Test("an icon chosen for one monitor's event does not leak to another's")
    func overridesDoNotLeakAcrossCategories() async {
        var overrides = IconOverrides()
        overrides["Connected", in: "Bluetooth"] = .symbol("wave.3.right")
        let middleware = IconOverrideMiddleware(overrides: overrides)

        let usb = NotificationEvent(name: "Connected", category: "USB", title: "t", body: "b", icon: .symbol("usb"))
        #expect(await icon(after: middleware, usb) == .symbol("usb"))
    }
}

/// Counts how many times the middleware went to disk.
private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func read() -> Data {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return Data([UInt8(value)])
    }
}
