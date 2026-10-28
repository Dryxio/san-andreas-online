local handlers, timers, sent = {}, {}, {}
root, resourceRoot, localPlayer = {}, {}, {kind="player"}
local now, wander, restored, damage, replies = 0, 0, 0, 0, 0
local function element(kind) return {kind=kind, alive=true} end
local ped, vehicle, remote = element("ped"), element("vehicle"), element("player")
local nativeResponse = {{type=900,values={0,0,0,0,0,0,0,0}}}
function isElement(e) return type(e)=="table" and e.alive end
function getElementType(e) return e.kind end
function addEvent() end
function addEventHandler(name, _, fn) handlers[name]=fn end
function setTimer(fn, ms, count) timers[#timers+1]={fn=fn,count=count};return fn end
function triggerServerEvent(name, _, ...) sent[#sent+1]={name=name,args={...}} end
function isElementSyncer(e) return e==ped and ped.owner==localPlayer end
function isElementStreamedIn() return true end
function isPedDead() return false end
function isPedMissionActor() return true end
function canPedBeDraggedOut() return false end
function setPedMissionActor() end
function setPedCanBeDraggedOut() end
function acquirePedNativeEventProfile() return 10 end
function releasePedNativeEventProfile() nativeResponse={} end
function acquireElementStreamingLease() return 20 end
function releaseElementStreamingLease() end
function isPedNativeEventProfileActive() return true end
function isPedDoingTask() return false end
function getPedOccupiedVehicle() return false end
function setPedExitVehicle() return true end
function getTickCount() return now end
function setPedWander() wander=wander+1;nativeResponse={};return true end
function killPedTask() end
function getPedNativeVehicleResponse() return nativeResponse end
function restorePedNativeVehicleResponse(_, response) restored=restored+1; nativeResponse=response;return true end
function addPedNativeDamageEvent() damage=damage+1;return true end
function addPedNativeDamageResponseEvent() replies=replies+1;return true end
function outputDebugString() end
local function event(name, src, ...) source=src;handlers[name](...) end
local function tick()
    now=now+100
    local copy={};for i,t in ipairs(timers) do copy[i]=t end
    for _,t in ipairs(copy) do if t.count~=1 or not t.fired then t.fn();t.fired=true end end
end
dofile("official-resources/native-vehicle-traffic/occupant_client.lua")
ped.owner=localPlayer
event("carOccupants:state", resourceRoot, 1,1,localPlayer,vehicle,{ped},false,false)
tick()
assert(wander==0, "a native fight/flee response must survive initial baseline setup")
nativeResponse=false;tick()
assert(wander==0, "an unsupported active native response must not be cleared")
nativeResponse={};tick()
assert(wander==1, "wander starts only after native response completion")
tick();assert(wander==1, "baseline not resent each tick")
local continuation={{type=900,values={1,2,3,4,5,6,7,8}}}
event("carOccupants:state", resourceRoot,1,2,localPlayer,vehicle,{ped},false,continuation)
tick()
assert(restored==1 and wander==1, "restored reaction cannot be immediately cleared by wander")
event("carOccupants:revoke",resourceRoot,1,2)
assert(sent[#sent].name=="carOccupants:released" and sent[#sent].args[3]==continuation)
ped.owner=remote
event("carOccupants:state",resourceRoot,1,3,remote,vehicle,{ped},false,false);tick()
event("carOccupants:damage",resourceRoot,1,2,1,3,5,0);assert(damage==0,"old epoch hit rejected")
event("carOccupants:damage",resourceRoot,1,3,1,3,5,0)
event("carOccupants:damage",resourceRoot,1,3,1,3,5,0);assert(damage==1,"native damage applied once")
ped.owner=localPlayer
event("carOccupants:state",resourceRoot,1,4,localPlayer,vehicle,{ped},false,false);tick()
event("onClientPedDamage",ped,remote,0,3)
event("carOccupants:hit",resourceRoot,1,4,remote,1,3);tick()
assert(replies==0,"ordinary native hit prevents duplicate reaction")
event("carOccupants:hit",resourceRoot,1,4,remote,2,3);tick()
assert(replies==1,"missing native personality response bridged without health replay")
print("PASS: native response preservation, baseline completion, handoff, stale damage and incoming hit deduplication")
