--[[
    Advanced Vehicle Sirens (AVS) - Client Sequencer & Math Engine
    
    Computes:
    - On/Off state slices from millisecond pattern arrays
    - Rotator beam angles
    - Directional light intensity and camera line-of-sight attenuation
]]

AVSSequencer = {}

-- Determine whether a pattern is active at timestamp nowMs
function AVSSequencer.isPatternActive(expandedPattern, patternTotal, initialState, nowMs)
    if not expandedPattern or #expandedPattern == 0 or patternTotal <= 0 then
        return initialState
    end

    local elapsed = nowMs % patternTotal
    local currentState = initialState
    local accumulated = 0

    for i = 1, #expandedPattern do
        local dur = expandedPattern[i]
        if dur > 0 then
            if elapsed < accumulated + dur then
                return currentState
            end
            accumulated = accumulated + dur
        end
        currentState = not currentState
    end

    return currentState
end

-- Compute rotator angle in degrees [0..360) at timestamp nowMs
function AVSSequencer.getRotatorAngle(rotatorConfig, nowMs)
    if not rotatorConfig then return 0 end
    local duration = rotatorConfig.time or 1000
    if duration <= 0 then duration = 1000 end
    local elapsed = nowMs % duration
    local progress = elapsed / duration
    local sweep = rotatorConfig.radius or 360.0
    local angle = progress * sweep

    if rotatorConfig.direction == "counter-clockwise" then
        angle = 360.0 - angle
    end
    angle = (angle + (rotatorConfig.offset or 0)) % 360
    return angle
end

-- Compute directional visibility multiplier [0..1]
-- lightFwd: 3D normalized forward vector of the light in world space
-- toCam: 3D normalized vector from light to camera
function AVSSequencer.computeDirectionalFactor(sirenType, lightFwd, toCam, coneDegrees)
    if sirenType == "non-directional" then
        return 1.0
    end

    local fwdX, fwdY, fwdZ = lightFwd.x, lightFwd.y, lightFwd.z
    if sirenType == "inversed" then
        fwdX, fwdY, fwdZ = -fwdX, -fwdY, -fwdZ
    end

    -- Dot product between light forward and vector to camera
    local dot = fwdX * toCam.x + fwdY * toCam.y + fwdZ * toCam.z

    local halfCone = (coneDegrees or 180.0) * 0.5
    local minDot = math.cos(math.rad(halfCone))

    if dot < minDot then
        return 0.0
    end

    -- Smooth cosine falloff from center (dot=1.0) to edge of cone (dot=minDot)
    local normalized = (dot - minDot) / math.max(0.001, (1.0 - minDot))
    return math.max(0.0, math.min(1.0, normalized * normalized))
end
