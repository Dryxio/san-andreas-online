-- Client side of native-wanted-police.
--
-- What runs here and why:
-- - Cop AI. The server picks one client per cop (the ped syncer). Only that
--   client gives the cop its native task, always aimed at the suspect the
--   server named (setPedKillOnFoot / setPedGoTo). Other clients just see the
--   result through normal ped sync. No retail police task is ever used: they
--   read the local wanted level and expect a real CCopPed (see server.lua).
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

local function drive(ped)
    local phase = getElementData(ped, 'neon:policePhase')
    local suspect = getElementData(ped, 'neon:policeSuspect')
    local epoch = getElementData(ped, 'neon:policeEpoch') or 0
    local state = applied[ped]
    local t = now()
    if isPedDead(ped) then return end
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

setTimer(function()
    for _, ped in ipairs(getElementsByType('ped', root, true)) do
        if getElementData(ped, 'neon:police') == true and isElementSyncer(ped) then
            drive(ped)
        else
            applied[ped] = nil -- owner changed: the next owner gives the task again
        end
    end
    for ped in pairs(applied) do
        if not isElement(ped) then applied[ped] = nil end
    end
end, 400, 0)

------------------------------------------------------------------------
-- Spawn points and visibility.
------------------------------------------------------------------------

local function hiddenFromCamera(x, y, z)
    if type(isAmbientPedSphereVisible) == 'function' then
        return not isAmbientPedSphereVisible(x, y, z, 1.0)
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
        local ground = getGroundPosition(x, y, pz + 30)
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

-- Another player's check before a cop appears near them.
addEvent('neonPolice:spawnVeto', true)
addEventHandler('neonPolice:spawnVeto', resourceRoot, function(id, x, y, z)
    local visible = true
    if type(x) == 'number' and type(y) == 'number' and type(z) == 'number' then
        local px, py, pz = getElementPosition(localPlayer)
        visible = getDistanceBetweenPoints3D(px, py, pz, x, y, z) < 18 or not hiddenFromCamera(x, y, z)
    end
    triggerServerEvent('neonPolice:spawnVetoResult', resourceRoot, id, visible)
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
addEventHandler('neonPolice:arrest', resourceRoot, function(_, duration)
    lockControls()
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
