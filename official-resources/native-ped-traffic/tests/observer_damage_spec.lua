-- Run from the directory containing native-ped-traffic.
local handlers, tick, wanted, calls = {}, 0, false, 0
root, resourceRoot = {}, {}
local phone = {kind="player", platform=true}
local player = {kind="player", weapon=22, x=0}
local ped = {kind="ped", owner=phone, x=10, health=100}
function isElement(e) return type(e) == "table" end
function getElementType(e) return e.kind end
function getElementSyncer(e) return e.owner end
function getPedWeapon(e) return e.weapon end
function isPedDead(e) return e.dead end
function getElementDimension(e) return e.dimension or 0 end
function getElementInterior() return 0 end
function getElementPosition(e) return e.x or 0,0,0 end
function getDistanceBetweenPoints3D(x,y,z,a,b,c) return math.sqrt((x-a)^2+(y-b)^2+(z-c)^2) end
function getElementHealth(e) return e.health end
function getWeaponProperty() return 25 end
function getTickCount() return tick end
function getElementData(e, key) return key=="neon:isMobileClient" and e.platform or e[key] end
function setElementData(e,key,val) e[key]=val end
function removeElementData(e,key) e[key]=nil end
function getResourceFromName() return wanted end
function getResourceState() return "running" end
function getResourceExportedFunctions() return {"handlesTrafficBulletDamage"} end
function getElementsByType() return {phone, player} end
function setElementHealth(e, health) calls=calls+1; e.health=health end
function killPed(e, shooter) calls=calls+1; e.dead=true; e.killer=shooter end
function addEvent() end
function addEventHandler(name, _, action) handlers[name]=action end
exports={["native-wanted-police"]={handlesTrafficBulletDamage=function() return true end}}
local function fire(name, src, sender, ...)
    source,client=src,sender
    handlers[name](...)
end
dofile("native-ped-traffic/observer_damage.lua")
TrafficObserverDamage.install(function(e) return e==ped end)
TrafficObserverDamage.mark(ped)
assert(ped["neon:serverBulletDamage"] and ped["neon:ambientDamageAuthority"])
fire("onResourceStart",resourceRoot,nil)
local function hint() fire("pedTraffic:bulletCollision",resourceRoot,player,ped,22) end
local function shot(y) fire("onPlayerWeaponFire",player,nil,22,30,y or 0,0.6,nil,0,0,0.6) end
hint(); assert(calls==0)
shot(); assert(ped.health==75)
shot(); hint(); assert(ped.health==50)
hint(); shot(35); assert(calls==2)
tick=tick+800
wanted=true; fire("onResourceStart",{},nil,wanted); shot(); hint(); assert(calls==2)
fire("onResourceStop",{},nil,wanted); wanted=false; ped.dimension=9; shot(); hint(); assert(calls==2)
tick=tick+800; ped.dimension=0; ped.owner=player; hint(); shot(); assert(calls==2)
tick=tick+800; ped.owner=phone; player.weapon=0; ped.x=9
TrafficObserverDamage.melee(player,ped,0,3); assert(calls==2)
ped.x=3
TrafficObserverDamage.melee(player,ped,0,3); TrafficObserverDamage.melee(player,ped,0,3)
assert(calls==3 and ped.health==25)
player.weapon=22; shot(); hint(); assert(ped.killer==player)
TrafficObserverDamage.release(ped)
assert(not ped["neon:serverBulletDamage"] and not ped["neon:ambientDamageAuthority"])
print("PASS: standalone and shared damage authority, both packet orders, invalid hits, melee cadence and lethal credit")
