#!/usr/bin/env python3
"""E4: EngineDump --json --seconds 24 --pause-at 6 --resume-after 6 output on stdin."""
import json, sys
rows = [json.loads(l) for l in sys.stdin if l.startswith("{")]
ev = {r["event"]: r["elapsed"] for r in rows if r.get("type") == "event"}
snaps = [r for r in rows if r.get("type") == "snapshot"]
during = [s for s in snaps if ev["pause"] < s["elapsed"] < ev["resume"]]
after = [s for s in snaps if s["elapsed"] > ev["resume"]]
first = after[0] if after else None
print(f"pause {ev['pause']:.2f}s resume {ev['resume']:.2f}s; publications while paused: {len(during)}; "
      f"first after resume +{first['elapsed'] - ev['resume']:.2f}s cpu={first['cpuPercent']}" if first else "no publication after resume")
ok = not during and first and first["elapsed"] - ev["resume"] <= 4 and (first["cpuPercent"] is None or 0 <= first["cpuPercent"] <= 100)
print("E4", "PASS" if ok else "FAIL")
