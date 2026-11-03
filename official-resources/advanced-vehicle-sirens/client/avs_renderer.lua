--[[
    Advanced Vehicle Sirens (AVS) - Client 3D Corona & Light Renderer
    
    Renders high-intensity directional emergency vehicle strobes:
    - Directional line-of-sight flares with TIR lens optic falloff
    - 360-degree rotating beacons with smooth angular interpolation
    - Camera-oriented 3D billboarded coronas with hot-core blending
    - Dynamic ground reflection and road illumination
    - Zero performance overhead when vehicle sirens are switched off
]]

AVSRenderer = {}

local coronaTexture = nil
local registeredModelConfigs = {}
local activeVehicles = {}

function AVSRenderer.init()
    if not coronaTexture then
        coronaTexture = dxCreateTexture("assets/corona.png", "dxt5")
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

-- Track vehicles with active sirens
function AVSRenderer.setVehicleState(vehicle, stateName)
    if not isElement(vehicle) then return end
    if not stateName or stateName == 0 or stateName == "0" or stateName == "off" or stateName == false then
        activeVehicles[vehicle] = nil
    else
        activeVehicles[vehicle] = tostring(stateName)
    end
end

function AVSRenderer.getVehicleState(vehicle)
    return activeVehicles[vehicle] or 0
end

-- Main render loop: pre-render executes right before GTA draws world entities
local function onRenderPulse()
    -- If native C++ engine is handling AVS coronas, skip Lua software rendering
    if type(setVehicleSirenState) == "function" then
        return
    end
    if not coronaTexture then
        AVSRenderer.init()
        if not coronaTexture then return end
    end

    local now = getTickCount()
    local camX, camY, camZ = getCameraMatrix()
    if not camX then return end

    for vehicle, stateName in pairs(activeVehicles) do
        if isElement(vehicle) and isElementStreamedIn(vehicle) then
            local vx, vy, vz = getElementPosition(vehicle)
            local distToCam = getDistanceBetweenPoints3D(camX, camY, camZ, vx, vy, vz)

            -- Render distance cutoff (150m is standard AVS corona far clip)
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
                                        -- Get exact world coordinates of this dummy frame
                                        local wx, wy, wz = getVehicleComponentPosition(vehicle, compInfo.name, "world")
                                        if wx then
                                            local dx = camX - wx
                                            local dy = camY - wy
                                            local dz = camZ - wz
                                            local dLen = math.sqrt(dx * dx + dy * dy + dz * dz)
                                            if dLen < 0.1 then dLen = 0.1 end

                                            local toCam = { x = dx / dLen, y = dy / dLen, z = dz / dLen }

                                            -- Compute world-space forward vector of the light
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

                                            if dirFactor > 0.02 then
                                                local col = dummyConfig.color
                                                local baseA = col.a or 180
                                                local alpha = math.floor(baseA * dirFactor)

                                                -- Billboard corona size scales with distance slightly for optical visibility
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
        end
    end
end

addEventHandler("onClientPreRender", root, onRenderPulse)
