--[[
    Advanced Vehicle Sirens (AVS) - Shared JSON Configuration Parser
    
    Parses AVS specification JSON manifests:
    - Resolves references and palette color names
    - Expands repetition cycles in pattern timing arrays
    - Organizes states and material dummies into optimized runtime tables
    - Strictly data-driven: no hardcoded models, offsets, or colors
]]

AVSParser = {}

-- Expand pattern definitions supporting repetition count arrays:
-- e.g. [ [2, 600, 600] ] -> [600, 600, 600, 600]
-- e.g. [ 0, 100, 300 ]   -> [0, 100, 300]
local function expandPattern(rawPattern)
    local result = {}
    if type(rawPattern) ~= "table" then
        return { 500, 500 }
    end

    for _, entry in ipairs(rawPattern) do
        if type(entry) == "table" then
            local count = tonumber(entry[1]) or 1
            local segment = {}
            for i = 2, #entry do
                segment[#segment + 1] = tonumber(entry[i]) or 500
            end
            if #segment == 0 then
                segment = { 500, 500 }
            end
            for _ = 1, count do
                for _, dur in ipairs(segment) do
                    result[#result + 1] = dur
                end
            end
        elseif type(entry) == "number" then
            result[#result + 1] = math.floor(entry)
        end
    end

    if #result == 0 then
        result = { 500, 500 }
    end
    return result
end

-- Resolve RGBA color table from either string reference, hex, or inline object
local function resolveColor(rawColor, colorPalette)
    if type(rawColor) == "string" then
        local found = colorPalette and colorPalette[rawColor]
        if found then
            return resolveColor(found, colorPalette)
        end
        -- Check hex format #RRGGBB or #RRGGBBAA
        local hex = rawColor:gsub("#", "")
        if #hex == 6 or #hex == 8 then
            local r = tonumber(hex:sub(1, 2), 16) or 255
            local g = tonumber(hex:sub(3, 4), 16) or 255
            local b = tonumber(hex:sub(5, 6), 16) or 255
            local a = (#hex == 8) and (tonumber(hex:sub(7, 8), 16) or 255) or 255
            return { r = r, g = g, b = b, a = a }
        end
    elseif type(rawColor) == "table" then
        local r = tonumber(rawColor.red or rawColor.r or rawColor[1]) or 255
        local g = tonumber(rawColor.green or rawColor.g or rawColor[2]) or 255
        local b = tonumber(rawColor.blue or rawColor.b or rawColor[3]) or 255
        local a = tonumber(rawColor.alpha or rawColor.a or rawColor[4]) or 180
        return {
            r = math.max(0, math.min(255, r)),
            g = math.max(0, math.min(255, g)),
            b = math.max(0, math.min(255, b)),
            a = math.max(0, math.min(255, a)),
        }
    end
    return { r = 255, g = 255, b = 255, a = 180 }
end

function AVSParser.parse(jsonInput)
    local root = nil
    if type(jsonInput) == "string" then
        root = fromJSON(jsonInput)
    elseif type(jsonInput) == "table" then
        root = jsonInput
    end

    if type(root) ~= "table" then
        return nil, "Invalid JSON data"
    end

    local references = root.references or {}
    local colorPalette = references.colors or {}

    local parsed = {
        references = references,
        colors = colorPalette,
        states = {},       -- Map: stateName -> stateData
        stateOrder = {},   -- Array of state names for cycling
    }

    local rawStates = root.states
    if not rawStates or type(rawStates) ~= "table" then
        rawStates = {}
        for k, v in pairs(root) do
            if k ~= "references" and k ~= "streamDistance" and k ~= "inertia" and k ~= "inertiaAngle" and k ~= "flare" and k ~= "flareDistance" and type(v) == "table" then
                rawStates[k] = v
            end
        end
    end
    for stateName, stateDummies in pairs(rawStates) do
        parsed.stateOrder[#parsed.stateOrder + 1] = tostring(stateName)
        local dummiesMap = {}

        if type(stateDummies) == "table" then
            for dummyKey, rawDummy in pairs(stateDummies) do
                local dummyId = tonumber(dummyKey) or dummyKey
                if type(rawDummy) == "table" then
                    -- Merge referenced templates (e.g. "reference": "strobe")
                    local merged = {}
                    local refKey = rawDummy.reference
                    if type(refKey) == "string" and references[refKey] then
                        for k, v in pairs(references[refKey]) do
                            merged[k] = v
                        end
                    elseif type(refKey) == "table" then
                        for _, singleRef in ipairs(refKey) do
                            if type(singleRef) == "string" and references[singleRef] then
                                for k, v in pairs(references[singleRef]) do
                                    merged[k] = v
                                end
                            end
                        end
                    end
                    -- Override with explicitly specified dummy properties
                    for k, v in pairs(rawDummy) do
                        merged[k] = v
                    end

                    -- Resolve final color
                    local color = resolveColor(merged.color, colorPalette)

                    -- Expand flash timing pattern
                    local pattern = expandPattern(merged.pattern)
                    local patternTotal = 0
                    for _, dur in ipairs(pattern) do
                        patternTotal = patternTotal + dur
                    end

                    -- Parse rotator configuration if present
                    local rotator = nil
                    if merged.rotator and type(merged.rotator) == "table" then
                        rotator = {
                            direction = merged.rotator.direction or "clockwise",
                            type = merged.rotator.type or "linear",
                            time = tonumber(merged.rotator.time) or 1000,
                            offset = tonumber(merged.rotator.offset) or 0.0,
                            radius = tonumber(merged.rotator.radius) or 360.0,
                        }
                    end

                    -- Type: directional, non-directional, inversed, rotator
                    local sirenType = tostring(merged.type or (rotator and "rotator" or "directional")):lower()

                    dummiesMap[dummyId] = {
                        id = dummyId,
                        color = color,
                        size = tonumber(merged.size) or 0.25,
                        radius = tonumber(merged.radius) or 180.0, -- visibility arc in degrees
                        pattern = pattern,
                        patternTotal = patternTotal,
                        initialState = (merged.state == 1 or merged.state == true),
                        sirenType = sirenType,
                        rotator = rotator,
                        diffuse = merged.diffuse,
                        shadow = merged.shadow,
                    }
                end
            end
        end

        parsed.states[tostring(stateName)] = {
            name = tostring(stateName),
            dummies = dummiesMap,
        }
    end

    -- Sort stateOrder for consistent cycling (e.g. 1.Emergency -> 2. Right -> 3. Left)
    table.sort(parsed.stateOrder, function(a, b)
        return tostring(a) < tostring(b)
    end)

    return parsed
end
