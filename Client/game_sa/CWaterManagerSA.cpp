/*****************************************************************************
 *
 *  PROJECT:     Multi Theft Auto v1.0
 *  LICENSE:     See LICENSE in the top level directory
 *  FILE:        game_sa/CWaterManagerSA.cpp
 *  PURPOSE:     Control the lakes and seas
 *
 *  Multi Theft Auto is available from https://www.multitheftauto.com/
 *
 *****************************************************************************/

#include "StdInc.h"
#include <core/CCoreInterface.h>
#include <multiplayer/CMultiplayer.h>
#include "CWaterManagerSA.h"
#include "CWorldSectorCodeMover.h"

#include <array>
#include <cmath>
#include <cstring>

extern CCoreInterface* g_pCore;

extern int ms_iNumNonDefaultAndNonZeroVertices;

#define WATER_VISIBLE 1
#define WATER_SHALLOW 2
// SA's own polygon flag bits are bToBeRendered (1), bInvisible (2) and
// bLimitedDepth (4); water.dat flag 3 (swimming pools) sets bLimitedDepth.
// The native depth test reads bit 4, so the extended lookup must too:
// testing WATER_SHALLOW (2) made every pool count as bottomless water, which
// put tunnels under pools "underwater" (issue #128).
#define WATER_SA_LIMITED_DEPTH 4

using namespace std;

#define POLYENTRY_TYPE(entry)    ((entry)->m_wValue >> 14)
#define POLYENTRY_ID(entry)      ((entry)->m_wValue & 0x3FFF)
#define MAKE_POLYENTRY(type, id) (WORD)(((type) << 14) | (id))

// These are code references in SA to the various data pools. We relocate these pools
// to our own buffers to have more space, and thus have to update all references.
DWORD CWaterManagerSA::m_VertexXrefs[] = {
    0x6E5B6E, 0x6E5BC3, 0x6E5BF7, 0x6E5EA3, 0x6E5ED7, 0x6E5F84, 0x6E5F8B, 0x6E6487, 0x6E64A7, 0x6E65E4, 0x6E6608, 0x6E7B9B, 0x6E7BBC, 0x6E7C51, 0x6E7C73,
    0x6E7E11, 0x6E7E18, 0x6E7E3A, 0x6E7E41, 0x6E7E5A, 0x6E7E61, 0x6E811C, 0x6E8127, 0x6E8143, 0x6E814E, 0x6E9E2F, 0x6E9E63, 0x6EA00A, 0x6EA04C, 0x6EA08E,
    0x6EFC1F, 0x6EFC5E, 0x6EFC95, 0x6EFDF9, 0x6EFE31, 0x6E5B36, 0x6E5B75, 0x6E5C15, 0x6E5C45, 0x6E5EFC, 0x6E5F06, 0x6E64BF, 0x6E64E0, 0x6E6624, 0x6E6649,
    0x6E7BDC, 0x6E7BF6, 0x6E7C58, 0x6E7C8E, 0x6E7DF8, 0x6E7E08, 0x6E7E31, 0x6E801C, 0x6E8029, 0x6E804B, 0x6E8060, 0x6E807B, 0x6E8088, 0x6E809A, 0x6E80BF,
    0x6E80D8, 0x6E80FD, 0x6E9E8D, 0x6E9EC1, 0x6E9FFF, 0x6EA03D, 0x6EA07F, 0x6EFC18, 0x6EFC57, 0x6EFC8E, 0x6EFDCB, 0x6EFE2A, 0x6E5863, 0x6E58B7, 0x6E5945,
    0x6E598F, 0x6E5B7B, 0x6E5CA9, 0x6E5CB3, 0x6E5CBB, 0x6E5CC7, 0x6E5CD3, 0x6E5D83, 0x6E5D8E, 0x6E5D96, 0x6E5DA3, 0x6E5DAE, 0x6E5FC4, 0x6E5FD0, 0x6E5FDE,
    0x6E5FE4, 0x6E5FF0, 0x6E60AE, 0x6E60BA, 0x6E60C4, 0x6E60CA, 0x6E60D4, 0x6E9FC7, 0x6EFBF6, 0x6EFC35, 0x6EFC6C, 0x6EFD90, 0x6EFDC2, 0x6EFDF0, 0x6EFE1E,
    0x6E5CEF, 0x6E5CFD, 0x6E5D06, 0x6E5D0D, 0x6E5D1A, 0x6E5DCB, 0x6E5DD9, 0x6E5DE2, 0x6E5DE9, 0x6E5DF4, 0x6E600C, 0x6E601A, 0x6E6025, 0x6E602C, 0x6E6039,
    0x6E60F0, 0x6E60FE, 0x6E6107, 0x6E610E, 0x6E611B, 0x6E9F09, 0x6E9F41, 0x6E9F71, 0x6E9FA1, 0x6E5D30, 0x6E5D3E, 0x6E5D47, 0x6E5D4E, 0x6E5D5B, 0x6E5E0B,
    0x6E5E19, 0x6E5E22, 0x6E5E29, 0x6E5E34, 0x6E604F, 0x6E605D, 0x6E6068, 0x6E606F, 0x6E607C, 0x6E6131, 0x6E613F, 0x6E6148, 0x6E614F, 0x6E615C, 0x6E9F20,
    0x6E9F54, 0x6E9F84, 0x6E9FB4, 0x6EA0EE, 0x6EA149, 0x6EA193, 0x6EA1CB, 0x6EA0F5, 0x6EA150, 0x6EA19A, 0x6EA1D2, 0x000000};

DWORD CWaterManagerSA::m_QuadXrefs[] = {0x6E5859, 0x6E5985, 0x6E63C8, 0x6E652B, 0x6E7B88, 0x6E816A, 0x6E8635, 0x6E8709, 0x6E9E1D, 0x6E8171, 0x6E8178, 0x6EFCCF,
                                        0x6E817F, 0x6E5849, 0x6E588A, 0x6E5979, 0x6E59B0, 0x6E8185, 0x6E8199, 0x6E81AD, 0x6E81B5, 0x6E81CB, 0x000000};

DWORD CWaterManagerSA::m_TriangleXrefs[] = {0x6E58AD, 0x6E593B, 0x6E7C44, 0x6E7E7F, 0x6E8673, 0x6E86E4, 0x6EFC27, 0x6E7C64, 0x6E7E8B,
                                            0x6EFBEA, 0x6E7C7F, 0x6E7E93, 0x6EFBE2, 0x6E589D, 0x6E58DE, 0x6E592F, 0x6E5966, 0x6E7E9A,
                                            0x6E7EA8, 0x6E7EBD, 0x6E7EC6, 0x6E7EDA, 0x6EFBD3, 0x6EFCA3, 0x000000};

DWORD CWaterManagerSA::m_ZonePolyXrefs[] = {0x6E57B2, 0x6E57AA, 0x6E57C8, 0x6E58F2, 0x6E638F, 0x6E86A1, 0x6E6387, 0x6E8699, 0x6E57DE, 0x6E57E8, 0x000000};

CWaterManagerSA* g_pWaterManager = NULL;

namespace
{
    constexpr std::size_t WATER_MOVED_CODE_CAPACITY = 4096;
    constexpr int         TOTAL_EXTENDED_WATER_BLOCKS = NUM_WaterZones;
    constexpr int         OUTSIDE_WORLD_BLOCKS_CAPACITY = 512;

    int   g_extendedWaterBlocksPerDimension = EXTENDED_WATER_BLOCKS_PER_DIMENSION;
    float g_extendedWaterBlocksHalf = static_cast<float>(EXTENDED_WATER_BLOCKS_HALF);
    float g_extendedWaterMapMinCoord = EXTENDED_WATER_MAP_MIN_COORD;
    float g_extendedWaterMapMaxCoord = EXTENDED_WATER_MAP_MAX_COORD;

    std::array<CWaterPolyEntrySAInterface, TOTAL_EXTENDED_WATER_BLOCKS> g_extendedWaterZones{};
    short g_blocksToBeRenderedOutsideWorldX[OUTSIDE_WORLD_BLOCKS_CAPACITY]{};
    short g_blocksToBeRenderedOutsideWorldY[OUTSIDE_WORLD_BLOCKS_CAPACITY]{};
    std::uint8_t* g_waterMovedCode{};
    bool          g_extendedWaterMapInstalled{};
    float         g_worldSeaBedOuterBoundary{-1.0f};

    using RenderSeaBedSegment_t = void(__cdecl*)(int, int, float, float, float, float);

    bool ShouldRenderWorldSeaBedBlock(int blockX, int blockY)
    {
        if (g_worldSeaBedOuterBoundary < 0.0f)
            return true;

        // The procedural seabed keeps GTA's original 500-unit block coordinate
        // system even though custom water now uses Neon's extended 40x40 index.
        constexpr float vanillaWaterHalfSize = VANILLA_WATER_BLOCKS_HALF * EXTENDED_WATER_BLOCK_SIZE;
        const float     minX = blockX * EXTENDED_WATER_BLOCK_SIZE - vanillaWaterHalfSize;
        const float     maxX = minX + EXTENDED_WATER_BLOCK_SIZE;
        const float     minY = blockY * EXTENDED_WATER_BLOCK_SIZE - vanillaWaterHalfSize;
        const float     maxY = minY + EXTENDED_WATER_BLOCK_SIZE;
        return minX < g_worldSeaBedOuterBoundary && maxX > -g_worldSeaBedOuterBoundary && minY < g_worldSeaBedOuterBoundary &&
               maxY > -g_worldSeaBedOuterBoundary;
    }

    void __cdecl RenderFilteredSeaBedSegment(int blockX, int blockY, float minU, float maxU, float minV, float maxV)
    {
        if (ShouldRenderWorldSeaBedBlock(blockX, blockY))
            reinterpret_cast<RenderSeaBedSegment_t>(0x6E6870)(blockX, blockY, minU, maxU, minV, maxV);
    }

    void __cdecl RenderFilteredDetailedSeaBedSegment(int blockX, int blockY, float minU, float maxU, float minV, float maxV)
    {
        if (ShouldRenderWorldSeaBedBlock(blockX, blockY))
            reinterpret_cast<RenderSeaBedSegment_t>(0x6E6A10)(blockX, blockY, minU, maxU, minV, maxV);
    }

    struct SWaterMapManifestEntry
    {
        std::uintptr_t      address;
        std::size_t         originalSize;
        const std::uint8_t* bytecode;
        std::size_t         bytecodeSize;
        std::uintptr_t      continueAt;
    };

#include "CWaterMapManifest.inc"

    bool ReadWaterPatchMemory(std::uintptr_t address, void* output, std::size_t size)
    {
        MEMORY_BASIC_INFORMATION memory{};
        if (VirtualQuery(reinterpret_cast<const void*>(address), &memory, sizeof(memory)) != sizeof(memory) || memory.State != MEM_COMMIT ||
            (memory.Protect & (PAGE_NOACCESS | PAGE_GUARD)) != 0 ||
            address + size > reinterpret_cast<std::uintptr_t>(memory.BaseAddress) + memory.RegionSize)
        {
            return false;
        }

        std::memcpy(output, reinterpret_cast<const void*>(address), size);
        return true;
    }

    bool WriteWaterPatchMemory(std::uintptr_t address, const void* bytes, std::size_t size)
    {
        DWORD oldProtection{};
        if (!VirtualProtect(reinterpret_cast<void*>(address), size, PAGE_EXECUTE_READWRITE, &oldProtection))
            return false;

        std::memcpy(reinterpret_cast<void*>(address), bytes, size);
        FlushInstructionCache(GetCurrentProcess(), reinterpret_cast<void*>(address), size);
        DWORD ignored{};
        return VirtualProtect(reinterpret_cast<void*>(address), size, oldProtection, &ignored) != FALSE;
    }

    bool TestExtendedWaterLevelHeight(float positionZ, float waterLevel, bool limitedDepth)
    {
        const float lowerTolerance = *reinterpret_cast<float*>(0x858B44);
        const float upperTolerance = *reinterpret_cast<float*>(0x858BA4);
        return (waterLevel - lowerTolerance <= positionZ || !limitedDepth) && waterLevel + upperTolerance >= positionZ;
    }

    struct SWaterVertexValues
    {
        CVector position;
        float   bigWaves;
        float   smallWaves;
    };

    SWaterVertexValues GetWaterVertexValues(CWaterPolySA* polygon, int index)
    {
        auto* vertex = static_cast<CWaterVertexSA*>(polygon->GetVertex(index));
        SWaterVertexValues values{};
        vertex->GetPosition(values.position);
        values.bigWaves = vertex->GetInterface()->m_fUnknown;
        values.smallWaves = vertex->GetInterface()->m_fHeight;
        return values;
    }

    bool TestExtendedWaterPolygon(CWaterPolySA* polygon, const CVector& position, float* waterLevel, float* bigWaves, float* smallWaves)
    {
        const SWaterVertexValues v0 = GetWaterVertexValues(polygon, 0);
        const SWaterVertexValues v1 = GetWaterVertexValues(polygon, 1);
        const SWaterVertexValues v2 = GetWaterVertexValues(polygon, 2);

        if (position.fX < v0.position.fX || v1.position.fX < position.fX)
            return false;

        const float xT = (position.fX - v0.position.fX) / (v1.position.fX - v0.position.fX);
        bool        limitedDepth{};

        if (polygon->GetType() == WATER_POLY_QUAD)
        {
            const SWaterVertexValues v3 = GetWaterVertexValues(polygon, 3);
            if (position.fY < v0.position.fY || v2.position.fY < position.fY)
                return false;

            const float yT = (position.fY - v0.position.fY) / (v2.position.fY - v0.position.fY);
            if (xT + yT > 1.0f)
            {
                const float inverseX = 1.0f - xT;
                const float inverseY = 1.0f - yT;
                *waterLevel = (v1.position.fZ - v3.position.fZ) * inverseY + (v2.position.fZ - v3.position.fZ) * inverseX + v3.position.fZ;
                if (bigWaves)
                {
                    *bigWaves = (v2.bigWaves - v3.bigWaves) * inverseX + (v1.bigWaves - v3.bigWaves) * inverseY + v3.bigWaves;
                    *smallWaves = (v2.smallWaves - v3.smallWaves) * inverseX + (v1.smallWaves - v3.smallWaves) * inverseY + v3.smallWaves;
                }
            }
            else
            {
                *waterLevel = (v1.position.fZ - v0.position.fZ) * xT + (v2.position.fZ - v0.position.fZ) * yT + v0.position.fZ;
                if (bigWaves)
                {
                    *bigWaves = (v1.bigWaves - v0.bigWaves) * xT + (v2.bigWaves - v0.bigWaves) * yT + v0.bigWaves;
                    *smallWaves = (v1.smallWaves - v0.smallWaves) * xT + (v2.smallWaves - v0.smallWaves) * yT + v0.smallWaves;
                }
            }
            limitedDepth = (static_cast<CWaterQuadSA*>(polygon)->GetInterface()->m_wFlags & WATER_SA_LIMITED_DEPTH) != 0;
        }
        else
        {
            const float minY = std::min(v0.position.fY, v2.position.fY);
            const float maxY = std::max(v0.position.fY, v2.position.fY);
            if (position.fY < minY || maxY < position.fY)
                return false;

            const float yT = (position.fY - v0.position.fY) / (v2.position.fY - v0.position.fY);
            if (v0.position.fX == v2.position.fX)
            {
                if (xT + yT > 1.0f)
                    return false;
                *waterLevel = (v1.position.fZ - v0.position.fZ) * xT + (v2.position.fZ - v0.position.fZ) * yT + v0.position.fZ;
                if (bigWaves)
                {
                    *bigWaves = (v2.bigWaves - v0.bigWaves) * yT + (v1.bigWaves - v0.bigWaves) * xT + v0.bigWaves;
                    *smallWaves = (v1.smallWaves - v0.smallWaves) * xT + (v2.smallWaves - v0.smallWaves) * yT + v0.smallWaves;
                }
            }
            else
            {
                if (xT < yT)
                    return false;
                const float inverseX = 1.0f - xT;
                *waterLevel = (v0.position.fZ - v1.position.fZ) * inverseX + (v2.position.fZ - v1.position.fZ) * yT + v1.position.fZ;
                if (bigWaves)
                {
                    *bigWaves = (v2.bigWaves - v1.bigWaves) * yT + (v0.bigWaves - v1.bigWaves) * inverseX + v1.bigWaves;
                    *smallWaves = (v2.smallWaves - v1.smallWaves) * yT + (v0.smallWaves - v1.smallWaves) * inverseX + v1.smallWaves;
                }
            }
            limitedDepth = (static_cast<CWaterTriangleSA*>(polygon)->GetInterface()->m_wFlags & WATER_SA_LIMITED_DEPTH) != 0;
        }

        return !bigWaves || TestExtendedWaterLevelHeight(position.fZ, *waterLevel, limitedDepth);
    }

    bool __cdecl ExtendedGetWaterLevelNoWaves(CVector position, float* waterLevel, float* bigWaves, float* smallWaves)
    {
        if (position.fX >= EXTENDED_WATER_MAP_MIN_COORD && position.fX < EXTENDED_WATER_MAP_MAX_COORD &&
            position.fY >= EXTENDED_WATER_MAP_MIN_COORD && position.fY < EXTENDED_WATER_MAP_MAX_COORD)
        {
            CWaterZoneSA* zone = g_pWaterManager->GetZoneContaining(position.fX, position.fY);
            if (zone)
            {
                for (CWaterZoneSA::iterator iterator = zone->begin(); *iterator; ++iterator)
                {
                    if (TestExtendedWaterPolygon(*iterator, position, waterLevel, bigWaves, smallWaves))
                        return true;
                }
            }
        }

        // Preserve GTA's infinite sea independently from the custom polygon
        // index. An extended empty block outside San Andreas is still ocean.
        if (position.fX < -3000.0f || position.fX > 3000.0f || position.fY < -3000.0f || position.fY > 3000.0f)
        {
            *waterLevel = *reinterpret_cast<float*>(0x6E873F);
            if (bigWaves)
            {
                *bigWaves = 1.0f;
                *smallWaves = 0.0f;
            }
            return true;
        }
        return false;
    }

    void __cdecl ExtendedWaterBlockHit(int blockX, int blockY)
    {
        if (blockX >= 0 && blockX < EXTENDED_WATER_BLOCKS_PER_DIMENSION && blockY >= 0 && blockY < EXTENDED_WATER_BLOCKS_PER_DIMENSION)
        {
            using MarkWaterPolygons_t = void(__cdecl*)(int, int, bool);
            reinterpret_cast<MarkWaterPolygons_t>(0x6E5810)(blockX, blockY, *reinterpret_cast<DWORD*>(0xB72914) != 0);
        }

        const int vanillaMinBlock = EXTENDED_WATER_TO_VANILLA_BLOCK_OFFSET;
        const int vanillaMaxBlock = vanillaMinBlock + VANILLA_WATER_BLOCKS_PER_DIMENSION - 1;
        if (blockX <= vanillaMinBlock || blockX >= vanillaMaxBlock || blockY <= vanillaMinBlock || blockY >= vanillaMaxBlock)
        {
            auto& count = *reinterpret_cast<DWORD*>(0xC215EC);
            if (count < OUTSIDE_WORLD_BLOCKS_CAPACITY)
            {
                g_blocksToBeRenderedOutsideWorldX[count] = static_cast<short>(blockX - EXTENDED_WATER_TO_VANILLA_BLOCK_OFFSET);
                g_blocksToBeRenderedOutsideWorldY[count] = static_cast<short>(blockY - EXTENDED_WATER_TO_VANILLA_BLOCK_OFFSET);
                ++count;
            }
        }
    }

    __declspec(naked) void PatchWaterAddToBlock()
    {
        MTA_VERIFY_HOOK_LOCAL_SIZE;
        __asm
        {
            imul eax, g_extendedWaterBlocksPerDimension
            add ecx, eax
            push 0x6E575E
            retn
        }
    }

    __declspec(naked) void PatchWaterMarkBlock()
    {
        MTA_VERIFY_HOOK_LOCAL_SIZE;
        __asm
        {
            imul eax, g_extendedWaterBlocksPerDimension
            lea edx, [ecx + eax]
            push 0x6E581E
            retn
        }
    }

    __declspec(naked) void PatchWaterTestLineBlock()
    {
        MTA_VERIFY_HOOK_LOCAL_SIZE;
        __asm
        {
            mov ebp, edi
            imul ebp, g_extendedWaterBlocksPerDimension
            push 0x6E631E
            retn
        }
    }

    void PatchWaterPointerReferences(const std::uintptr_t* addresses, std::size_t count, const void* value)
    {
        for (std::size_t i = 0; i < count; ++i)
            MemPut<DWORD>(addresses[i], reinterpret_cast<DWORD>(value));
    }

    bool InstallExtendedWaterMapPatch()
    {
        if (g_extendedWaterMapInstalled)
            return true;

        constexpr int vanillaOffset = EXTENDED_WATER_TO_VANILLA_BLOCK_OFFSET;
        auto* const   vanillaZones = reinterpret_cast<CWaterPolyEntrySAInterface*>(ARRAY_WaterZones);
        for (int x = 0; x < VANILLA_WATER_BLOCKS_PER_DIMENSION; ++x)
        {
            for (int y = 0; y < VANILLA_WATER_BLOCKS_PER_DIMENSION; ++y)
            {
                g_extendedWaterZones[(x + vanillaOffset) * EXTENDED_WATER_BLOCKS_PER_DIMENSION + y + vanillaOffset] =
                    vanillaZones[x * VANILLA_WATER_BLOCKS_PER_DIMENSION + y];
            }
        }

        g_waterMovedCode = static_cast<std::uint8_t*>(
            VirtualAlloc(nullptr, WATER_MOVED_CODE_CAPACITY, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE));
        if (!g_waterMovedCode)
            return false;

        CWorldSectorCodeMover mover(reinterpret_cast<std::uintptr_t>(g_waterMovedCode), WATER_MOVED_CODE_CAPACITY, ReadWaterPatchMemory);
        mover.SetVariable("NUMBER_OF_WATER_BLOCKS_PER_DIMENSION", EXTENDED_WATER_BLOCKS_PER_DIMENSION);
        mover.SetVariable("NUMBER_OF_WATER_BLOCKS_PER_DIMENSION_MINUS_ONE", EXTENDED_WATER_BLOCKS_PER_DIMENSION - 1);
        mover.SetVariable("TOTAL_NUMBER_OF_WATER_BLOCKS", TOTAL_EXTENDED_WATER_BLOCKS);

        // BlockHit and GetWaterLevelNoWaves are replaced completely to retain
        // the vanilla ocean boundary. Only TestLineAgainstWater still needs
        // Fastman92's widened loop bounds.
        for (std::size_t i = 12; i < std::size(WATER_MAP_MANIFEST); ++i)
        {
            const SWaterMapManifestEntry& entry = WATER_MAP_MANIFEST[i];
            if (!mover.Prepare(entry.address, entry.originalSize, entry.bytecode, entry.bytecodeSize, entry.continueAt))
                return false;
        }
        if (!mover.Commit(WriteWaterPatchMemory))
            return false;

        const std::uintptr_t blockArrayReferences[] = {0x6E5762, 0x6E5783, 0x6E5801, 0x6E5822, 0x6E635E, 0x6E85F3, 0x6EAE94};
        PatchWaterPointerReferences(blockArrayReferences, std::size(blockArrayReferences), g_extendedWaterZones.data());

        const std::uintptr_t minCoordReferences[] = {0x6E5A4A, 0x6E5AB9, 0x6E9DA1, 0x6E9DE7};
        const std::uintptr_t maxCoordReferences[] = {0x6E5A83, 0x6E5AF9, 0x6E7B4C, 0x6E7B6F, 0x6E9DD2, 0x6E9DFC};
        PatchWaterPointerReferences(minCoordReferences, std::size(minCoordReferences), &g_extendedWaterMapMinCoord);
        PatchWaterPointerReferences(maxCoordReferences, std::size(maxCoordReferences), &g_extendedWaterMapMaxCoord);

        const std::uintptr_t scanHalfReferences[] = {0x6E6DC4, 0x6E6DD8, 0x6E6DEC, 0x6E6E00, 0x6E6E14,
                                                     0x6E6E28, 0x6E6E48, 0x6E6E5C, 0x6E6E70, 0x6E6E84};
        const std::uintptr_t lineHalfReferences[] = {0x6E62B9, 0x6E62CE, 0x6E62E5, 0x6E62FA, 0x6E6734, 0x6E674C};
        PatchWaterPointerReferences(scanHalfReferences, std::size(scanHalfReferences), &g_extendedWaterBlocksHalf);
        PatchWaterPointerReferences(lineHalfReferences, std::size(lineHalfReferences), &g_extendedWaterBlocksHalf);

        MemPut<DWORD>(0x6E5A57, static_cast<DWORD>(-10000));
        MemPut<DWORD>(0x6E5A8F, static_cast<DWORD>(10000));
        MemPut<DWORD>(0x6E5AC5, static_cast<DWORD>(-10000));
        MemPut<DWORD>(0x6E5B05, static_cast<DWORD>(10000));
        MemPut<DWORD>(0x6E7D0D, 20000);
        MemPut<DWORD>(0x6E7D2A, 20000);
        MemPut<DWORD>(0x6EAE8F, (TOTAL_EXTENDED_WATER_BLOCKS * sizeof(WORD)) / sizeof(DWORD));

        HookInstall(0x6E5758, reinterpret_cast<DWORD>(&PatchWaterAddToBlock), 6);
        HookInstall(0x6E5818, reinterpret_cast<DWORD>(&PatchWaterMarkBlock), 6);
        HookInstall(0x6E6318, reinterpret_cast<DWORD>(&PatchWaterTestLineBlock), 6);
        HookInstall(0x6E6CA0, reinterpret_cast<DWORD>(&ExtendedWaterBlockHit), 5);
        HookInstall(0x6E8580, reinterpret_cast<DWORD>(&ExtendedGetWaterLevelNoWaves), 5);

        // These are the only four native RenderWater call sites that generate
        // the non-entity `seabd32` floor. Filtering them leaves the separate
        // infinite-ocean water pass and all water physics untouched.
        HookInstallCall(0x6EF80F, reinterpret_cast<DWORD>(&RenderFilteredDetailedSeaBedSegment));
        HookInstallCall(0x6EF822, reinterpret_cast<DWORD>(&RenderFilteredSeaBedSegment));
        HookInstallCall(0x6EF848, reinterpret_cast<DWORD>(&RenderFilteredDetailedSeaBedSegment));
        HookInstallCall(0x6EF861, reinterpret_cast<DWORD>(&RenderFilteredSeaBedSegment));

        g_extendedWaterMapInstalled = true;
        return true;
    }
}

CWaterPolyEntrySAInterface* GetExtendedWaterZoneArray()
{
    return g_extendedWaterZones.data();
}

// -----------------------------------------------------
// Water zone iterator (iterates over polys in a zone)

CWaterZoneSA::iterator::iterator()
{
    m_pCurrent = NULL;
    m_pFirst = NULL;
    m_bSinglePoly = false;
}

CWaterZoneSA::iterator::iterator(CWaterZoneSA* pZone)
{
    if (POLYENTRY_TYPE(pZone->GetInterface()) == WATER_POLY_LIST)
    {
        m_pCurrent = &g_pWaterManager->m_ZonePolyPool[POLYENTRY_ID(pZone->GetInterface())];
        m_bSinglePoly = false;
    }
    else
    {
        m_pCurrent = pZone->GetInterface();
        m_bSinglePoly = true;
    }
    m_pFirst = m_pCurrent;
}

CWaterZoneSA::iterator::iterator(const CWaterZoneSA::iterator& other)
{
    operator=(other);
}

CWaterZoneSA::iterator& CWaterZoneSA::iterator::operator=(const CWaterZoneSA::iterator& other)
{
    m_pCurrent = other.m_pCurrent;
    m_pFirst = other.m_pFirst;
    m_bSinglePoly = other.m_bSinglePoly;
    return *this;
}

void CWaterZoneSA::iterator::operator++()
{
    m_pCurrent++;
}

void CWaterZoneSA::iterator::operator--()
{
    m_pCurrent--;
}

CWaterZoneSA::iterator CWaterZoneSA::iterator::operator+(int n)
{
    iterator it(*this);
    it.m_pCurrent += n;
    return it;
}

CWaterZoneSA::iterator CWaterZoneSA::iterator::operator-(int n)
{
    iterator it(*this);
    it.m_pCurrent -= n;
    return it;
}

int CWaterZoneSA::iterator::operator-(CWaterZoneSA::iterator& other)
{
    return other.m_pCurrent - m_pCurrent;
}

bool CWaterZoneSA::iterator::operator==(const CWaterZoneSA::iterator& other)
{
    return m_pCurrent == other.m_pCurrent;
}

bool CWaterZoneSA::iterator::operator!=(const CWaterZoneSA::iterator& other)
{
    return m_pCurrent != other.m_pCurrent;
}

CWaterPolySA* CWaterZoneSA::iterator::operator*()
{
    if ((m_bSinglePoly && m_pCurrent != m_pFirst) || m_pCurrent->m_wValue == 0)
        return NULL;

    if (POLYENTRY_TYPE(m_pCurrent) == WATER_POLY_QUAD)
    {
        return &g_pWaterManager->m_Quads[POLYENTRY_ID(m_pCurrent)];
    }
    else if (POLYENTRY_TYPE(m_pCurrent) == WATER_POLY_TRIANGLE)
    {
        return &g_pWaterManager->m_Triangles[POLYENTRY_ID(m_pCurrent)];
    }
    return NULL;
}

CWaterZoneSA::iterator::operator CWaterPolyEntrySAInterface*()
{
    return m_pCurrent;
}

CWaterZoneSA::iterator CWaterZoneSA::begin()
{
    return iterator(this);
}

CWaterZoneSA::iterator CWaterZoneSA::end()
{
    iterator it(this);
    while (*it)
        ++it;
    return it;
}

// -----------------------------------------------------
// Water zones
//   SA divides the world in 500x500 squares, each of these squares is called a "zone"
//   here. These zones are used for quickly finding the water polygons near a given
//   point (e.g. the player for swimming, the camera for underwater post effects)
//   Each zone has a list of water polygons that partially or completely overlap it.

CWaterPolyEntrySAInterface* CWaterZoneSA::AddPoly(CWaterPoly* pPoly)
{
    return AddPoly(pPoly->GetType(), pPoly->GetID());
}

CWaterPolyEntrySAInterface* CWaterZoneSA::AddPoly(EWaterPolyType type, WORD wID)
{
    if (m_pInterface->m_wValue == 0)
    {
        m_pInterface->m_wValue = MAKE_POLYENTRY(type, wID);
        return m_pInterface;
    }
    else if (POLYENTRY_TYPE(m_pInterface) != WATER_POLY_LIST)
    {
        if (*(DWORD*)VAR_NumWaterZonePolys + 3 > NUM_NewWaterZonePolys)
            return NULL;

        WORD wOffset = *(WORD*)VAR_NumWaterZonePolys;
        g_pWaterManager->m_ZonePolyPool[wOffset].m_wValue = MAKE_POLYENTRY(type, wID);
        g_pWaterManager->m_ZonePolyPool[wOffset + 1].m_wValue = m_pInterface->m_wValue;
        g_pWaterManager->m_ZonePolyPool[wOffset + 2].m_wValue = 0;
        m_pInterface->m_wValue = MAKE_POLYENTRY(WATER_POLY_LIST, wOffset);

        MemAddFast<DWORD>(VAR_NumWaterZonePolys, 3);
        return &g_pWaterManager->m_ZonePolyPool[wOffset + 1];
    }
    else
    {
        if (*(DWORD*)VAR_NumWaterZonePolys + 1 > NUM_NewWaterZonePolys)
            return NULL;

        CWaterPolyEntrySAInterface* pZoneStart = (CWaterPolyEntrySAInterface*)begin();
        CWaterPolyEntrySAInterface* pEntry = &g_pWaterManager->m_ZonePolyPool[*(DWORD*)VAR_NumWaterZonePolys];
        while (pEntry > pZoneStart)
        {
            pEntry->m_wValue = (pEntry - 1)->m_wValue;
            pEntry--;
        }
        pZoneStart->m_wValue = MAKE_POLYENTRY(type, wID);

        WORD                        wZoneStartOffset = pZoneStart - g_pWaterManager->m_ZonePolyPool;
        CWaterPolyEntrySAInterface* pZoneInterface = GetExtendedWaterZoneArray();
        for (; pZoneInterface != &GetExtendedWaterZoneArray()[NUM_WaterZones]; pZoneInterface++)
        {
            if (POLYENTRY_TYPE(pZoneInterface) == WATER_POLY_LIST && POLYENTRY_ID(pZoneInterface) > wZoneStartOffset)
                pZoneInterface->m_wValue++;
        }

        (*(DWORD*)VAR_NumWaterZonePolys)++;
        return pZoneStart;
    }
}

bool CWaterZoneSA::RemovePoly(CWaterPoly* pPoly)
{
    return RemovePoly(pPoly->GetType(), pPoly->GetID());
}

bool CWaterZoneSA::RemovePoly(EWaterPolyType type, WORD wID)
{
    if (m_pInterface->m_wValue == 0)
    {
        return false;
    }
    else if (POLYENTRY_TYPE(m_pInterface) != WATER_POLY_LIST)
    {
        if (POLYENTRY_ID(m_pInterface) == wID)
        {
            m_pInterface->m_wValue = 0;
            return true;
        }
        else
        {
            return false;
        }
    }
    else
    {
        CWaterPolyEntrySAInterface* pEntries = (CWaterPolyEntrySAInterface*)begin();
        CWaterPolyEntrySAInterface* pEnd = &g_pWaterManager->m_ZonePolyPool[*(DWORD*)VAR_NumWaterZonePolys];
        WORD                        wOffset = pEntries - g_pWaterManager->m_ZonePolyPool;
        if (end() - begin() == 2)
        {
            if (pEntries[0].m_wValue == MAKE_POLYENTRY(type, wID) || pEntries[1].m_wValue == MAKE_POLYENTRY(type, wID))
            {
                if (pEntries[0].m_wValue == MAKE_POLYENTRY(type, wID))
                    m_pInterface->m_wValue = pEntries[1].m_wValue;
                else
                    m_pInterface->m_wValue = pEntries[0].m_wValue;

                CWaterPolyEntrySAInterface* pEntry = pEntries + 3;
                for (; pEntry < pEnd; pEntry++)
                    (pEntry - 3)->m_wValue = pEntry->m_wValue;

                CWaterPolyEntrySAInterface* pZoneInterface = GetExtendedWaterZoneArray();
                for (; pZoneInterface < &GetExtendedWaterZoneArray()[NUM_WaterZones]; pZoneInterface++)
                {
                    if (POLYENTRY_TYPE(pZoneInterface) == WATER_POLY_LIST && POLYENTRY_ID(pZoneInterface) > wOffset)
                        pZoneInterface->m_wValue -= 3;
                }
                MemSubFast<DWORD>(VAR_NumWaterZonePolys, 3);
                return true;
            }
            else
            {
                return false;
            }
        }
        else
        {
            for (iterator it = begin(); *it; ++it)
            {
                if ((*it)->GetType() == type && (*it)->GetID() == wID)
                {
                    CWaterPolyEntrySAInterface* pEntry = (CWaterPolyEntrySAInterface*)it + 1;
                    for (; pEntry < pEnd; pEntry++)
                        (pEntry - 1)->m_wValue = pEntry->m_wValue;

                    CWaterPolyEntrySAInterface* pZoneInterface = GetExtendedWaterZoneArray();
                    for (; pZoneInterface < &GetExtendedWaterZoneArray()[NUM_WaterZones]; pZoneInterface++)
                    {
                        if (POLYENTRY_TYPE(pZoneInterface) == WATER_POLY_LIST && POLYENTRY_ID(pZoneInterface) > wOffset)
                            pZoneInterface->m_wValue--;
                    }
                    (*(DWORD*)VAR_NumWaterZonePolys)--;
                    return true;
                }
            }
            return false;
        }
    }
}

// -----------------------------------------------------
// Change trackkeepers

void CWaterChangeVertexMove::Undo(void* pChangedObject)
{
    ((CWaterVertexSA*)pChangedObject)->SetPosition(m_vecOriginalPosition);
}

// -----------------------------------------------------
// Manager

CWaterManagerSA::CWaterManagerSA()
{
    g_pWaterManager = this;
    m_bInitializedVertices = false;
    m_bAltRenderOrder = false;
    m_iActivePolyCount = 0;
    m_bWaterDrawnLast = true;
    RelocatePools();
    InstallExtendedWaterMapPatch();
    InstallHooks();

    for (DWORD i = 0; i < NUM_WaterZones; i++)
        m_Zones[i].SetInterface(&GetExtendedWaterZoneArray()[i]);

    for (DWORD i = 0; i < NUM_NewWaterVertices; i++)
        m_Vertices[i].SetInterface(&m_VertexPool[i]);

    for (DWORD i = 0; i < NUM_NewWaterQuads; i++)
        m_Quads[i].SetInterface(&m_QuadPool[i]);

    for (DWORD i = 0; i < NUM_NewWaterTriangles; i++)
        m_Triangles[i].SetInterface(&m_TrianglePool[i]);
}

CWaterManagerSA::~CWaterManagerSA()
{
    UndoChanges();
    g_pWaterManager = NULL;
}

void CWaterManagerSA::RelocatePools()
{
    DWORD* pXrefGroups[] = {m_VertexXrefs, m_QuadXrefs, m_TriangleXrefs, m_ZonePolyXrefs, 0};
    void*  pNewPools[] = {m_VertexPool, m_QuadPool, m_TrianglePool, m_ZonePolyPool, 0};

    DWORD** pXrefGroup = NULL;
    void*   pNewPool = NULL;
    for (int i = 0; pXrefGroup = (DWORD**)pXrefGroups[i]; i++)
    {
        pNewPool = pNewPools[i];
        DWORD dwDelta = (DWORD)pNewPool - *pXrefGroup[0];
        for (DWORD** ppXref = pXrefGroup; *ppXref; ppXref++)
        {
            MemAdd<DWORD>(*ppXref, dwDelta);
        }
    }

//
// Fix outside world water blocks disappearing when using long draw distances
//

// GTA default is 70 blocks. We increase this to 512 which is 2^9
#define OUTSIDE_WORLD_BLOCKS_BITS 9
    BYTE part1[] = {0xC1, 0xF8, OUTSIDE_WORLD_BLOCKS_BITS + 1,  // sar eax,13           = 2^(10-1) = 512
                    0x7A, 0x19};                                // jp part2             Effectively jump always

    BYTE part2[] = {0x72, 0xFB,                    // jc exit              Jump if at limit
                    0xA1, 0xEC, 0x15, 0xC2, 0x00,  // mov eax,NumBlocks    Restore eax
                    0x73, 0xDE};                   // jnc dothing          Effectively jump always

    MemCpy((void*)0x6E6CE9, part1, sizeof(part1));
    MemCpy((void*)0x6E6D07, part2, sizeof(part2));

    MemPut<uint>(0x6E6CF2, (uint)&g_blocksToBeRenderedOutsideWorldX);
    MemPut<uint>(0x6E6CFA, (uint)&g_blocksToBeRenderedOutsideWorldY);

    MemPut<uint>(0x6EF6E4, (uint)&g_blocksToBeRenderedOutsideWorldX);
    MemPut<uint>(0x6EF6EC, (uint)&g_blocksToBeRenderedOutsideWorldY);

    MemPut<uint>(0x6EFE86, (uint)&g_blocksToBeRenderedOutsideWorldX);
    MemPut<uint>(0x6EFE99, (uint)&g_blocksToBeRenderedOutsideWorldY);
    MemPut<uint>(0x6EFEB3, (uint)&g_blocksToBeRenderedOutsideWorldY);
}

// The following hooks change the way SA iterates over water polygons.
// Normally it simply iterates over the first NumPolies slots in the
// pool; however in MTA, we can dynamically delete water polys,
// creating gaps. These hooks make SA skip empty pool slots.

DWORD                         dwHook6E9E23continue = 0x6E9E29;
static void __declspec(naked) Hook6E9E23()
{
    MTA_VERIFY_HOOK_LOCAL_SIZE;

    // clang-format off
    __asm
    {
        check:
        mov     eax, dword ptr [edi]
        test    eax, eax
        jnz     cont
        add     edi, 0xA        // sizeof(CWaterQuadSAInterface)
        jmp     check
        
        cont:
        movsx   eax, word ptr [edi]
        lea     ebx, [eax+4*eax]
        jmp     dwHook6E9E23continue
    }
    // clang-format on
}

DWORD                         dwHook6EFCD7continue = 0x6EFCDD;
DWORD                         dwHook6EFCD7skip = 0x6EFE5E;
static void __declspec(naked) Hook6EFCD7()
{
    MTA_VERIFY_HOOK_LOCAL_SIZE;

    // clang-format off
    __asm
    {
        mov     eax, dword ptr [esi-4]
        test    eax, eax
        jz      check
        jmp     dwHook6EFCD7skip

        check:
        add     esi, 0xA        // sizeof(CWaterQuadSAInterface)
        mov     eax, dword ptr [esi-4]
        test    eax, eax
        jz      check
        jmp     dwHook6EFCD7continue
    }
    // clang-format on
}

DWORD                         dwHook6EFBD8continue = 0x6EFBDE;
static void __declspec(naked) Hook6EFBD8()
{
    MTA_VERIFY_HOOK_LOCAL_SIZE;

    // clang-format off
    __asm
    {
        check:
        mov     eax, 0x6EFC27
        mov     eax, dword ptr [eax]
        mov     eax, dword ptr [eax+8*esi]
        test    eax, eax
        jnz     cont
        inc     esi
        jmp     check

        cont:
        jmp dwHook6EFBD8continue
    }
    // clang-format on
}

void CWaterManagerSA::InstallHooks()
{
    HookInstall(0x6E9E23, (DWORD)Hook6E9E23, 6);

    MemPut<DWORD>(0x6EFCD9, (DWORD)Hook6EFCD7 - 0x6EFCDD);

    MemPut<DWORD>(0x6EFBC7, 0x05EBED33);
    MemPut<DWORD>(0x6EFBCB, 0x90909090);
    MemPut<BYTE>(0x6EFBCF, 0x46);
    MemPut<DWORD>(0x6EFBDA, (DWORD)Hook6EFBD8 - 0x6EFBDE);
    MemPut<BYTE>(0x6EFBFB, 0x17);
    MemPut<BYTE>(0x6EFC02, 0x13);
    MemPut<BYTE>(0x6EFC04, 0x57);
    MemPut<BYTE>(0x6EFC07, 0x53);
    MemPut<BYTE>(0x6EFC0A, 0x57);
    MemPut<BYTE>(0x6EFC10, 0x53);
    MemPut<BYTE>(0x6EFCB2, 0x45);
    MemPut<BYTE>(0x6EFCB4, 0xE8);
    MemPut<BYTE>(0x6EFCB7, 0x14);
}

CWaterZoneSA* CWaterManagerSA::GetZone(int iCol, int iRow)
{
    int zoneID = EXTENDED_WATER_BLOCKS_PER_DIMENSION * iCol + iRow;
    return &m_Zones[zoneID];
}

CWaterZoneSA* CWaterManagerSA::GetZoneContaining(float fX, float fY)
{
    if (fX < EXTENDED_WATER_MAP_MIN_COORD || fX >= EXTENDED_WATER_MAP_MAX_COORD || fY < EXTENDED_WATER_MAP_MIN_COORD ||
        fY >= EXTENDED_WATER_MAP_MAX_COORD)
        return NULL;

    int zoneID = EXTENDED_WATER_BLOCKS_PER_DIMENSION * (static_cast<int>(fX - EXTENDED_WATER_MAP_MIN_COORD) / EXTENDED_WATER_BLOCK_SIZE) +
                 static_cast<int>(fY - EXTENDED_WATER_MAP_MIN_COORD) / EXTENDED_WATER_BLOCK_SIZE;
    return &m_Zones[zoneID];
}

void CWaterManagerSA::GetZonesContaining(CWaterPoly* pPoly, std::vector<CWaterZoneSA*>& out)
{
    CVector v1;
    CVector v2;
    CVector v3;

    pPoly->GetVertex(0)->GetPosition(v1);
    pPoly->GetVertex(1)->GetPosition(v2);
    pPoly->GetVertex(2)->GetPosition(v3);

    GetZonesContaining(v1, v2, v3, out);
}

void CWaterManagerSA::GetZonesContaining(const CVector& v1, const CVector& v2, const CVector& v3, std::vector<CWaterZoneSA*>& out)
{
    out.clear();
    float fColumnLeft = EXTENDED_WATER_MAP_MIN_COORD;
    for (int column = 0; column < EXTENDED_WATER_BLOCKS_PER_DIMENSION; column++)
    {
        float fRowBottom = EXTENDED_WATER_MAP_MIN_COORD;
        for (int row = 0; row < EXTENDED_WATER_BLOCKS_PER_DIMENSION; row++)
        {
            if (v2.fX >= fColumnLeft && v1.fX < fColumnLeft + EXTENDED_WATER_BLOCK_SIZE && std::max<float>(v1.fY, v3.fY) >= fRowBottom &&
                std::min<float>(v1.fY, v3.fY) < fRowBottom + EXTENDED_WATER_BLOCK_SIZE)
                out.push_back(&m_Zones[column * EXTENDED_WATER_BLOCKS_PER_DIMENSION + row]);
            fRowBottom += EXTENDED_WATER_BLOCK_SIZE;
        }
        fColumnLeft += EXTENDED_WATER_BLOCK_SIZE;
    }
}

// Uses https://playtechs.blogspot.com/2007/03/raytracing-on-grid.html
void CWaterManagerSA::GetZonesIntersecting(const CVector& startPos, const CVector& endPos, std::vector<CWaterZoneSA*>& vecOut)
{
    vecOut.clear();
    float minX = Clamp<float>(EXTENDED_WATER_MAP_MIN_COORD, std::min<float>(startPos.fX, endPos.fX), EXTENDED_WATER_MAP_MAX_ENTITY_COORD);
    float maxX = Clamp<float>(EXTENDED_WATER_MAP_MIN_COORD, std::max<float>(startPos.fX, endPos.fX), EXTENDED_WATER_MAP_MAX_ENTITY_COORD);
    float minY = Clamp<float>(EXTENDED_WATER_MAP_MIN_COORD, std::min<float>(startPos.fY, endPos.fY), EXTENDED_WATER_MAP_MAX_ENTITY_COORD);
    float maxY = Clamp<float>(EXTENDED_WATER_MAP_MIN_COORD, std::max<float>(startPos.fY, endPos.fY), EXTENDED_WATER_MAP_MAX_ENTITY_COORD);

    int lowXZone = Clamp<int>(0, static_cast<int>((minX - EXTENDED_WATER_MAP_MIN_COORD) / EXTENDED_WATER_BLOCK_SIZE),
                              EXTENDED_WATER_BLOCKS_PER_DIMENSION - 1);
    int lowYZone = Clamp<int>(0, static_cast<int>((minY - EXTENDED_WATER_MAP_MIN_COORD) / EXTENDED_WATER_BLOCK_SIZE),
                              EXTENDED_WATER_BLOCKS_PER_DIMENSION - 1);
    int highXZone = Clamp<int>(0, static_cast<int>((maxX - EXTENDED_WATER_MAP_MIN_COORD) / EXTENDED_WATER_BLOCK_SIZE),
                               EXTENDED_WATER_BLOCKS_PER_DIMENSION - 1);
    int highYZone = Clamp<int>(0, static_cast<int>((maxY - EXTENDED_WATER_MAP_MIN_COORD) / EXTENDED_WATER_BLOCK_SIZE),
                               EXTENDED_WATER_BLOCKS_PER_DIMENSION - 1);

    if (lowXZone == highXZone)
    {
        for (int i = lowYZone; i <= highYZone; i++)
        {
            vecOut.push_back(GetZone(lowXZone, i));
        }
        return;
    }
    if (lowYZone == highYZone)
    {
        for (int i = lowXZone; i <= highXZone; i++)
        {
            vecOut.push_back(GetZone(i, lowYZone));
        }
        return;
    }

    float dX = fabs(maxX - minX);
    float dY = fabs(maxY - minY);
    float dist;
    int   n = 1;
    int   xZone = lowXZone;
    int   yZone = lowYZone;

    n += highXZone - lowXZone;
    n += highYZone - lowYZone;
    dist = (floor(minX) + 1 - minX) * dY;
    dist -= (floor(minY) + 1 - minY) * dX;

    for (; n > 0; --n)
    {
        // A bound check here fixes client crash (https://github.com/multitheftauto/mtasa-blue/issues/835)
        // See PR https://github.com/multitheftauto/mtasa-blue/pull/836
        if (Between<int>(lowXZone, xZone, highXZone) && Between<int>(lowYZone, yZone, highYZone))
        {
            vecOut.push_back(GetZone(xZone, yZone));
        }
        if (dist > 0)
        {
            yZone++;
            dist -= dX;
        }
        else
        {
            xZone++;
            dist += dY;
        }
    }
}

CWaterVertex* CWaterManagerSA::CreateVertex(const CVector& vecPosition)
{
    WORD wID = ((CreateWaterVertex_t)FUNC_CreateWaterVertex)((long)vecPosition.fX & ~1, (long)vecPosition.fY & ~1, vecPosition.fZ, 0.2f, 0.1f, 0);
    return &m_Vertices[wID];
}

CWaterPoly* CWaterManagerSA::GetPolyAtPoint(const CVector& vecPosition)
{
    if (vecPosition.fX < EXTENDED_WATER_MAP_MIN_COORD || vecPosition.fX >= EXTENDED_WATER_MAP_MAX_COORD ||
        vecPosition.fY < EXTENDED_WATER_MAP_MIN_COORD || vecPosition.fY >= EXTENDED_WATER_MAP_MAX_COORD)
        return NULL;

    CWaterZoneSA* pZone = GetZoneContaining(vecPosition.fX, vecPosition.fY);
    if (!pZone)
        return NULL;

    CWaterZoneSA::iterator it;
    for (it = pZone->begin(); *it; ++it)
    {
        if ((*it)->ContainsPoint(vecPosition.fX, vecPosition.fY))
        {
            return *it;
        }
    }
    return NULL;
}

CWaterPoly* CWaterManagerSA::CreateQuad(const CVector& vecBL, const CVector& vecBR, const CVector& vecTL, const CVector& vecTR, bool bShallow)
{
    if (*(DWORD*)VAR_NumWaterQuads >= NUM_NewWaterQuads)
        return NULL;

    if (vecTL.fX >= vecTR.fX || vecBL.fX >= vecBR.fX || vecTL.fY <= vecBL.fY || vecTR.fY <= vecBR.fY ||
        vecTL.fX < EXTENDED_WATER_MAP_MIN_COORD || vecTL.fX > EXTENDED_WATER_MAP_MAX_ENTITY_COORD || vecTL.fY < EXTENDED_WATER_MAP_MIN_COORD ||
        vecTL.fY > EXTENDED_WATER_MAP_MAX_ENTITY_COORD || vecTR.fX < EXTENDED_WATER_MAP_MIN_COORD || vecTR.fX > EXTENDED_WATER_MAP_MAX_ENTITY_COORD ||
        vecTR.fY < EXTENDED_WATER_MAP_MIN_COORD || vecTR.fY > EXTENDED_WATER_MAP_MAX_ENTITY_COORD || vecBL.fX < EXTENDED_WATER_MAP_MIN_COORD ||
        vecBL.fX > EXTENDED_WATER_MAP_MAX_ENTITY_COORD || vecBL.fY < EXTENDED_WATER_MAP_MIN_COORD || vecBL.fY > EXTENDED_WATER_MAP_MAX_ENTITY_COORD ||
        vecBR.fX < EXTENDED_WATER_MAP_MIN_COORD || vecBR.fX > EXTENDED_WATER_MAP_MAX_ENTITY_COORD || vecBR.fY < EXTENDED_WATER_MAP_MIN_COORD ||
        vecBR.fY > EXTENDED_WATER_MAP_MAX_ENTITY_COORD)
        return NULL;

    if (*(DWORD*)VAR_NumWaterVertices + 4 > NUM_NewWaterVertices || *(DWORD*)VAR_NumWaterQuads + 1 > NUM_NewWaterQuads ||
        *(DWORD*)VAR_NumWaterZonePolys + 2 > NUM_NewWaterZonePolys)
        return NULL;

    std::vector<CWaterZoneSA*> zones;
    g_pWaterManager->GetZonesContaining(vecBL, vecBR, vecTL, zones);
    if (zones.empty())
        return NULL;

    CWaterVertex* pV1 = CreateVertex(vecBL);
    CWaterVertex* pV2 = CreateVertex(vecBR);
    CWaterVertex* pV3 = CreateVertex(vecTL);
    CWaterVertex* pV4 = CreateVertex(vecTR);

    CWaterQuadSAInterface* pInterface = g_pWaterManager->m_QuadPool;
    while (*(DWORD*)&pInterface->m_wVertexIDs != 0)
        pInterface++;
    pInterface->m_wVertexIDs[0] = pV1->GetID();
    pInterface->m_wVertexIDs[1] = pV2->GetID();
    pInterface->m_wVertexIDs[2] = pV3->GetID();
    pInterface->m_wVertexIDs[3] = pV4->GetID();  // This is ok
    pInterface->m_wFlags = WATER_VISIBLE;
    if (bShallow)
        pInterface->m_wFlags |= WATER_SHALLOW;

    WORD                                 wID = (WORD)(pInterface - g_pWaterManager->m_QuadPool);
    std::vector<CWaterZoneSA*>::iterator it;
    for (it = zones.begin(); it != zones.end(); it++)
        (*it)->AddPoly(WATER_POLY_QUAD, wID);

    (*(DWORD*)VAR_NumWaterQuads)++;
    CWaterQuadSA* pPoly = &g_pWaterManager->m_Quads[wID];

    m_iActivePolyCount++;
    UpdateRenderOrderRequirement();
    return pPoly;
}

CWaterPoly* CWaterManagerSA::CreateTriangle(const CVector& vec1, const CVector& vec2, const CVector& vec3, bool bShallow)
{
    if (*(DWORD*)VAR_NumWaterVertices >= NUM_NewWaterVertices)
        return NULL;

    if (vec1.fX >= vec2.fX || vec1.fY == vec3.fY || vec2.fY == vec3.fY || (vec1.fY < vec3.fY) != (vec2.fY < vec3.fY) ||
        vec1.fX < EXTENDED_WATER_MAP_MIN_COORD || vec1.fX > EXTENDED_WATER_MAP_MAX_ENTITY_COORD || vec1.fY < EXTENDED_WATER_MAP_MIN_COORD ||
        vec1.fY > EXTENDED_WATER_MAP_MAX_ENTITY_COORD || vec2.fX < EXTENDED_WATER_MAP_MIN_COORD || vec2.fX > EXTENDED_WATER_MAP_MAX_ENTITY_COORD ||
        vec2.fY < EXTENDED_WATER_MAP_MIN_COORD || vec2.fY > EXTENDED_WATER_MAP_MAX_ENTITY_COORD || vec3.fX < EXTENDED_WATER_MAP_MIN_COORD ||
        vec3.fX > EXTENDED_WATER_MAP_MAX_ENTITY_COORD || vec3.fY < EXTENDED_WATER_MAP_MIN_COORD || vec3.fY > EXTENDED_WATER_MAP_MAX_ENTITY_COORD)
        return NULL;

    if (*(DWORD*)VAR_NumWaterVertices + 4 > NUM_NewWaterVertices || *(DWORD*)VAR_NumWaterTriangles + 1 > NUM_NewWaterTriangles ||
        *(DWORD*)VAR_NumWaterZonePolys + 2 > NUM_NewWaterZonePolys)
        return NULL;

    std::vector<CWaterZoneSA*> zones;
    g_pWaterManager->GetZonesContaining(vec1, vec2, vec3, zones);
    if (zones.empty())
        return NULL;

    CWaterVertex* pV1 = CreateVertex(vec1);
    CWaterVertex* pV2 = CreateVertex(vec2);
    CWaterVertex* pV3 = CreateVertex(vec3);

    CWaterTriangleSAInterface* pInterface = g_pWaterManager->m_TrianglePool;
    while (*(DWORD*)&pInterface->m_wVertexIDs != 0)
        pInterface++;
    pInterface->m_wVertexIDs[0] = pV1->GetID();
    pInterface->m_wVertexIDs[1] = pV2->GetID();
    pInterface->m_wVertexIDs[2] = pV3->GetID();
    pInterface->m_wFlags = WATER_VISIBLE;
    if (bShallow)
        pInterface->m_wFlags |= WATER_SHALLOW;

    WORD                                 wID = (WORD)(pInterface - g_pWaterManager->m_TrianglePool);
    std::vector<CWaterZoneSA*>::iterator it;
    for (it = zones.begin(); it != zones.end(); it++)
        (*it)->AddPoly(WATER_POLY_TRIANGLE, wID);

    (*(DWORD*)VAR_NumWaterTriangles)++;
    CWaterTriangleSA* pPoly = &g_pWaterManager->m_Triangles[wID];

    m_iActivePolyCount++;
    UpdateRenderOrderRequirement();
    return pPoly;
}

bool CWaterManagerSA::DeletePoly(CWaterPoly* pPoly)
{
    std::vector<CWaterZoneSA*> zones;
    GetZonesContaining(pPoly, zones);
    if (zones.empty())
        return false;

    std::vector<CWaterZoneSA*>::iterator it;
    for (it = zones.begin(); it != zones.end(); it++)
        (*it)->RemovePoly(pPoly);

    if (pPoly->GetType() == WATER_POLY_QUAD)
    {
        MemSetFast(((CWaterQuadSA*)pPoly)->GetInterface(), 0, sizeof(CWaterQuadSAInterface));
        (*(DWORD*)VAR_NumWaterQuads)--;
    }
    else
    {
        MemSetFast(((CWaterTriangleSA*)pPoly)->GetInterface(), 0, sizeof(CWaterTriangleSAInterface));
        (*(DWORD*)VAR_NumWaterTriangles)--;
    }

    m_iActivePolyCount--;
    UpdateRenderOrderRequirement();
    return true;
}

bool CWaterManagerSA::GetWaterLevel(const CVector& vecPosition, float* pfLevel, bool ignoreDistanceToWaterThreshold, CVector* pvecUnknown)
{
    return ((GetWaterLevel_t)FUNC_GetWaterLevel)(vecPosition.fX, vecPosition.fY, vecPosition.fZ, pfLevel, ignoreDistanceToWaterThreshold, pvecUnknown);
}

bool CWaterManagerSA::SetPositionWaterLevel(const CVector& vecPosition, float fLevel, void* pChangeSource)
{
    // Specific water poly
    CWaterPoly* pPoly = GetPolyAtPoint(vecPosition);
    if (!pPoly)
        return false;

    return SetPolyWaterLevel(pPoly, fLevel, pChangeSource);
}

bool CWaterManagerSA::SetWorldWaterLevel(float fLevel, void* pChangeSource, bool bIncludeWorldNonSeaLevel, bool bIncludeWorldSeaLevel,
                                         bool bIncludeOutsideWorldLevel)
{
    assert(m_bInitializedVertices);
    CVector vecVertexPos;

    if (bIncludeWorldSeaLevel || bIncludeWorldNonSeaLevel)
    {
        for (DWORD i = 0; i < NUM_DefWaterVertices; i++)
        {
            m_Vertices[i].GetPosition(vecVertexPos);
            if ((bIncludeWorldNonSeaLevel && m_Vertices[i].IsWorldNonSeaLevel()) || (bIncludeWorldSeaLevel && !m_Vertices[i].IsWorldNonSeaLevel()))
                vecVertexPos.fZ = fLevel;
            m_Vertices[i].SetPosition(vecVertexPos, pChangeSource);
        }
    }

    if (bIncludeOutsideWorldLevel)
        SetOutsideWorldWaterLevel(fLevel);

    return true;
}

bool CWaterManagerSA::SetPolyWaterLevel(CWaterPoly* pPoly, float fLevel, void* pChangeSource)
{
    CVector vecVertexPos;
    for (int i = 0; i < pPoly->GetNumVertices(); i++)
    {
        pPoly->GetVertex(i)->GetPosition(vecVertexPos);
        vecVertexPos.fZ = fLevel;
        pPoly->GetVertex(i)->SetPosition(vecVertexPos, pChangeSource);
    }
    return true;
}

void CWaterManagerSA::SetOutsideWorldWaterLevel(float fLevel)
{
    // Outside world vertices
    MemPut<float>(0x6EFECC, fLevel);
    MemPut<float>(0x6EFF0C, fLevel);
    MemPut<float>(0x6EFF4A, fLevel);
    MemPut<float>(0x6EFFA6, fLevel);
    // Collision
    MemPut<float>(0x6E873F, fLevel);
    // Sound
    MemPut<float>(0x6EA238, fLevel);
}

float CWaterManagerSA::GetWaveLevel()
{
    return *(float*)VAR_WaveLevel;
}

void CWaterManagerSA::SetWaveLevel(float fWaveLevel)
{
    if (fWaveLevel >= 0.0f)
    {
        // DISABLE the game resetting the wave level
        MemPut<BYTE>(0x72C665, 0xDD);
        MemPut<BYTE>(0x72C666, 0xD8);
        MemSet((void*)0x72C667, 0x90, 4);
        MemSet((void*)0x72C659, 0x90, 10);

        MemPutFast<float>(VAR_WaveLevel, fWaveLevel);
    }
    else
    {
        MemPut<BYTE>(0x72C665, 0xD9);
        MemPut<BYTE>(0x72C666, 0x1D);
        MemPut<BYTE>(0x72C667, 0xE8);
        MemPut<BYTE>(0x72C668, 0x12);
        MemPut<BYTE>(0x72C669, 0xC8);
        MemPut<BYTE>(0x72C66A, 0x00);

        MemPut<BYTE>(0x72C659, 0xC7);
        MemPut<BYTE>(0x72C65A, 0x05);
        MemPut<BYTE>(0x72C65B, 0xE8);
        MemPut<BYTE>(0x72C65C, 0x12);
        MemPut<BYTE>(0x72C65D, 0xC8);
        MemPut<BYTE>(0x72C65E, 0x00);
        MemPut<BYTE>(0x72C65F, 0x00);
        MemPut<BYTE>(0x72C660, 0x00);
        MemPut<BYTE>(0x72C661, 0x80);
        MemPut<BYTE>(0x72C662, 0x3F);

        MemPutFast<float>(VAR_WaveLevel, 0.6f);
    }
}

bool CWaterManagerSA::IsPointOutsideOfGameArea(const CVector& vecPos)
{
    return vecPos.fX < -3000 || vecPos.fX > 3000 || vecPos.fY < -3000 || vecPos.fY > 3000;
}

bool CWaterManagerSA::TestLineAgainstWater(const CVector& vecStart, const CVector& vecEnd, CVector* vecCollision)
{
    CVector rayDir = vecEnd - vecStart;

    std::vector<CWaterZoneSA*> vecZones;
    GetZonesIntersecting(vecStart, vecEnd, vecZones);

    std::deque<CVector> vecVertices;
    for (auto& zone : vecZones)
    {
        CWaterZoneSA::iterator iter;
        for (iter = zone->begin(); iter != zone->end(); ++iter)
        {
            auto poly = *iter;
            int  iNumVertices = poly->GetNumVertices();
            if (iNumVertices < 3)
                continue;

            vecVertices.clear();

            CVector vecTemp;
            poly->GetVertex(0)->GetPosition(vecTemp);
            vecVertices.push_back(vecTemp);
            poly->GetVertex(1)->GetPosition(vecTemp);
            vecVertices.push_back(vecTemp);
            poly->GetVertex(2)->GetPosition(vecTemp);
            vecVertices.push_back(vecTemp);

            if (vecStart.IntersectsSegmentTriangle(rayDir, vecVertices[0], vecVertices[1], vecVertices[2], vecCollision))
            {
                return true;
            }

            if (iNumVertices < 4)
                continue;

            for (int i = 3; i < iNumVertices; i++)
            {
                vecVertices.pop_front();
                poly->GetVertex(i)->GetPosition(vecTemp);
                vecVertices.push_back(vecTemp);

                if (vecStart.IntersectsSegmentTriangle(rayDir, vecVertices[0], vecVertices[1], vecVertices[2], vecCollision))
                {
                    return true;
                }
            }
        }
    }

    // Custom water takes priority over GTA's infinite sea. If no polygon was
    // hit, retain the original outside-world ocean at its independent level.
    CVector     oceanIntersection{};
    const float oceanHeight = *reinterpret_cast<float*>(0x6E873F);
    if (vecStart.IntersectsSegmentPlane(rayDir, CVector(0, 0, 1), CVector(0, 0, oceanHeight), &oceanIntersection) &&
        IsPointOutsideOfGameArea(oceanIntersection))
    {
        *vecCollision = oceanIntersection;
        return true;
    }
    return false;
}

void CWaterManagerSA::AddChange(void* pChangeSource, void* pChangedObject, CWaterChange* pChange)
{
    if (!pChangeSource)
    {
        delete pChange;
        return;
    }

    std::map<void*, std::map<void*, CWaterChange*> >::iterator sourceIt = m_Changes.find(pChangeSource);
    if (sourceIt == m_Changes.end())
        sourceIt = m_Changes.insert(make_pair(pChangeSource, std::map<void*, CWaterChange*>())).first;

    std::map<void*, CWaterChange*>::iterator changeIt = sourceIt->second.find(pChangedObject);
    if (changeIt == sourceIt->second.end())
    {
        sourceIt->second.insert(make_pair(pChangedObject, pChange));
    }
    else
    {
        delete pChange;
    }
}

void CWaterManagerSA::UndoChanges(void* pChangeSource)
{
    if (pChangeSource == NULL)
    {
        while (!m_Changes.empty())
        {
            if (m_Changes.begin()->first)
                UndoChanges(m_Changes.begin()->first);
            else
                m_Changes.erase(m_Changes.begin());
        }
    }
    else
    {
        std::map<void*, std::map<void*, CWaterChange*> >::iterator sourceIt = m_Changes.find(pChangeSource);
        if (sourceIt == m_Changes.end())
            return;
        std::map<void*, CWaterChange*>::iterator changeIt = sourceIt->second.begin();
        for (; changeIt != sourceIt->second.end(); changeIt++)
        {
            changeIt->second->Undo(changeIt->first);
            delete changeIt->second;
        }
        m_Changes.erase(sourceIt);
    }
}

void CWaterManagerSA::RebuildIndex()
{
    // Rebuilds the list of polygons of each zone
    MemSetFast(GetExtendedWaterZoneArray(), 0, NUM_WaterZones * sizeof(CWaterPolyEntrySAInterface));
    MemPutFast<DWORD>(VAR_NumWaterZonePolys, 0);
    ((BuildWaterIndex_t)FUNC_BuildWaterIndex)();
}

void CWaterManagerSA::ResetWorldWaterLevel()
{
    if (m_bInitializedVertices)
        for (DWORD i = 0; i < NUM_DefWaterVertices; i++)
            m_Vertices[i].Reset();

    SetOutsideWorldWaterLevel(DEFAULT_WATER_LEVEL);
}

void CWaterManagerSA::Reset()
{
    // Resets all water to the original single player configuration
    UndoChanges();

    SetOutsideWorldWaterLevel(DEFAULT_WATER_LEVEL);

    MemSetFast(m_QuadPool, 0, sizeof(m_QuadPool));
    MemSetFast(m_TrianglePool, 0, sizeof(m_TrianglePool));

    ((ReadWaterConfiguration_t)FUNC_ReadWaterConfiguration)();

    SetWaveLevel(DEFAULT_WAVE_LEVEL);

    for (DWORD i = 0; i < NUM_NewWaterVertices; i++)
        m_Vertices[i].Init(i < NUM_DefWaterVertices);

    ms_iNumNonDefaultAndNonZeroVertices = 0;
    m_bInitializedVertices = true;
}

// Dynamically hook/unhook water rendering when required
void CWaterManagerSA::UpdateRenderOrderRequirement()
{
    bool bAltRenderOrderRequired = ms_iNumNonDefaultAndNonZeroVertices != 0 || m_iActivePolyCount > 0 || m_bWaterDrawnLast;
    if (m_bAltRenderOrder != bAltRenderOrderRequired)
    {
        OutputDebugLine(
            SString("[Water] SetAltWaterOrderEnabled: %d  (ms_iNumNonDefaultAndNonZeroVertices:%d  m_bWaterDrawnLast:%d  m_Changes:%d  m_iActivePolyCount:%d",
                    bAltRenderOrderRequired, ms_iNumNonDefaultAndNonZeroVertices, m_bWaterDrawnLast, m_Changes.size(), m_iActivePolyCount));
        m_bAltRenderOrder = bAltRenderOrderRequired;
        g_pCore->GetMultiplayer()->SetAltWaterOrderEnabled(m_bAltRenderOrder);
    }
}

void CWaterManagerSA::SetWaterDrawnLast(bool bEnable)
{
    m_bWaterDrawnLast = bEnable;
    UpdateRenderOrderRequirement();
}

bool CWaterManagerSA::IsWaterDrawnLast()
{
    return m_bWaterDrawnLast;
}

void CWaterManagerSA::SetWorldSeaBedOuterBoundary(float fBoundary)
{
    g_worldSeaBedOuterBoundary = fBoundary;
}

void CWaterManagerSA::ResetWorldSeaBedOuterBoundary()
{
    g_worldSeaBedOuterBoundary = -1.0f;
}

float CWaterManagerSA::GetWorldSeaBedOuterBoundary() const
{
    return g_worldSeaBedOuterBoundary;
}
