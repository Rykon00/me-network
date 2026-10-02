--------------------------------------------------------------------------------
--- FORK AE2: MIGRATION OF OLD ME NETWORKS (issue #68, step R1; the rule is in docs/ME-REWORK.md, "Migration")
--- Before issue #68 the ME network was the logistic network: the controller a roboport (`me-controller`),
--- the drives logistic storage chests (`me-drive-1k` ... `me-drive-256k`) holding the items, the interface a
--- requester chest (`me-interface`). Those prototypes stay hidden so saves load them. This module runs from
--- on_configuration_changed (after the graph rebuild) whenever such entities exist, and replaces them:
---   1. the old entities are grouped by the logistic network they stood in (one group = one old ME network);
---      the ME members of the new kind in that logistic network (terminals, CPUs, providers, fluid drives,
---      ...) join the group;
---   2. every item in the old drives and interfaces is counted;
---   3. the first old controller becomes an ME Controller in place, the others are removed and their item goes
---      into the network; a group without one gets a new controller next to its first member;
---   4. every old drive becomes an ME Drive with four cells of its tier holding its contents (the 256k drive's
---      acceleration card goes into the network), every old interface an ME Interface (its contents and
---      trash go into the network);
---   5. what the cells cannot take, and stacks the network cannot store, go into iron chests next to the
---      controller (spilled there if no chest fits);
---   6. cables connect the group's members to the controller (scripts/fork-me-network.lua, connect);
---   7. ghosts of old entities become ghosts of the new ones;
---   8. the item totals of step 2 are compared with the cells, chests and spilled items (FORK-ME-MIGRATE in
---      the log, a chat message on a difference).
--- The report of the last run is kept in storage.fork_me_migrate (remote: gregtorio-me-network, migration).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local io = require("scripts.fork-me-io")

local M = {}

local CHEST = "iron-chest"
local MARGIN = 16                    -- tiles around a group in which cables are routed

local function md()
	local m = prototypes.mod_data["fork-me-network"]
	return m and m.data or nil
end

local function gps(surface, p)
	return string.format("[gps=%d,%d,%s]", math.floor(p.x), math.floor(p.y), surface.name)
end

local function count_stack(t, stack)
	local key = stack.name .. "@" .. stack.quality.name
	t[key] = (t[key] or 0) + stack.count
end

--- the stacks of some inventories, copied with their data into one script inventory
local function collect(inventories)
	local n = 0
	for _, inv in pairs(inventories) do
		if inv then n = n + #inv - inv.count_empty_stacks() end
	end
	local out = game.create_inventory(math.max(1, n))
	local i = 1
	for _, inv in pairs(inventories) do
		if inv then
			for j = 1, #inv do
				if inv[j].valid_for_read then
					out[i].transfer_stack(inv[j])
					i = i + 1
				end
			end
		end
	end
	return out
end

--- the old ME entities of a surface, grouped by the logistic network they stand in
local function find_groups(surface, data)
	local old_names = { data.legacy.controller, data.legacy.interface }
	for name in pairs(data.legacy_drives) do old_names[#old_names + 1] = name end
	local groups, order = {}, {}
	local function group_of(force, ln, solo)
		local key = force.name .. ":" .. (ln and ("n" .. ln.network_id) or ("s" .. solo))
		local g = groups[key]
		if not g then
			g = { key = key, force = force, surface = surface, controllers = {}, drives = {}, interfaces = {}, members = {},
				ln = ln and ln.network_id }
			groups[key] = g
			order[#order + 1] = key
		end
		return g
	end
	local types = { roboport = true, ["logistic-container"] = true }
	local found = surface.find_entities_filtered{ name = old_names }
	table.sort(found, function(a, b) return a.unit_number < b.unit_number end)
	for _, e in ipairs(found) do
		if types[e.type] then
			local ln = e.logistic_network
			local g = group_of(e.force, ln, e.unit_number)
			if e.type == "roboport" then g.controllers[#g.controllers + 1] = e
			elseif data.legacy_drives[e.name] then g.drives[#g.drives + 1] = e
			else g.interfaces[#g.interfaces + 1] = e end
		end
	end
	if #order == 0 then return {} end
	--- the members of the new kind in the same logistic networks
	local by_ln = {}
	for _, key in ipairs(order) do
		local g = groups[key]
		if g.ln then by_ln[g.force.name .. ":" .. g.ln] = g end
	end
	local members = surface.find_entities_filtered{ name = N.node_names() }
	table.sort(members, function(a, b) return a.unit_number < b.unit_number end)
	for _, e in ipairs(members) do
		local ln = surface.find_logistic_network_by_position(e.position, e.force)
		local g = ln and by_ln[e.force.name .. ":" .. ln.network_id]
		if g then g.members[#g.members + 1] = e end
	end
	local out = {}
	for _, key in ipairs(order) do out[#out + 1] = groups[key] end
	return out
end

--- replace one old entity by `name` at the same spot; the new entity is registered in the graph
local function replace(old, name)
	local surface, position, force, direction = old.surface, old.position, old.force, old.direction
	old.destroy()
	local e = surface.create_entity{ name = name, position = position, force = force, direction = direction }
	if e then
		--- a new controller starts with an empty buffer: without this the network would be off for a tick
		if e.type == "electric-energy-interface" then e.energy = e.electric_buffer_size end
		N.on_built(e)
	end
	return e
end

local function add(t, key, n) t[key] = (t[key] or 0) + n end

local function migrate_group(g, data, report)
	local surface, force = g.surface, g.force
	local before, overflow = {}, {}              -- item@quality -> count; stacks that found no cell
	local stores = {}                            -- script inventories with what goes into the network
	local new_drives = {}
	--- 1) count and collect: drives first (each into its own cells), then interfaces
	local drive_stacks = {}
	for _, d in ipairs(g.drives) do
		local inv = collect({ d.get_inventory(defines.inventory.chest) })
		for i = 1, #inv do if inv[i].valid_for_read then count_stack(before, inv[i]) end end
		drive_stacks[#drive_stacks + 1] = { entity = d, name = d.name, inv = inv }
	end
	for _, f in ipairs(g.interfaces) do
		local inv = collect({ f.get_inventory(defines.inventory.chest), f.get_inventory(defines.inventory.logistic_container_trash) })
		for i = 1, #inv do if inv[i].valid_for_read then count_stack(before, inv[i]) end end
		stores[#stores + 1] = inv
	end
	local extra = game.create_inventory(#g.controllers + #g.drives + 1)
	--- 2) the controller
	local controller
	for i, c in ipairs(g.controllers) do
		if i == 1 then
			controller = replace(c, data.names.controller)
		else
			c.destroy()
			extra.insert{ name = "me-controller", count = 1 }
			add(before, "me-controller@normal", 1)
		end
	end
	if not controller then
		local first = g.drives[1] or g.interfaces[1] or g.members[1]
		local pos = first and surface.find_non_colliding_position(data.names.controller, first.position, 32, 1)
		controller = pos and surface.create_entity{ name = data.names.controller, position = pos, force = force }
		if controller then
			N.on_built(controller)
			report.controllers_added = report.controllers_added + 1
		end
	end
	--- 3) drives: an ME Drive with four cells of the old tier, filled with the old drive's contents
	for _, ds in ipairs(drive_stacks) do
		local info = data.legacy_drives[ds.name]
		local d = replace(ds.entity, data.names.drive)
		if d then
			new_drives[#new_drives + 1] = d
			local cells = game.create_inventory(1)
			for slot = 1, info.cells do
				cells[1].set_stack{ name = info.cell, count = 1 }
				N.insert_cell(d, cells[1], slot)
			end
			cells.destroy()
			for i = 1, #ds.inv do
				if ds.inv[i].valid_for_read then N.store_in_drive(d, ds.inv[i]) end
			end
			if info.extra and prototypes.item[info.extra.name] then
				extra.insert(info.extra)
				add(before, info.extra.name .. "@normal", info.extra.count)
			end
		end
		stores[#stores + 1] = ds.inv              -- the rest goes into any cell of the group
	end
	--- 4) interfaces
	local new_interfaces = {}
	for _, f in ipairs(g.interfaces) do
		local e = replace(f, data.names.interface)
		if e then
			io.on_built(e)
			new_interfaces[#new_interfaces + 1] = e
		end
	end
	stores[#stores + 1] = extra
	--- 5) everything left into the cells of the group's drives, the rest into chests next to the controller
	for _, inv in ipairs(stores) do
		for i = 1, #inv do
			local stack = inv[i]
			for _, d in ipairs(new_drives) do
				if not stack.valid_for_read then break end
				N.store_in_drive(d, stack)
			end
			if stack.valid_for_read then overflow[#overflow + 1] = stack end
		end
	end
	local chests, spilled = {}, {}
	local at = controller or g.drives[1] or g.members[1]
	local at_pos = at and at.valid and at.position or { x = 0, y = 0 }
	for _, stack in ipairs(overflow) do
		local placed = false
		for _, c in ipairs(chests) do
			local inv = c.get_inventory(defines.inventory.chest)
			for j = 1, #inv do
				if not inv[j].valid_for_read then
					inv[j].transfer_stack(stack)
					placed = true
					break
				end
			end
			if placed then break end
		end
		if not placed then
			local pos = surface.find_non_colliding_position(CHEST, at_pos, 32, 1)
			local c = pos and surface.create_entity{ name = CHEST, position = pos, force = force }
			if c then
				chests[#chests + 1] = c
				c.get_inventory(defines.inventory.chest)[1].transfer_stack(stack)
			else
				count_stack(spilled, stack)
				surface.spill_item_stack{ position = at_pos, stack = stack, allow_belts = false }
				stack.clear()
			end
		end
	end
	if #chests > 0 then
		force.print({ "fork-me-net.migrate-chest", #chests, gps(surface, chests[1].position) })
	end
	--- 6) cables: every member to the controller
	local members = { controller }
	for _, list in ipairs({ new_drives, new_interfaces, g.members }) do
		for _, e in ipairs(list) do if e.valid then members[#members + 1] = e end end
	end
	local cables, unreached = 0, {}
	if controller and controller.valid then
		cables, unreached = N.connect(members, MARGIN)
	end
	report.cables = report.cables + cables
	for _, e in ipairs(unreached) do
		report.unreached = report.unreached + 1
		log("FORK-ME-MIGRATE: no cable path to " .. e.name .. " at " .. e.position.x .. "," .. e.position.y)
		force.print({ "fork-me-net.migrate-unreached", e.localised_name, gps(surface, e.position) })
	end
	--- 7) check: the items before against the new cells, the chests and what was spilled
	local after = {}
	for _, d in ipairs(new_drives) do
		for _, cell in pairs(N.drive_info(d)) do
			for key, n in pairs(cell.items) do
				local name, q = N.parse_key(key)
				add(after, name .. "@" .. q, n)
			end
		end
	end
	for _, c in ipairs(chests) do
		local inv = c.get_inventory(defines.inventory.chest)
		for j = 1, #inv do if inv[j].valid_for_read then count_stack(after, inv[j]) end end
	end
	for k, n in pairs(spilled) do add(after, k, n) end
	local diff = {}
	for k, n in pairs(before) do if (after[k] or 0) ~= n then diff[#diff + 1] = k .. " " .. n .. "->" .. (after[k] or 0) end end
	for k, n in pairs(after) do if not before[k] then diff[#diff + 1] = k .. " 0->" .. n end end
	table.sort(diff)
	for k, n in pairs(before) do add(report.before, k, n) end
	for k, n in pairs(after) do add(report.after, k, n) end
	report.groups = report.groups + 1
	report.drives = report.drives + #new_drives
	report.chests = report.chests + #chests
	local total = 0
	for _, n in pairs(before) do total = total + n end
	log("FORK-ME-MIGRATE: " .. surface.name .. " " .. g.key .. ": " .. #g.controllers .. " controllers, " .. #new_drives
		.. " drives, " .. #new_interfaces .. " interfaces, " .. #g.members .. " other members, " .. total .. " items, "
		.. cables .. " cables, " .. #unreached .. " unreached, " .. #chests .. " overflow chests, "
		.. (#diff == 0 and "all items kept" or ("DIFFERENCE " .. table.concat(diff, ", "))))
	if #diff > 0 then
		report.diff = report.diff + #diff
		force.print({ "fork-me-net.migrate-diff", table.concat(diff, ", ") })
	end
	for _, inv in ipairs(stores) do if inv.valid then inv.destroy() end end
	if controller and controller.valid then
		force.print({ "fork-me-net.migrate-done", #new_drives, cables, gps(surface, controller.position) })
	end
end

--- ghosts of old entities become ghosts of the new ones (in the tested saves the game has already removed them
--- when the save is loaded: no item builds the old prototypes any more)
local function swap_ghosts(surface, data)
	local map = { [data.legacy.controller] = data.names.controller, [data.legacy.interface] = data.names.interface }
	for name in pairs(data.legacy_drives) do map[name] = data.names.drive end
	local names = {}
	for name in pairs(map) do names[#names + 1] = name end
	local n = 0
	for _, g in pairs(surface.find_entities_filtered{ ghost_name = names }) do
		local ok = (g.ghost_type == "roboport" or g.ghost_type == "logistic-container" or g.ghost_type == "simple-entity-with-force")
		if ok then
			local target, pos, force = map[g.ghost_name], g.position, g.force
			g.destroy()
			surface.create_entity{ name = "entity-ghost", inner_name = target, position = pos, force = force }
			n = n + 1
		end
	end
	return n
end

--------------------------------------------------------------------------------
--- fluids (issue #68, step R2): before R2 the fluid lived in script state per ME Fluid Drive
--- (storage.fork_me_fluids.drives), destroyed drives left recovered fluid (.recovered), upgrades held a drive's
--- fluid for a moment (.replacing), and a picked up fluid drive carried its fluid in its item's tags.
---   1. every old fluid drive becomes an ME Drive with four fluid cells of its tier holding its fluid (more cells
---      in the free slots if four cannot hold its types; the 256k drive's acceleration card goes into a chest);
---   2. recovered and held fluid goes into the fluid cells of the network it belonged to (its anchor, or an ME
---      member next to its position; also when that network is off), else into the nearest drive with fluid room
---      on the surface;
---   3. a loaded old fluid drive item in a player's inventory or a chest, car, wagon or spidertron keeps its item
---      (without tags: placing it gives its four empty cells) and its fluid comes as fluid cells into the same
---      inventory (spilled next to it when full);
---   4. what found no room is put into new fluid cells in an iron chest next to where it was;
---   5. the old fluid state is dropped; every unit is counted before and after (FORK-ME-MIGRATE).
--------------------------------------------------------------------------------

local function add_fluids(t, contents, factor)
	for name, amount in pairs(contents or {}) do
		if type(name) == "string" and type(amount) == "number" and amount > 0 and prototypes.fluid[name] then
			t[name] = (t[name] or 0) + amount * (factor or 1)
		end
	end
end

local function sum(t)
	local n = 0
	for _, v in pairs(t) do n = n + v end
	return n
end

--- the smallest fluid cell that holds `amount` of one fluid (else the biggest)
local function cell_for(data, amount)
	local best, biggest
	for name, spec in pairs(data.cells) do
		if spec.kind == "fluid" then
			local holds = (spec.bytes - spec.per_type) * (spec.per_byte or 8)
			if holds >= amount and (not best or spec.bytes < data.cells[best].bytes) then best = name end
			if not biggest or spec.bytes > data.cells[biggest].bytes then biggest = name end
		end
	end
	return best or biggest
end

--- stacks (definitions) into iron chests next to `position`; returns the chests (spilled when none fits)
local function chest_for(surface, force, position, defs, report)
	local inv_chest, n = nil, 0
	for _, def in ipairs(defs) do
		if not (inv_chest and inv_chest.valid and inv_chest.get_inventory(defines.inventory.chest).can_insert(def)) then
			local pos = surface.find_non_colliding_position(CHEST, position, 32, 1)
			inv_chest = pos and surface.create_entity{ name = CHEST, position = pos, force = force }
			if inv_chest then
				n = n + 1
				force.print({ "fork-me-net.migrate-fluid-chest", gps(surface, inv_chest.position) })
			end
		end
		if inv_chest then
			inv_chest.get_inventory(defines.inventory.chest).insert(def)
		else
			local tmp = game.create_inventory(1)
			tmp[1].set_stack(def)
			surface.spill_item_stack{ position = position, stack = tmp[1], allow_belts = false }
			tmp.destroy()
		end
	end
	report.chests = report.chests + n
end

--- the fluid of fluid cell stack definitions
local function fluid_of_defs(defs)
	local out = {}
	for _, def in ipairs(defs) do
		local items = def.tags and def.tags.fork_me_cell and def.tags.fork_me_cell.items or {}
		for key, amount in pairs(items) do
			if key:sub(1, 6) == "fluid/" then out[key:sub(7)] = (out[key:sub(7)] or 0) + amount end
		end
	end
	return out
end

--- fluid that lost its drive (recovered, held for an upgrade, a vanished drive): into its network, else into the
--- nearest drive with room, else into new cells in a chest. Adds what was stored to `after`.
local function place_fluid(data, surface, force, position, anchor, contents, after, report)
	local net = anchor and anchor.valid and N.network_of(anchor) or N.network_near(surface, position, force, 1.5, true)
	local left = {}
	for name, amount in pairs(contents) do
		local rest = amount
		if net then
			local got = N.store_fluid_in_network(net, name, rest)
			after[name] = (after[name] or 0) + got
			rest = rest - got
		end
		for _, d in ipairs(rest > 1e-6 and N.fluid_drives_near(surface.index, force.name, position, name) or {}) do
			if rest <= 1e-6 then break end
			local got = N.store_fluid_in_drive(d.entity, name, rest)
			after[name] = (after[name] or 0) + got
			rest = rest - got
		end
		if rest > 1e-6 then left[name] = rest end
	end
	if next(left) then
		local defs = {}
		for name, amount in pairs(left) do
			for _, def in ipairs(N.fluid_cells(cell_for(data, amount), { [name] = amount })) do defs[#defs + 1] = def end
		end
		add_fluids(after, fluid_of_defs(defs))
		chest_for(surface, force, position, defs, report)
	end
end

local CARRIERS = { "container", "logistic-container", "car", "cargo-wagon", "spider-vehicle" }

function M.run_fluids()
	local data = md()
	if not (data and data.legacy_drives) then return nil end
	local s = storage.fork_me_fluids or {}
	local old = {}                                     -- old fluid drive names -> legacy info
	for name, info in pairs(data.legacy_drives) do
		if info.fluid and prototypes.entity[name] then old[name] = info end
	end
	local names = {}
	for name in pairs(old) do names[#names + 1] = name end
	table.sort(names)
	local report = { drives = 0, cells_added = 0, items = 0, entries = 0, chests = 0, before = {}, after = {} }
	local before, after = report.before, report.after
	local records = s.drives or {}
	--- 1) old fluid drive entities
	for _, surface in pairs(game.surfaces) do
		local found = #names > 0 and surface.find_entities_filtered{ name = names } or {}
		table.sort(found, function(a, b) return a.unit_number < b.unit_number end)
		for _, e in ipairs(found) do
			local info = old[e.name]
			local rec = records[e.unit_number]
			local contents = {}
			add_fluids(contents, rec and rec.contents)
			records[e.unit_number] = nil
			add_fluids(before, contents)
			local surface_, force, pos = e.surface, e.force, e.position
			local d = replace(e, data.names.drive)
			if d then
				report.drives = report.drives + 1
				local cells = game.create_inventory(1)
				for slot = 1, info.cells do
					cells[1].set_stack{ name = info.cell, count = 1 }
					N.insert_cell(d, cells[1], slot)
				end
				cells.destroy()
				local left, added = N.fill_fluids(d, info.cell, contents)
				report.cells_added = report.cells_added + added
				for name, amount in pairs(contents) do after[name] = (after[name] or 0) + amount - (left[name] or 0) end
				local defs = N.fluid_cells(info.cell, left)
				add_fluids(after, fluid_of_defs(defs))
				if info.extra and prototypes.item[info.extra.name] then defs[#defs + 1] = { name = info.extra.name, count = info.extra.count } end
				if #defs > 0 then chest_for(surface_, force, pos, defs, report) end
			else
				place_fluid(data, surface_, force, pos, nil, contents, after, report)
			end
		end
	end
	--- 2) records of drives that vanished, recovered fluid, fluid held for an upgrade
	for _, rec in pairs(records) do
		local surface, force = rec.surface and game.get_surface(rec.surface), rec.force and game.forces[rec.force]
		if surface and force and rec.contents and next(rec.contents) then
			local contents = {}
			add_fluids(contents, rec.contents)
			add_fluids(before, contents)
			report.entries = report.entries + 1
			place_fluid(data, surface, force, rec.position or { x = 0, y = 0 }, nil, contents, after, report)
		end
	end
	for surface_index, per in pairs(s.recovered or {}) do
		local surface = game.get_surface(surface_index)
		for force_name, list in pairs(per) do
			local force = game.forces[force_name]
			for _, entry in ipairs(list) do
				local contents = {}
				add_fluids(contents, entry.contents)
				if surface and force and next(contents) then
					add_fluids(before, contents)
					report.entries = report.entries + 1
					place_fluid(data, surface, force, entry.position, entry.anchor, contents, after, report)
				end
			end
		end
	end
	for _, p in pairs(s.replacing or {}) do
		local surface, force = game.get_surface(p.surface), game.forces[p.force]
		local contents = {}
		add_fluids(contents, p.contents)
		if surface and force and next(contents) then
			add_fluids(before, contents)
			report.entries = report.entries + 1
			place_fluid(data, surface, force, p.position, nil, contents, after, report)
		end
	end
	--- 3) loaded old fluid drive items in inventories: the item stays (without tags), its fluid comes as cells
	local function convert(inv, surface, position, force)
		if not (inv and inv.valid) then return end
		for i = 1, #inv do
			local stack = inv[i]
			local info = stack.valid_for_read and old[stack.name]
			if info and stack.is_item_with_tags then
				local tags = stack.tags
				local fluid = tags and tags[info.fluid_tag]
				if type(fluid) == "table" then
					local contents = {}
					add_fluids(contents, fluid, stack.count)
					add_fluids(before, contents)
					stack.set_stack{ name = stack.name, count = stack.count, quality = stack.quality }   -- no tags, no description
					local defs = N.fluid_cells(info.cell, contents)
					add_fluids(after, fluid_of_defs(defs))
					report.items = report.items + 1
					for _, def in ipairs(defs) do
						if inv.insert(def) < 1 then chest_for(surface, force, position, { def }, report) end
					end
				end
			end
		end
	end
	if next(old) then
		for _, player in pairs(game.players) do
			if player.character or player.controller_type == defines.controllers.god then
				for _, id in pairs({ defines.inventory.character_main, defines.inventory.character_trash, defines.inventory.god_main }) do
					local ok, inv = pcall(function() return player.get_inventory(id) end)
					if ok and inv then convert(inv, player.surface, player.position, player.force) end
				end
			end
			if player.cursor_stack and player.cursor_stack.valid_for_read and old[player.cursor_stack.name] then
				local inv = player.get_main_inventory()
				if inv and inv.find_empty_stack() then
					local empty = inv.find_empty_stack()
					empty.transfer_stack(player.cursor_stack)
					convert(inv, player.surface, player.position, player.force)
				end
			end
		end
		for _, surface in pairs(game.surfaces) do
			for _, e in pairs(surface.find_entities_filtered{ type = CARRIERS }) do
				for id = 1, e.get_max_inventory_index() do
					local inv = e.get_inventory(id)
					if inv then convert(inv, surface, e.position, e.force) end
				end
			end
		end
	end
	--- 4) the old fluid state goes; the fluid interfaces stay (rebuilt by fork-me-fluids.lua)
	if storage.fork_me_fluids then
		storage.fork_me_fluids.drives, storage.fork_me_fluids.recovered, storage.fork_me_fluids.replacing = nil, nil, nil
		storage.fork_me_fluids.gui, storage.fork_me_fluids.prebuild, storage.fork_me_fluids.rcursor = nil, nil, nil
	end
	local b, a = sum(before), sum(after)
	if report.drives + report.entries + report.items == 0 then return report end
	local diff = {}
	for name, v in pairs(before) do
		if math.abs((after[name] or 0) - v) > 1e-3 then diff[#diff + 1] = name .. " " .. v .. "->" .. (after[name] or 0) end
	end
	for name, v in pairs(after) do if not before[name] then diff[#diff + 1] = name .. " 0->" .. v end end
	table.sort(diff)
	report.diff = #diff
	storage.fork_me_migrate_fluids = report
	log(string.format("FORK-ME-MIGRATE: fluids: %d fluid drives, %d recovered or held entries, %d loaded drive items, "
		.. "%.1f units before, %.1f after, %d cells added, %d chests, %s", report.drives, report.entries, report.items, b, a,
		report.cells_added, report.chests, #diff == 0 and "all fluid kept" or ("DIFFERENCE " .. table.concat(diff, ", "))))
	if #diff > 0 then game.print({ "fork-me-net.migrate-diff", table.concat(diff, ", ") }) end
	return report
end

--- Run the migration on every surface (idempotent: does nothing without old entities). Returns the report.
function M.run()
	local data = md()
	if not (data and data.names and data.names.controller) then return nil end
	local report = { groups = 0, drives = 0, cables = 0, unreached = 0, chests = 0, controllers_added = 0, ghosts = 0,
		diff = 0, before = {}, after = {}, tick = game.tick }
	for _, surface in pairs(game.surfaces) do
		for _, g in ipairs(find_groups(surface, data)) do migrate_group(g, data, report) end
		report.ghosts = report.ghosts + swap_ghosts(surface, data)
	end
	if report.groups > 0 or report.ghosts > 0 then
		storage.fork_me_migrate = report
		log("FORK-ME-MIGRATE: " .. report.groups .. " old ME networks, " .. report.drives .. " drives, " .. report.cables
			.. " cables, " .. report.unreached .. " unreached, " .. report.ghosts .. " ghosts, " .. report.diff .. " differences")
	end
	return report
end

remote.add_interface("gregtorio-me-migrate", {
	--- the report of the last migration that did something (nil if none ever ran)
	report = function() return storage.fork_me_migrate end,
	--- the report of the last fluid migration (issue #68, R2) that did something
	fluid_report = function() return storage.fork_me_migrate_fluids end,
})

return M
