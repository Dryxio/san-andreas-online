/*****************************************************************************
 *
 *  PROJECT:     Multi Theft Auto
 *  LICENSE:     See LICENSE in the top level directory
 *  FILE:        Shared/sdk/WaterFlags.h
 *  PURPOSE:     Flags of scripted water, shared by createWater on both sides
 *
 *****************************************************************************/

#pragma once

// Scripted water uses the numbers from the last column of SA's data/water.dat,
// so map makers can copy them straight from that file (issue #3):
//   0  invisible, bottomless
//   1  visible, bottomless (sea, rivers, lakes)
//   2  invisible, shallow
//   3  visible, shallow (swimming pools)
// "Shallow" means the game only counts the area as water down to a few metres
// below its surface, so a tunnel or room under a pool stays dry.
namespace WaterFlags
{
    constexpr unsigned char Visible = 1;
    constexpr unsigned char Shallow = 2;
    constexpr unsigned char All = Visible | Shallow;
    constexpr unsigned char Default = Visible;

    // createWater's last argument used to be a bool "shallow". MTA copied it
    // into GTA's polygon flags at the bit GTA reads as "invisible", so for
    // every MTA release `true` has meant invisible, bottomless water. Old
    // scripts keep exactly that; the shallow depth is opt-in through flags.
    constexpr unsigned char FromLegacyShallow(bool bShallow)
    {
        return bShallow ? 0 : Default;
    }

    constexpr bool IsValid(int iFlags)
    {
        return iFlags >= 0 && iFlags <= All;
    }

    // Reads createWater's last argument, the same way on client and server: a
    // water.dat flag from 0 to 3, or the old bool. A template so this header
    // does not have to pull in the Lua argument reader.
    template <typename TArgReader>
    unsigned char ReadArgument(TArgReader& argStream)
    {
        if (argStream.NextIsNumber())
        {
            int iFlags = Default;
            argStream.ReadNumber(iFlags);
            if (IsValid(iFlags))
                return static_cast<unsigned char>(iFlags);
            argStream.SetCustomError("Expected a water.dat flag from 0 to 3", "Bad argument");
            return Default;
        }

        bool bShallow;
        argStream.ReadBool(bShallow, false);
        return FromLegacyShallow(bShallow);
    }
}
