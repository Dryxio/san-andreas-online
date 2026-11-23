-- Android locomotion and reactions for ambient pedestrians.

local IS_MOBILE = (type(getVersion) == "function" and getVersion().os == "Android") or
    (type(getVersion) ~= "function" and type(isWorldRPGMobilePopulation) == "function" and isWorldRPGMobilePopulation() == true)

if not IS_MOBILE then
    MobilePuppet = {
        active = false,
        start = function() end,
        startWander = function() end,
        stop = function() end
    }
    return
end

outputDebugString("[ped-traffic][mobile-syncer] Motor de Locomocao Mobile Syncer ATIVADO (Fase 1)", 3)

local activeWalkers = {} -- [ped] = { timer = handle, state = "walking", nextTurn = tick, heading = float }

-- Helper para calcular coordenadas 2D a frente do pedestre
local function getPositionInFrontOfPed(ped, distance)
    local x, y, z = getElementPosition(ped)
    local r = getPedRotation(ped) or 0
    local rad = math.rad(-r)
    local fx = x + math.sin(rad) * distance
    local fy = y + math.cos(rad) * distance
    return fx, fy, z
end

-- Limpa e para completamente o controle de um pedestre
local function stopWalker(ped)
    if not isElement(ped) then
        activeWalkers[ped] = nil
        return
    end

    if activeWalkers[ped] and isTimer(activeWalkers[ped].timer) then
        killTimer(activeWalkers[ped].timer)
    end
    activeWalkers[ped] = nil

    if isElement(ped) then
        setPedControlState(ped, "forwards", false)
        setPedControlState(ped, "walk", false)
    end
end

-- Pulso de decisao de caminho e desvio de obstaculos
local function pulseWalker(ped)
    if not isElement(ped) or isPedDead(ped) then
        stopWalker(ped)
        return
    end

    local walker = activeWalkers[ped]
    if not walker then return end

    -- Se o mobile nao e mais o syncer deste ped, apenas manter controle basico
    local isSyncer = isElementSyncer(ped)

    local x, y, z = getElementPosition(ped)
    local now = getTickCount()

    if walker.state == "paused" then
        if now >= walker.resumeTick then
            walker.state = "walking"
            setPedControlState(ped, "forwards", true)
            setPedControlState(ped, "walk", true)
        end
        return
    end

    -- Se estiver andando como syncer:
    if isSyncer then
        setPedControlState(ped, "forwards", true)
        setPedControlState(ped, "walk", true)

        -- Checar obstaculo a frente com raycast duplo (quadril 0.6m e solo 0.15m para postes caidos e detritos)
        local fx, fy, fz = getPositionInFrontOfPed(ped, 2.2)
        local hitUpper = processLineOfSight(x, y, z + 0.6, fx, fy, fz + 0.6, true, true, false, true, false, false, false, ped)
        local hitLower = not hitUpper and processLineOfSight(x, y, z + 0.15, fx, fy, fz + 0.15, true, true, false, true, false, false, false, ped)
        local hit = hitUpper or hitLower

        -- Anti-Stuck: checar se o pedestre esta realmente avancando na calçada
        walker.lastCheckTick = walker.lastCheckTick or now
        if now - walker.lastCheckTick >= 2500 then
            walker.lastCheckTick = now
            if walker.lastX and walker.lastY then
                local distMoved = getDistanceBetweenPoints2D(x, y, walker.lastX, walker.lastY)
                if distMoved < 0.25 then
                    hit = true
                    walker.stuckCount = (walker.stuckCount or 0) + 1
                else
                    walker.stuckCount = 0
                end
            end
            walker.lastX, walker.lastY = x, y
        end

        -- Desviar se houver obstaculo ou colisao
        if hit then
            local currentRot = getPedRotation(ped) or 0
            if (walker.stuckCount or 0) >= 2 then
                -- Travado por mais de 5s: forcar meia-volta (180 graus) para sair da esquina/poste
                local turnAngle = 180 + math.random(-30, 30)
                setPedRotation(ped, (currentRot + turnAngle) % 360)
                walker.nextTurn = now + 6000
                walker.stuckCount = 0
            else
                local turnAngle = (math.random(0, 1) == 0 and 90 or -90) + math.random(-25, 25)
                local newRot = (currentRot + turnAngle) % 360
                setPedRotation(ped, newRot)
                walker.nextTurn = now + math.random(5000, 12000)
            end
        elseif now >= (walker.nextTurn or 0) then
            -- Curva natural ou pausa casual de pedestre
            if math.random(1, 10) <= 2 then
                -- 20% de chance de pausa casual de 2 a 3 segundos
                walker.state = "paused"
                walker.resumeTick = now + math.random(2000, 3500)
                setPedControlState(ped, "forwards", false)
                setPedControlState(ped, "walk", false)
                local idles = {"idle_stance", "idle_chat"}
                setPedAnimation(ped, "ped", idles[math.random(1, #idles)], 3000, true, false, false)
            else
                -- Virar levemente a esquerda ou direita (angulo natural de esquina)
                local currentRot = getPedRotation(ped) or 0
                local delta = math.random(-45, 45)
                setPedRotation(ped, (currentRot + delta) % 360)
                walker.nextTurn = now + math.random(6000, 14000)
            end
        end
    end
end

-- Inicia a locomocao de caminhada real como Syncer mobile
local function startWander(ped, direction)
    if not isElement(ped) then return false end

    stopWalker(ped)

    local initHeading = (direction and direction >= 0 and direction <= 7)
        and (direction * 45.0)
        or math.random(0, 360)

    setPedRotation(ped, initHeading)
    setPedControlState(ped, "forwards", true)
    setPedControlState(ped, "walk", true)

    local walker = {
        state = "walking",
        nextTurn = getTickCount() + math.random(4000, 9000),
        resumeTick = 0,
        heading = initHeading
    }

    walker.timer = setTimer(function()
        pulseWalker(ped)
    end, 1200, 0)

    activeWalkers[ped] = walker
    return true
end

-- Resposta Interativa: Reacao a mira de arma do jogador
addEventHandler("onClientPlayerTarget", localPlayer, function(target)
    if isElement(target) and getElementType(target) == "ped" and activeWalkers[target] then
        local weapon = getPedWeapon(localPlayer)
        if weapon and weapon >= 22 and weapon <= 38 then
            setPedControlState(target, "forwards", false)
            setPedControlState(target, "walk", false)
            setPedAnimation(target, "ped", "cower", 4000, true, false, false)
            if activeWalkers[target] then
                activeWalkers[target].state = "paused"
                activeWalkers[target].resumeTick = getTickCount() + 4000
            end
        end
    end
end)

-- Limpeza ao destruir o elemento
addEventHandler("onClientElementDestroy", root, function()
    if getElementType(source) == "ped" and activeWalkers[source] then
        stopWalker(source)
    end
end)

-- Resposta a dano de observador: aplicar reducao de saude no syncer mobile
local function reactToDamage(ped, epoch, attacker)
    if not isElement(ped) or not isElementSyncer(ped) or isPedDead(ped) or
        getElementData(ped, "neon:ambientPedTrafficEpoch") ~= epoch or
        getElementData(ped, "neon:ambientPedPopulationClass") == "cop" then return end
    PedTrafficObstacles.noteFlee(ped, attacker, epoch)
    -- Health (including lethal hits) has already been applied by the server.
    setPedControlState(ped, "walk", false)
    setPedControlState(ped, "sprint", true)
    setTimer(function(p)
        if isElement(p) and isElementSyncer(p) and not isPedDead(p) and
            getElementData(p, "neon:ambientPedTrafficEpoch") == epoch then
            setPedControlState(p, "sprint", false)
            setPedControlState(p, "walk", true)
        end
    end, 4000, 1, ped)
    return true
end

-- API publica exportada
MobilePuppet = {
    active = true,
    start = function(ped) return startWander(ped, math.random(0, 7)) end,
    startWander = startWander,
    reactToDamage = reactToDamage,
    stop = stopWalker
}
