-- CREATE_CHAR creates mission peds, not ambient population. Replicate that
-- classification independently of task ownership, including late observers.
local marker = "storyWorldRuntime:scmPed"
local previous = {}

local function apply(ped)
    if not isElement(ped) or getElementType(ped) ~= "ped" then return end
    if getElementData(ped, marker) == true then
        if previous[ped] == nil then previous[ped] = isPedMissionActor(ped) end
        if not setPedMissionActor(ped, true) then
            outputDebugString("[story world runtime] SCM mission actor classification refused", 1)
        end
    elseif previous[ped] ~= nil then
        setPedMissionActor(ped, previous[ped])
        previous[ped] = nil
    end
end

addEventHandler("onClientElementDataChange", root, function(key)
    if key == marker then apply(source) end
end)
addEventHandler("onClientElementStreamIn", root, function() apply(source) end)
addEventHandler("onClientResourceStart", resourceRoot, function()
    for _, ped in ipairs(getElementsByType("ped")) do apply(ped) end
end)
addEventHandler("onClientElementDestroy", root, function() previous[source] = nil end)
addEventHandler("onClientResourceStop", resourceRoot, function()
    for ped, value in pairs(previous) do
        if isElement(ped) then setPedMissionActor(ped, value) end
    end
    previous = {}
end)
