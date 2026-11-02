--[[
    Advanced Vehicle Sirens (AVS) - Client Model & Config Loader
    
    Loads JSON manifests and registers model configurations:
    - Automatically parses configs/554.json on resource startup
    - Imports and replaces preview vehicle DFF/TXD (Yosemite / Ford F-250)
    - Exposes dynamic registration for external resources
]]

addEventHandler("onClientResourceStart", resourceRoot, function()
    -- Initialize corona renderer texture
    AVSRenderer.init()

    -- 1. Load preview Yosemite (model 554) textures and DFF
    if fileExists("models/yosemite.txd") and fileExists("models/yosemite.dff") then
        local txd = engineLoadTXD("models/yosemite.txd")
        if txd then
            engineImportTXD(txd, 554)
        end
        local dff = engineLoadDFF("models/yosemite.dff")
        if dff then
            engineReplaceModel(dff, 554)
        end
    end

    -- 2. Load 554.json config manifest
    if fileExists("configs/554.json") then
        local hFile = fileOpen("configs/554.json", true)
        if hFile then
            local size = fileGetSize(hFile)
            local content = fileRead(hFile, size)
            fileClose(hFile)

            local parsed, err = AVSParser.parse(content)
            if parsed then
                AVSRenderer.registerModelConfig(554, parsed)
                outputDebugString("[AVS] Successfully registered siren manifest for model 554 with " ..
                    tostring(#parsed.stateOrder) .. " states.", 3)
            else
                outputDebugString("[AVS] Error parsing configs/554.json: " .. tostring(err), 1)
            end
        end
    end
end)

-- Receive dynamic model registrations from server or other resources
addEvent("avs:registerModelConfig", true)
addEventHandler("avs:registerModelConfig", root, function(modelId, jsonStringOrTable)
    local parsed = nil
    if type(jsonStringOrTable) == "string" then
        parsed = AVSParser.parse(jsonStringOrTable)
    elseif type(jsonStringOrTable) == "table" then
        if jsonStringOrTable.states and jsonStringOrTable.stateOrder then
            parsed = jsonStringOrTable
        else
            parsed = AVSParser.parse(jsonStringOrTable)
        end
    end

    if parsed and tonumber(modelId) then
        AVSRenderer.registerModelConfig(tonumber(modelId), parsed)
    end
end)
