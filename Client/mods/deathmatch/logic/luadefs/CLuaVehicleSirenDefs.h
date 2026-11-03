/*****************************************************************************
 *
 *  PROJECT:     Multi Theft Auto
 *  LICENSE:     See LICENSE in the top level directory
 *  FILE:        Client/mods/deathmatch/logic/luadefs/CLuaVehicleSirenDefs.h
 *  PURPOSE:     Lua script definitions for Advanced Vehicle Sirens (AVS)
 *
 *****************************************************************************/

#pragma once

#include "CLuaDefs.h"

class CLuaVehicleSirenDefs : public CLuaDefs
{
public:
    static void LoadFunctions();

    LUA_DECLARE(RegisterVehicleSirenModel);
    LUA_DECLARE(UnregisterVehicleSirenModel);
    LUA_DECLARE(IsVehicleSirenModelRegistered);
    LUA_DECLARE(GetVehicleSirenStates);
    LUA_DECLARE(SetVehicleSirenState);
    LUA_DECLARE(GetVehicleSirenState);
    LUA_DECLARE(SetVehicleSirenMuted);
    LUA_DECLARE(IsVehicleSirenMuted);
    LUA_DECLARE(SetVehicleSirenShadowsEnabled);
    LUA_DECLARE(IsVehicleSirenShadowsEnabled);
    LUA_DECLARE(SetSirenShadowsEnabled);
    LUA_DECLARE(IsSirenShadowsEnabled);
};
