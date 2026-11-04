#!/usr/bin/env python3
"""Analyse a timeline.sh run: engine vs independent references. Usage: analyze.py <out dir>"""
import json, re, sys, time, statistics as st
from collections import defaultdict

D = sys.argv[1]
ev = {}
for line in open(f"{D}/events.txt"):
    t, name = line.split()[:2]
    ev[name] = float(t)
ncpu = int(open(f"{D}/events.txt").readline().split("ncpu=")[1])

snaps = []
for line in open(f"{D}/engine.jsonl"):
    try:
        r = json.loads(line)
    except ValueError:
        continue
    if r.get("type") == "snapshot":
        snaps.append(r)
if not snaps:
    sys.exit("no engine snapshots")
# EngineDump timestamps are wall-clock epoch seconds of the snapshot.
def state_at(t):
    cur = None
    for s in snaps:
        if s["timestamp"] <= t: cur = s
        else: break
    return cur
def series(t0, t1, f, step=1.0):
    out, t = [], t0
    while t <= t1:
        s = state_at(t)
        v = f(s) if s else None
        if v is not None: out.append(v)
        t += step
    return out
def mean(xs): return st.mean(xs) if xs else float("nan")

# ---- top ----
tops = []  # (t, user+sys, [(pid, cmd, cpu, rsize)])
cur = None
for line in open(f"{D}/top.txt"):
    m = re.match(r"(\d{4}/\d\d/\d\d \d\d:\d\d:\d\d)", line)
    if m:
        cur = {"t": time.mktime(time.strptime(m.group(1), "%Y/%m/%d %H:%M:%S")), "rows": []}
        tops.append(cur); continue
    m = re.match(r"CPU usage: ([\d.]+)% user, ([\d.]+)% sys", line)
    if m and cur: cur["cpu"] = float(m.group(1)) + float(m.group(2)); continue
    m = re.match(r"^(\d+)\s+(.+?)\s+([\d.]+)\s+(\S+)\s*$", line)
    if m and cur: cur["rows"].append((int(m.group(1)), m.group(2).strip(), float(m.group(3)), m.group(4)))
tops = tops[1:]  # first sample's CPU line is not an interval measurement
def top_in(t0, t1): return [x for x in tops if t0 <= x["t"] <= t1 and "cpu" in x]

gpu = []
for line in open(f"{D}/gpu.txt"):
    m = re.match(r"([\d.]+) \"Device Utilization %\"=(\d+)", line)
    if m: gpu.append((float(m.group(1)), float(m.group(2))))
def gpu_in(t0, t1): return [v for t, v in gpu if t0 <= t <= t1]

smc = []  # (t, {key: value})
for line in open(f"{D}/smc.txt"):
    if line.startswith("== "): smc.append((float(line.split()[1]), {})); continue
    p = line.rstrip("\n").split("\t")
    if len(p) == 3 and smc: smc[-1][1][p[1]] = float(p[2])

R = {}
def report(k, v): R[k] = v; print(f"{k}: {v}")

rest = (ev["start"] + 8, ev["cpuload-start"])
cpuL = (ev["cpuload-start"] + 8, ev["cpuload-end"])
cool1 = (ev["cpuload-end"], ev["gpuload-start"])
gpuL = (ev["gpuload-start"] + 6, ev["gpuload-end"])
gpuL_eng = (ev["gpuload-start"] + 6, ev["gpuload-end"] + 4)
cpuL_eng = (ev["cpuload-start"] + 6, ev["cpuload-end"] + 4)

print(f"== {D}  ncpu={ncpu}  snapshots={len(snaps)}  top samples={len(tops)}")
# B1/B2 CPU
e_rest = series(*rest, lambda s: s["cpuPercent"]); t_rest = [x["cpu"] for x in top_in(*rest)]
e_load = series(*cpuL, lambda s: s["cpuPercent"]); t_load = [x["cpu"] for x in top_in(*cpuL)]
report("B1 cpu rest engine/top mean", f"{mean(e_rest):.1f} / {mean(t_rest):.1f} (diff {abs(mean(e_rest)-mean(t_rest)):.1f} pp)")
report("B2 cpu load engine/top mean", f"{mean(e_load):.1f} / {mean(t_load):.1f} (diff {abs(mean(e_load)-mean(t_load)):.1f} pp)")
# B4 GPU
ge_rest = series(*rest, lambda s: s["gpuPercent"]); gi_rest = gpu_in(*rest)
ge_load = series(*gpuL, lambda s: s["gpuPercent"]); gi_load = gpu_in(*gpuL)
report("B4 gpu rest engine/ioreg mean", f"{mean(ge_rest):.1f} / {mean(gi_rest):.1f}")
report("B4 gpu load engine/ioreg mean", f"{mean(ge_load):.1f} / {mean(gi_load):.1f}")

# B5 memory vs vm_stat
memsize, page = [int(x) for x in open(f"{D}/mem.txt").read().split()]
blocks = open(f"{D}/vm.txt").read().split("== ")[1:]
diffs = []
for b in blocks:
    lines = b.splitlines(); t = float(lines[0])
    vals = {}
    for l in lines[1:]:
        m = re.match(r"(.+?):\s+(\d+)\.", l)
        if m: vals[m.group(1)] = int(m.group(2))
    ps = int(re.search(r"page size of (\d+)", b).group(1))
    used = (vals["Pages wired down"] + vals["Pages active"] + vals["Pages occupied by compressor"]) * ps
    s = state_at(t)
    if s and s.get("memory"):
        diffs.append((s["memory"]["used"] - used) / memsize * 100)
        last = (s["memory"], used)
report("B5 memory total engine/hw.memsize", f"{snaps[-1]['memory']['total']} / {memsize} equal={snaps[-1]['memory']['total']==memsize}")
report("B5 memory used diff % of total (per vm_stat block)", " ".join(f"{d:+.2f}" for d in diffs))
report("B5 memory last engine used/vm_stat used GB", f"{last[0]['used']/2**30:.2f} / {last[1]/2**30:.2f}")
# B6 disk
dk = snaps[-1]["disk"]; dtxt = open(f"{D}/disk.txt").read()
dfl = [l for l in dtxt.splitlines() if l.endswith(" /") or l.split()[-1:] == ["/"]]
dfp = dfl[0].split()
df_total, df_avail = int(dfp[1]) * 1024, int(dfp[3]) * 1024
ct = re.search(r"Container Total Space:.*?\((\d+) Bytes\)", dtxt)
cf = re.search(r"Container Free Space:.*?\((\d+) Bytes\)", dtxt)
report("B6 disk engine total/free/name", f"{dk['total']/1e9:.1f} GB / {dk['free']/1e9:.1f} GB / {dk['volumeName']}")
report("B6 disk df total/avail", f"{df_total/1e9:.1f} / {df_avail/1e9:.1f} GB")
if ct: report("B6 disk diskutil container total/free", f"{int(ct.group(1))/1e9:.1f} / {int(cf.group(1))/1e9:.1f} GB")

# B7/B8 processes
def eng_rows(t0, t1):
    seen = []
    for s in snaps:
        if t0 <= s["timestamp"] <= t1: seen.append([(p["pid"], p["name"], round(p["cpuPercent"], 1)) for p in s["topProcesses"]])
    return seen
load_rows = eng_rows(*cpuL_eng)
report("B7 engine top rows during CPU load (last)", load_rows[-1] if load_rows else None)
rest_rows = eng_rows(*rest)
top5 = set()
for x in top_in(*rest): top5 |= {r[0] for r in x["rows"][:5]}
if rest_rows:
    last = rest_rows[-1]
    report("B7 rest engine rows (last)", last)
    report("B7 rest engine pids in top's top-5 (any sample)", f"{sum(1 for p in last if p[0] in top5)}/3")
allnames = {p["name"] for s in snaps for p in s["topProcesses"]}
report("B8 WindowServer in any engine row", "WindowServer" in allnames)
report("B8 WindowServer in top's top-3 at rest (samples)", sum(1 for x in top_in(*rest) if any(r[1].startswith("WindowServer") for r in x["rows"][:3])))
report("B10 header", f"{snaps[-1]['machineName']} · {snaps[-1]['chipName']}")
th = [l.split()[1] for l in open(f"{D}/thermal.txt")]
report("B11 thermal engine values / os values", f"{sorted({s['thermal'] for s in snaps if s['thermal']})} / {sorted(set(th))}")

# C temps
def tseries(key, rng): return series(*rng, lambda s: s[key]["peak"] if s.get(key) else None)
cpu_pre = mean(tseries("cpuTemp", rest)); cpu_max = max(tseries("cpuTemp", cpuL_eng) or [float("nan")])
tail = (ev["gpuload-start"] - 20, ev["gpuload-start"])
cpu_after = mean(tseries("cpuTemp", tail))
gpu_pre = mean(tseries("gpuTemp", (ev["gpuload-start"] - 20, ev["gpuload-start"])))
gpu_max = max(tseries("gpuTemp", gpuL_eng) or [float("nan")])
counts = [sorted({str((s[k] or {}).get("sensorCount")) for s in snaps}) for k in ("cpuTemp", "gpuTemp")]
report("C2/C3 sensorCount cpu/gpu", counts)
report("C4 cpu peak pre / load max / 40-60 s after", f"{cpu_pre:.1f} / {cpu_max:.1f} (+{cpu_max-cpu_pre:.1f}) / {cpu_after:.1f} (-{cpu_max-cpu_after:.1f})")
report("C5 gpu peak pre / load max", f"{gpu_pre:.1f} / {gpu_max:.1f} (+{gpu_max-gpu_pre:.1f})")
allt = [v for s in snaps for k in ("cpuTemp", "gpuTemp") if s.get(k) for v in (s[k]["peak"], s[k]["average"])]
bad = [s for s in snaps for k in ("cpuTemp", "gpuTemp") if s.get(k) and s[k]["average"] > s[k]["peak"]]
report("C6 temp range all published", f"{min(allt):.1f}..{max(allt):.1f}  avg>peak count={len(bad)}")
cavg_pre = mean(series(*rest, lambda s: s["cpuTemp"]["average"] if s.get("cpuTemp") else None))
cavg_max = max(series(*cpuL_eng, lambda s: s["cpuTemp"]["average"] if s.get("cpuTemp") else None) or [float("nan")])
report("C4 cpu avg pre / load max", f"{cavg_pre:.1f} / {cavg_max:.1f} (+{cavg_max-cavg_pre:.1f})")

# C7 SMC family response
def smc_in(t0, t1): return [m for t, m in smc if t0 <= t <= t1]
def fam_stats(load_rng):
    pre, load = smc_in(*rest), smc_in(*load_rng)
    fam = defaultdict(list)
    for k in set().union(*[m.keys() for m in pre]) if pre else []:
        pv = [m[k] for m in pre if k in m]; lv = [m[k] for m in load if k in m]
        if not pv or not lv: continue
        fam[k[:2]].append((k, mean(pv), max(lv), max(lv) - mean(pv)))
    return fam
for label, rng in (("CPU", (ev["cpuload-start"], ev["cpuload-end"] + 2)), ("GPU", (ev["gpuload-start"], ev["gpuload-end"] + 2))):
    fam = fam_stats(rng)
    print(f"C7 SMC families under {label} load (family: n, rest-mean max, load max, max rise, keys rising >=5C):")
    for f, ks in sorted(fam.items(), key=lambda kv: -max(x[3] for x in kv[1])):
        valid = [x for x in ks if 0.5 <= x[1] <= 150]
        if not valid: continue
        rising = sum(1 for x in valid if x[3] >= 5)
        print(f"   {f}: n={len(valid)} rest={max(x[1] for x in valid):.1f} load={max(x[2] for x in valid):.1f} rise={max(x[3] for x in valid):+.1f} rising={rising}")
