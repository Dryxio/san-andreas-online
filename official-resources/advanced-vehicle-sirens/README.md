# Advanced Vehicle Sirens (AVS) for Multi Theft Auto

A high-performance, fully synchronized port of the popular **Advanced Vehicle Sirens (AVS)** modification for MTA:SA.

Provides authentic emergency vehicle lightbars, strobes, directional optic flares, rotators, and multi-state lighting arrays (e.g. Emergency, Left/Right traffic arrows) with zero hardcoded offsets or vehicle restrictions.

---

## Features

- **100% Data-Driven & Zero Hardcoding**:
  - Automatically loads `.json` manifests matching the AVS specification.
  - Dynamically scans RenderWare DFF model hierarchies for `siren_1`..`siren_N`, `siren1`..`sirenN`, and `light_em1`..`light_emN` frame dummies.
  - Supports up to 255 independent strobe dummies per vehicle with no engine limits.
- **Directional Optic Flares**:
  - Replicates Total Internal Reflection (TIR) optical lenses using 3D line-of-sight vectors.
  - Strobes are intensely bright when viewed head-on and smoothly attenuate when viewed from lateral angles.
- **360-Degree Rotating Beacons (Rotators)**:
  - Supports revolving lightbars with angular interpolation and directional sweep controls.
- **Multi-State Lighting Arrays**:
  - Supports distinct vehicle states (e.g., `1.Emergency`, `2. Right`, `3. Left`).
  - Smoothly cycles between states or jumps directly to configured patterns.
- **High-Performance Online Synchronization**:
  - Lightweight network synchronization across streamed-in clients.
  - Zero performance overhead when vehicle sirens are switched off.
- **Driver Keybinds & Commands**:
  - `R` or `/sirenstate` or `/avs cycle`: Cycles through available states.
  - `L` or `/sirenmute`: Toggles siren audio wail while keeping strobe lights active.
  - `/avs <state>`: Jump directly to state name or number.

---

## Reference Vehicle

Included out-of-the-box is the **Ford F-250 with Directional Arrow Lightbar** (`yosemite.dff`, `yosemite.txd`, and `554.json`):
- Model ID: `554` (Yosemite)
- Configured with 42 independent siren dummies across 3 functional states:
  1. `1.Emergency` (Full 360 strobe and perimeter flasher array)
  2. `2. Right` (Traffic directional advisor arrow pointing right)
  3. `3. Left` (Traffic directional advisor arrow pointing left)

---

## Developer API

### Server-Side Exports

```lua
-- Set active siren state (accepts state name string e.g. "1.Emergency" or index e.g. 1, or 0 for off)
exports["advanced-vehicle-sirens"]:setVehicleSirenState(vehicle, stateNameOrIndex)

-- Get current siren state (returns string state name or 0)
local state = exports["advanced-vehicle-sirens"]:getVehicleSirenState(vehicle)

-- Cycle to next state (Off -> State 1 -> State 2 -> ... -> Off)
exports["advanced-vehicle-sirens"]:cycleVehicleSirenState(vehicle)

-- Mute / Unmute siren audio wail
exports["advanced-vehicle-sirens"]:setVehicleSirenMuted(vehicle, true)
local isMuted = exports["advanced-vehicle-sirens"]:isVehicleSirenMuted(vehicle)

-- Register a new vehicle model dynamically at runtime
exports["advanced-vehicle-sirens"]:registerVehicleSirenModel(modelId, jsonStringOrTable)

-- Unregister a vehicle model
exports["advanced-vehicle-sirens"]:unregisterVehicleSirenModel(modelId)
```

### Client-Side Exports

```lua
-- Get current vehicle siren state
local state = exports["advanced-vehicle-sirens"]:getVehicleSirenState(vehicle)

-- Check if vehicle sirens are currently active
local active = exports["advanced-vehicle-sirens"]:isVehicleSirenActive(vehicle)

-- Get list of all available states configured for this vehicle
local states = exports["advanced-vehicle-sirens"]:getVehicleAvailableStates(vehicle)
-- Returns: { "1.Emergency", "2. Right", "3. Left" }
```

---

## Adding New Vehicles

1. Place your vehicle model `.json` manifest into the `configs/` folder (e.g., `configs/596.json` for Police LS).
2. Ensure your `.dff` model contains standard AVS dummy naming conventions (`siren_1`, `siren_2`, etc.).
3. The resource will automatically parse and bind the light patterns to that model ID.
