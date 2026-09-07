import AppKit
import SwiftUI

/// Custom "About HardwareSentry" window, replacing macOS's own auto-generated panel.
///
/// The default panel only ever shows the name, version and copyright it can read out of
/// `Info.plist` — nothing that answers "what is this application". Written to match
/// ROMForge's own About, which is where this pattern comes from.
struct AboutView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 96, height: 96)
            Text("HardwareSentry")
                .font(.title2.bold())
            Text("Version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("A menu-bar application that watches the hardware attached to a Mac and says when something changes — a drive plugged in, a display waking, the Wi-Fi network switching, the machine starting to throttle because it is hot. It reports what the hardware says about itself and never changes any of it.\n\nEvery notification is a row you can switch off on its own, and every extra line in a message is too; the Help window's Modules reference lists all of them, built from the modules themselves rather than written by hand.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                // Without this the paragraphs are compressed rather than wrapped, and
                // the last line of the second one is clipped to an ellipsis.
                .fixedSize(horizontal: false, vertical: true)
            Text("Copyright © 2026 Jensy Leonardo Martínez Cruz. Free software under the GNU General Public License v3.0 or later. It comes with ABSOLUTELY NO WARRANTY.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(width: 460)
    }
}
