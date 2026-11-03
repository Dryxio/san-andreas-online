--[[
    Advanced Vehicle Sirens (AVS) - Client Model & Config Loader
    
    Loads JSON manifests and registers model configurations:
    - Registers models with the native C++ AVS engine (registerVehicleSirenModel)
    - Imports and replaces emergency vehicle DFFs and TXDs
    - Exposes dynamic registration for external resources
]]

local vehicleCatalog = {
    { model = 407, name = "Firetruck",          dff = "models/firetruk.dff", txd = "models/firetruk.txd", config = "configs/407.json" },
    { model = 416, name = "Ambulance",          dff = "models/ambulan.dff",  txd = "models/ambulan.txd",  config = "configs/416.json" },
    { model = 426, name = "Premier (Unmarked)", dff = "models/premier.dff",  txd = "models/premier.txd",  config = "configs/426.json" },
    { model = 427, name = "Enforcer",           dff = "models/enforcer.dff", txd = "models/enforcer.txd", config = "configs/427.json" },
    { model = 445, name = "Admiral (Unmarked)", dff = "models/admiral.dff",  txd = "models/admiral.txd",  config = "configs/445.json" },
    { model = 490, name = "FBI Rancher",        dff = "models/fbiranch.dff", txd = "models/fbiranch.txd", config = "configs/490.json" },
    { model = 523, name = "HPV-1000 Police Bike", config = "configs/523.json" },
    { model = 525, name = "Towtruck",           dff = "models/towtruck.dff", txd = "models/towtruck.txd", config = "configs/525.json" },
    { model = 528, name = "FBI Truck",          dff = "models/fbitruck.dff", txd = "models/fbitruck.txd", config = "configs/528.json" },
    { model = 554, name = "Yosemite (DOT)",     dff = "models/yosemite.dff", txd = "models/yosemite.txd", config = "configs/554.json" },
    { model = 578, name = "DFT-30 (DOT)",       dff = "models/dft30.dff",    txd = "models/dft30.txd",    config = "configs/578.json" },
    { model = 596, name = "Police Car (LS)",    dff = "models/copcarla.dff", txd = "models/copcarla.txd", config = "configs/596.json" },
    { model = 597, name = "Police Car (SF)",    dff = "models/copcarsf.dff", txd = "models/copcarsf.txd", config = "configs/597.json" },
    { model = 598, name = "Police Car (LV)",    dff = "models/copcarvg.dff", txd = "models/copcarvg.txd", config = "configs/598.json" },
    { model = 599, name = "Police Ranger (Rural)", dff = "models/copcarru.dff", txd = "models/copcarru.txd", config = "configs/599.json" },
}

addEventHandler("onClientResourceStart", resourceRoot, function()
    local loadedCount = 0

    -- Preload shadow texture dictionary (shadows256.txd) for ground reflections
    if fileExists("assets/shadows256.txd") then
        local shadowTxd = engineLoadTXD("assets/shadows256.txd")
        if shadowTxd then
            outputDebugString("[AVS] Loaded ground light reflection texture library (shadows256.txd)", 3)
        end
    end

    for _, entry in ipairs(vehicleCatalog) do
        local modelId = entry.model

        -- 1. Load vehicle textures (TXD) and geometry (DFF) if provided
        if entry.txd and entry.dff and fileExists(entry.txd) and fileExists(entry.dff) then
            local txd = engineLoadTXD(entry.txd)
            if txd then
                engineImportTXD(txd, modelId)
            end
            local dff = engineLoadDFF(entry.dff)
            if dff then
                engineReplaceModel(dff, modelId)
            end
        end

        -- 2. Load JSON manifest and register with native C++ engine
        if entry.config and fileExists(entry.config) then
            local hFile = fileOpen(entry.config, true)
            if hFile then
                local size = fileGetSize(hFile)
                local content = fileRead(hFile, size)
                fileClose(hFile)

                if type(registerVehicleSirenModel) == "function" then
                    local success = registerVehicleSirenModel(modelId, content)
                    if success then
                        loadedCount = loadedCount + 1
                    else
                        outputDebugString("[AVS] Native C++ engine failed to register config for model " .. tostring(modelId), 2)
                    end
                end

                -- Fallback / complementary parser registration
                if AVSParser and AVSRenderer then
                    local parsed, err = AVSParser.parse(content)
                    if parsed then
                        AVSRenderer.registerModelConfig(modelId, parsed)
                    end
                end
            end
        end
    end

    outputDebugString(string.format("[AVS] Successfully initialized %d emergency vehicle configurations.", loadedCount), 3)
end)

-- Receive dynamic model registrations from server or other resources
addEvent("avs:registerModelConfig", true)
addEventHandler("avs:registerModelConfig", root, function(modelId, jsonStringOrTable)
    modelId = tonumber(modelId)
    if not modelId then return end

    local jsonString = nil
    if type(jsonStringOrTable) == "string" then
        jsonString = jsonStringOrTable
    elseif type(jsonStringOrTable) == "table" and toJSON then
        jsonString = toJSON(jsonStringOrTable)
    end

    if jsonString and type(registerVehicleSirenModel) == "function" then
        registerVehicleSirenModel(modelId, jsonString)
    end

    if AVSParser and AVSRenderer and jsonString then
        local parsed = AVSParser.parse(jsonString)
        if parsed then
            AVSRenderer.registerModelConfig(modelId, parsed)
        end
    end
end)
