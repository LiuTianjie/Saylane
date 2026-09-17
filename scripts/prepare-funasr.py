#!/usr/bin/env python3
"""Fetch pinned official arm64 helpers. Model weights are never bundled."""
import hashlib,json,os,shutil,tarfile,urllib.request
from pathlib import Path
root=Path(__file__).resolve().parent.parent
vendor=root/'Vendor/FunASR';lock=json.loads((vendor/'runtime.lock.json').read_text())
archive=root/'build/funasr-runtime/runtime.tar.gz';archive.parent.mkdir(parents=True,exist_ok=True)
if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest()!=lock['sha256']:
 urllib.request.urlretrieve(lock['url'],archive)
if hashlib.sha256(archive.read_bytes()).hexdigest()!=lock['sha256']:raise RuntimeError('FunASR archive checksum mismatch')
dest=vendor/'Runtime';dest.mkdir(exist_ok=True)
with tarfile.open(archive) as tar:
 for name in ['llama-funasr-sensevoice','llama-funasr-cli']:
  member=next(x for x in tar.getmembers() if x.name in [name,'./'+name])
  if not member.isfile():raise RuntimeError('Expected a regular executable')
  data=tar.extractfile(member).read();path=dest/name
  if not path.exists() or path.read_bytes()!=data:path.write_bytes(data)
  path.chmod(0o755)
print('FunASR native helpers verified.')
