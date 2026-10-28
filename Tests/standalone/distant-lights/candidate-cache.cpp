#include <DistantLightCandidateCache.h>
#include <algorithm>
#include <cassert>
#include <iostream>
int main()
{
    using Position = std::array<float, 3>;
    std::vector<Position> points;
    for (int x = -3000; x <= 3000; x += 80)
        for (int y = -3000; y <= 3000; y += 80)
            points.push_back({float(x), float(y), float((x + y) % 150)});
    DistantLights::CandidateCache cache;
    for (int frame = 0; frame < 240; ++frame)
    {
        Position    camera{float(frame * 5 - 600), float(frame % 41 * 3), float(frame % 11)};
        const float range = frame < 100 ? 1800.0f + float(frame % 17) : 300.0f + float(frame % 7);
        if (frame == 120)
            points.push_back(camera);  // Newly streamed source.
        if (frame == 180)
        {
            points.front() = camera;
            cache.Clear();
        }  // Same-sized rebuild.
        const auto& selected = cache.Select(camera, range, points.size(), [&](std::size_t i) { return points[i]; });
        assert(std::is_sorted(selected.begin(), selected.end()));
        assert(selected.size() < points.size());
        for (std::size_t i = 0; i < points.size(); ++i)
        {
            float d2 = 0;
            for (int axis = 0; axis < 3; ++axis)
                d2 += (camera[axis] - points[i][axis]) * (camera[axis] - points[i][axis]);
            if (d2 <= range * range)
                assert(std::binary_search(selected.begin(), selected.end(), i));
        }
    }
    // A cached boundary at precisely the movement margin must not lose an entrant.
    std::vector<Position> boundary{{365, 0, 0}, {10000, 0, 0}};
    cache.Clear();
    cache.Select({0, 0, 0}, 301, boundary.size(), [&](std::size_t i) { return boundary[i]; });
    const auto& selected = cache.Select({64, 0, 0}, 301, boundary.size(), [&](std::size_t i) { return boundary[i]; });
    assert(selected.size() == 1 && selected[0] == 0);
    int reads = 0;
    cache.Clear();
    auto getter = [&](std::size_t i)
    {
        ++reads;
        return boundary[i];
    };
    cache.Select({0, 0, 0}, 301, boundary.size(), getter);
    cache.Select({0, 0, 0}, 310, boundary.size(), getter);
    assert(reads == 2);  // Small automatic-range changes reuse the conservative subset.
    cache.Select({64, 0, 0}, 310, boundary.size(), getter);
    assert(reads == 4);  // Growth and movement together exhaust the margin.
    std::cout << "240 moving-camera cache comparisons and boundary checks passed\n";
}
