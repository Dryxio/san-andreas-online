#pragma once

#include <cmath>
#include <utility>

namespace OcclusionRegionBounds
{
    inline std::pair<float, float> HorizontalExtents(float width, float length, float height, unsigned char rotationX, unsigned char rotationY,
                                                     unsigned char rotationZ)
    {
        // Upright occluders cannot project their height onto the excavation's
        // XY rectangle. A 3D sphere needlessly excluded nearby tall buildings.
        // Keep the existing enclosing sphere for tilted records until their
        // full native Euler transform is needed here.
        constexpr float margin = 0.001f;
        if (rotationX || rotationY)
        {
            const float radius = std::sqrt(width * width + length * length + height * height) * 0.5f + margin;
            return {radius, radius};
        }
        constexpr double radiansPerByte = 6.28318530717958647692 / 256.0;
        const double     angle = rotationZ * radiansPerByte;
        const double     cosine = std::abs(std::cos(angle));
        const double     sine = std::abs(std::sin(angle));
        width = std::abs(width);
        length = std::abs(length);
        return {static_cast<float>((width * cosine + length * sine) * 0.5) + margin, static_cast<float>((width * sine + length * cosine) * 0.5) + margin};
    }
}
