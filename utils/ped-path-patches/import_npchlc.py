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
  - NPC-HLC speed limits pick GTA's speed class (slow / normal / highway);
  - junctions: NPC-HLC models a junction as a small loop of curved turn
    connections, which GTA would treat as tiny roads with lanes of their own
    (cars then cut corners over the sidewalk). Each such loop is merged into
    one junction node, and every junction gets a node 10 m up each long
    approach so turns start where GTA's own maps would start them.
NPC-HLC forbidden turn pairs have no GTA equivalent and are reported.
"""
import argparse
import heapq
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


def merge_junction_loops(part, max_perimeter=60.0, max_diameter=35.0, absorb=3.0):
    """Collapse each small loop of road edges into a single junction node.

    NPC-HLC drives turn connections exactly on their arcs, so a junction is a
    ring of short curves around the crossing. GTA instead offsets every lane
    2.7 m from a link and curves between link midpoints, so those rings make
    cars swerve through the junction. GTA's own junctions are one node that
    every approach links to, so loops whose perimeter is below max_perimeter
    become one node at their centroid. Clusters wider than max_diameter (a
    real roundabout or small block) are left alone, and approach nodes
    within `absorb` metres of the new node are merged too, so no link is
    shorter than GTA's whole-metre minimum. Returns (part, merged, skipped).
    """
    pos = {n['id']: n['position'] for n in part['nodes']}
    adj = {k: {} for k in pos}
    for e in part['edges']:
        length = math.dist(pos[e['a']][:2], pos[e['b']][:2])
        adj[e['a']][e['b']] = length
        adj[e['b']][e['a']] = length

    def detour(u, v, limit):
        # Shortest u -> v path that does not use the u-v edge itself.
        best = {u: 0.0}
        queue = [(0.0, u)]
        while queue:
            d, x = heapq.heappop(queue)
            if x == v:
                return d
            if d > best.get(x, math.inf) or d > limit:
                continue
            for y, w in adj[x].items():
                if {x, y} == {u, v}:
                    continue
                if d + w < best.get(y, math.inf):
                    best[y] = d + w
                    heapq.heappush(queue, (d + w, y))
        return None

    parent = {k: k for k in pos}

    def find(k):
        while parent[k] != k:
            parent[k] = parent[parent[k]]
            k = parent[k]
        return k

    for e in part['edges']:
        length = adj[e['a']][e['b']]
        if detour(e['a'], e['b'], max_perimeter - length) is not None:
            parent[find(e['a'])] = find(e['b'])
    clusters = {}
    for k in pos:
        clusters.setdefault(find(k), []).append(k)
    merged, skipped, rename = 0, 0, {}
    for root, members in sorted(clusters.items()):
        if len(members) < 2:
            continue
        if max(math.dist(pos[a][:2], pos[b][:2]) for a in members for b in members) > max_diameter:
            skipped += 1
            continue
        members = set(members)
        centre = [sum(pos[m][i] for m in members) / len(members) for i in range(3)]
        for m in list(members):
            for n in adj[m]:
                if n not in members and math.dist(pos[n][:2], centre[:2]) < absorb:
                    members.add(n)
        key = 'j' + min(members)
        for m in members:
            rename[m] = key
        pos[key] = [round(v, 3) for v in centre]
        merged += 1
    if not rename:
        return part, 0, skipped
    speeds = {}
    for n in part['nodes']:
        target = rename.get(n['id'], n['id'])
        if 'speed' in n:
            speeds[target] = min(speeds.get(target, n['speed']), n['speed'])
    edges, index = [], {}
    for e in part['edges']:
        a, b = rename.get(e['a'], e['a']), rename.get(e['b'], e['b'])
        if a == b:
            continue
        lanes = list(e.get('lanes', [1, 1]))
        key = frozenset((a, b))
        if key in index:
            # Two approaches now share the same pair: keep the most lanes
            # each way so no direction is lost.
            old = index[key]
            if old['a'] != a:
                lanes.reverse()
            old['lanes'] = [max(old['lanes'][0], lanes[0]), max(old['lanes'][1], lanes[1])]
            continue
        edge = dict(e, a=a, b=b)
        if 'lanes' in e:
            edge['lanes'] = lanes
        index[key] = edge
        edges.append(edge)
    used = {e['a'] for e in edges} | {e['b'] for e in edges}
    nodes = []
    for k in sorted(used, key=lambda k: (k[0] != 'j', k)):
        node = dict(id=k, position=pos[k])
        if k in speeds:
            node['speed'] = speeds[k]
        nodes.append(node)
    return dict(nodes=nodes, edges=edges), merged, skipped


def add_approach_nodes(part, distance=10.0):
    """Give every junction a node `distance` metres up each approach.

    GTA starts a turn halfway along the link entering the junction, so a
    30-60 m approach link makes cars begin turning far too early and cut
    across the corner. GTA's own maps keep a node close to every junction.
    """
    pos = {n['id']: n['position'] for n in part['nodes']}
    degree = {}
    for e in part['edges']:
        degree[e['a']] = degree.get(e['a'], 0) + 1
        degree[e['b']] = degree.get(e['b'], 0) + 1
    nodes, edges, added = list(part['nodes']), [], 0
    speed = {n['id']: n.get('speed') for n in part['nodes']}
    for e in part['edges']:
        a, b = e['a'], e['b']
        length = math.dist(pos[a][:2], pos[b][:2])
        cuts = []
        for end, other in ((a, b), (b, a)):
            if degree[end] >= 3 and length > 2.5 * distance:
                cuts.append((end, other))
        if not cuts:
            edges.append(e)
            continue
        chain = [a]
        points = []
        for end, other in cuts:
            t = distance / length
            p = [pos[end][i] + (pos[other][i] - pos[end][i]) * t for i in range(3)]
            key = f'a{end}>{other}'
            pos[key] = [round(v, 3) for v in p]
            node = dict(id=key, position=pos[key])
            if speed.get(end) is not None or speed.get(other) is not None:
                node['speed'] = min(v for v in (speed.get(end), speed.get(other)) if v is not None)
            nodes.append(node)
            points.append((math.dist(pos[a][:2], p[:2]), key))
            added += 1
        chain += [k for _, k in sorted(points)] + [b]
        for u, v in zip(chain, chain[1:]):
            edges.append(dict(e, a=u, b=v))
    return dict(nodes=nodes, edges=edges), added


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('maps', nargs='+', type=Path, help='NPC-HLC path map files (npchlc_traffic/paths/maps/*)')
    p.add_argument('--output', type=Path, required=True, help='compile_world.py spec to write')
    p.add_argument('--replace', type=int, nargs='*', default=[], help='extra regions (0-63) whose stock paths are removed')
    p.add_argument('--curve-step', type=float, default=8.0)
    p.add_argument('--road-step', type=float, default=60.0)
    p.add_argument('--sidewalk-step', type=float, default=30.0)
    p.add_argument('--junction-loop', type=float, default=60.0,
                   help='merge road loops shorter than this perimeter (m) into one junction node; 0 keeps them')
    p.add_argument('--junction-approach', type=float, default=10.0,
                   help='add a road node this far (m) up each long junction approach; 0 keeps the spacing')
    args = p.parse_args()
    roads = dict(nodes=[], edges=[])
    walks = dict(nodes=[], edges=[])
    forbidden = 0
    junctions = dict(merged=0, skipped=0, approachNodes=0)
    for index, path in enumerate(args.maps):
        positions, conns, turns = npchlc.read(path.read_bytes())
        forbidden += len(turns)
        prefix = f'm{index}:'
        for target, kind, step in ((roads, 'cars', args.road_step), (walks, 'peds', args.sidewalk_step)):
            part = build(positions, conns, kind, args.curve_step, step)
            if kind == 'cars' and args.junction_loop > 0:
                part, merged, skipped = merge_junction_loops(part, args.junction_loop)
                junctions['merged'] += merged
                junctions['skipped'] += skipped
            if kind == 'cars' and args.junction_approach > 0:
                part, added = add_approach_nodes(part, args.junction_approach)
                junctions['approachNodes'] += added
            target['nodes'] += [dict(n, id=prefix + n['id']) for n in part['nodes']]
            target['edges'] += [dict(e, a=prefix + e['a'], b=prefix + e['b']) for e in part['edges']]
    spec = dict(replace=args.replace, roads=roads, sidewalks=walks)
    args.output.write_text(json.dumps(spec, indent=1))
    print(json.dumps(dict(roadNodes=len(roads['nodes']), roadEdges=len(roads['edges']), sidewalkNodes=len(walks['nodes']),
                          sidewalkEdges=len(walks['edges']), forbiddenTurnsIgnored=forbidden, junctionsMerged=junctions['merged'],
                          junctionLoopsKeptTooWide=junctions['skipped'],
                          junctionApproachNodes=junctions['approachNodes'], output=str(args.output))))


if __name__ == '__main__':
    main()
