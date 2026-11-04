#!/usr/bin/env python3
"""Analyse a procs.sh run. Usage: analyze_procs.py <out dir>"""
import json, sys
D = sys.argv[1]
ev = {}
for l in open(f"{D}/events.txt"):
    p = l.split(); ev[p[1]] = float(p[0])
ncpu = int(open(f"{D}/events.txt").readline().split("ncpu=")[1])
snaps = [r for r in (json.loads(l) for l in open(f"{D}/engine.jsonl")) if r.get("type") == "snapshot"]
single, long_ = int(open(f"{D}/single.pid").read()), int(open(f"{D}/long.pid").read())
ps = []
for block in open(f"{D}/ps.txt").read().split("== ")[1:]:
    lines = block.splitlines(); t = float(lines[0]); rows = {}
    for l in lines[1:]:
        p = l.split(None, 2)
        if len(p) == 3: rows[int(p[0])] = (int(p[1]) * 1024, p[2])
    ps.append((t, rows))
def rows_for(pid): return [(s["timestamp"], p) for s in snaps for p in s["topProcesses"] if p["pid"] == pid]
def cpu_at(t0, t1): v = [s["cpuPercent"] for s in snaps if t0 <= s["timestamp"] <= t1 and s["cpuPercent"] is not None]; return sum(v) / len(v)

print(f"== {D} ncpu={ncpu} snapshots={len(snaps)}")
base = cpu_at(ev["start"] + 4, ev["single-start"]); during = cpu_at(ev["single-start"] + 8, ev["single-end"])
print(f"B3 machine CPU base {base:.1f} -> single-thread {during:.1f}: rise {during-base:.1f} pp (expected {100/ncpu:.1f} ± 5)")
r = rows_for(single)
first = r[0][0] - ev["single-start"] if r else None
rank1 = [s["timestamp"] - ev["single-start"] for s in snaps if s["topProcesses"] and s["topProcesses"][0]["pid"] == single]
print(f"B7 single spin: first in top-3 after {first and round(first,1)} s; first #1 after {rank1 and round(rank1[0],1)} s; values {sorted({round(p['cpuPercent'],1) for _, p in r})}")
for t, p in r[-1:]:
    near = min(ps, key=lambda x: abs(x[0] - t))[1].get(single)
    print(f"B9 single spin RSS engine {p['residentBytes']} vs ps {near and near[0]}")
# B9 on bigger processes at rest: compare every engine row pid with nearest ps sample
diffs = []
for s in snaps:
    near = min(ps, key=lambda x: abs(x[0] - s["timestamp"]))[1]
    for p in s["topProcesses"]:
        if p["pid"] in near and near[p["pid"]][0] > 50e6:
            diffs.append((p["name"], p["residentBytes"] / near[p["pid"]][0]))
worst = sorted(diffs, key=lambda x: abs(1 - x[1]))[-3:]
print(f"B9 RSS engine/ps ratio for rows > 50 MB: n={len(diffs)} min={min(x[1] for x in diffs):.2f} max={max(x[1] for x in diffs):.2f} worst={worst}")
r = rows_for(long_)
print(f"G2 4-thread row values {sorted({round(p['cpuPercent'],1) for _, p in r})}")
print(f"G3 long name shown: {sorted({p['name'] for _, p in r})}")
after = [s for s in snaps if s["timestamp"] >= ev["long-end"]]
gone = next((s["timestamp"] - ev["long-end"] for s in after if all(p["pid"] != long_ for p in s["topProcesses"])), None)
print(f"G4 long process left top-3 {gone and round(gone,1)} s after exit")
ch = [s for s in snaps if ev["churn-start"] <= s["timestamp"] <= ev["churn-end"] + 5]
names = {p["name"] for s in ch for p in s["topProcesses"]}
gaps = [b["timestamp"] - a["timestamp"] for a, b in zip(ch, ch[1:])]
print(f"G1 churn: publications {len(ch)}, max gap {max(gaps):.1f} s, names {sorted(names)}, empty names {sum(1 for n in names if not n.strip())}")
print(f"G1 churn machine CPU mean {cpu_at(ev['churn-start'], ev['churn-end']):.1f}")
summary = [json.loads(l) for l in open(f"{D}/engine.jsonl") if '"summary"' in l]
print("engine summary", summary[-1] if summary else None)
