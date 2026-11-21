-- A render callback shows that this downloaded Lua chunk ran in the game loop.
local function firstFrame()
    removeEventHandler("onClientRender", root, firstFrame)
    triggerServerEvent("androidSessionTest:firstFrame", resourceRoot)
    outputChatBox("Neon Android session test: client resource running.")
end

addEventHandler("onClientResourceStart", resourceRoot, function()
    addEventHandler("onClientRender", root, firstFrame)
end)

local function liveFrame()
    removeEventHandler("onClientRender", root, liveFrame)
    triggerServerEvent("androidSessionTest:liveFrame", resourceRoot)
end

addEvent("androidSessionTest:checkFrame", true)
addEventHandler("androidSessionTest:checkFrame", resourceRoot, function()
    addEventHandler("onClientRender", root, liveFrame)
end, false)
