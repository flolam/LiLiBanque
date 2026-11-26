#!/usr/bin/env python3
"""Execute the real addon in Lua 5.1 (pip install lupa==2.8).

PY_CHECK decodes an in-game export independently of the Lua encoder: base64, CRC32 (zlib),
JSON parse, then compares with the expected subset built from the Lua table itself.
"""
from pathlib import Path
from typing import Any
import base64
import binascii
import hashlib
import json
import os
import re
import sys
import zlib
try:
    from lupa.lua51 import LuaRuntime
except ImportError:
    if not os.environ.get('LUPA_PATH'):
        raise
    sys.path.insert(0, os.environ['LUPA_PATH'])
    from lupa.lua51 import LuaRuntime
ROOT = Path(__file__).resolve().parents[1]
# Exact Sync.lua shipped in v1.1.1: the compatibility test must run the real old receiver.
assert hashlib.sha256((ROOT / 'tests/compat/sync-1.1.1.lua').read_bytes()).hexdigest() == '270cdcc94503a4dc8646b5c8e8b5aecf29b7e38a15892154f44bb396dcecf1af'
assert hashlib.sha256((ROOT / 'tests/compat/core-1.2.0.lua').read_bytes()).hexdigest() == '7ee3eb33de6c8afff068ae263a2da0183fa85d1ae4ef3e9cf9a03668e75e5681'
# encoding=None: Lua strings stay bytes, so invalid UTF-8 in test data reaches Python intact.
runtime: Any = LuaRuntime  # stubs do not describe byte mode
lua = runtime(unpack_returned_tuples=True, encoding=None)
lua_type = lua.eval(b'type')
ARRAYS = {'bankMoney', 'gaps'}


def to_py(value, key=None):
    if isinstance(value, bytes):
        return value.decode('utf-8', errors='replace')
    if lua_type(value) != b'table':
        return value
    items = list(value.items())
    keys = [k for k, _ in items]
    if key in ARRAYS or (key not in {'stock', 'slots'} and keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1))):
        return [to_py(value[i]) for i in range(1, len(keys) + 1)]
    out = {}
    for k, v in items:
        name = k.decode('utf-8', errors='replace') if isinstance(k, bytes) else str(k)
        out[name] = to_py(v, name)
    return out


def expected_payload(db):
    full = to_py(db)
    assert isinstance(full, dict)
    return {
        'schema': full['schema'], 'addonVersion': full['addonVersion'], 'guild': full['guild'],
        'scannedBy': full.get('scannedBy', {}), 'ledger': full.get('ledger', {}), 'events': full.get('events', {}),
        'roster': full.get('roster', {'scannedAt': 0, 'members': {}}),
        'bankMoney': full.get('bankMoney', [])[-30:], 'gaps': full.get('gaps', []),
        'stock': full.get('stock', {}),
    }


def py_check(export, db):
    try:
        text = export.decode('ascii')
        match = re.fullmatch(r'!LILI1!([A-Za-z0-9+/]*={0,2})!([0-9a-f]{8})', text)
        if not match:
            return b'format invalide'
        raw = base64.b64decode(match.group(1), validate=True)
        if base64.b64encode(raw).decode() != match.group(1):
            return b'base64 non canonique'
        if '%08x' % zlib.crc32(raw) != match.group(2):
            return b'crc32 different'
        decoded = json.loads(raw.decode('utf-8'))  # strict UTF-8: raises on invalid bytes
        want = expected_payload(db)
        if decoded != want:
            for k in want:
                if decoded.get(k) != want[k]:
                    return ('contenu different sur ' + k).encode()
            return b'contenu different'
        return b'ok'
    except (ValueError, binascii.Error, UnicodeDecodeError) as err:
        return ('erreur ' + type(err).__name__ + ': ' + str(err)).encode()


g = lua.globals()
g[b'ROOT'] = str(ROOT).encode()
g[b'PY_CHECK'] = py_check
g[b'PY_CRC32'] = lambda s: ('%08x' % zlib.crc32(s)).encode()
# The older shared suite defines a global test(), so run the standalone transport tests first.
if legacy_root := os.environ.get('STOCK_LEGACY_ROOT'):
    g[b'STOCK_LEGACY_ROOT'] = str(Path(legacy_root).resolve()).encode()
if legacy_root := os.environ.get('OFFICER_LEGACY_ROOT'):
    legacy = Path(legacy_root).resolve()
    for module, digest in {
        'Core': '1d6b57b7278af7d8952824658571115400b94d217a9507fe4b48f53eb594b390',
        'Wire': '4f764ddefd72f45b2223c06a3d4e5dd73f173363e8a25f30fdacc181dba76c96',
        'Sync': '5ec54a99fda45c7d010d8d0505362f2e063dfaa1c29b9bd2cc9ebbba2448cae0',
    }.items():
        assert hashlib.sha256((legacy / 'LiLiBanque' / f'{module}.lua').read_bytes()).hexdigest() == digest, f'v1.4.1 fixture differs: {module}'
    g[b'OFFICER_LEGACY_ROOT'] = str(legacy).encode()
for suite in ('p2p-catchup.lua', 'stock-p2p.lua', 'test.lua', 'ui-redesign.lua', 'coffre.lua'):
    lua.execute((ROOT / 'tests' / suite).read_bytes())
