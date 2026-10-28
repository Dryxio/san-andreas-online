#pragma once

namespace DistantLights
{
    // Exact axis-aligned form of CSprite's four-corner rejection at angle 0.
    // Keep touching edges and unusual extents: only reject what GTA rejects.
    inline bool SpriteOutsideScreen(float x, float y, float halfWidth, float halfHeight, float width, float height)
    {
        const float left = x - halfWidth, right = x + halfWidth;
        const float top = y - halfHeight, bottom = y + halfHeight;
        return (left < 0.0f && right < 0.0f) || (top < 0.0f && bottom < 0.0f) || (left > width && right > width) || (top > height && bottom > height);
    }
}
