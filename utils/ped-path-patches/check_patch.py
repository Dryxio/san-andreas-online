#!/usr/bin/env python3
"""Check a compiled path patch the way the client will, before shipping it.

Parses NPEDPAT1/NPEDPAT2 with the same limits as Shared/sdk/PedPathPatchFormat.h,
applies it to the stock NODES data and verifies the effective graph with the
rules CPedPathPatchesSA enforces (and the GTA behaviour behind them):
pedestrian links reciprocal with equal cost and matching flood groups; road
nodes with 1-12 links, reciprocal links sharing navi and length, distinct navi
per node, flood groups consistent, navi attached to the lower endpoint, nodes
inside their region, and dead-end hints that cannot loop.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import compile_world as world  # noqa: E402


class Reader:
    def __init__(self, data):
        self.data, self.offset = data, 0

    def take(self, fmt):
        size = struct.calcsize(fmt)
        if self.offset + size > len(self.data):
            raise ValueError('truncated-patch')
        values = struct.unpack_from(fmt, self.data, self.offset)
        self.offset += size
        return values if len(values) > 1 else values[0]


def parse(data):
    r = Reader(data)
    magic = data[:8]
    r.offset = 8
    if magic not in (b'NPEDPAT1', b'NPEDPAT2'):
        raise ValueError('unsupported-patch-format')
    roads = magic == b'NPEDPAT2'
    if r.take('<I') != 64:
        raise ValueError('invalid-area-count')
    areas = {}
    for _ in range(64):
        a, nodes, vehicles, addresses, cars = r.take('<5I')
        digest = r.data[r.offset:r.offset + 32]
        r.offset += 32
        peds = {}
        for _ in range(r.take('<I')):
            node, x, y, z, width, flood, enabled, count = r.take('<H3h4B')
            links = [r.take('<HHBB') for _ in range(count)]
            if node < vehicles or node in peds or enabled > 1 or count > 15 or (not enabled and count):
                raise ValueError('invalid-ped-node')
            peds[node] = dict(pos=(x, y, z), flood=flood, enabled=bool(enabled), links=[((la, ln), length, flags) for la, ln, length, flags in links])
        vehicle_edits, navi_edits = {}, {}
        if roads:
            for _ in range(r.take('<I')):
                node, x, y, z, width, flood, flags, speed, spawn, count = r.take('<H3h6B')
                links = [r.take('<HHBH') for _ in range(count)]
                if node >= vehicles or node in vehicle_edits or flags & 0x0F or speed > 3 or not 1 <= count <= 12 or width > 127:
                    raise ValueError('invalid-vehicle-node')
                if len({l[3] for l in links}) != count:
                    raise ValueError('invalid-vehicle-link')
                vehicle_edits[node] = dict(pos=(x, y, z), flood=flood, flags=flags, spawn=spawn,
                                           links=[((la, ln), length, navi) for la, ln, length, navi in links])
            for _ in range(r.take('<I')):
                nid, x, y, aa, an, dx, dy, width, lanes, light = r.take('<H2hHH2b3B')
                if nid >= 1024 or nid in navi_edits or aa >= 64 or width > 127 or lanes > 0x7F or light > 3:
                    raise ValueError('invalid-navi-record')
                navi_edits[nid] = dict(attached=(aa, an), lanes=lanes)
        areas[a] = dict(nodes=nodes, vehicles=vehicles, addresses=addresses, cars=cars, digest=digest,
                        peds=peds, roads=vehicle_edits, navi=navi_edits)
    if r.offset != len(data):
        raise ValueError('trailing-data')
    return areas


def check(stock_areas, stock, patch):
    for a, p in patch.items():
        s = stock_areas[a]
        if (p['nodes'], p['vehicles'], p['addresses'], p['cars'], p['digest']) != (s.count, s.vehicles, s.addresses, s.cars, s.digest):
            raise ValueError(f'base-fingerprint-mismatch in region {a}')
    # Pedestrians.
    ped = {}
    for a, s in stock_areas.items():
        for n in range(s.vehicles, s.count):
            e = s.edit(n)
            ped[(a, n)] = dict(enabled=True, flood=e['flood'], links=[((l['area'], l['node']), l['length']) for l in e['links']])
        for n, e in patch[a]['peds'].items():
            ped[(a, n)] = dict(enabled=e['enabled'], flood=e['flood'], links=[(t, length) for t, length, _ in e['links']])
    for key, node in ped.items():
        for to, length in node['links']:
            target = ped.get(to)
            if target is None or not target['enabled'] or target['flood'] != node['flood'] or not length:
                raise ValueError(f'pedestrian link {key}->{to} targets a missing/disabled node or another flood group')
            if not any(b == key and bl == length for b, bl in target['links']):
                raise ValueError(f'pedestrian link {key}->{to} is not reciprocal with equal cost')
    # Roads.
    road, navi = {}, {}
    for a, s in stock_areas.items():
        for n in range(s.vehicles):
            node = s.nodes[n]
            road[(a, n)] = dict(links=stock[a].road(n), flood=node[23], flags=node[24] & 0xF0, spawn=node[26],
                               pos=struct.unpack_from('<3h', node, 8), edited=False)
        for nid, rec in enumerate(stock[a].navi):
            navi[(a, nid)] = dict(attached=struct.unpack_from('<HH', rec, 4), edited=False)
        for n, e in patch[a]['roads'].items():
            road[(a, n)] = dict(links=e['links'], flood=e['flood'], flags=e['flags'], spawn=e['spawn'], pos=e['pos'], edited=True)
        for nid, e in patch[a]['navi'].items():
            navi[(a, nid)] = dict(attached=e['attached'], edited=True)
    for key, node in road.items():
        a = key[0]
        if not 1 <= len(node['links']) <= 12:
            raise ValueError(f'road node {key} has {len(node["links"])} links')
        if node['edited'] and world.region_of(node['pos'][0] / 8, node['pos'][1] / 8) != a:
            raise ValueError(f'road node {key} lies outside its region')
        seen = set()
        for to, length, n in node['links']:
            target = road.get(to)
            if target is None or not length:
                raise ValueError(f'road link {key}->{to} is invalid')
            if target['flood'] != node['flood']:
                raise ValueError(f'road link {key}->{to} crosses flood groups')
            if not any(b == key and bl == length and bn == n for b, bl, bn in target['links']):
                raise ValueError(f'road link {key}->{to} has no reverse link with the same navi and length')
            if n in seen:
                raise ValueError(f'road node {key} repeats a navi record')
            seen.add(n)
            host = (n >> 10, n & 0x3FF)
            if host not in navi:
                raise ValueError(f'road link {key}->{to} names a missing navi {host}')
            if node['edited'] or target['edited'] or navi[host]['edited']:
                if tuple(navi[host]['attached']) != min(key, to):
                    raise ValueError(f'navi {host} is not on the lower endpoint of {key}-{to}')
                if (node['flags'] & 0x80) != (target['flags'] & 0x80):
                    raise ValueError(f'road link {key}->{to} joins land and water')
                mid = ((node['pos'][0] + target['pos'][0]) / 16, (node['pos'][1] + target['pos'][1]) / 16)
                if host[0] not in (a, to[0], world.region_of(*mid)):
                    raise ValueError(f'navi {host} is hosted outside the regions of {key}-{to}')
        if node['edited'] and node['flags'] & 0x10:
            prev, cur = None, key
            for _ in range(10000):
                nxt = [t for t, _, _ in road[cur]['links'] if t != prev and (road[t]['spawn'] >> 4 == 0 or road[t]['spawn'] >> 4 > 10)]
                if len(nxt) != 1:
                    break
                prev, cur = cur, nxt[0]
            else:
                raise ValueError(f'dead-end hint on {key} loops')
    counts = {a: max([p['cars']] + [nid + 1 for nid in p['navi']]) for a, p in patch.items()}
    if max(counts.values()) > 1024:
        raise ValueError('a region exceeds 1024 navi records')
    return dict(regionsEdited=sum(1 for p in patch.values() if p['peds'] or p['roads'] or p['navi']),
                roadEdits=sum(len(p['roads']) for p in patch.values()), naviEdits=sum(len(p['navi']) for p in patch.values()),
                pedEdits=sum(len(p['peds']) for p in patch.values()), maxNaviInRegion=max(counts.values()))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--paths', type=Path, required=True)
    p.add_argument('patch', type=Path)
    args = p.parse_args()
    data = args.patch.read_bytes()
    stock_areas, stock = world.load(args.paths)
    print(json.dumps(dict(check(stock_areas, stock, parse(data)), revision=hashlib.sha256(data).hexdigest(), status='ok')))


if __name__ == '__main__':
    main()
