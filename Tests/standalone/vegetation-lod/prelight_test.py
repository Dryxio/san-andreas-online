#!/usr/bin/env python3
"""Check RGB projection and exercise the production lighting-update lifecycle."""
import importlib.util
import math
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('match_prelight', ROOT / 'utils/vegetation-lod/match_prelight.py')
prelight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prelight)


class ProjectionTests(unittest.TestCase):
    def test_face_interior(self):
        distance, weights = prelight.closest_weights((0.25, 0.25, 2), (0, 0, 0), (1, 0, 0), (0, 1, 0))
        self.assertAlmostEqual(distance, 4)
        self.assertEqual(weights, (0.5, 0.25, 0.25))
        # Affine color gradients interpolate exactly; no arbitrary per-model multiplier.
        self.assertEqual(sum(a * b for a, b in zip(weights, (0, 100, 200))), 75)

    def test_edges_corners_and_degenerate_faces(self):
        cases = [((2, 0, 0), ((0, 0, 0), (1, 0, 0), (0, 1, 0)), 1),
                 ((0.5, -1, 0), ((0, 0, 0), (1, 0, 0), (0, 1, 0)), 1),
                 ((0.5, 1, 0), ((0, 0, 0), (1, 0, 0), (1, 0, 0)), 1),
                 ((0, 0, 2), ((0, 0, 0),) * 3, 4)]
        for point, corners, expected in cases:
            distance, weights = prelight.closest_weights(point, *corners)
            self.assertAlmostEqual(distance, expected)
            self.assertAlmostEqual(sum(weights), 1)
            self.assertTrue(all(math.isfinite(v) and 0 <= v <= 1 for v in weights))

    def test_actual_assets_only_rgb_changes(self):
        # The calibrated geometry is also a valid donor. Reprojection checks
        # that even a different tessellation never edits topology/UVs/alpha.
        donor = (prelight.DATA / 'lodveg_palm02.dff').read_bytes()
        for path in prelight.DATA.glob('*.dff'):
            original = path.read_bytes()
            vertices, _, day, night = prelight.geometry(original)
            projected = prelight.project(original, donor)
            permitted = {offset + i * 4 + channel for offset in (day, night)
                         for i in range(len(vertices)) for channel in range(3)}
            self.assertEqual(len(original), len(projected))
            self.assertTrue(all(i in permitted or a == b for i, (a, b) in enumerate(zip(original, projected))), path.name)


def test_runtime():
    source = (ROOT / 'Client/game_sa/CVegetationLODSA.h').read_text()
    start = source.index('    inline void UpdateLighting(')
    end = source.index('    inline std::size_t Find(', start)
    body = source[start:end].replace('*reinterpret_cast<const float*>(0x8D12C0)', 'testBalance')
    body = body.replace('reinterpret_cast<void(__cdecl*)(RpAtomic*, bool)>(0x5D7200)', 'NativeUpdate')
    prefix = '''#include <cassert>
#include <cmath>
#include <limits>
struct RpAtomic {};
struct Asset { RpAtomic* atomic{}; float lightingBalance{std::numeric_limits<float>::quiet_NaN()}; };
float testBalance = 1; unsigned calls = 0;
void NativeUpdate(RpAtomic* atomic, bool force) { assert(atomic && force); ++calls; }
'''
    suffix = '''int main() {
 RpAtomic atomic; Asset asset; asset.atomic = &atomic;
 UpdateLighting(asset); assert(calls == 1); // First load at midnight must update.
 for (int i=0;i<1000;++i) UpdateLighting(asset);
 assert(calls == 1); // Same species drawn by many entities does not repeat work.
 testBalance = 0.5f; UpdateLighting(asset); assert(calls == 2);
 testBalance = 0.501f; UpdateLighting(asset); assert(calls == 3); // No 0.01 native throttle.
 testBalance = 0; UpdateLighting(asset); assert(calls == 4);
 testBalance = 1; UpdateLighting(asset); assert(calls == 5); // Day -> night jump.
 testBalance = std::numeric_limits<float>::quiet_NaN(); UpdateLighting(asset); assert(calls == 5);
 testBalance = std::numeric_limits<float>::infinity(); UpdateLighting(asset); assert(calls == 5);
 testBalance = 1; UpdateLighting(asset); assert(calls == 5);
 asset = {}; asset.atomic = &atomic; UpdateLighting(asset); assert(calls == 6); // Reset/reload.
 Asset another; another.atomic = &atomic; UpdateLighting(another); assert(calls == 7);
}'''
    with tempfile.TemporaryDirectory(prefix='neon-vegetation-prelight-') as tmp:
        cpp, binary = Path(tmp) / 'test.cpp', Path(tmp) / 'test'
        cpp.write_text(prefix + body + suffix)
        subprocess.run(['clang++', '-std=c++17', '-fsanitize=address,undefined', str(cpp), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
    print('Production lighting update: initial night, time jumps, shared species, invalid time and reset passed')


if __name__ == '__main__':
    test_runtime()
    unittest.main()
