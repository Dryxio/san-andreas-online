local file = assert(io.open("native-ped-traffic/client.lua"))
local code = file:read("*a")
file:close()
local first = assert(code:find("do\n    local function logTrafficPed", 1, true))
local last = assert(code:find('addEventHandler("onClientElementStreamIn"', first, true))
local chunk = assert((loadstring or load)(code:sub(first, last-1)))
local peds = {}
for id=1,16 do peds[id] = {id=id, valid=true} end
function isElement(ped) return ped.valid end
function isElementStreamedIn(ped) return ped.valid end
function getElementData(ped, key)
    if key == "neon:ambientPedTraffic" then return true end
    if key == "neon:ambientPedTrafficId" then return ped.id end
end
function getElementPosition() return 1, 2, 3 end
getElementVelocity, getElementRotation = getElementPosition, getElementPosition
function getGroundPosition() return false end
function getElementModel() return 17 end
function isElementSyncer() return false end
function getAvoidanceState() return false end
function getThreatState() return false,false end
getVehicleReactionState = getThreatState
nativeEventProfiles = {}
for _, mobile in ipairs({true, false}) do
    isMobileClient, enabled, debugEnabled = mobile, true, true
    local ticks = mobile and 8 or 1
    local timer, scans, queries = nil, 0, 0
    function setTimer(fn, ms) assert(ms*ticks==2000); timer = fn end
    function getElementsByType() scans = scans + 1; return peds end
    function log(msg) assert(msg:find("groundZ=false", 1, true)); queries = queries + 1 end
    chunk()
    for tick=1,ticks do
        timer()
        assert(queries==tick*16/ticks, "work must be distributed across timer ticks")
    end
    assert(scans==1)
    enabled = false
    timer()
    assert(scans==1 and queries==16)
end
print("PASS: all diagnostic IDs survive missing ground, Android batches work and disabled traffic stays idle")
