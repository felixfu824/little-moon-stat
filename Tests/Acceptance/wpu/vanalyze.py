#!/usr/bin/env python3
"""WP-U V1-V6 analysis of vtimeline.sh output. Usage: vanalyze.py <out dir> <sensor-report.json> <memhog MiB>"""
import json, sys, statistics as st
out, rep, mib = sys.argv[1], sys.argv[2], float(sys.argv[3])
mb = [json.loads(l) for l in open(f'{out}/mb.jsonl') if l.startswith('{')]
ev = {}
for l in open(f'{out}/events.txt'):
    t, name = l.split()[:2]; ev[name] = float(t)
t0 = ev['start']
for r in mb: r['T'] = r['wall'] - t0
sel = json.load(open(rep))['selection']
memsize, pagesize = [int(x) for x in open(f'{out}/mem.txt').read().split()]
def res(case, ok, detail): print(f"RESULT {case} {'PASS' if ok else 'FAIL'} :: {detail}")
rel = lambda name: ev[name] - t0

# V1 same-tick agreement
bad = []
for r in mb:
    for m, p in (('mCpu', 'cpuPeak'), ('mGpu', 'gpuPeak'), ('mRam', 'ramPct')):
        if r[p] is None or r[m] is None:
            if (r[p] is None) != (r[m] is None): bad.append((r['T'], m, r[m], r[p]))
            continue
        if abs(r[m] - r[p]) >= 1.0: bad.append((round(r['T'], 1), m, r[m], round(r[p], 2)))
maxd = {m: max(abs(r[m] - r[p]) for r in mb if r[m] is not None and r[p] is not None) for m, p in (('mCpu', 'cpuPeak'), ('mGpu', 'gpuPeak'), ('mRam', 'ramPct'))}
res('V1', not bad and len(mb) > 30, f"{len(mb)} publications; max |moon-panel| = { {k: round(v, 2) for k, v in maxd.items()} }; violations={bad[:5]}")
# flicker at rest (first REST window) and overall: number changes per minute
def changes(key, a, b):
    rows = [r for r in mb if a <= r['T'] <= b]
    return sum(1 for x, y in zip(rows, rows[1:]) if x[key] != y[key]), (b - a) / 60
for key in ('mCpu', 'mGpu', 'mRam', 'mCpuStep', 'mGpuStep'):
    n, mins = changes(key, 2, rel('cpuload-start'))
    print(f"INFO flicker-at-rest {key}: {n} changes in {mins*60:.0f} s = {n/mins:.1f}/min")
# cadence
ts = [r['T'] for r in mb]; gaps = [b - a for a, b in zip(ts, ts[1:])]
print(f"INFO publication gaps: median {st.median(gaps):.2f} s, max {max(gaps):.2f} s; sensors cpu={mb[-1]['cpuN']} gpu={mb[-1]['gpuN']} procs={mb[-1]['procs']} cpuPct={mb[-1]['cpuPct']}")

# V2 vs raw SMC probe over the app's chosen keys
probe = []; cur = None
for l in open(f'{out}/smc.txt'):
    if l.startswith('=='):
        cur = {'T': float(l.split()[1]) - t0, 'k': {}}; probe.append(cur)
    elif l.startswith('SMC') and cur is not None:
        _, k, v = l.split('\t'); cur['k'][k] = float(v)
def pmax(p, keys):
    vals = [p['k'][k] for k in keys if k in p['k'] and 0.5 <= p['k'][k] <= 150]
    return max(vals) if vals else None
def wmean(rows, key, a, b): v = [r[key] for r in rows if a <= r['T'] <= b and r.get(key) is not None]; return st.mean(v) if v else None
for p in probe: p['cpu'] = pmax(p, sel['cpuKeys']); p['gpu'] = pmax(p, sel['gpuKeys'])
wins = {'rest': (5, rel('cpuload-start')), 'cpuload': (rel('cpuload-end') - 10, rel('cpuload-end')),
        'gpuload': (rel('gpuload-end') - 10, rel('gpuload-end'))}
ok = True; det = []
for w, (a, b) in wins.items():
    for fam, key in (('cpu', 'cpuPeak'), ('gpu', 'gpuPeak')):
        e, p = wmean(mb, key, a, b), wmean(probe, fam, a, b)
        d = e - p; det.append(f"{w}/{fam}: engine {e:.2f} probe {p:.2f} d={d:+.2f}")
        if abs(d) > 2.0: ok = False
res('V2', ok, '; '.join(det))

# V3 RAM vs vm_stat
vm = []; cur = None
for l in open(f'{out}/vm.txt'):
    if l.startswith('=='): cur = {'T': float(l.split()[1]) - t0}; vm.append(cur); continue
    if cur is None or ':' not in l: continue
    k, v = l.split(':', 1); v = v.strip().rstrip('.')
    if v.isdigit(): cur[k.strip()] = int(v)
for v in vm:
    v['pct'] = (v['Pages wired down'] + v['Pages active'] + v['Pages occupied by compressor']) * pagesize / memsize * 100
diffs = []
for v in vm:
    near = min(mb, key=lambda r: abs(r['T'] - v['T']))
    if abs(near['T'] - v['T']) <= 1.5 and near['ramPct'] is not None: diffs.append((round(v['T'], 1), round(near['ramPct'] - v['pct'], 2)))
mx = max(abs(d) for _, d in diffs)
res('V3', mx <= 1.5 and len(diffs) > 20, f"{len(diffs)} paired samples; max |engine-vm_stat| = {mx:.2f} pt; mean {st.mean(d for _, d in diffs):+.2f} pt (vm_stat wired+active+compressor x {pagesize} / {memsize})")

# V4 CPU moon responsiveness
base = wmean(mb, 'mCpu', 5, rel('cpuload-start'))
s = rel('cpuload-start'); e = rel('cpuload-end')
hit = next((r['T'] - s for r in mb if s <= r['T'] <= e + 2 and r['mCpu'] >= base + 5), None)
peak = max(r['mCpu'] for r in mb if s <= r['T'] <= e + 3)
fall = next((r['T'] - e for r in mb if e <= r['T'] <= e + 60 and r['mCpu'] <= peak - 3), None)
res('V4', hit is not None and hit <= 10 and fall is not None, f"rest mean {base:.1f} C; +5 C after {hit} s; peak {peak}; -3 C after {fall} s post-load; steps {sorted(set(r['mCpuStep'] for r in mb if s <= r['T'] <= e))}")
# V5 GPU
base = wmean(mb, 'mGpu', rel('gpuload-start') - 15, rel('gpuload-start'))
s = rel('gpuload-start'); e = rel('gpuload-end')
hit = next((r['T'] - s for r in mb if s <= r['T'] <= e + 2 and r['mGpu'] >= base + 5), None)
peak = max(r['mGpu'] for r in mb if s <= r['T'] <= e + 3)
res('V5', hit is not None and hit <= 12, f"pre-load mean {base:.1f} C; +5 C after {hit} s; peak {peak}; steps {sorted(set(r['mGpuStep'] for r in mb if s <= r['T'] <= e))}")
# V6 RAM
exp = mib * 1048576 / memsize * 100
s = rel('memload-start'); e = rel('memload-end')
base = wmean(mb, 'ramPct', s - 10, s)
hit = next((r['T'] - s for r in mb if s <= r['T'] <= e and r['mRam'] >= base + 0.6 * exp), None)
held = wmean(mb, 'mRam', s + 8, e)
after = [r for r in mb if r['T'] > e + 1]
back = after[-1]['mRam'] if after else None
res('V6', hit is not None and hit <= 6 and back is not None and back <= base + 0.4 * exp,
    f"expected +{exp:.2f} pt; base {base:.2f}; moon reached +60% after {hit} s; held mean {held:.2f}; after release {back} (t={after[-1]['T'] - e if after else None:.1f} s after end)")
