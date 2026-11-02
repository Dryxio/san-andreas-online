-- Server authority for wanted levels and police (issue #91, version 1).
--
-- Why it is built this way:
-- - The server is the only authority on crimes, wanted levels, which cop
--   chases whom, and arrests. GTA's wanted system cannot hold several network
--   suspects (every Neon ped points at the local player's CWanted), so each
--   player gets an independent ledger from rules.lua.
-- - Cops come from two places, as in solo: street cops already walking in
--   native-ped-traffic join the chase, and new cops are created out of view.
--   Two resources must never drive the same NPC, so a street cop is first
--   released by the traffic resource (releaseTrafficCop) and then belongs to
--   this resource only.
-- - The server decides but cannot run GTA's AI. One client (the ped syncer)
--   runs each cop's native task. Wherever possible that client is another
--   player near the suspect, not the suspect. A watchdog checks that every cop
--   really closes in and moves it to another owner, or replaces it, if not.
-- - GTA's retail cop tasks (pursuit, arrest, kill criminal) are never used:
--   they read the local wanted singleton and cast to CCopPed. Cops use the
--   explicit-target primitive setPedKillOnFoot. Checked in the binary: the
--   kill-criminal response cannot start on a Neon ped, because every MTA
--   player and script ped is a CPlayerPed of ped type 0 (0x60D5B0 calls
--   CPed::CPed(0); IsPlayer 0x5DF8F0) and both the constructor 0x68BE70 and
--   CreateFirstSubTask 0x68DC60 drop a player-type criminal.
local R = NativeWantedRules

local function setting(name, default)
    local value = get(name)
    if value == false or value == nil then return default end
    if type(default) == 'number' then return tonumber(value) or default end
    if type(default) == 'boolean' then return value == true or value == 'true' end
    return value
end

local cfg = {}
local function loadSettings()
    cfg.maxCops = setting('maxCops', 24)
    cfg.maxCopsPerSuspect = setting('maxCopsPerSuspect', 10)
    cfg.pvpCrimes = setting('pvpCrimes', true)
    cfg.copLostDistance = setting('copLostDistance', 220)
    cfg.ownerRange = setting('ownerRange', 90)
    cfg.overheadStars = setting('overheadStars', true)
    cfg.bustedText = setting('bustedText', true)
    cfg.streetCops = setting('streetCops', true)
    -- Multiplayer choice: solo has no foot-cop spawner during a chase (cops
    -- are ambient walkers plus car crews). Version 1 has no police cars, so
    -- foot units arrive at roughly the rate solo sends cars: 2 stars one car
    -- every 8 s, 3 stars every 5 s, 4+ without delay (issue #91).
    cfg.dispatchDelay = {[1] = 6000, [2] = 4000, [3] = 2500, [4] = 1500, [5] = 1500, [6] = 1500}
end
loadSettings()

local suspects = {}   -- player -> suspect state
local units = {}      -- ped -> unit
local ready = {}      -- player -> true once client.lua is running
local pendingSpawns = {}
local nextRequestId, nextUnitId = 0, 0
local lastVehicleAttacker = {}
local reportBudget = {}

local function now() return getTickCount() end

-- Every value this resource publishes is written with client changes denied:
-- with the default trust a client could retarget a cop or fake its stars.
local function setData(element, key, value)
    return setElementData(element, key, value, 'broadcast', 'deny')
end
local function isPlayer(e) return isElement(e) and getElementType(e) == 'player' end
local function isPed(e) return isElement(e) and getElementType(e) == 'ped' end

local function distance3(a, b)
    local ax, ay, az = getElementPosition(a)
    local bx, by, bz = getElementPosition(b)
    return getDistanceBetweenPoints3D(ax, ay, az, bx, by, bz), az - bz
end

local function inMainWorld(e)
    return getElementDimension(e) == 0 and getElementInterior(e) == 0
end

local function suspectOf(player)
    local s = suspects[player]
    if not s and isPlayer(player) then
        s = {player = player, w = R.new(now()), enabled = true, units = {}, lastDispatch = 0,
             published = 0, backoffUntil = 0, still = false}
        suspects[player] = s
    end
    return s
end

-- Classify an element the way GTA classifies a crime victim.
local function victimClass(e)
    if isPlayer(e) then return 'player' end
    if not isPed(e) then return nil end
    if units[e] then return 'cop' end
    -- Element data is client-writable on other resources' peds, so the
    -- server classifies by model (peds.ide types) only.
    return R.pedClassForModel(getElementModel(e))
end

local function isCopPed(e)
    return isPed(e) and not isPedDead(e) and victimClass(e) == 'cop'
end

-- WorkOutPolicePresence: living cops and law vehicles in a 3D radius, no line
-- of sight. The offender's own vehicle does not count.
local function policeNear(x, y, z, radius, offender)
    for _, ped in ipairs(getElementsWithinRange(x, y, z, radius, 'ped', 0, 0)) do
        if isCopPed(ped) then return true end
    end
    -- Vehicles count while in service: GTA's bIsLawEnforcer flag is set on
    -- police-generated cars and cleared when the cop driver leaves, and an
    -- abandoned or wrecked vehicle never counts. Neon approximates "in
    -- service" as a law model driven by a cop (the Maverick: any driver).
    local own = offender and getPedOccupiedVehicle(offender)
    for _, vehicle in ipairs(getElementsWithinRange(x, y, z, radius, 'vehicle', 0, 0)) do
        local model = getElementModel(vehicle)
        local driver = getVehicleController(vehicle)
        if vehicle ~= own and R.lawVehicles[model] and not isVehicleBlown(vehicle) and isElement(driver) and
            driver ~= offender and (model == 497 or isCopPed(driver)) then
            return true
        end
    end
    return false
end

local function aliveUnits(s)
    local list = {}
    for _, ped in ipairs(s.units) do
        local unit = units[ped]
        if unit and isElement(ped) and not isPedDead(ped) and unit.phase ~= 'disengage' then list[#list + 1] = unit end
    end
    return list
end

local function setPhase(unit, phase)
    if unit.phase == phase then return end
    unit.phase = phase
    if isElement(unit.ped) then
        setData(unit.ped, 'neon:policePhase', phase)
        triggerEvent('onNativePoliceUnitStateChange', unit.ped, unit.suspect or false, phase)
    end
end

local function dismissUnits(s, reason)
    for _, ped in ipairs(s.units) do
        local unit = units[ped]
        if unit then
            unit.retireReason = reason
            unit.retiredAt = unit.retiredAt or now()
            setPhase(unit, 'disengage')
        end
    end
end

local function endArrest(s, busted)
    if not s.arrest then return end
    s.arrest = nil
    s.arrestCooldownUntil = now() + 3000
    if isElement(s.player) then triggerClientEvent(s.player, 'neonPolice:arrestEnd', resourceRoot, busted == true) end
    for _, unit in ipairs(aliveUnits(s)) do setPhase(unit, 'pursue') end
end

-- Push the ledger's level to the suspect's own HUD and to everyone else.
-- setPlayerWantedLevel only writes the suspect's local CWanted (HUD stars);
-- no Neon decision reads it back.
local function publish(s, reason)
    local level = s.w.level
    if level == s.published then return end
    local old = s.published
    s.published = level
    if isElement(s.player) then
        setPlayerWantedLevel(s.player, level)
        setData(s.player, 'neon:wantedLevel', level)
    end
    triggerEvent('onNativeWantedLevelChange', s.player, old, level, reason or 'crime')
    if level == 0 then
        endArrest(s, false)
        dismissUnits(s, reason or 'cleared')
        if old > 0 and reason == 'decay' then triggerEvent('onNativeSuspectEscaped', s.player, old) end
    end
end

-- Report one crime against the offender's ledger (CCrime::ReportCrime).
local function reportCrime(offender, crimeType, victim, origin, queueOnly)
    if not isPlayer(offender) or not R.weights[crimeType] then return false end
    local s = suspectOf(offender)
    if not s.enabled or isPedDead(offender) or getElementDimension(offender) ~= 0 then return false end
    if victim == offender then return false end
    local class = victim and victimClass(victim)
    if not triggerEvent('onNativeCrimeValidated', offender, crimeType, victim or false, origin or 'server') then return false end
    local x, y, z = getElementPosition(offender)
    local present = not queueOnly and policeNear(x, y, z, R.detectionRange(crimeType), offender)
    local _, immediate = R.report(s.w, crimeType, victim or 'none',
                                  {policePresent = present, policeDontCare = R.policeDontCare(class), queueOnly = queueOnly},
                                  now())
    triggerEvent('onNativeCrimeReported', offender, crimeType, victim or false, immediate)
    -- Hurting a cop during an arrest is resisting it.
    if s.arrest and class == 'cop' then endArrest(s, false) end
    publish(s, 'crime')
    return true
end

-- Resolve "who did it" when GTA reports a vehicle as the attacker.
local function attackerPlayer(attacker)
    if isPlayer(attacker) then return attacker end
    if isElement(attacker) and getElementType(attacker) == 'vehicle' then
        local driver = getVehicleController(attacker)
        if isPlayer(driver) then return driver end
    end
    return nil
end

-- Is it believable that `offender` hit `target` with `weapon`? Reports of
-- damage come from clients (the victim's syncer, the victim player, or the
-- attacker), so a framed player must at least be close enough and hold the
-- weapon named.
local function plausibleRange(weapon)
    weapon = tonumber(weapon) or 0
    if weapon == 49 or weapon == 50 then return 25 end
    if weapon < 10 then return 8 end
    if weapon == 37 or weapon == 18 or weapon == 16 or weapon == 51 or weapon == 35 or weapon == 36 or weapon == 39 then return 80 end
    return 200
end

local function plausibleHit(offender, target, weapon)
    weapon = tonumber(weapon)
    if not weapon or distance3(offender, target) > plausibleRange(weapon) then return false end
    local inVehicle = getPedOccupiedVehicle(offender) ~= false and getPedOccupiedVehicle(offender) ~= nil
    if weapon == 49 or weapon == 50 then return inVehicle end
    if weapon == 51 then return true end
    if weapon == 0 then return not inVehicle end
    if weapon >= 1 and weapon <= 46 then return getPedWeapon(offender) == weapon end
    return false
end

-- One hit by a player, as GTA reports it:
-- - GenerateDamageEvent (0x73A530): ReportCrime(2 "damage ped") on the victim;
-- - CPed::KillPedWithCar (0x5F0360): ReportCrime(10/11) when run over;
-- - explosions hitting a ped (0x567750): ReportCrime(4/5);
-- - ReportCriminalEvent (0x4B3440): the weapon's crime, queued only.
-- Duplicates from several evidence sources collapse on (type, victim).
local function reportDamage(attacker, victim, weapon, origin, stealth)
    local offender = attackerPlayer(attacker)
    if not offender or offender == victim or not isElement(victim) then return end
    local class = victimClass(victim)
    if not class then return end
    if class == 'player' then
        if not cfg.pvpCrimes then return end
        class = 'civilian'
    end
    if origin ~= 'weapon-fire' and not plausibleHit(offender, victim, weapon) then return end
    local cop = class == 'cop'
    reportCrime(offender, R.crime.DAMAGE_PED, victim, origin)
    if weapon == 49 or weapon == 50 then
        reportCrime(offender, cop and R.crime.RUN_OVER_COP or R.crime.RUN_OVER_PED, victim, origin)
    elseif weapon == 51 then
        reportCrime(offender, cop and R.crime.SHOOT_COP or R.crime.SHOOT_PED, victim, origin)
    end
    if stealth then reportCrime(offender, R.crime.STAB_PED, victim, origin) end -- stealth kill (0x6859A0)
    local queued = R.damageQueuedCrime(class, weapon)
    if queued then reportCrime(offender, queued, victim, origin, true) end
end

------------------------------------------------------------------------
-- Crime sources the server can see or validate.
------------------------------------------------------------------------

-- CWeapon::DoBulletImpact (0x73B550): firing reports crime 1 against what was
-- hit, and a hit ped (cop or not) also reports crime 4.
addEventHandler('onPlayerWeaponFire', root, function(weapon, _, _, _, hitElement)
    reportCrime(source, R.crime.FIRE_WEAPON, isElement(hitElement) and hitElement or nil, 'weapon-fire')
    if isElement(hitElement) then
        local kind = getElementType(hitElement)
        if kind == 'ped' or kind == 'player' then
            if kind == 'player' and not cfg.pvpCrimes then return end
            reportCrime(source, R.crime.SHOOT_PED, hitElement, 'weapon-fire')
        elseif kind == 'vehicle' then
            lastVehicleAttacker[hitElement] = {player = source, at = now()}
        end
    end
end)

addEventHandler('onPlayerDamage', root, function(attacker, weapon)
    if attacker then reportDamage(attacker, source, weapon, 'player-damage') end
end)

addEventHandler('onPedWasted', root, function(_, killer, weapon, _, stealth)
    if killer then reportDamage(killer, source, weapon, 'ped-wasted', stealth == true) end
end)

-- CTaskSimpleCarSetPedInAsDriver/Passenger (0x64B950 / 0x64B5D0): the
-- first time any player gets into a vehicle, in any seat, GTA marks it as
-- "owned by the player" and reports crime 6 against it. Gamemodes mark
-- vehicles that belong to players with element data neon:playerOwned = true.
local enteredVehicles = {}
addEventHandler('onPlayerVehicleEnter', root, function(vehicle)
    if enteredVehicles[vehicle] or getElementData(vehicle, 'neon:playerOwned') == true then return end
    enteredVehicles[vehicle] = true
    reportCrime(source, R.crime.STEAL_CAR, vehicle, 'vehicle-enter')
end)

addEventHandler('onPlayerTarget', root, function(target)
    if isCopPed(target) and R.isArmedWeapon(getPedWeapon(source)) then
        reportCrime(source, R.crime.AIM_AT_COP, target, 'aim')
    end
end)

-- Explosion types created by a player's own weapon: grenade, molotov, rocket,
-- weak rocket, mine, tank grenade. Car explosions are sent by the car's
-- syncer, who is not necessarily to blame, so they go through onVehicleExplode.
local playerExplosionTypes = {[0] = true, [1] = true, [2] = true, [3] = true, [8] = true, [10] = true}
addEventHandler('onExplosion', root, function(_, _, _, explosionType)
    if isPlayer(source) and playerExplosionTypes[explosionType] then
        reportCrime(source, R.crime.EXPLOSION, nil, 'explosion')
    end
end)

addEventHandler('onVehicleExplode', root, function()
    local last = lastVehicleAttacker[source]
    lastVehicleAttacker[source] = nil
    if not last or now() - last.at > 10000 or not isElement(last.player) then return end
    local vehicleType = getVehicleType(source)
    local crimeType = vehicleType == 'Helicopter' and R.crime.DESTROY_HELI or vehicleType == 'Plane' and R.crime.DESTROY_PLANE or
        R.crime.DESTROY_VEHICLE
    reportCrime(last.player, crimeType, source, 'vehicle-explode')
end)

addEventHandler('onElementDestroy', root, function()
    lastVehicleAttacker[source] = nil
    enteredVehicles[source] = nil
end)

-- Bounded per-client budget for client evidence (30 reports a second).
local function spend(player)
    local t = now()
    local b = reportBudget[player]
    if not b or t - b.at >= 1000 then b = {at = t, count = 0}; reportBudget[player] = b end
    b.count = b.count + 1
    return b.count <= 30
end

-- Damage seen by the victim ped's syncer (or the attacker's own client). The
-- server re-checks who may report it and whether the distance is plausible.
addEvent('neonPolice:damage', true)
addEventHandler('neonPolice:damage', resourceRoot, function(victim, attacker, weapon)
    if not spend(client) or not isPed(victim) then return end
    local offender = attackerPlayer(attacker)
    if not offender then return end
    if client ~= getElementSyncer(victim) and client ~= offender then return end
    if type(weapon) ~= 'number' then return end
    reportDamage(attacker, victim, weapon, 'ped-damage')
end)

-- Vehicle damage the server cannot see. Collisions are symmetric, so a
-- driver's report about his own vehicle is never used. Accepted: the
-- attacker reporting himself, or the syncer of an empty vehicle.
-- Only two things follow: punching a vehicle (crime 21, CTaskSimpleFight
-- 0x61D0B0) and who to blame if the vehicle is destroyed (0x6D7C90).
addEvent('neonPolice:vehicleDamage', true)
addEventHandler('neonPolice:vehicleDamage', resourceRoot, function(vehicle, attacker, weapon)
    if not spend(client) or not isElement(vehicle) or getElementType(vehicle) ~= 'vehicle' then return end
    local offender = attackerPlayer(attacker)
    local controller = getVehicleController(vehicle)
    if not offender or controller == offender or client == controller then return end
    local selfReport = client == offender
    if not selfReport and not (client == getElementSyncer(vehicle) and not isElement(controller)) then return end
    if not plausibleHit(offender, vehicle, weapon) then return end
    if selfReport then lastVehicleAttacker[vehicle] = {player = offender, at = now()} end
    if weapon == 0 then reportCrime(offender, R.crime.PUNCH_VEHICLE, vehicle, 'vehicle-damage') end
end)

------------------------------------------------------------------------
-- Cops.
------------------------------------------------------------------------

-- Cops still chasing count against maxCops; retiring ones (walking away,
-- dead, waiting to be out of view) have their own, larger ceiling so they
-- can never block dispatch for everyone.
local function countUnits()
    local active, retiring = 0, 0
    for ped, unit in pairs(units) do
        if unit.phase ~= 'disengage' and isElement(ped) and not isPedDead(ped) then
            active = active + 1
        else
            retiring = retiring + 1
        end
    end
    return active, retiring
end

local function findRotation(x1, y1, x2, y2)
    local t = -math.deg(math.atan2(x2 - x1, y2 - y1))
    return t < 0 and t + 360 or t
end

-- The client that runs a cop's AI: the nearest other ready player close to
-- the cop, else the suspect. A player the watchdog caught stalling a cop is
-- avoided for 20 s, so the cop does not bounce back to him.
local function chooseOwner(unit)
    local t = now()
    unit.avoid = unit.avoid or {}
    local function allowed(player) return ready[player] and (unit.avoid[player] or 0) <= t end
    local best, bestDistance
    for _, player in ipairs(getElementsByType('player')) do
        if player ~= unit.suspect and allowed(player) and not isPedDead(player) and inMainWorld(player) then
            local d = distance3(player, unit.ped)
            if d <= cfg.ownerRange and (not bestDistance or d < bestDistance) then best, bestDistance = player, d end
        end
    end
    if best then return best end
    if isPlayer(unit.suspect) and allowed(unit.suspect) then return unit.suspect end
    return unit.owner
end

local function assignOwner(unit, owner)
    if not isPlayer(owner) or owner == unit.owner then return end
    if setElementSyncer(unit.ped, owner, true) then
        unit.owner = owner
        unit.epoch = unit.epoch + 1
        setData(unit.ped, 'neon:policeEpoch', unit.epoch)
    end
end

local function avoidOwner(unit)
    if isPlayer(unit.owner) then
        unit.avoid = unit.avoid or {}
        unit.avoid[unit.owner] = now() + 20000
    end
    assignOwner(unit, chooseOwner(unit))
end

-- Make `ped` a unit chasing `s`: shared by cops this resource spawns and
-- street cops taken over from native-ped-traffic.
local function registerUnit(s, ped, tier, street)
    nextUnitId = nextUnitId + 1
    local unit = {id = nextUnitId, ped = ped, suspect = s.player, phase = 'pursue', epoch = 0, createdAt = now(),
                  progressAt = now(), bestDistance = math.huge, stalls = 0, tier = tier, street = street, avoid = {}}
    units[ped] = unit
    s.units[#s.units + 1] = ped
    setData(ped, 'neon:police', true)
    setData(ped, 'neon:ambientPedPopulationClass', 'cop')
    setData(ped, 'neon:policeSuspect', s.player)
    setData(ped, 'neon:policeUnit', unit.id)
    setData(ped, 'neon:policePhase', 'pursue')
    unit.lastX, unit.lastY, unit.lastZ = getElementPosition(ped)
    unit.lastAt = now()
    assignOwner(unit, chooseOwner(unit))
    triggerEvent('onNativePoliceUnitStateChange', ped, s.player, 'pursue')
    return unit
end

local function createUnit(s, x, y, z)
    local level = s.w.level
    local px, py = getElementPosition(s.player)
    local loadout = R.copLoadout(level, R.isArmedWeapon(getPedWeapon(s.player)))
    -- GTA picks the default cop from the player's level (0x407C00).
    local model = loadout.model or R.copModel(level, R.mapLevel(px, py))
    local ped = createPed(model, x, y, z, findRotation(x, y, px, py))
    if not ped then return false end
    -- City cops carry the nightstick and the pistol; the tick picks which is
    -- in hand from the suspect's weapon (the 1-star rule).
    if loadout.model then
        giveWeapon(ped, loadout.weapon, loadout.ammo, true)
    else
        giveWeapon(ped, 22, 1000, not loadout.melee)
        giveWeapon(ped, 3, 1, loadout.melee)
    end
    if loadout.armor > 0 then setPedArmor(ped, loadout.armor) end
    registerUnit(s, ped, loadout.model ~= nil, false)
    return true
end

local function pursuitCap(s)
    return math.min(R.caps[s.w.level].cops, cfg.maxCopsPerSuspect)
end

local function canDispatch(s)
    local active = countUnits()
    return s.w.level > 0 and #aliveUnits(s) < pursuitCap(s) and active < cfg.maxCops
end

-- A suspect cops may go after: the same conditions tickSuspect uses, which
-- include GTA's police back-off (CanCopJoinPursuit 0x562FB0 refuses then).
local function suspectActive(s, t)
    return s.enabled and s.w.level > 0 and isElement(s.player) and not isPedDead(s.player) and
        inMainWorld(s.player) and s.backoffUntil <= (t or now())
end

------------------------------------------------------------------------
-- Street cops (native-ped-traffic) joining the chase.
------------------------------------------------------------------------

-- Solo does not only send new cops: every cop already walking the street
-- joins the pursuit of a wanted player (CTaskComplexWanderCop 0x674D80), up
-- to the level's pursuit cap, a closer cop replacing the farthest one
-- (rules.lua, R.pursuitJoin). Here the traffic resource owns those cops and
-- deliberately keeps them from reacting (GTA's own reaction would read the
-- local player's wanted level), so the police resource takes them over with
-- native-ped-traffic's releaseTrafficCop export. The ped is not recreated:
-- the cop the player sees is the one that comes for him.
local trafficLacksRelease = false
local function trafficRunning()
    if trafficLacksRelease then return false end
    local traffic = getResourceFromName('native-ped-traffic')
    return traffic and getResourceState(traffic) == 'running'
end

local function isStreetCop(ped)
    -- The marker is only a cheap filter; the traffic resource's own record
    -- decides in releaseTrafficCop. The model decides that it is a cop.
    return not units[ped] and getElementData(ped, 'neon:ambientPedTraffic') == true and not isPedDead(ped) and
        not getPedOccupiedVehicle(ped) and R.pedClassForModel(getElementModel(ped)) == 'cop'
end

local function vehicleSpeedSquared(player)
    local vehicle = getPedOccupiedVehicle(player)
    if not vehicle then return nil end
    local vx, vy, vz = getElementVelocity(vehicle)
    return vx * vx + vy * vy + vz * vz
end

local function retireUnit(unit, reason)
    unit.retireReason = reason
    unit.retiredAt = unit.retiredAt or now()
    setPhase(unit, 'disengage')
end

-- Street cops keep their own model and weapons (traffic arms them with the
-- nightstick and a 1000-round pistol, like solo's city cops). The 1-star
-- weapon rule in watchUnit then applies to them as to any city cop.
local function adoptStreetCop(s, ped)
    setElementFrozen(ped, false)
    local model = getElementModel(ped)
    local tier = model == 285 or model == 286 or model == 287
    return registerUnit(s, ped, tier, true)
end

local function recruitStreetCops()
    if not cfg.streetCops or not trafficRunning() then return end
    local t = now()
    local wanted = {}
    for _, s in pairs(suspects) do
        -- Like dispatch, nobody new joins during an arrest: a fresh attack
        -- task would hit a suspect who already has his hands up.
        if suspectActive(s, t) and not s.arrest then wanted[#wanted + 1] = s end
    end
    if #wanted == 0 then return end
    -- Every street cop near a wanted player, with the suspect it would take:
    -- the nearest one it can target (0x68BBD0). Solo does not try a second
    -- player when the nearest one's pursuit is full.
    local seen, candidates = {}, {}
    for _, s in ipairs(wanted) do
        local x, y, z = getElementPosition(s.player)
        for _, ped in ipairs(getElementsWithinRange(x, y, z, cfg.copLostDistance, 'ped', 0, 0)) do
            if not seen[ped] and isStreetCop(ped) then
                seen[ped] = true
                local best, bestDistance
                for _, other in ipairs(wanted) do
                    local d = distance3(ped, other.player)
                    if d <= cfg.copLostDistance and R.footCopCanTarget(d, vehicleSpeedSquared(other.player)) and
                        (not bestDistance or d < bestDistance) then
                        best, bestDistance = other, d
                    end
                end
                if best then candidates[#candidates + 1] = {ped = ped, s = best, distance = bestDistance} end
            end
        end
    end
    -- Closest first, so one pass never takes a cop that a closer one would
    -- displace straight away.
    table.sort(candidates, function(a, b) return a.distance < b.distance end)
    for _, candidate in ipairs(candidates) do
        local s = candidate.s
        local pursuers, list = {}, {}
        for _, ped in ipairs(s.units) do
            local unit = units[ped]
            if unit and unit.phase ~= 'disengage' then
                list[#list + 1] = unit
                pursuers[#pursuers + 1] = {distance = isElement(ped) and distance3(ped, s.player) or math.huge,
                                           alive = isElement(ped) and not isPedDead(ped)}
            end
        end
        local ok, dropped = R.pursuitJoin(pursuitCap(s), pursuers, candidate.distance)
        local active = countUnits()
        if ok and active - #dropped < cfg.maxCops and isElement(candidate.ped) then
            local released = exports['native-ped-traffic']:releaseTrafficCop(candidate.ped)
            if released == nil then
                -- An older traffic build without the export: stop asking (one
                -- warning, not one per second) until it is restarted.
                trafficLacksRelease = true
                return
            end
            if released then
                for _, index in ipairs(dropped) do retireUnit(list[index], 'displaced') end
                adoptStreetCop(s, candidate.ped)
            end
        end
    end
end

addEventHandler('onResourceStart', root, function(resource)
    if getResourceName(resource) == 'native-ped-traffic' then trafficLacksRelease = false end
end)

local function requestSpawn(s)
    nextRequestId = nextRequestId + 1
    local x, y, z = getElementPosition(s.player)
    pendingSpawns[nextRequestId] = {player = s.player, at = now()}
    s.spawnPending = nextRequestId
    s.lastDispatch = now()
    triggerClientEvent(s.player, 'neonPolice:spawnProbe', resourceRoot, nextRequestId, x, y, z)
end

-- The suspect's client proposes a point off its screen. Every other player
-- within 150 m must then confirm it is off their screen too, so a cop never
-- appears in front of anyone.
addEvent('neonPolice:spawnCandidate', true)
addEventHandler('neonPolice:spawnCandidate', resourceRoot, function(id, x, y, z)
    local pending = pendingSpawns[id]
    -- Only the asked client may answer (or consume) its own request.
    if not pending or pending.player ~= client or pending.veto then return end
    local s = suspects[client]
    if not s then pendingSpawns[id] = nil; return end
    local function refuse()
        pendingSpawns[id] = nil
        if s.spawnPending == id then s.spawnPending = false end
    end
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' or x ~= x or y ~= y or z ~= z then return refuse() end
    if s.w.level == 0 or not inMainWorld(client) or isPedDead(client) then return refuse() end
    local px, py, pz = getElementPosition(client)
    local d = getDistanceBetweenPoints3D(px, py, pz, x, y, z)
    if d < 18 or d > 140 or math.abs(pz - z) > 40 then return refuse() end
    local watchers = {}
    for _, player in ipairs(getElementsByType('player')) do
        if player ~= client and inMainWorld(player) then
            local ox, oy, oz = getElementPosition(player)
            local od = getDistanceBetweenPoints3D(ox, oy, oz, x, y, z)
            if od < 18 then return refuse() end
            if od < 150 and ready[player] then watchers[#watchers + 1] = player end
        end
    end
    if not canDispatch(s) then return refuse() end
    if #watchers == 0 then
        refuse()
        createUnit(s, x, y, z)
        return
    end
    local set = {}
    for _, player in ipairs(watchers) do set[player] = true end
    pending.veto = {x = x, y = y, z = z, waiting = #watchers, watchers = set}
    pending.at = now()
    triggerClientEvent(watchers, 'neonPolice:spawnVeto', resourceRoot, id, x, y, z)
end)

addEvent('neonPolice:spawnVetoResult', true)
addEventHandler('neonPolice:spawnVetoResult', resourceRoot, function(id, visible)
    local pending = pendingSpawns[id]
    if not pending or not pending.veto or not pending.veto.watchers[client] then return end
    local veto = pending.veto
    veto.watchers[client] = nil
    veto.waiting = veto.waiting - 1
    local s = suspects[pending.player]
    if visible ~= false or veto.waiting <= 0 then
        pendingSpawns[id] = nil
        if s and s.spawnPending == id then s.spawnPending = false end
    end
    if visible == false and veto.waiting <= 0 and s and canDispatch(s) and inMainWorld(s.player) then
        createUnit(s, veto.x, veto.y, veto.z)
    end
end)

local function destroyUnit(ped)
    local unit = units[ped]
    units[ped] = nil
    if unit then
        local s = suspects[unit.suspect]
        if s then
            for index, other in ipairs(s.units) do
                if other == ped then table.remove(s.units, index); break end
            end
        end
    end
    if isElement(ped) then destroyElement(ped) end
end

-- Retired cops leave only when nobody can see them disappear.
local visibilityChecks, nextVisibilityId = {}, 0
local function probeRetired()
    local retiring = {}
    for ped, unit in pairs(units) do
        if unit.phase == 'disengage' or not isElement(ped) or isPedDead(ped) then retiring[#retiring + 1] = ped end
    end
    if #retiring == 0 then return end
    local t = now()
    -- Hard ceiling: if too many cops are waiting to leave unseen (a watcher
    -- that always answers "visible", say), the oldest go anyway.
    local ceiling = cfg.maxCops * 2
    if #retiring > ceiling then
        table.sort(retiring, function(a, b)
            return ((units[a] and units[a].retiredAt) or 0) < ((units[b] and units[b].retiredAt) or 0)
        end)
        for index = 1, #retiring - ceiling do destroyUnit(retiring[index]) end
    end
    for _, ped in ipairs(retiring) do
        local unit = units[ped]
        if not isElement(ped) then
            destroyUnit(ped)
        elseif t - (unit.retiredAt or t) > 90000 then
            destroyUnit(ped) -- hard limit so a stuck probe can never leak peds
        else
            unit.retiredAt = unit.retiredAt or t
            local x, y, z = getElementPosition(ped)
            local watchers = {}
            for _, player in ipairs(getElementsWithinRange(x, y, z, 150, 'player')) do
                if ready[player] then watchers[#watchers + 1] = player end
            end
            if #watchers == 0 then
                destroyUnit(ped)
            elseif not unit.visibilityCheck then
                nextVisibilityId = nextVisibilityId + 1
                unit.visibilityCheck = nextVisibilityId
                visibilityChecks[nextVisibilityId] = {ped = ped, waiting = #watchers, visible = false, at = t, watchers = {}}
                for _, player in ipairs(watchers) do visibilityChecks[nextVisibilityId].watchers[player] = true end
                triggerClientEvent(watchers, 'neonPolice:visibilityProbe', resourceRoot, nextVisibilityId, ped)
            end
        end
    end
    for id, check in pairs(visibilityChecks) do
        if t - check.at > 3000 then
            visibilityChecks[id] = nil
            if units[check.ped] then units[check.ped].visibilityCheck = nil end
        end
    end
end

addEvent('neonPolice:visibilityResult', true)
addEventHandler('neonPolice:visibilityResult', resourceRoot, function(id, visible)
    local check = visibilityChecks[id]
    if not check or not check.watchers[client] then return end
    check.watchers[client] = nil
    check.waiting = check.waiting - 1
    if visible == true then check.visible = true end
    if check.waiting <= 0 then
        visibilityChecks[id] = nil
        local unit = units[check.ped]
        if unit then
            unit.visibilityCheck = nil
            if not check.visible then destroyUnit(check.ped) end
        end
    end
end)

-- Watchdog: every pursuing cop must close in on its suspect. A stalled cop
-- moves to another owner twice, then is retired and replaced. A cop that
-- jumps faster than it can run is treated as a misbehaving owner.
local function watchUnit(s, unit)
    local ped = unit.ped
    if not isElement(ped) or isPedDead(ped) then
        unit.retiredAt = unit.retiredAt or now()
        unit.retireReason = 'dead'
        setPhase(unit, 'disengage')
        return
    end
    local t = now()
    local x, y, z = getElementPosition(ped)
    local moved = getDistanceBetweenPoints3D(x, y, z, unit.lastX, unit.lastY, unit.lastZ)
    local elapsed = math.max(1, t - unit.lastAt)
    unit.lastX, unit.lastY, unit.lastZ, unit.lastAt = x, y, z, t
    if moved / elapsed * 1000 > 30 and not getPedOccupiedVehicle(ped) then avoidOwner(unit) end
    local d = distance3(ped, s.player)
    if d > cfg.copLostDistance then
        unit.retireReason = 'lost'
        unit.retiredAt = t
        setPhase(unit, 'disengage')
        return
    end
    if unit.phase ~= 'pursue' or d <= 6 then
        unit.progressAt, unit.bestDistance = t, d
    elseif d < unit.bestDistance - 1.5 then
        unit.progressAt, unit.bestDistance = t, d
    elseif t - unit.progressAt > 7000 then
        unit.stalls = unit.stalls + 1
        unit.progressAt, unit.bestDistance = t, d
        if unit.stalls >= 3 then
            unit.retireReason = 'stalled'
            unit.retiredAt = t
            setPhase(unit, 'disengage')
            return
        end
        avoidOwner(unit)
    end
    -- Keep the preferred owner: hand over when a closer non-suspect player
    -- is available or the current owner left.
    if (t - (unit.ownerCheckedAt or 0)) > 3000 then
        unit.ownerCheckedAt = t
        local owner = unit.owner
        local valid = isPlayer(owner) and ready[owner] and inMainWorld(owner) and distance3(owner, ped) <= cfg.ownerRange + 20
        if not valid or owner == s.player then assignOwner(unit, chooseOwner(unit)) end
    end
    -- 1-star rule: nightstick unless the suspect carries a gun.
    if not unit.tier then
        local wantGun = s.w.level >= 2 or R.isArmedWeapon(getPedWeapon(s.player))
        local slot = wantGun and 2 or 1
        if getPedWeaponSlot(ped) ~= slot then setPedWeaponSlot(ped, slot) end
    end
end

------------------------------------------------------------------------
-- Arrest (server-validated, scripted presentation).
------------------------------------------------------------------------

local function nearestArrestingCop(s, maxDistance)
    local best, bestDistance
    for _, unit in ipairs(aliveUnits(s)) do
        local d, dz = distance3(unit.ped, s.player)
        if d <= maxDistance and math.abs(dz) <= 2 and (not bestDistance or d < bestDistance) then best, bestDistance = unit, d end
    end
    return best, bestDistance
end

local busting = {}  -- players in the default outcome's fade and respawn

local function bust(s)
    local player = s.player
    local level = s.w.level
    local fine = R.bustedFine(level)
    local px, py, pz = getElementPosition(player)
    local station = R.nearestStation(px, py, pz)
    s.arrest = nil
    R.clear(s.w, now())
    publish(s, 'busted')
    -- Release the arrest lock and show BUSTED before the event, so a gamemode
    -- that cancels it and locks controls in its handler (jail, cuffs) keeps
    -- its lock.
    triggerClientEvent(player, 'neonPolice:arrestEnd', resourceRoot, true)
    if not triggerEvent('onNativePlayerArrested', player, level, fine, station[5], station[1], station[2], station[3], station[4]) then
        return
    end
    -- Default outcome (CGameLogic): fine by stars, weapons taken, respawn at
    -- the nearest police station. Controls stay locked until the respawn.
    takePlayerMoney(player, math.max(0, math.min(getPlayerMoney(player), fine)))
    takeAllWeapons(player)
    busting[player] = true
    triggerClientEvent(player, 'neonPolice:bustHold', resourceRoot, true)
    fadeCamera(player, false, 1.5)
    setTimer(function()
        busting[player] = nil
        if not isElement(player) then return end
        if not isPedDead(player) then
            spawnPlayer(player, station[1], station[2], station[3], station[4], getElementModel(player), 0, 0)
            setCameraTarget(player, player)
        end
        fadeCamera(player, true, 1.5)
        triggerClientEvent(player, 'neonPolice:bustHold', resourceRoot, false)
    end, 3000, 1)
end

local function beginArrest(s, unit)
    if not triggerEvent('onNativePlayerArrestAttempt', s.player, unit.ped) then
        s.arrestCooldownUntil = now() + 3000
        return
    end
    s.arrest = {cop = unit.ped, at = now()}
    for _, other in ipairs(aliveUnits(s)) do setPhase(other, 'arrest') end
    triggerClientEvent(s.player, 'neonPolice:arrest', resourceRoot, unit.ped, 4000)
end

-- Solo arrests once the suspect is knocked down within 3 m (|dz| <= 2 m), and
-- the radius grows to 4 m once it starts; busted after 4 s. The suspect's
-- client reports "knocked down"; the server also accepts a suspect standing
-- still next to a cop for 2.5 s (a multiplayer rule, so a client that never
-- reports cannot avoid arrest forever).
local function updateArrest(s)
    local player = s.player
    local t = now()
    if s.arrest then
        local cop = s.arrest.cop
        local d, dz = 999, 0
        if isElement(cop) and not isPedDead(cop) then d, dz = distance3(cop, player) end
        if isPedDead(player) or getPedOccupiedVehicle(player) or d > 4 or math.abs(dz) > 2 then
            endArrest(s, false)
        elseif t - s.arrest.at >= 4000 then
            bust(s)
        end
        return
    end
    if s.w.level == 0 or isPedDead(player) or getPedOccupiedVehicle(player) or (s.arrestCooldownUntil or 0) > t then
        s.stillSince = nil
        return
    end
    local unit, d = nearestArrestingCop(s, 3)
    if not unit then s.stillSince = nil; return end
    local vx, vy, vz = getElementVelocity(player)
    local speed = math.sqrt(vx * vx + vy * vy + vz * vz) * 50
    if speed < 0.8 and d <= 2.5 then
        s.stillSince = s.stillSince or t
    else
        s.stillSince = nil
    end
    local down = s.downAt and t - s.downAt < 1500
    if down or (s.stillSince and t - s.stillSince >= 2500) then beginArrest(s, unit) end
end

addEvent('neonPolice:down', true)
addEventHandler('neonPolice:down', resourceRoot, function()
    local s = suspects[client]
    if s and s.w.level > 0 then s.downAt = now() end
end)

------------------------------------------------------------------------
-- Main loop.
------------------------------------------------------------------------

local function inLawVehicleOrAircraft(player)
    local vehicle = getPedOccupiedVehicle(player)
    if not vehicle then return false end
    local vehicleType = getVehicleType(vehicle)
    return R.lawVehicles[getElementModel(vehicle)] == true or vehicleType == 'Helicopter' or vehicleType == 'Plane'
end

local function tickSuspect(s)
    local player = s.player
    local t = now()
    local x, y, z = getElementPosition(player)
    local before = s.w.level
    R.tick(s.w, t, {
        region = R.region(x, y),
        interior = getElementInterior(player) ~= 0,
        policeNearby = policeNear(x, y, z, R.policePresenceDecayRadius, player),
        inLawVehicleOrAircraft = inLawVehicleOrAircraft(player),
    })
    -- The tick also reports queued crimes, so the level can rise here.
    publish(s, s.w.level > before and 'crime' or 'decay')
    local level = s.w.level
    local active = s.enabled and level > 0 and not isPedDead(player) and inMainWorld(player) and s.backoffUntil <= t
    if not active then
        endArrest(s, false)
        if #aliveUnits(s) > 0 then dismissUnits(s, 'inactive') end
        return
    end
    for _, ped in ipairs(s.units) do
        local unit = units[ped]
        if unit and unit.phase ~= 'disengage' then watchUnit(s, unit) end
    end
    updateArrest(s)
    -- A request that was answered, refused or never answered must not block
    -- the next dispatch.
    local pending = s.spawnPending and pendingSpawns[s.spawnPending]
    if s.spawnPending and (not pending or t - pending.at > 2500) then
        pendingSpawns[s.spawnPending] = nil
        s.spawnPending = false
    end
    if not s.spawnPending and not s.arrest and ready[player] and canDispatch(s) and
        t - s.lastDispatch >= (cfg.dispatchDelay[level] or 2000) then
        requestSpawn(s)
    end
end

local function forgetPlayer(player)
    local s = suspects[player]
    if s then
        dismissUnits(s, 'quit')
        for _, ped in ipairs(s.units) do
            local unit = units[ped]
            if unit then unit.suspect = false end
        end
    end
    suspects[player] = nil
    ready[player] = nil
    reportBudget[player] = nil
    for id, pending in pairs(pendingSpawns) do
        if pending.player == player then pendingSpawns[id] = nil end
    end
end

addEvent('neonPolice:ready', true)
addEventHandler('neonPolice:ready', resourceRoot, function()
    ready[client] = true
    suspectOf(client)
end)

addEventHandler('onPlayerQuit', root, function() forgetPlayer(source) end)

-- Wasted clears the wanted level, as in solo. The hospital outcome belongs to
-- the gamemode.
addEventHandler('onPlayerWasted', root, function(_, killer, weapon)
    if killer and killer ~= source then reportDamage(killer, source, weapon, 'player-wasted') end
    local s = suspects[source]
    if s then
        endArrest(s, false)
        R.clear(s.w, now())
        publish(s, 'wasted')
    end
end)

addEventHandler('onResourceStart', resourceRoot, function()
    setData(resourceRoot, 'neon:policeConfig', {overheadStars = cfg.overheadStars, bustedText = cfg.bustedText})
    for _, player in ipairs(getElementsByType('player')) do suspectOf(player) end
    setTimer(function()
        for player, s in pairs(suspects) do
            if isElement(player) then tickSuspect(s) else suspects[player] = nil end
        end
        -- A cop whose suspect quit has nobody to chase.
        for ped, unit in pairs(units) do
            if not unit.suspect and unit.phase ~= 'disengage' then
                unit.retiredAt = now()
                setPhase(unit, 'disengage')
            end
        end
    end, 250, 0)
    setTimer(probeRetired, 2000, 0)
    setTimer(recruitStreetCops, 1000, 0)
end)

addEventHandler('onResourceStop', resourceRoot, function()
    for player in pairs(busting) do
        if isElement(player) then fadeCamera(player, true, 0.5) end
    end
    for ped in pairs(units) do
        if isElement(ped) then destroyElement(ped) end
    end
    for player, s in pairs(suspects) do
        if isElement(player) and s.published > 0 then
            setPlayerWantedLevel(player, 0)
            removeElementData(player, 'neon:wantedLevel')
        end
    end
end)

------------------------------------------------------------------------
-- Exports (see README.md).
------------------------------------------------------------------------

function reportNativeCrime(offender, crimeType, victim)
    crimeType = tonumber(crimeType)
    if not crimeType or crimeType ~= math.floor(crimeType) then return false end
    return reportCrime(offender, crimeType, isElement(victim) and victim or nil, 'export')
end

function getNativeWantedState(player)
    local s = isPlayer(player) and suspectOf(player)
    if not s then return false end
    return {
        level = s.w.level, chaos = s.w.chaos, maximum = s.w.maximum, enabled = s.enabled,
        units = #aliveUnits(s), arrest = s.arrest ~= nil, parole = s.w.paroleAt ~= false,
        backoff = s.backoffUntil > now(),
    }
end

function setNativeWantedEnabled(player, enabled)
    local s = isPlayer(player) and suspectOf(player)
    if not s or type(enabled) ~= 'boolean' then return false end
    s.enabled = enabled
    if not enabled then
        endArrest(s, false)
        R.clear(s.w, now())
        publish(s, 'disabled')
    end
    return true
end

-- reason 'parole' is Pay 'n' Spray: any crime in the next 20 s restores the
-- previous level.
function clearNativeWanted(player, reason)
    local s = isPlayer(player) and suspectOf(player)
    if not s then return false end
    endArrest(s, false)
    if reason == 'parole' then R.clearOnParole(s.w, now()) else R.clear(s.w, now()) end
    publish(s, type(reason) == 'string' and reason or 'cleared')
    return true
end

function setNativeWantedLevel(player, level)
    local s = isPlayer(player) and suspectOf(player)
    level = tonumber(level)
    if not s or not level or level < 0 or level > 6 then return false end
    R.setLevel(s.w, level, now())
    publish(s, 'script')
    return true
end

function setNativeWantedMaximum(player, level)
    local s = isPlayer(player) and suspectOf(player)
    level = tonumber(level)
    if not s or not level or level < 0 or level > 6 then return false end
    R.setMaximum(s.w, level, now())
    publish(s, 'maximum')
    return true
end

function getNativePoliceUnits(player)
    local s = isPlayer(player) and suspects[player]
    local list = {}
    if s then
        for _, unit in ipairs(aliveUnits(s)) do list[#list + 1] = unit.ped end
    end
    return list
end

-- Cops break off for `duration` ms (missions, cutscenes). Stars stay.
function requestNativePoliceBackoff(player, duration)
    local s = isPlayer(player) and suspectOf(player)
    duration = tonumber(duration)
    if not s or not duration or duration < 0 or duration > 600000 then return false end
    s.backoffUntil = now() + duration
    endArrest(s, false)
    dismissUnits(s, 'backoff')
    return true
end

for _, name in ipairs({'onNativeCrimeValidated', 'onNativeCrimeReported', 'onNativeWantedLevelChange',
                       'onNativePoliceUnitStateChange', 'onNativePlayerArrestAttempt', 'onNativePlayerArrested',
                       'onNativeSuspectEscaped'}) do
    addEvent(name, false)
end
