--[[
    Advanced Vehicle Sirens (AVS) - Server State Manager & Synchronization
    
    Synchronizes:
    - Active siren state per vehicle (Off / State 1 / State 2 / State 3)
    - Siren audio mute flag
    - Dynamic model configurations across connected clients
    - Driver keybinds and commands
]]

local serverModelConfigs = {}
local serverVehicleStates = {}
local serverVehicleMuted = {}

-- Load configs on server startup
addEventHandler("onResourceStart", resourceRoot, function()
    if fileExists("configs/554.json") then
        local hFile = fileOpen("configs/554.json", true)
        if hFile then
            local size = fileGetSize(hFile)
            local content = fileRead(hFile, size)
            fileClose(hFile)

            local parsed = AVSParser.parse(content)
            if parsed then
                serverModelConfigs[554] = parsed
                outputServerLog("[AVS] Server registered model 554 configuration with " ..
                    tostring(#parsed.stateOrder) .. " states.")
            end
        end
    end
end)

-- Send registered configs to joining players
addEventHandler("onPlayerResourceStart", root, function(res)
    if res == resourceRoot then
        for modelId, cfg in pairs(serverModelConfigs) do
            triggerClientEvent(source, "avs:registerModelConfig", resourceRoot, modelId, cfg)
        end
    end
end)

-- Set vehicle siren state
function setVehicleSirenState(vehicle, state)
    if not isElement(vehicle) or getElementType(vehicle) ~= "vehicle" then
        return false
    end

    local model = getElementModel(vehicle)
    local cfg = serverModelConfigs[model]
    local targetState = 0

    if state == 0 or state == "0" or state == "off" or state == false or state == nil then
        targetState = 0
    else
        -- Accept numeric index or state name string
        if type(state) == "number" and cfg and cfg.stateOrder and cfg.stateOrder[state] then
            targetState = cfg.stateOrder[state]
        else
            targetState = tostring(state)
        end
    end

    serverVehicleStates[vehicle] = targetState
    setElementData(vehicle, "avs:state", targetState, true)

    -- Native GTA siren sound control
    if targetState == 0 then
        setVehicleSirensOn(vehicle, false)
    else
        if not serverVehicleMuted[vehicle] then
            setVehicleSirensOn(vehicle, true)
        else
            setVehicleSirensOn(vehicle, false)
        end
    end

    return true
end

-- Get vehicle siren state
function getVehicleSirenState(vehicle)
    if not isElement(vehicle) then return 0 end
    return serverVehicleStates[vehicle] or getElementData(vehicle, "avs:state") or 0
end

-- Cycle vehicle siren state (Off -> State 1 -> State 2 -> ... -> Off)
function cycleVehicleSirenState(vehicle)
    if not isElement(vehicle) then return false end
    local model = getElementModel(vehicle)
    local cfg = serverModelConfigs[model]
    if not cfg or not cfg.stateOrder or #cfg.stateOrder == 0 then
        return false
    end

    local current = getVehicleSirenState(vehicle)
    local nextState = 0

    if current == 0 or current == "0" then
        nextState = cfg.stateOrder[1]
    else
        local foundIdx = 0
        for i, sName in ipairs(cfg.stateOrder) do
            if sName == current then
                foundIdx = i
                break
            end
        end

        if foundIdx > 0 and foundIdx < #cfg.stateOrder then
            nextState = cfg.stateOrder[foundIdx + 1]
        else
            nextState = 0 -- Loop back to Off
        end
    end

    return setVehicleSirenState(vehicle, nextState)
end

-- Set vehicle siren audio mute
function setVehicleSirenMuted(vehicle, muted)
    if not isElement(vehicle) then return false end
    local isMuted = muted and true or false
    serverVehicleMuted[vehicle] = isMuted
    setElementData(vehicle, "avs:muted", isMuted, true)

    local currentState = getVehicleSirenState(vehicle)
    if currentState ~= 0 and currentState ~= "0" then
        setVehicleSirensOn(vehicle, not isMuted)
    end
    return true
end

-- Is vehicle siren audio muted
function isVehicleSirenMuted(vehicle)
    if not isElement(vehicle) then return false end
    return serverVehicleMuted[vehicle] or false
end

-- Register model config dynamically
function registerVehicleSirenModel(modelId, configInput)
    local parsed = nil
    if type(configInput) == "string" then
        parsed = AVSParser.parse(configInput)
    elseif type(configInput) == "table" then
        if configInput.states and configInput.stateOrder then
            parsed = configInput
        else
            parsed = AVSParser.parse(configInput)
        end
    end

    if not parsed or not tonumber(modelId) then
        return false
    end

    local mId = tonumber(modelId)
    serverModelConfigs[mId] = parsed
    triggerClientEvent(root, "avs:registerModelConfig", resourceRoot, mId, parsed)
    return true
end

-- Unregister model config
function unregisterVehicleSirenModel(modelId)
    local mId = tonumber(modelId)
    serverModelConfigs[mId] = nil
    return true
end

-- Handle requests from driver client
addEvent("avs:requestStateCycle", true)
addEventHandler("avs:requestStateCycle", root, function()
    local veh = getPedOccupiedVehicle(client)
    if veh and getVehicleController(veh) == client then
        cycleVehicleSirenState(veh)
    end
end)

addEvent("avs:requestStateSet", true)
addEventHandler("avs:requestStateSet", root, function(targetState)
    local veh = getPedOccupiedVehicle(client)
    if veh and getVehicleController(veh) == client then
        setVehicleSirenState(veh, targetState)
    end
end)

addEvent("avs:requestMuteToggle", true)
addEventHandler("avs:requestMuteToggle", root, function()
    local veh = getPedOccupiedVehicle(client)
    if veh and getVehicleController(veh) == client then
        local current = isVehicleSirenMuted(veh)
        setVehicleSirenMuted(veh, not current)
    end
end)

-- Clean up on vehicle destruction
addEventHandler("onElementDestroy", root, function()
    if getElementType(source) == "vehicle" then
        serverVehicleStates[source] = nil
        serverVehicleMuted[source] = nil
    end
end)
