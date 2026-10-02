--------------------------------------------------------------------------------
--- ME NETWORK: THE OLD FLUID BLOCKS BECOME THE UNIFIED BLOCKS (issue #3; docs/ME-REWORK.md "Items and fluids in
--- one block")
--- The ME Interface, ME Import Bus, ME Export Bus and ME Storage Bus handle items and fluids; the ME Fluid
--- Interface, ME Fluid Import / Export Bus and ME Fluid Storage Bus are hidden prototypes (prototypes/fluids.lua) so
--- saves load them. From on_configuration_changed (after the graph rebuild, the hand-over of a Gregtorio save and
--- the R1/R2 migrations, before the modules rebuild their records) this module replaces every placed one in place
--- with its settings and without losing fluid, turns their ghosts into ghosts of the unified blocks, their items in
--- inventories, cells, blueprints and patterns into the unified items, and logs what it did (FORK-ME-MIGRATE:
--- unified). The build event does the same for an old block or ghost built from an old blueprint. Idempotent: what
--- it converts disappears.
--- Rules of the conversion:
---   * fluid interface: import mode -> no config (every side imports); export mode -> row 1 = its fluid at its level,
---     tied to all four sides. Its tank's share of the fluid segment (lost when the tank goes) goes into the new
---     sides (the tied ones first), then into the network's drives.
---   * fluid import / export bus: direction and filters ("fluid/<name>"); fluid storage bus: direction, mode,
---     priority, filters (its segment is claimed again at its first visit).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local io = require("scripts.fork-me-io")
local sbus = require("scripts.fork-me-storagebus")
local P = require("scripts.fork-me-patterns")

local M = {}

local EPS = 1e-6
local IFACE_TAG, BUS_TAG, SBUS_TAG = "fork_me_interface", "fork_me_bus", "fork_me_storage_bus"
local OLD_IFACE_TAG, OLD_SBUS_TAG = "fork_me_fluid_interface", "fork_me_fluid_storage_bus"
--- the inventories that may hold items: chests, vehicles, corpses, platform hubs (missing types are skipped)
local CARRIERS = { "container", "logistic-container", "infinity-container", "car", "cargo-wagon", "spider-vehicle",
	"character", "character-corpse", "space-platform-hub", "cargo-landing-pad" }

local function md()
	local m = prototypes.mod_data["fork-me-fluids"]
	return m and m.data or {}
end

--- old entity -> unified entity, old item -> unified item, the old fluid interface's name
local function maps()
	local u = md().unified or {}
	return u.entities or {}, u.items or {}, (md().interface or {}).name or "me-fluid-interface"
end

local function gps(surface, p)
	return string.format("[gps=%d,%d,%s]", math.floor(p.x), math.floor(p.y), surface.name)
end

local function add(t, name, n) t[name] = (t[name] or 0) + n end

--------------------------------------------------------------------------------
--- settings
--------------------------------------------------------------------------------

--- the interface config and sides of an old fluid interface's settings { mode, fluid, level }
local function interface_settings(old)
	if type(old) == "table" and old.mode == "export" and type(old.fluid) == "string" and prototypes.fluid[old.fluid] then
		local level = math.floor(tonumber(old.level) or 0)
		return { [1] = { type = "fluid", name = old.fluid, amount = level } }, { 1, 1, 1, 1 }
	end
	return {}, {}
end

local function fluid_keys(names)
	local out = {}
	for _, name in pairs(type(names) == "table" and names or {}) do
		if type(name) == "string" then out[#out + 1] = N.is_fluid_key(name) and name or ("fluid/" .. name) end
	end
	return out
end

--- the tags of a unified block from the tags of an old one (other tags are kept)
function M.convert_tags(old_name, tags)
	local out = {}
	for k, v in pairs(type(tags) == "table" and tags or {}) do out[k] = v end
	local _, _, iface = maps()
	if old_name == iface then
		local o = out[OLD_IFACE_TAG]
		out[OLD_IFACE_TAG] = nil
		if type(o) == "table" then
			local config, sides = interface_settings(o)
			if next(config) then out[IFACE_TAG] = io.interface_tag(config, sides) end
		end
	elseif type(out[BUS_TAG]) == "table" then
		out[BUS_TAG] = { filters = fluid_keys(out[BUS_TAG].filters) }
	elseif type(out[OLD_SBUS_TAG]) == "table" then
		out[SBUS_TAG] = sbus.settings_of_tags(out)
		out[OLD_SBUS_TAG] = nil
	end
	return next(out) and out or nil
end

--------------------------------------------------------------------------------
--- placed blocks
--------------------------------------------------------------------------------

--- { fluid -> amount } of a fluid box's segment (or of the box alone)
local function segment_of(entity, box)
	local fb = entity.fluidbox
	local out = {}
	local c = fb.get_fluid_segment_id(box) and fb.get_fluid_segment_contents(box)
	if c then
		for name, n in pairs(c) do out[name] = n end
	else
		local f = fb[box]
		if f and f.amount > EPS then out[f.name] = f.amount end
	end
	return out
end

--- the old block's settings, read before it goes
local function settings_of(old, iface)
	local unit = old.unit_number
	if old.name == iface then
		local s = storage.fork_me_fluids
		return { interface = s and s.interfaces and s.interfaces[unit] or nil }
	end
	local ext = N.ext_get(unit)
	if ext and ext.ext == "fluid-storage-bus" then
		return { storage = { mode = ext.mode, priority = ext.priority, filters = fluid_keys(ext.filters) } }
	end
	local io_s = storage.fork_me_io
	local rec = io_s and io_s.recs and io_s.recs[unit]
	return { filters = fluid_keys(rec and (rec.keys or rec.filters) or {}) }
end

--- apply the old settings (or the converted tags of a built ghost) to the unified block
local function apply(new, old_name, settings, tags, iface)
	if tags then
		io.on_built(new, tags)
		sbus.on_built(new, tags)
		return
	end
	if old_name == iface then
		local config, sides = interface_settings(settings.interface)
		io.set_interface_config(new, config, sides)
	elseif settings.storage then
		sbus.set_settings(new, settings.storage)
	else
		io.set_bus_filters(new, settings.filters or {})
	end
end

--- Put the old fluid interface's share of its segment back: into the new sides (the tied ones first, then any side
--- whose segment holds nothing else), then into the network. Returns the amount placed.
local function restore(new, name, amount, temperature)
	local left = amount
	local tanks = io.tanks_of(new) or {}
	local sides = io.get_interface_sides(new) or {}
	local order = {}
	for d = 1, 4 do if type(sides[d]) == "number" then order[#order + 1] = d end end
	for d = 1, 4 do if type(sides[d]) ~= "number" then order[#order + 1] = d end end
	for _, d in ipairs(order) do
		local t = tanks[d]
		if left <= EPS then break end
		if t and t.valid then
			local other = false
			for n, a in pairs(segment_of(t, 1)) do if n ~= name and a > EPS then other = true end end
			if not other then left = left - t.insert_fluid{ name = name, amount = left, temperature = temperature } end
		end
	end
	if left > EPS then
		local net = N.network_of(new)
		if net then left = left - N.store_fluid_in_network(net, name, left) end
	end
	return amount - math.max(0, left)
end

--- Replace one old block by the unified one. `tags`: the blueprint tags of a robot-built one (else the settings are
--- read from the old block's records). Returns the new entity.
local function replace(old, tags, report, raise)
	local entities, _, iface = maps()
	local target = entities[old.name]
	if not target then return nil end
	local surface, position, direction, force = old.surface, old.position, old.direction, old.force
	local quality, last_user, old_name = old.quality, old.last_user, old.name
	local settings = settings_of(old, iface)
	local share, temperature = {}, nil
	if old_name == iface then
		local held = old.fluidbox[1]
		temperature = held and held.temperature
		for name, n in pairs(segment_of(old, 1)) do share[name] = n end   -- the segment now; minus what is left after
	end
	if raise then script.raise_script_destroy{ entity = old } end      -- the modules let the old block go
	if old.valid then old.destroy() end
	local new = surface.create_entity{ name = target, position = position, direction = direction, force = force,
		quality = quality, raise_built = true, create_build_effect_smoke = false }
	if not new then
		report.failed = report.failed + 1
		log("FORK-ME-MIGRATE: unified: could not place " .. target .. " at " .. position.x .. "," .. position.y)
		return nil
	end
	if last_user then new.last_user = last_user end
	apply(new, old_name, settings, tags and M.convert_tags(old_name, tags), iface)
	report.blocks = report.blocks + 1
	if next(share) then
		--- what the new sides' segments hold now: the rest of the old segment; the difference was the old tank's
		local after, seen = {}, {}
		for d, t in pairs(io.tanks_of(new) or {}) do
			local id = t.fluidbox.get_fluid_segment_id(1)
			local key = id and ("s" .. id) or ("t" .. d)
			if not seen[key] then
				seen[key] = true
				for name, n in pairs(segment_of(t, 1)) do add(after, name, n) end
			end
		end
		for name, n in pairs(share) do
			local lost = n - (after[name] or 0)
			if lost > EPS then
				add(report.before, name, lost)
				add(report.after, name, restore(new, name, lost, temperature))
			end
		end
	end
	return new
end

--------------------------------------------------------------------------------
--- items
--------------------------------------------------------------------------------

local convert_stack

--- the old blocks of a blueprint (also in a book) become the unified ones, with their tags
local function convert_blueprint(stack, report)
	local ok, ents = pcall(stack.get_blueprint_entities)
	if not (ok and ents) then return end
	local entities = maps()
	local changed = false
	for _, be in pairs(ents) do
		local new = entities[be.name]
		if new then
			be.tags = M.convert_tags(be.name, be.tags)
			be.name = new
			changed = true
		end
	end
	if changed then
		stack.set_blueprint_entities(ents)
		report.blueprints = report.blueprints + 1
	end
end

convert_stack = function(stack, report)
	if not (stack and stack.valid_for_read) then return end
	local _, items = maps()
	local new = items[stack.name]
	if new then
		report.items = report.items + stack.count
		stack.set_stack{ name = new, count = stack.count, quality = stack.quality.name }
	elseif stack.is_blueprint then
		convert_blueprint(stack, report)
	elseif stack.is_blueprint_book then
		local inv = stack.get_inventory(defines.inventory.item_main)
		for i = 1, inv and #inv or 0 do convert_stack(inv[i], report) end
	end
end

local function convert_inventory(inv, report)
	if not (inv and inv.valid) then return end
	for i = 1, #inv do
		local stack = inv[i]
		if stack.valid_for_read then convert_stack(stack, report) end
	end
end

local function convert_items(report)
	for _, player in pairs(game.players) do
		for _, id in pairs({ defines.inventory.character_main, defines.inventory.character_trash, defines.inventory.god_main }) do
			local ok, inv = pcall(function() return player.get_inventory(id) end)
			if ok and inv then convert_inventory(inv, report) end
		end
		if player.cursor_stack then convert_stack(player.cursor_stack, report) end
	end
	for _, surface in pairs(game.surfaces) do
		for _, t in pairs(CARRIERS) do
			local ok, list = pcall(surface.find_entities_filtered, { type = t })
			for _, e in pairs(ok and list or {}) do
				for id = 1, e.get_max_inventory_index() do
					convert_inventory(e.get_inventory(id), report)
				end
			end
		end
		for _, e in pairs(surface.find_entities_filtered{ name = "item-on-ground" }) do convert_stack(e.stack, report) end
	end
	report.items = report.items + N.apply_aliases()                  -- the cells in the drives
	--- encoded patterns in the providers (patterns read later are converted when they are read, P.normalize)
	local ac = storage.fork_ae2
	for _, p in pairs(ac and ac.providers or {}) do
		for slot, raw in pairs(p.slots or {}) do
			local def = P.normalize(raw)
			if def then p.slots[slot] = def end
		end
	end
end

--------------------------------------------------------------------------------
--- the migration and the build event
--------------------------------------------------------------------------------

local function new_report()
	return { blocks = 0, ghosts = 0, items = 0, blueprints = 0, failed = 0, before = {}, after = {} }
end

local function sum(t)
	local n = 0
	for _, v in pairs(t) do n = n + v end
	return n
end

--- on_configuration_changed: every old block, ghost and item
function M.run()
	local entities, items = maps()
	local names = {}
	for old in pairs(entities) do
		if prototypes.entity[old] then names[#names + 1] = old end
	end
	if #names == 0 and not next(items) then return end
	table.sort(names)
	local report = new_report()
	for _, surface in pairs(game.surfaces) do
		local list = surface.find_entities_filtered{ name = names }
		table.sort(list, function(a, b) return a.unit_number < b.unit_number end)
		for _, old in ipairs(list) do
			if old.valid then replace(old, nil, report, true) end
		end
		for _, g in pairs(surface.find_entities_filtered{ ghost_name = names }) do
			local target = entities[g.ghost_name]
			local ghost = surface.create_entity{ name = "entity-ghost", inner_name = target, position = g.position,
				direction = g.direction, force = g.force, quality = g.quality, tags = M.convert_tags(g.ghost_name, g.tags) }
			if ghost then
				g.destroy()
				report.ghosts = report.ghosts + 1
			end
		end
	end
	--- the items once per save (nothing makes old items afterwards: old blueprints are converted when they are built,
	--- cells in inventories when they are put into a drive, patterns when they are read)
	local done = storage.fork_me_unify and storage.fork_me_unify.items_done
	if not done and next(items) then convert_items(report) end
	if report.blocks + report.ghosts + report.items + report.blueprints + report.failed == 0 then
		storage.fork_me_unify = storage.fork_me_unify or { blocks = 0, ghosts = 0, items = 0, blueprints = 0, failed = 0,
			before = 0, after = 0 }
		storage.fork_me_unify.items_done = true
		return
	end
	local before, after = sum(report.before), sum(report.after)
	local line = string.format("%d blocks, %d ghosts, %d items, %d blueprints; fluid in the old tanks %.1f units, %.1f kept",
		report.blocks, report.ghosts, report.items, report.blueprints, before, after)
	log("FORK-ME-MIGRATE: unified: " .. line)
	if report.failed > 0 or after < before - 0.01 then
		game.print({ "fork-me-net.unified-loss", line })
	end
	storage.fork_me_unify = { blocks = report.blocks, ghosts = report.ghosts, items = report.items,
		blueprints = report.blueprints, failed = report.failed, before = before, after = after, items_done = true }
end

--- The build event (control.lua, before every other module): an old block built by a robot from a ghost (its
--- prototype is placeable by the unified item) becomes the unified block, a ghost of one a ghost of the unified
--- block. Returns true when the entity was replaced (the other modules skip it).
function M.on_built(entity, tags)
	if not (entity and entity.valid) then return false end
	local entities = maps()
	if entity.type == "entity-ghost" then
		local target = entities[entity.ghost_name]
		if not target then return false end
		local surface = entity.surface
		local ghost = surface.create_entity{ name = "entity-ghost", inner_name = target, position = entity.position,
			direction = entity.direction, force = entity.force, quality = entity.quality,
			tags = M.convert_tags(entity.ghost_name, entity.tags), raise_built = false }
		if ghost then entity.destroy() end
		return true
	end
	if not entities[entity.name] then return false end
	replace(entity, tags or {}, new_report(), false)
	return true
end

--- the report of the last run (the runtime and migration tests)
function M.report() return storage.fork_me_unify end

return M
