// Run with c++ -std=c++17 Tests/standalone/test_water_entity_flags.cpp -o /tmp/water-flags && /tmp/water-flags
#include "../../Shared/sdk/WaterFlags.h"
#include <string>

struct BitWriter
{
    std::string bits;
    void WriteBit(bool value) { bits += value ? '1' : '0'; }
};

int main()
{
    // Order by water.dat flag (hidden, visible, hidden shallow, visible shallow).
    const char* current[] = {"00", "01", "10", "11"};
    const char* release189[] = {"1", "0", "1", "0"};
    for (unsigned char flags = 0; flags <= WaterFlags::All; ++flags)
    {
        BitWriter modern, legacy;
        WaterFlags::WriteEntityFlags(modern, flags, false);
        WaterFlags::WriteEntityFlags(legacy, flags, true);
        if (modern.bits != current[flags] || legacy.bits != release189[flags])
            return 1;
    }
    return 0;
}
