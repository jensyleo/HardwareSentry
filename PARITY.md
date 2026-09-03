# Parity with HG4MAC

HardwareSentry is a rewrite, not a port: no code is shared with HG4MAC, and the modules
were written one at a time against macOS APIs directly. That raises an obvious question —
whether anything was lost on the way — and the honest answer for most of this rewrite was
that nobody could say, because the only check being applied was somebody reading the code
and judging it complete. Every gap found during the work was found that way and only after
the module had already been called finished.

So the check is mechanical now.

## Running it

```
Tools/parity-audit.sh [path-to-HG4MAC]
```

It exits non-zero when the original can do something this application cannot. Being ahead
is reported but never fails.

It reads HG4MAC's Objective-C sources and this application's own catalogue — the same list
the settings window renders, dumped as JSON by the `sentry-inventory` executable — so what
is compared is what each application actually declares, not what a summary says it does.

Three axes, matching the three kinds of thing that can go missing:

| Axis | What it checks | Map file for deliberate differences |
|---|---|---|
| Notifications | every notification HG4MAC can raise can be raised here | `Tools/parity-map.tsv` |
| Optional lines | every "show this too" preference has somewhere to come from | `Tools/parity-fields.tsv` |
| Tuning | every interval, threshold, mode and remembered date is reachable | `Tools/parity-settings.tsv` |

It also fails on a module or event with no icon, which is not a parity question but the
regression that recurred in five modules: the icon used to be inferred from a module's
first event, so changing the order of the list silently changed the icon.

## Where it stands

```
HG4MAC declares      106 notifications
HardwareSentry has   13 modules, 194 events, 170 optional body fields
covered by name      101
covered by mapping   5 original names -> 16 finer-grained events
tuning knobs         13 settings in HG4MAC, all reachable
optional lines       148 preference keys in HG4MAC, all accounted for
```

No gaps on any axis. 77 events have no counterpart in HG4MAC at all.

## The five notifications that are not name-for-name

Four of them are one switch here becoming several, which is the point: a single "the
signal changed" cannot express "tell me when I am about to lose the connection, and not
every time it wobbles".

- `AirportSignalChange` → five Wi-Fi strength bands
- `BluetoothSignalChange` → five bands, for paired devices
- `ThermalStateChanged` → the four pressure levels
- `DarkWakeThermalEmergency` → `ThermalDarkWakeEmergency`, for the module's prefix
- `AudioMicInUse` → `AudioMicInUseChanged`, because it fires when the microphone stops
  being used as well, which the original name reads as only the former

The same idea explains most of the additions: USB, Thunderbolt, Volume and Bluetooth
announce what kind of thing was plugged in, and Power has a row per ten percent, so
"tell me at twenty percent" is a checkbox rather than a wish.

## Where this application is deliberately not identical

- **`transmitPower` is not in dBm.** CoreWLAN returns milliwatts; the original labels it
  dBm, which makes a normal reading print as an impossible one.
- **Battery health is checked in days, not months-plus-unit.** The original's pair let
  somebody choose "0 months", which means never without saying so.
- **The experimental video-link detection has no switch of its own.** Its notification's
  checkbox is the switch: with the notification off the detector never starts, so two
  controls could not disagree about whether it is running.
- **Volumes can be ignored individually.** A Time Machine disk that mounts on a schedule
  used to cost either its notifications or every other volume's.

## What this does not prove

Parity of declarations is not parity of behaviour, and the audit cannot see the following.
They are checked by hand, and the ones needing hardware are still open:

- **Not verifiable on this machine**: NVMe SMART attributes (this M4 exposes an Apple
  Fabric controller with no `IONVMeController`), printer notifications (no printer has
  ever been added — `lpstat -p` reports no destinations), network scanner discovery (no
  scanner on this network).
- **Needs a person and a cable**: walking out of Wi-Fi range, plugging and unplugging a
  disk, pairing headphones, connecting an external display.
- **Private API**: AirPods battery level is read through public IORegistry properties
  where they exist and guarded private selectors otherwise. If Apple removes them the
  battery line stops appearing and nothing else changes.

## What was measured

Both applications launched together on the same Mac, announcing the same hardware, then
left running for two minutes:

| | HG4MAC | HardwareSentry |
|---|---|---|
| CPU over two idle minutes | 0.42 s | 0.37 s |
| Resident memory, at launch | 130 MB | 95 MB |
| Resident memory, two minutes later | 138 MB | 81 MB |

Close enough that neither is a reason to choose one over the other; worth recording mainly
because a rewrite that had accidentally left a busy loop running would show up here.
