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
