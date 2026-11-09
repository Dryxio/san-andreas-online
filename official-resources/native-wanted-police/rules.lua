-- Wanted rules shared by the server ledger, the client and the tests.
--
-- Why this file exists: Neon cannot switch GTA's own police back on. GTA keeps
-- a single wanted level (the local player's), every remote player and script
-- ped points at it (Client/game_sa/CPlayerPedSA.cpp), and the retail cop tasks
-- expect real CCopPed objects. So the server keeps one wanted ledger per
-- player instead, and this file reproduces GTA's own rules for it.
--
-- Every number below was read in the GTA SA 1.0 US binary (gta_sa.exe), not
-- taken from gta-reversed, which has known mistakes here (issue #91):
--   CWanted::ReportCrimeNow        0x562120  crime weights (jump table 0x5622A0)
--   CWanted::UpdateWantedLevel     0x561C90  star thresholds and pursuit caps
--   CWanted::SetWantedLevel        0x562470  chaos set for a forced level
--   CWanted::SetWantedLevelNoDrop  0x562570  minimum level, parole restore
--   CWanted::SetMaximumWantedLevel 0x561E70  chaos ceiling per maximum level
--   CWanted::ClearWantedLevelAndGoOnParole 0x5625A0
--   CWanted::AddCrimeToQ           0x562000  16 entries, dedupe (type, victim)
--   CWanted::UpdateCrimesQ         0x562760  report after 500 ms, free after 10 s
--   CWanted::Update                0x562C90  decay, parole expiry, queue tick
--   CCrime::ReportCrime            0x532010  presence radius, minimum stars
--   CCrime::FindImmediateDetectionRange 0x531FC0 (14 / 30 / 60 m)
--   CWeather::UpdateWeatherRegion  0x72A640  LA/SF/LV/desert/countryside boxes
--   police restart points          main.scm opcode 016D (7 stations)
--   CRestart::FindClosestPoliceRestartPoint 0x460A50 (x6 across levels)
--   default cop model by level     0x407C00, table 0x8A5AA0 (283/280/281/282)
--   level boxes                    data/map.zon (Vegas, SF01-03, LA01-02)
--   CEventDamage::ReportCriminalEvent 0x4B3440 (damage -> queued crime)
--   GenerateDamageEvent 0x73A530, CWeapon::DoBulletImpact 0x73B550,
--   CPed::KillPedWithCar 0x5F0360, explosions 0x567750: direct reports
--   CVehicle::IsLawEnforcementVehicle 0x6D2370
--   street cops joining: WanderCop 0x674D80, CanCopJoinPursuit 0x562F60,
--   ComputePursuitCopToDisplace 0x562B00, PolicePursuit::SetPursuit 0x68BBD0
--
-- The module is plain Lua 5.1 with no MTA calls so the tests can run it.
NativeWantedRules = {}
local R = NativeWantedRules

R.crime = {
    FIRE_WEAPON = 1, DAMAGE_PED = 2, DAMAGE_COP = 3, SHOOT_PED = 4, SHOOT_COP = 5,
    STEAL_CAR = 6, RUN_RED_LIGHT = 7, DAMAGE_COP_CAR = 8, SPEEDING = 9,
    RUN_OVER_PED = 10, RUN_OVER_COP = 11, DESTROY_HELI = 12, PED_BURNED = 13,
    COP_BURNED = 14, CAR_BURNED = 15, DESTROY_PLANE = 16, EXPLOSION = 17,
    STAB_PED = 18, STAB_COP = 19, DESTROY_VEHICLE = 20, PUNCH_VEHICLE = 21,
    AIM_AT_COP = 22,
}

-- Chaos added per crime (ReportCrimeNow). Type 1 (firing a weapon) adds
-- nothing on its own: it only matters when police are within range.
R.weights = {
    [1] = 0, [2] = 5, [3] = 45, [4] = 30, [5] = 80, [6] = 15, [7] = 10, [8] = 5, [9] = 5,
    [10] = 18, [11] = 80, [12] = 400, [13] = 20, [14] = 80, [15] = 20, [16] = 400,
    [17] = 25, [18] = 35, [19] = 100, [20] = 70, [21] = 2, [22] = 2,
}

-- UpdateWantedLevel uses signed "jl" branches, so each threshold is inclusive.
R.thresholds = {50, 180, 550, 1200, 2400, 4600}
R.defaultMaximumChaos = 9200

-- Chaos written by SetWantedLevel(n) and the ceiling set by
-- SetMaximumWantedLevel(n).
R.levelChaos = {[0] = 0, 70, 200, 570, 1220, 2420, 4620}
R.maximumChaos = {[0] = 0, 115, 365, 875, 1800, 3500, 6900}

-- Pursuit caps written by UpdateWantedLevel. They are ceilings, not spawn
-- orders: solo does not create this many cops at once.
R.caps = {
    [0] = {cops = 0, cars = 0, roadblock = 0},
    [1] = {cops = 1, cars = 1, roadblock = 0},
    [2] = {cops = 3, cars = 2, roadblock = 0},
    [3] = {cops = 4, cars = 2, roadblock = 12},
    [4] = {cops = 6, cars = 2, roadblock = 18},
    [5] = {cops = 8, cars = 3, roadblock = 24},
    [6] = {cops = 10, cars = 3, roadblock = 30},
}

-- Street cops joining a pursuit. In solo every wandering cop
-- (CTaskComplexWanderCop::ControlSubTask 0x674D80, via 0x66B160) switches to
-- CTaskComplexPolicePursuit while the player is wanted, if the pursuit list
-- accepts it. There is no distance limit beyond the cop existing.
--
-- CWanted::CanCopJoinPursuit 0x562F60 with ComputePursuitCopToDisplace
-- 0x562B00: refused when the cap is 0; while the list is full, a dead
-- pursuer is displaced first (slot order), otherwise the pursuer farthest
-- from the player, and only if it is farther than the newcomer (squared
-- distances, the newcomer's raised to at least 1.0: 0x858624). No candidate
-- means the newcomer does not join.
-- pursuers: array of {distance = metres, alive = bool}. Returns ok and the
-- indices of the pursuers to drop.
function R.pursuitJoin(cap, pursuers, distance)
    if not cap or cap <= 0 then return false, {} end
    local list, count = {}, 0
    for index, p in ipairs(pursuers) do list[index] = p; count = count + 1 end
    local newcomer = math.max(1.0, distance * distance)
    local dropped = {}
    while count >= cap do
        local pick
        local farthest = newcomer
        for index = 1, #pursuers do
            local p = list[index]
            if p then
                if not p.alive then pick = index; break end
                local d = p.distance * p.distance
                if d > farthest then pick, farthest = index, d end
            end
        end
        if not pick then return false, {} end
        list[pick] = false
        count = count - 1
        dropped[#dropped + 1] = pick
    end
    return true, dropped
end

-- CTaskComplexPolicePursuit::SetPursuit 0x68BBD0: the cop takes the nearest
-- player (range FLT_MAX at 0x863A3C). A player in a vehicle is only taken
-- while |move speed|^2 * distance^2 < 16 (0x8599D0); move speed is GTA's
-- per-step velocity, the unit getElementVelocity returns. A foot cop does not
-- chase a car going past, but does go for one that stops.
R.pursuitVehicleLimit = 16
function R.footCopCanTarget(distance, vehicleSpeedSquared)
    if not vehicleSpeedSquared then return true end
    return vehicleSpeedSquared * distance * distance < R.pursuitVehicleLimit
end

-- Police car mission (CCarAI::FindPoliceCarMissionForWantedLevel 0x41C9D0):
-- 2 = ram, 4 = block, from rand() & 3. 0-1 star always block; 2 stars block
-- unless the roll is 3 (3 in 4); 3 stars block on 0-1 (1 in 2); 4-6 stars
-- block only on 0 (1 in 4). Solo's 2/4 target the local player, so Neon
-- sends the car-target equivalents (15/17, see setPedDriveMission).
-- roll: an integer 0-3.
function R.policeCarMission(level, roll)
    roll = roll % 4
    if level == 2 then return roll < 3 and 'block' or 'ram' end
    if level == 3 then return roll < 2 and 'block' or 'ram' end
    if level >= 4 and level <= 6 then return roll == 0 and 'block' or 'ram' end
    return 'block'
end

------------------------------------------------------------------------
-- Police cars (version 2). Read in the binary:
--   CCarCtrl::GenerateOneRandomCar 0x430050 (police branch 0x43016A-0x430223)
--   police car model 0x421980, default cop car 0x407C50 (tables 0x8A5A8C /
--   0x8A5AA0), occupants CCarAI::AddPoliceCarOccupants 0x41C070, cruise
--   speed 0x41CAA0, mission 0x41C9D0, chase CCarAI::UpdateCarAI 0x41DA30,
--   close-range slowdown 0x41D3D0, CTaskComplexCopInCar 0x68FA50/0x68FD50.
------------------------------------------------------------------------

-- Dispatch: never below 2 stars. A new car needs fewer cars in pursuit than
-- the cap (R.caps.cars), fewer cops in pursuit than R.caps.cops, and time
-- since the last police car: more than 8 s at 2 stars, 5 s at 3, none at 4+.
R.carDispatchDelay = {[2] = 8000, [3] = 5000}
function R.canDispatchCar(level, carsInPursuit, copsInPursuit, sinceLastCar)
    if level < 2 or level > 6 then return false end
    if carsInPursuit >= R.caps[level].cars or copsInPursuit >= R.caps[level].cops then return false end
    return sinceLastCar > (R.carDispatchDelay[level] or -1)
end

-- Default cop car by map level (0x8A5A8C): Ranger in the countryside,
-- LSPD, SFPD, LVPD; the matching cop is R.levelCopModel (0x8A5AA0).
R.areaCopCar = {[0] = 599, [1] = 596, [2] = 597, [3] = 598}

-- 0x421980: at 4 stars (SWAT) an Enforcer when rand(0,3) == 2, else the
-- default car; at 5 (FBI) always the FBI Rancher; at 6 (army) Barracks when
-- rand() < 0x3FFF, else the Rhino. roll3: 0-2, rollHalf: boolean.
-- The default car is the HPV1000 police bike (523) while the cop-bike switch
-- is on (0x407C50 reads 0x9654BE); see R.copBikeSwitch.
function R.policeCarModel(level, mapLevel, roll3, rollHalf, bikeOn)
    if level == 4 and roll3 == 2 then return 427 end
    if level == 5 then return 490 end
    if level == 6 then return rollHalf and 433 or 432 end
    if bikeOn and level < 3 then return 523 end
    return R.areaCopCar[mapLevel] or 599
end

-- The cop-bike switch (0x40A150, run with the streaming of the default cop
-- models): it is forced off at 3 stars and above and in the countryside (map
-- level 0); otherwise it flips every 30-50 s (rand(30000, 50000), 0x40A1A9).
-- So in a city at 2 stars about half of the police vehicles are bikes.
-- state: {on = boolean, flipAt = ms}. roll: 0-1. Returns the state.
function R.copBikeSwitch(state, level, mapLevel, now, roll)
    if level >= 3 or mapLevel == 0 then
        state.on = false
    elseif now >= (state.flipAt or 0) then
        state.on = not state.on
        state.flipAt = now + 30000 + math.floor(roll * 20000)
    end
    return state
end

-- 0x41C070: who rides in each model (MTA seats; 0 is the driver) and which
-- cop. Enforcer and FBI Rancher fill four seats; the Rhino only a driver;
-- cop cars and the Barracks a driver and a front passenger (above 1 star,
-- always the case for a dispatched car).
function R.policeCarCrew(model, mapLevel)
    if model == 427 then return {0, 1, 2, 3}, 285 end
    if model == 490 then return {0, 1, 2, 3}, 286 end
    if model == 432 then return {0}, 287 end
    -- The bike shares the Rhino's case (driver only); its rider is the
    -- motorbike cop 284 (0x8A5A9C).
    if model == 523 then return {0}, 284 end
    if model == 433 then return {0, 1}, 287 end
    return {0, 1}, R.levelCopModel[mapLevel] or 280
end

-- Above 2 stars, cop cars and the Barracks: a 25 % roll gives the driver a
-- shotgun (25, 1000 rounds, 0x5E89B0); if it fails, a second 25 % roll gives
-- it to the passenger. Returns the seat that gets it, or nil.
function R.policeCarShotgunSeat(level, model, rollDriver, rollPassenger)
    if level <= 2 or not (model == 433 or (model >= 596 and model <= 599)) then return nil end
    if rollDriver < 0.25 then return 0 end
    if rollPassenger < 0.25 then return 1 end
    return nil
end

-- Cruise speed (0x41CAA0): 25 at 1 star, 34 at 2; at 3-6 handling+0x88
-- times 54, 72, 75, 78. UpdateCarAI writes it again every frame during a
-- chase.
-- handling+0x88 is the top speed cHandlingDataMgr::ConvertDataToGameUnits
-- (0x6F5080) works out from handling.cfg, in game units (km/h / 180):
-- starting at fMaxVelocity / 180 it steps down by 0.01 until the engine
-- (fEngineAcceleration x 0.0004 / 6) beats the drag at that speed
-- (fDragMult / 1000 x 0.5 x v^2; below 0.01 drag, v (1 - 1 / (1 + drag v^2))).
-- The step comes first, so the result is at least 0.01 below fMaxVelocity.
-- With handling flag 0x1000000 (OFFROAD_ABILITY) it is fMaxVelocity / 180 x
-- 0.8333 instead. The server's getVehicleHandling gives handling.cfg units.
function R.handlingTopSpeed(maxVelocityKmh, engineAcceleration, dragCoeff, handlingFlags)
    local top = (maxVelocityKmh or 160) / 180
    if handlingFlags and math.floor(handlingFlags / 0x1000000) % 2 == 1 then return top * 0.8333333 end
    local push = (engineAcceleration or 20) * 0.0004 / 6
    local drag = dragCoeff or 2
    local v = top
    while v > 0 do
        v = v - 0.01
        local force
        if drag < 0.01 then
            force = -(1 / (1 + drag * v * v) - 1) * v
        else
            force = drag / 1000 * 0.5 * v * v
        end
        if push >= force then break end
    end
    return math.max(v, 0)
end

R.carSpeedFactor = {[3] = 54, [4] = 72, [5] = 75, [6] = 78}
function R.policeCarSpeed(level, topSpeed)
    if level <= 1 then return 25 end
    if level == 2 then return 34 end
    local speed = (topSpeed or 160 / 180) * (R.carSpeedFactor[math.min(level, 6)] or 54)
    return math.max(1, math.min(speed, 254))
end

-- 0x41D3D0, only once the car is in close range: at 1-2 stars the car slows
-- down near the suspect (3D distance). Any level: a suspect on foot moving
-- slower than 0.07 within 30 m caps the speed at 10. speedUnits is the
-- suspect's speed in GTA units per step (getElementVelocity).
function R.policeCarCloseSpeed(level, speed, onFoot, distance, speedUnits)
    if level == 1 or level == 2 then
        local far = level == 1 and 25 or 34
        if onFoot then
            if distance < 20 then speed = 5 elseif distance < 40 then speed = level == 1 and 13 or 18 else speed = far end
        else
            if distance < 10 then speed = level == 1 and 15 or 27 elseif distance < 20 then speed = level == 1 and 22 or 30 else speed = far end
        end
    end
    if onFoot and (speedUnits or 0) < 0.07 and distance < 30 then speed = math.min(speed, 10) end
    return speed
end

-- The autopilot switches to the close mission under 20 m (vehicle+0x3DD
-- default) and back above FindSwitchDistanceFar (0x41BF70): 50 m for a car
-- flagged bIsLawEnforcer, +0x3DD + 5 = 25 m otherwise. A script-created
-- vehicle is never flagged (SetIsLawEnforcer 0x6D2330 is only called by
-- GTA's own population and mission code), which also keeps UpdateCarAI's
-- local-player police branches off these cars. So 25 m is where the native
-- mission really switches back, and the siren and the close-range speed
-- follow it.
R.carCloseDistance = 20
R.carFarDistance = 25

-- Cops get out (UpdateCarAI, close missions, then 0x41C760) when the car is
-- within 10 m (2D) of the suspect and the suspect is on foot, his vehicle is
-- upside down (up.z < -0.9), or it has stayed slow for more than 2.5 s. Not
-- from a Rhino, unless its random seed is above 10000.
-- "Slow" is counted per police car (vehicle+0x4DC), only while that car is
-- in its close mission, and is reset as soon as the suspect is faster: under
-- 0.05 per step (about 2.5 m/s) in the ram-close mission (0x41DE42), under
-- 0.04 (about 2 m/s) in the block-close mission (0x41E1AD).
R.bailDistance = 10
R.bailSlowSpeed = 0.05
R.bailSlowTime = 2500
function R.bailSlowSpeedFor(mission)
    return mission == 'block' and 0.04 or 0.05
end
function R.shouldBail(distance2D, onFoot, upsideDown, slowFor)
    if distance2D >= R.bailDistance then return false end
    return onFoot or upsideDown or (slowFor or 0) > R.bailSlowTime
end

-- CTaskComplexCopInCar 0x68FD50: the passenger leaves at once; the driver
-- waits 3000 + rand(0, 2000) ms (250 + rand(0, 1250) once he has driven
-- again after getting out). He stays at the wheel and resumes the chase if
-- the suspect's vehicle gets away (0x68FF6A-0x68FF9C). Both tests use
-- squared lengths (0x406DA0): |v|^2 x timeStep x 50 > 1, so faster than
-- about 0.141 per step (7 m/s) at 50 fps, or the suspect's vehicle more than
-- 10 m (d^2 > 100) from the cop himself. The same test lets the driver
-- (never a passenger) get back in (0x690179-0x6901BC): suspect in another
-- vehicle that gets away, cop within 4 m of his car (d^2 < 16), car neither
-- upside down (up.z < -0.9, 0x6D1D90) nor on its side (|right.z| >= 0.8,
-- 0x6D1DD0).
function R.driverExitDelay(reentered, roll)
    if reentered then return 250 + math.floor(roll * 1250) end
    return 3000 + math.floor(roll * 2000)
end
R.suspectCarFarDistance = 10
R.reenterDistance = 4
function R.suspectCarGetsAway(speedUnits, distance)
    return speedUnits * speedUnits * 50 > 1.0 or distance > R.suspectCarFarDistance
end

R.queueSize = 16
R.queueReportDelay = 500
R.queueLifetime = 10000
R.decayInterval = 1000
R.paroleDuration = 20000
R.policePresenceDecayRadius = 18

-- FindImmediateDetectionRange: 3D police-presence radius around the offender.
-- No line of sight is involved and no civilian witness is required.
function R.detectionRange(crimeType)
    if crimeType == 12 or crimeType == 16 or crimeType == 17 then return 60 end
    if crimeType == 20 then return 30 end
    return 14
end

-- Direct minimum stars applied by ReportCrime whatever the chaos.
function R.minimumLevel(crimeType)
    if crimeType == 3 then return 1 end
    if crimeType == 5 or crimeType == 19 then return 2 end
    return 0
end

function R.levelForChaos(chaos)
    local level = 0
    for index, threshold in ipairs(R.thresholds) do
        if chaos >= threshold then level = index end
    end
    return level
end

function R.new(now)
    return {
        chaos = 0, level = 0, maximum = 6, maximumChaos = R.defaultMaximumChaos,
        paroleChaos = 0, paroleLevel = 0, paroleAt = false,
        lastDecay = now or 0, levelChangedAt = now or 0,
        queue = {},
        -- Multiplayer addition: one hit can arrive from several evidence
        -- sources (bullet sync, the victim's syncer, the death event). GTA's
        -- queue would forget it when SetWantedLevel clears the queue, so the
        -- same (type, victim) is also remembered here for the queue's 10 s.
        recent = {},
    }
end

local function updateLevel(w, now)
    if w.chaos > w.maximumChaos then w.chaos = w.maximumChaos end
    if w.chaos < 0 then w.chaos = 0 end
    local old = w.level
    w.level = R.levelForChaos(w.chaos)
    if w.level > w.maximum then w.level = w.maximum end
    if w.level ~= old then w.levelChangedAt = now or w.levelChangedAt end
    return old ~= w.level
end

-- SetWantedLevel: capped at the maximum, clears the crime queue.
function R.setLevel(w, level, now)
    level = math.max(0, math.min(math.floor(level), w.maximum))
    w.queue = {}
    w.chaos = R.levelChaos[level]
    return updateLevel(w, now)
end

-- SetWantedLevelNoDrop: first restores the level held before parole, then
-- raises to the requested minimum. Never lowers.
function R.setLevelNoDrop(w, level, now)
    local changed = false
    if w.level < w.paroleLevel then changed = R.setLevel(w, w.paroleLevel, now) or changed end
    if w.level < level then changed = R.setLevel(w, level, now) or changed end
    return changed
end

function R.setMaximum(w, level, now)
    level = math.max(0, math.min(math.floor(level), 6))
    -- An explicit maximum of 6 really is 6900 chaos in the binary; only a
    -- ledger that was never capped keeps the startup ceiling of 9200.
    -- 0x561E70 only stores the caps; the level follows on the next update.
    w.maximum = level
    w.maximumChaos = R.maximumChaos[level]
    return false
end

-- ClearWantedLevelAndGoOnParole: Pay 'n' Spray. Any crime in the next 20 s
-- brings back the old chaos (ReportCrimeNow keeps max(chaos, parole chaos)).
function R.clearOnParole(w, now)
    -- 0x5625A0 leaves the crime queue alone: a crime queued before the
    -- spray still reports afterwards and restores the old chaos.
    w.paroleChaos, w.paroleLevel, w.paroleAt = w.chaos, w.level, now
    w.chaos = 0
    return updateLevel(w, now)
end

function R.clear(w, now)
    w.paroleChaos, w.paroleLevel, w.paroleAt = 0, 0, false
    w.chaos = 0
    w.queue = {}
    w.recent = {}
    return updateLevel(w, now)
end

-- ReportCrimeNow. options.policeDontCare is GTA's flag for victims of ped
-- type gang 1-10, dealer or criminal (CPedType check 0x608A40): x0.333.
function R.reportNow(w, crimeType, options, now)
    local weight = R.weights[crimeType]
    if weight and weight > 0 then
        local multiplier = 1
        if options and options.policeDontCare then multiplier = multiplier * 0.333 end
        if options and options.multiplier then multiplier = multiplier * options.multiplier end
        w.chaos = w.chaos + math.floor(weight * multiplier)
    end
    if w.chaos < w.paroleChaos then w.chaos = w.paroleChaos end
    return updateLevel(w, now)
end

local function findQueued(w, crimeType, victimKey)
    for _, entry in ipairs(w.queue) do
        if entry.crimeType == crimeType and entry.victim == victimKey then return entry end
    end
end

-- CCrime::ReportCrime + AddCrimeToQ. Returns changed, immediate.
--   options.policePresent: police within detectionRange(type) of the offender
--   options.policeDontCare: see reportNow
-- A duplicate (type, victim) inside the 10 s window is ignored once reported;
-- an unreported duplicate is promoted when police are now present.
function R.report(w, crimeType, victimKey, options, now)
    if not R.weights[crimeType] then return false, false end
    options = options or {}
    local changed, immediate = false, false
    local entry = findQueued(w, crimeType, victimKey)
    local key = tostring(crimeType) .. ':' .. tostring(victimKey)
    for oldKey, at in pairs(w.recent) do
        if now - at > R.queueLifetime then w.recent[oldKey] = nil end
    end
    if not entry and w.recent[key] then
        -- Already counted: ReportCrime still applies its minimum stars.
        if not options.queueOnly then
            if options.policePresent then changed = R.setLevelNoDrop(w, 1, now) end
            local minimum = R.minimumLevel(crimeType)
            if minimum > 0 then changed = R.setLevelNoDrop(w, minimum, now) or changed end
        end
        return changed, false
    end
    w.recent[key] = w.recent[key] or now
    if options.queueOnly then
        -- CWanted::RegisterCrime (0x562410): queue only, no police check and
        -- no minimum stars. Used for damage events (ReportCriminalEvent).
        if not entry and #w.queue < R.queueSize then
            w.queue[#w.queue + 1] = {crimeType = crimeType, victim = victimKey, at = now, reported = false,
                                     policeDontCare = options.policeDontCare}
        end
        return false, false
    end
    if options.policePresent then
        if not entry then
            if #w.queue < R.queueSize then
                w.queue[#w.queue + 1] = {crimeType = crimeType, victim = victimKey, at = now, reported = true,
                                         policeDontCare = options.policeDontCare}
            end
            changed = R.reportNow(w, crimeType, options, now)
            immediate = true
        elseif not entry.reported then
            entry.reported = true
            changed = R.reportNow(w, crimeType, options, now)
            immediate = true
        end
        -- ReportCrime calls SetWantedLevelNoDrop(1) even for a duplicate.
        changed = R.setLevelNoDrop(w, 1, now) or changed
    elseif not entry and #w.queue < R.queueSize then
        -- A full queue drops the crime, as AddCrimeToQ does.
        w.queue[#w.queue + 1] = {crimeType = crimeType, victim = victimKey, at = now, reported = false,
                                 policeDontCare = options.policeDontCare}
    end
    local minimum = R.minimumLevel(crimeType)
    if minimum > 0 then changed = R.setLevelNoDrop(w, minimum, now) or changed end
    return changed, immediate
end

-- UpdateCrimesQ: report queued crimes older than 500 ms, free after 10 s.
function R.updateQueue(w, now)
    local changed = false
    local kept = {}
    for _, entry in ipairs(w.queue) do
        if not entry.reported and now - entry.at > R.queueReportDelay then
            entry.reported = true
            changed = R.reportNow(w, entry.crimeType, {policeDontCare = entry.policeDontCare}, now) or changed
        end
        if now - entry.at <= R.queueLifetime then kept[#kept + 1] = entry end
    end
    w.queue = kept
    return changed
end

-- CWeather::UpdateWeatherRegion boxes (floats read from .rdata).
function R.region(x, y)
    if x > 1000 and y > 910 then return 'lv' end
    if x > -850 and x < 1000 and y > 1280 then return 'desert' end
    if x < -1430 and y > -580 and y < 1430 then return 'sf' end
    if x > 250 and x < 3000 and y > -3000 and y < -850 then return 'la' end
    return 'countryside'
end

-- CWanted::Update, run about once a second.
--   env.region: R.region of the suspect
--   env.interior: true when the suspect is inside an interior
--   env.policeNearby: police within 18 m (WorkOutPolicePresence)
--   env.inLawVehicleOrAircraft: law-enforcement vehicle, helicopter or plane
-- 1 star always decays (-1/s, -2/s in countryside or desert). 2+ stars only
-- decay outside, in countryside or desert (-2/s). Both need no police within
-- 18 m and not riding a police vehicle or aircraft. No line of sight is used.
function R.tick(w, now, env)
    local changed = false
    if w.paroleAt and w.paroleAt + R.paroleDuration < now then
        w.paroleChaos, w.paroleLevel, w.paroleAt = 0, 0, false
    end
    if now - w.lastDecay <= R.decayInterval then return false end
    env = env or {}
    local rural = env.region == 'countryside' or env.region == 'desert'
    if w.level < 2 or (rural and not env.interior) then
        if env.inLawVehicleOrAircraft then
            w.lastDecay = now
        elseif not env.policeNearby then
            w.lastDecay = now
            if w.chaos > 0 then
                w.chaos = w.chaos - (rural and 2 or 1)
                changed = updateLevel(w, now) or changed
            end
        end
        -- Police within 18 m: the binary leaves the decay timestamp alone,
        -- so the check (and the crime queue) runs again on the next tick.
    else
        w.lastDecay = now
    end
    changed = R.updateQueue(w, now) or changed
    return changed
end

-- CGameLogic busted fine by wanted level (issue #91, binary-checked there).
R.bustedFines = {[0] = 100, 100, 200, 400, 600, 900, 1500}
function R.bustedFine(level) return R.bustedFines[math.max(0, math.min(6, level or 0))] end

-- Police restart points from main.scm (opcode 016D): x, y, z, heading.
R.policeStations = {
    {1550.68, -1675.49, 14.51, 90.0, 'Los Santos'},
    {632.23, -571.71, 15.35, 267.2, 'Dillimore'},
    {-2163.83, -2387.82, 29.62, 134.21, 'Angel Pine'},
    {-1605.79, 716.86, 11.02, 355.3, 'San Fierro'},
    {-212.19, 979.42, 18.32, 278.05, 'Fort Carson'},
    {-1393.07, 2633.12, 54.95, 86.04, 'El Quebrados'},
    {2337.08, 2453.8, 13.98, 90.76, 'Las Venturas'},
}

-- 0x460A50: 3D distance, times 6 when the player is in a city level and the
-- station is in another level (so a busted player stays on their island).
function R.nearestStation(x, y, z)
    local best, bestDistance
    local level = R.mapLevel(x, y)
    for _, station in ipairs(R.policeStations) do
        local dx, dy, dz = station[1] - x, station[2] - y, station[3] - z
        local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
        if level ~= 0 and R.mapLevel(station[1], station[2]) ~= level then distance = distance * 6 end
        if not bestDistance or distance < bestDistance then best, bestDistance = station, distance end
    end
    return best
end

-- Map levels (CTheZones), from the level boxes in data/map.zon:
-- 0 countryside, 1 Los Santos, 2 San Fierro, 3 Las Venturas.
R.levelBoxes = {
    {685.0, 476.093, 3000.0, 3000.0, 3},          -- Vegas
    {-3000.0, -742.306, -1270.53, 1530.24, 2},    -- SF01
    {-1270.53, -402.481, -1038.45, 832.495, 2},   -- SF02
    {-1038.45, -145.539, -897.546, 376.632, 2},   -- SF03
    {480.0, -3000.0, 3000.0, -850.0, 1},          -- LA01
    {80.0, -2101.61, 1075.0, -1239.61, 1},        -- LA02
}
function R.mapLevel(x, y)
    for _, box in ipairs(R.levelBoxes) do
        if x >= box[1] and x <= box[3] and y >= box[2] and y <= box[4] then return box[5] end
    end
    return 0
end

-- Default cop model by the player's level (0x407C00 / 0x8A5AA0), then the
-- response tier GTA requires at exactly 4 (SWAT), 5 (FBI) and 6 (army) stars
-- (AreSwatRequired 0x561F40 and following). Solo brings those tiers in
-- vehicles; version 1 has no police vehicles, so the dispatched foot unit
-- takes that tier's model and loadout.
R.levelCopModel = {[0] = 283, [1] = 280, [2] = 281, [3] = 282}
R.tierModel = {[4] = 285, [5] = 286, [6] = 287}

-- Weapons (ammo 1000 each): city cop nightstick + pistol; SWAT micro uzi,
-- armour 50; FBI MP5, armour 100; army M4, armour 100. At 1 star the cop
-- keeps the nightstick unless the suspect carries an instant-hit or
-- projectile weapon (0x68BAD0).
function R.copLoadout(level, suspectArmed)
    if level == 4 then return {model = 285, weapon = 28, ammo = 1000, armor = 50, melee = false} end
    if level == 5 then return {model = 286, weapon = 29, ammo = 1000, armor = 100, melee = false} end
    if level >= 6 then return {model = 287, weapon = 31, ammo = 1000, armor = 100, melee = false} end
    if level <= 1 and not suspectArmed then return {weapon = 3, ammo = 1, armor = 0, melee = true} end
    return {weapon = 22, ammo = 1000, armor = 0, melee = false}
end

function R.copModel(level, mapLevel)
    return R.tierModel[level] or R.levelCopModel[mapLevel] or 280
end

-- Weapon IDs that count as instant-hit or projectile for the 1-star rule.
function R.isArmedWeapon(weapon)
    weapon = tonumber(weapon) or 0
    return (weapon >= 16 and weapon <= 18) or (weapon >= 22 and weapon <= 36) or weapon == 38 or weapon == 39
end

-- CEventDamage::ReportCriminalEvent (0x4B3440): the crime queued for a hit,
-- by GTA weapon type. Weapons 0-9 (fists, melee, knife, chainsaw) count as
-- hitting, 10-41 as shooting (including dildos, molotov, flamethrower and
-- spray can, as in the binary), 49/50 as running over. Anything else (fall,
-- explosion, drowning) queues nothing.
function R.damageQueuedCrime(victimClass, weapon)
    weapon = tonumber(weapon) or -1
    local cop = victimClass == 'cop'
    if weapon >= 0 and weapon < 10 then return cop and 3 or 2 end
    if weapon >= 10 and weapon <= 41 then return cop and 5 or 4 end
    if weapon == 49 or weapon == 50 then return cop and 11 or 10 end
    return nil
end

function R.policeDontCare(victimClass)
    return victimClass == 'gang' or victimClass == 'criminal'
end

-- Law-enforcement models (IsLawEnforcementVehicle 0x6D2370) plus the police
-- Maverick that WorkOutPolicePresence also accepts.
R.lawVehicles = {
    [427] = true, [430] = true, [432] = true, [433] = true, [490] = true, [497] = true,
    [523] = true, [528] = true, [596] = true, [597] = true, [598] = true, [599] = true, [601] = true,
}

R.copPedModels = {[280] = true, [281] = true, [282] = true, [283] = true, [284] = true,
                  [285] = true, [286] = true, [287] = true, [288] = true}

-- Ped types from peds.ide, by model. 0x608A40 gives the x0.333 "police don't
-- care" multiplier to gang 1-10 (types 7-16), dealer (17) and criminal (20)
-- victims. MTA peds are all CPlayerPed wrappers, so the model is the only
-- identity the server can trust (element data can be changed by clients).
-- Dealers use criminal models 28-30 plus 254 (native-ped-traffic catalog), so
-- they share the 'criminal' class.
R.gangPedModels = {}
for _, model in ipairs({102, 103, 104, 105, 106, 107, 108, 109, 110, 114, 115, 116, 117, 118, 120, 121, 122, 123,
                        124, 125, 126, 127, 173, 174, 175}) do R.gangPedModels[model] = true end
R.criminalPedModels = {}
for _, model in ipairs({21, 28, 29, 30, 47, 100, 111, 112, 113, 143, 144, 146, 181, 183, 184, 223, 250, 254}) do
    R.criminalPedModels[model] = true
end

function R.pedClassForModel(model)
    if R.copPedModels[model] then return 'cop' end
    if R.gangPedModels[model] then return 'gang' end
    if R.criminalPedModels[model] then return 'criminal' end
    return 'civilian'
end

return R
