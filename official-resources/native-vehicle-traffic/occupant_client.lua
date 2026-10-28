local cohorts = {}
local function release(c)
    for ped, state in pairs(c.states) do
        if isElement(ped) then
            -- Only remove our walking baseline. An extraction is owned by
            -- MTA's ordinary vehicle protocol, not by this Lua task lease.
            if state.wander and isElementSyncer(ped) then killPedTask(ped, "primary", 3, false) end
            if state.profile then releasePedNativeEventProfile(state.profile) end
            setPedCanBeDraggedOut(ped, state.wasDraggable)
            setPedMissionActor(ped, state.wasMission)
        end
        if state.streaming then releaseElementStreamingLease(state.streaming) end
    end
    c.states = {}
    if c.vehicleLease then releaseElementStreamingLease(c.vehicleLease) end
    c.vehicleLease = nil
end

local function inVehicleTask(ped)
    for _, name in ipairs({"TASK_COMPLEX_CAR_SLOW_BE_DRAGGED_OUT_AND_STAND_UP", "TASK_COMPLEX_CAR_QUICK_BE_DRAGGED_OUT",
        "TASK_SIMPLE_BIKE_JACKED", "TASK_COMPLEX_LEAVE_CAR", "TASK_COMPLEX_ENTER_CAR_AS_DRIVER",
        "TASK_COMPLEX_ENTER_CAR_AS_PASSENGER", "TASK_COMPLEX_GET_UP_AND_STAND_STILL"}) do
        if isPedDoingTask(ped, name) then return true end
    end
    return false
end

addEvent("carOccupants:state", true)
addEventHandler("carOccupants:state", resourceRoot, function(id, epoch, owner, vehicle, peds, evacuate, response)
    local old = cohorts[id]
    if old and old.epoch >= epoch then return end
    if old then release(old) end
    cohorts[id] = {id = id, epoch = epoch, owner = owner, vehicle = vehicle, peds = peds, evacuate = evacuate, states = {}, response = response, responsePending = type(response) == "table" and #response > 0}
end)

addEvent("carOccupants:revoke", true)
addEventHandler("carOccupants:revoke", resourceRoot, function(id, epoch)
    local c = cohorts[id]
    if not c or c.epoch ~= epoch or c.owner ~= localPlayer then return end
    local ped = c.peds[1]
    local s = c.states[ped]
    local response = c.response or false
    if s and s.profile and isElement(ped) and isElementSyncer(ped) and isPedNativeEventProfileActive(ped, s.profile) then
        response = getPedNativeVehicleResponse(ped, s.profile)
    end
    release(c)
    c.revoked = true
    triggerServerEvent("carOccupants:released", resourceRoot, id, epoch, response)
end)

addEvent("carOccupants:stop", true)
addEventHandler("carOccupants:stop", resourceRoot, function(id, epoch)
    local c = cohorts[id]
    if not c or c.epoch > epoch then return end
    release(c)
    cohorts[id] = nil
end)

setTimer(function()
    for _, c in pairs(cohorts) do
        if not c.revoked then
            local ready = true
            if c.owner == localPlayer and isElement(c.vehicle) and not c.vehicleLease then
                c.vehicleLease = acquireElementStreamingLease(c.vehicle)
            end
            for _, ped in ipairs(c.peds) do
                if isElement(ped) then
                    local s = c.states[ped]
                    if not s then
                        s = {wasMission = isPedMissionActor(ped), wasDraggable = canPedBeDraggedOut(ped)}
                        c.states[ped] = s
                        setPedMissionActor(ped, false)
                        setPedCanBeDraggedOut(ped, true)
                        s.profile = acquirePedNativeEventProfile(ped, "ambient-wander")
                        if c.owner == localPlayer then s.streaming = acquireElementStreamingLease(ped) end
                    end
                    if not s.profile then s.profile = acquirePedNativeEventProfile(ped, "ambient-wander") end
                    if c.owner == localPlayer and not s.streaming then s.streaming = acquireElementStreamingLease(ped) end
                    if c.owner == localPlayer and not isPedDead(ped) then
                        local active = s.profile and s.streaming and isElementSyncer(ped) and isElementStreamedIn(ped)
                            and isPedNativeEventProfileActive(ped, s.profile)
                        if active and c.responsePending then
                            -- Restore only while native response slots are empty;
                            -- a new local event must always win over old history.
                            local current = getPedNativeVehicleResponse(ped, s.profile)
                            if type(current) ~= "table" or #current > 0 or restorePedNativeVehicleResponse(ped, c.response, s.profile) then
                                c.responsePending = false
                            else
                                c.restoreStarted = c.restoreStarted or getTickCount()
                                if getTickCount() - c.restoreStarted > 3000 then
                                    outputDebugString("[carOccupants] response restore unavailable id=" .. c.id, 2)
                                    c.responsePending = false
                                end
                            end
                        end
                        if not active or c.responsePending then ready = false
                        elseif c.evacuate and getPedOccupiedVehicle(ped) and not inVehicleTask(ped) then
                            if not s.exitRequested then s.exitRequested = setPedExitVehicle(ped) == true end
                        elseif not getPedOccupiedVehicle(ped) and not inVehicleTask(ped) and not s.wander then
                            -- setPedWander is a script-command event: retail
                            -- 0x4BA844 clears BOTH response slots. Only dispatch
                            -- it once native reactions have actually finished.
                            local remaining = getPedNativeVehicleResponse(ped, s.profile)
                            if type(remaining) == "table" and #remaining == 0 then
                                s.wander = setPedWander(ped, "walk", 0, true) == true
                            end
                        end
                    end
                else ready = false end
            end
            if c.owner == localPlayer and ready and not c.responsePending and getTickCount() - (c.lastResponseAt or -500) >= 500 then
                local ped = c.peds[1]
                local s = c.states[ped]
                if s and s.profile and isElement(ped) and not isPedDead(ped) then
                    c.response = getPedNativeVehicleResponse(ped, s.profile)
                    triggerServerEvent("carOccupants:response", resourceRoot, c.id, c.epoch, c.response)
                    c.lastResponseAt = getTickCount()
                end
            end
            if c.owner == localPlayer and not c.accepted and getTickCount() - (c.lastDiagnostic or -2000) >= 2000 then
                c.lastDiagnostic = getTickCount()
                local ped = c.peds[1]
                local s = c.states[ped]
                if isElement(ped) and VehicleTrafficTransport and VehicleTrafficTransport.diagnosticsEnabled then
                    triggerServerEvent("carTraffic:clientDiagnostic", resourceRoot, c.id, c.epoch, "occupant-readiness", {
                        ready = ready, streamed = isElementStreamedIn(ped), syncer = isElementSyncer(ped),
                        lease = s and s.streaming ~= nil, profile = s and s.profile ~= nil,
                        active = s and s.profile and isPedNativeEventProfileActive(ped, s.profile),
                        mission = isPedMissionActor(ped), draggable = canPedBeDraggedOut(ped),
                        seat = getPedOccupiedVehicleSeat(ped), physical = {getPedTask(ped, "primary", 0)},
                        primary = {getPedTask(ped, "primary", 3)}, response = {getPedTask(ped, "primary", 2)},
                    })
                end
            end
            if c.owner == localPlayer and ready and not c.accepted then
                c.accepted = true
                triggerServerEvent("carOccupants:accepted", resourceRoot, c.id, c.epoch)
            end
        end
    end
end, 100, 0)

addEventHandler("onClientResourceStart", resourceRoot, function()
    triggerServerEvent("carOccupants:ready", resourceRoot)
end)
addEventHandler("onClientResourceStop", resourceRoot, function()
    for _, c in pairs(cohorts) do release(c) end
end)

local function cohortFor(ped)
    for _, c in pairs(cohorts) do if c.peds[1] == ped then return c end end
end
local function observeDamage(attacker, weapon, bodypart, factor, direction)
    local c = cohortFor(attacker)
    local s = c and c.states[attacker]
    if source == localPlayer or getElementType(source) ~= "player" or weapon ~= 0
        or not c or c.revoked or not c.accepted or c.owner ~= localPlayer or not isElementSyncer(attacker)
        or not s or not s.profile or not isPedNativeEventProfileActive(attacker, s.profile) then return end
    c.damageNonce = (c.damageNonce or 0) + 1
    triggerServerEvent("carOccupants:damageObserved", resourceRoot, c.id, c.epoch, source, c.damageNonce, bodypart, factor, direction)
end
addEventHandler("onClientPlayerNativeDamageAttempt", root, observeDamage)
addEvent("carOccupants:damage", true)
addEventHandler("carOccupants:damage", resourceRoot, function(id, epoch, nonce, bodypart, factor, direction)
    local c = cohorts[id]
    local ped = c and c.peds[1]
    local s = c and c.states[ped]
    if not c or c.epoch ~= epoch or c.revoked or not isElement(ped) or isElementSyncer(ped)
        or nonce <= (c.damageReceipt or 0) or not s or not s.profile then return end
    c.damageReceipt = nonce
    addPedNativeDamageEvent(localPlayer, ped, 0, bodypart, factor, direction, s.profile)
end)

-- The regular MTA health packet remains authoritative for incoming hits.
-- Only supply a missing personality response on the victim's current owner.
addEventHandler("onClientPedDamage", root, function(attacker, weapon, bodypart)
    local c = cohortFor(source)
    if not c or c.revoked or weapon ~= 0 or not isElement(attacker) then return end
    if isElementSyncer(source) then
        c.localHits = c.localHits or {}
        c.localHits[attacker] = {at = getTickCount(), bodypart = bodypart}
    elseif attacker == localPlayer then
        c.hitNonce = (c.hitNonce or 0) + 1
        triggerServerEvent("carOccupants:hitObserved", resourceRoot, c.id, c.epoch, c.hitNonce, bodypart)
    end
end)
addEvent("carOccupants:hit", true)
addEventHandler("carOccupants:hit", resourceRoot, function(id, epoch, attacker, nonce, bodypart)
    local c = cohorts[id]
    if not c or c.epoch ~= epoch or c.revoked or c.owner ~= localPlayer then return end
    c.hitReceipts = c.hitReceipts or {}
    if nonce <= (c.hitReceipts[attacker] or 0) then return end
    c.hitReceipts[attacker] = nonce
    setTimer(function()
        local ped = c.peds[1]
        local s = c.states[ped]
        if cohorts[id] ~= c or c.revoked or not isElement(ped) or not isElement(attacker) or isPedDead(ped)
            or not isElementSyncer(ped) or not s or not s.profile or not isPedNativeEventProfileActive(ped, s.profile) then return end
        local observed = c.localHits and c.localHits[attacker]
        if observed and observed.bodypart == bodypart and getTickCount() - observed.at < 1000 then
            c.localHits[attacker] = nil
            return
        end
        addPedNativeDamageResponseEvent(ped, attacker, 0, bodypart, s.profile)
    end, 100, 1)
end)
