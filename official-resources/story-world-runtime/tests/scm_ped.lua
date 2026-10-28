-- Shared classification/lifecycle contracts; no GTA visual simulation.
local handlers = {}
root = {} resourceRoot = {} sourceResourceRoot = {}
local caller = sourceResourceRoot
function addEvent() end
function addEventHandler(name, _, f) handlers[name] = f end
function setTimer() return {} end
function outputServerLog() end
function isElement(e) return type(e) == "table" and not e.destroyed end
function createPed(model,x,y,z,h) return {kind="ped",model=model,x=x,y=y,z=z,h=h,data={}} end
function setElementDimension(ped,d) ped.dimension=d end
local acceptData=true
function setElementData(ped,key,value,mode,policy)
    assert(mode=="broadcast" and policy=="deny")
    if not acceptData then return false end
    ped.data[key]=value return true
end
function destroyElement(e)
    e.destroyed=true
    local old=source source=e handlers.onElementDestroy() source=old
end
function getResourceRootElement(r) return r end
function triggerEvent() end
dofile("official-resources/story-world-runtime/server.lua")
local p=createStoryScmPed(269,1,2,3,4,4182)
assert(p.z==4 and p.dimension==4182 and p.data["storyWorldRuntime:scmPed"])
sourceResourceRoot={}
local other=createStoryScmPed(270,1,2,3,4,4182)
handlers.onResourceStop(caller)
assert(p.destroyed and not other.destroyed,"caller stop crossed mission ownership")
acceptData=false
local refused,reason=createStoryScmPed(269,1,2,3,4,4182)
assert(refused==false and reason:find("replication failed"))
handlers.onResourceStop(resourceRoot)
assert(other.destroyed,"runtime stop left an actor behind")
print("PASS server SCM ped: coordinate conversion, protected replicated classification, failure and caller cleanup")

handlers={}
local a={kind="ped",data={["storyWorldRuntime:scmPed"]=true},mission=false}
local b={kind="ped",data={},mission=false}
local c={kind="ped",data={["storyWorldRuntime:scmPed"]=true},mission=true}
function getElementType(ped) return ped.kind end
function getElementData(ped,key) return ped.data[key] end
function isPedMissionActor(ped) return ped.mission end
function setPedMissionActor(ped,value) ped.mission=value return true end
function getElementsByType() return {a,b,c} end
function outputDebugString() error("unexpected classification failure") end
dofile("official-resources/story-world-runtime/scm_ped_client.lua")
handlers.onClientResourceStart()
assert(a.mission and not b.mission and c.mission,"late join changed unrelated ambient ped")
-- No owner check: an observer already carries the policy before handoff.
a.mission=false source=a handlers.onClientElementStreamIn()
assert(a.mission,"stream-in failed to reapply classification")
b.data["storyWorldRuntime:scmPed"]=true source=b
handlers.onClientElementDataChange("storyWorldRuntime:scmPed")
assert(b.mission,"live creation marker did not classify ped")
b.data["storyWorldRuntime:scmPed"]=nil
handlers.onClientElementDataChange("storyWorldRuntime:scmPed")
assert(not b.mission,"marker removal did not restore prior state")
source=a handlers.onClientElementDestroy() a.destroyed=true
handlers.onClientResourceStop()
assert(c.mission and not b.mission,"stop did not preserve preexisting mission policy")
print("PASS client SCM ped: live creation, late join, stream-in, observers, marker removal, destruction and restoration")
