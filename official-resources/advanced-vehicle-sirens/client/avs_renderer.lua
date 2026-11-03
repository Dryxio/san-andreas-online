--[[
    Advanced Vehicle Sirens (AVS) - Client 3D Corona, Texture Swapper & Ground Shadow Renderer
    
    Provides 100% standalone AVS rendering for standard, unmodified MTA:SA:
    - Directional line-of-sight flares with TIR lens optic falloff
    - 360-degree rotating beacons with smooth angular interpolation
    - Camera-oriented 3D billboarded coronas with hot-core blending
    - Dynamic lightbar bulb & reflector strobing via ps_3_0 / ps_2_0 HLSL shaders
      (decodes AVS material encoding so individual bulbs pulse and alternate realistically)
    - Dynamic asphalt / ground reflection projections using 33 authentic AVS shadow optics
    - Developer and player toggles for ground shadow reflections
    - Zero performance overhead when sirens are inactive
]]

AVSRenderer = {}

local coronaTexture = nil
local registeredModelConfigs = {}
local activeVehicles = {}

-- Global shadow reflection toggle (true by default)
local globalShadowsEnabled = true

-- Predefined list of 33 ground shadow textures matching AVS specifications
local shadowTextureNames = {
    [0] = "arealight256",
    [1] = "bollard256",
    [2] = "comet256",
    [3] = "cylindernarrow256",
    [4] = "defined256",
    [5] = "defineddiffuse256",
    [6] = "defineddiffusespot256",
    [7] = "definedspot256",
    [8] = "display256",
    [9] = "jellyfish256",
    [10] = "mediumscatter256",
    [11] = "overhead256",
    [12] = "parallelbeam256",
    [13] = "pear256",
    [14] = "pointlight256",
    [15] = "round256",
    [16] = "scatterlight256",
    [17] = "softarrow256",
    [18] = "softdisplay256",
    [19] = "star256",
    [20] = "starfocused256",
    [21] = "taillight256",
    [22] = "threelobeumbrella256",
    [23] = "threelobevee256",
    [24] = "tightfocused256",
    [25] = "toppost256",
    [26] = "trapezoid256",
    [27] = "umbrella256",
    [28] = "vee256",
    [29] = "veeup256",
    [30] = "xarrow256",
    [31] = "xarrowdiffuse256",
    [32] = "xarrowsoft256",
}

-- Cache loaded shadow texture elements
local shadowTextures = {}

-- Cache loaded 2D textures (unlit and illuminated) to prevent duplicate VRAM allocation
local cachedTextures = {}

local function getTexture(texName)
    if cachedTextures[texName] ~= nil then
        return cachedTextures[texName]
    end

    local path = "assets/textures/" .. texName .. ".png"
    if fileExists(path) then
        local tex = dxCreateTexture(path)
        cachedTextures[texName] = tex or false
        return tex
    end

    cachedTextures[texName] = false
    return nil
end

-- Model-specific unlit target texture -> unlit source & authentic illuminated replacement texture pairs
local vehicleTexturePairs = {
    -- Model 407 (Firetruck)
    [407] = {
        { target = "sirenlights128", unlit = "sirenlights128", replacement = "sirenlights128on" },
        { target = "siren128",       unlit = "siren128",       replacement = "siren128on" },
    },
    -- Model 416 (Ambulance)
    [416] = {
        { target = "sirenlight128", unlit = "sirenlight128", replacement = "sirenlight128_on" },
        { target = "siren256",      unlit = "siren256",      replacement = "siren256_on" },
    },
    -- Model 426 (Premier Unmarked)
    [426] = {
        { target = "sirenlight128", unlit = "sirenlight128", replacement = "sirenlight128on" },
    },
    -- Model 427 (Enforcer)
    [427] = {
        { target = "sirenlights",   unlit = "sirenlights",   replacement = "sirenlights_on" },
    },
    -- Model 445 (Admiral Unmarked)
    [445] = {
        { target = "sirenlight128", unlit = "sirenlight128", replacement = "sirenlight128on" },
    },
    -- Model 490 (FBI Rancher)
    [490] = {
        { target = "sirenlight128", unlit = "sirenlight128", replacement = "sirenlight128on" },
    },
    -- Model 525 (Towtruck)
    [525] = {
        { target = "vehiclelights", unlit = "vehiclelights", replacement = "vehiclelights_on" },
    },
    -- Model 528 (FBI Truck)
    [528] = {
        { target = "siren64",       unlit = "siren64",       replacement = "siren64_on" },
    },
    -- Model 554 (Yosemite DOT)
    [554] = {
        { target = "sirenlight",    unlit = "sirenlight",    replacement = "sirenlighton" },
    },
    -- Model 578 (DFT-30 DOT)
    [578] = {
        { target = "sirentow",      unlit = "sirentow",      replacement = "sirentow_on" },
    },
    -- Model 596 (Police Car LS - Dodge Charger)
    [596] = {
        { target = "sirenlight",    unlit = "sirenlight",    replacement = "sirenlighton" },
    },
    -- Model 597 (Police Car SF)
    [597] = {
        { target = "sirenlight",    unlit = "sirenlight",    replacement = "sirenlight_on" },
    },
    -- Model 598 (Police Car LV)
    [598] = {
        { target = "sirenlight128", unlit = "sirenlight128", replacement = "sirenlight128on" },
    },
    -- Model 599 (Police Ranger Rural)
    [599] = {
        { target = "sirennavlights", unlit = "sirennavlights", replacement = "sirennavlightson" },
        { target = "siren32",        unlit = "siren32",        replacement = "siren32on" },
        { target = "siren12",        unlit = "siren12",        replacement = "siren12on" },
        { target = "siren64",        unlit = "siren64",        replacement = "siren64on" },
    },
}

-- Vehicle-specific dynamic shader instances: vehicleShaders[vehicle] = { [targetName] = shaderElement }
local vehicleShaders = {}

-- Attach dynamic strobe shaders to vehicle materials
local function attachVehicleShaders(vehicle)
    if not isElement(vehicle) then return end
    local model = getElementModel(vehicle)
    local pairsList = vehicleTexturePairs[model]
    if not pairsList then return end

    if not vehicleShaders[vehicle] then
        vehicleShaders[vehicle] = {}
    end

    for _, pair in ipairs(pairsList) do
        if not vehicleShaders[vehicle][pair.target] then
            local texOff = getTexture(pair.unlit or pair.target)
            local texOn  = getTexture(pair.replacement)

            if texOn and fileExists("assets/tex_replace.fx") then
                local shader = dxCreateShader("assets/tex_replace.fx", 0, 160.0, false, "vehicle")
                if shader then
                    if texOff then
                        dxSetShaderValue(shader, "gTextureOff", texOff)
                    else
                        dxSetShaderValue(shader, "gTextureOff", texOn)
                    end
                    dxSetShaderValue(shader, "gTextureOn", texOn)
                    dxSetShaderValue(shader, "gGlobalOn", 0.0)
                    dxSetShaderValue(shader, "gStateA", 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
                    dxSetShaderValue(shader, "gStateB", 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
                    dxSetShaderValue(shader, "gStateC", 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)

                    engineApplyShaderToWorldTexture(shader, pair.target, vehicle)
                    vehicleShaders[vehicle][pair.target] = shader
                end
            end
        end
    end
end

-- Reset dynamic strobe shaders for vehicle to unlit off state (zero out strobe values)
local function resetVehicleShaders(vehicle)
    if not vehicleShaders[vehicle] then return end
    for _, shader in pairs(vehicleShaders[vehicle]) do
        if isElement(shader) then
            dxSetShaderValue(shader, "gGlobalOn", 0.0)
            dxSetShaderValue(shader, "gStateA", 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
            dxSetShaderValue(shader, "gStateB", 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
            dxSetShaderValue(shader, "gStateC", 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        end
    end
end

-- Detach and destroy dynamic strobe shaders for vehicle
local function detachVehicleShaders(vehicle)
    if not vehicleShaders[vehicle] then return end

    for target, shader in pairs(vehicleShaders[vehicle]) do
        if isElement(shader) then
            if isElement(vehicle) then
                engineRemoveShaderFromWorldTexture(shader, target, vehicle)
            end
            destroyElement(shader)
        end
    end

    vehicleShaders[vehicle] = nil
end

-- Lazy shadow texture loader
local function getShadowTexture(typeId)
    local id = tonumber(typeId) or 0
    if shadowTextures[id] ~= nil then
        return shadowTextures[id]
    end

    local texName = shadowTextureNames[id] or "arealight256"
    local filePath = "assets/shadows/" .. texName .. ".png"

    if fileExists(filePath) then
        local tex = dxCreateTexture(filePath)
        shadowTextures[id] = tex or false
        return tex
    end

    shadowTextures[id] = false
    return nil
end

function AVSRenderer.init()
    if not coronaTexture and fileExists("assets/corona.png") then
        coronaTexture = dxCreateTexture("assets/corona.png")
    end
end

function AVSRenderer.registerModelConfig(modelId, configTable)
    registeredModelConfigs[tonumber(modelId)] = configTable
end

function AVSRenderer.unregisterModelConfig(modelId)
    registeredModelConfigs[tonumber(modelId)] = nil
end

function AVSRenderer.getModelConfig(modelId)
    return registeredModelConfigs[tonumber(modelId)]
end

function AVSRenderer.getAllConfigs()
    return registeredModelConfigs
end

-- Ground shadow toggles
function AVSRenderer.setShadowsEnabled(enabled)
    globalShadowsEnabled = (enabled == true)
end

function AVSRenderer.isShadowsEnabled()
    return globalShadowsEnabled
end

function AVSRenderer.setVehicleShadowsEnabled(vehicle, enabled)
    if not isElement(vehicle) then return end
    setElementData(vehicle, "avs:shadows", enabled == true)
end

function AVSRenderer.isVehicleShadowsEnabled(vehicle)
    if not isElement(vehicle) then return false end
    if not globalShadowsEnabled then return false end
    return getElementData(vehicle, "avs:shadows") ~= false
end

-- Track vehicles with active sirens
function AVSRenderer.setVehicleState(vehicle, stateName)
    if not isElement(vehicle) then return end
    local wasActive = (activeVehicles[vehicle] ~= nil)
    local isActive = not (not stateName or stateName == 0 or stateName == "0" or stateName == "off" or stateName == false)

    if isActive then
        activeVehicles[vehicle] = tostring(stateName)
        if not wasActive then
            attachVehicleShaders(vehicle)
        end
    else
        activeVehicles[vehicle] = nil
        if wasActive then
            resetVehicleShaders(vehicle)
        end
    end
end

function AVSRenderer.getVehicleState(vehicle)
    return activeVehicles[vehicle] or 0
end

-- Main render loop: executed during onClientRender so 3D coronas appear on top of vehicle lenses
local function onRenderPulse()
    if not coronaTexture then
        AVSRenderer.init()
        if not coronaTexture then return end
    end

    -- Check if custom native C++ engine is handling 3D coronas directly
    local nativeHandlesCoronas = (type(isVehicleSirenModelRegistered) == "function")

    local now = getTickCount()
    local camX, camY, camZ = getCameraMatrix()
    if not camX then return end

    for vehicle, stateName in pairs(activeVehicles) do
        if isElement(vehicle) and isElementStreamedIn(vehicle) then
            local vx, vy, vz = getElementPosition(vehicle)
            local distToCam = getDistanceBetweenPoints3D(camX, camY, camZ, vx, vy, vz)

            -- Render cutoff distance (160m)
            if distToCam <= 160.0 then
                local model = getElementModel(vehicle)
                local config = registeredModelConfigs[model]

                -- Ensure shaders are attached to this vehicle instance
                if not vehicleShaders[vehicle] then
                    attachVehicleShaders(vehicle)
                end

                if config and config.states and config.states[stateName] then
                    local stateData = config.states[stateName]
                    local scanned = AVSScanner.getScannedVehicle(vehicle)
                    if not scanned then
                        scanned = AVSScanner.scanVehicle(vehicle, config)
                    end

                    -- Prepare dummy states table for dynamic shader strobing (0..47)
                    local states = {}
                    for i = 0, 47 do
                        states[i] = 0.0
                    end
                    local anyDummyActive = false

                    if scanned and scanned.dummies then
                        local vMatrix = getElementMatrix(vehicle)
                        if vMatrix then
                            -- Extract vehicle world orientation vectors
                            local vRightX, vRightY, vRightZ = vMatrix[1][1], vMatrix[1][2], vMatrix[1][3]
                            local vFwdX, vFwdY, vFwdZ = vMatrix[2][1], vMatrix[2][2], vMatrix[2][3]

                            -- Check if ground reflections are active for this vehicle
                            local allowShadows = globalShadowsEnabled and (getElementData(vehicle, "avs:shadows") ~= false) and (distToCam <= 80.0)

                            for dummyId, dummyConfig in pairs(stateData.dummies) do
                                -- Check if this dummy is active in the current millisecond slice
                                local isActive = AVSSequencer.isPatternActive(
                                    dummyConfig.pattern,
                                    dummyConfig.patternTotal,
                                    dummyConfig.initialState,
                                    now
                                )

                                local numId = tonumber(dummyId)
                                if isActive then
                                    anyDummyActive = true
                                    if numId and numId >= 0 and numId <= 47 then
                                        states[numId] = 1.0
                                    end
                                end

                                if isActive then
                                    local compInfo = scanned.dummies[dummyId]
                                    if compInfo then
                                        -- Get exact world coordinates of this dummy
                                        local wx, wy, wz = getVehicleComponentPosition(vehicle, compInfo.name, "world")
                                        if wx then
                                            local dx = camX - wx
                                            local dy = camY - wy
                                            local dz = camZ - wz
                                            local dLen = math.sqrt(dx * dx + dy * dy + dz * dz)
                                            if dLen < 0.1 then dLen = 0.1 end

                                            local toCam = { x = dx / dLen, y = dy / dLen, z = dz / dLen }

                                            -- Compute world-space forward vector of the light beam
                                            local lightAngle = compInfo.angle or 0
                                            if dummyConfig.sirenType == "rotator" then
                                                local rotAngle = AVSSequencer.getRotatorAngle(dummyConfig.rotator, now)
                                                lightAngle = (lightAngle + rotAngle) % 360
                                            end

                                            local rad = math.rad(lightAngle)
                                            local sinR, cosR = math.sin(rad), math.cos(rad)
                                            local lFwdX = -sinR * vRightX + cosR * vFwdX
                                            local lFwdY = -sinR * vRightY + cosR * vFwdY
                                            local lFwdZ = -sinR * vRightZ + cosR * vFwdZ
                                            local lightFwd = { x = lFwdX, y = lFwdY, z = lFwdZ }

                                            -- Directional line-of-sight factor
                                            local dirFactor = AVSSequencer.computeDirectionalFactor(
                                                dummyConfig.sirenType,
                                                lightFwd,
                                                toCam,
                                                dummyConfig.radius
                                            )

                                            local col = dummyConfig.color
                                            local baseA = col.a or 180

                                            -----------------------------------------------------------------
                                            -- 1. 3D Billboarded Corona Flares (Pure Lua Engine)
                                            -----------------------------------------------------------------
                                            if not nativeHandlesCoronas and dirFactor > 0.02 then
                                                local alpha = math.floor(baseA * dirFactor)
                                                local sz = (dummyConfig.size or 0.25) * 2.2
                                                local halfSz = sz * 0.5

                                                -- Apply slight camera bias (0.06m) so corona renders cleanly outside lens glass
                                                local bx = wx + toCam.x * 0.06
                                                local by = wy + toCam.y * 0.06
                                                local bz = wz + toCam.z * 0.06

                                                -- 3D billboarded corona flare
                                                dxDrawMaterialLine3D(
                                                    bx, by, bz - halfSz,
                                                    bx, by, bz + halfSz,
                                                    coronaTexture,
                                                    sz,
                                                    tocolor(col.r, col.g, col.b, alpha)
                                                )

                                                -- Super-bright hot white core flare when looking directly down the beam
                                                if dirFactor > 0.65 then
                                                    local coreFrac = (dirFactor - 0.65) / 0.35
                                                    local coreSz = sz * 0.45
                                                    local coreA = math.floor(255 * coreFrac)
                                                    dxDrawMaterialLine3D(
                                                        bx, by, bz - coreSz * 0.5,
                                                        bx, by, bz + coreSz * 0.5,
                                                        coronaTexture,
                                                        coreSz,
                                                        tocolor(255, 255, 255, coreA)
                                                    )
                                                end
                                            end

                                            -----------------------------------------------------------------
                                            -- 2. Dynamic Ground / Road Reflections (AVS Shadow Projections)
                                            -----------------------------------------------------------------
                                            if allowShadows and dummyConfig.shadow and dirFactor > 0.04 then
                                                local sh = dummyConfig.shadow
                                                local shType = tonumber(sh.type) or 0
                                                local shOffset = tonumber(sh.offset) or 0.5
                                                local shSize = (tonumber(sh.size) or 1.0) * 2.4
                                                local shTex = getShadowTexture(shType)

                                                if shTex then
                                                    -- Calculate projection center along the light's horizontal forward vector
                                                    local projX = wx + lFwdX * shOffset
                                                    local projY = wy + lFwdY * shOffset
                                                    local projZ = wz

                                                    -- Raycast downward to locate exact road surface
                                                    local hit, hx, hy, hz = processLineOfSight(
                                                        projX, projY, projZ + 0.4,
                                                        projX, projY, projZ - 4.5,
                                                        true, false, false, true, false, false, false, false, vehicle
                                                    )

                                                    local groundZ = hit and (hz + 0.035) or (vz - 0.65)
                                                    local groundDist = math.abs(projZ - groundZ)

                                                    if groundDist <= 4.5 then
                                                        local distFalloff = math.max(0.0, 1.0 - (groundDist / 4.5))
                                                        local shAlpha = math.floor(baseA * dirFactor * distFalloff * 0.95)

                                                        if shAlpha > 8 then
                                                            local halfSz = shSize * 0.5
                                                            local sX = projX - lFwdX * halfSz
                                                            local sY = projY - lFwdY * halfSz
                                                            local eX = projX + lFwdX * halfSz
                                                            local eY = projY + lFwdY * halfSz

                                                            -- Render flat horizontal quad oriented along light direction
                                                            dxDrawMaterialLine3D(
                                                                sX, sY, groundZ,
                                                                eX, eY, groundZ,
                                                                shTex,
                                                                shSize,
                                                                tocolor(col.r, col.g, col.b, shAlpha),
                                                                false,
                                                                projX, projY, groundZ + 10.0
                                                            )
                                                        end
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end

                    -- Update dynamic shader strobe state for this vehicle
                    if vehicleShaders[vehicle] then
                        local globalPulse = anyDummyActive and 1.0 or 0.0
                        for _, shader in pairs(vehicleShaders[vehicle]) do
                            if isElement(shader) then
                                dxSetShaderValue(shader, "gStateA",
                                    states[0], states[1], states[2], states[3],
                                    states[4], states[5], states[6], states[7],
                                    states[8], states[9], states[10], states[11],
                                    states[12], states[13], states[14], states[15]
                                )
                                dxSetShaderValue(shader, "gStateB",
                                    states[16], states[17], states[18], states[19],
                                    states[20], states[21], states[22], states[23],
                                    states[24], states[25], states[26], states[27],
                                    states[28], states[29], states[30], states[31]
                                )
                                dxSetShaderValue(shader, "gStateC",
                                    states[32], states[33], states[34], states[35],
                                    states[36], states[37], states[38], states[39],
                                    states[40], states[41], states[42], states[43],
                                    states[44], states[45], states[46], states[47]
                                )
                                dxSetShaderValue(shader, "gGlobalOn", globalPulse)
                            end
                        end
                    end
                end
            end
        else
            activeVehicles[vehicle] = nil
            detachVehicleShaders(vehicle)
        end
    end
end

-- Render in onClientRender so coronas and reflections are drawn on top of vehicle lenses
addEventHandler("onClientRender", root, onRenderPulse)

-- Attach unlit shaders when emergency vehicles stream in so they never display raw cyan vertex diffuse
addEventHandler("onClientElementStreamIn", root, function()
    if getElementType(source) == "vehicle" then
        local model = getElementModel(source)
        if vehicleTexturePairs[model] then
            attachVehicleShaders(source)
        end
    end
end)

-- Clean up shaders on vehicle destruction or streaming out
addEventHandler("onClientElementDestroy", root, function()
    if getElementType(source) == "vehicle" then
        detachVehicleShaders(source)
        activeVehicles[source] = nil
    end
end)

-- Note: When streaming out, hide/destroy shaders to release GPU state
addEventHandler("onClientElementStreamOut", root, function()
    if getElementType(source) == "vehicle" then
        detachVehicleShaders(source)
    end
end)

-- Handle vehicle model change (e.g. skin/mod reloads)
addEventHandler("onClientElementModelChange", root, function(oldModel, newModel)
    if getElementType(source) == "vehicle" then
        detachVehicleShaders(source)
        if vehicleTexturePairs[newModel] then
            attachVehicleShaders(source)
        end
    end
end)

-- Initialize all currently streamed-in vehicles on resource start
addEventHandler("onClientResourceStart", resourceRoot, function()
    for _, veh in ipairs(getElementsByType("vehicle", root, true)) do
        local model = getElementModel(veh)
        if vehicleTexturePairs[model] then
            attachVehicleShaders(veh)
        end
    end
end)

-- Clean up all shaders on resource stop
addEventHandler("onClientResourceStop", resourceRoot, function()
    for veh, _ in pairs(vehicleShaders) do
        detachVehicleShaders(veh)
    end
end)
