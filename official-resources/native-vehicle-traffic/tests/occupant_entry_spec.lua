-- Exercise the real event handler with MTA's pre-event seat reservation.
local file = assert(io.open("official-resources/native-vehicle-traffic/server.lua", "r"))
local code = file:read("*a"); file:close()
local first = assert(code:find('addEventHandler("onVehicleStartEnter", root, function', 1, true))
local last = assert(code:find('addEventHandler("onVehicleEnter", root, function', first, true))
local handler
root = {}
function addEventHandler(_, _, fn) handler = fn end
function getElementType(element) return element.kind end
function getVehicleOccupant(vehicle, seat) return vehicle.seats[seat] or false end
local cancelled, revokes = 0, 0
function cancelEvent() cancelled = cancelled + 1 end
local car = {kind="vehicle",seats={}}
local player = {kind="player"}
local npc = {kind="ped"}
local unit = {vehicle=car,state="active"}
local constructor = assert((loadstring or load)("return function(units, beginRevoke)\n" .. code:sub(first,last-1) .. "\nend"))()
constructor({unit},function(u,p,why) assert(u==unit and p==player and why=="player-takeover");revokes=revokes+1;return true end)
source=car
car.seats[1]=player
handler(player,1)
assert(cancelled==0 and revokes==0,"the entrant's passenger reservation is not a jack victim")
car.seats[1]=nil
handler(player,1)
assert(cancelled==0 and revokes==0,"unreserved free passenger seat also stays in road activity")
car.seats[0]=npc
handler(player,0)
assert(cancelled==1 and revokes==1 and unit.pendingTakeover==player and unit.takeoverSeat==0)
handler(npc,0)
assert(revokes==1,"native NPC entry cannot manufacture a player takeover")
print("PASS: actual entry handler respects MTA reservation order and driver takeover")
