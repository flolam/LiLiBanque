#!/usr/bin/env python3
"""Execute the real addon in Lua 5.1 (pip install lupa==2.8).

PY_CHECK decodes an in-game export independently of the Lua encoder: base64, CRC32 (zlib),
JSON parse, then compares with the expected subset built from the Lua table itself.
"""
from pathlib import Path
import base64
import binascii
import hashlib
import json
import re
import sys
import zlib
try:
    from lupa.lua51 import LuaRuntime
except ImportError:
    import os
    if not os.environ.get('LUPA_PATH'):
        raise
    sys.path.insert(0, os.environ['LUPA_PATH'])
    from lupa.lua51 import LuaRuntime
ROOT = Path(__file__).resolve().parents[1]
# Exact Sync.lua shipped in v1.1.1: the compatibility test must run the real old receiver.
assert hashlib.sha256((ROOT / 'tests/compat/sync-1.1.1.lua').read_bytes()).hexdigest() == '270cdcc94503a4dc8646b5c8e8b5aecf29b7e38a15892154f44bb396dcecf1af'
assert hashlib.sha256((ROOT / 'tests/compat/core-1.2.0.lua').read_bytes()).hexdigest() == '7ee3eb33de6c8afff068ae263a2da0183fa85d1ae4ef3e9cf9a03668e75e5681'
# encoding=None: Lua strings stay bytes, so invalid UTF-8 in test data reaches Python intact.
lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)
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
lua.execute((ROOT / 'tests/test.lua').read_bytes())
