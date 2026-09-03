#!/bin/bash
# Checks HardwareSentry still covers everything HG4MAC can notify about.
#
# Written because every parity gap found during this rewrite was the same mistake: a
# module believed finished, because somebody read the code and thought it looked complete.
# Reading is not a check. This asks both codebases what they actually declare.
#
#   Tools/parity-audit.sh [path-to-HG4MAC]
#
# Exits non-zero if the original can raise a notification this application cannot, or if a
# module or event would show without an icon. Extra events here are reported, not failed:
# being ahead is allowed.
set -uo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
original="${1:-$here/../HG4MAC}"

if [ ! -d "$original" ]; then
    echo "HG4MAC not found at $original — pass its path as the first argument." >&2
    exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

# --- What the original declares -------------------------------------------------------
#
# Three sources, unioned. `noteNames` is the list it registers, and would be the obvious
# single source — except that it is out of date in the original: PowerBatteryHealth and
# PowerLowPowerMode are raised without being registered there. So the literals actually
# passed to the notification call count too.
find "$original" -name "HWGrowl*Monitor.m" | while read -r file; do
    {
        awk '/^- *\(NSArray *\*?\) *noteNames/,/^}/' "$file" | grep -oE '@"[A-Za-z0-9_]+"'
        grep -oE 'notifyWithName:@"[A-Za-z0-9_]+"' "$file" | sed 's/notifyWithName://'
        grep -oE 'noteName *= *@"[A-Za-z0-9_]+"' "$file" | sed 's/.*= *//'
    } | sed 's/@"//;s/"//'
done | sort -u | grep -v '^$' > "$work/original.txt"

# --- What this application declares ---------------------------------------------------
#
# Asked of the built catalogue rather than grepped out of Swift, so what is checked is
# what the preferences screen shows and the dispatcher can raise.
(cd "$here/HardwareSentryCore" && swift run -q sentry-inventory) > "$work/inventory.json" || {
    echo "could not build the inventory dump" >&2
    exit 2
}

# Second axis: the optional lines. Every "show this too" preference the original offers
# must have somewhere to come from here.
grep -rhE '#define HWG_[A-Z0-9_]*SHOW_[A-Z0-9_]+_KEY' $(find "$original" -name "*.h" -o -name "*.m") \
    | sed -E 's/#define (HWG_[A-Z0-9_]+_KEY).*/\1/' | sort -u > "$work/original-fields.txt"

# Third axis: the tuning knobs. Everything the original stores that is not a "show this"
# or a "notify me" — intervals, thresholds, modes, remembered dates.
grep -rhE '^#define HWG_[A-Z0-9_]+ +@"' $(find "$original" -name "*.h" -o -name "*.m") \
    | sed -E 's/#define HWG_[A-Z0-9_]+ +@"([^"]*)".*/\1/' \
    | grep -vE '^HWG[A-Za-z]*(Show|Notify)' | sort -u > "$work/original-settings.txt"

python3 - "$work/inventory.json" "$work/original.txt" "$here/Tools/parity-map.tsv" "$work/original-fields.txt" "$here/Tools/parity-fields.tsv" "$work/original-settings.txt" "$here/Tools/parity-settings.tsv" "$here" <<'PYEOF'
import json, re, subprocess, sys

inventory, original_path, map_path, fields_path, fields_map_path = sys.argv[1:6]
settings_path, settings_map_path, root = sys.argv[6:9]
data = json.load(open(inventory))

mine = {e["name"] for m in data["modules"] for e in m["events"]}
original = {line.strip() for line in open(original_path) if line.strip()}

covered_by = {}
for line in open(map_path):
    if line.startswith("#") or not line.strip():
        continue
    parts = line.rstrip("\n").split("\t")
    covered_by[parts[0]] = [n for n in parts[1].split(",") if n]

problems = []

# 1. Nothing the original can say may be unsayable here.
for name in sorted(original):
    if name in mine:
        continue
    replacements = covered_by.get(name)
    if replacements is None:
        problems.append(f"MISSING  {name} — no event of this name and no entry in parity-map.tsv")
        continue
    absent = [r for r in replacements if r not in mine]
    if absent:
        problems.append(f"MISSING  {name} — mapped to {', '.join(absent)}, which do not exist")

# 2. A module or event without an icon shows blank in the list. This regressed in five
#    modules during the rewrite, each time because the icon was inferred from the first
#    event and grouping changed which event was first.
for module in data["modules"]:
    if not module["hasDeclaredIcon"]:
        problems.append(f"NO ICON  module {module['category']}")
    for event in module["events"]:
        if not event["hasIcon"]:
            problems.append(f"NO ICON  {module['category']}.{event['name']}")

# --- The optional lines ---------------------------------------------------------------
#
# The original names its preference keys by module prefix, so which module a key belongs
# to is read off the key itself. Two prefixes are sub-groups of one module (POWER_ADAPTER
# under Power, VOLUME_LOWSPACE under Volume) and three are the one Network module split
# the way the original's tabs split it.
module_of_prefix = {
    "USB": "USB", "BT": "Bluetooth", "DISPLAY": "Display", "POWER": "Power",
    "POWER_ADAPTER": "Power", "CAMERA": "Camera", "WIFI": "Network", "IP": "Network",
    "ETH": "Network", "VOLUME": "Volume", "VOLUME_LOWSPACE": "Volume",
    "GAMEPAD": "Gamepad", "AUDIO": "Audio", "PRINTER": "Printer", "TB": "Thunderbolt",
    "THERMAL": "Thermal", "SCANNER": "Scanner",
}

fields_by_module = {m["category"]: [f["name"] for f in m["fields"]] for m in data["modules"]}
events_by_module = {m["category"]: [e["name"] for e in m["events"]] for m in data["modules"]}

field_map = {}
for line in open(fields_map_path):
    if line.startswith("#") or not line.strip():
        continue
    key, target = line.rstrip("\n").split("\t")[:2]
    field_map[key] = target

def flatten(name):
    return re.sub(r"[^a-z0-9]", "", name.lower())

original_fields = [line.strip() for line in open(fields_path) if line.strip()]
for key in original_fields:
    match = re.match(r"HWG_(.+)_SHOW_(.+)_KEY", key)
    if not match:
        continue
    prefix, rest = match.group(1), match.group(2)
    module = module_of_prefix.get(prefix)
    if module is None:
        problems.append(f"UNKNOWN  {key} — prefix {prefix} is not mapped to a module")
        continue

    candidates = fields_by_module.get(module, []) + events_by_module.get(module, [])
    named = field_map.get(key)
    if named is not None:
        if named not in candidates:
            problems.append(f"MISSING  {key} — mapped to {module}.{named}, which does not exist")
        continue

    wanted = flatten(rest)
    if any(flatten(c) == wanted for c in candidates):
        continue
    if any(wanted in flatten(c) or flatten(c) in wanted for c in candidates):
        continue
    problems.append(
        f"MISSING  {key} — no {module} field or event resembles it, and no entry in parity-fields.tsv"
    )

# --- The tuning knobs -----------------------------------------------------------------
settings_map = {}
for line in open(settings_map_path):
    if line.startswith("#") or not line.strip():
        continue
    parts = line.rstrip("\n").split("\t")
    settings_map[parts[0]] = parts[1] if len(parts) > 1 else ""

original_settings = [line.strip() for line in open(settings_path) if line.strip()]
todo_settings = []
for key in original_settings:
    target = settings_map.get(key)
    if target is None:
        problems.append(f"MISSING  {key} — a setting with no counterpart and no entry in parity-settings.tsv")
        continue
    if target in ("-", ""):
        continue
    if target == "TODO":
        todo_settings.append(key)
        continue
    # A key nothing reads is a knob that cannot be turned: the class of gap this axis
    # exists to catch. So the check is that the name appears in the source, not merely
    # that somebody wrote it down here.
    found = subprocess.run(
        ["grep", "-rq", target, f"{root}/HardwareSentry", f"{root}/HardwareSentryCore/Sources"],
        capture_output=True,
    ).returncode == 0
    if not found:
        problems.append(f"MISSING  {key} — mapped to {target}, which appears nowhere in the source")

mapped = {r for rs in covered_by.values() for r in rs}
extra = sorted(mine - original - mapped)

print(f"HG4MAC declares      {len(original)} notifications")
print(f"HardwareSentry has   {len(data['modules'])} modules, {data['eventCount']} events, {data['fieldCount']} optional body fields")
print(f"covered by name      {len(original & mine)}")
print(f"covered by mapping   {len(covered_by)} original names -> {len(mapped)} finer-grained events")
print(f"tuning knobs         {len(original_settings)} settings in HG4MAC")
print(f"optional lines       {len(original_fields)} preference keys in HG4MAC, all accounted for" if not [p for p in problems if p.startswith(("MISSING  HWG", "UNKNOWN"))] else f"optional lines       {len(original_fields)} preference keys in HG4MAC")
print()

if todo_settings:
    print(f"{len(todo_settings)} settings implemented but not yet reachable from the settings window:")
    for key in todo_settings:
        print(f"  TODO  {key}")
    print()

if extra:
    print(f"{len(extra)} events with no counterpart in HG4MAC (additions, not failures):")
    for name in extra:
        print(f"  +  {name}")
    print()

if problems:
    print(f"{len(problems)} problems:")
    for problem in problems:
        print(f"  {problem}")
    sys.exit(1)

print("No gaps: every notification HG4MAC can raise, this application can raise.")
PYEOF
