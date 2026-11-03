--[[
    Advanced Vehicle Sirens (AVS) - Client Component Scanner
    
    Dynamically scans vehicle 3D model (DFF) hierarchies for siren dummies:
    - Matches naming conventions: 'siren_X', 'sirenX', 'light_emX'
    - Caches component names and base angles per vehicle instance
    - Zero hardcoded vehicle component tables or fixed offsets
]]

AVSScanner = {}
local vehicleCache = {}

-- Extract numeric dummy ID from component name:
-- e.g. "siren_1" -> 1, "siren42" -> 42, "light_em5" -> 5
local function extractDummyId(compName)
    local lower = compName:lower()
    local idStr = lower:match("^siren_?(%d+)$") or lower:match("^light_em(%d+)$")
    if idStr then
        return tonumber(idStr)
    end
    return nil
end

function AVSScanner.scanVehicle(vehicle, modelConfig)
    if not isElement(vehicle) or not modelConfig then
        return nil
    end

    local components = getVehicleComponents(vehicle)
    if not components or type(components) ~= "table" then
        return nil
    end

    local dummies = {}
    local count = 0

    for compName, _ in pairs(components) do
        local id = extractDummyId(compName)
        if id then
            local rx, ry, rz = getVehicleComponentRotation(vehicle, compName, "root")
            dummies[id] = {
                name = compName,
                angle = rz or 0,
            }
            count = count + 1
        end
    end

    local record = {
        vehicle = vehicle,
        model = getElementModel(vehicle),
        dummies = dummies,
        dummyCount = count,
    }
    vehicleCache[vehicle] = record
    return record
end

function AVSScanner.getScannedVehicle(vehicle)
    return vehicleCache[vehicle]
end

function AVSScanner.clearVehicle(vehicle)
    vehicleCache[vehicle] = nil
end

addEventHandler("onClientElementDestroy", root, function()
    if getElementType(source) == "vehicle" then
        AVSScanner.clearVehicle(source)
    end
end)

addEventHandler("onClientElementStreamOut", root, function()
    if getElementType(source) == "vehicle" then
        AVSScanner.clearVehicle(source)
    end
end)
