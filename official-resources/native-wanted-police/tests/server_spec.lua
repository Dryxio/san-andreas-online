-- Run from the repository root: lua official-resources/native-wanted-police/tests/server_spec.lua
-- Runs the real server.lua against small MTA stand-ins. It checks authority,
-- ownership, the watchdog and the arrest flow. GTA's AI, collision and
-- animation need a real client and are not covered here.
local passed = 0
local function check(name, condition)
    if not condition then error('FAILED: ' .. name, 2) end
    passed = passed + 1
end

math.atan2 = math.atan2 or math.atan
unpack = unpack or table.unpack

local T = 0
local handlers, timers, clientEvents, serverEvents, elements = {}, {}, {}, {}, {}
local cancelled = {}
root, resourceRoot = {kind = 'root', data = {}}, {kind = 'resource', data = {}, name = 'native-wanted-police'}

local function element(kind, fields)
    local e = fields or {}
    e.kind = kind
    e.x, e.y, e.z = e.x or 0, e.y or 0, e.z or 0
    e.data = e.data or {}
    e.dimension, e.interior = e.dimension or 0, e.interior or 0
    e.alive = true
    elements[#elements + 1] = e
    return e
end

-- Settings: the version 1 sections run with police cars off (foot cops at
-- every level); section 14 turns them on through onSettingChange.
local settings = {policeCars = 'false'}
function get(name) return settings[name] or false end
function getThisResource() return resourceRoot end
function getTickCount() return T end
function isElement(e) return type(e) == 'table' and e.kind ~= nil and e.alive == true end
function getElementType(e) return e.kind end
function getElementPosition(e)
    -- A ped in a vehicle is where the vehicle is.
    if e.kind == 'ped' and e.vehicle and e.vehicle.occupants then return e.vehicle.x, e.vehicle.y, e.vehicle.z end
    return e.x, e.y, e.z
end
function setElementPosition(e, x, y, z)
    e.x, e.y, e.z = x, y, z
    for _, ped in pairs(e.occupants or {}) do ped.x, ped.y, ped.z = x, y, z end
    return true
end
function setElementAlpha(e, alpha) e.alpha = alpha; return true end
function setVehicleOverrideLights(e, state) e.lights = state; return true end
function getDistanceBetweenPoints3D(a, b, c, d, e, f) return math.sqrt((a - d) ^ 2 + (b - e) ^ 2 + (c - f) ^ 2) end
function getElementDimension(e) return e.dimension end
function getElementInterior(e) return e.interior end
function getElementData(e, key) return e.data[key] end
local untrustedWrites = 0
function setElementData(e, key, value, sync, trust)
    if trust ~= 'deny' then untrustedWrites = untrustedWrites + 1 end
    e.data[key] = value; return true
end
function removeElementData(e, key) e.data[key] = nil end
function getElementModel(e) return e.model or 0 end
function getElementsWithinRange(x, y, z, range, kind)
    -- MTA refuses a position that is not three numbers.
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then error('getElementsWithinRange: bad position') end
    local list = {}
    for _, e in ipairs(elements) do
        if e.alive and (not kind or e.kind == kind) and getDistanceBetweenPoints3D(x, y, z, e.x, e.y, e.z) <= range then
            list[#list + 1] = e
        end
    end
    return list
end
function getElementsByType(kind)
    local list = {}
    for _, e in ipairs(elements) do if e.alive and e.kind == kind then list[#list + 1] = e end end
    return list
end
function getPedOccupiedVehicle(e) return e.vehicle end
function isVehicleBlown(e) return e.blown == true end
function isPedDead(e) return e.dead == true end
function getVehicleController(v) return v.driver end
function getVehicleType(v) return v.vehicleType or 'Automobile' end
function getElementSyncer(e) return e.syncer end
function setElementSyncer(e, player) e.syncer = player; return true end
function getPedWeapon(e) return e.weapon or 0 end
function getPedWeaponSlot(e) return e.slot or 0 end
function setPedWeaponSlot(e, slot) e.slot = slot; return true end
function giveWeapon(e, weapon, ammo, current)
    e.weapons = e.weapons or {}
    e.weapons[weapon] = ammo
    if current then e.weapon = weapon; e.slot = weapon == 3 and 1 or 2 end
end
function setPedArmor(e, armor) e.armor = armor end
function getElementVelocity(e) return e.vx or 0, e.vy or 0, e.vz or 0 end
function getPlayerMoney(e) return e.money or 0 end
function takePlayerMoney(e, amount) e.money = (e.money or 0) - amount end
function takeAllWeapons(e) e.weapon = 0; e.tookWeapons = true end
function fadeCamera() end
function setCameraTarget() end
function spawnPlayer(e, x, y, z) e.x, e.y, e.z = x, y, z; e.spawned = true end
function setPlayerWantedLevel(e, level) e.hudStars = level end
function destroyElement(e) e.alive = false end
function createPed(model, x, y, z, rot)
    return element('ped', {model = model, x = x, y = y, z = z, rot = rot})
end
function createVehicle(model, x, y, z, rx, ry, rz)
    return element('vehicle', {model = model, x = x, y = y, z = z, rot = rz, occupants = {}, health = 1000})
end
function warpPedIntoVehicle(ped, vehicle, seat)
    ped.vehicle, ped.seat = vehicle, seat
    vehicle.occupants[seat] = ped
    if seat == 0 then vehicle.driver = ped end
    return true
end
function removePedFromVehicle(ped)
    local vehicle = ped.vehicle
    if vehicle then
        if vehicle.occupants then vehicle.occupants[ped.seat] = nil end
        if vehicle.driver == ped then vehicle.driver = nil end
    end
    ped.vehicle, ped.seat = nil, nil
    ped.removedFromVehicle = true
    return true
end
function getPedOccupiedVehicleSeat(ped) return ped.seat end
function getVehicleOccupant(vehicle, seat)
    local ped = vehicle.occupants and vehicle.occupants[seat or 0]
    if ped and ped.vehicle == vehicle then return ped end
    return false
end
function getVehicleHandling() return {maxVelocity = 200, engineAcceleration = 25, dragCoeff = 2, handlingFlags = 0x10200008} end
function setVehicleEngineState() return true end
function setVehicleSirensOn(vehicle, on) vehicle.siren = on; return true end
function getElementHealth(e) return e.health or 100 end
function getElementMatrix(e) return {{1, 0, 0}, {0, 1, 0}, {0, 0, e.upZ or 1}, {e.x, e.y, e.z}} end
function setTimer(fn, interval, times, ...) timers[#timers + 1] = {fn = fn, interval = interval, times = times, args = {...}} end
function addEvent() end
function addEventHandler(name, _, fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end
function triggerEvent(name, src, ...)
    serverEvents[#serverEvents + 1] = {name = name, source = src, args = {...}}
    return not cancelled[name]
end
function triggerClientEvent(target, name, _, ...)
    clientEvents[#clientEvents + 1] = {target = target, name = name, args = {...}}
end

local function fire(name, src, cli, ...)
    source, client = src, cli
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
    source, client = nil, nil
end

local function lastClientEvent(name, target)
    for i = #clientEvents, 1, -1 do
        local e = clientEvents[i]
        if e.name == name and (not target or e.target == target) then return e end
    end
end

local step
-- Advance time until the server sends a new spawn probe to `player`.
local function nextProbe(player)
    local seen = #clientEvents
    for _ = 1, 80 do
        step(250)
        for i = seen + 1, #clientEvents do
            local e = clientEvents[i]
            if e.name == 'neonPolice:spawnProbe' and e.target == player then return e end
        end
    end
    error('no spawn probe')
end

-- Answer every pending spawn veto sent since `from` (other players' checks).
local function answerVetoes(from, visible)
    for i = from + 1, #clientEvents do
        local e = clientEvents[i]
        if e.name == 'neonPolice:spawnVeto' then
            local targets = (type(e.target) == 'table' and e.target.kind == nil) and e.target or {e.target}
            for _, target in ipairs(targets) do
                fire('neonPolice:spawnVetoResult', resourceRoot, target, e.args[1], visible)
            end
        end
    end
end

-- Get the next probe for `player`, answer it at (x, y, z), clear the vetoes.
local function spawnAt(player, x, y, z, visible)
    local probe = nextProbe(player)
    local mark = #clientEvents
    fire('neonPolice:spawnCandidate', resourceRoot, player, probe.args[1], x, y, z)
    answerVetoes(mark, visible == true)
    return probe
end

-- Answer every reveal probe sent since `from` (staged police cars).
local function answerReveals(from, isReady, visible)
    for i = from + 1, #clientEvents do
        local e = clientEvents[i]
        if e.name == 'neonPolice:revealProbe' then
            local targets = (type(e.target) == 'table' and e.target.kind == nil) and e.target or {e.target}
            for _, target in ipairs(targets) do
                fire('neonPolice:revealResult', resourceRoot, target, e.args[1], isReady, visible)
            end
        end
    end
end

local function countServerEvents(name)
    local n = 0
    for _, e in ipairs(serverEvents) do if e.name == name then n = n + 1 end end
    return n
end

-- native-ped-traffic stand-in: releaseTrafficCop accepts peds marked
-- `releasable` and records every request.
local trafficResource = {name = 'native-ped-traffic', state = 'running'}
local releaseRequests, releaseAnswer = {}, nil
function getResourceFromName(name) return name == 'native-ped-traffic' and trafficResource or false end
function getResourceState(r) return r.state end
function getResourceName(r) return r and r.name end
function setElementFrozen(e, frozen) e.frozen = frozen; return true end
exports = {['native-ped-traffic'] = {releaseTrafficCop = function(_, ped)
    releaseRequests[#releaseRequests + 1] = ped
    if releaseAnswer ~= nil then return releaseAnswer end
    if not ped.releasable then return false end
    ped.data['neon:ambientPedTraffic'] = false
    return true
end}}

dofile('official-resources/native-wanted-police/rules.lua')
dofile('official-resources/native-wanted-police/server.lua')

-- Two suspects and a third player far from both.
local alice = element('player', {x = 2495, y = -1687, z = 13, money = 5000})
local bob = element('player', {x = 2510, y = -1690, z = 13, money = 5000})
local carol = element('player', {x = 2000, y = -1000, z = 13, money = 0})
fire('onResourceStart', resourceRoot)
for _, p in ipairs({alice, bob, carol}) do fire('neonPolice:ready', resourceRoot, p) end
local loop = timers[1]
function step(ms)
    local target = T + ms
    while T < target do
        T = T + 250
        loop.fn()
    end
end

-- 1. Independent ledgers: Alice shoots a traffic cop from 10 m (cop within
-- 14 m: reported at once, at least one star). Bob is untouched.
local trafficCop = element('ped', {model = 280, x = 2505, y = -1687, z = 13, syncer = alice,
                                   data = {['neon:ambientPedPopulationClass'] = 'civilian'}})
alice.weapon = 22
fire('onPlayerWeaponFire', alice, nil, 22, 0, 0, 0, trafficCop)
check('shooting next to a cop: 1 star at once', getNativeWantedState(alice).level == 1)
check('the HUD gets the stars', alice.hudStars == 1 and alice.data['neon:wantedLevel'] == 1)
check('Bob stays clean', getNativeWantedState(bob).level == 0)
check('spoofed element data does not hide a cop (model decides)', getNativeWantedState(alice).chaos >= 70)
-- The hit itself (victim's syncer): damage ped + queued shoot-cop (80).
fire('neonPolice:damage', resourceRoot, alice, trafficCop, alice, 22)
local chaosBeforeQueue = getNativeWantedState(alice).chaos
step(1250)
check('queued shoot-cop crime adds 80', getNativeWantedState(alice).chaos == chaosBeforeQueue + 80)
-- The same hit reported again by another source is not counted twice.
fire('neonPolice:damage', resourceRoot, alice, trafficCop, alice, 22)
fire('onPlayerWeaponFire', alice, nil, 22, 0, 0, 0, trafficCop)
local settled = getNativeWantedState(alice).chaos
step(1250)
check('duplicate evidence not counted twice', getNativeWantedState(alice).chaos == settled)
setNativeWantedLevel(alice, 2)
alice.weapon = 0

-- 2. Dispatch asks Alice's client for an off-screen point.
local probe = nextProbe(alice)
check('spawn probe sent to the suspect', probe ~= nil)
-- A forged answer from another client is ignored.
fire('neonPolice:spawnCandidate', resourceRoot, bob, probe.args[1], 2540, -1650, 13)
check('candidate from the wrong client ignored', #getNativePoliceUnits(alice) == 0)
-- The real client can still answer after a forged reply: too close, refused.
fire('neonPolice:spawnCandidate', resourceRoot, alice, probe.args[1], 2497, -1687, 13)
check('candidate too close refused', #getNativePoliceUnits(alice) == 0)
-- Bob (within 150 m) sees the spot: no cop.
spawnAt(alice, 2495, -1640, 13, true)
check('a spot another player can see is refused', #getNativePoliceUnits(alice) == 0)
spawnAt(alice, 2495, -1640, 13, false)
local cops = getNativePoliceUnits(alice)
check('a cop was created', #cops == 1)
local cop = cops[1]
check('cop is marked', cop.data['neon:police'] == true and cop.data['neon:policeSuspect'] == alice)
check('regional LS model', cop.model == 280)
check('Bob, not the suspect, runs the cop', cop.syncer == bob)
check('2 stars: pistol in hand', cop.weapon == 22)
check('every published value denies client changes', untrustedWrites == 0)

-- 3. Damage evidence: only the victim's syncer or the attacker may report,
-- from a believable distance, with the weapon he really holds.
local civilian = element('ped', {model = 7, x = 2512, y = -1689, z = 13, syncer = bob})
local before = getNativeWantedState(bob).chaos
fire('neonPolice:damage', resourceRoot, carol, civilian, bob, 0)
check('report from an unrelated client ignored', getNativeWantedState(bob).chaos == before)
civilian.x = 3000
fire('neonPolice:damage', resourceRoot, bob, civilian, bob, 0)
check('implausible distance ignored', getNativeWantedState(bob).chaos == before)
civilian.x = 2512
fire('neonPolice:damage', resourceRoot, bob, civilian, bob, 31)
check('a weapon he does not hold is ignored', getNativeWantedState(bob).chaos == before)
fire('neonPolice:damage', resourceRoot, bob, civilian, bob, 0)
step(1500)
check('valid report counted for Bob', getNativeWantedState(bob).chaos > before)
-- Framing through stock events: a far player blamed for a kill.
local farPed = element('ped', {model = 7, x = 1500, y = -1000, z = 13})
local carolBefore = getNativeWantedState(carol).chaos
fire('onPedWasted', farPed, nil, 0, carol, 31, 3, false)
step(1500)
check('a far player cannot be blamed for a kill', getNativeWantedState(carol).chaos == carolBefore)
-- A driver reporting his own vehicle never blames anyone.
local car = element('vehicle', {model = 400, x = 2001, y = -1001, z = 13, driver = bob})
fire('neonPolice:vehicleDamage', resourceRoot, bob, car, carol, 0)
check('a driver cannot blame someone for his car', getNativeWantedState(carol).chaos == carolBefore)
check('Alice and Bob keep separate cops', cop.data['neon:policeSuspect'] == alice)
-- First entry into any vehicle is car theft (crime 6, queued); a vehicle the
-- gamemode marks as the player's own is not.
local parked = element('vehicle', {model = 400, x = 2000, y = -1002, z = 13})
local owned = element('vehicle', {model = 400, x = 2000, y = -1003, z = 13, data = {['neon:playerOwned'] = true}})
fire('onPlayerVehicleEnter', carol, nil, owned, 0)
step(1500)
check('own car: no crime', getNativeWantedState(carol).chaos == carolBefore)
fire('onPlayerVehicleEnter', carol, nil, parked, 0)
step(1500)
check('first entry into a parked car: theft counted', getNativeWantedState(carol).chaos == carolBefore + 15)
fire('onPlayerVehicleEnter', carol, nil, parked, 0)
step(11000)
check('only the first entry counts', getNativeWantedState(carol).chaos <= carolBefore + 15)
clearNativeWanted(carol)
clearNativeWanted(bob)

-- 4. Watchdog: a cop that does not close in moves to another owner, then retires.
local owner = cop.syncer
step(8000)
check('stalled cop handed to another owner', cop.syncer ~= owner or cop.data['neon:policePhase'] == 'disengage')
step(16000)
check('third stall retires the cop', cop.data['neon:policePhase'] == 'disengage')

-- 5. Arrest: a fresh cop reaches Alice, she is knocked down, busted after 4 s.
spawnAt(alice, 2495, -1720, 13, false)
local cops2 = getNativePoliceUnits(alice)
local arrestingCop = cops2[#cops2]
arrestingCop.x, arrestingCop.y = alice.x + 1.5, alice.y
fire('neonPolice:down', resourceRoot, alice)
step(250)
check('arrest started', getNativeWantedState(alice).arrest == true)
check('suspect client told', lastClientEvent('neonPolice:arrest', alice) ~= nil)
check('cops hold during the arrest', arrestingCop.data['neon:policePhase'] == 'arrest')
local level = getNativeWantedState(alice).level
step(4250)
check('busted after 4 s', countServerEvents('onNativePlayerArrested') == 1)
for _, e in ipairs(serverEvents) do
    if e.name == 'onNativePlayerArrested' then
        check('the event carries the station respawn point', e.args[3] == 'Los Santos' and math.abs(e.args[4] - 1550.68) < 0.01)
    end
end
check('controls held until the respawn', lastClientEvent('neonPolice:bustHold', alice).args[1] == true)
check('wanted cleared', getNativeWantedState(alice).level == 0 and alice.hudStars == 0)
check('fine by stars taken', alice.money == 5000 - NativeWantedRules.bustedFine(level))
check('weapons taken', alice.tookWeapons == true)
check('cops disengage', arrestingCop.data['neon:policePhase'] == 'disengage')
local respawn = timers[#timers]
respawn.fn()
check('respawned at LSPD', alice.spawned and math.abs(alice.x - 1550.68) < 0.01)
check('controls released after the respawn', lastClientEvent('neonPolice:bustHold', alice).args[1] == false)

-- 6. Resisting: entering a vehicle during an arrest breaks it off.
setNativeWantedLevel(alice, 1)
alice.x, alice.y = 2495, -1687
spawnAt(alice, 2495, -1650, 13, false)
local unarmedCop = getNativePoliceUnits(alice)[1]
check('1 star, unarmed suspect: nightstick', unarmedCop.weapon == 3)
unarmedCop.x, unarmedCop.y = alice.x + 1, alice.y
fire('neonPolice:down', resourceRoot, alice)
step(250)
check('second arrest started', getNativeWantedState(alice).arrest == true)
alice.vehicle = element('vehicle', {model = 400, x = alice.x, y = alice.y, z = alice.z})
step(250)
check('getting in a car resists the arrest', getNativeWantedState(alice).arrest == false)
check('suspect controls released', lastClientEvent('neonPolice:arrestEnd', alice).args[1] == false)
alice.vehicle = nil

-- 7. A cancelled arrest event leaves the outcome to the gamemode.
cancelled.onNativePlayerArrested = true
local moneyBefore = alice.money
alice.tookWeapons, alice.spawned = false, false
local arrestsBefore = countServerEvents('onNativePlayerArrested')
for _ = 1, 40 do
    step(250)
    if getNativeWantedState(alice).arrest then break end
    fire('neonPolice:down', resourceRoot, alice)
end
step(4250)
check('cancelled bust still reported', countServerEvents('onNativePlayerArrested') == arrestsBefore + 1)
check('cancelled bust: wanted cleared', getNativeWantedState(alice).level == 0)
check('cancelled bust: no fine, weapons kept', alice.money == moneyBefore and alice.tookWeapons == false)
cancelled.onNativePlayerArrested = nil

-- 8. Wasted clears the wanted level.
setNativeWantedLevel(bob, 3)
bob.dead = true
fire('onPlayerWasted', bob, nil, 0, nil, 0)
check('wasted clears', getNativeWantedState(bob).level == 0)
bob.dead = false

-- 9. A debt is never paid off by a bust.
alice.money = -500
local bustsBefore = countServerEvents('onNativePlayerArrested')
setNativeWantedLevel(alice, 1)
for _ = 1, 80 do
    step(250)
    local cop1 = getNativePoliceUnits(alice)[1]
    if cop1 then cop1.x, cop1.y = alice.x + 1, alice.y end
    if getNativeWantedState(alice).arrest then break end
    if not cop1 then
        local p2 = lastClientEvent('neonPolice:spawnProbe', alice)
        if p2 then fire('neonPolice:spawnCandidate', resourceRoot, alice, p2.args[1], alice.x, alice.y + 40, 13) end
        answerVetoes(0, false)
    end
    fire('neonPolice:down', resourceRoot, alice)
end
step(4250)
check('busted while in debt', countServerEvents('onNativePlayerArrested') == bustsBefore + 1)
check('negative money stays negative', alice.money == -500)
alice.money = 5000

-- 10. Retired cops vanish only when nobody sees them.
local retired = 0
for _, e in ipairs(elements) do
    if e.kind == 'ped' and e.data['neon:police'] and e.alive then retired = retired + 1 end
end
local visibilityProbe = timers[2]
visibilityProbe.fn()
local check1 = lastClientEvent('neonPolice:visibilityProbe')
check('visibility asked to nearby players', check1 ~= nil)
for _, target in ipairs(type(check1.target) == 'table' and check1.target.kind == nil and check1.target or {check1.target}) do
    fire('neonPolice:visibilityResult', resourceRoot, target, check1.args[1], false)
end
local after = 0
for _, e in ipairs(elements) do
    if e.kind == 'ped' and e.data['neon:police'] and e.alive then after = after + 1 end
end
check('an unseen retired cop is removed', after < retired)

-- 11. Exports.
check('maximum caps the level', setNativeWantedMaximum(bob, 2) and setNativeWantedLevel(bob, 6) and getNativeWantedState(bob).level == 2)
check('parole clear', clearNativeWanted(bob, 'parole') and getNativeWantedState(bob).parole == true)
check('report export validates the type', reportNativeCrime(bob, 99) == false and reportNativeCrime(bob, 2) == true)
check('disabled player ignores crimes', setNativeWantedEnabled(carol, false) and reportNativeCrime(carol, 5) == false)
check('backoff', requestNativePoliceBackoff(alice, 5000) and getNativeWantedState(alice).backoff == true)

-- 12. Quitting removes the suspect and retires his cops.
setNativeWantedLevel(bob, 2)
fire('onPlayerQuit', bob)
check('quit forgets the suspect', getNativePoliceUnits(bob)[1] == nil)

-- 13. Street cops from native-ped-traffic join the chase (solo's wandering
-- cops, 0x674D80), within the level's pursuit cap.
local recruit
for _, timer in ipairs(timers) do if timer.interval == 1000 then recruit = timer end end
check('street cop recruitment runs every second', recruit ~= nil)
local erin = element('player', {x = 1000, y = 1000, z = 10})
fire('neonPolice:ready', resourceRoot, erin)
local function streetCop(x, y, fields)
    local cop = element('ped', fields or {})
    cop.model, cop.x, cop.y, cop.z = cop.model or 280, x, y, 10
    cop.data['neon:ambientPedTraffic'] = true
    cop.data['neon:ambientPedPopulationClass'] = 'cop'
    cop.releasable = cop.releasable ~= false
    cop.frozen = true
    return cop
end
local farCop = streetCop(1060, 1000)
recruit.fn()
check('no stars: street cops stay in traffic', #releaseRequests == 0 and getNativePoliceUnits(erin)[1] == nil)
setNativeWantedLevel(erin, 1)
recruit.fn()
check('1 star: the street cop joins', getNativePoliceUnits(erin)[1] == farCop)
check('it is now a unit of this resource', farCop.data['neon:police'] == true and farCop.data['neon:policeSuspect'] == erin)
check('the joined cop runs on the suspect (nobody else near)', farCop.syncer == erin and farCop.frozen == false)
local nearCop = streetCop(1020, 1000)
local fartherCop = streetCop(1100, 1000)
recruit.fn()
check('cap 1: a closer cop displaces the farther one', getNativePoliceUnits(erin)[1] == nearCop and #getNativePoliceUnits(erin) == 1)
check('the displaced cop walks away', farCop.data['neon:policePhase'] == 'disengage')
check('a cop farther than every pursuer is not taken', fartherCop.data['neon:police'] == nil)
setNativeWantedLevel(erin, 2)
local refused = streetCop(1030, 1000, {releasable = false})
recruit.fn()
check('2 stars: a farther cop joins while there is room', fartherCop.data['neon:police'] == true)
check('a cop the traffic resource refuses stays in traffic', refused.data['neon:police'] == nil)
local civilian = streetCop(1010, 1000, {model = 7})
local unmarked = element('ped', {model = 280, x = 1005, y = 1000, z = 10})
setNativeWantedLevel(erin, 3)
recruit.fn()
check('a non-cop model is never taken', civilian.data['neon:police'] == nil)
check('a cop without the traffic marker is never asked for', unmarked.data['neon:police'] == nil)
-- A suspect driving fast past a foot cop is not chased (0x68BBD0).
setNativeWantedLevel(erin, 6)
local passing = streetCop(1040, 1000)
local car = element('vehicle', {x = 1000, y = 1000, z = 10, vx = 0.5})
erin.vehicle = car
recruit.fn()
check('a car at 90 km/h 40 m away is ignored', passing.data['neon:police'] == nil)
car.vx = 0
recruit.fn()
check('the car stops: the cop joins', passing.data['neon:police'] == true)
erin.vehicle = nil
-- An older traffic build without the export: one call, then no more.
local older = streetCop(1015, 1000)
releaseAnswer = nil
exports['native-ped-traffic'].releaseTrafficCop = function(_, ped) releaseRequests[#releaseRequests + 1] = ped; return nil end
local asked = #releaseRequests
recruit.fn(); recruit.fn()
check('a traffic build without the export is asked once', #releaseRequests == asked + 1 and older.data['neon:police'] == nil)

-- 14. Police cars (version 2), in Las Venturas far from everyone else.
settings.policeCars = 'true'
fire('onSettingChange', root, nil, '*native-wanted-police.policeCars')
local frank = element('player', {x = 2200, y = 2200, z = 10, money = 5000})
fire('neonPolice:ready', resourceRoot, frank)
local function probesTo(player, name, from)
    local list = {}
    for i = (from or 0) + 1, #clientEvents do
        local e = clientEvents[i]
        local listed = type(e.target) == 'table' and e.target.kind == nil
        local hit = e.target == player
        if listed then for _, target in ipairs(e.target) do hit = hit or target == player end end
        if e.name == name and hit then list[#list + 1] = e end
    end
    return list
end
-- Fixed rolls for Frank's first car: the cop-bike switch starts off and
-- flips in 50 s, the car rams, nobody gets a shotgun.
local realRandom = math.random
math.random = function(a, b)
    if a == nil then return 0.9 end
    return b or a
end
local mark = #clientEvents
setNativeWantedLevel(frank, 1)
step(10000)
check('1 star: no police car and no foot cop spawned', #probesTo(frank, 'neonPolice:carProbe', mark) == 0 and
    #probesTo(frank, 'neonPolice:spawnProbe', mark) == 0)
setNativeWantedLevel(frank, 2)
step(250)
local carProbes = probesTo(frank, 'neonPolice:carProbe', mark)
check('2 stars: a police car is asked for at once', #carProbes == 1)
check('LV: an LVPD cruiser', carProbes[1].args[2] == 598)
fire('neonPolice:carCandidate', resourceRoot, bob, carProbes[1].args[1], 2200, 2280, 10, 180)
check('a candidate from another client is ignored', #getNativePoliceCars(frank) == 0)
fire('neonPolice:carCandidate', resourceRoot, frank, carProbes[1].args[1], 2200, 2280, 10, 180)
local cruisers = getNativePoliceCars(frank)
math.random = realRandom
check('the car is created', #cruisers == 1)
local cruiser = cruisers[1]
local driver, passenger = getVehicleOccupant(cruiser, 0), getVehicleOccupant(cruiser, 1)
check('driver and passenger, LV cops', driver and passenger and driver.model == 282 and passenger.model == 282)
check('the crew are units chasing Frank', driver.data['neon:police'] == true and passenger.data['neon:policeSuspect'] == frank)
check('car, driver and passenger run on one client', cruiser.syncer == frank and driver.syncer == frank and passenger.syncer == frank)
check('2 stars: speed 34, a mission chosen', cruiser.data['neon:policeCarSpeed'] == 34 and
    (cruiser.data['neon:policeCarMission'] == 'ram' or cruiser.data['neon:policeCarMission'] == 'block'))
check('crew armed with the pistol', driver.weapon == 22 and passenger.weapons[3] == 1)
-- Staging: created hidden, then shown once every nearby client is ready.
check('created hidden at its road point', cruiser.alpha == 0 and driver.alpha == 0 and passenger.alpha == 0 and
    cruiser.lights == 1 and cruiser.data['neon:policeCarPhase'] == 'staging' and cruiser.z > 10 and cruiser.z < 11)
check('a staged car already counts against the car cap', getNativeWantedState(frank).cars == 1)
mark = #clientEvents
step(250)
check('the suspect is asked to check the reveal', #probesTo(frank, 'neonPolice:revealProbe', mark) == 1)
answerReveals(mark, false, false)
check('not loaded on the suspect\'s client: still hidden', cruiser.alpha == 0 and cruiser.data['neon:policeCarPhase'] == 'staging')
mark = #clientEvents
step(500)
answerReveals(mark, true, true)
check('its spot on his screen up close: still hidden', cruiser.alpha == 0)
mark = #clientEvents
step(500)
answerReveals(mark, true, false)
check('loaded and out of view: shown, the chase starts', cruiser.alpha == 255 and driver.alpha == 255 and
    passenger.alpha == 255 and cruiser.lights == 0 and cruiser.data['neon:policeCarPhase'] == 'chase')
check('a cop driving a law car counts as police nearby', getNativeWantedState(frank).cars == 1)
cruiser.vx = 0.3 -- the owner drives it (GTA's AI is not simulated here)
mark = #clientEvents
step(5500) -- 6.75 s since the car was created (staging took 1.25 s)
check('2 stars: no second car within 8 s', #probesTo(frank, 'neonPolice:carProbe', mark) == 0)
step(1500)
check('a second car after 8 s', #probesTo(frank, 'neonPolice:carProbe', mark) == 1)
-- Leave that request unanswered and a second one too: foot cops stand in.
step(3000)
step(9000)
local footMark = #clientEvents
step(5000)
check('two missed car placements: a foot cop is asked for', #probesTo(frank, 'neonPolice:spawnProbe', footMark) >= 1 or
    #probesTo(frank, 'neonPolice:spawnProbe', mark) >= 1)

-- The car reaches Frank on foot: the passenger gets out at once, the driver
-- after 3-5 s.
cruiser.x, cruiser.y = frank.x + 6, frank.y
driver.x, driver.y, passenger.x, passenger.y = cruiser.x, cruiser.y, cruiser.x, cruiser.y
step(250)
check('within 10 m of a suspect on foot: the car stops', cruiser.data['neon:policeCarPhase'] == 'bail')
check('the siren is on up close', cruiser.siren == true)
check('the passenger is ordered out at once', passenger.data['neon:policeOrder'] == 'exit' and driver.data['neon:policeOrder'] == nil)
removePedFromVehicle(passenger)
step(2500)
check('the driver still waits', driver.data['neon:policeOrder'] == nil)
step(2750)
check('then the driver gets out too', driver.data['neon:policeOrder'] == 'exit')
removePedFromVehicle(driver)
step(250)
check('empty car: parked, orders done', cruiser.data['neon:policeCarPhase'] == 'parked' and driver.data['neon:policeOrder'] == nil)
check('out of the car they chase on foot', not getPedOccupiedVehicle(driver) and driver.data['neon:policePhase'] == 'pursue')
check('a parked car no longer counts against the car cap', getNativeWantedState(frank).cars == 0)

-- Frank drives off: only the driver goes back to his car, once within 4 m
-- of it (0x6901B1).
local getaway = element('vehicle', {model = 400, x = frank.x, y = frank.y, z = 10, vx = 0.5, occupants = {}})
warpPedIntoVehicle(frank, getaway, 0)
driver.x, driver.y = cruiser.x + 6, cruiser.y
passenger.x, passenger.y = cruiser.x + 4, cruiser.y
step(250)
check('6 m from his car: not yet', driver.data['neon:policeOrder'] == nil and cruiser.data['neon:policeCarPhase'] == 'parked')
driver.x = cruiser.x + 3
step(250)
check('the driver is sent back to his car', driver.data['neon:policeOrder'] == 'enter' and cruiser.data['neon:policeCarPhase'] == 'boarding')
check('never the passenger', passenger.data['neon:policeOrder'] == nil)
warpPedIntoVehicle(driver, cruiser, 0)
step(250)
check('back at the wheel: the chase goes on', cruiser.data['neon:policeCarPhase'] == 'chase' and driver.data['neon:policeOrder'] == nil)

-- Frank stops his car next to the cop on foot: pulled out and arrested.
getaway.vx = 0
passenger.x, passenger.y = frank.x + 2, frank.y
cruiser.x, cruiser.y = frank.x + 30, frank.y
driver.x, driver.y = cruiser.x, cruiser.y
-- Ramming the police car is damaging a cop's vehicle (crime 8, queued).
local chaos8 = getNativeWantedState(frank).chaos
cruiser.x = frank.x + 15
fire('neonPolice:vehicleDamage', resourceRoot, frank, cruiser, getaway, 49)
cruiser.x = frank.x + 30
step(2250)
check('hitting a police car with a cop inside: crime 8 (+5)', getNativeWantedState(frank).chaos == chaos8 + 5)
step(750)
check('a car stopped 2.5 s with a cop at the door: the arrest starts', getNativeWantedState(frank).arrest == true)
check('the suspect is told to get out', lastClientEvent('neonPolice:arrest', frank).args[3] == 'car')
step(3250)
check('still inside after 3 s: taken out', frank.removedFromVehicle == true and not getPedOccupiedVehicle(frank))
step(250)
check('then hands up on foot', lastClientEvent('neonPolice:arrest', frank).args[3] == 'foot')
local arrestsBeforeFrank = countServerEvents('onNativePlayerArrested')
step(4250)
check('busted', countServerEvents('onNativePlayerArrested') == arrestsBeforeFrank + 1)
check('the car is retired with the chase', cruiser.data['neon:policeCarPhase'] == 'retire')
-- The cleanup pass asks the players near the retired car, then removes it
-- once nobody sees it (it used to fail on every car waiting to leave).
mark = #clientEvents
visibilityProbe.fn()
local carCheck
for _, e in ipairs(probesTo(frank, 'neonPolice:visibilityProbe', mark)) do
    if e.args[2] == cruiser then carCheck = e end
end
check('a retired car is checked by the players near it', carCheck ~= nil)
fire('neonPolice:visibilityResult', resourceRoot, frank, carCheck.args[1], false)
check('and removed once nobody sees it', cruiser.alive == false)

-- A player who takes a parked police car keeps it.
setNativeWantedLevel(frank, 3)
mark = #clientEvents
step(250)
local probe3 = probesTo(frank, 'neonPolice:carProbe', mark)[1]
check('3 stars: a new car', probe3 ~= nil)
fire('neonPolice:carCandidate', resourceRoot, frank, probe3.args[1], 2200, 2120, 10, 0)
local second = getNativePoliceCars(frank)[1]
check('created', second ~= nil and second ~= cruiser)
mark = #clientEvents
step(250)
answerReveals(mark, true, false)
check('and shown', second.alpha == 255)
removePedFromVehicle(getVehicleOccupant(second, 1))
removePedFromVehicle(getVehicleOccupant(second, 0))
step(250)
warpPedIntoVehicle(frank, second, 0)
second.driver = frank
step(250)
check('stolen: no longer a police car of this resource', getNativePoliceCars(frank)[1] == nil and second.alive and
    second.data['neon:policeCar'] == nil)

-- 15. Fixes from review: no chase/bail flip-flop, infinite rotation, parked
-- cars outside the cap, orders cleared, a stolen car's passenger.
local gina = element('player', {x = 2600, y = 2600, z = 10, money = 5000})
fire('neonPolice:ready', resourceRoot, gina)
-- Fixed rolls again: a two-seat cruiser, never the cop bike.
math.random = function(a, b)
    if a == nil then return 0.9 end
    return b or a
end
setNativeWantedLevel(gina, 2)
mark = #clientEvents
step(250)
local probeG = probesTo(gina, 'neonPolice:carProbe', mark)[1]
fire('neonPolice:carCandidate', resourceRoot, gina, probeG.args[1], 2600, 2680, 10, 1 / 0)
check('an infinite rotation is refused', #getNativePoliceCars(gina) == 0)
mark = #clientEvents
step(1250)
probeG = probesTo(gina, 'neonPolice:carProbe', mark)[1]
fire('neonPolice:carCandidate', resourceRoot, gina, probeG.args[1], 2600, 2680, 10, 0)
local carG = getNativePoliceCars(gina)[1]
math.random = realRandom
check('then a valid answer creates the car', carG ~= nil)
mark = #clientEvents
step(250)
answerReveals(mark, true, false)
check('shown', carG.data['neon:policeCarPhase'] == 'chase')
carG.vx = 0.3
local creep = element('vehicle', {model = 400, x = gina.x, y = gina.y, z = 10, vx = 0.03, occupants = {}})
warpPedIntoVehicle(gina, creep, 0)
carG.x, carG.y = gina.x + 6, gina.y
step(2500)
check('the 2.5 s count starts when the car is close, not before', carG.data['neon:policeCarPhase'] == 'chase')
step(500)
check('a creeping suspect (1.5 m/s): the car stops after 2.5 s up close', carG.data['neon:policeCarPhase'] == 'bail')
creep.vx = 0.2
step(250)
check('he speeds off (10 m/s): the driver keeps the wheel', carG.data['neon:policeCarPhase'] == 'chase')
creep.vx = 0.03
local phases = {}
for _ = 1, 8 do step(250); phases[carG.data['neon:policeCarPhase']] = true end
check('no flip-flop when he creeps again: a new 2.5 s count', phases.chase and not phases.bail)
-- Gunfire on the police car is seen by the server: crime 8.
local chaosG = getNativeWantedState(gina).chaos
gina.weapon = 22
fire('onPlayerWeaponFire', gina, nil, 22, 0, 0, 0, carG)
step(2250)
check('shooting a police car: crime 8 seen by the server', getNativeWantedState(gina).chaos >= chaosG + 5)
-- A bystander running the car cannot blame a far player with a weapon.
local hank = element('player', {x = 2600, y = 2640, z = 10})
fire('neonPolice:ready', resourceRoot, hank)
carG.syncer = hank
local hankChaos = getNativeWantedState(gina).chaos
gina.x = 2650
fire('neonPolice:vehicleDamage', resourceRoot, hank, carG, gina, 22)
step(2250)
check('a bystander syncer is not believed for gunfire', getNativeWantedState(gina).chaos == hankChaos)
gina.x = 2600
-- A player jacks the moving police car with the passenger still inside.
local passengerG = getVehicleOccupant(carG, 1)
removePedFromVehicle(getVehicleOccupant(carG, 0))
removePedFromVehicle(gina)
warpPedIntoVehicle(gina, carG, 0)
step(250)
check('jacked: the seated cop is told to get out', passengerG.data['neon:policeOrder'] == 'exit')
check('and is no police car any more', getNativePoliceCars(gina)[1] == nil)
gina.vx = 0
carG.vx = 0
step(3000)
check('a cop sitting in the suspect\'s car never arrests him', getNativeWantedState(gina).arrest == false)
removePedFromVehicle(passengerG)
step(250)
check('out of the car: the exit order is done', passengerG.data['neon:policeOrder'] == nil)
removePedFromVehicle(gina)
setNativeWantedLevel(gina, 0)

-- 16. Production review: framing by a bystander, bounded vetoes, hidden
-- foot cops, staging timeout, the far placement ring, the police bike.
local ivan = element('player', {x = 2300, y = 1500, z = 10, money = 5000})
local jill = element('player', {x = 2310, y = 1500, z = 10})
fire('neonPolice:ready', resourceRoot, ivan)
fire('neonPolice:ready', resourceRoot, jill)
local streetCivilian = element('ped', {model = 7, x = 2305, y = 1500, z = 10, syncer = jill})
ivan.weapon = 22
local ivanChaos = getNativeWantedState(ivan).chaos
fire('neonPolice:damage', resourceRoot, jill, streetCivilian, ivan, 22)
step(1500)
check('a bystander syncer alone cannot blame a gun hit', getNativeWantedState(ivan).chaos == ivanChaos)
fire('onPlayerWeaponFire', ivan, nil, 22, 0, 0, 0, nil)
ivanChaos = getNativeWantedState(ivan).chaos
fire('neonPolice:damage', resourceRoot, jill, streetCivilian, ivan, 22)
step(1500)
check('with a shot the server saw just before, it is believed', getNativeWantedState(ivan).chaos > ivanChaos)
ivan.weapon = 0
streetCivilian.x = 2310
ivanChaos = getNativeWantedState(ivan).chaos
fire('neonPolice:damage', resourceRoot, jill, streetCivilian, ivan, 0)
step(1500)
check('a punch from 10 m reported by a bystander is ignored', getNativeWantedState(ivan).chaos <= ivanChaos)
setNativeWantedLevel(ivan, 0)
step(250)

-- Police cars off for the foot-cop checks.
settings.policeCars = 'false'
fire('onSettingChange', root, nil, '*native-wanted-police.policeCars')
setNativeWantedLevel(ivan, 4) -- a cop every 1.5 s, and no decay in town
local vetoed = 0
for _ = 1, 9 do
    local before = #getNativePoliceUnits(ivan)
    spawnAt(ivan, 2300, 1560, 10, true)
    if #getNativePoliceUnits(ivan) == before then vetoed = vetoed + 1 end
end
check('a watcher that always says "visible": only 8 vetoes in 20 s count', vetoed == 8)
local footCop = getNativePoliceUnits(ivan)[1]
check('a foot cop is created transparent and fades in', footCop and footCop.alpha == 0 and footCop.z == 10)
setNativeWantedLevel(ivan, 0)
step(250)
settings.policeCars = 'true'
fire('onSettingChange', root, nil, '*native-wanted-police.policeCars')

-- The police bike: switch on (roll 0.1), 2 stars in Las Venturas.
math.random = function(a, b)
    if a == nil then return 0.1 end
    return a
end
step(51000) -- Jill's vetoes age out, and the bike switch is due
setNativeWantedLevel(ivan, 2)
mark = #clientEvents
step(250)
local probeI = probesTo(ivan, 'neonPolice:carProbe', mark)[1]
check('2 stars in town with the bike switch on: an HPV1000', probeI and probeI.args[2] == 523)
fire('neonPolice:carCandidate', resourceRoot, ivan, probeI.args[1], 2300, 1500 + 215, 10, 0)
check('a point beyond 210 m is refused', #getNativePoliceCars(ivan) == 0)
step(1250)
probeI = probesTo(ivan, 'neonPolice:carProbe', mark)
probeI = probeI[#probeI]
jill.x = 2400
fire('neonPolice:carCandidate', resourceRoot, ivan, probeI.args[1], 2300, 1500 + 180, 10, 0)
answerVetoes(mark, false)
math.random = realRandom
local bikeCar = getNativePoliceCars(ivan)[1]
check('the 160 m ring is accepted', bikeCar ~= nil)
check('one motorbike cop rides it', getVehicleOccupant(bikeCar, 0).model == 284 and not getVehicleOccupant(bikeCar, 1))
-- Nobody answers the reveal: removed unseen after 6 s, and the next car
-- waits 2 s.
mark = #clientEvents
step(6250)
check('a car that cannot be shown within 6 s is removed', bikeCar.alive == false and #getNativePoliceCars(ivan) == 0)
local soon = #probesTo(ivan, 'neonPolice:carProbe', mark)
step(1000)
check('and the next car waits', #probesTo(ivan, 'neonPolice:carProbe', mark) == soon)
setNativeWantedLevel(ivan, 0)

print(('server_spec: %d checks passed'):format(passed))
