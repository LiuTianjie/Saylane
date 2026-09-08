#!/usr/bin/env python3
"""Build official 通用规范汉字 readings overlay.

Source: mozillazg/pinyin-data kTGHZ2013 (MIT), the 2013 通用规范汉字字典 readings.
Each character keeps every valid pinyin syllable. Frequency is copied from the
existing unigram so common polyphones like 行/hang and 长/chang rank on page 1.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import unicodedata
from collections import defaultdict

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


def char_frequencies(path: pathlib.Path) -> dict[str, int]:
    freq: dict[str, int] = defaultdict(int)
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        pinyin, raw, word = line.split("\t")
        if " " not in pinyin and len(word) == 1:
            freq[word] = max(freq[word], int(raw))
    return freq


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", default="scripts/data/kTGHZ2013.txt")
    parser.add_argument("--dict", default="Sources/Resources/pinyin.dict.tsv")
    parser.add_argument("--output", default="Sources/Resources/pinyin.chars.tsv")
    args = parser.parse_args()
    freq = char_frequencies(pathlib.Path(args.dict))
    rows: list[tuple[str, int, str]] = []
    seen: set[tuple[str, str]] = set()
    for line in pathlib.Path(args.source).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = re.match(r"U\+[0-9A-F]+:\s+(\S+)\s+#\s+(\S+)", line)
        if not match:
            continue
        char = match.group(2)[0]
        primary = True
        for raw in match.group(1).split(","):
            syllable = normalize_token(raw)
            if syllable not in SYLLABLES:
                continue
            key = (syllable, char)
            if key in seen:
                continue
            seen.add(key)
            unigram = max(freq[char], 1)
            # First listed reading keeps the unigram. Extra readings stay typeable
            # without stealing the first page (见/xian must not beat 先).
            value = unigram if primary else max(80, min(800, unigram * 4 // 100))
            rows.append((syllable, value, char))
            primary = False
    rows.sort(key=lambda item: (item[0], -item[1], item[2]))
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        handle.write("# Official 通用规范汉字 readings from mozillazg/pinyin-data kTGHZ2013\n")
        handle.write("# Frequency copied from the character unigram so alternate readings stay typeable.\n")
        for syllable, value, char in rows:
            handle.write(f"{syllable}\t{value}\t{char}\n")
    print(f"wrote {len(rows)} readings to {output}")


if __name__ == "__main__":
    main()
