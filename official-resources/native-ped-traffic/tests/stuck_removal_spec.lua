-- Run from the directory containing native-ped-traffic.
local file = assert(io.open("native-ped-traffic/server.lua"))
local code = file:read("*a")
file:close()
local stuck = assert(code:find('removeRecord(record, "ped-stuck-obstacle")', 1, true))
local start = assert(code:sub(1, stuck):match(".*()    local records = {}"))
local finish = assert(code:find("end, 1000, 0)", stuck, true))
local run = assert((loadstring or load)("local now = 16000\n" .. code:sub(start, finish - 1)))
local blocked = {ped = {live = true}, state = "active", lastPosCheckAt = 12000,
    lastCheckX = 0, lastCheckY = 0, stuckTicks = 2}
local other = {ped = {live = true}, state = "revoking", handoffDeadline = 0}
trafficPeds = {[blocked.ped] = blocked, [other.ped] = other}
local removals, handoffs = 0, 0
function isElement(ped) return ped.live end
function isPedDead() return false end
function getElementPosition(ped) assert(ped.live); return 0, 0, 0 end
function removeRecord(record, reason)
    assert(record == blocked and reason == "ped-stuck-obstacle")
    record.removing, record.ped.live = true, false
    trafficPeds[record.ped] = nil
    removals = removals + 1
end
function findClosestPopulationResident() error("removed ped reached residency check") end
function finishHandoff(record) assert(record == other); handoffs = handoffs + 1 end
run()
assert(removals == 1 and handoffs == 1, "each record must complete independently")
print("stuck ped removal and next record passed")
