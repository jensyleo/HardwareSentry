import SwiftUI

@main
struct HardwareSentryApp: App {
    static let settingsWindowID = "settings"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The application's own icon rather than a system symbol: in a menu bar full of
        // other people's glyphs, the thing that makes this one findable is that it looks
        // like the application it belongs to.
        MenuBarExtra(isInserted: Binding(
            get: { delegate.menuBarIconIsVisible },
            set: { delegate.menuBarIconIsVisible = $0 }
        )) {
            Button("About HardwareSentry") {
                NSApplication.shared.orderFrontStandardAboutPanel(nil)
                NSApplication.shared.activate()
            }

            Button("Send a Test Notification") {
                delegate.sendTestNotification()
            }

            Divider()

            SettingsButton()

            Divider()

            Button("Quit HardwareSentry") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            MenuBarIcon(delegate: delegate)
        }
        // Hidden when somebody has asked for the dock only, or for nothing at all. The
        // application keeps running either way — this is where it shows itself, not
        // whether it works.


        // A plain window rather than the `Settings` scene: that one sizes itself to the
        // content's intrinsic height and refuses to resize, which leaves the appearance
        // tab permanently cut off — and it grows with every setting added. The menu item
        // and ⌘, are wired by hand below, which is the whole of what `Settings` gave us.
        Window("HardwareSentry Settings", id: Self.settingsWindowID) {
            SettingsView(appearance: delegate.appearance, events: delegate.eventSettings, history: delegate.history, iconOverrides: delegate.iconOverrides, general: delegate.general)
                .onAppear { NSApplication.shared.activate() }
        }
        .defaultSize(width: 620, height: 720)
        .windowResizability(.contentMinSize)
    }
}

/// Opens the settings window and brings the application forward with it — without the
/// second part, a menu-bar-only application puts the window up behind whatever the person
/// was already looking at.
///
private struct SettingsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            openWindow(id: HardwareSentryApp.settingsWindowID)
            NSApplication.shared.activate()
        }
        .keyboardShortcut(",")
    }
}

/// The menu bar's own icon: the application icon, drawn small.
///
/// Not a template image — the artwork is colourful, and flattening it to a monochrome
/// silhouette would make it one more indistinguishable grey glyph among a dozen.
private struct MenuBarIcon: View {
    let delegate: AppDelegate
    /// Lends the delegate the ability to open the settings window, since only a scene can
    /// and the delegate is what hears about a second launch.
    ///
    /// Wired from the menu bar label rather than from the Settings menu item: the label is
    /// built the moment the application launches, whereas the menu's contents are not
    /// built until somebody opens the menu — so wiring it there meant a second launch did
    /// nothing at all unless the menu happened to have been opened first.
    @Environment(\.openWindow) private var openWindow

    /// The menu bar sizes itself to whatever it is handed, so the image has to be resized
    /// rather than merely displayed small: a SwiftUI `.frame` on the view leaves the
    /// underlying `NSImage` at its full 1024pt and the status item grows to match, which
    /// pushes it off the bar entirely.
    private static let image: NSImage? = {
        guard let icon = NSApplication.shared.applicationIconImage else { return nil }
        let side: CGFloat = 18
        let resized = NSImage(size: NSSize(width: side, height: side))
        resized.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        resized.unlockFocus()
        return resized
    }()

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
            } else {
                Image(systemName: "dot.radiowaves.left.and.right")
            }
        }
        .onAppear {
            delegate.openSettingsWindow = { openWindow(id: HardwareSentryApp.settingsWindowID) }
        }
    }
}
