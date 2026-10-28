#include <Project2DFXDrawDistance.h>
#include <WorldRenderPolicy.h>
#include <cassert>
#include <iostream>
#include <limits>
int main()
{
    using namespace Project2DFXDrawDistance;
    Settings settings;
    assert(ResolveFarClip(400, 1.5f, 0) == 600);
    assert(ResolveFarClip(800, 1.5f, 0) == 1200);
    assert(ResolveFarClip(400, 2, 600) == 600);
    assert(ResolveFarClip(800, 1.5f, 600) == 800);
    assert(ResolveFarClip(800, 0.5f, 600) == 400);
    assert(ResolveFarClip(400, 1.5f, -1) == 600);
    // The player slider must be monotone across the category unit boundary,
    // and leave disabled/excluded models alone at every position.
    assert(ResolveFarClip(400, 2, 0, 0.25f) == 200);
    assert(ResolveFarClip(400, 2, 0, 2) == 1600);
    assert(ResolveFarClip(400, 2, 600, 2) == 600);
    assert(ResolveFarClip(800, 2, 600, 2) == 800);
    assert(ResolveFarClip(400, 10, 0, 2) == 8000);  // Advanced base is clamped before scaling.
    assert(ApplyValue(100, 10, false, 2) == 2000);
    assert(ApplyValue(100, 12, false, 0.5f) == 6);
    assert(ApplyValue(1000, 1300, true, 0.25f) == 1000);
    assert(ApplyValue(1000, 1300, true, 2) == 2600);
    assert(SanitizeScale(std::numeric_limits<float>::quiet_NaN()) == 1);
    assert(SanitizeScale(std::numeric_limits<float>::infinity()) == 1);
    assert(SanitizeScale(-1) == 0.25f && SanitizeScale(100) == 2);
    assert(ResolveFarClip(400, 2, 0, std::numeric_limits<float>::quiet_NaN()) == 800);
    for (float base : {0.0f, 0.5f, 10.0f, 10.1f, 800.0f, 5000.0f})
    {
        Settings custom;
        custom.vegetation = base;
        float previous = 0;
        for (int percent = 25; percent <= 200; percent += 5)
        {
            custom.scale = percent / 100.0f;
            const float result = Resolve(620, 150, false, custom);
            assert(result >= previous);
            previous = result;
            assert(Resolve(1700, 500, false, custom) == 500);
            assert(Resolve(4000, 150, false, custom) == 150);
            assert(Resolve(1700, 150, true, custom) == 150);
            assert(custom.vegetation == base);  // Never overwrite the advanced base.
        }
        custom.scale = 1;
        const float initial = Resolve(620, 150, false, custom);
        custom.scale = 2;
        (void)Resolve(620, 150, false, custom);
        custom.scale = 1;
        assert(Resolve(620, 150, false, custom) == initial);
    }
    Settings disabled;
    disabled.vegetation = disabled.generic = disabled.normal = disabled.timed = disabled.lod = 0;
    disabled.scale = 2;
    assert(Resolve(620, 150, false, disabled) == 150);
    assert(Resolve(4000, 900, false, disabled) == 900);
    Settings scaled;
    scaled.scale = 2;
    assert(Resolve(620, 150, false, scaled) == 1600);
    assert(Resolve(620, 301, false, scaled) == 2600);  // Classify from original distance.
    scaled.vegetation = 0;
    assert(Resolve(620, 150, false, scaled) == 600);  // Preserve category fallthrough.

    for (auto mode : {WorldRenderPolicy::Mode::Project2DFX, WorldRenderPolicy::Mode::LODOnly, WorldRenderPolicy::Mode::Legacy})
        for (bool enabled : {false, true})
            for (bool resource : {false, true})
                for (bool vegetation : {false, true})
                {
                    auto budget = WorldRenderPolicy::Resolve(enabled, mode, resource, vegetation, 2000.0f, 800.0f);
                    assert(budget.blanketModels == (enabled && mode == WorldRenderPolicy::Mode::Legacy));
                    assert(budget.normalScale == (enabled && mode == WorldRenderPolicy::Mode::Project2DFX ? 800.0f / 300.0f : 1.0f));
                    if (resource)
                        assert(budget.sectorScale >= 10 && budget.hooks);
                    if (vegetation)
                        assert(budget.hooks);
                    if (!enabled)
                        assert(budget.nativeScale == 1 && budget.normalScale == 1);
                    if (mode == WorldRenderPolicy::Mode::Project2DFX)
                        assert(budget.nativeScale == 1);
                }

    assert(Resolve(620, 150, false, settings) == 800);
    assert(Resolve(620, 301, false, settings) == 1300);
    assert(Resolve(1000, 50, false, settings) == 300);
    assert(Resolve(4000, 50, false, settings) == 50);
    assert(Resolve(4000, 300, false, settings) == 300);
    assert(Resolve(4000, 301, false, settings) == 1300);
    assert(Resolve(4000, 2000, false, settings) == 2000);
    assert(Resolve(1350, 50, false, settings) == 50);    // dynamic2 exclusion
    assert(Resolve(1700, 500, false, settings) == 500);  // interior exclusion
    settings.vegetation = 2;
    assert(Resolve(620, 150, false, settings) == 300);
    settings.generic = 0;
    settings.normal = 3;
    settings.vegetation = 0;
    assert(Resolve(620, 150, false, settings) == 450);
    settings.lod = 0.5f;
    assert(Resolve(4000, 1000, false, settings) == 500);
    settings.timed = 2;
    assert(Resolve(1700, 80, true, settings) == 160);
    assert(ApplyValue(20, 10) == 200);
    assert(ApplyValue(20, 10.1f) == 10.1f);
    settings = {};
    unsigned int excluded = 0;
    for (unsigned int id = 0; id <= 18631; ++id)
    {
        if (IsExcluded(id))
        {
            assert(Resolve(id, 150, false, settings) == 150);
            assert(Resolve(id, 900, false, settings) == 900);
            ++excluded;
        }
    }
    std::cout << "Project2DFX policy boundaries passed; " << excluded << " excluded IDs\n";
}
