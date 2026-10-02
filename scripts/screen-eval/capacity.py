#!/usr/bin/env python3
"""How good is max_chars? Usage: capacity.py <out-dir>

max_chars is what a language model is told about a block: roughly how many
characters of the target language fit where the source is, at its size and in
its lines. It is an estimate from widths, not a measurement of the words that
will come back. This compares it with what the fitter then did with a real
translation (the quick one, in <name>.v2.json): a translation within max_chars
should have been set at the original size in the original lines; a longer one
should have been made smaller, wrapped, cut, or left untranslated.
"""
import glob
import json
import os
import sys


def main(out):
    rows = {}
    for path in sorted(glob.glob(os.path.join(out, '*.v2.json'))):
        name = os.path.basename(path)[:-len('.v2.json')]
        direction = 'en → zh' if '-en@' in name else 'zh → en'
        row = rows.setdefault(direction, {'blocks': 0, 'within': 0, 'within_fit': 0, 'over': 0, 'over_fit': 0})
        for block in json.load(open(path))['blocks']:
            # Only what was asked to be translated and came back as something else.
            if not block.get('maxChars') or not block['translation'] or block['translation'] == block['original']:
                continue
            placed = block['placedLines']
            fits = bool(placed) and block['shrink'] == 1 and not block['truncated'] and len(placed) <= block['lines']
            row['blocks'] += 1
            if len(block['translation']) <= block['maxChars']:
                row['within'] += 1
                row['within_fit'] += fits
            else:
                row['over'] += 1
                row['over_fit'] += fits
    print(f"{'':10}{'blocks':>8}{'within max_chars':>20}{'… and set as is':>18}{'over max_chars':>18}{'… yet set as is':>18}")
    for direction, row in rows.items():
        def share(part, whole):
            return f"{part} ({100 * part / whole:.0f}%)" if whole else '0'
        print(f"{direction:10}{row['blocks']:>8}{row['within']:>20}{share(row['within_fit'], row['within']):>18}"
              f"{row['over']:>18}{share(row['over_fit'], row['over']):>18}")


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'build/screen-eval/out')
