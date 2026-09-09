#!/usr/bin/env python3
"""Build a frequency-ranked pinyin lexicon.

Character readings: mozillazg/pinyin-data (MIT)
Phrase readings: mozillazg/phrase-pinyin-data (MIT); ingested as real phrases
Word frequency: hermitdave/FrequencyWords zh_cn_full (CC-BY-SA-4.0)
"""
from __future__ import annotations

import argparse
import pathlib
import re
import unicodedata

SYLLABLES = {
    "a", "ai", "an", "ang", "ao",
    "ba", "bai", "ban", "bang", "bao", "bei", "ben", "beng", "bi", "bian", "biao", "bie", "bin", "bing", "bo", "bu",
    "ca", "cai", "can", "cang", "cao", "ce", "cei", "cen", "ceng", "ci", "cong", "cou", "cu", "cuan", "cui", "cun", "cuo",
    "cha", "chai", "chan", "chang", "chao", "che", "chen", "cheng", "chi", "chong", "chou", "chu", "chua", "chuai",
    "chuan", "chuang", "chui", "chun", "chuo",
    "da", "dai", "dan", "dang", "dao", "de", "dei", "den", "deng", "di", "dia", "dian", "diao", "die", "ding", "diu",
    "dong", "dou", "du", "duan", "dui", "dun", "duo",
    "e", "ei", "en", "eng", "er",
    "fa", "fan", "fang", "fei", "fen", "feng", "fiao", "fo", "fou", "fu",
    "ga", "gai", "gan", "gang", "gao", "ge", "gei", "gen", "geng", "gong", "gou", "gu", "gua", "guai", "guan", "guang",
    "gui", "gun", "guo",
    "ha", "hai", "han", "hang", "hao", "he", "hei", "hen", "heng", "hong", "hou", "hu", "hua", "huai", "huan", "huang",
    "hui", "hun", "huo",
    "ji", "jia", "jian", "jiang", "jiao", "jie", "jin", "jing", "jiong", "jiu", "ju", "juan", "jue", "jun",
    "ka", "kai", "kan", "kang", "kao", "ke", "kei", "ken", "keng", "kong", "kou", "ku", "kua", "kuai", "kuan", "kuang",
    "kui", "kun", "kuo",
    "la", "lai", "lan", "lang", "lao", "le", "lei", "leng", "li", "lia", "lian", "liang", "liao", "lie", "lin", "ling",
    "liu", "lo", "long", "lou", "lu", "luan", "lue", "lun", "luo", "lv", "lve",
    "ma", "mai", "man", "mang", "mao", "me", "mei", "men", "meng", "mi", "mian", "miao", "mie", "min", "ming", "miu",
    "mo", "mou", "mu",
    "n", "na", "nai", "nan", "nang", "nao", "ne", "nei", "nen", "neng", "ng", "ni", "nian", "niang", "niao", "nie",
    "nin", "ning", "niu", "nong", "nou", "nu", "nuan", "nue", "nun", "nuo", "nv", "nve",
    "o", "ou",
    "pa", "pai", "pan", "pang", "pao", "pei", "pen", "peng", "pi", "pian", "piao", "pie", "pin", "ping", "po", "pou", "pu",
    "qi", "qia", "qian", "qiang", "qiao", "qie", "qin", "qing", "qiong", "qiu", "qu", "quan", "que", "qun",
    "ran", "rang", "rao", "re", "ren", "reng", "ri", "rong", "rou", "ru", "rua", "ruan", "rui", "run", "ruo",
    "sa", "sai", "san", "sang", "sao", "se", "sen", "seng", "si", "song", "sou", "su", "suan", "sui", "sun", "suo",
    "sha", "shai", "shan", "shang", "shao", "she", "shei", "shen", "sheng", "shi", "shou", "shu", "shua", "shuai",
    "shuan", "shuang", "shui", "shun", "shuo",
    "ta", "tai", "tan", "tang", "tao", "te", "tei", "teng", "ti", "tian", "tiao", "tie", "ting", "tong", "tou", "tu",
    "tuan", "tui", "tun", "tuo",
    "wa", "wai", "wan", "wang", "wei", "wen", "weng", "wo", "wu",
    "xi", "xia", "xian", "xiang", "xiao", "xie", "xin", "xing", "xiong", "xiu", "xu", "xuan", "xue", "xun",
    "ya", "yan", "yang", "yao", "ye", "yi", "yin", "ying", "yo", "yong", "you", "yu", "yuan", "yue", "yun",
    "za", "zai", "zan", "zang", "zao", "ze", "zei", "zen", "zeng", "zi", "zong", "zou", "zu", "zuan", "zui", "zun", "zuo",
    "zha", "zhai", "zhan", "zhang", "zhao", "zhe", "zhei", "zhen", "zheng", "zhi", "zhong", "zhou", "zhu", "zhua",
    "zhuai", "zhuan", "zhuang", "zhui", "zhun", "zhuo",
}


def normalize_token(token: str) -> str:
    token = token.strip().replace("u:", "v").replace("U:", "v")
    for src in ("ü", "Ü", "ǖ", "ǘ", "ǚ", "ǜ"):
        token = token.replace(src, "v")
    token = unicodedata.normalize("NFD", token)
    token = "".join(ch for ch in token if unicodedata.category(ch) != "Mn")
    token = re.sub(r"[^a-zA-Z]", "", token).lower()
    return {"lue": "lve", "nue": "nve"}.get(token, token)


def parse_characters(path: pathlib.Path) -> dict[str, list[str]]:
    mapping: dict[str, list[str]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"U\+[0-9A-F]+:\s+(\S+)\s+#\s+(\S+)", line.strip())
        if not match:
            continue
        char = match.group(2)[0]
        readings: list[str] = []
        for raw in match.group(1).split(","):
            pinyin = normalize_token(raw)
            if pinyin in SYLLABLES and pinyin not in readings:
                readings.append(pinyin)
        if readings:
            mapping[char] = readings
    return mapping


def parse_overrides(path: pathlib.Path) -> dict[str, list[str]]:
    overrides: dict[str, list[str]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#") or ":" not in line:
            continue
        word, raw = line.split(":", 1)
        word = word.strip()
        syllables = [normalize_token(part) for part in raw.split()]
        if word and syllables and all(part in SYLLABLES for part in syllables):
            overrides[word] = syllables
    return overrides


def parse_frequency(path: pathlib.Path) -> dict[str, int]:
    rows: dict[str, int] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        word, raw = parts
        try:
            freq = int(raw)
        except ValueError:
            continue
        if word and freq > 0:
            rows[word] = max(rows.get(word, 0), freq)
    return rows


def resolve_syllables(word: str, char_pinyin: dict[str, list[str]], overrides: dict[str, list[str]]) -> list[str] | None:
    if word in overrides:
        return overrides[word]
    if any(char not in char_pinyin for char in word):
        return None
    return [char_pinyin[char][0] for char in word]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--characters", required=True)
    parser.add_argument("--official-chars", default="")
    parser.add_argument("--phrases", required=True)
    parser.add_argument("--phrases-large", default="")
    parser.add_argument("--frequency", required=True)
    parser.add_argument("--min-freq", type=int, default=5)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    all_readings = parse_characters(pathlib.Path(args.characters))
    official = parse_characters(pathlib.Path(args.official_chars)) if args.official_chars else all_readings
    char_pinyin = {char: all_readings.get(char, readings) for char, readings in official.items()}
    overrides = parse_overrides(pathlib.Path(args.phrases))
    if args.phrases_large:
        overrides.update(parse_overrides(pathlib.Path(args.phrases_large)))
    freq_map = parse_frequency(pathlib.Path(args.frequency))
    merged: dict[tuple[str, str], tuple[int, list[str]]] = {}

    def add(word: str, syllables: list[str], freq: int) -> None:
        key = ("".join(syllables), word)
        current = merged.get(key)
        if current is None or freq > current[0]:
            merged[key] = (freq, syllables)

    for word, freq in freq_map.items():
        if freq < args.min_freq and len(word) > 1:
            continue
        if len(word) > 6:
            continue
        syllables = resolve_syllables(word, char_pinyin, overrides)
        if syllables is None:
            continue
        add(word, syllables, freq)

    for word, syllables in parse_overrides(pathlib.Path(args.phrases)).items():
        add(word, syllables, max(freq_map.get(word, 0), 40))

    for char, readings in char_pinyin.items():
        unigram = max(freq_map.get(char, 0), 1)
        for index, pinyin in enumerate(readings):
            # Extra official readings stay typeable without stealing page 1.
            freq = unigram if index == 0 else max(80, min(800, unigram * 4 // 100))
            add(char, [pinyin], freq)

    rows = [(syllables, freq, word) for (_, word), (freq, syllables) in merged.items()]
    rows.sort(key=lambda item: ("".join(item[0]), -item[1], item[2]))
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        handle.write("# Saylane pinyin lexicon\n")
        handle.write("# Readings: mozillazg/pinyin-data and phrase-pinyin-data (MIT)\n")
        handle.write("# Frequency: hermitdave/FrequencyWords zh_cn_full (CC-BY-SA-4.0)\n")
        for syllables, freq, word in rows:
            handle.write(f"{' '.join(syllables)}\t{freq}\t{word}\n")
    print(f"wrote {len(rows)} entries to {output}")


if __name__ == "__main__":
    main()
