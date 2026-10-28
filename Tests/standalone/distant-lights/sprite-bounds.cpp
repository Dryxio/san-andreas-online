#include <DistantLightSpriteBounds.h>
#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <iostream>
#include <limits>
#include <random>

// Reference: CSprite::RenderBufferedOneXLUSprite_Rotate_Aspect, angle zero.
// Compare its four generated corners, including negative and degenerate sizes.
static bool NativeReject(float x, float y, float w, float h, float width, float height)
{
    const float                angle = 0.0f;
    const float                s = std::sin(angle), c = std::cos(angle);
    const std::array<float, 4> xs{(-c - s) * w + x, (s - c) * w + x, (c + s) * w + x, (c - s) * w + x};
    const std::array<float, 4> ys{(s - c) * h + y, (c + s) * h + y, (c - s) * h + y, (-c - s) * h + y};
    const auto                 below = [](float v) { return v < 0.0f; };
    return std::all_of(xs.begin(), xs.end(), below) || std::all_of(ys.begin(), ys.end(), below) ||
           std::all_of(xs.begin(), xs.end(), [width](float v) { return v > width; }) ||
           std::all_of(ys.begin(), ys.end(), [height](float v) { return v > height; });
}
int main()
{
    std::mt19937                          generator(8675309);
    std::uniform_real_distribution<float> position(-12000.0f, 12000.0f), extent(-2000.0f, 2000.0f);
    for (const auto size : {std::array<float, 2>{640, 480}, {1920, 1080}, {3840, 2160}})
    {
        for (int i = 0; i < 100000; ++i)
        {
            const auto x = position(generator), y = position(generator), w = extent(generator), h = extent(generator);
            assert(DistantLights::SpriteOutsideScreen(x, y, w, h, size[0], size[1]) == NativeReject(x, y, w, h, size[0], size[1]));
        }
        for (const float radius : {0.0f, 0.35f, 1.0f, 10000.0f})
        {
            for (const float edge : {-radius, radius, size[0] - radius, size[0] + radius})
                for (const float x : {std::nextafter(edge, -INFINITY), edge, std::nextafter(edge, INFINITY)})
                    assert(DistantLights::SpriteOutsideScreen(x, 0, radius, radius, size[0], size[1]) == NativeReject(x, 0, radius, radius, size[0], size[1]));
            assert(!DistantLights::SpriteOutsideScreen(-radius, 0, radius, radius, size[0], size[1]));
            assert(!DistantLights::SpriteOutsideScreen(size[0] + radius, 0, radius, radius, size[0], size[1]));
        }
    }
    std::cout << "300000 native corner comparisons and edge cases passed\n";
}
