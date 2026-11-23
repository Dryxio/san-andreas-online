-- A desktop bullet packet identifies player victims only. Match its shot
-- segment to one GTA collision before updating a ped owned by an Android peer.
TrafficObserverDamage = {}
local mobile, pending, lastMelee = {}, {}, {}
local managed, wantedResource

function TrafficObserverDamage.mark(ped)
    setElementData(ped, "neon:ambientDamageAuthority", true, "local", "deny")
    setElementData(ped, "neon:serverBulletDamage", true, "broadcast", "deny")
    setElementData(ped, "neon:ambientPedTraffic", true)
end

function TrafficObserverDamage.release(ped)
    removeElementData(ped, "neon:ambientDamageAuthority")
    setElementData(ped, "neon:ambientPedTraffic", false)
    if getElementData(ped, "neon:police") ~= true then removeElementData(ped, "neon:serverBulletDamage") end
end

local function eligible(shooter, ped, weapon)
    if not isElement(ped) or not managed(ped) or isPedDead(ped) or not isElement(shooter) or
        getPedWeapon(shooter) ~= weapon then return false end
    local owner = getElementSyncer(ped)
    return owner and mobile[owner] and owner ~= shooter and
        getElementDimension(shooter) == getElementDimension(ped) and getElementInterior(shooter) == getElementInterior(ped)
end

local function debit(shooter, ped, weapon, part, damage)
    local remaining = getElementHealth(ped) - damage
    if remaining <= 0 then killPed(ped, shooter, weapon, part) else setElementHealth(ped, remaining) end
end

function TrafficObserverDamage.melee(shooter, ped, weapon, part)
    if weapon < 0 or weapon > 15 or weapon ~= math.floor(weapon) or not eligible(shooter, ped, weapon) then return end
    local x, y, z = getElementPosition(shooter)
    local a, b, c = getElementPosition(ped)
    local t = getTickCount()
    if getDistanceBetweenPoints3D(x, y, z, a, b, c) > 4 or
        (lastMelee[shooter] and t - lastMelee[shooter] < 350) then return end
    lastMelee[shooter] = t
    local damage = getWeaponProperty(weapon, "std", "damage")
    debit(shooter, ped, weapon, part, type(damage) == "number" and damage > 0 and damage or 25)
end

local function onSegment(shooter, ped, ray)
    local px, py, pz = getElementPosition(ped)
    local sx, sy, sz = getElementPosition(shooter)
    if getDistanceBetweenPoints3D(sx, sy, sz, ray.sx, ray.sy, ray.sz) > 20 then return false end
    local dx, dy, dz = ray.x - ray.sx, ray.y - ray.sy, ray.z - ray.sz
    local length = dx*dx + dy*dy + dz*dz
    if not (length > 0 and length <= 500*500) then return false end
    local t = math.max(0, math.min(1, ((px-ray.sx)*dx + (py-ray.sy)*dy + (pz+0.6-ray.sz)*dz)/length))
    return getDistanceBetweenPoints3D(px, py, pz+0.6, ray.sx+t*dx, ray.sy+t*dy, ray.sz+t*dz) <= 2.5
end

local function wantedHandles(ped, weapon)
    return wantedResource and getResourceState(wantedResource) == "running" and
        exports["native-wanted-police"]:handlesTrafficBulletDamage(ped, weapon) == true
end

local function pair(shooter, weapon, ray, ped)
    local t = getTickCount()
    local queue = pending[shooter] or {}
    pending[shooter] = queue
    local i = 1
    while i <= #queue do
        local entry = queue[i]
        if t - entry.at > 700 then
            table.remove(queue, i)
        else
            if entry.weapon == weapon and (entry.ray ~= nil) ~= (ray ~= nil) then
                local target, shot = ped or entry.ped, ray or entry.ray
                if (not shot.hit or shot.hit == target) and eligible(shooter, target, weapon) and
                    onSegment(shooter, target, shot) then
                    table.remove(queue, i)
                    if wantedHandles(target, weapon) then return end
                    local damage = getWeaponProperty(weapon, "std", "damage")
                    if type(damage) == "number" and damage > 0 then debit(shooter, target, weapon, 3, damage) end
                    return
                end
            end
            i = i + 1
        end
    end
    if #queue >= 16 then table.remove(queue, 1) end
    queue[#queue+1] = {at=t, weapon=weapon, ray=ray, ped=ped}
end

function TrafficObserverDamage.install(isManaged)
    managed = isManaged
    addEventHandler("onElementDataChange", root, function(key)
        if key == "neon:isMobileClient" and getElementType(source) == "player" then
            mobile[source] = getElementData(source, key) == true or nil
        end
    end)
    addEventHandler("onResourceStart", root, function(started)
        if source == resourceRoot then
            for _, p in ipairs(getElementsByType("player")) do mobile[p] = getElementData(p, "neon:isMobileClient") == true or nil end
        end
        local wanted = getResourceFromName("native-wanted-police")
        if wanted and (source == resourceRoot or started == wanted) then
            wantedResource = nil
            for _, name in ipairs(getResourceExportedFunctions(wanted) or {}) do
                if name == "handlesTrafficBulletDamage" then wantedResource = wanted; break end
            end
        end
    end)
    addEventHandler("onResourceStop", root, function(stopped)
        if wantedResource == stopped then wantedResource = nil end
    end)
    addEventHandler("onPlayerQuit", root, function()
        mobile[source], pending[source], lastMelee[source] = nil, nil, nil
    end)
    addEvent("pedTraffic:bulletCollision", true)
    addEventHandler("pedTraffic:bulletCollision", resourceRoot, function(ped, weapon)
        if source == resourceRoot and type(weapon) == "number" and weapon >= 22 and weapon <= 34 and
            eligible(client, ped, weapon) then pair(client, weapon, nil, ped) end
    end)
    addEventHandler("onPlayerWeaponFire", root, function(weapon, x, y, z, hit, sx, sy, sz)
        if next(mobile) and weapon >= 22 and weapon <= 34 and (not hit or managed(hit)) and
            type(x) == "number" and type(y) == "number" and type(z) == "number" and
            type(sx) == "number" and type(sy) == "number" and type(sz) == "number" then
            pair(source, weapon, {x=x, y=y, z=z, sx=sx, sy=sy, sz=sz, hit=hit}, nil)
        end
    end)
end
