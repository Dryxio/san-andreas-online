#pragma once

#include "CGameSA.h"
#include "CModelInfoSA.h"
#include "CPoolsSA.h"
#include "CPoolSAInterface.h"
#include <algorithm>
#include <map>
#include <vector>

extern CGameSA* pGame;

// Project2DFX preloads native LOD parents and creates their RenderWare objects.
// Neon pools can move and Lua can replace models: retain handles and owned model
// references, never the raw IPL pointers kept by the single-player plugin.
namespace Project2DFXPreload
{
    struct Handle
    {
        unsigned int        pool;
        int                 slot;
        unsigned char       generation;
        unsigned short      model;
        CEntitySAInterface* allocation;
    };
    struct OwnedObject
    {
        Handle   handle;
        RpClump* object;
    };
    struct Lease
    {
        std::vector<OwnedObject> objects;
    };
    inline std::map<unsigned short, Lease> leases;
    inline bool                            enabled = false;
    inline bool                            dirty = true;
    inline long long                       lastScan = 0;

    inline CPoolSAInterface<CEntitySAInterface>* Pool(unsigned int index)
    {
        return *reinterpret_cast<CPoolSAInterface<CEntitySAInterface>**>(index == 0 ? CLASS_CBuildingPool : CLASS_CDummyPool);
    }
    inline CEntitySAInterface* Resolve(const Handle& handle)
    {
        auto* pool = Pool(handle.pool);
        if (!pool || pool->m_pObjects != handle.allocation || handle.slot < 0 || handle.slot >= pool->m_nSize || pool->m_byteMap[handle.slot].bEmpty ||
            pool->m_byteMap[handle.slot].nId != handle.generation)
            return nullptr;
        auto* entity = pool->m_pObjects + handle.slot;
        return entity->m_nModelIndex == handle.model ? entity : nullptr;
    }
    inline void Release(unsigned short model, Lease& lease)
    {
        for (const auto& owned : lease.objects)
        {
            auto* entity = Resolve(owned.handle);
            // Restreaming may already have destroyed/replaced our object.
            if (entity && entity->m_pRwObject == owned.object && !entity->bImBeingRendered)
                entity->DeleteRwObject();
        }
        auto* info = pGame->GetModelInfo(model, true);
        if (info)
        {
            info->IsLoaded();  // Promote a pending MTA reference before releasing it.
            info->RemoveRef();
        }
    }
    inline void Clear()
    {
        for (auto& entry : leases)
            Release(entry.first, entry.second);
        leases.clear();
        dirty = true;
    }
    inline void ModelChanging(unsigned int model)
    {
        auto found = leases.find(static_cast<unsigned short>(model));
        if (found != leases.end() && model == found->first)
        {
            Release(found->first, found->second);
            leases.erase(found);
        }
        dirty = true;
    }
    inline void Configure(bool value)
    {
        if (enabled == value)
            return;
        enabled = value;
        if (!enabled)
            Clear();
        dirty = true;
    }
    inline void Pulse()
    {
        if (!enabled || pGame->GetSystemState() != SystemState::GS_PLAYING_GAME)
            return;
        const auto now = SharedUtil::GetTickCount64_();
        // Reconcile streamed IPLs and map removals outside the render traversal.
        // Settings and model replacements bypass the interval via dirty.
        if (!dirty && now - lastScan < 2000)
            return;
        dirty = false;
        lastScan = now;
        // Keep per-model capacity between reconciliations: an unchanged world
        // must not allocate thousands of handle vectors every two seconds.
        // Refill from the pools each time; cached handles are never resolved.
        static std::map<unsigned short, std::vector<Handle>> desired;
        for (auto& entry : desired)
            entry.second.clear();
        for (unsigned int kind = 0; kind < 2; ++kind)
        {
            auto* pool = Pool(kind);
            if (!pool)
                continue;
            for (int slot = 0; slot < pool->m_nSize; ++slot)
            {
                if (pool->m_byteMap[slot].bEmpty)
                    continue;
                auto*      entity = pool->m_pObjects + slot;
                const auto model = entity->m_nModelIndex;
                if (model < 615 || model > 18631 || !entity->numLodChildren || entity->IsHighLodEntity() || entity->IsLowLodEntity() ||
                    (entity->nType != 1 && entity->nType != 5) || pGame->GetPools()->GetClientEntity(reinterpret_cast<DWORD*>(entity)))
                    continue;
                auto* info = static_cast<CModelInfoSA*>(pGame->GetModelInfo(model, true));
                if (!info || info->HasVegetationLODOverride())
                    continue;
                desired[model].push_back({kind, slot, pool->m_byteMap[slot].nId, model, pool->m_pObjects});
            }
        }
        for (auto it = desired.begin(); it != desired.end();)
        {
            if (it->second.empty())
                it = desired.erase(it);
            else
                ++it;
        }
        for (auto it = leases.begin(); it != leases.end();)
        {
            if (desired.find(it->first) == desired.end())
            {
                Release(it->first, it->second);
                it = leases.erase(it);
            }
            else
                ++it;
        }
        bool requested = false;
        for (const auto& entry : desired)
        {
            auto* info = pGame->GetModelInfo(entry.first, true);
            if (leases.find(entry.first) == leases.end() && info && !info->IsLoaded())
            {
                // MTA references provide residency after the batch completes.
                // Do not leave GAME_REQUIRED/MISSION_REQUIRED flags owned by
                // this preference on models that other resources also use.
                pGame->GetStreaming()->RequestModel(entry.first, 0);
                requested = true;
            }
        }
        if (requested)
            pGame->GetStreaming()->LoadAllRequestedModels(false, "Project2DFX LOD preload");
        for (const auto& entry : desired)
        {
            auto* info = static_cast<CModelInfoSA*>(pGame->GetModelInfo(entry.first, true));
            if (!info || info->HasVegetationLODOverride() || !info->IsLoaded())
                continue;
            auto found = leases.find(entry.first);
            if (found == leases.end())
            {
                // Already loaded: this adds ownership without another request
                // or a change to the streaming flags of shared models.
                info->ModelAddRef(EModelRequestType::NON_BLOCKING, "Project2DFX LOD preload");
                found = leases.emplace(entry.first, Lease{}).first;
            }
            auto& objects = found->second.objects;
            objects.erase(std::remove_if(objects.begin(), objects.end(),
                                         [](const OwnedObject& owned)
                                         {
                                             auto* entity = Resolve(owned.handle);
                                             return !entity || entity->m_pRwObject != owned.object;
                                         }),
                          objects.end());
            for (const auto& handle : entry.second)
            {
                auto* entity = Resolve(handle);
                if (entity && !entity->m_pRwObject)
                {
                    entity->CreateRwObject();
                    if (entity->m_pRwObject)
                        objects.push_back({handle, entity->m_pRwObject});
                }
            }
        }
    }
}
