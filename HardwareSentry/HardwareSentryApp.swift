import SwiftUI

@main
struct HardwareSentryApp: App {
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

            SettingsLink {
                Text("Settings…")
            }
            .keyboardShortcut(",")

            Divider()

            Button("Quit HardwareSentry") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }

        Settings {
            SettingsView(appearance: delegate.appearance, events: delegate.eventSettings)
        }
    }
}
