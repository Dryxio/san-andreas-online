#pragma once
#include <memory>
#include <net/ns_common.h>

class CMainConfig;
class CQuicGameplay
{
public:
    CQuicGameplay();
    ~CQuicGameplay();
    bool Start(CMainConfig& config);
    void Pulse();
    void Stop();
    bool Send(const GamePeer& peer, unsigned char kind, NetBitStreamInterface& stream, NetServerPacketReliability reliability, ePacketOrdering ordering);
    void Close(const GamePeer& peer);
    std::string InstallSerial(const GamePeer& peer) const;
private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};
