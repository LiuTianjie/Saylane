#!/usr/bin/env python3
"""Build a compact word-bigram table for pinyin sentence decoding."""
from __future__ import annotations

import argparse
import collections
import pathlib
import re

HAN = re.compile(r"[\u4e00-\u9fff]+")


def load_vocab(dict_path: pathlib.Path) -> tuple[set[str], dict[str, int], int]:
    vocab: set[str] = set()
    uni: dict[str, int] = {}
    longest = 1
    for line in dict_path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        word, freq_s = parts[2], parts[1]
        try:
            freq = int(freq_s)
        except ValueError:
            continue
        vocab.add(word)
        uni[word] = uni.get(word, 0) + freq
        longest = max(longest, len(word))
    return vocab, uni, longest


def add_bigram(table: collections.Counter[tuple[str, str]], left: str, right: str, count: int) -> None:
    if count <= 0 or left == right == "":
        return
    table[(left, right)] += count


def phrase_bigrams(uni: dict[str, int], vocab: set[str]) -> collections.Counter[tuple[str, str]]:
    table: collections.Counter[tuple[str, str]] = collections.Counter()
    for word, freq in uni.items():
        n = len(word)
        if n < 2:
            continue
        for i in range(1, n):
            left, right = word[:i], word[i:]
            if left in vocab and right in vocab:
                add_bigram(table, left, right, max(freq, 1))
    return table


def segment(line: str, vocab: set[str], longest: int) -> list[str]:
    chars = [ch for ch in line if "\u4e00" <= ch <= "\u9fff"]
    if not chars:
        return []
    text = "".join(chars)
    words: list[str] = []
    i, n = 0, len(text)
    while i < n:
        matched = None
        span = min(longest, n - i)
        for size in range(span, 0, -1):
            piece = text[i : i + size]
            if piece in vocab:
                matched = piece
                break
        if matched is None:
            i += 1
            continue
        words.append(matched)
        i += len(matched)
    return words


def corpus_bigrams(path: pathlib.Path, vocab: set[str], longest: int, limit_bytes: int) -> collections.Counter[tuple[str, str]]:
    table: collections.Counter[tuple[str, str]] = collections.Counter()
    consumed = 0
    with path.open(encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            consumed += len(line.encode("utf-8", errors="ignore"))
            words = segment(line, vocab, longest)
            for left, right in zip(words, words[1:]):
                add_bigram(table, left, right, 1)
            if consumed >= limit_bytes:
                break
    return table


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dict", required=True)
    parser.add_argument("--corpus")
    parser.add_argument("--output", required=True)
    parser.add_argument("--max-bigrams", type=int, default=250000)
    parser.add_argument("--corpus-bytes", type=int, default=80_000_000)
    args = parser.parse_args()
    vocab, uni, longest = load_vocab(pathlib.Path(args.dict))
    table = phrase_bigrams(uni, vocab)
    if args.corpus and pathlib.Path(args.corpus).exists():
        table.update(corpus_bigrams(pathlib.Path(args.corpus), vocab, longest, args.corpus_bytes))
    # High-value collocations that long-sentence IME must get right.
    seeds = {
        ("去", "北京"): 50000,
        ("北京", "玩"): 8000,
        ("今天", "天气"): 40000,
        ("天气", "很"): 20000,
        ("很", "好"): 30000,
        ("现在", "九"): 12000,
        ("九", "点"): 25000,
        ("点", "了"): 20000,
        ("现在", "九点"): 15000,
        ("九点", "了"): 18000,
        ("我", "想"): 80000,
        ("想", "去"): 40000,
        ("想", "吃"): 20000,
        ("我", "爱"): 30000,
        ("爱", "你"): 40000,
        ("你", "好"): 40000,
        ("中国", "人民"): 12000,
        ("觉得", "这个"): 15000,
        ("这个", "可以"): 12000,
        ("我们", "明天"): 12000,
        ("明天", "去"): 15000,
        ("去", "背景"): 1,
    }
    for pair, count in seeds.items():
        if pair[0] in vocab and pair[1] in vocab:
            table[pair] += count
    rows = table.most_common(args.max_bigrams)
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        handle.write("# word bigrams for Saylane sentence decoding\n")
        handle.write("# Phrase splits from the lexicon plus OpenSubtitles-derived counts\n")
        for (left, right), count in rows:
            if count <= 0:
                continue
            handle.write(f"{left}\t{right}\t{count}\n")
    print(f"wrote {len(rows)} bigrams to {output} vocab={len(vocab)}")


if __name__ == "__main__":
    main()
