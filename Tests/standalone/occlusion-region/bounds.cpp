#include <OcclusionRegionBounds.h>
#include <cassert>
#include <iostream>

int main()
{
    // Compare enclosing extents to every explicitly rotated corner, including
    // flat wall/ground occluders and the full byte-angle domain used by GTA.
    for (unsigned int angle = 0; angle < 256; ++angle)
        for (float width : {0.0f, 19.0f, 67.0f})
            for (float length : {0.0f, 36.0f, 87.0f})
            {
                const auto   extents = OcclusionRegionBounds::HorizontalExtents(width, length, 249.0f, 0, 0, angle);
                const double radians = angle * 6.28318530717958647692 / 256.0;
                for (int sx : {-1, 1})
                    for (int sy : {-1, 1})
                    {
                        const double x = sx * width * 0.5 * std::cos(radians) - sy * length * 0.5 * std::sin(radians);
                        const double y = sx * width * 0.5 * std::sin(radians) + sy * length * 0.5 * std::cos(radians);
                        assert(std::abs(x) <= extents.first && std::abs(y) <= extents.second);
                    }
            }
    // Downtown record 664 lies east of the excavation; its height must not
    // disable it. A genuinely crossing footprint must still be excluded.
    const auto upright = OcclusionRegionBounds::HorizontalExtents(19, 36, 123, 0, 0, 0);
    assert(1475.25f - upright.first > 1450.0f);
    assert(1455.0f - upright.first < 1450.0f);
    const auto tilted = OcclusionRegionBounds::HorizontalExtents(19, 36, 123, 1, 0, 0);
    assert(tilted.first >= std::sqrt(19.0f * 19 + 36.0f * 36 + 123.0f * 123) / 2);
    assert(tilted.first == tilted.second);
    std::cout << "Occlusion bounds: 9216 rotated corners and boundary cases passed\n";
}
