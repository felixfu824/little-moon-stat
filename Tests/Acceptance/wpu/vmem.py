#!/usr/bin/env python3
"""WP-U V6 analysis of vmem.sh output. Usage: vmem.py <out> <MiB>"""
import json, sys, statistics as st
out, mib = sys.argv[1], float(sys.argv[2])
ev = {l.split()[1]: float(l.split()[0]) for l in open(f'{out}/events.txt')}; t0 = ev['start']
mb = [json.loads(l) for l in open(f'{out}/mb.jsonl')]
for r in mb: r['T'] = r['wall'] - t0
memsize, pagesize = [int(x) for x in open(f'{out}/mem.txt').read().split()]
vm = []; cur = None
for l in open(f'{out}/vm.txt'):
    if l.startswith('=='): cur = {'T': float(l.split()[1]) - t0}; vm.append(cur); continue
    if ':' in l:
        k, v = l.split(':', 1); v = v.strip().rstrip('.')
        if v.isdigit(): cur[k.strip()] = int(v)
for v in vm: v['pct'] = (v['Pages wired down'] + v['Pages active'] + v['Pages occupied by compressor']) * pagesize / memsize * 100
s, e = ev['memload-start'] - t0, ev['memload-end'] - t0
m = lambda rows, key, a, b: st.mean(r[key] for r in rows if a <= r['T'] <= b)
exp = mib * 1048576 / memsize * 100
vb, vh, va = m(vm, 'pct', s - 10, s), m(vm, 'pct', s + 8, e), m(vm, 'pct', e + 6, e + 20)
eb, eh, ea = m(mb, 'mRam', s - 10, s), m(mb, 'mRam', s + 8, e), m(mb, 'mRam', e + 6, e + 20)
hit = next((r['T'] - s for r in mb if s <= r['T'] <= e and r['mRam'] >= eb + 0.6 * (vh - vb)), None)
diffs = [abs(min(mb, key=lambda r: abs(r['T'] - v['T']))['ramPct'] - v['pct']) for v in vm if v['T'] < mb[-1]['T']]
ok = (vh - vb) >= 0.5 * exp and hit is not None and hit <= 6 and abs((eh - eb) - (vh - vb)) <= 1.5 and ea <= eb + 0.4 * (vh - vb) + 1
print(f"RESULT V6 {'PASS' if ok else 'FAIL'} :: load {mib:.0f} MiB = +{exp:.2f} pt expected; vm_stat base/held/after {vb:.2f}/{vh:.2f}/{va:.2f}; "
      f"RAM moon base/held/after {eb:.2f}/{eh:.2f}/{ea:.2f}; moon reached 60% of the vm_stat rise after {hit} s; max |engine-vm_stat| {max(diffs):.2f} pt")
