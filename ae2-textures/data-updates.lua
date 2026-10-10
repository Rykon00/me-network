--- ME Network - AE2 Textures: the second data stage. ME Network issue #267 draws a drive's cells and lights as hidden
--- entities whose pictures its data-final-fixes.lua makes from the drive view (issue #278: the controller's state from
--- the controller view), so this mod sets the views here, before it (a mod's data-final-fixes.lua runs after every
--- data-updates.lua). ME Network does not know this mod.
local MOD = "__me-network-ae2-textures__/"
local function say(key, text) log("me-network-ae2-textures: " .. key .. ": " .. text) end
--- ME Network issue #264: the cells in the ME Drive's bays and the ME Chest's slot as AE2-Unofficial draws them
--- (RenderDrive.java, RenderMEChest.java): a piece of its cell textures in each bay that holds a cell, with the light in
--- it. ME Network draws them from its drive view (its docs/API.md; issue #267: set here, in data-updates), in px of the
--- 64 px picture: here the places on this mod's drive and chest (tools/ae2_blocks.py: AE2's 16 px face x3 at (3, 3)): AE2's bay (2 + 7 * column, 1 + 3 * row)
--- of the drive, its slot (5, 9) of the chest, the light (3, 1) and (4, 2) of a bay, one AE2 pixel.
local mod_data = data.raw["mod-data"]["fork-me-network"]
local view = mod_data and mod_data.data.drive_view
if view then                                                         -- (ME Network before 0.5.3 has none)
	local function px(v) return 3 + 3 * v end
	local cells = {}
	for _, n in pairs({ "drive-cell-item", "drive-cell-fluid", "chest-cell-item", "chest-cell-fluid" }) do
		local w, h = n:sub(1, 5) == "drive" and 15 or 18, n:sub(1, 5) == "drive" and 6 or 9
		cells[n] = MOD .. "graphics/blocks/cells/" .. n .. ".png"
		data:extend({ { type = "sprite", name = "me-network-ae2-textures-" .. n, filename = cells[n], priority = "high",
			width = w, height = h, scale = 0.5 } })
	end
	local bays = {}
	for row = 0, 4 do
		for column = 0, 1 do bays[#bays + 1] = { x = px(2 + 7 * column), y = px(1 + 3 * row) } end
	end
	view.drive = { bays = bays, light = { x = 9, y = 3, w = 3, h = 3 }, cells = { w = 15, h = 6,
		item = "me-network-ae2-textures-drive-cell-item", fluid = "me-network-ae2-textures-drive-cell-fluid" } }
	view.chest = { bays = { { x = px(5), y = px(9) } }, light = { x = 12, y = 6, w = 3, h = 3 }, cells = { w = 18, h = 9,
		item = "me-network-ae2-textures-chest-cell-item", fluid = "me-network-ae2-textures-chest-cell-fluid" } }
	say("drive view", "the cells of the ME Drive and the ME Chest at AE2's places")
end

--- ME Network issue #278: the ME Controller's state as AE2-Unofficial shows it (BlockController.java,
--- RenderBlockController.java): without power the dark block (the picture of overrides.lua), with power its lights run
--- through their 12 frames (3 Minecraft ticks each: 9 ticks here), in a conflict (a second controller) its red pattern.
--- ME Network draws them over the controller's picture from its controller view (its docs/API.md).
local cview = mod_data and mod_data.data.controller_view
if cview then                                                        -- (ME Network before 0.5.3 has none)
	local function block(name, extra)
		local a = { filename = MOD .. "graphics/blocks/" .. name .. ".png", priority = "high", width = 128, height = 128,
			scale = 0.5 }
		for k, v in pairs(extra or {}) do a[k] = v end
		return a
	end
	cview.on = block("me-controller-on", { frame_count = 12, line_length = 1, animation_speed = 1 / 9 })
	cview.conflict = block("me-controller-conflict")
	say("controller view", "AE2's controller lights and conflict pattern")
end
