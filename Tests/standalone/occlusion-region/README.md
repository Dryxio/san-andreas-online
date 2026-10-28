# Resource occlusion-region bounds

`setOcclusionRegion` excludes native exterior occluders intersecting an XY
rectangle. Upright occluders use their rotated horizontal footprint; their
height cannot extend that footprint. Tilted records retain a conservative 3D
sphere. A small outward margin includes touching boundaries despite rounding.

The native layout stores length before width, while local X uses width.
Horizontal rotation is an unsigned byte representing one turn in 256 steps.
The implementation follows `COccluder::ProcessOneOccluder` in gta-reversed.

```
clang++ -std=c++17 -I Shared/sdk Tests/standalone/occlusion-region/bounds.cpp -o /tmp/neon-occlusion-bounds
/tmp/neon-occlusion-bounds
```

The test verifies containment of rotated corners across the entire byte-angle
range, flat occluders, a tall building outside Downtown's excavation and the
tilted fallback. It does not establish FPS gains or validate the rectangle
chosen by a resource. A resource removing geometry beyond its rectangle must
also exclude the corresponding occluders. Runtime visual checks remain necessary.
