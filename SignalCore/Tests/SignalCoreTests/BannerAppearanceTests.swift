import Foundation
import Testing
@testable import SignalCore

@Suite("BannerAppearance")
struct BannerAppearanceTests {
    @Test("out of the box, banners look the way they did before any of this was configurable")
    func standardMatchesPreviousBehaviour() {
        let standard = BannerAppearance.standard

        #expect(standard.corner == .topTrailing)
        #expect(standard.width == 300)
        #expect(standard.margin == 12)
        #expect(standard.spacing == 8)
        #expect(standard.visibleLifetime == 5)
        #expect(standard.opacity == 1)
        #expect(standard.isAnimated)
    }

    @Test("a nonsensical stored value cannot produce a banner nobody can see")
    func constructionClampsAbsurdValues() {
        let appearance = BannerAppearance(width: 0, margin: -50, visibleLifetime: 0, opacity: 0)

        #expect(appearance.width == BannerAppearance.widthRange.lowerBound)
        #expect(appearance.margin == BannerAppearance.marginRange.lowerBound)
        #expect(appearance.visibleLifetime == BannerAppearance.lifetimeRange.lowerBound)
        #expect(appearance.opacity == BannerAppearance.opacityRange.lowerBound)
    }

    @Test("values set after construction are clamped too, not just those passed in")
    func mutationClampsAsWell() {
        var appearance = BannerAppearance.standard
        appearance.width = 10_000
        appearance.visibleLifetime = -1

        #expect(appearance.width == BannerAppearance.widthRange.upperBound)
        #expect(appearance.visibleLifetime == BannerAppearance.lifetimeRange.lowerBound)
    }

    @Test("each corner knows which way it stacks and slides in from")
    func cornerGeometry() {
        #expect(BannerCorner.topTrailing.isTop)
        #expect(!BannerCorner.topTrailing.isLeading)
        #expect(!BannerCorner.bottomLeading.isTop)
        #expect(BannerCorner.bottomLeading.isLeading)
    }
}

@Suite("BannerAppearanceStore")
struct BannerAppearanceStoreTests {
    /// A suite and prefix of its own per test: these run in parallel, and one test's
    /// choices must not be another's starting point.
    @MainActor
    private func makeStore(_ id: String = UUID().uuidString) -> (BannerAppearanceStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "BannerAppearanceStoreTests.\(id)")!
        return (BannerAppearanceStore(defaults: defaults, keyPrefix: "Test.\(id)"), defaults)
    }

    @Test("a fresh store hands back the standard look")
    @MainActor
    func freshStoreIsStandard() {
        let (store, _) = makeStore()
        #expect(store.appearance == .standard)
    }

    @Test("what is chosen is what comes back next launch")
    @MainActor
    func choicesSurviveARelaunch() {
        let id = UUID().uuidString
        let (store, defaults) = makeStore(id)

        store.appearance.corner = .bottomLeading
        store.appearance.width = 420
        store.appearance.visibleLifetime = 12
        store.appearance.textScale = .large
        store.appearance.material = .hud
        store.appearance.isAnimated = false
        store.appearance.animationDuration = 0.6
        store.appearance.tint = .custom(red: 0.1, green: 0.5, blue: 0.9)

        let reopened = BannerAppearanceStore(defaults: defaults, keyPrefix: "Test.\(id)")

        #expect(reopened.appearance.corner == .bottomLeading)
        #expect(reopened.appearance.width == 420)
        #expect(reopened.appearance.visibleLifetime == 12)
        #expect(reopened.appearance.textScale == .large)
        #expect(reopened.appearance.material == .hud)
        #expect(!reopened.appearance.isAnimated)
        #expect(reopened.appearance.animationDuration == 0.6)
        #expect(reopened.appearance.tint == .custom(red: 0.1, green: 0.5, blue: 0.9))
    }

    @Test("choosing the system material again is remembered too, not just custom")
    @MainActor
    func tintBackToSystemMaterialSurvivesARelaunch() {
        let id = UUID().uuidString
        let (store, defaults) = makeStore(id)

        store.appearance.tint = .custom(red: 0.1, green: 0.5, blue: 0.9)
        store.appearance.tint = .systemMaterial

        let reopened = BannerAppearanceStore(defaults: defaults, keyPrefix: "Test.\(id)")
        #expect(reopened.appearance.tint == .systemMaterial)
    }

    @Test("one unreadable setting does not throw away the rest")
    @MainActor
    func garbageFallsBackPerFieldOnly() {
        let id = UUID().uuidString
        let (store, defaults) = makeStore(id)
        store.appearance.width = 420

        // Something else wrote nonsense over one key — a hand-edited defaults entry, or
        // a value written by a future version that means something different.
        defaults.set("not a corner at all", forKey: "Test.\(id).corner")

        let reopened = BannerAppearanceStore(defaults: defaults, keyPrefix: "Test.\(id)")

        #expect(reopened.appearance.corner == BannerAppearance.standard.corner)
        #expect(reopened.appearance.width == 420)
    }

    @Test("a stored value outside what the editor allows is still brought back into range")
    @MainActor
    func storedValueOutOfRangeIsClamped() {
        let id = UUID().uuidString
        let (_, defaults) = makeStore(id)
        defaults.set(99_999.0, forKey: "Test.\(id).width")

        let store = BannerAppearanceStore(defaults: defaults, keyPrefix: "Test.\(id)")

        #expect(store.appearance.width == BannerAppearance.widthRange.upperBound)
    }

    @Test("resetting forgets every choice, not just the ones still on screen")
    @MainActor
    func resetForgetsEverything() {
        let id = UUID().uuidString
        let (store, defaults) = makeStore(id)
        store.appearance.corner = .bottomLeading
        store.appearance.width = 500

        store.reset()

        #expect(store.appearance == .standard)
        #expect(defaults.object(forKey: "Test.\(id).width") == nil)

        let reopened = BannerAppearanceStore(defaults: defaults, keyPrefix: "Test.\(id)")
        #expect(reopened.appearance == .standard)
    }
}

@Suite("BannerSound")
struct BannerSoundTests {
    @Test("silence is the default, so the application does not start making noise unasked")
    func silentByDefault() {
        #expect(BannerAppearance.standard.sound == .none)
    }

    @Test("only a real choice has a system sound to ask for")
    func onlyChosenSoundsResolve() {
        #expect(BannerSound.none.systemName == nil)
        #expect(BannerSound.glass.systemName == "Glass")
        #expect(BannerSound.none.label == "None")
    }

    @Test("every sound but silence names a file macOS actually ships")
    func everySoundExists() {
        // A name that resolves to nothing would be a silent setting pretending to be a
        // sound, which is worse than not offering it.
        for sound in BannerSound.allCases where sound != .none {
            let path = "/System/Library/Sounds/\(sound.rawValue).aiff"
            #expect(FileManager.default.fileExists(atPath: path), "missing \(sound.rawValue)")
        }
    }

    @Test("a chosen sound comes back next launch")
    @MainActor
    func soundSurvivesRelaunch() {
        let id = UUID().uuidString
        let defaults = UserDefaults(suiteName: "BannerSoundTests.\(id)")!
        let store = BannerAppearanceStore(defaults: defaults, keyPrefix: "Test.\(id)")

        store.appearance.sound = .submarine
        let reopened = BannerAppearanceStore(defaults: defaults, keyPrefix: "Test.\(id)")

        #expect(reopened.appearance.sound == .submarine)
    }
}

@MainActor
@Suite("Banner themes")
struct BannerThemeTests {
    private func store() -> BannerThemeStore {
        BannerThemeStore(defaults: UserDefaults(suiteName: "BannerThemeTests-\(UUID().uuidString)")!)
    }

    @Test("applying a theme changes the look and nothing else")
    func appliesOnlyTheLook() throws {
        let compact = try #require(BannerTheme.builtIn.first { $0.name == "Compact" })
        let mine = BannerAppearance(corner: .bottomLeading, visibleLifetime: 20, sound: .glass, screen: .primary)
        let result = compact.applied(to: mine)
        #expect(result.cornerRadius == 8)
        #expect(result.textScale == .small)
        #expect(result.corner == .bottomLeading)
        #expect(result.visibleLifetime == 20)
        #expect(result.sound == .glass)
    }

    @Test("a theme recognises the look it made")
    func matchesItself() throws {
        let ocean = try #require(BannerTheme.builtIn.first { $0.name == "Ocean" })
        #expect(ocean.matches(ocean.applied(to: .standard)))
        #expect(!ocean.matches(.standard))
    }

    @Test("saved themes survive, and a built-in name cannot be taken")
    func savesAndRefuses() {
        let themes = store()
        #expect(themes.save(name: "Mine", from: BannerAppearance(cornerRadius: 20)))
        #expect(themes.custom.map(\.name) == ["Mine"])
        #expect(!themes.save(name: "Glass", from: .standard))
        #expect(!themes.save(name: "  ", from: .standard))
        #expect(themes.custom.count == 1)
    }

    @Test("export then import round-trips, skipping built-in names")
    func roundTrip() throws {
        let a = store(); a.save(name: "Mine", from: BannerAppearance(borderWidth: 3))
        let data = try #require(a.exportData())
        let b = store()
        #expect(b.importData(data) == 1)
        #expect(b.custom.first?.borderWidth == 3)
        #expect(b.importData(Data("nonsense".utf8)) == nil)
    }
}

@MainActor
@Suite("Banner severity styles")
struct BannerSeverityStyleTests {
    @Test("a badge maps to the kind of notice it marks")
    func mapping() {
        #expect(BannerSeverity(badge: nil) == .info)
        #expect(BannerSeverity(badge: .positive) == .connected)
        #expect(BannerSeverity(badge: .negative) == .gone)
        #expect(BannerSeverity(badge: .warning) == .attention)
        #expect(BannerSeverity(badge: .critical) == .critical)
    }

    @Test("a kind with nothing special is left out, so it looks like the rest")
    func defaultsDropped() {
        let appearance = BannerAppearance(severityStyles: [.info: BannerSeverityStyle(), .attention: BannerSeverityStyle(staysUntilDismissed: true)])
        #expect(appearance.severityStyles.keys.sorted { $0.rawValue < $1.rawValue } == [.attention])
        #expect(appearance.style(for: .info).isDefault)
    }

    @Test("styles survive being stored and read back")
    func persists() {
        let defaults = UserDefaults(suiteName: "SeverityTests-\(UUID().uuidString)")!
        let store = BannerAppearanceStore(defaults: defaults, keyPrefix: "T")
        store.appearance.severityStyles[.attention] = BannerSeverityStyle(accent: [1, 0.5, 0], sound: .glass, staysUntilDismissed: true)
        let reread = BannerAppearanceStore(defaults: defaults, keyPrefix: "T")
        #expect(reread.appearance.style(for: .attention).sound == .glass)
        #expect(reread.appearance.style(for: .attention).staysUntilDismissed)
        #expect(reread.appearance.style(for: .attention).accent == [1, 0.5, 0])
        #expect(reread.appearance.style(for: .gone).isDefault)
    }
}

@MainActor
@Suite("Banner themes by macOS mode")
struct BannerThemeModeTests {
    @Test("the theme for the current mode is laid over the look, and nothing is chosen means nothing changes")
    func perMode() {
        let themes = BannerThemeStore(defaults: UserDefaults(suiteName: "ModeTests-\(UUID().uuidString)")!)
        let base = BannerAppearance(corner: .bottomLeading)
        #expect(themes.automaticallyApplied(to: base, isDark: true) == base)
        themes.darkThemeName = "Ember"
        let dark = themes.automaticallyApplied(to: base, isDark: true)
        #expect(dark.cornerRadius == 16)
        #expect(dark.corner == .bottomLeading)
        #expect(themes.automaticallyApplied(to: base, isDark: false) == base)
        themes.darkThemeName = "No such theme"
        #expect(themes.automaticallyApplied(to: base, isDark: true) == base)
    }
}

@Suite("Per-module time on screen")
struct ModuleLifetimeTests {
    @Test("a module with its own time leaves by it, the others by the shared one")
    func ownTime() {
        var stack = BannerStack(availableHeight: 1000, visibleLifetime: 10, revealSpacing: 0)
        stack.lifetimeByModule = ["Power": 3]
        let now = Date()
        _ = stack.admit(NotificationEvent(name: "a", category: "Power", title: "p", body: ""), height: 50, at: now, phase: .steady)
        _ = stack.admit(NotificationEvent(name: "b", category: "USB", title: "u", body: ""), height: 50, at: now, phase: .steady)
        let after4 = stack.expire(at: now.addingTimeInterval(4))
        #expect(after4.removed.count == 1)
        #expect(stack.visible.count == 1)
        let after11 = stack.expire(at: now.addingTimeInterval(11))
        #expect(after11.removed.count == 1)
    }
}
