--- Runtime test of me-network issue #129: the ME buses and the ME Terminal are walkable, like the ME cable.
--- A row of every block of the scope (import, export and storage bus in all four directions, the terminal, the three hidden
--- old fluid buses, and the cable and the underground cable as the reference that was walkable before) and of the blocks that
--- stay solid (ME Interface, drive, controller, pattern provider, level maintainer, circuit interface, a crafting block, the
--- Cell Workbench). On the position of each one a character can be placed, or not; nothing else can be built there: not a
--- chest, not a cable, not a bus (the "object" layer stays); no collision mask has the "player" layer, and the mask of the
--- walkable ones is the cable's, so the cars (whose mask names "player") pass too. The mask is prototype data: nothing is stored.
--- (The draw order, the character above a bus, needs the game.) Loaded by control.lua: require("walkable")(H) returns
--- { setup, tick, running } like lab.lua.

local BX, BY = -350, -250
local CHECK = 40

local DIRS = { north = defines.direction.north, east = defines.direction.east, south = defines.direction.south, west = defines.direction.west }

--- name, direction (nil: none), walkable
local ROW = {
	{ "me-import-bus", "north", true }, { "me-import-bus", "east", true }, { "me-import-bus", "south", true }, { "me-import-bus", "west", true },
	{ "me-export-bus", "north", true }, { "me-export-bus", "east", true }, { "me-export-bus", "south", true }, { "me-export-bus", "west", true },
	{ "me-storage-bus", "north", true }, { "me-storage-bus", "east", true }, { "me-storage-bus", "south", true }, { "me-storage-bus", "west", true },
	{ "me-terminal", nil, true },
	{ "me-fluid-import-bus", "south", true }, { "me-fluid-export-bus", "south", true }, { "me-fluid-storage-bus", "south", true },
	{ "me-cable", nil, true },
	{ "me-network-interface", nil, false }, { "me-drive", nil, false }, { "me-pattern-provider", nil, false },
	{ "me-level-maintainer", nil, false }, { "me-circuit-interface", nil, false }, { "me-crafting-unit", nil, false },
	{ "me-cell-workbench", nil, false },
}

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}

	local function pos(i) return { BX + 2 * i + 0.5, BY + 0.5 } end

	function T.setup(s)
		local fails = {}
		for i, def in ipairs(ROW) do
			--- (no build event for the old fluid buses: the unification would replace them; the others are registered like any block)
			local ok, e = pcall(function()
				return s.create_entity{ name = def[1], position = pos(i), force = "player", direction = def[2] and DIRS[def[2]] or nil,
					raise_built = not def[1]:find("^me%-fluid") }
			end)
			if not (ok and e) then fails[#fails + 1] = "walkable: " .. def[1] .. " was not built: " .. tostring(e) end
		end
		local ug = s.create_entity{ name = "me-underground-cable", position = pos(#ROW + 1), force = "player", direction = defines.direction.east,
			raise_built = true }
		if not ug then fails[#fails + 1] = "walkable: the underground cable was not built" end
		return fails
	end

	function T.tick()
		local st = storage.walkable129
		if st and st.done then return end
		if game.tick < CHECK then return end
		st = { problems = {}, done = true }
		storage.walkable129 = st
		local s = game.surfaces[1]
		local problems = st.problems
		local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
		local rows = {}
		for i, def in ipairs(ROW) do rows[i] = { def[1], def[2], def[3] } end
		rows[#rows + 1] = { "me-underground-cable", "east", true }
		local walkable_n, solid_n = 0, 0
		for i, def in ipairs(rows) do
			local name, dir, walkable = def[1], def[2], def[3]
			local label = name .. (dir and (" " .. dir) or "")
			local p = pos(i)
			local e = s.find_entities_filtered{ name = name, position = p, radius = 0.4 }[1]
			if not e then
				problems[#problems + 1] = label .. " is not there"
			else
				local mask = prototypes.entity[name].collision_mask.layers
				local stands = s.can_place_entity{ name = "character", position = p }
				if walkable then
					walkable_n = walkable_n + 1
					expect(mask.player == nil and mask.object and mask.item, label .. ": the mask of a walkable block must keep the object and item layers")
					expect(stands, "a character cannot stand on " .. label)
					--- nothing can be built on it: not a chest, not a cable, not a bus
					for _, other in pairs({ "iron-chest", "me-cable", "me-import-bus", "me-terminal" }) do
						expect(not s.can_place_entity{ name = other, position = p }, other .. " can be built on " .. label)
					end
					--- a car's mask names "player": it passes too
					expect(mask.player == nil and mask.car == nil and mask.train == nil, label .. ": a vehicle's layer in the mask")
				else
					solid_n = solid_n + 1
					expect(mask.player, label .. ": the collision mask of a solid block lacks the player layer")
					expect(not stands, "a character can stand on " .. label .. ", which stays solid")
				end
			end
		end
		--- the mask of every block of the scope is the cable's
		local function same(a, b)
			for k in pairs(a) do if not b[k] then return false end end
			for k in pairs(b) do if not a[k] then return false end end
			return true
		end
		local cable_mask = prototypes.entity["me-cable"].collision_mask.layers
		for _, name in pairs({ "me-import-bus", "me-export-bus", "me-storage-bus", "me-terminal", "me-fluid-import-bus", "me-fluid-export-bus",
			"me-fluid-storage-bus" }) do
			expect(same(prototypes.entity[name].collision_mask.layers, cable_mask), name .. ": the mask is not the cable's")
		end
		--- the selection box is the same as before: a block is clicked as it was (mining, windows, copy and paste)
		for _, name in pairs({ "me-import-bus", "me-export-bus", "me-storage-bus", "me-terminal" }) do
			local box = prototypes.entity[name].selection_box
			expect(box.left_top.x == -0.5 and box.right_bottom.x == 0.5 and box.left_top.y == -0.5 and box.right_bottom.y == 0.5,
				name .. ": the selection box changed " .. serpent.line(box))
		end
		me_report("WALKABLE", "ME walkable blocks", problems, walkable_n .. " blocks a character stands on and nothing else can be built on, "
			.. solid_n .. " that stay solid")
	end

	function T.running(check) check(storage.walkable129 and storage.walkable129.done, "ME walkable blocks") end
	return T
end
