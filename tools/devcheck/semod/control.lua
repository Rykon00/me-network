--- Runtime test of ME Network with Space Exploration (tools/devcheck/devcheck.py se): loaded with Space Exploration and its
--- dependencies only, on a new map. Every part reports a DEVCHECK-SE-<KEY> line ("ok ..." or "failed ..."), every problem a
--- DEVCHECK-SE-FAIL line; DEVCHECK-SE-DONE at the end.
---   PLACE    every block of the mod can be built on Space Exploration's space platform scaffold, space platform plating
---            and spaceship floor (LuaSurface.can_place_entity as a player builds it), and on Nauvis.
---   BUILD    a network on spaceship floor in Nauvis Orbit: controller (powered by an electric energy interface), a drive with
---            item cells and a fluid cell, a pattern provider with an encoded pattern and a priority, an export bus with a
---            filter and a card, a storage bus on a chest, an interface with a row, an IO port with a cell, a cell workbench
---            with a cell, a pattern terminal, an access point, a level maintainer, a pair of P2P tunnels, a crafting unit
---            and storage, and a quantum bridge whose partner stands in a second network on Nauvis.
---   LAUNCH   the ship is moved to a surface of its own the way Space Exploration's SpaceshipClone.clone moves one:
---            LuaSurface.clone_brush over its tiles, then every original destroyed with raise_destroy. (Its launch itself
---            starts from a button of its window and from nothing a script can call: the real flight is in the in-game
---            checklist.) Nothing lies on the ground where it stood, and the network holds what it held.
---   TRAVEL   the network works on the ship's surface for two seconds: powered, the interface filled from the drive, the
---            quantum bridge linked to Nauvis again.
---   LAND     the ship is moved onto Nauvis the same way, next to the partner network: everything as before the launch.
---   COPY     a clone whose source stays is still a copy: an empty drive with the source's priority, the source keeps its cells.
---   PAD      storage buses read a cargo rocket landing pad and a delivery cannon chest of Space Exploration.
---   SURFACE  Space Exploration's question before it deletes a zone's surface is answered with "no" while ME blocks stand
---            on it; a surface with a network that is deleted leaves no member, drive or network in the mod's storage.
---
--- Issue #706, `devcheck.py launch` (the startup setting zz-me-se-real-launch of settings.lua): none of the steps above runs
--- by the tick. The harness drives a headless server through RCON instead: the remote interface "me-se-launch" below builds
--- the same network inside a real spaceship of Space Exploration (spaceship floor, walls around it, a rocket engine in the
--- back wall, a booster tank with liquid rocket fuel, the console; power from charged accumulators, because Space
--- Exploration counts an electric energy interface as a generator far too heavy for a ship), the harness waits for Space
--- Exploration's integrity check and calls its own Spaceship.launch and Spaceship.land_at_position in its Lua state
--- (`/silent-command __space-exploration__ ...`), and the interface compares what the network holds after each move.

local NET, IO, SB, AC, PT = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-storagebus", "gregtorio-me-autocraft",
	"gregtorio-me-pattern-terminal"
local QB, P2P, PORT, BENCH, MOVE = "gregtorio-me-qbridge", "gregtorio-me-p2p", "gregtorio-me-ioport", "gregtorio-me-workbench",
	"me-network-space-exploration"
local SE = "space-exploration"

local fails = {}
local function fail(what) fails[#fails + 1] = what log("DEVCHECK-SE-FAIL " .. what) end
local function report(key, problems, text)
	for _, p in ipairs(problems) do fail(key .. ": " .. p) end
	local line = (#problems == 0 and "ok" or "failed") .. " (" .. text .. ")"
	log("DEVCHECK-SE-" .. key .. " " .. line)
	return line .. (#problems > 0 and (" PROBLEMS: " .. table.concat(problems, " ;; ")) or "")
end

local SHIP = { x1 = -8, y1 = -6, x2 = 9, y2 = 5 }       -- the ship's tiles in Nauvis Orbit (inclusive)
local REAL = { x1 = -8, y1 = -6, x2 = 9, y2 = 11 }      -- issue #706: the real ship (walls on its border, console, tank and engine below the network)
local REAL_LAUNCH = settings.startup["zz-me-se-real-launch"] and settings.startup["zz-me-se-real-launch"].value
local FLIGHT = "me-se-flight"                           -- the surface it flies on
local LAND = { dx = 60, dy = 40 }                       -- where it lands on Nauvis, relative to its tiles

local function tiles(surface, name, x1, y1, x2, y2)
	surface.request_to_generate_chunks({ (x1 + x2) / 2, (y1 + y2) / 2 }, 3)
	surface.force_generate_chunk_requests()
	local list = {}
	for x = x1, x2 do for y = y1, y2 do list[#list + 1] = { name = name, position = { x, y } } end end
	surface.set_tiles(list)
end

local function place(s, problems, name, x, y, extra)
	local def = { name = name, position = { x, y }, force = "player", raise_built = true }
	for k, v in pairs(extra or {}) do def[k] = v end
	local ok, e = pcall(s.create_entity, def)
	if not (ok and e) then problems[#problems + 1] = "could not place " .. name .. ": " .. tostring(e) return nil end
	return e
end

local function orbit()
	local zone = remote.call(SE, "get_zone_from_name", { zone_name = "Nauvis Orbit" })
	return zone and remote.call(SE, "zone_get_make_surface", { zone_index = zone.index }), zone
end

--------------------------------------------------------------------------------
--- PLACE
--------------------------------------------------------------------------------

local function place_test()
	local problems = {}
	local s = orbit()
	if not s then report("PLACE", { "no surface of Nauvis Orbit" }, "") return end
	local floors = { { "se-space-platform-scaffold", 40 }, { "se-space-platform-plating", 60 }, { "se-spaceship-floor", 80 } }
	for _, f in ipairs(floors) do
		if not prototypes.tile[f[1]] then problems[#problems + 1] = "no tile " .. f[1] else tiles(s, f[1], f[2], -4, f[2] + 8, 4) end
	end
	local names, n = {}, 0
	for name, item in pairs(prototypes.item) do
		local e = item.place_result
		if e and (e.name:sub(1, 3) == "me-" or item.name == "fluix-cable") and not item.hidden then names[#names + 1] = e.name end
	end
	table.sort(names)
	local nauvis = game.surfaces.nauvis
	for _, name in ipairs(names) do
		n = n + 1
		for _, f in ipairs(floors) do
			if prototypes.tile[f[1]] and not s.can_place_entity{ name = name, position = { f[2] + 4.5, 0.5 }, force = "player",
					build_check_type = defines.build_check_type.manual } then
				problems[#problems + 1] = name .. " cannot be built on " .. f[1]
			end
		end
		local pos = nauvis.find_non_colliding_position(name, { 200, 200 }, 40, 1)
		if not pos then problems[#problems + 1] = name .. " cannot be built on Nauvis" end
	end
	report("PLACE", problems, n .. " blocks on scaffold, plating, spaceship floor and Nauvis")
end

--------------------------------------------------------------------------------
--- BUILD
--------------------------------------------------------------------------------

local function cell(name)
	local inv = game.create_inventory(1)
	inv[1].set_stack{ name = name, count = 1 }
	return inv
end

local function build(real)
	local problems = {}
	local s = orbit()
	local t = { }
	storage.t = t
	local S = real and REAL or SHIP
	tiles(s, "se-spaceship-floor", S.x1, S.y1, S.x2, S.y2)
	local function at(name, x, y, extra) return place(s, problems, name, x, y, extra) end
	if real then
		for _, y in ipairs({ -4, -2, 0, 2, 4 }) do
			local acc = at("accumulator", -6, y)
			if acc then acc.energy = acc.electric_buffer_size end
		end
	else
		local eei = at("electric-energy-interface", -6, -4)
		if eei then eei.power_production = 5e6 eei.electric_buffer_size = 5e7 eei.energy = 5e7 end
	end
	at("substation", -3, -4)
	t.ctrl = at("me-network-controller", 0, -4)
	t.drive = at("me-drive", 2.5, -3.5)
	t.provider = at("me-pattern-provider", 3.5, -3.5)
	t.iface = at("me-network-interface", 4.5, -3.5)
	t.port = at("me-io-port", 5.5, -3.5)
	t.bench = at("me-cell-workbench", 6.5, -3.5)
	t.pterm = at("me-pattern-terminal", 7.5, -3.5)
	t.ap = at("me-wireless-access-point", 8.5, -3.5)
	t.maint = at("me-level-maintainer", 2.5, -1.5)
	t.chest = at("steel-chest", 4.5, -0.5)
	t.sbus = at("me-storage-bus", 4.5, -1.5, { direction = defines.direction.south })
	t.xchest = at("steel-chest", 6.5, -0.5)
	t.xbus = at("me-export-bus", 6.5, -1.5, { direction = defines.direction.south })
	t.tunnel_in = at("me-item-p2p-tunnel", 8.5, -1.5)
	t.tunnel_out = at("me-item-p2p-tunnel", 8.5, 1.5)
	t.cpu = at("me-1k-crafting-storage", 2.5, 1.5)
	t.cpu2 = at("me-crafting-unit", 3.5, 1.5)
	t.bridge = at("me-quantum-bridge", 0.5, 2.5)
	t.machine = at("assembling-machine-2", 4.5, 3.5)
	if t.machine then t.machine.set_recipe("iron-gear-wheel") end
	local members = {}
	for _, k in ipairs({ "ctrl", "drive", "provider", "iface", "port", "pterm", "ap", "maint", "sbus", "xbus", "tunnel_in",
			"tunnel_out", "cpu", "cpu2", "bridge" }) do
		if t[k] then members[#members + 1] = t[k] end
	end
	local _, unreached = remote.call(NET, "connect", members, 16)
	for _, e in pairs(unreached or {}) do problems[#problems + 1] = "no cable path to " .. e.name end
	--- the drive: three item cells and a fluid cell
	if t.drive then
		for slot, name in ipairs({ "me-16k-storage-cell", "me-16k-storage-cell", "me-4k-storage-cell", "me-16k-fluid-storage-cell" }) do
			local inv = cell(name)
			if not remote.call(NET, "insert_cell", t.drive, inv[1], slot) then problems[#problems + 1] = "no cell in slot " .. slot end
			inv.destroy()
		end
		remote.call(NET, "store_in_drive", t.drive, "iron-plate", 1000)
		remote.call(NET, "store_in_drive", t.drive, "copper-plate", 300)
		remote.call(NET, "store_in_drive", t.drive, "me-capacity-card", 4)
		remote.call(NET, "store_fluid_in_drive", t.drive, "water", 5000)
	end
	--- the provider: an encoded pattern, a priority
	if t.provider then
		local inv = game.create_inventory(2)
		inv.insert{ name = "me-blank-pattern", count = 1 }
		local where, why = remote.call(PT, "encode_def", inv, nil, { kind = "crafting", recipe = "iron-gear-wheel" })
		local stack = inv.find_item_stack("me-encoded-pattern")
		if not (where and stack and remote.call(AC, "insert_pattern", t.provider, stack)) then
			problems[#problems + 1] = "no pattern in the provider: " .. tostring(why)
		end
		inv.destroy()
		remote.call(AC, "set_priority", t.provider, 3)
	end
	if t.iface then remote.call(IO, "set_interface_slot", t.iface, 1, "iron-plate", "normal", 50) end
	if t.xbus then
		remote.call(IO, "set_bus_filters", t.xbus, { "stone" })       -- (nothing of it in the network: the bus only keeps its setting)
		local inv = cell("me-capacity-card")
		local why = remote.call(IO, "bus_shift_in", t.xbus, inv[1])
		if inv[1].valid_for_read then problems[#problems + 1] = "the export bus did not take its card: " .. tostring(why) end
		inv.destroy()
	end
	if t.chest then t.chest.insert{ name = "steel-plate", count = 200 } end
	if t.port then
		local inv = cell("me-1k-storage-cell")
		remote.call(PORT, "shift_in", t.port, inv[1])
		if inv[1].valid_for_read then problems[#problems + 1] = "the IO port did not take its cell" end
		inv.destroy()
	end
	if t.bench then
		local inv = cell("me-1k-storage-cell")
		remote.call(BENCH, "shift_in", t.bench, inv[1], nil)
		if inv[1].valid_for_read then problems[#problems + 1] = "the workbench did not take its cell" end
		inv.destroy()
	end
	if t.maint then remote.call("gregtorio-me-circuit", "set_maintainer", t.maint, "iron-gear-wheel", 0) end
	if t.tunnel_in and t.tunnel_out then
		remote.call(P2P, "set", t.tunnel_in, 11, false)
		remote.call(P2P, "set", t.tunnel_out, 11, true)
	end
	--- the partner network on Nauvis, where the ship will land next to it
	local n = game.surfaces.nauvis
	local nx, ny = LAND.dx + 30, LAND.dy
	tiles(n, "refined-concrete", nx - 10, ny - 8, nx + 10, ny + 8)
	for _, e in pairs(n.find_entities_filtered{ area = { { nx - 10, ny - 8 }, { nx + 11, ny + 9 } } }) do
		if e.valid and e.type ~= "character" then e.destroy() end
	end
	local function on_nauvis(name, x, y, extra) return place(n, problems, name, nx + x, ny + y, extra) end
	local e2 = on_nauvis("electric-energy-interface", -6, -4)
	if e2 then e2.power_production = 5e6 e2.electric_buffer_size = 5e7 e2.energy = 5e7 end
	on_nauvis("substation", -3, -4)
	--- (no controller: a network has one, the ship's, through the bridge)
	t.n_bridge = on_nauvis("me-quantum-bridge", 0.5, 2.5)
	t.n_iface = on_nauvis("me-network-interface", 5.5, 2.5)
	for x = 1.5, 4.5 do pcall(n.create_entity, { name = "me-cable", position = { nx + x, ny + 2.5 }, force = "player", raise_built = true }) end
	if t.n_bridge and t.n_iface then
		if not remote.call(NET, "same_network", t.n_bridge, t.n_iface) then problems[#problems + 1] = "Nauvis: the interface is not cabled to the bridge" end
		remote.call(IO, "set_interface_slot", t.n_iface, 1, "copper-plate", "normal", 20)
	end
	if t.bridge and t.n_bridge then
		remote.call(QB, "set_frequency", t.bridge, 9)
		remote.call(QB, "set_frequency", t.n_bridge, 9)
	end
	if real then
		--- the ship around the network: an engine in the back wall, walls on the rest of the border, a booster tank with
		--- fuel, and the console last (its build starts Space Exploration's integrity check)
		at("se-spaceship-rocket-engine", 1.5, 10)                   -- (tiles 0..2 x 8..11)
		for x = S.x1, S.x2 do
			for y = S.y1, S.y2 do
				local border = x == S.x1 or x == S.x2 or y == S.y1 or y == S.y2
				if border and not (y == S.y2 and x >= 0 and x <= 2) then at("se-spaceship-wall", x + 0.5, y + 0.5) end
			end
		end
		local tank = at("se-spaceship-rocket-booster-tank", 5.5, 7.5)
		if tank then tank.insert_fluid{ name = "se-liquid-rocket-fuel", amount = 100000 } end
		t.console = at("se-spaceship-console", -4, 8)
	end
	return report("BUILD", problems, #members .. " blocks on spaceship floor in " .. s.name .. ", a partner network on Nauvis"
		.. (real and ", inside a real spaceship" or ""))
end

--------------------------------------------------------------------------------
--- what the network holds and how its blocks are set: compared before and after a move
--------------------------------------------------------------------------------

local function inv_names(inv)
	local out = {}
	if not inv then return "none" end
	for i = 1, #inv do out[#out + 1] = inv[i].valid_for_read and (inv[i].name .. "x" .. inv[i].count) or "-" end
	return table.concat(out, ",")
end

local function snapshot()
	local t = storage.t
	local out = {}
	local function put(k, v) out[#out + 1] = k .. "=" .. tostring(v) end
	local net = remote.call(NET, "network", t.ctrl)
	put("status", net and net.status)
	put("cells", net and net.cells)
	put("drives", net and net.drives)
	for _, name in ipairs({ "iron-plate", "copper-plate", "steel-plate", "me-capacity-card" }) do
		put(name, remote.call(NET, "count", t.ctrl, name))
	end
	put("water", remote.call(NET, "fluid_count", t.ctrl, "water"))
	local info = remote.call(AC, "provider_info", t.provider)
	local slot = info and info.slots and info.slots[1]
	put("pattern", slot and (tostring(slot.kind) .. ":" .. tostring(slot.recipe)) or "none")
	put("provider priority", remote.call(AC, "get_priority", t.provider))
	local bus = remote.call(IO, "get_bus", t.xbus)
	put("export filters", bus and table.concat(bus.filters, ",") or "none")
	put("export cards", inv_names(remote.call(IO, "bus_inventory", t.xbus)))
	put("interface", serpent.line(remote.call(IO, "get_interface_config", t.iface)))
	put("storage bus", serpent.line((remote.call(SB, "get_settings", t.sbus) or {}).mode))
	put("port cells", inv_names(remote.call(PORT, "cells", t.port)))
	local wb = remote.call(BENCH, "info", t.bench)
	put("workbench", wb and tostring(wb.cell and (wb.cell.name or true) or wb.name or "empty") or "none")
	local mt = remote.call("gregtorio-me-circuit", "get_maintainer", t.maint)
	put("maintainer", mt and (tostring(mt.key) .. ":" .. tostring(mt.amount)) or "none")
	local pi, po = remote.call(P2P, "info", t.tunnel_in), remote.call(P2P, "info", t.tunnel_out)
	put("tunnels", tostring(pi and pi.freq) .. "/" .. tostring(pi and pi.output) .. " " .. tostring(po and po.freq) .. "/" .. tostring(po and po.output))
	local qi = remote.call(QB, "info", t.bridge)
	put("bridge frequency", qi and (qi.freq or qi.frequency))
	local g = remote.call(AC, "group_info", t.cpu)
	put("cpu", g and (tostring(g.n or g.blocks) .. " blocks, " .. tostring(g.bytes) .. " bytes") or "none")
	return out
end

local function compare(before, after, skip)
	local problems = {}
	for i, row in ipairs(before) do
		local key = row:match("^[^=]+")
		if not (skip and skip[key]) and after[i] ~= row then problems[#problems + 1] = "was " .. row .. ", now " .. tostring(after[i]) end
	end
	return problems
end

--------------------------------------------------------------------------------
--- the move, as Space Exploration's scripts/spaceship-clone.lua makes it
--------------------------------------------------------------------------------

local KEYS = { "ctrl", "drive", "provider", "iface", "port", "bench", "pterm", "ap", "maint", "chest", "sbus", "xchest", "xbus",
	"tunnel_in", "tunnel_out", "cpu", "cpu2", "bridge", "machine" }

--- the ship's tiles x1..y2 of `from` go to `to` at the offset dx, dy. Returns what lies on the ground at the old place.
local function fly(from, to, x1, y1, x2, y2, dx, dy)
	local t = storage.t
	tiles(to, "se-spaceship-floor", x1 + dx, y1 + dy, x2 + dx, y2 + dy)
	local positions = {}
	for x = x1, x2 do for y = y1, y2 do positions[#positions + 1] = { x = x, y = y } end end
	local where = {}
	for _, k in ipairs(KEYS) do
		if t[k] and t[k].valid then where[k] = { t[k].name, t[k].position } end
	end
	from.clone_brush{ source_offset = { 0, 0 }, destination_offset = { dx, dy }, destination_surface = to, clone_tiles = false,
		clone_entities = true, clone_decoratives = false, clear_destination_entities = false,
		clear_destination_decoratives = false, expand_map = true, source_positions = positions }
	for _, p in ipairs(positions) do
		for _, e in pairs(from.find_entities_filtered{ area = { { p.x, p.y }, { p.x + 1, p.y + 1 } } }) do
			if e.valid and e.type ~= "character" then e.destroy({ raise_destroy = true }) end
		end
	end
	tiles(from, from.name == "nauvis" and "refined-concrete" or "se-space", x1, y1, x2, y2)
	for k, w in pairs(where) do
		t[k] = to.find_entity(w[1], { w[2].x + dx, w[2].y + dy })
	end
	local spilled = from.find_entities_filtered{ type = "item-entity", area = { { x1 - 3, y1 - 3 }, { x2 + 4, y2 + 4 } } }
	for _, e in pairs(spilled) do log("DEVCHECK-SE-SPILLED " .. e.stack.name .. " x" .. e.stack.count .. " on " .. from.name) end
	return #spilled
end

local function moved_ok(problems, spilled, from)
	local t = storage.t
	if spilled > 0 then problems[#problems + 1] = spilled .. " item stacks lie on the ground where the ship stood" end
	for _, k in ipairs(KEYS) do
		if not (t[k] and t[k].valid) then problems[#problems + 1] = k .. " did not arrive" end
	end
	if from and from.valid then                              -- (a landed ship's own surface is deleted by Space Exploration)
		local hook = remote.call(MOVE, "space_exploration_delete_surface", { surface_index = from.index })
		if not (hook and hook.allow_delete) then problems[#problems + 1] = "members are still recorded on " .. from.name end
	end
	local ok, why = remote.call(NET, "sweep_list_ok")
	if not ok then problems[#problems + 1] = "the graph's sweep list: " .. tostring(why) end
	if remote.call(MOVE, "stale") > 0 then problems[#problems + 1] = remote.call(MOVE, "stale") .. " members without an entity" end
end

--------------------------------------------------------------------------------
--- the run
--------------------------------------------------------------------------------

local STEPS = {}

STEPS[10] = function()
	place_test()
	build()
end

STEPS[200] = function()
	local t = storage.t
	storage.before = snapshot()
	local problems = {}
	local net = remote.call(NET, "network", t.ctrl)
	if not (net and net.status == "ok") then problems[#problems + 1] = "the network in orbit does not work: " .. tostring(net and net.status) end
	if not remote.call(NET, "same_network", t.bridge, t.n_bridge) then problems[#problems + 1] = "the quantum bridge orbit - Nauvis is not linked" end
	if t.iface.get_item_count("iron-plate") ~= 50 then problems[#problems + 1] = "the interface in orbit holds " .. t.iface.get_item_count("iron-plate") .. " iron plates, not 50" end
	local hook = remote.call(MOVE, "space_exploration_delete_surface", { surface_index = t.ctrl.surface.index })
	if not hook or hook.allow_delete ~= false then problems[#problems + 1] = "the surface with the network may be deleted" end
	report("ORBIT", problems, "the network works in " .. t.ctrl.surface.name .. " on power of that surface, bridged to Nauvis: " .. table.concat(storage.before, "; "))
	--- the launch
	problems = {}
	local from = t.ctrl.surface
	local flight = game.create_surface(FLIGHT, { width = 128, height = 128 })
	local old_ctrl = t.ctrl.unit_number
	local spilled = fly(from, flight, SHIP.x1, SHIP.y1, SHIP.x2, SHIP.y2, 0, 0)
	moved_ok(problems, spilled, from)
	if t.ctrl and t.ctrl.valid then
		for _, p in ipairs(compare(storage.before, snapshot(), { status = true })) do problems[#problems + 1] = p end
		if remote.call(MOVE, "resolve", old_ctrl) ~= t.ctrl.unit_number then problems[#problems + 1] = "the controller's old unit number does not lead to the new one" end
	end
	report("LAUNCH", problems, "moved to " .. FLIGHT .. " by clone_brush and raise_destroy, " .. spilled .. " stacks spilled")
end

STEPS[330] = function()
	local t = storage.t
	local problems = {}
	for _, p in ipairs(compare(storage.before, snapshot())) do problems[#problems + 1] = p end
	if not remote.call(NET, "same_network", t.bridge, t.n_bridge) then problems[#problems + 1] = "the quantum bridge ship - Nauvis is not linked" end
	if t.iface.get_item_count("iron-plate") ~= 50 then problems[#problems + 1] = "the interface holds " .. t.iface.get_item_count("iron-plate") .. " iron plates, not 50" end
	report("TRAVEL", problems, "the network works on the ship's surface, bridged to Nauvis")
	problems = {}
	local from = t.ctrl.surface
	local spilled = fly(from, game.surfaces.nauvis, SHIP.x1, SHIP.y1, SHIP.x2, SHIP.y2, LAND.dx, LAND.dy)
	moved_ok(problems, spilled, from)
	if t.ctrl and t.ctrl.valid then
		for _, p in ipairs(compare(storage.before, snapshot(), { status = true })) do problems[#problems + 1] = p end
	end
	report("LAND", problems, "moved onto Nauvis, " .. spilled .. " stacks spilled")
end

STEPS[460] = function()
	local t = storage.t
	local problems = {}
	for _, p in ipairs(compare(storage.before, snapshot())) do problems[#problems + 1] = p end
	if not remote.call(NET, "same_network", t.bridge, t.n_bridge) then problems[#problems + 1] = "the quantum bridge is not linked after the landing" end
	if t.iface.get_item_count("iron-plate") ~= 50 then problems[#problems + 1] = "the interface holds " .. t.iface.get_item_count("iron-plate") .. " iron plates, not 50" end
	if t.n_iface.get_item_count("copper-plate") ~= 20 then
		problems[#problems + 1] = "the interface of the partner network holds " .. t.n_iface.get_item_count("copper-plate") .. " copper plates through the bridge, not 20"
	end
	report("LANDED", problems, "the network works on Nauvis as before the launch")
	--- COPY: a clone whose source stays
	problems = {}
	local n = game.surfaces.nauvis
	local p = t.drive.position
	local copy = t.drive.clone{ position = { p.x, p.y + 12 }, surface = n }
	storage.copy = copy
	local net = remote.call(NET, "network", t.ctrl)
	if not copy then problems[#problems + 1] = "the drive was not cloned"
	else
		local cells
		for _, row in ipairs(storage.before) do cells = cells or row:match("^cells=(%d+)") end
		if not (net and tostring(net.cells) == cells) then
			problems[#problems + 1] = "the source lost cells to its clone: " .. tostring(net and net.cells) .. " of " .. tostring(cells)
		end
		local cnet = remote.call(NET, "network", copy)
		if cnet and (cnet.cells or 0) > 0 and cnet.id ~= (net and net.id) then problems[#problems + 1] = "the clone has cells" end
	end
	report("COPY", problems, "a cloned drive whose source stays is empty")
	--- PAD: Space Exploration's containers
	problems = {}
	local base = { x = LAND.dx - 80, y = LAND.dy }             -- (clear of the landed ship)
	tiles(n, "refined-concrete", base.x - 12, base.y - 14, base.x + 40, base.y + 12)
	for _, e in pairs(n.find_entities_filtered{ area = { { base.x - 12, base.y - 14 }, { base.x + 41, base.y + 13 } } }) do
		if e.valid and e.type ~= "character" then e.destroy() end
	end
	local pads = {}
	for i, name in ipairs({ "cargo-landing-pad", "se-delivery-cannon-chest", "se-rocket-launch-pad" }) do
		if prototypes.entity[name] then
			local x = base.x + (i - 1) * 14
			--- (without raise_built: Space Exploration's scripts refuse a pad of a force without players, and a headless run has
			--- none; the buses work with the container itself)
			local pad = place(n, problems, name, x, base.y, { raise_built = false })
			if pad then
				local box = pad.bounding_box
				local bus = place(n, problems, "me-storage-bus", math.floor(pad.position.x) + 0.5, math.floor(box.left_top.y) - 0.5,
					{ direction = defines.direction.south })
				local ctrl = place(n, problems, "me-network-controller", math.floor(pad.position.x) + 4, math.floor(box.left_top.y) - 3)
				local eei = place(n, problems, "electric-energy-interface", math.floor(pad.position.x) + 8, math.floor(box.left_top.y) - 3)
				place(n, problems, "substation", math.floor(pad.position.x) + 6, math.floor(box.left_top.y) - 6)
				if eei then eei.power_production = 5e6 eei.electric_buffer_size = 5e7 eei.energy = 5e7 end
				if bus and ctrl then remote.call(NET, "connect", { ctrl, bus }, 16) end
				local got = pad.insert{ name = "iron-plate", count = 77 }
				pads[#pads + 1] = { name = name, ctrl = ctrl, bus = bus, got = got }
			end
		else
			problems[#problems + 1] = "no entity " .. name
		end
	end
	storage.pads = pads
	for _, p2 in ipairs(problems) do fail("PAD: " .. p2) end
end

STEPS[700] = function()
	local problems = {}
	for _, pad in ipairs(storage.pads or {}) do
		local n = pad.ctrl and pad.ctrl.valid and remote.call(NET, "count", pad.ctrl, "iron-plate")
		if n ~= pad.got or pad.got == 0 then
			problems[#problems + 1] = "the storage bus on " .. pad.name .. " shows " .. tostring(n) .. " of " .. tostring(pad.got) .. " iron plates"
		elseif remote.call(NET, "extract", pad.ctrl, "iron-plate", 7) ~= 7 then
			problems[#problems + 1] = "the network cannot take from " .. pad.name
		end
	end
	report("PAD", problems, #(storage.pads or {}) .. " containers of Space Exploration read and emptied through a storage bus")
	--- SURFACE: a surface with a network is deleted
	problems = {}
	local s = game.create_surface("me-se-gone", { width = 64, height = 64 })
	tiles(s, "se-space-platform-scaffold", -8, -8, 8, 8)
	local ctrl = place(s, problems, "me-network-controller", 0, 0)
	local drive = place(s, problems, "me-drive", 2.5, 0.5)
	if ctrl and drive then
		remote.call(NET, "connect", { ctrl, drive }, 8)
		local inv = cell("me-1k-storage-cell")
		remote.call(NET, "insert_cell", drive, inv[1], 1)
		inv.destroy()
	end
	storage.gone_before = remote.call(MOVE, "counts")
	game.delete_surface(s)
	for _, p2 in ipairs(problems) do fail("SURFACE: " .. p2) end
end

STEPS[720] = function()
	local problems = {}
	local now, before = remote.call(MOVE, "counts"), storage.gone_before or {}
	if game.surfaces["me-se-gone"] then problems[#problems + 1] = "the surface was not deleted" end
	if remote.call(MOVE, "stale") > 0 then problems[#problems + 1] = remote.call(MOVE, "stale") .. " members without an entity" end
	for _, k in ipairs({ "nodes", "nets", "drives" }) do
		local want = (before[k] or 0) - (k == "nodes" and (before.nodes_gone or 0) or 1)
		if k ~= "nodes" and now[k] ~= want then problems[#problems + 1] = k .. ": " .. tostring(now[k]) .. " after the deletion, expected " .. want end
	end
	if (now.nodes or 0) >= (before.nodes or 0) then problems[#problems + 1] = "members: " .. tostring(now.nodes) .. " after the deletion, " .. tostring(before.nodes) .. " before" end
	local ok, why = remote.call(NET, "sweep_list_ok")
	if not ok then problems[#problems + 1] = "the graph's sweep list: " .. tostring(why) end
	report("SURFACE", problems, "a deleted surface leaves no member, drive or network (" .. serpent.line(now) .. ")")
	log("DEVCHECK-SE-DONE " .. #fails .. " problems")
end

if not REAL_LAUNCH then
	script.on_event(defines.events.on_tick, function(event)
		local step = STEPS[event.tick]
		if step then step() end
	end)
end

--------------------------------------------------------------------------------
--- issue #706: the real launch, driven by the harness through RCON (devcheck.py launch)
--------------------------------------------------------------------------------

--- where every block of KEYS stands now (name, position, surface), to find its clone after Space Exploration moved the ship
local function remember()
	local t, where = storage.t, {}
	for _, k in ipairs(KEYS) do
		if t[k] and t[k].valid then where[k] = { t[k].name, t[k].position, t[k].surface.index } end
	end
	storage.where = where
end

if REAL_LAUNCH then
	remote.add_interface("me-se-launch", {
		--- the network inside a real spaceship in Nauvis Orbit; every technology researched (the integrity limit of the ship)
		build = function()
			game.forces.player.research_all_technologies()
			local line = build(true)
			remember()
			return "Space Exploration " .. tostring(script.active_mods[SE]) .. ": " .. line
		end,
		--- before the launch: the network works; what it holds is kept for the comparisons
		keep = function()
			local t = storage.t
			storage.before = snapshot()
			local problems = {}
			local net = remote.call(NET, "network", t.ctrl)
			if not (net and net.status == "ok") then problems[#problems + 1] = "the network in orbit does not work: " .. tostring(net and net.status) end
			if not remote.call(NET, "same_network", t.bridge, t.n_bridge) then problems[#problems + 1] = "the quantum bridge orbit - Nauvis is not linked" end
			if t.iface.get_item_count("iron-plate") ~= 50 then problems[#problems + 1] = "the interface in orbit holds " .. t.iface.get_item_count("iron-plate") .. " iron plates, not 50" end
			storage.old_ctrl = t.ctrl.unit_number
			remember()
			return report("ORBIT", problems, "the network works in " .. t.ctrl.surface.name .. ", bridged to Nauvis: " .. table.concat(storage.before, "; "))
		end,
		--- after Space Exploration moved the ship to `surface` by dx, dy: every block is found there, nothing lies where it
		--- stood, the network holds what it held (its status may still be settling: `works` checks it later)
		moved = function(key, surface, dx, dy)
			local t, problems = storage.t, {}
			local to = game.get_surface(surface)
			if not to then return report(key, { "no surface " .. tostring(surface) }, "") end
			local from
			for k, w in pairs(storage.where or {}) do
				from = from or game.get_surface(w[3])
				t[k] = to.find_entity(w[1], { w[2].x + dx, w[2].y + dy })
			end
			local spilled = 0
			if from and from.valid then
				local list = from.find_entities_filtered{ type = "item-entity", area = { { REAL.x1 - 3, REAL.y1 - 3 }, { REAL.x2 + 4, REAL.y2 + 4 } } }
				for _, e in pairs(list) do log("DEVCHECK-SE-SPILLED " .. e.stack.name .. " x" .. e.stack.count .. " on " .. from.name) end
				spilled = #list
			end
			moved_ok(problems, spilled, from)
			if t.ctrl and t.ctrl.valid then
				for _, p in ipairs(compare(storage.before, snapshot(), { status = true })) do problems[#problems + 1] = p end
				if remote.call(MOVE, "resolve", storage.old_ctrl) ~= t.ctrl.unit_number then
					problems[#problems + 1] = "the controller's first unit number does not lead to the one it has now"
				end
			end
			remember()
			return report(key, problems, "moved to " .. to.name .. " by Space Exploration, " .. spilled .. " stacks spilled")
		end,
		--- a while after a move: everything as before the launch, the bridge linked, the interfaces filled
		works = function(key)
			local t, problems = storage.t, {}
			for _, p in ipairs(compare(storage.before, snapshot())) do problems[#problems + 1] = p end
			if not remote.call(NET, "same_network", t.bridge, t.n_bridge) then problems[#problems + 1] = "the quantum bridge to Nauvis is not linked" end
			if t.iface.get_item_count("iron-plate") ~= 50 then problems[#problems + 1] = "the interface holds " .. t.iface.get_item_count("iron-plate") .. " iron plates, not 50" end
			if t.n_iface.get_item_count("copper-plate") ~= 20 then
				problems[#problems + 1] = "the interface of the partner network holds " .. t.n_iface.get_item_count("copper-plate") .. " copper plates through the bridge, not 20"
			end
			return report(key, problems, "the network works on " .. t.ctrl.surface.name .. " as before the launch")
		end,
		failures = function() return #fails end,
	})
end
