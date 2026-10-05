#!/usr/bin/env python3
"""Bundle pinned official app-server packages, preserving their helper layout."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

app = Path(sys.argv[1])
records = json.loads(Path('resources/codex-runtime.json').read_text())
for record in records:
    arch = 'arm64' if 'aarch64' in record['name'] else 'x86_64'
    cache = Path('build/codex-runtime') / arch
    marker = cache / '.verified'
    if not marker.exists():
        archive = Path('build') / record['name']
        if not archive.exists():
            subprocess.run(['curl','-fL','--retry','3','--silent','--show-error',record['url'],'-o',str(archive)],check=True)
        hasher = hashlib.sha256()
        with archive.open('rb') as data:
            for chunk in iter(lambda: data.read(1024 * 1024), b''): hasher.update(chunk)
        digest = 'sha256:' + hasher.hexdigest()
        if digest != record['digest']:
            raise SystemExit('Codex runtime checksum mismatch: '+arch)
        cache.mkdir(parents=True,exist_ok=True)
        subprocess.run(['tar','-xzf',str(archive),'-C',str(cache)],check=True)
        marker.write_text(record['digest'])
    target=app / 'Contents/Resources/Codex' / arch
    subprocess.run(['/usr/bin/ditto',str(cache),str(target)],check=True)
shutil.copyfile('resources/Codex-LICENSE.txt',app / 'Contents/Resources/Codex-LICENSE.txt')
shutil.copyfile('resources/Codex-NOTICE.txt',app / 'Contents/Resources/Codex-NOTICE.txt')
