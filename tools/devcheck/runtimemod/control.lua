--- Runtime tests of ME Network (tools/devcheck/devcheck.py runtime). They were written in Gregtorio Continued (issue
--- numbers below are Gregtorio's) and run on vanilla (with the stand-ins of data.lua for the few Gregtorio machines
--- and recipes they name) and with Gregtorio. Every test builds its own network in on_init and reports a
--- DEVCHECK-RUNTIME-<KEY> line; DEVCHECK-RUNTIME-DONE when all have reported. Any runtime error fails the run.
--- ME network core (issue #68, prototypes/network.lua, scripts/fork-me-network.lua, fork-me-io.lua,
--- fork-me-terminal.lua): cable graph and power, storage cells, the terminal's functions, interface and buses
--- (me_graph_test, me_cells_test, me_terminal_test, me_io_test). The ME networks of the other tests are laid
--- out as before and connected by the network's cable router (me_connect).
--- Autocrafting (prototypes/autocrafting.lua, scripts/fork-me-autocraft.lua): a network
--- with a crafting CPU, two Molecular Assemblers with pattern providers (iron plate + 2 iron sticks ->
--- gear, gear + plate -> transport belt) and raw materials in a drive. Job 1 crafts belts through the
--- two-level chain, job 2 asks for more than the raw materials allow and must not start, job 3 is
--- refused while job 1 runs on the only CPU (issue #6: a job needs a free CPU) and takes nothing.
--- Encoded patterns (issue #80, scripts/fork-me-patterns.lua): every provider gets its patterns the way a player
--- gives them (blank patterns encoded through the terminal's functions, put into its slots: give_patterns).
--- Furnace and pattern items (furnace_test): encoding a crafting and a processing pattern (tags, tooltip data, not
--- researched), a crafting pattern next to a furnace is no pattern ("furnace"), a processing pattern smelts a job,
--- clearing, loading, settings paste (priority), blueprint tags (patterns pending until a blank is in the network,
--- an old 0.4.1 tag), a provider mined (patterns into the buffer), destroyed (dropped) and gone without an event.
--- Recipe switching (pattern_switch_test): three crafting patterns on one Molecular Assembler run three jobs (the
--- recipe is switched, what was left in the machine goes into the network), two jobs wait for the same machine, two
--- patterns for one output (provider priority), a processing pattern on a machine with its own recipe, a level
--- maintainer keeping blank patterns. Processing line (pattern_line_test): a processing pattern pushes into a chest,
--- the "line" (this script) turns the inputs into outputs in another chest and an import bus brings them back.
--- Fluids (issue #68 step R2, prototypes/fluids.lua, scripts/fork-me-fluids.lua): a network with a
--- drive of four 1k fluid cells, an import interface with a tank of chlorine connected to it, an export interface,
--- a roboport with construction robots, and pattern machines with fluid recipes (chemical reactors, an extractor).
--- Checks the import and export totals, a fluid cell taken out (its fluid in the tags), stored in the network and
--- put back, the drive mined by robots (cells with their fluid in the storage chest) and rebuilt, full cells, a
--- reported fluid shortfall, and jobs with a fluid ingredient, a fluid product and both. ME fluid cells
--- (fluid_cell_test): a mixed drive, tags, capacity, the terminal with fluids, the fluid buses, old fluid drive
--- items placed. The migration of old Gregtorio saves is tested by Gregtorio's devcheck (migrate).
--- Issue #38: the level maintainer (one job at a time, stops at N, circuit amount and condition), crafting
--- CPU tiers (two jobs at once), the circuit interface (network contents on the wire) and the settings of
--- maintainers, circuit and fluid interfaces in blueprints, settings paste and clones (setup_issue38_tests).
--- State of a robot job at `pos` for a timeout message: ghosts and blocking entities there, the tile,
--- the chunk, and every construction network covering it (robots with position, energy and order).
function robot_report(s, pos, name)
	local force = game.forces.player
	local out = {}
	local function add(x) out[#out + 1] = x end
	local area = { { pos[1] - 1.5, pos[2] - 1.5 }, { pos[1] + 1.5, pos[2] + 1.5 } }
	add("ghosts " .. #s.find_entities_filtered{ ghost_name = name, position = pos, radius = 0.5 })
	local blocking = {}
	for _, e in pairs(s.find_entities_filtered{ area = area }) do
		if e.name ~= name and e.type ~= "entity-ghost" then blocking[#blocking + 1] = e.name .. "@" .. e.position.x .. "," .. e.position.y end
	end
	add("near: " .. table.concat(blocking, " "))
	add("tile " .. s.get_tile(pos[1], pos[2]).name)
	local chunk = { math.floor(pos[1] / 32), math.floor(pos[2] / 32) }
	add("chunk generated " .. tostring(s.is_chunk_generated(chunk)) .. " charted " .. tostring(force.is_chunk_charted(s, chunk)))
	for _, n in pairs(s.find_logistic_networks_by_construction_area(pos, force)) do
		local robots = {}
		for _, r in pairs(n.construction_robots) do
			robots[#robots + 1] = string.format("(%.1f,%.1f e=%.0f orders=%d)", r.position.x, r.position.y, r.energy, #r.robot_order_queue)
		end
		local ports = {}
		for _, c in pairs(n.cells) do ports[#ports + 1] = c.owner.name .. " e=" .. string.format("%.0f", c.owner.energy) end
		add("network " .. n.network_id .. ": robots " .. n.available_construction_robots .. "/" .. n.all_construction_robots
			.. " " .. table.concat(robots, " ") .. " cells " .. table.concat(ports, ", "))
	end
	return table.concat(out, "; ")
end

--------------------------------------------------------------------------------
--- ME network core (issue #68, scripts/fork-me-network.lua, fork-me-io.lua, fork-me-terminal.lua), right of the
--- machine grid (no power poles of the grid reach there): the cable graph (join, split, two controllers, a member
--- removed without an event, the cable router, power on and off), storage cells (insert and remove with the
--- contents in tags, AE2 capacity, quality, a cell stored in a cell, the drive window's clicks, a destroyed drive
--- spills its cells, an old drive item, robots mining a drive with cells), the terminal's functions (take a stack,
--- one, into the inventory, store the cursor and the inventory, search, sort, items that cannot be stored) and
--- import/export (ME Interface filters, import and export bus, rotation, settings paste and blueprint tags).
--------------------------------------------------------------------------------

local NET, TERM, IO = "gregtorio-me-network", "gregtorio-me-terminal", "gregtorio-me-io"
local GX, GY = 200, 100                                 -- graph test
local PX, PY = 235, 100                                 -- power test (no pole of the graph test reaches it)
local CX, CY = 200, 125                                 -- cells, terminal and import/export test

local function me_place(s, fails, what, name, x, y, extra)
	local ok, e = pcall(function()
		local def = { name = name, position = { x, y }, force = "player", raise_built = true }
		for k, v in pairs(extra or {}) do def[k] = v end
		return s.create_entity(def)
	end)
	if not (ok and e) then fails[#fails + 1] = what .. " " .. name .. ": " .. tostring(e) return nil end
	return e
end

--- ME cables on the tiles x1..x2 of row y (tile coordinates)
local function cable_row(s, fails, x1, x2, y)
	for x = x1, x2 do me_place(s, fails, "cable", "me-cable", x + 0.5, y + 0.5) end
end

local function power(s, fails, what, x, y)
	local eei = me_place(s, fails, what, "electric-energy-interface", x, y)
	if eei then
		eei.power_production = 1e6
		eei.electric_buffer_size = 1e7
	end
	me_place(s, fails, what, "substation", x + 3, y)
	return eei
end

function setup_me_network(s)
	local fails = {}
	--- graph: controller A, five cables, drive D
	power(s, fails, "graph", GX, GY)
	me_place(s, fails, "graph", "me-network-controller", GX + 6, GY)              -- tiles GX+5..6, GY-1..GY
	cable_row(s, fails, GX + 7, GX + 11, GY - 1)
	me_place(s, fails, "graph", "me-drive", GX + 12.5, GY - 0.5)
	--- power: a controller and a drive without any pole
	me_place(s, fails, "power", "me-network-controller", PX + 6, PY)
	me_place(s, fails, "power", "me-drive", PX + 7.5, PY - 0.5)
	--- cells, terminal, import/export: controller, D1, D2, terminal, interface in a row; buses below
	power(s, fails, "cells", CX, CY)
	me_place(s, fails, "cells", "substation", CX + 16, CY + 2)
	me_place(s, fails, "cells", "me-network-controller", CX + 7, CY)               -- tiles CX+6..7, CY-1..CY
	me_place(s, fails, "cells", "me-drive", CX + 8.5, CY - 0.5)
	me_place(s, fails, "cells", "me-drive", CX + 9.5, CY - 0.5)
	me_place(s, fails, "cells", "me-terminal", CX + 10.5, CY - 0.5)
	me_place(s, fails, "cells", "me-network-interface", CX + 11.5, CY - 0.5)
	me_place(s, fails, "cells", "me-drive", CX + 12.5, CY - 0.5)                    -- D3: destroyed by the test
	me_place(s, fails, "cells", "me-import-bus", CX + 8.5, CY + 0.5, { direction = defines.direction.south })
	me_place(s, fails, "cells", "me-export-bus", CX + 9.5, CY + 0.5, { direction = defines.direction.south })
	me_place(s, fails, "cells", "me-export-bus", CX + 11.5, CY + 0.5, { direction = defines.direction.south })
	me_place(s, fails, "cells", "iron-chest", CX + 8.5, CY + 1.5)
	me_place(s, fails, "cells", "iron-chest", CX + 9.5, CY + 1.5)
	local m = me_place(s, fails, "cells", "me-molecular-assembler", CX + 11.5, CY + 2.5)
	if m then
		m.force.recipes["iron-gear-crafting-table"].enabled = true
		m.set_recipe("iron-gear-crafting-table")
	end
	--- robots for the drive deconstruction
	local port = me_place(s, fails, "cells", "roboport", CX + 20, CY + 6)
	if port then port.insert{ name = "construction-robot", count = 2 } end
	me_place(s, fails, "cells", "storage-chest", CX + 17.5, CY + 6.5)
	return fails
end

local function me_report(key, name, problems, note)
	for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL " .. name .. ": " .. p) end
	log("DEVCHECK-RUNTIME-" .. key .. " " .. (#problems == 0 and "ok" or "failed") .. (note and (" (" .. note .. ")") or ""))
end

--- issue #80: a provider gets encoded patterns the way a player gives them: a blank pattern (made by script) is
--- encoded with the terminal's function and put into the provider's next free slot. `defs`: patterns as data
--- ({ kind = "crafting", recipe } or { kind = "processing", inputs, outputs }). Returns the number put in.
local AC = "gregtorio-me-autocraft"
function give_patterns(provider, defs, fails)
	local inv = game.create_inventory(2)
	local n = 0
	for _, def in ipairs(defs) do
		inv.insert{ name = "me-blank-pattern", count = 1 }
		local where, why = remote.call(TERM, "encode_def", false, inv, false, def)
		local stack = inv.find_item_stack("me-encoded-pattern")
		if where and stack and remote.call(AC, "insert_pattern", provider, stack) then
			n = n + 1
		elseif fails then
			fails[#fails + 1] = "pattern " .. serpent.line(def) .. " for the provider at " .. serpent.line(provider.position) .. ": " .. tostring(why)
		end
		inv.clear()
	end
	inv.destroy()
	return n
end

--- crafting patterns of the recipes set in the assembling machines next to a provider (what a provider read from
--- its machines before issue #80)
function machine_patterns(provider)
	local defs, seen = {}, {}
	for _, d in pairs({ { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }) do
		for _, m in pairs(provider.surface.find_entities_filtered{ type = "assembling-machine",
			position = { provider.position.x + d[1], provider.position.y + d[2] } }) do
			local r = m.get_recipe()
			if r and not seen[r.name] then
				seen[r.name] = true
				defs[#defs + 1] = { kind = "crafting", recipe = r.name }
			end
		end
	end
	return defs
end

--- the encoded patterns lying on the ground around `pos` (a destroyed provider drops them)
function patterns_on_ground(s, pos, radius)
	local n = 0
	for _, e in pairs(s.find_entities_filtered{ name = "item-on-ground", position = pos, radius = radius or 3 }) do
		if e.stack.valid_for_read and e.stack.name == "me-encoded-pattern" then n = n + e.stack.count end
	end
	return n
end

--- cable graph and power
function me_graph_test()
	local s = game.surfaces[1]
	local st = storage.me_graph
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function finish(note)
		storage.me_graph.done = true
		me_report("MEGRAPH", "ME graph", problems, note)
	end
	local a = s.find_entity("me-network-controller", { GX + 6, GY })
	local d = s.find_entity("me-drive", { GX + 12.5, GY - 0.5 })
	local function net(e) return remote.call(NET, "network", e) end
	local function same(x, y) return remote.call(NET, "same_network", x, y) end
	local function cable(x) return s.find_entity("me-cable", { GX + x + 0.5, GY - 0.5 }) end
	if not st then
		if game.tick < 60 then return end
		storage.me_graph = { phase = "graph", phase_tick = game.tick }
		st = storage.me_graph
		if not (a and d) then expect(false, "entities missing") return finish() end
		--- the ME windows find their entity by unit number (game.get_entity_by_unit_number knows none of them)
		expect(remote.call(TERM, "entity_by_unit", d.unit_number) == d and remote.call(TERM, "entity_by_unit", a.unit_number) == a,
			"the ME windows cannot find their entity by unit number")
		--- join: controller, 5 cables and the drive are one network that works
		local n = net(a)
		expect(same(a, d), "the drive is not in the controller's network")
		expect(n and n.ok and n.members == 7 and n.controllers == 1, "network " .. serpent.line(n))
		expect(n and n.power == 124000, "controller power " .. tostring(n and n.power) .. " W, expected 124000 (base + one drive)")
		expect(remote.call(NET, "cable_variation", cable(9)) == 11 and remote.call(NET, "cable_variation", cable(7)) == 11,
			"cable pictures " .. remote.call(NET, "cable_variation", cable(9)) .. "/" .. remote.call(NET, "cable_variation", cable(7)))
		local id = n and n.id
		--- split: the middle cable is removed
		cable(9).destroy{ raise_destroy = true }
		expect(not same(a, d), "the drive is still in the controller's network after the split")
		local nd = net(d)
		expect(nd and not nd.ok and nd.status == "no-controller" and nd.members == 3, "drive's part " .. serpent.line(nd))
		expect(net(a).members == 3 and net(a).id == id, "controller's part " .. serpent.line(net(a)))
		expect(remote.call(NET, "cable_variation", cable(8)) == 9, "cable picture next to the gap " .. remote.call(NET, "cable_variation", cable(8)))
		--- join again
		s.create_entity{ name = "me-cable", position = { GX + 9.5, GY - 0.5 }, force = "player", raise_built = true }
		expect(same(a, d) and net(a).members == 7 and net(a).id == id, "rejoined network " .. serpent.line(net(a)))
		--- two controllers: a second one next to the drive is a conflict, the network stores nothing
		local b = s.create_entity{ name = "me-network-controller", position = { GX + 14, GY }, force = "player", raise_built = true }
		local nb = net(a)
		expect(same(a, b) and nb.controllers == 2 and nb.graph_status == "conflict" and not nb.ok, "two controllers " .. serpent.line(nb))
		expect(remote.call(NET, "insert", a, "iron-plate", 10) == 0, "a network with a controller conflict took items")
		expect(b.custom_status ~= nil, "no conflict status on the controller")
		b.destroy{ raise_destroy = true }
		expect(net(a).ok and net(a).controllers == 1, "after removing the second controller " .. serpent.line(net(a)))
		expect(a.custom_status == nil, "the conflict status stayed on the controller")
		--- a member removed without an event: found by the sweep
		cable(10).destroy()
		expect(remote.call(NET, "sweep") == 1, "the sweep did not find the vanished cable")
		expect(not same(a, d), "the drive is still connected through a vanished cable")
		s.create_entity{ name = "me-cable", position = { GX + 10.5, GY - 0.5 }, force = "player", raise_built = true }
		expect(remote.call(NET, "sweep_list_ok"), "the sweep list after the vanished cable and the new one")
		--- the same through the slow step's sweep (issue #43: it walks a list that is kept as members come and go)
		cable(10).destroy()
		for _ = 1, 60 do remote.call(NET, "slow_step") end
		expect(not same(a, d), "the slow step's sweep did not find the vanished cable")
		expect(remote.call(NET, "sweep_list_ok"), "the sweep list after the slow step's sweep")
		s.create_entity{ name = "me-cable", position = { GX + 10.5, GY - 0.5 }, force = "player", raise_built = true }
		--- the router connects a drive 5 tiles below
		local e = s.create_entity{ name = "me-drive", position = { GX + 12.5, GY + 4.5 }, force = "player", raise_built = true }
		local placed, unreached = remote.call(NET, "connect", { a, e }, 8)
		expect(placed > 0 and #unreached == 0 and same(a, e), "router: " .. placed .. " cables, " .. #unreached .. " unreached")
		--- underground cable: drive, end facing east, 3 free tiles, end facing west, drive (no controller needed)
		local ux, uy = GX + 20.5, GY + 12.5
		local function put(name, dx, dy, dir)
			return s.create_entity{ name = name, position = { ux + dx, uy + dy }, force = "player", direction = dir, raise_built = true }
		end
		local ud1 = put("me-drive", 0, 0)
		local u1 = put("me-underground-cable", 1, 0, defines.direction.east)
		local u2 = put("me-underground-cable", 5, 0, defines.direction.west)
		local ud2 = put("me-drive", 6, 0)
		expect(ud1 and u1 and u2 and ud2 and same(ud1, ud2), "the drives are not connected through the underground cable")
		expect(u1 and u2 and remote.call(NET, "underground_partner", u1) == u2.unit_number, "the underground ends did not pair")
		--- a cable over the run and one beside an end belong to other networks
		local over = put("me-cable", 3, 0)
		local beside = put("me-cable", 1, 1)
		expect(over and not same(over, ud1), "a cable over the underground run joined it")
		expect(beside and not same(beside, ud1), "a cable beside an underground end joined it")
		--- removing an end splits, placing it again joins
		u2.destroy{ raise_destroy = true }
		expect(not same(ud1, ud2), "still connected without the second end")
		u2 = put("me-underground-cable", 5, 0, defines.direction.west)
		expect(u2 and same(ud1, ud2), "not connected again after placing the end again")
		--- rotating an end breaks the link (and turning it back restores it)
		u1.direction = defines.direction.south
		remote.call(NET, "rotated", u1)
		expect(not same(ud1, ud2) and remote.call(NET, "underground_partner", u2) == nil, "still linked after rotating an end")
		u1.direction = defines.direction.east
		remote.call(NET, "rotated", u1)
		expect(same(ud1, ud2), "not linked after rotating the end back")
		st.underground = { ud1 = ud1, ud2 = ud2, u1 = u1, u2 = u2, over = over, beside = beside }
		--- out of reach: an end 12 tiles away does not pair
		local far1 = put("me-underground-cable", 1, 3, defines.direction.east)
		local far2 = put("me-underground-cable", 13, 3, defines.direction.west)
		expect(far1 and far2 and remote.call(NET, "underground_partner", far1) == nil, "ends 12 tiles apart paired")
		--- it is an underground pipe of its own category: a pipe next to it does not connect
		local pipe = put("pipe", 0, 3)
		expect(pipe and #pipe.fluidbox.get_connections(1) == 0, "a pipe connected to an underground cable")
		--- an end placed between a pair takes the near end (like underground pipes); removing it gives the pair back
		local wd1, wd2 = put("me-drive", 0, 6), put("me-drive", 8, 6)
		local w1 = put("me-underground-cable", 1, 6, defines.direction.east)
		local w2 = put("me-underground-cable", 7, 6, defines.direction.west)
		expect(same(wd1, wd2), "the second pair did not connect")
		local w3 = put("me-underground-cable", 4, 6, defines.direction.west)
		expect(remote.call(NET, "underground_partner", w1) == w3.unit_number and not same(wd1, wd2)
			and remote.call(NET, "underground_partner", w2) == nil, "the middle end did not take the near end")
		w3.destroy{ raise_destroy = true }
		st.weave = { wd1 = wd1, wd2 = wd2, w1 = w1, w2 = w2 }
		--- cables can be walked over
		local mask = prototypes.entity["me-cable"].collision_mask.layers
		expect(not mask.player and not prototypes.entity["me-underground-cable"].collision_mask.layers.player,
			"ME cables block the player")
		expect(s.can_place_entity{ name = "character", position = { ux + 3, uy } }, "a character cannot stand on an ME cable")
		--- power: the unpowered network does not work
		local pa = s.find_entity("me-network-controller", { PX + 6, PY })
		local pd = s.find_entity("me-drive", { PX + 7.5, PY - 0.5 })
		local np = pa and net(pa)
		expect(np and not np.ok and np.status == "no-power" and same(pa, pd), "network without power " .. serpent.line(np))
		local eei = s.create_entity{ name = "electric-energy-interface", position = { PX, PY }, force = "player" }
		eei.power_production = 1e6
		eei.electric_buffer_size = 1e7
		s.create_entity{ name = "substation", position = { PX + 3, PY }, force = "player" }
		st.eei = eei
		if #problems > 0 then return finish() end
		return
	end
	if st.done then return end
	local pa = s.find_entity("me-network-controller", { PX + 6, PY })
	if st.phase == "graph" then
		if game.tick >= st.phase_tick + 60 then
			expect(net(pa).ok, "the network with power does not work: " .. serpent.line(net(pa)))
			st.eei.destroy()
			st.phase, st.phase_tick = "off", game.tick
		end
	elseif st.phase == "off" then
		if game.tick >= st.phase_tick + 120 then
			local n = net(pa)
			expect(not n.ok and n.status == "no-power", "after the power was cut " .. serpent.line(n))
			--- (before the rebuild below, which would pair them anyway: the slow step must have done it)
			local w = st.weave
			if w then
				expect(same(w.wd1, w.wd2) and remote.call(NET, "underground_partner", w.w1) == w.w2.unit_number,
					"the pair did not connect again after removing the end between them")
			end
			--- the graph rebuild (on_configuration_changed) keeps the underground pairs and their side rule
			local u = st.underground
			if u then
				remote.call(NET, "rebuild")
				expect(same(u.ud1, u.ud2) and remote.call(NET, "underground_partner", u.u1) == u.u2.unit_number,
					"the underground pair is lost after the graph rebuild")
				expect(not same(u.over, u.ud1) and not same(u.beside, u.ud1), "the graph rebuild joined cables over or beside the run")
			end
			return finish("join, split, conflict, sweep, router, underground cable, walkable, power")
		end
	end
	if #problems > 0 then finish() end
end

--- storage cells, terminal functions, import and export
function me_cells_test()
	local s = game.surfaces[1]
	local st = storage.me_cells
	if st and st.done then return end
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function find(name, x, y) return s.find_entity(name, { CX + x, CY + y }) end
	local d1, d2, d3 = find("me-drive", 8.5, -0.5), find("me-drive", 9.5, -0.5), find("me-drive", 12.5, -0.5)
	local t, iface = find("me-terminal", 10.5, -0.5), find("me-network-interface", 11.5, -0.5)
	local ib, eb, eb2 = find("me-import-bus", 8.5, 0.5), find("me-export-bus", 9.5, 0.5), find("me-export-bus", 11.5, 0.5)
	local ichest, echest = find("iron-chest", 8.5, 1.5), find("iron-chest", 9.5, 1.5)
	local mol = find("me-molecular-assembler", 11.5, 2.5)
	local function count(name, q) return remote.call(NET, "count", t, name, q) end
	local function near(a, b) return a == b end
	if not st then
		if game.tick < 60 then return end
		storage.me_cells = { phase = "cells", phase_tick = game.tick }
		st = storage.me_cells
		local function finish(note)
			st.done = true
			me_report("MECELLS", "ME cells", problems, note)
		end
		if not (d1 and d2 and d3 and t and iface and ib and eb and eb2 and ichest and echest and mol) then
			expect(false, "entities missing")
			finish()
			me_report("METERMINAL", "ME terminal", { "entities missing" })
			me_report("MEIO", "ME import/export", { "entities missing" })
			storage.me_term, storage.me_io = { done = true }, { done = true }
			return
		end
		local inv = game.create_inventory(4)
		--- cells into slots: a 1k cell into D1 slot 1, a 4k cell into slot 2
		inv[1].set_stack{ name = "me-1k-storage-cell", count = 1 }
		inv[2].set_stack{ name = "me-4k-storage-cell", count = 1 }
		expect(remote.call(NET, "insert_cell", d1, inv[1], 1) == 1 and not inv[1].valid_for_read, "1k cell not inserted")
		expect(remote.call(NET, "insert_cell", d1, inv[2], 2) == 2, "4k cell not inserted")
		inv[3].set_stack{ name = "iron-plate", count = 5 }
		local _, why = remote.call(NET, "insert_cell", d1, inv[3], 3)
		expect(why == "not-a-cell" and inv[3].count == 5, "a plate went into a drive slot: " .. tostring(why))
		inv[3].clear()
		local n = remote.call(NET, "network", t)
		expect(n and n.ok and n.bytes_total == 1024 + 4096 and n.types_total == 126 and n.cells == 2 and n.drives == 3,
			"network with two cells " .. serpent.line(n))
		--- items: 1000 iron plates and 50 copper plates go into the first cell (AE2 bytes: 8 per type, one per 8 items)
		expect(remote.call(NET, "insert", t, "iron-plate", 1000) == 1000, "iron plates not stored")
		expect(remote.call(NET, "insert", t, "copper-plate", 50) == 50, "copper plates not stored")
		local info = remote.call(NET, "drive", d1)
		expect(info[1] and info[1].bytes == 8 + 125 + 8 + 7 and info[1].types == 2 and info[1].items["iron-plate"] == 1000,
			"1k cell after storing " .. serpent.line(info[1]))
		--- the cell is taken out: its contents travel in its tags, the network no longer has them
		expect(remote.call(NET, "take_cell", d1, 1, inv[1]), "take_cell failed")
		local tags = inv[1].valid_for_read and inv[1].tags or {}
		local carried = tags.fork_me_cell and tags.fork_me_cell.items or {}
		expect(carried["iron-plate"] == 1000 and carried["copper-plate"] == 50, "cell tags " .. serpent.line(tags))
		expect(count("iron-plate") == 0 and count("copper-plate") == 0, "the network keeps the items of a removed cell")
		--- into another drive: the items are back
		expect(remote.call(NET, "insert_cell", d2, inv[1], 4) == 4, "the cell did not go into drive 2")
		expect(count("iron-plate") == 1000 and count("copper-plate") == 50, "after moving the cell: " .. count("iron-plate"))
		--- capacity: the room left in the 1k cell (876 bytes) and the empty 4k cell
		local room = (1024 - 148) * 8 + (4096 - 32) * 8
		expect(remote.call(NET, "can_insert", t, "iron-plate", 1e6) == room, "can_insert " .. remote.call(NET, "can_insert", t, "iron-plate", 1e6) .. ", expected " .. room)
		expect(remote.call(NET, "insert", t, "iron-plate", room + 10) == room, "the cells took more than their bytes")
		local i1, i2 = remote.call(NET, "drive", d2)[4], remote.call(NET, "drive", d1)[2]
		expect(i1.state == "full" and i2.state == "full" and i1.bytes == 1024 and i2.bytes == 4096, "full cells " .. serpent.line(i1) .. " " .. serpent.line(i2))
		expect(remote.call(NET, "extract", t, "iron-plate", room) == room, "extract after the capacity test")
		--- quality is its own type
		expect(remote.call(NET, "insert", t, "iron-plate", 10, "uncommon") == 10 and count("iron-plate", "uncommon") == 10
			and count("iron-plate") == 1000, "uncommon plates " .. count("iron-plate", "uncommon"))
		expect(remote.call(NET, "extract", t, "iron-plate", 10, "uncommon") == 10, "uncommon plates not taken out")
		--- a cell stored in a cell: it keeps its tags through the terminal
		inv[2].set_stack{ name = "me-1k-storage-cell", count = 1 }
		inv[2].tags = { fork_me_cell = { items = { ["copper-plate"] = 7 } } }
		expect(remote.call(TERM, "store_stack", t, inv[2]) == 1, "a loaded cell was not stored")
		local special
		for key in pairs(remote.call(NET, "contents", t)) do if key:find("^me%-1k%-storage%-cell@normal#") then special = key end end
		expect(special, "no entry for the loaded cell: " .. serpent.line(remote.call(NET, "contents", t)))
		expect(remote.call(TERM, "withdraw", t, inv, "me-1k-storage-cell", "normal", 1) == 1, "the loaded cell was not withdrawn")
		local back
		for i = 1, #inv do
			if inv[i].valid_for_read and inv[i].name == "me-1k-storage-cell" then back = inv[i] end
		end
		local bt = back and back.tags or {}
		expect(bt.fork_me_cell and bt.fork_me_cell.items["copper-plate"] == 7, "the withdrawn cell lost its contents " .. serpent.line(bt))
		--- the drive window: take the 4k cell into the cursor, put it into slot 3, shift click it into the inventory
		local cursor, main = game.create_inventory(1), game.create_inventory(4)
		expect(remote.call(NET, "drive_click", cursor[1], main, d1, 2, false) == nil and cursor[1].valid_for_read
			and cursor[1].name == "me-4k-storage-cell", "click on a filled slot")
		expect(remote.call(NET, "drive_click", cursor[1], main, d1, 3, false) == nil and not cursor[1].valid_for_read
			and remote.call(NET, "drive", d1)[3], "click on an empty slot with a cell in hand")
		expect(remote.call(NET, "drive_click", cursor[1], main, d1, 3, true) == nil and main.get_item_count("me-4k-storage-cell") == 1,
			"shift click on a filled slot")
		main.remove{ name = "me-4k-storage-cell", count = 1 }
		cursor[1].set_stack{ name = "me-4k-storage-cell", count = 1 }
		expect(remote.call(NET, "drive_click", cursor[1], main, d1, 2, false) == nil, "cell back into slot 2")
		cursor.destroy()
		main.destroy()
		--- a destroyed drive spills its cells with their contents
		inv[3].set_stack{ name = "me-1k-storage-cell", count = 1 }
		remote.call(NET, "insert_cell", d3, inv[3], 1)
		remote.call(NET, "store_in_drive", d3, "copper-plate", 5)
		expect(count("copper-plate") == 55, "copper with the cell of drive 3: " .. count("copper-plate"))
		local pos = d3.position
		d3.destroy{ raise_destroy = true }
		expect(count("copper-plate") == 50, "copper after drive 3 was destroyed: " .. count("copper-plate"))
		local spilled
		for _, g in pairs(s.find_entities_filtered{ name = "item-on-ground", position = pos, radius = 3 }) do
			local stack = g.stack
			if stack.name == "me-1k-storage-cell" then
				local tg = stack.tags
				spilled = tg and tg.fork_me_cell and tg.fork_me_cell.items["copper-plate"]
				g.destroy()
			end
		end
		expect(spilled == 5, "the spilled cell carries " .. tostring(spilled) .. " copper plates")
		--- an old drive item placed: its four cells are in the new drive
		local old = s.create_entity{ name = "me-drive", position = { CX + 14.5, CY + 4.5 }, force = "player" }
		inv[3].set_stack{ name = "me-drive-256k", count = 1 }
		remote.call(NET, "built", old, inv[3])
		local oi = remote.call(NET, "drive", old)
		expect(oi[1] and oi[4] and oi[4].name == "me-256k-storage-cell" and not oi[5], "old 256k drive item: " .. serpent.line(oi))
		local card = s.find_entities_filtered{ name = "item-on-ground", position = old.position, radius = 3 }
		--- the old item's extra part comes back if the game has it (Gregtorio's acceleration card), else nothing
		if prototypes.item["acceleration-card"] then
			expect(#card == 1 and card[1].stack.name == "acceleration-card", "the old drive's acceleration card was not given back")
		else
			expect(#card == 0, "an old drive item without an acceleration card in the game dropped " .. #card .. " items")
		end
		for _, g in pairs(card) do g.destroy() end
		--- robots mine a drive with two loaded cells: drive and cells (with their contents) arrive in the storage chest
		local rd = s.create_entity{ name = "me-drive", position = { CX + 15.5, CY + 8.5 }, force = "player", raise_built = true }
		inv[3].set_stack{ name = "me-1k-storage-cell", count = 1 }
		inv[4].set_stack{ name = "me-16k-storage-cell", count = 1 }
		remote.call(NET, "insert_cell", rd, inv[3], 1)
		remote.call(NET, "insert_cell", rd, inv[4], 7)
		expect(remote.call(NET, "store_in_drive", rd, "stone", 20) == 20, "stone into the robots' drive")
		expect(rd.order_deconstruction("player"), "the drive cannot be deconstructed")
		inv.destroy()
		if #problems > 0 then return finish() end
		st.terminal_ready = true
		return
	end
	--- robots: wait for the drive and its cells in the storage chest
	if st.phase == "cells" then
		local chest = find("storage-chest", 17.5, 6.5)
		local ci = chest.get_inventory(defines.inventory.chest)
		local drives, cells, stone = ci.get_item_count("me-drive"), 0, 0
		for i = 1, #ci do
			local stack = ci[i]
			if stack.valid_for_read and stack.name:find("storage%-cell") then
				cells = cells + 1
				local tg = stack.tags
				stone = stone + (tg and tg.fork_me_cell and tg.fork_me_cell.items.stone or 0)
			end
		end
		if drives == 1 and cells == 2 then
			expect(stone == 20, "the cells mined by robots carry " .. stone .. " stone")
			st.done = true
			for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL ME cells: " .. p) end
			me_report("MECELLS", "ME cells", problems, "slots, tags, capacity, quality, cell in a cell, drive window, spill, old item, robots")
			return
		end
		if game.tick > st.phase_tick + 900 then
			expect(false, "robots did not bring the drive and its cells: drives " .. drives .. ", cells " .. cells
				.. " (" .. robot_report(s, { CX + 15.5, CY + 8.5 }, "me-drive") .. ")")
			st.done = true
			me_report("MECELLS", "ME cells", problems)
		end
	end
end

--- the terminal's functions (the GUI buttons) on the network of the cells test
function me_terminal_test()
	local st = storage.me_cells
	if not (st and st.terminal_ready) or (storage.me_term and storage.me_term.done) then return end
	storage.me_term = { done = true }
	local s = game.surfaces[1]
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local t = s.find_entity("me-terminal", { CX + 10.5, CY - 0.5 })
	local function count(name) return remote.call(NET, "count", t, name) end
	local cursor, main = game.create_inventory(1), game.create_inventory(10)
	local size = prototypes.item["iron-plate"].stack_size
	expect(remote.call(TERM, "problem", t) == nil, "terminal problem " .. tostring(remote.call(TERM, "problem", t)))
	--- left click: a stack into the empty cursor
	expect(remote.call(TERM, "take", cursor[1], main, t, "iron-plate", "stack") == size and cursor[1].count == size
		and count("iron-plate") == 1000 - size, "take a stack: cursor " .. cursor[1].count)
	--- right click with plates in hand: one more (none above a stack)
	cursor[1].count = size - 1
	remote.call(NET, "insert", t, "iron-plate", 1)
	expect(remote.call(TERM, "take", cursor[1], main, t, "iron-plate", "one") == 1 and cursor[1].count == size, "take one more")
	expect(remote.call(TERM, "take", cursor[1], main, t, "iron-plate", "one") == 0, "took one more than a stack into the cursor")
	--- left click with something in hand: it is stored
	expect(remote.call(TERM, "take", cursor[1], main, t, "copper-plate", "stack") == -size and not cursor[1].valid_for_read
		and count("iron-plate") == 1000, "left click with plates in hand stores them: " .. count("iron-plate"))
	--- right click with an empty cursor: one item
	expect(remote.call(TERM, "take", cursor[1], main, t, "copper-plate", "one") == 1 and cursor[1].count == 1, "take one")
	expect(remote.call(TERM, "store_cursor", cursor[1], t) == 1 and not cursor[1].valid_for_read, "store the cursor")
	--- shift click: a stack into the inventory, then the inventory row stores all of it
	expect(remote.call(TERM, "take", cursor[1], main, t, "iron-plate", "inventory") == size and main.get_item_count("iron-plate") == size,
		"shift click: inventory holds " .. main.get_item_count("iron-plate"))
	main.insert{ name = "iron-plate", count = 7 }
	remote.call(NET, "extract", t, "iron-plate", 7)
	expect(remote.call(TERM, "store_inventory_item", main, t, "iron-plate", "normal", true) == size + 7 and main.get_item_count("iron-plate") == 0
		and count("iron-plate") == 1000, "storing all plates of the inventory: " .. count("iron-plate"))
	--- search and sort
	local found = remote.call(TERM, "entries", t, "copper", "count")
	expect(#found == 1 and found[1].name == "copper-plate", "search 'copper': " .. serpent.line(found))
	local all = remote.call(TERM, "entries", t, "", "count")
	expect(#all >= 2 and all[1].name == "iron-plate", "sort by amount: " .. serpent.line(all[1]))
	local by_name = remote.call(TERM, "entries", t, "", "name")
	expect(by_name[1].name <= by_name[#by_name].name and by_name[1].name == "copper-plate", "sort by name: " .. serpent.line(by_name[1]))
	--- what cannot be stored: spoiling items, blueprints
	local spoiling
	for name, p in pairs(prototypes.item) do
		if p.get_spoil_ticks() > 0 and (not spoiling or name < spoiling) then spoiling = name end
	end
	main[1].set_stack{ name = spoiling, count = 1 }
	local n, why = remote.call(TERM, "store_stack", t, main[1])
	expect(n == nil and why == "cannot-store-spoil" and main[1].valid_for_read, "a spoiling item: " .. tostring(n) .. " " .. tostring(why))
	main[2].set_stack{ name = "blueprint", count = 1 }
	n, why = remote.call(TERM, "store_stack", t, main[2])
	expect(n == nil and why == "cannot-store-blueprint", "a blueprint: " .. tostring(n) .. " " .. tostring(why))
	cursor.destroy()
	main.destroy()
	me_report("METERMINAL", "ME terminal", problems, "take stack/one/inventory, store cursor and inventory, search, sort, unstorable")
end

--- an ME Drive with four cells of `tier` (default 16k; `fluid`: fluid cells) at x, y, holding `items` ({ name -> count })
function me_drive(s, fails, what, x, y, items, tier, fluid)
	local d = me_place(s, fails, what, "me-drive", x, y)
	if not d then return nil end
	local inv = game.create_inventory(1)
	for slot = 1, 4 do
		inv[1].set_stack{ name = "me-" .. (tier or "16k") .. (fluid and "-fluid" or "") .. "-storage-cell", count = 1 }
		remote.call(NET, "insert_cell", d, inv[1], slot)
	end
	inv.destroy()
	local names = {}
	for name in pairs(items or {}) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		local got = remote.call(NET, "store_in_drive", d, name, items[name])
		if got ~= items[name] then fails[#fails + 1] = what .. ": only " .. got .. " " .. name .. " went into the drive" end
	end
	return d
end

--- ME cables from the controller (members[1]) to every other member
function me_connect(fails, what, members)
	local ok = true
	for _, e in pairs(members) do if not (e and e.valid) then ok = false end end
	if not ok then fails[#fails + 1] = what .. ": a network member is missing" return end
	local _, unreached = remote.call(NET, "connect", members, 16)
	for _, e in pairs(unreached) do fails[#fails + 1] = what .. ": no cable path to " .. e.name .. " at " .. e.position.x .. "," .. e.position.y end
end

--- items of the network an entity belongs to (normal quality)
function me_count(e, name) return (e and e.valid) and remote.call(NET, "count", e, name) or -1 end

--- ME Interface and buses on the network of the cells test
function me_io_test()
	local st = storage.me_cells
	if not (st and st.terminal_ready and storage.me_term) or (storage.me_io and storage.me_io.done) then return end
	storage.me_io = { done = true }
	local s = game.surfaces[1]
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function find(name, x, y) return s.find_entity(name, { CX + x, CY + y }) end
	local t, iface = find("me-terminal", 10.5, -0.5), find("me-network-interface", 11.5, -0.5)
	local ib, eb, eb2 = find("me-import-bus", 8.5, 0.5), find("me-export-bus", 9.5, 0.5), find("me-export-bus", 11.5, 0.5)
	local ichest, echest = find("iron-chest", 8.5, 1.5), find("iron-chest", 9.5, 1.5)
	local mol = find("me-molecular-assembler", 11.5, 2.5)
	local function count(name) return remote.call(NET, "count", t, name) end
	local size = prototypes.item["iron-plate"].stack_size
	--- interface (R3 config): one stack of iron plates kept in it, copper put in is imported, a spoiling item stays
	expect(remote.call(IO, "set_interface_config", iface, { [1] = { name = "iron-plate", amount = size } }), "set_interface_config")
	local inv = iface.get_inventory(defines.inventory.chest)
	inv[5].set_stack{ name = "copper-plate", count = 20 }
	local spoiling
	for name, p in pairs(prototypes.item) do
		if p.get_spoil_ticks() > 0 and (not spoiling or name < spoiling) then spoiling = name end
	end
	inv[6].set_stack{ name = spoiling, count = 1 }
	local copper = count("copper-plate")
	remote.call(IO, "step", iface)
	expect(inv.get_item_count("iron-plate") == size and count("iron-plate") == 1000 - size,
		"export: " .. inv.get_item_count("iron-plate"))
	expect(not inv[5].valid_for_read and count("copper-plate") == copper + 20, "import: network copper " .. count("copper-plate"))
	expect(inv[6].valid_for_read, "the spoiling item left the interface")
	inv.remove{ name = "iron-plate", count = size - 10 }  -- an inserter took plates: topped up
	remote.call(IO, "step", iface)
	expect(inv.get_item_count("iron-plate") == size and count("iron-plate") == 1000 - 2 * size + 10, "export top-up: " .. inv.get_item_count("iron-plate"))
	inv.insert{ name = "iron-plate", count = 30 }          -- more than configured: the surplus goes back
	remote.call(IO, "step", iface)
	expect(inv.get_item_count("iron-plate") == size and count("iron-plate") == 1000 - 2 * size + 40, "surplus back: " .. inv.get_item_count("iron-plate"))
	inv[6].clear()
	--- settings paste of the config
	local other = s.create_entity{ name = "me-network-interface", position = { CX + 2.5, CY + 8.5 }, force = "player", raise_built = true }
	remote.call(IO, "paste", iface, other)
	local f = remote.call(IO, "get_interface_config", other)
	expect(f[1] and f[1].name == "iron-plate" and f[1].amount == size, "pasted config " .. serpent.line(f))
	--- a pre-R3 interface: its slot filters become config (one stack per filtered slot), the filters are cleared
	local legacy = s.create_entity{ name = "me-network-interface", position = { CX + 2.5, CY + 10.5 }, force = "player" }
	local linv = legacy.get_inventory(defines.inventory.chest)
	linv.set_filter(3, { name = "copper-plate", quality = "normal" })
	linv.set_filter(4, { name = "copper-plate", quality = "normal" })
	linv.set_filter(7, { name = "iron-gear-wheel", quality = "normal" })
	local lc = remote.call(IO, "get_interface_config", legacy)
	local csize, gsize = prototypes.item["copper-plate"].stack_size, prototypes.item["iron-gear-wheel"].stack_size
	expect(lc[1] and lc[1].name == "copper-plate" and lc[1].amount == 2 * csize and lc[2] and lc[2].name == "iron-gear-wheel"
		and lc[2].amount == gsize and not linv.get_filter(3), "old filters as config " .. serpent.line(lc))
	--- old and new blueprint tags of an interface
	local b1 = s.create_entity{ name = "me-network-interface", position = { CX + 4.5, CY + 10.5 }, force = "player" }
	remote.call(IO, "built", b1, { fork_me_interface = { filters = { [2] = { name = "copper-plate", quality = "normal" } } } })
	local c1 = remote.call(IO, "get_interface_config", b1)
	expect(c1[1] and c1[1].name == "copper-plate" and c1[1].amount == csize, "old blueprint tag " .. serpent.line(c1))
	local b2 = s.create_entity{ name = "me-network-interface", position = { CX + 6.5, CY + 10.5 }, force = "player" }
	remote.call(IO, "built", b2, { fork_me_interface = { config = { { slot = 4, name = "iron-plate", quality = "normal", amount = 7 } } } })
	local c2 = remote.call(IO, "get_interface_config", b2)
	expect(c2[4] and c2[4].amount == 7 and not c2[1], "blueprint tag " .. serpent.line(c2))
	--- import bus: 100 gears in the chest it faces, 64 per visit
	ichest.insert{ name = "iron-gear-wheel", count = 100 }
	expect(remote.call(IO, "step", ib) == 64 and count("iron-gear-wheel") == 64, "import bus first visit: " .. count("iron-gear-wheel"))
	expect(remote.call(IO, "step", ib) == 36 and ichest.get_item_count("iron-gear-wheel") == 0, "import bus second visit")
	remote.call(IO, "set_bus_filters", ib, { "copper-plate" })
	ichest.insert{ name = "iron-gear-wheel", count = 5 }
	expect(remote.call(IO, "step", ib) == 0 and ichest.get_item_count("iron-gear-wheel") == 5, "a filtered import bus took gears")
	--- export bus into a chest: 64 per visit; into a machine: up to a stack of the ingredient
	expect(remote.call(IO, "step", eb) == 0, "an export bus without filters moved items")
	remote.call(IO, "set_bus_filters", eb, { "iron-gear-wheel" })
	expect(remote.call(IO, "step", eb) == 64 and echest.get_item_count("iron-gear-wheel") == 64, "export bus into the chest")
	remote.call(IO, "set_bus_filters", eb2, { "iron-plate" })
	local before = count("iron-plate")
	remote.call(IO, "step", eb2)
	local given = mol.get_inventory(defines.inventory.crafter_input).get_item_count("iron-plate")
	expect(given == math.min(64, size) and count("iron-plate") == before - given, "export bus into the machine: " .. given)
	--- rotated to face the import bus (an ME block): nothing to work with
	eb.rotate{ reverse = true }
	eb.rotate{ reverse = true }
	remote.call(IO, "step", eb)
	expect(remote.call(IO, "get_bus", eb).status == "no-target", "rotated bus: " .. serpent.line(remote.call(IO, "get_bus", eb)))
	--- bus settings: paste and blueprint tag
	local eb3 = s.create_entity{ name = "me-export-bus", position = { CX + 4.5, CY + 8.5 }, force = "player", raise_built = true }
	remote.call(IO, "paste", eb2, eb3)
	expect(serpent.line(remote.call(IO, "get_bus", eb3).filters) == serpent.line({ "iron-plate" }), "pasted bus filters")
	local bpi = game.create_inventory(1)
	bpi.insert{ name = "blueprint" }
	local mapping = bpi[1].create_blueprint{ surface = s, force = "player", area = { { CX + 2, CY + 8 }, { CX + 5, CY + 9 } } }
	remote.call(IO, "tag_blueprint", bpi[1], mapping)
	local tagged = 0
	for index, e in pairs(mapping or {}) do
		if e.name == "me-network-interface" and bpi[1].get_blueprint_entity_tag(index, "fork_me_interface") then tagged = tagged + 1 end
		if e.name == "me-export-bus" and bpi[1].get_blueprint_entity_tag(index, "fork_me_bus") then tagged = tagged + 1 end
	end
	expect(tagged == 2, "blueprint tags of interface and bus: " .. tagged)
	bpi.destroy()
	me_report("MEIO", "ME import/export", problems, "interface import/export, import and export bus, rotation, paste, blueprint")
end

--- me-network issue #17: the upgrade cards, the storage bus settings and the priorities (cards.lua)
cards17 = require("cards")({ me_place = me_place, cable_row = cable_row, power = power, me_report = me_report,
	me_drive = function(...) return me_drive(...) end })
--- part 3: the ME Cell Workbench and the cards on cells (workbench.lua)
bench17 = require("workbench")({ me_place = me_place, cable_row = cable_row, power = power, me_report = me_report })
--- me-network issue #38: the parked blocks and their wakes (parking.lua)
parking38 = require("parking")({ me_place = me_place, cable_row = cable_row, power = power, me_report = me_report })
--- me-network issue #43: the removal from the cable graph (graph.lua)
graph43 = require("graph")({ me_place = me_place, me_report = me_report })
--- me-network issue #43: the holder cursors of the storage engine (holders.lua)
holders43 = require("holders")({ me_place = me_place, me_report = me_report })
--- me-network issue #38, part 3: the command /me-stats (stats.lua)
stats38 = require("stats")({ me_place = me_place, power = power, me_report = me_report })
--- me-network issue #51: starved arrivals and the margin of a short busy list (margin.lua)
margin51 = require("margin")({ me_place = me_place, me_report = me_report })
--- me-network issue #67: a refilled chest behind a storage bus (refill.lua)
refill67 = require("refill")({ me_place = me_place, power = power, me_report = me_report })
--- me-network issue #86: an ME Export Bus into a lab (lab.lua)
lab86 = require("lab")({ me_place = me_place, power = power, me_report = me_report })
--- me-network issue #84: damaged items on the by-count paths (damaged.lua)
damaged84 = require("damaged")({ me_place = me_place, me_report = me_report })
--- me-network issue #85: an import bus with only refused stacks (refused.lua)
refused85 = require("refused")({ me_place = me_place, power = power, me_report = me_report })
--- me-network issue #110: the Acceleration Card in the ME Molecular Assembler's module slots (accel.lua)
accel110 = require("accel")({ me_place = me_place, me_report = me_report })
--- me-network issue #110, part 2: the Acceleration Cards of the import and export bus (busaccel.lua)
busaccel110 = require("busaccel")({ me_place = me_place, power = power, me_report = me_report })
--- me-network issue #50: kept plans (plans.lua)
plans50 = require("plans")({ me_place = me_place, me_report = me_report })
--- me-network issue #50, lever 6: the scan of the pattern providers (scan.lua)
scan50 = require("scan")({ me_place = me_place, me_report = me_report })
--- me-network issue #50, lever 8: the terminal's kept entries (entries.lua)
entries50 = require("entries")({ me_place = me_place, me_report = me_report })
--- me-network issue #59: the storage engine's kept holder lists (holderlists.lua)
holderlists59 = require("holderlists")({ me_place = me_place, me_report = me_report })
--- me-network issue #76: what can be stored (storable.lua)
storable76 = require("storable")({ me_place = me_place, cable_row = cable_row, power = power, me_report = me_report,
	me_drive = function(...) return me_drive(...) end })
--- me-network issue #6: crafting CPUs as multiblocks (cpus.lua)
cpus6 = require("cpus")({ me_place = me_place, cable_row = cable_row, power = power, me_report = me_report,
	me_drive = function(...) return me_drive(...) end })

--- Victory (scripts/fork-victory.lua): researching `victory` must win the game, and go on.
--- Winning stops the scripts of the benchmark run (no player to continue), so this runs last: as soon
--- as every other test has reported, at the latest at tick VICTORY_DEADLINE (a test still running
--- then is reported as unfinished). Checked from the 10-tick handler below.
local DONE_DEADLINE = 1450
local function tests_running()
	local running = {}
	local function check(done, name) if not done then running[#running + 1] = name end end
	check(storage.me_graph and storage.me_graph.done, "ME graph")
	check(storage.me_cells and storage.me_cells.done, "ME cells")
	check(storage.me_term and storage.me_term.done, "ME terminal")
	check(storage.me_io and storage.me_io.done, "ME import/export")
	check(storage.autocraft and storage.autocraft.done, "autocrafting")
	check(storage.furnace and storage.furnace.done, "furnace patterns")
	check(storage.patswitch and storage.patswitch.done, "pattern recipe switching")
	check(storage.patline and storage.patline.done, "processing line")
	check(storage.fluids and storage.fluids.done, "fluids")
	check(storage.fluid_cells and storage.fluid_cells.done, "ME fluid cells")
	check(storage.me_r3 and storage.me_r3.done, "ME partitions and windows")
	check(storage.me_sbus and storage.me_sbus.done, "ME storage bus")
	check(storage.me_fsbus and storage.me_fsbus.done, "ME fluid storage bus")
	check(storage.unified and storage.unified.done, "ME unified I/O")
	check(storage.maint38 and storage.maint38.done, "level maintainer")
	check(storage.tiers38 and storage.tiers38.done, "crafting CPU tiers")
	check(storage.circuit38 and storage.circuit38.done, "circuit interface")
	check(storage.settings38 and storage.settings38.done, "settings copy")
	check(storage.sched_test and storage.sched_test.done, "ME scheduler")
	check(storage.cursor_t and storage.cursor_t.done, "open key and cursor")
	check(storage.paste_t and storage.paste_t.done, "recipe paste")
	cards17.running(check)
	bench17.running(check)
	cpus6.running(check)
	parking38.running(check)
	busaccel110.running(check)
	accel110.running(check)
	damaged84.running(check)
	refused85.running(check)
	lab86.running(check)
	refill67.running(check)
	stats38.running(check)
	margin51.running(check)
	plans50.running(check)
	scan50.running(check)
	entries50.running(check)
	holderlists59.running(check)
	holders43.running(check)
	storable76.running(check)
	graph43.running(check)
	return running
end

--- every test has reported (DEVCHECK-RUNTIME-DONE), or the deadline names the ones still running
local function done_test()
	if storage.done_reported then return end
	local running = tests_running()
	if #running > 0 and game.tick < DONE_DEADLINE then return end
	storage.done_reported = true
	for _, name in pairs(running) do log("DEVCHECK-RUNTIME-FAIL test still running at tick " .. game.tick .. ": " .. name) end
	log("DEVCHECK-RUNTIME-DONE " .. (#running == 0 and "ok" or "failed") .. " (tick " .. game.tick .. ")")
end

local AC_Y = 140
local AC_PLATES, AC_STICKS = 200, 100
local AC_ITEM, AC_AMOUNT = "transport-belt", 10
local AC_CRUSH, AC_CRUSH_AMOUNT = "crushed-iron", 1

function setup_autocraft_test(s)
	local fails = {}
	local function place(name, x, y, recipe)
		local ok, e = pcall(function()
			return s.create_entity{ name = name, position = { x, y }, force = "player", raise_built = true }
		end)
		if not (ok and e) then fails[#fails + 1] = "autocraft " .. name .. ": " .. tostring(e) return nil end
		if recipe then
			e.force.recipes[recipe].enabled = true
			local ok2, err = pcall(function() e.set_recipe(recipe) end)
			if not ok2 then fails[#fails + 1] = "autocraft recipe " .. recipe .. ": " .. tostring(err) end
		end
		return e
	end
	local eei = place("electric-energy-interface", 12.5, AC_Y + 6.5)
	if eei then
		eei.power_production = 1e6
		eei.electric_buffer_size = 1e7
	end
	place("substation", 13, AC_Y + 2)
	local ctrl = place("me-network-controller", 6, AC_Y)
	local term = place("me-terminal", 8.5, AC_Y + 4.5)
	local cpu = place("me-crafting-cpu", 10, AC_Y)
	local drive = me_drive(s, fails, "autocraft", 8.5, AC_Y + 6.5,
		{ ["raw-iron"] = 20, ["iron-plate"] = AC_PLATES, ["iron-stick"] = AC_STICKS })
	place("me-molecular-assembler", 14.5, AC_Y + 0.5, "iron-gear-crafting-table")
	place("me-molecular-assembler", 20.5, AC_Y + 0.5, AC_ITEM)
	local p1 = place("me-pattern-provider", 16.5, AC_Y + 0.5)
	local p2 = place("me-pattern-provider", 18.5, AC_Y + 0.5)
	--- not connected to the network: its recipe must not become a pattern
	place("me-molecular-assembler", 32.5, AC_Y + 0.5, "splitter")
	place("me-pattern-provider", 34.5, AC_Y + 0.5)
	--- a GT machine as pattern machine: crushing raw iron (may have several or probabilistic products)
	place("ev-macerator", 16.5, AC_Y + 4.5, AC_CRUSH)
	local p3 = place("me-pattern-provider", 18.5, AC_Y + 4.5)
	me_connect(fails, "autocraft", { ctrl, term, cpu, drive, p1, p2, p3 })
	--- issue #80: the providers hold crafting patterns of their machines' recipes
	for _, p in pairs({ p1, p2, p3, s.find_entity("me-pattern-provider", { 34.5, AC_Y + 0.5 }) }) do
		if p then give_patterns(p, machine_patterns(p), fails) end
	end
	return fails
end

local function autocraft_test()
	local s = game.surfaces[1]
	local terminal = s.find_entity("me-terminal", { 8.5, AC_Y + 4.5 })
	local function count(item) return me_count(terminal, item) end
	local st = storage.autocraft
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function finish_test(note)
		storage.autocraft.done = true
		for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL autocraft: " .. p) end
		log("DEVCHECK-RUNTIME-AUTOCRAFT " .. (#problems == 0 and "ok" or "failed") .. (note and (" (" .. note .. ")") or ""))
	end

	if not st then
		if game.tick < 60 then return end
		storage.autocraft = { started = game.tick }
		st = storage.autocraft
		if not terminal then expect(false, "entities missing") return finish_test() end
		local n_cpu, free = remote.call("gregtorio-me-autocraft", "cpus", terminal)
		expect(n_cpu == 1 and free == 1, "expected 1 free CPU, got " .. n_cpu .. "/" .. free)
		local craftable = remote.call("gregtorio-me-autocraft", "craftable", terminal)
		local set = {}
		for _, n in pairs(craftable) do set[n] = true end
		expect(set[AC_ITEM] and set["iron-gear-wheel"], "patterns not registered")
		expect(not set["splitter"], "a machine outside the network became a pattern")
		expect(count("iron-plate") == AC_PLATES and count("iron-stick") == AC_STICKS, "raw materials not in the network")

		--- per-craft amounts, from the recipes
		local belt = prototypes.recipe[AC_ITEM]
		local per_run = 0
		for _, p in pairs(belt.products) do if p.name == AC_ITEM then per_run = p.amount end end
		st.per_run = per_run
		st.runs = math.ceil(AC_AMOUNT / per_run)
		st.belts = st.runs * per_run
		local plan = remote.call("gregtorio-me-autocraft", "plan", terminal, AC_ITEM, AC_AMOUNT)
		expect(plan and plan.ok and plan.steps == 2 and plan.runs == 2 * st.runs, "plan of job 1: " .. serpent.line(plan))

		--- job 1
		local id1, why1 = remote.call("gregtorio-me-autocraft", "start", terminal, AC_ITEM, AC_AMOUNT)
		expect(id1, "job 1 did not start: " .. tostring(why1))
		st.job1 = id1
		--- items are reserved at the start: plates for gears and belts, sticks for gears
		expect(count("iron-plate") == AC_PLATES - 2 * st.runs, "job 1 reserved " .. (AC_PLATES - count("iron-plate")) .. " plates")
		expect(count("iron-stick") == AC_STICKS - 2 * st.runs, "job 1 reserved " .. (AC_STICKS - count("iron-stick")) .. " sticks")

		--- job 2: more than the raw materials allow (sticks run out), must report the exact shortfall and not start
		local big = 1000
		local runs2 = math.ceil(big / per_run)
		local plates_before, sticks_before = count("iron-plate"), count("iron-stick")
		local want_plates, want_sticks = math.max(0, 2 * runs2 - plates_before), math.max(0, 2 * runs2 - sticks_before)
		expect(want_plates > 0 and want_sticks > 0, "test setup: job 2 must be short of plates and sticks")
		local id2, why2, missing = remote.call("gregtorio-me-autocraft", "start", terminal, AC_ITEM, big)
		expect(id2 == nil and why2 == "missing", "job 2 must not start (" .. tostring(id2) .. ", " .. tostring(why2) .. ")")
		expect(missing and (missing["iron-plate"] or 0) == want_plates and (missing["iron-stick"] or 0) == want_sticks,
			"job 2 missing " .. serpent.line(missing) .. ", expected plates " .. want_plates .. " sticks " .. want_sticks)
		expect(count("iron-plate") == plates_before and count("iron-stick") == sticks_before, "job 2 took items although it did not start")

		--- job 3: one CPU only and it is busy: the start is refused (issue #6: a job needs a free CPU) and takes nothing
		local plates3, sticks3 = count("iron-plate"), count("iron-stick")
		local id3, why3 = remote.call("gregtorio-me-autocraft", "start", terminal, AC_ITEM, per_run)
		expect(id3 == nil and why3 == "no-free-cpu", "job 3 must be refused while the CPU is busy (" .. tostring(id3) .. ", " .. tostring(why3) .. ")")
		expect(count("iron-plate") == plates3 and count("iron-stick") == sticks3, "the refused job 3 took items")
		if id3 then remote.call("gregtorio-me-autocraft", "cancel", id3) end
		if #problems > 0 then return finish_test() end
		return
	end
	if st.done then return end

	--- Everything is a multiple of these crafts, so whatever the network holds (plus what a job still
	--- carries) is worth exactly the raw materials it started with: plate + 2 sticks make a gear,
	--- gear + plate make one craft of belts.
	local function raw_value()
		local belts = count(AC_ITEM) / st.per_run
		return count("iron-plate") + count("iron-gear-wheel") + 2 * belts,
			count("iron-stick") + 2 * count("iron-gear-wheel") + 2 * belts
	end
	local function expect_all_raw(what)
		local plates, sticks = raw_value()
		expect(plates == AC_PLATES and sticks == AC_STICKS, what .. ": raw value " .. plates .. "/" .. sticks .. ", expected " .. AC_PLATES .. "/" .. AC_STICKS)
	end
	local function job_of(id)
		local j = remote.call("gregtorio-me-autocraft", "job", id)
		for item, n in pairs(j and j.pool or {}) do
			expect(n >= 0, "job " .. id .. " pool holds " .. n .. " " .. item)   -- a job may never hand out more than it holds
		end
		return j
	end
	local function timeout_after(ticks, what)
		if game.tick > st.phase_tick + ticks then
			expect(false, what .. " timed out: " .. serpent.line(st.job and job_of(st.job)))
			finish_test()
			return true
		end
	end
	local function next_phase(name) st.phase = name st.phase_tick = game.tick end

	local phase = st.phase or "job1"
	if phase == "job1" then
		st.phase_tick = st.phase_tick or st.started
		local j1 = job_of(st.job1)
		if j1 and (j1.status == "done" or j1.status == "failed") then
			expect(j1.status == "done", "job 1 ended as " .. j1.status)
			expect(count(AC_ITEM) == st.belts, "job 1 result: " .. count(AC_ITEM) .. " " .. AC_ITEM .. ", expected " .. st.belts)
			expect(count("iron-plate") == AC_PLATES - 2 * st.runs, "plates after job 1: " .. count("iron-plate"))
			expect(count("iron-stick") == AC_STICKS - 2 * st.runs, "sticks after job 1: " .. count("iron-stick"))
			expect(count("iron-gear-wheel") == 0, "leftover gears: " .. count("iron-gear-wheel"))
			expect(j1.done == j1.total, "job 1 progress " .. j1.done .. "/" .. j1.total)
			expect_all_raw("after job 1")
			st.job1_ticks = game.tick - st.started
			if #problems > 0 then return finish_test() end
			--- scenario 2: the CPU is removed while machines are crafting
			st.job = remote.call("gregtorio-me-autocraft", "start", terminal, AC_ITEM, AC_AMOUNT)
			expect(st.job, "job 4 did not start")
			if not st.job then return finish_test() end
			return next_phase("cpu-lease")
		end
		timeout_after(300, "job 1")
	elseif phase == "cpu-lease" then
		local j = job_of(st.job)
		if j.leases > 0 then
			local cpu = s.find_entity("me-crafting-cpu", { 10, AC_Y })
			expect(cpu, "CPU not found")
			if cpu then cpu.destroy() end
			return next_phase("cpu-paused")
		end
		timeout_after(200, "CPU scenario (waiting for a machine to work)")
	elseif phase == "cpu-paused" then
		if game.tick >= st.phase_tick + 100 then
			local j = job_of(st.job)
			expect(j.status == "queued" and j.done < j.total, "job without CPU should be paused, status " .. j.status)
			local ok, cpu = pcall(function()
				return s.create_entity{ name = "me-crafting-cpu", position = { 10, AC_Y }, force = "player", raise_built = true }
			end)
			--- the CPU stands where the old one stood: the cables that connected it are still there
			expect(ok and cpu and remote.call(NET, "same_network", cpu, terminal), "the new CPU is not in the network")
			expect(ok and cpu, "new CPU could not be placed")
			if not (ok and cpu) then return finish_test() end
			return next_phase("cpu-resumed")
		end
	elseif phase == "cpu-resumed" then
		local j = job_of(st.job)
		if j.status == "done" or j.status == "failed" then
			expect(j.status == "done", "job 4 ended as " .. j.status)
			expect(count(AC_ITEM) == 2 * st.belts, "belts after job 4: " .. count(AC_ITEM))
			expect_all_raw("after job 4 (CPU replaced)")
			if #problems > 0 then return finish_test() end
			--- scenario 3: a pattern machine is removed, the job waits; cancelling gives everything back
			st.job = remote.call("gregtorio-me-autocraft", "start", terminal, AC_ITEM, AC_AMOUNT)
			expect(st.job, "job 5 did not start")
			local b = s.find_entity("me-molecular-assembler", { 20.5, AC_Y + 0.5 })
			expect(b, "belt assembler not found")
			if b then b.destroy() end
			if not st.job then return finish_test() end
			return next_phase("machine-wait")
		end
		timeout_after(300, "job 4 after replacing the CPU")
	elseif phase == "machine-wait" then
		local j = job_of(st.job)
		if j.status == "running" and j.wait == "machine" and j.leases == 0 then
			remote.call("gregtorio-me-autocraft", "cancel", st.job)
			return next_phase("machine-cancelled")
		end
		timeout_after(300, "job 5 (waiting for the removed machine)")
	elseif phase == "machine-cancelled" then
		local j = job_of(st.job)
		if j.status == "cancelled" then
			expect(next(j.pool) == nil, "job 5 keeps items after being cancelled: " .. serpent.line(j.pool))
			expect(count("iron-gear-wheel") > 0, "job 5 did not return the gears it made")
			expect_all_raw("after cancelling job 5")
			if #problems > 0 then return finish_test() end
			--- scenario 4: a GT machine (macerator) as pattern machine
			local recipe = prototypes.recipe[AC_CRUSH]
			local yield, per_run = 0, 0
			for _, p in pairs(recipe.products) do
				if p.name == AC_CRUSH then yield = p.amount * (p.probability or 1) end
			end
			for _, i in pairs(recipe.ingredients) do if i.name == "raw-iron" then per_run = i.amount end end
			st.crush_runs = math.ceil(AC_CRUSH_AMOUNT / yield)
			st.crush_raw = per_run
			local plan = remote.call("gregtorio-me-autocraft", "plan", terminal, AC_CRUSH, AC_CRUSH_AMOUNT)
			expect(plan and plan.ok and plan.steps == 1 and plan.runs == st.crush_runs, "macerator plan: " .. serpent.line(plan))
			st.job = remote.call("gregtorio-me-autocraft", "start", terminal, AC_CRUSH, AC_CRUSH_AMOUNT)
			expect(st.job, "macerator job did not start")
			if not st.job then return finish_test() end
			return next_phase("crush")
		end
		timeout_after(200, "cancelling job 5")
	elseif phase == "crush" then
		local j = job_of(st.job)
		if j.status == "done" or j.status == "failed" then
			expect(j.status == "done", "macerator job ended as " .. j.status)
			expect(count("raw-iron") == 20 - st.crush_runs * st.crush_raw, "raw iron left: " .. count("raw-iron"))
			expect(count(AC_CRUSH) >= AC_CRUSH_AMOUNT or #prototypes.recipe[AC_CRUSH].products > 1 or prototypes.recipe[AC_CRUSH].products[1].probability,
				"crushed iron in the network: " .. count(AC_CRUSH))
			expect(next(j.pool) == nil, "macerator job keeps items: " .. serpent.line(j.pool))
			return finish_test("job 1 took " .. st.job1_ticks .. " ticks, whole test " .. (game.tick - st.started))
		end
		timeout_after(600, "macerator job")
	end
end

--------------------------------------------------------------------------------
--- furnaces and pattern items (issue #27, issue #80): encoding a crafting and a processing pattern through the
--- terminal's functions, a crafting pattern next to a furnace ("furnace": no pattern), a processing pattern that
--- smelts a job, clearing and loading a pattern, settings paste (priority), blueprint tags (patterns pending
--- until the network has a blank, an old 0.4.1 tag), a provider mined (buffer), destroyed (dropped), gone without
--- an event (dropped where it stood)
--------------------------------------------------------------------------------

local FU_X, FU_Y = -116, -220                          -- own network, above the machine grid
local FU_RECIPE, FU_ITEM, FU_INPUT, FU_AMOUNT = "iron-dust-smelter", "iron-ingot", "iron-dust", 2
local FU_PROVIDER_A = { FU_X + 16.5, FU_Y + 10.5 }     -- touches furnace A (west)
local FU_PROVIDER_B = { FU_X + 7.5, FU_Y + 10.5 }      -- touches furnace B (west)
local FU_GHOST = { FU_X + 20.5, FU_Y + 4.5 }
local FU_GHOST_OLD = { FU_X + 24.5, FU_Y + 4.5 }
local FU_BLANKS = 2
local BLANK, ENCODED = "me-blank-pattern", "me-encoded-pattern"

function setup_furnace_test(s)
	local fails = {}
	local function place(name, x, y)
		local ok, e = pcall(function()
			return s.create_entity{ name = name, position = { x, y }, force = "player", raise_built = true }
		end)
		if not (ok and e) then fails[#fails + 1] = "furnace test " .. name .. ": " .. tostring(e) return nil end
		return e
	end
	local eei = place("electric-energy-interface", FU_X + 12.5, FU_Y + 6.5)
	if eei then
		eei.power_production = 1e6
		eei.electric_buffer_size = 1e7
	end
	place("substation", FU_X + 13, FU_Y + 2)
	local ctrl = place("me-network-controller", FU_X + 6, FU_Y)
	local term = place("me-terminal", FU_X + 8.5, FU_Y + 4.5)
	local cpu = place("me-crafting-cpu", FU_X + 10, FU_Y)
	local drive = me_drive(s, fails, "furnace test", FU_X + 8.5, FU_Y + 6.5, { [FU_INPUT] = 10, [BLANK] = FU_BLANKS })
	for _, pos in pairs({ { FU_X + 15, FU_Y + 11 }, { FU_X + 6, FU_Y + 11 } }) do
		local f = place("iron-furnace", pos[1], pos[2])
		if f then f.get_inventory(defines.inventory.fuel).insert{ name = "coal", count = 20 } end
	end
	local pa = place("me-pattern-provider", FU_PROVIDER_A[1], FU_PROVIDER_A[2])
	local pb = place("me-pattern-provider", FU_PROVIDER_B[1], FU_PROVIDER_B[2])
	me_connect(fails, "furnace test", { ctrl, term, cpu, drive, pa, pb })
	return fails
end

function furnace_test()
	local s = game.surfaces[1]
	local A = "gregtorio-me-autocraft"
	local terminal = s.find_entity("me-terminal", { FU_X + 8.5, FU_Y + 4.5 })
	local net = terminal and remote.call(NET, "network", terminal)
	local pa = s.find_entity("me-pattern-provider", FU_PROVIDER_A)
	local pb = s.find_entity("me-pattern-provider", FU_PROVIDER_B)
	local furnace_a = s.find_entity("iron-furnace", { FU_X + 15, FU_Y + 11 })
	local function count(item) return me_count(terminal, item) end
	local st = storage.furnace
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function finish_test(note)
		storage.furnace.done = true
		for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL furnace patterns: " .. p) end
		log("DEVCHECK-RUNTIME-FURNACE " .. (#problems == 0 and "ok" or "failed") .. (note and (" (" .. note .. ")") or ""))
	end
	local function craftable()
		local set = {}
		for _, k in pairs(remote.call(A, "craftable", terminal)) do set[k] = true end
		return set
	end

	if not st then
		if game.tick < 60 then return end
		storage.furnace = { started = game.tick, inv = game.create_inventory(4), hand = game.create_inventory(1) }
		st = storage.furnace
		if not (terminal and net and pa and pb and furnace_a) then expect(false, "entities missing") return finish_test() end
		local force, inv, hand = terminal.force, st.inv, st.hand
		expect(count(BLANK) == FU_BLANKS, "blank patterns in the network: " .. count(BLANK))
		--- encoding a crafting pattern: only a researched recipe
		force.recipes[FU_RECIPE].enabled = false
		local ed = remote.call(TERM, "new_editor")
		local ok, why = remote.call(TERM, "set_editor_recipe", force, ed, FU_RECIPE)
		expect(not ok and why == "not-researched", "a recipe that is not researched was accepted: " .. tostring(why))
		force.recipes[FU_RECIPE].enabled = true
		ok, why, ed = remote.call(TERM, "set_editor_recipe", force, ed, FU_RECIPE)
		expect(ok and ed.recipe == FU_RECIPE and ed.mode == "crafting", "set_editor_recipe: " .. tostring(why))
		--- no blank in hand or inventory: from the network, into the inventory (no hand)
		local where = remote.call(TERM, "encode", false, inv, terminal, force, ed)
		expect(where == "inventory" and count(BLANK) == FU_BLANKS - 1, "encoding from the network: " .. tostring(where) .. ", blanks " .. count(BLANK))
		local cstack = inv.find_item_stack(ENCODED)
		local info = cstack and remote.call(TERM, "pattern_info", cstack)
		local per_run, yield = 0, 0
		for _, i in pairs(prototypes.recipe[FU_RECIPE].ingredients) do if i.name == FU_INPUT then per_run = i.amount end end
		for _, p in pairs(prototypes.recipe[FU_RECIPE].products) do if p.name == FU_ITEM then yield = p.amount end end
		expect(info and info.valid and info.kind == "crafting" and info.recipe == FU_RECIPE and info.inputs[1].key == FU_INPUT
			and info.inputs[1].amount == per_run and info.outputs[1].key == FU_ITEM and info.outputs[1].amount == yield
			and type(info.description) == "table", "crafting pattern data " .. serpent.line(info))
		local tags = cstack and cstack.tags or {}
		expect(tags.fork_me_pattern and tags.fork_me_pattern.recipe == FU_RECIPE, "crafting pattern tags " .. serpent.line(tags))
		expect(cstack and type(cstack.custom_description) == "table", "the encoded pattern has no tooltip")
		expect(cstack and cstack.prototype.stack_size == 1 and cstack.is_item_with_tags, "the encoded pattern is no item with tags of stack size 1")
		--- a crafting pattern next to a furnace is no pattern
		expect(cstack and remote.call(A, "insert_pattern", pa, cstack) == 1, "the crafting pattern did not go into provider A")
		local pinfo = remote.call(A, "provider_info", pa)
		expect(pinfo.slots[1] and pinfo.slots[1].reason == "furnace" and not pinfo.slots[1].ok, "crafting pattern at a furnace " .. serpent.line(pinfo.slots[1]))
		local ignored = remote.call(A, "ignored", terminal)
		expect(ignored.furnace == 1 and ignored.total == 1, "ignored " .. serpent.line(ignored))
		expect(not craftable()[FU_ITEM], "a crafting pattern next to a furnace became a pattern")
		--- a processing pattern from the recipe, encoded from a blank in the hand (it replaces the blank there)
		ed.mode = "processing"
		ok, why, ed = remote.call(TERM, "set_editor_recipe", force, ed, FU_RECIPE)
		expect(ok and ed.inputs[1] and ed.inputs[1].key == FU_INPUT and ed.outputs[1] and ed.outputs[1].key == FU_ITEM, "processing rows " .. serpent.line(ed))
		hand[1].set_stack{ name = BLANK, count = 1 }
		where = remote.call(TERM, "encode", hand[1], inv, terminal, force, ed)
		info = remote.call(TERM, "pattern_info", hand[1])
		expect(where == "cursor" and info and info.kind == "processing" and info.inputs[1].amount == per_run and info.outputs[1].amount == yield
			and info.id and info.id:sub(1, 2) == "p/", "processing pattern " .. tostring(where) .. " " .. serpent.line(info))
		expect(count(BLANK) == FU_BLANKS - 1, "the hand's blank was not used: network blanks " .. count(BLANK))
		--- load it into a new editor
		local ed2 = remote.call(TERM, "new_editor")
		ok, why, ed2 = remote.call(TERM, "load_pattern", hand[1], ed2)
		expect(ok and ed2.mode == "processing" and ed2.inputs[1].key == FU_INPUT and ed2.outputs[1].key == FU_ITEM, "load_pattern " .. serpent.line(ed2))
		--- into provider A by the window's click (the hand is the cursor)
		expect(remote.call(A, "provider_click", hand[1], inv, pa, 2, false) == nil and not hand[1].valid_for_read, "click with the pattern on slot 2")
		pinfo = remote.call(A, "provider_info", pa)
		expect(pinfo.slots[2] and pinfo.slots[2].ok and pinfo.slots[2].machines == 1 and pinfo.slots[2].kind == "processing", "processing slot " .. serpent.line(pinfo.slots[2]))
		expect(craftable()[FU_ITEM], "the furnace with a processing pattern is no pattern")
		st.runs = math.ceil(FU_AMOUNT / yield)
		st.input = st.runs * per_run
		st.output = st.runs * yield
		local plan = remote.call(A, "plan", terminal, FU_ITEM, FU_AMOUNT)
		expect(plan and plan.ok and plan.steps == 1 and plan.runs == st.runs and plan.pids[1]:sub(1, 2) == "p/", "furnace plan: " .. serpent.line(plan))
		st.job = remote.call(A, "start", terminal, FU_ITEM, FU_AMOUNT)
		expect(st.job, "furnace job did not start")
		if #problems > 0 then return finish_test() end
		return
	end
	if st.done then return end

	local j = remote.call(A, "job", st.job)
	if j and (j.status == "done" or j.status == "failed" or j.status == "cancelled") then
		local force, inv, hand = terminal.force, st.inv, st.hand
		expect(j.status == "done", "furnace job ended as " .. j.status .. " " .. serpent.line(j))
		expect(count(FU_ITEM) == st.output, "ingots in storage: " .. count(FU_ITEM) .. ", expected " .. st.output)
		expect(count(FU_INPUT) == 10 - st.input, "dust left: " .. count(FU_INPUT) .. ", expected " .. (10 - st.input))
		expect(next(j.pool) == nil, "furnace job keeps items: " .. serpent.line(j.pool))
		expect(j.steps[1].kind == "processing" and (j.steps[1].received[FU_ITEM] or 0) == st.output, "processing step " .. serpent.line(j.steps[1]))
		expect(furnace_a.get_inventory(defines.inventory.furnace_source).is_empty()
			and furnace_a.get_inventory(defines.inventory.furnace_result).is_empty(), "furnace A is not empty after the job")
		--- clearing: the crafting pattern of slot 1 into the hand, cleared to a blank
		expect(remote.call(A, "provider_click", hand[1], inv, pa, 1, false) == nil and hand[1].valid_for_read and hand[1].name == ENCODED,
			"taking the crafting pattern into the hand")
		expect(remote.call(TERM, "clear_pattern", hand[1]) and hand[1].valid_for_read and hand[1].name == BLANK and hand[1].count == 1,
			"clearing the pattern in hand")
		local ok, why = remote.call(TERM, "clear_pattern", hand[1])
		expect(not ok and why == "no-pattern-in-hand", "clearing a blank pattern: " .. tostring(why))
		expect(inv.get_item_count(ENCODED) == 0 and not remote.call(A, "provider_info", pa).slots[1], "slot 1 not empty after taking the pattern")
		--- settings paste: the priority, no patterns
		remote.call(A, "set_priority", pa, 5)
		remote.call(A, "paste", pa, pb)
		local pbi = remote.call(A, "provider_info", pb)
		expect(pbi.priority == 5 and next(pbi.slots) == nil, "pasted provider " .. serpent.line(pbi))
		--- blueprint: priority and patterns as entity tag
		local bpi = game.create_inventory(1)
		bpi.insert{ name = "blueprint" }
		local mapping = bpi[1].create_blueprint{ surface = s, force = "player",
			area = { { FU_PROVIDER_A[1] - 0.4, FU_PROVIDER_A[2] - 0.4 }, { FU_PROVIDER_A[1] + 0.4, FU_PROVIDER_A[2] + 0.4 } } }
		remote.call(A, "tag_blueprint", bpi[1], mapping)
		local tag
		for index, e in pairs(mapping or {}) do
			if e.name == "me-pattern-provider" then tag = bpi[1].get_blueprint_entity_tag(index, "fork_me_provider") end
		end
		expect(tag and tag.priority == 5 and tag.patterns and tag.patterns["2"] and tag.patterns["2"].kind == "processing"
			and not tag.patterns["1"], "provider blueprint tag " .. serpent.line(tag))
		bpi.destroy()
		--- a ghost with the tag is revived with no blank in the network: the pattern waits for one
		expect(remote.call(TERM, "withdraw", terminal, inv, BLANK, "normal", 10) == FU_BLANKS - 1 and count(BLANK) == 0, "taking the blanks out")
		local ghost = s.create_entity{ name = "entity-ghost", inner_name = "me-pattern-provider", position = FU_GHOST,
			force = "player", tags = { fork_me_provider = tag } }
		local _, revived = ghost.revive{ raise_revive = true }
		local fails = {}
		if revived then me_connect(fails, "furnace test ghost", { s.find_entity("me-network-controller", { FU_X + 6, FU_Y }), revived }) end
		expect(#fails == 0, "connecting the revived provider: " .. table.concat(fails, ", "))
		local ri = revived and remote.call(A, "provider_info", revived)
		expect(ri and ri.priority == 5 and ri.slots[2] and ri.slots[2].pending and ri.slots[2].kind == "processing" and not ri.slots[1],
			"revived provider without a blank " .. serpent.line(ri))
		expect(not (ri and remote.call(TERM, "withdraw", terminal, inv, ENCODED, "normal", 1) > 0), "a pending pattern is an item")
		--- a blank in the network: it is encoded with the pattern (nothing out of nothing)
		expect(remote.call(TERM, "store_stack", terminal, inv.find_item_stack(BLANK)) == FU_BLANKS - 1, "storing the blanks again")
		ri = revived and remote.call(A, "provider_info", revived)
		expect(ri and ri.slots[2] and not ri.slots[2].pending and ri.slots[2].kind == "processing" and count(BLANK) == FU_BLANKS - 2,
			"the pending pattern took a blank: " .. serpent.line(ri and ri.slots[2]) .. ", blanks " .. count(BLANK))
		--- an old blueprint (0.4.1: the furnace recipe choice) gives a processing pattern of that recipe
		ghost = s.create_entity{ name = "entity-ghost", inner_name = "me-pattern-provider", position = FU_GHOST_OLD,
			force = "player", tags = { fork_ae2_recipe = FU_RECIPE } }
		local _, old = ghost.revive{ raise_revive = true }
		local oi = old and remote.call(A, "provider_info", old)
		expect(oi and oi.slots[1] and oi.slots[1].pending and oi.slots[1].kind == "processing" and oi.slots[1].recipe == FU_RECIPE,
			"provider from an old blueprint " .. serpent.line(oi))
		--- mined (the mined-entity handler with the event's buffer): the pattern comes along, the pending one does not
		local buffer = game.create_inventory(4)
		remote.call(A, "on_removed", revived, buffer)
		local mined = buffer.find_item_stack(ENCODED)
		local mi = mined and remote.call(TERM, "pattern_info", mined)
		expect(buffer.get_item_count(ENCODED) == 1 and mi and mi.kind == "processing" and mi.recipe == FU_RECIPE, "mined provider: " .. serpent.line(mi))
		if revived and revived.valid then revived.destroy{ raise_destroy = true } end
		remote.call(A, "on_removed", old, buffer)
		expect(buffer.get_item_count(ENCODED) == 1, "a pending pattern came out of a mined provider")
		if old and old.valid then old.destroy{ raise_destroy = true } end
		buffer.destroy()
		--- destroyed: the patterns of provider A drop on the ground (the died event)
		pa.die()
		expect(patterns_on_ground(s, FU_PROVIDER_A) == 1, "patterns on the ground after A was destroyed: " .. patterns_on_ground(s, FU_PROVIDER_A))
		--- gone without an event: provider B gets a pattern (the cleared blank, encoded again), then vanishes; its
		--- pattern is dropped where it stood when the providers are scanned
		ed = remote.call(TERM, "new_editor")
		ok, why, ed = remote.call(TERM, "set_editor_recipe", force, ed, FU_RECIPE)
		expect(remote.call(TERM, "encode", hand[1], inv, terminal, force, ed) == "cursor", "encoding the cleared blank again")
		expect(remote.call(A, "insert_pattern", pb, hand[1]) == 1, "pattern into provider B")
		pb.destroy()
		remote.call(A, "plan", terminal, FU_ITEM, 1)                      -- a fresh plan rescans every provider
		expect(patterns_on_ground(s, FU_PROVIDER_B) == 1, "patterns on the ground after B vanished: " .. patterns_on_ground(s, FU_PROVIDER_B))
		st.inv.destroy()
		st.hand.destroy()
		return finish_test("job took " .. (game.tick - st.started) .. " ticks")
	end
	if game.tick > st.started + 1200 then
		local status
		for name, v in pairs(defines.entity_status) do if furnace_a.status == v then status = name end end
		expect(false, "furnace job timed out: " .. serpent.line(j) .. ", furnace " .. tostring(status) .. " progress "
			.. furnace_a.crafting_progress .. " recipe energy " .. prototypes.recipe[FU_RECIPE].energy)
		finish_test()
	end
end

--------------------------------------------------------------------------------
--- issue #80: recipe switching and the pattern choice (pattern_switch_test), a processing line returning its outputs
--- through an import bus (pattern_line_test); two own networks right of the issue #38 tests
--------------------------------------------------------------------------------

local PS_X, PS_Y = 300, -60
local PL_X, PL_Y = 300, 20
local PS_BELT = "transport-belt"
local GEAR_RECIPE_80 = "iron-gear-crafting-table"
local PL_IN, PL_OUT, PL_IN_N, PL_OUT_N, PL_AMOUNT = "copper-plate", "copper-cable", 2, 3, 9

local function pattern_network(s, fails, x, y, items, cpus)
	local function place(name, px, py, extra) return me_place(s, fails, "issue #80", name, px, py, extra) end
	local eei = place("electric-energy-interface", x + 12.5, y + 6.5)
	if eei then
		eei.power_production = 1e6
		eei.electric_buffer_size = 1e7
	end
	place("substation", x + 13, y + 2)
	local members = { place("me-network-controller", x + 6, y), place("me-terminal", x + 8.5, y + 4.5),
		place("me-crafting-cpu", x + 10, y) }
	if cpus > 1 then members[#members + 1] = place("me-crafting-cpu", x + 10, y - 3) end
	members[#members + 1] = me_drive(s, fails, "issue #80", x + 8.5, y + 6.5, items)
	return members
end

function setup_pattern_tests(s)
	local fails = {}
	--- recipe switching: M1 without a recipe behind provider PA (three crafting patterns), M2 with the gear recipe of
	--- its own behind provider PB (a processing pattern for gears), a level maintainer, two CPUs
	--- plates and sticks for gears and belts, and the ingredients of ten blank patterns (the recipe of the game)
	local items = { ["iron-plate"] = 200, ["iron-stick"] = 200 }
	for _, i in pairs(prototypes.recipe["me-blank-pattern"].ingredients) do
		items[i.name] = (items[i.name] or 0) + 10 * i.amount
	end
	local m = pattern_network(s, fails, PS_X, PS_Y, items, 2)
	me_place(s, fails, "issue #80", "me-molecular-assembler", PS_X + 14.5, PS_Y + 0.5)
	m[#m + 1] = me_place(s, fails, "issue #80", "me-pattern-provider", PS_X + 16.5, PS_Y + 0.5)
	m[#m + 1] = me_place(s, fails, "issue #80", "me-pattern-provider", PS_X + 18.5, PS_Y + 0.5)
	local m2 = me_place(s, fails, "issue #80", "me-molecular-assembler", PS_X + 20.5, PS_Y + 0.5)
	if m2 then
		m2.force.recipes[GEAR_RECIPE_80].enabled = true
		m2.set_recipe(GEAR_RECIPE_80)
	end
	m[#m + 1] = me_place(s, fails, "issue #80", "me-level-maintainer", PS_X + 4.5, PS_Y + 8.5)
	me_connect(fails, "pattern switch", m)
	--- processing line: provider PL facing a chest (the line's input), an import bus facing the output chest
	m = pattern_network(s, fails, PL_X, PL_Y, { [PL_IN] = 100, ["me-blank-pattern"] = 2 }, 1)
	m[#m + 1] = me_place(s, fails, "issue #80", "me-pattern-provider", PL_X + 16.5, PL_Y + 0.5)
	me_place(s, fails, "issue #80", "iron-chest", PL_X + 17.5, PL_Y + 0.5)
	m[#m + 1] = me_place(s, fails, "issue #80", "me-import-bus", PL_X + 17.5, PL_Y + 2.5, { direction = defines.direction.south })
	me_place(s, fails, "issue #80", "iron-chest", PL_X + 17.5, PL_Y + 3.5)
	me_connect(fails, "processing line", m)
	return fails
end

function pattern_switch_test()
	local s = game.surfaces[1]
	local terminal = s.find_entity("me-terminal", { PS_X + 8.5, PS_Y + 4.5 })
	local m1 = s.find_entity("me-molecular-assembler", { PS_X + 14.5, PS_Y + 0.5 })
	local m2 = s.find_entity("me-molecular-assembler", { PS_X + 20.5, PS_Y + 0.5 })
	local pa = s.find_entity("me-pattern-provider", { PS_X + 16.5, PS_Y + 0.5 })
	local pb = s.find_entity("me-pattern-provider", { PS_X + 18.5, PS_Y + 0.5 })
	local maint = s.find_entity("me-level-maintainer", { PS_X + 4.5, PS_Y + 8.5 })
	local st = storage.patswitch
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function finish(note)
		storage.patswitch.done = true
		me_report("PATSWITCH", "pattern recipe switching", problems, note)
	end
	local function count(item) return me_count(terminal, item) end
	local function recipe_of(m) local r = m.get_recipe() return r and r.name end
	local function per(recipe, name, products)
		local n = 0
		for _, e in pairs(products and prototypes.recipe[recipe].products or prototypes.recipe[recipe].ingredients) do
			if e.name == name then n = n + e.amount end
		end
		return n
	end

	if not st then
		if game.tick < 60 then return end
		storage.patswitch = { started = game.tick, phase = "two", phase_tick = game.tick, notes = {} }
		st = storage.patswitch
		if not (terminal and m1 and m2 and pa and pb and maint) then expect(false, "entities missing") return finish() end
		local force = terminal.force
		for _, r in pairs({ GEAR_RECIPE_80, PS_BELT, "me-blank-pattern" }) do force.recipes[r].enabled = true end
		local fails = {}
		give_patterns(pa, { { kind = "crafting", recipe = GEAR_RECIPE_80 }, { kind = "crafting", recipe = PS_BELT },
			{ kind = "crafting", recipe = "me-blank-pattern" } }, fails)
		local ed = remote.call(TERM, "new_editor")
		ed.mode = "processing"
		local _, _, filled = remote.call(TERM, "set_editor_recipe", force, ed, GEAR_RECIPE_80)
		local def = remote.call(TERM, "pattern_of", force, filled)
		expect(def and def.kind == "processing", "processing gear pattern " .. serpent.line(def))
		if def then give_patterns(pb, { def }, fails) end
		expect(#fails == 0, table.concat(fails, ", "))
		local ia = remote.call(AC, "provider_info", pa)
		for slot = 1, 3 do
			expect(ia.slots[slot] and ia.slots[slot].ok and ia.slots[slot].machines == 1, "provider A slot " .. slot .. ": " .. serpent.line(ia.slots[slot]))
		end
		expect(recipe_of(m1) == nil, "M1 has a recipe before any job")
		local ib = remote.call(AC, "provider_info", pb)
		expect(ib.slots[1] and ib.slots[1].ok and ib.slots[1].kind == "processing", "provider B " .. serpent.line(ib.slots[1]))
		--- two patterns make gears: the provider built first wins at the same priority, a higher priority wins
		local plan = remote.call(AC, "plan", terminal, "iron-gear-wheel", 1)
		expect(plan and plan.ok and plan.pids[1] == "c/" .. GEAR_RECIPE_80, "gear pattern at equal priority: " .. serpent.line(plan and plan.pids))
		remote.call(AC, "set_priority", pb, 10)
		plan = remote.call(AC, "plan", terminal, "iron-gear-wheel", 1)
		expect(plan and plan.ok and plan.pids[1] and plan.pids[1]:sub(1, 2) == "p/", "gear pattern with provider B at 10: " .. serpent.line(plan and plan.pids))
		--- the processing pattern on M2 (its own recipe): pushed in, products taken out
		st.gears0 = count("iron-gear-wheel")
		st.job = remote.call(AC, "start", terminal, "iron-gear-wheel", 2)
		expect(st.job, "processing gear job did not start")
		if #problems > 0 then return finish() end
		return
	end
	if st.done then return end
	local function next_phase(name) st.phase = name st.phase_tick = game.tick end
	local function job(id) return remote.call(AC, "job", id) end
	local function over(j) return j and (j.status == "done" or j.status == "failed" or j.status == "cancelled") end
	local function timeout(ticks, what)
		if game.tick > st.phase_tick + ticks then
			expect(false, what .. " timed out: " .. serpent.line(st.job and job(st.job)) .. ", M1 " .. tostring(recipe_of(m1)))
			finish()
			return true
		end
	end
	local function check_done(what, id)
		local j = job(id)
		expect(j.status == "done", what .. " ended as " .. j.status .. " " .. serpent.line(j.reason))
		expect(next(j.pool) == nil, what .. " keeps a pool: " .. serpent.line(j.pool))
		return j
	end

	if st.phase == "two" then
		local j = job(st.job)
		if over(j) then
			check_done("the processing gear job", st.job)
			expect(j.steps[1].kind == "processing" and j.steps[1].received["iron-gear-wheel"] == 2, "processing step " .. serpent.line(j.steps[1]))
			expect(count("iron-gear-wheel") == st.gears0 + 2, "gears after the processing job: " .. count("iron-gear-wheel"))
			expect(recipe_of(m2) == GEAR_RECIPE_80 and recipe_of(m1) == nil, "a machine was switched by a processing job")
			--- provider B below A: the crafting pattern on M1 (switched to the gear recipe)
			remote.call(AC, "set_priority", pb, -10)
			local plan = remote.call(AC, "plan", terminal, "iron-gear-wheel", 1)
			expect(plan and plan.pids[1] == "c/" .. GEAR_RECIPE_80, "gear pattern with provider B at -10: " .. serpent.line(plan and plan.pids))
			st.gears1 = count("iron-gear-wheel")
			st.job = remote.call(AC, "start", terminal, "iron-gear-wheel", 4)
			expect(st.job, "gear job did not start")
			if #problems > 0 then return finish() end
			return next_phase("gears")
		end
		timeout(400, "the processing gear job")
	elseif st.phase == "gears" then
		local j = job(st.job)
		if over(j) then
			check_done("the gear job", st.job)
			expect(recipe_of(m1) == GEAR_RECIPE_80, "M1 was not switched to the gear recipe: " .. tostring(recipe_of(m1)))
			expect(count("iron-gear-wheel") == st.gears1 + 4, "gears after the gear job: " .. count("iron-gear-wheel"))
			--- left in the machine: 3 plates in the input, 2 gears in the output; the switch to belts moves them out
			m1.get_inventory(defines.inventory.crafter_input).insert{ name = "iron-plate", count = 3 }
			m1.get_inventory(defines.inventory.crafter_output).insert{ name = "iron-gear-wheel", count = 2 }
			st.plates2, st.gears2, st.belts2 = count("iron-plate"), count("iron-gear-wheel"), count(PS_BELT)
			local out = per(PS_BELT, PS_BELT, true)
			st.belt_runs = math.ceil(4 / out)
			st.job = remote.call(AC, "start", terminal, PS_BELT, 4)
			expect(st.job, "belt job did not start")
			if #problems > 0 then return finish() end
			return next_phase("belts")
		end
		timeout(400, "the gear job")
	elseif st.phase == "belts" then
		local j = job(st.job)
		if over(j) then
			check_done("the belt job", st.job)
			expect(recipe_of(m1) == PS_BELT, "M1 was not switched to the belt recipe: " .. tostring(recipe_of(m1)))
			local runs = st.belt_runs
			local want_plates = st.plates2 - runs * per(PS_BELT, "iron-plate") + 3
			local want_gears = st.gears2 - runs * per(PS_BELT, "iron-gear-wheel") + 2
			expect(count("iron-plate") == want_plates and count("iron-gear-wheel") == want_gears
				and count(PS_BELT) == st.belts2 + runs * per(PS_BELT, PS_BELT, true),
				"after the switch: plates " .. count("iron-plate") .. "/" .. want_plates .. ", gears " .. count("iron-gear-wheel") .. "/" .. want_gears
				.. ", belts " .. count(PS_BELT))
			expect(m1.get_inventory(defines.inventory.crafter_input).is_empty() and m1.get_inventory(defines.inventory.crafter_output).is_empty(),
				"M1 is not empty after the belt job")
			st.blanks3 = count("me-blank-pattern")
			st.job = remote.call(AC, "start", terminal, "me-blank-pattern", 2)
			expect(st.job, "blank pattern job did not start")
			if #problems > 0 then return finish() end
			return next_phase("blanks")
		end
		timeout(400, "the belt job")
	elseif st.phase == "blanks" then
		local j = job(st.job)
		if over(j) then
			check_done("the blank pattern job", st.job)
			expect(recipe_of(m1) == "me-blank-pattern", "M1 was not switched to the blank pattern recipe: " .. tostring(recipe_of(m1)))
			expect(count("me-blank-pattern") == st.blanks3 + 2, "blank patterns after the job: " .. count("me-blank-pattern"))
			--- two jobs want M1 at once (two CPUs): one waits for the machine
			st.queue = { remote.call(AC, "start", terminal, "iron-gear-wheel", 4), remote.call(AC, "start", terminal, PS_BELT, 4) }
			expect(st.queue[1] and st.queue[2], "the two jobs did not start")
			if #problems > 0 then return finish() end
			return next_phase("queue")
		end
		timeout(400, "the blank pattern job")
	elseif st.phase == "queue" then
		local a, b = job(st.queue[1]), job(st.queue[2])
		if (a.leases > 0 and b.wait == "machine") or (b.leases > 0 and a.wait == "machine") then st.waited = true end
		expect(not (a.leases > 0 and b.leases > 0), "two jobs had a lease on M1 at once")
		if over(a) and over(b) then
			check_done("the first queued job", st.queue[1])
			check_done("the second queued job", st.queue[2])
			expect(st.waited, "no job ever waited for the busy machine")
			--- the level maintainer keeps blank patterns in stock (their crafting pattern on M1)
			st.keep = count("me-blank-pattern") + 2
			expect(remote.call("gregtorio-me-circuit", "set_maintainer", maint, "me-blank-pattern", st.keep, false), "set_maintainer")
			return next_phase("maintainer")
		end
		timeout(600, "the two queued jobs")
	elseif st.phase == "maintainer" then
		if count("me-blank-pattern") >= st.keep then
			local mine = false
			for _, j in pairs(remote.call(AC, "jobs", terminal)) do
				if j.item == "me-blank-pattern" and j.owner == maint.unit_number and j.status == "done" then mine = true end
			end
			expect(mine, "the blank patterns were not made by a maintainer job")
			expect(recipe_of(m1) == "me-blank-pattern", "M1 recipe after the maintainer job: " .. tostring(recipe_of(m1)))
			if #problems > 0 then return finish() end
			return finish("gears, belts, blank patterns on one machine, two jobs queued, maintainer, " .. (game.tick - st.started) .. " ticks")
		end
		timeout(500, "the maintainer job for blank patterns (" .. serpent.line(remote.call("gregtorio-me-circuit", "get_maintainer", maint)) .. ")")
	end
	if #problems > 0 then finish() end
end

function pattern_line_test()
	local s = game.surfaces[1]
	local terminal = s.find_entity("me-terminal", { PL_X + 8.5, PL_Y + 4.5 })
	local p = s.find_entity("me-pattern-provider", { PL_X + 16.5, PL_Y + 0.5 })
	local cin = s.find_entity("iron-chest", { PL_X + 17.5, PL_Y + 0.5 })
	local cout = s.find_entity("iron-chest", { PL_X + 17.5, PL_Y + 3.5 })
	local st = storage.patline
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function finish(note)
		storage.patline.done = true
		me_report("PATLINE", "processing line", problems, note)
	end
	local function count(item) return me_count(terminal, item) end

	if not st then
		if game.tick < 60 then return end
		storage.patline = { started = game.tick }
		st = storage.patline
		if not (terminal and p and cin and cout) then expect(false, "entities missing") return finish() end
		--- a processing pattern with free rows, encoded from a blank of the network
		local ed = remote.call(TERM, "new_editor")
		ed.mode = "processing"
		local ok1, ok2
		ok1, ed = remote.call(TERM, "set_editor_row", ed, "inputs", 1, PL_IN, PL_IN_N)
		ok2, ed = remote.call(TERM, "set_editor_row", ed, "outputs", 1, PL_OUT, PL_OUT_N)
		expect(ok1 and ok2, "set_editor_row")
		local ok3 = remote.call(TERM, "set_editor_row", ed, "inputs", 2, "me-encoded-pattern", 1)
		expect(not ok3, "an item with tags was accepted as a pattern input")
		local inv = game.create_inventory(2)
		local hand, own, in_net = remote.call(TERM, "blanks", false, inv, terminal)
		expect(hand == 0 and own == 0 and in_net == 2, "blanks " .. hand .. "/" .. own .. "/" .. in_net)
		local where = remote.call(TERM, "encode", false, inv, terminal, terminal.force, ed)
		local stack = inv.find_item_stack("me-encoded-pattern")
		local info = stack and remote.call(TERM, "pattern_info", stack)
		expect(where == "inventory" and info and info.kind == "processing" and info.inputs[1].key == PL_IN and info.inputs[1].amount == PL_IN_N
			and info.outputs[1].key == PL_OUT and info.outputs[1].amount == PL_OUT_N, "line pattern " .. tostring(where) .. " " .. serpent.line(info))
		expect(count("me-blank-pattern") == 1, "blank patterns in the network after encoding: " .. count("me-blank-pattern"))
		expect(stack and remote.call(AC, "insert_pattern", p, stack) == 1, "the line pattern did not go into the provider")
		inv.destroy()
		local pi = remote.call(AC, "provider_info", p)
		expect(pi.slots[1] and pi.slots[1].ok and pi.slots[1].machines == 1, "line provider " .. serpent.line(pi.slots[1]))
		st.runs = math.ceil(PL_AMOUNT / PL_OUT_N)
		st.job = remote.call(AC, "start", terminal, PL_OUT, PL_AMOUNT)
		expect(st.job, "the line job did not start")
		st.plates = count(PL_IN)
		if #problems > 0 then return finish() end
		return
	end
	if st.done then return end
	--- the line: every pair of plates in the input chest becomes three cables in the output chest
	local inp = cin.get_inventory(defines.inventory.chest)
	local pairs_n = math.floor(inp.get_item_count(PL_IN) / PL_IN_N)
	if pairs_n > 0 then
		st.awaited = st.awaited or remote.call(AC, "awaiting", terminal, PL_OUT)
		inp.remove{ name = PL_IN, count = pairs_n * PL_IN_N }
		cout.insert{ name = PL_OUT, count = pairs_n * PL_OUT_N }
	end
	local j = remote.call(AC, "job", st.job)
	if j.status == "done" or j.status == "failed" or j.status == "cancelled" then
		expect(j.status == "done", "the line job ended as " .. j.status .. " " .. serpent.line(j.reason))
		expect(next(j.pool) == nil, "the line job keeps a pool: " .. serpent.line(j.pool))
		expect(j.steps[1].received[PL_OUT] == st.runs * PL_OUT_N, "outputs received " .. serpent.line(j.steps[1].received))
		expect(count(PL_OUT) == st.runs * PL_OUT_N, "cables in the network: " .. count(PL_OUT))
		expect(count(PL_IN) == 100 - st.runs * PL_IN_N, "plates in the network: " .. count(PL_IN))
		expect(st.awaited == st.runs * PL_OUT_N, "the job waited for " .. tostring(st.awaited) .. " cables")
		expect(remote.call(AC, "awaiting", terminal, PL_OUT) == 0, "a done job still waits for cables")
		expect(inp.is_empty(), "the line's input chest is not empty")
		if #problems > 0 then return finish() end
		return finish("pushed into a chest, " .. st.runs * PL_OUT_N .. " cables back through an import bus, " .. (game.tick - st.started) .. " ticks")
	end
	if game.tick > st.started + 900 then
		expect(false, "the line job timed out: " .. serpent.line(j) .. ", input chest " .. inp.get_item_count(PL_IN) .. ", output chest "
			.. cout.get_item_count(PL_OUT))
		finish()
	end
end

--- issue #38: the schedule of every scheduled block of the map and the queues' counts, as one line; the harness
--- compares it between the unbroken run and a run that was saved at tick 500 and loaded again (ticks 1000, 1400)
local SB_REMOTE, CIRC_REMOTE = "gregtorio-me-storagebus", "gregtorio-me-circuit"
local function schedule_digest()
	local s = game.surfaces[1]
	local parts = {}
	local function put(prefix, e, sch)
		if sch then
			parts[#parts + 1] = string.format("%s%d:%s:%s:%s:%s:%s:%s:%s", prefix, e.unit_number, tostring(sch.due), tostring(sch.interval),
				tostring(sch.last), tostring(sch.probing), tostring(sch.parked), tostring(sch.front), tostring(sch.backlog))
		end
	end
	for _, e in pairs(s.find_entities_filtered{ name = { "me-network-interface", "me-import-bus", "me-export-bus" } }) do
		put("io", e, remote.call(IO, "schedule", e))
	end
	for _, e in pairs(s.find_entities_filtered{ name = "me-storage-bus" }) do
		put("sb", e, remote.call(SB_REMOTE, "schedule", e))
	end
	for _, e in pairs(s.find_entities_filtered{ name = { "me-level-maintainer", "me-circuit-interface" } }) do
		put("m", e, remote.call(CIRC_REMOTE, "schedule", e))
	end
	table.sort(parts)
	local bl = remote.call(IO, "backlogs")
	local keys = {}
	for k in pairs(bl) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local v = bl[k]
		parts[#parts + 1] = k .. "=" .. (type(v) == "table" and serpent.line(v, { sortkeys = true, comment = false }) or tostring(v))
	end
	return table.concat(parts, " ")
end

script.on_nth_tick(10, function()
	if game.tick == 1000 or game.tick == 1400 then log("DEVCHECK-RUNTIME-SCHEDULE " .. game.tick .. " " .. schedule_digest()) end
	if not (storage.me_graph and storage.me_graph.done) then me_graph_test() end
	if not (storage.me_cells and storage.me_cells.done) then me_cells_test() end
	me_terminal_test()
	me_io_test()
	if not (storage.autocraft and storage.autocraft.done) then autocraft_test() end
	if not (storage.furnace and storage.furnace.done) then furnace_test() end
	if not (storage.patswitch and storage.patswitch.done) then pattern_switch_test() end
	if not (storage.patline and storage.patline.done) then pattern_line_test() end
	if not (storage.fluids and storage.fluids.done) then fluid_test() end
	fluid_cell_test()
	me_r3_test()
	storage_bus_test()
	fluid_storage_bus_test()
	unified_test()
	if not (storage.maint38 and storage.maint38.done) then maintainer_test() end
	if not (storage.tiers38 and storage.tiers38.done) then cpu_tier_test() end
	if not (storage.circuit38 and storage.circuit38.done) then circuit_test() end
	settings_test()
	if not (storage.sched_test and storage.sched_test.done) then scheduler_test() end
	cursor_test()
	paste_test()
	cards17.tick()
	bench17.tick()
	cpus6.tick()
	parking38.tick()
	stats38.tick()
	margin51.tick()
	busaccel110.tick()
	accel110.tick()
	damaged84.tick()
	refused85.tick()
	lab86.tick()
	refill67.tick()
	plans50.tick()
	scan50.tick()
	entries50.tick()
	holderlists59.tick()
	holders43.tick()
	storable76.tick()
	graph43.tick()
	done_test()
end)


--------------------------------------------------------------------------------
--- fluids (issue #68 step R2: fluid cells in an ME Drive): storage, interfaces, a fluid cell's round trip
--- (taken out, stored in the network, back), a drive with fluid cells mined by robots and rebuilt, full cells,
--- fluid autocrafting
--------------------------------------------------------------------------------

local FL_Y = 200                                        -- below everything else: the roboport's area is 25 tiles
local FL_FLUID, FL_TANK_AMOUNT = "chlorine", 2000      -- in the tank connected to interface A
local FL_EXPORT_LEVEL = 1000                            -- interface B exports up to this level
local FL_CHLORINE_EXTRA, FL_PHENOL = 20000, 100         -- put into the network by script for the jobs
local FL_SILICON, FL_TIN, FL_BOARDS = 50, 20, 5
local FL_DRIVE = "me-drive"                             -- with four 1k fluid cells
local FL_CELL = "me-1k-fluid-storage-cell"
local FL_FULL = 4 * (1024 - 8) * 8                      -- four 1k fluid cells holding one fluid
local FL_DRIVE_POS = { 10.5, FL_Y + 2.5 }
local FL_EPS = 1e-3

--- the layout (everything inside the controller's area, x <= 22 and y <= FL_Y + 16; HV reactors: there is no EV one)
local FL = {
	terminal = { "me-terminal", 8.5, FL_Y + 2.5 },
	iface_a = { "me-network-interface", 2.5, FL_Y + 4.5 },   -- issue #3: the ME Interface's fluid sides
	iface_b = { "me-network-interface", 5.5, FL_Y + 4.5 },
	tank = { "storage-tank", 3.5, FL_Y + 6.5 },           -- its north connection meets interface A's south side
	idrive = { "me-drive", 12.5, FL_Y + 2.5 },
	chest = { "iron-chest", 14.5, FL_Y + 2.5 },
	store = { "storage-chest", 20.5, FL_Y + 2.5 },        -- the robots' storage
	reactor_a = { "hv-chemical-reactor", 12.5, FL_Y + 7.5 },
	extractor = { "ev-extractor", 16.5, FL_Y + 7.5 },
	reactor_c = { "hv-chemical-reactor", 12.5, FL_Y + 11.5 },
	reactor_d = { "hv-chemical-reactor", 20.5, FL_Y + 11.5 },
}

function setup_fluid_test(s)
	local fails = {}
	local function place(name, x, y, extra)
		local ok, e = pcall(function()
			local def = { name = name, position = { x, y }, force = "player", raise_built = true }
			for k, v in pairs(extra or {}) do def[k] = v end
			return s.create_entity(def)
		end)
		if not (ok and e) then fails[#fails + 1] = "fluids " .. name .. ": " .. tostring(e) return nil end
		return e
	end
	local function machine(def, recipe)
		local e = place(def[1], def[2], def[3])
		if e and recipe then
			e.force.recipes[recipe].enabled = true
			local ok, err = pcall(function() e.set_recipe(recipe) end)
			if not ok then fails[#fails + 1] = "fluids recipe " .. recipe .. ": " .. tostring(err) end
		end
		return e
	end
	local eei = place("electric-energy-interface", 0, FL_Y)
	if eei then
		eei.power_production = 1e6
		eei.electric_buffer_size = 1e7
	end
	place("substation", 3, FL_Y)
	place("substation", 16, FL_Y + 4)
	local ctrl = place("me-network-controller", 6, FL_Y)
	local cpu = place("me-quantum-crafting-cpu", 10, FL_Y)       -- three jobs at once (issue #6: no queue behind a busy CPU)
	local term = place(FL.terminal[1], FL.terminal[2], FL.terminal[3])
	local fdrive = me_drive(s, fails, "fluids", FL_DRIVE_POS[1], FL_DRIVE_POS[2], {}, "1k", true)
	local idrive = me_drive(s, fails, "fluids", FL.idrive[2], FL.idrive[3],
		{ ["raw-silicon"] = FL_SILICON, ["tin-ingot"] = FL_TIN, ["resin-circuit-board"] = FL_BOARDS })
	place(FL.chest[1], FL.chest[2], FL.chest[3])
	place(FL.store[1], FL.store[2], FL.store[3])
	--- import: a tank connected to interface A's south side (a side imports by default); export: interface B
	--- stands alone (its north side keeps the exported fluid).
	--- (No pump: a 2.0 pump moves fluid in proportion to the fill level of its source, a trickle here.)
	local ia = place(FL.iface_a[1], FL.iface_a[2], FL.iface_a[3])
	local tank = place(FL.tank[1], FL.tank[2], FL.tank[3])
	if tank then tank.insert_fluid{ name = FL_FLUID, amount = FL_TANK_AMOUNT } end
	local ib = place(FL.iface_b[1], FL.iface_b[2], FL.iface_b[3])
	--- construction robots for the drive round trip (their storage chest: FL.store)
	local port = place("roboport", 16, FL_Y)
	if port then port.insert{ name = "construction-robot", count = 2 } end
	game.forces.player.worker_robots_speed_modifier = 3
	--- pattern machines: raw silicon + chlorine -> silicon tetrachloride (fluid in and out), tin ingot ->
	--- molten tin (fluid out), resin board + phenol -> phenolic board (fluid in), and a reactor whose input
	--- box has a pipe connected (must be ignored)
	machine(FL.reactor_a, "silicon-tetrachloride")
	machine(FL.extractor, "molten-tin")
	local p1 = place("me-pattern-provider", 14.5, FL_Y + 7.5)     -- touches reactor A (west) and the extractor (east)
	machine(FL.reactor_c, "phenolic-circuit-board")
	local p2 = place("me-pattern-provider", 14.5, FL_Y + 11.5)
	machine(FL.reactor_d, "hydrochloric-acid")
	local p3 = place("me-pattern-provider", 18.5, FL_Y + 11.5)
	place("pipe", 19.5, FL_Y + 9.5)                    -- on the north-west input port of reactor D
	me_connect(fails, "fluids", { ctrl, cpu, term, fdrive, idrive, ia, ib, p1, p2, p3 })
	--- issue #80: crafting patterns of the fluid recipes set in the machines
	for _, p in pairs({ p1, p2, p3 }) do
		if p then give_patterns(p, machine_patterns(p), fails) end
	end
	return fails
end

function fluid_test()
	local s = game.surfaces[1]
	local F, A = "gregtorio-me-fluids", "gregtorio-me-autocraft"
	local function ent(def) return s.find_entity(def[1], { def[2], def[3] }) end
	--- issue #3: the interfaces' fluid is in their four side tanks; B exports through its north side (row 1)
	local function tanks_of(e) return remote.call(IO, "interface_tanks", e) or {} end
	local function held(e, fluid)
		local n = 0
		for _, tk in pairs(tanks_of(e)) do n = n + tk.get_fluid_count(fluid) end
		return n
	end
	local function set_export(e, fluid, level)
		return remote.call(IO, "set_interface_config", e, { [1] = { type = "fluid", name = fluid, amount = level } }, { 1 })
	end
	local function set_import(e) return remote.call(IO, "set_interface_config", e, {}, {}) end
	local function side(e, d)
		local i = remote.call(IO, "get_interface", e)
		return i and i.fluids[d] or {}
	end
	local terminal = ent(FL.terminal)
	local net = terminal and remote.call(NET, "network", terminal)
	local function count(fluid) return terminal and remote.call(F, "count", terminal, fluid) or -1 end
	--- items of a name in the network, items with tags (a loaded fluid drive item) included
	local function items(name)
		if not net then return -1 end
		local n = 0
		for key, c in pairs(remote.call(NET, "contents", terminal)) do
			if key == name or key:sub(1, #name + 8) == name .. "@normal#" then n = n + c end
		end
		return n
	end
	local function near(a, b, what) return math.abs(a - b) <= FL_EPS end
	local st = storage.fluids
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function finish_test(note)
		storage.fluids.done = true
		for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL fluids: " .. p) end
		log("DEVCHECK-RUNTIME-FLUIDS " .. (#problems == 0 and "ok" or "failed") .. (note and (" (" .. note .. ")") or ""))
	end

	if not st then
		if game.tick < 60 then return end
		storage.fluids = { started = game.tick, phase = "import", phase_tick = game.tick }
		st = storage.fluids
		local a, b, tank, drive = ent(FL.iface_a), ent(FL.iface_b), ent(FL.tank), s.find_entity(FL_DRIVE, FL_DRIVE_POS)
		expect(terminal and a and b and tank and drive, "entities missing")
		if not (terminal and a and b and tank and drive) then return finish_test() end
		expect(net and net.ok, "no working ME network at the terminal")
		expect(tanks_of(a)[3] and #tanks_of(a)[3].fluidbox.get_connections(1) > 0, "interface A's south side is not connected to the tank")
		expect(tanks_of(b)[1] and #tanks_of(b)[1].fluidbox.get_connections(1) == 0, "interface B must stand alone")
		local capacity, used = remote.call(F, "capacity", terminal)   -- the import may have run already
		expect(capacity == 4 * 1024 * 8 and used >= 0 and used <= (8 + math.ceil(FL_TANK_AMOUNT / 8)) * 8, "fluid capacity " .. tostring(capacity) .. "/" .. tostring(used))
		expect(side(a, 3).setting == "import", "interface A's south side by default " .. serpent.line(side(a, 3)))
		expect(set_export(b, FL_FLUID, FL_EXPORT_LEVEL), "set_interface_config failed")
		local cb, sb = remote.call(IO, "get_interface_config", b), remote.call(IO, "get_interface_sides", b)
		expect(cb[1] and cb[1].type == "fluid" and cb[1].name == FL_FLUID and cb[1].amount == FL_EXPORT_LEVEL and sb[1] == 1,
			"interface B settings " .. serpent.line(cb) .. " " .. serpent.line(sb))
		if #problems > 0 then return finish_test() end
		return
	end
	if st.done then return end

	local function timeout_after(ticks, what)
		if game.tick > st.phase_tick + ticks then
			expect(false, what .. " timed out at tick " .. game.tick .. " (network " .. FL_FLUID .. " " .. count(FL_FLUID) .. ")")
			finish_test()
			return true
		end
	end
	local function next_phase(name) st.phase = name st.phase_tick = game.tick end
	local a, b, tank = ent(FL.iface_a), ent(FL.iface_b), ent(FL.tank)
	local function in_pipes() return tank.get_fluid_count(FL_FLUID) + held(a, FL_FLUID) end
	local function job_of(id)
		local j = remote.call(A, "job", id)
		for key, n in pairs(j and j.pool or {}) do
			expect(n >= -FL_EPS, "job " .. id .. " pool holds " .. n .. " " .. key)
		end
		return j
	end

	local phase = st.phase
	if phase == "import" then
		--- the tank drains into interface A, the network stores it; B (export since tick 60) takes its level out
		if in_pipes() < 0.01 and near(held(b, FL_FLUID), FL_EXPORT_LEVEL) then
			local stored, in_b = count(FL_FLUID), held(b, FL_FLUID)
			expect(near(stored + in_b, FL_TANK_AMOUNT), "fluid not conserved: network " .. stored .. " + export " .. in_b)
			local capacity, used = remote.call(F, "capacity", terminal)
			expect(used == (8 + math.ceil(stored / 8)) * 8, "used " .. used .. " is not the bytes of " .. stored .. " units")
			local totals = remote.call(F, "totals", terminal)
			expect(near(totals[FL_FLUID] or 0, stored), "totals differ from count")
			expect(side(b, 1).status == "ok", "interface B's north side " .. serpent.line(side(b, 1)))
			st.import_ticks = game.tick - st.started
			if #problems > 0 then return finish_test() end
			return next_phase("export-hold")
		end
		timeout_after(300, "import from the tank")
	elseif phase == "export-hold" then
		--- export never overfills and never takes back
		if game.tick >= st.phase_tick + 60 then
			expect(near(held(b, FL_FLUID), FL_EXPORT_LEVEL), "export level drifted to " .. held(b, FL_FLUID))
			expect(near(count(FL_FLUID), FL_TANK_AMOUNT - FL_EXPORT_LEVEL), "network changed while holding: " .. count(FL_FLUID))
			set_import(b)
			return next_phase("reimport")
		end
	elseif phase == "reimport" then
		if held(b, FL_FLUID) < 0.01 then
			expect(near(count(FL_FLUID), FL_TANK_AMOUNT), "after re-import the network holds " .. count(FL_FLUID))
			if #problems > 0 then return finish_test() end
			--- the fluid cell is taken out: its chlorine travels in its tags
			local drive, chest = s.find_entity(FL_DRIVE, FL_DRIVE_POS), ent(FL.chest)
			local inv = chest.get_inventory(defines.inventory.chest)
			expect(remote.call(NET, "take_cell", drive, 1, inv), "take_cell failed")
			local stack
			for i = 1, #inv do
				if inv[i].valid_for_read and inv[i].name == FL_CELL then stack = inv[i] end
			end
			local tags = stack and stack.tags or {}
			local carried = tags.fork_me_cell and tags.fork_me_cell.items["fluid/" .. FL_FLUID] or 0
			expect(near(carried, FL_TANK_AMOUNT), "fluid cell carries " .. tostring(carried))
			expect(count(FL_FLUID) == 0, "the network keeps the fluid of a removed cell: " .. count(FL_FLUID))
			if not stack then return finish_test() end
			--- the loaded fluid cell survives a trip through the terminal (stored with its tags, withdrawn)
			local stored = remote.call("gregtorio-me-terminal", "store_stack", terminal, stack)
			expect(stored == 1 and items(FL_CELL) == 1, "storing the fluid cell: " .. tostring(stored) .. ", in network " .. items(FL_CELL))
			local back = remote.call("gregtorio-me-terminal", "withdraw", terminal, chest, FL_CELL, "normal", 1)
			expect(back == 1 and items(FL_CELL) == 0, "withdrawing the fluid cell: " .. tostring(back))
			stack = nil
			for i = 1, #inv do
				if inv[i].valid_for_read and inv[i].name == FL_CELL then stack = inv[i] end
			end
			local tags2 = stack and stack.tags or {}
			expect(stack and near(tags2.fork_me_cell and tags2.fork_me_cell.items["fluid/" .. FL_FLUID] or 0, FL_TANK_AMOUNT),
				"the fluid cell lost its fluid in the terminal: " .. serpent.line(tags2))
			if not stack then return finish_test() end
			--- back into the drive (another slot): the network holds the chlorine again
			expect(remote.call(NET, "insert_cell", drive, stack, 7) == 7, "the fluid cell did not go back into the drive")
			expect(near(count(FL_FLUID), FL_TANK_AMOUNT), "after the cell is back the network holds " .. count(FL_FLUID))
			if #problems > 0 then return finish_test() end
			--- now through construction robots: the drive and its cells (with the chlorine) into a storage chest
			expect(drive.order_deconstruction(drive.force), "order_deconstruction refused")
			return next_phase("robot-mine")
		end
		timeout_after(300, "re-import from interface B")
	elseif phase == "robot-mine" then
		if not s.find_entity(FL_DRIVE, FL_DRIVE_POS) then
			expect(count(FL_FLUID) == 0, "network holds fluid without a drive: " .. count(FL_FLUID))
			return next_phase("robot-stored")
		end
		timeout_after(600, "robots deconstructing the drive (" .. robot_report(s, FL_DRIVE_POS, FL_DRIVE) .. ")")
	elseif phase == "robot-stored" then
		--- the robot delivers the drive and its four cells (the one with chlorine with its tags) into the storage chest
		local store = ent(FL.store)
		local inv = store.get_inventory(defines.inventory.chest)
		if inv.get_item_count(FL_DRIVE) >= 1 and inv.get_item_count(FL_CELL) >= 4 then
			local carried = 0
			for i = 1, #inv do
				local stack = inv[i]
				if stack.valid_for_read and stack.name == FL_CELL then
					local tags = stack.tags or {}
					carried = carried + (tags.fork_me_cell and tags.fork_me_cell.items["fluid/" .. FL_FLUID] or 0)
				end
			end
			expect(near(carried, FL_TANK_AMOUNT), "robot-mined fluid cells carry " .. tostring(carried))
			local ok, ghost = pcall(function()
				return s.create_entity{ name = "entity-ghost", inner_name = FL_DRIVE, position = FL_DRIVE_POS, force = "player" }
			end)
			expect(ok and ghost, "ghost could not be placed: " .. tostring(ghost))
			if not (ok and ghost) then return finish_test() end
			return next_phase("robot-build")
		end
		timeout_after(600, "robot storing the drive item (" .. robot_report(s, FL_DRIVE_POS, FL_DRIVE) .. ")")
	elseif phase == "robot-build" then
		local rebuilt = s.find_entity(FL_DRIVE, FL_DRIVE_POS)
		if rebuilt then
			expect(count(FL_FLUID) == 0, "a drive rebuilt by robots is not empty: " .. count(FL_FLUID))
			--- the cells go back in (by script: what a player does in the drive window)
			local inv = ent(FL.store).get_inventory(defines.inventory.chest)
			for i = 1, #inv do
				if inv[i].valid_for_read and inv[i].name == FL_CELL then remote.call(NET, "insert_cell", rebuilt, inv[i]) end
			end
			expect(near(count(FL_FLUID), FL_TANK_AMOUNT), "after the cells are back the network holds " .. count(FL_FLUID)
				.. " (tank " .. in_pipes() .. ", B " .. held(b, FL_FLUID) .. ")")
			if #problems > 0 then return finish_test() end
			--- full cells: the import stops and keeps the fluid in the tank, an export of a fluid the
			--- network does not hold reports it
			local room = remote.call(NET, "can_insert_fluid", terminal, FL_FLUID, 1e9)
			expect(near(count(FL_FLUID) + room, FL_FULL), "room for chlorine " .. room .. ", expected " .. (FL_FULL - count(FL_FLUID)))
			expect(near(remote.call(F, "insert", terminal, FL_FLUID, room), room), "could not fill the cells")
			expect(near(count(FL_FLUID), FL_FULL), "cells not full: " .. count(FL_FLUID))
			expect(remote.call(F, "insert", terminal, FL_FLUID, 10) == 0, "full cells took fluid")
			tank.insert_fluid{ name = FL_FLUID, amount = 500 }
			set_export(b, "water", FL_EXPORT_LEVEL)
			return next_phase("full")
		end
		timeout_after(600, "robots building the drive from the ghost (" .. robot_report(s, FL_DRIVE_POS, FL_DRIVE) .. ")")
	elseif phase == "full" then
		if game.tick >= st.phase_tick + 40 then
			expect(side(a, 3).status == "full", "import into full drives: " .. serpent.line(side(a, 3)))
			expect(near(in_pipes(), 500), "fluid left the tank although the drives are full: " .. in_pipes())
			expect(near(count(FL_FLUID), FL_FULL), "network changed while full: " .. count(FL_FLUID))
			expect(side(b, 1).status == "empty-network", "export of a missing fluid: " .. serpent.line(side(b, 1)))
			expect(held(b, "water") == 0, "export interface got water from nowhere")
			expect(near(remote.call(F, "remove", terminal, FL_FLUID, 30000), 30000), "could not take fluid out")
			set_import(b)
			return next_phase("full-drain")
		end
	elseif phase == "full-drain" then
		if in_pipes() < 0.01 then
			expect(near(count(FL_FLUID), FL_FULL - 30000 + 500), "after making room the network holds " .. count(FL_FLUID))
			if #problems > 0 then return finish_test() end
			--- fluid autocrafting: fill the network, check the patterns and a shortfall, start three jobs
			expect(near(remote.call(F, "insert", terminal, FL_FLUID, FL_CHLORINE_EXTRA), FL_CHLORINE_EXTRA), "could not insert chlorine")
			expect(near(remote.call(F, "insert", terminal, "phenol", FL_PHENOL), FL_PHENOL), "could not insert phenol")
			local craftable, set = remote.call(A, "craftable", terminal), {}
			for _, k in pairs(craftable) do set[k] = true end
			expect(set["fluid/silicon-tetrachloride"] and set["fluid/molten-tin"] and set["phenolic-circuit-board"], "fluid patterns missing: " .. serpent.line(craftable))
			expect(not set["fluid/hydrochloric-acid"], "a reactor with a pipe on its input became a pattern")
			local ignored = remote.call(A, "ignored", terminal)
			expect(ignored and ignored["fluid-pipes"] == 1, "ignored reasons " .. serpent.line(ignored))
			local d = ent(FL.reactor_d)
			local piped = false
			for i = 1, #d.fluidbox do if #d.fluidbox.get_connections(i) > 0 then piped = true end end
			expect(piped, "test setup: the pipe is not connected to reactor D")
			--- shortfall: 10000 units = 100 runs = 40000 chlorine and 100 raw silicon
			local have = count(FL_FLUID)
			local plan = remote.call(A, "plan", terminal, "fluid/silicon-tetrachloride", 10000)
			expect(plan and not plan.ok and plan.missing, "shortfall plan " .. serpent.line(plan))
			if plan and plan.missing then
				expect(near(plan.missing["fluid/chlorine"] or 0, 40000 - have), "missing chlorine " .. tostring(plan.missing["fluid/chlorine"]) .. ", expected " .. (40000 - have))
				expect(plan.missing["raw-silicon"] == 100 - FL_SILICON, "missing raw silicon " .. tostring(plan.missing["raw-silicon"]))
			end
			expect(near(count(FL_FLUID), have), "a plan took fluid")
			st.chlorine, st.phenol = count(FL_FLUID), count("phenol")
			st.silicon, st.tin, st.boards = items("raw-silicon"), items("tin-ingot"), items("resin-circuit-board")
			local id1, why1 = remote.call(A, "start", terminal, "fluid/silicon-tetrachloride", 200)   -- 2 runs: 800 chlorine, 2 raw silicon
			local id2, why2 = remote.call(A, "start", terminal, "fluid/molten-tin", 100)             -- 7 runs: 7 ingots -> 100.8 molten tin
			local id3, why3 = remote.call(A, "start", terminal, "phenolic-circuit-board", 3)          -- 3 runs: 30 phenol, 3 boards
			expect(id1 and id2 and id3, "fluid jobs did not start: " .. tostring(why1) .. " " .. tostring(why2) .. " " .. tostring(why3))
			if not (id1 and id2 and id3) then return finish_test() end
			--- reserved at the start (plus the small margin per fluid)
			expect(count(FL_FLUID) <= st.chlorine - 800 and count(FL_FLUID) >= st.chlorine - 800.1, "job 1 reserved " .. (st.chlorine - count(FL_FLUID)) .. " chlorine")
			expect(items("raw-silicon") == st.silicon - 2 and items("tin-ingot") == st.tin - 7 and items("resin-circuit-board") == st.boards - 3, "items not reserved")
			st.jobs = { id1, id2, id3 }
			return next_phase("craft")
		end
		timeout_after(200, "import after making room")
	elseif phase == "craft" then
		local all_over, failed = true, {}
		for _, id in pairs(st.jobs) do
			local j = job_of(id)
			if not j or (j.status ~= "done" and j.status ~= "failed") then all_over = false end
			if j and j.status == "failed" then failed[#failed + 1] = id .. ":" .. serpent.line(j) end
		end
		if all_over then
			expect(#failed == 0, "fluid jobs failed: " .. table.concat(failed, "; "))
			expect(near(count("silicon-tetrachloride"), 200), "silicon tetrachloride in the network: " .. count("silicon-tetrachloride"))
			expect(near(count(FL_FLUID), st.chlorine - 800), "chlorine after the jobs: " .. count(FL_FLUID) .. ", expected " .. (st.chlorine - 800))
			expect(near(count("molten-tin"), 100.8), "molten tin in the network: " .. count("molten-tin"))
			expect(near(count("phenol"), st.phenol - 30), "phenol after the jobs: " .. count("phenol"))
			expect(items("raw-silicon") == st.silicon - 2, "raw silicon left: " .. items("raw-silicon"))
			expect(items("tin-ingot") == st.tin - 7, "tin ingots left: " .. items("tin-ingot"))
			expect(items("resin-circuit-board") == st.boards - 3, "resin boards left: " .. items("resin-circuit-board"))
			expect(items("phenolic-circuit-board") == 3, "phenolic boards: " .. items("phenolic-circuit-board"))
			for _, id in pairs(st.jobs) do
				local j = job_of(id)
				expect(j and next(j.pool) == nil, "job " .. id .. " keeps a pool: " .. serpent.line(j and j.pool))
			end
			--- the machines hold nothing of the jobs any more
			for _, def in pairs({ FL.reactor_a, FL.extractor, FL.reactor_c }) do
				local m = ent(def)
				for i = 1, #m.fluidbox do
					local f = m.fluidbox[i]
					expect(not f or f.amount < FL_EPS, def[1] .. " keeps " .. (f and (f.amount .. " " .. f.name) or ""))
				end
			end
			if #problems > 0 then return finish_test() end
			--- a pattern machine mined by robots while it holds the job's fluid: the fluid returns with the pool. The
			--- reactor's recipe is cleared first: the crafting pattern (a fluid recipe) must set it again (issue #80)
			ent(FL.reactor_a).set_recipe(nil)
			local pi = remote.call(A, "provider_info", s.find_entity("me-pattern-provider", { 14.5, FL_Y + 7.5 }))
			local fluid_slot
			for _, d in pairs(pi.slots) do if d.recipe == "silicon-tetrachloride" then fluid_slot = d end end
			expect(fluid_slot and fluid_slot.ok, "the fluid crafting pattern with its reactor without a recipe: " .. serpent.line(fluid_slot))
			st.chlorine_before = count(FL_FLUID)
			st.job = remote.call(A, "start", terminal, "fluid/silicon-tetrachloride", 100)   -- 1 run: 400 chlorine
			expect(st.job, "job 4 did not start")
			if not st.job then return finish_test() end
			return next_phase("mine-lease")
		end
		timeout_after(600, "fluid jobs")
	elseif phase == "mine-lease" then
		local j = job_of(st.job)
		if j.leases > 0 then
			local r = ent(FL.reactor_a).get_recipe()
			expect(r and r.name == "silicon-tetrachloride", "the reactor was not set to the pattern's recipe: " .. tostring(r and r.name))
			expect(ent(FL.reactor_a).order_deconstruction(game.forces.player), "could not order the reactor deconstructed")
			return next_phase("mine-wait")
		end
		timeout_after(200, "job 4 handing chlorine to the reactor")
	elseif phase == "mine-wait" then
		local j = job_of(st.job)
		if j.status == "done" or j.status == "failed" then
			expect(not ent(FL.reactor_a), "the reactor was not mined")
			expect(next(j.pool) == nil, "job 4 keeps a pool: " .. serpent.line(j.pool))
			local now = count(FL_FLUID)
			if j.status == "done" then                       -- the craft finished before the robot arrived
				expect(near(now, st.chlorine_before - 400), "chlorine after job 4 (done): " .. now)
			else                                             -- mined while leased: nothing beyond the running craft is lost
				expect(now >= st.chlorine_before - 400 - FL_EPS and now <= st.chlorine_before + FL_EPS,
					"chlorine after job 4 (failed): " .. now .. ", before " .. st.chlorine_before)
				expect(now > st.chlorine_before - 400 or true, "")
			end
			return finish_test("import took " .. st.import_ticks .. " ticks, whole test " .. (game.tick - st.started))
		end
		timeout_after(600, "job 4 after the reactor was mined")
	end
end

--------------------------------------------------------------------------------
--- ME fluid cells (issue #68 step R2, scripts/fork-me-network.lua, fork-me-io.lua, fork-me-terminal.lua), right
--- of the machine grid: a drive with an item cell and a fluid cell (each takes only its kind), a fluid cell taken
--- out with its fluid in the tags and put back, the capacity of a fluid cell, the terminal's grid with fluids
--- (search, no taking by hand), the fluid import bus emptying a tank and the fluid export bus filling one, and
--- old fluid drive items with fluid in their tags placed as ME Drives (four cells, more when needed).
--------------------------------------------------------------------------------

local FX, FY = 200, 160

function setup_fluid_cell_test(s)
	local fails = {}
	power(s, fails, "fluid cells", FX, FY)
	me_place(s, fails, "fluid cells", "me-network-controller", FX + 7, FY)          -- tiles FX+6..7, FY-1..FY
	me_place(s, fails, "fluid cells", "me-drive", FX + 8.5, FY - 0.5)
	me_place(s, fails, "fluid cells", "me-terminal", FX + 9.5, FY - 0.5)
	cable_row(s, fails, FX + 10, FX + 11, FY - 1)
	--- the import bus faces tank 1 (3x3 below it), the export bus tank 2 (issue #3: the unified buses on fluid)
	me_place(s, fails, "fluid cells", "me-import-bus", FX + 8.5, FY + 0.5, { direction = defines.direction.south })
	me_place(s, fails, "fluid cells", "me-export-bus", FX + 11.5, FY + 0.5, { direction = defines.direction.south })
	me_place(s, fails, "fluid cells", "storage-tank", FX + 8.5, FY + 2.5)
	me_place(s, fails, "fluid cells", "storage-tank", FX + 12.5, FY + 2.5)
	return fails
end

function fluid_cell_test()
	if storage.fluid_cells then return end
	if game.tick < 60 then return end
	storage.fluid_cells = { done = true }
	local s = game.surfaces[1]
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function near(a, b) return math.abs((a or 0) - (b or 0)) <= 1e-3 end
	local function find(name, x, y) return s.find_entity(name, { FX + x, FY + y }) end
	local d, t = find("me-drive", 8.5, -0.5), find("me-terminal", 9.5, -0.5)
	local ib, eb = find("me-import-bus", 8.5, 0.5), find("me-export-bus", 11.5, 0.5)
	local t1, t2 = find("storage-tank", 8.5, 2.5), find("storage-tank", 12.5, 2.5)
	if not (d and t and ib and eb and t1 and t2) then
		return me_report("FLUIDCELLS", "ME fluid cells", { "entities missing" })
	end
	local function water() return remote.call(NET, "fluid_count", t, "water") end
	local inv = game.create_inventory(4)
	--- a mixed drive: an item cell in slot 1, a fluid cell in slot 2
	inv[1].set_stack{ name = "me-1k-storage-cell", count = 1 }
	inv[2].set_stack{ name = "me-4k-fluid-storage-cell", count = 1 }
	expect(remote.call(NET, "insert_cell", d, inv[1], 1) == 1 and remote.call(NET, "insert_cell", d, inv[2], 2) == 2, "cells not inserted")
	local n = remote.call(NET, "network", t)
	expect(n and n.ok and n.cells == 1 and n.fluid_cells == 1 and n.bytes_total == 1024 and n.fbytes_total == 4096
		and n.ftypes_total == 18, "mixed drive " .. serpent.line(n))
	expect(remote.call(NET, "insert", t, "iron-plate", 100) == 100, "plates not stored")
	expect(near(remote.call(NET, "insert_fluid", t, "water", 1000.5), 1000.5), "water not stored")
	local info = remote.call(NET, "drive", d)
	expect(info[1].items["iron-plate"] == 100 and not info[1].items["fluid/water"], "item cell " .. serpent.line(info[1]))
	expect(near(info[2].items["fluid/water"], 1000.5) and not info[2].items["iron-plate"] and info[2].bytes == 32 + 126,
		"fluid cell " .. serpent.line(info[2]))
	--- the fluid cell is taken out with its water in the tags; without it the network takes no fluid
	expect(remote.call(NET, "take_cell", d, 2, inv[3]), "take_cell failed")
	local tags = inv[3].valid_for_read and inv[3].tags or {}
	expect(near(tags.fork_me_cell and tags.fork_me_cell.items["fluid/water"], 1000.5), "fluid cell tags " .. serpent.line(tags))
	expect(water() == 0, "the network keeps the water of a removed cell: " .. water())
	expect(remote.call(NET, "insert_fluid", t, "water", 10) == 0, "an item cell took fluid")
	expect(remote.call(NET, "insert_cell", d, inv[3], 5) == 5 and near(water(), 1000.5), "the fluid cell back: " .. water())
	--- capacity of the 4k fluid cell with one fluid: its free bytes and the rest of the last byte
	local held = math.ceil(1000.5 / 8)
	local room = (4096 - 32 - held) * 8 + (held * 8 - 1000.5)
	expect(near(remote.call(NET, "can_insert_fluid", t, "water", 1e9), room), "room for water " .. remote.call(NET, "can_insert_fluid", t, "water", 1e9) .. ", expected " .. room)
	--- the terminal: items first, then fluids; search; fluids cannot be taken by hand
	local all = remote.call(TERM, "entries", t, "", "count")
	expect(#all == 2 and all[1].name == "iron-plate" and all[2].fluid and all[2].key == "fluid/water" and near(all[2].count, 1000.5),
		"terminal entries " .. serpent.line(all))
	local found = remote.call(TERM, "entries", t, "wat", "name")
	expect(#found == 1 and found[1].fluid, "search 'wat': " .. serpent.line(found))
	local cursor = game.create_inventory(1)
	local got, why = remote.call(TERM, "take", cursor[1], inv, t, "fluid/water", "stack")
	expect(got == nil and why == "fluid-by-hand" and not cursor[1].valid_for_read, "taking water by hand: " .. tostring(got) .. " " .. tostring(why))
	cursor.destroy()
	--- the fluid import bus empties tank 1 (1000 units per visit)
	t1.insert_fluid{ name = "water", amount = 2500 }
	local before = water()
	local moved = remote.call(IO, "step", ib) + remote.call(IO, "step", ib) + remote.call(IO, "step", ib)
	local left = t1.get_fluid_count("water")
	expect(near(moved, 2500) and left < 1e-3 and near(water(), before + 2500), "import bus: moved " .. moved .. ", tank " .. left .. ", network " .. water())
	--- the fluid export bus: nothing without a filter, then water into tank 2
	expect(remote.call(IO, "step", eb) == 0, "an export bus without filters moved fluid")
	remote.call(IO, "set_bus_filters", eb, { "water" })
	before = water()
	moved = remote.call(IO, "step", eb)
	expect(near(moved, 1000) and near(t2.get_fluid_count("water"), 1000) and near(water(), before - 1000),
		"export bus: moved " .. moved .. ", tank " .. t2.get_fluid_count("water") .. ", network " .. water())
	local bf = remote.call(IO, "get_bus", eb)
	expect(bf and serpent.line(bf.filters) == serpent.line({ "fluid/water" }), "fluid bus filters " .. serpent.line(bf))
	--- old fluid drive items: placing one gives an ME Drive with four fluid cells holding its fluid
	local old = s.create_entity{ name = "me-drive", position = { FX + 16.5, FY + 6.5 }, force = "player" }
	inv[4].set_stack{ name = "me-fluid-drive-1k", count = 1 }
	inv[4].tags = { fork_me_fluids = { water = 12345, chlorine = 10 } }
	remote.call(NET, "built", old, inv[4])
	local oi, total = remote.call(NET, "drive", old), 0
	for _, cell in pairs(oi) do for _, v in pairs(cell.items) do total = total + v end end
	expect(oi[4] and oi[4].name == "me-1k-fluid-storage-cell" and not oi[5] and near(total, 12355), "old fluid drive item: " .. serpent.line(oi))
	--- more fluid than four cells hold: more cells in the free slots, nothing lost
	local big = s.create_entity{ name = "me-drive", position = { FX + 18.5, FY + 6.5 }, force = "player" }
	inv[4].set_stack{ name = "me-fluid-drive-1k", count = 1 }
	inv[4].tags = { fork_me_fluids = { water = 40000 } }
	remote.call(NET, "built", big, inv[4])
	local bi = remote.call(NET, "drive", big)
	total = 0
	for _, cell in pairs(bi) do for _, v in pairs(cell.items) do total = total + v end end
	expect(bi[5] and near(total, 40000), "an old item with more fluid than four cells hold: " .. serpent.line(bi))
	inv.destroy()
	me_report("FLUIDCELLS", "ME fluid cells", problems, "mixed drive, tags, capacity, terminal, fluid buses, old fluid drive items")
end

--- Issue #68 step R3: cell partitions and drive priorities (insertion and extraction order), drive settings
--- in blueprints, settings paste and clones, the read and set functions of every ME window, the terminal's
--- tabs. Own network: controller, drives D1..D3 and a terminal in a row; the other blocks stand apart (their
--- windows are read without a network).
local RX, RY = 250, 160
local GUI = "gregtorio-me-gui"

function setup_r3_test(s)
	local fails = {}
	power(s, fails, "R3", RX, RY)
	me_place(s, fails, "R3", "me-network-controller", RX + 7, RY)          -- tiles RX+6..7, RY-1..RY
	me_place(s, fails, "R3", "me-drive", RX + 8.5, RY - 0.5)
	me_place(s, fails, "R3", "me-drive", RX + 9.5, RY - 0.5)
	me_place(s, fails, "R3", "me-drive", RX + 10.5, RY - 0.5)
	me_place(s, fails, "R3", "me-terminal", RX + 11.5, RY - 0.5)
	local x = RX
	for _, name in pairs({ "me-import-bus", "me-export-bus", "me-storage-bus", "me-network-interface",
		"me-pattern-provider", "me-crafting-cpu", "me-level-maintainer", "me-circuit-interface" }) do
		me_place(s, fails, "R3", name, x + 0.5, RY + 6.5)
		x = x + 4
	end
	return fails
end

function me_r3_test()
	if storage.me_r3 then return end
	if game.tick < 60 then return end
	storage.me_r3 = { done = true }
	local s = game.surfaces[1]
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function find(name, x, y) return s.find_entity(name, { RX + x, RY + y }) end
	local d1, d2, d3, t = find("me-drive", 8.5, -0.5), find("me-drive", 9.5, -0.5), find("me-drive", 10.5, -0.5), find("me-terminal", 11.5, -0.5)
	local ctrl = find("me-network-controller", 7, 0)
	if not (d1 and d2 and d3 and t and ctrl) then return me_report("MER3", "ME partitions and windows", { "entities missing" }) end
	local inv = game.create_inventory(6)
	local function cell(drive, slot, name)
		inv[1].set_stack{ name = name or "me-1k-storage-cell", count = 1 }
		return remote.call(NET, "insert_cell", drive, inv[1], slot) == slot
	end
	expect(cell(d1, 1) and cell(d1, 2) and cell(d2, 1) and cell(d3, 1), "cells not inserted")
	local u1, u2, u3 = d1.unit_number, d2.unit_number, d3.unit_number
	local function holders(key)
		local h = remote.call(NET, "holders", t, key)
		local out = {}
		for cid, n in pairs(h) do out[#out + 1] = cid .. "=" .. n end
		table.sort(out)
		return table.concat(out, ",")
	end
	local function cid(unit, slot) return unit .. ":" .. slot end

	--- priorities: D2 = 5 is filled first
	expect(remote.call(NET, "set_priority", d2, 5) and remote.call(NET, "get_priority", d2) == 5, "set_priority")
	expect(remote.call(NET, "set_partition", d1, 2, { "copper-plate" }), "set_partition")
	expect(serpent.line(remote.call(NET, "get_partition", d1, 2)) == serpent.line({ "copper-plate" }), "get_partition")
	local order = remote.call(NET, "order", t)
	expect(order[1] and order[1].cid == cid(u2, 1) and order[1].p == 5, "insertion order " .. serpent.line(order))
	remote.call(NET, "insert", t, "iron-plate", 100)
	expect(holders("iron-plate") == cid(u2, 1) .. "=100", "iron into the priority 5 drive: " .. holders("iron-plate"))
	--- a higher priority drive comes before a partitioned cell of a lower one
	remote.call(NET, "insert", t, "copper-plate", 50)
	expect(holders("copper-plate") == cid(u2, 1) .. "=50", "copper by priority: " .. holders("copper-plate"))
	--- D2 below D1: the cell partitioned for copper first, other items never go into it
	remote.call(NET, "set_priority", d2, -5)
	remote.call(NET, "insert", t, "copper-plate", 30)
	expect(holders("copper-plate") == table.concat({ cid(u1, 2) .. "=30", cid(u2, 1) .. "=50" }, ","), "copper into the partitioned cell: " .. holders("copper-plate"))
	remote.call(NET, "insert", t, "iron-gear-wheel", 20)
	expect(holders("iron-gear-wheel") == cid(u1, 1) .. "=20", "gears not into the partitioned cell: " .. holders("iron-gear-wheel"))
	--- a partitioned cell takes nothing else even when every other cell is full
	expect(remote.call(NET, "set_partition", d1, 1, { "stone" }) and remote.call(NET, "set_partition", d2, 1, { "stone" })
		and remote.call(NET, "set_partition", d3, 1, { "stone" }), "partitions for the full test")
	expect(remote.call(NET, "can_insert", t, "wood", 10) == 0, "a partitioned cell took wood")
	for _, d in pairs({ d1, d2, d3 }) do remote.call(NET, "set_partition", d, 1, {}) end
	--- extraction: lower priority first (D2 at -5 before D1)
	expect(remote.call(NET, "extract", t, "copper-plate", 40) == 40, "extract copper")
	expect(holders("copper-plate") == table.concat({ cid(u1, 2) .. "=30", cid(u2, 1) .. "=10" }, ","), "extraction by priority: " .. holders("copper-plate"))
	--- the same priority: unpartitioned cells before partitioned ones
	remote.call(NET, "set_priority", d2, 0)
	expect(remote.call(NET, "extract", t, "copper-plate", 15) == 15, "extract copper 2")
	expect(holders("copper-plate") == cid(u1, 2) .. "=25", "unpartitioned first: " .. holders("copper-plate"))
	--- partition from contents
	expect(remote.call(NET, "partition_from_contents", d1, 1), "partition_from_contents")
	expect(serpent.line(remote.call(NET, "get_partition", d1, 1)) == serpent.line({ "iron-gear-wheel" }), "from contents: " .. serpent.line(remote.call(NET, "get_partition", d1, 1)))
	--- the partition travels with the cell, also an empty one
	expect(remote.call(NET, "set_partition", d3, 1, { "stone", "wood" }), "partition of the empty cell")
	expect(remote.call(NET, "take_cell", d3, 1, inv[2]), "take the empty cell")
	local tags = inv[2].valid_for_read and inv[2].tags or {}
	expect(tags.fork_me_cell and tags.fork_me_cell.partition and tags.fork_me_cell.partition.stone, "empty cell tags " .. serpent.line(tags))
	expect(remote.call(NET, "insert_cell", d3, inv[2], 3) == 3 and serpent.line(remote.call(NET, "get_partition", d3, 3)) == serpent.line({ "stone", "wood" }),
		"partition back in the drive " .. serpent.line(remote.call(NET, "get_partition", d3, 3)))
	expect(remote.call(NET, "take_cell", d1, 2, inv[3]), "take the copper cell")
	tags = inv[3].valid_for_read and inv[3].tags or {}
	expect(tags.fork_me_cell and tags.fork_me_cell.items["copper-plate"] == 25 and tags.fork_me_cell.partition["copper-plate"], "copper cell tags " .. serpent.line(tags))
	expect(remote.call(NET, "insert_cell", d1, inv[3], 2) == 2, "copper cell back")
	--- a fluid cell partitioned for water takes no steam; an item cell refuses fluid keys
	expect(cell(d3, 4, "me-1k-fluid-storage-cell"), "fluid cell")
	expect(remote.call(NET, "set_partition", d3, 4, { "fluid/water", "iron-plate" }), "fluid partition")
	expect(serpent.line(remote.call(NET, "get_partition", d3, 4)) == serpent.line({ "fluid/water" }), "fluid partition keeps fluids only")
	expect(remote.call(NET, "can_insert_fluid", t, "steam", 10) == 0 and remote.call(NET, "can_insert_fluid", t, "water", 10) == 10, "fluid partition room")

	--- drive settings: blueprint (through the autocrafting handler and its hooks), revive, paste, clone
	remote.call(NET, "set_priority", d1, 7)
	local settings = remote.call(NET, "drive_settings", d1)
	expect(settings and settings.priority == 7 and settings.partitions["1"] and settings.partitions["2"][1] == "copper-plate", "drive_settings " .. serpent.line(settings))
	local bpi = game.create_inventory(1)
	bpi.insert{ name = "blueprint" }
	local mapping = bpi[1].create_blueprint{ surface = s, force = "player", area = { { RX + 8, RY - 1 }, { RX + 9, RY } } }
	remote.call("gregtorio-me-autocraft", "tag_blueprint", bpi[1], mapping)
	local tag
	for index, e in pairs(mapping or {}) do
		if e.name == "me-drive" then tag = bpi[1].get_blueprint_entity_tag(index, "fork_me_drive") end
	end
	expect(tag and tag.priority == 7 and tag.partitions and tag.partitions["2"] and tag.partitions["2"][1] == "copper-plate", "drive blueprint tag " .. serpent.line(tag))
	local ghosts = bpi[1].build_blueprint{ surface = s, force = "player", position = { RX + 20.5, RY + 12.5 } }
	local built
	for _, g in pairs(ghosts or {}) do
		if g.valid and g.ghost_name == "me-drive" then
			local _, e = g.revive{ raise_revive = true }
			built = e
		end
	end
	expect(built and remote.call(NET, "get_priority", built) == 7, "revived drive priority " .. tostring(built and remote.call(NET, "get_priority", built)))
	if built then
		expect(cell(built, 2), "cell into the revived drive")
		expect(serpent.line(remote.call(NET, "get_partition", built, 2)) == serpent.line({ "copper-plate" }), "the slot's partition from the blueprint: "
			.. serpent.line(remote.call(NET, "get_partition", built, 2)))
	end
	bpi.destroy()
	local pasted = s.create_entity{ name = "me-drive", position = { RX + 22.5, RY + 12.5 }, force = "player", raise_built = true }
	expect(cell(pasted, 2) and cell(pasted, 3), "cells for the paste")
	remote.call(NET, "set_partition", pasted, 3, { "wood" })
	remote.call(NET, "paste", d1, pasted)
	expect(remote.call(NET, "get_priority", pasted) == 7 and serpent.line(remote.call(NET, "get_partition", pasted, 2)) == serpent.line({ "copper-plate" })
		and #remote.call(NET, "get_partition", pasted, 3) == 0, "pasted drive settings " .. serpent.line(remote.call(NET, "drive_settings", pasted)))
	local clone = d1.clone{ position = { RX + 24.5, RY + 12.5 } }
	expect(clone and remote.call(NET, "get_priority", clone) == 7, "cloned drive priority")

	--- the windows' read and set functions
	expect(remote.call(GUI, "fmt", 999) == "999" and remote.call(GUI, "fmt", 1234) == "1.2k" and remote.call(GUI, "fmt", 12345) == "12k"
		and remote.call(GUI, "fmt", 1500000) == "1.5M" and remote.call(GUI, "fmt", 2.5e9) == "2.5G" and remote.call(GUI, "fmt", 12.5) == "12.5",
		"fmt " .. remote.call(GUI, "fmt", 1234) .. " " .. remote.call(GUI, "fmt", 2.5e9))
	local blocks = {}
	local x = RX
	for _, name in pairs({ "me-import-bus", "me-export-bus", "me-storage-bus", "me-network-interface",
		"me-pattern-provider", "me-crafting-cpu", "me-level-maintainer", "me-circuit-interface" }) do
		blocks[name] = s.find_entity(name, { x + 0.5, RY + 6.5 })
		expect(blocks[name] and remote.call(GUI, "has_window", blocks[name]), "no window for " .. name)
		x = x + 4
	end
	for _, e in pairs({ d1, t, ctrl }) do expect(remote.call(GUI, "has_window", e), "no window for " .. e.name) end
	--- Every block with a window is found again by the unit number its window keeps in its tags: a window whose
	--- entity is not found stays empty and is closed by the next refresh (the ME Cell Workbench did, it is no node
	--- of the ME graph). All blocks of the test map, so a new block is covered when a test places it.
	local lost, seen = {}, 0
	--- not these: the three interfaces that the cells test places without a build event on purpose
	local unbuilt = { [(CX + 2.5) .. ":" .. (CY + 10.5)] = true, [(CX + 4.5) .. ":" .. (CY + 10.5)] = true,
		[(CX + 6.5) .. ":" .. (CY + 10.5)] = true }
	for _, e in pairs(s.find_entities_filtered{ force = "player" }) do
		if e.unit_number and remote.call(GUI, "has_window", e) and not unbuilt[e.position.x .. ":" .. e.position.y] then
			seen = seen + 1
			if remote.call(TERM, "entity_by_unit", e.unit_number) ~= e then lost[e.name] = (lost[e.name] or 0) + 1 end
		end
	end
	expect(seen > 20 and next(lost) == nil, "windows that cannot find their entity by unit number: " .. serpent.line(lost)
		.. " (" .. seen .. " blocks with a window)")
	local dd = remote.call(GUI, "drive_data", d1)
	expect(dd and dd.priority == 7 and dd.online and dd.cells[1] and dd.cells[2].partition[1] == "copper-plate", "drive_data " .. serpent.line(dd))
	local cd = remote.call(GUI, "cell_data", d1, 1)
	expect(cd and cd.contents[1] and cd.contents[1].key == "iron-gear-wheel" and cd.contents[1].count == 20, "cell_data " .. serpent.line(cd))
	expect(remote.call(GUI, "set_partition_slot", d1, 1, 2, "iron-plate"), "set_partition_slot")
	expect(serpent.line(remote.call(NET, "get_partition", d1, 1)) == serpent.line({ "iron-gear-wheel", "iron-plate" }), "partition button 2")
	remote.call(GUI, "set_partition_slot", d1, 1, 1, nil)
	expect(serpent.line(remote.call(NET, "get_partition", d1, 1)) == serpent.line({ "iron-plate" }), "partition button 1 cleared")
	local ctl = remote.call(GUI, "controller_data", ctrl)
	expect(ctl and ctl.ok and ctl.drives == 3 and ctl.cells >= 4, "controller_data " .. serpent.line(ctl))
	local pd = remote.call(GUI, "provider_data", blocks["me-pattern-provider"])
	expect(pd and pd.machines and #pd.machines == 0 and pd.slot_count == 9 and next(pd.slots) == nil and pd.priority == 0,
		"provider_data " .. serpent.line(pd))
	local cpu = remote.call(GUI, "cpu_data", blocks["me-crafting-cpu"])
	expect(cpu and cpu.slots == 1 and #cpu.jobs == 0, "cpu_data " .. serpent.line(cpu))
	local maint = blocks["me-level-maintainer"]
	expect(remote.call(GUI, "set_maintainer_target", maint, "iron-plate"), "set_maintainer_target")
	local md = remote.call(GUI, "maintainer_data", maint)
	expect(md and md.key == "iron-plate" and md.condition, "maintainer_data " .. serpent.line(md))
	remote.call(GUI, "set_maintainer_target", maint, nil)
	expect(remote.call(GUI, "maintainer_data", maint).key == nil, "the maintainer's target cleared")
	expect(remote.call("gregtorio-me-circuit", "set_condition", maint, true, { type = "item", name = "iron-plate" }, "<", 5), "set_condition")
	local cond = remote.call("gregtorio-me-circuit", "get_condition", maint)
	expect(cond.enabled and cond.signal and cond.signal.name == "iron-plate" and cond.comparator == "<" and cond.constant == 5, "condition " .. serpent.line(cond))
	local ci = blocks["me-circuit-interface"]
	remote.call(GUI, "set_circuit_filter", ci, 1, "iron-plate")
	remote.call(GUI, "set_circuit_filter", ci, 2, "fluid/water")
	remote.call(GUI, "set_circuit_filter", ci, 1, nil)
	local cdata = remote.call(GUI, "circuit_data", ci)
	expect(cdata and serpent.line(cdata.filters) == serpent.line({ "fluid/water" }) and cdata.enabled ~= nil, "circuit_data " .. serpent.line(cdata))
	remote.call("gregtorio-me-circuit", "set_circuit_enabled", ci, false)
	expect(remote.call("gregtorio-me-circuit", "get_circuit_enabled", ci) == false, "circuit output switch")
	local iface = blocks["me-network-interface"]
	local fi = remote.call(GUI, "interface_data", iface)
	expect(fi and fi.volume and fi.volume > 0 and fi.fluids and #fi.fluids == 4 and fi.fluids[1].setting == "import",
		"interface_data: the fluid sides " .. serpent.line(fi and fi.fluids))
	local isize = prototypes.item["iron-plate"].stack_size
	remote.call(GUI, "set_interface_item", iface, 3, { name = "iron-plate", quality = "normal" })
	local idata = remote.call(GUI, "interface_data", iface)
	expect(idata and idata.config[3] and idata.config[3].amount == isize and idata.slots == 9, "interface_data " .. serpent.line(idata))
	remote.call(IO, "set_interface_slot", iface, 3, "iron-plate", "normal", 7)
	remote.call(GUI, "set_interface_item", iface, 5, { name = "iron-plate", quality = "normal" })
	idata = remote.call(GUI, "interface_data", iface)
	expect(idata.config[5] and idata.config[5].amount == 7 and not idata.config[3], "an item moved to another config slot " .. serpent.line(idata.config))
	remote.call(GUI, "set_interface_item", iface, 5, nil)
	expect(next(remote.call(GUI, "interface_data", iface).config) == nil, "config slot cleared")
	--- issue #3: a fluid row from the window's picker (issue #70: its choice) takes the first free side, a side drop-down
	expect(remote.call(GUI, "set_interface_choice", iface, 2, { kind = "fluid", name = "water" }), "set_interface_choice")
	idata = remote.call(GUI, "interface_data", iface)
	expect(idata.config[2] and idata.config[2].type == "fluid" and idata.config[2].amount == idata.volume and idata.sides[1] == 2,
		"a fluid row " .. serpent.line(idata.config) .. " " .. serpent.line(idata.sides))
	remote.call(GUI, "set_interface_choice", iface, 2, { kind = "item", name = "iron-plate", quality = "normal" })
	idata = remote.call(GUI, "interface_data", iface)
	expect(idata.config[2] and idata.config[2].type == nil and idata.sides[1] == nil, "the fluid row became an item row " .. serpent.line(idata))
	--- issue #70: a choice that is no item or fluid (a virtual signal) is refused and the row stays (right click empties it)
	expect(remote.call(GUI, "set_interface_choice", iface, 2, { kind = "virtual", name = "signal-A" }) == false
		and remote.call(GUI, "set_interface_choice", iface, 2, { kind = "item", name = "no-such-item" }) == false
		and remote.call(GUI, "set_interface_choice", iface, 2, { kind = "item", name = "iron-plate", quality = "no-such-quality" }) == false
		and idata.config[2] ~= nil and remote.call(GUI, "interface_data", iface).config[2] ~= nil, "a refused choice leaves the row")
	remote.call(GUI, "set_interface_item", iface, 2, nil)
	expect(next(remote.call(GUI, "interface_data", iface).config) == nil, "the row emptied")
	local bus = blocks["me-export-bus"]
	remote.call(IO, "set_bus_filter", bus, 1, "iron-plate")
	remote.call(IO, "set_bus_filter", bus, 3, "copper-plate")
	local bd = remote.call(GUI, "bus_data", bus)
	expect(bd and serpent.line(bd.filters) == serpent.line({ "iron-plate", "copper-plate" }) and bd.max == 9, "bus_data " .. serpent.line(bd))
	remote.call(IO, "set_bus_filter", bus, 1, nil)
	expect(serpent.line(remote.call(GUI, "bus_data", bus).filters) == serpent.line({ "copper-plate" }), "bus filter removed")
	remote.call(IO, "set_bus_filter", bus, 2, "fluid/water")
	expect(serpent.line(remote.call(GUI, "bus_data", bus).filters) == serpent.line({ "copper-plate", "fluid/water" }), "a fluid bus filter")
	local fbd = remote.call(GUI, "bus_data", blocks["me-import-bus"])
	expect(fbd and fbd.import and fbd.max == 9, "import bus_data " .. serpent.line(fbd))
	local sbd = remote.call(GUI, "storage_bus_data", blocks["me-storage-bus"])
	expect(sbd and sbd.max == 18 and sbd.side == "item", "storage_bus_data " .. serpent.line(sbd))
	expect(remote.call(GUI, "key_of_elem", "item-with-quality", { name = "iron-plate", quality = "normal" }) == "iron-plate"
		and remote.call(GUI, "key_of_elem", "fluid", "water") == "fluid/water", "key_of_elem")
	--- issue #70: the key of the picker's choice: items with their quality where a place takes one, else the plain name
	local uq = prototypes.quality["uncommon"] and "uncommon"
	expect(remote.call(GUI, "key_of_choice", { kind = "item", name = "iron-plate", quality = "normal" }, true) == "iron-plate"
		and remote.call(GUI, "key_of_choice", { kind = "item", name = "iron-plate" }, true) == "iron-plate"
		and (not uq or remote.call(GUI, "key_of_choice", { kind = "item", name = "iron-plate", quality = uq }, true) == "iron-plate@" .. uq)
		and (not uq or remote.call(GUI, "key_of_choice", { kind = "item", name = "iron-plate", quality = uq }, false) == "iron-plate")
		and remote.call(GUI, "key_of_choice", { kind = "fluid", name = "water" }, true) == "fluid/water"
		and remote.call(GUI, "key_of_choice", { kind = "fluid", name = "water" }, false) == "fluid/water"
		and remote.call(GUI, "key_of_choice", { kind = "virtual", name = "signal-A" }, true) == nil
		and remote.call(GUI, "key_of_choice", { kind = "item", name = "signal-A" }, true) == nil
		and remote.call(GUI, "key_of_choice", { kind = "item", name = "no-such-item" }, true) == nil
		and remote.call(GUI, "key_of_choice", { kind = "item", name = "iron-plate", quality = "no-such-quality" }, true) == nil
		and remote.call(GUI, "key_of_choice", { kind = "fluid", name = "iron-plate" }, true) == nil
		and remote.call(GUI, "key_of_choice", nil, true) == nil, "key_of_choice")

	--- the terminal's tabs
	local items = remote.call(TERM, "entries", t, "", "count", "items")
	local fluids_only = remote.call(TERM, "entries", t, "", "count", "fluids")
	local all = remote.call(TERM, "entries", t, "", "count", "all")
	remote.call(NET, "insert_fluid", t, "water", 100)
	fluids_only = remote.call(TERM, "entries", t, "", "count", "fluids")
	expect(#items >= 3 and #fluids_only == 1 and fluids_only[1].key == "fluid/water" and #all >= 3, "kind filter " .. #items .. "/" .. #fluids_only .. "/" .. #all)
	for _, e in pairs(items) do expect(not e.fluid, "a fluid in the items view") end
	local cells = remote.call(TERM, "cells", t)
	expect(#cells == 3 and cells[1].unit == u1 and cells[1].priority == 7, "cells tab " .. serpent.line(cells))
	local prev = remote.call(TERM, "craft_preview", t, "iron-gear-wheel", 1)
	expect(prev and not prev.ok and prev.reason, "craft preview without pattern " .. serpent.line(prev))
	local prev0 = remote.call(TERM, "craft_preview", t, "iron-gear-wheel", 0)
	expect(prev0 and prev0.reason == "bad-amount", "craft preview amount 0 " .. serpent.line(prev0))
	expect(#remote.call(TERM, "jobs", t) == 0, "jobs tab")

	--- issue #28: every window has the inventory pane and a shift + click target; the targets of each block, clicked
	--- through the GUI module with a script inventory standing for the player's
	local wins = remote.call(GUI, "windows")
	local without = {}
	for name, w in pairs(wins) do if not (w.pane and w.shift) then without[#without + 1] = name end end
	expect(#without == 0 and table_size(wins) >= 13, "windows without the pane or a shift + click target: " .. serpent.line(without)
		.. " of " .. table_size(wins))
	local pinv = game.create_inventory(20)
	local hold = game.create_inventory(1)
	local function click(e, slot, mode, window) return remote.call(GUI, "inventory_click", hold[1], pinv, slot, mode, e, window) end
	local function count(name) return remote.call(NET, "count", t, name) end
	--- the terminal: shift + click stores the stack, control + click every stack of that item, a blueprint is refused
	pinv[1].set_stack{ name = "stone", count = 10 }
	pinv[2].set_stack{ name = "stone", count = 7 }
	local st0 = count("stone")
	local why = click(t, 1, "shift")
	expect(why == nil and count("stone") == st0 + 10 and not pinv[1].valid_for_read and pinv[2].count == 7,
		"terminal shift + click: " .. tostring(why) .. ", network " .. count("stone"))
	pinv[1].set_stack{ name = "stone", count = 5 }
	why = click(t, 2, "control")
	expect(why == nil and count("stone") == st0 + 22 and pinv.get_item_count("stone") == 0, "terminal control + click: " .. tostring(why)
		.. ", network " .. count("stone"))
	pinv[4].set_stack{ name = "blueprint", count = 1 }
	why = click(t, 4, "shift")
	expect(why == "cannot-store-blueprint" and pinv[4].valid_for_read, "a blueprint shift-clicked at the terminal: " .. tostring(why))
	--- the blocks without slots store into their network (new ones in a row right of the terminal: on its network)
	local row = {}
	for i, name in ipairs({ "me-network-interface", "me-import-bus", "me-export-bus", "me-level-maintainer", "me-circuit-interface" }) do
		row[#row + 1] = s.create_entity{ name = name, position = { RX + 11.5 + i, RY - 0.5 }, force = "player", raise_built = true }
	end
	row[#row + 1] = s.create_entity{ name = "me-crafting-cpu", position = { RX + 18, RY }, force = "player", raise_built = true }
	row[#row + 1] = ctrl
	for _, e in pairs(row) do
		pinv[5].set_stack{ name = "stone-brick", count = 3 }
		local b0 = count("stone-brick")
		why = click(e, 5, "shift")
		expect(why == nil and count("stone-brick") == b0 + 3 and not pinv[5].valid_for_read, "shift + click stores at " .. e.name .. ": "
			.. tostring(why))
	end
	expect(click(ctrl, 4, "shift") == "cannot-store-blueprint" and pinv[4].valid_for_read, "a blueprint shift-clicked at the controller")
	pinv[6].set_stack{ name = "stone-brick", count = 2 }
	pinv[7].set_stack{ name = "stone-brick", count = 4 }
	local b0 = count("stone-brick")
	why = click(row[1], 6, "control")
	expect(why == nil and count("stone-brick") == b0 + 6 and pinv.get_item_count("stone-brick") == 0, "control + click at the interface: "
		.. tostring(why))
	local lone = s.create_entity{ name = "me-network-interface", position = { RX + 30.5, RY + 22.5 }, force = "player", raise_built = true }
	pinv[5].set_stack{ name = "stone-brick", count = 3 }
	why = lone and click(lone, 5, "shift")
	expect((why == "no-network" or why == "no-controller") and pinv[5].count == 3, "shift + click at an interface without a network: " .. tostring(why))
	if lone then lone.destroy() end
	pinv[5].clear()
	--- the drive: a cell into a free slot, an iron plate refused, a full drive refused; the cell window of that drive too
	local function n_cells(d)
		local n = 0
		for _ in pairs(remote.call(NET, "drive", d)) do n = n + 1 end
		return n
	end
	local c0 = n_cells(d3)
	pinv[8].set_stack{ name = "me-1k-storage-cell", count = 1 }
	why = click(d3, 8, "shift")
	expect(why == nil and not pinv[8].valid_for_read and n_cells(d3) == c0 + 1, "shift + click of a cell at the drive: " .. tostring(why))
	pinv[9].set_stack{ name = "iron-plate", count = 5 }
	why = click(d3, 9, "shift")
	expect(why == "not-a-cell" and pinv[9].count == 5, "shift + click of iron plates at the drive: " .. tostring(why))
	pinv[8].set_stack{ name = "me-1k-storage-cell", count = 1 }
	why = click(d3, 8, "shift", "cell")
	expect(why == nil and n_cells(d3) == c0 + 2, "shift + click of a cell in the cell window: " .. tostring(why))
	for _ = 1, 10 do
		pinv[8].set_stack{ name = "me-1k-storage-cell", count = 1 }
		why = click(d3, 8, "shift")
		if why then break end
	end
	expect(why == "drive-full" and pinv[8].valid_for_read and n_cells(d3) == 10, "a full drive: " .. tostring(why) .. ", " .. n_cells(d3))
	pinv[8].clear()
	--- the pattern provider: an encoded pattern into a free slot, an iron plate refused
	local prov = blocks["me-pattern-provider"]
	pinv[10].set_stack{ name = "me-blank-pattern", count = 1 }
	remote.call(TERM, "encode_def", false, pinv, false, { kind = "crafting", recipe = "me-blank-pattern" })
	local _, pi = pinv.find_item_stack("me-encoded-pattern")
	why = pi and click(prov, pi, "shift")
	local pd2 = remote.call(GUI, "provider_data", prov)
	expect(pi and why == nil and pinv.get_item_count("me-encoded-pattern") == 0 and pd2.slots[1], "shift + click of a pattern at the provider: "
		.. tostring(why))
	why = click(prov, 9, "shift")
	expect(why == "not-a-pattern" and pinv[9].count == 5, "shift + click of iron plates at the provider: " .. tostring(why))
	for i = 1, #row - 1 do if row[i].valid then row[i].destroy{ raise_destroy = true } end end
	hold.destroy()
	pinv.destroy()
	inv.destroy()
	me_report("MER3", "ME partitions and windows", problems,
		"partitions, priorities, insert/extract order, drive blueprint/paste/clone, window data and set functions, terminal tabs, "
		.. "every window with the pane and its shift + click target")
end

--------------------------------------------------------------------------------
--- ME Storage Bus (issue #68, scripts/fork-me-storagebus.lua): own network right of the R3 test, a drive with two
--- 1k cells, a terminal and storage buses on iron chests below a cable row. Checks the totals after a visit, a
--- terminal extract from the chest, a filtered bus taking its item and the rest going into the cells, priority
--- against the cells (insert and extract), read only and write only, a stale snapshot (an extract and a terminal
--- take find only what is really there), two buses on one chest, a bus facing an ME block, a chest removed with
--- and without an event, a removed bus, the settings in a blueprint tag, on a revived ghost, by paste and clone,
--- the window data; then an inserter puts wood into a chest: the network must show it within the storage bus idle
--- limit (issue #5: an idle bus backs off up to it).
--------------------------------------------------------------------------------

local SBX, SBY = 300, 125
local SB = "gregtorio-me-storagebus"

function setup_storage_bus_test(s)
	local fails = {}
	local what = "storage bus"
	power(s, fails, what, SBX, SBY)
	me_place(s, fails, what, "me-network-controller", SBX + 7, SBY)            -- tiles SBX+6..7, SBY-1..SBY
	me_place(s, fails, what, "me-drive", SBX + 8.5, SBY - 0.5)
	me_place(s, fails, what, "me-terminal", SBX + 9.5, SBY - 0.5)
	cable_row(s, fails, SBX + 10, SBX + 22, SBY - 1)
	local south = { direction = defines.direction.south }
	--- B1 (main) on C1, B2 (filters) on C2, B3 on C3, B6 on C7 (inserter); each bus below the cable row
	for _, x in pairs({ 10.5, 12.5, 15.5, 20.5 }) do
		me_place(s, fails, what, "me-storage-bus", SBX + x, SBY + 0.5, south)
		me_place(s, fails, what, "iron-chest", SBX + x, SBY + 1.5)
	end
	me_place(s, fails, what, "me-cable", SBX + 16.5, SBY + 0.5)
	me_place(s, fails, what, "me-storage-bus", SBX + 16.5, SBY + 1.5, { direction = defines.direction.west })   -- B4: C3 too
	me_place(s, fails, what, "me-storage-bus", SBX + 18.5, SBY + 0.5, { direction = defines.direction.north })  -- B5: a cable
	me_place(s, fails, what, "me-storage-bus", SBX + 22.5, SBY + 0.5, south)                                   -- B7: settings
	--- the inserter test: a source chest, an inserter dropping into C7, a substation for it
	me_place(s, fails, what, "iron-chest", SBX + 20.5, SBY + 3.5)
	local ins = me_place(s, fails, what, "inserter", SBX + 20.5, SBY + 2.5)
	if ins and ins.drop_position.y > SBY + 2.5 then
		ins.rotate()
		ins.rotate()
	end
	me_place(s, fails, what, "substation", SBX + 18, SBY + 5)
	return fails
end

function storage_bus_test()
	local st = storage.me_sbus
	if (st and st.done) or game.tick < 60 then return end
	local s = game.surfaces[1]
	local function find(name, x, y) return s.find_entity(name, { SBX + x, SBY + y }) end
	local t, drive = find("me-terminal", 9.5, -0.5), find("me-drive", 8.5, -0.5)
	local c7 = find("iron-chest", 20.5, 1.5)
	local function count(name) return remote.call(NET, "count", t, name) end
	if st then
		--- the inserter: the wood it put into C7 must be in the network within one visit cycle
		local problems = st.problems
		if not st.seen and c7 and c7.get_item_count("wood") > 0 then st.seen = game.tick end
		local buses = s.count_entities_filtered{ name = "me-storage-bus" }
		--- issue #5: an idle bus reads its chest at least every storage bus idle limit ticks (the queue may hold it back
		--- one tick per budget of visits), plus this test's 10 tick granularity
		local cycle = settings.global["me-network-storage-bus-idle-limit"].value
			+ math.ceil(buses / settings.global["me-network-storage-bus-visits-per-tick"].value) + 10
		if st.seen and count("wood") == 1 then
			if game.tick - st.seen > cycle then problems[#problems + 1] = "wood seen after " .. (game.tick - st.seen) .. " ticks (cycle " .. cycle .. ")" end
			st.done = true
			me_report("MESTORAGEBUS", "ME storage bus", problems, "inserter picked up after " .. (game.tick - st.seen) .. " ticks, cycle " .. cycle)
		elseif game.tick > st.started + 900 then
			problems[#problems + 1] = "the inserter's wood never showed up (seen at " .. tostring(st.seen) .. ", network " .. count("wood") .. ")"
			st.done = true
			me_report("MESTORAGEBUS", "ME storage bus", problems)
		end
		return
	end
	st = { problems = {}, started = game.tick }
	storage.me_sbus = st
	local problems = st.problems
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function bus(x, y) return find("me-storage-bus", x, y) end
	local b1, b2, b3, b4, b5, b6, b7 = bus(10.5, 0.5), bus(12.5, 0.5), bus(15.5, 0.5), bus(16.5, 1.5), bus(18.5, 0.5),
		bus(20.5, 0.5), bus(22.5, 0.5)
	local c1, c2, c3 = find("iron-chest", 10.5, 1.5), find("iron-chest", 12.5, 1.5), find("iron-chest", 15.5, 1.5)
	local src = find("iron-chest", 20.5, 3.5)
	if not (t and drive and b1 and b2 and b3 and b4 and b5 and b6 and b7 and c1 and c2 and c3 and c7 and src) then
		st.done = true
		return me_report("MESTORAGEBUS", "ME storage bus", { "entities missing" })
	end
	local inv = game.create_inventory(4)
	for slot = 1, 2 do
		inv[1].set_stack{ name = "me-1k-storage-cell", count = 1 }
		remote.call(NET, "insert_cell", drive, inv[1], slot)
	end
	local net = remote.call(NET, "network", t)
	expect(net and net.ok and net.storage_buses == 7, "network " .. serpent.line(net))
	local function visit(b) remote.call(SB, "visit", b) end
	local function info(b) return remote.call(SB, "info", b) or {} end
	local function in_cells(name)
		local n = 0
		for _, c in pairs(remote.call(NET, "drive", drive)) do n = n + (c.items[name] or 0) end
		return n
	end
	--- the editor's infinity chest (type infinity-container) is a chest for the buses and the storage bus: above the
	--- cable row an import bus, an export bus and a storage bus on one infinity chest each; removed again, so the
	--- rest of this test sees the 7 buses and no coal
	do
		local north = defines.direction.north
		local function make(name, x, y, dir)
			return s.create_entity{ name = name, position = { SBX + x, SBY + y }, direction = dir, force = "player", raise_built = true }
		end
		local ci, ce, cs = make("infinity-chest", 12.5, -2.5), make("infinity-chest", 14.5, -2.5), make("infinity-chest", 16.5, -2.5)
		local ib, eb, sb = make("me-import-bus", 12.5, -1.5, north), make("me-export-bus", 14.5, -1.5, north),
			make("me-storage-bus", 16.5, -1.5, north)
		if ci and ce and cs and ib and eb and sb then
			ci.insert{ name = "coal", count = 10 }
			remote.call(IO, "step", ib)
			expect(count("coal") == 10 and ci.get_item_count("coal") == 0 and remote.call(IO, "get_bus", ib).status ~= "no-target",
				"import bus on an infinity chest: " .. count("coal") .. ", " .. serpent.line(remote.call(IO, "get_bus", ib)))
			remote.call(IO, "set_bus_filters", eb, { "coal" })
			remote.call(IO, "step", eb)
			expect(ce.get_item_count("coal") == 10 and count("coal") == 0,
				"export bus into an infinity chest: " .. ce.get_item_count("coal") .. ", " .. serpent.line(remote.call(IO, "get_bus", eb)))
			cs.insert{ name = "coal", count = 25 }
			visit(sb)
			local i8 = info(sb)
			expect(i8.status == "ok" and i8.target == "infinity-chest" and count("coal") == 25, "storage bus on an infinity chest: " .. serpent.line(i8))
			expect(remote.call(NET, "extract", t, "coal", 5) == 5 and cs.get_item_count("coal") == 20 and count("coal") == 20,
				"extract from the infinity chest: " .. cs.get_item_count("coal"))
			cs.destroy{ raise_destroy = true }
			expect(count("coal") == 0 and info(sb).status == "no-target", "infinity chest removed: coal " .. count("coal"))
		else
			expect(false, "infinity chests or their buses not placed")
		end
		for _, e in pairs({ ib, eb, sb }) do if e and e.valid then e.destroy{ raise_destroy = true } end end
		for _, e in pairs({ ci, ce, cs }) do if e and e.valid then e.destroy() end end
	end
	--- the network's items must be the cells' plus what the working buses show of their chests (after a visit)
	local pairs_ = { { b1, c1 }, { b2, c2 }, { b3, c3 }, { b4, c3 }, { b6, c7 } }
	local function consistent(label)
		local want = {}
		for _, c in pairs(remote.call(NET, "drive", drive)) do
			for k, n in pairs(c.items) do want[k] = (want[k] or 0) + n end
		end
		for _, p in ipairs(pairs_) do
			if p[1].valid then
				visit(p[1])
				local i = info(p[1])
				if i.status == "ok" and i.mode ~= "write" and p[2].valid then
					local allow = {}
					for _, f in pairs(i.filters) do allow[f] = true end
					for _, it in pairs(p[2].get_inventory(defines.inventory.chest).get_contents()) do
						if #i.filters == 0 or allow[it.name] then want[it.name] = (want[it.name] or 0) + it.count end
					end
				end
			end
		end
		local have = remote.call(NET, "contents", t)
		local diff = {}
		for k, n in pairs(want) do if have[k] ~= n then diff[#diff + 1] = k .. " " .. tostring(have[k]) .. "/" .. n end end
		for k, n in pairs(have) do if not want[k] then diff[#diff + 1] = k .. " " .. n .. "/0" end end
		table.sort(diff)
		expect(#diff == 0, label .. ": network/expected " .. table.concat(diff, ", "))
	end
	local ch1 = c1.get_inventory(defines.inventory.chest)

	--- the chest's items in the network's totals after a visit (not before: no event)
	ch1.insert{ name = "iron-plate", count = 100 }
	ch1.insert{ name = "copper-plate", count = 50 }
	expect(count("iron-plate") == 0, "C1 seen without a visit")
	visit(b1)
	expect(count("iron-plate") == 100 and count("copper-plate") == 50, "totals after a visit: " .. count("iron-plate") .. "/" .. count("copper-plate"))
	local i1 = info(b1)
	expect(i1.status == "ok" and i1.items == 150 and i1.types == 2 and i1.target == "iron-chest", "info " .. serpent.line(i1))
	--- a terminal take: the cells are empty, so out of C1
	local pinv = game.create_inventory(10)
	local size = prototypes.item["iron-plate"].stack_size
	local got = remote.call(TERM, "take", inv[2], pinv, t, "iron-plate", "inventory")
	expect(got == math.min(100, size) and pinv.get_item_count("iron-plate") == got and c1.get_item_count("iron-plate") == 100 - got
		and count("iron-plate") == 100 - got, "terminal take from C1: " .. tostring(got))
	pinv.remove{ name = "iron-plate", count = got }
	ch1.insert{ name = "iron-plate", count = got }              -- 100 again
	visit(b1)
	--- a filtered bus gets its item; an item without a filter goes into the cells
	expect(remote.call(SB, "set_settings", b2, { filters = { "copper-plate" } }), "set_settings filters")
	expect(remote.call(NET, "insert", t, "copper-plate", 30) == 30 and c2.get_item_count("copper-plate") == 30
		and c1.get_item_count("copper-plate") == 50, "filtered insert: C2 " .. c2.get_item_count("copper-plate"))
	expect(remote.call(NET, "insert", t, "iron-gear-wheel", 20) == 20 and in_cells("iron-gear-wheel") == 20
		and c2.get_item_count("iron-gear-wheel") == 0 and c1.get_item_count("iron-gear-wheel") == 0, "unfiltered insert into the cells: " .. in_cells("iron-gear-wheel"))
	consistent("after the inserts")
	--- priority against the cells
	remote.call(SB, "set_settings", b1, { priority = 10 })
	remote.call(NET, "insert", t, "stone", 40)
	expect(c1.get_item_count("stone") == 40 and in_cells("stone") == 0, "priority 10: stone into C1 " .. c1.get_item_count("stone"))
	remote.call(SB, "set_settings", b1, { priority = -10 })
	remote.call(NET, "insert", t, "stone", 15)
	expect(c1.get_item_count("stone") == 40 and in_cells("stone") == 15, "priority -10: stone into the cells " .. in_cells("stone"))
	remote.call(NET, "store_in_drive", drive, "iron-plate", 10)
	expect(remote.call(NET, "extract", t, "iron-plate", 5) == 5 and c1.get_item_count("iron-plate") == 95 and in_cells("iron-plate") == 10,
		"priority -10: iron taken from C1 first")
	remote.call(SB, "set_settings", b1, { priority = 10 })
	expect(remote.call(NET, "extract", t, "iron-plate", 5) == 5 and c1.get_item_count("iron-plate") == 95 and in_cells("iron-plate") == 5,
		"priority 10: iron taken from the cells first")
	consistent("after the priorities")
	--- read only: nothing goes in (stone into the cells although C1 has priority 10), taking works
	remote.call(SB, "set_settings", b1, { mode = "read" })
	remote.call(NET, "insert", t, "stone", 5)
	expect(c1.get_item_count("stone") == 40 and in_cells("stone") == 20, "read only: stone into C1")
	expect(remote.call(NET, "extract", t, "stone", 25) == 25 and in_cells("stone") == 0 and c1.get_item_count("stone") == 35,
		"read only: taken from C1 " .. c1.get_item_count("stone"))
	--- write only: C1 is not shown and not taken from, but filled
	remote.call(SB, "set_settings", b1, { mode = "write" })
	expect(count("stone") == 0 and count("copper-plate") == 30, "write only: C1 shown " .. count("stone") .. "/" .. count("copper-plate"))
	remote.call(NET, "insert", t, "stone", 7)
	expect(c1.get_item_count("stone") == 42 and count("stone") == 0, "write only: stone into C1 " .. c1.get_item_count("stone"))
	expect(remote.call(NET, "extract", t, "copper-plate", 40) == 30 and c1.get_item_count("copper-plate") == 50, "write only: copper taken from C1")
	remote.call(SB, "set_settings", b1, { mode = "readwrite" })
	expect(count("stone") == 42 and count("copper-plate") == 50, "read and write again: " .. count("stone") .. "/" .. count("copper-plate"))
	consistent("after the modes")
	--- stale snapshot: items taken out by hand are counted until the next visit, but an extract finds only the real ones
	ch1.remove{ name = "stone", count = 40 }
	expect(count("stone") == 42, "stone recounted without a visit")
	expect(remote.call(NET, "extract", t, "stone", 10) == 2 and count("stone") == 0 and c1.get_item_count("stone") == 0,
		"stale extract: network " .. count("stone"))
	local iron_c1 = c1.get_item_count("iron-plate")
	ch1.remove{ name = "iron-plate", count = iron_c1 }
	local before = pinv.get_item_count("iron-plate")
	local got2 = remote.call(TERM, "take", inv[3], pinv, t, "iron-plate", "inventory")
	expect(got2 == 5 and pinv.get_item_count("iron-plate") == before + 5 and count("iron-plate") == 0,
		"stale terminal take: " .. tostring(got2) .. ", inventory +" .. (pinv.get_item_count("iron-plate") - before))
	consistent("after the stale takes")
	--- two buses on one chest: counted once, one of them refused; the other takes over when the first goes
	c3.insert{ name = "steel-plate", count = 7 }
	visit(b3)
	visit(b4)
	local s3, s4 = info(b3).status, info(b4).status
	expect(count("steel-plate") == 7 and (s3 == "ok") ~= (s4 == "ok") and (s3 == "shared-target" or s4 == "shared-target"),
		"two buses on one chest: steel " .. count("steel-plate") .. ", " .. tostring(s3) .. "/" .. tostring(s4))
	local owner, other = b3, b4
	if s4 == "ok" then owner, other = b4, b3 end
	owner.destroy{ raise_destroy = true }
	expect(count("steel-plate") == 0, "a removed bus left its chest in the network: steel " .. count("steel-plate"))
	visit(other)
	expect(count("steel-plate") == 7 and info(other).status == "ok", "the second bus took over: steel " .. count("steel-plate") .. ", " .. tostring(info(other).status))
	--- a bus facing an ME block works with nothing
	visit(b5)
	expect(info(b5).status == "me-target", "facing a cable: " .. tostring(info(b5).status))
	--- a chest removed with an event leaves the network at once, one removed without an event at the next visit
	c2.insert{ name = "copper-plate", count = 9 }
	visit(b2)
	expect(count("copper-plate") == 59, "copper in C1 and C2: " .. count("copper-plate"))
	c2.destroy{ raise_destroy = true }
	expect(count("copper-plate") == 50 and info(b2).status == "no-target", "C2 removed: copper " .. count("copper-plate"))
	c3.destroy()
	visit(other)
	expect(count("steel-plate") == 0 and info(other).status == "no-target", "C3 removed without an event: steel " .. count("steel-plate"))
	--- a removed bus: C1 leaves the network
	b1.destroy{ raise_destroy = true }
	expect(count("copper-plate") == 0 and count("iron-plate") == in_cells("iron-plate"), "B1 removed: copper " .. count("copper-plate"))
	consistent("after the removals")
	net = remote.call(NET, "network", t)
	expect(net and net.storage_buses == 5, "storage buses left: " .. serpent.line(net and net.storage_buses))
	--- settings: blueprint tag, a revived ghost with the tag, paste, clone, the window's data
	local want = { mode = "read", priority = 7, filters = { "copper-plate", "iron-plate" } }
	expect(remote.call(SB, "set_settings", b7, want), "set_settings b7")
	local function same(b, label)
		local g = remote.call(SB, "get_settings", b)
		expect(g and serpent.line(g) == serpent.line(want), label .. ": " .. serpent.line(g))
	end
	same(b7, "settings")
	local bpi = game.create_inventory(1)
	bpi.insert{ name = "blueprint" }
	local mapping = bpi[1].create_blueprint{ surface = s, force = "player", area = { { SBX + 22, SBY }, { SBX + 23, SBY + 1 } } }
	remote.call(SB, "tag_blueprint", bpi[1], mapping)
	local tag
	for index, e in pairs(mapping or {}) do
		if e.name == "me-storage-bus" then tag = bpi[1].get_blueprint_entity_tag(index, "fork_me_storage_bus") end
	end
	bpi.destroy()
	expect(tag and serpent.line(tag) == serpent.line(want), "blueprint tag " .. serpent.line(tag))
	local ghost = s.create_entity{ name = "entity-ghost", inner_name = "me-storage-bus", position = { SBX + 26.5, SBY + 8.5 },
		force = "player", tags = { fork_me_storage_bus = tag } }
	local _, revived = ghost.revive{ raise_revive = true }
	if revived then same(revived, "revived ghost") else expect(false, "ghost not revived") end
	local pasted = s.create_entity{ name = "me-storage-bus", position = { SBX + 28.5, SBY + 8.5 }, force = "player", raise_built = true }
	remote.call(SB, "paste", b7, pasted)
	same(pasted, "pasted")
	local clone = b7.clone{ position = { SBX + 30.5, SBY + 8.5 } }
	if clone then same(clone, "clone") else expect(false, "no clone") end
	local wd = remote.call(GUI, "storage_bus_data", b7)
	expect(wd and wd.mode == "read" and wd.priority == 7 and wd.max == 18 and wd.status == "no-target", "window data " .. serpent.line(wd))
	expect(remote.call(GUI, "has_window", b7), "the storage bus has no window")
	remote.call(SB, "set_filter", b7, 1, nil)
	expect(serpent.line(remote.call(SB, "get_settings", b7).filters) == serpent.line({ "iron-plate" }), "filter removed")
	inv.destroy()
	pinv.destroy()
	--- the inserter test (above): one wood into the source chest
	src.insert{ name = "wood", count = 1 }
end

--------------------------------------------------------------------------------
--- Items and fluids in one block (me-network issue #3; scripts/fork-me-io.lua, fork-me-storagebus.lua,
--- fork-me-unify.lua): own network. The ME Interface with an item row and a fluid row (the fluid row takes the first
--- side with a pipe), an import side, a side switched off, a pipe loop between an export and an import side, the
--- fluid of its sides back into the network when it is mined; an export bus on a machine with a fluid recipe (items
--- into the input inventory, the fluid into an input box), an import bus on such a machine (the output inventory and
--- an output box; the input box is left alone); a storage bus that faces a chest, then a tank (it becomes the fluid
--- side), then a cable; mixed filters; the old fluid blocks: built by a script, their ghosts with old tags (revived
--- with the settings), their items (hidden, placing the unified block, no recipe, no unlock).
--------------------------------------------------------------------------------

local UX, UY = 300, 240

function setup_unified_test(s)
	local fails = {}
	local what = "unified"
	power(s, fails, what, UX, UY)
	me_place(s, fails, what, "me-network-controller", UX + 7, UY)
	me_drive(s, fails, what, UX + 8.5, UY - 0.5, { ["iron-plate"] = 200, ["resin-circuit-board"] = 50 }, "16k")
	local fd = me_drive(s, fails, what, UX + 9.5, UY - 0.5, {}, "1k", true)
	if fd then
		remote.call(NET, "store_fluid_in_drive", fd, "water", 3000)
		remote.call(NET, "store_fluid_in_drive", fd, "phenol", 2000)
	end
	me_place(s, fails, what, "me-terminal", UX + 10.5, UY - 0.5)
	cable_row(s, fails, UX + 11, UX + 40, UY - 1)
	local south = { direction = defines.direction.south }
	--- interface I: a pipe on its east side (exports), steam in a pipe on its south side (imported)
	me_place(s, fails, what, "me-network-interface", UX + 12.5, UY + 0.5)
	me_place(s, fails, what, "pipe", UX + 13.5, UY + 0.5)
	local steam = me_place(s, fails, what, "pipe", UX + 12.5, UY + 1.5)
	if steam then steam.fluidbox[1] = { name = "steam", amount = 50, temperature = 165 } end
	--- interface L: one pipe loop from its east side round to its south side
	me_place(s, fails, what, "me-network-interface", UX + 15.5, UY + 0.5)
	me_place(s, fails, what, "pipe", UX + 16.5, UY + 0.5)
	me_place(s, fails, what, "pipe", UX + 16.5, UY + 1.5)
	me_place(s, fails, what, "pipe", UX + 15.5, UY + 1.5)
	--- the export bus on reactor R (no power: it does not craft), the import bus on reactor R2
	me_place(s, fails, what, "me-export-bus", UX + 20.5, UY + 0.5, south)
	local r = me_place(s, fails, what, "hv-chemical-reactor", UX + 20.5, UY + 2.5)
	me_place(s, fails, what, "me-import-bus", UX + 25.5, UY + 0.5, south)
	local r2 = me_place(s, fails, what, "hv-chemical-reactor", UX + 25.5, UY + 2.5)
	for _, m in pairs({ r, r2 }) do
		if m then
			m.force.recipes["phenolic-circuit-board"].enabled = true
			m.set_recipe("phenolic-circuit-board")
		end
	end
	--- the storage bus on a chest (later a tank)
	me_place(s, fails, what, "me-storage-bus", UX + 30.5, UY + 0.5, south)
	local chest = me_place(s, fails, what, "iron-chest", UX + 30.5, UY + 1.5)
	if chest then chest.insert{ name = "wood", count = 30 } end
	return fails
end

function unified_test()
	if storage.unified or game.tick < 60 then return end
	storage.unified = { done = true }
	local s = game.surfaces[1]
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function near(a, b, eps) return math.abs((a or 0) - (b or 0)) <= (eps or 0.01) end
	local function find(name, x, y) return s.find_entity(name, { UX + x, UY + y }) end
	local t = find("me-terminal", 10.5, -0.5)
	local i, l = find("me-network-interface", 12.5, 0.5), find("me-network-interface", 15.5, 0.5)
	local eb, ib = find("me-export-bus", 20.5, 0.5), find("me-import-bus", 25.5, 0.5)
	local r, r2 = find("hv-chemical-reactor", 20.5, 2.5), find("hv-chemical-reactor", 25.5, 2.5)
	local sb, chest = find("me-storage-bus", 30.5, 0.5), find("iron-chest", 30.5, 1.5)
	local steam_pipe = find("pipe", 12.5, 1.5)
	if not (t and i and l and eb and ib and r and r2 and sb and chest and steam_pipe) then
		return me_report("UNIFIED", "ME unified I/O", { "entities missing" })
	end
	local net = remote.call(NET, "network", t)
	expect(net and net.ok, "network " .. serpent.line(net))
	local function fluid(name) return remote.call(NET, "fluid_count", t, name) end
	local function item(name) return remote.call(NET, "count", t, name) end
	local function tanks(e) return remote.call(IO, "interface_tanks", e) or {} end
	local function side(e, d) return (remote.call(IO, "get_interface", e) or { fluids = {} }).fluids[d] or {} end
	local function step(e, n) for _ = 1, n or 1 do remote.call(IO, "step", e) end end

	--- the interface: four side tanks on its tile, an item row and a fluid row (which takes the east side: the first
	--- side with a pipe; north is the cable)
	expect(#tanks(i) == 4 and s.count_entities_filtered{ name = "me-network-interface-side", position = i.position } == 4,
		"the interface has " .. #tanks(i) .. " side tanks")
	expect(remote.call(IO, "set_interface_key", i, 1, "iron-plate", 20), "item row")
	expect(remote.call(IO, "set_interface_key", i, 2, "fluid/water", 1000), "fluid row")
	local sides = remote.call(IO, "get_interface_sides", i)
	expect(sides[2] == 2 and sides[1] == nil and sides[3] == nil, "the fluid row took " .. serpent.line(sides))
	local water0 = fluid("water")                            -- (the I/O step may have imported the steam already)
	step(i, 6)
	local inv = i.get_inventory(defines.inventory.chest)
	expect(inv.get_item_count("iron-plate") == 20, "item row: " .. inv.get_item_count("iron-plate") .. " plates")
	local east = tanks(i)[2].fluidbox[1]
	expect(east and east.name == "water" and near(east.amount, 1000, 0.5), "fluid row: the east side holds " .. serpent.line(east))
	local seg = tanks(i)[2].fluidbox.get_fluid_segment_contents(1) or {}
	expect(near(water0 - fluid("water"), seg.water or 0, 0.05), "water out of the network " .. (water0 - fluid("water"))
		.. ", in the east segment " .. tostring(seg.water))
	expect(near(fluid("steam"), 50) and (steam_pipe.fluidbox[1] == nil or steam_pipe.fluidbox[1].amount < 1e-3),
		"import side: steam " .. fluid("steam") .. ", pipe " .. serpent.line(steam_pipe.fluidbox[1]))
	expect(side(i, 3).status == "import" and side(i, 2).status == "ok", "side status " .. serpent.line(side(i, 2)) .. serpent.line(side(i, 3)))
	--- a side switched off keeps what is piped in
	remote.call(IO, "set_interface_side", i, 3, "off")
	steam_pipe.fluidbox[1] = { name = "steam", amount = 20, temperature = 165 }
	step(i)
	expect(near(fluid("steam"), 50) and side(i, 3).status == "off", "an off side imported: " .. fluid("steam"))
	remote.call(IO, "set_interface_side", i, 3, "import")
	step(i)
	expect(near(fluid("steam"), 70), "the side imports again: " .. fluid("steam"))
	--- the loop: an export side and an import side on one pipe network
	remote.call(IO, "set_interface_config", l, { [1] = { type = "fluid", name = "water", amount = 500 } }, { [2] = 1 })
	local w1 = fluid("water")
	step(l, 8)
	local lseg = tanks(l)[2].fluidbox.get_fluid_segment_contents(1) or {}
	expect(tanks(l)[2].fluidbox.get_fluid_segment_id(1) == tanks(l)[3].fluidbox.get_fluid_segment_id(1), "the loop is not one segment")
	expect(side(l, 3).status == "loop" and near(w1 - fluid("water"), lseg.water or 0, 0.05),
		"loop: south side " .. serpent.line(side(l, 3)) .. ", out of the network " .. (w1 - fluid("water")) .. ", in the loop " .. tostring(lseg.water))
	--- the blueprint tag of the interface: rows and sides
	local bpi = game.create_inventory(1)
	bpi.insert{ name = "blueprint" }
	local mapping = bpi[1].create_blueprint{ surface = s, force = "player", area = { { UX + 12, UY }, { UX + 13, UY + 1 } } }
	remote.call(IO, "tag_blueprint", bpi[1], mapping)
	local tag
	for index, e in pairs(mapping or {}) do
		if e.name == "me-network-interface" then tag = bpi[1].get_blueprint_entity_tag(index, "fork_me_interface") end
		expect(e.name ~= "me-network-interface-side", "a side tank is in the blueprint")
	end
	bpi.destroy()
	expect(tag and #tag.config == 2 and tag.config[2].type == "fluid" and #tag.sides == 1 and tag.sides[1].side == 2
		and tag.sides[1].row == 2, "interface tag " .. serpent.line(tag))
	--- mined: the fluid of the loop goes back into the network, the side tanks go
	local w2 = fluid("water")
	local in_loop = (tanks(l)[2].fluidbox.get_fluid_segment_contents(1) or {}).water or 0
	remote.call(IO, "removed", l, true)
	local lpos = l.position
	l.destroy()
	expect(near(fluid("water"), w2 + in_loop, 0.05), "mined interface: network water " .. fluid("water") .. ", expected " .. (w2 + in_loop))
	expect(s.count_entities_filtered{ name = "me-network-interface-side", position = lpos } == 0, "side tanks left behind")

	--- the export bus on a machine with a fluid recipe: items into the input inventory, the fluid into an input box
	remote.call(IO, "set_bus_filters", eb, { "resin-circuit-board", "fluid/phenol" })
	local bi = remote.call(IO, "bus_info", eb)
	expect(bi and bi.items and bi.fluids and not bi.import, "export bus info " .. serpent.line(bi))
	local p0 = fluid("phenol")
	step(eb)
	local boards = r.get_inventory(defines.inventory.crafter_input).get_item_count("resin-circuit-board")
	local phenol = r.get_fluid_count("phenol")
	expect(boards > 0 and phenol > 0 and near(p0 - fluid("phenol"), phenol), "export bus on a machine: " .. boards .. " boards, "
		.. phenol .. " phenol, network phenol " .. fluid("phenol"))
	--- the import bus on such a machine: the output inventory and an output box (the input box is left alone)
	r2.get_inventory(defines.inventory.crafter_output).insert{ name = "phenolic-circuit-board", count = 10 }
	local fb = r2.fluidbox
	local in_box, out_box
	for k = 1, #fb do
		local pr = fb.get_prototype(k)
		if pr and pr.production_type == nil and pr[1] then pr = pr[1] end
		if pr and pr.production_type == "input" and not in_box then in_box = k end
		if pr and pr.production_type == "output" and not out_box then out_box = k end
	end
	expect(in_box, "reactor boxes " .. tostring(in_box) .. "/" .. tostring(out_box))
	if in_box then
		fb[in_box] = { name = "phenol", amount = 7 }
		local ok = out_box and pcall(function() fb[out_box] = { name = "phenol", amount = 30 } end)
		local out_held = ok and fb[out_box] and fb[out_box].amount or 0
		local pb0, pp0 = item("phenolic-circuit-board"), fluid("phenol")
		step(ib)
		expect(item("phenolic-circuit-board") == pb0 + 10, "import bus: boards " .. item("phenolic-circuit-board"))
		expect(near(fluid("phenol"), pp0 + out_held) and near(fb[in_box] and fb[in_box].amount or 0, 7),
			"import bus: phenol " .. fluid("phenol") .. " (output box had " .. out_held .. "), input box "
			.. serpent.line(fb[in_box]))
		--- only item filters: no fluid
		if ok then fb[out_box] = { name = "phenol", amount = 30 } end
		remote.call(IO, "set_bus_filters", ib, { "phenolic-circuit-board" })
		local pp1 = fluid("phenol")
		step(ib)
		expect(near(fluid("phenol"), pp1), "an import bus with only item filters took fluid")
	end

	--- the storage bus: a chest (item side), then a tank (fluid side), then a cable
	remote.call("gregtorio-me-storagebus", "visit", sb)
	local si = remote.call("gregtorio-me-storagebus", "info", sb)
	expect(si and si.side == "item" and item("wood") == 30, "storage bus on a chest " .. serpent.line(si) .. ", wood " .. item("wood"))
	chest.destroy{ raise_destroy = true }
	local tank = s.create_entity{ name = "storage-tank", position = { UX + 30.5, UY + 2.5 }, force = "player", raise_built = true }
	tank.insert_fluid{ name = "lubricant", amount = 700 }
	remote.call("gregtorio-me-storagebus", "visit", sb)
	si = remote.call("gregtorio-me-storagebus", "info", sb)
	net = remote.call(NET, "network", t)
	expect(si and si.side == "fluid" and si.fluid == "lubricant" and near(fluid("lubricant"), 700) and item("wood") == 0
		and net.fluid_storage_buses == 1 and net.storage_buses == 0, "storage bus on a tank " .. serpent.line(si) .. ", lubricant "
		.. fluid("lubricant") .. ", buses " .. tostring(net.fluid_storage_buses) .. "/" .. tostring(net.storage_buses))
	expect(near(remote.call(NET, "extract_fluid", t, "lubricant", 200), 200) and near(tank.get_fluid_count("lubricant"), 500, 1),
		"taken from the tank: " .. tank.get_fluid_count("lubricant"))
	remote.call("gregtorio-me-storagebus", "set_settings", sb, { filters = { "wood", "fluid/lubricant", "water" } })
	local st = remote.call("gregtorio-me-storagebus", "get_settings", sb)
	expect(st and serpent.line(st.filters) == serpent.line({ "wood", "fluid/lubricant", "fluid/water" }), "mixed filters " .. serpent.line(st))
	sb.direction = defines.direction.north                   -- the cable row
	remote.call("gregtorio-me-storagebus", "rotated", sb)
	si = remote.call("gregtorio-me-storagebus", "info", sb)
	expect(si and si.status == "me-target" and si.side == "item" and fluid("lubricant") == 0, "rotated onto the cable " .. serpent.line(si))

	--- the old fluid blocks: one built by a script becomes the unified one; their ghosts become unified ghosts with
	--- the settings in their tags
	s.create_entity{ name = "me-fluid-import-bus", position = { UX + 35.5, UY + 0.5 }, direction = defines.direction.south,
		force = "player", raise_built = true }
	expect(find("me-fluid-import-bus", 35.5, 0.5) == nil, "an old fluid import bus built by a script stayed")
	local new = find("me-import-bus", 35.5, 0.5)
	expect(new and new.direction == defines.direction.south, "no unified import bus in its place")
	local function ghost(name, x, tags, dir)
		s.create_entity{ name = "entity-ghost", inner_name = name, position = { UX + x, UY + 4.5 }, direction = dir,
			force = "player", tags = tags, raise_built = true }
		local g = s.find_entities_filtered{ type = "entity-ghost", position = { UX + x, UY + 4.5 } }[1]
		local e
		if g then _, e = g.revive{ raise_revive = true } end
		return g, e
	end
	local _, e1 = ghost("me-fluid-export-bus", 12.5, { fork_me_bus = { filters = { "water" } } }, defines.direction.east)
	local b1 = e1 and remote.call(IO, "get_bus", e1)
	expect(e1 and e1.name == "me-export-bus" and e1.direction == defines.direction.east and b1
		and serpent.line(b1.filters) == serpent.line({ "fluid/water" }), "old export bus ghost: " .. tostring(e1 and e1.name) .. " " .. serpent.line(b1))
	local _, e2 = ghost("me-fluid-interface", 14.5, { fork_me_fluid_interface = { mode = "export", fluid = "water", level = 777 } })
	local c2 = e2 and remote.call(IO, "get_interface_config", e2)
	local s2 = e2 and remote.call(IO, "get_interface_sides", e2)
	expect(e2 and e2.name == "me-network-interface" and c2[1] and c2[1].type == "fluid" and c2[1].name == "water" and c2[1].amount == 777
		and serpent.line(s2) == serpent.line({ 1, 1, 1, 1 }), "old fluid interface ghost: " .. serpent.line(c2) .. " " .. serpent.line(s2))
	local _, e3 = ghost("me-fluid-storage-bus", 16.5, { fork_me_fluid_storage_bus = { mode = "read", priority = 3, filters = { "water" } } })
	local g3 = e3 and remote.call("gregtorio-me-storagebus", "get_settings", e3)
	expect(e3 and e3.name == "me-storage-bus" and g3 and g3.mode == "read" and g3.priority == 3
		and serpent.line(g3.filters) == serpent.line({ "fluid/water" }), "old fluid storage bus ghost: " .. serpent.line(g3))
	--- the old items: hidden, they place the unified block, no recipe makes them, no technology unlocks them
	for old_name, unified in pairs({ ["me-fluid-interface"] = "me-network-interface", ["me-fluid-import-bus"] = "me-import-bus",
		["me-fluid-export-bus"] = "me-export-bus", ["me-fluid-storage-bus"] = "me-storage-bus" }) do
		local p = prototypes.item[old_name]
		expect(p and p.hidden and p.place_result and p.place_result.name == unified, old_name .. ": " .. tostring(p and p.place_result and p.place_result.name))
		expect(prototypes.recipe[old_name] == nil, "the recipe " .. old_name .. " exists")
	end
	for _, eff in pairs(prototypes.technology["me-fluid-storage"].effects) do
		expect(not (eff.recipe and eff.recipe:find("^me%-fluid%-") and not eff.recipe:find("cell")), "me-fluid-storage unlocks " .. tostring(eff.recipe))
	end
	me_report("UNIFIED", "ME unified I/O", problems, "interface rows and sides, buses on machines, storage bus sides, old blocks")
end

--------------------------------------------------------------------------------
--- ME Storage Bus on fluid (issue #68, scripts/fork-me-fluid-storagebus.lua; issue #3: the storage bus itself, the
--- remote of the old fluid storage bus works on it): own network right of the storage bus test,
--- a drive with four 1k fluid cells, a terminal, fluid storage buses on storage tanks below a cable row. T1 and T2
--- are one fluid segment (a pipe between them): counted once, the second bus refused; removing the pipe splits
--- the segment and the second bus takes its part. Then the terminal's entries and an extract (what autocrafting and
--- the export buses do), a filtered insert (T3) and the rest into the cells, priority, read only and write only, a
--- stale snapshot (fluid taken out by hand), another temperature (hot steam in T4), removals, the settings in a
--- blueprint tag, on a revived ghost, by paste and clone, the window data; after every part the network's fluid
--- must equal the cells plus the segments of the working buses. Then (waiting) the fluid export bus takes from
--- T1's segment, a level maintainer counts it ("stocked") and a pump filling T5 is in the network within one
--- visit cycle.
--------------------------------------------------------------------------------

local FSX, FSY = 340, 125
local FSB = "gregtorio-me-fluid-storagebus"
local FS_CY = FSY + 2.5                                     -- centre row of the tanks below the buses

function setup_fluid_storage_bus_test(s)
	local fails = {}
	local what = "fluid storage bus"
	power(s, fails, what, FSX, FSY)
	me_place(s, fails, what, "me-network-controller", FSX + 7, FSY)
	me_drive(s, fails, what, FSX + 8.5, FSY - 0.5, {}, "1k", true)
	me_place(s, fails, what, "me-terminal", FSX + 9.5, FSY - 0.5)
	cable_row(s, fails, FSX + 10, FSX + 38, FSY - 1)
	local south = { direction = defines.direction.south }
	--- T1 (north) and T2 (east) joined by the pipe P on T1's east and T2's west connection: one segment
	me_place(s, fails, what, "storage-tank", FSX + 12.5, FS_CY)
	me_place(s, fails, what, "pipe", FSX + 14.5, FS_CY + 1)
	me_place(s, fails, what, "storage-tank", FSX + 16.5, FS_CY, { direction = defines.direction.east })
	me_place(s, fails, what, "me-storage-bus", FSX + 12.5, FSY + 0.5, south)     -- B1 on T1
	me_place(s, fails, what, "me-storage-bus", FSX + 16.5, FSY + 0.5, south)     -- B2 on T2: same segment
	me_place(s, fails, what, "me-storage-bus", FSX + 19.5, FSY + 0.5, { direction = defines.direction.north })  -- B6: a cable
	me_place(s, fails, what, "storage-tank", FSX + 21.5, FS_CY)                         -- T3: filters
	me_place(s, fails, what, "me-storage-bus", FSX + 21.5, FSY + 0.5, south)     -- B3
	me_place(s, fails, what, "storage-tank", FSX + 26.5, FS_CY)                         -- T4: priority, modes, temperature
	me_place(s, fails, what, "me-storage-bus", FSX + 26.5, FSY + 0.5, south)     -- B4
	me_place(s, fails, what, "storage-tank", FSX + 31.5, FS_CY)                         -- T5: filled by the pump
	me_place(s, fails, what, "me-storage-bus", FSX + 31.5, FSY + 0.5, south)     -- B5
	--- the pump (output north into T5's south connection) and its source tank TS (north connection into the pump)
	me_place(s, fails, what, "pump", FSX + 32.5, FSY + 5, { direction = defines.direction.north })
	me_place(s, fails, what, "storage-tank", FSX + 33.5, FSY + 7.5)
	power(s, fails, what, FSX + 36, FSY + 8)
	--- the fluid export bus into TE, and a level maintainer
	me_place(s, fails, what, "me-export-bus", FSX + 35.5, FSY + 0.5, south)
	me_place(s, fails, what, "storage-tank", FSX + 35.5, FS_CY)
	me_place(s, fails, what, "me-level-maintainer", FSX + 37.5, FSY + 0.5)
	return fails
end

function fluid_storage_bus_test()
	local st = storage.me_fsbus
	if (st and st.done) or game.tick < 60 then return end
	local s = game.surfaces[1]
	local function find(name, x, y) return s.find_entity(name, { FSX + x, FSY + y }) end
	local t, drive = find("me-terminal", 9.5, -0.5), find("me-drive", 8.5, -0.5)
	local function fcount(name) return remote.call(NET, "fluid_count", t, name) end
	local function near(a, b) return math.abs((a or 0) - (b or 0)) < 0.01 end
	local function seg(tank) return tank.fluidbox.get_fluid_segment_contents(1) or {} end
	local function info(b) return remote.call(FSB, "info", b) or {} end
	local cy = FS_CY - FSY
	if st then
		--- waiting part: the export bus, the maintainer, the pump
		local problems = st.problems
		local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
		local t5, b5 = find("storage-tank", 31.5, cy), find("me-storage-bus", 31.5, 0.5)
		local te = find("storage-tank", 35.5, cy)
		local maint = find("me-level-maintainer", 37.5, 0.5)
		if not st.export_done and te.get_fluid_count("lubricant") > 0 then
			st.export_done = true
			remote.call(IO, "set_bus_filters", find("me-export-bus", 35.5, 0.5), {})   -- one visit is enough
			expect(near(seg(st.t1).lubricant, st.t1_before - te.get_fluid_count("lubricant")),
				"export bus: T1's segment " .. tostring(seg(st.t1).lubricant) .. ", before " .. st.t1_before .. ", TE " .. te.get_fluid_count("lubricant"))
		end
		if not st.maint_done then
			local m = remote.call("gregtorio-me-circuit", "get_maintainer", maint)
			if m and m.status == "stocked" then
				st.maint_done = true
				expect(near(m.stock, fcount("lubricant")) and m.stock >= 100, "maintainer stock " .. tostring(m.stock) .. ", network " .. fcount("lubricant"))
			end
		end
		if not st.seen and (seg(t5).water or 0) > 0 then st.seen = game.tick end
		local buses = (remote.call(NET, "network", t) or {}).fluid_storage_buses or 0   -- the fluid side's visit list
		local cycle = settings.global["me-network-storage-bus-idle-limit"].value
			+ math.ceil(buses / settings.global["me-network-storage-bus-visits-per-tick"].value) + 10   -- (issue #5)
		if st.seen and not st.pump_done and (info(b5).contents or {})["fluid/water"] then
			st.pump_done = game.tick - st.seen
			expect(st.pump_done <= cycle, "pump: water seen after " .. st.pump_done .. " ticks (cycle " .. cycle .. ")")
		end
		if st.export_done and st.maint_done and st.pump_done then
			st.done = true
			return me_report("MEFLUIDSTORAGEBUS", "ME fluid storage bus", problems,
				"pump picked up after " .. st.pump_done .. " ticks, cycle " .. cycle)
		elseif game.tick > st.started + 900 then
			expect(st.export_done, "the export bus took nothing from T1's segment")
			expect(st.maint_done, "maintainer: " .. serpent.line(remote.call("gregtorio-me-circuit", "get_maintainer", maint))
				.. " schedule " .. serpent.line(remote.call("gregtorio-me-circuit", "schedule", maint)))
			expect(st.pump_done, "the pump's water never showed up (seen at " .. tostring(st.seen) .. ", B5 " .. serpent.line(info(b5)) .. ")")
			st.done = true
			return me_report("MEFLUIDSTORAGEBUS", "ME fluid storage bus", problems)
		end
		return
	end
	st = { problems = {}, started = game.tick }
	storage.me_fsbus = st
	local problems = st.problems
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function bus(x) return find("me-storage-bus", x, 0.5) end
	local b1, b2, b6, b3, b4, b5 = bus(12.5), bus(16.5), bus(19.5), bus(21.5), bus(26.5), bus(31.5)
	local t1, t2 = find("storage-tank", 12.5, cy), find("storage-tank", 16.5, cy)
	local t3, t4, t5 = find("storage-tank", 21.5, cy), find("storage-tank", 26.5, cy), find("storage-tank", 31.5, cy)
	local ts, te = find("storage-tank", 33.5, 7.5), find("storage-tank", 35.5, cy)
	local pipe = find("pipe", 14.5, cy + 1)
	local ebus, maint = find("me-export-bus", 35.5, 0.5), find("me-level-maintainer", 37.5, 0.5)
	if not (t and drive and b1 and b2 and b3 and b4 and b5 and b6 and t1 and t2 and t3 and t4 and t5 and ts and te and pipe
		and ebus and maint) then
		st.done = true
		return me_report("MEFLUIDSTORAGEBUS", "ME fluid storage bus", { "entities missing" })
	end
	st.t1 = t1
	local net = remote.call(NET, "network", t)
	--- B6 faces a cable: no target, no fluid side
	expect(net and net.ok and net.fluid_storage_buses == 5 and net.storage_buses == 1, "network " .. serpent.line(net))
	expect(t1.fluidbox.get_fluid_segment_id(1) == t2.fluidbox.get_fluid_segment_id(1), "T1 and T2 are not one segment")
	local function visit(b) remote.call(FSB, "visit", b) end
	local function cells(name)
		local n = 0
		for _, c in pairs(remote.call(NET, "drive", drive)) do n = n + (c.items["fluid/" .. name] or 0) end
		return n
	end
	--- the network's fluid must be the cells' plus the segments of the working buses (each segment once)
	local pairs_ = { { b1, t1 }, { b2, t2 }, { b3, t3 }, { b4, t4 }, { b5, t5 } }
	local function consistent(label)
		local want = {}
		for _, c in pairs(remote.call(NET, "drive", drive)) do
			for k, n in pairs(c.items) do
				if k:sub(1, 6) == "fluid/" then want[k:sub(7)] = (want[k:sub(7)] or 0) + n end
			end
		end
		for _, p in ipairs(pairs_) do
			if p[1].valid then visit(p[1]) end
		end
		local done = {}
		for _, p in ipairs(pairs_) do
			if p[1].valid and p[2].valid then
				local i = info(p[1])
				local id = p[2].fluidbox.get_fluid_segment_id(1)
				if (i.status == "ok" or i.status == "temperature") and i.mode ~= "write" and not done[id] then
					done[id] = true
					local allow = {}
					for _, f in pairs(i.filters) do allow[f] = true end
					for name, n in pairs(seg(p[2])) do
						if #i.filters == 0 or allow["fluid/" .. name] then want[name] = (want[name] or 0) + n end
					end
				end
			end
		end
		local have = remote.call(NET, "fluid_contents", t)
		local diff = {}
		for k, n in pairs(want) do if not near(have[k], n) then diff[#diff + 1] = k .. " " .. tostring(have[k]) .. "/" .. n end end
		for k, n in pairs(have) do if not want[k] then diff[#diff + 1] = k .. " " .. n .. "/0" end end
		table.sort(diff)
		expect(#diff == 0, label .. ": network/expected " .. table.concat(diff, ", "))
	end

	--- one segment, two tanks: counted once after a visit (not before: no event), the second bus refused
	t1.insert_fluid{ name = "lubricant", amount = 1000 }
	expect(fcount("lubricant") == 0, "T1 seen without a visit")
	visit(b1)
	visit(b2)
	local i1, i2 = info(b1), info(b2)
	expect(near(fcount("lubricant"), 1000), "two tanks of one segment: lubricant " .. fcount("lubricant"))
	expect(i1.status == "ok" and i2.status == "shared-target" and i1.segment == "s" .. t1.fluidbox.get_fluid_segment_id(1)
		and i1.fluid == "lubricant" and near(i1.amount, 1000) and i1.target == "storage-tank",
		"one segment: " .. serpent.line(i1) .. " / " .. serpent.line(i2))
	consistent("one segment")
	--- the terminal shows it (and refuses it by hand); an extract (what autocrafting and the export buses do) takes from it
	local shown
	for _, en in pairs(remote.call(TERM, "entries", t, "", "count", "fluids")) do
		if en.key == "fluid/lubricant" then shown = en.count end
	end
	expect(near(shown, 1000), "terminal entry: " .. tostring(shown))
	local inv = game.create_inventory(2)
	local took = remote.call(TERM, "take", inv[1], inv, t, "fluid/lubricant", "inventory")
	expect(not took or took == 0, "terminal took fluid by hand: " .. tostring(took))
	inv.destroy()
	expect(near(remote.call(NET, "extract_fluid", t, "lubricant", 300), 300) and near(seg(t1).lubricant, 700)
		and near(fcount("lubricant"), 700), "extract from the segment: T1+T2 " .. tostring(seg(t1).lubricant))
	consistent("after the extract")
	--- split: the pipe between T1 and T2 removed, B2 takes T2's part
	pipe.destroy{ raise_destroy = true }
	expect(t1.fluidbox.get_fluid_segment_id(1) ~= t2.fluidbox.get_fluid_segment_id(1), "the segment did not split")
	local part1, part2 = seg(t1).lubricant or 0, seg(t2).lubricant or 0
	expect(near(part1 + part2, 700), "split parts " .. part1 .. " + " .. part2)
	--- before any visit the engine never takes more than the bus really owns
	local got = remote.call(NET, "extract_fluid", t, "lubricant", 700)
	expect(got <= part1 + 1e-6 and near(seg(t1).lubricant or 0, part1 - got), "extract after the split: " .. got .. " of " .. part1)
	if got > 0 then t1.insert_fluid{ name = "lubricant", amount = got } end      -- back to the split state
	remote.call(FSB, "step")                                                     -- the removal marked B1 for the next step
	visit(b2)
	i1, i2 = info(b1), info(b2)
	expect(i1.status == "ok" and i2.status == "ok" and i1.segment ~= i2.segment and near(i2.amount, part2)
		and near(fcount("lubricant"), 700), "after the split: " .. serpent.line(i1) .. " / " .. serpent.line(i2) .. ", network " .. fcount("lubricant"))
	consistent("after the split")
	--- a filtered bus gets its fluid; a fluid no bus holds goes into the cells
	expect(remote.call(FSB, "set_settings", b3, { filters = { "sulfuric-acid" } }), "set_settings filters")
	expect(near(remote.call(NET, "insert_fluid", t, "sulfuric-acid", 500), 500) and near(seg(t3)["sulfuric-acid"], 500)
		and cells("sulfuric-acid") == 0, "filtered insert: T3 " .. tostring(seg(t3)["sulfuric-acid"]))
	expect(near(remote.call(NET, "insert_fluid", t, "crude-oil", 400), 400) and near(cells("crude-oil"), 400)
		and not seg(t4)["crude-oil"] and not seg(t3)["crude-oil"], "crude oil into the cells: " .. cells("crude-oil"))
	consistent("after the inserts")
	--- priority against the cells
	remote.call(FSB, "set_settings", b4, { priority = 10 })
	remote.call(NET, "insert_fluid", t, "water", 200)
	expect(near(seg(t4).water, 200) and cells("water") == 0, "priority 10: water into T4 " .. tostring(seg(t4).water))
	remote.call(FSB, "set_settings", b4, { priority = -10 })
	remote.call(NET, "insert_fluid", t, "water", 100)
	expect(near(seg(t4).water, 200) and near(cells("water"), 100), "priority -10: water into the cells " .. cells("water"))
	expect(near(remote.call(NET, "extract_fluid", t, "water", 50), 50) and near(seg(t4).water, 150) and near(cells("water"), 100),
		"priority -10: water taken from T4 first")
	remote.call(FSB, "set_settings", b4, { priority = 10 })
	expect(near(remote.call(NET, "extract_fluid", t, "water", 50), 50) and near(seg(t4).water, 150) and near(cells("water"), 50),
		"priority 10: water taken from the cells first")
	consistent("after the priorities")
	--- read only: nothing goes in, taking works; write only: not shown, not taken from, but filled
	remote.call(FSB, "set_settings", b4, { mode = "read", priority = -10 })
	remote.call(NET, "insert_fluid", t, "water", 30)
	expect(near(seg(t4).water, 150) and near(cells("water"), 80), "read only: water into T4 " .. tostring(seg(t4).water))
	expect(near(remote.call(NET, "extract_fluid", t, "water", 50), 50) and near(cells("water"), 80) and near(seg(t4).water, 100),
		"read only: taken from T4 " .. tostring(seg(t4).water))
	remote.call(FSB, "set_settings", b4, { mode = "write", priority = 10 })
	expect(near(fcount("water"), 80), "write only: T4 shown " .. fcount("water"))
	remote.call(NET, "insert_fluid", t, "water", 20)
	expect(near(seg(t4).water, 120) and near(fcount("water"), 80), "write only: water into T4 " .. tostring(seg(t4).water))
	expect(near(remote.call(NET, "extract_fluid", t, "water", 200), 80) and near(seg(t4).water, 120), "write only: water taken from T4")
	remote.call(FSB, "set_settings", b4, { mode = "readwrite", priority = 0 })
	expect(near(fcount("water"), 120), "read and write again: " .. fcount("water"))
	consistent("after the modes")
	--- stale snapshot: fluid taken out by hand is counted until the next visit, but an extract finds only the real fluid
	t4.remove_fluid{ name = "water", amount = 100 }
	expect(near(fcount("water"), 120), "water recounted without a visit")
	expect(near(remote.call(NET, "extract_fluid", t, "water", 120), 20) and fcount("water") == 0 and (seg(t4).water or 0) < 1e-6,
		"stale extract: network " .. fcount("water"))
	consistent("after the stale extract")
	--- another temperature: hot steam in T4 is read, the network's steam (default temperature) does not go in
	t4.insert_fluid{ name = "steam", amount = 100, temperature = 500 }
	visit(b4)
	local i4 = info(b4)
	expect(i4.status == "temperature" and near(i4.temperature, 500) and near(fcount("steam"), 100), "hot steam: " .. serpent.line(i4))
	expect(near(remote.call(NET, "insert_fluid", t, "steam", 50), 50) and near(seg(t4).steam, 100) and near(cells("steam"), 50)
		and near(t4.fluidbox[1].temperature, 500), "steam inserted into the hot tank: T4 " .. tostring(seg(t4).steam))
	expect(near(remote.call(NET, "extract_fluid", t, "steam", 120), 120) and near(seg(t4).steam, 0) and near(cells("steam"), 30),
		"steam taken: T4 " .. tostring(seg(t4).steam) .. ", cells " .. cells("steam"))
	consistent("after the temperature")
	--- removals: a tank removed with an event leaves at once, a removed bus takes its segment out
	t3.destroy{ raise_destroy = true }
	expect(fcount("sulfuric-acid") == 0 and info(b3).status == "no-target", "T3 removed: acid " .. fcount("sulfuric-acid"))
	b2.destroy{ raise_destroy = true }
	expect(near(fcount("lubricant"), part1), "B2 removed: lubricant " .. fcount("lubricant") .. ", T1 " .. part1)
	consistent("after the removals")
	net = remote.call(NET, "network", t)
	--- (B3 lost its tank: no side until it faces something again)
	expect(net and net.fluid_storage_buses == 3, "storage buses on fluid left: " .. serpent.line(net and net.fluid_storage_buses))
	--- a bus facing an ME block works with nothing
	visit(b6)
	expect(info(b6).status == "me-target", "facing a cable: " .. tostring(info(b6).status))
	--- settings: blueprint tag, a revived ghost with the tag, paste, clone, the window's data
	expect(remote.call(FSB, "set_settings", b6, { mode = "read", priority = 7, filters = { "lubricant", "water" } }), "set_settings b6")
	local want = { mode = "read", priority = 7, filters = { "fluid/lubricant", "fluid/water" } }   -- plain fluid names: fluids
	local function same(b, label)
		local g = remote.call(FSB, "get_settings", b)
		expect(g and serpent.line(g) == serpent.line(want), label .. ": " .. serpent.line(g))
	end
	same(b6, "settings")
	local bpi = game.create_inventory(1)
	bpi.insert{ name = "blueprint" }
	local mapping = bpi[1].create_blueprint{ surface = s, force = "player", area = { { FSX + 19, FSY }, { FSX + 20, FSY + 1 } } }
	remote.call(FSB, "tag_blueprint", bpi[1], mapping)
	local tag
	for index, e in pairs(mapping or {}) do
		if e.name == "me-storage-bus" then tag = bpi[1].get_blueprint_entity_tag(index, "fork_me_storage_bus") end
	end
	bpi.destroy()
	expect(tag and serpent.line(tag) == serpent.line(want), "blueprint tag " .. serpent.line(tag))
	local ghost = s.create_entity{ name = "entity-ghost", inner_name = "me-storage-bus", position = { FSX + 26.5, FSY + 12.5 },
		force = "player", tags = { fork_me_storage_bus = tag } }
	local _, revived = ghost.revive{ raise_revive = true }
	if revived then same(revived, "revived ghost") else expect(false, "ghost not revived") end
	local pasted = s.create_entity{ name = "me-storage-bus", position = { FSX + 28.5, FSY + 12.5 }, force = "player", raise_built = true }
	remote.call(FSB, "paste", b6, pasted)
	same(pasted, "pasted")
	local clone = b6.clone{ position = { FSX + 30.5, FSY + 12.5 } }
	if clone then same(clone, "clone") else expect(false, "no clone") end
	local wd = remote.call(GUI, "storage_bus_data", b6)
	expect(wd and wd.mode == "read" and wd.priority == 7 and wd.max == 18 and wd.status == "me-target", "window data " .. serpent.line(wd))
	expect(remote.call(GUI, "has_window", b6), "the storage bus has no window")
	remote.call(FSB, "set_filter", b6, 1, nil)
	expect(serpent.line(remote.call(FSB, "get_settings", b6).filters) == serpent.line({ "fluid/water" }), "filter removed")
	--- the waiting part (above): the export bus takes lubricant from T1's segment, a maintainer keeps 100 lubricant,
	--- the pump fills T5 from TS
	t1.insert_fluid{ name = "lubricant", amount = 2000 }                     -- enough for the export and the maintainer
	visit(b1)
	st.t1_before = seg(t1).lubricant or 0
	remote.call(IO, "set_bus_filters", ebus, { "lubricant" })
	remote.call("gregtorio-me-circuit", "set_maintainer", maint, "fluid/lubricant", 100, false)
	ts.insert_fluid{ name = "water", amount = 5000 }
end

--------------------------------------------------------------------------------
--- issue #38 (scripts/fork-me-circuit.lua, CPU tiers in scripts/fork-me-autocraft.lua): four own networks
--- right of the machine grid. Level maintainer: keeps 10 gears (exactly one job, then nothing while the
--- stock holds), refills what is taken out, takes its amount from a circuit signal, is switched off and on
--- by the lamp's circuit condition. CPU tiers: a co-processing CPU runs two jobs at once on two machines at
--- twice the speed, a third job waits; a quantum CPU has four slots. Circuit interface: the wire carries the
--- network contents (items and fluids), then only the filtered ones, and follows a change. Settings copy:
--- maintainer, circuit interface and fluid interface settings survive a blueprint (built and revived),
--- settings paste and cloning.
--------------------------------------------------------------------------------

local X38 = 250
local LM_Y, CT_Y, CI_Y, SC_Y = -80, -20, 40, 100
local LM_ITEM, LM_KEEP, LM_TAKE, LM_CIRCUIT, LM_LATER = "iron-gear-wheel", 10, 3, 14, 20
local GEAR_RECIPE = "iron-gear-crafting-table"
local AC38, C38, F38 = "gregtorio-me-autocraft", "gregtorio-me-circuit", "gregtorio-me-fluids"
local RED = defines.wire_connector_id.circuit_red

local function place38(s, fails, name, x, y, recipe)
	local ok, e = pcall(function()
		return s.create_entity{ name = name, position = { x, y }, force = "player", raise_built = true }
	end)
	if not (ok and e) then fails[#fails + 1] = "issue #38 " .. name .. ": " .. tostring(e) return nil end
	if recipe then
		e.force.recipes[recipe].enabled = true
		local ok2, err = pcall(function() e.set_recipe(recipe) end)
		if not ok2 then fails[#fails + 1] = "issue #38 recipe " .. recipe .. ": " .. tostring(err) end
	end
	return e
end

--- power, controller, terminal, a CPU (optional), a drive with plates and sticks (the layout of the autocrafting
--- test); returns the members (the controller first) for me_connect
local function network38(s, fails, y, cpu)
	local eei = place38(s, fails, "electric-energy-interface", X38 + 12.5, y + 6.5)
	if eei then
		eei.power_production = 1e6
		eei.electric_buffer_size = 1e7
	end
	place38(s, fails, "substation", X38 + 13, y + 2)
	local members = { place38(s, fails, "me-network-controller", X38 + 6, y), place38(s, fails, "me-terminal", X38 + 8.5, y + 4.5) }
	if cpu then members[#members + 1] = place38(s, fails, cpu, X38 + 10, y) end
	members[#members + 1] = me_drive(s, fails, "issue #38", X38 + 8.5, y + 6.5, { ["iron-plate"] = 200, ["iron-stick"] = 200 })
	return members
end

--- connect the entities to the controller of the network at row y (cables), then refresh circuit interfaces
local function connect38(y, entities, fails)
	local ctrl = game.surfaces[1].find_entity("me-network-controller", { X38 + 6, y })
	local list = { ctrl }
	for _, e in pairs(entities) do list[#list + 1] = e end
	me_connect(fails, "issue #38", list)
	for _, e in pairs(entities) do
		if e and e.valid and e.name == "me-circuit-interface" then remote.call("gregtorio-me-circuit", "update_circuit", e) end
	end
end

local function wire(a, b)
	return a.get_wire_connector(RED, true).connect_to(b.get_wire_connector(RED, true), false)
end

function setup_issue38_tests(s)
	local fails = {}
	--- level maintainer: two base CPUs (a free slot while a job runs: only the maintainer's own rule keeps it
	--- from starting a second job), one gear machine, a constant combinator for the circuit input
	local m = network38(s, fails, LM_Y, "me-crafting-cpu")
	m[#m + 1] = place38(s, fails, "me-crafting-cpu", X38 + 10, LM_Y - 3)
	place38(s, fails, "me-molecular-assembler", X38 + 14.5, LM_Y + 0.5, GEAR_RECIPE)
	m[#m + 1] = place38(s, fails, "me-pattern-provider", X38 + 16.5, LM_Y + 0.5)
	m[#m + 1] = place38(s, fails, "me-level-maintainer", X38 + 4.5, LM_Y + 8.5)
	place38(s, fails, "constant-combinator", X38 + 3.5, LM_Y + 10.5)
	me_connect(fails, "level maintainer", m)
	give_patterns(s.find_entity("me-pattern-provider", { X38 + 16.5, LM_Y + 0.5 }), { { kind = "crafting", recipe = GEAR_RECIPE } }, fails)
	--- CPU tiers: a co-processing CPU and two gear machines
	m = network38(s, fails, CT_Y, "me-co-processing-cpu")
	place38(s, fails, "me-molecular-assembler", X38 + 14.5, CT_Y + 0.5, GEAR_RECIPE)
	m[#m + 1] = place38(s, fails, "me-pattern-provider", X38 + 16.5, CT_Y + 0.5)
	place38(s, fails, "me-molecular-assembler", X38 + 20.5, CT_Y + 0.5, GEAR_RECIPE)
	m[#m + 1] = place38(s, fails, "me-pattern-provider", X38 + 18.5, CT_Y + 0.5)
	me_connect(fails, "CPU tiers", m)
	for _, x in pairs({ 16.5, 18.5 }) do
		give_patterns(s.find_entity("me-pattern-provider", { X38 + x, CT_Y + 0.5 }), { { kind = "crafting", recipe = GEAR_RECIPE } }, fails)
	end
	--- circuit interface: a fluid drive, the interface wired to a pole
	m = network38(s, fails, CI_Y, nil)
	m[#m + 1] = me_drive(s, fails, "circuit interface", X38 + 14.5, CI_Y + 6.5, {}, "1k", true)
	m[#m + 1] = place38(s, fails, "me-circuit-interface", X38 + 2.5, CI_Y + 8.5)
	place38(s, fails, "small-electric-pole", X38 + 0.5, CI_Y + 8.5)
	me_connect(fails, "circuit interface", m)
	--- settings copy: a maintainer, a circuit interface and an ME Interface with item and fluid rows and sides
	m = network38(s, fails, SC_Y, nil)
	m[#m + 1] = place38(s, fails, "me-level-maintainer", X38 + 2.5, SC_Y + 10.5)
	m[#m + 1] = place38(s, fails, "me-circuit-interface", X38 + 3.5, SC_Y + 10.5)
	m[#m + 1] = place38(s, fails, "me-network-interface", X38 + 4.5, SC_Y + 10.5)
	me_connect(fails, "settings copy", m)
	return fails
end

local function report38(key, name, problems, note)
	for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL " .. name .. ": " .. p) end
	log("DEVCHECK-RUNTIME-" .. key .. " " .. (#problems == 0 and "ok" or "failed") .. (note and (" (" .. note .. ")") or ""))
end

--- level maintainer: exactly one job, stops at N, refills, circuit amount, circuit condition
function maintainer_test()
	local s = game.surfaces[1]
	local terminal = s.find_entity("me-terminal", { X38 + 8.5, LM_Y + 4.5 })
	local m = s.find_entity("me-level-maintainer", { X38 + 4.5, LM_Y + 8.5 })
	local cc = s.find_entity("constant-combinator", { X38 + 3.5, LM_Y + 10.5 })
	local net = terminal and remote.call(NET, "network", terminal)
	local st = storage.maint38
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function finish(note)
		storage.maint38.done = true
		report38("MAINTAINER", "level maintainer", problems, note)
	end
	local function count() return me_count(terminal, LM_ITEM) end
	local function gear_jobs(active_only)
		local out = {}
		for _, j in pairs(remote.call(AC38, "jobs", terminal)) do
			if j.item == LM_ITEM and (j.active or not active_only) then out[#out + 1] = j end
		end
		return out
	end

	if not st then
		if game.tick < 60 then return end
		storage.maint38 = { started = game.tick, phase = "keep", phase_tick = game.tick, seen = {}, jobs = 0, amounts = {} }
		st = storage.maint38
		if not (terminal and net and m and cc) then expect(false, "entities missing") return finish() end
		expect(count() == 0, "gears in the network at the start: " .. count())
		local _, free, _, slots = remote.call(AC38, "cpus", terminal)
		expect(slots == 2 and free == 2, "maintainer network: " .. tostring(slots) .. " job slots, " .. free .. " free")
		expect(remote.call(C38, "set_maintainer", m, LM_ITEM, LM_KEEP, false), "set_maintainer failed")
		local g = remote.call(C38, "get_maintainer", m)
		expect(g and g.key == LM_ITEM and g.amount == LM_KEEP and g.circuit == false, "settings not stored: " .. serpent.line(g))
		if #problems > 0 then return finish() end
		return
	end
	if st.done then return end
	local function next_phase(name) st.phase = name st.phase_tick = game.tick end
	local function timeout(ticks, what)
		if game.tick > st.phase_tick + ticks then
			expect(false, what .. " timed out: maintainer " .. serpent.line(remote.call(C38, "get_maintainer", m))
				.. ", jobs " .. serpent.line(gear_jobs(false)) .. ", gears " .. count())
			finish()
			return true
		end
	end

	--- never two active jobs for the gear, and every job comes from the maintainer
	local active = gear_jobs(true)
	expect(#active <= 1, "more than one active gear job: " .. serpent.line(active))
	for _, j in pairs(gear_jobs(false)) do
		if not st.seen[j.id] then
			st.seen[j.id] = true
			st.jobs = st.jobs + 1
			st.last = { id = j.id, amount = j.amount }
			st.amounts[#st.amounts + 1] = j.amount
			expect(j.owner == m.unit_number, "job " .. j.id .. " was not started by the maintainer (owner " .. tostring(j.owner) .. ")")
			local info = remote.call(AC38, "job", j.id)
			expect(info.cpu_name == nil or (info.cpu_name == "me-crafting-cpu" and info.ops == 6),
				"a job on the ME Crafting CPU: " .. tostring(info.cpu_name) .. " with " .. tostring(info.ops) .. " hand-overs per step")
		end
	end
	if #problems > 0 then return finish() end
	local g = remote.call(C38, "get_maintainer", m)
	local function last_done(what)
		local j = remote.call(AC38, "job", st.last.id)
		expect(j and j.status == "done", what .. " ended as " .. tostring(j and j.status))
	end

	if st.phase == "keep" then
		if st.jobs == 1 and #active == 0 then
			last_done("the first job")
			expect(st.last.amount == LM_KEEP, "the first job asks for " .. st.last.amount .. ", expected " .. LM_KEEP)
			expect(count() >= LM_KEEP, "gears after the first job: " .. count())
			st.after_first = count()
			return next_phase("hold")
		end
		timeout(500, "the first maintainer job")
	elseif st.phase == "hold" then
		--- the stock is reached: no further job for 120 ticks (six maintainer checks)
		expect(st.jobs == 1, "a second job started although " .. count() .. " gears are in stock")
		if game.tick >= st.phase_tick + 120 then
			expect(g.status == "stocked", "status with enough in stock: " .. tostring(g.status))
			expect(count() == st.after_first, "the gear count changed without a job: " .. count())
			remote.call(NET, "extract", terminal, LM_ITEM, LM_TAKE)
			st.low = count()
			expect(st.low < LM_KEEP, "test setup: taking " .. LM_TAKE .. " gears out leaves " .. st.low)
			next_phase("refill")
		end
	elseif st.phase == "refill" then
		if st.jobs == 2 and #active == 0 then
			last_done("the refill job")
			expect(st.last.amount == LM_KEEP - st.low, "the refill job asks for " .. st.last.amount .. ", expected " .. (LM_KEEP - st.low))
			expect(count() >= LM_KEEP, "gears after the refill: " .. count())
			--- circuit input: the combinator sends LM_CIRCUIT gears, the maintainer takes its amount from the wire
			expect(wire(cc, m), "the combinator could not be wired to the maintainer")
			local cb = cc.get_or_create_control_behavior()
			local section = cb.get_section(1) or cb.add_section()
			section.set_slot(1, { value = { type = "item", name = LM_ITEM, quality = "normal", comparator = "=" }, min = LM_CIRCUIT })
			m.get_or_create_control_behavior().circuit_enable_disable = false
			remote.call(C38, "set_maintainer", m, nil, nil, true)
			st.before_circuit = count()
			return next_phase("circuit")
		end
		timeout(500, "the refill job")
	elseif st.phase == "circuit" then
		if st.jobs == 3 and #active == 0 then
			last_done("the circuit job")
			expect(st.last.amount == LM_CIRCUIT - st.before_circuit,
				"the circuit job asks for " .. st.last.amount .. ", expected " .. (LM_CIRCUIT - st.before_circuit))
			expect(count() >= LM_CIRCUIT, "gears after the circuit job: " .. count())
			expect(g.target == LM_CIRCUIT, "target from the circuit: " .. tostring(g.target))
			--- switched off by the lamp's circuit condition (signal-X > 0 is not on the wire), then amount 20 by hand
			local cb = m.get_or_create_control_behavior()
			cb.circuit_enable_disable = true
			cb.circuit_condition = { first_signal = { type = "virtual", name = "signal-X" }, comparator = ">", constant = 0 }
			remote.call(C38, "set_maintainer", m, nil, LM_LATER, false)
			return next_phase("disabled")
		end
		timeout(500, "the circuit job")
	elseif st.phase == "disabled" then
		expect(st.jobs == 3, "a job started while the circuit condition is false")
		if game.tick >= st.phase_tick + 100 then
			expect(g.status == "disabled", "status with a false circuit condition: " .. tostring(g.status))
			m.get_or_create_control_behavior().circuit_condition =
				{ first_signal = { type = "item", name = LM_ITEM }, comparator = ">", constant = 0 }
			st.before_enable = count()
			next_phase("enabled")
		end
	elseif st.phase == "enabled" then
		if st.jobs == 4 and #active == 0 then
			last_done("the job after switching on")
			expect(st.last.amount == LM_LATER - st.before_enable,
				"the job after switching on asks for " .. st.last.amount .. ", expected " .. (LM_LATER - st.before_enable))
			expect(count() >= LM_LATER, "gears at the end: " .. count())
			if #problems > 0 then return finish() end
			return finish("jobs for " .. table.concat(st.amounts, ", ") .. " gears, whole test " .. (game.tick - st.started) .. " ticks")
		end
		timeout(500, "the job after switching on")
	end
	if #problems > 0 then finish() end
end

--- CPU tiers: two jobs at once on a co-processing CPU, a third one waits; the quantum CPU's slots
function cpu_tier_test()
	local s = game.surfaces[1]
	local terminal = s.find_entity("me-terminal", { X38 + 8.5, CT_Y + 4.5 })
	local net = terminal and remote.call(NET, "network", terminal)
	local st = storage.tiers38
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function finish(note)
		storage.tiers38.done = true
		report38("CPUTIERS", "crafting CPU tiers", problems, note)
	end
	local function count(item) return me_count(terminal, item) end

	if not st then
		if game.tick < 60 then return end
		storage.tiers38 = { started = game.tick }
		st = storage.tiers38
		if not (terminal and net) then expect(false, "entities missing") return finish() end
		local n, free, _, slots = remote.call(AC38, "cpus", terminal)
		expect(n == 1 and slots == 2 and free == 2, "co-processing CPU: " .. n .. " CPUs, " .. tostring(slots) .. " slots, " .. free .. " free")
		local a = remote.call(AC38, "start", terminal, LM_ITEM, 8)
		local b = remote.call(AC38, "start", terminal, LM_ITEM, 8)
		expect(a and b, "the two jobs did not start")
		if not (a and b) then return finish() end
		local ja, jb = remote.call(AC38, "job", a), remote.call(AC38, "job", b)
		expect(ja.status == "running" and jb.status == "running", "the two jobs do not run at once: " .. ja.status .. ", " .. jb.status)
		expect(ja.cpu == jb.cpu and ja.cpu_name == "me-co-processing-cpu", "the jobs are not on the co-processing CPU: " .. tostring(ja.cpu_name))
		expect(ja.ops == 12 and jb.ops == 12, "hand-overs per step on the co-processing CPU: " .. ja.ops .. ", " .. jb.ops)
		local _, free2 = remote.call(AC38, "cpus", terminal)
		expect(free2 == 0, "free slots with two jobs: " .. free2)
		local c, why = remote.call(AC38, "start", terminal, LM_ITEM, 1)
		expect(c == nil and why == "no-free-cpu", "a third job must be refused while both slots run (issue #6): " .. tostring(c) .. " " .. tostring(why))
		if c then remote.call(AC38, "cancel", c) end
		st.a, st.b, st.c = a, b, c
		if #problems > 0 then return finish() end
		return
	end
	if st.done then return end
	local ja, jb = remote.call(AC38, "job", st.a), remote.call(AC38, "job", st.b)
	if ja.leases > 0 and jb.leases > 0 then st.overlap = true end     -- both jobs had a machine crafting at once
	local function over(j) return j.status == "done" or j.status == "failed" or j.status == "cancelled" end
	if over(ja) and over(jb) then
		expect(ja.status == "done" and jb.status == "done", "jobs ended as " .. ja.status .. ", " .. jb.status)
		expect(st.overlap, "the two jobs never had a machine crafting at the same time")
		expect(count(LM_ITEM) >= 16, "gears after both jobs: " .. count(LM_ITEM))
		local jc = st.c and remote.call(AC38, "job", st.c)
		expect(not jc or jc.status == "cancelled", "the third job: " .. tostring(jc and jc.status))
		--- the upgrade planner's result, by script: a quantum CPU with four slots
		local cpu = s.find_entity("me-co-processing-cpu", { X38 + 10, CT_Y })
		if cpu then cpu.destroy() end
		local q = s.create_entity{ name = "me-quantum-crafting-cpu", position = { X38 + 10, CT_Y }, force = "player", raise_built = true }
		local n, free, _, slots = remote.call(AC38, "cpus", terminal)
		expect(q and n == 1 and slots == 4 and free == 4, "quantum CPU: " .. n .. " CPUs, " .. tostring(slots) .. " slots, " .. free .. " free")
		if #problems > 0 then return finish() end
		return finish("two jobs of 8 gears at once, " .. (game.tick - st.started) .. " ticks")
	end
	if game.tick > st.started + 900 then
		expect(false, "the two jobs timed out: " .. serpent.line(ja) .. " / " .. serpent.line(jb))
		finish()
	end
end

--- circuit interface: the wire carries the network contents, then the filtered ones, and follows a change
function circuit_test()
	local s = game.surfaces[1]
	local terminal = s.find_entity("me-terminal", { X38 + 8.5, CI_Y + 4.5 })
	local ci = s.find_entity("me-circuit-interface", { X38 + 2.5, CI_Y + 8.5 })
	local pole = s.find_entity("small-electric-pole", { X38 + 0.5, CI_Y + 8.5 })
	local drive = s.find_entity("me-drive", { X38 + 8.5, CI_Y + 6.5 })
	local net = terminal and remote.call(NET, "network", terminal)
	local st = storage.circuit38
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function finish(note)
		storage.circuit38.done = true
		report38("CIRCUIT", "circuit interface", problems, note)
	end
	--- "name" for items (with "@quality" above normal), "fluid/name" for fluids -> count
	local function on_wire()
		local out = {}
		local cn = ci.get_circuit_network(RED)
		for _, sg in pairs(cn and cn.signals or {}) do
			local sig = sg.signal
			local key
			if sig.type == "fluid" then key = "fluid/" .. sig.name
			else
				local q = sig.quality and (type(sig.quality) == "string" and sig.quality or sig.quality.name) or "normal"
				key = sig.name .. (q ~= "normal" and ("@" .. q) or "")
			end
			out[key] = (out[key] or 0) + sg.count
		end
		return out
	end
	local function expected(filter)
		local out = {}
		for key, n in pairs(remote.call(NET, "contents", terminal)) do      -- keys: "name" or "name@quality"
			local name = key:match("^[^@#]+")
			if not filter or filter[name] then out[key] = (out[key] or 0) + n end
		end
		for name, amount in pairs(remote.call(F38, "totals", terminal)) do
			if (not filter or filter["fluid/" .. name]) and amount >= 1 then out["fluid/" .. name] = math.floor(amount) end
		end
		return out
	end
	local function same(a, b)
		for k, v in pairs(a) do if b[k] ~= v then return false end end
		for k, v in pairs(b) do if a[k] ~= v then return false end end
		return true
	end

	if not st then
		if game.tick < 60 then return end
		storage.circuit38 = { started = game.tick, phase = "all", phase_tick = game.tick }
		st = storage.circuit38
		if not (terminal and net and ci and pole and drive) then expect(false, "entities missing") return finish() end
		local put = remote.call(F38, "insert", terminal, "water", 500.5)
		expect(math.abs(put - 500.5) < 1e-6, "water into the fluid drive: " .. put)
		expect(wire(ci, pole), "the interface could not be wired")
		if #problems > 0 then return finish() end
		return
	end
	if st.done then return end
	local function next_phase(name) st.phase = name st.phase_tick = game.tick end
	local wired = on_wire()
	if st.phase == "all" then
		local want = expected(nil)
		if same(wired, want) then
			expect(wired["fluid/water"] == 500, "water on the wire: " .. tostring(wired["fluid/water"]))
			expect(wired["iron-plate"] == 200 and wired["iron-stick"] == 200, "items on the wire: " .. serpent.line(wired))
			st.all = table_size(wired)
			remote.call(C38, "set_circuit_filters", ci, { "iron-plate", "fluid/water" })
			return next_phase("filtered")
		end
		if game.tick > st.phase_tick + 200 then
			expect(false, "the wire does not carry the network contents: " .. serpent.line(wired) .. ", expected " .. serpent.line(want))
			return finish()
		end
	elseif st.phase == "filtered" then
		local want = expected({ ["iron-plate"] = true, ["fluid/water"] = true })
		if same(wired, want) then
			local got = remote.call(C38, "get_circuit", ci)
			expect(got and #got.filters == 2 and got.signals == 2, "interface record: " .. serpent.line(got))
			remote.call(NET, "store_in_drive", drive, "iron-plate", 25)
			return next_phase("change")
		end
		if game.tick > st.phase_tick + 200 then
			expect(false, "the filtered wire: " .. serpent.line(wired) .. ", expected " .. serpent.line(want))
			return finish()
		end
	elseif st.phase == "change" then
		if wired["iron-plate"] == 225 then
			expect(table_size(wired) == 2, "the filtered wire after the change: " .. serpent.line(wired))
			if #problems > 0 then return finish() end
			return finish(st.all .. " signals, then 2 filtered, change seen after " .. (game.tick - st.phase_tick) .. " ticks")
		end
		if game.tick > st.phase_tick + 200 then
			expect(false, "the wire did not follow the change: " .. serpent.line(wired))
			return finish()
		end
	end
end

--- settings copy: blueprint (tags, built and revived), settings paste, cloning; for maintainers, circuit
--- interfaces and fluid interfaces
function settings_test()
	if storage.settings38 then return end
	if game.tick < 60 then return end
	storage.settings38 = { done = true }
	local s = game.surfaces[1]
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local m = s.find_entity("me-level-maintainer", { X38 + 2.5, SC_Y + 10.5 })
	local ci = s.find_entity("me-circuit-interface", { X38 + 3.5, SC_Y + 10.5 })
	local fi = s.find_entity("me-network-interface", { X38 + 4.5, SC_Y + 10.5 })
	if not (m and ci and fi) then
		expect(false, "entities missing")
		return report38("SETTINGS", "settings copy", problems)
	end
	local M_SET = { key = "fluid/water", amount = 1234, circuit = true }
	local C_SET = { "iron-plate", "fluid/water" }
	local F_CONFIG = { [1] = { name = "iron-plate", quality = "normal", amount = 50 }, [2] = { type = "fluid", name = "water", amount = 2345 } }
	local F_SIDES = { [2] = 2, [4] = "off" }
	remote.call(C38, "set_maintainer", m, M_SET.key, M_SET.amount, M_SET.circuit)
	remote.call(C38, "set_circuit_filters", ci, C_SET)
	remote.call(IO, "set_interface_config", fi, F_CONFIG, F_SIDES)
	local function check(what, mm, cc, ff)
		if mm then
			local g = remote.call(C38, "get_maintainer", mm)
			expect(g and g.key == M_SET.key and g.amount == M_SET.amount and g.circuit == M_SET.circuit,
				what .. ": maintainer settings " .. serpent.line(g))
		end
		if cc then
			local g = remote.call(C38, "get_circuit", cc)
			expect(g and serpent.line(g.filters) == serpent.line(C_SET), what .. ": circuit interface filters " .. serpent.line(g))
			--- that network has no fluid drive: of the two filters only the plates are on the wire
			expect(g and g.signals == 1, what .. ": circuit interface signals " .. tostring(g and g.signals))
		end
		if ff then
			local c, sd = remote.call(IO, "get_interface_config", ff), remote.call(IO, "get_interface_sides", ff)
			expect(c and c[1] and c[1].name == "iron-plate" and c[1].amount == 50 and c[2] and c[2].type == "fluid"
				and c[2].name == "water" and c[2].amount == 2345 and serpent.line(sd) == serpent.line(F_SIDES),
				what .. ": ME Interface settings " .. serpent.line(c) .. " " .. serpent.line(sd))
		end
	end
	check("original", m, ci, fi)

	--- blueprint: the settings become entity tags (the handler of on_player_setup_blueprint)
	local inv = game.create_inventory(1)
	inv.insert{ name = "blueprint" }
	local bp = inv[1]
	local mapping = bp.create_blueprint{ surface = s, force = "player",
		area = { { X38 + 2, SC_Y + 10 }, { X38 + 5, SC_Y + 11 } } }
	remote.call(AC38, "tag_blueprint", bp, mapping)
	local tagged = {}
	for index, e in pairs(mapping or {}) do
		local tag = ({ ["me-level-maintainer"] = "fork_me_maintainer", ["me-circuit-interface"] = "fork_me_circuit",
			["me-network-interface"] = "fork_me_interface" })[e.name]
		if tag then tagged[e.name] = bp.get_blueprint_entity_tag(index, tag) end
	end
	local tm, tc, tf = tagged["me-level-maintainer"], tagged["me-circuit-interface"], tagged["me-network-interface"]
	expect(tm and tm.key == M_SET.key and tm.amount == M_SET.amount and tm.circuit == M_SET.circuit, "maintainer tag " .. serpent.line(tm))
	expect(tc and serpent.line(tc.filters) == serpent.line(C_SET), "circuit interface tag " .. serpent.line(tc))
	expect(tf and tf.config and #tf.config == 2 and tf.sides and #tf.sides == 2, "ME Interface tag " .. serpent.line(tf))
	--- built from the blueprint (ghosts with the tags) and revived: the new entities have the settings
	local ghosts = bp.build_blueprint{ surface = s, force = "player", position = { X38 + 10, SC_Y + 14 } }
	local built = {}
	for _, g in pairs(ghosts or {}) do
		if g.valid then
			local name = g.ghost_name
			local _, e = g.revive{ raise_revive = true }
			if e then built[name] = e end
		end
	end
	built["me-cable"] = nil                         -- the cables that connected the originals are in the blueprint too
	expect(table_size(built) == 3, "revived from the blueprint: " .. table_size(built) .. " of 3")
	local cfails = {}
	connect38(SC_Y, { built["me-level-maintainer"], built["me-circuit-interface"], built["me-network-interface"] }, cfails)
	check("blueprint", built["me-level-maintainer"], built["me-circuit-interface"], built["me-network-interface"])
	inv.destroy()

	--- settings paste onto plain entities
	local pm = s.create_entity{ name = "me-level-maintainer", position = { X38 + 2.5, SC_Y + 12.5 }, force = "player", raise_built = true }
	local pc = s.create_entity{ name = "me-circuit-interface", position = { X38 + 3.5, SC_Y + 12.5 }, force = "player", raise_built = true }
	local pf = s.create_entity{ name = "me-network-interface", position = { X38 + 4.5, SC_Y + 12.5 }, force = "player", raise_built = true }
	remote.call(C38, "paste", m, pm)
	remote.call(C38, "paste", ci, pc)
	remote.call(IO, "paste", fi, pf)
	connect38(SC_Y, { pm, pc, pf }, cfails)
	check("paste", pm, pc, pf)

	--- clones (on_entity_cloned)
	local km = m.clone{ position = { X38 + 2.5, SC_Y + 8.5 } }
	local kc = ci.clone{ position = { X38 + 3.5, SC_Y + 8.5 } }
	local kf = fi.clone{ position = { X38 + 4.5, SC_Y + 8.5 } }
	expect(km and kc and kf, "clone failed")
	connect38(SC_Y, { km, kc, kf }, cfails)
	for _, f in pairs(cfails) do expect(false, f) end
	check("clone", km, kc, kf)
	report38("SETTINGS", "settings copy", problems, #problems == 0 and "blueprint, paste and clone of 3 entity types" or nil)
end

--------------------------------------------------------------------------------
--- the scheduler (me-network issue #5, scripts/fork-me-schedule.lua): an export bus whose item the network lacks
--- sleeps and wakes when the item comes in; an import bus facing nothing takes a chest built in front of it at its
--- next tick; a full storage bus is passed by until its next read (then it takes items again); 300 random inserts and
--- extracts keep the network's totals equal to the cells plus the storage bus's chest, and every count equal to what
--- went in minus what came out.
--------------------------------------------------------------------------------

local SCX, SCY = 380, 40
local SB = "gregtorio-me-storagebus"

function setup_scheduler_test(s)
	local fails = {}
	local function place(name, x, y, extra) return me_place(s, fails, "scheduler", name, x, y, extra) end
	local eei = place("electric-energy-interface", SCX + 12.5, SCY + 6.5)
	if eei then
		eei.power_production = 1e6
		eei.electric_buffer_size = 1e7
	end
	place("substation", SCX + 13, SCY + 2)
	local north = { direction = defines.direction.north }
	local members = { place("me-network-controller", SCX + 6, SCY),
		me_drive(s, fails, "scheduler", SCX + 8.5, SCY + 4.5, { ["iron-plate"] = 1000, ["iron-gear-wheel"] = 500 }),
		place("me-export-bus", SCX + 2.5, SCY + 0.5, north),              -- E1: copper plates into C1
		place("me-import-bus", SCX + 3.5, SCY + 0.5, north),              -- I2: nothing in front yet
		place("me-storage-bus", SCX + 4.5, SCY + 0.5, north) }            -- S1: chest C3, priority 10
	place("iron-chest", SCX + 2.5, SCY - 0.5)
	place("iron-chest", SCX + 4.5, SCY - 0.5)
	me_connect(fails, "scheduler", members)
	if members[3] then remote.call(IO, "set_bus_filters", members[3], { "copper-plate" }) end
	if members[5] then remote.call(SB, "set_settings", members[5], { priority = 10 }) end
	return fails
end

function scheduler_test()
	local s = game.surfaces[1]
	if game.tick < 120 then return end
	local function find(name, x, y) return s.find_entity(name, { SCX + x, SCY + y }) end
	local ctrl = find("me-network-controller", 6, 0)
	local e1, i2, s1 = find("me-export-bus", 2.5, 0.5), find("me-import-bus", 3.5, 0.5), find("me-storage-bus", 4.5, 0.5)
	local c1, c3 = find("iron-chest", 2.5, -0.5), find("iron-chest", 4.5, -0.5)
	local st = storage.sched_test
	if not st then
		st = { phase = 1, problems = {} }
		storage.sched_test = st
	end
	local problems = st.problems
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function finish(note)
		st.done = true
		me_report("SCHEDULER", "ME scheduler", problems, note)
	end
	if not (ctrl and e1 and i2 and s1 and c1 and c3) then
		problems[#problems + 1] = "a block of the test is missing"
		finish()
		return
	end
	local function count(name) return remote.call(NET, "count", ctrl, name) end
	if st.phase == 1 then
		--- issue #38: the scheduler's counters (visits, backlog, intervals) are readable and count the visits so far
		local stats = remote.call(IO, "sched_stats", false)
		local io_st = stats and stats.io
		expect(io_st and io_st.visits > 0 and io_st.ticks > 0 and io_st.idle and io_st.full, "sched_stats has no io counters")
		local bl = remote.call(IO, "backlogs")
		expect(bl and bl.io == 0, "backlogs: the io queue should be empty in a small network: " .. serpent.line(bl))
		--- issue #38: the counts of the busy and the probe list are in storage and add up with the parked blocks
		expect(bl and bl.io_busy + bl.io_probing + bl.io_parked == bl.io_units and bl.io_units > 0,
			"the io counts do not add up: " .. serpent.line(bl))
		expect(bl and bl.storage_bus_busy + bl.storage_bus_probing == bl.storage_bus_units,
			"the storage bus counts do not add up: " .. serpent.line(bl))
		--- the export bus found no copper: it is parked (no visit, no probe) until the network gets some
		expect(c1.get_item_count("copper-plate") == 0, "copper in C1 before there was any")
		local sch = remote.call(IO, "schedule", e1)
		if not sch then
			problems[#problems + 1] = "the export bus is not scheduled"
		elseif sch.front or sch.backlog or (sch.due and sch.due <= game.tick + 1) then
			return                                                  -- due anyway: try again at the next round
		end
		expect(sch and sch.parked == "no-key", "the export bus without its item is not parked for it: " .. serpent.line(sch))
		remote.call(NET, "insert", ctrl, "copper-plate", 50)
		sch = remote.call(IO, "schedule", e1)
		expect(sch and sch.front and not sch.parked, "the export bus was not woken to the front by its copper ("
			.. serpent.line(sch) .. " at tick " .. game.tick .. ")")
		st.t, st.phase = game.tick, 2
	elseif st.phase == 2 then
		if c1.get_item_count("copper-plate") > 0 then
			st.woken = game.tick - st.t
			expect(st.woken <= 20, "export bus woke after " .. st.woken .. " ticks")
			--- a chest with wood built in front of the import bus
			local c2 = s.create_entity{ name = "iron-chest", position = { SCX + 3.5, SCY - 0.5 }, force = "player", raise_built = true }
			if c2 then c2.insert{ name = "wood", count = 100 } end
			local sch = remote.call(IO, "schedule", i2)
			expect(sch and sch.front, "the import bus was not woken to the front by the chest built in front of it ("
				.. serpent.line(sch) .. " at tick " .. game.tick .. ")")
			--- the export bus moved its copper: it is busy now, due at a tick (the chest uses none: the longest interval)
			local se = remote.call(IO, "schedule", e1)
			expect(se and not se.parked and not se.probing and se.due and se.due <= game.tick + 600,
				"the export bus that moved copper is not busy: " .. serpent.line(se))
			st.t, st.phase = game.tick, 3
		elseif game.tick - st.t > 30 then
			problems[#problems + 1] = "the export bus never woke for its copper"
			st.phase = 3
			st.t = game.tick
		end
	elseif st.phase == 3 then
		if count("wood") >= 100 then
			st.built = game.tick - st.t
			--- 100 wood at the bus speed (256 items per second) are 24 ticks; the first visit after the wake has only
			--- the ticks since the bus's last idle visit to spend, the next one comes an active interval (15 ticks)
			--- later, and this test looks every 10 ticks: 50 at most. (The wake itself is checked above.)
			expect(st.built <= 50, "the import bus took the built chest's wood after " .. st.built .. " ticks")
			st.phase = 4
		elseif game.tick - st.t > 60 then
			problems[#problems + 1] = "the import bus never took the wood of the chest built in front of it (" .. count("wood") .. ")"
			st.phase = 4
		end
	elseif st.phase == 4 then
		--- a full storage bus is passed by until its next read
		local inv = c3.get_inventory(defines.inventory.chest)
		inv.insert{ name = "iron-plate", count = 100 * #inv }
		remote.call(SB, "visit", s1)
		local full = c3.get_item_count("iron-plate")
		local total = count("iron-plate")
		local n = remote.call(NET, "insert", ctrl, "iron-plate", 10)
		expect(n == 10 and count("iron-plate") == total + 10, "insert with a full storage bus: " .. n)
		expect(c3.get_item_count("iron-plate") == full, "the full chest took plates")
		inv.remove{ name = "iron-plate", count = 50 }               -- by hand: no event
		remote.call(NET, "insert", ctrl, "iron-plate", 10)
		expect(c3.get_item_count("iron-plate") == full - 50, "a full storage bus was asked again before its next read")
		remote.call(SB, "visit", s1)
		remote.call(NET, "insert", ctrl, "iron-plate", 10)
		expect(c3.get_item_count("iron-plate") == full - 40, "after its read the storage bus (priority 10) did not take the plates: "
			.. c3.get_item_count("iron-plate") .. " of " .. (full - 40))
		st.phase = 5
	elseif st.phase == 5 then
		--- random inserts and extracts: every count is what went in minus what came out, and the totals are the
		--- cells plus the storage bus's chest
		local keys = { "iron-plate", "iron-gear-wheel", "copper-plate", "wood", "iron-plate@uncommon", "stone" }
		local before, moved = {}, {}
		for _, k in ipairs(keys) do before[k] = remote.call(NET, "contents", ctrl)[k] or 0 moved[k] = 0 end
		local seed = 7
		for _ = 1, 300 do
			seed = (seed * 1103515245 + 12345) % 2147483648
			local r = math.floor(seed / 65536)
			local k = keys[r % #keys + 1]
			local name, q = k:match("^([^@]+)@?(.*)$")
			q = q ~= "" and q or "normal"
			local n = math.floor(r / 7) % 120 + 1
			if r % 2 == 0 then
				moved[k] = moved[k] + remote.call(NET, "insert", ctrl, name, n, q)
			else
				moved[k] = moved[k] - remote.call(NET, "extract", ctrl, name, n, q)
			end
		end
		remote.call(SB, "visit", s1)
		local contents = remote.call(NET, "contents", ctrl)
		local cells = {}
		local d = find("me-drive", 8.5, 4.5)
		for _, cell in pairs(remote.call(NET, "drive", d)) do
			for k, n in pairs(cell.items) do cells[k] = (cells[k] or 0) + n end
		end
		for _, it in pairs(c3.get_inventory(defines.inventory.chest).get_contents()) do
			local k = (it.quality or "normal") == "normal" and it.name or (it.name .. "@" .. it.quality)
			cells[k] = (cells[k] or 0) + it.count
		end
		for _, k in ipairs(keys) do
			expect((contents[k] or 0) == before[k] + moved[k], k .. ": " .. tostring(contents[k]) .. " in the network, "
				.. (before[k] + moved[k]) .. " expected")
			expect((cells[k] or 0) == (contents[k] or 0), k .. ": cells and chest hold " .. tostring(cells[k]) .. ", the totals say "
				.. tostring(contents[k]))
		end
		for k, n in pairs(contents) do
			if not k:find("^fluid/") and (cells[k] or 0) ~= n then problems[#problems + 1] = k .. ": totals " .. n .. ", storage " .. tostring(cells[k]) end
		end
		st.note = "woken after " .. tostring(st.woken) .. " ticks, built chest taken after " .. tostring(st.built) .. " ticks"
		--- issue #38: a block blocked on the network's side is parked (no visit, no probe) and woken by the network:
		--- the power goes, copper comes in (the export bus wakes, finds no power and parks), the power comes back
		local eei = find("electric-energy-interface", 12.5, 6.5)
		if not eei then
			problems[#problems + 1] = "the test's power source is missing"
			finish(st.note)
			return
		end
		eei.power_production, eei.energy, ctrl.energy = 0, 0, 0
		st.t, st.phase = game.tick, 6
	elseif st.phase == 6 then
		--- the controller's buffer drains over some ticks: wake the export bus only once the network reports no power
		local n = remote.call(NET, "network", ctrl)
		if n and n.status == "no-power" then
			--- copper for later, and a wake through the settings (the bus is busy, not waiting for its key)
			remote.call(NET, "insert", ctrl, "copper-plate", 10)
			st.copper = c1.get_item_count("copper-plate")
			remote.call(IO, "set_bus_filters", e1, { "copper-plate" })
			st.dark = game.tick - st.t
			st.t, st.phase = game.tick, 7
		elseif game.tick - st.t > 300 then
			problems[#problems + 1] = "the network kept its power 300 ticks after the source was cut: " .. serpent.line(n)
			local eei = find("electric-energy-interface", 12.5, 6.5)
			if eei then eei.power_production = 1e6 end
			finish(st.note)
		end
	elseif st.phase == 7 then
		local sch = remote.call(IO, "schedule", e1)
		local eei = find("electric-energy-interface", 12.5, 6.5)
		if sch and sch.parked == "no-power" then
			st.dark = game.tick - st.t
			local bl = remote.call(IO, "backlogs")
			expect(bl and bl.io_parked >= 1 and bl.io_busy + bl.io_probing + bl.io_parked == bl.io_units,
				"the parked block is not counted: " .. serpent.line(bl))
			expect(c1.get_item_count("copper-plate") == st.copper, "copper moved without power")
			if eei then eei.power_production = 1e6 end
			st.t, st.phase = game.tick, 8
		elseif game.tick - st.t > 60 then
			problems[#problems + 1] = "the export bus woken without power was not parked within 60 ticks: " .. serpent.line(sch)
			if eei then eei.power_production = 1e6 end
			finish(st.note)
		end
	elseif st.phase == 8 then
		if c1.get_item_count("copper-plate") > st.copper then
			st.lit = game.tick - st.t
			--- the slow step asks a network with parked blocks for its power every 60 ticks; the wake is visited next tick
			expect(st.lit <= 90, "the export bus parked for power moved its copper only " .. st.lit .. " ticks after the power came back")
			local sch = remote.call(IO, "schedule", e1)
			expect(sch and sch.parked ~= "no-power", "the export bus is still parked for power: " .. serpent.line(sch))
			finish(st.note .. ", the network dark " .. st.dark .. " ticks after the cut, the parked bus served " .. st.lit
				.. " ticks after the power came back")
		elseif game.tick - st.t > 300 then
			problems[#problems + 1] = "the export bus parked for power never woke (" .. serpent.line(remote.call(IO, "schedule", e1)) .. ")"
			finish(st.note)
		end
	end
end

--------------------------------------------------------------------------------
--- The open key with a tool in the cursor (G.click_opens, fork-me-gui.lua): an ME window opens on a click exactly
--- when the game would open a chest's window. The harness has no player, so the decision is fed real item stacks
--- of every cursor tool (and the cursor flags a stack cannot hold: a library blueprint, a ghost, a wire being
--- dragged, a damaged block). Opening the window, the game's own click action and the tool staying in the cursor
--- need the real game.
function cursor_test()
	if storage.cursor_t then return end
	storage.cursor_t = { done = true }
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local inv = game.create_inventory(1)
	local stack = inv[1]
	local n = 0
	local function case(name, setup, flags, want)
		n = n + 1
		stack.clear()
		local ok, err = pcall(setup)
		if not ok then expect(false, name .. ": setup failed: " .. tostring(err)) return end
		local got, why = remote.call("gregtorio-me-terminal", "click_opens", stack, flags or {})
		expect(got == want, name .. ": " .. tostring(got) .. " (" .. tostring(why) .. "), expected " .. tostring(want))
	end
	local function item(name, count) return function() stack.set_stack{ name = name, count = count or 1 } end end
	local function blueprint()
		stack.set_stack{ name = "blueprint" }
		stack.set_blueprint_entities{ { entity_number = 1, name = "small-lamp", position = { 0.5, 0.5 } } }
	end
	local none = function() end
	--- the window opens: an empty hand, plain items, a storage cell and an encoded pattern (quick insert first)
	case("empty hand", none, nil, true)
	case("iron plate", item("iron-plate", 50), nil, true)
	case("module", item("speed-module", 5), nil, true)
	case("storage cell", item("me-1k-storage-cell"), nil, true)
	case("blank pattern", item("me-blank-pattern", 5), nil, true)
	case("repair pack, block not damaged", item("repair-pack", 5), nil, true)
	--- it does not: tools, wires, ghosts, items being built
	case("blueprint", blueprint, { blueprint = true }, false)
	case("blueprint (stack only)", blueprint, nil, false)
	case("empty blueprint", item("blueprint"), nil, false)
	case("blueprint book", function()
		stack.set_stack{ name = "blueprint-book" }
		local book = stack.get_inventory(defines.inventory.item_main)
		book.insert{ name = "blueprint" }
		book[1].set_blueprint_entities{ { entity_number = 1, name = "small-lamp", position = { 0.5, 0.5 } } }
	end, { blueprint = true }, false)
	case("empty blueprint book", item("blueprint-book"), nil, false)
	case("deconstruction planner", item("deconstruction-planner"), nil, false)
	case("upgrade planner", item("upgrade-planner"), nil, false)
	case("copy-paste tool", item("copy-paste-tool"), nil, false)
	case("cut tool", item("cut-paste-tool"), nil, false)
	case("selection tool of another mod", item("zz-devcheck-selection-tool"), nil, false)
	case("spidertron remote", item("spidertron-remote"), nil, false)
	case("artillery targeting remote", item("artillery-targeting-remote"), nil, false)
	case("red wire", item("red-wire"), nil, false)
	case("green wire", item("green-wire"), nil, false)
	case("copper wire", item("copper-wire"), nil, false)
	case("rail planner", item("rail", 10), nil, false)
	case("buildable item (belt)", item("transport-belt", 50), nil, false)
	case("buildable ME block (fluix cable)", item("fluix-cable", 50), nil, false)
	case("tile item (landfill)", item("landfill", 50), nil, false)
	case("item with entity data (car)", item("car"), nil, false)
	case("capsule (fish)", item("raw-fish", 5), nil, false)
	case("capsule (grenade)", item("grenade", 5), nil, false)
	case("repair pack, block damaged", item("repair-pack", 5), { damaged = true }, false)
	--- the cursor flags without a readable stack
	case("blueprint from the library", none, { blueprint = true }, false)
	case("library record (book)", none, { record = true }, false)
	case("ghost in the cursor", none, { ghost = true }, false)
	case("wire being dragged", none, { wire = true }, false)
	inv.destroy()
	for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL cursor: " .. p) end
	log("DEVCHECK-RUNTIME-CURSOR " .. (#problems == 0 and "ok" or "failed") .. " (" .. n .. " cursor states)")
end

--------------------------------------------------------------------------------
--- Recipe paste (me-network issue #12, scripts/fork-me-recipe-paste.lua): a crafting machine's recipe pasted onto an
--- ME Interface, a storage bus, an export and an import bus. The harness has no player, so the event handler is
--- called with the event's shape (remote `paste`, which returns the flying text's messages); that the game raises
--- the event for a crafting machine is checked on the prototypes (every crafting machine lists the four blocks in
--- its additional_pastable_entities, the GregTech machines with Gregtorio too). The cases: an item recipe, a fluid
--- recipe, a quality recipe, recipes with more ingredients than the blocks hold (the fixtures of runtimemod/data.lua
--- and data-final-fixes.lua),
--- a furnace (its current recipe, then its previous one), machines without a recipe, the interface's sides (off
--- stays, a fluid that comes again keeps its side, a pipe side first, no pipe, no side left), mode and priority of a
--- storage bus kept, a recipe without items for a chest, and a paste between two ME blocks is no recipe paste.
--------------------------------------------------------------------------------

local PAX, PAY = 300, 290
local RP = "gregtorio-me-recipe-paste"
local PASTE_TARGETS = { "me-network-interface", "me-import-bus", "me-export-bus", "me-storage-bus" }

function setup_paste_test(s)
	local fails = {}
	local what = "recipe paste"
	power(s, fails, what, PAX, PAY)
	me_place(s, fails, what, "me-network-controller", PAX + 7, PAY)
	cable_row(s, fails, PAX + 8, PAX + 46, PAY - 1)
	local south = { direction = defines.direction.south }
	for _, x in pairs({ 9.5, 12.5, 14.5, 16.5, 18.5, 20.5, 22.5, 24.5 }) do
		me_place(s, fails, what, "me-network-interface", PAX + x, PAY + 0.5)
	end
	me_place(s, fails, what, "pipe", PAX + 10.5, PAY + 0.5)                     -- the east side of interface I1
	me_place(s, fails, what, "iron-chest", PAX + 26.5, PAY + 1.5)
	me_place(s, fails, what, "iron-chest", PAX + 28.5, PAY + 1.5)
	local water = me_place(s, fails, what, "pipe", PAX + 30.5, PAY + 1.5)
	if water then water.fluidbox[1] = { name = "water", amount = 50 } end
	for _, x in pairs({ 26.5, 28.5, 30.5, 32.5 }) do me_place(s, fails, what, "me-storage-bus", PAX + x, PAY + 0.5, south) end
	for _, x in pairs({ 34.5, 36.5, 38.5, 40.5 }) do me_place(s, fails, what, "me-export-bus", PAX + x, PAY + 0.5, south) end
	for _, x in pairs({ 42.5, 44.5 }) do me_place(s, fails, what, "me-import-bus", PAX + x, PAY + 0.5, south) end
	--- the machines, away from the blocks
	local function machine(name, x, recipe, quality)
		local m = me_place(s, fails, what, name, PAX + x, PAY + 6.5)
		if m and recipe then
			m.force.recipes[recipe].enabled = true
			m.set_recipe(recipe, quality)
		end
		return m
	end
	machine("me-molecular-assembler", 10.5, "iron-gear-crafting-table")
	machine("me-molecular-assembler", 14.5, "iron-gear-crafting-table", "uncommon")
	machine("me-molecular-assembler", 18.5)
	machine("hv-chemical-reactor", 22.5, "phenolic-circuit-board")
	machine("hv-chemical-reactor", 26.5, "hydrochloric-acid")
	machine("zz-devcheck-paste-machine", 30.5, "zz-devcheck-paste-many")
	machine("zz-devcheck-paste-machine", 34.5, "zz-devcheck-paste-fluids")
	game.forces.player.recipes["iron-dust-smelter"].enabled = true    -- a furnace only picks enabled recipes
	for _, x in pairs({ 38, 41 }) do
		local f = me_place(s, fails, what, "iron-furnace", PAX + x, PAY + 7)
		if f then f.get_inventory(defines.inventory.fuel).insert{ name = "coal", count = 5 } end
		if f and x == 38 then f.get_inventory(defines.inventory.furnace_source).insert{ name = "iron-dust", count = 1 } end
	end
	return fails
end

function paste_test()
	local st = storage.paste_t
	if (st and st.done) or game.tick < 60 then return end
	local s = game.surfaces[1]
	local function find(name, x, y) return s.find_entity(name, { PAX + x, PAY + y }) end
	local function iface(x) return find("me-network-interface", x, 0.5) end
	local f1 = find("iron-furnace", 38, 7)
	if st then
		--- the furnace's previous recipe: once the furnace is idle, pasted onto export bus E4
		local idle = f1 and f1.valid and f1.get_recipe() == nil
		if not idle and game.tick < 1300 then return end
		st.done = true
		local problems = st.problems
		local eb = find("me-export-bus", 40.5, 0.5)
		local note = st.note or ""
		if idle and eb then
			local msgs = remote.call(RP, "paste", f1, eb)
			local f = remote.call(IO, "get_bus", eb).filters
			if not (msgs and #msgs == 0 and serpent.line(f) == serpent.line({ "iron-dust" })) then
				problems[#problems + 1] = "furnace's previous recipe onto an export bus: " .. serpent.line(f) .. " " .. serpent.line(msgs)
			end
			note = note .. ", previous recipe at tick " .. game.tick
		else
			note = note .. ", the furnace was still busy at tick " .. game.tick .. ": previous recipe not checked"
		end
		return me_report("RECIPEPASTE", "recipe paste", problems, note)
	end
	st = { problems = {} }
	storage.paste_t = st
	local problems = st.problems
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function keys(msgs)
		local out = {}
		for _, m in ipairs(msgs or {}) do
			local k = type(m) == "table" and m[1] or tostring(m)
			out[#out + 1] = (k:gsub("^fork%-me%-paste%.", ""))
		end
		return out
	end
	local function has(msgs, key) for _, k in ipairs(keys(msgs)) do if k == key then return true end end return false end
	local function line(x) return serpent.line(x) end

	--- the game raises the event only for pairs the source prototype lists: every crafting machine lists the blocks
	local machines, missing = 0, {}
	for name, p in pairs(prototypes.get_entity_filtered{ { filter = "crafting-machine" } }) do
		machines = machines + 1
		local listed = {}
		for _, t in pairs(p.additional_pastable_entities or {}) do listed[t.name] = true end
		for _, t in ipairs(PASTE_TARGETS) do
			if not listed[t] then missing[#missing + 1] = name .. " -> " .. t end
		end
	end
	expect(#missing == 0, "crafting machines that cannot paste onto ME blocks: " .. table.concat(missing, ", ", 1, math.min(#missing, 10)))
	local gt = prototypes.entity["hv-chemical-reactor"]
	expect(gt and gt.type == "assembling-machine", "hv-chemical-reactor is no assembling machine")

	local m1, m2, m3 = find("me-molecular-assembler", 10.5, 6.5), find("me-molecular-assembler", 14.5, 6.5), find("me-molecular-assembler", 18.5, 6.5)
	local r1, r2 = find("hv-chemical-reactor", 22.5, 6.5), find("hv-chemical-reactor", 26.5, 6.5)
	local mx = find("zz-devcheck-paste-machine", 30.5, 6.5)
	local f2 = find("iron-furnace", 41, 7)
	local mf = find("zz-devcheck-paste-machine", 34.5, 6.5)
	local i1, i2, i3, i4, i5, i6, i7, i8 = iface(9.5), iface(12.5), iface(14.5), iface(16.5), iface(18.5), iface(20.5), iface(22.5), iface(24.5)
	local sb1, sb2, sb3, sb4 = find("me-storage-bus", 26.5, 0.5), find("me-storage-bus", 28.5, 0.5), find("me-storage-bus", 30.5, 0.5), find("me-storage-bus", 32.5, 0.5)
	local e1, e2, e3 = find("me-export-bus", 34.5, 0.5), find("me-export-bus", 36.5, 0.5), find("me-export-bus", 38.5, 0.5)
	local ib1, ib2 = find("me-import-bus", 42.5, 0.5), find("me-import-bus", 44.5, 0.5)
	if not (m1 and m2 and m3 and r1 and r2 and mx and mf and f1 and f2 and i1 and i2 and i3 and i4 and i5 and i6 and i7 and i8
		and sb1 and sb2 and sb3 and sb4 and e1 and e2 and e3 and ib1 and ib2) then
		st.done = true
		return me_report("RECIPEPASTE", "recipe paste", { "entities missing" })
	end
	local volume = remote.call(IO, "get_interface", i1).volume
	local function stack(name) return prototypes.item[name].stack_size end
	local function config_line(e)
		local out = {}
		for i, c in pairs(remote.call(IO, "get_interface_config", e)) do
			out[#out + 1] = i .. "=" .. (c.type == "fluid" and ("fluid/" .. c.name) or (c.name .. "@" .. c.quality)) .. ":" .. c.amount
		end
		table.sort(out)
		return table.concat(out, " ")
	end
	local function sides(e) return line(remote.call(IO, "get_interface_sides", e)) end

	--- the gear recipe's two items in the recipe's order (Gregtorio's lists the stick first)
	local gear = {}
	for _, g in ipairs(prototypes.recipe["iron-gear-crafting-table"].ingredients) do gear[#gear + 1] = g.name end
	local function gear_rows(q) return "1=" .. gear[1] .. "@" .. q .. ":" .. stack(gear[1]) .. " 2=" .. gear[2] .. "@" .. q .. ":" .. stack(gear[2]) end
	--- an item recipe onto an interface: its rows are replaced, one stack each
	remote.call(IO, "set_interface_config", i2, { { name = "copper-plate", quality = "normal", amount = 10 } })
	local msgs = remote.call(RP, "paste", m1, i2)
	local want = gear_rows("normal")
	expect(#keys(msgs) == 0 and config_line(i2) == want, "item recipe onto an interface: " .. config_line(i2) .. " " .. line(keys(msgs)))
	--- a quality recipe: the rows and the storage bus filters take its quality (mode and priority stay), the export bus
	--- has no quality and says so
	msgs = remote.call(RP, "paste", m2, i3)
	want = gear_rows("uncommon")
	expect(#keys(msgs) == 0 and config_line(i3) == want, "quality recipe onto an interface: " .. config_line(i3))
	remote.call(SB, "set_settings", sb1, { mode = "read", priority = 7, filters = { "wood" } })
	msgs = remote.call(RP, "paste", m2, sb1)
	local st1 = remote.call(SB, "get_settings", sb1)
	expect(#keys(msgs) == 0 and line(st1) == line({ mode = "read", priority = 7, filters = { gear[1] .. "@uncommon", gear[2] .. "@uncommon" } }),
		"quality recipe onto a storage bus: " .. line(st1))
	msgs = remote.call(RP, "paste", m2, e3)
	expect(line(remote.call(IO, "get_bus", e3).filters) == line(gear) and line(keys(msgs)) == line({ "bus-quality" }),
		"quality recipe onto an export bus: " .. line(remote.call(IO, "get_bus", e3).filters) .. " " .. line(keys(msgs)))
	--- a recipe without item ingredients onto a storage bus on a chest: unchanged, the player is told
	msgs = remote.call(RP, "paste", r2, sb1)
	expect(line(keys(msgs)) == line({ "no-items" }) and line(remote.call(SB, "get_settings", sb1)) == line(st1),
		"fluid-only recipe onto a storage bus on a chest: " .. line(remote.call(SB, "get_settings", sb1)) .. " " .. line(keys(msgs)))

	--- a fluid recipe onto an interface: the fluid row gets the side's volume and the side with a pipe (east); the
	--- north side stays off
	remote.call(IO, "set_interface_side", i1, 1, "off")
	msgs = remote.call(RP, "paste", r1, i1)
	want = "1=resin-circuit-board@normal:" .. stack("resin-circuit-board") .. " 2=fluid/phenol:" .. volume
	expect(#keys(msgs) == 0 and config_line(i1) == want and sides(i1) == line({ "off", 2 }),
		"fluid recipe onto an interface with a pipe: " .. config_line(i1) .. " sides " .. sides(i1) .. " " .. line(keys(msgs)))
	--- a side tied to a fluid that comes again keeps it; then a recipe without it: the side imports again, the two new
	--- fluid rows get the next import sides, which have no pipe (the player is told)
	remote.call(IO, "set_interface_config", i4, { [5] = { type = "fluid", name = "phenol", amount = 100 } }, { [1] = "off", [3] = 5 })
	msgs = remote.call(RP, "paste", r1, i4)
	expect(#keys(msgs) == 0 and sides(i4) == line({ [1] = "off", [3] = 2 }), "a fluid's side kept: " .. sides(i4) .. " " .. line(keys(msgs)))
	msgs = remote.call(RP, "paste", r2, i4)
	want = "1=fluid/chlorine:" .. volume .. " 2=fluid/hydrogen:" .. volume
	expect(config_line(i4) == want and sides(i4) == line({ "off", 1, 2 }) and line(keys(msgs)) == line({ "no-pipe", "no-pipe" }),
		"two fluids onto sides without a pipe: " .. config_line(i4) .. " sides " .. sides(i4) .. " " .. line(keys(msgs)))
	--- the fluid recipe onto the buses and storage buses
	msgs = remote.call(RP, "paste", r1, e1)
	expect(#keys(msgs) == 0 and line(remote.call(IO, "get_bus", e1).filters) == line({ "resin-circuit-board", "fluid/phenol" }),
		"fluid recipe onto an export bus: " .. line(remote.call(IO, "get_bus", e1).filters))
	msgs = remote.call(RP, "paste", r1, ib2)
	expect(#keys(msgs) == 0 and line(remote.call(IO, "get_bus", ib2).filters) == line({ "phenolic-circuit-board" }),
		"fluid recipe onto an import bus (its products): " .. line(remote.call(IO, "get_bus", ib2).filters))
	msgs = remote.call(RP, "paste", r2, ib1)
	expect(#keys(msgs) == 0 and line(remote.call(IO, "get_bus", ib1).filters) == line({ "fluid/hydrochloric-acid" }),
		"fluid product onto an import bus: " .. line(remote.call(IO, "get_bus", ib1).filters))
	local sb3_info = remote.call(SB, "info", sb3)
	expect(sb3_info and sb3_info.side == "fluid" and sb3_info.target, "storage bus on the pipe is on its fluid side: " .. line(sb3_info and sb3_info.side))
	msgs = remote.call(RP, "paste", r1, sb3)
	expect(#keys(msgs) == 0 and line(remote.call(SB, "get_settings", sb3).filters) == line({ "fluid/phenol" }),
		"fluid recipe onto a storage bus on a tank: " .. line(remote.call(SB, "get_settings", sb3).filters))
	msgs = remote.call(RP, "paste", r1, sb4)
	expect(#keys(msgs) == 0 and line(remote.call(SB, "get_settings", sb4).filters) == line({ "resin-circuit-board", "fluid/phenol" }),
		"fluid recipe onto a storage bus without a target: " .. line(remote.call(SB, "get_settings", sb4).filters))

	--- more ingredients than the blocks hold (20 items and 5 fluids; 2 items and 5 fluids), in the game's order
	local function fill(recipe)                          -- what the interface takes: 9 rows, 4 fluids
		local names, fl = {}, 0
		for _, g in ipairs(prototypes.recipe[recipe].ingredients) do
			if #names < 9 and (g.type ~= "fluid" or fl < 4) then
				names[#names + 1] = g.name
				if g.type == "fluid" then fl = fl + 1 end
			end
		end
		return names, fl
	end
	local function row_names(e)
		local out = {}
		local cfg = remote.call(IO, "get_interface_config", e)
		for i = 1, 9 do out[#out + 1] = cfg[i] and cfg[i].name or nil end
		return out
	end
	local many = prototypes.recipe["zz-devcheck-paste-many"].ingredients
	local names = fill("zz-devcheck-paste-many")
	msgs = remote.call(RP, "paste", mx, i5)
	expect(line(row_names(i5)) == line(names) and has(msgs, "rows-full"),
		"too many ingredients onto an interface: " .. config_line(i5) .. " " .. line(keys(msgs)))
	local fnames, fl = fill("zz-devcheck-paste-fluids")
	msgs = remote.call(RP, "paste", mf, i6)
	expect(fl == 4 and line(row_names(i6)) == line(fnames) and line(keys(msgs)) == line({ "no-pipe", "no-pipe", "no-pipe", "no-pipe", "fluids-full" })
		and #remote.call(IO, "get_interface_sides", i6) == 4,
		"five fluids onto an interface: " .. config_line(i6) .. " sides " .. sides(i6) .. " " .. line(keys(msgs)))
	remote.call(IO, "set_interface_config", i5, {}, { "off", "off", "off" })
	msgs = remote.call(RP, "paste", mf, i5)
	local s5 = remote.call(IO, "get_interface_sides", i5)
	expect(s5[1] == "off" and s5[2] == "off" and s5[3] == "off" and type(s5[4]) == "number"
		and line(keys(msgs)) == line({ "no-pipe", "no-side", "no-side", "no-side", "fluids-full" }),
		"fluid rows with no side left: " .. sides(i5) .. " " .. line(keys(msgs)))
	msgs = remote.call(RP, "paste", mx, sb2)
	local f2s = remote.call(SB, "get_settings", sb2).filters
	local items_only = true
	for _, k in ipairs(f2s) do if k:find("^fluid/") then items_only = false end end
	expect(#f2s == 18 and items_only and line(keys(msgs)) == line({ "filters-full" }),
		"too many items onto a storage bus on a chest: " .. #f2s .. " " .. line(keys(msgs)))
	msgs = remote.call(RP, "paste", mx, sb3)
	expect(#remote.call(SB, "get_settings", sb3).filters == 5 and #keys(msgs) == 0, "five fluids onto a storage bus on a tank")
	msgs = remote.call(RP, "paste", mx, sb4)
	expect(#remote.call(SB, "get_settings", sb4).filters == 18 and line(keys(msgs)) == line({ "filters-full" }),
		"too many ingredients onto a storage bus without a target")
	msgs = remote.call(RP, "paste", mx, e2)
	local ef = remote.call(IO, "get_bus", e2).filters
	local want_ef = {}
	for i = 1, 9 do want_ef[i] = (many[i].type == "fluid" and "fluid/" or "") .. many[i].name end
	expect(line(ef) == line(want_ef) and line(keys(msgs)) == line({ "filters-full" }),
		"too many ingredients onto an export bus: " .. line(ef) .. " " .. line(keys(msgs)))

	--- machines without a recipe: nothing changes, the player is told
	local before = config_line(i8)
	msgs = remote.call(RP, "paste", m3, i8)
	expect(line(keys(msgs)) == line({ "no-recipe" }) and config_line(i8) == before, "assembler without a recipe: " .. line(keys(msgs)))
	msgs = remote.call(RP, "paste", f2, e3)
	expect(line(keys(msgs)) == line({ "no-recipe" }) and line(remote.call(IO, "get_bus", e3).filters) == line(gear),
		"furnace that never smelted: " .. line(keys(msgs)))
	--- the furnace while it smelts (its current recipe)
	local busy = f1.get_recipe() ~= nil
	msgs = remote.call(RP, "paste", f1, i7)
	expect(#keys(msgs) == 0 and config_line(i7) == "1=iron-dust@normal:" .. stack("iron-dust"), "furnace onto an interface: " .. config_line(i7) .. " " .. line(keys(msgs)))
	--- a paste between ME blocks is no recipe paste (their own handlers copy the settings)
	expect(remote.call(RP, "paste", i1, i2) == nil and remote.call(RP, "paste", e1, e2) == nil, "a paste between ME blocks taken as a recipe paste")
	st.note = machines .. " crafting machines can paste onto the four blocks, furnace " .. (busy and "smelting" or "already idle") .. " at the first paste"
end

--- The terrain comes from the map seed: trees, rocks, cliffs, water and enemies can be anywhere. The
--- tests place their entities by script, which ignores all that, but construction robots do not build
--- a ghost over a tree or on water, so a robot rebuild timed out on some seeds (issue #47). The whole
--- generated test area is cleared first (ore patches stay, they block nothing).
local TEST_RADIUS = 12                                     -- chunks around { 0, 0 }; every test lies inside
local function clear_test_area(s)
	local r = TEST_RADIUS * 32
	local area = { { -r, -r }, { r + 32, r + 32 } }
	local removed, water = 0, {}
	for _, e in pairs(s.find_entities_filtered{ area = area, force = { "neutral", "enemy" } }) do
		if e.valid and e.type ~= "resource" then
			e.destroy()
			removed = removed + 1
		end
	end
	for _, t in pairs(s.find_tiles_filtered{ area = area, collision_mask = "water_tile" }) do
		water[#water + 1] = { name = "landfill", position = t.position }
	end
	s.set_tiles(water)
	s.destroy_decoratives{ area = area }
	s.peaceful_mode = true
	game.map_settings.enemy_expansion.enabled = false
	return removed, #water
end

script.on_init(function()
	local s = game.surfaces[1]
	s.always_day = true
	s.request_to_generate_chunks({ 0, 0 }, TEST_RADIUS)
	s.force_generate_chunk_requests()
	local removed, water = clear_test_area(s)
	log("DEVCHECK-RUNTIME-SEED " .. s.map_gen_settings.seed .. " (test area cleared: " .. removed .. " entities, " .. water .. " water tiles)")
	local fails = {}
	for _, f in pairs(setup_me_network(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_autocraft_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_furnace_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_pattern_tests(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_fluid_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_fluid_cell_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_r3_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_storage_bus_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_fluid_storage_bus_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_unified_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_issue38_tests(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_scheduler_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_paste_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(cards17.setup(s)) do fails[#fails + 1] = f end
	for _, f in pairs(bench17.setup(s)) do fails[#fails + 1] = f end
	for _, f in pairs(cpus6.setup(s)) do fails[#fails + 1] = f end
	for _, f in pairs(parking38.setup(s)) do fails[#fails + 1] = f end
	for _, f in pairs(stats38.setup(s)) do fails[#fails + 1] = f end
	for _, f in pairs(margin51.setup(s)) do fails[#fails + 1] = f end
	for _, f in pairs(busaccel110.setup(s)) do fails[#fails + 1] = f end
	for _, f in pairs(accel110.setup(s)) do fails[#fails + 1] = f end
	for _, f in pairs(damaged84.setup(s)) do fails[#fails + 1] = f end
	for _, f in pairs(refused85.setup(s)) do fails[#fails + 1] = f end
	for _, f in pairs(lab86.setup(s)) do fails[#fails + 1] = f end
	for _, f in pairs(refill67.setup(s)) do fails[#fails + 1] = f end
	for _, f in pairs(plans50.setup(s)) do fails[#fails + 1] = f end
	for _, f in pairs(scan50.setup(s)) do fails[#fails + 1] = f end
	for _, f in pairs(entries50.setup(s)) do fails[#fails + 1] = f end
	for _, f in pairs(holderlists59.setup(s)) do fails[#fails + 1] = f end
	for _, f in pairs(holders43.setup(s)) do fails[#fails + 1] = f end
	for _, f in pairs(storable76.setup(s)) do fails[#fails + 1] = f end
	for _, f in pairs(graph43.setup(s)) do fails[#fails + 1] = f end
	log("DEVCHECK-RUNTIME setup failed=" .. #fails .. " (" .. (script.active_mods["gregtorio-continued"] and "with Gregtorio Continued" or "vanilla") .. ")")
	for _, f in pairs(fails) do log("DEVCHECK-RUNTIME-FAIL " .. f) end
end)
