#include "WorldRenderPolicy.h"
#include <cassert>
#include <iostream>
int main()
{
    using WorldRenderPolicy::Resolve;
    // Every combination includes the otherwise surprising legacy+resource LOD
    // case: historical MTA already scanned 10x when the resource owned a LOD.
    unsigned scenarios = 0;
    for (bool extended : {false, true})
    for (bool legacy : {false, true})
    for (bool resource : {false, true})
    for (bool vegetation : {false, true})
    {
        auto state = Resolve(extended, legacy, resource, vegetation, 2000);
        assert(state.blanketModels == (extended && legacy));
        if (!extended || legacy) assert(state.nativeScale == 1);
        if (extended && !legacy) assert(state.nativeScale > 6 && !state.blanketModels);
        if (resource) assert(state.sectorScale >= 10 && state.hooks);
        if (vegetation) assert(state.hooks);
        if (!extended && !resource && !vegetation) assert(!state.hooks);
        if (extended && legacy && !resource && !vegetation) assert(!state.hooks && state.sectorScale == 1);
        ++scenarios;
    }
    // A server's short far clip must not turn standalone vegetation into an
    // unbounded city scan, and the vegetation switch never adds blanket HD.
    assert(WorldRenderPolicy::VegetationScanScale(200) == 1);
    assert(WorldRenderPolicy::VegetationScanScale(5000) < 5.34f);
    assert(WorldRenderPolicy::VegetationScanScale(650) == 2.5f);
    assert(Resolve(true, false, false, false, 1).nativeScale == 1);
    assert(Resolve(true, false, false, false, 10000).nativeScale < 16.67f);
    std::cout << scenarios << " policy scenarios passed\n";
}
