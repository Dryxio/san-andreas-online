-- Run from official-resources (or the World RPG resource directory).
local now, timer, handlers, commands, reads, maxReads
root = {}
function getTickCount() return now end
function addEventHandler(event, _, fn) handlers[event] = fn end
function setTimer(fn, interval) assert(interval == 100); timer = fn end
function isElement(p) return type(p) == "table" and p.valid ~= false end
function isElementStreamedIn(p) return p.streamed ~= false end
function isElementSyncer(p) return p.owner ~= false end
function isPedDead(p) return p.dead == true end
function isPedInVehicle(p) return p.seated == true end
function isElementFrozen(p) return p.frozen == true end
function getElementPosition(p) return p.x, p.y, p.z end
function getElementRotation(p) return 0, 0, p.heading or 0 end
function Vector3(x, y, z) return {x=x, y=y, z=z} end
function setPedWander(p, move, dir, sensible)
    commands[#commands+1] = {ped=p, move=move, dir=dir, sensible=sensible}
    return true
end
function setPedGoTo(p, point, move)
    commands[#commands+1] = {ped=p, move=move, point=point}
    return true
end
local ped, task, assignments
local function setup(mobile)
    now, timer, handlers, commands, reads, maxReads = 0, nil, {}, {}, 0, 0
    ped = {x=0, y=0, z=11, blocked=true, mode="walk"}
    task = {ped=ped, epoch=7, accepted=true, direction=3}
    assignments = {[ped]=task}
    getPedTrafficObstacleScan = function(p, resume)
        reads = reads + 1
        assert(isElementSyncer(p) and assignments[p].accepted)
        if p.unknown then return end
        return p.mode, p.heading or 0, 10, p.blocked, {[3]=10} -- the only mobile exit is west
    end
    dofile("native-ped-traffic/obstacle_client.lua")
    PedTrafficObstacles.install(assignments, mobile, function(p) return not p.released end,
        function(p) return p.attacker end)
end
local function tick(n)
    for _ = 1, n do
        now, reads = now + 100, 0
        timer()
        maxReads = math.max(reads, maxReads)
    end
end

-- Desktop uses the actual ray layout and ground-relative heights. Only the west
-- corridor has safe support; the others have either a low crate or a drop.
local waits, floorKnown, staticBlock
function isPedDoingTask(_, name)
    if waits then return name == waits end
    return name == "TASK_COMPLEX_WANDER" or (ped.mode == "flee" and name == "TASK_COMPLEX_FLEE_ENTITY")
end
function getGroundPosition(x, y)
    if not floorKnown then return false end
    if math.abs(x - ped.x) <= 0.01 and math.abs(y - ped.y) <= 0.01 then return 10 end
    if x < -2.7 and math.abs(y) < 0.1 then return 10 end
    return 6
end
function processLineOfSight(x, y, z, ex, ey, _, buildings, cars, peds, objects, dummies, _, _, _, ignored)
    assert(buildings and cars and not peds and objects and dummies and ignored == ped)
    return staticBlock and ey > 1 and (ey-y)^2 + (ex-x)^2 < 3 and math.abs(z - 10.25) < 0.001
end
setup(false)
floorKnown, staticBlock = true, true
tick(6)
assert(#commands == 1 and commands[1].move == "walk" and commands[1].dir == 6)
setup(false)
ped.mode = "flee"
ped.attacker = {x=2,y=0}
tick(6)
assert(#commands == 1 and commands[1].point.x < -2.7 and commands[1].point.z == 10)
assert(PedTrafficObstacles.isEvading(ped, 7) and not PedTrafficObstacles.isEvading(ped, 8))
ped.x, staticBlock = -1, false
tick(5)
assert(#commands == 2 and commands[2].move == "run" and commands[2].dir == 6)
assert(not PedTrafficObstacles.isEvading(ped, 7))
for _, name in ipairs({"TASK_COMPLEX_CROSS_ROAD_LOOK_AND_ACHIEVE_HEADING","TASK_SIMPLE_COWER",
                        "TASK_SIMPLE_HANDS_UP","TASK_SIMPLE_DUCK","TASK_COMPLEX_KILL_PED_ON_FOOT"}) do
    setup(false); waits = name; tick(45); assert(#commands == 0, name)
end
waits = nil
setup(false); floorKnown = false; tick(45); assert(#commands == 0)
setup(false); floorKnown = true; staticBlock = false; tick(29); assert(#commands == 0)
tick(8); assert(#commands == 1 and commands[1].dir == task.direction)
setup(false); staticBlock = true
for i=1,45 do ped.y=i*0.2; tick(1) end
assert(#commands == 0)
setup(true); tick(6)
assert(#commands == 1 and commands[1].dir == 6 and commands[1].move == "walk")
setup(true); PedTrafficObstacles.noteFlee(ped, {x=2,y=0}, 7); tick(6)
assert(#commands == 1 and commands[1].move == "run" and commands[1].dir == 6)
ped.x, ped.blocked = -1, false; tick(5)
assert(#commands == 2 and commands[2].move == "run" and commands[2].dir == 6)
for i=1,45 do ped.x=-1-i*0.2; tick(1) end
assert(#commands == 3 and commands[3].move == "walk")
setup(true); ped.mode = "crossing"; ped.heading = 270
PedTrafficObstacles.noteFlee(ped, {x=-2,y=0}, 7); tick(6)
assert(#commands == 1 and commands[1].dir == 2 and commands[1].move == "run")
setup(true); ped.mode="pause"; tick(45); assert(#commands == 0)
setup(true); ped.unknown=true; tick(45); assert(#commands == 0)
for _, field in ipairs({"seated","dead","frozen","released"}) do
    setup(true); ped[field]=true;tick(30);assert(#commands == 0 and maxReads == 0, field)
end
setup(true); ped.mode="flee"; tick(6)
ped.owner=false;tick(20);assert(#commands == 1 and not PedTrafficObstacles.isEvading(ped,7))
setup(true); ped.mode="flee"; tick(6)
source=ped;handlers.onClientElementStreamOut();ped.streamed=false;tick(30)
assert(#commands == 1 and not PedTrafficObstacles.isEvading(ped,7))
setup(true); PedTrafficObstacles.noteFlee(ped,{x=1,y=0},7)
assignments[ped]={ped=ped,accepted=true,epoch=8,direction=1};tick(6)
assert(#commands == 1 and commands[1].move == "walk")
setup(true)
for i=1,12 do
    local p={x=i,y=0,z=11,mode="walk",blocked=true}
    assignments[p]={ped=p,epoch=i,accepted=true,direction=0}
end
tick(32)
local visited={};for _,command in ipairs(commands) do visited[command.ped]=true end
for p in pairs(assignments) do assert(visited[p]) end
assert(maxReads == 1)
getPedTrafficObstacleScan=nil; timer=nil
PedTrafficObstacles.install(assignments,true,function() return true end,function() end)
assert(timer==nil)
print("PASS: pedestrian collision recovery, ground, escape headings, protected tasks, epoch handoff and Android query budget")
