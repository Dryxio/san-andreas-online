-- Obstacle recovery for individual traffic assignments, adapted from itsbo5's PR #133.
PedTrafficObstacles = {}

local function endpoint(x, y, heading, distance)
    local radians = math.rad(heading)
    return x - math.sin(radians) * distance, y + math.cos(radians) * distance
end

-- GTA path-node directions go clockwise from north (FindNextNodeWandering).
-- MTA headings increase counterclockwise, so west (90 degrees) is node 6.
local function wanderDirection(heading)
    return math.floor((-heading + 22.5) / 45) % 8
end

local function desktopMode(ped, resuming)
    local function doing(task) return isPedDoingTask(ped, task) end
    if doing("TASK_SIMPLE_COWER") or doing("TASK_SIMPLE_HANDS_UP") or doing("TASK_SIMPLE_DUCK") or
        doing("TASK_COMPLEX_KILL_PED_ON_FOOT") or doing("TASK_SIMPLE_FIGHT_CTRL") then return "pause" end
    local flee = doing("TASK_COMPLEX_SMART_FLEE_ENTITY") or doing("TASK_COMPLEX_FLEE_ENTITY") or
        doing("TASK_COMPLEX_FLEE_ANY_MEANS") or doing("TASK_COMPLEX_FLEE_POINT") or doing("TASK_COMPLEX_SMART_FLEE_POINT")
    if doing("TASK_COMPLEX_CROSS_ROAD_LOOK_AND_ACHIEVE_HEADING") or doing("TASK_COMPLEX_OBSERVE_TRAFFIC_LIGHTS") or
        doing("TASK_COMPLEX_OBSERVE_TRAFFIC_LIGHTS_AND_ACHIEVE_HEADING") then return flee and "flee-crossing" or "crossing" end
    if flee then return "flee" end
    if resuming and doing("TASK_COMPLEX_GO_TO_POINT_AND_STAND_STILL") then return "detour" end
    if doing("TASK_COMPLEX_WANDER") and not doing("TASK_SIMPLE_STAND_STILL") then return "walk" end
    return "pause"
end

local fan = {0, -20, 20, -35, 35}
local function desktopScan(ped, resumeHeading, x, y, z)
    local mode = desktopMode(ped, resumeHeading ~= nil)
    local _, _, heading = getElementRotation(ped)
    if mode == "pause" or mode == "crossing" or mode == "flee-crossing" then return mode, heading end
    local floor = getGroundPosition(x, y, z + 0.25)
    if type(floor) ~= "number" or floor < z - 2 or floor > z + 0.2 then return end
    local function blocked(ex, ey, ez, h)
        return processLineOfSight(x, y, floor + h, ex, ey, ez + h, true, true, false, true, true, false, false, false, ped)
    end
    local front = false
    for _, offset in ipairs(fan) do
        local ex, ey = endpoint(x, y, (resumeHeading or heading) + offset, 1.6)
        if blocked(ex, ey, floor, 0.25) or blocked(ex, ey, floor, 0.60) or blocked(ex, ey, floor, 1.0) then
            front = true
            break
        end
    end
    local routes = {}
    if front and not resumeHeading then
        for dir = 0, 7 do
            local ex, ey = endpoint(x, y, dir * 45, 2.8)
            local ground = getGroundPosition(ex, ey, z + 0.25)
            if type(ground) == "number" and math.abs(ground - floor) <= 1.2 and
                not blocked(ex, ey, ground, 0.15) and not blocked(ex, ey, ground, 0.60) and not blocked(ex, ey, ground, 1.0) then
                routes[dir + 1] = ground
            end
        end
    end
    return mode, heading, floor, front, routes
end

local function chooseRoute(x, y, heading, floor, routes, attacker)
    local tx, ty
    if isElement(attacker) then tx, ty = getElementPosition(attacker) end
    local best, bestScore
    for dir = 0, 7 do
        local ground = routes[dir + 1]
        local angle = math.abs((dir * 45 - heading + 180) % 360 - 180)
        if ground and angle >= 22.5 then
            local delta = ground - floor
            local score = -angle * 0.05
            if math.abs(delta) <= 0.08 then score = score + 6 end
            if delta < -0.1 then score = score - 4 end
            if tx then
                local ex, ey = endpoint(x, y, dir * 45, 2.8)
                score = score + 2 * math.sqrt((ex - tx)^2 + (ey - ty)^2)
            end
            if not bestScore or score > bestScore then best, bestScore = dir, score end
        end
    end
    return best
end

function PedTrafficObstacles.install(assignments, mobile, eligible, attackerFor)
    local states, threats = {}, {}
    local queue, cursor = {}, 1
    local function forget(ped)
        states[ped], threats[ped] = nil, nil
    end
    addEventHandler("onClientElementDestroy", root, function() forget(source) end)
    addEventHandler("onClientElementStreamOut", root, function() forget(source) end)
    function PedTrafficObstacles.noteFlee(ped, attacker, epoch)
        local task = assignments[ped]
        if task and task.accepted and task.epoch == epoch and isElementSyncer(ped) then
            threats[ped] = {task = task, attacker = attacker, at = getTickCount()}
        end
    end
    function PedTrafficObstacles.isEvading(ped, epoch)
        local s = states[ped]
        return s and s.returnHeading ~= nil and s.task == assignments[ped] and s.task.epoch == epoch
    end
    local scan = mobile and getPedTrafficObstacleScan or desktopScan
    -- Older Android clients expose a placeholder processLineOfSight. Their native wander remains in control.
    if mobile and type(getPedTrafficObstacleScan) ~= "function" then return end
    local function sample(task, now)
        local ped = task.ped
        if assignments[ped] ~= task then return end
        if not task.accepted or not isElement(ped) or not isElementStreamedIn(ped) or not isElementSyncer(ped) or
            not eligible(ped, task) or isPedDead(ped) or isPedInVehicle(ped) or isElementFrozen(ped) then
            return forget(ped)
        end
        local x, y, z = getElementPosition(ped)
        if not z then return forget(ped) end
        local s = states[ped]
        if not s or s.task ~= task then
            states[ped] = {task = task, x = x, y = y, z = z, since = now}
            return
        end
        local moved = (x - s.x)^2 + (y - s.y)^2 >= 0.14^2 or math.abs(z - s.z) > 0.4
        if moved then s.x, s.y, s.z, s.since = x, y, z, now end
        if not s.returnHeading and now - s.since < 500 and not (s.runUntil and now >= s.runUntil) then return end
        if now < (s.nextScan or 0) then return end
        s.nextScan = now + 450
        local mode, heading, floor, blocked, routes = scan(ped, s.returnHeading, x, y, z)
        if not mode then return end
        local threat = threats[ped]
        if threat and (threat.task ~= task or now - threat.at > 4000) then threats[ped], threat = nil, nil end
        if mode == "pause" or (mode == "crossing" and not threat and not s.returnHeading) then
            s.since, s.returnHeading, s.runUntil = now, nil, nil
            return
        end
        local fleeing = mode == "flee" or mode == "flee-crossing" or threat ~= nil
        if s.runUntil and now >= s.runUntil and not fleeing and not s.returnHeading and mode == "walk" then
            if setPedWander(ped, "walk", wanderDirection(heading), true) then
                s.runUntil, s.since = nil, now
            end
            return
        end
        local attacker = attackerFor(ped, task) or (threat and threat.attacker)
        if s.returnHeading then
            local travelled = (x - s.startX)^2 + (y - s.startY)^2
            if travelled < 1.5^2 and now - s.started < 1400 and (travelled < 0.8^2 or blocked ~= false) then return end
            local away = s.returnHeading
            local target = isElement(attacker) and attacker or s.attacker
            if isElement(target) then
                local tx, ty = getElementPosition(target)
                if tx and (x ~= tx or y ~= ty) then away = math.deg(math.atan2(tx - x, y - ty)) end
            end
            if setPedWander(ped, "run", wanderDirection(away), false) then
                s.returnHeading, s.attacker, s.since, s.runUntil = nil, nil, now, now + 4000
            end
            return
        end
        if mode == "crossing" or mode == "flee-crossing" then
            if fleeing and setPedWander(ped, "run", wanderDirection(heading), false) then
                s.runUntil = now + 4000
            end
            s.since = now
            return
        end
        if not blocked then
            if mode == "walk" and not fleeing and now - s.since >= 3000 then
                setPedWander(ped, "walk", task.direction, true)
                s.since = now
            end
            return
        end
        local dir = chooseRoute(x, y, heading, floor, routes, fleeing and attacker)
        if not dir then return end
        if fleeing then
            local ex, ey = endpoint(x, y, dir * 45, 2.8)
            local accepted = not mobile and type(setPedGoTo) == "function" and setPedGoTo(ped, Vector3(ex, ey, routes[dir + 1]), "run", 0.4, 0.4, 2500)
            if accepted or setPedWander(ped, "run", wanderDirection(dir * 45), false) then
                s.returnHeading, s.startX, s.startY, s.started, s.attacker = heading % 360, x, y, now, attacker
            end
        else
            setPedWander(ped, "walk", wanderDirection(dir * 45), true)
        end
        s.since = now
    end
    local function pulse()
        if cursor > #queue then
            for ped, s in pairs(states) do
                if assignments[ped] ~= s.task then forget(ped) end
            end
            queue, cursor = {}, 1
            for _, task in pairs(assignments) do
                if task.accepted then queue[#queue + 1] = task end
            end
        end
        for _ = 1, mobile and 1 or 3 do
            local task = queue[cursor]
            if not task then return end
            cursor = cursor + 1
            sample(task, getTickCount())
        end
    end
    setTimer(pulse, 100, 0)
end
