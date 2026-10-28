#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <vector>

namespace DistantLights
{
    // Immutable IPL light positions let us reuse a conservative spatial subset.
    // The margin covers every camera movement until the next refresh; exact
    // distance, flashing and removal checks still run on every selected light.
    class CandidateCache
    {
        using Position = std::array<float, 3>;
        Position                 center{};
        float                    radius{};
        std::size_t              count{};
        bool                     valid{};
        std::vector<std::size_t> indices;
        static float             DistanceSquared(const Position& a, const Position& b)
        {
            float result = 0;
            for (std::size_t i = 0; i < 3; ++i)
                result += (a[i] - b[i]) * (a[i] - b[i]);
            return result;
        }

    public:
        void Clear()
        {
            valid = false;
            indices.clear();
        }
        template <class GetPosition>
        const std::vector<std::size_t>& Select(Position camera, float range, std::size_t sourceCount, GetPosition getPosition)
        {
            constexpr float margin = 64.0f;
            if (!std::isfinite(range) || !std::isfinite(camera[0]) || !std::isfinite(camera[1]) || !std::isfinite(camera[2]))
            {
                Clear();
                return indices;
            }
            // Weather-derived range may change every frame. Spend the same
            // conservative margin on range growth and camera motion together.
            const float allowance = margin - std::max(0.0f, range - radius);
            if (!valid || count != sourceCount || allowance < 0 || DistanceSquared(center, camera) > allowance * allowance)
            {
                center = camera;
                radius = range;
                count = sourceCount;
                valid = true;
                indices.clear();
                const float expanded = range + margin + 1.0f;  // Conservative floating-point boundary slack.
                for (std::size_t i = 0; i < count; ++i)
                    if (DistanceSquared(camera, getPosition(i)) <= expanded * expanded)
                        indices.push_back(i);
            }
            return indices;
        }
    };
}
