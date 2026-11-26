#pragma once
#include "ns_playerid.h"
#include <cassert>
#include <cstdint>

// Scoped to gameplay. Only the stock callback and the authenticated QUIC
// acceptor construct these values. Never serialize the process-local handle.
class GamePeer
{
public:
    GamePeer() = default;
    GamePeer(const NetServerPlayerID& socket) : m_address(socket) {}
    static GamePeer Quic(uint64_t handle, unsigned long ip, unsigned short port)
    {
        assert(handle != 0);
        GamePeer peer(NetServerPlayerID(ip, port));
        peer.m_handle = handle;
        return peer;
    }
    bool IsQuic() const { return m_handle != 0; }
    uint64_t Handle() const { return m_handle; }
    const NetServerPlayerID& Stock() const { assert(!IsQuic()); return m_address; }
    unsigned long GetBinaryAddress() const { return m_address.GetBinaryAddress(); }
    unsigned short GetPort() const { return m_address.GetPort(); }
    bool operator<(const GamePeer& other) const
    {
        if (m_handle || other.m_handle) return m_handle < other.m_handle;
        return m_address < other.m_address;
    }
    bool operator==(const GamePeer& other) const
    {
        return m_handle == other.m_handle && (m_handle || m_address == other.m_address);
    }
private:
    NetServerPlayerID m_address;
    uint64_t m_handle = 0;
};
