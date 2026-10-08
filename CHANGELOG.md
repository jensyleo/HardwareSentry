# Changelog

All notable changes to this project are documented here. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/) and the project uses
[semantic versioning](https://semver.org/). Everything before 0.2.0 is grouped under 0.1.0,
the first tagged release.

## [0.2.0] - 2026-10-08

### A network share names its protocol, not macOS's internal filesystem name

Volume Monitor already told a NAS/file-server mount apart from local storage (by its
filesystem — `smbfs`, `afpfs`, `nfs`, `webdav`, `ftp` — and Disk Arbitration's own
`VolumeNetwork` flag), but the notification's "File system" line showed that same raw
name, which nobody but macOS itself would recognise. It now reads SMB, AFP, NFS, WebDAV or
FTP instead; every other filesystem (APFS, ExFAT…) is still shown exactly as macOS names
it, unchanged.

## [0.1.0] - 2026-10-08

### Dead-code sweep

A full audit (SignalCore included) found three genuinely unused members and removed them:
`NotificationDispatcher.setPipeline`/`setDelivery` (every dispatcher gets its pipeline and
delivery channel at construction; nothing ever swapped them afterward), the standalone
`NotificationIconView` SwiftUI view (superseded by the `NotificationIcon.image(side:)`
extension in the same file, which every actual call site already used), and
`UnreadableDiskTracker.hasReported(wholeDiskName:)` (an accessor with no caller). Everything
else audited — public API surface, delegate callbacks, `SystemDelivery`'s intentionally
unused-in-repo package API — was confirmed live or deliberate.

### The third-party notice overstated what was actually reused from HardwareGrowler

`THIRD-PARTY-NOTICES.md` claimed the per-module icons and two camera workarounds were
Growl's. Neither claim survived a provenance audit against the original HardwareGrowler-NC
import inside HG4MAC's own history: the icons are independently drawn artwork that only
kept Growl's old filenames, and Camera Monitor — the two workarounds' whole subject — never
existed in the original at all. Removed the file; the README's Attribution section is now
Inspiration, and says plainly that this is a clean-room rewrite sharing no source, artwork,
or text with HardwareGrowler.

A follow-up, exhaustive pass — every module's notification strings diffed line by line
against the original, not just a sample — found two more sentences carried over unchanged
beyond the low-battery body line already caught: Network Monitor's Wi-Fi disconnect body
("Left network %@.") and Power Monitor's charge-time note ("Time to charge/remaining: %ld
minutes"). All three are reworded now.

### USB remotes and graphics tablets are named instead of filed under Keyboard/Mouse

HID is one USB class for a keyboard, a mouse, a gamepad, a media remote and a graphics
tablet alike; only the HID Report Descriptor's own usage page tells them apart, which is
how gamepads were split out already. Two more usage pages get the same treatment: a
device leading with Consumer (`0x0C`) / Consumer Control — a media remote, a volume
knob, a presentation clicker — is now "Remote Control", and one leading with Digitizers
(`0x0D`) / Digitizer or Pen is "Graphics Tablet". Each has its own notification row.

Both read `PrimaryUsagePage`, which is what a device *leads* with, so an ordinary
keyboard is unaffected even though nearly all of them also carry a Consumer Control
collection for their media keys. Touch screens and touch pads (`0x0D` usages `0x04` and
`0x05`) are deliberately left where they are: those really are pointing devices.

Neither has artwork of its own yet — both borrow the HID glyph, as the gamepad row
already does.

### The volumes macOS mounts for itself are passed over

Measured over the upgrade to macOS 27: Volume Monitor raised **188 notifications**, about
60% of everything this application said in the period, and not one of them was a disk
anybody plugged in. Forty read "Volume Ejected Unsafely" — alarming wording for something
nobody did and nobody can act on.

They come from macOS's own machinery: the staging volume a software update runs from
(`/System/Volumes/Update/mnt1`), its target and temporary mounts (`msu-target-*`,
`tmp-mount-*`), the signed disk images system extensions are delivered in, and the hidden
APFS volumes every Mac has — Preboot, VM, xarts, iSCPreboot, Hardware.

These could not be listed in the existing "ignored drives" editor instead, which is the
reason this is built in rather than left to whoever is annoyed by it: each of those mounts
is named afresh with a random suffix — `tmp-mount-HUnUd0`, `tmp-mount-0pLNqq`,
`tmp-mount-1Ih9QL` — so there is no name anybody could write down. Only the prefixes hold
still.

Volume ▸ "Ignore the volumes macOS mounts for itself", **on by default**. That makes it the
one place in this application where a default silences something, which is why the setting
states the evidence rather than merely asserting it is noise.

The built-in set is kept separate from the patterns somebody writes: a list they wrote
stays theirs, and a built-in list merely copied into it once could never be corrected for
anyone who had already run the application. It matches by *path* wherever a path will do —
`/System/Volumes/` and the cryptex directory belong to the system, whereas a volume
*named* "Update" or "Hardware" could plausibly be somebody's own disk. `/Volumes/`, where a
person's disks actually mount, is deliberately absent, and the test that matters most is
the one proving a real disk is never caught.

One question this raised answered itself: the exclusion is applied before an event is ever
raised, so an excluded volume never reaches the dispatcher and cannot contribute to a
flap report either.

### Fixed: tests that began failing at random under Xcode 27 / Swift 6.4

Nothing in the application itself broke on the new toolchain — it builds without a single
warning, and every one of these failures reproduced with the day's own work stashed. The
tests were the problem, and had been fragile all along.

Each one waited for a monitor's scripted source by spinning a *fixed number of turns* —
`for _ in 0..<100 where events.count < expecting { await Task.yield() }`. How many turns
that actually takes depends on how the runtime schedules and how busy the machine is, so
the number was a guess that happened to hold. Swift 6.4 schedules differently and between
16 and 24 tests began failing, a different set on every run.

Raising the count was tried and rejected: at 100,000 the suite still passed but took 200
seconds, and at 5,000 it was fast again but still flaked once in four runs. There is no
count that is both correct and quick, because the quantity being guessed is not a count.

All 35 of them wait on the clock now, through one small `waitUntil` helper: it returns the
moment the condition holds, and gives up after two seconds. Sleeping rather than spinning
also lets the monitor's own task run instead of competing with it for the same thread. Six
consecutive runs, no failures, about six seconds — against half a second before, most of
the difference being the cases that *must* wait to prove nothing arrives.

Twenty-nine more waits were converted in the same pass, in nine files the day's failures
never touched. Those spin a fixed number of turns with no condition at all, used where the
test cannot name a number to wait up to: a change that gets suppressed produces fewer
events than changes. They are the same guess in the same shape — one of them, in
`PowerMonitorTests`, used the very count of 100 that had just been failing elsewhere — so
they were converted before they could fail too rather than after.

### Fixed: a network share was recognised by a field that is empty for network shares

NAS detection read Disk Arbitration's `DADeviceProtocol` and looked for "SMB", "AFP" or
"NFS" in it. That field names the *bus* a disk sits on — "USB", "SATA", "Apple Fabric",
"Secure Digital" — and a share has no bus, so it is `nil`. Read live 2026-09-18 from the
one network volume mounted at the time, against every local volume on the same Mac:

    /System/Volumes/Data/home    DeviceProtocol: nil            VolumeKind: autofs
    /  and every APFS sibling    DeviceProtocol: Apple Fabric   VolumeKind: apfs

A share is recognised by its filesystem now — `smbfs`, `afpfs`, `nfs`, `webdav`, `ftp` —
and by Disk Arbitration stating outright that the volume is on the network, which is the
answer that does not depend on knowing every protocol in advance. WebDAV and FTP are
named for the first time; both are as much somewhere-else-on-the-network as the three
that were listed before, which is the whole of what the row claims.

The protocol check is kept rather than replaced: it costs nothing, and if some mount does
report a protocol there it still answers.

`autofs` is deliberately excluded even though it reports itself as being on the network.
It is the automounter's own placeholder — `/System/Volumes/Data/home` is one on every Mac,
with no share behind it — and announcing it would be announcing the operating system's own
plumbing rather than anything somebody connected to.

### A banner's close control moves to the top-left

Where macOS itself puts it. Notification Center's close button sits over the top-left
corner of the notification's icon and appears once the pointer is on it; this one was in
the top-right, which is the one corner macOS never uses for it.

### Fixed: Bluetooth notices that sometimes never arrived, or arrived far too late

Reported live while testing a Joy-Con. The cause was in `SignalCore`'s flap detection,
which collapses a storm of notifications about one unstable device into a single report
and then drops further notices about it for a cooldown. It counted occurrences by the
device's *name* alone — and two modules can speak for one physical device. Bluetooth
Monitor and Gamepad Monitor both name that controller "Joy-Con (R)", so their two
notices shared one counter: each connect contributed two, and two connect/disconnect
cycles reached a threshold meant for four. Everything about the device was then dropped
for the next twenty seconds.

Two modules agreeing about one device is not that device flapping. The counter is keyed
on the module as well as the name now — which is how the duplicate-suppression stage
beside it has always keyed; this was the odd one out. The instability report still names
the device rather than the internal key.

The banner queue was examined at the same time and left alone: it allows twelve on screen
at once, reveals them 0.4s apart, and holds up to sixty-four while the application is
still announcing what was already plugged in, against sixteen once it has settled. The
startup burst has the larger limit for exactly that reason, and behaves.

### Fixed: every Bluetooth departure was titled generically

Reported live with a Joy-Con: it arrived as "Bluetooth Gamepad Connected" and left as
plain "Bluetooth Disconnected", while the icon beside that message correctly showed a
gamepad. The kind was taken *out* of the remembered-kinds dictionary a line earlier, and
the title then looked it up in that dictionary again — so it found nothing, every time,
for every kind. The icon read the value that had been taken out, which is why only the
title was wrong and the mismatch was visible in one message.

### Optionally, every message can name the module that raised it

Off by default, because the artwork usually says it already. Asked for after a case
where it did not: a controller connecting raises one notification from Gamepad Monitor
and another from Bluetooth Monitor, both titled about a controller, both wearing a
picture of one — and nothing on either saying which module it came from. That is not
idle curiosity: the switch that silences one of them lives under whichever module it was.

General ▸ "Say which module raised it" adds a last line — "Module: Bluetooth" — to every
message from every module. It is added once, centrally, where every module's body is
already assembled, rather than as a field each module has to declare: it is not something
the device said about itself, it is this application saying which of its own modules is
speaking, so it belongs to no module's field list and is switched once, globally.

### An About panel that says what the application is, and a help topic on double notices

The Help window and its ⌘? menu entry already existed. What did not was an About panel
of its own: macOS's auto-generated one shows the name, version and copyright it can read
out of `Info.plist` and nothing else. This one adds what the application actually is,
alongside the new icon.

Building it turned up something the panel was the first thing to display: the bundle had
`CFBundleShortVersionString` hardcoded to **1.0**, while the project, the README and the
CHANGELOG all say 0.1.0, pre-release. The plist reads the project's own
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` now, so there is one source of truth
and it cannot drift again.

The Help window also gains a topic it was missing: **"Why one device said several
things"**. It has always explained why a notification did not arrive; the opposite
question — why one connection produced three — had no answer anywhere, and the rules
behind it are not guessable. It lists every switch that decides which module stays
quiet, why the USB and Bluetooth sides start from opposite defaults, and which cases are
not duplicates at all (a dock and what is plugged into it; a disk attaching and its
volume mounting).

### Bluetooth's overlap with Audio and Gamepad Monitor is yours to decide

When two modules can see the same physical device, one of them says nothing. For USB
that has always been a choice — three switches decide whether USB Monitor's redundant
notice folds away. For Bluetooth it was not a choice at all: the rules were written into
the code, and they run in the *opposite* direction. A USB webcam is announced by Camera
Monitor while USB Monitor folds; a Bluetooth headset is announced by Bluetooth Monitor
while Audio Monitor folds. Two policies for one problem, only one of them yours.

The direction is kept — a pairing is news in its own right, which is why the Bluetooth
notice is the one worth keeping — but it is a setting now rather than a rule:

- **Audio ▸ "Notify for Bluetooth devices as well as Bluetooth Monitor"**, off by
  default exactly as before. On, an accessory is announced here too, for the part
  Bluetooth Monitor cannot say: sample rate, channel count, which device just became the
  default.
- **Bluetooth ▸ "Announce controllers Gamepad Monitor also reports"**, on by default
  exactly as before. This pair had no rule at all and simply announced twice — which the
  new Bluetooth gamepad row made obvious rather than caused. Off keeps only Gamepad
  Monitor's richer notice; the setting says plainly what that costs, since
  `GameController.framework` recognises only its own list of controllers and one it does
  not know would then be announced by nothing.

Switching the controller row off folds the departure away too, not just the arrival: a
disconnect for something never announced as arriving is a notification about nothing.

Thunderbolt was examined for the same treatment and deliberately left alone. Its
overlaps are not the same shape: Thunderbolt Monitor announces a dock or a storage
controller on the bus, while Volume or Audio Monitor announce the volume that mounted or
the device behind it — different layers of one connection, each saying something the
other cannot, rather than one device announced twice. There was also no Thunderbolt
hardware to verify any of it against. If a true duplicate turns up, this is the pattern
to follow.

### The application has an icon of its own

Until now the bundle carried HG4MAC's icon as a placeholder — the last inherited asset
in it. The icon it ships with now is its own: a radar sweep ringed by the devices this
application watches for.

The artwork comes full-bleed on a near-black ground, which is not the shape a macOS icon
is: shipped as it came, it would sit in the Dock as a square, noticeably larger than
every icon beside it. So the plate is cropped out of it, masked to the superellipse
macOS actually uses — a squircle, not a plain rounded rectangle — and centred at 824 in
a 1024 canvas, the proportions macOS draws app icons at. That is what makes it line up
with its neighbours instead of towering over them.

`Tools/make-app-icon.py` does all of that from `Icons/AppIcon-source.png`, so the icon
can be rebuilt from the artwork rather than being a binary nobody can regenerate. It is
run by hand, not by the build.

### Fixed: an audio device announcing itself as "Unknown Manufacturer"

The same defect as the camera one below, in the other module the same device reaches.
CoreAudio's placeholder is the phrase "Unknown Manufacturer" where AVFoundation's is just
"Unknown", and only emptiness was checked, so a Logitech BRIO's audio side read
`Model: Unknown Manufacturer · Logitech BRIO:046D:085E`. The maker is refused now and the
line says the model alone.

Both modules refuse the same set of phrases — "unknown", "unknown manufacturer", "unknown
model", "unknown device" — matched whole rather than as a prefix, so a real company called
"Unknown Devices Ltd" still comes through. The set is repeated in each module rather than
shared, because a monitor may depend only on `SentryContract`.

Checked at the same time and deliberately left alone: Bluetooth's maker comes from the
GATT Device Information characteristic, a string the accessory writes about itself rather
than a placeholder the system substitutes, so it is not the same defect.

### Fixed: a camera announcing itself as "Manufacturer: Unknown"

Read live from a real Logitech BRIO: `AVCaptureDevice.manufacturer` answers the literal
word "Unknown" for it, not an empty string — and only emptiness was being checked, so the
placeholder went straight into the message. That is the same "not really an answer" shape
USB Monitor already refuses from USB-IF's own escape hatches, and it is worse than saying
nothing at all, since the maker is right there in the camera's own name.

### Cameras report the VID:PID they were hiding in their model string

AVFoundation exposes no vendor or product property, which is why the maker went missing
above. But a UVC camera's `modelID` carries both — the BRIO's reads "UVC Camera
VendorID_1133 ProductID_2142" — so they are parsed out and reported as `046D:085E`, the
way every specification sheet and USB Monitor's own line writes them. Off by default,
like the rest of the specification lines; nil for a built-in camera, whose model string
carries no identifiers at all.

This closes the audit item that asked for a USB vendor cross-reference here. It turned
out not to need one: the identifiers themselves are available without leaving this
module, and the vendor's *name* was never the missing piece — "Logitech BRIO" already
says it.

### The USB gamepad, remote and tablet rows get pictures of their own

Splitting the Keyboard row out gave `.keyboard` the ported HID artwork — which is,
literally, a picture of a keyboard. Everything else that had been borrowing that same
glyph while it had none of its own was then being announced with a picture of a
keyboard: a gamepad, a remote control and a graphics tablet all were. Borrowing it was
honest while `.hid` meant "keyboard or mouse"; it stopped being honest the moment the
keyboard had its own row.

All three have their own artwork now, drawn to match the ported set — the same USB
trident, the same orange body, black outline and white details, and a red cross over the
device alone for the disconnected variant.

Two shared glyphs are deliberately left shared, because neither one lies: Bluetooth and
WiFi adapters both use the wireless picture, and both really are wireless adapters; plain
Mass Storage and USB Drive both use the drive picture.

### The USB manufacturer line is labelled for what it actually holds

That line has always carried the maker *and* the product name joined together — Settings
has called the row "Manufacturer / product name" all along — but the message itself
labelled it just "Manufacturer". Reported live: a keyboard that names its own
manufacturer "USB" read as "Manufacturer: USB usb keyboard", which looks like a bug here
rather than the two true strings it is. The message now says "Manufacturer/Product" and
agrees with its own setting.

Camera Monitor's "Manufacturer" line is left alone: that one really is only the
manufacturer.

### A USB keyboard and a USB mouse are told apart

Reported live, with both plugged in at once: a keyboard and a mouse produced two
identical "USB Keyboard/Mouse Connected" notifications, each saying "HID
(Keyboard/Mouse)", with nothing in either to say which was which. The class byte cannot
tell them apart — HID is one class for both — but the usage each leads with can, and
always could. Generic Desktop usage Keyboard (`0x06`) and Mouse (`0x02`) now resolve to
a Keyboard row and a Mouse row, each with its own notification setting.

The keyboard row wears the ported HID artwork, which already is a picture of a keyboard;
the mouse row has one drawn to match it. The combined `.hid` row stays for a HID that
leads with neither — a combo receiver, or a usage nothing here recognises.

### Fixed: a keyboard could have been announced as a remote control

Found while implementing the split above, against the same hardware. Nearly every
keyboard publishes *two* HID interfaces: Generic Desktop/Keyboard, and Consumer Control
for its media keys. The usage read for classification was whichever the registry handed
over first, so which of the two won depended on enumeration order — and the Consumer
Control reading is what the previous release began resolving to "Remote Control". The
keyboard tested here happens to enumerate its keyboard interface first, which is the
only reason it was ever announced correctly.

Every usage in the device's subtree is collected now, and the most telling one is
chosen: Generic Desktop, where a device declares what it actually is, outranks
Digitizers, which outranks Consumer Control — almost always a secondary collection
bolted onto something else. Usages nothing here recognises rank equal and so keep their
original position, leaving such a device to behave exactly as it did before.

### Audio: Continuity and AVB are named instead of "Other"

Two transports CoreAudio reports that nothing here had a case for, so both were labelled
"Other": Continuity Capture — an iPhone standing in as a microphone, which is common
enough now to deserve its own name — and AVB, audio over Ethernet, which pro interfaces
use. Both are spelled the way Camera Monitor already spells Continuity. Neither is
wireless in the sense that hands a device over to Bluetooth Monitor, and neither is
software, so neither is swept up by the switches that silence those.

### Bluetooth imaging devices and toy controllers are named

Two more Class of Device major classes get read. Imaging (`0x06`) is the one major class
whose minor field is a set of *flags* rather than a value, so a single device can claim
several at once — a print/scan/copy machine claims two. It is read most-specific-first,
in the order somebody would name the thing on their desk: Printer, then Scanner, then
Camera, then Display, each with its own row and artwork. And under Toy (`0x08`), a
Controller is the same thing a gamepad is, so it resolves to the gamepad row rather than
to nothing.

Both classes previously fell through to the generic glyph in their entirety. The rest of
the Toy class — robots, vehicles, dolls, "game" — is still left generic on purpose, as
is an imaging device that claims no flag at all: none has artwork that would be honest.

### Fixed: a wired Ethernet adapter could be announced as "WiFi Adapter"

Found while auditing, against hardware connected at the time: the Realtek USB Ethernet
adapter in a USB-C dock reports device class `0x00` — "ask the interfaces" — and says it
is Ethernet only through those interfaces (Communications/ECM plus CDC Data). Those are
normally waited for, so it lands correctly on "Network Adapter". But the wait is
bounded, and if it times out the device arrives with class `0x00` and no interfaces at
all: nothing resolved, so the vendor-ID guess got its turn, and Realtek is on the
WiFi-chip vendor list. A wired adapter would then be announced as "WiFi Adapter" — same
shape as the Billboard misread above, a real device losing to a guess.

The device's own product name says "LAN", which beats guessing from the vendor, so it is
read first now. Wireless names ("WLAN", "Wi-Fi", "Wireless", "802.11") are read first of
all and resolve to WiFi Adapter directly — which also makes that detection less
dependent on the vendor list. Both matches are on whole words rather than substrings,
because "WLAN" ends in "lan": read as a substring, a WiFi dongle would have been
announced as a wired adapter, which is the same mistake in the opposite direction.

### Bluetooth peripherals are told apart past "keyboard or mouse"

A classic Bluetooth device announces what it is in its Class of Device record, and for
major class Peripheral that record carries two independent fields: two bits saying
whether the thing is a keyboard, a pointing device or both, and a four-bit device type
underneath them. Only the two bits were ever read. Everything the Bluetooth SIG defines
in the four bits below — joysticks, gamepads, remote controls, digitizer tablets,
digital pens, card readers, handheld scanners, sensing devices — set neither bit, so
each one answered "not a keyboard, not a mouse" and was announced with the generic
Bluetooth glyph.

The four bits are read now, with six new kinds and artwork to match: Gamepad (joystick
and gamepad both), Remote Control, Graphics Tablet (digitizer tablet and digital pen),
Card Reader, Handheld Scanner and Sensor. Each gets its own notification row in
Settings, so any of them can be switched off on its own.

The two bits are still read first, so a real keyboard or mouse keeps answering exactly
as it always did whatever the four bits underneath happen to say. The one exception is
deliberate: a digitizer tablet sets the pointing-device bit and *also* names itself a
tablet, and the tablet is the more specific of the two answers. Uncategorized
peripherals and handheld gestural input devices are still left generic on purpose —
there is no artwork that would be honest for either.

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
