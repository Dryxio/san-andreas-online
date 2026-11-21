// Run with c++ -std=c++17 Tests/standalone/test_android_ac_exemption.cpp -o /tmp/android-ac-exemption && /tmp/android-ac-exemption
#include <cassert>
#include <string>

// Android protocol hints select wire compatibility. Stock anticheat decisions belong to the network module.
bool DetectAndroidClient(bool hasAndroidTicketClaim, unsigned short bitStreamVersion, const std::string& playerVersion)
{
    return hasAndroidTicketClaim ||
           bitStreamVersion == 0x0030 ||
           playerVersion.find("29999") != std::string::npos;
}

// Simulates network protocol compatibility check from CGame::Packet_PlayerJoinData
bool IsSupportedProtocol(unsigned short clientNetVersion, unsigned short serverNetVersion, bool& outRelease189)
{
    outRelease189 = (clientNetVersion == 0x41E6);
    return clientNetVersion == serverNetVersion || outRelease189 || clientNetVersion == 0x41E7;
}

// Simulates chat header wire format from CChatEchoPacket::Write
constexpr bool ChatEchoPacketHasDesktopHeader(unsigned short bitStreamVersion)
{
    return bitStreamVersion > 0x30;
}

static_assert(ChatEchoPacketHasDesktopHeader(0x003D) == true);
static_assert(ChatEchoPacketHasDesktopHeader(0x0030) == false);

int main()
{
    // Protocol compatibility checks
    bool is189 = false;
    assert(IsSupportedProtocol(0x41E6, 0x41E7, is189) == true);
    assert(is189 == true);

    assert(IsSupportedProtocol(0x41E6, 0x41E6, is189) == true);
    assert(is189 == true);

    assert(IsSupportedProtocol(0x41E7, 0x41E7, is189) == true);
    assert(is189 == false);

    assert(IsSupportedProtocol(0x41E5, 0x41E7, is189) == false);

    // 1. Desktop Windows PC client on default server
    const bool pcIsAndroid = DetectAndroidClient(false, 0x003D, "1.6.0-9.22445.0");
    assert(!pcIsAndroid);

    // 2. Android client identified via mobile bitstream version 0x0030
    const bool androidByBitStream = DetectAndroidClient(false, 0x0030, "1.7.0-9.29999.0");
    assert(androidByBitStream == true);

    // 3. Android client identified via mobile build number 29999
    const bool androidByBuild = DetectAndroidClient(false, 0x003D, "1.7.0-9.29999.0");
    assert(androidByBuild == true);

    // 4. Android client identified via hardware ticket admission claim
    const bool androidByTicket = DetectAndroidClient(true, 0x003D, "1.6.0-9.00000.0");
    assert(androidByTicket == true);

    assert(ChatEchoPacketHasDesktopHeader(0x003D) == true);
    assert(ChatEchoPacketHasDesktopHeader(0x0030) == false);
    return 0;
}
