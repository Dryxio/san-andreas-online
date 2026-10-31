#!/usr/bin/env python3
"""Compile a custom-map road and sidewalk graph into an NPEDPAT2 path patch.

A custom map replaces San Andreas in some regions. This tool frees every stock
road and sidewalk node in those regions, places the map's own graph in the
freed slots and derives everything GTA's car and pedestrian code assumes
(navi records, lane bits, lengths, flood groups, dead-end hints). It never
distributes vanilla NODES data: the patch only carries edits plus SHA-256
fingerprints of the base it was built against.

Spec (JSON):
  {"replace": [area, ...],                     # optional; regions holding custom nodes are always replaced
   "roads": {"nodes": [{"id": key, "position": [x, y, z], "speed": 0|1|2, "spawn": 0-15, "width": 0-127}],
             "edges": [{"a": key, "b": key, "lanes": [a_to_b, b_to_a], "light": 0|1|2}]},
   "sidewalks": {"nodes": [{"id": key, "position": [x, y, z]}],
                 "edges": [{"a": key, "b": key, "crossing": 0-3}]}}

Rules that come from GTA SA 1.0 US (see README.md):
  - vehicle node ids are the stock range of their region; roads are placed in
    freed slots, never appended, and nodes must lie inside their region;
  - every road edge is stored in both directions with one shared navi record
    attached to the lower address, pointing toward it, at the midpoint;
  - no road node may have zero links: unused slots are parked as linked pairs
    under the map with zero lanes;
  - lengths are truncated 3-D distances in 1..255.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import compile_patch as base  # noqa: E402

AREAS = 64
MAX_NAVI = 1024
MAX_ROAD_LINKS = 12
PARKED_FLOOD = 255
PARKED_Z = -4000.0


def region_of(x, y):
    axis = lambda v: min(7, max(0, math.floor((v + 3000) / 750)))
    return axis(y) * 8 + axis(x)


def region_centre(area):
    return -3000 + (area % 8) * 750 + 375, -3000 + (area // 8) * 750 + 375


class Stock:
    """Stock road data of one region, on top of compile_patch.Area."""

    def __init__(self, area):
        self.area = area
        data = area.raw
        offset = 20 + area.count * 28
        self.navi = [bytearray(data[offset + i * 14:offset + (i + 1) * 14]) for i in range(area.cars)]
        offset += area.cars * 14
        nlinks = area.addresses + 192 if area.addresses else 0
        offset += nlinks * 4
        self.navi_links = list(struct.unpack_from(f'<{area.addresses}H', data, offset)) if area.addresses else []

    def road(self, node):
        n = self.area.nodes[node]
        base_id = struct.unpack_from('<H', n, 16)[0]
        links = []
        for k in range(base_id, base_id + (n[24] & 15)):
            ta, tn = self.area.links[k]
            links.append(((ta, tn), self.area.lengths[k], self.navi_links[k]))
        return links


def load(directory):
    areas = {}
    for a in range(AREAS):
        raw = (directory / f'NODES{a}.DAT').read_bytes()
        area = base.Area(a, raw)
        area.raw = raw
        areas[a] = area
    return areas, {a: Stock(areas[a]) for a in areas}


def finite(position, label):
    if (not isinstance(position, list) or len(position) != 3 or
            any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or not -4096 <= v <= 4095.875 for v in position)):
        raise ValueError(f'{label} position outside native fixed-point range')
    return [float(v) for v in position]


def fixed(v):
    return round(v * 8)


def graph(section, kind):
    nodes, edges = {}, []
    for node in (section or {}).get('nodes', []):
        key = node['id']
        if key in nodes:
            raise ValueError(f'duplicate {kind} node {key!r}')
        nodes[key] = dict(node, position=finite(node['position'], kind))
    seen = set()
    for edge in (section or {}).get('edges', []):
        a, b = edge['a'], edge['b']
        if a not in nodes or b not in nodes or a == b:
            raise ValueError(f'invalid {kind} edge {a!r}-{b!r}')
        key = frozenset((a, b))
        if key in seen:
            raise ValueError(f'duplicate {kind} edge {a!r}-{b!r}')
        seen.add(key)
        length = int(math.dist(nodes[a]['position'], nodes[b]['position']))
        if not 1 <= length <= 255:
            raise ValueError(f'{kind} edge {a!r}-{b!r} must be 1-255 m long (got {length}); split or merge it')
        edges.append(dict(edge, length=length))
    return nodes, edges


def components(keys, edges):
    parent = {k: k for k in keys}

    def find(k):
        while parent[k] != k:
            parent[k] = parent[parent[k]]
            k = parent[k]
        return k
    for e in edges:
        parent[find(e['a'])] = find(e['b'])
    return {k: find(k) for k in keys}


def compile_world(areas, stock, spec):
    roads, road_edges = graph(spec.get('roads'), 'road')
    walks, walk_edges = graph(spec.get('sidewalks'), 'sidewalk')
    replace = {base.integer(a, 0, 63, 'area') for a in spec.get('replace', [])}
    replace |= {region_of(*n['position'][:2]) for n in roads.values()}
    replace |= {region_of(*n['position'][:2]) for n in walks.values()}

    # ---- Roads -----------------------------------------------------------
    # Stock road graph, then remove every node of the replaced regions. A
    # neighbour left without links cannot stay (zero links divides by zero),
    # so its whole region joins the replacement and the closure repeats.
    stock_roads = {(a, n): stock[a].road(n) for a in range(AREAS) for n in range(areas[a].vehicles)}

    def unsafe_neighbour(key, links):
        # A neighbour that loses links becomes an edited node, which the client
        # holds to the derived rules. A few stock nodes break them (17 lie
        # outside their region; four LS airport tunnel navi hang on a third
        # node), so such a region is replaced instead of edited.
        a, n = key
        x, y = struct.unpack_from('<2h', areas[a].nodes[n], 8)
        if region_of(x / 8, y / 8) != a:
            return True
        for to, _, navi in links:
            host, nid = navi >> 10, navi & 0x3FF
            if nid >= len(stock[host].navi) or struct.unpack_from('<HH', stock[host].navi[nid], 4) != min(key, to):
                return True
        return False
    while True:
        survivors = {k: [l for l in v if l[0][0] not in replace] for k, v in stock_roads.items() if k[0] not in replace}
        orphaned = {k[0] for k, v in survivors.items() if not v}
        orphaned |= {k[0] for k, v in survivors.items() if len(v) != len(stock_roads[k]) and unsafe_neighbour(k, v)}
        if not orphaned:
            break
        replace |= orphaned

    by_region = {}
    for key, node in roads.items():
        by_region.setdefault(region_of(*node['position'][:2]), []).append(key)
    address = {}
    for area, keys in sorted(by_region.items()):
        if len(keys) > areas[area].vehicles:
            raise ValueError(f'region {area} has {areas[area].vehicles} road slots but the map needs {len(keys)}')
        for slot, key in enumerate(sorted(keys, key=lambda k: (roads[k]['position'][1], roads[k]['position'][0]))):
            address[key] = (area, slot)

    adjacency = {k: [] for k in roads}
    for e in road_edges:
        adjacency[e['a']].append(e)
        adjacency[e['b']].append(e)
    for key, links in adjacency.items():
        if not links or len(links) > MAX_ROAD_LINKS:
            raise ValueError(f'road node {key!r} has {len(links)} links (needs 1-{MAX_ROAD_LINKS})')

    # Navi ids: anything still referenced by a surviving stock link keeps its
    # id; everything else hosted in a replaced region becomes free.
    referenced = {}
    for links in survivors.values():
        for _, _, navi in links:
            referenced.setdefault(navi >> 10, set()).add(navi & 0x3FF)
    next_free = {a: iter([i for i in range(MAX_NAVI) if i not in referenced.get(a, set())]) for a in replace}

    def take_navi(area):
        if area not in next_free:
            raise ValueError(f'navi host region {area} is not replaced')
        try:
            return next(next_free[area])
        except StopIteration:
            raise ValueError(f'region {area} exceeds {MAX_NAVI} navi records') from None

    used_floods = {areas[a].nodes[n][23] for (a, n) in survivors}
    free_floods = iter([f for f in range(1, PARKED_FLOOD) if f not in used_floods])
    road_component = components(roads, road_edges)
    flood_of = {}
    for root in sorted(set(road_component.values()), key=str):
        try:
            flood_of[root] = next(free_floods)
        except StopIteration:
            raise ValueError('too many separate road networks for 8-bit flood groups') from None

    vehicle_edits = {a: {} for a in range(AREAS)}
    navi_edits = {a: {} for a in range(AREAS)}

    def add_navi(host, a_addr, a_pos, b_addr, b_pos, lanes_toward_a, lanes_toward_b, light, width):
        nid = take_navi(host)
        attached, other = (a_addr, b_addr) if a_addr < b_addr else (b_addr, a_addr)
        att_pos, oth_pos = (a_pos, b_pos) if a_addr < b_addr else (b_pos, a_pos)
        toward, away = (lanes_toward_a, lanes_toward_b) if a_addr < b_addr else (lanes_toward_b, lanes_toward_a)
        dx, dy = att_pos[0] - oth_pos[0], att_pos[1] - oth_pos[1]
        norm = math.hypot(dx, dy) or 1.0
        if light == 'auto':
            light = 1 if abs(dy) > abs(dx) else 2
        navi_edits[host][nid] = dict(
            position=[fixed((a_pos[0] + b_pos[0]) / 2), fixed((a_pos[1] + b_pos[1]) / 2)], attached=attached,
            direction=[max(-100, min(100, round(dx / norm * 100))), max(-100, min(100, round(dy / norm * 100)))],
            width=width, lanes=(toward & 7) | ((away & 7) << 3), light=light)
        return nid | (host << 10)

    links_of = {k: [] for k in roads}
    for e in road_edges:
        a, b = e['a'], e['b']
        lanes = e.get('lanes', [1, 1])
        ab, ba = (base.integer(v, 0, 7, 'lanes') for v in lanes)
        light = e.get('light', 0)
        if light not in (0, 1, 2, 'auto'):
            raise ValueError('light must be 0, 1, 2 or "auto"')
        pa, pb = roads[a]['position'], roads[b]['position']
        # Host the navi where the edge's midpoint lies, or in an endpoint's
        # region; either streams in with the edge (links are <= 255 m).
        host = region_of((pa[0] + pb[0]) / 2, (pa[1] + pb[1]) / 2)
        if host not in replace:
            host = address[a][0]
        attached_key = a if address[a] < address[b] else b
        width = base.integer(roads[attached_key].get('width', 0), 0, 127, 'width')
        navi = add_navi(host, address[a], pa, address[b], pb, ba, ab, light, width)
        links_of[a].append((address[b], e['length'], navi))
        links_of[b].append((address[a], e['length'], navi))

    def dead_end(start):
        """Mirror of ThisNodeWillLeadIntoADeadEnd (0x44D310) on custom roads."""
        prev, cur, steps = None, start, 0
        while steps < 100000:
            steps += 1
            nxt = [e['b'] if e['a'] == cur else e['a'] for e in adjacency[cur]]
            nxt = [k for k in nxt if k != prev and roads[k].get('behaviour', 0) in (0,) ]
            if not nxt:
                return True
            if len(nxt) > 1:
                return False
            prev, cur = cur, nxt[0]
            if cur == start:
                return False
        return False

    for key, node in roads.items():
        area, slot = address[key]
        speed = base.integer(node.get('speed', 1), 0, 2, 'speed')
        vehicle_edits[area][slot] = dict(
            position=[fixed(v) for v in node['position']], width=base.integer(node.get('width', 0), 0, 127, 'width'),
            flood=flood_of[road_component[key]], flags=0x10 if dead_end(key) else 0, speed=speed,
            spawn=base.integer(node.get('spawn', 15), 0, 15, 'spawn'), links=sorted(links_of[key]))

    # Park every freed slot that the map does not use: linked pairs (a chain
    # of three when odd) under the region, switched off, zero lanes.
    for area in sorted(replace):
        used = {address[k][1] for k in by_region.get(area, [])}
        free = [n for n in range(areas[area].vehicles) if n not in used]
        if not free:
            continue
        if len(free) == 1:
            raise ValueError(f'region {area} would leave a single unused road slot; add or remove one road node there')
        cx, cy = region_centre(area)
        groups = [free[i:i + 2] for i in range(0, len(free) - 3, 2)] + [free[len(free) - (3 if len(free) % 2 else 2):]]
        for gi, group in enumerate(groups):
            positions = [(cx - 300 + (gi % 200) * 3, cy - 300 + (gi // 200) * 3 + j * 1.5 * 2, PARKED_Z) for j in range(len(group))]
            for j in range(len(group) - 1):
                a_addr, b_addr = (area, group[j]), (area, group[j + 1])
                navi = add_navi(area, a_addr, positions[j], b_addr, positions[j + 1], 0, 0, 0, 0)
                length = int(math.dist(positions[j], positions[j + 1]))
                for me, other in ((j, j + 1), (j + 1, j)):
                    edit = vehicle_edits[area].setdefault(group[me], dict(
                        position=[fixed(v) for v in positions[me]], width=0, flood=PARKED_FLOOD, flags=0x20, speed=1, spawn=0, links=[]))
                    edit['links'].append(((area, group[other]), length, navi))

    # Neighbours outside the replaced regions keep their roads but drop links
    # into them, and lose the dead-end hint if their chain changed.
    for (a, n), links in survivors.items():
        original = stock_roads[(a, n)]
        if len(links) != len(original):
            node = areas[a].nodes[n]
            vehicle_edits[a][n] = dict(
                position=list(struct.unpack_from('<3h', node, 8)), width=node[22], flood=node[23],
                flags=(node[24] & 0xC0) | (node[24] & 0x20), speed=(node[25] >> 4) & 3, spawn=node[26], links=links)

    # Unused freed navi ids in replaced regions: keep geometry, remove lanes.
    for area in replace:
        for nid in range(stock[area].area.cars):
            if nid in navi_edits[area] or nid in referenced.get(area, set()):
                continue
            rec = stock[area].navi[nid]
            navi_edits[area][nid] = dict(
                position=list(struct.unpack_from('<2h', rec, 0)), attached=struct.unpack_from('<HH', rec, 4),
                direction=list(struct.unpack_from('<2b', rec, 8)), width=min(rec[10], 127), lanes=0, light=0)

    # ---- Sidewalks -------------------------------------------------------
    ped_edits = {a: {} for a in range(AREAS)}
    removed = {(a, n) for a in replace for n in range(areas[a].vehicles, areas[a].count)}
    stock_peds = {(a, n): areas[a].edit(n) for a in range(AREAS) for n in range(areas[a].vehicles, areas[a].count)}
    for (a, n), e in stock_peds.items():
        if (a, n) in removed:
            continue
        kept = [l for l in e['links'] if (l['area'], l['node']) not in removed]
        if len(kept) != len(e['links']):
            ped_edits[a][n] = dict(e, links=kept)
    walk_region = {}
    for key, node in walks.items():
        walk_region.setdefault(region_of(*node['position'][:2]), []).append(key)
    walk_address = {}
    for area, keys in sorted(walk_region.items()):
        slots = list(range(areas[area].vehicles, areas[area].count))
        appended = areas[area].count
        for key in sorted(keys, key=lambda k: (walks[k]['position'][1], walks[k]['position'][0])):
            if slots:
                walk_address[key] = (area, slots.pop(0))
            else:
                if appended >= base.MAX_NODES:
                    raise ValueError(f'region {area} has no room for more sidewalk nodes')
                walk_address[key] = (area, appended)
                appended += 1
    used_ped_floods = {stock_peds[k]['flood'] for k in stock_peds if k not in removed}
    free_ped_floods = iter([f for f in range(1, 256) if f not in used_ped_floods])
    walk_component = components(walks, walk_edges)
    ped_flood = {}
    for root in sorted(set(walk_component.values()), key=str):
        try:
            ped_flood[root] = next(free_ped_floods)
        except StopIteration:
            raise ValueError('too many separate sidewalk networks for 8-bit flood groups') from None
    walk_links = {k: [] for k in walks}
    for e in walk_edges:
        crossing = base.integer(e.get('crossing', 0), 0, 3, 'crossing')
        walk_links[e['a']].append(dict(area=walk_address[e['b']][0], node=walk_address[e['b']][1], length=e['length'], flags=crossing))
        walk_links[e['b']].append(dict(area=walk_address[e['a']][0], node=walk_address[e['a']][1], length=e['length'], flags=crossing))
    used_slots = set(walk_address.values())
    for key, node in walks.items():
        if len(walk_links[key]) > 15:
            raise ValueError(f'sidewalk node {key!r} has more than 15 links')
        area, slot = walk_address[key]
        ped_edits[area][slot] = dict(position=node['position'], width=0, flood=ped_flood[walk_component[key]], enabled=True,
                                    links=walk_links[key])
    for (a, n) in removed:
        if (a, n) not in used_slots:
            ped_edits[a][n] = dict(position=stock_peds[(a, n)]['position'], width=0, flood=stock_peds[(a, n)]['flood'],
                                   enabled=False, links=[])

    validate(areas, stock, vehicle_edits, navi_edits)
    data = emit(areas, ped_edits, vehicle_edits, navi_edits)
    # Never hand out a file the client would refuse: repeat its full checks.
    import check_patch
    check_patch.check(areas, stock, check_patch.parse(data))
    return data, dict(
        replaced=sorted(replace), roadNodes=len(roads), roadEdges=len(road_edges), sidewalkNodes=len(walks),
        sidewalkEdges=len(walk_edges), roadNetworks=len(flood_of), sidewalkNetworks=len(ped_flood))


def validate(areas, stock, vehicle_edits, navi_edits):
    """The same invariants CPedPathPatchesSA::ValidateRoads enforces."""
    eff = {}
    for a in range(AREAS):
        for n in range(areas[a].vehicles):
            if n in vehicle_edits[a]:
                e = vehicle_edits[a][n]
                eff[(a, n)] = (e['links'], e['flood'], e['flags'], e['position'], True)
            else:
                node = areas[a].nodes[n]
                eff[(a, n)] = (stock[a].road(n), node[23], node[24] & 0xF0, list(struct.unpack_from('<3h', node, 8)), False)
    navi_attached = {}
    for a in range(AREAS):
        for nid, rec in enumerate(stock[a].navi):
            navi_attached[(a, nid)] = struct.unpack_from('<HH', rec, 4)
        for nid, e in navi_edits[a].items():
            navi_attached[(a, nid)] = tuple(e['attached'])
    for (a, n), (links, flood, flags, pos, edited) in eff.items():
        if not 1 <= len(links) <= MAX_ROAD_LINKS:
            raise ValueError(f'road node {(a, n)} has {len(links)} links')
        if edited and region_of(pos[0] / 8, pos[1] / 8) != a:
            raise ValueError(f'road node {(a, n)} lies outside its region')
        navis = set()
        for to, length, navi in links:
            if to not in eff or not length:
                raise ValueError(f'road link {(a, n)}->{to} is invalid')
            t_links, t_flood, t_flags, t_pos, t_edited = eff[to]
            if t_flood != flood:
                raise ValueError(f'road link {(a, n)}->{to} crosses flood groups')
            if not any(b == (a, n) and bl == length and bn == navi for b, bl, bn in t_links):
                raise ValueError(f'road link {(a, n)}->{to} has no matching reverse link')
            if navi in navis:
                raise ValueError(f'road node {(a, n)} repeats navi {navi}')
            navis.add(navi)
            host = (navi >> 10, navi & 0x3FF)
            if host not in navi_attached:
                raise ValueError(f'road link {(a, n)}->{to} names missing navi {host}')
            if edited or t_edited or host in {(h, i) for h in [host[0]] for i in navi_edits[host[0]]}:
                if tuple(navi_attached[host]) != min((a, n), to):
                    raise ValueError(f'navi {host} is not attached to the lower endpoint of {(a, n)}-{to}')


def emit(areas, ped_edits, vehicle_edits, navi_edits):
    out = bytearray(b'NPEDPAT2' + struct.pack('<I', AREAS))
    for a in range(AREAS):
        area = areas[a]
        peds = ped_edits[a]
        out.extend(struct.pack('<5I', a, area.count, area.vehicles, area.addresses, area.cars) + area.digest + struct.pack('<I', len(peds)))
        budget = area.addresses
        for n, e in sorted(peds.items()):
            links = e['links']
            out.extend(struct.pack('<H3h4B', n, *[fixed(v) for v in e['position']], e['width'], e['flood'], 1 if e['enabled'] else 0, len(links)))
            for l in links:
                out.extend(struct.pack('<HHBB', l['area'], l['node'], l['length'], l['flags']))
            budget += len(links)
        roads = vehicle_edits[a]
        out.extend(struct.pack('<I', len(roads)))
        for n, e in sorted(roads.items()):
            out.extend(struct.pack('<H3h5BB', n, *e['position'], e['width'], e['flood'], e['flags'], e['speed'], e['spawn'], len(e['links'])))
            for to, length, navi in e['links']:
                out.extend(struct.pack('<HHBH', to[0], to[1], length, navi))
            budget += len(e['links'])
        if budget > base.MAX_LINKS - base.DYNAMIC:
            raise ValueError(f'region {a} exceeds the link budget')
        navis = navi_edits[a]
        out.extend(struct.pack('<I', len(navis)))
        for nid, e in sorted(navis.items()):
            out.extend(struct.pack('<H2hHH2b3B', nid, *e['position'], *e['attached'], *e['direction'], e['width'], e['lanes'], e['light']))
    if len(out) > 4 * 1024 * 1024:
        raise ValueError('patch too large')
    return bytes(out)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--paths', type=Path, required=True, help='directory with the stock NODES0.DAT..NODES63.DAT')
    p.add_argument('--spec', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    areas, stock = load(args.paths)
    data, summary = compile_world(areas, stock, json.loads(args.spec.read_text()))
    args.output.write_bytes(data)
    print(json.dumps(dict(summary, revision=hashlib.sha256(data).hexdigest(), bytes=len(data), output=str(args.output))))


if __name__ == '__main__':
    main()
