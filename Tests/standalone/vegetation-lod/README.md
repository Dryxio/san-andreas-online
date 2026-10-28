# World distance / vegetation checkpoint

Extended world distance has three independent policies: Project2DFX (default
for new configurations), LOD only (the previous optimized policy), and Legacy.
Legacy reproduces the pre-unrestricted-HD behavior: blanket model distances,
vanilla native visibility limits, and the existing 10x sector scan only when a
resource owns MTA low-LOD elements. It does not restore the expensive
unrestricted HD mode. Existing explicit Legacy users retain Legacy.
Vegetation LODs remain independent and disabled by default.

## Automated checks

From the repository root:

```sh
clang++ -std=c++17 -I Shared/sdk Tests/standalone/vegetation-lod/policy.cpp -o /tmp/neon-vegetation-policy
/tmp/neon-vegetation-policy
python3 utils/vegetation-lod/validate_assets.py
python3 Tests/standalone/vegetation-lod/queue_test.py
npm run build --prefix Tools/server-browser-prototype
```

The policy check covers all 16 combinations of master, legacy, resource-LOD
presence and vegetation, plus camera bounds. Asset validation checks hashes,
model mappings, one atomic per DFF, identity local frames and completeness of
the supplied texture dictionary. These are not
GPU benchmarks or proof of visual correctness.

The queue test runs the production request/pulse bodies with a fake loader:
repeated requests coalesce, only one asset is prepared per pulse, failures are
latched, and disabled processing does not load assets. It does not test disk I/O
or RenderWare. Runtime activation and reset checks remain necessary.

## Runtime matrix

Test Extended OFF and each of the three modes ON, with vegetation OFF and ON.
Repeat with a resource owning a low-LOD object and without one. Use the same
camera, time, weather and FPS cap for comparisons. Do not launch tests
without the user's request.

- Verify a known palm (620/621/622/645) near, across its transition, and far.
- With vegetation OFF, toggling legacy alone while Extended is OFF changes nothing.
- With vegetation ON and Extended OFF, only supported stock vegetation gains
  distant geometry; camera far clip stays unchanged.
- A server far clip of 650 remains authoritative in all modes.
- Remove/restore one native tree: its LOD must disappear/reappear with it.
- Replace the tree DFF or set its model LOD distance from Lua: the resource
  retains ownership. Restore/reset it and vegetation LOD becomes eligible again.
- Switch options repeatedly, restart the resource, reconnect and change map:
  no duplicate entities, stale pointers, or permanently modified model distances.
- Check both fully opaque rendering and the outer distance fade, daytime/night,
  wet weather, and different camera angles.

## Limits

The implementation substitutes a lightweight atomic during the native draw,
including the fading pass. GTA still streams the source HD model; this reduces
rendered geometry, not all HD residency or world scanning cost. The switch to
LOD is a discrete transition at the catalog distance, not a dual-mesh crossfade.
No procedural grass is added. Five unverified/missing definitions retain GTA
rendering; see the asset manifest. Visibility queues missing assets, and the
game prepares at most one per pulse outside entity traversal. Native rendering
and range remain until preparation succeeds. Individual TXD/DFF reads are still
synchronous, so this is not a hard loading-time budget. Failures are retried
after reset or disabling/re-enabling vegetation.
Resource custom DFFs and explicit model-distance overrides are excluded.

Run `python3 Tests/standalone/vegetation-lod/range_test.py` to exercise the
production range helper against all 89 authored definitions under ASan/UBSan.
It verifies pack defaults, monotonic caps and the margin beyond every transition.
This does not validate GTA visibility, alpha rendering or UI persistence.

## Day/night prelight continuity

The standalone LOD atomics install GTA's building rendering pipeline after
loading. Because the render substitution bypasses CEntity::PreRender, their
colors are explicitly updated from GTA's current day/night balance. The first
update is forced even when first loading at night. Further updates occur only
when the balance changes, once per loaded species rather than once per entity.
Reset/reload invalidates this cache; both opaque and fading render paths use it.

The pack's generic day/night RGB has been replaced by projection from the
matching stock mesh: closest triangle with barycentric interpolation in model
space. Both times use the same projection, and LOD alpha, geometry, UVs and
textures are unchanged. Excluded resource-owned models remain excluded.
This corrects the mismatched prelight; the different mesh and texture artwork
can still produce a visible silhouette/texture transition. There is no extra
draw or dual-mesh crossfade and no promise of pixel-identical shading.

Regenerate after reimport (the importer requires `--gta-img` and runs this step):

```sh
python3 utils/vegetation-lod/match_prelight.py --gta-img /path/to/original/models/gta3.img
python3 utils/vegetation-lod/match_prelight.py --gta-img /path/to/original/models/gta3.img --check
python3 Tests/standalone/vegetation-lod/prelight_test.py
```

All donors and generated files are validated before writes. Manifest provenance
records the original pack hash, donor DFF hash and calibrated output hash.
Use an unmodified GTA IMG; no donor mesh/texture is redistributed by this tool.

Pending in-game acceptance: palms 620/621/622/648 near and far at midnight,
noon, dawn and dusk; enable the option for the first time at midnight; jump the
server clock; repeat with SkyGfx enabled and disabled; confirm resource override,
outer alpha fade, reset/reconnect and dense-vegetation stability. This checkpoint
is locally tested only; no Windows client build/runtime test was requested.
