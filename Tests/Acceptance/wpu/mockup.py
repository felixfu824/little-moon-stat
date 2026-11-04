#!/usr/bin/env python3
"""WP-U: independent re-implementation of the mockups' renderVals() maths (TwinMoons.dc.html and
MoonPopover.dc.html), compared with the app's model dumped by modelcheck.swift.
Usage: mockup.py <modelcheck.jsonl>   Prints one RESULT line per case."""
import json, math, sys

def js_round(x):  # JavaScript Math.round: half toward +infinity
    return math.floor(x + 0.5)

def clamp(v): return max(0.0, min(1.0, v))
def step(t): return js_round(clamp((t - 50) / 45) * 7)          # integer 0..7 (mockup returns /7)
def lit(t): return 0.12 + 0.88 * step(t) / 7
def lit_pct(p): return 0.12 + 0.88 * (js_round(clamp(p / 100) * 7) / 7)
RAMP = {
    'd': [(50, (255, 255, 255)), (62, (255, 241, 214)), (72, (255, 208, 138)), (80, (255, 169, 77)), (88, (255, 122, 61)), (95, (255, 59, 48))],
    'l': [(50, (29, 29, 31)), (62, (74, 58, 34)), (72, (138, 90, 16)), (80, (178, 90, 0)), (88, (194, 65, 12)), (95, (215, 0, 21))],
}
def heat_q(tq, bg):
    stops = RAMP[bg]
    for i in range(1, len(stops)):
        if tq <= stops[i][0]:
            a, b = stops[i - 1], stops[i]
            k = (tq - a[0]) / (b[0] - a[0])
            return [js_round(a[1][j] + (b[1][j] - a[1][j]) * k) for j in range(3)]
    return list(stops[-1][1])
def heat_step(s, bg): return heat_q(50 + 45 * s / 7, bg)

rows = [json.loads(l) for l in open(sys.argv[1]) if l.startswith('{')]
by = lambda k: [r for r in rows if r['k'] == k]
def res(case, ok, detail): print(f"RESULT {case} {'PASS' if ok else 'FAIL'} :: {detail}")

# M1
bad = [(r['t'], r['step'], step(r['t'])) for r in by('step') if r['step'] != step(r['t']) or abs(r['lit'] - lit(r['t'])) > 1e-9]
res('M1', not bad and len(by('step')) == 801, f"{len(by('step'))} temperatures 30.0-110.0; mismatches={bad[:6]}")
# M2
bad = []
for r in by('ink'):
    exp = heat_step(r['step'], 'd' if r['dark'] else 'l')
    if any(abs(a - b) > 1 for a, b in zip(r['rgb'], exp)): bad.append((r['dark'], r['step'], r['rgb'], exp))
table = {('d' if r['dark'] else 'l') + str(r['step']): r['rgb'] for r in by('ink')}
res('M2', not bad and len(by('ink')) == 16, f"16 step colours; mismatches={bad}; dark={[table['d%d' % s] for s in range(8)]} light={[table['l%d' % s] for s in range(8)]}")
# M3
bad = []
for r in by('ram'):
    p = r['p']
    if abs((0.12 + 0.88 * r['phase'] / 7) - lit_pct(p)) > 1e-9: bad.append(('phase', p, r['phase']))
    if r['colour'] != step(p): bad.append(('colour', p, r['colour'], step(p)))
res('M3', not bad, f"{len(by('ram'))} RAM % values; mismatches={bad[:6]}")
# M5
bad = []
for r in by('resolve'):
    exp = {'Celsius': 'celsius', 'Fahrenheit': 'fahrenheit'}.get(r['pref']) or ('fahrenheit' if r['locale'] == 'en_US' else 'celsius')
    if r['unit'] != exp: bad.append(r)
for r in by('fmt'):
    s = r['s']
    if r['v'] is None:
        if s != '—': bad.append(r)
        continue
    if not (s.endswith('°C') or s.endswith('°F')): bad.append(r)
    if r['unit'] == 'celsius' and s != f"{r['v']:.0f}°C": bad.append(r)
    if r['unit'] == 'fahrenheit':
        if not s.endswith('°F') or abs(int(s[:-2]) - (r['v'] * 9 / 5 + 32)) > 0.5 + 1e-9: bad.append(r)
sysu = by('machineSystemUnit')[0]
fmts = {(r['v'], r['unit']): r['s'] for r in by('fmt')}
res('M5', not bad, f"resolve+format mismatches={bad[:4]}; samples 75.5C={fmts[(75.5,'celsius')]} 76.5C={fmts[(76.5,'celsius')]} 100F={fmts[(100,'fahrenheit')]} nil={fmts[(None,'celsius')]}; this Mac System->{sysu['unit']} (AppleTemperatureUnit={sysu['AppleTemperatureUnit']}, locale={sysu['locale']})")
# M6
sl = by('slots')[0]; tw = {r['s']: r['w'] for r in by('textw')}
over = [s for s in ['100°C', '212°F', '302°F', '—', '8°C', '46°F'] if tw[s] > sl['label'] + 1e-6] + [s for s in ['100%', '0%', '—'] if tw[s] > sl['ram'] + 1e-6]
multi = [r for r in by('subset') if len(r['imageSizes']) != 1]
res('M6', not over and not multi, f"slot temp={sl['label']} ram={sl['ram']}; widths={ {k: round(v, 2) for k, v in tw.items()} }; overflow={over}; subsets with >1 image size={multi}")
# M7 (offline part: sum of widths, order checked in renders)
w = {r['raw']: r['width'] for r in by('subset')}
moonw = {1: 19 + sl['label'], 2: 19 + sl['label'], 4: 19 + sl['ram']}
bad = []
for raw in range(1, 8):
    parts = [moonw[b] for b in (1, 2, 4) if raw & b]
    exp = 12 + sum(parts) + 8 * (len(parts) - 1)
    if abs(w[raw] - exp) > 1e-6: bad.append((raw, w[raw], exp))
res('M7-offline', not bad, f"widths per subset raw->pt {w}; none={w[0]} (renderer) ; mismatches={bad}")
# M8/M9/M10 quantizer sequences
seqs = {r['name']: r['rows'] for r in by('seq')}
def changes(col, rows): return sum(1 for a, b in zip(rows, rows[1:]) if a[col] != b[col])
detail = []; ok = True
for name, rws in seqs.items():
    if not name.startswith('noise'): continue
    rows2 = rws[1:]
    nc, pc = changes(1, rows2), changes(2, rows2)
    err = max(abs(r[1] - r[0]) for r in rws)
    centre = float(name[5:])
    near_boundary = any(abs(centre - (50 + (k + 0.5) * 45 / 7)) < 1 for k in range(7))
    detail.append(f"{name}: numberChanges={nc} phaseChanges={pc} maxErr={err:.2f}")
    # number may legitimately move once if the first reading anchors near the edge of the noise band
    if nc > 1 or err >= 1.0 or pc > 1: ok = False
res('M8/M9 noise', ok, '; '.join(detail))
det = []; ok = True
for name, rws in seqs.items():
    if not name.startswith('half'): continue
    nc = changes(1, rws[1:]); err = max(abs(r[1] - r[0]) for r in rws); ok = ok and nc <= 1 and err < 1.0
    det.append(f"{name}: numberChanges={nc} maxErr={err:.2f}")
res('M8b half-band noise (+-0.45 C, peak-to-peak < 1 C deadband)', ok, '; '.join(det))
for name in ['ramNoise', 'ramNoiseBoundary']:
    rws = seqs[name][1:]
    res(f'M8/M9 {name}', changes(7, rws) <= 1 and changes(8, rws) <= 1 and changes(9, rws) <= 1,
        f"numberChanges={changes(7, rws)} phaseChanges={changes(8, rws)} colourChanges={changes(9, rws)} maxErr={max(abs(r[7]-r[6]) for r in seqs[name]):.2f}")
sw = seqs['sweep']
err = max(abs(r[1] - r[0]) for r in sw)
# step must equal the mockup step whenever the value is >= 1.0 C away from a boundary
lag = [(r[0], r[2], step(r[0])) for r in sw if r[2] != step(r[0]) and min(abs(r[0] - (50 + (k + 0.5) * 45 / 7)) for k in range(7)) > 1.0 + 1e-9]
res('M8/M9 sweep', err < 1.0 and not lag, f"40->100->40 C in 0.25 steps: maxNumberErr={err:.2f}; steps differing from mockup >1 C from a boundary={lag[:5]}")
st = seqs['step2']
res('M8 sustained 2C', [r[1] for r in st] == [70, 70, 70, 72, 72, 74, 74, 70, 68], f"numbers={[r[1] for r in st]} phases={[r[2] for r in st]}")
# M10 Fahrenheit: number shown = deadbanded C converted
fvals = [r[1] * 9 / 5 + 32 for r in seqs['noise76.5']]
exact = [r[0] * 9 / 5 + 32 for r in seqs['noise76.5']]
res('M10', len(set(round(v) for v in fvals[1:])) <= 2 and max(abs(round(a) - b) for a, b in zip(fvals, exact)) <= 2.0,
    f"distinct F numbers under +-0.9C noise={sorted(set(round(v) for v in fvals))}; max |shown-exact|={max(abs(round(a) - b) for a, b in zip(fvals, exact)):.2f} F")
ms = seqs['missing']
res('M11 quantizer', ms[1][1] is None and ms[1][2] is None and ms[1][7] is None and ms[2][1] == 71,
    f"rows={ms}; nil alpha dark={[r['alpha'] for r in by('inkNil')]}")
# M12
a = {(r['lang'], r['unit'], r['raw']): r['s'] for r in by('a11y')}
exp_en = "CPU 76 degrees Celsius, GPU 63 degrees Celsius, RAM 58 percent"
ok = a[('en', 'celsius', 7)] == exp_en and a[('en', 'celsius', 0)] == 'MacMonitorPanel' and a[('en', 'celsius', 4)] == 'RAM 58 percent' \
    and a[('en', 'fahrenheit', 3)] == 'CPU 169 degrees Fahrenheit, GPU 145 degrees Fahrenheit'
res('M12', ok, f"en/C all={a[('en','celsius',7)]!r}; en/F cpu+gpu={a[('en','fahrenheit',3)]!r}; zh/C all={a[('zh-Hant','celsius',7)]!r}; zh/F all={a[('zh-Hant','fahrenheit',7)]!r}; none={a[('en','celsius',0)]!r}; nil={[r['s'] for r in by('a11yNil')][:2]}")
# M4/M13 pixels
bad = []; det = []
for r in by('px'):
    bg = 'd' if r['dark'] else 'l'
    if r['step'] >= 0:
        exp = heat_step(r['step'], bg)
        probe = r['edge'] if r['step'] < 7 else r['centre']
        if any(abs(a - b) > 3 for a, b in zip(probe[:3], exp)) or probe[3] < 250: bad.append((bg, r['step'], probe, exp))
        if r['step'] == 0 and r['centre'][3] > 80: bad.append(('step0 centre should be dim', r['centre']))
        if r['step'] == 7 and r['leftEdge'][3] < 250: bad.append(('step7 left edge should be lit', r['leftEdge']))
    else:
        if r['edge'][3] > 80 or r['centre'][3] > 80: bad.append(('nil should be dim/empty', r))
    det.append(f"{bg}{r['step']}: centre={r['centre']} edge={r['edge']}")
res('M4/M13 pixels', not bad, f"bad={bad}; {'; '.join(det)}")
print('CONTEXT', by('context'))
