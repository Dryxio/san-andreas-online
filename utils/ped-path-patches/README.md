# Change pedestrian paths on custom maps

This checkpoint adds a client resource API for moving, adding and disabling
pedestrian nodes in GTA's exterior path network. Native wandering and
`setPedNavigateTo` read the modified network. Vehicle nodes and their links are
not editable through this format.

```lua
local ok, revisionOrReason = engineLoadPedPathPatch("detour.npp")
local revision, reason = engineGetPedPathPatchRevision()
local graphRevision, reason = engineGetPedPathGraphRevision()
local removed = engineUnloadPedPathPatch()
```

Declare the `.npp` file in `meta.xml`. The loading resource owns one patch;
resource stop restores its base graph automatically. All four functions are
client-side. Paths must belong to the calling resource. Load returns
`true, sha256` or `false, reason`; revision returns `sha256` or `false, reason`;
unload returns whether a patch was removed. SHA-256 covers the exact compiled
patch, including its base graph fingerprints. The graph query is accessible from any resource and hashes the sorted set of
active patch revisions. It returns `false, reason` if any lease is incompatible
or no patch is active. Compare this aggregate revision, not just one resource's
file revision, before selecting an NPC syncer. A resource must request fresh
revisions through its server before granting AI authority; streaming can invalidate
a lease after an earlier readiness report. The engine does not automatically
modify existing traffic resources' syncer policy.

## Compile an edit

`compile_patch.py` consumes the author's verified `NODES0.DAT` through
`NODES63.DAT` and a JSON edit specification. Use a trusted local export of the
same base graph as the client; loose data files and IMG entries can differ.

```
python3 utils/ped-path-patches/compile_patch.py --paths /path/to/paths \
  --spec test-resources/ped-path-patch-test/detour.json --output detour.npp
```

Each `areas` entry has an `area` (0–63) and `nodes`. Each node edit specifies
`id`, `position` (three world coordinates), `width` (native units of 1/16),
`flood` (native connectivity group), optional `enabled` (default true), and
`links` (`area`, `node`, `length` in native graph-cost units, optional `flags`
0–3). Existing pedestrian IDs stay unchanged. Added IDs must start at the
original node count and be contiguous. There are at most 15 outgoing links.
Disabled nodes have no links; the compiler also removes their incoming links
and includes all 64 regions for verification. Editing a vehicle node is rejected.
Keep the same flood group across connected nodes; this version does not merge
previously separate native flood groups.

The binary format starts with `NPEDPAT1`, little-endian area count (exactly 64), then sorted
area records: five uint32 fields (area, original node count, vehicle count,
address count, car-link count), 32-byte normalized base SHA-256, uint32 edit
count, and edits. An edit is uint16 ID, three int16 positions scaled by eight,
four bytes (width, flood, enabled, link count), followed by links of uint16
area, uint16 node, uint8 length, uint8 flags. Trailing data is rejected.
Only edits and fingerprints are distributed, not the original graph files.

## Lifecycle and limits

- The graph is GTA-global per client, not isolated by dimension or interior.
  This checkpoint targets the original 64 exterior regions, not map-grid
  expansion or custom interiors.
- All 64 base regions are requested and verified synchronously before publication,
  including every incoming edge. Only edited regions are reserved: two patches
  cannot edit the same region. The effective pedestrian graph must have equal-cost
  reciprocal links, as required by GTA's path reconstruction.
- Streaming reloads reapply the patch and recheck the base fingerprint.
  A rejected reload invalidates the lease. Previously published node addresses
  remain backed by storage even if the replacement graph is shorter; changing
  that base requires a client restart before patches can be admitted again.
- Added node storage and IDs remain reserved for the process lifetime. Unload
  turns them into non-spawnable, disconnected tombstones. The identical patch
  can be restarted, but a different patch adding nodes to the same region
  requires restarting the client. This prevents old task addresses being
  silently recycled for unrelated paths. Existing tasks are not forcibly
  restarted; they may finish their current segment before using restored paths.
- Fixed caps: 4 MiB file, 4096 nodes and 32768 link slots per region, including
  192 slots reserved for native dynamic links. Slabs are bounded and retained;
  this is not an unbounded history of every patch revision.
- Active interior link rewrites are refused during patch admission. While a patch
  owns a region, new native interior connections involving that region are
  suppressed on both endpoints. Exterior-to-interior navigation through that
  region is therefore unavailable until the patch is unloaded. The loader
  requires the verified US 1.0 native entrypoints and fails on competing detours.
- Patches do not fix unrelated event-profile, collision-support or synchronization
  problems, and do not provide a server-side route calculator.

## Roads on custom maps (NPEDPAT2)

The same API also loads road edits, so GTA's own driving AI (and SA:O's
native traffic) drives a custom map's roads. Version 2 files add road node and
navi (`CCarPathLink`) edits to each region record; version 1 files load as
before. Write them with `compile_world.py`, never by hand:

```
python3 utils/ped-path-patches/compile_world.py --paths /path/to/stock/nodes \
  --spec map.json --output map.npp
python3 utils/ped-path-patches/check_patch.py --paths /path/to/stock/nodes map.npp
```

The spec lists road nodes/edges (`lanes: [a_to_b, b_to_a]`, optional `speed`
0 slow / 1 normal / 2 highway, `light` 0/1/2/`"auto"`) and sidewalk
nodes/edges (`crossing` flags). Every region that holds a custom node, plus
any listed in `replace`, loses all its stock roads and sidewalks. The
compiler then:

- places custom road nodes in that region's stock vehicle slots. Native
  searches split each region's nodes at the stock vehicle count, so roads can
  be moved or parked but never added: a region's road capacity is its stock
  vehicle node count;
- writes one navi record per edge, attached to the lower node address and
  pointing toward it, at the midpoint, with lanes for each direction. A
  one-way road keeps both links and gets zero lanes on one side; dropping a
  reverse link would hang GTA's route search;
- parks unused vehicle slots as linked pairs under the region with zero lanes
  (a road node with no links divides by zero during car placement);
- assigns flood groups per connected network and recomputes dead-end hints;
- removes links from neighbouring regions into replaced ones, and replaces a
  neighbour region too if one of its roads would be left with no links.

`check_patch.py` repeats the client's checks against the stock data before
you ship a file. The client refuses road files whose effective graph breaks
any rule above, with an error such as `asymmetric-road-link`.

Limits: 1024 navi records per region; 12 links per road node; edges 1-255 m
(longer ones must be split); custom roads do not connect to surviving stock
roads. A region that would keep exactly one unused road slot is refused; add
or remove one node there. Road edits in a region use the same one-patch-per-
region rule as sidewalks, and navi ids above the stock count stay reserved
until the client restarts.

### Importing NPC-HLC traffic paths

`import_npchlc.py` turns NPC-HLC (`npchlc_traffic/paths/maps/*`) graphs into a
spec: car connections become roads, pedestrian ones sidewalks, curved
connections are followed as arcs, and NPC-HLC lanes (right lanes n1 to n2,
left lanes n2 to n1, none for two-way) become GTA lanes. Forbidden-turn pairs
have no GTA equivalent and are reported.

```
python3 utils/ped-path-patches/import_npchlc.py weston --output map.json
```

## Tester handoff

Use `test-resources/ped-path-patch-test`. Its synthetic Idlewood detour is a
reproducible fixture, not the author's unavailable Seven/Alhambra assets.

1. Install the matching complete CI client artifact; keep modules from the same
   build together. Start the resource on the test server and connect two clients.
2. Both clients must report the same revision as `fixture.lua`. A mismatched
   base graph must report an error, not partial success.
3. Both players run `/pathpatch visit` to stream the fixture location. Wait for
   `building collision ready: true` on both clients. Each client creates a building collision barrier and checks that it blocks
   the direct segment while leaving the detour clear. Readiness stays false if
   this collision check fails. A frozen object would not suffice: GTA ignores
   CObjects in the native short-route shortcut.
4. `/pathpatch` spawns a shared ped and dispatches native navigation near
   X=1954, Y=-1820. Observe the detour through X=1948.5 and return to vanilla.
   The test reports task acceptance, not arrival success: visually verify the
   safe obstacle avoidance and compare owner/observer positions. GTA may shorten
   clear portions of the path; exact traversal of every node is not required.
5. `/pathpatch handoff` transfers to another nearby ready client. Repeat while
   the pedestrian is on an added node. `/pathpatch wander` exercises wandering.
6. Travel far enough to unload the region, return with `/pathpatch visit`, wait
   for collision readiness, then run `/pathpatchstatus` and navigation again. Restart the resource and repeat.
7. `/pathpatchunload` during navigation must not crash; `/pathpatchload` reloads
   the identical patch. Restart/disconnect/reconnect and repeat several times.
8. Run vanilla vehicle traffic through the region; check driving, lanes and
   traffic lights. Exercise a malformed/truncated file and overlapping resources:
   refusal must leave the previous graph untouched.

No local C++ compilation or runtime test was requested. Static checks and the
independent reviews are separate from CI build results and tester observations.

## Implementation references

Lua registration: `CLuaWorldDefs.cpp`; resource cleanup: `CResource.cpp`;
engine: `CPedPathPatchesSA.cpp`; bounded decoder: `PedPathPatchFormat.h`.
Native reference: compact US 1.0 SHA-256
`72ae59e44c761389e354a50dc6215e964fe771121e2f4b1877273a493ceecc9b`.
Load entry `0x4529F0`, unload entry `0x44D0F0`, CPathFind `0x96F050`.
In the full 1.0 US executable (14,383,616 bytes, the one most players run)
these entries, and dynamic link `0x44E000`, are 5-byte jumps into the SecuROM
section (`0x156F750`, `0x1563FB0`, `0x1560C20`); the client follows them and
hooks the bodies, which carry the same prologues.
