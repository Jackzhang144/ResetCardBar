#!/usr/bin/env python3
import base64
from pathlib import Path
import plistlib
import subprocess
import xml.etree.ElementTree as ET

info = plistlib.loads(Path('resources/Info.plist').read_bytes())
feed = ET.parse('dist/appcast.xml')
ns = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
item = feed.find('./channel/item')
assert item is not None, 'appcast has no release'
assert item.findtext('sparkle:version', namespaces=ns) == info['CFBundleVersion']
enclosure = item.find('enclosure')
assert enclosure is not None
signature = enclosure.get('{'+ns['sparkle']+'}edSignature')
archive = Path('dist') / enclosure.get('url').split('/')[-1]
assert archive.is_file() and int(enclosure.get('length')) == archive.stat().st_size
assert len(base64.b64decode(signature, validate=True)) == 64
assert enclosure.get('url').startswith('https://github.com/Jackzhang144/ResetCardBar/releases/download/v'+info['CFBundleShortVersionString']+'/')
# sign_update reads the matching key from Keychain locally, or from the CI secret on stdin.
import os
key = os.environ.get('SPARKLE_PRIVATE_KEY')
args=['build/Sparkle/bin/sign_update','--verify']
if key: args += ['--ed-key-file','-']
else: args += ['--account','ResetCardBar']
subprocess.run(args+[str(archive),signature], input=key, text=True, check=True)
print('PASS: release version, HTTPS URL, archive length and EdDSA signature')
