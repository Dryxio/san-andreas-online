#pragma once

#include "CEntitySA.h"
#include "CModelInfoSA.h"
#include "CRenderWareSA.h"
#include "gamesa_renderware.h"
#include <array>
#include <cmath>
#include <limits>

// Presentation-only assets: no model IDs, collision replacements or extra IPL
// entities. Every swap is scoped to one native draw, including GTA's alpha pass.
namespace VegetationLOD
{
    struct Definition
    {
        unsigned short model;
        const char*    file;
        float          transition;
        float          range;
    };
    inline constexpr Definition definitions[] = {
#include "CVegetationLODModelsSA.inc"
    };
    // Visibility also visits non-vegetation every frame. A small read-only
    // table avoids searching the catalog for every building and every pass.
    // Zero denotes an absent model; entries store the asset index plus one.
    static_assert(std::size(definitions) < 256);
    inline constexpr auto modelIndices = []
    {
        constexpr auto lastModel = []
        {
            unsigned short result = 0;
            for (const auto& definition : definitions)
                if (definition.model > result)
                    result = definition.model;
            return result;
        }();
        std::array<unsigned char, lastModel + 1> result{};
        for (std::size_t index = 0; index < std::size(definitions); ++index)
            result[definitions[index].model] = static_cast<unsigned char>(index + 1);
        return result;
    }();
    struct Asset
    {
        RpAtomic*                  atomic{};
        RwFrame*                   frame{};
        bool                       attempted{};
        bool                       requested{};
        bool                       busy{};
        RpClump*                   original{};
        CBaseModelInfoSAInterface* modelInfo{};
        float                      originalDistance{};
        float                      lightingBalance{std::numeric_limits<float>::quiet_NaN()};
    };
    inline std::array<Asset, std::size(definitions)> assets;
    inline RwTexDictionary*                          dictionary{};
    inline bool                                      dictionaryAttempted{};
    inline bool                                      enabled{};
    inline float                                     distanceLimit{};

    inline float Range(const Definition& definition)
    {
        // Cap only the added representation, preserving pack defaults at zero.
        // A 400 m minimum stays beyond every authored transition and the native
        // 300 m visibility gate; visibility and alpha fading use the same range.
        return distanceLimit > 0.0f ? std::min(definition.range, std::max(400.0f, distanceLimit)) : definition.range;
    }

    inline void Clear(CRenderWareSA* rw)
    {
        for (auto& asset : assets)
        {
            // Settings/reset run outside render callbacks. A busy entry must
            // never be destroyed while GTA still owns the temporary pointer.
            assert(!asset.busy);
            if (asset.atomic)
                RpAtomicDestroy(asset.atomic);
            if (asset.frame)
                RwFrameDestroy(asset.frame);
            asset = {};
        }
        if (dictionary)
            rw->DestroyTXD(dictionary);
        dictionary = nullptr;
        dictionaryAttempted = false;
    }

    inline bool Load(std::size_t index, CRenderWareSA* rw)
    {
        auto& asset = assets[index];
        if (asset.attempted)
            return asset.atomic != nullptr;
        asset.attempted = true;
        if (!dictionaryAttempted)
        {
            dictionaryAttempted = true;
            dictionary = rw->ReadTXD(CalcMTASAPath("MTA\\data\\vegetation-lod\\LODvegetation.txd"), {});
            if (!dictionary)
                OutputReleaseLine("[Vegetation LOD] Missing/invalid texture dictionary; keeping original vegetation");
        }
        if (!dictionary)
            return false;
        auto* previous = RwTexDictionaryGetCurrent();
        RwTexDictionarySetCurrent(dictionary);
        auto* clump = rw->ReadDFF(CalcMTASAPath(SString("MTA\\data\\vegetation-lod\\%s", definitions[index].file)), {}, 0, false);
        RwTexDictionarySetCurrent(previous);
        if (clump)
        {
            std::vector<RpAtomic*> atomics;
            CRenderWareSA::GetClumpAtomicList(clump, atomics);
            if (atomics.size() == 1)
            {
                asset.atomic = RpAtomicClone(atomics.front());
                asset.frame = RwFrameCreate();
                if (asset.atomic && asset.frame)
                {
                    RpAtomicSetFrame(asset.atomic, asset.frame);
                    // ReadDFF alone bypasses CAtomicModelInfo::SetAtomic. Install
                    // GTA's building pipeline so the streamed night colors are used.
                    reinterpret_cast<void(__cdecl*)(RpAtomic*)>(0x5D7F00)(asset.atomic);
                }
            }
            rw->DestroyDFF(clump);
        }
        if (!asset.atomic || !asset.frame)
        {
            if (asset.atomic)
                RpAtomicDestroy(asset.atomic);
            if (asset.frame)
                RwFrameDestroy(asset.frame);
            asset.atomic = nullptr;
            asset.frame = nullptr;
            OutputReleaseLine(SString("[Vegetation LOD] Cannot load %s; keeping original model", definitions[index].file));
            return false;
        }
        return true;
    }

    inline void UpdateLighting(Asset& asset)
    {
        const float balance = *reinterpret_cast<const float*>(0x8D12C0);
        if (!std::isfinite(balance) || asset.lightingBalance == balance)
            return;
        // These render-only atomics never pass through CEntity::PreRender.
        // Force the first update even at midnight: the plugin initializes its
        // balance to night while geometry still contains the streamed day RGB.
        // One update per species/balance avoids rewriting shared geometry for
        // every tree; use the game's balance to follow the native day/night cycle.
        reinterpret_cast<void(__cdecl*)(RpAtomic*, bool)>(0x5D7200)(asset.atomic, true);
        asset.lightingBalance = balance;
    }

    inline std::size_t Find(CEntitySAInterface* entity)
    {
        if (!enabled || !entity || (entity->nType != 1 && entity->nType != 5))
            return std::size(definitions);
        const auto model = entity->m_nModelIndex;
        const auto index = model < modelIndices.size() ? modelIndices[model] : 0;
        return index ? static_cast<std::size_t>(index - 1) : std::size(definitions);
    }

    inline bool Request(std::size_t index)
    {
        auto& asset = assets[index];
        // Visibility must not open files or build RenderWare objects. Until
        // preparation completes, keep the native range and representation.
        if (!asset.attempted)
            asset.requested = true;
        return asset.atomic != nullptr;
    }

    inline void Pulse(CRenderWareSA* rw)
    {
        if (!enabled)
            return;
        // Loading many newly visible species in one traversal stalls a frame.
        // Prepare at most one requested asset per game pulse instead. A single
        // TXD/DFF read remains synchronous; this is not a hard time budget.
        for (std::size_t index = 0; index < assets.size(); ++index)
        {
            auto& asset = assets[index];
            if (!asset.requested)
                continue;
            asset.requested = false;
            Load(index, rw);
            return;
        }
    }
}
