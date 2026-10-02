#!/usr/bin/env python3
"""Score a pipeline's blocks against the truth a page reported about itself.

    score.py <pages-dir> <out-dir> <suffix> [--detail NAME]

<suffix> is `current` (the shipping pipeline, written by `baseline`) or `v2`.
For every block the truth is the font size, weight and colour of the DOM text
that lies under its source lines. Blocks whose lines cover text of mixed sizes
are left out of the size statistics.
"""
import difflib
import json
import re
import statistics
import sys
from pathlib import Path


def overlap(a, b):
    w = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])
    h = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
    return max(0, w) * max(0, h) if w > 0 and h > 0 else 0


def rgb(css):
    m = re.findall(r"[\d.]+", css)
    return tuple(float(x) for x in m[:3]) if len(m) >= 3 else (0, 0, 0)


def norm(text):
    return re.sub(r"[\W_]+", "", text.lower())


def same_words(a, b):
    """The recognised line and the DOM text share a real stretch of characters."""
    a, b = norm(a), norm(b)
    if not a or not b:
        return False
    match = difflib.SequenceMatcher(None, a, b, autojunk=False).find_longest_match(0, len(a), 0, len(b))
    return match.size >= max(2, 0.4 * min(len(a), len(b)))


def truth_for(line, truth_items, text=None):
    """Dominant truth style under one source line, or None when mixed or absent.

    Only DOM text that reads like the recognised line counts: a rectangle that
    merely overlaps (a hidden menu, a neighbouring cell) is not its truth.
    """
    weights = {}
    total = 0
    for item in truth_items:
        if text is not None and not same_words(text, item["text"]):
            continue
        if "rgba" in item["color"]:
            continue
        for rect in item["rects"]:
            # Compare on the ink band: DOM line boxes are taller than the glyphs.
            area = overlap(line, rect)
            if area <= 0:
                continue
            key = (item["size"], item["weight"], item["color"], item.get("align", ""))
            weights[key] = weights.get(key, 0) + area
            total += area
    if not weights:
        return None
    key, best = max(weights.items(), key=lambda kv: kv[1])
    sizes = {}
    for (size, *_), area in weights.items():
        sizes[size] = sizes.get(size, 0) + area
    if max(sizes.values()) < 0.8 * total:
        return None
    return {"size": max(sizes, key=sizes.get), "weight": key[1], "color": rgb(key[2]), "align": key[3]}


def score(pages, out, suffix, name):
    truth = json.loads((pages / f"{name}.json").read_text())
    result = json.loads((out / f"{name}.{suffix}.json").read_text())
    scale = truth["scale"]
    rows = []
    for block in result["blocks"]:
        texts = block.get("lineTexts") or [block["original"]] * len(block["lineRects"])
        styles = [truth_for(line, truth["items"], text) for line, text in zip(block["lineRects"], texts)]
        styles = [s for s in styles if s]
        if not styles:
            continue
        size = statistics.median(s["size"] for s in styles)
        style = styles[0]
        row = {"text": block["original"], "truth": size, "size": block["size"],
               "error": (block["size"] - size) / size,
               "boldTruth": style["weight"] >= 600, "bold": bool(block.get("bold")),
               "colorTruth": style["color"], "color": block.get("color")}
        rows.append(row)
    return scale, rows, result


def pct(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * q))] if values else float("nan")


def main():
    pages, out, suffix = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    detail = sys.argv[sys.argv.index("--detail") + 1] if "--detail" in sys.argv else None
    names = sorted(p.name[: -len(f".{suffix}.json")] for p in out.glob(f"*.{suffix}.json"))
    print(f"{'sample':<18} blocks  size error: median  p90   max   bias | within 5%  | bold ok | colour ΔRGB median")
    everything = []
    for name in names:
        if not (pages / f"{name}.json").exists():
            continue
        scale, rows, _ = score(pages, out, suffix, name)
        if not rows:
            continue
        errors = [abs(r["error"]) for r in rows]
        bias = statistics.mean(r["error"] for r in rows)
        within = sum(e <= 0.05 for e in errors) / len(errors)
        bold = sum(r["bold"] == r["boldTruth"] for r in rows) / len(rows)
        deltas = [max(abs(a - b) for a, b in zip(r["color"], r["colorTruth"])) for r in rows if r["color"]]
        colour = f"{statistics.median(deltas):5.0f}" if deltas else "    –"
        print(f"{name:<18} {len(rows):>5}   {statistics.median(errors)*100:>12.1f}% {pct(errors, .9)*100:>5.1f}% {max(errors)*100:>5.1f}% {bias*100:>+6.1f}% | {within*100:>7.0f}%   | {bold*100:>5.0f}%  | {colour}")
        everything += [(name, r) for r in rows]
        if detail == name:
            for r in sorted(rows, key=lambda r: -abs(r["error"])):
                print(f"    truth {r['truth']:>5.1f}  got {r['size']:>5.1f}  {r['error']*100:>+6.1f}%  {'B' if r['bold'] else ' '}/{'B' if r['boldTruth'] else ' '}  {r['text'][:60]}")
    for label, test in (("all @2x", lambda n: n.endswith("@2x")), ("all @1x", lambda n: n.endswith("@1x")), ("all", lambda n: True)):
        errors = [abs(r["error"]) for n, r in everything if test(n)]
        if not errors:
            continue
        bias = statistics.mean(r["error"] for n, r in everything if test(n))
        within = sum(e <= 0.05 for e in errors) / len(errors)
        print(f"{label:<18} {len(errors):>5}   {statistics.median(errors)*100:>12.1f}% {pct(errors, .9)*100:>5.1f}% {max(errors)*100:>5.1f}% {bias*100:>+6.1f}% | {within*100:>7.0f}%")


if __name__ == "__main__":
    main()
