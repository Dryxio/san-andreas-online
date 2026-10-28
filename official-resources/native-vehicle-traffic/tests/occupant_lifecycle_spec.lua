-- Exercise the production lifecycle against engine boundaries, not a copy of
-- its state machine. In particular, vehicle theft must not delete any actor.
local handlers, timers, messages = {}, {}, {}
local now, deleted = 0, 0
root, resourceRoot = {}, {}
local function element(kind, x) return {kind = kind, x = x or 0, alive = true, dimension = 0, interior = 0} end
local a, b = element("player"), element("player", 10)
local players = {a, b}
function isElement(e) return type(e) == "table" and e.alive == true end
function getElementType(e) return e.kind end
function getElementDimension(e) return e.dimension end
function getElementInterior(e) return e.interior end
function getElementPosition(e) return e.x, 0, 0 end
function getDistanceBetweenPoints3D(x, y, z, xx, yy, zz) return math.abs(x - xx) end
function getTickCount() return now end
function setPedFightingStyle() return true end
function isPedDead(e) return e.dead == true end
function setElementSyncer(e, owner) e.owner = owner; return true end
function getElementSyncer(e) return e.owner end
function getVehicleOccupant(e) return e.driver end
function removeElementData() return true end
function destroyElement(e) e.alive = false; deleted = deleted + 1; return true end
function getElementsByType(kind) return kind == "player" and players or {} end
function addEvent() end
function addEventHandler(name, target, fn) handlers[name] = fn end
function setTimer(fn) timers[#timers + 1] = fn; return fn end
function triggerClientEvent(recipient, name, src, ...) messages[#messages + 1] = {recipient = recipient, name = name, args = {...}} end
local function event(name, who, ...) client, source = who, resourceRoot; handlers[name](...) end
local function tick(ms) now = now + ms; for _, fn in ipairs(timers) do fn() end end
local function stateFor(ped)
    for i = #messages, 1, -1 do
        local m = messages[i]
        if m.name == "carOccupants:state" and m.args[5][1] == ped then return m.args end
    end
end
dofile("official-resources/native-vehicle-traffic/occupant_lifecycle.lua")
event("carOccupants:ready", a); event("carOccupants:ready", b)
local car, driver, passenger = element("vehicle"), element("ped"), element("ped")
car.driver = driver
local accepted = 0
assert(TrafficOccupantLifecycle.retain(car, {driver, passenger}, a, false, function() accepted = accepted + 1 end))
assert(deleted == 0 and isElement(driver) and isElement(passenger), "retention preserves both identities")
local d, p = stateFor(driver), stateFor(passenger)
assert(d[1] ~= p[1] and d[3] == a and p[3] == a, "paired initial authority, independent actor lifetimes")
event("carOccupants:accepted", b, d[1], d[2]); assert(accepted == 0, "non-owner cannot release entry barrier")
event("carOccupants:accepted", a, d[1], d[2] - 1); assert(accepted == 0, "stale epoch ignored")
event("carOccupants:accepted", a, d[1], d[2]); assert(accepted == 0, "all occupants must be ready")
event("carOccupants:accepted", a, p[1], p[2]); assert(accepted == 1)
event("carOccupants:accepted", a, p[1], p[2]); assert(accepted == 1, "duplicate ACK cannot restart extraction")
-- A remains near the driver; B follows the passenger in the stolen car.
passenger.x, b.x = 500, 505
tick(500)
event("carOccupants:released", a, p[1], p[2])
assert(passenger.owner == b and driver.owner == a, "separated actors elect independently")
event("carOccupants:released", a, p[1], p[2])
assert(passenger.owner == b, "old owner cannot overwrite the successor")
driver.dead = true
tick(61000)
assert(deleted == 0, "visible corpses and survivors are retained")
players, a.x, b.x = {}, 2000, 2000
tick(500); tick(61000)
assert(not isElement(driver) and not isElement(passenger) and isElement(car), "actor cleanup never destroys retained vehicle")
print("PASS: occupant identity, ACK barrier, stale/wrong owner, separated authority, corpse/survivor and vehicle lifetime")

-- Destroying a not-yet-ready actor cannot hold surviving actors hostage.
players, a.x, b.x = {a, b}, 0, 10
local car2, d2, p2 = element("vehicle"), element("ped"), element("ped")
car2.driver = d2
local ready2 = 0
TrafficOccupantLifecycle.retain(car2, {d2,p2}, a, false, function() ready2 = ready2 + 1 end)
local ds, ps = stateFor(d2), stateFor(p2)
event("carOccupants:accepted", a, ds[1], ds[2])
destroyElement(p2); tick(500)
assert(ready2 == 1, "destroyed passenger resolves the entry barrier")
-- Store only the current authority's bounded semantic snapshot and preserve
-- exact target identities through a release/reassignment.
local response = {{type = 900, target = b, vehicle = car2, values = {1,2,3,4,5,6,7,8}}}
event("carOccupants:response", b, ds[1], ds[2], response)
a.x = 500; tick(500)
event("carOccupants:released", a, ds[1], ds[2], response)
local reassigned = stateFor(d2)
assert(reassigned[3] == b and reassigned[7][1].target == b and reassigned[7][1].vehicle == car2)
assert(reassigned[7][1].values[8] == 8)
-- An empty live snapshot clears completed intent; an older owner cannot
-- reinstate it and an unbounded payload cannot cross the native boundary.
event("carOccupants:response", b, reassigned[1], reassigned[2], {})
event("carOccupants:response", a, reassigned[1], ds[2], response)
event("carOccupants:response", b, reassigned[1], reassigned[2], {{type=900, values={0/0,0,0,0,0,0,0,0}}})
event("carOccupants:ready", a)
assert(#stateFor(d2)[7] == 0)
function getPedWeapon(e) return e.weapon or 0 end
local function lastMessage() return messages[#messages] end
local count = #messages
a.x = 1
local id, epoch = reassigned[1], reassigned[2]
event("carOccupants:accepted", b, id, epoch)
event("carOccupants:damageObserved", a, id, epoch, a, 1, 3, 5, 0)
assert(#messages == count, "non-owner cannot submit damage")
event("carOccupants:damageObserved", b, id, epoch, a, 1, 3, 200, 0)
assert(#messages == count, "unreachable unarmed factor rejected")
event("carOccupants:damageObserved", b, id, epoch, a, 1, 3, 5, 0)
assert(#messages == count+1 and lastMessage().name == "carOccupants:damage" and lastMessage().recipient == a)
event("carOccupants:damageObserved", b, id, epoch, a, 1, 3, 5, 0)
event("carOccupants:damageObserved", b, id, epoch, a, 2, 3, 5, 0)
assert(#messages == count+1, "duplicate and implausible cadence rejected")
a.x = 100
event("carOccupants:damageObserved", b, id, epoch, a, 3, 3, 5, 0)
assert(#messages == count+1, "distant fabricated contact rejected")
print("PASS: destroyed readiness, semantic snapshot, stale owner, bounded payload and remote melee validation")
