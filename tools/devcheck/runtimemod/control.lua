--- Places every assembling machine that has an item, gives it a recipe and power, then lets
--- the benchmark run the map. Any runtime error in Gregtorio's scripts or the entities fails
--- the run. Results are logged as DEVCHECK-RUNTIME lines.
--- ME network core (issue #68, prototypes/120-fork-ae2.lua, scripts/fork-me-network.lua, fork-me-io.lua,
--- fork-me-terminal.lua): cable graph and power, storage cells, the terminal's functions, interface and buses
--- (me_graph_test, me_cells_test, me_terminal_test, me_io_test). The ME networks of the other tests are laid
--- out as before and connected by the network's cable router (me_connect).
--- Autocrafting (prototypes/121-fork-ae2-autocrafting.lua, scripts/fork-me-autocraft.lua): a network
--- with a crafting CPU, two Molecular Assemblers with pattern providers (iron plate + 2 iron sticks ->
--- gear, gear + plate -> transport belt) and raw materials in a drive. Job 1 crafts belts through the
--- two-level chain, job 2 asks for more than the raw materials allow and must not start, job 3 is
--- queued behind job 1 (one CPU) and cancelled; its items must come back.
--- Furnace patterns (issue #27): in its own network, a fresh iron furnace next to a pattern provider
--- with a chosen recipe is a pattern at once and smelts a job into storage; a furnace without choice
--- and without a smelted recipe is counted as ignored ("no-recipe"). Settings paste, blueprint tags and
--- a revived ghost carry the choice.
--- Fluids (issue #68 step R2, prototypes/122-fork-ae2-fluids.lua, scripts/fork-me-fluids.lua): a network with a
--- drive of four 1k fluid cells, an import interface with a tank of chlorine connected to it, an export interface,
--- a roboport with construction robots, and pattern machines with fluid recipes (chemical reactors, an extractor).
--- Checks the import and export totals, a fluid cell taken out (its fluid in the tags), stored in the network and
--- put back, the drive mined by robots (cells with their fluid in the storage chest) and rebuilt, full cells, a
--- reported fluid shortfall, and jobs with a fluid ingredient, a fluid product and both. ME fluid cells
--- (fluid_cell_test): a mixed drive, tags, capacity, the terminal with fluids, the fluid buses, old fluid drive
--- items placed. The old fluid recovery is tested as the migration (migratemod).
--- Molds (prototypes/150-fork-molds.lua): an LV alloy smelter with a mold recipe must stop
--- without a mold, run with a mold in its mold slot and keep the mold there.
--- Endgame power (prototypes/136-fork-power.lua): a plasma turbine and a naquadah reactor under load
--- must burn their fuel and make power; the turbine's output hatch gets the cooled fluid.
--- Fuel check (issue #25): steam and the other generator's fuel stop a generator; the right fuel runs it.
--- Turbine tiers (issue #34): the UHV to UXV plasma turbines under an overload give exactly four amps of
--- their tier and return the cooled fluid of the plasma they burnt.
--- Recipes of issue #35: grades 7 and 8, FPIC/APIC wafers and chips, complex SMDs and the recipes that
--- use them are crafted once each (setup_recipe_test).
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
		expect(u1 and u2 and remote.call(NET, "underground_link", u1) and remote.call(NET, "underground_link", u2),
			"the paired underground ends show no line")
		--- a cable over the run and one beside an end belong to other networks
		local over = put("me-cable", 3, 0)
		local beside = put("me-cable", 1, 1)
		expect(over and not same(over, ud1), "a cable over the underground run joined it")
		expect(beside and not same(beside, ud1), "a cable beside an underground end joined it")
		--- removing an end splits, placing it again joins
		u2.destroy{ raise_destroy = true }
		expect(not same(ud1, ud2), "still connected without the second end")
		expect(not remote.call(NET, "underground_link", u1), "the line stayed after removing the second end")
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
		expect(far1 and far2 and remote.call(NET, "underground_partner", far1) == nil, "ends 11 tiles apart paired")
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
			--- the graph rebuild (on_configuration_changed) keeps the underground pairs and their side rule
			local u = st.underground
			if u then
				remote.call(NET, "rebuild")
				expect(same(u.ud1, u.ud2) and remote.call(NET, "underground_partner", u.u1) == u.u2.unit_number,
					"the underground pair is lost after the graph rebuild")
				expect(not same(u.over, u.ud1) and not same(u.beside, u.ud1), "the graph rebuild joined cables over or beside the run")
				expect(remote.call(NET, "underground_link", u.u1), "no line after the graph rebuild")
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
		expect(#card == 1 and card[1].stack.name == "acceleration-card", "the old drive's acceleration card was not given back")
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
	expect(n == nil and why == "cannot-store", "a blueprint: " .. tostring(n) .. " " .. tostring(why))
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

--- Victory (scripts/fork-victory.lua): researching `victory` must win the game, and go on.
--- Winning stops the scripts of the benchmark run (no player to continue), so this runs last: as soon
--- as every other test has reported, at the latest at tick VICTORY_DEADLINE (a test still running
--- then is reported as unfinished). Checked from the 10-tick handler below.
local VICTORY_DEADLINE = 1450
local function tests_running()
	local running = {}
	local function check(done, name) if not done then running[#running + 1] = name end end
	check(storage.me_graph and storage.me_graph.done, "ME graph")
	check(storage.me_cells and storage.me_cells.done, "ME cells")
	check(storage.me_term and storage.me_term.done, "ME terminal")
	check(storage.me_io and storage.me_io.done, "ME import/export")
	check(storage.mold_done, "mold")
	check(storage.autocraft and storage.autocraft.done, "autocrafting")
	check(storage.furnace and storage.furnace.done, "furnace patterns")
	check(storage.fluids and storage.fluids.done, "fluids")
	check(storage.fluid_cells and storage.fluid_cells.done, "ME fluid cells")
	check(storage.me_r3 and storage.me_r3.done, "ME partitions and windows")
	check(storage.power_checked, "power")
	check(storage.fuel and storage.fuel.done, "fuel check")
	check(storage.cooled and storage.cooled.done, "cooled fluid")
	check(storage.tiers and storage.tiers.done, "turbine tiers")
	check(storage.recipe_test and storage.recipe_test.done, "recipes of issue #35")
	check(storage.maint38 and storage.maint38.done, "level maintainer")
	check(storage.tiers38 and storage.tiers38.done, "crafting CPU tiers")
	check(storage.circuit38 and storage.circuit38.done, "circuit interface")
	check(storage.settings38 and storage.settings38.done, "settings copy")
	return running
end

function victory_test()
	if storage.victory_checked then return end
	local running = tests_running()
	if #running > 0 and game.tick < VICTORY_DEADLINE then return end
	storage.victory_checked = true
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	expect(#running == 0, "tests still running at tick " .. game.tick .. ": " .. table.concat(running, ", "))
	local ok, err = pcall(function() game.forces.player.technologies["victory"].researched = true end)
	expect(ok, "victory test: " .. tostring(err))
	--- (can_continue cannot be read before a player chooses to go on; the script passes it, see fork-victory.lua)
	expect(game.finished, "victory test: researching `victory` did not finish the game")
	--- Phase 6b: after victory, the post-victory technologies (MAX science) must be researchable. `victory` is
	--- infinite, so it is no prerequisite; their prerequisites are researched by script, then the engine must
	--- accept `godforge-upgrades` (the infinite sink) in the research queue, and researching its first level
	--- must give the godforge's magmatter recipe its productivity and leave the godforge unlocked.
	local force = game.forces.player
	local seen = {}
	local function research_prerequisites(tech)
		for name, pre in pairs(tech.prerequisites) do
			if not seen[name] then
				seen[name] = true
				research_prerequisites(pre)
				if not pre.researched then pre.researched = true end
			end
		end
	end
	local upgrades = force.technologies["godforge-upgrades"]
	ok, err = pcall(function()
		research_prerequisites(upgrades)
		force.research_queue = { "godforge-upgrades" }
	end)
	expect(ok, "post-victory test: " .. tostring(err))
	local queued = force.research_queue[1]
	expect(queued and queued.name == "godforge-upgrades",
		"post-victory test: godforge-upgrades was not accepted for research (prerequisites not met)")
	force.research_queue = {}
	upgrades.researched = true
	expect(upgrades.level == 2, "post-victory test: godforge-upgrades is at level " .. upgrades.level .. ", not 2")
	local bonus = force.recipes["molten-magmatter-from-neutronium"].productivity_bonus
	expect(math.abs(bonus - 0.05) < 1e-6, "post-victory test: magmatter productivity " .. bonus .. ", not 0.05")
	expect(force.recipes["godforge"].enabled and force.technologies["max-materials"].enabled,
		"post-victory test: the godforge recipe is not unlocked")
	log("DEVCHECK-RUNTIME-POSTVICTORY " .. (#problems == 0 and "ok" or "failed") .. " (godforge-upgrades level 1, "
		.. (seen["victory"] and "victory is a prerequisite" or "after victory") .. ")")
	for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL " .. p) end
	log("DEVCHECK-RUNTIME-VICTORY " .. (#problems == 0 and "ok" or "failed") .. " (tick " .. game.tick .. ")")
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

		--- job 3: one CPU only, so it waits; cancelling gives everything back
		local plates3, sticks3 = count("iron-plate"), count("iron-stick")
		local id3 = remote.call("gregtorio-me-autocraft", "start", terminal, AC_ITEM, per_run)
		expect(id3, "job 3 did not start")
		if id3 then
			local j3 = remote.call("gregtorio-me-autocraft", "job", id3)
			expect(j3 and j3.status == "queued", "job 3 should wait for the CPU (status " .. tostring(j3 and j3.status) .. ")")
			expect(count("iron-plate") == plates3 - 2 and count("iron-stick") == sticks3 - 2, "job 3 did not reserve its items")
			remote.call("gregtorio-me-autocraft", "cancel", id3)
			st.job3, st.plates3, st.sticks3 = id3, plates3, sticks3
		end
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
		local j1, j3 = job_of(st.job1), st.job3 and job_of(st.job3)
		if j3 and j3.status == "cancelled" and not st.j3_checked then
			st.j3_checked = true
			--- the cancelled job's plates/sticks are back (job 1 keeps its own reservation)
			expect(count("iron-plate") == st.plates3 and count("iron-stick") == st.sticks3,
				"job 3 cancelled but items not returned: plates " .. count("iron-plate") .. "/" .. st.plates3 .. " sticks " .. count("iron-stick") .. "/" .. st.sticks3)
		end
		if j1 and (j1.status == "done" or j1.status == "failed") then
			expect(j1.status == "done", "job 1 ended as " .. j1.status)
			expect(st.j3_checked, "job 3 was never cancelled")
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
--- furnace patterns (issue #27): the recipe choice of a pattern provider
--------------------------------------------------------------------------------

local FU_X, FU_Y = -116, -220                          -- own network, above the machine grid
local FU_RECIPE, FU_ITEM, FU_INPUT, FU_AMOUNT = "iron-dust-smelter", "iron-ingot", "iron-dust", 2
local FU_PROVIDER_A = { FU_X + 16.5, FU_Y + 10.5 }     -- touches furnace A (west)
local FU_PROVIDER_B = { FU_X + 7.5, FU_Y + 10.5 }      -- touches furnace B (west)
local FU_GHOST = { FU_X + 20.5, FU_Y + 4.5 }

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
	local drive = me_drive(s, fails, "furnace test", FU_X + 8.5, FU_Y + 6.5, { [FU_INPUT] = 10 })
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
		storage.furnace = { started = game.tick }
		st = storage.furnace
		if not (terminal and net and pa and pb and furnace_a) then expect(false, "entities missing") return finish_test() end
		--- fresh furnaces: no recipe, no previous recipe; both are counted as ignored
		expect(furnace_a.previous_recipe == nil and furnace_a.get_recipe() == nil, "furnace A is not fresh")
		local ignored = remote.call(A, "ignored", terminal)
		expect(ignored["no-recipe"] == 2 and ignored.total == 2, "fresh furnaces ignored: " .. serpent.line(ignored))
		expect(not craftable()[FU_ITEM], "a fresh furnace became a pattern")
		--- the GUI's options: researched recipes of the furnace's categories only
		local options = remote.call(A, "recipe_options", pa)
		local listed = {}
		for _, n in pairs(options) do listed[n] = true end
		expect(not listed[FU_RECIPE], "the options list a recipe that is not researched")
		terminal.force.recipes[FU_RECIPE].enabled = true
		options = remote.call(A, "recipe_options", pa)
		listed = {}
		for _, n in pairs(options) do
			listed[n] = true
			local r = terminal.force.recipes[n]
			expect(r.enabled and prototypes.recipe[n].category == "smelting", "option " .. n .. " is not a researched smelting recipe")
		end
		expect(listed[FU_RECIPE], "the options miss " .. FU_RECIPE .. ": " .. serpent.line(options))
		--- choose the recipe (the GUI's code path): a pattern right away
		expect(remote.call(A, "set_recipe", pa, FU_RECIPE), "set_recipe failed")
		expect(remote.call(A, "get_recipe", pa) == FU_RECIPE, "choice not stored")
		expect(craftable()[FU_ITEM], "the furnace with a chosen recipe is no pattern")
		ignored = remote.call(A, "ignored", terminal)
		expect(ignored["no-recipe"] == 1 and ignored.total == 1, "ignored after the choice: " .. serpent.line(ignored))
		local per_run = 0
		for _, i in pairs(prototypes.recipe[FU_RECIPE].ingredients) do if i.name == FU_INPUT then per_run = i.amount end end
		local yield = 0
		for _, p in pairs(prototypes.recipe[FU_RECIPE].products) do if p.name == FU_ITEM then yield = p.amount end end
		st.runs = math.ceil(FU_AMOUNT / yield)
		st.input = st.runs * per_run
		st.output = st.runs * yield
		local plan = remote.call(A, "plan", terminal, FU_ITEM, FU_AMOUNT)
		expect(plan and plan.ok and plan.steps == 1 and plan.runs == st.runs, "furnace plan: " .. serpent.line(plan))
		st.job = remote.call(A, "start", terminal, FU_ITEM, FU_AMOUNT)
		expect(st.job, "furnace job did not start")
		if #problems > 0 then return finish_test() end
		return
	end
	if st.done then return end

	local j = remote.call(A, "job", st.job)
	if j and (j.status == "done" or j.status == "failed" or j.status == "cancelled") then
		expect(j.status == "done", "furnace job ended as " .. j.status .. " " .. serpent.line(j))
		expect(count(FU_ITEM) == st.output, "ingots in storage: " .. count(FU_ITEM) .. ", expected " .. st.output)
		expect(count(FU_INPUT) == 10 - st.input, "dust left: " .. count(FU_INPUT) .. ", expected " .. (10 - st.input))
		expect(next(j.pool) == nil, "furnace job keeps items: " .. serpent.line(j.pool))
		expect(furnace_a.get_inventory(defines.inventory.furnace_source).is_empty()
			and furnace_a.get_inventory(defines.inventory.furnace_result).is_empty(), "furnace A is not empty after the job")
		--- settings paste: provider B takes the choice, furnace B becomes a pattern too
		remote.call(A, "paste", pa, pb)
		expect(remote.call(A, "get_recipe", pb) == FU_RECIPE, "paste did not copy the choice")
		local ignored = remote.call(A, "ignored", terminal)
		expect((ignored.total or 0) == 0, "ignored after the paste: " .. serpent.line(ignored))
		--- without a choice the recipe furnace A smelted last (previous_recipe) keeps it a pattern
		remote.call(A, "set_recipe", pa, nil)
		ignored = remote.call(A, "ignored", terminal)
		expect((ignored.total or 0) == 0, "furnace A without choice lost its last smelted recipe: " .. serpent.line(ignored))
		remote.call(A, "set_recipe", pa, FU_RECIPE)
		--- blueprint: the provider's choice becomes an entity tag
		local inv = game.create_inventory(1)
		inv.insert{ name = "blueprint" }
		local bp = inv[1]
		local mapping = bp.create_blueprint{ surface = s, force = "player",
			area = { { FU_PROVIDER_A[1] - 0.4, FU_PROVIDER_A[2] - 0.4 }, { FU_PROVIDER_A[1] + 0.4, FU_PROVIDER_A[2] + 0.4 } } }
		remote.call(A, "tag_blueprint", bp, mapping)
		local tagged = false
		for index, e in pairs(mapping or {}) do
			if e.name == "me-pattern-provider" then tagged = bp.get_blueprint_entity_tag(index, "fork_ae2_recipe") == FU_RECIPE end
		end
		expect(tagged, "the blueprint does not carry the choice")
		inv.destroy()
		--- a ghost with the tag is revived: the new provider has the choice
		local ghost = s.create_entity{ name = "entity-ghost", inner_name = "me-pattern-provider", position = FU_GHOST,
			force = "player", tags = { fork_ae2_recipe = FU_RECIPE } }
		local _, revived = ghost.revive{ raise_revive = true }
		expect(revived and remote.call(A, "get_recipe", revived) == FU_RECIPE, "a revived ghost lost the choice")
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

script.on_nth_tick(10, function()
	if not (storage.me_graph and storage.me_graph.done) then me_graph_test() end
	if not (storage.me_cells and storage.me_cells.done) then me_cells_test() end
	me_terminal_test()
	me_io_test()
	if not (storage.autocraft and storage.autocraft.done) then autocraft_test() end
	if not (storage.furnace and storage.furnace.done) then furnace_test() end
	if not (storage.fluids and storage.fluids.done) then fluid_test() end
	fluid_cell_test()
	me_r3_test()
	if not (storage.fuel and storage.fuel.done) then fuel_test() end
	if not (storage.cooled and storage.cooled.done) then cooled_test() end
	if not (storage.tiers and storage.tiers.done) then tier_test() end
	if not (storage.recipe_test and storage.recipe_test.done) then recipe_test() end
	if not (storage.maint38 and storage.maint38.done) then maintainer_test() end
	if not (storage.tiers38 and storage.tiers38.done) then cpu_tier_test() end
	if not (storage.circuit38 and storage.circuit38.done) then circuit_test() end
	settings_test()
	victory_test()
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
	iface_a = { "me-fluid-interface", 2.5, FL_Y + 4.5 },
	iface_b = { "me-fluid-interface", 5.5, FL_Y + 4.5 },
	tank = { "storage-tank", 3.5, FL_Y + 6.5 },           -- its north connection meets interface A
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
	local cpu = place("me-crafting-cpu", 10, FL_Y)
	local term = place(FL.terminal[1], FL.terminal[2], FL.terminal[3])
	local fdrive = me_drive(s, fails, "fluids", FL_DRIVE_POS[1], FL_DRIVE_POS[2], {}, "1k", true)
	local idrive = me_drive(s, fails, "fluids", FL.idrive[2], FL.idrive[3],
		{ ["raw-silicon"] = FL_SILICON, ["tin-ingot"] = FL_TIN, ["resin-circuit-board"] = FL_BOARDS })
	place(FL.chest[1], FL.chest[2], FL.chest[3])
	place(FL.store[1], FL.store[2], FL.store[3])
	--- import: a tank connected to interface A (default mode is import); export: interface B stands alone.
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
	return fails
end

function fluid_test()
	local s = game.surfaces[1]
	local F, A = "gregtorio-me-fluids", "gregtorio-me-autocraft"
	local function ent(def) return s.find_entity(def[1], { def[2], def[3] }) end
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
		expect(#a.fluidbox.get_connections(1) > 0, "interface A is not connected to the tank")
		expect(#b.fluidbox.get_connections(1) == 0, "interface B must stand alone")
		local capacity, used = remote.call(F, "capacity", terminal)   -- the import may have run already
		expect(capacity == 4 * 1024 * 8 and used >= 0 and used <= (8 + math.ceil(FL_TANK_AMOUNT / 8)) * 8, "fluid capacity " .. tostring(capacity) .. "/" .. tostring(used))
		local ia = remote.call(F, "get_interface", a)
		expect(ia and ia.mode == "import", "interface A default mode " .. tostring(ia and ia.mode))
		expect(remote.call(F, "set_interface", b, "export", FL_FLUID, FL_EXPORT_LEVEL), "set_interface failed")
		local ib = remote.call(F, "get_interface", b)
		expect(ib and ib.mode == "export" and ib.fluid == FL_FLUID and ib.level == FL_EXPORT_LEVEL, "interface B settings " .. serpent.line(ib))
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
	local function in_pipes() return tank.get_fluid_count(FL_FLUID) + a.get_fluid_count(FL_FLUID) end
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
		if in_pipes() < 0.01 and near(b.get_fluid_count(FL_FLUID), FL_EXPORT_LEVEL) then
			local stored, in_b = count(FL_FLUID), b.get_fluid_count(FL_FLUID)
			expect(near(stored + in_b, FL_TANK_AMOUNT), "fluid not conserved: network " .. stored .. " + export " .. in_b)
			local capacity, used = remote.call(F, "capacity", terminal)
			expect(used == (8 + math.ceil(stored / 8)) * 8, "used " .. used .. " is not the bytes of " .. stored .. " units")
			local totals = remote.call(F, "totals", terminal)
			expect(near(totals[FL_FLUID] or 0, stored), "totals differ from count")
			local ib = remote.call(F, "get_interface", b)
			expect(ib and ib.status == "ok", "interface B status " .. tostring(ib and ib.status))
			st.import_ticks = game.tick - st.started
			if #problems > 0 then return finish_test() end
			return next_phase("export-hold")
		end
		timeout_after(300, "import from the tank")
	elseif phase == "export-hold" then
		--- export never overfills and never takes back
		if game.tick >= st.phase_tick + 60 then
			expect(near(b.get_fluid_count(FL_FLUID), FL_EXPORT_LEVEL), "export level drifted to " .. b.get_fluid_count(FL_FLUID))
			expect(near(count(FL_FLUID), FL_TANK_AMOUNT - FL_EXPORT_LEVEL), "network changed while holding: " .. count(FL_FLUID))
			remote.call(F, "set_interface", b, "import")
			return next_phase("reimport")
		end
	elseif phase == "reimport" then
		if b.get_fluid_count(FL_FLUID) < 0.01 then
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
				.. " (tank " .. in_pipes() .. ", B " .. b.get_fluid_count(FL_FLUID) .. ")")
			if #problems > 0 then return finish_test() end
			--- full cells: the import stops and keeps the fluid in the tank, an export of a fluid the
			--- network does not hold reports it
			local room = remote.call(NET, "can_insert_fluid", terminal, FL_FLUID, 1e9)
			expect(near(count(FL_FLUID) + room, FL_FULL), "room for chlorine " .. room .. ", expected " .. (FL_FULL - count(FL_FLUID)))
			expect(near(remote.call(F, "insert", terminal, FL_FLUID, room), room), "could not fill the cells")
			expect(near(count(FL_FLUID), FL_FULL), "cells not full: " .. count(FL_FLUID))
			expect(remote.call(F, "insert", terminal, FL_FLUID, 10) == 0, "full cells took fluid")
			tank.insert_fluid{ name = FL_FLUID, amount = 500 }
			remote.call(F, "set_interface", b, "export", "water", FL_EXPORT_LEVEL)
			return next_phase("full")
		end
		timeout_after(600, "robots building the drive from the ghost (" .. robot_report(s, FL_DRIVE_POS, FL_DRIVE) .. ")")
	elseif phase == "full" then
		if game.tick >= st.phase_tick + 40 then
			local ia, ib = remote.call(F, "get_interface", a), remote.call(F, "get_interface", b)
			expect(ia and ia.status == "full", "import into full drives: status " .. tostring(ia and ia.status))
			expect(near(in_pipes(), 500), "fluid left the tank although the drives are full: " .. in_pipes())
			expect(near(count(FL_FLUID), FL_FULL), "network changed while full: " .. count(FL_FLUID))
			expect(ib and ib.status == "empty-network", "export of a missing fluid: status " .. tostring(ib and ib.status))
			expect(b.get_fluid_count("water") == 0, "export interface got water from nowhere")
			expect(near(remote.call(F, "remove", terminal, FL_FLUID, 30000), 30000), "could not take fluid out")
			remote.call(F, "set_interface", b, "import")
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
			--- a pattern machine mined by robots while it holds the job's fluid: the fluid returns with the pool
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
	--- the import bus faces tank 1 (3x3 below it), the export bus tank 2
	me_place(s, fails, "fluid cells", "me-fluid-import-bus", FX + 8.5, FY + 0.5, { direction = defines.direction.south })
	me_place(s, fails, "fluid cells", "me-fluid-export-bus", FX + 11.5, FY + 0.5, { direction = defines.direction.south })
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
	local ib, eb = find("me-fluid-import-bus", 8.5, 0.5), find("me-fluid-export-bus", 11.5, 0.5)
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
	expect(bf and serpent.line(bf.filters) == serpent.line({ "water" }), "fluid bus filters " .. serpent.line(bf))
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
	for _, name in pairs({ "me-import-bus", "me-export-bus", "me-fluid-import-bus", "me-fluid-export-bus", "me-network-interface",
		"me-pattern-provider", "me-crafting-cpu", "me-level-maintainer", "me-circuit-interface", "me-fluid-interface" }) do
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
	for _, name in pairs({ "me-import-bus", "me-export-bus", "me-fluid-import-bus", "me-fluid-export-bus", "me-network-interface",
		"me-pattern-provider", "me-crafting-cpu", "me-level-maintainer", "me-circuit-interface", "me-fluid-interface" }) do
		blocks[name] = s.find_entity(name, { x + 0.5, RY + 6.5 })
		expect(blocks[name] and remote.call(GUI, "has_window", blocks[name]), "no window for " .. name)
		x = x + 4
	end
	for _, e in pairs({ d1, t, ctrl }) do expect(remote.call(GUI, "has_window", e), "no window for " .. e.name) end
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
	expect(pd and pd.machines and pd.furnaces == 0, "provider_data " .. serpent.line(pd))
	local cpu = remote.call(GUI, "cpu_data", blocks["me-crafting-cpu"])
	expect(cpu and cpu.slots == 1 and #cpu.jobs == 0, "cpu_data " .. serpent.line(cpu))
	local maint = blocks["me-level-maintainer"]
	expect(remote.call(GUI, "set_maintainer_target", maint, { type = "item", name = "iron-plate" }), "set_maintainer_target")
	local md = remote.call(GUI, "maintainer_data", maint)
	expect(md and md.key == "iron-plate" and md.condition, "maintainer_data " .. serpent.line(md))
	remote.call(GUI, "set_maintainer_target", maint, { type = "virtual", name = "signal-A" })
	expect(remote.call(GUI, "maintainer_data", maint).key == nil, "a virtual signal as maintainer target")
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
	local fi = remote.call(GUI, "fluid_interface_data", blocks["me-fluid-interface"])
	expect(fi and fi.mode and fi.volume and fi.volume > 0, "fluid_interface_data " .. serpent.line(fi))
	local iface = blocks["me-network-interface"]
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
	local bus = blocks["me-export-bus"]
	remote.call(IO, "set_bus_filter", bus, 1, "iron-plate")
	remote.call(IO, "set_bus_filter", bus, 3, "copper-plate")
	local bd = remote.call(GUI, "bus_data", bus)
	expect(bd and serpent.line(bd.filters) == serpent.line({ "iron-plate", "copper-plate" }) and not bd.fluid and bd.max == 5, "bus_data " .. serpent.line(bd))
	remote.call(IO, "set_bus_filter", bus, 1, nil)
	expect(serpent.line(remote.call(GUI, "bus_data", bus).filters) == serpent.line({ "copper-plate" }), "bus filter removed")
	local fbd = remote.call(GUI, "bus_data", blocks["me-fluid-import-bus"])
	expect(fbd and fbd.fluid and fbd.import, "fluid bus_data " .. serpent.line(fbd))
	expect(remote.call(GUI, "key_of_elem", "item-with-quality", { name = "iron-plate", quality = "normal" }) == "iron-plate"
		and remote.call(GUI, "key_of_elem", "fluid", "water") == "fluid/water"
		and remote.call(GUI, "key_of_elem", "signal", { type = "virtual", name = "signal-A" }) == nil, "key_of_elem")

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
	inv.destroy()
	me_report("MER3", "ME partitions and windows", problems,
		"partitions, priorities, insert/extract order, drive blueprint/paste/clone, window data and set functions, terminal tabs")
end

--- Endgame power (prototypes/136-fork-power.lua, scripts/fork-power.lua): a LuV large plasma turbine
--- with helium plasma and a turbine output hatch next to it, and a UV large naquadah reactor with
--- naquadah based fuel MK1, each loaded by an electric energy interface that draws the generator's
--- full output. After 7 s both must have produced power and burnt fuel, and the hatch must hold the
--- cooled fluid (helium) for the plasma the turbine burnt (see the cooled fluid test below).
local PW_Y = 260                                        -- below the fluid test and its roboport area
local PW_TICK = 420
local PW = {
	turbine = { "luv-large-plasma-turbine", 1.5, PW_Y + 1.5, "helium-plasma", 100, 81.92e6 },
	hatch = { "turbine-output-hatch", 3.5, PW_Y + 1.5 },
	reactor = { "uv-large-naquadah-reactor", 42.5, PW_Y + 2.5, "naquadah-based-fuel-mk1", 10, 327.68e6 },
}

function setup_power_test(s)
	local fails = {}
	local function place(def)
		local ok, e = pcall(function()
			return s.create_entity{ name = def[1], position = { def[2], def[3] }, force = "player", raise_built = true }
		end)
		if not (ok and e) then fails[#fails + 1] = "power test " .. def[1] .. ": " .. tostring(e) return nil end
		return e
	end
	for _, key in pairs({ "turbine", "reactor" }) do
		local def = PW[key]
		local g = place(def)
		if g then
			local got = g.insert_fluid{ name = def[4], amount = def[5] }
			if got < def[5] then fails[#fails + 1] = "power test: " .. def[1] .. " took only " .. got .. " " .. def[4] end
			local ok, err = pcall(function()
				local eei = s.create_entity{ name = "electric-energy-interface", position = { def[2], def[3] + 6 }, force = "player" }
				eei.power_production = 0
				eei.power_usage = def[6] / 60
				eei.electric_buffer_size = 1e8
				s.create_entity{ name = "substation", position = { def[2] + 4, def[3] + 6 }, force = "player" }
			end)
			if not ok then fails[#fails + 1] = "power test load: " .. tostring(err) end
		end
	end
	place(PW.hatch)
	return fails
end

script.on_nth_tick(PW_TICK, function(event)
	if storage.power_checked or event.tick == 0 then return end
	storage.power_checked = true
	local s = game.surfaces[1]
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function find(def) return s.find_entity(def[1], { def[2], def[3] }) end
	local turbine, hatch, reactor = find(PW.turbine), find(PW.hatch), find(PW.reactor)
	expect(turbine and hatch and reactor, "power test entities missing")
	--- an input-output fluid box keeps part of its fluid in the pipeline segment, which
	--- get_fluid_count does not report
	local function fluid_in(e, fluid)
		local seg = e.fluidbox.get_fluid_segment_contents(1)
		return e.get_fluid_count(fluid) + ((seg and seg[fluid]) or 0)
	end
	local summary = ""
	if #problems == 0 then
		local seconds = event.tick / 60
		--- turbine: 81.92 MW on helium plasma (81.92 MJ per unit) burns one unit per second
		local left = fluid_in(turbine, "helium-plasma")
		local burnt = PW.turbine[5] - left
		expect(turbine.energy_generated_last_tick > 0, "plasma turbine generates nothing")
		expect(burnt > 0.6 * seconds and burnt < 1.2 * seconds, "plasma turbine burnt " .. burnt .. " helium plasma in " .. seconds .. " s")
		local helium = hatch.get_fluid_count("helium")
		local owed = remote.call("gregtorio-power", "debt", turbine) + remote.call("gregtorio-power", "energy", turbine) / PW.turbine[6]
		expect(helium > 0, "the output hatch got no helium")
		expect(math.abs(helium + owed - burnt) <= cooled_tolerance(burnt), "hatch holds " .. helium .. " helium (+ " .. owed .. " owed) for " .. burnt .. " plasma burnt")
		expect(hatch.get_fluid_count("helium-plasma") == 0, "plasma leaked into the output hatch")
		--- reactor: 327.68 MW on fuel MK1 (58.5 GJ per unit) burns 0.0056 units per second
		local fuel_left = fluid_in(reactor, "naquadah-based-fuel-mk1")
		local fuel_burnt = PW.reactor[5] - fuel_left
		expect(reactor.energy_generated_last_tick > 0, "naquadah reactor generates nothing")
		expect(fuel_burnt > 0.003 * seconds and fuel_burnt < 0.007 * seconds, "naquadah reactor burnt " .. fuel_burnt .. " fuel in " .. seconds .. " s")
		summary = string.format(" (turbine %.2f plasma -> %.2f helium, %.1f MW; reactor %.4f fuel, %.1f MW)",
			burnt, helium, turbine.energy_generated_last_tick * 60 / 1e6, fuel_burnt, reactor.energy_generated_last_tick * 60 / 1e6)
	end
	for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL " .. p) end
	log("DEVCHECK-RUNTIME-POWER " .. (#problems == 0 and "ok" or "failed") .. summary)
end)

--- Fuel check (issue #25, scripts/fork-power.lua): generators on a wrong fluid, each with its own
--- load of the generator's full output and its own network (25 tiles apart). Steam (through a pipe)
--- in a plasma turbine, steam in a naquadah reactor, naquadah fuel in a plasma turbine and plasma in
--- a naquadah reactor must make no power, keep their fluid and show "Wrong fuel"; after the right
--- fuel is put in they run. A running turbine whose plasma is replaced by steam burns steam for at
--- most one check interval (10 ticks, the documented window) and then stops.
local FC_Y = PW_Y
local FC_WINDOW_TICKS = 10
local FC = {
	--  key            generator                     x      wrong fluid                amount  right fuel                 amount  load (W)
	{ "steam_turbine", "luv-large-plasma-turbine",   75.5,  "steam",                   100,    "helium-plasma",           100,    81.92e6, pipe = true },
	{ "steam_reactor", "uv-large-naquadah-reactor",  100.5, "steam",                   500,    "naquadah-based-fuel-mk1", 10,     327.68e6 },
	{ "fuel_turbine",  "luv-large-plasma-turbine",   125.5, "naquadah-based-fuel-mk1", 10,     "helium-plasma",           100,    81.92e6 },
	{ "plasma_reactor", "uv-large-naquadah-reactor", 150.5, "helium-plasma",           100,    "naquadah-based-fuel-mk1", 10,     327.68e6 },
	--- issue #34: the new tiers take the same fuel check (1000 plasma: 7.8 s of the UXV turbine)
	{ "steam_uxv",     "uxv-large-plasma-turbine",   200.5, "steam",                   100,    "helium-plasma",           1000,   10485.76e6 },
	{ "fuel_uev",      "uev-large-plasma-turbine",   225.5, "naquadah-based-fuel-mk1", 10,     "helium-plasma",           100,    1310.72e6 },
	{ "window",        "luv-large-plasma-turbine",   175.5, "steam",                   500,    "helium-plasma",           100,    81.92e6 },
}

--- an input-output fluid box keeps part of its fluid in the pipeline segment (see the power test)
local function fc_fluid_in(e, fluid)
	local seg = e.fluidbox.get_fluid_segment_contents(1)
	return e.get_fluid_count(fluid) + ((seg and seg[fluid]) or 0)
end

function setup_fuel_test(s)
	local fails = {}
	storage.fuel = { gens = {} }
	for _, def in ipairs(FC) do
		local ok, err = pcall(function()
			local y = FC_Y + (def[2]:find("reactor") and 2.5 or 1.5)
			local g = s.create_entity{ name = def[2], position = { def[3], y }, force = "player", raise_built = true }
			local first, amount = def[4], def[5]
			if def[1] == "window" then first, amount = def[6], def[7] end
			if def.pipe then
				--- the north connection of the 3x3 turbine is one tile above its top edge
				local pipe = s.create_entity{ name = "pipe", position = { def[3], y - 2 }, force = "player" }
				local got = pipe.insert_fluid{ name = first, amount = amount }
				if got < amount then fails[#fails + 1] = "fuel test: the pipe took only " .. got .. " " .. first end
			else
				local got = g.insert_fluid{ name = first, amount = amount }
				if got < amount then fails[#fails + 1] = "fuel test: " .. def[1] .. " took only " .. got .. " " .. first end
			end
			local eei = s.create_entity{ name = "electric-energy-interface", position = { def[3], y + 6 }, force = "player" }
			eei.power_production = 0
			eei.power_usage = def[8] / 60
			eei.electric_buffer_size = math.max(1e8, 2 * def[8] / 60)
			s.create_entity{ name = "substation", position = { def[3] + 4, y + 6 }, force = "player" }
			storage.fuel.gens[def[1]] = g
		end)
		if not ok then fails[#fails + 1] = "fuel test " .. def[1] .. ": " .. tostring(err) end
	end
	return fails
end

--- The window turbine: from the swap on, its plasma is taken out every tick, and on the tick it is
--- empty the steam goes in, so the fuel check (every 10 ticks) meets steam that may have burnt since
function fuel_window_tick()
	local st = storage.fuel
	if not (st and st.phase and not st.window_swapped and not st.done) then return end
	local def = FC[#FC]
	local g = st.gens.window
	if not (g and g.valid) then return end
	g.remove_fluid{ name = def[6], amount = 1e9 }
	if fc_fluid_in(g, def[6]) > 0 then return end
	local got = g.insert_fluid{ name = def[4], amount = def[5] }
	if math.abs(got - def[5]) > 1e-6 then log("DEVCHECK-RUNTIME-FAIL fuel test: window turbine took only " .. got .. " steam") end
	st.window_swapped, st.window_stopped = game.tick, g.disabled_by_script
end

function fuel_test()
	local st = storage.fuel
	if not st then return end
	local tick = game.tick
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function label_key(e)
		local cs = e.custom_status
		return cs and type(cs.label) == "table" and cs.label[1] or nil
	end
	local function finish(summary)
		st.done = true
		for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL fuel test: " .. p) end
		log("DEVCHECK-RUNTIME-FUEL " .. (#problems == 0 and "ok" or "failed") .. (summary or ""))
	end
	for _, def in ipairs(FC) do
		if not (st.gens[def[1]] and st.gens[def[1]].valid) then
			problems[#problems + 1] = "generator " .. def[1] .. " missing"
			return finish()
		end
	end
	if not st.phase and tick >= 120 then
		--- wrong fuels: no power, fluid kept, status set; the window turbine runs on plasma
		for _, def in ipairs(FC) do
			local g = st.gens[def[1]]
			if def[1] == "window" then
				expect(g.energy_generated_last_tick > 0, "window turbine does not run on plasma")
				expect(not g.disabled_by_script, "window turbine stopped on plasma")
			else
				local left = fc_fluid_in(g, def[4])
				expect(g.energy_generated_last_tick == 0, def[1] .. " generates " .. g.energy_generated_last_tick .. " J/tick on " .. def[4])
				expect(math.abs(left - def[5]) < 1e-6, def[1] .. " holds " .. left .. " " .. def[4] .. " of " .. def[5])
				expect(g.disabled_by_script, def[1] .. " is not stopped")
				expect(label_key(g) == "entity-status.fork-wrong-fuel", def[1] .. " status " .. serpent.line(g.custom_status))
			end
		end
		if #problems > 0 then return finish() end
		st.phase, st.drain = "draining", 0
	elseif st.phase == "draining" then
		--- swap: empty the stopped ones (removing takes only the entity's share, the segment gives
		--- the rest back over the next ticks), then put the right fuel in; the window turbine is
		--- swapped every tick by fuel_window_tick
		local left = 0
		for _, def in ipairs(FC) do
			if def[1] ~= "window" then
				local g = st.gens[def[1]]
				g.remove_fluid{ name = def[4], amount = 1e9 }
				left = left + fc_fluid_in(g, def[4])
			end
		end
		st.drain = st.drain + 1
		if left > 0 then
			if st.drain > 30 then
				problems[#problems + 1] = "could not empty the generators (" .. left .. " left)"
				return finish()
			end
			return
		end
		for _, def in ipairs(FC) do
			if def[1] ~= "window" then
				local g = st.gens[def[1]]
				local got = g.insert_fluid{ name = def[6], amount = def[7] }
				expect(math.abs(got - def[7]) < 1e-6, def[1] .. " took only " .. got .. " " .. def[6] .. " after emptying it")
			end
		end
		st.phase, st.swapped = "right", tick
		if #problems > 0 then return finish() end
	elseif st.phase == "right" and st.window_swapped and not st.window_mid and tick >= st.window_swapped + FC_WINDOW_TICKS + 10 then
		st.window_mid = fc_fluid_in(st.gens.window, FC[#FC][4])
	elseif st.phase == "right" and st.window_mid and tick >= math.max(st.swapped, st.window_swapped) + 60 then
		local summary = ""
		for _, def in ipairs(FC) do
			local g = st.gens[def[1]]
			if def[1] == "window" then
				--- at most one interval of the full output on steam (+1 tick for the check order)
				local burnt = def[5] - fc_fluid_in(g, def[4])
				local max = def[8] * (FC_WINDOW_TICKS + 1) / 60 / prototypes.fluid[def[4]].fuel_value
				expect(burnt <= max, "window turbine burnt " .. burnt .. " steam, more than " .. max)
				--- a stopped generator keeps its last energy_generated_last_tick: the steam must not move
				expect(st.window_mid and math.abs(fc_fluid_in(g, def[4]) - st.window_mid) < 1e-6,
					"window turbine still burns steam (" .. tostring(st.window_mid) .. " -> " .. fc_fluid_in(g, def[4]) .. ")")
				expect(g.disabled_by_script, "window turbine is not stopped")
				expect(label_key(g) == "entity-status.fork-wrong-fuel", "window turbine status " .. serpent.line(g.custom_status))
				summary = string.format(" (window: %.1f steam = %.2f MJ burnt, swapped on tick %d %s)", burnt,
					burnt * prototypes.fluid[def[4]].fuel_value / 1e6, st.window_swapped,
					st.window_stopped and "after the turbine had stopped" or "while the turbine ran")
			else
				local burnt = def[7] - fc_fluid_in(g, def[6])
				expect(g.energy_generated_last_tick > 0, def[1] .. " does not run on " .. def[6])
				expect(burnt > 0, def[1] .. " burnt no " .. def[6])
				expect(not g.disabled_by_script, def[1] .. " still stopped on " .. def[6])
				expect(g.custom_status == nil, def[1] .. " still has status " .. serpent.line(g.custom_status))
			end
		end
		return finish(summary)
	elseif tick > 900 then
		problems[#problems + 1] = "timed out in phase " .. tostring(st.phase)
		return finish()
	end
end

--- Cooled fluid (issue #28, scripts/fork-power.lua): the cooled fluid in a turbine's output hatch
--- must match the plasma it burnt, one unit per unit, within COOLED_TOL (relative) + COOLED_ABS
--- units, whatever the load. Every LuV plasma turbine has its own load (an electric energy interface
--- that draws exactly the given share of 81.92 MW per tick, no buffer), set every tick:
---   full, partial (40 %), burst (full for 5 ticks out of 23, idle in between): a known amount of
---     helium plasma burnt to the last drop, then the hatch must hold exactly that much helium;
---   idle: no load; only the first fill of the load's buffer is burnt, and returned;
---   full_hatch: the hatch starts with 3999 of its 4000 helium, so the rest stays owed; once it is
---     emptied it must get all of it;
---   pair_a, pair_b: two turbines side by side on helium and nitrogen plasma, one hatch each: each
---     hatch gets only its own cooled fluid, in the right amount.
--- A running turbine is compared as hatch + owed + the energy of the current step / fuel value.
local CO_Y = 370
local COOLED_TOL, COOLED_ABS = 1e-3, 1e-3
local CO_DEADLINE = 1300
local CO_POWER = 81.92e6
local CO = {
	--  key           x      plasma            amount  load(tick)                                       hatch x offset
	{ "full",       200.5, "helium-plasma",   4,     function() return 1 end,                         2 },
	{ "partial",    225.5, "helium-plasma",   2,     function() return 0.4 end,                       2 },
	{ "burst",      250.5, "helium-plasma",   1.5,   function(t) return t % 23 < 5 and 1 or 0 end,    2 },
	{ "idle",       275.5, "helium-plasma",   10,    function() return 0 end,                         2 },
	{ "full_hatch", 300.5, "helium-plasma",   100,   function() return 1 end,                         2 },
	{ "pair_a",     330.5, "helium-plasma",   100,   function() return 1 end,                         -2 },
	{ "pair_b",     333.5, "nitrogen-plasma", 100,   function() return 1 end,                         2 },
}
local CO_PREFILL = 3999

function cooled_tolerance(burnt) return COOLED_ABS + COOLED_TOL * burnt end

function setup_cooled_test(s)
	local fails = {}
	storage.cooled = { t = {} }
	for i, def in ipairs(CO) do
		local ok, err = pcall(function()
			local g = s.create_entity{ name = "luv-large-plasma-turbine", position = { def[2], CO_Y }, force = "player", raise_built = true }
			local got = g.insert_fluid{ name = def[3], amount = def[4] }
			if math.abs(got - def[4]) > 1e-6 then fails[#fails + 1] = "cooled test: " .. def[1] .. " took only " .. got .. " " .. def[3] end
			local eei = s.create_entity{ name = "electric-energy-interface", position = { def[2], CO_Y + 6 }, force = "player" }
			eei.power_production = 0
			eei.power_usage = 0
			eei.electric_buffer_size = CO_POWER / 60
			s.create_entity{ name = "substation", position = { def[2] + (def[6] > 0 and 4 or -4), CO_Y + 6 }, force = "player" }
			local h = s.create_entity{ name = "turbine-output-hatch", position = { def[2] + def[6], CO_Y }, force = "player", raise_built = true }
			storage.cooled.t[def[1]] = { g = g, eei = eei, h = h, i = i, removed = 0 }
		end)
		if not ok then fails[#fails + 1] = "cooled test " .. def[1] .. ": " .. tostring(err) end
	end
	local fh = storage.cooled.t.full_hatch
	if fh then
		local got = fh.h.insert_fluid{ name = "helium", amount = CO_PREFILL }
		if math.abs(got - CO_PREFILL) > 1e-6 then fails[#fails + 1] = "cooled test: the full hatch took only " .. got .. " helium" end
	end
	return fails
end

--- Every tick: the load of each turbine
function cooled_load_tick(tick)
	local st = storage.cooled
	if not st or st.done then return end
	for _, c in pairs(st.t) do
		if c.eei.valid then c.eei.power_usage = CO_POWER / 60 * CO[c.i][5](tick) end
	end
end

function cooled_test()
	local st = storage.cooled
	if not st then return end
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function finish(summary)
		st.done = true
		for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL cooled fluid test: " .. p) end
		log("DEVCHECK-RUNTIME-COOLED " .. (#problems == 0 and "ok" or "failed") .. (summary or ""))
	end
	for _, def in ipairs(CO) do
		local c = st.t[def[1]]
		if not (c and c.g.valid and c.h.valid and c.eei.valid) then
			problems[#problems + 1] = def[1] .. " missing"
			return finish()
		end
	end
	local P = "gregtorio-power"
	--- the plasma a turbine burnt (entity and segment) and the cooled fluid it returned: in the hatch
	--- (and taken out of it by the test), owed, and the energy of the current step
	local function account(c)
		local def = CO[c.i]
		local fuel = prototypes.fluid[def[3]].fuel_value
		local out = def[3] == "helium-plasma" and "helium" or "nitrogen"
		local seg = c.g.fluidbox.get_fluid_segment_contents(1)
		local burnt = def[4] - c.g.get_fluid_count(def[3]) - ((seg and seg[def[3]]) or 0)
		local prefill = def[1] == "full_hatch" and CO_PREFILL or 0
		local hatch = c.h.get_fluid_count(out) + c.removed - prefill
		local owed = remote.call(P, "debt", c.g, out)
		local pending = remote.call(P, "energy", c.g) / fuel
		return burnt, hatch, owed, pending, out
	end
	local function matches(key, c)
		local burnt, hatch, owed, pending, out = account(c)
		local ok = math.abs(hatch + owed + pending - burnt) <= cooled_tolerance(burnt)
		st.worst = math.max(st.worst or 0, math.abs(hatch + owed + pending - burnt) / burnt)
		expect(ok, string.format("%s: %.6f plasma burnt, hatch got %.6f %s, %.6f owed, %.6f pending", key, burnt, hatch, out, owed, pending))
		return burnt, hatch + owed + pending - burnt
	end
	local tick = game.tick
	st.dry = st.dry or {}
	--- the known amounts: burnt to the last drop, stopped for "no fuel", nothing owed or pending
	for _, key in pairs({ "full", "partial", "burst" }) do
		local c = st.t[key]
		if not st.dry[key] then
			local burnt, hatch, owed, pending = account(c)
			local amount = CO[c.i][4]
			if burnt >= amount - 1e-9 and owed < 1e-4 and pending == 0 and c.g.disabled_by_script then
				st.dry[key] = { tick = tick, hatch = hatch }
				st.worst = math.max(st.worst or 0, math.abs(hatch - amount) / amount)
				expect(math.abs(hatch - amount) <= cooled_tolerance(amount),
					string.format("%s: %.6f plasma burnt, the hatch got %.6f", key, amount, hatch))
			end
		end
	end
	--- the full hatch: full, the rest owed; then emptied, and it must get everything
	local fh = st.t.full_hatch
	if not st.hatch_phase then
		local burnt, _, owed = account(fh)
		if burnt >= 3 then
			expect(math.abs(fh.h.get_fluid_count("helium") - 4000) < 1e-3, "full hatch holds " .. fh.h.get_fluid_count("helium") .. " of 4000")
			expect(owed > 1.5, "full hatch: only " .. owed .. " helium owed for " .. burnt .. " plasma burnt")
			matches("full_hatch (full)", fh)
			st.hatch_owed = owed
			fh.removed = fh.removed + fh.h.remove_fluid{ name = "helium", amount = 4000 }
			st.hatch_phase = tick
		end
	elseif st.hatch_phase ~= true and tick >= st.hatch_phase + 60 then
		matches("full_hatch (emptied)", fh)
		local _, _, owed = account(fh)
		expect(owed < 0.2, "full hatch: still " .. owed .. " helium owed after it was emptied")
		st.hatch_phase = true
	end
	--- the pair: own fluid only, right amounts
	if not st.pair_checked and account(st.t.pair_a) >= 3 then
		matches("pair_a", st.t.pair_a)
		matches("pair_b", st.t.pair_b)
		expect(st.t.pair_a.h.get_fluid_count("nitrogen") == 0, "pair_a's hatch got nitrogen")
		expect(st.t.pair_b.h.get_fluid_count("helium") == 0, "pair_b's hatch got helium")
		expect(account(st.t.pair_b) > 1, "pair_b burnt only " .. account(st.t.pair_b) .. " nitrogen plasma")
		st.pair_checked = true
	end
	if #problems > 0 then return finish() end
	if st.dry.full and st.dry.partial and st.dry.burst and st.hatch_phase == true and st.pair_checked then
		--- idle: only the first fill of its load's buffer (one tick of output each) is burnt
		local idle_burnt = matches("idle", st.t.idle)
		expect(idle_burnt < 3 / 60 + 1e-6, "idle turbine burnt " .. idle_burnt .. " plasma")
		return finish(string.format(" (4/2/1.5 plasma -> %.6f/%.6f/%.6f helium at full/40%%/burst load, worst error %.1e, full hatch owed %.2f)",
			st.dry.full.hatch, st.dry.partial.hatch, st.dry.burst.hatch, st.worst or 0, st.hatch_owed))
	end
	if tick > CO_DEADLINE then
		local left = {}
		for _, key in pairs({ "full", "partial", "burst" }) do
			if not st.dry[key] then
				local burnt, hatch, owed, pending = account(st.t[key])
				left[key] = { burnt = burnt, hatch = hatch, owed = owed, pending = pending, stopped = st.t[key].g.disabled_by_script }
			end
		end
		expect(false, "timed out: dry " .. serpent.line(st.dry) .. " (not yet: " .. serpent.line(left) .. ")" .. ", full hatch " .. tostring(st.hatch_phase) .. ", pair " .. tostring(st.pair_checked))
		return finish()
	end
end

--- Turbine tiers (issue #34, prototypes/136-fork-power.lua): one UHV to UXV (and MAX, phase 6b) large plasma turbine each
--- and a second UXV one on neon plasma, with an output hatch and a load of twice its output (an electric
--- energy interface in its own network). While it runs, every turbine must generate exactly four amps
--- of its tier per tick (the cap, not the load; fluid_usage_per_tick must let the weakest plasma, neon,
--- reach it too); once its plasma (one to one and a half seconds of full output) is burnt to the last
--- drop, its hatch must hold exactly that much cooled fluid (tolerance of the cooled fluid test).
--- The runtime code is the one of the LuV turbines: the new turbines are only listed in the mod data.
local TT_Y = -260                                       -- above the machine grid, below the recipe test
local TT_CHECK_TICK = 20
local TT_DEADLINE = 600
local TT = {
	--  turbine                     x      plasma            amount  cooled fluid    cap (W)
	{ "uhv-large-plasma-turbine", 100.5, "helium-plasma",   8,      "helium",       655.36e6 },
	{ "uev-large-plasma-turbine", 125.5, "helium-plasma",   16,     "helium",       1310.72e6 },
	{ "uiv-large-plasma-turbine", 150.5, "nitrogen-plasma", 30,     "nitrogen",     2621.44e6 },
	{ "umv-large-plasma-turbine", 175.5, "iron-plasma",     30,     "molten-iron",  5242.88e6 },
	{ "uxv-large-plasma-turbine", 200.5, "helium-plasma",   128,    "helium",       10485.76e6 },
	--- the weakest plasma (20.48 MJ): the UXV turbine needs 8.53 of its 9 units per tick for the cap
	{ "uxv-large-plasma-turbine", 225.5, "neon-plasma",     512,    "neon",         10485.76e6 },
	--- phase 6b (prototypes/141-fork-max.lua): the MAX turbine, also on the weakest plasma (17.07 of its 18 units)
	{ "max-large-plasma-turbine", 250.5, "helium-plasma",   256,    "helium",       20971.52e6 },
	{ "max-large-plasma-turbine", 275.5, "neon-plasma",     960,    "neon",         20971.52e6 },
}

function setup_tier_test(s)
	local fails = {}
	storage.tiers = { t = {}, dry = {} }
	for i, def in ipairs(TT) do
		local ok, err = pcall(function()
			local g = s.create_entity{ name = def[1], position = { def[2], TT_Y }, force = "player", raise_built = true }
			local got = g.insert_fluid{ name = def[3], amount = def[4] }
			if math.abs(got - def[4]) > 1e-6 then fails[#fails + 1] = "tier test: " .. def[1] .. " took only " .. got .. " " .. def[3] end
			local eei = s.create_entity{ name = "electric-energy-interface", position = { def[2], TT_Y + 6 }, force = "player" }
			eei.power_production = 0
			eei.power_usage = 2 * def[6] / 60
			eei.electric_buffer_size = 4 * def[6] / 60
			s.create_entity{ name = "substation", position = { def[2] + 4, TT_Y + 6 }, force = "player" }
			local h = s.create_entity{ name = "turbine-output-hatch", position = { def[2] + 2, TT_Y }, force = "player", raise_built = true }
			storage.tiers.t[i] = { g = g, h = h }
		end)
		if not ok then fails[#fails + 1] = "tier test " .. def[1] .. ": " .. tostring(err) end
	end
	return fails
end

function tier_test()
	local st = storage.tiers
	if not st then return end
	local tick = game.tick
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function finish(summary)
		st.done = true
		for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL turbine tier test: " .. p) end
		log("DEVCHECK-RUNTIME-TIERS " .. (#problems == 0 and "ok" or "failed") .. (summary or ""))
	end
	for i, def in ipairs(TT) do
		local c = st.t[i]
		if not (c and c.g.valid and c.h.valid) then
			problems[#problems + 1] = def[1] .. " missing"
			return finish()
		end
	end
	--- the cap: four amps of the tier per tick under twice that load, as the prototype says
	if not st.capped and tick >= TT_CHECK_TICK then
		for i, def in ipairs(TT) do
			local g = st.t[i].g
			local per_tick = def[6] / 60
			local max = g.prototype.get_max_power_output()
			expect(math.abs(max - per_tick) <= 1e-6 * per_tick, def[1] .. ": max_power_output " .. max * 60 .. " W, expected " .. def[6])
			expect(not g.disabled_by_script, def[1] .. " is stopped on " .. def[3] .. " (" .. serpent.line(g.custom_status) .. ")")
			expect(math.abs(g.energy_generated_last_tick - per_tick) <= 1e-6 * per_tick,
				string.format("%s generates %.6g W under a load of %.6g W, expected the cap %.6g W", def[1],
					g.energy_generated_last_tick * 60, 2 * def[6], def[6]))
		end
		st.capped = true
		if #problems > 0 then return finish() end
	end
	--- the cooled fluid: burnt to the last drop (stopped for "no fuel", nothing owed or pending)
	for i, def in ipairs(TT) do
		local c = st.t[i]
		if not st.dry[i] then
			local seg = c.g.fluidbox.get_fluid_segment_contents(1)
			local burnt = def[4] - c.g.get_fluid_count(def[3]) - ((seg and seg[def[3]]) or 0)
			local owed = remote.call("gregtorio-power", "debt", c.g, def[5])
			local pending = remote.call("gregtorio-power", "energy", c.g)
			if burnt >= def[4] - 1e-9 and owed < 1e-4 and pending == 0 and c.g.disabled_by_script then
				local hatch = c.h.get_fluid_count(def[5])
				st.dry[i] = { tick = tick, hatch = hatch }
				st.worst = math.max(st.worst or 0, math.abs(hatch - def[4]) / def[4])
				expect(math.abs(hatch - def[4]) <= cooled_tolerance(def[4]),
					string.format("%s: %.6f %s burnt, the hatch got %.6f %s", def[1], def[4], def[3], hatch, def[5]))
				expect(c.h.get_fluid_count(def[3]) == 0, def[1] .. ": plasma leaked into the output hatch")
			end
		end
	end
	if #problems > 0 then return finish() end
	if st.capped and table_size(st.dry) == #TT then
		local parts = {}
		for i, def in ipairs(TT) do
			parts[#parts + 1] = string.format("%s %.6g MW: %g -> %.6f", def[1]:sub(1, 3), def[6] / 1e6, def[4], st.dry[i].hatch)
		end
		return finish(string.format(" (%s; worst error %.1e)", table.concat(parts, ", "), st.worst or 0))
	end
	if tick > TT_DEADLINE then
		expect(false, "timed out: capped " .. tostring(st.capped) .. ", dry " .. serpent.line(st.dry))
		return finish()
	end
end

--- New recipes of issue #35 (prototypes/129-fork-water-purification.lua): grades 7 and 8 in the water
--- purification plant, the FPIC and APIC wafers and chips, the complex SMDs, the quark creation catalyst
--- and recipes that take the new parts; the same for issues #39 and #36 and phase 6a (plasma forge, QFT).
--- Each machine gets one craft's ingredients (placed above the machine grid, powered like it); once it
--- crafts, its progress is set close to the end (the grades take 25 and 30 s, a mainframe 12 minutes), and
--- the main product must come out (a main product with a probability: the craft must finish).
local RT_Y = -300
local RT_DEADLINE = 900
local RT = {
	{ "water-purification-plant", "grade-7-water" },
	{ "water-purification-plant", "grade-8-water" },
	{ "uhv-laser-engraver", "fpic-wafer" },
	{ "uev-laser-engraver", "apic-wafer" },
	{ "uhv-assembling-machine", "femto-power-ic" },
	{ "uev-assembling-machine", "atto-power-ic" },
	{ "uv-assembling-machine", "complex-smd-transistor" },
	{ "uv-assembling-machine", "complex-smd-resistor" },
	{ "uv-assembling-machine", "complex-smd-capacitor" },
	{ "uv-assembling-machine", "complex-smd-diode" },
	{ "uv-assembling-machine", "complex-smd-inductor" },
	{ "zpm-assembly-line", "quark-creation-catalyst" },
	{ "zpm-assembly-line", "uev-energy-hatch" },
	{ "zpm-assembly-line", "uiv-energy-hatch" },
	{ "zpm-assembly-line", "fusion-reactor-mk4-controller" },
	{ "luv-circuit-assembly-line", "wetware-processor-mainframe" },
	-- issues #39 and #36 (prototypes/137-fork-endgame-materials.lua): the drafts made real, the new
	-- materials and recipes that take them
	{ "iv-circuit-assembler", "lapotronic-energy-orb-cluster" },
	{ "ev-assembling-machine", "wrapped-plutonium-ingot" },
	{ "hv-implosion-compressor", "high-density-plutonium-nugget" },
	{ "luv-mixer", "plutonium-based-liquid-fuel" },
	{ "hv-mixer", "super-coolant" },
	{ "hv-canning-machine", "1080k-super-coolant-cell" },
	{ "zpm-electric-blast-furnace", "hot-fluxed-electrum-ingot" },
	{ "zpm-alloy-blast-smelter", "molten-fluxed-electrum" },
	{ "uv-electric-blast-furnace", "hot-bedrockium-ingot" },
	{ "uhv-electric-blast-furnace", "hot-quantium-ingot" },
	{ "iv-extractor", "molten-quantium" },
	{ "uhv-mixer", "naquadah-based-fuel-mk2" },
	{ "water-purification-plant", "grade-5-water" },
	{ "zpm-assembly-line", "uxv-energy-hatch" },
	-- phase 6a (prototypes/139-fork-endgame-multiblocks.lua): a plasma forge recipe (the catalyst and a metal) and
	-- a quantum force transformer recipe in the real machines
	{ "dimensionally-transcendent-plasma-forge", "excited-dimensionally-transcendent-crude-catalyst" },
	{ "dimensionally-transcendent-plasma-forge", "molten-spacetime-dtpf-crude" },
	{ "quantum-force-transformer", "metallic-platinum-powder-qft-platinum-dust" },
	-- phase 6b (prototypes/140-fork-godforge.lua, 141-fork-max.lua): godforge recipes (star matter, magmatter), the
	-- stellar catalyst in the plasma forge, a MAX component, a recipe in a MAX machine and the MAX pack from MAX parts
	{ "godforge", "raw-star-matter" },
	{ "godforge", "molten-magmatter-from-neutronium" },
	{ "dimensionally-transcendent-plasma-forge", "excited-dimensionally-transcendent-stellar-catalyst" },
	{ "zpm-assembly-line", "max-motor" },
	{ "max-assembling-machine", "maximum-voltage-coil" },
	{ "uxv-assembling-machine", "max-science-pack-from-magmatter" },
}

local function rt_product(recipe)
	local r = prototypes.recipe[recipe]
	for _, p in pairs(r.products) do
		if p.name == (r.main_product and r.main_product.name or p.name) then return p end
	end
end

function setup_recipe_test(s)
	local fails = {}
	storage.recipe_test = { m = {}, ok = {} }
	local x = -150
	for i, def in pairs(RT) do
		local ok, err = pcall(function()
			local e = s.create_entity{ name = def[1], position = { x, RT_Y }, force = "player", raise_built = true }
			s.create_entity{ name = "electric-energy-interface", position = { x, RT_Y + 7 }, force = "player" }
			s.create_entity{ name = "substation", position = { x + 5, RT_Y + 7 }, force = "player" }
			e.force.recipes[def[2]].enabled = true
			e.set_recipe(def[2])
			for _, ing in pairs(prototypes.recipe[def[2]].ingredients) do
				if ing.type == "item" then
					local n = e.insert{ name = ing.name, count = ing.amount }
					assert(n == ing.amount, "only " .. n .. " of " .. ing.amount .. " " .. ing.name .. " fit")
				else
					local n = e.insert_fluid{ name = ing.name, amount = ing.amount }
					assert(math.abs(n - ing.amount) < 1e-6, "only " .. n .. " of " .. ing.amount .. " " .. ing.name .. " fit")
				end
			end
			storage.recipe_test.m[i] = e
		end)
		if not ok then fails[#fails + 1] = "recipe test " .. def[2] .. " in " .. def[1] .. ": " .. tostring(err) end
		x = x + 18
	end
	return fails
end

function recipe_test()
	local st = storage.recipe_test
	if not st or st.done then return end
	local pending = {}
	for i, def in pairs(RT) do
		local e = st.m[i]
		if e and e.valid and not st.ok[i] then
			local p = rt_product(def[2])
			local made = p.type == "fluid" and e.get_fluid_count(p.name) or
				e.get_inventory(defines.inventory.crafter_output).get_item_count(p.name)
			-- a main product with a probability (the QFT's focused output) may roll nothing: a finished craft counts
			if made >= (p.amount or p.amount_min or 1) - 1e-6 or ((p.probability or 1) < 1 and e.products_finished > 0) then
				st.ok[i] = true
			else
				if e.crafting_progress > 0 and e.crafting_progress < 0.999 then e.crafting_progress = 0.999 end
				local status
				for name, v in pairs(defines.entity_status) do if e.status == v then status = name end end
				pending[#pending + 1] = def[2] .. " (" .. tostring(status) .. ", progress " .. e.crafting_progress .. ", made " .. made .. ")"
			end
		end
	end
	local n = 0
	for _ in pairs(st.ok) do n = n + 1 end
	if #pending == 0 or game.tick > RT_DEADLINE then
		st.done = true
		local problems = {}
		if n < #RT then problems[#problems + 1] = "recipe test: " .. (#RT - n) .. " of " .. #RT .. " recipes made nothing: " .. table.concat(pending, ", ") end
		for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL " .. p) end
		log("DEVCHECK-RUNTIME-RECIPES " .. (#problems == 0 and "ok" or "failed") .. " (" .. n .. " of " .. #RT .. " recipes crafted by tick " .. game.tick .. ")")
	end
end

local MOLD_Y = 120
local MOLD_RECIPE = "glass-alloy-smelter"
local MOLD_DEADLINE = 900                               -- ticks for the first glass with the mold in (361 needed)

function setup_mold_test(s)
	local ok, err = pcall(function()
		local eei = s.create_entity{ name = "electric-energy-interface", position = { 0, MOLD_Y }, force = "player" }
		eei.power_production = 1e6
		eei.electric_buffer_size = 1e7
		s.create_entity{ name = "substation", position = { 3, MOLD_Y }, force = "player" }
		local m = s.create_entity{ name = "lv-alloy-smelter", position = { 6, MOLD_Y }, force = "player", raise_built = true }
		m.force.recipes[MOLD_RECIPE].enabled = true
		m.set_recipe(MOLD_RECIPE)
		m.insert{ name = "glass-dust", count = 20 }
		storage.mold_machine = m
	end)
	if not ok then return { "mold test setup: " .. tostring(err) } end
	return {}
end

script.on_event(defines.events.on_tick, function(event)
	fuel_window_tick()
	cooled_load_tick(event.tick)
	local m = storage.mold_machine
	if storage.mold_done then return end
	local function glass_made()
		return m and m.valid and m.get_inventory(defines.inventory.crafter_output or defines.inventory.assembling_machine_output).get_item_count("glass") or 0
	end
	--- phase 2 as soon as the first glass is out, at the latest MOLD_DEADLINE ticks after the mold went in
	local phase
	if not storage.mold_phase1 and event.tick >= 60 then
		phase = 1
		storage.mold_phase1 = event.tick
	elseif storage.mold_phase1 and (glass_made() > 0 or event.tick >= storage.mold_phase1 + MOLD_DEADLINE) then
		phase = 2
		storage.mold_done = true
	else
		return
	end
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	expect(m and m.valid, "mold test machine missing")
	if #problems == 0 then
		local glass = glass_made()
		local inv = m.get_module_inventory()
		if phase == 1 then
			expect(m.disabled_by_script, "mold test: machine without mold is not stopped")
			expect(glass == 0, "mold test: crafted " .. glass .. " glass without a mold")
			expect(inv and inv.insert{ name = "mold", count = 1 } == 1, "mold test: mold does not fit into the mold slot")
		else
			expect(not m.disabled_by_script, "mold test: machine with mold is still stopped")
			expect(glass > 0, "mold test: no glass crafted with the mold inserted")
			expect(inv.get_item_count("mold") == 1, "mold test: mold left the mold slot")
			expect(m.get_item_count("mold") == 1, "mold test: mold was duplicated or moved")
			log("DEVCHECK-RUNTIME-MOLD " .. (#problems == 0 and "ok" or "failed") .. " (glass " .. glass .. " after " .. (event.tick - storage.mold_phase1) .. " ticks)")
		end
	end
	for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL " .. p) end
	if #problems > 0 and phase == 1 then
		storage.mold_done = true
		log("DEVCHECK-RUNTIME-MOLD failed")
	end
end)

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
	--- CPU tiers: a co-processing CPU and two gear machines
	m = network38(s, fails, CT_Y, "me-co-processing-cpu")
	place38(s, fails, "me-molecular-assembler", X38 + 14.5, CT_Y + 0.5, GEAR_RECIPE)
	m[#m + 1] = place38(s, fails, "me-pattern-provider", X38 + 16.5, CT_Y + 0.5)
	place38(s, fails, "me-molecular-assembler", X38 + 20.5, CT_Y + 0.5, GEAR_RECIPE)
	m[#m + 1] = place38(s, fails, "me-pattern-provider", X38 + 18.5, CT_Y + 0.5)
	me_connect(fails, "CPU tiers", m)
	--- circuit interface: a fluid drive, the interface wired to a pole
	m = network38(s, fails, CI_Y, nil)
	m[#m + 1] = me_drive(s, fails, "circuit interface", X38 + 14.5, CI_Y + 6.5, {}, "1k", true)
	m[#m + 1] = place38(s, fails, "me-circuit-interface", X38 + 2.5, CI_Y + 8.5)
	place38(s, fails, "small-electric-pole", X38 + 0.5, CI_Y + 8.5)
	me_connect(fails, "circuit interface", m)
	--- settings copy: a maintainer, a circuit interface and a fluid interface with settings
	m = network38(s, fails, SC_Y, nil)
	m[#m + 1] = place38(s, fails, "me-level-maintainer", X38 + 2.5, SC_Y + 10.5)
	m[#m + 1] = place38(s, fails, "me-circuit-interface", X38 + 3.5, SC_Y + 10.5)
	m[#m + 1] = place38(s, fails, "me-fluid-interface", X38 + 4.5, SC_Y + 10.5)
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
		local c = remote.call(AC38, "start", terminal, LM_ITEM, 1)
		local jc = c and remote.call(AC38, "job", c)
		expect(jc and jc.status == "queued", "a third job must wait for a slot: " .. tostring(jc and jc.status))
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
	local fi = s.find_entity("me-fluid-interface", { X38 + 4.5, SC_Y + 10.5 })
	if not (m and ci and fi) then
		expect(false, "entities missing")
		return report38("SETTINGS", "settings copy", problems)
	end
	local M_SET = { key = "fluid/water", amount = 1234, circuit = true }
	local C_SET = { "iron-plate", "fluid/water" }
	local F_SET = { mode = "export", fluid = "water", level = 2345 }
	remote.call(C38, "set_maintainer", m, M_SET.key, M_SET.amount, M_SET.circuit)
	remote.call(C38, "set_circuit_filters", ci, C_SET)
	remote.call(F38, "set_interface", fi, F_SET.mode, F_SET.fluid, F_SET.level)
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
			local g = remote.call(F38, "get_interface", ff)
			expect(g and g.mode == F_SET.mode and g.fluid == F_SET.fluid and g.level == F_SET.level,
				what .. ": fluid interface settings " .. serpent.line(g))
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
			["me-fluid-interface"] = "fork_me_fluid_interface" })[e.name]
		if tag then tagged[e.name] = bp.get_blueprint_entity_tag(index, tag) end
	end
	local tm, tc, tf = tagged["me-level-maintainer"], tagged["me-circuit-interface"], tagged["me-fluid-interface"]
	expect(tm and tm.key == M_SET.key and tm.amount == M_SET.amount and tm.circuit == M_SET.circuit, "maintainer tag " .. serpent.line(tm))
	expect(tc and serpent.line(tc.filters) == serpent.line(C_SET), "circuit interface tag " .. serpent.line(tc))
	expect(tf and tf.mode == F_SET.mode and tf.fluid == F_SET.fluid and tf.level == F_SET.level, "fluid interface tag " .. serpent.line(tf))
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
	connect38(SC_Y, { built["me-level-maintainer"], built["me-circuit-interface"], built["me-fluid-interface"] }, cfails)
	check("blueprint", built["me-level-maintainer"], built["me-circuit-interface"], built["me-fluid-interface"])
	inv.destroy()

	--- settings paste onto plain entities
	local pm = s.create_entity{ name = "me-level-maintainer", position = { X38 + 2.5, SC_Y + 12.5 }, force = "player", raise_built = true }
	local pc = s.create_entity{ name = "me-circuit-interface", position = { X38 + 3.5, SC_Y + 12.5 }, force = "player", raise_built = true }
	local pf = s.create_entity{ name = "me-fluid-interface", position = { X38 + 4.5, SC_Y + 12.5 }, force = "player", raise_built = true }
	remote.call(C38, "paste", m, pm)
	remote.call(C38, "paste", ci, pc)
	remote.call(F38, "paste", fi, pf)
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
	local recipe_for = {}
	for rn, r in pairs(prototypes.recipe) do recipe_for[r.category] = recipe_for[r.category] or rn end
	local x, y, placed, with_recipe, fails = -150, -150, 0, 0, {}
	for name, p in pairs(prototypes.get_entity_filtered{ { filter = "type", type = "assembling-machine" } }) do
		if p.items_to_place_this and #p.items_to_place_this > 0 then
			--- the autocrafting test's network lies in the grid: its cables need free tiles (issue #68)
			while x >= -12 and x <= 46 and y >= 120 and y <= 160 do
				x = x + 14
				if x > 150 then x = -150; y = y + 14 end
			end
			local ok, e = pcall(function()
				return s.create_entity{ name = name, position = { x, y }, force = "player", raise_built = true }
			end)
			if ok and e then
				placed = placed + 1
				for c, _ in pairs(p.crafting_categories) do
					if recipe_for[c] and pcall(function() e.set_recipe(recipe_for[c]) end) then
						with_recipe = with_recipe + 1
						break
					end
				end
				s.create_entity{ name = "electric-energy-interface", position = { x, y + 7 }, force = "player" }
				s.create_entity{ name = "substation", position = { x + 5, y + 7 }, force = "player" }
			else
				fails[#fails + 1] = name .. ": " .. tostring(e)
			end
			x = x + 14
			if x > 150 then x = -150; y = y + 14 end
		end
	end
	for _, f in pairs(setup_me_network(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_mold_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_autocraft_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_furnace_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_fluid_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_fluid_cell_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_r3_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_power_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_fuel_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_cooled_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_tier_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_recipe_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_issue38_tests(s)) do fails[#fails + 1] = f end
	log("DEVCHECK-RUNTIME placed=" .. placed .. " with_recipe=" .. with_recipe .. " failed=" .. #fails)
	for _, f in pairs(fails) do log("DEVCHECK-RUNTIME-FAIL " .. f) end
end)
