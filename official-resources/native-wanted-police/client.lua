-- Client side of native-wanted-police.
--
-- What runs here and why:
-- - Cop AI. The server picks one client per cop (the ped syncer). Only that
--   client gives the cop its native task, always aimed at the suspect the
--   server named (setPedKillOnFoot / setPedGoTo). Other clients just see the
--   result through normal ped sync. No retail police task is ever used: they
--   read the local wanted level and expect a real CCopPed (see server.lua).
-- - Police cars (version 2). The client that syncs the car runs its driver:
--   GTA's ram or block mission on the suspect's vehicle (setPedDriveMission),
--   or a drive to a suspect on foot. The server decides when the crew stops,
--   gets out or gets back in; this client only carries the orders out.
-- - Spawn points. The suspect's client finds an off-screen ped-path point
--   with GTA's own population placement (getAmbientPedSpawnCandidate), so a
--   cop never pops into view.
-- - Evidence. The syncer of a damaged ped or vehicle (or the attacker
--   himself) tells the server who hit it; the server re-checks everything.
-- - The suspect's side of an arrest, BUSTED text, and other players' stars.
local function now() return getTickCount() end
local applied = {}         -- ped -> last task given while this client owned it
local damageSent = {}
local lastDownReport = 0
local busted = false
local savedControls = false

local function config(key, default)
    local data = getElementData(resourceRoot, 'neon:policeConfig')
    if type(data) == 'table' and data[key] ~= nil then return data[key] end
    return default
end

local function hasTask(ped, name)
    for slot = 0, 4 do
        for _, task in ipairs({getPedTask(ped, 'primary', slot)}) do
            if task == name then return true end
        end
    end
    return false
end

------------------------------------------------------------------------
-- Cop AI on the owning client.
------------------------------------------------------------------------

-- Streaming leases keep a car and its driver simulated on the client that
-- runs them, even at the edge of its streaming range.
local leases = {}
local function holdStreaming(element)
    if leases[element] or type(acquireElementStreamingLease) ~= 'function' then return end
    local lease = acquireElementStreamingLease(element)
    if lease then leases[element] = lease end
end

local function releaseStreaming(element)
    local lease = leases[element]
    leases[element] = nil
    if lease and type(releaseElementStreamingLease) == 'function' then releaseElementStreamingLease(lease) end
end

local function speedOf(element)
    local vx, vy, vz = getElementVelocity(element)
    return math.sqrt(vx * vx + vy * vy + vz * vz)
end

-- The driver of a police car, on the client that syncs both.
local function driveCar(ped, vehicle, phase, suspect, epoch, state, t)
    if getPedOccupiedVehicleSeat(ped) ~= 0 then return end -- passengers ride
    -- GTA's drive tasks change the vehicle's autopilot: wait until the car
    -- has been handed to this client as well.
    if not isElementSyncer(vehicle) then return end
    holdStreaming(vehicle)
    holdStreaming(ped)
    if not state or state.vehicle ~= vehicle then
        -- A mission car: a ghost instead of falling through the world where
        -- collision is not loaded, back on the road once it is.
        if type(setVehicleLoadCollisionFlag) == 'function' then setVehicleLoadCollisionFlag(vehicle, false) end
        -- Being warped in leaves GTA's in-car task in the script slot.
        killPedTask(ped, 'primary', 3, false)
        state = {vehicle = vehicle}
    end
    local carPhase = getElementData(vehicle, 'neon:policeCarPhase')
    local key, issue
    if phase == 'disengage' or carPhase == 'retire' then
        key = 'wander'
        issue = function() return setPedDriveWander(ped, vehicle, 20, 'stop_for_cars') end
    elseif phase == 'arrest' or carPhase ~= 'chase' then
        -- Solo sets mission 0 and speed 0: the car brakes where it is.
        local x, y, z = getElementPosition(vehicle)
        key = 'stop'
        issue = function() return setPedDriveTo(ped, vehicle, Vector3(x, y, z), 0, 'accurate', 'stop_for_cars') end
    elseif isElement(suspect) then
        local suspectVehicle = getPedOccupiedVehicle(suspect)
        local level = tonumber(getElementData(suspect, 'neon:wantedLevel')) or 2
        local speed = tonumber(getElementData(vehicle, 'neon:policeCarSpeed')) or 34
        local cx, cy, cz = getElementPosition(vehicle)
        local px, py, pz = getElementPosition(suspect)
        local d2 = getDistanceBetweenPoints2D(cx, cy, px, py)
        -- GTA's close / far mission switch (20 m / 25 m, rules.lua).
        if d2 < NativeWantedRules.carCloseDistance then
            state.close = true
        elseif d2 > NativeWantedRules.carFarDistance then
            state.close = false
        end
        if state.close then
            speed = NativeWantedRules.policeCarCloseSpeed(level, speed, not suspectVehicle,
                                                          getDistanceBetweenPoints3D(cx, cy, cz, px, py, pz),
                                                          speedOf(suspectVehicle or suspect))
        end
        local useMission = suspectVehicle and isElementStreamedIn(suspectVehicle) and not isVehicleBlown(suspectVehicle) and
            type(setPedDriveMission) == 'function' and (state.missionRefusedAt or 0) + 3000 < t
        -- GTA clears the mission's target when the suspect's vehicle is
        -- recreated (streamed out and back in) and then sets mission 0
        -- (0x41FA8B): the task lives on, but the car just stands there. A car
        -- standing still while far from the suspect gets its mission again.
        if useMission and not state.close and speedOf(vehicle) < 0.02 then
            state.stuckSince = state.stuckSince or t
        else
            state.stuckSince = nil
        end
        if useMission then
            local mission = getElementData(vehicle, 'neon:policeCarMission') == 'ram' and 'ram' or 'block'
            -- A suspect on a bike is blocked, never rammed (0x41FDE0).
            local vehicleType = getVehicleType(suspectVehicle)
            if vehicleType == 'Bike' or vehicleType == 'BMX' then mission = 'block' end
            key = 'mission:' .. mission .. ':' .. tostring(suspectVehicle)
            state.wantSpeed = speed
            issue = function()
                local ok = setPedDriveMission(ped, vehicle, suspectVehicle, mission .. '_car', speed, 'avoid_cars')
                -- Builds before ram/block were admitted refuse: drive to
                -- the suspect instead, and try again a little later.
                if not ok then state.missionRefusedAt = t end
                return ok
            end
        else
            key = 'goto:' .. speed
            issue = function() return setPedDriveTo(ped, vehicle, Vector3(px, py, pz), speed, 'normal', 'avoid_cars') end
        end
    end
    if not key then return end
    local refresh = false
    if state.key == key and state.epoch == epoch then
        if key:sub(1, 5) == 'goto:' then
            refresh = t - state.at > 1500
        elseif key:sub(1, 8) == 'mission:' then
            -- Re-issue once GTA has dropped the mission task, or for a new
            -- speed band: that restarts GTA's mission (back to far, path
            -- cleared), so a speed change alone waits 2 s between restarts.
            refresh = (t - state.at > 3000 and not hasTask(ped, 'TASK_COMPLEX_CAR_DRIVE_MISSION')) or
                (state.speed ~= state.wantSpeed and t - state.at > 2000) or
                (state.stuckSince ~= nil and t - state.stuckSince > 2000 and t - state.at > 2000)
        end
        if not refresh then applied[ped] = state; return end
    end
    if issue() then
        state.key, state.epoch, state.at = key, epoch, t
        state.speed = state.wantSpeed
        state.stuckSince = nil
    else
        state.key = nil
    end
    applied[ped] = state
end

local function drive(ped)
    local phase = getElementData(ped, 'neon:policePhase')
    local suspect = getElementData(ped, 'neon:policeSuspect')
    local epoch = getElementData(ped, 'neon:policeEpoch') or 0
    local state = applied[ped]
    local t = now()
    if isPedDead(ped) then return end
    local vehicle = getPedOccupiedVehicle(ped)
    local orderGiven = getElementData(ped, 'neon:policeOrder')
    if vehicle then
        if orderGiven == 'exit' then
            -- GTA's own exit (door, animation). The drive task is dropped
            -- first so it cannot fight the exit. Asked again if refused.
            if not state or state.exit ~= vehicle or t - state.at > 2000 then
                if getPedOccupiedVehicleSeat(ped) == 0 then killPedTask(ped, 'primary', 3, false) end
                setPedExitVehicle(ped)
                applied[ped] = {exit = vehicle, at = t}
            end
            return
        end
        return driveCar(ped, vehicle, phase, suspect, epoch, state, t)
    end
    if orderGiven == 'enter' then
        -- The driver goes back to his car, as driver (task 701).
        -- CClientPed::EnterVehicle refuses while a primary task runs (the
        -- foot chase sits in slot 3) or a gun task is active, so both go.
        local car = getElementData(ped, 'neon:policeCarVehicle')
        if isElement(car) and (not state or state.enter ~= car or t - state.at > 1000) then
            killPedTask(ped, 'primary', 3, true)
            killPedTask(ped, 'secondary', 0, true)
            if setPedEnterVehicle(ped, car, 0) then
                applied[ped] = {enter = car, at = t + 2000}
            else
                applied[ped] = {enter = car, at = t}
            end
        end
        return
    end
    if phase == 'disengage' then
        if not state or state.phase ~= 'disengage' then
            setPedWander(ped, 'walk')
            applied[ped] = {phase = 'disengage', epoch = epoch, at = t}
        end
        return
    end
    if not isElement(suspect) then return end
    local streamed = isElementStreamedIn(suspect) and not isPedDead(suspect)
    if phase == 'arrest' then
        if not state or state.phase ~= 'arrest' or state.epoch ~= epoch then
            if streamed then
                setPedTurnToFace(ped, suspect)
                local weapon = getPedWeapon(ped)
                if weapon >= 22 then
                    local x, y, z = getPedBonePosition(suspect, 3)
                    setPedAimAt(ped, Vector3(x, y, z), 4500)
                end
            end
            applied[ped] = {phase = 'arrest', epoch = epoch, at = t}
        end
        return
    end
    -- Pursue: attack the named suspect when he is streamed in, otherwise run
    -- to where he is.
    local kind = streamed and 'kill' or 'goto'
    local px, py, pz = getElementPosition(suspect)
    local cx, cy, cz = getElementPosition(ped)
    local distance = getDistanceBetweenPoints3D(px, py, pz, cx, cy, cz)
    local stale = not state or state.phase ~= 'pursue' or state.epoch ~= epoch or state.kind ~= kind or state.target ~= suspect
    local refresh = false
    if state and not stale then
        if kind == 'goto' then
            refresh = t - state.at > 2000
        else
            -- Re-issue only once GTA has dropped the attack (a dispatched
            -- task is only queued, and responses such as falling replace
            -- it); re-issuing a live attack would restart its combo.
            refresh = t - state.at > 3000 and not hasTask(ped, 'TASK_COMPLEX_KILL_PED_ON_FOOT')
        end
    end
    if stale or refresh then
        local ok
        if kind == 'kill' then
            ok = setPedKillOnFoot(ped, suspect)
        else
            ok = setPedGoTo(ped, Vector3(px, py, pz), 'sprint', 2.0, 4.0)
        end
        -- Remember the task only when it was accepted, so a refusal is
        -- retried on the next pass.
        if ok then applied[ped] = {phase = 'pursue', epoch = epoch, kind = kind, target = suspect, at = t} end
    end
end

-- Every MTA ped is a CPlayerPed. Unless it is a mission actor, MTA's shot
-- sync makes CWeapon::Fire take the player branch of FireInstantHit
-- (CPed::IsPlayer at 0x74034C), which aims through the camera/replicated
-- player aim instead of the target the AI task chose. A cop running
-- setPedKillOnFoot never fills that aim, so its bullets went into the air
-- or sideways and never hit. Mission actors keep the native ped branch
-- (0x7407C1), as GTA's own cops do. This is local state, so every client
-- sets it: the cop shoots straight whichever client runs it after a handoff.
local function makeMissionActor(ped)
    if isPedMissionActor(ped) then return end
    if not setPedMissionActor(ped, true) then
        outputDebugString('[native-wanted-police] cop refused as mission actor', 2)
    end
end

setTimer(function()
    for _, ped in ipairs(getElementsByType('ped', root, true)) do
        local cop = getElementData(ped, 'neon:police') == true
        if cop then makeMissionActor(ped) end
        if cop and isElementSyncer(ped) then
            drive(ped)
        else
            -- Owner changed: the next owner gives the task again. The task
            -- this client gave keeps running locally (MTA only drops jump and
            -- climb tasks on a handover), and its autopilot would fight the
            -- new owner's sync, so it is stopped here, as
            -- native-vehicle-traffic does when it releases a unit.
            if applied[ped] and isElement(ped) and not isPedDead(ped) then
                killPedTask(ped, 'primary', 3, not getPedOccupiedVehicle(ped))
            end
            applied[ped] = nil
        end
    end
    for ped in pairs(applied) do
        if not isElement(ped) then applied[ped] = nil end
    end
    -- Leases only while this client runs the element.
    for element in pairs(leases) do
        if not isElement(element) or not isElementSyncer(element) then releaseStreaming(element) end
    end
end, 400, 0)

------------------------------------------------------------------------
-- Spawn points and visibility.
------------------------------------------------------------------------

-- radius: 1 m for a ped; 5 m for a car, as GTA's road placement (0x424210)
-- and native-vehicle-traffic test, so the nose of a long car cannot be on
-- screen while its centre is not.
local function hiddenFromCamera(x, y, z, radius)
    if type(isAmbientPedSphereVisible) == 'function' then
        return not isAmbientPedSphereVisible(x, y, z, radius or 1.0)
    end
    if not getScreenFromWorldPosition(x, y, z + 1, 0.1) then return true end
    local cx, cy, cz = getCameraMatrix()
    return not isLineOfSightClear(cx, cy, cz, x, y, z + 1, true, false, false, true, false, true)
end

addEvent('neonPolice:spawnProbe', true)
addEventHandler('neonPolice:spawnProbe', resourceRoot, function(id)
    local px, py, pz = getElementPosition(localPlayer)
    local function accept(x, y, z)
        local d = getDistanceBetweenPoints3D(px, py, pz, x, y, z)
        return d >= 20 and d <= 130 and math.abs(z - pz) < 30 and hiddenFromCamera(x, y, z)
    end
    -- GTA's own placement: an off-screen ped-path node in the creation ring.
    if type(getAmbientPedSpawnCandidate) == 'function' then
        for _ = 1, 4 do
            local candidate = getAmbientPedSpawnCandidate(px, py, pz, 'civilian')
            if type(candidate) == 'table' and accept(candidate.x, candidate.y, candidate.z) then
                triggerServerEvent('neonPolice:spawnCandidate', resourceRoot, id, candidate.x, candidate.y, candidate.z)
                return
            end
        end
    end
    -- Fallback: ground points on a ring around the suspect, out of view and
    -- out of water.
    for _ = 1, 16 do
        local angle = math.random() * math.pi * 2
        local radius = 45 + math.random() * 30
        local x, y = px + math.cos(angle) * radius, py + math.sin(angle) * radius
        -- Searched from just above the suspect's height: from higher up the
        -- first surface found is often a roof.
        local ground = getGroundPosition(x, y, pz + 5)
        if ground and ground ~= 0 and math.abs(ground - pz) < 20 then
            local water = getWaterLevel(x, y, ground + 1)
            local z = ground + 1.0
            if not (water and water > ground) and accept(x, y, z) then
                triggerServerEvent('neonPolice:spawnCandidate', resourceRoot, id, x, y, z)
                return
            end
        end
    end
end)

-- Police cars: GTA's own road placement for a car of this model near the
-- suspect (GenerateCarCreationCoors2, lane offset and ground check), the
-- same oracle native-vehicle-traffic uses. The C++ reads the model's
-- collision, so the model is held loaded while it runs.
addEvent('neonPolice:carProbe', true)
addEventHandler('neonPolice:carProbe', resourceRoot, function(id, model)
    local function answer(candidate)
        if candidate then
            triggerServerEvent('neonPolice:carCandidate', resourceRoot, id, candidate.x, candidate.y, candidate.z,
                               candidate.rotation)
        else
            triggerServerEvent('neonPolice:carCandidate', resourceRoot, id, false)
        end
    end
    model = tonumber(model)
    if not model or type(getAmbientVehicleSpawnCandidate) ~= 'function' then return answer(false) end
    local px, py, pz = getElementPosition(localPlayer)
    if type(updateAmbientPedPopulationModels) == 'function' then updateAmbientPedPopulationModels(px, py, pz) end
    local held = false
    if type(engineStreamingRequestModel) == 'function' and type(engineStreamingGetModelLoadState) == 'function' then
        held = pcall(engineStreamingRequestModel, model, true, true)
        local ok, state = pcall(engineStreamingGetModelLoadState, model)
        if held and not (ok and state == 'loaded') then
            pcall(engineStreamingReleaseModel, model, true)
            return answer(false)
        end
    end
    -- GTA's placement answers on two rings (0x424210): about 160 m, a point
    -- the camera may see (a car that far is a speck, and it is staged hidden
    -- until loaded anyway), and 38 m, a point it must not see. Both are
    -- kept; only a visible point within 70 m is refused. Keeping only hidden
    -- points threw away every far one, so every car appeared 38 m away,
    -- right at the edge of the screen.
    local found
    for _ = 1, 4 do
        local candidate = getAmbientVehicleSpawnCandidate(px, py, pz, model)
        if type(candidate) == 'table' then
            local d = getDistanceBetweenPoints3D(px, py, pz, candidate.x, candidate.y, candidate.z)
            if d >= 30 and d <= 205 and (d >= 70 or hiddenFromCamera(candidate.x, candidate.y, candidate.z, 5.0)) then
                found = candidate
                break
            end
        end
    end
    if held then pcall(engineStreamingReleaseModel, model, true) end
    answer(found)
end)

-- Another player's check before a cop appears near them. A car point uses
-- the car rule: refused only when on screen within 70 m (or closer than
-- 25 m).
addEvent('neonPolice:spawnVeto', true)
addEventHandler('neonPolice:spawnVeto', resourceRoot, function(id, x, y, z, kind)
    local visible = true
    if type(x) == 'number' and type(y) == 'number' and type(z) == 'number' then
        local px, py, pz = getElementPosition(localPlayer)
        local d = getDistanceBetweenPoints3D(px, py, pz, x, y, z)
        if kind == 'car' then
            visible = d < 25 or (d < 70 and not hiddenFromCamera(x, y, z, 5.0))
        else
            visible = d < 18 or not hiddenFromCamera(x, y, z)
        end
    end
    triggerServerEvent('neonPolice:spawnVetoResult', resourceRoot, id, visible)
end)

local function modelLoaded(model)
    if type(engineStreamingGetModelLoadState) ~= 'function' then return true end
    local ok, state = pcall(engineStreamingGetModelLoadState, model)
    return not ok or state == 'loaded'
end

-- A new police car is created hidden; the server shows it once every
-- nearby client answers here: ready (car and crew streamed in with their
-- models loaded, when within 160 m) and not visible (its spot is not on
-- screen within 70 m, 5 m sphere).
addEvent('neonPolice:revealProbe', true)
addEventHandler('neonPolice:revealProbe', resourceRoot, function(id, vehicle)
    local isReady, visible = true, false
    if isElement(vehicle) then
        local occupants = getVehicleOccupants(vehicle) or {}
        -- Hidden here too, in case the server's alpha change has not been
        -- applied yet when the car streams in.
        setElementAlpha(vehicle, 0)
        setVehicleOverrideLights(vehicle, 1)
        for _, ped in pairs(occupants) do setElementAlpha(ped, 0) end
        local x, y, z = getElementPosition(vehicle)
        local px, py, pz = getElementPosition(localPlayer)
        local d = getDistanceBetweenPoints3D(px, py, pz, x, y, z)
        if d < 160 then
            isReady = isElementStreamedIn(vehicle) and modelLoaded(getElementModel(vehicle))
            for _, ped in pairs(occupants) do
                isReady = isReady and isElementStreamedIn(ped) and modelLoaded(getElementModel(ped))
            end
        end
        visible = d < 70 and not hiddenFromCamera(x, y, z, 5.0)
    end
    triggerServerEvent('neonPolice:revealResult', resourceRoot, id, isReady == true, visible)
end)

addEvent('neonPolice:visibilityProbe', true)
addEventHandler('neonPolice:visibilityProbe', resourceRoot, function(id, ped)
    local visible = false
    if isElement(ped) and isElementStreamedIn(ped) and isElementOnScreen(ped) then
        local cx, cy, cz = getCameraMatrix()
        local x, y, z = getElementPosition(ped)
        visible = isLineOfSightClear(cx, cy, cz, x, y, z, true, false, false, true, false, true)
    end
    triggerServerEvent('neonPolice:visibilityResult', resourceRoot, id, visible)
end)

------------------------------------------------------------------------
-- Evidence for crimes the server cannot see.
------------------------------------------------------------------------

local function offenderOf(attacker)
    if not isElement(attacker) then return nil end
    if getElementType(attacker) == 'player' then return attacker end
    if getElementType(attacker) == 'vehicle' then
        local driver = getVehicleController(attacker)
        if isElement(driver) and getElementType(driver) == 'player' then return driver end
    end
    return nil
end

local function throttled(key)
    local t = now()
    if (damageSent[key] or 0) > t then return true end
    damageSent[key] = t + 400
    return false
end

addEventHandler('onClientPedDamage', root, function(attacker, weapon)
    -- A hit another script cancelled (safe zone, god mode) is no crime.
    if wasEventCancelled() or getElementType(source) ~= 'ped' then return end
    local offender = offenderOf(attacker)
    if not offender then return end
    if not isElementSyncer(source) and offender ~= localPlayer then return end
    weapon = tonumber(weapon) or 0
    if throttled(tostring(source) .. tostring(offender) .. weapon) then return end
    triggerServerEvent('neonPolice:damage', resourceRoot, source, attacker, weapon)
end)

addEventHandler('onClientVehicleDamage', root, function(attacker, weapon)
    if wasEventCancelled() then return end
    local offender = offenderOf(attacker)
    if not offender then return end
    if not isElementSyncer(source) and getVehicleController(source) ~= localPlayer and offender ~= localPlayer then return end
    weapon = tonumber(weapon) or 49 -- a collision has no weapon: count it as ramming
    if throttled(tostring(source) .. tostring(offender) .. weapon) then return end
    triggerServerEvent('neonPolice:vehicleDamage', resourceRoot, source, attacker, weapon)
end)

setTimer(function()
    local t = now()
    for key, until_ in pairs(damageSent) do
        if until_ < t then damageSent[key] = nil end
    end
end, 10000, 0)

------------------------------------------------------------------------
-- Suspect side: knocked down, arrest, BUSTED.
------------------------------------------------------------------------

local knockedDownTasks = {TASK_SIMPLE_FALL = true, TASK_SIMPLE_GET_UP = true}

local function copNearMe(range)
    local px, py, pz = getElementPosition(localPlayer)
    for _, ped in ipairs(getElementsByType('ped', root, true)) do
        if getElementData(ped, 'neon:police') == true and getElementData(ped, 'neon:policeSuspect') == localPlayer and
            not isPedDead(ped) then
            local x, y, z = getElementPosition(ped)
            if getDistanceBetweenPoints3D(px, py, pz, x, y, z) <= range then return true end
        end
    end
    return false
end

setTimer(function()
    local level = getElementData(localPlayer, 'neon:wantedLevel') or 0
    if level <= 0 or isPedInVehicle(localPlayer) or isPedDead(localPlayer) then return end
    if not knockedDownTasks[getPedSimplestTask(localPlayer)] then return end
    if now() - lastDownReport < 1000 or not copNearMe(4) then return end
    lastDownReport = now()
    triggerServerEvent('neonPolice:down', resourceRoot)
end, 200, 0)

-- Only the controls this resource turned off are turned back on, so a
-- gamemode's own control locks survive an arrest.
local arrestControls = {'forwards', 'backwards', 'left', 'right', 'sprint', 'jump', 'crouch', 'fire', 'aim_weapon',
                        'enter_exit', 'enter_passenger', 'next_weapon', 'previous_weapon', 'walk'}

local function lockControls()
    if savedControls then return end
    savedControls = {}
    for _, control in ipairs(arrestControls) do
        if isControlEnabled(control) then
            savedControls[#savedControls + 1] = control
            toggleControl(control, false)
        end
    end
end

local function unlockControls()
    if not savedControls then return end
    for _, control in ipairs(savedControls) do toggleControl(control, true) end
    savedControls = false
end

local handsUpAnimation = false

addEvent('neonPolice:arrest', true)
addEventHandler('neonPolice:arrest', resourceRoot, function(_, duration, kind)
    lockControls()
    if kind == 'car' then
        -- Pulled out of a stopped car: GTA's own exit. The server takes the
        -- suspect out itself if this does not happen, then sends 'foot'.
        if getPedOccupiedVehicle(localPlayer) and type(setPedExitVehicle) == 'function' then setPedExitVehicle(localPlayer) end
        return
    end
    duration = math.max(1000, math.min(tonumber(duration) or 4000, 6000))
    -- setPedHandsUp (GTA's hands-up task) only exists in builds after
    -- 2026-11-01; older clients play the same stock animation instead.
    if type(setPedHandsUp) ~= 'function' or not setPedHandsUp(localPlayer, duration) then
        handsUpAnimation = setPedAnimation(localPlayer, 'ped', 'handsup', -1, false, false, false, true)
    end
end)

-- Default busted outcome: controls stay locked through the fade until the
-- respawn at the police station.
addEvent('neonPolice:bustHold', true)
addEventHandler('neonPolice:bustHold', resourceRoot, function(hold)
    if hold then lockControls() else unlockControls() end
end)

addEvent('neonPolice:arrestEnd', true)
addEventHandler('neonPolice:arrestEnd', resourceRoot, function(wasBusted)
    unlockControls()
    if handsUpAnimation then
        setPedAnimation(localPlayer)
        handsUpAnimation = false
    end
    if wasBusted and config('bustedText', true) then busted = now() + 4000 end
end)

------------------------------------------------------------------------
-- Drawing: BUSTED, and the stars of other wanted players nearby.
------------------------------------------------------------------------

local function drawStar(x, y, radius, color)
    local points = {{x, y, color}}
    for i = 0, 10 do
        local angle = -math.pi / 2 + i * math.pi / 5
        local r = (i % 2 == 0) and radius or radius * 0.45
        points[#points + 1] = {x + math.cos(angle) * r, y + math.sin(angle) * r, color}
    end
    dxDrawPrimitive('trianglefan', false, unpack(points))
end

addEventHandler('onClientRender', root, function()
    if busted then
        if now() > busted then
            busted = false
        else
            local sw, sh = guiGetScreenSize()
            local scale = sh / 480
            dxDrawText('BUSTED', 2, sh * 0.42 + 2, sw + 2, sh * 0.42 + 2, tocolor(0, 0, 0, 255), 2.2 * scale, 'pricedown', 'center', 'top')
            dxDrawText('BUSTED', 0, sh * 0.42, sw, sh * 0.42, tocolor(220, 220, 220, 255), 2.2 * scale, 'pricedown', 'center', 'top')
        end
    end
    if not config('overheadStars', true) then return end
    local cx, cy, cz = getCameraMatrix()
    local sh = select(2, guiGetScreenSize())
    for _, player in ipairs(getElementsByType('player', root, true)) do
        local level = player ~= localPlayer and getElementData(player, 'neon:wantedLevel') or 0
        if type(level) == 'number' and level > 0 and not isPedDead(player) then
            local x, y, z = getPedBonePosition(player, 8)
            if x and getDistanceBetweenPoints3D(cx, cy, cz, x, y, z) < 45 then
                local sx, sy = getScreenFromWorldPosition(x, y, z + 0.45)
                if sx then
                    local radius = sh / 110
                    local start = sx - (level - 1) * radius * 1.1
                    for i = 0, level - 1 do
                        drawStar(start + i * radius * 2.2 + 1, sy + 1, radius, tocolor(0, 0, 0, 200))
                        drawStar(start + i * radius * 2.2, sy, radius, tocolor(214, 160, 40, 255))
                    end
                end
            end
        end
    end
end)

addEventHandler('onClientResourceStart', resourceRoot, function()
    triggerServerEvent('neonPolice:ready', resourceRoot)
end)

addEventHandler('onClientResourceStop', resourceRoot, function()
    unlockControls()
end)
