"""Tests for compile_world.py (custom-map roads and sidewalks) and check_patch.py.

Synthetic regions keep the tests independent of GTA's data files. Set
SAO_STOCK_NODES to a directory of stock NODES*.DAT to also compile a sample
replacement against the real San Andreas graph.
"""
import copy
import importlib.util
import math
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
TOOLS = ROOT / 'utils/ped-path-patches'
sys.path.insert(0, str(TOOLS))


def load(name):
    spec = importlib.util.spec_from_file_location(name, TOOLS / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


world = load('compile_world')
checker = load('check_patch')
npchlc = load('npchlc')
importer = load('import_npchlc')


def centre(area):
    return world.region_centre(area)


def raw_area(area):
    """Four road nodes (two linked pairs) and two linked sidewalk nodes."""
    cx, cy = centre(area)
    nodes = []
    positions = [(cx - 10, cy, 0), (cx + 10, cy, 0), (cx - 10, cy + 40, 0), (cx + 10, cy + 40, 0), (cx, cy - 20, 0), (cx, cy - 10, 0)]
    link_targets = [[1], [0], [3], [2], [5], [4]]
    base = 0
    links, navi_links, lengths = [], [], []
    navi = []
    for i, (pos, targets) in enumerate(zip(positions, link_targets)):
        n = bytearray(28)
        struct.pack_into('<3h', n, 8, *(round(v * 8) for v in pos))
        struct.pack_into('<4H', n, 14, 0x7FFE, base, area, i)
        n[22] = 0
        n[23] = 1 + i // 2 if i < 4 else 7
        n[24] = len(targets)
        n[25] = 0x10 if i < 4 else 0
        n[26] = 15
        nodes.append(bytes(n))
        for t in targets:
            links.append((area, t))
            lengths.append(20 if i < 4 else 10)
            if i < 4:
                pair = min(i, t) // 2
                navi_links.append(pair | (area << 10))
            else:
                navi_links.append(0)
        base += len(targets)
    for pair in range(2):
        a, b = positions[pair * 2], positions[pair * 2 + 1]
        rec = bytearray(14)
        struct.pack_into('<2h', rec, 0, round((a[0] + b[0]) * 4), round((a[1] + b[1]) * 4))
        struct.pack_into('<HH', rec, 4, area, pair * 2)
        struct.pack_into('<2b', rec, 8, -100, 0)
        rec[11] = 0x09
        navi.append(bytes(rec))
    count = len(links)
    out = struct.pack('<5I', 6, 4, 2, len(navi), count) + b''.join(nodes) + b''.join(navi)
    out += b''.join(struct.pack('<HH', *l) for l in links) + struct.pack('<HH', 0xFFFF, 0) * 192
    out += struct.pack(f'<{count}H', *navi_links)
    out += bytes(lengths) + bytes(192) + bytes(count) + bytes(192)
    return out


def write_regions(directory):
    for a in range(64):
        (directory / f'NODES{a}.DAT').write_bytes(raw_area(a))


class WorldTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        write_regions(self.dir)
        self.areas, self.stock = world.load(self.dir)
        cx, cy = centre(9)
        self.spec = {
            'roads': {'nodes': [{'id': 'a', 'position': [cx - 20, cy, 1]}, {'id': 'b', 'position': [cx + 20, cy, 1]}],
                      'edges': [{'a': 'a', 'b': 'b', 'lanes': [1, 0]}]},
            'sidewalks': {'nodes': [{'id': 'p', 'position': [cx, cy + 5, 1]}, {'id': 'q', 'position': [cx, cy + 25, 1]}],
                          'edges': [{'a': 'p', 'b': 'q'}]},
        }

    def tearDown(self):
        self.tmp.cleanup()

    def compile(self, spec=None):
        return world.compile_world(self.areas, self.stock, spec or self.spec)

    def test_compiles_and_passes_client_checks(self):
        data, summary = self.compile()
        self.assertEqual(data[:8], b'NPEDPAT2')
        self.assertEqual(summary['replaced'], [9])
        report = checker.check(self.areas, self.stock, checker.parse(data))
        self.assertEqual(report['regionsEdited'], 1)

    def test_deterministic(self):
        self.assertEqual(self.compile()[0], self.compile(copy.deepcopy(self.spec))[0])

    def test_navi_on_lower_endpoint_with_one_way_lanes(self):
        data, _ = self.compile()
        patch = checker.parse(data)
        roads = patch[9]['roads']
        link = roads[0]['links'][0]
        navi = patch[9]['navi'][link[2] & 0x3FF]
        self.assertEqual(tuple(navi['attached']), (9, 0))
        # a -> b only: a is the lower address, so lanes run away from it.
        self.assertEqual(navi['lanes'], 1 << 3)

    def test_unused_slots_are_parked_not_emptied(self):
        data, _ = self.compile()
        roads = checker.parse(data)[9]['roads']
        parked = [n for n, e in roads.items() if e['flood'] == world.PARKED_FLOOD]
        self.assertEqual(sorted(parked), [2, 3])
        self.assertTrue(all(roads[n]['links'] and roads[n]['flags'] & 0x20 for n in parked))

    def test_single_leftover_slot_is_rejected(self):
        cx, cy = centre(9)
        self.spec['roads']['nodes'].append({'id': 'c', 'position': [cx + 30, cy + 30, 1]})
        self.spec['roads']['edges'].append({'a': 'b', 'b': 'c'})
        with self.assertRaises(ValueError):
            self.compile()

    def test_rejects_long_edges_and_capacity(self):
        cx, cy = centre(9)
        self.spec['roads']['nodes'][1]['position'] = [cx + 300, cy, 1]
        with self.assertRaises(ValueError):
            self.compile()
        spec = copy.deepcopy(self.spec)
        spec['roads']['nodes'] = [{'id': str(i), 'position': [cx + i * 5, cy, 1]} for i in range(5)]
        spec['roads']['edges'] = [{'a': str(i), 'b': str(i + 1)} for i in range(4)]
        with self.assertRaises(ValueError):
            self.compile(spec)

    def test_checker_rejects_asymmetric_road(self):
        data, _ = self.compile()
        patch = checker.parse(data)
        patch[9]['roads'][0]['links'][0] = (patch[9]['roads'][0]['links'][0][0], 99, patch[9]['roads'][0]['links'][0][2])
        with self.assertRaises(ValueError):
            checker.check(self.areas, self.stock, patch)

    def test_checker_rejects_dead_end_hint_on_ring(self):
        # GTA starts the dead-end walk with the other end of a link as the
        # previous node, so a hint on a branchless ring never terminates.
        cx, cy = centre(9)
        ring = [[cx - 20, cy - 20, 1], [cx + 20, cy - 20, 1], [cx + 20, cy + 20, 1], [cx - 20, cy + 20, 1]]
        spec = {'roads': {'nodes': [{'id': str(i), 'position': p} for i, p in enumerate(ring)],
                          'edges': [{'a': str(i), 'b': str((i + 1) % 4)} for i in range(4)]}}
        data, _ = self.compile(spec)
        patch = checker.parse(data)
        checker.check(self.areas, self.stock, patch)
        patch[9]['roads'][0]['flags'] |= 0x10
        with self.assertRaises(ValueError):
            checker.check(self.areas, self.stock, patch)

    def test_npchlc_arc_and_lanes(self):
        positions = [(0, 0, 0), (10, 10, 0), (0, 10, 0)]
        conn = npchlc.Conn(0, 0, 1, 2, 'cars', 0, 40, 0, 1, 1)
        points = npchlc.polyline(positions, conn, 2)
        self.assertEqual(points[0], positions[0])
        self.assertEqual(points[-1], positions[1])
        for p in points:
            self.assertAlmostEqual(((p[0] - 0) ** 2 + (p[1] - 10) ** 2) ** 0.5, 10, places=5)

    def test_junction_loop_becomes_one_node_with_approaches(self):
        # NPC-HLC junction: a 10 m square of turn connections with three
        # 50 m roads leaving it. GTA should get one junction node, a node
        # 10 m up each long approach, and the far ends untouched.
        square = {'s0': [0, 0, 0], 's1': [10, 0, 0], 's2': [10, 10, 0], 's3': [0, 10, 0]}
        arms = {'w': [-50, 0, 0], 'e': [60, 0, 0], 'n': [5, 60, 0]}
        nodes = [dict(id=k, position=p) for k, p in {**square, **arms}.items()]
        edges = [dict(a=f's{i}', b=f's{(i + 1) % 4}', lanes=[1, 1]) for i in range(4)]
        edges += [dict(a='w', b='s0', lanes=[1, 1]), dict(a='s1', b='e', lanes=[1, 1]), dict(a='n', b='s2', lanes=[1, 1])]
        part, merged, skipped = importer.merge_junction_loops(dict(nodes=nodes, edges=edges))
        self.assertEqual((merged, skipped), (1, 0))
        junction = [n for n in part['nodes'] if n['id'].startswith('j')]
        self.assertEqual(len(junction), 1)
        self.assertEqual(sorted({e['a'] for e in part['edges']} | {e['b'] for e in part['edges']}), sorted(['w', 'e', 'n', junction[0]['id']]))
        part, added = importer.add_approach_nodes(part)
        self.assertEqual(added, 3)
        centre = junction[0]['position']
        for n in part['nodes']:
            if n['id'].startswith('a'):
                self.assertAlmostEqual(math.dist(n['position'][:2], centre[:2]), 10, places=3)

    def test_wide_loop_is_not_a_junction(self):
        # A 50 m block is a real street loop, not a junction.
        corners = [[0, 0, 0], [50, 0, 0], [50, 50, 0], [0, 50, 0]]
        nodes = [dict(id=f'b{i}', position=p) for i, p in enumerate(corners)]
        edges = [dict(a=f'b{i}', b=f'b{(i + 1) % 4}') for i in range(4)]
        part, merged, _ = importer.merge_junction_loops(dict(nodes=nodes, edges=edges))
        self.assertEqual(merged, 0)
        self.assertEqual(len(part['nodes']), 4)


@unittest.skipUnless(os.environ.get('SAO_STOCK_NODES'), 'set SAO_STOCK_NODES to the stock NODES directory')
class StockTests(unittest.TestCase):
    def test_replacing_a_region_passes_client_checks(self):
        areas, stock = world.load(Path(os.environ['SAO_STOCK_NODES']))
        cx, cy = centre(33)
        spec = {'roads': {'nodes': [{'id': 'a', 'position': [cx, cy, 10]}, {'id': 'b', 'position': [cx + 50, cy, 10]}],
                          'edges': [{'a': 'a', 'b': 'b'}]}}
        data, _ = world.compile_world(areas, stock, spec)
        checker.check(areas, stock, checker.parse(data))


if __name__ == '__main__':
    unittest.main()
