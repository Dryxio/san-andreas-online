/*****************************************************************************
 *
 *  PROJECT:     Multi Theft Auto
 *  LICENSE:     See LICENSE in the top level directory
 *  FILE:        Client/mods/deathmatch/logic/luadefs/CLuaVehicleSirenDefs.cpp
 *  PURPOSE:     Lua script definitions for Advanced Vehicle Sirens (AVS)
 *
 *****************************************************************************/

#include "StdInc.h"
#include "CLuaVehicleSirenDefs.h"
#include "../CClientVehicleSirenManager.h"
#include "../CClientVehicle.h"
#include <CScriptArgReader.h>

void CLuaVehicleSirenDefs::LoadFunctions()
{
    constexpr static const std::pair<const char*, lua_CFunction> functions[]{
        {"registerVehicleSirenModel", RegisterVehicleSirenModel},
        {"unregisterVehicleSirenModel", UnregisterVehicleSirenModel},
        {"isVehicleSirenModelRegistered", IsVehicleSirenModelRegistered},
        {"getVehicleSirenStates", GetVehicleSirenStates},
        {"setVehicleSirenState", SetVehicleSirenState},
        {"getVehicleSirenState", GetVehicleSirenState},
        {"setVehicleSirenMuted", SetVehicleSirenMuted},
        {"isVehicleSirenMuted", IsVehicleSirenMuted},
        {"setVehicleSirenShadowsEnabled", SetVehicleSirenShadowsEnabled},
        {"isVehicleSirenShadowsEnabled", IsVehicleSirenShadowsEnabled},
        {"setSirenShadowsEnabled", SetSirenShadowsEnabled},
        {"isSirenShadowsEnabled", IsSirenShadowsEnabled},
    };

    for (const auto& [name, function] : functions)
        CLuaCFunctions::AddFunction(name, function);
}

int CLuaVehicleSirenDefs::RegisterVehicleSirenModel(lua_State* luaVM)
{
    unsigned short modelId = 0;
    SString        jsonContent;

    CScriptArgReader argStream(luaVM);
    argStream.ReadNumber(modelId);
    argStream.ReadString(jsonContent);

    if (!argStream.HasErrors())
    {
        bool success = CClientVehicleSirenManager::GetSingleton().RegisterModelFromJSON(modelId, std::string(jsonContent.c_str()));
        lua_pushboolean(luaVM, success);
        return 1;
    }

    m_pScriptDebugging->LogCustom(luaVM, argStream.GetFullErrorMessage());
    lua_pushboolean(luaVM, false);
    return 1;
}

int CLuaVehicleSirenDefs::UnregisterVehicleSirenModel(lua_State* luaVM)
{
    unsigned short modelId = 0;

    CScriptArgReader argStream(luaVM);
    argStream.ReadNumber(modelId);

    if (!argStream.HasErrors())
    {
        bool success = CClientVehicleSirenManager::GetSingleton().UnregisterModel(modelId);
        lua_pushboolean(luaVM, success);
        return 1;
    }

    m_pScriptDebugging->LogCustom(luaVM, argStream.GetFullErrorMessage());
    lua_pushboolean(luaVM, false);
    return 1;
}

int CLuaVehicleSirenDefs::IsVehicleSirenModelRegistered(lua_State* luaVM)
{
    unsigned short modelId = 0;

    CScriptArgReader argStream(luaVM);
    argStream.ReadNumber(modelId);

    if (!argStream.HasErrors())
    {
        bool registered = CClientVehicleSirenManager::GetSingleton().HasModelConfig(modelId);
        lua_pushboolean(luaVM, registered);
        return 1;
    }

    m_pScriptDebugging->LogCustom(luaVM, argStream.GetFullErrorMessage());
    lua_pushboolean(luaVM, false);
    return 1;
}

int CLuaVehicleSirenDefs::GetVehicleSirenStates(lua_State* luaVM)
{
    unsigned short modelId = 0;

    CScriptArgReader argStream(luaVM);
    argStream.ReadNumber(modelId);

    if (!argStream.HasErrors())
    {
        std::vector<std::string> states = CClientVehicleSirenManager::GetSingleton().GetModelStates(modelId);
        lua_createtable(luaVM, static_cast<int>(states.size()), 0);
        for (size_t i = 0; i < states.size(); ++i)
        {
            lua_pushstring(luaVM, states[i].c_str());
            lua_rawseti(luaVM, -2, static_cast<int>(i + 1));
        }
        return 1;
    }

    m_pScriptDebugging->LogCustom(luaVM, argStream.GetFullErrorMessage());
    lua_pushboolean(luaVM, false);
    return 1;
}

int CLuaVehicleSirenDefs::SetVehicleSirenState(lua_State* luaVM)
{
    CClientVehicle* pVehicle = nullptr;

    CScriptArgReader argStream(luaVM);
    argStream.ReadUserData(pVehicle);

    if (!argStream.HasErrors())
    {
        if (argStream.NextIsString())
        {
            SString stateName;
            argStream.ReadString(stateName);
            bool success = CClientVehicleSirenManager::GetSingleton().SetVehicleSirenState(pVehicle, std::string(stateName.c_str()));
            lua_pushboolean(luaVM, success);
            return 1;
        }
        else if (argStream.NextIsNumber())
        {
            int stateIndex = 0;
            argStream.ReadNumber(stateIndex);
            bool success = CClientVehicleSirenManager::GetSingleton().SetVehicleSirenState(pVehicle, stateIndex);
            lua_pushboolean(luaVM, success);
            return 1;
        }
    }

    m_pScriptDebugging->LogCustom(luaVM, argStream.GetFullErrorMessage());
    lua_pushboolean(luaVM, false);
    return 1;
}

int CLuaVehicleSirenDefs::GetVehicleSirenState(lua_State* luaVM)
{
    CClientVehicle* pVehicle = nullptr;

    CScriptArgReader argStream(luaVM);
    argStream.ReadUserData(pVehicle);

    if (!argStream.HasErrors())
    {
        int         stateIndex = CClientVehicleSirenManager::GetSingleton().GetVehicleSirenStateIndex(pVehicle);
        std::string stateName = CClientVehicleSirenManager::GetSingleton().GetVehicleSirenStateName(pVehicle);

        lua_pushnumber(luaVM, stateIndex);
        lua_pushstring(luaVM, stateName.c_str());
        return 2;
    }

    m_pScriptDebugging->LogCustom(luaVM, argStream.GetFullErrorMessage());
    lua_pushnil(luaVM);
    return 1;
}

int CLuaVehicleSirenDefs::SetVehicleSirenMuted(lua_State* luaVM)
{
    CClientVehicle* pVehicle = nullptr;
    bool            muted = false;

    CScriptArgReader argStream(luaVM);
    argStream.ReadUserData(pVehicle);
    argStream.ReadBool(muted);

    if (!argStream.HasErrors())
    {
        CClientVehicleSirenManager::GetSingleton().SetVehicleSirenMuted(pVehicle, muted);
        lua_pushboolean(luaVM, true);
        return 1;
    }

    m_pScriptDebugging->LogCustom(luaVM, argStream.GetFullErrorMessage());
    lua_pushboolean(luaVM, false);
    return 1;
}

int CLuaVehicleSirenDefs::IsVehicleSirenMuted(lua_State* luaVM)
{
    CClientVehicle* pVehicle = nullptr;

    CScriptArgReader argStream(luaVM);
    argStream.ReadUserData(pVehicle);

    if (!argStream.HasErrors())
    {
        bool muted = CClientVehicleSirenManager::GetSingleton().IsVehicleSirenMuted(pVehicle);
        lua_pushboolean(luaVM, muted);
        return 1;
    }

    m_pScriptDebugging->LogCustom(luaVM, argStream.GetFullErrorMessage());
    lua_pushboolean(luaVM, false);
    return 1;
}

int CLuaVehicleSirenDefs::SetVehicleSirenShadowsEnabled(lua_State* luaVM)
{
    CClientVehicle* pVehicle = nullptr;
    bool            enabled = false;

    CScriptArgReader argStream(luaVM);
    argStream.ReadUserData(pVehicle);
    argStream.ReadBool(enabled);

    if (!argStream.HasErrors())
    {
        CClientVehicleSirenManager::GetSingleton().SetVehicleSirenShadowsEnabled(pVehicle, enabled);
        lua_pushboolean(luaVM, true);
        return 1;
    }

    m_pScriptDebugging->LogCustom(luaVM, argStream.GetFullErrorMessage());
    lua_pushboolean(luaVM, false);
    return 1;
}

int CLuaVehicleSirenDefs::IsVehicleSirenShadowsEnabled(lua_State* luaVM)
{
    CClientVehicle* pVehicle = nullptr;

    CScriptArgReader argStream(luaVM);
    argStream.ReadUserData(pVehicle);

    if (!argStream.HasErrors())
    {
        bool enabled = CClientVehicleSirenManager::GetSingleton().IsVehicleSirenShadowsEnabled(pVehicle);
        lua_pushboolean(luaVM, enabled);
        return 1;
    }

    m_pScriptDebugging->LogCustom(luaVM, argStream.GetFullErrorMessage());
    lua_pushboolean(luaVM, false);
    return 1;
}

int CLuaVehicleSirenDefs::SetSirenShadowsEnabled(lua_State* luaVM)
{
    bool enabled = false;

    CScriptArgReader argStream(luaVM);
    argStream.ReadBool(enabled);

    if (!argStream.HasErrors())
    {
        CClientVehicleSirenManager::GetSingleton().SetSirenShadowsEnabled(enabled);
        lua_pushboolean(luaVM, true);
        return 1;
    }

    m_pScriptDebugging->LogCustom(luaVM, argStream.GetFullErrorMessage());
    lua_pushboolean(luaVM, false);
    return 1;
}

int CLuaVehicleSirenDefs::IsSirenShadowsEnabled(lua_State* luaVM)
{
    bool enabled = CClientVehicleSirenManager::GetSingleton().IsSirenShadowsEnabled();
    lua_pushboolean(luaVM, enabled);
    return 1;
}
