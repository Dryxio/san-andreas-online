--[[
    Advanced Vehicle Sirens (AVS) - Client Controls, Keybinds & API
    
    Provides:
    - Automatic state listener for 'avs:state' element data
    - In-vehicle driver keybinds (R to cycle states, L to mute, 1/2/3 direct jump)
    - Sound and UI notifications
    - Client-side exported functions
]]

-- Update renderer whenever vehicle state changes
addEventHandler("onClientElementDataChange", root, function(key, oldValue, newValue)
    if key == "avs:state" and getElementType(source) == "vehicle" then
        AVSRenderer.setVehicleState(source, newValue)
    end
end)

-- Initialize state for newly streamed in vehicles
addEventHandler("onClientElementStreamIn", root, function()
    if getElementType(source) == "vehicle" then
        local st = getElementData(source, "avs:state")
        if st and st ~= 0 and st ~= "0" then
            AVSRenderer.setVehicleState(source, st)
        end
    end
end)

-- Keybind handlers for driver
local function onCycleStateKey()
    local veh = getPedOccupiedVehicle(localPlayer)
    if veh and getVehicleController(veh) == localPlayer then
        triggerServerEvent("avs:requestStateCycle", resourceRoot)
    end
end

local function onMuteKey()
    local veh = getPedOccupiedVehicle(localPlayer)
    if veh and getVehicleController(veh) == localPlayer then
        triggerServerEvent("avs:requestMuteToggle", resourceRoot)
    end
end

-- Commands for direct state jumps and binds
addCommandHandler("avs", function(_, stateArg)
    local veh = getPedOccupiedVehicle(localPlayer)
    if veh and getVehicleController(veh) == localPlayer then
        if not stateArg or stateArg == "" or stateArg == "cycle" then
            triggerServerEvent("avs:requestStateCycle", resourceRoot)
        else
            local target = tonumber(stateArg) or stateArg
            triggerServerEvent("avs:requestStateSet", resourceRoot, target)
        end
    end
end)

addCommandHandler("sirenstate", onCycleStateKey)
addCommandHandler("sirenmute", onMuteKey)

-- Bind default AVS keys on player vehicle enter
addEventHandler("onClientPlayerVehicleEnter", localPlayer, function(veh, seat)
    if seat == 0 then
        bindKey("r", "down", onCycleStateKey)
        bindKey("l", "down", onMuteKey)
    end
end)

addEventHandler("onClientPlayerVehicleExit", localPlayer, function(veh, seat)
    if seat == 0 then
        unbindKey("r", "down", onCycleStateKey)
        unbindKey("l", "down", onMuteKey)
    end
end)

-- Re-bind if resource started while already inside a vehicle
addEventHandler("onClientResourceStart", resourceRoot, function()
    local veh = getPedOccupiedVehicle(localPlayer)
    if veh and getVehicleController(veh) == localPlayer then
        bindKey("r", "down", onCycleStateKey)
        bindKey("l", "down", onMuteKey)
    end
end)

-- Client Exported Functions
function getVehicleSirenState(vehicle)
    if not isElement(vehicle) then return 0 end
    return AVSRenderer.getVehicleState(vehicle)
end

function isVehicleSirenActive(vehicle)
    local st = getVehicleSirenState(vehicle)
    return (st ~= 0 and st ~= "0" and st ~= false)
end

function getVehicleAvailableStates(vehicle)
    if not isElement(vehicle) then return {} end
    local model = getElementModel(vehicle)
    local cfg = AVSRenderer.getModelConfig(model)
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
    if vehicle == getPedOccupiedVehicle(localPlayer) and getVehicleController(vehicle) == localPlayer then
        triggerServerEvent("avs:requestStateSet", resourceRoot, newState)
        return true
    end
    return false
end
