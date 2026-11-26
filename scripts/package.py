#!/usr/bin/env python3
"""Package only the installable addon; emit WowUp GitHub release metadata."""
from pathlib import Path
import argparse
import json
import re
from zipfile import ZipFile, ZIP_DEFLATED, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
# Textures are loaded by path at runtime, not listed in the TOC.
CODE = ['Addon.lua', 'Core.lua', 'Export.lua', 'LiLiBanque.toc', 'Sync.lua', 'UI.lua', 'Wire.lua']
EXPECTED = sorted(CODE + ['Art/LiLiNote.tga'])

def build(tag: str | None = None, output: Path | None = None):
    source = ROOT / 'LiLiBanque'
    toc = (source / 'LiLiBanque.toc').read_text(encoding='utf-8')
    version_match = re.search(r'^## Version: (\S+)$', toc, re.M)
    interface_match = re.search(r'^## Interface: (\d+)$', toc, re.M)
    assert version_match is not None and interface_match is not None, 'Invalid TOC'
    version = version_match.group(1)
    listed = [line.strip() for line in toc.splitlines() if line.strip() and not line.startswith('#')]
    if sorted(listed + ['LiLiBanque.toc']) != CODE:
        raise ValueError(f'TOC file list differs: {listed}')
    interface = int(interface_match.group(1))
    core = (source / 'Core.lua').read_text(encoding='utf-8')
    if f"C.VERSION = '{version}'" not in core:
        raise ValueError('TOC/Core.lua versions differ')
    if tag is not None and tag != f'v{version}':
        raise ValueError(f'Tag {tag!r} differs from addon v{version}')
    out = output or ROOT / 'dist'
    out.mkdir(parents=True, exist_ok=True)
    # -forever also matches WowUp legacy filename detection if release.json is unavailable.
    name = f'LiLiBanque-{version}-forever.zip'
    files = sorted(p.relative_to(source).as_posix() for p in source.rglob('*') if p.is_file())
    if files != EXPECTED:
        raise ValueError(f'Addon file list differs: {files}')
    with ZipFile(out / name, 'w', ZIP_DEFLATED) as archive:
        for file in files:
            entry = ZipInfo('LiLiBanque/' + file, date_time=(2026, 1, 1, 0, 0, 0))
            entry.compress_type = ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, (source / file).read_bytes())
    metadata = {'releases': [{'name': f'v{version}', 'filename': name, 'nolib': False,
                              'metadata': [{'flavor': 'forever', 'interface': interface}]}]}
    (out / 'release.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
    with ZipFile(out / name) as archive:
        assert archive.testzip() is None
        assert archive.namelist() == ['LiLiBanque/' + f for f in files]
    print(f'OK {name}: {len(files)} fichiers ; flavor=forever interface={interface}')
    return out / name

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--tag')
    args = parser.parse_args()
    build(args.tag)
