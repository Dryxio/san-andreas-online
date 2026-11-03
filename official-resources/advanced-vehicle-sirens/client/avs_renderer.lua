--[[
    Advanced Vehicle Sirens (AVS) - Client 3D Corona, Texture Glow & Ground Shadow Renderer
    
    Provides 100% standalone AVS rendering for standard, unmodified MTA:SA:
    - Directional line-of-sight flares with TIR lens optic falloff
    - 360-degree rotating beacons with smooth angular interpolation
    - Camera-oriented 3D billboarded coronas with hot-core blending
    - Dynamic asphalt / ground reflection projections using 33 authentic AVS shadow optics
    - Automatic lightbar lens emissive glow shader on activation
    - Developer and player toggles for ground shadow reflections
    - Zero performance overhead when sirens are inactive
]]

AVSRenderer = {}

local coronaTexture = nil
local lightbarShader = nil
local registeredModelConfigs = {}
local activeVehicles = {}
local vehicleGlowApplied = {}

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

-- Common lightbar and beacon texture names across emergency vehicles
local lightbarTextureNames = {
    "sirenlight*",
    "sirenlight128*",
    "siren256*",
    "sirentow*",
    "vehiclelights*",
    "emerglights*",
    "sirenlights*",
    "siren64*",
    "siren32*",
    "siren12*",
    "sirennavlights*",
    "lightbar*",
    "arrow_sign*",
}

-- Lazy shadow texture loader
local function getShadowTexture(typeId)
    local id = tonumber(typeId) or 0
    if shadowTextures[id] ~= nil then
        return shadowTextures[id]
    end

    local texName = shadowTextureNames[id] or "arealight256"
    local filePath = "assets/shadows/" .. texName .. ".png"

    if fileExists(filePath) then
        local tex = dxCreateTexture(filePath, "dxt5")
        shadowTextures[id] = tex or false
        return tex
    end

    shadowTextures[id] = false
    return nil
end

function AVSRenderer.init()
    if not coronaTexture and fileExists("assets/corona.png") then
        coronaTexture = dxCreateTexture("assets/corona.png", "dxt5")
    end
    if not lightbarShader and fileExists("assets/lightbar_glow.fx") then
        lightbarShader = dxCreateShader("assets/lightbar_glow.fx", 0, 140.0, false, "vehicle")
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

-- Apply or remove lightbar emissive shader on a vehicle
local function updateVehicleLightbarShader(vehicle, active)
    if not lightbarShader or not isElement(vehicle) then return end

    if active then
        if not vehicleGlowApplied[vehicle] then
            for _, texName in ipairs(lightbarTextureNames) do
                engineApplyShaderToWorldTexture(lightbarShader, texName, vehicle)
            end
            vehicleGlowApplied[vehicle] = true
        end
    else
        if vehicleGlowApplied[vehicle] then
            for _, texName in ipairs(lightbarTextureNames) do
                engineRemoveShaderFromWorldTexture(lightbarShader, texName, vehicle)
            end
            vehicleGlowApplied[vehicle] = nil
        end
    end
end

-- Track vehicles with active sirens
function AVSRenderer.setVehicleState(vehicle, stateName)
    if not isElement(vehicle) then return end
    if not stateName or stateName == 0 or stateName == "0" or stateName == "off" or stateName == false then
        activeVehicles[vehicle] = nil
        updateVehicleLightbarShader(vehicle, false)
    else
        activeVehicles[vehicle] = tostring(stateName)
        updateVehicleLightbarShader(vehicle, true)
    end
end

function AVSRenderer.getVehicleState(vehicle)
    return activeVehicles[vehicle] or 0
end

-- Main render loop: pre-render executes right before GTA draws world entities
local function onRenderPulse()
    if not coronaTexture or not lightbarShader then
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

                if config and config.states and config.states[stateName] then
                    local stateData = config.states[stateName]
                    local scanned = AVSScanner.getScannedVehicle(vehicle)
                    if not scanned then
                        scanned = AVSScanner.scanVehicle(vehicle, config)
                    end

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

                                                -- 3D billboarded corona flare
                                                dxDrawMaterialLine3D(
                                                    wx, wy, wz - halfSz,
                                                    wx, wy, wz + halfSz,
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
                                                        wx, wy, wz - coreSz * 0.5,
                                                        wx, wy, wz + coreSz * 0.5,
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
                end
            end
        else
            activeVehicles[vehicle] = nil
            updateVehicleLightbarShader(vehicle, false)
        end
    end
end

addEventHandler("onClientPreRender", root, onRenderPulse)

-- Clean up on vehicle destruction or streaming out
addEventHandler("onClientElementDestroy", root, function()
    if getElementType(source) == "vehicle" then
        activeVehicles[source] = nil
        updateVehicleLightbarShader(source, false)
    end
end)

addEventHandler("onClientElementStreamOut", root, function()
    if getElementType(source) == "vehicle" then
        updateVehicleLightbarShader(source, false)
    end
end)
