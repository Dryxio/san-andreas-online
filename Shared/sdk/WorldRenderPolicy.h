#pragma once
#include <algorithm>
#include <cmath>

// Legacy intentionally reproduces the pre-native-HD-extension behavior. LOD
// resources retain their original 10x scan. Project2DFX and LOD-only modes
// own native visibility hooks independently of those resources.
namespace WorldRenderPolicy
{
    enum class Mode
    {
        Project2DFX = 0,
        LODOnly = 1,
        Legacy = 2
    };

    struct Budgets
    {
        bool  blanketModels;
        bool  hooks;
        float nativeScale;
        float sectorScale;
        float normalScale;
    };
    inline Budgets Resolve(bool extended, Mode mode, bool resourceLods, bool vegetation, float distance, float normalDistance = 300.0f)
    {
        const float scale = extended && mode == Mode::LODOnly ? std::clamp(distance, 300.0f, 5000.0f) / 300.0f : 1.0f;
        const float normal = extended && mode == Mode::Project2DFX ? std::max(300.0f, normalDistance) / 300.0f : 1.0f;
        return {extended && mode == Mode::Legacy, resourceLods || (extended && mode != Mode::Legacy) || vegetation, scale,
                std::max({scale, normal, resourceLods ? 10.0f : 1.0f}), normal};
    }
    // Preserve the historical two-mode policy in its existing regression tests.
    inline Budgets Resolve(bool extended, bool legacy, bool resourceLods, bool vegetation, float distance)
    {
        return Resolve(extended, legacy ? Mode::Legacy : Mode::LODOnly, resourceLods, vegetation, distance);
    }
    inline float VegetationScanScale(float cameraFarClip)
    {
        // Independent vegetation never changes the camera. Include a small
        // bounds margin, capped by the longest authored vegetation LOD range.
        return std::clamp((cameraFarClip + 100.0f) / 300.0f, 1.0f, 1600.0f / 300.0f);
    }
}
