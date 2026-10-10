--- ME Network - AE2 Textures (issue #239): sets this mod's files in place of ME Network's, by prototype name, from the
--- table in overrides.lua. ME Network does not know this mod. One file (an icon, a layer, a sheet) is replaced by one
--- file; no image is put together here, and the layers of another origin around it stay as they are.
--- What cannot be applied (a prototype or a file that is not there) is skipped with a line in the log, so the game
--- still loads with ME Network's own graphics; devcheck fails on such a line.

local OVERRIDES = require("overrides")
local OWN = "__me-network__/"
local MOD = "__me-network-ae2-textures__/"

local function starts(s, prefix) return type(s) == "string" and s:sub(1, #prefix) == prefix end

local function say(key, text) log("me-network-ae2-textures: " .. key .. ": " .. text) end

--- every place in a prototype that names a file of ME Network: { {holder table, key, file} }
local function places_of(proto)
	local out, seen = {}, {}
	local function walk(t, depth)
		if depth > 16 or seen[t] then return end
		seen[t] = true
		for k, v in pairs(t) do
			if starts(v, OWN) then
				out[#out + 1] = { t, k, v }
			elseif type(v) == "table" then
				walk(v, depth + 1)
			end
		end
	end
	walk(proto, 0)
	return out
end

--- puts `new` (a file of this mod, or a table with `filename` and the sprite fields that differ) at every place of `old`
local function replace(key, places, old, new)
	local file = type(new) == "table" and new.filename or new
	if not starts(file, MOD) then
		say(key, "SKIPPED: " .. tostring(file) .. " is not a file of this mod (" .. MOD .. ")")
		return
	end
	local n = 0
	for _, p in pairs(places) do
		local holder, k, v = p[1], p[2], p[3]
		if v == old then
			if type(new) == "table" and type(k) ~= "string" then
				say(key, "SKIPPED: " .. old .. " is one of several file names of a sprite; give a file name only")
				return
			end
			holder[k] = file
			if type(new) == "table" then
				for field, value in pairs(new) do
					if field ~= "filename" then holder[field] = value end
				end
			end
			n = n + 1
		end
	end
	if n == 0 then
		say(key, "SKIPPED: " .. old .. " is not a file of this prototype")
	else
		say(key, old .. " -> " .. file .. " (" .. n .. (n == 1 and " place)" or " places)"))
	end
end

for key, value in pairs(OVERRIDES) do
	local kind, name = key:match("^([^/]+)/(.+)$")
	local proto = kind and data.raw[kind] and data.raw[kind][name]
	if not proto then
		say(key, "SKIPPED: no prototype of that type and name")
	else
		-- a copy of its own, so a table that ME Network shares between prototypes keeps its files elsewhere
		proto = table.deepcopy(proto)
		data.raw[kind][name] = proto
		local places = places_of(proto)
		if type(value) == "string" or (type(value) == "table" and value.filename) then
			local files = {}
			for _, p in pairs(places) do files[p[3]] = true end
			local list = {}
			for f in pairs(files) do list[#list + 1] = f end
			if #list == 1 then
				replace(key, places, list[1], value)
			else
				say(key, "SKIPPED: the prototype uses " .. #list .. " files of ME Network; name the one to replace")
			end
		elseif type(value) == "table" then
			for old, new in pairs(value) do
				if starts(old, OWN) then
					replace(key, places, old, new)
				else
					say(key, "SKIPPED: " .. tostring(old) .. " is not a file of ME Network (" .. OWN .. ")")
				end
			end
		else
			say(key, "SKIPPED: the value is neither a file name nor a table")
		end
	end
end

--- ME Network issue #264: the cells in the ME Drive's bays and the ME Chest's slot as AE2-Unofficial draws them
--- (RenderDrive.java, RenderMEChest.java): a piece of its cell textures in each bay that holds a cell, with the light in
--- it. ME Network draws them from its drive view (its docs/API.md), in px of the 64 px picture: here the places on this
--- mod's drive and chest (tools/ae2_blocks.py: AE2's 16 px face x3 at (3, 3)): AE2's bay (2 + 7 * column, 1 + 3 * row)
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
