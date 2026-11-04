#!/usr/bin/env python3
"""Per-key temperature attribution from a timeline.sh run.
Usage: c7keys.py <dir> <comma-separated CPU keys the app uses>
Prints: engine CPU/GPU max under each load, and unused keys that are CPU-biased (rise under CPU load >= rise
under GPU load, rise >= 5 C) and read hotter than the app's CPU max during the CPU load."""
import json, sys
D, used = sys.argv[1], set(sys.argv[2].split(","))
ev = {l.split()[1]: float(l.split()[0]) for l in open(f"{D}/events.txt")}
snaps = [r for r in (json.loads(l) for l in open(f"{D}/engine.jsonl")) if r.get("type") == "snapshot"]
def emax(k, a, b): return max((s[k]["peak"] for s in snaps if a <= s["timestamp"] <= b and s.get(k)), default=float("nan"))
cl = (ev["cpuload-start"], ev["cpuload-end"] + 4); gl = (ev["gpuload-start"], ev["gpuload-end"] + 4)
print(f"engine under CPU load: CPU max {emax('cpuTemp', *cl):.1f}  GPU max {emax('gpuTemp', *cl):.1f}")
print(f"engine under GPU load: CPU max {emax('cpuTemp', *gl):.1f}  GPU max {emax('gpuTemp', *gl):.1f}")
smc = []
for line in open(f"{D}/smc.txt"):
    if line.startswith("== "): smc.append((float(line.split()[1]), {})); continue
    p = line.rstrip("\n").split("\t")
    if len(p) == 3 and smc: smc[-1][1][p[1]] = float(p[2])
w = lambda a, b: [m for t, m in smc if a <= t <= b]
rest, C, G = w(ev["start"] + 8, ev["cpuload-start"]), w(ev["cpuload-start"], ev["cpuload-end"] + 2), w(ev["gpuload-start"], ev["gpuload-end"] + 2)
appmax = emax("cpuTemp", *cl)
rows = []
for k in rest[0]:
    if not k.startswith(("Tp", "Te", "Tf", "Ts", "Tm")): continue
    r = sum(m[k] for m in rest) / len(rest); c = max(m[k] for m in C); g = max(m[k] for m in G)
    if not 0.5 <= r <= 150: continue
    rows.append((k, r, c, g, c - r, g - r))
usedrows = [x for x in rows if x[0] in used]
print("used keys (rest, cpuLoadMax, gpuLoadMax, riseCPU, riseGPU):")
for x in sorted(usedrows): print("   %s %.1f %.1f %.1f %+.1f %+.1f" % x)
miss = [x for x in rows if x[0] not in used and x[4] >= 5 and x[4] >= x[5] and x[2] > appmax]
print(f"unused CPU-biased keys hotter than app CPU max {appmax:.1f} under CPU load: {len(miss)}")
for x in sorted(miss, key=lambda x: -x[2])[:12]: print("   %s %.1f %.1f %.1f %+.1f %+.1f" % x)
hot = [x for x in rows if x[0] not in used and x[2] > appmax]
print(f"all unused keys hotter than app CPU max under CPU load: {len(hot)} (of which GPU-biased {sum(1 for x in hot if x[5] > x[4])})")
