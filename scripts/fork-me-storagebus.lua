--------------------------------------------------------------------------------
--- FORK AE2: ME STORAGE BUS (issue #68; prototypes/network.lua, docs/ME-REWORK.md "Storage bus")
---   * A rotatable 1x1 ME block that faces a chest, a logistic chest, the editor's infinity chest or a cargo wagon: that inventory
---     becomes storage of the network. The terminal shows what is in it, everything that extracts from the
---     network can take from it, and inserts go into it by its filter and priority.
---   * Settings: item filters (a whitelist: the bus shows and takes only these items; none = every item),
---     a priority (-1000 ... 1000, the order of R3 together with the drives) and a mode: read and write,
---     read only (the network takes from it, never puts into it) or write only (the network puts into it and
---     does not see what is in it). Kept in blueprints (tag fork_me_storage_bus), settings paste and clones.
---   * The bus's storage is an "external cell" of the storage engine (scripts/fork-me-network.lua): the
---     record below is that cell. Its `items` are a snapshot of the inventory; the engine keeps the
---     network's totals and index from it.
---   * Consistency: inserters and players change the inventory without an event. The I/O step (15 ticks,
---     scripts/fork-me-io.lua) visits VISITS_PER_STEP buses round robin; a visit reads the inventory once
---     (get_contents) and applies the difference to the snapshot (N.ext_sync). Between two visits the
---     snapshot may be stale; every insert and extract through the bus works on the real inventory (the
---     engine asks `count` before it takes and corrects the snapshot), so the network never hands out
---     items that are gone; it may show items that are gone (until the next visit or extract) or not yet
---     show items that came in (until the next visit).
---   * Rules: one bus per inventory (a second bus on the same inventory is refused with a status and takes
---     over when the first one goes); a bus facing an ME block is refused (no loops); removing the bus or
---     the inventory drops the inventory from the network.
--- State: the records live in the network module (storage.fork_me_net.ext, they are the cells); this module
--- keeps the visit list and which bus uses which inventory (storage.fork_me_sbus).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")

local M = {}

local KIND = "storage-bus"
local VISITS_PER_STEP = 8           -- bus visits per I/O step (every 15 ticks)
local MAX_FILTERS = 18
local MAX_PRIORITY = 1000
local TAG = "fork_me_storage_bus"   -- blueprint tag: { mode, priority, filters = { keys } }
local MODES = { readwrite = true, read = true, write = true }
local FRONT = {
	[defines.direction.north] = { 0, -1 }, [defines.direction.east] = { 1, 0 },
	[defines.direction.south] = { 0, 1 }, [defines.direction.west] = { -1, 0 },
}
--- entity types a storage bus works with, and their inventory
local INVENTORY = {
	["container"] = defines.inventory.chest,
	["logistic-container"] = defines.inventory.chest,
	["infinity-container"] = defines.inventory.chest,   -- the editor's infinity chest
	["cargo-wagon"] = defines.inventory.cargo_wagon,
}
--- item types the network cannot hold as plain items (the same rule as the cells, M.storable of the network)
local NOT_PLAIN = {
	["item-with-inventory"] = true, ["item-with-tags"] = true, ["item-with-entity-data"] = true, ["blueprint"] = true,
	["blueprint-book"] = true, ["deconstruction-item"] = true, ["upgrade-item"] = true, ["copy-paste-tool"] = true,
	["selection-tool"] = true, ["spidertron-remote"] = true, ["armor"] = true,
}

local function state()
	local s = storage.fork_me_sbus
	if not s then
		s = { list = {}, cursor = 1, claims = {} }     -- claims: inventory owner unit -> bus unit
		storage.fork_me_sbus = s
	end
	return s
end

local function is_bus(entity) return entity and entity.valid and N.kind_of(entity.name) == KIND end

--- the record (the external cell) of a bus
local function rec_of(entity)
	return entity and entity.valid and entity.unit_number and N.ext_get(entity.unit_number) or nil
end

--------------------------------------------------------------------------------
--- items
--------------------------------------------------------------------------------

local plain_cache = {}
--- can the network show and move this item through a storage bus? (plain items that do not spoil)
local function plain(name, quality)
	local k = name .. "@" .. quality
	local v = plain_cache[k]
	if v == nil then
		local p = prototypes.item[name]
		v = p ~= nil and not NOT_PLAIN[p.type] and p.get_spoil_ticks(quality) <= 0
		plain_cache[k] = v
	end
	return v
end

local function allowed(rec, key)
	return rec.partition == nil or rec.partition[key] == true
end

--- the target inventory if the bus may use it now (a cargo wagon only while it stands in front of the bus)
local function inventory_of(rec)
	local t = rec.target
	if not (t and t.valid) then return nil end
	if t.type == "cargo-wagon" then                      -- a train moves: the wagon must still cover the tile in front
		local e = rec.entity
		local d = FRONT[e.direction] or FRONT[defines.direction.north]
		local here = e.surface.find_entities_filtered{ position = { e.position.x + d[1], e.position.y + d[2] },
			type = "cargo-wagon", limit = 1 }[1]
		if here ~= t then return nil end
	end
	return t.get_inventory(INVENTORY[t.type])
end

--------------------------------------------------------------------------------
--- the external cell's functions (called by the storage engine)
--------------------------------------------------------------------------------

local function item_of(key)
	if N.is_fluid_key(key) or key:find("#", 1, true) then return nil end
	local name, q = N.parse_key(key)
	if not plain(name, q) then return nil end
	return name, q
end

N.ext_handlers[KIND] = {
	--- items of `key` the inventory takes now
	room = function(rec, key)
		if rec.mode == "read" or not allowed(rec, key) then return 0 end
		local name, q = item_of(key)
		local inv = name and inventory_of(rec)
		if not inv then return 0 end
		return inv.get_insertable_count{ name = name, quality = q }
	end,
	--- put up to `count` into the inventory; returns the count inserted
	insert = function(rec, key, count)
		if rec.mode == "read" or not allowed(rec, key) then return 0 end
		local name, q = item_of(key)
		local inv = name and inventory_of(rec)
		if not inv then return 0 end
		return inv.insert{ name = name, quality = q, count = count }
	end,
	--- the real count of `key` in the inventory (0 when the bus cannot take from it)
	count = function(rec, key)
		if rec.mode == "write" or not allowed(rec, key) then return 0 end
		local name, q = item_of(key)
		local inv = name and inventory_of(rec)
		if not inv then return 0 end
		return inv.get_item_count{ name = name, quality = q }
	end,
	--- take up to `count` out of the inventory; returns the count removed
	extract = function(rec, key, count)
		if rec.mode == "write" then return 0 end
		local name, q = item_of(key)
		local inv = name and inventory_of(rec)
		if not inv then return 0 end
		return inv.remove{ name = name, quality = q, count = count }
	end,
}

--------------------------------------------------------------------------------
--- target and visit
--------------------------------------------------------------------------------

local function release(s, rec)
	local tu = rec.target_unit
	if tu and s.claims[tu] == rec.unit then s.claims[tu] = nil end
	rec.target, rec.target_unit = nil, nil
end

--- is the inventory owner `tu` used by another bus that still faces it?
local function claimed_by_other(s, rec, tu)
	local other = s.claims[tu]
	if not other or other == rec.unit then return false end
	local o = N.ext_get(other)
	if o and o.entity.valid and o.target_unit == tu and o.target and o.target.valid then return true end
	s.claims[tu] = nil                                   -- a stale claim (bus gone or turned away)
	return false
end

--- the entity in front of the bus; sets rec.target or rec.status
local function resolve(s, rec)
	local e = rec.entity
	local t = rec.target
	if t and t.valid and rec.dir == e.direction and (t.type ~= "cargo-wagon" or inventory_of(rec)) then
		rec.status = "ok"
		return t
	end
	release(s, rec)
	rec.dir = e.direction
	local d = FRONT[e.direction] or FRONT[defines.direction.north]
	local status = "no-target"
	for _, o in pairs(e.surface.find_entities_filtered{ position = { e.position.x + d[1], e.position.y + d[2] } }) do
		if o.valid and o ~= e then
			if N.kind_of(o.name) or o.name:sub(1, 3) == "me-" then
				status = "me-target"                     -- an ME block (or an old ME chest): no loops
				break
			elseif INVENTORY[o.type] and o.unit_number then
				if claimed_by_other(s, rec, o.unit_number) then
					status = "shared-target"
				else
					s.claims[o.unit_number] = rec.unit
					rec.target, rec.target_unit = o, o.unit_number
					status = nil
				end
				break
			end
		end
	end
	rec.status = status or "ok"
	return rec.target
end

--- One visit: find the target, read its inventory once and apply the difference to the network
function M.visit(rec)
	local s = state()
	local e = rec.entity
	if not e.valid then return end
	local t = resolve(s, rec)
	local contents = {}
	local inv = t and inventory_of(rec)
	if inv and rec.mode ~= "write" then
		for _, it in pairs(inv.get_contents()) do
			local q = it.quality or "normal"
			if plain(it.name, q) then
				local key = N.key_of(it.name, q)
				if allowed(rec, key) then contents[key] = (contents[key] or 0) + it.count end
			end
		end
	end
	N.ext_sync(rec.unit, contents)
	if rec.status == "ok" then
		local net = N.network_of(e)
		local ok, why = N.usable(net)
		if not ok then rec.status = why or "no-network" end
	end
end

--- the I/O step (scripts/fork-me-io.lua): VISITS_PER_STEP buses, round robin
function M.on_step()
	local s = storage.fork_me_sbus
	if not (s and #s.list > 0) then return end
	for _ = 1, math.min(VISITS_PER_STEP, #s.list) do
		if s.cursor > #s.list then s.cursor = 1 end
		local unit = s.list[s.cursor]
		local rec = N.ext_get(unit)
		if rec and rec.entity.valid then
			M.visit(rec)
			s.cursor = s.cursor + 1
		else
			table.remove(s.list, s.cursor)
			if rec then N.ext_detach(unit) end
		end
		if #s.list == 0 then break end
	end
end

--------------------------------------------------------------------------------
--- settings
--------------------------------------------------------------------------------

--- filters checked against the prototypes: a list of keys ("name" or "name@quality"), at most MAX_FILTERS
local function clean_filters(filters)
	local out, seen = {}, {}
	if type(filters) ~= "table" then return out end
	for _, key in ipairs(filters) do
		if type(key) == "string" and not seen[key] and #out < MAX_FILTERS and not key:find("#", 1, true)
			and not N.is_fluid_key(key) then
			local name, q = N.parse_key(key)
			if prototypes.item[name] and prototypes.quality[q] then
				seen[key] = true
				out[#out + 1] = N.key_of(name, q)
			end
		end
	end
	return out
end

--- the settings of a bus: { mode, priority, filters = { keys } }
function M.get_settings(entity)
	local rec = rec_of(entity)
	if not rec then return nil end
	return { mode = rec.mode, priority = rec.priority or 0, filters = { table.unpack(rec.filters) } }
end

--- Apply settings (missing fields keep their value). The inventory is read again at once, so the
--- network shows what the new filter and mode allow.
function M.set_settings(entity, settings)
	local rec = rec_of(entity)
	if not (rec and type(settings) == "table") then return false end
	if MODES[settings.mode] then rec.mode = settings.mode end
	if settings.priority ~= nil then
		local p = math.floor(tonumber(settings.priority) or 0)
		rec.priority = math.max(-MAX_PRIORITY, math.min(MAX_PRIORITY, p))
	end
	if settings.filters ~= nil then
		rec.filters = clean_filters(settings.filters)
		local set
		for _, key in ipairs(rec.filters) do
			set = set or {}
			set[key] = true
		end
		rec.partition = set
	end
	rec.hidden = rec.mode == "write" or nil
	N.ext_touch(rec.unit)
	M.visit(rec)
	return true
end

function M.set_mode(entity, mode) return M.set_settings(entity, { mode = mode }) end
function M.set_priority(entity, priority) return M.set_settings(entity, { priority = priority }) end
function M.set_filters(entity, filters) return M.set_settings(entity, { filters = filters }) end

--- one filter button of the window: `key` nil removes it; the list stays packed
function M.set_filter(entity, index, key)
	local rec = rec_of(entity)
	if not rec then return false end
	local list = {}
	for i = 1, MAX_FILTERS do
		local v
		if i == index then v = key else v = rec.filters[i] end
		if v then list[#list + 1] = v end
	end
	return M.set_filters(entity, list)
end

--- the window's data: { mode, priority, filters, max, status, target, items, types, unit }
function M.info(entity)
	local rec = rec_of(entity)
	if not rec then return nil end
	local items, types = 0, 0
	for _, n in pairs(rec.items) do
		items = items + n
		types = types + 1
	end
	local t = rec.target
	return { mode = rec.mode, priority = rec.priority or 0, filters = { table.unpack(rec.filters) }, max = MAX_FILTERS,
		status = rec.status or "ok", target = t and t.valid and t.name or nil, items = items, types = types,
		contents = rec.items }
end

M.MAX_FILTERS = MAX_FILTERS

--------------------------------------------------------------------------------
--- events
--------------------------------------------------------------------------------

local function register(entity)
	local s = state()
	local unit = entity.unit_number
	local rec = N.ext_get(unit)
	if not rec then
		rec = { ext = KIND, unit = unit, entity = entity, items = {}, data = {}, mode = "readwrite", priority = 0,
			filters = {}, status = "no-target" }
		N.ext_attach(entity, rec)
	end
	local listed = false
	for _, u in ipairs(s.list) do if u == unit then listed = true break end end
	if not listed then s.list[#s.list + 1] = unit end
	return rec
end

--- `tags`: blueprint tags of a built ghost; `source`: the original of a clone
function M.on_built(entity, tags, source)
	if not is_bus(entity) then return end
	local rec = register(entity)
	local t = type(tags) == "table" and tags[TAG] or nil
	if type(t) == "table" then
		M.set_settings(entity, t)
	elseif source and is_bus(source) then
		M.set_settings(entity, M.get_settings(source))
	else
		M.visit(rec)
	end
end

--- a removed entity: a bus lets its inventory go (the network module drops its cell); an inventory a bus
--- uses leaves the network at once
function M.on_removed(entity)
	local s = storage.fork_me_sbus
	if not (s and entity and entity.valid and entity.unit_number) then return end
	local unit = entity.unit_number
	local rec = N.ext_get(unit)
	if rec and rec.ext == KIND then
		release(s, rec)
		for i = #s.list, 1, -1 do if s.list[i] == unit then table.remove(s.list, i) end end
		return
	end
	local bus = s.claims[unit]
	if bus then
		s.claims[unit] = nil
		local r = N.ext_get(bus)
		if r and r.target_unit == unit then
			r.target, r.target_unit, r.status = nil, nil, "no-target"
			N.ext_sync(bus, {})
		end
	end
end

function M.on_rotated(entity)
	local rec = is_bus(entity) and rec_of(entity)
	if rec then M.visit(rec) end
end

function M.on_entity_settings_pasted(event)
	local src, dst = event.source, event.destination
	if is_bus(src) and is_bus(dst) then M.set_settings(dst, M.get_settings(src)) end
end

--- blueprint hook of the autocrafting module (one on_player_setup_blueprint handler)
function M.tag_blueprint(bp, mapping)
	for index, entity in pairs(mapping) do
		if is_bus(entity) then
			local st = M.get_settings(entity)
			if st and (st.mode ~= "readwrite" or st.priority ~= 0 or #st.filters > 0) then
				bp.set_blueprint_entity_tag(index, TAG, st)
			end
		end
	end
end

--- after the graph rebuild: every storage bus has a record and is in the visit list, targets are found again
function M.on_configuration_changed()
	local s = state()
	s.list, s.cursor, s.claims = {}, 1, {}
	plain_cache = {}
	local names = {}
	for _, name in pairs(N.node_names()) do
		if N.kind_of(name) == KIND then names[#names + 1] = name end
	end
	if #names == 0 then return end
	local all = {}
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = names }) do all[#all + 1] = e end
	end
	table.sort(all, function(a, b) return a.unit_number < b.unit_number end)
	for _, e in ipairs(all) do
		local rec = register(e)
		rec.target, rec.target_unit, rec.dir = nil, nil, nil
	end
	for _, e in ipairs(all) do M.visit(N.ext_get(e.unit_number)) end
end

remote.add_interface("gregtorio-me-storagebus", {
	--- one visit now (what the I/O step does)
	visit = function(entity)
		local rec = rec_of(entity)
		if rec then M.visit(rec) end
		return rec ~= nil
	end,
	info = function(entity) return M.info(entity) end,
	get_settings = function(entity) return M.get_settings(entity) end,
	set_settings = function(entity, settings) return M.set_settings(entity, settings) end,
	set_filter = function(entity, index, key) return M.set_filter(entity, index, key) end,
	paste = function(source, destination) M.on_entity_settings_pasted{ source = source, destination = destination } end,
	tag_blueprint = function(bp, mapping) M.tag_blueprint(bp, mapping) end,
	--- what a build event does (`tags`: blueprint tags, `source`: the original of a clone)
	built = function(entity, tags, source) M.on_built(entity, tags, source) end,
	--- what the removal events do for an inventory a bus uses (destroy() raises none)
	removed = function(entity) M.on_removed(entity) end,
	rotated = function(entity) M.on_rotated(entity) end,
})

return M
