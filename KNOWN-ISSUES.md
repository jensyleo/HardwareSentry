# Known issues

Small, understood defects that are not worth holding a release for, kept here so they are
not rediscovered from scratch. Anything larger belongs in the code it affects.

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
