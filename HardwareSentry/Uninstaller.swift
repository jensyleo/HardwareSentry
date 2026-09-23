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

        // `appPath` is wherever the running `.app` happens to sit on disk, not a value
        // this process chose — a folder renamed to contain a quote or `$(...)` must not
        // be able to break out of the script below and run as this shell. Every
        // interpolated value is single-quoted, the only quoting style shell metacharacters
        // (backticks, `$`, `;`, double quotes) cannot escape from.
        var script = "sleep 1\n"
        script += "defaults delete \(shellQuoted(bundleID)) >/dev/null 2>&1\n"
        for directory in searchDirectories {
            let path = "\(home)/\(directory)"
            script += "find \(shellQuoted(path)) -maxdepth 1 -iname \(shellQuoted("*\(bundleID)*")) -exec rm -rf {} + >/dev/null 2>&1\n"
            script += "find \(shellQuoted(path)) -maxdepth 1 -iname '*HardwareSentry*' -exec rm -rf {} + >/dev/null 2>&1\n"
        }
        script += "mv \(shellQuoted(appPath)) \(shellQuoted("\(home)/.Trash/")) >/dev/null 2>&1\n"

        if alsoResettingPermissions {
            // Codenames TCC uses internally for Bluetooth, Location, and Local Network —
            // undocumented, so this may need revisiting on a future macOS.
            let services = ["BluetoothAlways", "BluetoothPeripheral", "Liverpool", "Willow"]
            let resets = services
                .map { "tccutil reset \($0) \(shellQuoted(bundleID))" }
                .joined(separator: "; ")
            // AppleScript's own string literal, not the shell's — its escaping rules are
            // backslash-based, unrelated to the single-quoting used above.
            let appleScriptEscaped = resets
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            script += "osascript -e 'do shell script \"\(appleScriptEscaped)\" with administrator privileges' >/dev/null 2>&1\n"
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()

        NSApplication.shared.terminate(nil)
    }

    /// Wraps a value in single quotes for safe interpolation into a `/bin/sh` script,
    /// escaping any single quotes the value itself contains.
    ///
    /// Single quotes are the only shell quoting style nothing inside can break out of:
    /// double quotes still expand `$…`, backticks, and `\`, which a booby-trapped folder
    /// name could exploit.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
