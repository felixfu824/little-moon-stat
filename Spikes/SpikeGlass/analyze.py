#!/usr/bin/env python3
"""Analyze saved own-window screenshots; never reads or captures the desktop."""
import csv
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw

root = Path(sys.argv[1] if len(sys.argv) > 1 else "docs/spikes/glass")
variants = ["appkit-clear", "appkit-tinted", "swiftui", "visualeffect"]
results = {}
previews = []


def pixels(image):
    return np.asarray(image.convert("RGB"), dtype=np.float64)


def diff(first, second, box):
    delta = np.abs(pixels(first.crop(box)) - pixels(second.crop(box)))
    return {"mae_rgb_255": round(float(delta.mean()), 4),
            "changed_percent_gt_2": round(float((delta.max(axis=2) > 2).mean() * 100), 4)}


for variant in variants:
    directory = root / variant
    images = {path.stem: Image.open(path).convert("RGBA") for path in directory.glob("*.png")}
    events = json.loads((directory / "events.json").read_text())
    captures = {row["name"]: row for row in events if row["event"] == "capture"}
    # Nominal-point images, with a text-free band near the bottom of the panel.
    size = images["backdrop"].getbbox()[2:]
    assert size[0] / size[1] == 360 / 400, size
    scale = size[0] / 360
    band = tuple(round(x * scale) for x in (30, 350, 330, 380))
    interior = tuple(round(x * scale) for x in (26, 26, 334, 374))
    row = {
        "live_band": diff(images["live-a"], images["live-b"], band),
        "live_interior": diff(images["live-a"], images["live-b"], interior),
        "static_band": diff(images["static-a"], images["static-b"], band),
        "moved_band": diff(images["moved-a"], images["moved-b"], band),
        "effect_vs_backdrop_band": diff(images["static-b"], images["backdrop"], band),
        "live_interval_seconds": round(captures["live-b"]["requestTime"] - captures["live-a"]["requestTime"], 6),
        "moved_interval_seconds": round(captures["moved-b"]["requestTime"] - captures["moved-a"]["requestTime"], 6),
        "phase_pairs": [[captures[name]["phaseBefore"], captures[name]["phaseAfter"]]
                        for name in ("live-a", "live-b", "moved-a", "moved-b")],
    }
    assert all(a == b for a, b in row["phase_pairs"]), "Capture crossed a stripe update"
    assert row["phase_pairs"][0][0] != row["phase_pairs"][1][0]
    assert row["phase_pairs"][2][0] != row["phase_pairs"][3][0]
    assert captures["static-b"]["phaseBefore"] == captures["backdrop"]["phaseBefore"]
    for name in ("static-b", "backdrop"):
        # Peak adjacent-column RGB step on an empty horizontal band: blurred stripes
        # have a much smaller step than the sharp opaque backdrop's 255 levels.
        array = pixels(images[name].crop(band)).mean(axis=0)
        row[name + "_peak_column_step"] = round(float(np.abs(np.diff(array, axis=0)).max()), 4)
    with (directory / "cpu.csv").open() as file:
        cpu = [float(entry["cpu_percent"]) for entry in csv.DictReader(file)]
    assert len(cpu) == 10
    row["cpu_percent"] = {"samples": cpu, "mean": round(float(np.mean(cpu)), 4), "max": max(cpu)}
    results[variant] = row

    for label, a, b in (("live-diff", "live-a", "live-b"), ("moved-diff", "moved-a", "moved-b")):
        difference = ImageChops.difference(images[a].convert("RGB"), images[b].convert("RGB"))
        difference.crop((0, 0, *size)).save(directory / (label + ".png"))
    previews.append([images[name].crop((0, 0, *size)).resize((360, 400))
                     for name in ("live-a", "live-b", "moved-a", "moved-b")])
    print(variant, json.dumps(row, sort_keys=True))

(root / "metrics.json").write_text(json.dumps(results, indent=2) + "\n")
sheet = Image.new("RGB", (4 * 360, 4 * 430), "#20252b")
draw = ImageDraw.Draw(sheet)
for y, (variant, panels) in enumerate(zip(variants, previews)):
    for x, (name, panel) in enumerate(zip(("live-a", "live-b", "+200pt a", "+200pt b"), panels)):
        draw.text((x * 360 + 8, y * 430 + 8), variant + " / " + name, fill="white")
        sheet.paste(panel.convert("RGB"), (x * 360, y * 430 + 30))
sheet.save(root / "comparison.png")
