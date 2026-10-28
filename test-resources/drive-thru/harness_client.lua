local harness = {
    runId = nil,
    profile = nil,
    leader = nil,
    keyProbe = nil,
    timers = {},
}

local function rememberTimer(timer)
    harness.timers[timer] = true
    return timer
end

local function forgetTimer(timer)
    harness.timers[timer] = nil
end

local function clearTimers()
    for timer in pairs(harness.timers) do
        if isTimer(timer) then
            killTimer(timer)
        end
    end
    harness.timers = {}
    harness.keyProbe = nil
end

local function trace(event, data)
    local record = type(data) == "table" and data or {}
    record.event = event
    record.runId = harness.runId
    record.profile = harness.profile
    record.player = getPlayerName(localPlayer)
    outputDebugString("[drive-thru-transition-jsonl] " .. tostring(toJSON(record, true)):gsub("[\r\n]", ""))
end

local function cameraTargetsLocalPlayer()
    return getCameraTarget() == localPlayer
end

local function cameraTargetsLocalGameplay()
    local target = getCameraTarget()
    local vehicle = getPedOccupiedVehicle(localPlayer)
    -- GTA's normal follow camera retargets the occupied vehicle once the
    -- player has become its driver. Both forms are local gameplay ownership;
    -- any remote element or scripted matrix still fails this proof.
    return target == localPlayer or isElement(vehicle) and target == vehicle
end

local function beginInputProbe(runId, probeId, checkpoint, vehicle, waitStartedAt)
    if tonumber(runId) ~= harness.runId or not isElement(vehicle) or getElementType(vehicle) ~= "vehicle" then
        return
    end
    waitStartedAt = tonumber(waitStartedAt) or getTickCount()
    local occupied = getPedOccupiedVehicle(localPlayer) == vehicle
    local seat = occupied and getPedOccupiedVehicleSeat(localPlayer) or -1
    local streamed = isElementStreamedIn(vehicle)
    local wheels = streamed and isVehicleOnAllWheels(vehicle)
    local reason
    if not occupied then
        reason = "leader is outside the expected Greenwood"
    elseif seat ~= 0 then
        reason = "leader is not the Greenwood driver"
    elseif not streamed then
        reason = "Greenwood is not streamed"
    elseif isElementFrozen(localPlayer) or isElementFrozen(vehicle) then
        reason = "player or Greenwood is frozen"
    elseif not getElementCollisionsEnabled(vehicle) then
        reason = "Greenwood collisions are disabled"
    elseif not cameraTargetsLocalGameplay() then
        reason = "camera is not returned to local gameplay"
    elseif not isControlEnabled("accelerate") then
        reason = "gameplay controls are disabled"
    elseif not wheels then
        reason = "Greenwood is not on all wheels"
    end
    if reason and getTickCount() - waitStartedAt < 8000 then
        local timer
        timer = rememberTimer(setTimer(function()
            forgetTimer(timer)
            beginInputProbe(runId, probeId, checkpoint, vehicle, waitStartedAt)
        end, 50, 1))
        return
    end
    if reason then
        local evidence = {cameraLocal = cameraTargetsLocalPlayer(), cameraLocalDuringInput = false,
                          occupied = occupied, seat = seat, streamed = streamed,
                          onAllWheels = wheels, keyObserved = false, raw = 0, processed = 0, samples = 0, displacement = 0}
        trace("INPUT_FAIL", {probeId = probeId, checkpoint = checkpoint, reason = reason})
        return triggerServerEvent("drivethru:harnessInputDone", resourceRoot, runId, probeId, checkpoint, false, reason, evidence)
    end

    local startX, startY, startZ = getElementPosition(vehicle)
    local streamedAtStart = streamed
    local startedAt = getTickCount()
    local maxRaw, maxProcessed, maxDisplacement, samples = 0, 0, 0, 0
    local keyProbe = {probeId = tonumber(probeId), keyObserved = false}
    harness.keyProbe = keyProbe
    trace("INPUT_READY", {probeId = probeId, checkpoint = checkpoint, control = "accelerate", key = "w"})
    outputDebugString(("[drive-thru-transition] INPUT_READY checkpoint=%s player=%s key=w control=accelerate"):format(
                          tostring(checkpoint), getPlayerName(localPlayer)))
    triggerServerEvent("drivethru:harnessInputReady", resourceRoot, runId, probeId, checkpoint, "accelerate")

    local timer
    timer = rememberTimer(setTimer(function()
        if tonumber(runId) ~= harness.runId or harness.keyProbe ~= keyProbe then
            if isTimer(timer) then
                killTimer(timer)
            end
            forgetTimer(timer)
            return
        end
        if not isElement(vehicle) or getPedOccupiedVehicle(localPlayer) ~= vehicle or getPedOccupiedVehicleSeat(localPlayer) ~= 0 then
            killTimer(timer)
            forgetTimer(timer)
            harness.keyProbe = nil
            local transitioned = checkpoint == "restaurant" and keyProbe.keyObserved and maxRaw > 0.8 and maxProcessed > 0.8 and
                                   samples >= 3 and maxDisplacement > 0.5
            local evidence = {cameraLocal = cameraTargetsLocalPlayer(), cameraLocalDuringInput = samples > 0,
                              occupied = false, occupiedAtStart = true, seat = -1, streamed = false,
                              streamedAtStart = streamedAtStart, transitionAfterInput = transitioned,
                              onAllWheels = false, keyObserved = keyProbe.keyObserved, raw = maxRaw,
                              processed = maxProcessed, samples = samples, displacement = maxDisplacement}
            local transitionReason = transitioned and "physical gate transition observed" or
                                         "Greenwood occupancy was lost during physical input"
            return triggerServerEvent("drivethru:harnessInputDone", resourceRoot, runId, probeId, checkpoint, transitioned,
                                      transitionReason, evidence)
        end
        local raw = tonumber(getAnalogControlState("accelerate", true)) or 0
        local processed = tonumber(getAnalogControlState("accelerate", false)) or 0
        if getKeyState("w") == true then
            keyProbe.keyObserved = true
        end
        maxRaw = math.max(maxRaw, raw)
        maxProcessed = math.max(maxProcessed, processed)
        local x, y, z = getElementPosition(vehicle)
        maxDisplacement = math.max(maxDisplacement, getDistanceBetweenPoints3D(x, y, z, startX, startY, startZ))
        if raw > 0.8 and processed > 0.8 and cameraTargetsLocalGameplay() then
            samples = samples + 1
        end
        if keyProbe.keyObserved and samples >= 3 and maxDisplacement > 0.5 then
            killTimer(timer)
            forgetTimer(timer)
            harness.keyProbe = nil
            local cameraLocal = cameraTargetsLocalGameplay()
            local onAllWheels = isVehicleOnAllWheels(vehicle)
            local ok = onAllWheels
            local probeReason = ok and "physical input observed" or "Greenwood left its wheels"
            local evidence = {cameraLocal = cameraLocal, cameraLocalDuringInput = true, occupied = true, seat = 0,
                              streamed = isElementStreamedIn(vehicle),
                              occupiedAtStart = true, streamedAtStart = streamedAtStart,
                              onAllWheels = onAllWheels, keyObserved = true, raw = maxRaw, processed = maxProcessed,
                              samples = samples, displacement = maxDisplacement}
            trace(ok and "INPUT_PASS" or "INPUT_FAIL", {probeId = probeId, checkpoint = checkpoint, reason = probeReason,
                                                         raw = maxRaw, processed = maxProcessed, samples = samples,
                                                         displacement = maxDisplacement, keyObserved = true})
            return triggerServerEvent("drivethru:harnessInputDone", resourceRoot, runId, probeId, checkpoint, ok,
                                      probeReason, evidence)
        end
        if getTickCount() - startedAt >= 60000 then
            killTimer(timer)
            forgetTimer(timer)
            harness.keyProbe = nil
            local evidence = {cameraLocal = cameraTargetsLocalGameplay(), cameraLocalDuringInput = samples > 0,
                              occupied = true, seat = 0,
                              streamed = isElementStreamedIn(vehicle), onAllWheels = isVehicleOnAllWheels(vehicle),
                              keyObserved = keyProbe.keyObserved, raw = maxRaw, processed = maxProcessed,
                              samples = samples, displacement = maxDisplacement}
            trace("INPUT_FAIL", {probeId = probeId, checkpoint = checkpoint, reason = "physical W was not observed",
                                  raw = maxRaw, processed = maxProcessed, samples = samples,
                                  displacement = maxDisplacement, keyObserved = keyProbe.keyObserved})
            triggerServerEvent("drivethru:harnessInputDone", resourceRoot, runId, probeId, checkpoint, false,
                               "physical W was not observed", evidence)
        end
    end, 50, 0))
end

local function beginEntryProbe(runId, probeId, vehicle, waitStartedAt)
    if tonumber(runId) ~= harness.runId or not isElement(vehicle) or getElementType(vehicle) ~= "vehicle" then
        return
    end
    waitStartedAt = tonumber(waitStartedAt) or getTickCount()
    local streamed = isElementStreamedIn(vehicle)
    local reason
    if getPedOccupiedVehicle(localPlayer) then
        reason = "leader is already in a vehicle"
    elseif not streamed then
        reason = "Greenwood is not streamed"
    elseif isElementFrozen(localPlayer) or isElementFrozen(vehicle) then
        reason = "player or Greenwood is frozen"
    elseif not cameraTargetsLocalGameplay() then
        reason = "camera is not returned to local gameplay"
    elseif not isControlEnabled("enter_exit") then
        reason = "entry control is disabled"
    end
    if reason and getTickCount() - waitStartedAt < 8000 then
        local timer
        timer = rememberTimer(setTimer(function()
            forgetTimer(timer)
            beginEntryProbe(runId, probeId, vehicle, waitStartedAt)
        end, 50, 1))
        return
    end
    if reason then
        local evidence = {cameraLocalDuringInput = false, occupied = false, seat = -1, streamed = streamed,
                          onAllWheels = false, keyObserved = false, raw = 0, processed = 0, samples = 0, displacement = 0}
        trace("INPUT_FAIL", {probeId = probeId, checkpoint = "entry", reason = reason})
        return triggerServerEvent("drivethru:harnessInputDone", resourceRoot, runId, probeId, "entry", false, reason, evidence)
    end

    local startedAt = getTickCount()
    local maxRaw, maxProcessed = 0, 0
    local keyProbe = {probeId = tonumber(probeId), key = "f", keyObserved = false}
    harness.keyProbe = keyProbe
    trace("INPUT_READY", {probeId = probeId, checkpoint = "entry", control = "enter_exit", key = "f"})
    outputDebugString(("[drive-thru-transition] INPUT_READY checkpoint=entry player=%s key=f control=enter_exit"):format(
                          getPlayerName(localPlayer)))
    triggerServerEvent("drivethru:harnessInputReady", resourceRoot, runId, probeId, "entry", "enter_exit")

    local timer
    timer = rememberTimer(setTimer(function()
        if tonumber(runId) ~= harness.runId or harness.keyProbe ~= keyProbe then
            if isTimer(timer) then
                killTimer(timer)
            end
            forgetTimer(timer)
            return
        end
        local raw = tonumber(getAnalogControlState("enter_exit", true)) or 0
        local processed = tonumber(getAnalogControlState("enter_exit", false)) or 0
        maxRaw = math.max(maxRaw, raw)
        maxProcessed = math.max(maxProcessed, processed)
        if getKeyState("f") == true then
            keyProbe.keyObserved = true
        end
        local occupied = getPedOccupiedVehicle(localPlayer) == vehicle
        local seat = occupied and getPedOccupiedVehicleSeat(localPlayer) or -1
        if keyProbe.keyObserved and occupied and seat == 0 and cameraTargetsLocalGameplay() then
            killTimer(timer)
            forgetTimer(timer)
            harness.keyProbe = nil
            local evidence = {cameraLocalDuringInput = cameraTargetsLocalGameplay(), occupied = true, seat = 0,
                              streamed = isElementStreamedIn(vehicle), onAllWheels = isVehicleOnAllWheels(vehicle),
                              keyObserved = true, raw = maxRaw, processed = maxProcessed, samples = 1, displacement = 0}
            trace("INPUT_PASS", {probeId = probeId, checkpoint = "entry", raw = maxRaw, processed = maxProcessed,
                                  keyObserved = true, occupied = true, seat = 0})
            return triggerServerEvent("drivethru:harnessInputDone", resourceRoot, runId, probeId, "entry", true,
                                      "physical entry observed", evidence)
        end
        if getTickCount() - startedAt >= 30000 then
            killTimer(timer)
            forgetTimer(timer)
            harness.keyProbe = nil
            local evidence = {cameraLocalDuringInput = cameraTargetsLocalGameplay(), occupied = occupied, seat = seat,
                              streamed = isElementStreamedIn(vehicle), onAllWheels = isVehicleOnAllWheels(vehicle),
                              keyObserved = keyProbe.keyObserved, raw = maxRaw, processed = maxProcessed,
                              samples = 0, displacement = 0}
            trace("INPUT_FAIL", {probeId = probeId, checkpoint = "entry", reason = "physical F entry was not observed",
                                  raw = maxRaw, processed = maxProcessed, keyObserved = keyProbe.keyObserved,
                                  occupied = occupied, seat = seat})
            triggerServerEvent("drivethru:harnessInputDone", resourceRoot, runId, probeId, "entry", false,
                               "physical F entry was not observed", evidence)
        end
    end, 50, 0))
end

local function reconstructionEvidence(entities)
    local greenwood, voodoo = entities.vehicle, entities.voodoo
    if not isElement(greenwood) or not isElement(voodoo) then
        return false, "pursuit vehicles unavailable"
    end
    local required = {greenwood, voodoo, entities.smoke, entities.sweet, entities.ryder, entities.ballas_driver}
    for _, element in ipairs(required) do
        if not isElement(element) or not isElementStreamedIn(element) then
            return false, "a reconstructed element is not streamed"
        end
    end
    local greenwoodCount, voodooCount = 0, 0
    for _, vehicle in ipairs(getElementsByType("vehicle")) do
        local role = getElementData(vehicle, DRIVETHRU.vehicleRoleData)
        if role == "greenwood" then
            greenwoodCount = greenwoodCount + 1
        elseif role == "voodoo" then
            voodooCount = voodooCount + 1
        end
    end
    local health = getElementHealth(voodoo)
    if greenwoodCount ~= 1 or voodooCount ~= 1 then
        return false, ("vehicle uniqueness greenwood=%d voodoo=%d"):format(greenwoodCount, voodooCount),
               {greenwoodCount = greenwoodCount, voodooCount = voodooCount, health = health}
    end
    if math.abs(health - DRIVETHRU.restaurant.voodoo.health) > 0.01 then
        return false, ("Voodoo health expected=2700 actual=%.3f"):format(health),
               {greenwoodCount = greenwoodCount, voodooCount = voodooCount, health = health}
    end
    local expectedSeats = {[harness.leader] = 0, [entities.smoke] = 3, [entities.sweet] = 2, [entities.ryder] = 1}
    for ped, seat in pairs(expectedSeats) do
        if getPedOccupiedVehicle(ped) ~= greenwood or getPedOccupiedVehicleSeat(ped) ~= seat then
            return false, ("Greenwood seat mismatch expected=%d"):format(seat),
                   {greenwoodCount = greenwoodCount, voodooCount = voodooCount, health = health}
        end
    end
    if getPedOccupiedVehicle(entities.ballas_driver) ~= voodoo or getPedOccupiedVehicleSeat(entities.ballas_driver) ~= 0 then
        return false, "Ballas driver seat mismatch",
               {greenwoodCount = greenwoodCount, voodooCount = voodooCount, health = health}
    end
    return true, "stable", {greenwoodCount = greenwoodCount, voodooCount = voodooCount, health = health}
end

local function beginReconstructionProbe(runId, entities, startedAt, stableSamples)
    if tonumber(runId) ~= harness.runId or type(entities) ~= "table" then
        return
    end
    startedAt = tonumber(startedAt) or getTickCount()
    stableSamples = tonumber(stableSamples) or 0
    local ok, reason, evidence = reconstructionEvidence(entities)
    if ok then
        stableSamples = stableSamples + 1
        if stableSamples >= 3 then
            evidence.samples = stableSamples
            trace("RECONSTRUCTION_CLIENT_PASS", evidence)
            return triggerServerEvent("drivethru:harnessReconstructionDone", resourceRoot, runId, true, "stable", evidence)
        end
    else
        stableSamples = 0
    end
    if getTickCount() - startedAt >= 10000 then
        evidence = evidence or {}
        evidence.samples = stableSamples
        trace("RECONSTRUCTION_CLIENT_FAIL", {reason = reason, health = evidence.health,
                                               greenwoodCount = evidence.greenwoodCount, voodooCount = evidence.voodooCount})
        return triggerServerEvent("drivethru:harnessReconstructionDone", resourceRoot, runId, false, reason, evidence)
    end
    local timer
    timer = rememberTimer(setTimer(function()
        forgetTimer(timer)
        beginReconstructionProbe(runId, entities, startedAt, stableSamples)
    end, 100, 1))
end

local function cleanupEvidence()
    local cameraLocal = cameraTargetsLocalPlayer()
    local controls = isControlEnabled("accelerate") and isControlEnabled("forwards") and isControlEnabled("enter_exit")
    local missionElements = 0
    for _, elementType in ipairs({"vehicle", "ped"}) do
        for _, element in ipairs(getElementsByType(elementType)) do
            if getElementDimension(element) == DRIVETHRU.dimension and
                (getElementData(element, DRIVETHRU.missionActorData) == true or
                    type(getElementData(element, DRIVETHRU.vehicleRoleData)) == "string") then
                missionElements = missionElements + 1
            end
        end
    end
    return cameraLocal and controls and missionElements == 0,
           {cameraLocal = cameraLocal, controls = controls, missionElements = missionElements}
end

local function beginCleanupProbe(runId, startedAt)
    if tonumber(runId) ~= harness.runId then
        return
    end
    startedAt = tonumber(startedAt) or getTickCount()
    local ok, evidence = cleanupEvidence()
    if ok or getTickCount() - startedAt >= 5000 then
        local reason = ok and "clean" or ("camera=%s controls=%s missionElements=%d"):format(
                                             tostring(evidence.cameraLocal), tostring(evidence.controls), evidence.missionElements)
        trace(ok and "CLEANUP_CLIENT_PASS" or "CLEANUP_CLIENT_FAIL", evidence)
        triggerServerEvent("drivethru:harnessCleanupDone", resourceRoot, runId, ok, reason, evidence)
        if ok then
            clearTimers()
            harness.runId = nil
            harness.profile = nil
            harness.leader = nil
        end
        return
    end
    local timer
    timer = rememberTimer(setTimer(function()
        forgetTimer(timer)
        beginCleanupProbe(runId, startedAt)
    end, 100, 1))
end

addEvent("drivethru:harnessStart", true)
addEventHandler("drivethru:harnessStart", resourceRoot, function(runId, profile, leader)
    if source ~= resourceRoot or not isElement(leader) then
        return
    end
    clearTimers()
    harness.runId = tonumber(runId)
    harness.profile = tostring(profile)
    harness.leader = leader
    trace("CLIENT_START", {leader = getPlayerName(leader)})
end)

addEvent("drivethru:harnessInputProbe", true)
addEventHandler("drivethru:harnessInputProbe", resourceRoot, function(runId, probeId, checkpoint, vehicle)
    if source == resourceRoot then
        beginInputProbe(runId, probeId, tostring(checkpoint), vehicle, getTickCount())
    end
end)

addEvent("drivethru:harnessEntryProbe", true)
addEventHandler("drivethru:harnessEntryProbe", resourceRoot, function(runId, probeId, vehicle)
    if source == resourceRoot then
        beginEntryProbe(runId, probeId, vehicle, getTickCount())
    end
end)

addEvent("drivethru:harnessReconstructionProbe", true)
addEventHandler("drivethru:harnessReconstructionProbe", resourceRoot, function(runId, entities)
    if source == resourceRoot then
        beginReconstructionProbe(runId, entities, getTickCount(), 0)
    end
end)

addEvent("drivethru:harnessCleanupProbe", true)
addEventHandler("drivethru:harnessCleanupProbe", resourceRoot, function(runId)
    if source == resourceRoot then
        beginCleanupProbe(runId, getTickCount())
    end
end)

addEventHandler("onClientKey", root, function(button, pressed)
    if pressed == true and harness.keyProbe and button == (harness.keyProbe.key or "w") then
        harness.keyProbe.keyObserved = true
    end
end)

addEventHandler("onClientResourceStop", resourceRoot, clearTimers)
