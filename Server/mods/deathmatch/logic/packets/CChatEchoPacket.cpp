/*****************************************************************************
 *
 *  PROJECT:     Multi Theft Auto v1.0
 *  LICENSE:     See LICENSE in the top level directory
 *  FILE:        mods/deathmatch/logic/packets/CChatEchoPacket.cpp
 *  PURPOSE:     Chat message echo packet class
 *
 *  Multi Theft Auto is available from https://www.multitheftauto.com/
 *
 *****************************************************************************/

#include "StdInc.h"
#include "CChatEchoPacket.h"
#include "CElement.h"

bool CChatEchoPacket::Write(NetBitStreamInterface& BitStream) const
{
    // Write the color
    BitStream.Write(m_ucRed);
    BitStream.Write(m_ucGreen);
    BitStream.Write(m_ucBlue);
    BitStream.WriteBit(m_bColorCoded);

    // Write the client's ID and message type only for desktop clients (BitStream version > 0x30).
    // The Android mobile client (0x0030) reads only 25 bits of color/formatting header and treats
    // the remaining stream directly as text without ClientID (17 bits) or MessageType (8 bits).
    if (BitStream.Version() > 0x30)
    {
        BitStream.Write(GetSourceElement() ? GetSourceElement()->GetID() : INVALID_ELEMENT_ID);

        size_t sizeMessage = m_strMessage.length();
        if (sizeMessage >= MIN_CHATECHO_LENGTH)
        {
            BitStream.Write(m_ucMessageType);
            BitStream.Write(m_strMessage.c_str(), sizeMessage);
            return true;
        }

        return false;
    }

    size_t sizeMessage = m_strMessage.length();
    if (sizeMessage >= MIN_CHATECHO_LENGTH)
    {
        BitStream.Write(m_strMessage.c_str(), sizeMessage);
        return true;
    }

    return false;
}
