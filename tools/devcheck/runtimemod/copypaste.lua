--- Runtime test of me-network issue #383: the copy-paste tool (Ctrl+C, Ctrl+X, Ctrl+V) keeps the settings of every
--- configurable block. The game's copy is a blueprint that the handler of on_player_setup_blueprint tags (the stack of the
--- event since Factorio 2.0.34), pasted as ghosts with those tags, built by a player or a robot (the tags come with the
--- build event) or pasted over a block that stands there already. Every block below is configured, and its "signature"
--- (its entity in a blueprint of it, tags and the game's own settings, without position and number; the level
--- maintainer's empty rows left out) must be the same after each path:
--- * blueprint: a copy built on free ground as ghosts and revived (what #378 tested for five blocks);
--- * ghost copy: the ghosts of a paste copied again before anything built them (the copy holds ghosts), pasted and revived;
--- * paste over: the copy pasted over a blank block of the same kind that stands there already. The game makes no ghost
---   and raises no event (Factorio 2.0), so the block kept its blank settings (the step that lost them, issue #383; the
---   row "over, game only" records it); the mod's on_pre_build handler (scripts/fork-me-pasteover.lua, called here as the
---   event calls it, the harness has no player) gives the block the tags' settings;
--- * cut: the copy revived after the original was mined (Ctrl+X).
--- And the landing of the paste handler: a blueprint of the whole row (blocks of 1x1, 2x2 and 3x3) built at positions
--- on and off the tile grid in the four directions: every ghost stands where pasteover.landing puts its entity.
--- No network: the settings belong to the blocks, not to a network. Everything is built, checked and taken away in one tick.
--- Loaded by control.lua like lab.lua.

local IO, NET, AC = "gregtorio-me-io", "gregtorio-me-network", "gregtorio-me-autocraft"
local SB, C, MON, EM = "gregtorio-me-storagebus", "gregtorio-me-circuit", "gregtorio-me-monitor", "gregtorio-me-emitter"
local PO = "gregtorio-me-pasteover"
local BX, BY = -300, 180                 -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local STEP = 4                           -- tiles between two blocks of a row
local ROWS = { source = 0, blueprint = 6, ghost = 12, ghostcopy = 18, over = 24, raw = 30, cut = 36, mixed = 42 }
--- the landing check's second blueprint: entities of other sizes, two of them turned (a 1x2 pump facing east, a bus facing
--- west), so the area it covers has an even side; the ones the game lacks (another mod removed them) are left out
local MIXED = { { "assembling-machine-1", 1.5, 1.5 }, { "accumulator", 5, 1 }, { "pump", 8, 1, defines.direction.east },
	{ "me-import-bus", 10.5, 0.5, defines.direction.west }, { "iron-chest", 12.5, 2.5 } }
local LAND = { x = BX + 30, y = BY + 90 }   -- (the landing check: the row, turned, reaches 30 tiles around it)
local START = 60

local function cond(cb) cb.circuit_condition = { first_signal = { type = "item", name = "iron-plate" }, comparator = ">", constant = 5 } end
--- the blocks and how each is configured (by its remote interface, as its window does)
local BLOCKS = {
	{ "me-network-interface", function(e)
		remote.call(IO, "set_interface_config", e, { [1] = { name = "iron-plate", quality = "normal", amount = 50 },
			[2] = { type = "fluid", name = "water", amount = 2345 } }, { [2] = 2, [4] = "off" })
		remote.call(IO, "set_interface_priority", e, 3)
	end },
	{ "me-import-bus", function(e) remote.call(IO, "set_bus_filters", e, { "iron-plate", "fluid/water" }) end },
	{ "me-export-bus", function(e) remote.call(IO, "set_bus_filters", e, { "copper-plate", "iron-gear-wheel" }) end },
	{ "me-storage-bus", function(e) remote.call(SB, "set_settings", e, { filters = { "copper-plate" }, priority = 4 }) end },
	{ "me-level-maintainer", function(e) remote.call(C, "set_maintainer", e, "iron-gear-wheel", 1234, false) end },
	{ "me-circuit-interface", function(e) remote.call(C, "set_circuit_filters", e, { "iron-plate", "fluid/water" }) end },
	{ "me-toggle-bus", function(e) cond(e.get_or_create_control_behavior()) end },
	{ "me-inverted-toggle-bus", function(e) cond(e.get_or_create_control_behavior()) end },
	{ "me-storage-monitor", function(e) remote.call(MON, "set", e, "iron-plate", true) end },
	{ "me-conversion-monitor", function(e) remote.call(MON, "set", e, "copper-plate", true) end },
	{ "me-throughput-monitor", function(e) remote.call(MON, "set", e, "iron-plate", true, "hour") end },
	{ "me-level-emitter", function(e) remote.call(EM, "set", e, { key = "iron-plate", amount = 1000, mode = "low" }) end },
	{ "me-pattern-provider", function(e)
		remote.call(AC, "set_priority", e, 7)
		remote.call(AC, "set_blocking", e, "blocking")
	end },
	{ "me-drive", function(e) remote.call(NET, "set_priority", e, 5) end },
	{ "me-chest", function(e) remote.call(NET, "set_priority", e, -2) end },
}

--- the centre of block `i` in a row (by the size of its prototype)
local function spot(name, i, row)
	local p = prototypes.entity[name]
	local w, h = p.tile_width or 1, p.tile_height or 1
	return { BX + (i - 1) * STEP + w / 2, BY + ROWS[row] + h / 2 }
end

--- a blueprint (in a script inventory) of the entities in `area`, tagged by the mod's blueprint handler (the same code the
--- event's handler runs). Returns the inventory (destroy it) and its stack.
local function copy_of(s, area)
	local inv = game.create_inventory(1)
	inv.insert{ name = "blueprint" }
	local bp = inv[1]
	local mapping = bp.create_blueprint{ surface = s, force = "player", area = area } or {}
	remote.call(AC, "tag_blueprint", bp, mapping)
	return inv, bp
end

local function area_of(e)
	local b = e.bounding_box
	return { { b.left_top.x + 0.1, b.left_top.y + 0.1 }, { b.right_bottom.x - 0.1, b.right_bottom.y - 0.1 } }
end

--- the level maintainer writes its five rows once it has been rebuilt from tags (empty ones and batch 0 included):
--- the same settings, another spelling
local function normal(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do
		if k == "rows" and type(v) == "table" then
			local rows = {}
			for _, r in ipairs(v) do
				if r.key then
					local c = normal(r)
					if c.batch == 0 then c.batch = nil end
					rows[#rows + 1] = c
				end
			end
			out[k] = rows
		else
			out[k] = normal(v)
		end
	end
	return out
end

--- the block's entity in a blueprint of it, without its number and position (tags and the game's own settings)
local function signature(e)
	if not (e and e.valid) then return "(none)" end
	local inv, bp = copy_of(e.surface, area_of(e))
	local sig = "(not in the blueprint)"
	for _, be in pairs(bp.get_blueprint_entities() or {}) do
		if be.name == e.name then
			be.entity_number, be.position = nil, nil
			sig = serpent.line(normal(be))
		end
	end
	inv.destroy()
	return sig
end

--- build the blueprint `bp` with its centre at `at`; revive the ghosts unless `keep`. Returns the entity named `name`
--- built (or the ghost) and the number of ghosts.
local function paste(s, bp, at, name, keep)
	local ghosts = bp.build_blueprint{ surface = s, force = "player", position = at } or {}
	local found
	for _, g in pairs(ghosts) do
		if g.valid and g.name == "entity-ghost" and g.ghost_name == name then
			if keep then found = g
			else
				local _, e = g.revive{ raise_revive = true }
				found = e
			end
		end
	end
	return found, #ghosts
end

--- the landing check: the blueprint of the source row built at `at` in direction `d`; every ghost must stand where the
--- paste handler puts its blueprint entity. Returns the problems.
local function landing(s, bp, at, d)
	local problems = {}
	local want = remote.call(PO, "landings", bp, at, d)
	local ghosts = bp.build_blueprint{ surface = s, force = "player", position = at, direction = d } or {}
	if #ghosts < table_size(want) then
		problems[#problems + 1] = "landing at " .. serpent.line(at) .. " direction " .. d .. ": " .. #ghosts .. " ghosts of " .. table_size(want)
	end
	for _, g in pairs(ghosts) do
		if g.valid then
			local p = want[g.ghost_name]
			if not (p and math.abs(p.x - g.position.x) < 0.01 and math.abs(p.y - g.position.y) < 0.01) then
				problems[#problems + 1] = "landing of " .. g.ghost_name .. " at " .. serpent.line(at) .. " direction " .. d
					.. ": the ghost at " .. serpent.line(g.position) .. ", the handler says " .. serpent.line(p)
			end
			g.destroy()
		end
	end
	return problems
end

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}

	--- the blocks are built in the tick of the test and taken away in it (circuit interfaces and emitters share their
	--- budgets with the other tests)
	local function build(s)
		local fails = {}
		for _, m in ipairs(MIXED) do
			if prototypes.entity[m[1]] then
				me_place(s, fails, "copy-paste", m[1], BX + m[2], BY + ROWS.mixed + m[3], m[4] and { direction = m[4] } or nil)
			end
		end
		for i, b in ipairs(BLOCKS) do
			for _, row in ipairs({ "source", "over", "raw" }) do              -- (the blocks a paste goes over: blank)
				local p = spot(b[1], i, row)
				me_place(s, fails, "copy-paste", b[1], p[1], p[2])
			end
		end
		return fails
	end

	function T.setup() return {} end

	function T.tick()
		if game.tick ~= START then return end
		local s = game.surfaces[1]
		local problems, lost, raw = build(s), {}, {}
		local function lose(path, name, why)
			lost[path] = lost[path] or {}
			table.insert(lost[path], name)
			problems[#problems + 1] = path .. ": " .. name .. " " .. why
		end
		local sources = {}
		for i, b in ipairs(BLOCKS) do
			local src = s.find_entity(b[1], spot(b[1], i, "source"))
			if src then
				b[2](src)
				sources[i] = src
			else
				problems[#problems + 1] = b[1] .. ": the original was not built"
			end
		end
		--- the landing of the paste handler, against the game's own ghosts
		do
			local first, last = sources[1], sources[#BLOCKS]
			if first and last then
				local a, z = area_of(first), area_of(last)
				local inv, bp = copy_of(s, { { a[1][1], BY - 0.9 }, { z[2][1], BY + 3.9 } })
				local inv2, bp2 = copy_of(s, { { BX, BY + ROWS.mixed }, { BX + 14, BY + ROWS.mixed + 4 } })
				for _, b in ipairs({ bp, bp2 }) do
					for _, d in ipairs({ defines.direction.north, defines.direction.east, defines.direction.south, defines.direction.west }) do
						for _, off in ipairs({ { 0, 0 }, { 0.5, 0.5 }, { 0.25, 0.75 }, { 0.5, 0 }, { 0.75, 0.25 } }) do
							for _, p in ipairs(landing(s, b, { x = LAND.x + off[1], y = LAND.y + off[2] }, d)) do problems[#problems + 1] = p end
						end
					end
				end
				inv.destroy()
				inv2.destroy()
			end
		end
		for i, b in ipairs(BLOCKS) do
			local name, src = b[1], sources[i]
			if src then
				local want = signature(src)
				if not want:find("tags") and not want:find("control_behavior") then
					problems[#problems + 1] = name .. ": the original's blueprint carries no settings: " .. want
				end
				local function same(path, e)
					local got = signature(e)
					if got ~= want then lose(path, name, "lost its settings: " .. got .. " (the original: " .. want .. ")") end
				end
				local inv, bp = copy_of(s, area_of(src))
				--- blueprint: on free ground, revived
				same("blueprint", (paste(s, bp, spot(name, i, "blueprint"), name)))
				--- ghost copy: pasted as ghosts, the ghosts copied again, that copy pasted and revived
				local ghost = paste(s, bp, spot(name, i, "ghost"), name, true)
				if not ghost then lose("ghost copy", name, "made no ghost")
				else
					local inv2, bp2 = copy_of(s, area_of(ghost))
					same("ghost copy", (paste(s, bp2, spot(name, i, "ghostcopy"), name)))
					inv2.destroy()
				end
				--- paste over a blank block: the game alone (the step that loses the settings), then with the mod's handler
				local r = s.find_entity(name, spot(name, i, "raw"))
				local _, nr = paste(s, bp, spot(name, i, "raw"), name)
				if r and signature(r) ~= want then raw[#raw + 1] = name end
				local o = s.find_entity(name, spot(name, i, "over"))
				local at = spot(name, i, "over")
				remote.call(PO, "paste", bp, s, "player", { x = at[1], y = at[2] }, defines.direction.north)
				local _, n = paste(s, bp, at, name)
				if not (o and r) then problems[#problems + 1] = name .. ": the blank blocks to paste over were not built"
				else same("paste over", o) end
				if n + nr > 0 then problems[#problems + 1] = name .. ": the paste over a blank block made " .. (n + nr) .. " ghost(s)" end
				--- cut: the original mined, then the copy revived
				local ghost2 = paste(s, bp, spot(name, i, "cut"), name, true)
				local buffer = game.create_inventory(16)
				src.mine{ inventory = buffer, raise_destroyed = true, ignore_minable = true }
				buffer.destroy()
				if ghost2 and ghost2.valid then
					local _, e = ghost2.revive{ raise_revive = true }
					same("cut", e)
				else lose("cut", name, "made no ghost") end
				inv.destroy()
			end
		end
		local paths = {}
		for path, names in pairs(lost) do paths[#paths + 1] = path .. ": " .. table.concat(names, ", ") end
		table.sort(paths)
		--- (the blocks go again)
		for _, e in pairs(s.find_entities_filtered{ area = { { BX - 2, BY - 2 }, { BX + #BLOCKS * STEP + 2, BY + ROWS.mixed + 6 } } }) do
			if e.valid and e.type ~= "character" then e.destroy{ raise_destroy = true } end
		end
		storage.copypaste383 = { done = true, lost = paths, raw = raw }
		me_report("COPYPASTE", "ME settings through the copy-paste tool", problems, #paths == 0
			and (#BLOCKS .. " blocks keep their settings through a blueprint, a copy of ghosts, a paste over a blank block and a cut;"
				.. " the game alone pasted over " .. #raw .. " of them without their settings: " .. table.concat(raw, ", "))
			or ("lost: " .. table.concat(paths, "; ")))
	end

	function T.running(check) check(storage.copypaste383 and storage.copypaste383.done, "ME settings through the copy-paste tool") end
	return T
end
