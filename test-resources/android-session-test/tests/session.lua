-- Run from the resource directory with Lua 5.1. No server or phone is simulated beyond event delivery.
local handlers, logs, spawns = {}, {}, 0
local now, timers, requested = 0, {}, {}
local tester, other, reconnect = {serial="same"}, {serial="different"}, {serial="same"}
root, resourceRoot = {}, {}
local resource, scoreboard = {name="android-session-test"}, {name="scoreboard"}
function getThisResource() return resource end
function getResourceName(res) return res.name end
function getPlayerSerial(player) return player.serial end
function outputServerLog(msg) logs[#logs + 1] = msg end
function addEvent() end
function addEventHandler(name, _, fn) handlers[name] = fn end
function setTimer(fn, delay, times)
    assert(times == 1)
    local timer = {due = now + delay, fn = fn}
    timers[timer] = true
    return timer
end
function killTimer(timer)
    assert(timers[timer])
    timers[timer] = nil
end
local function advance(ms)
    now = now + ms
    local due = {}
    for timer in pairs(timers) do
        if timer.due <= now then due[#due + 1] = timer end
    end
    for _, timer in ipairs(due) do
        if timers[timer] then
            timers[timer] = nil
            timer.fn()
        end
    end
end
function triggerClientEvent(player, name, element)
    assert(name == "androidSessionTest:checkFrame" and element == resourceRoot)
    requested[player] = (requested[player] or 0) + 1
end
local function emit(name, sender, peer, ...)
    local prevSource, prevClient = source, client
    source, client = sender, peer
    handlers[name](...)
    source, client = prevSource, prevClient
end
function spawnPlayer(player)
    spawns = spawns + 1
    emit("onPlayerSpawn", player)
    return true
end
function fadeCamera() end
function setCameraTarget() end
local function logged(fragment)
    for _, line in ipairs(logs) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end
local function reset()
    handlers, logs, spawns = {}, {}, 0
    now, timers, requested = 0, {}, {}
    dofile("server.lua")
    emit("onResourceStart", resourceRoot)
end
local function frame(player) emit("androidSessionTest:firstFrame", resourceRoot, player) end
local function ack(player, res) emit("onPlayerResourceStart", player, nil, res) end
local function finishMinute(player, index)
    local ready = ("session=%d ready"):format(index)
    advance(59999)
    emit("androidSessionTest:liveFrame", resourceRoot, player)
    assert(not requested[player] and not logged(ready))
    advance(1)
    assert(requested[player] == 1 and not logged(ready))
    emit("androidSessionTest:liveFrame", resourceRoot, other)
    emit("androidSessionTest:liveFrame", root, player)
    assert(not logged(ready))
    emit("androidSessionTest:liveFrame", resourceRoot, player)
    assert(logged(ready))
end

reset()
emit("onPlayerJoin", tester)
frame(other)
ack(tester, resource)
assert(spawns == 0)
frame(tester)
assert(spawns == 1 and not logged("session=1 ready"))
ack(tester, scoreboard)
finishMinute(tester, 1)
assert(logged("session=1 ready") and not logged("PASS"))
frame(tester)
assert(spawns == 1)
emit("onPlayerQuit", tester, nil, "Quit")
emit("onPlayerJoin", other)
assert(not logged("session=2 joined"))
emit("onPlayerJoin", reconnect)
emit("onPlayerSpawn", reconnect)
ack(reconnect, scoreboard)
frame(reconnect)
ack(reconnect, resource)
finishMinute(reconnect, 2)
assert(logged("session=2 ready") and not logged("PASS") and spawns == 1)
emit("onPlayerQuit", reconnect, nil, "Quit")
assert(logged("PASS"))

reset()
emit("onPlayerJoin", tester)
ack(tester, resource)
emit("onPlayerQuit", tester, nil, "Quit")
emit("onPlayerJoin", reconnect)
assert(logged("INCOMPLETE") and not logged("session=2 joined") and not logged("PASS"))
-- Leaving while the timer runs cannot complete a later session.
reset()
emit("onPlayerJoin", tester)
frame(tester)
ack(tester, resource)
ack(tester, scoreboard)
advance(59999)
emit("onPlayerQuit", tester, nil, "Quit")
advance(1)
emit("androidSessionTest:liveFrame", resourceRoot, tester)
assert(not requested[tester] and not logged("session=1 ready") and logged("INCOMPLETE"))
-- A connected player with a stalled render loop fails the observation too.
reset()
emit("onPlayerJoin", tester)
frame(tester)
ack(tester, resource)
ack(tester, scoreboard)
advance(60000)
assert(requested[tester] == 1 and not logged("INCOMPLETE"))
advance(15000)
emit("androidSessionTest:liveFrame", resourceRoot, tester)
assert(logged("INCOMPLETE") and not logged("session=1 ready"))
-- A server kick after the phone spawns invalidates either session.
for kickedSession = 1, 2 do
    reset()
    for index, player in ipairs({tester, reconnect}) do
        emit("onPlayerJoin", player)
        ack(player, resource)
        frame(player)
        ack(player, scoreboard)
        finishMinute(player, index)
        assert(logged(("session=%d ready"):format(index)) and not logged("PASS"))
        if index == kickedSession then
            emit("onPlayerQuit", player, nil, "Kicked")
            emit("onPlayerJoin", reconnect)
            assert(logged(("INCOMPLETE session=%d ended with Kicked"):format(index)))
            assert(not logged(("session=%d joined"):format(index + 1)) and not logged("PASS"))
            break
        end
        emit("onPlayerQuit", player, nil, "Quit")
    end
end
print("PASS one-minute in-game frame checks, clean reconnect, and post-spawn kick rejection")

-- Run the actual client chunk through resource start and its first render callback.
local reports = {}
handlers = {}
function removeEventHandler(name, element, fn)
    assert(element == root and handlers[name] == fn)
    handlers[name] = nil
end
function triggerServerEvent(name, element)
    assert(element == resourceRoot)
    reports[#reports + 1] = name
end
function outputChatBox() end
dofile("client.lua")
assert(#reports == 0 and not handlers.onClientRender)
emit("onClientResourceStart", resourceRoot)
assert(#reports == 0)
emit("onClientRender", root)
assert(#reports == 1 and reports[1] == "androidSessionTest:firstFrame" and not handlers.onClientRender)
emit("androidSessionTest:checkFrame", resourceRoot)
assert(#reports == 1)
emit("onClientRender", root)
assert(#reports == 2 and reports[2] == "androidSessionTest:liveFrame" and not handlers.onClientRender)
print("PASS client reports a rendered frame on start and another on the server's request")
