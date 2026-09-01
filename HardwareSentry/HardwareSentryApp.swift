import SwiftUI

@main
struct HardwareSentryApp: App {
    static let settingsWindowID = "settings"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("HardwareSentry", systemImage: "dot.radiowaves.left.and.right") {
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
        }

        // A plain window rather than the `Settings` scene: that one sizes itself to the
        // content's intrinsic height and refuses to resize, which leaves the appearance
        // tab permanently cut off — and it grows with every setting added. The menu item
        // and ⌘, are wired by hand below, which is the whole of what `Settings` gave us.
        Window("HardwareSentry Settings", id: Self.settingsWindowID) {
            SettingsView(appearance: delegate.appearance, events: delegate.eventSettings, history: delegate.history)
        }
        .defaultSize(width: 620, height: 720)
        .windowResizability(.contentMinSize)
    }
}

/// Opens the settings window and brings the application forward with it — without the
/// second part, a menu-bar-only application puts the window up behind whatever the person
/// was already looking at.
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
