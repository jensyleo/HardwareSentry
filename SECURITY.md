# Security Policy

## Supported versions

Only the latest release on the `main` branch is supported. Older tags do not receive
security fixes.

## Scope

HardwareSentry is a local hardware-notification app. It:

- Only **reads** hardware and system state (IOKit, Disk Arbitration, CoreWLAN, CUPS,
  AVFoundation, IOBluetooth, and similar system frameworks) — it does not write to, mount,
  format, or otherwise modify any device, and it never sends anything over the network.
- Draws its own notification banners instead of handing them to macOS, and keeps its own
  history of what was shown, stored locally.
- Requests exactly two runtime permissions — **Bluetooth** (to see Bluetooth devices
  connecting at all) and **Location** (used only to read the *name* of the Wi-Fi network
  being joined; macOS treats an SSID as location data, and the actual location is never
  read) — plus, only if the Scanner module is switched on, the **Local Network** prompt it
  needs to browse Bonjour.
- Requires no elevated privileges. It runs, and is meant to always run, as the logged-in
  user with no admin relaunch of any kind.

Relevant report categories for this project:

- A code path that reads, transmits, or persists more than the hardware facts a module's
  own documented notification fields describe (for example, real location data rather
  than a Wi-Fi network name).
- A crash or memory-safety issue in a C bridge (`CCUPS`, `CNVMeSMART`) or in a system-API
  call reachable from an attacker-influenced input — a malformed or adversarial USB,
  Bluetooth, CUPS, or Bonjour advertisement, for instance.
- A flaw that lets a switched-off module, or a switched-off notification, still leak
  information about a device (this project treats "the switch is off" as a real privacy
  boundary, not just a display preference).
- Any code path that writes to, erases, ejects, or otherwise modifies a disk, printer, or
  other device — this application is read-only by design, so any such path is itself the
  bug.
- Unsanitized input reaching a shell command or a `Process` invocation.

**Out of scope:** the app not appearing in Notification Centre and not being silenced by
Do Not Disturb is by design (see the README), not a vulnerability.

## Reporting a vulnerability

Please report privately using **GitHub's "Report a vulnerability" feature** (Security tab
→ *Report a vulnerability*) on this repository, instead of opening a public issue.
Include:

- The affected version/commit and macOS version/architecture.
- Steps to reproduce, and the expected vs. actual behavior.
- Impact (what information could be read, retained, or exposed beyond what the switch or
  permission in question is meant to allow).

You should get an initial response within a few days. Confirmed issues will be fixed and
credited in the fix's release notes unless you request otherwise.
