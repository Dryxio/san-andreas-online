#!/usr/bin/env python3
"""Verify the supplied render-only catalog without requiring GTA or a VM."""
import hashlib
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / 'Shared/data/MTA San Andreas/MTA/data/vegetation-lod'

def chunks(data, start, end):
    while start < end:
        kind, size, version = struct.unpack_from('<III', data, start)
        stop = start + 12 + size
        assert stop <= end, 'Truncated RenderWare chunk'
        yield kind, start + 12, stop
        start = stop
    assert start == end

def main():
    manifest = json.loads((DATA / 'manifest.json').read_text())
    ids = set()
    used_textures = set()
    def collect_textures(data, start, end):
        for kind, a, b in chunks(data, start, end):
            if kind == 6:
                names = [data[x:y].split(b'\0')[0].decode().lower()
                         for tag, x, y in chunks(data, a, b) if tag == 2]
                if names:
                    used_textures.add(names[0])
            elif kind in (16, 26, 15, 8, 7):
                collect_textures(data, a, b)
    include = (ROOT / 'Client/game_sa/CVegetationLODModelsSA.inc').read_text()
    for row in manifest['models']:
        assert row['id'] not in ids
        ids.add(row['id'])
        data = (DATA / row['asset']).read_bytes()
        collect_textures(data, 0, len(data))
        assert hashlib.sha256(data).hexdigest() == row['sha256']
        assert row.get('prelight', {}).get('method') == 'closest-stock-triangle-rgb-v1', 'Regenerate calibrated day/night prelight'
        assert len(row['prelight']['stock_sha256']) == 64
        assert len(row['original_asset_sha256']) == 64
        assert f'{{{row["id"]}, "{row["asset"]}"' in include
        assert 0 < row['transition'] < row['range'] <= 1600
        top = list(chunks(data, 0, len(data)))
        assert len(top) == 1 and top[0][0] == 16
        children = list(chunks(data, top[0][1], top[0][2]))
        atomics = [v for v in children if v[0] == 20]
        assert len(atomics) == 1, (row['asset'], 'requires one atomic')
        for kind, start, end in children:
            if kind != 14:
                continue
            frame_struct = next(chunks(data, start, end))
            assert frame_struct[0] == 1
            count = struct.unpack_from('<I', data, frame_struct[1])[0]
            for i in range(count):
                matrix = struct.unpack_from('<12f', data, frame_struct[1] + 4 + 56 * i)
                identity = (1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0)
                assert all(abs(a-b) < 1e-5 for a, b in zip(matrix, identity)), 'Asset needs a local transform bake'
    assert len(ids) == 89
    assert not list(DATA.glob('*.ipl')) and not list(DATA.glob('*.ide'))
    txd = (DATA / 'LODvegetation.txd').read_bytes()
    kind, start, end = next(chunks(txd, 0, len(txd)))
    assert kind == 22
    available_textures = set()
    for tag, a, b in chunks(txd, start, end):
        if tag == 21:
            struct_tag, payload, _ = next(chunks(txd, a, b))
            assert struct_tag == 1
            available_textures.add(txd[payload + 8:payload + 40].split(b'\0')[0].decode().lower())
    assert used_textures <= available_textures, used_textures - available_textures
    print(f'{len(ids)} asset mappings, hashes, atomic counts and local frames verified')
    print(f'All {len(used_textures)} referenced textures exist in the supplied dictionary')

if __name__ == '__main__':
    main()
