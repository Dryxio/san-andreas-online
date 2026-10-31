#pragma once

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <map>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace PedPathPatch
{
    constexpr unsigned Areas = 64;
    constexpr unsigned MaxNodes = 4096;
    constexpr unsigned MaxLinks = 32768;
    constexpr unsigned DynamicLinks = 192;
    constexpr unsigned MaxFileSize = 4 * 1024 * 1024;
    // Vehicle (road) data. Navi links store a 10-bit id and a 6-bit area, so a
    // region can host at most 1024 navi records. FindLinksToGo (0x42B470)
    // scans 12 link slots of a vehicle node.
    constexpr unsigned MaxNavi = 1024;
    constexpr unsigned MaxVehicleLinks = 12;
    constexpr unsigned NaviSize = 14;

    struct Address
    {
        std::uint16_t area{}, node{};
    };
    inline bool operator<(Address a, Address b)
    {
        return a.area != b.area ? a.area < b.area : a.node < b.node;
    }
    inline bool operator==(Address a, Address b)
    {
        return a.area == b.area && a.node == b.node;
    }
    struct Link
    {
        Address      to;
        std::uint8_t length{}, flags{};
    };
    struct Edit
    {
        std::uint16_t               node{};
        std::array<std::int16_t, 3> position{};
        std::uint8_t                width{}, flood{}, enabled{};
        std::vector<Link>           links;
    };
    // A road link. Both directions of an edge carry the same navi record and
    // length: GTA's car route search and FollowPath rely on that pairing.
    struct VehicleLink
    {
        Address       to;
        std::uint8_t  length{};
        std::uint16_t navi{};  // (id & 0x3FF) | (area << 10)
    };
    // Vehicle node identities are fixed to the stock range [0, vehicles): every
    // native search uses that split, so roads are moved or parked, never added.
    struct VehicleEdit
    {
        std::uint16_t               node{};
        std::array<std::int16_t, 3> position{};
        std::uint8_t                width{}, flood{};
        std::uint8_t                flags{};  // +0x18 bits 4-7 (dead end, switched off, roadblock, water)
        std::uint8_t                speed{};  // +0x19 bits 4-5 speed class
        std::uint8_t                spawn{};  // +0x1A spawn probability (low) and behaviour (high)
        std::vector<VehicleLink>    links;
    };
    // CCarPathLink: where cars actually drive on an edge (midpoint, direction
    // toward attachedTo, lanes each way, traffic light).
    struct NaviEdit
    {
        std::uint16_t               id{};
        std::array<std::int16_t, 2> position{};
        Address                     attached;
        std::array<std::int8_t, 2>  direction{};
        std::uint8_t                width{}, lanes{};  // bits 0-2 toward attached, 3-5 away, 6 light direction
        std::uint8_t                light{};           // +0xC bits 0-1
    };
    struct Area
    {
        unsigned                     id{}, nodes{}, vehicles{}, addresses{}, carLinks{};
        std::array<std::uint8_t, 32> baseDigest{};
        std::vector<Edit>            edits;
        std::vector<VehicleEdit>     vehicleEdits;
        std::vector<NaviEdit>        naviEdits;
        bool                         Changed() const { return !edits.empty() || !vehicleEdits.empty() || !naviEdits.empty(); }
    };
    struct Patch
    {
        std::map<unsigned, Area> areas;
    };

    class Reader
    {
        const std::uint8_t* m_data;
        std::size_t         m_size, m_offset{};

    public:
        Reader(const void* data, std::size_t size) : m_data(static_cast<const std::uint8_t*>(data)), m_size(size) {}
        void Bytes(void* out, std::size_t count)
        {
            if (count > m_size - m_offset)
                throw std::runtime_error("truncated-patch");
            std::memcpy(out, m_data + m_offset, count);
            m_offset += count;
        }
        std::uint8_t U8()
        {
            std::uint8_t v;
            Bytes(&v, 1);
            return v;
        }
        std::uint16_t U16()
        {
            auto lo = U8();
            return lo | (unsigned(U8()) << 8);
        }
        std::uint32_t U32()
        {
            auto lo = U16();
            return lo | (std::uint32_t(U16()) << 16);
        }
        bool Done() const { return m_offset == m_size; }
    };

    inline Patch Parse(const void* data, std::size_t size)
    {
        if (!data || size < 12 || size > MaxFileSize)
            throw std::runtime_error("invalid-patch-size");
        Reader r(data, size);
        char   magic[8];
        r.Bytes(magic, 8);
        // Version 2 appends road (vehicle node and navi) edits to every area
        // record; version 1 files remain pedestrian-only and load unchanged.
        const bool roads = !std::memcmp(magic, "NPEDPAT2", 8);
        if (!roads && std::memcmp(magic, "NPEDPAT1", 8))
            throw std::runtime_error("unsupported-patch-format");
        const auto count = r.U32();
        if (count != Areas)
            throw std::runtime_error("invalid-area-count");
        Patch patch;
        bool  changed = false;
        for (unsigned i = 0; i < count; ++i)
        {
            Area a;
            a.id = r.U32();
            a.nodes = r.U32();
            a.vehicles = r.U32();
            a.addresses = r.U32();
            a.carLinks = r.U32();
            r.Bytes(a.baseDigest.data(), a.baseDigest.size());
            const auto edits = r.U32();
            if (a.id >= Areas || a.nodes > MaxNodes || a.vehicles > a.nodes || a.addresses > MaxLinks - DynamicLinks || a.carLinks > 65535 ||
                edits > MaxNodes || patch.areas.count(a.id))
                throw std::runtime_error("invalid-area-header");
            unsigned           next = a.nodes, linkCount = a.addresses;
            std::set<unsigned> seen;
            for (unsigned j = 0; j < edits; ++j)
            {
                Edit e;
                e.node = r.U16();
                for (auto& p : e.position)
                    p = static_cast<std::int16_t>(r.U16());
                e.width = r.U8();
                e.flood = r.U8();
                e.enabled = r.U8();
                const auto links = r.U8();
                if (e.node < a.vehicles || e.node >= MaxNodes || !seen.insert(e.node).second || e.enabled > 1 || links > 15 || (!e.enabled && links) ||
                    (!e.enabled && e.node >= a.nodes))
                    throw std::runtime_error("invalid-ped-node");
                // Appends have deterministic addresses; a missing slot must never
                // accidentally become a valid native path node.
                if (e.node >= a.nodes && e.node != next++)
                    throw std::runtime_error("non-contiguous-added-nodes");
                std::set<unsigned> targets;
                for (unsigned k = 0; k < links; ++k)
                {
                    Link l;
                    l.to.area = r.U16();
                    l.to.node = r.U16();
                    l.length = r.U8();
                    l.flags = r.U8();
                    if (l.to.area >= Areas || !l.length || l.flags > 3 || !targets.insert((unsigned(l.to.area) << 16) | l.to.node).second ||
                        (l.to.area == a.id && l.to.node == e.node))
                        throw std::runtime_error("invalid-ped-link");
                    e.links.push_back(l);
                }
                linkCount += links;
                if (linkCount > MaxLinks - DynamicLinks)
                    throw std::runtime_error("too-many-links");
                a.edits.push_back(std::move(e));
            }
            if (roads)
            {
                const auto vehicleEdits = r.U32();
                if (vehicleEdits > a.vehicles)
                    throw std::runtime_error("invalid-area-header");
                std::set<unsigned> vehicleSeen;
                for (unsigned j = 0; j < vehicleEdits; ++j)
                {
                    VehicleEdit e;
                    e.node = r.U16();
                    for (auto& p : e.position)
                        p = static_cast<std::int16_t>(r.U16());
                    e.width = r.U8();
                    e.flood = r.U8();
                    e.flags = r.U8();
                    e.speed = r.U8();
                    e.spawn = r.U8();
                    const auto links = r.U8();
                    // Zero links divides by zero in GenerateCarCreationCoors2;
                    // unused nodes are parked as linked pairs instead.
                    if (e.node >= a.vehicles || !vehicleSeen.insert(e.node).second || (e.flags & 0x0F) || e.speed > 3 || !links || links > MaxVehicleLinks ||
                        e.width > 127)
                        throw std::runtime_error("invalid-vehicle-node");
                    std::set<unsigned> targets, navis;
                    for (unsigned k = 0; k < links; ++k)
                    {
                        VehicleLink l;
                        l.to.area = r.U16();
                        l.to.node = r.U16();
                        l.length = r.U8();
                        l.navi = r.U16();
                        // Distinct navi per node: GenerateOneRandomCar loops
                        // until it finds a link with a different navi record.
                        if (l.to.area >= Areas || !l.length || !targets.insert((unsigned(l.to.area) << 16) | l.to.node).second ||
                            !navis.insert(l.navi).second || (l.to.area == a.id && l.to.node == e.node))
                            throw std::runtime_error("invalid-vehicle-link");
                        e.links.push_back(l);
                    }
                    linkCount += links;
                    if (linkCount > MaxLinks - DynamicLinks)
                        throw std::runtime_error("too-many-links");
                    a.vehicleEdits.push_back(std::move(e));
                }
                const auto naviEdits = r.U32();
                if (naviEdits > MaxNavi)
                    throw std::runtime_error("invalid-area-header");
                std::set<unsigned> naviSeen;
                for (unsigned j = 0; j < naviEdits; ++j)
                {
                    NaviEdit n;
                    n.id = r.U16();
                    for (auto& p : n.position)
                        p = static_cast<std::int16_t>(r.U16());
                    n.attached.area = r.U16();
                    n.attached.node = r.U16();
                    n.direction[0] = static_cast<std::int8_t>(r.U8());
                    n.direction[1] = static_cast<std::int8_t>(r.U8());
                    n.width = r.U8();
                    n.lanes = r.U8();
                    n.light = r.U8();
                    if (n.id >= MaxNavi || !naviSeen.insert(n.id).second || n.attached.area >= Areas || n.width > 127 || n.lanes > 0x7F || n.light > 3)
                        throw std::runtime_error("invalid-navi-record");
                    a.naviEdits.push_back(n);
                }
                // New navi ids above the stock count must be contiguous, like
                // added nodes: a gap would be an all-zero record that native
                // code could still index.
                unsigned added = 0, highest = 0;
                for (const auto& n : a.naviEdits)
                    if (n.id >= a.carLinks)
                    {
                        ++added;
                        highest = std::max<unsigned>(highest, n.id + 1);
                    }
                if (added && highest != a.carLinks + added)
                    throw std::runtime_error("non-contiguous-added-navi");
            }
            changed |= a.Changed();
            patch.areas.emplace(a.id, std::move(a));
        }
        if (!changed || !r.Done())
            throw std::runtime_error("empty-patch-or-trailing-data");
        for (const auto& entry : patch.areas)
            for (const auto& e : entry.second.edits)
                for (const auto& l : e.links)
                {
                    const auto target = patch.areas.find(l.to.area);
                    if (target == patch.areas.end() || l.to.node < target->second.vehicles)
                        throw std::runtime_error("missing-ped-link-dependency");
                    const Edit* targetEdit = nullptr;
                    for (const auto& candidate : target->second.edits)
                        if (candidate.node == l.to.node)
                            targetEdit = &candidate;
                    if ((targetEdit && (!targetEdit->enabled || targetEdit->flood != e.flood)) || (!targetEdit && l.to.node >= target->second.nodes))
                        throw std::runtime_error("invalid-ped-link-target");
                }
        // Road links may only target stock vehicle slots of a declared area;
        // the effective graph is checked again against live data on load.
        for (const auto& entry : patch.areas)
            for (const auto& e : entry.second.vehicleEdits)
                for (const auto& l : e.links)
                {
                    const auto target = patch.areas.find(l.to.area);
                    if (target == patch.areas.end() || l.to.node >= target->second.vehicles || patch.areas.find(l.navi >> 10) == patch.areas.end())
                        throw std::runtime_error("missing-vehicle-link-dependency");
                }
        return patch;
    }
}
