# Changelog

All notable changes to this project are documented here. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/); HardwareSentry has not made a first
tagged release yet, so everything so far lives under **Unreleased**.

## [Unreleased]

### Fixed: a hub's own Billboard chip misread as "Serial/Debug Adapter"

Reported live minutes after the `usb.ids` widening shipped: a VIA Labs "USB 2.0
BILLBOARD" chip — a hub's own internal companion device, always there, nothing plugged
in — showed up at every launch as "USB Serial/Debug Adapter Connected". Device class
`0x11` (Billboard) has a real name but no row of its own, so it looked exactly as
"unclassified" to the vendor-ID guess as a genuinely unclassifiable device — and once
VIA Labs became a "known vendor" via `usb.ids`, it got claimed. Fixed by adding the same
"has a real, named class" check `USBMonitor`'s "ignore identified devices" switch
already uses — a device that names anything real now never falls through to a
vendor-ID guess, no matter how broad that vendor list grows.

### Fixed: an empty card reader read as a plain pendrive

Reported live: a genuine multi-card reader (part of a USB-C dock), with no card in any
slot, showed up as generic "USB Mass Storage Connected" wearing the same flash-drive
icon a real pendrive gets. The heuristic that tells a card reader apart from a pendrive
reads the *disk's own* description — which does not exist at all without a card
actually inserted, since an empty slot publishes no disk for it to read. Fixed by also
checking the reader's own USB product name (available regardless of what is inserted),
which commonly says "Card Reader" outright — narrower than, and additive to, the
existing disk-based heuristic, never replacing it.

### Gamepad Monitor's icon now matches the controller's own brand

Every controller — a Joy-Con, a Switch Pro Controller, an Xbox pad, a generic MFi one —
drew with the same single glyph before, even though the module already knows exactly
which is which (`GCController.productCategory`, the same text the notification's own
"Type" field already shows). Four new icons — Xbox, PlayStation (DualShock 4 and
DualSense both), Joy-Con, Switch Pro Controller — are picked by keyword match against
that text; an unrecognised controller (most third-party MFi ones) and racing wheels
both keep the original plain glyph. Matched by keyword rather than an exact constant on
purpose: a real Joy-Con (R), confirmed live, reports its category as "Nintendo Switch
Joy-Con (R)", not the bare name Apple's own constant suggests.

### USB Monitor recognises serial/debug adapters by vendor, not just by class

An FTDI, Silicon Labs, WCH, SEGGER, ST-Link or other USB-serial/debug-probe chip
declares a USB-IF class byte (`0xFF`/`0xEF`/`0x00`) that says nothing about what the
device actually is — the class byte is USB-IF's own "ask the vendor" escape hatch, used
because no standard class fits. Such a device now gets its own row, icon and event
("Serial/Debug Adapter") when nothing else identifies it and its vendor ID is one of a
built-in list of common serial/debug vendors (FTDI, Silicon Labs, Prolific, WCH,
Microchip, SEGGER, STMicroelectronics, Cypress, TI, NXP, Atmel/Microchip, Digilent, the
OpenMoko/Black Magic Probe pool, Espressif, Renesas, Infineon). A device the class byte
already identifies is never second-guessed by this lookup, even if its vendor also
happens to make serial chips.

The vendor list can also update itself: Settings → USB → "Serial/debug adapter vendors"
has a "check automatically every N days" toggle plus a "Check Now" button, both pulling
a small hand-maintained JSON file from this application's own GitHub repository and
merging it into the built-in list — additive only, so a failed or empty check never
loses what was already known.

### USB Monitor tells a gamepad/joystick apart from a keyboard/mouse

Both are the same USB-IF HID class (`0x03`) — the class byte cannot tell a joystick
from a keyboard, only the HID Report Descriptor's own Usage Page/Usage can. Reported
live: a real generic USB gamepad showed up as "Keyboard/Mouse Connected." Fixed by
reading the Usage Page/Usage macOS's own HID family already works out (Generic Desktop,
usage Joystick/Gamepad/Multi-axis Controller) and giving it its own "Gamepad/Joystick"
row — keyboard and mouse stay merged under the original's own combined row, unchanged.

Gamepad Monitor's own notice for the same physical device — richer, from Apple's
GameController framework — always fired alongside USB Monitor's, undetected as a
duplicate before this, since there was nowhere for USB Monitor to say "Gamepad" more
specifically than "Keyboard/Mouse." Settings → Gamepad now has the same "Notify for USB
devices independently of USB Monitor" switch Camera/Audio already have, to fold the
plainer USB Monitor duplicate away in favor of Gamepad Monitor's own. On by default,
matching the original pair's own defaults.

**Found immediately after shipping the above, same live device:** connect read as
"Keyboard/Mouse," disconnect correctly as "Gamepad/Joystick" — the same teardown/
enumeration race `KNOWN-ISSUES.md` already has entries for, on a fourth registry
subtree (the `IOHIDDevice` object a HID interface's Usage Page/Usage lives on, not
published yet at the instant a device first arrives). Fixed the same way: a short
identity-based retry (`enrichedHIDUsage`, 15 tries/40ms — no physical device to wait on
here, so far shorter than the disk-description retry), chained onto both arrival paths
a HID device can take.

### USB Monitor tells a Bluetooth dongle apart from a plain wireless controller — and, as a best-effort guess, a WiFi one

Both used to read as the same generic "Wireless Controller" row (`0xE0`). Bluetooth is
now told apart reliably, by USB-IF's own subclass/protocol signature for it (confirmed
live against two real dongles, a Broadcom and a CSR8510, both connected at once) — not a
guess. WiFi has no USB-IF class of its own to read, so it is a vendor-ID guess instead
(Realtek, MediaTek, Ralink, Atheros, Broadcom, TP-Link), with the false-positive risk
that implies for a vendor that also sells things that are not WiFi. Settings → USB →
"Wireless dongles" has a separate on/off switch for each, reflecting that difference in
confidence; both on by default, falling back to the exact previous behaviour when off.

Found and fixed in the same change: the WiFi vendor check has to run *before* the
serial-vendor one, not after — once the serial-vendor list has been widened by a
`usb.ids` update, it recognises essentially any real vendor, WiFi ones included, so
checking it first would have silently swallowed every WiFi Adapter match into a Serial/
Debug Adapter one instead. Caught by a test using a real, live-observed vendor ID
(Realtek) against this machine's own already-updated vendor list, not assumed.

### "Check Now" says what it actually did

Pressing it gave no feedback beyond a silently-updated "Last checked" timestamp — a
successful check that found nothing new looked identical to one that failed outright.
Now shows one of three outcomes right under the button: "Updated — N vendors added or
renamed," "Already up to date — nothing new," or "Check failed — no connection, or the
URL did not respond." The scheduled background check stays silent either way, on
purpose — this is feedback for a button somebody just pressed, not a notification.

### The serial-vendor list now updates from usb.ids, not a repo this app alone maintains

The vendor-ID lookup behind "Serial/Debug Adapter" pulled its update from a JSON file in
this application's own GitHub repository — a file nobody but this project would ever
keep current. Switched to `usb.ids`, the Linux USB ID Repository's own vendor list,
community-maintained for decades and mirrored by Gentoo's `hwids` repo; the default
Update URL and the parser both changed to match. This is deliberately broader than
before: `usb.ids` names every USB vendor USB-IF has ever assigned an ID to, not only the
ones that make serial/debug chips, so once updated, any device whose class byte says
nothing but whose vendor `usb.ids` recognises can read as "Serial/Debug Adapter" too —
accepted as the tradeoff for a source somebody else actually keeps up to date.

### The serial-vendor update URL is now visible and editable

Settings → USB → "Serial/debug adapter vendors" showed only a "Check Now" button, with
no way to see or change where it actually pulled from. Added an "Update URL" field —
this application's own GitHub repository by default, exactly what it already used —
plus a "Restore Default" button next to it. Anyone can see exactly what host their Mac
would reach out to, and point it elsewhere (or back) without editing preferences by
hand.

### Wi-Fi signal polling and Mass Storage detection can now be switched off entirely

Both were only sliders — how often, never whether. Settings → Network → Wi-Fi and
Settings → USB now each have a checkbox above their sliders: off stops the periodic
work outright (no timer at all for Wi-Fi's signal/promiscuous-interface/bond-member
check; no background retry task spawned for an ambiguous disk, which is instead
announced immediately, as generically classified as it would have been before this
feature existed). On by default, matching every prior behaviour. For a Mac where the
periodic wake-up itself, not just its frequency, is not worth its cost.

### USB Mass Storage detection timing is now tunable, not fixed

The 250ms poll interval and 8-second backstop USB Monitor uses while waiting for an
external disk's own description (see `KNOWN-ISSUES.md`'s multi-round External Disk saga)
were fixed numbers. Settings → USB → "Mass Storage detection" now exposes both as
sliders — poll interval (100–2000ms) and give-up deadline (2–20s) — the same two-slider
shape Wi-Fi's own signal-check-interval/cooldown pair already has. Defaults are
unchanged, so nothing behaves any differently until these are actually moved; this exists
for tuning against a particular Mac's own disks rather than as a fix on its own. Takes
effect the next time the application starts.

### Every polling loop is now a setting, not a hardcoded number

An audit of every place this application checks state on a timer rather than reacting to
a native push notification (there is no OS callback for these — the whole reason each one
polls at all) found six background loops with no user-facing control: Bluetooth's
paired-device list (15s), its signal/RSSI read (10s), its BLE-accessory read (30s),
Printer's CUPS destination/job read (8s), Volume's free-space read (300s), and Network's
Wi-Fi-radio-power backstop (30s). Each now has a slider on its own module's Notifications
tab, the same shape the existing Scanner/Display/Network-signal controls already had.
Nothing changed by default — the numbers people already had keep working exactly as they
did; what changed is that they can now be changed. See `TODO.md` for the one remaining
polling loop in the app that could not simply grow a setting: USB Monitor's Mass Storage
hint retry, which is a bounded per-connect-event wait rather than a persistent
background timer, tracked separately.

### Fixed, reported live

- **"All elements" now actually means all.** It only put each module back to its own
  declared default, leaving individual notification/field checkboxes wherever they had
  last been set. Now switches on every module, every one of its notifications, and every
  optional field, without exception.
- **Switching one notification or field by hand now falls into "Custom".** Only switching
  a whole module used to do this; the preset picker kept claiming "All elements" (or
  Minimal/Recommended) even after a single checkbox inside it no longer matched.
- **A Mass Storage device's kind is no longer read too early.** Reported live right after
  the previous fix: the same external HDD showed generic "Mass Storage" on connect but
  correctly "External Disk" on disconnect. Same class of timing bug as the BRIO fix
  (2026-09-03), for a different layer: the disk's BSD name/description is still attaching
  underneath the USB device at the instant of arrival. Now retried on the same registry
  entry (up to 1 second) before falling back to generic — see `KNOWN-ISSUES.md`.
- **USB Monitor now tells an external disk enclosure apart from a pendrive too, not just
  an SD card.** Confirmed live, 2026-09-05, against a real pendrive and a real 1 TB
  external HDD connected at once, both showing as plain "Mass Storage": the drive's Disk
  Arbitration media name was a bare Seagate model number ("D ST1000LM02") with no
  "hdd"/"external" word to match, but its 1 TB size clears the same enclosure-sized
  threshold `VolumeKind` already uses — so `USBMassStorageHint` gained an `.externalDisk`
  case and that same size fallback. The pendrive, by contrast, is genuinely
  unidentifiable: its controller chip carries no product string at all and an
  unregistered placeholder vendor ID (`0xABCD`) — confirmed by reading its own USB
  descriptor directly — so it stays generic "Mass Storage", the same honest answer
  `VolumeKind` gives an identically bare device.
- **Opportunistic MicroSD wording, for a reader that names its slots.** Confirmed on this
  session's own reader: the USB device is shared by every slot, and both this reader's
  slots (checked via their SCSI `IOSCSILogicalUnitNub`) report the identical generic
  string — so nothing distinguishes SD from microSD on this specific hardware, and
  nothing in software can make it. For a reader that *does* name its slots differently,
  the "Card reader type" line now reads "MicroSD card" instead of "SD/CF card" when the
  combined name says "micro", "TF card", or "TransFlash" anywhere; `VolumeKind.infer`
  itself also now recognises a bare "microSD" or "TransFlash" name (microSDXC/microSDHC
  already matched the plain "sdxc"/"sdhc" tokens). See `KNOWN-ISSUES.md` for what this
  can and cannot promise.
- **A USB microSD reader in a hub now has a chance to be recognised as an SD card,
  not just a plain external disk.** Disk Arbitration reported this reader's `MediaName`
  as the literal, generic `"MassStorageClass"` — nothing SD-shaped for the existing
  heuristic to match — while the same disk's owning USB device, one registry level (nine
  hops) up, still answers `"USB Product Name" = "USB3.0 Card Reader"`. Volume Monitor's
  media-name guess now falls back to that USB product string when Disk Arbitration's own
  says nothing. See `KNOWN-ISSUES.md` for what is and is not confirmed end-to-end.
- **Gamepad Monitor no longer has a keyboard/mouse row.** Turning it on was reported to
  announce an entirely ordinary keyboard and mouse — nothing gaming-specific — because
  macOS's GameController framework cannot tell "a dedicated gaming peripheral opted into
  game input" apart from "any keyboard/mouse the system already has". HG4MAC's own switch
  for this rests on the opposite, incorrect assumption. Removed rather than kept and
  mislabelled; recorded in `PARITY.md`/`Tools/parity-map.tsv` as a deliberate,
  zero-replacement omission, not a gap.

### Security and robustness

A full adversarial pass over `HardwareSentryCore` and the app target (memory/resource
safety in the two C bridges, force-unwraps, concurrency correctness, injection risk,
performance) turned up five real issues, all fixed:

- **USB Monitor**, `IOKitUSBDeviceSource.swift` — a remote/malformed Bluetooth SDP record
  is not the source here, but three USB-side issues were: the composite-device interface
  cache (`resolvedInterfaceClasses`) had no eviction, so a device whose departure event is
  missed (sleep-through-unplug, a hub re-enumerating without one) leaked an entry for the
  rest of the process's life — now bounded and LRU-evicted at 256 entries. The detached
  task that polls IOKit for an ambiguous device's interfaces was untracked and
  uncancellable — now tracked and cancelled in `stop()`, so nothing keeps polling for up
  to 400ms after the watcher is torn down. Vendor/product/location IDs read from the
  registry were silently truncated to fit their field width on an out-of-range value —
  now read as nil instead, since a wrong ID could fold two different physical devices
  under the same cache key.
- **Bluetooth Monitor**, `BluetoothDetail+IOBluetooth.swift` — `serviceClassUUID(of:)`
  trusted a remote peer's SDP record to hand back exactly 2 bytes before reading them;
  a malformed record from a nearby device could have under-run that read. Now checked
  before reading.
- **Volume Monitor**, `NSWorkspaceVolumeSource.swift` — `f_fstypename`/`f_mntonname`
  were decoded with `String(cString:)` against a fixed-size kernel buffer with no bound
  of its own, unlike the safer pattern already used elsewhere in USB Monitor for a
  registry entry's name. Not reachable in practice — the kernel always null-terminates
  these — but brought in line with the safer pattern for free.

Checked and found solid in the same pass, worth recording so it is not re-investigated:
`CNVMeSMART.c`'s `IOObjectRelease` pairing and `sizeof`-driven buffer copy; the CUPS
bridge (a plain `libcups` header shim — all real calls are in Swift, going through
`String(cString:)` with no fixed buffers, and `PrinterSupply.parse`'s explicit
bounds-checked indexing across CUPS's parallel comma-lists); `ThunderboltMonitor`,
`NetworkMonitor`'s Wi-Fi code, and `SignalCore`'s notification dispatcher/banner-drawing
code (no `Process`/shell invocation anywhere in the project; no `as!`/`try!` anywhere).

### Core

- `SentryContract`: the shared vocabulary every monitor is built from — declarative
  events, optional body fields, icons, and the dispatcher that turns a raised event into
  a drawn banner.
- Notifications are drawn by the application itself, not handed to macOS: full control
  over the corner, size, how long a banner stays, and what it is drawn on, at the cost of
  not appearing in Notification Centre and not being silenced by Do Not Disturb.
- A settings window covering every module: which notifications are on, which optional
  body-field lines each one includes, per-event icon overrides (asset, SF Symbol, or
  system default), and a General tab for the menu-bar icon, login item, and profiles.
- A notification history: an enable switch, day-based retention, per-module opt-in, and a
  three-column table of what was shown and when.
- A generic "Simulate a Notification" picker on every module's tab, firing a real event
  through the real dispatcher pipeline (icon overrides, on/off switch, all of it) so a
  banner can be checked without the hardware in hand. Thermal keeps its own
  transition-shaped simulator instead, because its events are a *from → to* state change
  a plain picker cannot honestly stand in for.
- A visual SF Symbol browser for picking an icon override.
- `Tools/parity-audit.sh` / `sentry-inventory`: mechanically compares every notification
  HG4MAC (the Objective-C original) can raise against what this rewrite can raise, and
  fails the build on any gap. See `PARITY.md`.
- A resizable, properly sized settings window; a Help window (`Help ▸ HardwareSentry
  Help`) generated from the modules themselves, so it always describes the build in front
  of the reader; closable with Escape or a footer Done button, and wired to the system
  Help menu.
- App Nap disabled, so a monitor's polling loop is not throttled while the window is
  hidden.

### Thirteen monitors, ported one at a time

- **Thermal** — per-level state notifications and a dark-wake thermal emergency signal.
- **Gamepad** — controllers, keyboards, mice, and racing wheels.
- **Thunderbolt** — generic connect/disconnect, plus an additive eGPU-pair signal.
- **Scanner** — devices found/lost via Bonjour, off by default (it triggers the Local
  Network permission prompt), with its Bonjour TXT record read for extra detail.
- **Camera** — connect/disconnect, a debounced in-use signal, and video-effects state; a
  built-in camera is named "Camera", a USB one "Webcam"; a switch for virtual/aggregate
  devices, off by default.
- **Display** — connect/disconnect, mode/role/sleep changes, colour profile.
- **Printer** — the project's first real C bridge (`CCUPS`, wrapping `libcups`).
- **Bluetooth** — presence, radio state, subsystem state, pairing, per-device-kind rows,
  signal levels, BLE accessories, and the haptics split the original has.
- **Audio** — default device changes, connect/disconnect over an uncovered transport,
  mic-in-use, MIDI; a switch for virtual/aggregate devices, off by default; requests
  microphone access before arming the mic-in-use listener.
- **Volume** — mount/unmount, unsafe eject, low disk space, three rows per kind of drive
  (external disk, USB drive, SD card, optical, NAS), an Ignored Drives editor using
  HG4MAC's own picker, and a second C bridge (`CNVMeSMART`).
- **Power** — power source changes, fully-charged, low battery, sleep/wake, Low Power
  Mode, and an hourly battery-health reminder.
- **Network** — reachability, Wi-Fi join/leave and signal (one row per bar), wired link
  changes and speed, VPN tunnels, DHCP lease and hostname changes, the machine's own IP
  addresses reported at launch, and a network adapter's arrival announced as well as its
  departure.
- **USB** — one row per device class (Hub, Mass Storage, HID, Webcam, Scanner, Printer,
  Smart Card, Audio, Healthcare, Audio/Video, Type-C Bridge, Wireless, and Network
  Adapter for the Communications class); a composite device (one that declares nothing at
  the device level, only on its interfaces — the Logitech BRIO among them) is read from
  its interfaces instead, with a genuinely hybrid webcam+microphone read as Audio/Video; a
  switch to silence a device that is identified but has no row of its own (an internal hub
  chip enumerating as Billboard, say) without also silencing a genuinely unidentified
  device; a Mass Storage device is further told apart, heuristically, into a USB Drive or
  an SD Card Reader — see `KNOWN-ISSUES.md` for the honest limits of that heuristic;
  storage-medium and port-info registry walks are skipped for hubs, which measurably cut
  the time a hub's own arrival took to report.

### Notable fixes along the way

- A real crash calling `perform(_:)` on a selector that returns a small integer rather
  than an object.
- USB arrivals were waiting on the wrong IOKit notification, which is also why a
  composite device (the BRIO) was classified generically on connect but correctly on
  disconnect — see `KNOWN-ISSUES.md` for the full account.
- Internal volumes were announcing as "External Disk".
- One Wi-Fi join was being announced twice; the SSID was being used, wrongly, to decide
  whether a network existed at all.
- A missing Bluetooth usage-description string that made the permission prompt fail
  silently.
- Camera and Audio's own "independent of USB Monitor" notices were being silenced by a
  fixed behaviour rather than the checkbox meant to control them.

### Documentation

- `README.md`, `LICENSE` (GPL-3.0), `THIRD-PARTY-NOTICES.md` (the BSD 3-Clause notice for
  HardwareGrowler / The Growl Project, whose notification wording and set of hardware
  facts this rewrite's design derives from), `PARITY.md` (what the parity audit covers
  and what it structurally cannot), `KNOWN-ISSUES.md` (small, understood defects and open
  design questions, kept out of the code they affect so they are not rediscovered from
  scratch), and this changelog.

[Unreleased]: https://github.com/jensyleo/HardwareSentry/commits/main
