"""Read NPC-HLC traffic path maps (npchlc_traffic/paths/maps/*).

NPC-HLC is a long-standing MTA traffic plugin whose editor writes hand-placed
road and sidewalk graphs. Servers that move to SA:O can turn those graphs into
native GTA path patches instead of re-placing every node. This module only
reads the format and flattens curves into straight segments; mapping onto
GTA node IDs is done by import_npchlc.py.

File layout (little-endian), from npchlc_traffic/load_paths.lua:
  header      int32 nodeCount, connCount, forbiddenCount
  node   x16  int32 x, y, z (thousandths), int16 rx, ry (thousandths)
  conn   x20  int32 n1, n2, nb (1-based node indices, nb = -1 when straight),
              uint8 type (1 peds, 2 cars, 3 boats, 4 planes),
              uint8 lights (bits 0-1 at n1, bits 2-3 at n2: 1 NS, 2 WE, 3 ped),
              uint16 maxSpeed (tenths), uint8 leftLanes, uint8 rightLanes,
              uint16 density (thousandths)
  forbidden x8 int32 conn1, conn2 (turns NPC-HLC must not take)
"""
import math
import struct

TYPES = {1: 'peds', 2: 'cars', 3: 'boats', 4: 'planes'}


class Conn:
    def __init__(self, index, n1, n2, nb, kind, lights, speed, left, right, density):
        self.index, self.n1, self.n2, self.nb = index, n1, n2, nb
        self.kind, self.lights, self.speed = kind, lights, speed
        self.left, self.right, self.density = left, right, density


def read(data):
    if len(data) < 12:
        raise ValueError('truncated NPC-HLC header')
    nodes, conns, forbidden = struct.unpack_from('<3i', data)
    if min(nodes, conns, forbidden) < 0 or len(data) != 12 + nodes * 16 + conns * 20 + forbidden * 8:
        raise ValueError('NPC-HLC size does not match its header')
    offset = 12
    positions = []
    for _ in range(nodes):
        x, y, z, _rx, _ry = struct.unpack_from('<3i2h', data, offset)
        positions.append((x / 1000, y / 1000, z / 1000))
        offset += 16
    out = []
    for index in range(conns):
        n1, n2, nb, kind, lights, speed, left, right, density = struct.unpack_from('<3i2BH2BH', data, offset)
        offset += 20
        if not (1 <= n1 <= nodes and 1 <= n2 <= nodes and n1 != n2 and (nb == -1 or 1 <= nb <= nodes)) or kind not in TYPES:
            raise ValueError(f'invalid NPC-HLC connection {index + 1}')
        out.append(Conn(index, n1 - 1, n2 - 1, None if nb == -1 else nb - 1, TYPES[kind], lights, speed / 10, left, right, density / 1000))
    turns = [struct.unpack_from('<2i', data, offset + i * 8) for i in range(forbidden)]
    return positions, out, turns


def polyline(positions, conn, step):
    """Points from n1 to n2, following NPC-HLC's arc around nb when curved.

    NPC-HLC drives a curved connection around the bend node as a centre,
    interpolating angle and radius between both ends (walkAroundBend /
    driveAroundBend). Straight connections are split only when longer than
    the step, so native nodes keep GTA-like spacing.
    """
    a, b = positions[conn.n1], positions[conn.n2]
    if conn.nb is None:
        length = math.dist(a, b)
        count = max(1, math.ceil(length / step))
        return [tuple(a[k] + (b[k] - a[k]) * i / count for k in range(3)) for i in range(count + 1)]
    cx, cy = positions[conn.nb][:2]
    a0, a1 = math.atan2(a[1] - cy, a[0] - cx), math.atan2(b[1] - cy, b[0] - cx)
    sweep = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi
    r0, r1 = math.hypot(a[0] - cx, a[1] - cy), math.hypot(b[0] - cx, b[1] - cy)
    arc = abs(sweep) * (r0 + r1) / 2
    count = max(1, math.ceil(arc / step))
    points = []
    for i in range(count + 1):
        t = i / count
        angle, radius = a0 + sweep * t, r0 + (r1 - r0) * t
        points.append((cx + math.cos(angle) * radius, cy + math.sin(angle) * radius, a[2] + (b[2] - a[2]) * t))
    points[0], points[-1] = a, b
    return points
