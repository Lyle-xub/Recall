#!/usr/bin/env python3
"""Sign Recall with a stable identity. Never silently ship per-build ad-hoc identities."""
import os
from pathlib import Path
import re
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
entitlements = Path(__file__).resolve().parents[1] / 'macOS' / 'Recall.entitlements'
identity = os.environ.get('RECALL_CODESIGN_IDENTITY')
if not identity:
    available = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    choices = re.findall(r'\) ([0-9A-F]{40}) "([^"]+)"', available)
    identity = next((fingerprint for fingerprint, name in choices if name.startswith('Developer ID Application:')), None)
    identity = identity or next((fingerprint for fingerprint, name in choices if name.startswith('Apple Development:')), None)
if not identity:
    if os.environ.get('RECALL_ALLOW_ADHOC') == '1':
        identity = '-'
        print('CI-only ad-hoc signature. Do not use this artifact for persistent screen-recording authorization.')
    else:
        sys.exit('A stable signing identity is required. Set RECALL_CODESIGN_IDENTITY to an Apple Development or Developer ID identity. RECALL_ALLOW_ADHOC=1 is for CI compile artifacts only.')

magic = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf'}
options = ['--force', '--sign', identity]
if identity != '-':
    options += ['--options', 'runtime', '--timestamp']
# Sign bundled native engines and dylibs before the app, with the same team identity.
for file in sorted(app.rglob('*')):
    if not file.is_file() or file.is_symlink():
        continue
    with file.open('rb') as stream:
        is_macho = stream.read(4) in magic
    if is_macho:
        access = ['--entitlements', str(entitlements)] if file == app / 'Contents/MacOS/Recall' else []
        subprocess.run(['codesign', *options, *access, str(file)], check=True)
subprocess.run(['codesign', *options, '--entitlements', str(entitlements), str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
subprocess.run(['codesign', '-d', '-r-', str(app)], check=True)
