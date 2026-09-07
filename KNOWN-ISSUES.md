# Known issues

Small, understood defects that are not worth holding a release for, kept here so they are
not rediscovered from scratch. Anything larger belongs in the code it affects.

## Fixed: a wired Ethernet adapter could be announced as "WiFi Adapter"

**Status:** fixed 2026-09-07, found by audit rather than by a live report — the
misclassification needed a bounded retry to time out first, so it would have surfaced
only occasionally and looked random.

The Realtek USB Ethernet adapter in a USB-C dock (vendor `0x0BDA`, product `0x8153`,
device class `0x00`) names itself Ethernet only through its interfaces. Those are waited
for, and normally arrive, so the device resolves to "Network Adapter". When that wait
timed out, the device fell through to the vendor-ID guess — and Realtek is on the
WiFi-chip vendor list, so a wired adapter was announced as WiFi. Same shape as the
Billboard misread below: a real device losing to a last-resort guess.

Fixed by reading the product name before any vendor guess. Note for anyone extending
those keywords: they must be matched as whole words. "WLAN" ends in "lan", so a
substring match reads a WiFi dongle as wired — the same bug in the other direction, and
the reason wireless is checked first as well.

## Fixed: a Billboard chip read as "Serial/Debug Adapter" after the usb.ids widening

**Status:** fixed 2026-09-06, reported live minutes after the `usb.ids` widening
shipped — every launch showed a VIA Labs "USB 2.0 BILLBOARD" chip (a hub's own internal
companion device, always present, not something plugged in) as "USB Serial/Debug
Adapter Connected".

**Root cause.** `USBDevice.kind`'s vendor-lookup guard read `if resolved == nil`, but
`resolved == nil` is not the same question as "genuinely unclassifiable": device class
`0x11` (Billboard) has a real name (`className` already resolves it to "Billboard") but
no `USBDeviceKind` row of its own, so it reads as `resolved == nil` too. Once
`USBSerialVendorDatabase` was widened by a `usb.ids` update (see its own doc comment —
a deliberate, accepted tradeoff) VIA Labs' VID became a "known vendor," and the guard,
never designed to be second-guessed by a real class name, claimed it as a Serial/Debug
Adapter.

**The fix.** Added `!isMeaningfullyIdentified` to the same guard — the identical check
already guarding "ignore identified devices without their own icon" for exactly this
kind of gap. A device with a real, named class now never falls through to a vendor-ID
guess, regardless of how broad that vendor list grows.

## Not a bug: Gamepad Monitor never fires for most real controllers

**Status:** confirmed 2026-09-06, not something this application can fix — a limitation
of `GameController.framework` itself, on this macOS.

**What was reported.** After USB Monitor's own Gamepad/Joystick classification shipped
(and was confirmed correct, including a real HORI-licensed "HORIPAD S"), the question
came up: why does Gamepad Monitor's own, richer notice never fire alongside it?

**Confirmed directly, not assumed.** A small diagnostic calling `GCController.controllers()`
returned **0** with the HORIPAD S connected and actively working as a HID gamepad
(`PrimaryUsagePage`/`PrimaryUsage` correctly read as Generic Desktop/Gamepad). Apple's
GameController framework only surfaces a `GCControllerDidConnect` notification for
controllers it recognises from its own internal list — MFi-certified controllers and a
handful of major-brand ones (Xbox, DualShock/DualSense, Switch Pro among them) — not
every HID device that happens to expose a standard gamepad Usage Page. A HORI-licensed
pad and a no-name generic USB gamepad are both outside that list; the OS itself never
tells any app they exist as game controllers, this application included.

**Why this is not a bug to fix here.** There is nothing to read, poll, or retry around:
the framework simply never posts the notification this module listens for, regardless
of how long anything waits. USB Monitor's own "Gamepad/Joystick Connected" — reliable,
device-level, USB-IF/HID-standard classification — is, and will remain, the *only*
notice such a controller ever gets from this application. This is exactly why "Notify
for USB devices independently of USB Monitor" (Settings → Gamepad) defaults to **on**:
turning it off would leave many real, connected controllers with no notice at all.

**What would change this.** Only Apple adding a given controller to the OS's own
internal list — nothing this application does, or could do, changes which devices
`GameController.framework` recognises.

## Fixed: a USB gamepad connected as "Keyboard/Mouse", disconnected as "Gamepad/Joystick"

**Status:** fixed 2026-09-06, reported live immediately after the Gamepad/Joystick
classification itself shipped — the same real generic USB gamepad (`idVendor` 0x0810)
used to confirm that feature, connected and disconnected in the same session.

**What was actually happening.** The same teardown/enumeration race this file already
has three entries for (External Disk's connect/disconnect saga; `mediumType`'s own,
found by audit rather than report), on a fourth registry subtree: the HID interface's
own `bInterfaceClass` (`0x03`) is visible immediately, but the `IOHIDDevice` object
underneath it — the only place a Usage Page/Usage ever appears — is not published yet
at the instant a device first arrives. Confirmed live: connect read `hidUsagePage` as
nil and fell back to plain `.hid` ("Keyboard/Mouse"); disconnect, re-reading a registry
entry that had been alive for however long the device was actually connected, found the
Usage Page/Usage already settled and correctly read `.gamepad`.

**The fix.** The exact same shape as `enrichedMassStorageHint`/`enrichedInterfaceClasses`
before it: `enrichedHIDUsage`, a short identity-based retry (15 tries, 40ms apart — the
same cadence as the interface-class retry, since this is software registration with no
physical device to wait on, unlike a disk's own description) chained onto both arrival
paths a HID device can take — the plain one (device class `0x03` directly) and the
composite one (device class `0x00`/`0xEF`, `0x03` on an interface). A device that still
has not resolved by the deadline is left exactly `.hid`, the honest, original answer.

## Fixed: a USB-serial adapter went silent, read as a sibling hub instead

**Status:** fixed 2026-09-06, reported live as "connected a serial device and it's
detected as a USB hub" — confirmed with the real device connected, not assumed.

**What was actually happening.** Two devices enumerate together: a genuine hub chip
built into the adapter (a real, correctly-reporting "USB Hub Connected"), and the FTDI
serial chip itself (`FT232R USB UART`, device class `0x00`, its interface class FTDI's
own `0xFF` — "Vendor Specific", one of USB-IF's two escape hatches for a chip that uses
no standard class at all). The serial device was never "detected as a hub" — it was
detected as nothing, silently, so the one notification that did appear (the sibling
hub's, entirely correct on its own) read as if it were describing the serial adapter.

**Root cause.** `USBMonitor.ignoresIdentifiedGenericDevices` — "ignore identified devices
without their own icon" — was on (confirmed via `defaults read`), and its check
(`device.className != nil`) could not tell "Vendor Specific" apart from a class that
names something real. The switch exists to silence a chip like Billboard or
Communications, which *does* say something concrete about what it is; "Vendor Specific"
says the opposite — "not one of the standard classes, ask the vendor" — and is exactly
as uninformative as no class at all.

**The fix.** A new `USBDevice.isMeaningfullyIdentified`, checked instead of a bare
`className != nil`: true for a real class name, false for `className` resolving to
"Vendor Specific" or "Application Specific" (`0xFF`/`0xFE`, USB-IF's other escape hatch).
A vendor-specific device now announces through the generic row exactly as an
unclassified one always has, regardless of the switch.

**Generalised on request, immediately after confirming the fix worked, rather than left
scoped to the exact device reported.** "Vendor Specific"/"Application Specific" are two
of USB-IF's three "not a real answer" class names; the third, "Miscellaneous" (`0xEF`,
`className`'s own honest label for a composite device whose interfaces name nothing
recognisable either), was the identical shape and would have silenced a device hitting
that path the same way — confirmed by re-reading `className`'s own fallback, not by a
second live report. Folded into the same check (`Self.uninformativeClassNames`) rather
than left as a narrower fix that only covered the one class byte actually seen live.

## Investigated and rejected: naming the port/protocol in "Video Link Detected"

**Status:** investigated 2026-09-06, rejected — tested against 4 real connect/disconnect
cycles, not reasoned about from a single sample. Not worth retrying without new evidence.

**The idea.** A single connect's kernel log also showed `IOAccessoryManager` lines naming
the actual port and protocol — `IOPortTransportState::handleStateChange(): [Port-USB-C@2:
DisplayPort]` — which looked, from that one sample, like a clean one-shot marker that
could let the notification say "USB-C port 2, DisplayPort" instead of the generic
message.

**Why it doesn't work.** Streamed the same log across 4 real connect/disconnect cycles.
`handleStateChange` fired 44 times against `ReceiverConnected`'s 4 — not a 1:1 marker at
all. It fires for the port's USB3 *data* role changing (`[Port-USB-C@2: USB3]`, nothing
to do with video), for DisplayPort renegotiation with no cable event nearby, and in
clusters at moments with no connect or disconnect happening at all (14:40:19, 14:40:22 in
the captured run, both quiet). Building on it would trade one reliable, narrow marker for
one that fires roughly eleven times as often for unrelated reasons — a worse experimental
feature, not a better one.

**Left as it is.** The existing generic message stays exactly as it was — see the
adjoining entry below on why the message content itself already reflects the honest
ceiling of the *good* marker this feature already uses.

## Confirmed working live: the experimental "Video Link Detected" early warning

**Status:** confirmed 2026-09-05 — the first time this feature has been seen firing
against real hardware. Connecting a display over a USB-C-to-HDMI cable produced "Video
Link Detected" (Display Monitor) alongside a correct, detailed "Audio Device Connected"
(HDMI carries audio too), where before it had only ever been theoretical.

**Whether the message can say more than it does — checked directly against the actual
kernel log line, not assumed.** The real entry from this session:

```
kernel: (DCPAVFamilyProxy) IOAV[3960] AppleDCPDPTXRemoteHDCPAuthSessionProxy<0x100012e9c>
  ::handleMessage: ... Processed ReceiverConnected<0>
```

Repeated roughly every two seconds during the HDCP handshake retry. No port, no cable
type (HDMI vs. DisplayPort), no display identity anywhere in it — `IOAV[3960]` is a
message counter, `0x100012e9c` an in-process object address, neither stable enough to
mean anything to a person and neither naming the actual hardware. The generic message
`VideoLinkDetector`/`DisplayMonitor` already show is not a shortcoming to fix; it is the
honest ceiling of what this specific kernel log line contains. Nothing else to improve
here without a different, more specific log line to key on — not attempted, since none is
known to exist.

## Fixed: same teardown race, found for `mediumType` too, by an audit rather than a new report

**Status:** fixed 2026-09-06, confirmed working live for the two-disks-at-once case;
this one specific field was found by auditing the codebase for the same shape of bug
after the fix directly below, not by a fresh live report of it happening.

**What was checked.** After the departure-cache fix for `massStorageHint` was confirmed
working, an audit went looking for every other place in the application that re-reads
live system state for one specific device at disconnect with no cache — the same shape
of race. It found one real, currently-unprotected instance: `mediumType` ("Solid
State"/"Rotational") is read via the exact same `storageMedium(_:)` registry walk that
`massStorageHint`'s BSD name comes from — same disk-layer subtree, same teardown timing
— but had no cache of its own, unlike `massStorageHint` and `interfaceClasses`. A
disconnect notification could lose its "Medium" line for the identical reason one of the
two disks lost its "External Disk" kind, just not yet reported live because losing one
line reads as less obviously wrong than losing the whole kind.

Everything else checked — Camera, Gamepad, Thunderbolt, Bluetooth, Audio, Display, Power,
Printer, Scanner, Volume — either never re-reads live per-device state at departure at
all (most of them), or already has its own fallback for the one place it does
(`NetworkMonitor`'s Wi-Fi SSID). Camera's `AVCaptureDevice.uniqueID`/`localizedName` and
Gamepad's `GCController.vendorName` are re-read live at disconnect too, but both are
simple client-side-cached properties rather than a multi-layer registry/DiskArbitration
walk, and neither has ever been reported doing this — left unguarded rather than fixed on
spec.

**The fix.** A third cache, `resolvedMediumTypes`, mirrors the other two exactly: filled
in on arrival wherever a mediumType is read (whichever of the three code paths that
happens on), read back on departure whenever the fresh read comes back nil.

## Fixed: one of two external disks read generic "Mass Storage" only on disconnect

**Status:** fixed 2026-09-06, reported live with two real external HDDs connected at
once, after the connect-time fix directly below was confirmed working: one disk
disconnected correctly as "External Disk", the other read plain generic "Mass Storage" on
the way out.

**Root cause.** Departure reads a Mass Storage device's disk fresh, once, with no
retry — by the time `kIOTerminatedNotification` fires the disk is already being torn
down, so whether its BSD name/description are still readable at that exact moment is a
race, not a guarantee, and it can genuinely go either way between two otherwise-identical
disks. `resolvedInterfaceClasses` already exists precisely to give a composite device's
departure something to fall back on when its own live read comes back empty (the BRIO fix,
2026-09-03) — but no equivalent cache existed for a Mass Storage device's own hint, so
departure had nothing to fall back on when its one-shot read lost that race.

**The fix.** A second cache, `resolvedMassStorageHints`, mirrors `resolvedInterfaceClasses`
exactly: filled in on arrival the moment a hint resolves (immediately, or after the
retry), read back on departure whenever the fresh read comes back nil, and forgotten
either way once departure has asked. Confirmed by the same live report that found it —
not yet re-tested against the exact two disks that disagreed.

## Fixed: USB Monitor's external-disk detection read generic on connect, correct on disconnect

**Status:** fixed 2026-09-06, reported live immediately after the fix directly above —
"the external HDD shows Mass Storage on connect but External Disk Disconnected on
disconnect." Same disk, disagreeing with itself across the two notifications.

**Root cause.** The same shape as the composite-device (BRIO) bug fixed 2026-09-03, but
for a different reason. A Mass Storage device's own IOKit entry is *not* replaced the way
a composite device's is — what is still incomplete at `kIOFirstPublishNotification` is
the driver stack *underneath* it: the SCSI translation layer, then the block-storage
driver, then the disk's own BSD name, all of which the size-based `.externalDisk`
fallback depends on reading. By the time the device disconnects, that stack has long
since finished attaching — which is exactly why departure read the drive correctly and
arrival did not.

**The fix.** `IOKitUSBDeviceSource.drain(_:arriving:)` now recognises a Mass Storage
device whose `massStorageHint` came back nil (`isUnresolvedMassStorage(_:)`) and retries
on the very same `io_service_t` — not a fresh one, since nothing about this entry goes
stale while its own stack attaches beneath it, unlike the composite-device case. Bounded
at 20 tries, 50ms apart (1 second total): wider than the composite-device retry's 400ms,
since a disk's BSD name has a deeper stack to wait on than an interface descriptor does.
A device that still answers nothing by the deadline is left exactly as generic as it
always would have been.

**This first attempt did not work, and here is why.** Reported live, unchanged, right
after installing it: the exact same external HDD, reconnected several times, still read
generic on connect. Read straight off the live registry this time (`ioreg -p IOService`)
rather than assumed: this enclosure's own `bDeviceClass` is `0x00` — Mass Storage is
declared only on an *interface* underneath it (`bInterfaceClass 0x08`), the same
composite shape a webcam or an audio device uses. `isUnresolvedMassStorage(_:)` compared
the raw `deviceClass` byte to `0x08` directly, which this device's own byte never is, so
the retry this whole mechanism exists for silently never ran — the fix built and shipped
with a condition that could not fire for the device it was written for.

**The actual fix.** `isUnresolvedMassStorage(_:)` now reads `device.kind` — the already-
resolved class, which correctly falls back to the interfaces the same way `USBDeviceKind`
itself does — rather than the raw byte. Confirmed this time by reading the live registry
of the exact reporting enclosure, not merely reasoned about: its `bInterfaceClass` is
present and is `0x08`, so `device.kind == .massStorage` correctly recognises it as needing
the retry, where the raw-byte comparison never could.

**That fix, too, did not work — reported live, unchanged, as "still detects it as USB
Mass Storage on both connect and disconnect now."** Read the live registry a third time
rather than guess again. Two things were wrong at once:

1. **Two separate ambiguity branches, and this device takes the one with no
   `massStorageHint` retry at all.** `isAmbiguous(_:)` is false for this device once its
   interface has appeared — which, confirmed live, is already true at the very first
   read — so it never enters the composite-device branch (interfaces-only retry) in the
   first place; it takes the plain "not ambiguous" branch. The kind-comparison fix from
   the previous round was real and necessary, but it only helped a device that reaches
   that branch. This one always did — the retry it added should have applied — which
   means:
2. **The same-handle retry itself does not work for this device**, confirming that its
   own IOKit entry *is* replaced during driver matching, the same as a composite
   device's, contrary to this fix's first assumption ("nothing here replaces this
   entry"). A retry that keeps re-asking a handle that has already gone stale finds
   nothing no matter how long it waits — indistinguishable, from a single read, from a
   disk that will never resolve.

**The fix, unified with the existing mechanism rather than layered beside it.**
`enrichedMassStorageHint` now re-finds the device by vendor/product/location each poll —
exactly `matchingInterfaceClasses`'s own re-finding, now shared by both retries — instead
of trusting a handle to stay valid. Both branches in `drain(_:arriving:)` now chain this
retry in whenever the resolved kind is plain `.massStorage`: the already-ambiguous
composite branch chains it on *after* interfaces resolve (so a device ambiguous at both
levels gets both retries, one yield, not two), and the not-ambiguous branch runs it
directly, both keyed by identity rather than a handle.

**That fix, too, did not work — reported live as "exactly the same" a fourth time.**
Stopped reasoning about static registry snapshots at this point and built a purpose-made
diagnostic tool instead: a small signed binary watching this exact enclosure's real
connect live, polling its resolved state every 200ms and logging a timestamped timeline,
rather than inferring anything from a single read. The real timeline, measured directly:

```
t+0.0s   interfaces empty (bDeviceClass 0x00, ambiguous — matches isAmbiguous)
t+0.2s   interfaces resolve to [8, 8, 8] — comfortably inside enrichedInterfaceClasses's own window
t+0.2s – t+4.2s   disk description still unreadable ("no-bsd-name")
t+4.4s   BSD name + Disk Arbitration description finally readable — real media name, real size
```

**The actual bug, finally: the retry bound itself was too short by roughly 4×.** Every
previous round changed *which* mechanism ran the retry (same handle vs. re-found by
identity, which branch triggers it) and each change was a real, necessary fix for what it
targeted — but none of them touched the *timeout*, which stayed at 1 second throughout,
against a disk that needed 4.4. From inside a 1-second window, "still resolving" and
"will never resolve" are indistinguishable, so every fix looked unchanged no matter how
correct its own logic was.

**The fix.** `enrichedMassStorageHint`'s bound raised from 20 tries at 50ms (1s) to 32
tries at 250ms (8s) — nearly double the measured 4.4s, not merely matching it, since one
enclosure's timing is a data point, not a guarantee for every enclosure this heuristic
will ever meet.

**Confirmed this time by watching the real timeline, not by reasoning about a snapshot —
but the fixed code path itself has not yet been re-run against the live app.** Reconnect
the same enclosure once more and say what the connect notification actually reads. If
this is still wrong, the next step is *not* another guess at the mechanism — it is
running the same diagnostic tool again to watch the fixed code's own timeline directly.

## Fixed: USB Monitor showed a pendrive and an external HDD both as plain "Mass Storage"

**Status:** fixed 2026-09-05, confirmed against real hardware — a genuine 1 TB external
HDD and a genuine pendrive, connected at the same time, both reported generically.

**What was checked.** `diskutil info` and the raw USB descriptor for each device:
- The external HDD's Disk Arbitration media name is `"D ST1000LM02"` — a real Seagate
  model number, but not a word `USBMassStorageHint`'s token list recognised ("hdd",
  "external", …). Its enclosure bridge chip (`idVendor` 0x2109, VIA Labs) reports
  entirely unconfigured placeholder strings, `"VLI Manufacture String"`/`"VLI Product
  String"` — the enclosure's maker never customised them.
- The pendrive's Disk Arbitration media name is the bare, generic `"General Media"`, and
  its own USB descriptor carries no product string at all — only a vendor string of
  `"General"` and `idVendor` `0xABCD` (43981 decimal), a well-known unregistered
  placeholder identity used by unbranded chips, not a real vendor registration.

**The fix, and its honest limit.** `USBMassStorageHint` gained an `.externalDisk` case —
matched by name ("hdd"/"ssd"/"hard disk"/"hard drive"/"external") and, failing that, by
the same size threshold (≥400 GB) `VolumeKind`'s own heuristic already relies on for
exactly this situation. The 1 TB drive clears that threshold and is now correctly told
apart. The pendrive is not, and cannot be: there is no name to match and it is nowhere
near 400 GB, so it stays generic "Mass Storage" — the same honest answer Volume Monitor's
own, longer-established heuristic already gives this identical device. Confirmed by
reading the pendrive's actual USB descriptor rather than assumed: there is truly no text
anywhere on this device for any heuristic to find.

## Fixed: a microSD reader in a USB hub mounted as a plain external disk, not "SD card"

**Status:** fixed 2026-09-05, confirmed live — reported again after a first attempt at
this same fix did not actually change anything, tracked down and confirmed this time with
a standalone signed test binary reproducing the exact code path against the real,
connected reader (a two-slot "USB3.0 Card Reader", `Generic`/idVendor 1507/idProduct 1865,
mounting its FAT32 slot as `BATOCERA`).

**What was happening.** Volume Monitor's own SD-card heuristic (`VolumeKind.infer`) reads
Disk Arbitration's `MediaName`/`DeviceModel`, string-matching for tokens like "sd card",
"card reader". For the *mounted volume* (as opposed to the raw disk), Disk Arbitration
answers `DeviceModel` = `"MassStorageClass"` and `MediaName` = `"Untitled 1"` — confirmed
directly against the running description with `DADiskCopyDescription`. Neither string is
SD-shaped, so the heuristic had nothing to match and the volume mounted as a plain
external disk, reporting "Interface: USB" rather than "SD/CF card (external reader)".

**Root cause.** Disk Arbitration and IOKit disagree about what this device is called. The
owning `IOUSBHostDevice`, asked directly via IOKit, answers `"USB Product Name" = "USB3.0
Card Reader"` — the same descriptor `USBMonitor` already reads for its own device-class
rows — nine registry levels up from the volume's own `IOMedia` node. Disk Arbitration
simply does not surface that string for this device; IOKit still has it.

**The first attempt at this fix did not work, and here is why.** It read the USB product
string only when Disk Arbitration's own `MediaName`/`DeviceModel` were *empty* — reasoning
from a whole-disk (`disk6`) query that genuinely did return blank fields. But Volume
Monitor asks about the *mounted volume*, not the raw disk, and that query returns
non-empty-but-still-generic strings (`"Untitled 1"`, `"MassStorageClass"`) instead of
nothing — so the "only when empty" fallback never ran at all, and the fix silently did
nothing. Confirmed by reading `DADiskCopyDescription` for `/Volumes/BATOCERA` directly
against the live device, rather than assumed.

**The actual fix.** `NSWorkspaceVolumeSource.mediaNameForGuessing(_:)` now joins Disk
Arbitration's own `MediaName`/`DeviceModel` with the USB product string
unconditionally — found via `usbProductName(bsdName:)`, a bounded (16-level) upward walk
from the disk's BSD name — rather than only consulting it as a last resort, and leaves
`VolumeKind.infer`'s own token matching to use whichever part of the combined string
actually says something. No new token was needed: "USB3.0 Card Reader" already matches the
existing "card reader" token; the fix was joining in the right property unconditionally,
not widening the word list.

**Asked next: can SD and microSD be told apart?** Checked one level deeper than the fix
above, at the SCSI layer this reader's mass-storage stack exposes per slot
(`IOSCSILogicalUnitNub`'s own "Vendor Identification"/"Product Identification", not the
USB device's, since a multi-slot reader shares one USB device between every slot). For
*this* reader, both slots answer the identical generic `"MassStorageClass"` — no signal
at any level distinguishes them. That is a firmware limitation of this specific reader,
not something more code can work around, so `registryIdentityStrings(bsdName:)` now
collects the SCSI-level string opportunistically (for a reader that does bother to name
its slots differently) alongside the USB one, and `describeInterface(_:)` reads "MicroSD
card" instead of "SD/CF card" when the combined name says so — untestable against this
session's own hardware, since it names both slots identically, but harmless for it too.

**Confirmed this time, precisely how the first attempt should have been.** A standalone
binary — compiled and ad-hoc signed the same way the application itself is, since the
interpreted `swift run-file.swift` mode this session tried first is blocked from
`IOServiceGetMatchingService` in whatever sandbox this tool's own shell runs under —
reproduced `mediaNameForGuessing`'s exact logic against `/Volumes/BATOCERA` live and
printed the real combined string: `"Untitled 1 MassStorageClass USB3.0 Card Reader"`,
which does contain "card reader". Not yet watched as an actual banner in the running
application — that is the one step still worth doing after the next real unplug/replug.

## To revisit: "ignore identified devices without their own icon" works, but doesn't sit right

**Status:** working as designed, confirmed live (04-sep-2026) — a hub's internal Billboard
interface is silenced with the switch on, Hub/Network Adapter/Mass Storage are untouched
either way. Kept open anyway because the person who asked for it said as much directly:
"funciona, pero no me termina de convencer" (works, but doesn't fully convince me).

**What the switch does today.** `USBMonitor.ignoresIdentifiedGenericDevices`: a device whose
`className` resolves to something (a real USB-IF class name, however obscure — "Billboard",
"Content Security"...) but has no `USBDeviceKind` case of its own is silenced when the
switch is on; a device `className` itself returns nil for (nothing at all is known about
it) still announces regardless. One boolean, one behaviour, covering every class this app
does not have a dedicated row for, present and future.

**Why it might not be the right shape, worth thinking about later.** A few candidate
reasons, none confirmed:
- It is an app-wide, all-or-nothing switch. Someone might want Billboard silenced but a
  different icon-less class (Content Security, say) still announced, which this cannot do —
  the only escape is giving that other class its own `USBDeviceKind` too, the way
  Communications ("Network Adapter") just got one.
- It conflates two different questions under one name: "this class has no icon" and "this
  class is not something a person cares about." Most icon-less classes so far (Billboard,
  Content Security, Physical) *are* uninteresting chip-level plumbing, but that is a
  coincidence of what has been seen in practice, not something the switch actually checks.
  A future icon-less-but-genuinely-interesting class would have no way to be exempted short
  of, again, giving it its own row.
- The name itself ("ignore identified devices without their own icon") describes the
  mechanism, not the intent — a person has to already understand the codebase's own
  className/kind distinction to guess what it does from the label alone.

**How to settle it.** No action yet — revisit if it comes up again, or if a class shows up
that this switch's current all-or-nothing shape gets wrong.

## To investigate: USB Monitor's flash-drive/SD-card heuristic is borrowed, and imperfect where it came from

**Status:** shipped 2026-09-04, at the request of the person who asked "¿Es posible
diferenciar Mass Storage de pendrive?" and, once told the honest shape of the answer,
said to build it anyway and leave this note for later: "Si y deja documentado para que
despues se haga otra investigacion para solucionar eso."

**What it does.** USB Monitor's `0x08` (Mass Storage) class covers three different things
someone plugs in — a flash drive, an SD card reader, a portable HDD/SSD enclosure — and the
class byte alone cannot tell them apart. `USBMassStorageHint.infer(protocolName:mediaName:)`
in `USBDevice.swift` reads the disk itself through Disk Arbitration
(`IOKitUSBDeviceSource.massStorageHint(_:)`, using `DADiskCreateFromBSDName` off a BSD
device name read from the same IOKit registry walk that already finds "Medium Type") and
refines `USBDevice.kind` from plain `.massStorage` into `.usbDrive` or `.sdCardReader`
when the disk's protocol or name says so plainly. Anything the heuristic does not
recognise — a named disk enclosure, or a disk with nothing to go on at all — stays the
honest, generic `.massStorage`, exactly as before this existed.

**Why it is not trusted as a finished answer.** It is not a new technique: it is a scoped,
independently reimplemented copy (module isolation forbids importing another monitor's
types) of Volume Monitor's own `VolumeKind.infer`, which is itself an admittedly imperfect
heuristic over the same kind of Disk Arbitration data — string-matching a disk's reported
protocol and media name against fixed token lists, with no ground truth to check the guess
against. Whatever is unproven about the original is unproven here too, and USB Monitor
adds a wrinkle Volume Monitor never had to handle: it may be reading a disk that is not
mounted (no volume path to key off), and a BSD name found on some registry child of the
right shape, not necessarily the disk itself, so a future device whose registry layout
looks slightly different from what was tested could silently fall back to `nil` (which is
safe — `.massStorage`, not a wrong specific guess) or, less safely, get one right by
coincidence.

**Not yet done:**
- Confirmed only against reasoning about the registry shape and Volume Monitor's own
  behaviour, not against a real flash drive and a real SD card reader plugged in and
  watched live — unlike almost everything else in this file.
- No coverage for the size-based fallback Volume Monitor's own heuristic has (a large
  unnamed disk read as an external enclosure) — deliberately left out here rather than
  guessed at, so a future investigation should decide on purpose whether USB Monitor wants
  that too, not inherit it by accident.
- Whether the two new rows (`USBConnectedUSBDrive`, `USBConnectedSDCard`) and their icons
  (`Device-USBDrive`, reused as-is; `Device-SDCard`, copied byte-for-byte from Volume
  Monitor's own `Resources/`) read right against a live device has not been watched with
  eyes on real hardware yet.

**How to settle it.** Plug in an actual flash drive and an actual SD card reader, watch
what `USBConnectedUSBDrive` / `USBConnectedSDCard` fire and read correctly, and only then
decide whether the heuristic needs the size fallback, needs its BSD-name discovery
hardened against a different registry shape, or is simply good enough as it stands.

## To investigate: which modules need their own particular Simulate, like Thermal's

**Status:** open, 2026-09-04. Every module's Notifications tab now offers a generic
"Simulate a Notification" section (`GenericEventSimulator` in `EventSettingsView.swift`):
pick one of that module's own declared events from a list, fire it with its real title
and icon, through the same dispatcher pipeline a real one goes through (icon overrides,
the event's own on/off switch, all of it). Thermal keeps the one it already had
(`ThermalSimulator`) instead, because Thermal's events are not "pick one and fire it" —
they are a transition, *from* one state *to* another, and a plain event picker cannot
express that.

**What is not yet done.** Nobody has gone module by module asking whether the generic
picker is actually enough, or whether some other module's events are shaped like
Thermal's rather than like most others' — needing more than a name and an icon to
simulate honestly. Candidates worth a look, not yet confirmed:

- **Power** — a battery health reading, a low-power-mode change, a refire: state-shaped,
  possibly wanting a "from/to" or "at what percentage" simulator of its own rather than a
  bare event name.
- **Volume Monitor** — "Low disk space" means something only at a particular percentage
  free; simulating it as a bare event says nothing about *how* low, where a Thermal-style
  picker (or a percentage slider) would.
- **Network** — Wi-Fi signal level and DHCP lease events carry a number or a state a
  plain title does not; worth checking whether the generic simulator's fixed body text
  ("Simulated — nothing on this Mac actually changed.") reads as honest for these or as
  oddly generic next to a notification that is normally full of specifics.
- Every other module (USB, Camera, Audio, Bluetooth, Display, Printer, Scanner, Gamepad,
  Thunderbolt) — not reviewed yet either, just less obviously needing more than the
  generic picker already gives them, being one notice per kind of thing rather than one
  notice per *level* of something.

**How to settle it, module by module.** For each one: read its `MonitorEventDescription`
list and ask whether a fired event's title and icon alone already say everything a real
one would, or whether a real one always carries a number/state/detail the generic
simulator's fixed body cannot honestly stand in for. If the latter, it is a Thermal-style
candidate — its own `*Simulator` view and its own entry point on `AppDelegate`, the same
shape `simulateThermal`/`ThermalSimulator` already are.

## Fixed: USB Monitor classified a composite device generically on connect, correctly on disconnect

**Status:** fixed 2026-09-03, confirmed live against the BRIO across two full
connect/disconnect cycles — classification now reads correctly (`kind = .webcam`) within
14ms of the ambiguous read, both times. Kept here for the reasoning, not as an open item.

**What happened.** A composite USB device — the Logitech BRIO among them — showed up as
"USB Device Connected" / `Type: Miscellaneous` when it arrived, but as "USB Webcam
Disconnected" when it left. The two should have agreed: both go through the same
`USBDevice.kind` / `className`, which since 2026-09-03 fall back to the device's
interfaces when the device's own class names nothing (`0x00` or `0xEF`, the standard
composite-device marker).

**Root cause, confirmed against real hardware.** `IOKitUSBDeviceSource` reads a device's
interfaces at the exact moment `kIOFirstPublishNotification` fires for it — the moment
`USBMonitor`'s own "attached" event is built from. Measured directly:

- At `kIOFirstPublishNotification`, the device's interfaces are not children of it yet:
  `interfaceClasses` reads back empty, and *stays* empty for at least 5 full seconds on
  the same registry entry.
- `kIOMatchedNotification`, which fires ~9ms after first-publish, *does* see the full,
  correct set of interfaces (`[Video, Video, Video, Audio, Audio, Audio]` for the BRIO) —
  for one instant.
- Querying that same entry again 200ms later returns empty again. Not because the
  interfaces went away: the device republishes as a **new** registry entry shortly after
  matching (the same physical device, a different `io_service_t`), and the handle held
  from the first publish becomes stale. A fresh query at any later moment — which is what
  a standalone probe run well after the device settled correctly found — reaches the new,
  final entry instead of the stale one.

So the interfaces are never actually missing for long; the first handle
`USBMonitor` sees them through is simply the wrong one to keep asking. By the time the
device disconnects, whatever republishing was going to happen already has, so the terminal
entry's own interfaces read correctly — which is why the departure gets it right and the
arrival does not.

**Why waiting alone would not have fixed it.** The natural first idea — wait a little after
first-publish before reading interfaces — does not work: the *very entry* being asked goes
stale, so no amount of waiting on it helps.

**The fix.** `IOKitUSBDeviceSource.drain(_:arriving:)` now recognises an ambiguous read
(`isAmbiguous(_:)`: device class `0x00` or `0xEF`, no interfaces yet) and, only for that
case, looks the device up again by what survives the entry being replaced — vendor,
product and port location, not the `io_service_t` — polling up to ten times, 40ms apart
(`enrichedInterfaceClasses`/`matchingInterfaceClasses`). Measured live: the correct
interfaces are found on the first or second try, ~5–15ms in, nowhere near the 400ms
ceiling. An ordinary device — the overwhelming majority — never takes this path at all and
is yielded exactly as it always was, with no added latency.

**Reported live**, 2026-09-03, alongside screenshots showing the title/body disagreement
directly.

## First disconnection after launch is still announced, with USB notices switched off

**Severity:** minor. One extra notification, once per launch, and only in a specific order
of events.

**What happens.** With "Notify for USB devices independently of USB Monitor" switched
**off**, a camera that was **already plugged in when the application started** still
announces its *first* disconnection. Every cycle after that behaves: the reconnection is
silent, and so is the disconnection that follows it.

**Reported live**, 2026-09-03: "sigue sin funcionar a la primera pero es porque la app
inicia cuando ya está la cámara conectada".

**The cause is not established.** Worth saying plainly, because the obvious explanation is
wrong and cost time already. The obvious explanation would be that the startup sweep leaves
the monitor without the record its departure logic depends on. It does not: the sweep
yields the same `.connected` events through the same `handle(_:)`, so `connectedTransports`
and `suppressedUIDs` are populated exactly as a live connection would populate them. The
whole modelled path — connect, then disconnect, with the switch off throughout — is covered
and passes (`usbCameraCanBeSuppressedAgain`).

So something outside that model is responsible. Candidates, in the order worth checking:

1. **Another application announcing it.** HG4MAC watches the same hardware and draws its
   banners in the same screen corner, with its own wording and its own settings, and is
   completely invisible to HardwareSentry. This already caused a long false hunt on
   2026-09-03. Tell them apart by the wording: HG4MAC says `"USB Connection"` /
   `"USB Disconnection"`; HardwareSentry says `"USB Device Connected"` /
   `"USB Device Disconnected"`. Check with `pgrep -fl HG4MAC` before anything else.
2. **The transport reported at that particular moment.** See the composite-device timing
   issue above — the same registry-entry staleness could plausibly affect Camera's own
   AVFoundation-based transport reporting too, though this has not been measured
   specifically for that path yet.
3. **Which monitor is actually speaking.** Camera and Audio both announce this device, and
   both have their own switch. A notification from the one whose switch is still on reads
   as the other one failing.

**Already fixed, and not to be re-diagnosed.** Two separate defects in this same setting
were found and fixed first; each one on its own looked like the entire problem:

- The transport was described as `"usb"` — the raw four-character code, because no case in
  `CameraDetail.describe(transport:)` named USB — while the switch compared against
  `"USB"`. The setting did nothing whatsoever. Pinned now by a test on the spelling itself,
  and the comparison is case-insensitive so it cannot break the same way twice.
- The disconnection consulted only whether the *arrival* had been suppressed, so switching
  the setting off while a device was already connected leaked that device's departure.
  Fixed by remembering how each device attaches and judging the departure against the
  settings as they stand. Covered by
  `turningUSBOffAlsoSilencesAnAlreadyConnectedCamera`.

**How to settle it.** Quit HG4MAC, relaunch HardwareSentry with the camera connected and
the switch off, and watch whether a banner appears at all at launch and on the first
unplug. That separates candidate 1 from the rest in one pass.
