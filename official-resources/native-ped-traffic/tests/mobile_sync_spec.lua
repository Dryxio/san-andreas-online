-- Run from the resource directory's parent. Exercise the production Android
-- assignment and camera vote with deterministic GTA replies.
local f = assert(io.open("native-ped-traffic/client.lua", "r"))
local client = f:read("*a")
f:close()

local function section(first, nextSection)
    local start = assert(client:find(first, 1, true))
    local finish = assert(client:find(nextSection, start + #first, true))
    return client:sub(start, finish - 1)
end

local ped = {}
local owner, streamed, installed = true, true, false
local queued, stopped, accepted = 0, 0, 0
local task = {ped = ped, direction = 2, epoch = 1, requestedAt = 100}
assignments = {[ped] = task}
stats = {assignments = 0, failures = 0}
isMobileClient = true
function getNeonTrafficCapability(name) return name == "ped-wander" end
function getTickCount() return 100 end
function isElement(value) return value == ped end
function isElementStreamedIn() return streamed end
function isElementSyncer() return owner end
function isPedDead() return false end
function acquireElementStreamingLease() return 5 end
function releaseElementStreamingLease() end
function setPedWander()
    queued = queued + 1
    return true
end
function isPedDoingTask(_, name) return installed and name == "TASK_COMPLEX_WANDER" end
function killPedTask() stopped = stopped + 1 end
function setTimer(fn) return fn end
function clearTimer(object, key) object[key] = nil end
function log() end
function report(_, stage)
    assert(stage == "accepted")
    accepted = accepted + 1
end

local loadChunk = loadstring or load
local begin = assert(loadChunk(section("local function releaseTask(task", "local function stopResidencyObservation()") ..
    "\nreturn beginAssignment"))()
streamed = false
begin(task)
assert(queued == 0 and accepted == 0, "no task before native stream-in")
streamed = true
task.retryTimer()
assert(queued == 1 and accepted == 0, "return from setPedWander only acknowledges the queue")
installed = true
task.retryTimer()
assert(queued == 1 and accepted == 1, "one acceptance after native installation")
owner = false
task.monitorTimer()
assert(stopped == 1 and not assignments[ped], "release immediately when the syncer changes")

local handlers = {}
enabled, populationWorldReady, populationWorldRevision = true, true, 4
latestPopulationProfile = {worldRevision = 4, capturedAt = 100, creationDistanceMultiplier = 1}
localPlayer, resourceRoot = {}, {}
function addEvent() end
function addEventHandler(name, _, fn) handlers[name] = fn end
function getElementPosition() return 0, 0, 0 end
local vote
function triggerServerEvent(name, _, _, result)
    assert(name == "pedTraffic:visibilityProbeResult")
    vote = result
end
local cameraReply, cameraFailure, samples = false, nil, 0
function isAmbientPedSphereVisible()
    samples = samples + 1
    return cameraReply, cameraFailure
end

assert(loadChunk(section('addEvent("pedTraffic:visibilityProbe"', 'addEvent("pedTraffic:spawnFadeIn"')))()
local probe = handlers["pedTraffic:visibilityProbe"]
probe(1, "candidate", {{x = 20, y = 0, z = 10, radius = 1}}, "civilian")
assert(vote == false and samples == 1, "Android permits a nearby point outside the camera")
cameraReply = true
probe(2, "candidate", {{x = 20, y = 0, z = 10, radius = 1}}, "civilian")
assert(vote == true and samples == 2, "Android vetoes a point in view")
cameraReply, cameraFailure = false, "visibility-unavailable"
probe(3, "candidate", {{x = 20, y = 0, z = 10, radius = 1}}, "civilian")
assert(vote == true and samples == 3, "an unavailable camera is not an off-screen vote")
probe(4, "candidate", {{x = 80, y = 0, z = 10, radius = 1}}, "civilian")
assert(vote == false and samples == 3, "a distant point does not need a camera vote")
print("PASS: mobile wander acknowledgement, syncer loss and camera visibility")

latestPopulationProfile.creationDistanceMultiplier = nil
vote = nil
probe(5, "candidate", {{x = 20, y = 0, z = 10, radius = 1}}, "civilian")
assert(vote == true, "an incomplete profile must still answer the server")

dofile("native-ped-traffic/population_catalog.lua")
dofile("native-ped-traffic/population_zone_bounds.lua")
dofile("native-ped-traffic/population_world.lua")
populationCatalog = PedTrafficPopulationCatalog
function getElementPosition() return 2490, -1670, 13 end
function getZoneName() return "Los Santos" end
function getTime() return 12, 0 end
function getGroundPosition() return 13 end
function isWorldRPGMobilePopulation() return true end
PedTrafficPopulationCatalog = nil -- no-cache client loads before cached catalog
assert(loadChunk(section("local function worldRPGMobilePopulation()", "if type(addPedNativeGunAimedAtEvent)") ..
    "\nmobileZones = populationCatalog.zones"))()
PedTrafficPopulationCatalog = populationCatalog
local profile = assert(getAmbientPedPopulationProfile())
assert(profile.zoneLabel and profile.zoneType == populationCatalog.zones[profile.zoneLabel].populationType)
-- The APK falls back when its native creation oracle cannot select a point.
-- Use a sloped surface so copying the anchor's Z fails for the other members.
local function surface(x, y) return 10 + x * 0.001 - y * 0.002 end
getGroundPosition = surface
local function supported(ped, lift)
    assert(math.abs(ped.z - surface(ped.x, ped.y) - lift) < 0.00001)
end
supported(assert(getAmbientPedSpawnCandidate(2490, -1670, 13, "civilian", false)), 0.7)
local group = assert(getAmbientPedGangGroupCandidate(2490, -1670, 13, 0, 3))
for _, member in ipairs(group.members) do supported(member, 1) end
local couple = assert(getAmbientPedCivilianCoupleCandidate(2490, -1670, 13))
for _, member in ipairs(couple.members) do supported(member, 0.7) end
assert(couple.members[1].model ~= couple.members[2].model)
local calls = 0
function getGroundPosition()
    calls = calls + 1
    if calls == 1 then return 13 end
    return false
end
local pair, reason = getAmbientPedCivilianCoupleCandidate(2490, -1670, 13)
assert(not pair and reason == "ground-missing", "never duplicate a partner when its ground is missing")
calls = 0
local gang
gang, reason = getAmbientPedGangGroupCandidate(2490, -1670, 13, 0, 3)
assert(not gang and reason == "ground-missing")
function getGroundPosition() return 0 end
function processLineOfSight() return false end
assert(not getAmbientPedSpawnCandidate(2490, -1670, 13, "civilian", false))
function processLineOfSight() return true, 0, 0, 0 end
assert(getAmbientPedSpawnCandidate(2490, -1670, 13, "civilian", false).z == 0.7)
getGroundPosition = surface
print("PASS: ground at each ped, gang and couple position; distinct partner, missing floor and confirmed zero height")
local sf = assert(io.open("native-ped-traffic/server.lua"))
local server = sf:read("*a")
sf:close()
local validation = server:sub(assert(server:find("local function isFiniteNumber", 1, true)),
    assert(server:find("local function calculateNativeTargets", 1, true)) - 1)
populationWorld = {revision = 4, zones = populationCatalog.zones}
profile.worldRevision, profile.catalogRevision = 4, populationCatalog.revision
assert(assert(loadChunk(validation .. "\nreturn validatePopulationProfile"))()(profile))
for _, kind in ipairs({"civilian", "cop", "dealer", "gang"}) do
    local candidate = getAmbientPedSpawnCandidate(2490, -1670, 13, kind, kind == "gang" and 0 or false)
    assert(candidate.pedType and (kind == "gang" or candidate.gang == false))
    if kind == "civilian" then assert(populationCatalog.civilianPedTypeByModel[candidate.model] == candidate.pedType) end
end
print("PASS: mobile fallback profile accepted by the server and candidate model contracts")

-- The server may first receive the world acknowledgement while the player is
-- still in the login dimension. The revision also needs to survive spawn.
do
    local f = assert(io.open("native-ped-traffic/server.lua"))
    local server = f:read("*a")
    f:close()
    local a = assert(server:find('addEvent("pedTraffic:populationWorldApplied"', 1, true))
    local b = assert(server:find('addEvent("pedTraffic:residencySample"', a, true))
    local joined, timers, sent = {}, {}, {}
    local world, now = false, 500
    local env = setmetatable({
        enabled = true, resourceRoot = {}, root = {}, client = joined,
        populationWorld = {revision = 2}, populationCatalog = {revision = "catalog"},
        populationWorldRevisions = {},
        addEvent = function() end,
        addEventHandler = function(name, _, fn) handlers[name] = fn end,
        setTimer = function(fn) timers[#timers + 1] = fn end,
        getTickCount = function() return now end,
        isElement = function(p) return p == joined end,
        getElementType = function() return "player" end,
        getPlayerName = function() return "mobile" end,
        isEligiblePlayer = function() return world end,
        triggerClientEvent = function() end, setElementData = function(p, key, value) p[key] = value end,
        sendPopulationWorldState = function(p) sent[#sent + 1] = p end,
        log = function() end
    }, {__index = _G})
    env.source = env.resourceRoot
    env.isPopulationWorldReady = function(p) return env.populationWorldRevisions[p] == env.populationWorld.revision end
    local script = server:sub(a, b - 1)
    if setfenv then
        setfenv(assert(loadChunk(script)), env)()
    else
        assert(load(script, "population handshake", "t", env))()
    end
    handlers["pedTraffic:ready"]()
    local caps = {mobilePolyfill = true, pedWander = true, catalogRevision = "catalog"}
    handlers["pedTraffic:populationWorldApplied"](2, {populationFallback = true, pedWander = true, catalogRevision = "catalog"}, true)
    assert(joined["neon:isMobileClient"] == false and joined["neon:pedOwnerEligible"] == false)
    env.populationWorldRevisions[joined] = nil
    handlers["pedTraffic:populationWorldApplied"](1, caps, true)
    assert(not env.isPopulationWorldReady(joined))
    handlers["pedTraffic:populationWorldApplied"](2, caps, true)
    assert(env.isPopulationWorldReady(joined) and not world)
    world, now = true, 15000
    timers[1]()
    assert(#sent == 1)
    env.populationWorld.revision = 3
    timers[1]()
    assert(#sent == 2 and sent[2] == joined)
    env.source = joined
    handlers.onPlayerQuit()
    now = 30000
    timers[1]()
    assert(#sent == 2)
end
print("PASS: pre-spawn world acknowledgement, stale revision, targeted retry and disconnect")
