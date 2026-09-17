#!/usr/bin/env python3
"""Offline candidate evaluation; no model/runtime is bundled in Saylane.

Install numpy, pillow, onnxruntime in an isolated venv. Pass model, screenshot,
and output directory. The pinned export's preprocessing follows its model card.
"""
import hashlib
import json
from pathlib import Path
import platform
import sys
import time

import numpy as np
import onnxruntime as ort
from PIL import Image, ImageDraw

model, source, output = map(Path, sys.argv[1:4])
expected = "33688dbee1c23e34b81777e97cb428eb40f24b242c02b5f623484959e830aec8"
assert hashlib.sha256(model.read_bytes()).hexdigest() == expected, "Unexpected model export"
output.mkdir(parents=True, exist_ok=True)
options = ort.SessionOptions()
options.intra_op_num_threads = 2
options.inter_op_num_threads = 1
start = time.perf_counter()
session = ort.InferenceSession(str(model), sess_options=options, providers=["CPUExecutionProvider"])
load_ms = (time.perf_counter() - start) * 1000
image = Image.open(source).convert("RGB")
cases = {"full": image}
if image.size == (5120, 2578):
    cases["navigation"] = image.crop((1300, 100, 1780, 1500))
    cases["content"] = image.crop((1840, 0, 3050, 2578))
    cases["sidebar"] = image.crop((3100, 100, 3820, 2570))
labels = "paragraph_title image text number abstract content figure_title formula table table_title reference doc_title footnote header algorithm footer seal chart_title chart formula_number header_image footer_image aside_text".split()
report = {"model_sha256": expected, "model_bytes": model.stat().st_size,
          "source": str(source), "machine": platform.machine(), "ort": ort.__version__,
          "provider": session.get_providers(), "threads": 2, "load_ms": load_ms, "cases": {}}
for name, img in cases.items():
    times = []
    for _ in range(21):
        start = time.perf_counter()
        arr = np.asarray(img.resize((480, 480), Image.Resampling.BILINEAR), dtype=np.float32) / 255
        arr = (arr - np.array([.485, .456, .406], np.float32)) / np.array([.229, .224, .225], np.float32)
        dets, counts = session.run(None, {"image": np.transpose(arr, (2, 0, 1))[None],
            "scale_factor": np.array([[480/img.height, 480/img.width]], np.float32)})
        times.append((time.perf_counter() - start) * 1000)
    regions = [{"label": labels[int(row[0])], "score": float(row[1]), "box": list(map(float, row[2:]))}
               for row in dets[:int(counts[0])] if row[1] >= .3]
    preview = img.copy()
    draw = ImageDraw.Draw(preview)
    for region in regions:
        box = region["box"]
        draw.rectangle(box, outline="red", width=4)
        draw.text((box[0], box[1]), f'{region["label"]} {region["score"]:.2f}', fill="red", stroke_width=1)
    preview.thumbnail((1600, 1600))
    preview.save(output / f"{name}.png")
    report["cases"][name] = {"size": img.size, "first_ms": times[0],
        "warm_p50_ms": float(np.median(times[1:])), "warm_p95_ms": float(np.percentile(times[1:], 95)),
        "regions": regions}
(output / "report.json").write_text(json.dumps(report, indent=2))
print(json.dumps({k: {key: value for key, value in v.items() if key != "regions"} | {"regions": len(v["regions"])}
                  for k, v in report["cases"].items()}, indent=2))
