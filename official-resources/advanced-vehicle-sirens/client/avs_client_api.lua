--[[
    Advanced Vehicle Sirens (AVS) - Client Controls, Keybinds & API
    
    Provides:
    - Automatic state listener for 'avs:state', 'avs:muted', and 'avs:shadows' element data
    - Global driver keybinds:
        * H / Horn: Toggle siren on/off (State 0 <-> State 1)
        * R: Cycle siren states (Off -> 1 -> 2 -> 3 -> Off)
        * 1, 2, 3..9: Direct state selection
        * L: Toggle audio mute
    - Console commands: /avs [state], /avs0..9, /sirenstate, /sirenmute, /avsshadows, /sirenshadows
    - Clean visual notifications on state changes
    - Seamless support for both standard MTA:SA and custom C++ builds
]]

-- Check whether the custom native C++ engine is available
local hasNativeEngine = (type(isVehicleSirenModelRegistered) == "function")

-- Cache native C++ functions exposed by CLuaVehicleSirenDefs (if present)
local nativeSetVehicleSirenState = hasNativeEngine and setVehicleSirenState or nil
local nativeGetVehicleSirenState = hasNativeEngine and getVehicleSirenState or nil
local nativeSetVehicleSirenMuted = hasNativeEngine and setVehicleSirenMuted or nil
local nativeIsVehicleSirenMuted = hasNativeEngine and isVehicleSirenMuted or nil
local nativeIsModelRegistered = hasNativeEngine and isVehicleSirenModelRegistered or nil
local nativeSetVehicleSirenShadowsEnabled = hasNativeEngine and setVehicleSirenShadowsEnabled or nil
local nativeIsVehicleSirenShadowsEnabled = hasNativeEngine and isVehicleSirenShadowsEnabled or nil
local nativeSetSirenShadowsEnabled = hasNativeEngine and setSirenShadowsEnabled or nil
local nativeIsSirenShadowsEnabled = hasNativeEngine and isSirenShadowsEnabled or nil

-- Helper: Check if vehicle model is configured for AVS
local function isAVSVehicle(vehicle)
    if not isElement(vehicle) or getElementType(vehicle) ~= "vehicle" then
        return false
    end
    local model = getElementModel(vehicle)
    if nativeIsModelRegistered and nativeIsModelRegistered(model) then
        return true
    end
    if AVSRenderer and AVSRenderer.getModelConfig(model) then
        return true
    end
    return false
end

-- Helper: Get vehicle if local player is currently the driver and it's an AVS vehicle
local function getLocalDrivingAVSVehicle()
    local veh = getPedOccupiedVehicle(localPlayer)
    if not veh or getVehicleController(veh) ~= localPlayer then
        return nil
    end
    if isAVSVehicle(veh) then
        return veh
    end
    return nil
end

-- Update C++ engine and Lua renderer whenever vehicle state changes
addEventHandler("onClientElementDataChange", root, function(key, oldValue, newValue)
    if key == "avs:state" and getElementType(source) == "vehicle" then
        if nativeSetVehicleSirenState then
            nativeSetVehicleSirenState(source, newValue or 0)
        end
        if AVSRenderer then
            AVSRenderer.setVehicleState(source, newValue)
        end

        -- Provide immediate feedback to the driver
        if source == getPedOccupiedVehicle(localPlayer) and getVehicleController(source) == localPlayer then
            if newValue and newValue ~= 0 and newValue ~= "0" then
                outputChatBox("[AVS] Siren: " .. tostring(newValue), 0, 220, 255)
            else
                outputChatBox("[AVS] Siren: Off", 255, 120, 0)
            end
        end
    elseif key == "avs:muted" and getElementType(source) == "vehicle" then
        if nativeSetVehicleSirenMuted then
            nativeSetVehicleSirenMuted(source, newValue == true)
        end
        if source == getPedOccupiedVehicle(localPlayer) and getVehicleController(source) == localPlayer then
            outputChatBox("[AVS] Siren Audio: " .. (newValue and "Muted" or "Active"), 255, 200, 0)
        end
    elseif key == "avs:shadows" and getElementType(source) == "vehicle" then
        if nativeSetVehicleSirenShadowsEnabled then
            nativeSetVehicleSirenShadowsEnabled(source, newValue ~= false)
        end
        if AVSRenderer then
            AVSRenderer.setVehicleShadowsEnabled(source, newValue ~= false)
        end
    end
end)

-- Initialize state for newly streamed in vehicles
addEventHandler("onClientElementStreamIn", root, function()
    if getElementType(source) == "vehicle" then
        local st = getElementData(source, "avs:state")
        if st and st ~= 0 and st ~= "0" then
            if nativeSetVehicleSirenState then
                nativeSetVehicleSirenState(source, st)
            end
            if AVSRenderer then
                AVSRenderer.setVehicleState(source, st)
            end
        end
        local muted = getElementData(source, "avs:muted")
        if muted ~= nil and nativeSetVehicleSirenMuted then
            nativeSetVehicleSirenMuted(source, muted == true)
        end
        local shadows = getElementData(source, "avs:shadows")
        if shadows ~= nil then
            if nativeSetVehicleSirenShadowsEnabled then
                nativeSetVehicleSirenShadowsEnabled(source, shadows ~= false)
            end
            if AVSRenderer then
                AVSRenderer.setVehicleShadowsEnabled(source, shadows ~= false)
            end
        end
    end
end)

-- Keybind handlers
local function onHornToggle()
    local veh = getLocalDrivingAVSVehicle()
    if not veh then return end

    local curState = getElementData(veh, "avs:state") or 0
    if curState == 0 or curState == "0" then
        triggerServerEvent("avs:requestStateSet", resourceRoot, 1)
    else
        triggerServerEvent("avs:requestStateSet", resourceRoot, 0)
    end
end

local function onCycleStateKey()
    local veh = getLocalDrivingAVSVehicle()
    if not veh then return end
    triggerServerEvent("avs:requestStateCycle", resourceRoot)
end

local function onMuteKey()
    local veh = getLocalDrivingAVSVehicle()
    if not veh then return end
    triggerServerEvent("avs:requestMuteToggle", resourceRoot)
end

local function onNumberKey(key)
    local veh = getLocalDrivingAVSVehicle()
    if not veh then return end
    local num = tonumber(key)
    if num ~= nil then
        triggerServerEvent("avs:requestStateSet", resourceRoot, num)
    end
end

-- Commands for direct state jumps and binds
addCommandHandler("avs", function(_, stateArg)
    local veh = getLocalDrivingAVSVehicle()
    if veh then
        if not stateArg or stateArg == "" or stateArg == "cycle" then
            triggerServerEvent("avs:requestStateCycle", resourceRoot)
        else
            local target = tonumber(stateArg) or stateArg
            triggerServerEvent("avs:requestStateSet", resourceRoot, target)
        end
    end
end)

for i = 0, 9 do
    addCommandHandler("avs" .. tostring(i), function()
        local veh = getLocalDrivingAVSVehicle()
        if veh then
            triggerServerEvent("avs:requestStateSet", resourceRoot, i)
        end
    end)
end

addCommandHandler("sirenstate", onCycleStateKey)
addCommandHandler("sirenmute", onMuteKey)

-- Setup global keybindings on resource start
addEventHandler("onClientResourceStart", resourceRoot, function()
    -- Primary siren toggle on H and horn control
    bindKey("h", "down", onHornToggle)
    bindKey("horn", "down", onHornToggle)

    -- AVS cycling on R
    bindKey("r", "down", onCycleStateKey)

    -- AVS audio mute on L
    bindKey("l", "down", onMuteKey)

    -- Direct numeric state selection (1, 2, 3, 4, 5, 6, 7, 8, 9, 0)
    for i = 0, 9 do
        bindKey(tostring(i), "down", onNumberKey)
    end

    -- Sync any already spawned streamed-in vehicles
    for _, veh in ipairs(getElementsByType("vehicle")) do
        if isElementStreamedIn(veh) then
            local st = getElementData(veh, "avs:state")
            if st and st ~= 0 and st ~= "0" then
                if nativeSetVehicleSirenState then
                    nativeSetVehicleSirenState(veh, st)
                end
                if AVSRenderer then
                    AVSRenderer.setVehicleState(veh, st)
                end
            end
            local muted = getElementData(veh, "avs:muted")
            if muted ~= nil and nativeSetVehicleSirenMuted then
                nativeSetVehicleSirenMuted(veh, muted == true)
            end
            local shadows = getElementData(veh, "avs:shadows")
            if shadows ~= nil then
                if nativeSetVehicleSirenShadowsEnabled then
                    nativeSetVehicleSirenShadowsEnabled(veh, shadows ~= false)
                end
                if AVSRenderer then
                    AVSRenderer.setVehicleShadowsEnabled(veh, shadows ~= false)
                end
            end
        end
    end
end)

-- Cleanup keybindings on resource stop
addEventHandler("onClientResourceStop", resourceRoot, function()
    unbindKey("h", "down", onHornToggle)
    unbindKey("horn", "down", onHornToggle)
    unbindKey("r", "down", onCycleStateKey)
    unbindKey("l", "down", onMuteKey)
    for i = 0, 9 do
        unbindKey(tostring(i), "down", onNumberKey)
    end
end)

-- Client Exported Functions
function getVehicleSirenState(vehicle)
    if not isElement(vehicle) then return 0 end
    if nativeGetVehicleSirenState then
        return nativeGetVehicleSirenState(vehicle)
    end
    return getElementData(vehicle, "avs:state") or 0
end

function isVehicleSirenActive(vehicle)
    local st = getVehicleSirenState(vehicle)
    return (st ~= 0 and st ~= "0" and st ~= false)
end

function getVehicleAvailableStates(vehicle)
    if not isElement(vehicle) then return {} end
    local model = getElementModel(vehicle)
    local cfg = AVSRenderer and AVSRenderer.getModelConfig(model)
    if cfg and cfg.stateOrder then
        return cfg.stateOrder
    end
    return {}
end

function cycleVehicleSirenState(vehicle)
    if vehicle == getPedOccupiedVehicle(localPlayer) and getVehicleController(vehicle) == localPlayer then
        triggerServerEvent("avs:requestStateCycle", resourceRoot)
        return true
    end
    return false
end

function setVehicleSirenState(vehicle, newState)
    if not isElement(vehicle) then return false end
    if vehicle == getPedOccupiedVehicle(localPlayer) and getVehicleController(vehicle) == localPlayer then
        triggerServerEvent("avs:requestStateSet", resourceRoot, newState)
    end
    if nativeSetVehicleSirenState then
        return nativeSetVehicleSirenState(vehicle, newState)
    end
    return true
end

-- Ground reflection (siren shadow projection) control exports
function setVehicleSirenShadowsEnabled(vehicle, enabled)
    if not isElement(vehicle) then return false end
    if nativeSetVehicleSirenShadowsEnabled then
        nativeSetVehicleSirenShadowsEnabled(vehicle, enabled == true)
    end
    if AVSRenderer then
        AVSRenderer.setVehicleShadowsEnabled(vehicle, enabled == true)
    end
    return true
end

function isVehicleSirenShadowsEnabled(vehicle)
    if not isElement(vehicle) then return false end
    if nativeIsVehicleSirenShadowsEnabled then
        return nativeIsVehicleSirenShadowsEnabled(vehicle)
    end
    if AVSRenderer then
        return AVSRenderer.isVehicleShadowsEnabled(vehicle)
    end
    return getElementData(vehicle, "avs:shadows") ~= false
end

function setSirenShadowsEnabled(enabled)
    if nativeSetSirenShadowsEnabled then
        nativeSetSirenShadowsEnabled(enabled == true)
    end
    if AVSRenderer then
        AVSRenderer.setShadowsEnabled(enabled == true)
    end
    return true
end

function isSirenShadowsEnabled()
    if nativeIsSirenShadowsEnabled then
        return nativeIsSirenShadowsEnabled()
    end
    if AVSRenderer then
        return AVSRenderer.isShadowsEnabled()
    end
    return true
end

-- Console command to toggle shadows globally: /avsshadows [on/off] or /sirenshadows [on/off]
local function onShadowToggleCommand(_, stateArg)
    local newState = nil
    if stateArg == "on" or stateArg == "1" or stateArg == "true" then
        newState = true
    elseif stateArg == "off" or stateArg == "0" or stateArg == "false" then
        newState = false
    else
        newState = not isSirenShadowsEnabled()
    end
    setSirenShadowsEnabled(newState)
    outputChatBox("[AVS] Ground light reflections (siren shadows): " .. (newState and "Enabled" or "Disabled"), 0, 220, 255)
end

addCommandHandler("avsshadows", onShadowToggleCommand)
addCommandHandler("sirenshadows", onShadowToggleCommand)
