import AppKit
import Foundation
import Testing
@testable import SignalCore

@Suite("BannerScreen")
struct BannerScreenTests {
    /// A pretend two-monitor desk: a laptop display on the left with the menu bar, and a
    /// larger one to its right holding the window being typed into.
    private static let laptop = ScreenSnapshot(
        visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 850),
        frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
        isPrimary: true,
        isActive: false
    )
    private static let external = ScreenSnapshot(
        visibleFrame: NSRect(x: 1440, y: 0, width: 2560, height: 1400),
        frame: NSRect(x: 1440, y: 0, width: 2560, height: 1440),
        isPrimary: false,
        isActive: true
    )
    private static let desk = [laptop, external]

    @Test("the pointer's display wins when that is what was asked for")
    func pointerPicksItsOwnScreen() {
        #expect(BannerScreen.withPointer.resolve(among: Self.desk, pointer: NSPoint(x: 2000, y: 700)) == Self.external.visibleFrame)
        #expect(BannerScreen.withPointer.resolve(among: Self.desk, pointer: NSPoint(x: 100, y: 100)) == Self.laptop.visibleFrame)
    }

    @Test("a pointer in the menu bar still counts as being on that display")
    func pointerOutsideTheVisibleFrameStillCounts() {
        // The menu bar and the Dock sit outside `visibleFrame` but are plainly still on
        // the display, which is why the pointer is matched against the full frame.
        #expect(BannerScreen.withPointer.resolve(among: Self.desk, pointer: NSPoint(x: 700, y: 880)) == Self.laptop.visibleFrame)
    }

    @Test("the main display is the one with the menu bar, not the one with the key window")
    func primaryIsTheMenuBarScreen() {
        // NSScreen.main is not the main display despite the name — getting these the wrong
        // way round is the mistake this choice exists to make impossible.
        #expect(BannerScreen.primary.resolve(among: Self.desk, pointer: nil) == Self.laptop.visibleFrame)
        #expect(BannerScreen.active.resolve(among: Self.desk, pointer: nil) == Self.external.visibleFrame)
    }

    @Test("a pointer nowhere anybody can see falls back to the main display")
    func unknownPointerFallsBack() {
        // A display can be unplugged between the pointer being read and this being asked.
        #expect(BannerScreen.withPointer.resolve(among: Self.desk, pointer: NSPoint(x: 9999, y: 9999)) == Self.laptop.visibleFrame)
        #expect(BannerScreen.withPointer.resolve(among: Self.desk, pointer: nil) == Self.laptop.visibleFrame)
    }

    @Test("nothing focused falls back to the main display rather than to nothing")
    func noActiveScreenFallsBack() {
        let unfocused = Self.desk.map {
            ScreenSnapshot(visibleFrame: $0.visibleFrame, frame: $0.frame, isPrimary: $0.isPrimary, isActive: false)
        }
        #expect(BannerScreen.active.resolve(among: unfocused, pointer: nil) == Self.laptop.visibleFrame)
    }

    @Test("with the menu-bar display gone, some display is still chosen")
    func missingPrimaryStillYieldsAScreen() {
        // Unplugging mid-session leaves the order arbitrary; the honest answer to "your
        // chosen screen is gone" is another screen, never silence.
        #expect(BannerScreen.primary.resolve(among: [Self.external], pointer: nil) == Self.external.visibleFrame)
    }

    @Test("no displays at all is the one case with no answer")
    func noScreensMeansNoFrame() {
        for choice in BannerScreen.allCases {
            #expect(choice.resolve(among: [], pointer: NSPoint(x: 0, y: 0)) == nil)
        }
    }

    @Test("with one display every choice is that display")
    func oneScreenMakesTheChoiceMoot() {
        let only = ScreenSnapshot(
            visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 850),
            frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            isPrimary: true, isActive: true
        )
        for choice in BannerScreen.allCases {
            #expect(choice.resolve(among: [only], pointer: NSPoint(x: 9999, y: 9999)) == only.visibleFrame)
        }
    }

    @Test("the pointer's display is the default, being the best guess at where someone is looking")
    func defaultIsThePointer() {
        #expect(BannerAppearance.standard.screen == .withPointer)
    }

    @Test("a chosen display comes back next launch")
    @MainActor
    func choiceSurvivesARelaunch() {
        let id = UUID().uuidString
        let defaults = UserDefaults(suiteName: "BannerScreenTests.\(id)")!
        let store = BannerAppearanceStore(defaults: defaults, keyPrefix: "Test.\(id)")

        store.appearance.screen = .active
        let reopened = BannerAppearanceStore(defaults: defaults, keyPrefix: "Test.\(id)")

        #expect(reopened.appearance.screen == .active)
    }
}
