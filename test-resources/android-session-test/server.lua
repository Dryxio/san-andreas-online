-- Run on a private single-tester instance. Start before the first connection.
local testResource = getThisResource()
local testerSerial, active
local attempt = 0
local finished = false

local function log(message)
    outputServerLog("[android-session-test] " .. message)
end

local function milestone(session, name)
    if session[name] then return end
    session[name] = true
    log(("session=%d %s"):format(attempt, name))
    if session.ack and session.scoreboard and session.frame and session.spawned then
        -- Ask the same client to render again after a full minute in the world.
        session.timer = setTimer(function()
            if active ~= session then return end
            session.awaitingFrame = true
            session.timer = setTimer(function()
                if active ~= session then return end
                active = nil
                finished = true
                log(("INCOMPLETE session=%d did not report a frame after one minute"):format(attempt))
            end, 15000, 1)
            triggerClientEvent(session.player, "androidSessionTest:checkFrame", resourceRoot)
        end, 60000, 1)
        log(("session=%d observing 60 seconds"):format(attempt))
    end
end

local function maybeSpawn(session)
    if session.spawnRequested or session.spawned or not (session.frame and session.ack) then return end
    session.spawnRequested = true
    if spawnPlayer(session.player, 2492, -1685, 13.5, 0, 0, 0, 0) then
        setCameraTarget(session.player, session.player)
        fadeCamera(session.player, true)
    else
        log(("session=%d spawn request failed"):format(attempt))
    end
end

addEventHandler("onResourceStart", resourceRoot, function()
    log("ready for first join")
end)

addEventHandler("onPlayerJoin", root, function()
    if active or finished then return end
    local serial = getPlayerSerial(source)
    if type(serial) ~= "string" or serial == "" then return end
    if testerSerial and testerSerial ~= serial then return end
    testerSerial = serial
    attempt = attempt + 1
    active = {player = source}
    log(("session=%d joined"):format(attempt))
end, true, "high+100")

addEventHandler("onPlayerResourceStart", root, function(resource)
    if not active or source ~= active.player then return end
    if getResourceName(resource) == "scoreboard" then
        milestone(active, "scoreboard")
        return
    end
    if resource ~= testResource then return end
    milestone(active, "ack")
    maybeSpawn(active)
end)

addEvent("androidSessionTest:firstFrame", true)
addEventHandler("androidSessionTest:firstFrame", resourceRoot, function()
    if not active or client ~= active.player or source ~= resourceRoot then return end
    milestone(active, "frame")
    maybeSpawn(active)
end, false)

addEvent("androidSessionTest:liveFrame", true)
addEventHandler("androidSessionTest:liveFrame", resourceRoot, function()
    if not active or not active.awaitingFrame or client ~= active.player or source ~= resourceRoot then return end
    active.awaitingFrame = false
    killTimer(active.timer)
    active.timer = nil
    active.complete = true
    log(("session=%d ready"):format(attempt))
end, false)

addEventHandler("onPlayerSpawn", root, function()
    if active and source == active.player then milestone(active, "spawned") end
end)

addEventHandler("onPlayerQuit", root, function(quitType)
    if not active or source ~= active.player then return end
    local complete = active.complete
    if active.timer then killTimer(active.timer) end
    active = nil
    -- The network module can kick a player after their first frame and spawn.
    if quitType ~= "Quit" then
        finished = true
        log(("INCOMPLETE session=%d ended with %s"):format(attempt, quitType or "Unknown"))
        return
    end
    log(("session=%d quit"):format(attempt))
    if not complete then
        finished = true
        log("INCOMPLETE disconnected before the one-minute gameplay check completed")
    elseif attempt == 2 then
        finished = true
        log("PASS two joined sessions with resource execution and spawn")
    end
end)
