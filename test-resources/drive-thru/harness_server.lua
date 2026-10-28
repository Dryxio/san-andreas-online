local harness = {
    run = nil,
    serial = 0,
}

local STAGE_TIMEOUTS = {
    cutscene = 160000,
    actor_entry = 45000,
    enter_car = 45000,
    drive = 70000,
    restaurant_camera = 45000,
    restaurant_teardown = 45000,
    restaurant_rebuild = 45000,
    restaurant_barrier = 45000,
    pursuit_route_barrier = 45000,
    pursuit_task_barrier = 45000,
    chase = 180000,
    return_grove_drive = 70000,
    return_grove_scene_prepare = 45000,
    return_grove_scene = 180000,
    return_grove_scene_release = 45000,
    return_smoke_drive = 70000,
    return_smoke_scene_prepare = 45000,
    return_smoke_scene = 180000,
    return_smoke_scene_release = 45000,
    complete = 30000,
    failed = 30000,
}

local function playerName(player)
    return isElement(player) and getElementType(player) == "player" and getPlayerName(player) or "unavailable"
end

local function shallowCopy(source)
    local target = {}
    for key, value in pairs(source or {}) do
        target[key] = value
    end
    return target
end

local function trace(event, data)
    local run = harness.run
    if not run then
        return
    end
    local record = shallowCopy(data)
    record.event = event
    record.runId = run.id
    record.profile = run.profile
    record.elapsed = getTickCount() - run.startedAt
    record.stage = record.stage or run.lastStage
    local encoded = tostring(toJSON(record, true)):gsub("[\r\n]", "")
    outputServerLog("[drive-thru-transition-jsonl] " .. encoded)
    if run.traceFile and run.traceRecords < 1024 then
        fileWrite(run.traceFile, encoded .. "\n")
        fileFlush(run.traceFile)
        run.traceRecords = run.traceRecords + 1
    end
end

local function terminal(ok, reason)
    local run = harness.run
    if not run or run.terminal then
        return
    end
    run.terminal = true
    run.failureReason = ok and nil or tostring(reason or "unknown failure")
    for _, timer in ipairs(run.timers) do
        if isTimer(timer) then
            killTimer(timer)
        end
    end
    run.timers = {}
    local inputAllPassed = run.inputPassed.entry == true and run.inputPassed.restaurant == true and
                               run.inputPassed.chase_controls == true and
                               run.inputPassed.grove == true and run.inputPassed.smoke == true
    local objectivesPassed = run.objectivePassed.restaurant == true and run.objectivePassed.combat == true and
                                 run.objectivePassed.grove == true and run.objectivePassed.smoke == true
    local expectedSceneMode = run.skip and "skip" or "natural"
    local scenesPassed = run.cutscenesFinished.SWEET2A == expectedSceneMode and
                             run.cutscenesFinished.SWEET2B == expectedSceneMode and
                             run.returnScenes.grove == expectedSceneMode and run.returnScenes.smoke == expectedSceneMode
    trace(ok and "PASS" or "FAIL", {
        reason = reason,
        players = #run.participants,
        reconstruction = run.reconstructionPassed == true,
        chaseInput = run.inputPassed.chase_controls == true,
        driveBy = run.driveByPassed == true,
        footCombat = run.footCombatPassed == true,
        reward = run.rewardPassed == true,
        cleanup = run.cleanupPassed == true,
        inputAll = inputAllPassed,
        objectives = objectivesPassed,
        scenes = scenesPassed,
    })
    outputServerLog(("[drive-thru-transition] %s profile=%s players=%d reason=%s"):format(
                        ok and "PASS" or "FAIL", run.profile, #run.participants, tostring(reason or "complete")))
    if run.traceFile then
        fileClose(run.traceFile)
        run.traceFile = nil
    end
    if not ok and run.ownsMission and not run.cleanupStarted then
        local api = rawget(_G, "DRIVETHRU_MISSION_HARNESS_API")
        if type(api) == "table" and type(api.abort) == "function" then
            api.abort("transition_harness_fail")
        end
    end
    harness.run = nil
end

local function rememberTimer(timer)
    local run = harness.run
    if run then
        run.timers[#run.timers + 1] = timer
    end
    return timer
end

local function snapshotPlayer(player)
    local x, y, z = getElementPosition(player)
    return {
        x = x,
        y = y,
        z = z,
        interior = getElementInterior(player),
        dimension = getElementDimension(player),
        alpha = getElementAlpha(player),
        frozen = isElementFrozen(player),
        collisions = getElementCollisionsEnabled(player),
        health = getElementHealth(player),
        money = getPlayerMoney(player),
    }
end

local function restoredPlayer(player, expected, reward)
    if not isElement(player) or not expected then
        return false, "player unavailable"
    end
    local x, y, z = getElementPosition(player)
    local distance = getDistanceBetweenPoints3D(x, y, z, expected.x, expected.y, expected.z)
    local moneyExpected = expected.money + (reward or 0)
    if distance > 0.75 then
        return false, ("position delta %.3f"):format(distance)
    end
    if getElementInterior(player) ~= expected.interior or getElementDimension(player) ~= expected.dimension then
        return false, "interior/dimension mismatch"
    end
    if getElementAlpha(player) ~= expected.alpha or isElementFrozen(player) ~= expected.frozen or
        getElementCollisionsEnabled(player) ~= expected.collisions then
        return false, "alpha/frozen/collision mismatch"
    end
    if math.abs(getElementHealth(player) - expected.health) > 0.5 then
        return false, "health mismatch"
    end
    for _, control in ipairs({"forwards", "accelerate", "vehicle_left", "vehicle_right", "enter_exit", "chatbox"}) do
        if not isControlEnabled(player, control) then
            return false, "disabled control: " .. control
        end
    end
    if getPlayerMoney(player) ~= moneyExpected then
        return false, ("money expected=%d actual=%d"):format(moneyExpected, getPlayerMoney(player))
    end
    return true
end

local function roleVehicleCount(role)
    local count = 0
    for _, vehicle in ipairs(getElementsByType("vehicle")) do
        if getElementData(vehicle, DRIVETHRU.vehicleRoleData) == role and getElementDimension(vehicle) == DRIVETHRU.dimension then
            count = count + 1
        end
    end
    return count
end

local function missionElementCount()
    local count = 0
    for _, elementType in ipairs({"vehicle", "ped"}) do
        for _, element in ipairs(getElementsByType(elementType)) do
            if getElementDimension(element) == DRIVETHRU.dimension and
                (getElementData(element, DRIVETHRU.missionActorData) == true or
                    type(getElementData(element, DRIVETHRU.vehicleRoleData)) == "string") then
                count = count + 1
            end
        end
    end
    return count
end

local function serverReconstructionEvidence(entities)
    local greenwood, voodoo = entities.vehicle, entities.voodoo
    local expectedSeats = {smoke = 3, sweet = 2, ryder = 1}
    if not isElement(greenwood) or not isElement(voodoo) then
        return false, "pursuit vehicles unavailable"
    end
    if roleVehicleCount("greenwood") ~= 1 or roleVehicleCount("voodoo") ~= 1 then
        return false, ("vehicle uniqueness greenwood=%d voodoo=%d"):format(roleVehicleCount("greenwood"),
                                                                            roleVehicleCount("voodoo"))
    end
    if math.abs(getElementHealth(voodoo) - DRIVETHRU.restaurant.voodoo.health) > 0.01 then
        return false, ("Voodoo health expected=2700 actual=%.3f"):format(getElementHealth(voodoo))
    end
    local run = harness.run
    if not run or getPedOccupiedVehicle(run.leader) ~= greenwood or getPedOccupiedVehicleSeat(run.leader) ~= 0 then
        return false, "CJ seat mismatch"
    end
    for name, seat in pairs(expectedSeats) do
        local ped = entities[name]
        if not isElement(ped) or getPedOccupiedVehicle(ped) ~= greenwood or getPedOccupiedVehicleSeat(ped) ~= seat then
            return false, name .. " seat mismatch"
        end
    end
    if not isElement(entities.ballas_driver) or getPedOccupiedVehicle(entities.ballas_driver) ~= voodoo or
        getPedOccupiedVehicleSeat(entities.ballas_driver) ~= 0 then
        return false, "Ballas driver seat mismatch"
    end
    if getElementSyncer(greenwood) ~= run.leader or getElementSyncer(voodoo) ~= run.leader then
        return false, "vehicle syncer mismatch"
    end
    return true
end

local function expectedParticipant(player)
    local run = harness.run
    return run and run.participantSet[player] == true
end

local function issueInputProbe(checkpoint, vehicle)
    local run = harness.run
    if not run or run.activeProbe or run.inputIssued[checkpoint] then
        return
    end
    run.probeSerial = run.probeSerial + 1
    local probe = {id = run.probeSerial, checkpoint = checkpoint, vehicle = vehicle, startedAt = getTickCount()}
    run.activeProbe = probe
    run.inputIssued[checkpoint] = true
    trace("READY", {probeId = probe.id, checkpoint = checkpoint, player = playerName(run.leader), control = "accelerate", key = "w"})
    outputServerLog(("[drive-thru-transition] READY checkpoint=%s player=%s input=physical-w"):format(
                        checkpoint, playerName(run.leader)))
    triggerClientEvent(run.leader, "drivethru:harnessInputProbe", resourceRoot, run.id, probe.id, checkpoint, vehicle)
    rememberTimer(setTimer(function(expectedProbe)
        local current = harness.run
        if current and current.activeProbe == expectedProbe then
            terminal(false, "physical input checkpoint timed out: " .. expectedProbe.checkpoint)
        end
    end, 70000, 1, probe))
end

local function issueEntryProbe(vehicle)
    local run = harness.run
    if not run or run.activeProbe or run.inputIssued.entry then
        return
    end
    run.probeSerial = run.probeSerial + 1
    local probe = {id = run.probeSerial, checkpoint = "entry", vehicle = vehicle, startedAt = getTickCount()}
    run.activeProbe = probe
    run.inputIssued.entry = true
    trace("READY", {probeId = probe.id, checkpoint = probe.checkpoint, player = playerName(run.leader),
                     control = "enter_exit", key = "f"})
    outputServerLog(("[drive-thru-transition] READY checkpoint=entry player=%s input=physical-f"):format(
                        playerName(run.leader)))
    triggerClientEvent(run.leader, "drivethru:harnessEntryProbe", resourceRoot, run.id, probe.id, vehicle)
    rememberTimer(setTimer(function(expectedProbe)
        local current = harness.run
        if current and current.activeProbe == expectedProbe then
            terminal(false, "physical input checkpoint timed out: entry")
        end
    end, 45000, 1, probe))
end

local function evidenceFor(role, actor)
    local run = harness.run
    return run and run.presentation[role] and run.presentation[role][actor] or nil
end

local function driveByEvidenceReady()
    local run = harness.run
    if not run or not run.pursuitTasksReady or not run.inputPassed.chase_controls or not run.voodooDamaged then
        return false
    end
    for _, role in ipairs(run.expectedPlayers == 2 and {"leader", "observer"} or {"leader"}) do
        for _, actor in ipairs({"BallasPassenger", "Ryder", "Sweet"}) do
            local evidence = evidenceFor(role, actor)
            local ownershipCorrect = role == "leader" and evidence and evidence.clientClaimsSyncer and evidence.serverOwner or
                                         role == "observer" and evidence and not evidence.clientClaimsSyncer and not evidence.serverOwner
            -- onClientPedWeaponFire is generated only by the ped's native
            -- authority. Remote clients prove replication through the live
            -- drive-by task; the server-side vehicle damage gate above proves
            -- that the authoritative shots affected shared mission state.
            -- The bounded headless W probe leaves the Greenwood parked while
            -- the scripted Voodoo follows its route, so its passenger can be
            -- outside GTA's firing cone despite retaining the correct native
            -- task. Ryder and Sweet must really fire and damage the shared
            -- Voodoo; the opposing passenger is exercised again on foot.
            local firingEvidence = role == "observer" or actor == "BallasPassenger" or
                                       (role == "leader" and evidence and evidence.shots >= 1)
            if not evidence or not evidence.streamed or not evidence.driveBy or not firingEvidence or not ownershipCorrect then
                return false
            end
        end
    end
    return true
end

local function footCombatEvidenceReady()
    local run = harness.run
    if not run or not run.footCombatReady or not run.actualBallasDamage then
        return false
    end
    for _, actor in ipairs({"BallasDriver", "BallasPassenger"}) do
        local evidence = evidenceFor("leader", actor)
        if evidence and evidence.streamed and evidence.killOnFoot and evidence.clientClaimsSyncer and evidence.serverOwner then
            return true
        end
    end
    return false
end

local function poll()
    local run = harness.run
    local api = rawget(_G, "DRIVETHRU_MISSION_HARNESS_API")
    if not run or run.terminal then
        return
    end
    if type(api) ~= "table" then
        return terminal(false, "mission API disappeared")
    end
    if getTickCount() >= run.deadline then
        return terminal(false, "global timeout")
    end
    local state = api.snapshot()
    local stage = tostring(state.stage or "none")
    if stage ~= run.lastStage then
        run.lastStage = stage
        run.stageStartedAt = getTickCount()
        trace("STAGE", {stage = stage})
    elseif getTickCount() - run.stageStartedAt > (STAGE_TIMEOUTS[stage] or 60000) then
        return terminal(false, "stage timeout: " .. stage)
    end
    local objectiveStage = {
        restaurant = stage == "restaurant_camera" or stage == "restaurant_teardown" or stage == "cutscene" or
                         stage == "restaurant_rebuild" or stage == "restaurant_barrier" or stage == "pursuit_route_barrier" or
                         stage == "pursuit_task_barrier" or stage == "chase",
        combat = stage == "return_grove_drive" or stage:find("^return_grove_scene") ~= nil or
                     stage == "return_smoke_drive" or stage:find("^return_smoke_scene") ~= nil or stage == "complete",
        grove = stage:find("^return_grove_scene") ~= nil or stage == "return_smoke_drive" or
                    stage:find("^return_smoke_scene") ~= nil or stage == "complete",
        smoke = stage:find("^return_smoke_scene") ~= nil or stage == "complete",
    }
    for name, reached in pairs(objectiveStage) do
        local inputReady = name == "combat" and run.combatCompleted == true or name ~= "combat" and run.inputPassed[name] == true
        if reached and inputReady and not run.objectivePassed[name] then
            run.objectivePassed[name] = true
            trace("CHECKPOINT_PASS", {checkpoint = name, stage = stage})
        end
    end
    if not state.running and not run.cleanupStarted then
        return terminal(false, "mission graph stopped before cleanup verdict")
    end

    if run.skip and state.cutscene and state.cutscene.started and
        getTickCount() - (run.cutsceneStartedAt[state.cutscene.id] or getTickCount()) >= 1000 and
        not run.skippedScenes["cutscene:" .. state.cutscene.id] then
        local ok, kind, id = api.skipCurrentScene()
        if ok then
            run.skippedScenes["cutscene:" .. id] = true
            trace("SKIP", {kind = kind, sceneId = id, name = state.cutscene.name})
        end
    end
    if run.skip and state.returnScene and state.returnScene.skippable and
        not run.skippedScenes["return:" .. state.returnScene.id] then
        local ok, kind, id = api.skipCurrentScene()
        if ok then
            run.skippedScenes["return:" .. id] = true
            trace("SKIP", {kind = kind, sceneId = id, phase = state.returnScene.phase})
        end
    end

    if stage == "enter_car" and not run.inputIssued.entry then
        local ok, vehicle = api.stageEntry()
        if not ok then
            return terminal(false, "driver entry staging rejected: " .. tostring(vehicle))
        end
        issueEntryProbe(vehicle)
    elseif stage == "drive" and not run.activeProbe and not run.inputIssued.restaurant then
        local ok, vehicle = api.stageArrival("restaurant")
        if not ok then
            return terminal(false, "restaurant arrival staging rejected: " .. tostring(vehicle))
        end
        issueInputProbe("restaurant", vehicle)
    elseif stage == "chase" and not run.activeProbe and not run.inputIssued.chase_controls then
        issueInputProbe("chase_controls", state.entities.vehicle)
    elseif stage == "return_grove_drive" and not run.activeProbe and not run.inputIssued.grove then
        local ok, vehicle = api.stageArrival("grove")
        if not ok then
            return terminal(false, "Grove arrival staging rejected: " .. tostring(vehicle))
        end
        issueInputProbe("grove", vehicle)
    elseif stage == "return_smoke_drive" and not run.activeProbe and not run.inputIssued.smoke then
        local ok, vehicle = api.stageArrival("smoke")
        if not ok then
            return terminal(false, "Smoke arrival staging rejected: " .. tostring(vehicle))
        end
        issueInputProbe("smoke", vehicle)
    end

    if stage == "chase" and not state.footCombat and not run.footCombatForced and driveByEvidenceReady() then
        run.driveByPassed = true
        local ok, reason = api.forceFootCombat()
        if not ok then
            return terminal(false, "foot-combat threshold rejected: " .. tostring(reason))
        end
        run.footCombatForced = true
        trace("CHASE_PASS", {voodooMinimumHealth = run.voodooMinimumHealth, nativeDriveBy = true, actualDamage = true})
    elseif stage == "chase" and state.footCombat and run.footCombatReady and not run.footCombatStaged then
        run.footCombatReady = false
        local ok, reason = api.stageFootCombat()
        if not ok then
            return terminal(false, "foot-combat staging rejected: " .. tostring(reason))
        end
        run.footCombatStaged = true
        trace("FOOT_COMBAT_STAGED", {nativeTasks = true, damageInjected = false})
    elseif stage == "chase" and state.footCombat and not run.combatCompleted and footCombatEvidenceReady() then
        run.footCombatPassed = true
        local ok, reason = api.completeCombat()
        if not ok then
            return terminal(false, "combat completion rejected: " .. tostring(reason))
        end
        run.combatCompleted = true
        trace("COMBAT_PASS", {actualBallasDamage = true, killOnFoot = true, killedByHarness = reason})
    end
end

local function guardedPoll()
    local ok, reason = pcall(poll)
    if not ok and harness.run then
        terminal(false, "poll error: " .. tostring(reason))
    end
end

local function startTransition(sourcePlayer, expectedPlayers, skip)
    if harness.run then
        return outputServerLog("[drive-thru-transition] FAIL profile=unstarted reason=harness-already-running")
    end
    local api = rawget(_G, "DRIVETHRU_MISSION_HARNESS_API")
    if type(api) ~= "table" or type(api.start) ~= "function" then
        return outputServerLog("[drive-thru-transition] FAIL profile=unstarted reason=mission-api-unavailable")
    end
    local existing = api.snapshot()
    if existing.running then
        return outputServerLog("[drive-thru-transition] FAIL profile=unstarted reason=mission-already-running")
    end
    expectedPlayers = tonumber(expectedPlayers) or #getElementsByType("player")
    if expectedPlayers ~= 1 and expectedPlayers ~= 2 then
        return outputServerLog("[drive-thru-transition] FAIL profile=unstarted reason=expected-players-must-be-1-or-2")
    end
    local players = getElementsByType("player")
    if #players ~= expectedPlayers then
        return outputServerLog(("[drive-thru-transition] FAIL profile=unstarted reason=connected-player-count expected=%d actual=%d"):format(
                                   expectedPlayers, #players))
    end
    -- Server-console command handlers receive the console element as their
    -- source.  It is an element, but it is not a valid mission participant.
    local leader = isElement(sourcePlayer) and getElementType(sourcePlayer) == "player" and sourcePlayer or players[1]
    local participants, participantSet, snapshots = {leader}, {[leader] = true}, {[leader] = snapshotPlayer(leader)}
    for _, player in ipairs(players) do
        if player ~= leader then
            participants[#participants + 1] = player
            participantSet[player] = true
            snapshots[player] = snapshotPlayer(player)
        end
    end
    harness.serial = harness.serial + 1
    local profile = (expectedPlayers == 2 and "coop-" or "solo-") .. (skip and "skip" or "natural")
    local now = getTickCount()
    local tracePath = ("@drive-thru-transition-%d-%d.jsonl"):format(harness.serial, now)
    harness.run = {
        id = harness.serial,
        profile = profile,
        expectedPlayers = expectedPlayers,
        skip = skip == true,
        leader = leader,
        participants = participants,
        participantSet = participantSet,
        snapshots = snapshots,
        startedAt = now,
        deadline = now + 1200000,
        stageStartedAt = now,
        lastStage = "starting",
        timers = {},
        traceFile = fileCreate(tracePath),
        traceRecords = 0,
        inputIssued = {},
        inputPassed = {},
        objectivePassed = {},
        skippedScenes = {},
        presentation = {leader = {}, observer = {}},
        reconstructionReports = {},
        cleanupReports = {},
        cutscenesFinished = {},
        cutsceneStartedAt = {},
        returnScenes = {},
        probeSerial = 0,
        ownsMission = false,
    }
    trace("START", {players = expectedPlayers, leader = playerName(leader), traceFile = tracePath})
    local ok, reason = api.start(leader)
    if not ok then
        return terminal(false, "startMission rejected: " .. tostring(reason))
    end
    harness.run.ownsMission = true
    triggerClientEvent(participants, "drivethru:harnessStart", resourceRoot, harness.run.id, profile, leader)
    rememberTimer(setTimer(guardedPoll, 100, 0))
end

addEvent("drivethru:harnessInputReady", true)
addEventHandler("drivethru:harnessInputReady", resourceRoot, function(runId, probeId, checkpoint, control)
    local run, probe = harness.run, harness.run and harness.run.activeProbe
    if source ~= resourceRoot or not run or client ~= run.leader or tonumber(runId) ~= run.id or not probe or
        tonumber(probeId) ~= probe.id or tostring(checkpoint) ~= probe.checkpoint then
        return
    end
    trace("INPUT_READY", {probeId = probe.id, checkpoint = probe.checkpoint, player = playerName(client),
                           control = tostring(control), key = probe.checkpoint == "entry" and "f" or "w"})
end)

addEvent("drivethru:harnessInputDone", true)
addEventHandler("drivethru:harnessInputDone", resourceRoot, function(runId, probeId, checkpoint, ok, reason, evidence)
    local run, probe = harness.run, harness.run and harness.run.activeProbe
    if source ~= resourceRoot or not run or client ~= run.leader or tonumber(runId) ~= run.id or not probe or
        tonumber(probeId) ~= probe.id or tostring(checkpoint) ~= probe.checkpoint or type(evidence) ~= "table" then
        return
    end
    local raw, processed = tonumber(evidence.raw) or -1, tonumber(evidence.processed) or -1
    local samples, displacement = tonumber(evidence.samples) or -1, tonumber(evidence.displacement) or -1
    local state = DRIVETHRU_MISSION_HARNESS_API.snapshot()
    local serverOccupied = isElement(probe.vehicle) and getPedOccupiedVehicle(run.leader) == probe.vehicle and
                               getPedOccupiedVehicleSeat(run.leader) == 0
    local entry = probe.checkpoint == "entry"
    local restaurantTransition = probe.checkpoint == "restaurant" and evidence.transitionAfterInput == true and
                                     evidence.occupiedAtStart == true and evidence.streamedAtStart == true and
                                     (state.stage == "restaurant_camera" or state.stage == "restaurant_teardown" or
                                         state.stage == "cutscene" or state.stage == "restaurant_rebuild" or
                                         state.stage == "restaurant_barrier" or state.stage == "pursuit_route_barrier" or
                                         state.stage == "pursuit_task_barrier" or state.stage == "chase")
    local controlEvidence = entry or (raw > 0.8 and processed > 0.8 and samples >= 3 and displacement > 0.5 and
                                (evidence.onAllWheels == true or restaurantTransition))
    local occupancyEvidence = evidence.occupied == true and tonumber(evidence.seat) == 0 and evidence.streamed == true and
                                  serverOccupied or restaurantTransition
    local accepted = ok == true and evidence.keyObserved == true and evidence.cameraLocalDuringInput == true and
                         occupancyEvidence and state.running and isControlEnabled(run.leader, "chatbox") and controlEvidence
    if not accepted then
        trace("INPUT_FAIL", {probeId = probe.id, checkpoint = probe.checkpoint, reason = reason,
                             raw = evidence.raw, processed = evidence.processed, samples = evidence.samples,
                             displacement = evidence.displacement, keyObserved = evidence.keyObserved,
                             cameraLocal = evidence.cameraLocalDuringInput, occupied = evidence.occupied,
                             seat = evidence.seat, streamed = evidence.streamed, serverOccupied = serverOccupied,
                             serverChat = isControlEnabled(run.leader, "chatbox"), running = state.running})
        return terminal(false, "physical input rejected at " .. probe.checkpoint .. ": " .. tostring(reason))
    end
    run.activeProbe = nil
    run.inputPassed[probe.checkpoint] = true
    trace("INPUT_PASS", {probeId = probe.id, checkpoint = probe.checkpoint, raw = evidence.raw,
                         processed = evidence.processed, samples = evidence.samples, displacement = evidence.displacement,
                         keyObserved = true, onAllWheels = evidence.onAllWheels == true})
end)

addEvent("drivethru:harnessReconstructionDone", true)
addEventHandler("drivethru:harnessReconstructionDone", resourceRoot, function(runId, ok, reason, evidence)
    local run = harness.run
    if source ~= resourceRoot or not run or tonumber(runId) ~= run.id or not expectedParticipant(client) or
        run.reconstructionReports[client] then
        return
    end
    run.reconstructionReports[client] = ok == true
    trace(ok == true and "RECONSTRUCTION_CLIENT_PASS" or "RECONSTRUCTION_CLIENT_FAIL", {
        player = playerName(client), reason = reason, health = type(evidence) == "table" and evidence.health or nil,
        greenwoodCount = type(evidence) == "table" and evidence.greenwoodCount or nil,
        voodooCount = type(evidence) == "table" and evidence.voodooCount or nil,
    })
    if ok ~= true then
        return terminal(false, "client reconstruction rejected for " .. playerName(client) .. ": " .. tostring(reason))
    end
    local count = 0
    for _, player in ipairs(run.participants) do
        if run.reconstructionReports[player] == true then
            count = count + 1
        end
    end
    if count == run.expectedPlayers then
        run.reconstructionPassed = true
        trace("RECONSTRUCTION_PASS", {clients = count, server = true, health = 2700})
    end
end)

addEvent("drivethru:harnessCleanupDone", true)
addEventHandler("drivethru:harnessCleanupDone", resourceRoot, function(runId, ok, reason, evidence)
    local run = harness.run
    if source ~= resourceRoot or not run or tonumber(runId) ~= run.id or not expectedParticipant(client) or run.cleanupReports[client] then
        return
    end
    run.cleanupReports[client] = ok == true
    trace(ok == true and "CLEANUP_CLIENT_PASS" or "CLEANUP_CLIENT_FAIL", {
        player = playerName(client), reason = reason, cameraLocal = type(evidence) == "table" and evidence.cameraLocal or nil,
        controls = type(evidence) == "table" and evidence.controls or nil,
    })
    if ok ~= true then
        return terminal(false, "client cleanup rejected for " .. playerName(client) .. ": " .. tostring(reason))
    end
    local count = 0
    for _, player in ipairs(run.participants) do
        if run.cleanupReports[player] == true then
            count = count + 1
        end
    end
    if count == run.expectedPlayers then
        run.cleanupPassed = true
        terminal(run.rewardPassed and run.reconstructionPassed and run.driveByPassed and run.footCombatPassed,
                 run.rewardPassed and run.reconstructionPassed and run.driveByPassed and run.footCombatPassed and "complete" or
                     "required mission evidence missing at cleanup")
    end
end)

DRIVETHRU_TRANSITION_HARNESS = {
    onInternalError = function(method, reason)
        if harness.run then
            terminal(false, ("mission callback error method=%s reason=%s"):format(tostring(method), tostring(reason)))
        end
    end,
    onCutsceneStarted = function(sceneId, name, purpose)
        if harness.run then
            harness.run.cutsceneStartedAt[sceneId] = getTickCount()
            trace("CUTSCENE_STARTED", {sceneId = sceneId, name = name, purpose = purpose})
        end
    end,
    onCutsceneFinished = function(sceneId, name, purpose, skipped, elapsed)
        local run = harness.run
        if not run then
            return
        end
        if name ~= "SWEET2A" and name ~= "SWEET2B" then
            return terminal(false, "unexpected file cutscene: " .. tostring(name))
        end
        if skipped ~= run.skip then
            return terminal(false, ("cutscene profile mismatch name=%s expectedSkipped=%s actual=%s"):format(
                                name, tostring(run.skip), tostring(skipped)))
        end
        run.cutscenesFinished[name] = skipped and "skip" or "natural"
        trace("CUTSCENE_FINISHED", {sceneId = sceneId, name = name, purpose = purpose, skipped = skipped, elapsed = elapsed})
    end,
    onReturnSceneReleased = function(phase, skipped)
        local run = harness.run
        if not run then
            return
        end
        if phase ~= "grove" and phase ~= "smoke" then
            return terminal(false, "unexpected return scene: " .. tostring(phase))
        end
        if skipped ~= run.skip then
            return terminal(false, ("return-scene profile mismatch phase=%s expectedSkipped=%s actual=%s"):format(
                                phase, tostring(run.skip), tostring(skipped)))
        end
        run.returnScenes[phase] = skipped and "skip" or "natural"
        trace("RETURN_SCENE_RELEASED", {phase = phase, skipped = skipped})
    end,
    onRestaurantRebuildReady = function(details, entities)
        local run = harness.run
        if not run then
            return
        end
        local ok, reason = serverReconstructionEvidence(entities)
        if not ok then
            return terminal(false, "server reconstruction rejected: " .. tostring(reason))
        end
        trace("RECONSTRUCTION_SERVER_PASS", {details = tostring(details), health = getElementHealth(entities.voodoo),
                                               greenwoodCount = 1, voodooCount = 1})
        triggerClientEvent(run.participants, "drivethru:harnessReconstructionProbe", resourceRoot, run.id, entities)
        rememberTimer(setTimer(function(expectedRun)
            if harness.run == expectedRun and not expectedRun.reconstructionPassed then
                terminal(false, "client reconstruction reports timed out")
            end
        end, 12000, 1, run))
    end,
    onPursuitTasksReady = function(details)
        if harness.run then
            harness.run.pursuitTasksReady = true
            trace("PURSUIT_TASKS_PASS", {details = tostring(details)})
        end
    end,
    onFootCombatReady = function(details)
        if harness.run then
            harness.run.footCombatReady = true
            trace("FOOT_TASKS_PASS", {details = tostring(details)})
        end
    end,
    onPresentationDiagnostic = function(player, partyRole, actorLabel, stage, streamed, clientClaimsSyncer, serverOwner,
                                        shots, driveBy, killOnFoot, weapon, target)
        local run = harness.run
        if not run or not expectedParticipant(player) or (partyRole ~= "leader" and partyRole ~= "observer") then
            return
        end
        local current = run.presentation[partyRole][actorLabel] or {shots = 0}
        current.streamed = current.streamed == true or streamed == true
        current.shots = math.max(current.shots or 0, tonumber(shots) or 0)
        current.driveBy = current.driveBy == true or driveBy == true
        current.killOnFoot = current.killOnFoot == true or killOnFoot == true
        current.clientClaimsSyncer = clientClaimsSyncer == true
        current.serverOwner = serverOwner == true
        current.weapon = tostring(weapon)
        current.target = tostring(target)
        run.presentation[partyRole][actorLabel] = current
    end,
    onPedDamage = function(ped, attacker, weapon, bodypart, loss)
        local run = harness.run
        if not run or not isElement(ped) then
            return
        end
        local state = DRIVETHRU_MISSION_HARNESS_API.snapshot()
        local validAttacker = attacker == run.leader or attacker == state.entities.sweet or attacker == state.entities.ryder or
                                  attacker == state.entities.mate1 or attacker == state.entities.mate2
        if state.stage == "chase" and state.footCombat and (tonumber(loss) or 0) > 0 and validAttacker and
            (ped == state.entities.ballas_driver or ped == state.entities.ballas_passenger) then
            run.actualBallasDamage = true
            trace("BALLAS_DAMAGE", {actor = ped == state.entities.ballas_driver and "driver" or "passenger",
                                     attackerType = isElement(attacker) and getElementType(attacker) or "none",
                                     weapon = weapon, bodypart = bodypart, loss = loss})
        end
    end,
    onMissionPassed = function(reward, tune)
        local run = harness.run
        if not run then
            return
        end
        run.rewardPassed = tonumber(reward) == 200 and tonumber(tune) == 1 and
                               getPlayerMoney(run.leader) == run.snapshots[run.leader].money + 200
        trace("REWARD", {reward = reward, tune = tune, money = getPlayerMoney(run.leader), ok = run.rewardPassed})
        if not run.rewardPassed then
            terminal(false, "reward or tune mismatch")
        end
    end,
    onMissionFailed = function(reason, textKey)
        local run = harness.run
        if run then
            run.graphFailed = tostring(reason)
            trace("MISSION_FAILED", {reason = tostring(reason), textKey = tostring(textKey)})
        end
    end,
    onMissionCleanup = function(reason)
        local run = harness.run
        if not run or run.terminal then
            return
        end
        run.cleanupStarted = true
        if reason ~= "complete" or run.graphFailed then
            return terminal(false, "mission graph failed: " .. tostring(run.graphFailed or reason))
        end
        if missionElementCount() ~= 0 then
            return terminal(false, "mission elements survived cleanup: " .. missionElementCount())
        end
        for _, player in ipairs(run.participants) do
            local reward = player == run.leader and 200 or 0
            local ok, details = restoredPlayer(player, run.snapshots[player], reward)
            if not ok then
                return terminal(false, "server cleanup mismatch for " .. playerName(player) .. ": " .. details)
            end
        end
        local inputAllPassed = run.inputPassed.entry == true and run.inputPassed.restaurant == true and
                                   run.inputPassed.chase_controls == true and
                                   run.inputPassed.grove == true and run.inputPassed.smoke == true
        local objectivesPassed = run.objectivePassed.restaurant == true and run.objectivePassed.combat == true and
                                     run.objectivePassed.grove == true and run.objectivePassed.smoke == true
        local expectedSceneMode = run.skip and "skip" or "natural"
        local scenesPassed = run.cutscenesFinished.SWEET2A == expectedSceneMode and
                                 run.cutscenesFinished.SWEET2B == expectedSceneMode and
                                 run.returnScenes.grove == expectedSceneMode and run.returnScenes.smoke == expectedSceneMode
        if not inputAllPassed or not objectivesPassed or not scenesPassed then
            return terminal(false, "physical checkpoint or scene-profile evidence missing at cleanup")
        end
        trace("CLEANUP_SERVER_PASS", {players = #run.participants, missionElements = 0, inputAll = true,
                                       objectives = true, scenes = true})
        rememberTimer(setTimer(function(expectedRun)
            if harness.run == expectedRun then
                triggerClientEvent(expectedRun.participants, "drivethru:harnessCleanupProbe", resourceRoot, expectedRun.id)
            end
        end, 250, 1, run))
        rememberTimer(setTimer(function(expectedRun)
            if harness.run == expectedRun then
                terminal(false, "client cleanup reports timed out")
            end
        end, 10000, 1, run))
    end,
}

addEventHandler("onVehicleDamage", root, function(loss)
    local run = harness.run
    if not run then
        return
    end
    local state = DRIVETHRU_MISSION_HARNESS_API.snapshot()
    if source == state.entities.voodoo then
        local health = getElementHealth(source)
        run.voodooMinimumHealth = math.min(run.voodooMinimumHealth or health, health)
        if health < DRIVETHRU.restaurant.voodoo.health or (tonumber(loss) or 0) > 0 then
            run.voodooDamaged = true
        end
        trace("VOODOO_DAMAGE", {health = health, loss = tonumber(loss)})
    end
end)

addCommandHandler("drivethrutransitionnatural", function(player, _, expectedPlayers)
    startTransition(player, expectedPlayers, false)
end)

addCommandHandler("drivethrutransitionskip", function(player, _, expectedPlayers)
    startTransition(player, expectedPlayers, true)
end)

addEventHandler("onResourceStop", resourceRoot, function()
    if harness.run and harness.run.traceFile then
        fileClose(harness.run.traceFile)
    end
    harness.run = nil
    DRIVETHRU_TRANSITION_HARNESS = nil
end)
