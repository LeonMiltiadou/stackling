#!/bin/bash
# Summarises Stackling's activity log: what gets used, how, and what never does.
#   scripts/activity.sh          everything logged
#   scripts/activity.sh 7        the last 7 days
# Turn the log on in Settings › General › "Keep an activity log on this Mac".
set -eu
LOG="${STACKLING_ACTIVITY_LOG:-$HOME/Library/Application Support/io.github.leonmiltiadou.stackling/activity.jsonl}"
[ -f "$LOG" ] || { echo "No activity log yet at: $LOG"; echo "Turn it on in Stackling › Settings › General."; exit 1; }
exec python3 - "$LOG" "${1:-0}" <<'PY'
import json, sys, statistics
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone

path, days = sys.argv[1], int(sys.argv[2])
events = []
for line in open(path, encoding="utf-8"):
    try:
        e = json.loads(line)
        e["_t"] = datetime.fromisoformat(e["t"])
        events.append(e)
    except Exception:
        pass
if days:
    since = datetime.now(timezone.utc).astimezone() - timedelta(days=days)
    events = [e for e in events if e["_t"] >= since]
if not events:
    sys.exit("Nothing logged in that period.")

def bar(n, total, width=24):
    return "█" * max(1, round(width * n / total)) if total and n else ""

def secs(s):
    s = int(s)
    return f"{s} s" if s < 90 else f"{s // 60} min" if s < 5400 else f"{s // 3600} h"

catalogue = set()
for e in events:
    if e["e"] == "app.launch":
        catalogue |= set(e.get("catalogue", []))
by = defaultdict(list)
for e in events:
    by[e["e"]].append(e)

first, last = events[0]["_t"], events[-1]["_t"]
active_days = len({e["_t"].date() for e in events})
print(f"\nStackling activity · {first:%d %b} → {last:%d %b} · {active_days} active day(s) · {len(events)} events\n")

# Captures
done = by["capture.done"]
modes = Counter(e.get("mode") + (" (recording)" if e.get("purpose") == "recording" else "") for e in done)
native = len(by["capture.native"])
cancelled = len(by["capture.cancel"])
total_caps = len(done) + native
print(f"CAPTURES  {total_caps} total, {total_caps / max(active_days, 1):.0f} a day")
for mode, n in modes.most_common():
    print(f"  {mode:<24}{n:>5}  {bar(n, total_caps)}")
if native:
    print(f"  {'macOS shortcuts':<24}{native:>5}  {bar(native, total_caps)}")
if done or cancelled:
    choose = [e["ms"] / 1000 for e in done if e.get("ms")]
    print(f"  cancelled {cancelled} of {len(done) + cancelled} started"
          + (f" · median time to choose {statistics.median(choose):.1f} s" if choose else ""))
apps = Counter(e.get("app") or "?" for e in by["shot.new"])
if apps:
    print("  taken in: " + " · ".join(f"{a} {n}" for a, n in apps.most_common(6)))

# What happens to each shot
ACTIONS = {"shot.copy", "shot.copy-text", "shot.copy-gif", "shot.copy-path", "shot.drag", "shot.edit", "shot.preview",
           "shot.pin", "shot.keep", "shot.dismiss", "shot.trash", "shot.file", "shot.share", "shot.move-to",
           "shot.save-gif", "shot.name-claude", "shot.flatten", "shot.open-in-app", "shot.reveal"}
new_ids = {e.get("shot") for e in by["shot.new"] if e.get("shot")}
firsts = {}
for e in events:
    sid = e.get("shot")
    if sid in new_ids and e["e"] in ACTIONS and sid not in firsts:
        firsts[sid] = e
filed_auto = {e.get("shot") for e in by["autofile"] if e.get("outcome") == "filed"}
if new_ids:
    outcome = Counter(firsts[s]["e"].removeprefix("shot.") if s in firsts else "nothing yet" for s in new_ids)
    print(f"\nFIRST THING DONE WITH A NEW SHOT  ({len(new_ids)} shots)")
    for what, n in outcome.most_common():
        ages = [firsts[s]["age"] for s in new_ids if s in firsts and firsts[s]["e"] == "shot." + what and "age" in firsts[s]]
        hows = Counter(firsts[s].get("via", "click") for s in new_ids if s in firsts and firsts[s]["e"] == "shot." + what)
        detail = (f"median {secs(statistics.median(ages))} after" if ages else "")
        if hows:
            detail += "   " + " · ".join(f"{h} {c}" for h, c in hows.most_common())
        print(f"  {what:<14}{n:>5}  {round(100 * n / len(new_ids)):>3}%  {bar(n, len(new_ids), 16):<16}  {detail}")

# Everything, by use
print("\nEVERYTHING USED  (count · how it was started)")
counts = Counter(e["e"] for e in events if e["e"] not in {"app.launch", "app.quit"})
for name, n in counts.most_common():
    hows = Counter(e.get("via", "-") for e in by[name])
    how = " · ".join(f"{h} {c}" for h, c in hows.most_common(4)) if len(hows) > 1 or "-" not in hows else ""
    print(f"  {name:<24}{n:>5}   {how}")

never = sorted(catalogue - set(counts) - {"app.launch", "app.quit"})
if never:
    print(f"\nNEVER USED  ({len(never)} of {len(catalogue) - 2})")
    for i in range(0, len(never), 4):
        print("  " + "   ".join(f"{n:<22}" for n in never[i:i + 4]))

# A few closer looks
lib_open = by["library.open"]
if lib_open or by["library.search"]:
    searches = by["library.search"]
    empty = sum(1 for e in searches if e.get("results") == 0)
    how = Counter(e.get("via", "-") for e in lib_open)
    print(f"\nLIBRARY  opened {len(lib_open)} ({' · '.join(f'{h} {c}' for h, c in how.most_common())})"
          f" · {len(searches)} searches, {empty} found nothing")
sessions = by["editor.close"]
if sessions:
    tools = Counter()
    for e in sessions:
        tools.update(e.get("tools", {}))
    hows = Counter(e.get("how") for e in sessions)
    beautified = sum(1 for e in sessions if e.get("beautify"))
    print(f"EDITOR   {len(sessions)} sessions, left by {' · '.join(f'{h} {c}' for h, c in hows.most_common())}"
          f" · beautify {beautified} · tools: {' · '.join(f'{t} {c}' for t, c in tools.most_common()) or 'none'}")
auto = Counter(e.get("outcome") for e in by["autofile"])
if auto:
    conf = [e["confidence"] for e in by["autofile"] if "confidence" in e]
    print(f"AUTO-FILE {' · '.join(f'{o} {c}' for o, c in auto.most_common())}"
          + (f" · median confidence {statistics.median(conf):.0%}" if conf else ""))
cleared = sum(e.get("count", 0) for e in by["cleanup"])
if cleared:
    print(f"CLEAN-UP cleared {cleared} shot(s)")
changed = Counter(e.get("name") for e in by["settings.change"])
if changed:
    print("SETTINGS changed: " + " · ".join(f"{k} {c}" for k, c in changed.most_common()))
print()
PY
