--------------------------------------------------------------------------------
--- FORK AE2: ME STORAGE BUS (issue #68; issue #3 of me-network: items and fluids; prototypes/network.lua,
--- docs/ME-REWORK.md "Storage bus" and "Items and fluids in one block")
---   * A rotatable 1x1 ME block that faces a chest, a logistic chest, the editor's infinity chest or a cargo wagon:
---     that inventory becomes storage of the network (the item side, this module). Facing any other entity with a
---     fluid box (a storage tank), the fluid of that box's fluid segment becomes storage of the network (the fluid
---     side, scripts/fork-me-fluid-storagebus.lua: one bus per segment, the temperature rule). What it faces
---     decides, when the target is resolved; no target type has both. The terminal shows what is in it,
---     everything that extracts from the network can take from it, and inserts go into it by its filter and
---     priority.
---   * Settings: filters, items and fluids mixed (a whitelist of keys: the bus shows and takes only these; none =
---     everything), a priority (-1000 ... 1000, the order of R3 together with the drives) and a mode: read and
---     write, read only (the network takes from it, never puts into it) or write only (the network puts into it
---     and does not see what is in it). Kept in blueprints (tag fork_me_storage_bus), settings paste and clones.
---   * The bus's storage is an "external cell" of the storage engine (scripts/fork-me-network.lua): the
---     record below is that cell (ext = "storage-bus"; side = "fluid" and handler = "fluid-storage-bus" while it
---     faces fluid: the engine calls the fluid side's functions directly). Its `items` are a
---     snapshot of the inventory or segment; the engine keeps the network's totals and index from it.
---   * Consistency: inserters and players change the inventory without an event. Every bus is due at a tick
---     (issue #5, scripts/fork-me-schedule.lua; the fluid side has its own queue): the on_tick handler of control.lua
---     visits at most the setting "storage bus visits per tick" of them per side; a visit reads the inventory once
---     (get_contents) and applies the difference to the snapshot (N.ext_sync). A bus whose inventory changed is read
---     again after MIN_INTERVAL ticks, one that did not change twice as late each time, up to the storage bus idle
---     limit (a setting, 2 seconds by default): the longest time until the network sees a change. Between two visits the snapshot may be stale; every insert and extract through the bus works
---     on the real inventory (the engine asks `count` before it takes and corrects the snapshot), so the network
---     never hands out items that are gone; it may show items that are gone (until the next visit or extract) or
---     not yet show items that came in (until the next visit).
---   * Rules: one bus per inventory (a second bus on the same inventory is refused with a status and takes
---     over when the first one goes); a bus facing an ME block is refused (no loops); removing the bus or
---     the inventory drops the inventory from the network.
--- State: the records live in the network module (storage.fork_me_net.ext, they are the cells); this module
--- keeps the visit list of the item side and which bus uses which inventory (storage.fork_me_sbus).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local T = require("scripts.fork-me-targets")
local F = require("scripts.fork-me-fluid-storagebus")
local Sched = require("scripts.fork-me-schedule")

local M = {}

local KIND = "storage-bus"
local MIN_INTERVAL = 30             -- ticks until a bus whose inventory changed reads it again
local MAX_FILTERS = 18
local MAX_PRIORITY = 1000
local TAG = "fork_me_storage_bus"   -- blueprint tag: { mode, priority, filters = { keys } }
local OLD_TAG = "fork_me_fluid_storage_bus"   -- the old ME Fluid Storage Bus's tag: { mode, priority, filters = { fluid names } }
local MODES = { readwrite = true, read = true, write = true }
local INVENTORY = T.STORAGE
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

--- the queue of the item side's visits; a save from before issue #5 gets one with every bus due within a second
local function queue(s)
	if s.q then return s.q end
	s.q = Sched.new()
	for i, unit in ipairs(s.list) do
		local rec = N.ext_get(unit)
		if rec then Sched.at(s.q, rec, unit, game.tick + 1 + (i - 1) % 60) end
	end
	return s.q
end

local function is_bus(entity) return entity and entity.valid and N.kind_of(entity.name) == KIND end

--- the record (the external cell) of a bus
local function rec_of(entity)
	local rec = entity and entity.valid and entity.unit_number and N.ext_get(entity.unit_number) or nil
	return rec and rec.ext == KIND and rec or nil
end

--- is the bus in the item side's list? (a set beside the list, made when missing)
local function listed(s, unit)
	if not s.member then
		s.member = {}
		for _, u in ipairs(s.list) do s.member[u] = true end
	end
	return s.member[unit] == true
end

local function unlist(list, unit)
	for i = #list, 1, -1 do if list[i] == unit then table.remove(list, i) end end
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
		local here = e.surface.find_entities_filtered{ position = T.front(e), type = "cargo-wagon", limit = 1 }[1]
		if here ~= t then return nil end
	end
	return t.get_inventory(INVENTORY[t.type])
end

--------------------------------------------------------------------------------
--- the external cell's functions (called by the storage engine); the fluid side's are F.handlers
--------------------------------------------------------------------------------

local function item_of(key)
	if N.is_fluid_key(key) or key:find("#", 1, true) then return nil end
	local name, q = N.parse_key(key)
	if not plain(name, q) then return nil end
	return name, q
end

local ITEM = {
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

N.ext_handlers[KIND] = ITEM             -- the fluid side: N.ext_handlers[F.HANDLER] through rec.handler

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
	if o and o.entity.valid and o.side ~= "fluid" and o.target_unit == tu and o.target and o.target.valid then return true end
	s.claims[tu] = nil                                   -- a stale claim (bus gone, turned away or on fluid now)
	return false
end

--- put the bus into the visit list of its side (and out of the other one); a bus new to a side is due at once
local function list_side(s, rec)
	if rec.side == "fluid" then
		if listed(s, rec.unit) then
			unlist(s.list, rec.unit)
			s.member[rec.unit] = nil
		end
		F.list(rec)
	else
		F.unlist(rec)
		if not listed(s, rec.unit) then
			s.list[#s.list + 1] = rec.unit
			s.member[rec.unit] = true
			rec.siv = nil
			Sched.at(queue(s), rec, rec.unit, game.tick + 1)
		end
	end
end

--- The entity in front of the bus: an inventory makes it an item side bus (rec.target, claimed), any other entity
--- with a fluid box a fluid side bus (F.take: rec.target and rec.box); sets rec.side and rec.status. A valid cached
--- target is kept.
local function resolve(s, rec)
	local e = rec.entity
	local t = rec.target
	if t and t.valid and rec.dir == e.direction then
		if rec.side == "fluid" then
			if rec.box then return t end
		elseif t.type ~= "cargo-wagon" or inventory_of(rec) then
			rec.status = "ok"
			return t
		end
	end
	release(s, rec)
	F.drop(rec)
	rec.dir = e.direction
	local status, side = "no-target", nil
	for _, o in pairs(e.surface.find_entities_filtered{ position = T.front(e) }) do
		if o.valid and o ~= e then
			if N.kind_of(o.name) or o.name:sub(1, 3) == "me-" then
				status = "me-target"                     -- an ME block (or an old ME chest, an interface's side): no loops
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
			elseif F.take(rec, o) then
				side, status = "fluid", nil
				break
			end
		end
	end
	if rec.side ~= side then
		rec.side, rec.handler = side, side and F.HANDLER or nil
		N.ext_sync(rec.unit, {})                         -- the other side's snapshot goes
		N.ext_touch(rec.unit)                            -- it takes the other kind of keys now (the insertion lists)
	end
	list_side(s, rec)
	rec.status = status or "ok"
	return rec.target
end

--- One visit: find the target, read its inventory (or segment) once and apply the difference to the network.
--- Returns true when the snapshot or the target changed.
function M.visit(rec, cascade)
	local s = state()
	local e = rec.entity
	if not e.valid then return false end
	local before = rec.target
	local t = resolve(s, rec)
	if rec.side == "fluid" then return F.visit(rec, cascade) end
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
	local changed = N.ext_sync(rec.unit, contents) or before ~= rec.target
	if rec.status == "ok" then
		local net = N.network_of(e)
		local ok, why = N.usable(net)
		if not ok then rec.status = why or "no-network" end
	end
	return changed
end
--- the fluid side visits through this when its target is gone or the bus was rotated (it may face a chest now)
F.resolve_visit = function(rec, cascade) return M.visit(rec, cascade) end
F.lost = function(rec) list_side(state(), rec) end

--- the record of an item side bus that is due (nil when it is gone or on the fluid side now)
local function item_rec(unit)
	local rec = N.ext_get(unit)
	if rec and rec.ext == KIND and rec.side ~= "fluid" then return rec end
	return nil
end

local function visit_due(rec, unit)
	local s = storage.fork_me_sbus
	if not rec.entity.valid then
		unlist(s.list, unit)
		if s.member then s.member[unit] = nil end
		N.ext_detach(unit)
		return
	end
	local changed = M.visit(rec)
	if rec.side == "fluid" then return end           -- on the fluid side now: its queue has it
	--- (0.2.0 read 8 buses per 15 ticks: an idle bus never waits longer than that cycle)
	local idle = Sched.idle_limit(Sched.setting("storage_bus_idle"), #s.list, 8 / 15, MIN_INTERVAL)
	rec.siv = Sched.interval(rec.siv, changed and 1 or 0, true, MIN_INTERVAL, MIN_INTERVAL, idle)
	Sched.at(queue(s), rec, unit, game.tick + rec.siv)
end

--- every tick (control.lua): the item side buses that are due, then the fluid side's
function M.on_tick(tick)
	local s = storage.fork_me_sbus
	if s and #s.list > 0 then Sched.run(queue(s), tick, Sched.setting("storage_bus"), item_rec, visit_due) end
	F.on_tick(tick)
end

--- read the inventory or segment at the next tick (an entity was built in front of the bus)
function M.wake(unit)
	local rec = N.ext_get(unit)
	if not (rec and rec.ext == KIND) then return end
	rec.target = nil
	if rec.side == "fluid" then
		F.wake(rec)
	else
		local s = storage.fork_me_sbus
		if s and listed(s, unit) then
			rec.siv = nil
			Sched.wake(queue(s), rec, unit, game.tick + 1)
		end
	end
end

local bus_names
--- an entity was built: the storage buses facing it read it at the next tick
function M.wake_near(entity)
	if not (storage.fork_me_sbus and (T.STORAGE[entity.type] or T.has_fluid_boxes(entity))) then return end
	if not bus_names then
		bus_names = {}
		for _, name in pairs(N.node_names()) do
			if N.kind_of(name) == KIND then bus_names[#bus_names + 1] = name end
		end
	end
	local b = entity.bounding_box
	for _, bus in pairs(entity.surface.find_entities_filtered{ name = bus_names,
		area = { { b.left_top.x - 1, b.left_top.y - 1 }, { b.right_bottom.x + 1, b.right_bottom.y + 1 } } }) do
		local f = T.front(bus)
		if f[1] > b.left_top.x and f[1] < b.right_bottom.x and f[2] > b.left_top.y and f[2] < b.right_bottom.y then
			M.wake(bus.unit_number)
		end
	end
end

--------------------------------------------------------------------------------
--- settings
--------------------------------------------------------------------------------

--- filters checked against the prototypes: a list of keys ("name", "name@quality", "fluid/<name>"; a plain name
--- that is no item but a fluid is that fluid), at most MAX_FILTERS
local function clean_filters(filters)
	local out, seen = {}, {}
	if type(filters) ~= "table" then return out end
	for _, key in ipairs(filters) do
		if type(key) == "string" and #out < MAX_FILTERS and not key:find("#", 1, true) then
			local k
			if N.is_fluid_key(key) then
				if prototypes.fluid[key:sub(7)] then k = key end
			else
				local name, q = N.parse_key(key)
				if prototypes.item[name] and prototypes.quality[q] then k = N.key_of(name, q)
				elseif prototypes.fluid[key] then k = "fluid/" .. key end
			end
			if k and not seen[k] then
				seen[k] = true
				out[#out + 1] = k
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

--- Apply settings (missing fields keep their value). The inventory or segment is read again at once, so the
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

--- the window's data: { side, mode, priority, filters, max, status, target, items, types, contents; on fluid also
--- fluid, amount, temperature, segment }
function M.info(entity)
	local rec = rec_of(entity)
	if not rec then return nil end
	local items, types = 0, 0
	for _, n in pairs(rec.items) do
		items = items + n
		types = types + 1
	end
	local t = rec.target
	local out = { side = rec.side or "item", mode = rec.mode, priority = rec.priority or 0,
		filters = { table.unpack(rec.filters) }, max = MAX_FILTERS, status = rec.status or "ok",
		target = t and t.valid and t.name or nil, items = items, types = types, contents = rec.items }
	if rec.side == "fluid" then
		out.fluid, out.amount, out.temperature, out.segment = rec.fluid, items, rec.temp, rec.seg
	end
	return out
end

M.MAX_FILTERS = MAX_FILTERS

--------------------------------------------------------------------------------
--- events
--------------------------------------------------------------------------------

local function register(entity)
	local s = state()
	local unit = entity.unit_number
	local rec = N.ext_get(unit)
	if not (rec and rec.ext == KIND) then
		rec = { ext = KIND, unit = unit, entity = entity, items = {}, data = {}, mode = "readwrite", priority = 0,
			filters = {}, status = "no-target" }
		N.ext_attach(entity, rec)
	end
	list_side(s, rec)
	return rec
end

--- the settings of a blueprint tag: issue #3 / the item bus's { mode, priority, filters = keys }, or the old fluid
--- storage bus's { mode, priority, filters = fluid names }
local function settings_of_tags(tags)
	if type(tags) ~= "table" then return nil end
	if type(tags[TAG]) == "table" then return tags[TAG] end
	local old = tags[OLD_TAG]
	if type(old) ~= "table" then return nil end
	local filters = {}
	for _, name in ipairs(old.filters or {}) do
		if type(name) == "string" then filters[#filters + 1] = N.is_fluid_key(name) and name or ("fluid/" .. name) end
	end
	return { mode = old.mode, priority = old.priority, filters = filters }
end
M.settings_of_tags = settings_of_tags

--- `tags`: blueprint tags of a built ghost; `source`: the original of a clone
function M.on_built(entity, tags, source)
	if not is_bus(entity) then return end
	local rec = register(entity)
	local t = settings_of_tags(tags)
	if t then
		M.set_settings(entity, t)
	elseif source and is_bus(source) then
		M.set_settings(entity, M.get_settings(source))
	else
		M.visit(rec)
	end
end

--- a removed entity: a bus lets its inventory or segment go (the network module drops its cell); an inventory a
--- bus uses leaves the network at once; a removed fluid entity is the fluid side's business
function M.on_removed(entity)
	if not (entity and entity.valid and entity.unit_number) then return end
	local s = storage.fork_me_sbus
	local unit = entity.unit_number
	local rec = N.ext_get(unit)
	if rec and rec.ext == KIND then
		if s then
			release(s, rec)
			unlist(s.list, unit)
			if s.member then s.member[unit] = nil end
		end
		F.drop(rec)
		F.unlist(rec)
		return
	end
	local bus = s and s.claims[unit]
	if bus then
		s.claims[unit] = nil
		local r = N.ext_get(bus)
		if r and r.target_unit == unit then
			r.target, r.target_unit, r.status = nil, nil, "no-target"
			N.ext_sync(bus, {})
		end
	end
	F.on_removed(entity)
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

--- after the graph rebuild: every storage bus has a record and is in the visit list of its side, targets are found
--- again (the fluid side claims its segments in unit order)
function M.on_configuration_changed()
	local s = state()
	s.list, s.cursor, s.claims, s.member, s.q = {}, 1, {}, {}, Sched.new()
	F.reset()
	plain_cache, bus_names = {}, nil
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
		rec.target, rec.target_unit, rec.dir, rec.box, rec.seg = nil, nil, nil, nil, nil
		rec.filters = clean_filters(rec.filters)          -- (a save before issue #3 had item keys only: unchanged)
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

--- issue #3: the old remote of the ME Fluid Storage Bus works on the storage bus (its fluid side)
remote.add_interface("gregtorio-me-fluid-storagebus", {
	visit = function(entity)
		local rec = rec_of(entity)
		if rec then M.visit(rec) end
		return rec ~= nil
	end,
	--- the fluid side's part of the I/O step (urgent visits, then the round robin)
	step = function() F.on_step() end,
	info = function(entity) return M.info(entity) end,
	get_settings = function(entity) return M.get_settings(entity) end,
	set_settings = function(entity, settings) return M.set_settings(entity, settings) end,
	set_filter = function(entity, index, key) return M.set_filter(entity, index, key) end,
	paste = function(source, destination) M.on_entity_settings_pasted{ source = source, destination = destination } end,
	tag_blueprint = function(bp, mapping) M.tag_blueprint(bp, mapping) end,
	built = function(entity, tags, source) M.on_built(entity, tags, source) end,
	removed = function(entity) M.on_removed(entity) end,
	rotated = function(entity) M.on_rotated(entity) end,
})

return M
