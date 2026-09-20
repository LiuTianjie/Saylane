#!/usr/bin/env python3
"""Replay an explicit local corpus through the app and score accuracy/latency.
Nothing is recorded or uploaded. Reports contain the supplied transcripts.
"""
import argparse
import json
import math
from pathlib import Path
import re
import subprocess
import unicodedata


def normalized(text):
    return ''.join(c for c in unicodedata.normalize('NFKC', text).casefold() if c.isalnum())


def distance(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    for i, a in enumerate(reference, 1):
        row = [i]
        for j, b in enumerate(hypothesis, 1):
            row.append(min(row[-1] + 1, previous[j] + 1, previous[j - 1] + (a != b)))
        previous = row
    return previous[-1]


def term_present(term, text):
    term = unicodedata.normalize('NFKC', term).casefold().strip()
    text = unicodedata.normalize('NFKC', text).casefold()
    if not term:
        return False
    if term.isascii():
        # ASR may join English product-name words. Do not count AI inside chair,
        # or C++ as merely C, when scoring specialist vocabulary.
        pattern = r'\s*'.join(re.escape(word) for word in term.split())
        return re.search(r'(?<![a-z0-9])' + pattern + r'(?![a-z0-9])', text) is not None
    return normalized(term) in normalized(text)


def score(reference, hypothesis, terms=()):
    expected, actual = normalized(reference), normalized(hypothesis)
    terms = [term for term in terms if term.strip()]
    return {
        'character_edits': distance(expected, actual),
        'reference_characters': len(expected),
        'exact_match': expected == actual,
        'term_hits': sum(term_present(term, hypothesis) for term in terms),
        'term_count': len(terms),
        'false_speech': not expected and bool(actual),
    }


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)] if values else None


def summarize(rows):
    valid = [row for row in rows if 'score' in row]
    characters = sum(row['score']['reference_characters'] for row in valid)
    # Silent controls have no reference characters; report false speech separately.
    edits = sum(row['score']['character_edits'] for row in valid if row['score']['reference_characters'])
    terms = sum(row['score']['term_count'] for row in valid)
    summary = {
        'runs': len(valid), 'failures': len(rows) - len(valid),
        'character_error_rate': edits / characters if characters else None,
        'exact_match_rate': sum(row['score']['exact_match'] for row in valid) / len(valid) if valid else None,
        'term_recall': sum(row['score']['term_hits'] for row in valid) / terms if terms else None,
        'silent_false_speech': sum(row['score']['false_speech'] for row in valid),
    }
    for metric in ['setupMS', 'firstHypothesisMS', 'finalizeMS', 'revisedCharacterCount']:
        values = [row[metric] for row in valid if row.get(metric) is not None]
        summary[metric] = {'p50': percentile(values, .5), 'p95': percentile(values, .95), 'n': len(values)}
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True, help='Saylane.app or its executable')
    parser.add_argument('--corpus', type=Path, required=True, help='JSON array: id, audio, reference, locale, terms, category')
    parser.add_argument('--models', nargs='+', default=['apple'])
    parser.add_argument('--repeat', type=int, default=2, help='Repeated in one process: first use and subsequent use')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--batch', action='store_true', help='Feed as fast as possible; default is real-time replay')
    args = parser.parse_args()
    if not 1 <= args.repeat <= 20:
        parser.error('--repeat must be between 1 and 20')
    binary = args.app / 'Contents/MacOS/Saylane' if args.app.suffix == '.app' else args.app
    if not binary.is_file():
        parser.error('app executable does not exist')
    corpus = json.loads(args.corpus.read_text())
    if not isinstance(corpus, list) or not corpus:
        parser.error('corpus must be a nonempty JSON array')
    ids = set()
    for sample in corpus:
        if not isinstance(sample.get('id'), str) or sample['id'] in ids or not isinstance(sample.get('reference'), str):
            parser.error('each sample needs a unique string id and a reference string')
        ids.add(sample['id'])
        sample['audio'] = (args.corpus.parent / sample['audio']).resolve()
        if not sample['audio'].is_file():
            parser.error(f"audio file missing for {sample['id']}")
        if any(not term_present(term, sample['reference']) for term in sample.get('terms', [])):
            parser.error(f"terms must appear in the reference for {sample['id']}")
    args.output.mkdir(parents=True, exist_ok=True)
    rows = []
    for model_index, model in enumerate(args.models):
        for sample_index, sample in enumerate(corpus):
            # Numeric filenames: corpus identifiers and model names are never paths.
            raw = args.output / f'run-{model_index}-{sample_index}.json'
            raw.unlink(missing_ok=True)
            cmd = [str(binary.resolve()), '--recognize-file', str(sample['audio']), sample.get('locale', 'zh-CN'),
                   '--speech-model', model, '--asr-repeat', str(args.repeat), '--asr-report', str(raw.resolve())]
            if not args.batch:
                cmd.append('--realtime')
            try:
                process = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
                if not raw.is_file():
                    raise RuntimeError(f'no report, exit={process.returncode}: {process.stderr[-500:]}')
                reports = json.loads(raw.read_text())
                for report in reports:
                    rows.append(dict(report, sample=sample['id'], category=sample.get('category', 'unspecified'),
                                     score=score(sample['reference'], report['text'], sample.get('terms', []))))
                print(f"{model} / {sample['id']}: {len(reports)} runs", flush=True)
            except (subprocess.TimeoutExpired, RuntimeError, ValueError) as error:
                rows.append({'model': model, 'sample': sample['id'], 'error': str(error)})
                print(f"{model} / {sample['id']}: failed", flush=True)
    summary = {}
    for model in args.models:
        group = [row for row in rows if row['model'] == model]
        summary[model] = {
            'all': summarize(group),
            'first_use': summarize([row for row in group if row.get('iteration') == 1]),
            'subsequent_use': summarize([row for row in group if row.get('iteration', 0) > 1]),
        }
    result = {'schema_version': 1, 'realtime': not args.batch, 'summary': summary, 'runs': rows}
    (args.output / 'results.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 1 if any('error' in row for row in rows) else 0


if __name__ == '__main__':
    raise SystemExit(main())
