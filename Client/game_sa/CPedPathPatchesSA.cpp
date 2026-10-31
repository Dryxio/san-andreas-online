#include "StdInc.h"
#include "CPedPathPatchesSA.h"
#include "CGameSA.h"
#include "PedPathPatchFormat.h"
#include "SharedUtil.Hash.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <set>

extern CGameSA* pGame;

namespace
{
    using namespace PedPathPatch;
    constexpr std::uintptr_t Paths = 0x96F050;
    constexpr unsigned       NodeSize = 28;
    constexpr unsigned       StaticLinks = MaxLinks - DynamicLinks;
    using Node = std::array<std::uint8_t, NodeSize>;
    template <class T>
    T& Field(unsigned offset, unsigned area)
    {
        return reinterpret_cast<T*>(Paths + offset)[area];
    }
    unsigned& NodeCount(unsigned a)
    {
        return Field<unsigned>(0xFA4, a);
    }
    unsigned& VehicleCount(unsigned a)
    {
        return Field<unsigned>(0x10C4, a);
    }
    unsigned& PedCount(unsigned a)
    {
        return Field<unsigned>(0x11E4, a);
    }
    unsigned& CarCount(unsigned a)
    {
        return Field<unsigned>(0x1304, a);
    }
    unsigned& AddressCount(unsigned a)
    {
        return Field<unsigned>(0x1424, a);
    }
    Node*& Nodes(unsigned a)
    {
        return Field<Node*>(0x804, a);
    }
    Address*& Links(unsigned a)
    {
        return Field<Address*>(0xA44, a);
    }
    std::uint8_t*& Lengths(unsigned a)
    {
        return Field<std::uint8_t*>(0xB64, a);
    }
    std::uint8_t*& Intersections(unsigned a)
    {
        return Field<std::uint8_t*>(0xC84, a);
    }
    using Navi = std::array<std::uint8_t, NaviSize>;
    Navi*& NaviNodes(unsigned a)
    {
        return Field<Navi*>(0x924, a);
    }
    std::uint16_t*& NaviLinks(unsigned a)
    {
        return Field<std::uint16_t*>(0xDA4, a);
    }
    // GenerateCarCreationCoors2 caches its starting nodes until this time;
    // zero forces a rebuild after the road graph changes.
    constexpr std::uintptr_t CarCreationCacheTime = 0x9690E8;
    unsigned                 RegionOf(float x, float y)
    {
        const auto axis = [](float v) { return static_cast<unsigned>(std::clamp(static_cast<int>(std::floor((v + 3000.0f) / 750.0f)), 0, 7)); };
        return axis(y) * 8 + axis(x);
    }
    unsigned U16(const Node& n, unsigned off)
    {
        return n[off] | (unsigned(n[off + 1]) << 8);
    }
    void Put16(Node& n, unsigned off, unsigned v)
    {
        n[off] = v & 255;
        n[off + 1] = (v >> 8) & 255;
    }

    struct Region
    {
        Node*                      originalNodes{};
        Address*                   originalLinks{};
        std::uint16_t*             originalNaviLinks{};
        std::uint8_t *             originalLengths{}, *originalIntersections{};
        unsigned                   count{}, vehicles{}, addresses{}, cars{}, highWater{};
        bool                       loaded{}, published{}, retainedFirstNodes{}, faulted{};
        Node*                      rejectedNodes{};
        unsigned                   rejectedCount{}, rejectedPeds{};
        std::array<bool, MaxNodes> edited{};
        // Addresses and node storage never move after publication. Removed
        // custom nodes become inert tombstones, so a task's saved CNodeAddress
        // remains in bounds even after its resource stops.
        std::unique_ptr<Node[]>          nodes;
        std::unique_ptr<Address[]>       links;
        std::unique_ptr<std::uint16_t[]> naviLinks;
        std::unique_ptr<std::uint8_t[]>  lengths, intersections;
        std::string                      additionRevision;
        std::array<std::uint8_t, 32>     digest{};
        // Road (navi) records follow the same rules as nodes: the slab never
        // moves, and ids above the stock count stay reserved for the process
        // so a car's saved CCarPathLinkAddress always indexes real storage.
        Navi*                     originalNavi{};
        Navi*                     rejectedNavi{};
        unsigned                  rejectedNaviCount{}, naviHighWater{};
        std::unique_ptr<Navi[]>   navi;
        std::array<bool, MaxNavi> naviEdited{};
    };
    struct Lease
    {
        Patch       patch;
        std::string revision, error;
    };
    class Service final : public CPedPathPatches
    {
    public:
        bool Load(void*, const void*, std::size_t, std::string&, std::string&) override;
        bool Unload(void*) override;
        bool GetGraphRevision(std::string&, std::string&) const override;
        bool GetRevision(void*, std::string&, std::string&) const override;
        void Loaded(unsigned);
        void Unloading(unsigned);
        bool BlocksDynamic(Address first, Address second) const;

    private:
        std::array<Region, Areas> m_regions;
        std::map<void*, Lease>    m_leases;
        bool                      m_busy{}, m_hooks{};
        bool                      Install(std::string&);
        void                      Capture(unsigned);
        void                      ProtectRejectedReload(unsigned);
        void                      Publish(unsigned, const Area*);
        void                      Restore(Lease&);
        void                      Validate(const Patch&);
        void                      ValidateRoads(const Patch&);
    };
    Service g_service;
    using LoadFn = void(__thiscall*)(void*, void*, int);
    using UnloadFn = void(__thiscall*)(void*, int);
    LoadFn   g_load{};
    UnloadFn g_unload{};
    using DynamicFn = void(__thiscall*)(void*, Address, Address);
    DynamicFn       g_dynamic{};
    void __fastcall DynamicHook(void* paths, void*, Address first, Address second)
    {
        if (reinterpret_cast<std::uintptr_t>(paths) != Paths || !g_service.BlocksDynamic(first, second))
            g_dynamic(paths, first, second);
    }

    void __fastcall LoadHook(void* paths, void*, void* stream, int area)
    {
        g_load(paths, stream, area);
        if (reinterpret_cast<std::uintptr_t>(paths) == Paths && area >= 0 && area < int(Areas))
            g_service.Loaded(area);
    }
    void __fastcall UnloadHook(void* paths, void*, int area)
    {
        if (reinterpret_cast<std::uintptr_t>(paths) == Paths && area >= 0 && area < int(Areas))
            g_service.Unloading(area);
        g_unload(paths, area);
    }
    bool Service::BlocksDynamic(Address first, Address second) const
    {
        // Refuse both halves of a native exterior/interior connection while
        // an exterior patch owns either endpoint. Its snapshot cannot safely
        // absorb GTA's later interior topology mutation on resource rollback.
        for (const auto& lease : m_leases)
            for (unsigned area : {unsigned(first.area), unsigned(second.area)})
            {
                const auto found = lease.second.patch.areas.find(area);
                if (found != lease.second.patch.areas.end() && found->second.Changed())
                    return true;
            }
        return false;
    }
    template <std::size_t N>
    void* Gateway(std::uintptr_t address, const std::array<BYTE, N>& expected)
    {
        auto* code = static_cast<BYTE*>(VirtualAlloc(nullptr, N + 5, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE));
        if (!code)
            throw std::runtime_error("hook-allocation-failed");
        std::memcpy(code, expected.data(), N);
        code[N] = 0xE9;
        auto displacement = static_cast<std::int32_t>(address + N - reinterpret_cast<std::uintptr_t>(code + N + 5));
        std::memcpy(code + N + 1, &displacement, 4);
        FlushInstructionCache(GetCurrentProcess(), code, N + 5);
        return code;
    }
    bool Service::Install(std::string& error)
    {
        if (m_hooks)
            return true;
        // These whole-instruction prologues were checked in compact 1.0 US.
        // Fail closed on a different executable or a competing detour.
        constexpr std::array<BYTE, 5> loadBytes{{0x53, 0x8B, 0x5C, 0x24, 0x08}};
        constexpr std::array<BYTE, 7> unloadBytes{{0x53, 0x56, 0x57, 0x8B, 0x7C, 0x24, 0x10}};
        constexpr std::array<BYTE, 8> dynamicBytes{{0x83, 0xEC, 0x0C, 0x0F, 0xB7, 0x44, 0x24, 0x10}};
        if (pGame->GetGameVersion() != VERSION_US_10 || std::memcmp(reinterpret_cast<void*>(0x4529F0), loadBytes.data(), loadBytes.size()) ||
            std::memcmp(reinterpret_cast<void*>(0x44D0F0), unloadBytes.data(), unloadBytes.size()) ||
            std::memcmp(reinterpret_cast<void*>(0x44E000), dynamicBytes.data(), dynamicBytes.size()))
        {
            error = "unsupported-pathfinder-hooks";
            return false;
        }
        auto* load = Gateway(0x4529F0, loadBytes);
        void* unload = nullptr;
        try
        {
            unload = Gateway(0x44D0F0, unloadBytes);
        }
        catch (...)
        {
            VirtualFree(load, 0, MEM_RELEASE);
            throw;
        }
        void* dynamic = nullptr;
        try
        {
            dynamic = Gateway(0x44E000, dynamicBytes);
        }
        catch (...)
        {
            VirtualFree(load, 0, MEM_RELEASE);
            VirtualFree(unload, 0, MEM_RELEASE);
            throw;
        }
        g_dynamic = reinterpret_cast<DynamicFn>(dynamic);
        g_load = reinterpret_cast<LoadFn>(load);
        g_unload = reinterpret_cast<UnloadFn>(unload);
        if (!HookInstall(0x4529F0, &LoadHook, loadBytes.size()) || !HookInstall(0x44D0F0, &UnloadHook, unloadBytes.size()) ||
            !HookInstall(0x44E000, &DynamicHook, dynamicBytes.size()))
        {
            MemCpy(reinterpret_cast<void*>(0x4529F0), loadBytes.data(), loadBytes.size());
            MemCpy(reinterpret_cast<void*>(0x44D0F0), unloadBytes.data(), unloadBytes.size());
            MemCpy(reinterpret_cast<void*>(0x44E000), dynamicBytes.data(), dynamicBytes.size());
            VirtualFree(dynamic, 0, MEM_RELEASE);
            VirtualFree(load, 0, MEM_RELEASE);
            VirtualFree(unload, 0, MEM_RELEASE);
            g_load = nullptr;
            g_unload = nullptr;
            g_dynamic = nullptr;
            error = "hook-installation-failed";
            return false;
        }
        m_hooks = true;
        return true;
    }
    void Service::Capture(unsigned a)
    {
        auto& r = m_regions[a];
        if (r.faulted)
            throw std::runtime_error("base-region-changed-restart-client");
        if (r.loaded)
            return;
        const unsigned count = NodeCount(a), vehicles = VehicleCount(a), addresses = AddressCount(a), cars = CarCount(a);
        if (!Nodes(a) || count > MaxNodes || vehicles > count || PedCount(a) != count - vehicles || addresses > MaxLinks - DynamicLinks || cars > MaxNavi ||
            (addresses && (!Links(a) || !Lengths(a) || !Intersections(a) || !Field<void*>(0xDA4, a))) || (cars && !Field<void*>(0x924, a)))
            throw std::runtime_error("unsupported-base-region");
        // Interior connection rewrites share the link table. Do not snapshot a
        // transient graph as a base for an exterior resource patch.
        for (unsigned i = 0; i < count; ++i)
        {
            const auto& n = Nodes(a)[i];
            if (U16(n, 18) != a || U16(n, 20) != i || U16(n, 16) + (n[24] & 15) > addresses)
                throw std::runtime_error("base-region-has-dynamic-or-invalid-links");
        }
        std::vector<std::uint8_t> normalized;
        auto                      append = [&](const void* p, std::size_t size)
        {
            if (size)
            {
                auto* b = static_cast<const std::uint8_t*>(p);
                normalized.insert(normalized.end(), b, b + size);
            }
        };
        const std::array<unsigned, 5> header{{count, vehicles, count - vehicles, cars, addresses}};
        append(header.data(), sizeof(header));
        for (unsigned i = 0; i < count; ++i)
        {
            Node n = Nodes(a)[i];
            // Search pointers/distance and switched-road runtime flags are not
            // file identity. Keep geometry, topology and all vehicle data.
            std::fill(n.begin(), n.begin() + 8, 0);
            n[14] = n[15] = 0;
            n[24] &= ~0x20;
            n[25] &= ~0x07;
            append(n.data(), n.size());
        }
        append(Field<void*>(0x924, a), cars * 14);
        append(Links(a), addresses * sizeof(Address));
        append(Field<void*>(0xDA4, a), addresses * 2);
        append(Lengths(a), addresses);
        append(Intersections(a), addresses);
        std::array<std::uint8_t, 32> digest;
        SharedUtil::GenerateSha256(normalized.data(), static_cast<unsigned>(normalized.size()), digest.data());
        if (r.nodes && (r.count != count || r.vehicles != vehicles || r.addresses != addresses || r.digest != digest))
            throw std::runtime_error("base-region-changed-restart-client");
        r.originalNaviLinks = Field<std::uint16_t*>(0xDA4, a);
        r.originalNodes = Nodes(a);
        r.originalLinks = Links(a);
        r.originalLengths = Lengths(a);
        r.originalIntersections = Intersections(a);
        r.originalNavi = NaviNodes(a);
        r.count = count;
        r.vehicles = vehicles;
        r.addresses = addresses;
        r.cars = cars;
        r.digest = digest;
        r.highWater = std::max(r.highWater, count);
        r.naviHighWater = std::max(r.naviHighWater, cars);
        r.loaded = true;
    }
    void Service::ProtectRejectedReload(unsigned a)
    {
        auto& r = m_regions[a];
        if (!r.nodes || r.loaded || r.rejectedNodes)
            return;
        // A rejected base must never become admissible again in this process:
        // native tasks can retain addresses from the former graph indefinitely.
        r.faulted = true;
        if (r.navi && !r.rejectedNavi && CarCount(a) < r.naviHighWater && (NaviNodes(a) || !CarCount(a)))
        {
            // A car's autopilot can still name a navi id above the rejected
            // file's count. Back those ids with inert (zero-lane) records.
            r.rejectedNavi = NaviNodes(a);
            r.rejectedNaviCount = CarCount(a);
            if (r.rejectedNaviCount)
                std::copy_n(r.rejectedNavi, r.rejectedNaviCount, r.navi.get());
            for (unsigned i = r.rejectedNaviCount; i < r.naviHighWater; ++i)
            {
                r.navi[i][11] = 0;
                r.navi[i][12] &= ~0x03;
            }
            NaviNodes(a) = r.navi.get();
            CarCount(a) = r.naviHighWater;
        }
        if (!Nodes(a) || NodeCount(a) >= r.highWater)
            return;
        // GTA checks the region pointer, not the node count, when consuming
        // saved route/wander addresses. Even a failed reload therefore needs
        // the old address range backed by storage. Leave the new native links
        // untouched and pad only its node array with inert old-address slots.
        // This path allocates nothing and does not trust the rejected topology.
        r.rejectedNodes = Nodes(a);
        r.rejectedCount = NodeCount(a);
        r.rejectedPeds = PedCount(a);
        std::copy_n(r.rejectedNodes, r.rejectedCount, r.nodes.get());
        for (unsigned i = r.rejectedCount; i < r.highWater; ++i)
        {
            auto& n = r.nodes[i];
            std::fill(n.begin(), n.begin() + 8, 0);
            Put16(n, 14, 0x7FFE);
            Put16(n, 16, 0);
            Put16(n, 18, a);
            Put16(n, 20, i);
            n[24] = 0x20;
            n[25] = 0x05;
            n[26] = 0;
        }
        Nodes(a) = r.nodes.get();
        NodeCount(a) = r.highWater;
        PedCount(a) = r.rejectedPeds + r.highWater - r.rejectedCount;
    }
    void Service::Publish(unsigned a, const Area* patch)
    {
        auto& r = m_regions[a];
        if (!r.loaded || !r.nodes || r.faulted)
            return;
        // Preserve GTA's current vehicle and dynamic-link state. Only the
        // pedestrian records owned by the patch differ from the baseline.
        if (r.published)
        {
            for (unsigned id = 0; id < r.count; ++id)
                if (!r.edited[id])
                    r.originalNodes[id] = r.nodes[id];
            if (r.addresses)
            {
                std::copy_n(r.links.get(), r.addresses, r.originalLinks);
                std::copy_n(r.lengths.get(), r.addresses, r.originalLengths);
                std::copy_n(r.intersections.get(), r.addresses, r.originalIntersections);
                std::copy_n(r.naviLinks.get(), r.addresses, r.originalNaviLinks);
            }
            // Unpatched navi records may hold GTA's runtime bridge-light bit.
            for (unsigned id = 0; id < r.cars; ++id)
                if (!r.naviEdited[id])
                    r.originalNavi[id] = r.navi[id];
        }
        std::copy_n(r.originalNodes, r.count, r.nodes.get());
        if (r.cars)
            std::copy_n(r.originalNavi, r.cars, r.navi.get());
        for (unsigned i = r.cars; i < r.naviHighWater; ++i)
        {
            // Retired custom roads keep their geometry for cars still on them
            // but offer no lanes or lights, so nothing new spawns there.
            r.navi[i][11] = 0;
            r.navi[i][12] &= ~0x03;
        }
        std::fill_n(r.naviLinks.get(), MaxLinks, std::uint16_t(0xFFFF));
        if (r.addresses)
            std::copy_n(r.originalNaviLinks, r.addresses, r.naviLinks.get());
        if (r.addresses)
        {
            std::copy_n(r.originalLinks, r.addresses, r.links.get());
            std::copy_n(r.originalLengths, r.addresses, r.lengths.get());
            std::copy_n(r.originalIntersections, r.addresses, r.intersections.get());
        }
        if (!r.published)
        {
            std::fill_n(r.links.get() + StaticLinks, DynamicLinks, Address{0xFFFF, 0xFFFF});
            std::fill_n(r.lengths.get() + StaticLinks, DynamicLinks, 0);
            std::fill_n(r.intersections.get() + StaticLinks, DynamicLinks, 0);
        }
        for (unsigned i = r.count; i < r.highWater; ++i)
        {
            auto& n = r.nodes[i];
            // Preserve coordinates for in-flight tasks; remove all future
            // routing/spawn eligibility without recycling the address.
            n[24] = 0x20;
            n[25] = 0x05;
            n[26] = 0;
            Put16(n, 16, 0);
            Put16(n, 18, a);
            Put16(n, 20, i);
        }
        r.edited.fill(false);
        r.naviEdited.fill(false);
        unsigned link = r.addresses;
        if (patch)
        {
            // Roads first (baseline -> roads -> pedestrians), all in one slab
            // so GTA never sees a half-applied region.
            for (const auto& edit : patch->vehicleEdits)
            {
                r.edited[edit.node] = true;
                auto& n = r.nodes[edit.node];
                std::fill(n.begin(), n.begin() + 8, 0);
                for (unsigned k = 0; k < 3; ++k)
                    Put16(n, 8 + k * 2, static_cast<std::uint16_t>(edit.position[k]));
                Put16(n, 14, 0x7FFE);
                Put16(n, 16, link);
                Put16(n, 18, a);
                Put16(n, 20, edit.node);
                n[22] = edit.width;
                n[23] = edit.flood;
                n[24] = static_cast<std::uint8_t>((edit.flags & 0xF0) | edit.links.size());
                // +0x19 bit 0 mirrors "switched off" exactly as the loader does.
                n[25] = static_cast<std::uint8_t>(((edit.flags & 0x20) ? 1 : 0) | (edit.speed << 4));
                n[26] = edit.spawn;
                n[27] = 0;
                for (const auto& edge : edit.links)
                {
                    r.links[link] = edge.to;
                    r.lengths[link] = edge.length;
                    r.intersections[link] = 0;
                    r.naviLinks[link] = edge.navi;
                    ++link;
                }
            }
            for (const auto& edit : patch->naviEdits)
            {
                r.naviEdited[edit.id] = true;
                auto&              v = r.navi[edit.id];
                const std::uint8_t bridge = edit.id < r.cars ? (v[12] & 0x04) : 0;
                v[0] = static_cast<std::uint8_t>(edit.position[0] & 255);
                v[1] = static_cast<std::uint8_t>((static_cast<std::uint16_t>(edit.position[0]) >> 8) & 255);
                v[2] = static_cast<std::uint8_t>(edit.position[1] & 255);
                v[3] = static_cast<std::uint8_t>((static_cast<std::uint16_t>(edit.position[1]) >> 8) & 255);
                v[4] = edit.attached.area & 255;
                v[5] = edit.attached.area >> 8;
                v[6] = edit.attached.node & 255;
                v[7] = edit.attached.node >> 8;
                v[8] = static_cast<std::uint8_t>(edit.direction[0]);
                v[9] = static_cast<std::uint8_t>(edit.direction[1]);
                v[10] = edit.width;
                v[11] = edit.lanes;
                v[12] = static_cast<std::uint8_t>(edit.light | bridge);
                v[13] = 0;
            }
        }
        if (patch)
            for (const auto& edit : patch->edits)
            {
                r.edited[edit.node] = true;
                auto& n = r.nodes[edit.node];
                if (edit.node >= r.count)
                {
                    n.fill(0);
                    Put16(n, 14, 0x7FFE);
                    Put16(n, 18, a);
                    Put16(n, 20, edit.node);
                }
                for (unsigned k = 0; k < 3; ++k)
                    Put16(n, 8 + k * 2, static_cast<std::uint16_t>(edit.position[k]));
                n[22] = edit.width;
                n[23] = edit.flood;
                n[24] = edit.enabled ? static_cast<std::uint8_t>(edit.links.size()) : 0x20;
                n[25] = edit.enabled ? 0 : 5;
                n[26] = edit.enabled ? 15 : 0;
                Put16(n, 16, edit.links.empty() ? 0 : link);
                for (const auto& edge : edit.links)
                {
                    r.links[link] = edge.to;
                    r.lengths[link] = edge.length;
                    r.intersections[link] = edge.flags;
                    ++link;
                }
            }
        Nodes(a) = r.nodes.get();
        Links(a) = r.links.get();
        Lengths(a) = r.lengths.get();
        Intersections(a) = r.intersections.get();
        Field<std::uint16_t*>(0xDA4, a) = r.naviLinks.get();
        NaviNodes(a) = r.navi.get();
        // SA:O's own lane and spawn helpers bound navi ids by this count.
        CarCount(a) = r.naviHighWater;
        // Once the patch is gone, use the original dynamic boundary again.
        // Tombstones have no links, so no custom static index survives restore.
        // This also keeps retail interior bookkeeping on its original indices.
        AddressCount(a) = patch && patch->Changed() ? StaticLinks : r.addresses;
        if (!patch && r.addresses)
        {
            std::copy_n(r.originalLinks + r.addresses, DynamicLinks, r.links.get() + r.addresses);
            std::copy_n(r.originalLengths + r.addresses, DynamicLinks, r.lengths.get() + r.addresses);
            std::copy_n(r.originalIntersections + r.addresses, DynamicLinks, r.intersections.get() + r.addresses);
        }
        NodeCount(a) = r.highWater;
        PedCount(a) = r.highWater - r.vehicles;
        r.published = true;
        // Car placement caches starting nodes for a while; drop the cache so
        // new traffic never starts from a road that was just moved.
        *reinterpret_cast<std::uint32_t*>(CarCreationCacheTime) = 0;
    }
    void Service::Unloading(unsigned a)
    {
        auto& r = m_regions[a];
        if (r.rejectedNodes)
        {
            // The loader's replacement allocation is still owned by GTA.
            // Restore exactly that allocation for native delete[], never the
            // previous stream generation or our process-lifetime safety slab.
            Nodes(a) = r.rejectedNodes;
            NodeCount(a) = r.rejectedCount;
            PedCount(a) = r.rejectedPeds;
            r.rejectedNodes = nullptr;
        }
        if (r.rejectedNavi || (r.navi && !r.loaded && NaviNodes(a) == r.navi.get()))
        {
            // Native delete[] must free the loader's own navi allocation.
            NaviNodes(a) = r.rejectedNavi;
            CarCount(a) = r.rejectedNaviCount;
            r.rejectedNavi = nullptr;
            r.rejectedNaviCount = 0;
        }
        if (!r.loaded)
            return;
        if (r.published)
        {
            // Native delete[] must see native allocations, never our slabs.
            // Retain the first pre-publication node allocation for any native
            // consumer that captured a pointer before we installed the slab.
            Nodes(a) = r.retainedFirstNodes ? r.originalNodes : nullptr;
            r.retainedFirstNodes = true;
            Field<std::uint16_t*>(0xDA4, a) = r.originalNaviLinks;
            NaviNodes(a) = r.originalNavi;
            CarCount(a) = r.cars;
            Links(a) = r.originalLinks;
            Lengths(a) = r.originalLengths;
            Intersections(a) = r.originalIntersections;
            AddressCount(a) = r.addresses;
            NodeCount(a) = r.count;
            PedCount(a) = r.count - r.vehicles;
        }
        r.loaded = false;
        r.published = false;
    }
    void Service::Restore(Lease& lease)
    {
        for (const auto& item : lease.patch.areas)
            if (item.second.Changed())
                Publish(item.first, nullptr);
    }
    void Service::Loaded(unsigned a)
    {
        // Streaming may call this for unowned regions. Do not allocate or
        // change their data unless this process has used a patch there.
        bool needed = m_regions[a].nodes != nullptr;
        for (const auto& item : m_leases)
            needed |= item.second.patch.areas.count(a) != 0;
        if (!needed)
            return;
        try
        {
            Capture(a);
            const Area* selected = nullptr;
            for (auto& item : m_leases)
            {
                const auto found = item.second.patch.areas.find(a);
                if (found == item.second.patch.areas.end() || !item.second.error.empty())
                    continue;
                if (found->second.baseDigest != m_regions[a].digest)
                    throw std::runtime_error("base-fingerprint-mismatch-after-streaming");
                if (found->second.Changed())
                    selected = &found->second;
            }
            Publish(a, selected);
        }
        catch (const std::exception& e)
        {
            ProtectRejectedReload(a);
            for (auto& item : m_leases)
                if (item.second.patch.areas.count(a))
                {
                    item.second.error = e.what();
                    Restore(item.second);
                }
        }
    }
    void Service::Validate(const Patch& patch)
    {
        for (const auto& item : patch.areas)
        {
            const auto  a = item.first;
            const auto& p = item.second;
            const auto& r = m_regions[a];
            if (!r.loaded || p.nodes != r.count || p.vehicles != r.vehicles || p.addresses != r.addresses || p.carLinks != r.cars || p.baseDigest != r.digest)
                throw std::runtime_error("base-fingerprint-mismatch");
            for (const auto& e : p.edits)
            {
                for (const auto& l : e.links)
                {
                    const auto& target = patch.areas.at(l.to.area);
                    bool        edited = false;
                    for (const auto& te : target.edits)
                        edited |= te.node == l.to.node;
                    if (!edited && m_regions[l.to.area].originalNodes[l.to.node][23] != e.flood)
                        throw std::runtime_error("incompatible-flood-fill-group");
                }
            }
        }
        struct EffectiveNode
        {
            bool              enabled{true};
            unsigned          flood{};
            std::vector<Link> links;
        };
        std::array<std::vector<EffectiveNode>, Areas> graph;
        for (const auto& item : patch.areas)
        {
            const auto  a = item.first;
            const auto& r = m_regions[a];
            const auto  liveCount = r.published ? r.highWater : r.count;
            graph[a].resize(liveCount);
            const Node*         live = r.published ? r.nodes.get() : r.originalNodes;
            const Address*      links = r.published ? r.links.get() : r.originalLinks;
            const std::uint8_t* lengths = r.published ? r.lengths.get() : r.originalLengths;
            for (unsigned id = 0; id < liveCount; ++id)
            {
                const auto& n = live[id];
                const auto  base = U16(n, 16), count = unsigned(n[24] & 15);
                // Validate again on each load, including slabs retained after a
                // previous resource stop. Capture's original digest alone does
                // not certify that GTA has not added interior links meanwhile.
                if (base + count > AddressCount(a))
                    throw std::runtime_error("active-interior-links-not-supported");
                auto& out = graph[a][id];
                out.flood = n[23];
                for (unsigned k = 0; k < count; ++k)
                    out.links.push_back({links[base + k], lengths[base + k], 0});
            }
            for (const auto& e : item.second.edits)
            {
                if (e.node >= graph[a].size())
                    graph[a].resize(e.node + 1);
                graph[a][e.node] = {e.enabled != 0, e.flood, e.links};
            }
        }
        for (unsigned a = 0; a < Areas; ++a)
            for (unsigned id = m_regions[a].vehicles; id < graph[a].size(); ++id)
                for (const auto& link : graph[a][id].links)
                {
                    const auto to = link.to;
                    if (to.area >= Areas || to.node < m_regions[to.area].vehicles || to.node >= graph[to.area].size() || !link.length)
                        throw std::runtime_error("invalid-effective-ped-link");
                    const auto& target = graph[to.area][to.node];
                    if (!target.enabled || target.flood != graph[a][id].flood)
                        throw std::runtime_error("disabled-target-or-flood-mismatch");
                    bool reciprocal = false;
                    for (const auto& back : target.links)
                        reciprocal |= back.to.area == a && back.to.node == id && back.length == link.length;
                    // Retail reconstructs a path by subtracting the forward
                    // edge cost from distances propagated backwards. Missing
                    // equal-cost reverse edges can leave that loop stationary.
                    if (!reciprocal)
                        throw std::runtime_error("asymmetric-pedestrian-link");
                }
    }
    // Checks the effective road graph (live data plus this patch) for every
    // invariant whose violation hangs or crashes GTA's car code rather than
    // failing gracefully. The compiler derives these; this refuses a file
    // that was produced any other way.
    void Service::ValidateRoads(const Patch& patch)
    {
        bool roads = false;
        for (const auto& item : patch.areas)
            roads |= !item.second.vehicleEdits.empty() || !item.second.naviEdits.empty();
        if (!roads)
            return;
        struct Road
        {
            unsigned                    flood{};
            std::uint8_t                flags{}, spawn{};
            std::array<std::int16_t, 3> position{};
            std::vector<VehicleLink>    links;
            bool                        edited{};
        };
        std::array<std::vector<Road>, Areas> graph;
        std::array<std::vector<Navi>, Areas> navis;
        std::array<std::vector<bool>, Areas> naviTouched;
        for (const auto& item : patch.areas)
        {
            const auto           a = item.first;
            const auto&          r = m_regions[a];
            const Node*          live = r.published ? r.nodes.get() : r.originalNodes;
            const Address*       links = r.published ? r.links.get() : r.originalLinks;
            const std::uint8_t*  lengths = r.published ? r.lengths.get() : r.originalLengths;
            const std::uint16_t* naviLinks = r.published ? r.naviLinks.get() : r.originalNaviLinks;
            graph[a].resize(r.vehicles);
            for (unsigned id = 0; id < r.vehicles; ++id)
            {
                const auto& n = live[id];
                auto&       out = graph[a][id];
                const auto  base = U16(n, 16), count = unsigned(n[24] & 15);
                if (base + count > AddressCount(a))
                    throw std::runtime_error("active-interior-links-not-supported");
                out.flood = n[23];
                out.flags = n[24] & 0xF0;
                out.spawn = n[26];
                for (unsigned k = 0; k < 3; ++k)
                    out.position[k] = static_cast<std::int16_t>(U16(n, 8 + k * 2));
                for (unsigned k = 0; k < count; ++k)
                    out.links.push_back({links[base + k], lengths[base + k], naviLinks[base + k]});
            }
            for (const auto& e : item.second.vehicleEdits)
                graph[a][e.node] = {e.flood, e.flags, e.spawn, e.position, e.links, true};
            const Navi*    liveNavi = r.published ? r.navi.get() : r.originalNavi;
            const unsigned liveCount = r.published ? r.naviHighWater : r.cars;
            if (liveNavi && liveCount)
                navis[a].assign(liveNavi, liveNavi + liveCount);
            naviTouched[a].assign(MaxNavi, false);
            for (const auto& n : item.second.naviEdits)
            {
                if (n.id >= navis[a].size())
                    navis[a].resize(n.id + 1, Navi{});
                auto& v = navis[a][n.id];
                v[4] = n.attached.area & 255;
                v[5] = n.attached.area >> 8;
                v[6] = n.attached.node & 255;
                v[7] = n.attached.node >> 8;
                naviTouched[a][n.id] = true;
            }
        }
        for (unsigned a = 0; a < Areas; ++a)
            for (unsigned id = 0; id < graph[a].size(); ++id)
            {
                const auto& node = graph[a][id];
                // Zero links divides by zero in car placement; FindLinksToGo
                // reads exactly twelve link slots.
                if (node.links.empty() || node.links.size() > MaxVehicleLinks)
                    throw std::runtime_error("invalid-road-link-count");
                if (node.edited && RegionOf(node.position[0] / 8.0f, node.position[1] / 8.0f) != a)
                    throw std::runtime_error("road-node-outside-region");
                std::set<unsigned> seen;
                const Address      self{static_cast<std::uint16_t>(a), static_cast<std::uint16_t>(id)};
                for (const auto& link : node.links)
                {
                    const auto to = link.to;
                    if (to.area >= Areas || to.node >= graph[to.area].size() || !link.length)
                        throw std::runtime_error("invalid-effective-road-link");
                    const auto& target = graph[to.area][to.node];
                    if (target.flood != node.flood)
                        throw std::runtime_error("road-flood-mismatch");
                    // DoPathSearch walks back by subtracting the edge cost and
                    // FollowPath scans for the reverse link without a bound.
                    bool reciprocal = false;
                    for (const auto& back : target.links)
                        reciprocal |= back.to == self && back.length == link.length && back.navi == link.navi;
                    if (!reciprocal)
                        throw std::runtime_error("asymmetric-road-link");
                    if (!seen.insert(link.navi).second)
                        throw std::runtime_error("duplicate-road-navi");
                    const unsigned naviArea = link.navi >> 10, naviId = link.navi & 0x3FF;
                    if (naviArea >= Areas || naviId >= navis[naviArea].size())
                        throw std::runtime_error("missing-road-navi");
                    if (!node.edited && !target.edited && !naviTouched[naviArea][naviId])
                        continue;
                    // Lane side and travel sign both assume the navi hangs on
                    // the lower endpoint; anything else drives on the left.
                    const auto&   v = navis[naviArea][naviId];
                    const Address attached{static_cast<std::uint16_t>(v[4] | (v[5] << 8)), static_cast<std::uint16_t>(v[6] | (v[7] << 8))};
                    if (!(attached == std::min(self, to)))
                        throw std::runtime_error("road-navi-not-on-lower-endpoint");
                    if ((node.flags & 0x80) != (target.flags & 0x80))
                        throw std::runtime_error("road-links-land-and-water");
                    // The host region must stream with the edge, or a car on
                    // it would read an unloaded navi array.
                    const float mx = (node.position[0] + target.position[0]) / 16.0f, my = (node.position[1] + target.position[1]) / 16.0f;
                    if (naviArea != a && naviArea != to.area && naviArea != RegionOf(mx, my))
                        throw std::runtime_error("road-navi-host-region");
                }
                if (node.edited && (node.flags & 0x10))
                {
                    // ThisNodeWillLeadIntoADeadEnd follows single successors
                    // and never stops on a branchless ring.
                    Address prev{0xFFFF, 0xFFFF}, cur = self;
                    for (unsigned step = 0;; ++step)
                    {
                        if (step > MaxNodes * 2)
                            throw std::runtime_error("road-dead-end-hint-on-loop");
                        unsigned next = 0;
                        Address  following{};
                        for (const auto& l : graph[cur.area][cur.node].links)
                        {
                            const auto behaviour = graph[l.to.area][l.to.node].spawn >> 4;
                            if (!(l.to == prev) && (behaviour == 0 || behaviour > 10))
                            {
                                ++next;
                                following = l.to;
                            }
                        }
                        if (next != 1)
                            break;
                        prev = cur;
                        cur = following;
                    }
                }
            }
    }
    bool Service::Load(void* owner, const void* data, std::size_t size, std::string& revision, std::string& error)
    {
        if (!owner || m_busy)
        {
            error = "invalid-owner-or-busy";
            return false;
        }
        if (m_leases.count(owner))
        {
            error = "resource-already-has-patch";
            return false;
        }
        m_busy = true;
        struct Guard
        {
            bool& value;
            ~Guard() { value = false; }
        } guard{m_busy};
        try
        {
            Lease lease;
            lease.patch = Parse(data, size);
            lease.revision = SharedUtil::GenerateSha256HexString(data, static_cast<unsigned>(size));
            for (const auto& item : lease.patch.areas)
            {
                for (const auto& existing : m_leases)
                    if (item.second.Changed() && existing.second.patch.areas.at(item.first).Changed())
                        throw std::runtime_error("region-owned-by-another-resource");
                const auto& r = m_regions[item.first];
                for (const auto& e : item.second.edits)
                    if (e.node >= item.second.nodes && !r.additionRevision.empty() && r.additionRevision != lease.revision)
                        throw std::runtime_error("added-node-addresses-reserved-restart-client");
                for (const auto& n : item.second.naviEdits)
                    if (n.id >= item.second.carLinks && !r.additionRevision.empty() && r.additionRevision != lease.revision)
                        throw std::runtime_error("added-node-addresses-reserved-restart-client");
            }
            if (!Install(error))
                return false;
            // Use the public streamer, rather than invoking a disk loader
            // behind its back. All dependency regions are validated before
            // publishing any patch, and normal streaming flags are preserved.
            for (const auto& item : lease.patch.areas)
                if (!Nodes(item.first))
                    pGame->GetStreaming()->RequestModel(pGame->GetFileIDLayout().dat + item.first, 0);
            pGame->GetStreaming()->LoadAllRequestedModels(false, "ped-path-patch");
            for (const auto& item : lease.patch.areas)
                Capture(item.first);
            Validate(lease.patch);
            ValidateRoads(lease.patch);
            // Allocate every slab before publication: a failed allocation
            // cannot leave half of a multi-region patch visible to GTA.
            for (const auto& item : lease.patch.areas)
            {
                if (!item.second.Changed())
                    continue;
                auto& r = m_regions[item.first];
                if (!r.nodes)
                {
                    auto nodes = std::make_unique<Node[]>(MaxNodes);
                    auto links = std::make_unique<Address[]>(MaxLinks);
                    auto naviLinks = std::make_unique<std::uint16_t[]>(MaxLinks);
                    auto lengths = std::make_unique<std::uint8_t[]>(MaxLinks);
                    auto intersections = std::make_unique<std::uint8_t[]>(MaxLinks);
                    r.naviLinks = std::move(naviLinks);
                    r.nodes = std::move(nodes);
                    r.links = std::move(links);
                    r.lengths = std::move(lengths);
                    r.intersections = std::move(intersections);
                }
                if (!r.navi)
                    r.navi = std::make_unique<Navi[]>(MaxNavi);
            }
            for (const auto& item : lease.patch.areas)
            {
                for (const auto& e : item.second.edits)
                    if (e.node >= item.second.nodes)
                        m_regions[item.first].additionRevision = lease.revision;
                for (const auto& n : item.second.naviEdits)
                    if (n.id >= item.second.carLinks)
                        m_regions[item.first].additionRevision = lease.revision;
            }
            revision = lease.revision;
            auto inserted = m_leases.emplace(owner, std::move(lease)).first;
            for (const auto& item : inserted->second.patch.areas)
            {
                if (!item.second.Changed())
                    continue;
                auto& r = m_regions[item.first];
                for (const auto& e : item.second.edits)
                    if (e.node >= r.count)
                    {
                        r.highWater = std::max(r.highWater, unsigned(e.node) + 1);
                    }
                for (const auto& n : item.second.naviEdits)
                    r.naviHighWater = std::max(r.naviHighWater, unsigned(n.id) + 1);
                Publish(item.first, &item.second);
            }
            return true;
        }
        catch (const std::exception& e)
        {
            error = e.what();
            return false;
        }
    }
    bool Service::Unload(void* owner)
    {
        auto found = m_leases.find(owner);
        if (found == m_leases.end() || m_busy)
            return false;
        Restore(found->second);
        m_leases.erase(found);
        return true;
    }
    bool Service::GetGraphRevision(std::string& revision, std::string& error) const
    {
        if (m_leases.empty())
        {
            error = "no-patches";
            return false;
        }
        std::vector<std::string> revisions;
        for (const auto& item : m_leases)
        {
            if (!item.second.error.empty())
            {
                error = "active-graph-incompatible";
                return false;
            }
            revisions.push_back(item.second.revision);
        }
        std::sort(revisions.begin(), revisions.end());
        std::string manifest = "NPEDGRAPH1";
        for (const auto& value : revisions)
            manifest += value;
        revision = SharedUtil::GenerateSha256HexString(manifest.data(), static_cast<unsigned>(manifest.size()));
        return true;
    }
    bool Service::GetRevision(void* owner, std::string& revision, std::string& error) const
    {
        auto found = m_leases.find(owner);
        if (found == m_leases.end())
        {
            error = "no-patch";
            return false;
        }
        if (!found->second.error.empty())
        {
            error = found->second.error;
            return false;
        }
        revision = found->second.revision;
        return true;
    }
}
CPedPathPatches* GetPedPathPatchesSA()
{
    return &g_service;
}
