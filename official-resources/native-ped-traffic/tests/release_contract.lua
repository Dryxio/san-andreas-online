-- Run from the repository root with Lua 5.1+.
-- Executes the production releaseTrafficCop (the hand-over of a street cop to
-- native-wanted-police) with deterministic MTA boundaries. It checks who may
-- take a cop and what the traffic record leaves behind; the client release
-- of the ambient profile and GTA's tasks need a real client.
local function read(path)
    local file = assert(io.open(path)); local text = file:read('*a'); file:close(); return text
end
local function section(text, first, last)
    local a = assert(text:find(first, 1, true)); local b = assert(text:find(last, a + #first, true))
    return text:sub(a, b - 1)
end
local passed = 0
local function check(name, condition)
    if not condition then error('FAILED: ' .. name, 2) end
    passed = passed + 1
end

local server = read('official-resources/native-ped-traffic/server.lua')
local meta = read('official-resources/native-ped-traffic/meta.xml')
check('the export is declared server-side', meta:find('<export function="releaseTrafficCop" type="server" />', 1, true) ~= nil)

local thisResource = {name = 'native-ped-traffic', state = 'running'}
local police = {name = 'native-wanted-police', state = 'running'}
local sends, traces = {}, {}
root, resourceRoot = {}, {}
trafficPeds = {}
function getThisResource() return thisResource end
function getResourceState(r) return r.state end
function getResourceName(r) return r.name end
function isElement(x) return type(x) == 'table' and x.kind ~= nil and x.alive ~= false end
function isPedDead(x) return x.dead == true end
function setElementData(x, key, value) x.data[key] = value; return true end
function removeElementData(x, key) x.data[key] = nil; return true end
function setElementFrozen(x, frozen) x.frozen = frozen; return true end
function triggerClientEvent(target, name, _, ...) sends[#sends + 1] = {target = target, name = name, args = {...}} end
function getTrafficPedCount() local n = 0 for _ in pairs(trafficPeds) do n = n + 1 end return n end
function log() end
function writePopulationTrace(event, fields) traces[#traces + 1] = {event = event, fields = fields} end
assert((loadstring or load)(section(server, 'function releaseTrafficCop(ped)', 'local function sendAssignment')))()

local owner = {kind = 'player'}
local function cop(fields)
    local ped = {kind = 'ped', data = {['neon:ambientPedTraffic'] = true, ['neon:ambientPedCopSafe'] = true,
                                       ['neon:ambientPedTrafficEpoch'] = 4}, frozen = true}
    local record = {id = #traces + 10, ped = ped, owner = owner, epoch = 4, state = 'active', populationClass = 'cop'}
    for key, value in pairs(fields or {}) do record[key] = value end
    trafficPeds[ped] = record
    return ped, record
end
local function call(ped, from, fromClient)
    sourceResource, client = from, fromClient
    local result = releaseTrafficCop(ped)
    sourceResource, client = nil, nil
    return result
end

local ped, record = cop()
check('a client cannot take a cop', call(ped, police, owner) == false and trafficPeds[ped] == record)
check('the traffic resource cannot take its own cop', call(ped, thisResource) == false)
police.state = 'stopping'
check('a stopping resource cannot take a cop', call(ped, police) == false)
police.state = 'running'
check('a running server resource takes a settled cop', call(ped, police) == true)
check('the record is gone without destroying the ped', trafficPeds[ped] == nil and record.removing == true and ped.alive ~= false)
check('the owner ends its wander task', sends[1].target == owner and sends[1].name == 'pedTraffic:stop' and sends[1].args[2] == 4)
check('every client drops the ambient profile', ped.data['neon:ambientPedTraffic'] == false and ped.data['neon:ambientPedCopSafe'] == false)
check('old-epoch traffic messages no longer match', ped.data['neon:ambientPedTrafficEpoch'] == nil and ped.frozen == false)
check('the release is traced', traces[#traces].event == 'release' and traces[#traces].fields.to == 'native-wanted-police')
check('a released cop cannot be released twice', call(ped, police) == false)

for _, case in ipairs({
    {'a civilian', {populationClass = 'civilian'}},
    {'a gang member', {populationClass = 'gang', group = {}}},
    {'a cop mid-handoff', {state = 'revoking'}},
    {'a suspended cop', {state = 'suspended'}},
    {'a cop being assigned', {state = 'assigning'}},
    {'a cop under a visibility check', {visibilityCheckId = 3}},
    {'a cop in an air test', {airTest = {}}},
}) do
    local other, otherRecord = cop(case[2])
    check(case[1] .. ' is refused', call(other, police) == false and trafficPeds[other] == otherRecord)
end
local dead = cop()
dead.dead = true
check('a dead cop is refused', call(dead, police) == false)

print(('release_contract: %d checks passed'):format(passed))
