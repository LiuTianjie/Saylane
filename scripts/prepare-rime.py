#!/usr/bin/env python3
"""Fetch SHA-256-pinned runtime/data; compile dictionaries before app packaging.
Never deploy dictionaries or download code on the input-event path.
"""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'Vendor/Rime'
LOCK = VENDOR / 'dependencies.lock.json'
DOWNLOADS = VENDOR / 'Downloads'
RUNTIME = VENDOR / 'Runtime'
DATA = VENDOR / 'Rime'
CONFIG = ROOT / 'scripts/rime'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fetch(asset):
    target = DOWNLOADS / asset['file']
    if target.exists() and digest(target) == asset['sha256']:
        return
    request = urllib.request.Request(asset['url'], headers={'User-Agent': 'Saylane-dependency-builder'})
    with urllib.request.urlopen(request, timeout=120) as response:
        content = response.read()
    if hashlib.sha256(content).hexdigest() != asset['sha256']:
        raise RuntimeError(f"Checksum mismatch: {asset['file']}")
    temp = target.with_suffix(target.suffix + '.tmp')
    temp.write_bytes(content)
    temp.replace(target)


def main():
    lock = json.loads(LOCK.read_text())
    fingerprint = hashlib.sha256(LOCK.read_bytes() + Path(__file__).read_bytes() + b''.join(
        p.read_bytes() for p in sorted(CONFIG.iterdir()) if p.is_file()
    )).hexdigest()
    stamp = VENDOR / '.prepared'
    required = [RUNTIME / 'lib/librime.1.dylib', RUNTIME / 'lib/rime-plugins/librime-octagram.dylib', RUNTIME / 'include/rime_api.h',
                DATA / 'build/saylane.table.bin', DATA / 'build/saylane_pinyin.prism.bin',
                DATA / 'build/saylane_pinyin_fuzzy.prism.bin', DATA / 'build/saylane_pinyin.schema.yaml',
                DATA / 'build/saylane_pinyin_fuzzy.schema.yaml', DATA / 'build/saylane_pinyin_lm.schema.yaml',
                DATA / 'build/saylane_pinyin_fuzzy_lm.schema.yaml', DATA / 'build/melt_eng.table.bin',
                DATA / 'build/saylane_en.prism.bin', DATA / 'build/saylane_en.schema.yaml', DATA / 'essay.txt',
                DATA / 'opencc/emoji.json', DATA / 'opencc/emoji.txt', DATA / 'opencc/others.txt']
    if stamp.exists() and stamp.read_text() == fingerprint and all(p.exists() for p in required):
        print('Rime runtime and prebuilt dictionaries are up to date.')
        return
    DOWNLOADS.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(fetch, lock['assets']))
    with tempfile.TemporaryDirectory(dir=VENDOR, prefix='prepare-') as temp:
        temp = Path(temp)
        with tarfile.open(DOWNLOADS / 'librime.tar.bz2') as archive:
            archive.extractall(temp, filter='data')
        if RUNTIME.exists(): shutil.rmtree(RUNTIME)
        shutil.move(str(temp / 'dist'), RUNTIME)
        # The runtime that ships: the core library and, of the plugins in the
        # upstream archive, only the language-model one (octagram). No Lua, no
        # prediction plugin: nothing that runs scripts or is not used.
        for plugin in (RUNTIME / 'lib/rime-plugins').iterdir():
            if plugin.name != 'librime-octagram.dylib': plugin.unlink()
        if not (RUNTIME / 'lib/rime-plugins/librime-octagram.dylib').exists():
            raise RuntimeError('The upstream archive has no librime-octagram.dylib')
        for library in ['lib/librime.1.dylib', 'lib/rime-plugins/librime-octagram.dylib']:
            deps = subprocess.check_output(['otool', '-L', str(RUNTIME / library)], text=True)
            for line in deps.splitlines():
                if line.startswith('\t') and not line.strip().startswith(
                        ('@rpath/librime.1.dylib ', '@rpath/librime-octagram.dylib ', '/usr/lib/', '/System/Library/')):
                    raise RuntimeError(f'Unbundled runtime dependency in {library}: {line}')
        data = temp / 'Data'
        (data / 'cn_dicts').mkdir(parents=True)
        for name in ['8105', 'base', 'ext', 'others']:
            shutil.copy2(DOWNLOADS / f'{name}.dict.yaml', data / 'cn_dicts')
        (data / 'en_dicts').mkdir(parents=True)
        for name in ['en', 'en_ext']:
            shutil.copy2(DOWNLOADS / f'{name}.dict.yaml', data / 'en_dicts')
        for path in CONFIG.iterdir():
            if path.suffix == '.yaml': shutil.copy2(path, data)
        strict = (CONFIG / 'saylane_pinyin.schema.yaml').read_text()
        fuzz_rules = [
            'fuzz/^([zcs])h/$1/', 'fuzz/^([zcs])([^h])/$1h$2/',
            'fuzz/([ae])n$/$1ng/', 'fuzz/([ae])ng$/$1n/',
            'fuzz/in$/ing/', 'fuzz/ing$/in/'
        ]
        fuzz_algebra = ''.join('    - ' + rule + '\n' for rule in fuzz_rules)
        # Prism builder only. Runtime uses an exact translator plus a lowered
        # fuzzy translator, so every fuzzy pair (z/zh, an/ang, in/ing, ...)
        # keeps the exact-spelling winner first. One shared quality penalty;
        # no per-syllable exceptions.
        builder = strict.replace('schema_id: saylane_pinyin', 'schema_id: saylane_fuzzy_codes')
        builder = builder.replace('name: Saylane 拼音', 'name: Saylane 模糊音编码')
        builder = builder.replace('prism: saylane_pinyin', 'prism: saylane_pinyin_fuzzy')
        builder = builder.replace('  algebra:\n', '  algebra:\n' + fuzz_algebra)
        (data / 'saylane_fuzzy_codes.schema.yaml').write_text(builder)
        runtime = strict.replace('schema_id: saylane_pinyin', 'schema_id: saylane_pinyin_fuzzy')
        runtime = runtime.replace(
            '    - script_translator\n',
            '    - script_translator\n    - script_translator@fuzzy_translator\n')
        runtime += (
            '\nfuzzy_translator:\n'
            '  dictionary: saylane\n'
            '  prism: saylane_pinyin_fuzzy\n'
            '  enable_user_dict: false\n'
            '  enable_sentence: true\n'
            '  enable_completion: true\n'
            '  initial_quality: -4\n'
        )
        (data / 'saylane_pinyin_fuzzy.schema.yaml').write_text(runtime)
        # The same two schemas with the whole-sentence language model
        # (librime-octagram). The model file is not shipped: the user downloads
        # it from the settings into the Rime user directory, and these schemas
        # are selected only while it is there. On 60 everyday sentences typed
        # as one string of pinyin: 35 right without the model, 44 with it.
        grammar = '\ngrammar:\n  language: wanxiang-lts-zh-hans\n'
        (data / 'saylane_pinyin_lm.schema.yaml').write_text(
            strict.replace('schema_id: saylane_pinyin', 'schema_id: saylane_pinyin_lm')
                  .replace('name: Saylane 拼音', 'name: Saylane 拼音（语言模型）') + grammar)
        (data / 'saylane_pinyin_fuzzy_lm.schema.yaml').write_text(
            runtime.replace('schema_id: saylane_pinyin_fuzzy', 'schema_id: saylane_pinyin_fuzzy_lm')
                   .replace('name: Saylane 拼音', 'name: Saylane 拼音（语言模型）') + grammar)
        opencc = data / 'opencc'
        opencc.mkdir()
        for name in ['emoji.json', 'emoji.txt', 'others.txt']:
            shutil.copy2(DOWNLOADS / name, opencc / name)
        for name in ['essay.txt', 'essay-AUTHORS'] + [a['file'] for a in lock['assets'] if a['file'].endswith('-LICENSE')]:
            shutil.copy2(DOWNLOADS / name, data)
        shutil.copy2(LOCK, data / 'dependencies.lock.json')
        (data / 'SOURCE-NOTICE.txt').write_text(
            'librime 1.17.0: BSD-3-Clause; official unmodified macOS runtime.\n'
            'rime-ice dictionary subset: 8105, base, ext, others, en/en_ext, and opencc emoji tables.\n'
            'Of the plugins in that archive only librime-octagram (the language-model reader) is shipped; no Lua.\n'
            'No frontend code copied. No language model is shipped: the optional one is downloaded by the user.\n'
            'Dictionary sources, upstream headers, GPL-3.0 license and pinned URLs are included.\n'
            'rime-essay: LGPL-3.0; source essay.txt, AUTHORS and license included.\n'
            'The compiled data is built from these bundled sources and Saylane schema files.\n'
            'See dependencies.lock.json for exact versions, downloads and checksums.\n'
        )
        env = dict(os.environ, DYLD_LIBRARY_PATH=str(RUNTIME / 'lib'))
        log = ROOT / 'build/rime-deploy.log'
        log.parent.mkdir(exist_ok=True)
        print('Compiling Rime dictionaries; log:', log, flush=True)
        with log.open('w') as output:
            subprocess.run([str(RUNTIME / 'bin/rime_deployer'), '--build', str(data), str(data), str(data / 'build')],
                           env=env, stdout=output, stderr=subprocess.STDOUT, check=True)
        if DATA.exists(): shutil.rmtree(DATA)
        shutil.move(str(data), DATA)
    if not all(p.exists() for p in required):
        raise RuntimeError('Rime deployment did not produce all required artifacts')
    stamp.write_text(fingerprint)
    print('Prepared librime', lock['librime'], 'and native prebuilt dictionaries.')


if __name__ == '__main__':
    main()
