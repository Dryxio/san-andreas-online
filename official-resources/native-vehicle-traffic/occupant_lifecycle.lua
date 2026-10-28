-- Road driving is a temporary activity, not an ownership boundary for the
-- people in the car. Keep their elements after theft, death and seat changes.
TrafficOccupantLifecycle = {}
local api = TrafficOccupantLifecycle
local cohorts, readyClients = {}, {}
local nextId = 0
local radius, grace = 220, 60000

local function validPlayer(player, element)
    return isElement(element) and isElement(player) and readyClients[player] and not isPedDead(player)
        and getElementDimension(player) == getElementDimension(element)
        and getElementInterior(player) == getElementInterior(element)
end

local function distance(a, b)
    local x, y, z = getElementPosition(a)
    local bx, by, bz = getElementPosition(b)
    return getDistanceBetweenPoints3D(x, y, z, bx, by, bz)
end

local function anchor(c)
    for _, ped in ipairs(c.peds) do if isElement(ped) then return ped end end
    return nil
end

local function publish(c, recipient)
    triggerClientEvent(recipient or root, "carOccupants:state", resourceRoot,
        c.id, c.epoch, c.owner or false, c.vehicle, c.peds, c.evacuate, c.response or false)
end

local function clear(c, resolveMissing)
    cohorts[c.id] = nil
    local callback = c.onReady
    c.onReady = nil
    if resolveMissing and callback then callback() end
    triggerClientEvent(root, "carOccupants:stop", resourceRoot, c.id, c.epoch)
    for _, ped in ipairs(c.peds) do if isElement(ped) then destroyElement(ped) end end
    -- The vehicle has its own retained/adopted lifetime. Never destroy it
    -- merely because its former occupants have left the simulation bubble.
end

local function assign(c, owner)
    c.epoch = c.epoch + 1
    c.owner = owner
    c.pendingOwner, c.revokingAt, c.accepted = nil, nil, false
    c.assignedAt = getTickCount()
    c.damageNonce, c.damageTimes, c.hitReceipts = nil, nil, nil
    for _, ped in ipairs(c.peds) do
        if isElement(ped) then setElementSyncer(ped, owner or false, true, true) end
    end
    if isElement(c.vehicle) then
        local driver = getVehicleOccupant(c.vehicle, 0)
        if driver == c.peds[1] then setElementSyncer(c.vehicle, owner or false, true, true) end
    end
    publish(c)
end

local function choose(c, excluded)
    local a = anchor(c)
    if not a then return nil end
    local best, bestDistance
    for player in pairs(readyClients) do
        if player ~= excluded and validPlayer(player, a) then
            local d = distance(player, a)
            if d < radius and (not bestDistance or d < bestDistance) then best, bestDistance = player, d end
        end
    end
    return best
end

function api.retain(vehicle, peds, owner, evacuate, onReady)
    local actors = {}
    for _, ped in ipairs(peds) do
        if isElement(ped) and getElementType(ped) == "ped" then actors[#actors + 1] = ped end
    end
    if #actors == 0 then return false end
    local remaining = #actors
    local function accepted()
        remaining = remaining - 1
        if remaining == 0 and onReady then onReady() end
    end
    -- A driver on the pavement and passengers travelling in the stolen car
    -- must not remain pinned to one spatial authority. Initially give every
    -- actor to the jacker for the paired task, then retain them independently.
    for _, ped in ipairs(actors) do
        nextId = nextId + 1
        setPedFightingStyle(ped, 4)
        local c = {id = nextId, epoch = 0, vehicle = isElement(vehicle) and vehicle or false,
            peds = {ped}, evacuate = evacuate == true, onReady = accepted}
        removeElementData(ped, "neon:ambientVehicleTrafficId")
        removeElementData(ped, "neon:ambientVehicleTrafficEpoch")
        cohorts[c.id] = c
        assign(c, validPlayer(owner, ped) and owner or choose(c))
    end
    return true
end

function api.contains(vehicle)
    for _, c in pairs(cohorts) do if c.vehicle == vehicle then return true end end
    return false
end

function api.clear()
    local snapshot = {}
    for _, c in pairs(cohorts) do snapshot[#snapshot + 1] = c end
    for _, c in ipairs(snapshot) do clear(c) end
end

addEvent("carOccupants:ready", true)
addEventHandler("carOccupants:ready", resourceRoot, function()
    if source ~= resourceRoot or not isElement(client) or getElementType(client) ~= "player" then return end
    readyClients[client] = true
    for _, c in pairs(cohorts) do publish(c, client) end
end)

addEvent("carOccupants:accepted", true)
addEventHandler("carOccupants:accepted", resourceRoot, function(id, epoch)
    if source ~= resourceRoot then return end
    local c = cohorts[id]
    if not c or c.epoch ~= epoch or c.owner ~= client or c.revokingAt or c.accepted then return end
    for _, ped in ipairs(c.peds) do
        if isElement(ped) and getElementSyncer(ped) ~= client then return end
    end
    c.accepted = true
    local callback = c.onReady
    c.onReady = nil
    if callback then callback() end
end)

-- Only the current authority may describe its own remaining reaction. The
-- engine independently whitelists task kinds/parameters before native calls.
local function acceptResponse(c, response)
    if response == false then c.response = false; return true end
    if type(response) ~= "table" or #response > 8 then return false end
    local clean = {}
    for _, d in ipairs(response) do
        if type(d) ~= "table" or type(d.type) ~= "number" or d.type % 1 ~= 0 or d.type < 0 or d.type > 2000
            or type(d.values) ~= "table" or #d.values ~= 8 then return false end
        if d.target ~= nil and (not isElement(d.target) or (getElementType(d.target) ~= "ped" and getElementType(d.target) ~= "player")
            or d.target == c.peds[1] or not validPlayer(c.owner, d.target)) then return false end
        if d.vehicle ~= nil and (d.vehicle ~= c.vehicle or not isElement(d.vehicle)) then return false end
        local values = {}
        for i = 1, 8 do
            local value = d.values[i]
            if type(value) ~= "number" or value ~= value or value < -1000000 or value > 100000000 then return false end
            values[i] = value
        end
        clean[#clean + 1] = {type = d.type, target = d.target, vehicle = d.vehicle, values = values}
    end
    c.response = clean
    return true
end
addEvent("carOccupants:response", true)
addEventHandler("carOccupants:response", resourceRoot, function(id, epoch, response)
    local c = cohorts[id]
    if source ~= resourceRoot or not c or c.epoch ~= epoch or c.owner ~= client or c.revokingAt
        or not isElement(c.peds[1]) or getElementSyncer(c.peds[1]) ~= client then return end
    acceptResponse(c, response)
end)

addEvent("carOccupants:released", true)
addEventHandler("carOccupants:released", resourceRoot, function(id, epoch, response)
    if source ~= resourceRoot then return end
    local c = cohorts[id]
    if not c or c.owner ~= client or c.epoch ~= epoch or not c.revokingAt then return end
    if response ~= nil then acceptResponse(c, response) end
    assign(c, c.pendingOwner)
end)

addEventHandler("onPlayerQuit", root, function()
    readyClients[source] = nil
    for _, c in pairs(cohorts) do
        if c.owner == source then assign(c, choose(c, source)) end
        if c.pendingOwner == source then c.pendingOwner = choose(c, source) end
    end
end)

setTimer(function()
    local now = getTickCount()
    for _, c in pairs(cohorts) do
        local a = anchor(c)
        if not a then clear(c, true)
        else
            local observed = false
            -- Every surviving actor counts: the vehicle and a fleeing ped
            -- can be far apart, and neither may disappear beside a player.
            for _, ped in ipairs(c.peds) do
                if isElement(ped) then
                    for _, player in ipairs(getElementsByType("player")) do
                        if getElementDimension(player) == getElementDimension(ped)
                            and getElementInterior(player) == getElementInterior(ped)
                            and distance(player, ped) <= radius then observed = true break end
                    end
                end
            end
            if observed then c.emptySince = nil else c.emptySince = c.emptySince or now end
            if c.emptySince and now - c.emptySince >= grace then clear(c)
            elseif c.revokingAt then
                if now - c.revokingAt > 10000 then
                    -- Changing syncer fences the old native event profile even
                    -- if its release acknowledgement was lost.
                    assign(c, choose(c, c.owner))
                end
            elseif not c.owner or not validPlayer(c.owner, a) or distance(c.owner, a) > radius then
                local nextOwner = choose(c, c.owner)
                if c.owner and isElement(c.owner) then
                    c.pendingOwner, c.revokingAt = nextOwner, now
                    triggerClientEvent(c.owner, "carOccupants:revoke", resourceRoot, c.id, c.epoch)
                elseif nextOwner then assign(c, nextOwner) end
            end
        end
    end
end, 500, 0)

addEventHandler("onResourceStop", resourceRoot, api.clear)

-- These actors retain their stock civilian UNARMED_1 combat. Validate the
-- exact pre-calculator factor; health loss cannot be inverted into that input.
local civilianFactors = {}
for _, factor in ipairs({1,2,3,4,5,6,7,8,9,10,12,13,15,16,17,18,20,22,25,27,30,37}) do civilianFactors[factor] = true end
local function integer(value, minimum, maximum)
    return type(value) == "number" and value == math.floor(value) and value >= minimum and value <= maximum
end
local function sameWorld(a, b)
    return getElementDimension(a) == getElementDimension(b) and getElementInterior(a) == getElementInterior(b)
end
addEvent("carOccupants:damageObserved", true)
addEventHandler("carOccupants:damageObserved", resourceRoot, function(id, epoch, victim, nonce, bodypart, factor, direction)
    local c = cohorts[id]
    local ped = c and c.peds[1]
    if source ~= resourceRoot or not c or c.epoch ~= epoch or not c.accepted or c.revokingAt or c.owner ~= client
        or not isElement(ped) or isPedDead(ped) or getElementSyncer(ped) ~= client or getPedWeapon(ped) ~= 0
        or not isElement(victim) or getElementType(victim) ~= "player" or victim == client or isPedDead(victim)
        or not integer(nonce, 1, 2147483647) or nonce <= (c.damageNonce or 0)
        or not integer(bodypart, 0, 9) or (bodypart ~= 0 and bodypart < 3)
        or civilianFactors[factor] ~= true or not integer(direction, 0, 3)
        or not sameWorld(ped, victim) or distance(ped, victim) > 5 then return end
    local now = getTickCount()
    c.damageTimes = c.damageTimes or setmetatable({}, {__mode = "k"})
    if now - (c.damageTimes[victim] or -250) < 250 then return end
    c.damageNonce, c.damageTimes[victim] = nonce, now
    triggerClientEvent(victim, "carOccupants:damage", resourceRoot, id, epoch, nonce, bodypart, factor, direction)
end)

addEvent("carOccupants:hitObserved", true)
addEventHandler("carOccupants:hitObserved", resourceRoot, function(id, epoch, nonce, bodypart)
    local c = cohorts[id]
    local ped = c and c.peds[1]
    if source ~= resourceRoot or not c or c.epoch ~= epoch or not c.accepted or c.revokingAt
        or not isElement(c.owner) or c.owner == client or not validPlayer(client, ped)
        or not isElement(ped) or isPedDead(ped) or getElementSyncer(ped) ~= c.owner
        or getPedWeapon(client) ~= 0 or distance(client, ped) > 5
        or not integer(nonce, 1, 2147483647) or not integer(bodypart, 0, 9) or (bodypart ~= 0 and bodypart < 3) then return end
    c.hitReceipts = c.hitReceipts or setmetatable({}, {__mode = "k"})
    local previous, now = c.hitReceipts[client], getTickCount()
    if previous and (nonce <= previous.nonce or now - previous.at < 250) then return end
    c.hitReceipts[client] = {nonce = nonce, at = now}
    triggerClientEvent(c.owner, "carOccupants:hit", resourceRoot, id, epoch, client, nonce, bodypart)
end)
