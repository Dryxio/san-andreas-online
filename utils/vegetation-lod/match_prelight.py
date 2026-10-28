#!/usr/bin/env python3
"""Project stock day/night RGB onto LOD vertices; preserve geometry and alpha.

Run with --gta-img pointing to an unmodified GTA SA gta3.img. All inputs are
validated before writing. --check verifies reproducibility without changing files.
No GTA models or textures are copied into the repository.
"""
import argparse
import hashlib
import json
import math
import struct
from pathlib import Path

DATA = Path(__file__).resolve().parents[2] / 'Shared/data/MTA San Andreas/MTA/data/vegetation-lod'
METHOD = 'closest-stock-triangle-rgb-v1'


def chunks(data, start, end):
    while start < end:
        if start + 12 > end:
            raise ValueError('Truncated chunk header')
        tag, size, _ = struct.unpack_from('<III', data, start)
        stop = start + 12 + size
        if stop > end:
            raise ValueError('Truncated chunk payload')
        yield tag, start + 12, stop
        start = stop


def geometry(data):
    top = list(chunks(data, 0, len(data)))
    if len(top) != 1 or top[0][0] != 16:
        raise ValueError('Expected one RenderWare clump')
    children = list(chunks(data, top[0][1], top[0][2]))
    # Projection is in model space; reject unbaked frames instead of silently
    # assigning colors from a differently transformed source mesh.
    for tag, a, b in children:
        if tag == 14:
            _, x, _ = next(chunks(data, a, b))
            for i in range(struct.unpack_from('<I', data, x)[0]):
                values = struct.unpack_from('<12f', data, x + 4 + i * 56)
                identity = (1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0)
                if any(abs(u - v) > 1e-5 for u, v in zip(values, identity)):
                    raise ValueError('Non-identity model frame')
    _, a, b = next(c for c in children if c[0] == 26)
    geometries = [c for c in chunks(data, a, b) if c[0] == 15]
    if len(geometries) != 1:
        raise ValueError('Expected one geometry')
    _, a, b = geometries[0]
    parts = list(chunks(data, a, b))
    _, x, end = parts[0]
    flags, triangles, vertices, morphs = struct.unpack_from('<4I', data, x)
    if flags & 0x01000000 or not flags & 8 or morphs != 1 or not vertices:
        raise ValueError('Requires non-native, prelit, single-morph geometry')
    day = x + 16
    uv_sets = (flags >> 16) & 255
    if not uv_sets:
        uv_sets = 2 if flags & 128 else int(bool(flags & 4))
    pos = day + vertices * 4 + vertices * uv_sets * 8
    faces = []
    for i in range(triangles):
        v1, v2, _, v3 = struct.unpack_from('<4H', data, pos + i * 8)
        if max(v1, v2, v3) >= vertices:
            raise ValueError('Invalid triangle index')
        faces.append((v1, v2, v3))
    pos += triangles * 8
    has_vertices, has_normals = struct.unpack_from('<II', data, pos + 16)
    pos += 24
    if not has_vertices or pos + vertices * 12 * (1 + bool(has_normals)) != end:
        raise ValueError('Unexpected morph target layout/version')
    points = [struct.unpack_from('<3f', data, pos + i * 12) for i in range(vertices)]
    if not all(math.isfinite(v) for point in points for v in point):
        raise ValueError('Non-finite position')
    night = None
    for tag, a, b in parts:
        if tag == 3:
            for extension, x, y in chunks(data, a, b):
                if extension == 0x253F2F9 and y - x == 4 + vertices * 4 and struct.unpack_from('<I', data, x)[0]:
                    night = x + 4
    if night is None or not faces:
        raise ValueError('Missing night colors or triangles')
    return points, faces, day, night


def sub(a, b):
    return tuple(x - y for x, y in zip(a, b))


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def closest_weights(p, a, b, c):
    """Closest triangle point, including degenerate faces, as barycentric weights."""
    ab, ac, ap = sub(b, a), sub(c, a), sub(p, a)
    aa, bb, cc = dot(ab, ab), dot(ab, ac), dot(ac, ac)
    determinant = aa * cc - bb * bb
    candidates = []
    if determinant > 1e-12:
        u = (cc * dot(ap, ab) - bb * dot(ap, ac)) / determinant
        v = (aa * dot(ap, ac) - bb * dot(ap, ab)) / determinant
        if u >= 0 and v >= 0 and u + v <= 1:
            candidates.append((1 - u - v, u, v))
    for i, j in ((0, 1), (1, 2), (2, 0)):
        corners = (a, b, c)
        edge = sub(corners[j], corners[i])
        length = dot(edge, edge)
        t = max(0, min(1, dot(sub(p, corners[i]), edge) / length)) if length else 0
        w = [0.0, 0.0, 0.0]
        w[i], w[j] = 1 - t, t
        candidates.append(tuple(w))
    def distance(weights):
        point = tuple(sum(weights[j] * (a, b, c)[j][k] for j in range(3)) for k in range(3))
        delta = sub(p, point)
        return dot(delta, delta)
    weights = min(candidates, key=distance)
    return distance(weights), weights


def project(lod, stock):
    points, _, day, night = geometry(lod)
    source_points, faces, source_day, source_night = geometry(stock)
    result = bytearray(lod)
    for i, point in enumerate(points):
        # Use one spatial match for both color sets to avoid a shifting shading
        # pattern at dawn/dusk. Alpha belongs to the LOD silhouette, not the HD.
        face, (_, weights) = min(((f, closest_weights(point, *(source_points[v] for v in f))) for f in faces), key=lambda item: item[1][0])
        for destination, source in ((day, source_day), (night, source_night)):
            for channel in range(3):
                value = sum(weights[j] * stock[source + face[j] * 4 + channel] for j in range(3))
                result[destination + i * 4 + channel] = max(0, min(255, int(value + 0.5)))
    return bytes(result)


def read_img(path, names):
    result = {}
    with path.open('rb') as archive:
        magic, count = struct.unpack('<4sI', archive.read(8))
        if magic != b'VER2':
            raise ValueError('Expected IMG v2')
        entries = {}
        for _ in range(count):
            offset, sectors, _, name = struct.unpack('<IHH24s', archive.read(32))
            entries[name.split(b'\0')[0].decode().lower()] = (offset, sectors)
        for name in names:
            offset, sectors = entries[name.lower()]
            archive.seek(offset * 2048)
            data = archive.read(sectors * 2048)
            length = 12 + struct.unpack_from('<I', data, 4)[0]
            if length > len(data):
                raise ValueError('Truncated model in IMG')
            result[name] = data[:length]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gta-img', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    manifest_path = DATA / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    sources = read_img(args.gta_img, {row['source'] + '.dff' for row in manifest['models']})
    pending = []
    for row in manifest['models']:
        path = DATA / row['asset']
        original = path.read_bytes()
        if hashlib.sha256(original).hexdigest() != row['sha256']:
            raise ValueError(f'Unreviewed asset change: {path.name}')
        stock = sources[row['source'] + '.dff']
        calibrated = project(original, stock)
        provenance = {'method': METHOD, 'stock_sha256': hashlib.sha256(stock).hexdigest()}
        if args.check:
            if original != calibrated or row.get('prelight') != provenance:
                raise ValueError(f'Prelight needs regeneration: {path.name}')
        else:
            row.setdefault('original_asset_sha256', row['sha256'])
            row['prelight'] = provenance
            row['sha256'] = hashlib.sha256(calibrated).hexdigest()
            pending.append((path, calibrated))
    for path, data in pending:
        path.write_bytes(data)
    if not args.check:
        manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'{len(manifest["models"])} LOD day/night prelights {"verified" if args.check else "matched"}; geometry, textures and alpha preserved')


if __name__ == '__main__':
    main()
