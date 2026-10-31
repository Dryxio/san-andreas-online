-- Checks createWater's water.dat flags (issue #3).
--   /waterflags <0-3>  puts a 30x30 m sheet of water 10 m above you
--   /waterflags        removes it
-- The surface is 10 m above your feet, more than the 6 m SA allows under
-- shallow water, so:
--   0  invisible, bottomless  you are underwater, nothing drawn above you
--   1  visible, bottomless    you are underwater under a visible surface
--   2  invisible, shallow     you stay dry, nothing drawn
--   3  visible, shallow       you stay dry under a visible "pool" surface
-- Also try it outside the city at sea level, where flag 3 should still be
-- swimmable within a few metres of the surface.
local sheets = {}

local function clear(player)
    if isElement(sheets[player]) then destroyElement(sheets[player]) end
    sheets[player] = nil
end

addCommandHandler("waterflags", function(player, _, arg)
    clear(player)
    if not arg then
        outputChatBox("[Water flags] removed", player, 255, 200, 0)
        return
    end
    local x, y, z = getElementPosition(player)
    local level = z + 10
    -- Accepts the number as typed, so /waterflags 4 shows the error path.
    local water = createWater(x - 15, y - 15, level, x + 15, y - 15, level, x - 15, y + 15, level, x + 15, y + 15, level, tonumber(arg))
    sheets[player] = water or nil
    outputChatBox(("[Water flags] flags=%s at z=%.1f: %s"):format(arg, level, water and "created" or "refused"), player, 255, 200, 0)
end)

addEventHandler("onPlayerQuit", root, function() clear(source) end)

-- Argument parsing checks that need no player.
addEventHandler("onResourceStart", resourceRoot, function()
    local results = {}
    local function check(name, ok)
        results[#results + 1] = name .. "=" .. (ok and "ok" or "FAIL")
    end
    -- Triangle followed by a number must stay a triangle, not become a quad.
    local tri = createWater(0, 0, 5, 20, 0, 5, 10, 20, 5, 3)
    check("triangle+flags", tri ~= false)
    if tri then destroyElement(tri) end
    -- The old bool still works.
    local legacy = createWater(0, 0, 5, 20, 0, 5, 0, 20, 5, 20, 20, 5, true)
    check("legacy bool", legacy ~= false)
    if legacy then destroyElement(legacy) end
    -- Out-of-range flags are refused.
    check("flags 4 refused", createWater(0, 0, 5, 20, 0, 5, 0, 20, 5, 20, 20, 5, 4) == false)
    outputServerLog("[water-flags-test] " .. table.concat(results, " "))
end)
