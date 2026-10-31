#!/usr/bin/env python3
"""Turn an NPC-HLC traffic path map into a compile_world.py spec.

Servers moving from MTA to SA:O often carry years of hand-placed NPC-HLC
traffic paths. This keeps that work: roads and sidewalks become native GTA
path data, so GTA's own driving and walking AI uses them.

Mapping:
  - car connections become roads, pedestrian connections become sidewalks;
    boat and plane connections are ignored;
  - curved connections (NPC-HLC "bend" nodes) are followed as arcs and split
    into short straight pieces, as GTA only drives straight between nodes;
  - long straight connections are split so every edge stays within GTA's
    1-255 m link length;
  - NPC-HLC lanes: right lanes drive n1 -> n2, left lanes n2 -> n1, and a
    connection with neither is two-way with one lane each way;
  - NPC-HLC speed limits pick GTA's speed class (slow / normal / highway).
NPC-HLC forbidden turn pairs have no GTA equivalent and are reported.
"""
import argparse
import json
import math
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import npchlc  # noqa: E402


def speed_class(kmh):
    if kmh >= 100:
        return 2
    if kmh <= 25:
        return 0
    return 1


def build(positions, conns, kind, curve_step, straight_step):
    nodes, edges = {}, []
    speeds = {}

    def node(key, position, speed=None):
        if key not in nodes:
            nodes[key] = dict(id=key, position=[round(v, 3) for v in position])
        if speed is not None:
            speeds[key] = max(speeds.get(key, 0), speed)
        return key

    for conn in conns:
        if conn.kind != kind:
            continue
        points = npchlc.polyline(positions, conn, curve_step if conn.nb is not None else straight_step)
        keys = [f'n{conn.n1}']
        for i, p in enumerate(points[1:-1], 1):
            keys.append(f'c{conn.index}_{i}')
        keys.append(f'n{conn.n2}')
        # Drop intermediate points closer than 1 m to the previous kept one:
        # GTA link lengths are whole metres and must be at least 1.
        kept_keys, kept_points = [keys[0]], [points[0]]
        for key, point in zip(keys[1:-1], points[1:-1]):
            if math.dist(point, kept_points[-1]) >= 1.5 and math.dist(point, points[-1]) >= 1.5:
                kept_keys.append(key)
                kept_points.append(point)
        kept_keys.append(keys[-1])
        kept_points.append(points[-1])
        if math.dist(kept_points[0], kept_points[-1]) < 1 and len(kept_points) == 2:
            continue
        sc = speed_class(conn.speed) if kind == 'cars' else None
        for key, point in zip(kept_keys, kept_points):
            node(key, point, sc)
        for a, b in zip(kept_keys, kept_keys[1:]):
            edge = dict(a=a, b=b)
            if kind == 'cars':
                if conn.left == 0 and conn.right == 0:
                    lanes = [1, 1]
                else:
                    lanes = [min(conn.right, 7), min(conn.left, 7)]
                edge['lanes'] = lanes
            edges.append(edge)
    if kind == 'cars':
        for key, sc in speeds.items():
            nodes[key]['speed'] = sc
    # Collapse duplicate edges NPC-HLC sometimes stores between the same pair.
    unique, seen = [], set()
    for e in edges:
        k = frozenset((e['a'], e['b']))
        if k not in seen and e['a'] != e['b']:
            seen.add(k)
            unique.append(e)
    used = {e['a'] for e in unique} | {e['b'] for e in unique}
    return dict(nodes=[n for k, n in nodes.items() if k in used], edges=unique)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('maps', nargs='+', type=Path, help='NPC-HLC path map files (npchlc_traffic/paths/maps/*)')
    p.add_argument('--output', type=Path, required=True, help='compile_world.py spec to write')
    p.add_argument('--replace', type=int, nargs='*', default=[], help='extra regions (0-63) whose stock paths are removed')
    p.add_argument('--curve-step', type=float, default=8.0)
    p.add_argument('--road-step', type=float, default=60.0)
    p.add_argument('--sidewalk-step', type=float, default=30.0)
    args = p.parse_args()
    roads = dict(nodes=[], edges=[])
    walks = dict(nodes=[], edges=[])
    forbidden = 0
    for index, path in enumerate(args.maps):
        positions, conns, turns = npchlc.read(path.read_bytes())
        forbidden += len(turns)
        prefix = f'm{index}:'
        for target, kind, step in ((roads, 'cars', args.road_step), (walks, 'peds', args.sidewalk_step)):
            part = build(positions, conns, kind, args.curve_step, step)
            target['nodes'] += [dict(n, id=prefix + n['id']) for n in part['nodes']]
            target['edges'] += [dict(e, a=prefix + e['a'], b=prefix + e['b']) for e in part['edges']]
    spec = dict(replace=args.replace, roads=roads, sidewalks=walks)
    args.output.write_text(json.dumps(spec, indent=1))
    print(json.dumps(dict(roadNodes=len(roads['nodes']), roadEdges=len(roads['edges']), sidewalkNodes=len(walks['nodes']),
                          sidewalkEdges=len(walks['edges']), forbiddenTurnsIgnored=forbidden, output=str(args.output))))


if __name__ == '__main__':
    main()
