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
			if info.extra then
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
		local ok = (g.ghost_type == "roboport" or g.ghost_type == "logistic-container")
		if ok then
			local target, pos, force = map[g.ghost_name], g.position, g.force
			g.destroy()
			surface.create_entity{ name = "entity-ghost", inner_name = target, position = pos, force = force }
			n = n + 1
		end
	end
	return n
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
})

return M
