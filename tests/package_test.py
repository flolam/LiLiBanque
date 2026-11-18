#!/usr/bin/env python3
"""Checks the exact WowUp GitHub metadata contract, zip layout and tag guard."""
from pathlib import Path
from tempfile import TemporaryDirectory
from zipfile import ZipFile
import importlib.util
import json
import os

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('package', ROOT / 'scripts/package.py')
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
# Keep all scratch files under the explicitly configured scratch directory.
with TemporaryDirectory(prefix='lili-package-', dir=os.environ.get('TMPDIR') or None) as temp:
    out = Path(temp)
    toc_text = (ROOT / 'LiLiBanque/LiLiBanque.toc').read_text(encoding='utf-8')
    version = next(l.split(': ', 1)[1] for l in toc_text.splitlines() if l.startswith('## Version: '))
    zip_path = module.build('v' + version, out)
    with ZipFile(zip_path) as archive:
        assert archive.testzip() is None
        assert archive.namelist() == ['LiLiBanque/' + n for n in sorted(module.EXPECTED)], archive.namelist()
        assert all(n.startswith('LiLiBanque/') for n in archive.namelist())
        assert not any(n.startswith(('tests/', 'fixtures/')) for n in archive.namelist())
        toc = archive.read('LiLiBanque/LiLiBanque.toc').decode()
        assert '## Interface: 16001' in toc
        assert '## SavedVariables: LiLiBanqueDB\n' in toc, 'account upload must remain DB-only'
        assert '## SavedVariablesPerCharacter: LiLiBanqueState\n' in toc
        assert '## Author: La Bande à Li Li\n' in toc
        # Load order: data layer, transport, sync, export, then the addon and its window.
        listed = [l for l in toc.splitlines() if l and not l.startswith('#')]
        assert listed == ['Core.lua', 'Wire.lua', 'Sync.lua', 'Export.lua', 'Addon.lua', 'UI.lua'], listed
        for name in listed:
            assert b'loadstring' not in archive.read('LiLiBanque/' + name), name
    metadata = json.loads((out / 'release.json').read_text(encoding='utf-8'))
    # WowUp: release.nolib===false, metadata.flavor==='forever', matching asset.name.
    release = next(r for r in metadata['releases'] if r['nolib'] is False
                   and any(m['flavor'] == 'forever' for m in r['metadata']))
    assert release['filename'] == zip_path.name
    assert release['metadata'][0]['interface'] == 16001
    try:
        module.build('v9.9.9', out)
        raise AssertionError('mismatched tag accepted')
    except ValueError:
        pass
print(f'PASS packaging v{version} : layout, ordre TOC, CRC, metadata WowUp forever/16001, garde du tag')
