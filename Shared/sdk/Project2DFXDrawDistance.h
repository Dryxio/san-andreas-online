#pragma once
#include <algorithm>
#include <cmath>

// Port of SALodLights' IDETweaker policy. Classification deliberately uses the
// original IDE distance, not a distance already modified by a player/resource.
// Keep the unusual <=10 multiplier rule and LOD minimum semantics compatible.
namespace Project2DFXDrawDistance
{
    // A separate player scale preserves advanced values and their unit semantics.
    inline float SanitizeScale(float scale)
    {
        return std::isfinite(scale) ? std::clamp(scale, 0.25f, 2.0f) : 1.0f;
    }
    inline float ResolveFarClip(float original, float multiplier, float ceiling, float scale = 1.0f)
    {
        multiplier = std::isfinite(multiplier) ? std::clamp(multiplier, 0.1f, 10.0f) : 2.0f;
        multiplier *= SanitizeScale(scale);
        const float extended = original * multiplier;
        // Optional Neon ceiling limits extra range, never the native weather
        // visibility. Explicit sub-1 multipliers retain Project2DFX semantics.
        if (std::isfinite(ceiling) && ceiling > 0.0f && multiplier >= 1.0f)
            return std::max(original, std::min(extended, ceiling));
        return extended;
    }
    struct Settings
    {
        float scale{1.0f};
        float lod{1300.0f};
        float vegetation{800.0f};
        float generic{300.0f};
        float normal{0.0f};
        float timed{0.0f};
    };
    inline Settings Sanitize(Settings value)
    {
        value.scale = SanitizeScale(value.scale);
        const Settings defaults;
        float Settings::* members[] = {&Settings::lod, &Settings::vegetation, &Settings::generic, &Settings::normal, &Settings::timed};
        for (auto member : members)
            value.*member = std::isfinite(value.*member) ? std::clamp(value.*member, 0.0f, 5000.0f) : defaults.*member;
        return value;
    }
    inline bool IsExcluded(unsigned int id)
    {
        struct Range
        {
            unsigned int first, last;
        };
        static constexpr Range ranges[] = {
            {910, 955},     {1700, 1776},   {2360, 2872},   {2880, 2882},   {13590, 13667}, {14383, 14495}, {14497, 14528}, {14530, 14540}, {14542, 14554},
            {14556, 14556}, {14558, 14614}, {14616, 14630}, {14632, 14633}, {14635, 14641}, {14643, 14643}, {14650, 14657}, {14660, 14695}, {14699, 14728},
            {14735, 14762}, {14764, 14765}, {14770, 14856}, {14858, 14883}, {14885, 14898}, {14900, 14903}, {15025, 15043}, {15046, 15064}, {18000, 18036},
            {18038, 18075}, {18077, 18086}, {18088, 18092}, {18094, 18095}, {18098, 18101}, {18104, 18105}, {18109, 18109}, {18112, 18112}, {1327, 1572},
        };
        for (const auto& range : ranges)
            if (id >= range.first && id <= range.last)
                return true;
        return false;
    }
    inline float ApplyValue(float authored, float setting, bool minimum = false, float scale = 1.0f)
    {
        if (setting == 0.0f)
            return authored;
        // Decode before scaling: crossing 10 must never turn metres into a
        // multiplier. Zero and fixed-LOD minimums retain their original meaning.
        scale = SanitizeScale(scale);
        if (setting <= 10.0f)
            return authored * setting * scale;
        return minimum ? std::max(authored, setting * scale) : setting * scale;
    }
    inline float Resolve(unsigned int id, float authored, bool timed, const Settings& settings)
    {
        // Timed objects have their own loader hook in Project2DFX.
        if (timed)
            return ApplyValue(authored, settings.timed, false, settings.scale);
        if (IsExcluded(id))
            return authored;
        if (settings.vegetation != 0.0f && id >= 615 && id <= 792 && authored <= 300.0f)
            return ApplyValue(authored, settings.vegetation, false, settings.scale);
        if (authored > 300.0f)
            return ApplyValue(authored, settings.lod, true, settings.scale);
        if (settings.generic != 0.0f && id >= 615 && id <= 1572)
            return ApplyValue(authored, settings.generic, false, settings.scale);
        return ApplyValue(authored, settings.normal, false, settings.scale);
    }
}
