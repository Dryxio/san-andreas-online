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
root, resourceRoot = {kind = 'root', data = {}}, {kind = 'resource', data = {}}

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

function get(name) return false end
function getTickCount() return T end
function isElement(e) return type(e) == 'table' and e.kind ~= nil and e.alive == true end
function getElementType(e) return e.kind end
function getElementPosition(e) return e.x, e.y, e.z end
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

local function countServerEvents(name)
    local n = 0
    for _, e in ipairs(serverEvents) do if e.name == name then n = n + 1 end end
    return n
end

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

print(('server_spec: %d checks passed'):format(passed))
