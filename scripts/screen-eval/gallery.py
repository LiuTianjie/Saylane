#!/usr/bin/env python3
"""Write build/screen-eval/gallery.html: every sample as the source, the page
its publisher localised, the shipping pipeline's result and the V2 prototype's.

    gallery.py <pages-dir> <out-dir> <gallery.html>
"""
import html
import json
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import score  # noqa: E402

TITLES = {"app": "自建用例（浅色）", "appdark": "自建用例（深色）", "apple": "Apple 支持页（苹果自己的中/英文版）",
          "ghdocs": "GitHub Docs", "mdn": "MDN", "vue": "Vue 文档"}


def summary(pages, out, suffix, name):
    if not (out / f"{name}.{suffix}.json").exists():
        return "–"
    _, rows, result = score.score(pages, out, suffix, name)
    if not rows:
        return "–"
    errors = [abs(r["error"]) for r in rows]
    within = sum(e <= 0.05 for e in errors) / len(errors)
    text = f"字号误差中位 {statistics.median(errors) * 100:.1f}%，{within * 100:.0f}% 的块在 5% 以内"
    if suffix == "v2":
        placed = [b for b in result["blocks"] if b["placedLines"]]
        shrunk = sum(b["shrink"] < 1 for b in placed)
        cut = sum(b["truncated"] for b in placed)
        text += f"；{len(placed)} 块译文，缩小 {shrunk}，截断 {cut}"
    return text


def main():
    pages, out, target = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    rel_pages, rel_out = pages.resolve().relative_to(target.resolve().parent), out.resolve().relative_to(target.resolve().parent)
    parts = ["""<!doctype html><meta charset="utf-8"><title>截屏翻译对比</title>
<style>
 body{font:14px/1.5 -apple-system,"PingFang SC",sans-serif;margin:24px;background:#f5f5f7;color:#1d1d1f}
 h1{font-size:22px} h2{font-size:17px;margin:36px 0 4px} p{margin:4px 0 10px;color:#6e6e73}
 .row{display:grid;grid-template-columns:repeat(4,1fr);gap:10px}
 figure{margin:0;background:#fff;border:1px solid #d2d2d7;border-radius:8px;overflow:hidden}
 figcaption{padding:6px 10px;font-size:12px;border-bottom:1px solid #d2d2d7}
 figcaption b{display:block;font-size:13px} img{display:block;width:100%}
 @media (prefers-color-scheme:dark){body{background:#1c1c1e;color:#f5f5f7}figure{background:#2c2c2e;border-color:#3a3a3c}figcaption{border-color:#3a3a3c}}
</style>
<h1>截屏翻译：原图 / 真实本地化 / 现有版本 / V2 原型</h1>
<p>点图片看原始大小。“真实本地化”是同一页面由发布方自己做的另一语言版本，是要靠近的目标；它的内容会重排，原位翻译不会。</p>"""]
    names = sorted({p.name.split("@")[0].rsplit("-", 1)[0] for p in pages.glob("*.png")}, key=lambda n: list(TITLES).index(n) if n in TITLES else 99)
    for name in names:
        for scale in ("1x", "2x"):
            for source, other, arrow in (("en", "zh", "英 → 中"), ("zh", "en", "中 → 英")):
                sample = f"{name}-{source}@{scale}"
                if not (pages / f"{sample}.png").exists():
                    continue
                parts.append(f"<h2>{html.escape(TITLES.get(name, name))} · {arrow} · {scale}</h2><div class=row>")
                cells = [
                    ("原图", "", rel_pages / f"{sample}.png"),
                    ("真实本地化（目标）", "", rel_pages / f"{name}-{other}@{scale}.png"),
                    ("现有版本", summary(pages, out, "current", sample), rel_out / f"{sample}.current.png"),
                    ("V2 原型", summary(pages, out, "v2", sample), rel_out / f"{sample}.v2.png"),
                ]
                for title, note, path in cells:
                    parts.append(f'<figure><figcaption><b>{title}</b>{html.escape(note) or "&nbsp;"}</figcaption>'
                                 f'<a href="{path}" target="_blank"><img loading="lazy" src="{path}"></a></figure>')
                parts.append("</div>")
    target.write_text("\n".join(parts))
    print(target)


if __name__ == "__main__":
    main()
