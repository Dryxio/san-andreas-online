-- Run from the parent directory of the traffic resources.
local function section(fileName, first, last)
    local file = assert(io.open("native-ped-traffic/" .. fileName))
    local sourceCode = file:read("*a")
    file:close()
    local start = assert(sourceCode:find(first, 1, true))
    local finish = assert(sourceCode:find(last, start + #first, true))
    return sourceCode:sub(start, finish - 1)
end
local compile = loadstring or load
local events, messages, timer = {}, {}, nil
local owner, observer, loading = {}, {}, {}
source, resourceRoot, root = {}, {}, {}
source, client = resourceRoot, observer
function getElementsByType() return {owner, observer, loading} end
function isEligiblePlayer(p) return p == owner or p == observer end
function isPedOwnerEligible(p) return p == owner end
function isPopulationWorldReady(p) return p ~= loading end
local collect = assert(compile(section("server.lua", "local function getPopulationPlayers", "local function getPopulationWorldConvergencePlayerCount")
    .. "return getPopulationPlayers"))()
assert(#collect(isPedOwnerEligible) == 1)
assert(#collect(isEligiblePlayer) == 2 and collect(isEligiblePlayer)[2] == observer)

local scene = {
    {kind="ped", ["worldrpg:pedRouteIndex"]=3}, {kind="ped", ["worldrpg:staticPedIndex"]=3},
    {kind="ped", ["neon:ambientPedTrafficId"]=7}, {kind="ped", ["neon:ambientPedTrafficId"]=9, alpha=0},
    {kind="vehicle", ["neon:ambientVehicleTrafficId"]=11}, {kind="vehicle", ["worldrpg:routeIndex"]=2},
    {kind="vehicle", ["neon:ambientVehicleTrafficId"]=12, outside=true},
}
local now = 5000
function getElementType(e) return e.kind end
function getElementData(e, k) return e[k] end
function getElementAlpha(e) return e.alpha or 255 end
function isElementStreamedIn(e) return not e.outside end
function getElementDimension() return 0 end
function getElementInterior() return 0 end
function getElementPosition() return 1187, -1324, 13.5 end
function getElementsWithinRange(_, _, _, radius, kind, interior, dimension)
    assert(radius == 150 and kind == nil and interior == 0 and dimension == 0)
    return scene
end
function getPlayerName() return "observer" end
function isIntegerInRange(v, lo, hi) return type(v) == "number" and v % 1 == 0 and v >= lo and v <= hi end
function getTickCount() return now end
function addEvent() end
function addEventHandler(name, _, handler) events[name] = handler end
function triggerServerEvent(name, _, ...) events[name](...) end
function setTimer(handler) timer = handler end
function outputServerLog(s) messages[#messages+1] = s end
enabled, debugEnabled, isMobileClient = true, true, true
assert(compile(section("server.lua", "do\n    local lastSample", "setTimer(emitPedProductionTelemetry")))()
assert(compile(section("client.lua", "-- Sample client stream state", "local function monitorPhysicalTestSessions")))()
timer()
assert(messages[1]:find("pedIds=[7] vehicleIds=[11] walkerIds=[3] staticIds=[3] routeVehicleIds=[2]", 1, true))
timer()
assert(#messages == 1)
now, scene = 10000, {}
timer()
assert(messages[2]:find("pedIds=[] vehicleIds=[] walkerIds=[] staticIds=[] routeVehicleIds=[]", 1, true))
print("PASS: observer eligibility, nearby streamed IDs, hidden actors, both hospital roles and empty street")

-- An observer who cannot host a ped must still be asked before it disappears.
local target = {ped = {}, id = 9}
local asked = {}
getPopulationPlayers = collect
function isElement(value) return value ~= nil end
function triggerClientEvent(who, event) asked[who] = event end
function writePopulationTrace() end
pendingVisibilityChecks, nextVisibilityCheckId, config = {}, 0, {visibilityTimeout=1000}
local removal = assert(compile(section("server.lua", "local function beginRemovalVisibilityCheck", "local function clearTraffic")
    .. "return beginRemovalVisibilityCheck"))()
assert(removal(target, "surplus") and asked[observer] == "pedTraffic:visibilityProbe")
assert(pendingVisibilityChecks[target.visibilityCheckId].awaiting[observer] and asked[loading] == nil)
coupleRuntime = {}
assert(compile(section("server.lua", "function coupleRuntime.sendPresentations", "function coupleRuntime.sendAssignments")))()
local couple = {owner=owner, members={{ped={}}, {ped={}}}, id=1, epoch=2}
assert(coupleRuntime.sendPresentations(couple, "refresh") and asked[observer] == "pedTraffic:assignCouplePresentation")
print("PASS: removal waits for observer vote and couple presentation reaches observer")
