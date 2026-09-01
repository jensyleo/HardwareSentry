import AppKit
import Foundation

/// Which display banners appear on.
///
/// On a Mac with one screen every choice is the same screen, so this only starts to matter
/// once a second display is plugged in — which is exactly when it starts to matter a lot,
/// because a notification on the display you are not looking at is a notification you did
/// not get.
public enum BannerScreen: String, Sendable, CaseIterable, Identifiable {
    /// The display the pointer is on. The best available guess at where someone is
    /// looking, and the reason it is the default.
    case withPointer
    /// The display with the menu bar.
    case primary
    /// The display with the window currently taking keystrokes, falling back to the
    /// primary when nothing is focused.
    case active

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .withPointer: return "Where the pointer is"
        case .primary: return "Main display"
        case .active: return "Where the active window is"
        }
    }
}

/// What `BannerScreen` needs to know about one display in order to choose between them.
///
/// A plain value rather than an `NSScreen`, so the choosing can be exercised against a
/// pretend two-monitor desk without one.
public struct ScreenSnapshot: Sendable, Equatable {
    /// The area a banner may use — the full frame minus the menu bar and the Dock.
    public let visibleFrame: NSRect
    /// The whole display, used to decide which one the pointer is over. The pointer can
    /// legitimately sit in the menu bar or over the Dock, which are outside `visibleFrame`
    /// but plainly still on that display.
    public let frame: NSRect
    /// The display with the menu bar.
    public let isPrimary: Bool
    /// The display holding the window that currently takes keystrokes.
    public let isActive: Bool

    public init(visibleFrame: NSRect, frame: NSRect, isPrimary: Bool, isActive: Bool) {
        self.visibleFrame = visibleFrame
        self.frame = frame
        self.isPrimary = isPrimary
        self.isActive = isActive
    }
}

public extension BannerScreen {
    /// The area to draw in, or nil when there is nothing to draw on.
    ///
    /// Every branch falls back rather than failing. A display can be unplugged between one
    /// notification and the next, and the honest answer to "your chosen screen is gone" is
    /// another screen, not silence.
    func resolve(among screens: [ScreenSnapshot], pointer: NSPoint?) -> NSRect? {
        guard !screens.isEmpty else { return nil }

        let chosen: ScreenSnapshot?
        switch self {
        case .withPointer:
            chosen = pointer.flatMap { point in screens.first { $0.frame.contains(point) } }
        case .primary:
            chosen = screens.first(where: \.isPrimary)
        case .active:
            chosen = screens.first(where: \.isActive)
        }

        // The primary is the fallback rather than `screens[0]`: with a display unplugged
        // mid-session the order can be anything, and the display with the menu bar is the
        // one somebody would think of as theirs.
        return (chosen ?? screens.first(where: \.isPrimary) ?? screens.first)?.visibleFrame
    }
}

public extension ScreenSnapshot {
    /// The desk as it is right now.
    ///
    /// `NSScreen.main` is not the main display, despite the name — it is the screen with
    /// the key window. The display with the menu bar is `NSScreen.screens.first`. Getting
    /// those two the wrong way round is the whole reason this is spelled out here once
    /// instead of at each call site.
    @MainActor
    static func current() -> [ScreenSnapshot] {
        let active = NSScreen.main
        return NSScreen.screens.enumerated().map { index, screen in
            ScreenSnapshot(
                visibleFrame: screen.visibleFrame,
                frame: screen.frame,
                isPrimary: index == 0,
                isActive: screen == active
            )
        }
    }
}
