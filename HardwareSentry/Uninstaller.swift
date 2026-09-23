import AppKit
import ServiceManagement

/// Removes this application from the Mac it runs on: login item, preferences, caches,
/// logs, and the `.app` bundle itself — moved to the Trash, not deleted outright.
///
/// The cleanup runs as a detached shell command that starts after this process has quit,
/// not while it is still alive. `cfprefsd` owns the preferences domain for as long as the
/// process holds it open, and rewrites it on exit — deleting the plist in-process leaves
/// an orphaned file behind a moment later. Waiting for the process to actually be gone is
/// what makes the deletion stick.
@MainActor
enum Uninstaller {
    /// Shows the confirmation alert and, if the person agrees, quits the application and
    /// removes it. Does nothing if they cancel.
    static func confirmAndRun() {
        NSApplication.shared.activate()

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Uninstall HardwareSentry?"
        alert.informativeText = "This will quit HardwareSentry, remove it from login items, "
            + "delete all of its settings, and move the app to the Trash.\n\n"
            + "This cannot be undone."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")

        let resetPermissions = NSButton(checkboxWithTitle:
            "Also reset system permissions (Bluetooth, Location, Local Network) — asks for your admin password",
            target: nil, action: nil)
        resetPermissions.state = .on
        // Wide enough for the checkbox's own label not to wrap illegibly inside the
        // alert's default accessory width.
        resetPermissions.frame = NSRect(x: 0, y: 0, width: 400, height: 18)
        alert.accessoryView = resetPermissions

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(alsoResettingPermissions: resetPermissions.state == .on)
    }

    private static func run(alsoResettingPermissions: Bool) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let appPath = Bundle.main.bundlePath
        let home = NSHomeDirectory()

        // Best-effort, and harmless if it was never registered: unregistering after this
        // has already failed silently once, elsewhere in this codebase, is not a reason
        // to leave the person mid-uninstall over a login item.
        try? SMAppService.mainApp.unregister()

        let searchDirectories = [
            "Library/Preferences",
            "Library/Preferences/ByHost",
            "Library/Caches",
            "Library/Saved Application State",
            "Library/HTTPStorages",
            "Library/WebKit",
            "Library/Application Support",
            "Library/LaunchAgents",
            "Library/Logs/DiagnosticReports",
            "Library/Application Support/CrashReporter"
        ]

        var script = "sleep 1\n"
        script += "defaults delete \(bundleID) >/dev/null 2>&1\n"
        for directory in searchDirectories {
            let path = "\(home)/\(directory)"
            script += "find \"\(path)\" -maxdepth 1 -iname '*\(bundleID)*' -exec rm -rf {} + >/dev/null 2>&1\n"
            script += "find \"\(path)\" -maxdepth 1 -iname '*HardwareSentry*' -exec rm -rf {} + >/dev/null 2>&1\n"
        }
        script += "mv \"\(appPath)\" \"\(home)/.Trash/\" >/dev/null 2>&1\n"

        if alsoResettingPermissions {
            // Codenames TCC uses internally for Bluetooth, Location, and Local Network —
            // undocumented, so this may need revisiting on a future macOS.
            let services = ["BluetoothAlways", "BluetoothPeripheral", "Liverpool", "Willow"]
            let resets = services.map { "tccutil reset \($0) \(bundleID)" }.joined(separator: "; ")
            let escaped = resets.replacingOccurrences(of: "\"", with: "\\\"")
            script += "osascript -e 'do shell script \"\(escaped)\" with administrator privileges' >/dev/null 2>&1\n"
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()

        NSApplication.shared.terminate(nil)
    }
}
