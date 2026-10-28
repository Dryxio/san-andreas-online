# Project2DFX world-distance policy

Mode 0 uses the SALodLights IDETweaker categories and a fixed exterior weather
far-clip multiplier. Mode 1 keeps Neon's native LOD-only extension. Mode 2 keeps
historical Neon Legacy behavior. The master switch does not enable vegetation
LOD meshes or distant lights; those remain independent options.

## Settings

All keys start with `extended_draw_distance_`:

| Suffix | Default | Meaning |
| --- | --- | --- |
| `mode` | 0 | Project2DFX / LOD only / Legacy: 0 / 1 / 2 |
| `p2_percent` | 100 | Player scale: 25–200%, UI step 5%; preserves advanced base values |
| `p2_multiplier` | 2 | Multiply native weather far clip in exterior areas |
| `p2_lod` | 1300 | Original IDE distance greater than 300 |
| `p2_vegetation` | 800 | IDs 615–792, original distance at most 300 |
| `p2_generic` | 300 | Remaining eligible IDs 615–1572 |
| `p2_normal` | 0 | Other eligible normal models |
| `p2_timed` | 0 | Timed models, handled separately |
| `p2_ceiling` | 0 | Optional limit on added far clip; 0 disables the limit |

Category values preserve Project2DFX semantics: 0 disables that category change;
positive values through 10 multiply it; values above 10 specify metres.
A fixed LOD value is a minimum, while other fixed categories replace the value.
Vegetation and generic categories disabled with 0 fall through to the next
eligible category, matching Project2DFX. For unchanged stock vegetation, set
vegetation, generic and normal to 0.
The 36 exclusion ranges apply to normal models, not the separate timed path.
Changing a mode restores the original baseline before applying the next policy.

Neon adaptations preserve explicit Lua model-distance and far-clip overrides,
dynamically allocated IDs, and custom DFF ownership. Restoring/resetting a
replacement or script override makes the stock model eligible again. The native
visibility ceiling and scan follow the normal-object budget without inflating
every model to that ceiling. Existing resource LOD handling is retained.

The optional ceiling limits extension for multipliers of at least 1 while
retaining native weather visibility when it already exceeds the ceiling.
Multipliers below 1 retain their explicit reduction semantics. Lua far-clip
overrides bypass both calculations. At the default ceiling of 0 the reference
Project2DFX multiplier is unchanged.

There is no FPS feedback or altitude bonus in this fixed-multiplier path.
The world slider uses `p2_percent` in mode 0 and `distance` in modes 1 and 2;
each value is preserved separately across mode changes. Existing configurations
get 100% without replacing their advanced values. Thus 100% denotes the reference
profile only when those advanced values are also at their defaults. The old `legacy`
console key remains an alias (true selects 2, false selects 1).

## Verification

```
clang++ -std=c++17 -I Shared/sdk Tests/standalone/project2dfx/policy.cpp -o /tmp/neon-p2-policy
/tmp/neon-p2-policy
```

This checks category boundaries, all 1,588 excluded IDs, multiplier semantics,
and 24 combinations of mode/master/resource LOD/vegetation policy. It is not a
runtime benchmark. VM runtime verification and visual acceptance remain required.

## Player scale and restoration

Decode category values before applying the scale, so the slider cannot change
metres into multipliers at the value 10. Zero, exclusion rules, classification by
original distance, and fixed-LOD minimums are preserved. Apply scale to the
weather multiplier before the optional ceiling. A low scale can produce a final
multiplier below 1 and intentionally shorten visibility. Camera fog and native
LOD minimums can prevent visible changes even when the slider moves.
The effective camera multiplier can reach 20 (advanced base 10 × 200%).
Model ranges can likewise exceed the advanced field's 5000 m maximum after
scaling. The bounded slider does not promise a low performance cost.

Automatic lights continue to follow the resulting camera distance; manual light
range, sun size, preload selection, and simplified vegetation range are not
scaled. Resource far-clip and model overrides still take priority. Turning world
extension off leaves automatic lights following the native/resource camera.

Restore Project2DFX edits the pending world/light profile: mode 0, 100%, reference
advanced world and light values, and simplified vegetation disabled with its
range reset. It preserves both master switches and the saved legacy distance.
Apply persists the profile and Cancel discards it. Other Neon settings are untouched.

Standalone tests cover scale bounds, non-finite inputs, unit-boundary monotonicity,
zero/fallthrough/excluded/timed categories, LOD minimums, weather ceilings, and
repeat scaling without mutating the base values. Native menu, web/native bridge,
reconnect and resource override runtime acceptance remain pending; no VM build
or deployment is part of this slider checkpoint.
