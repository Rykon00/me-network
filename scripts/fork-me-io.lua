--------------------------------------------------------------------------------
--- FORK AE2: IMPORT AND EXPORT (issue #68, step R1; prototypes/120-fork-ae2.lua, docs/ME-REWORK.md)
---   * ME Interface: a container with up to CONFIG_SLOTS config entries (item, quality, amount; R3, AE2's
---     config slots). The network keeps the amount of each configured item in the container (fills up, takes
---     back the surplus); every other item in it is imported into the network (items the network cannot store
---     stay). Inserters work with it like with a chest. The config is kept in script (rec.config), in
---     blueprints (tag fork_me_interface = { config }), settings paste and clones. Saves before R3 used the
---     container's slot filters: they become config entries (one full stack per filtered slot) the first time
---     the interface is visited, and the filters are cleared (config_of).
---   * ME Import Bus / ME Export Bus: face one entity (their direction). The import bus pulls items from the
---     entity's output (assembler, furnace result, chest), the export bus puts its filtered items into the
---     entity's input (assembler or furnace input: up to one stack each; chest: as far as it has room).
---     Up to MAX_FILTERS filters (import: none = everything), kept in blueprints (tag fork_me_bus), settings
---     paste and clones. The windows of both are in scripts/fork-me-windows.lua.
--- The I/O step runs every STEP_TICKS ticks (shared with the fluid interfaces: this module registers the
--- interval and calls the fluid step first): at most ENDPOINTS_PER_STEP interfaces and buses, round robin;
--- an interface handles at most IFACE_SLOTS_PER_VISIT slots per visit, a bus moves BUS_ITEMS items.
--- State: storage.fork_me_io (records by unit number). GUI state lives in the GUI elements.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local fluids = require("scripts.fork-me-fluids")

local M = {}

local STEP_TICKS = 15                -- 20 (autocrafting), 30 (molds) and 60 (terminal) are taken
local ENDPOINTS_PER_STEP = 24
local IFACE_SLOTS_PER_VISIT = 8
local BUS_ITEMS = 64
local BUS_FLUID = 1000               -- fluid units a fluid bus moves per visit
local MAX_FILTERS = 5
local CONFIG_SLOTS = 9
local MAX_AMOUNT = 1000000
local IFACE_TAG, BUS_TAG = "fork_me_interface", "fork_me_bus"
local FRONT = {
	[defines.direction.north] = { 0, -1 }, [defines.direction.east] = { 1, 0 },
	[defines.direction.south] = { 0, 1 }, [defines.direction.west] = { -1, 0 },
}

local function state()
	local s = storage.fork_me_io
	if not s then
		s = { recs = {}, list = {}, cursor = 1 }
		storage.fork_me_io = s
	end
	return s
end

local function kind(entity) return entity and entity.valid and N.kind_of(entity.name) end

local function register(s, entity)
	local unit = entity.unit_number
	local rec = s.recs[unit]
	if not rec then
		rec = { entity = entity, kind = kind(entity), filters = {}, status = "ok" }
		s.recs[unit] = rec
		s.list[#s.list + 1] = unit
	end
	return rec
end

local function drop(s, unit)
	s.recs[unit] = nil
	for i = #s.list, 1, -1 do
		if s.list[i] == unit then table.remove(s.list, i) end
	end
end

--------------------------------------------------------------------------------
--- interface
--------------------------------------------------------------------------------

local function filter_of(inv, i)
	local f = inv.get_filter(i)
	if not f then return nil end
	if type(f) == "string" then return f, "normal" end
	local q = f.quality
	return f.name, q and (type(q) == "string" and q or q.name) or "normal"
end

local function clear_filters(inv)
	for i = 1, #inv do
		if inv.get_filter(i) then inv.set_filter(i, nil) end
	end
end

--- Old filters ({ [slot] = { name, quality } }, the slot filters of saves and blueprints before R3) as config
--- entries: one full stack per filtered slot, the same item in several slots adds up.
local function config_from_filters(filters)
	local out, by_key = {}, {}
	for i = 1, 18 do
		local f = filters[i] or filters[tostring(i)]
		local proto = type(f) == "table" and prototypes.item[f.name]
		if proto then
			local key = N.key_of(f.name, f.quality or "normal")
			if by_key[key] then
				by_key[key].amount = by_key[key].amount + proto.stack_size
			elseif #out < CONFIG_SLOTS then
				by_key[key] = { name = f.name, quality = f.quality or "normal", amount = proto.stack_size }
				out[#out + 1] = by_key[key]
			end
		end
	end
	return out
end

--- A config checked against the prototypes: { [i] = { name, quality, amount } } for i = 1 .. CONFIG_SLOTS
--- (a list, or a list of { slot = i, ... } as in blueprint tags). Entries without item or with amount 0 stay
--- (the item is shown, nothing is kept), duplicates of an earlier slot are dropped.
local function clean_config(config)
	local out, seen = {}, {}
	if type(config) ~= "table" then return out end
	for k, c in pairs(config) do
		local i = type(c) == "table" and tonumber(c.slot) or tonumber(k)
		if type(c) == "table" and i and i >= 1 and i <= CONFIG_SLOTS and i == math.floor(i) and prototypes.item[c.name] then
			local q = (type(c.quality) == "string" and prototypes.quality[c.quality]) and c.quality or "normal"
			local key = N.key_of(c.name, q)
			if not seen[key] then
				seen[key] = true
				local amount = math.max(0, math.min(MAX_AMOUNT, math.floor(tonumber(c.amount) or 0)))
				out[i] = { name = c.name, quality = q, amount = amount }
			end
		end
	end
	return out
end

--- the config of an interface; the first call on a pre-R3 interface turns its slot filters into config
local function config_of(rec)
	if rec.config then return rec.config end
	local inv = rec.entity.get_inventory(defines.inventory.chest)
	local filters = {}
	for i = 1, #inv do
		local name, q = filter_of(inv, i)
		if name then filters[i] = { name = name, quality = q } end
	end
	rec.config = clean_config(config_from_filters(filters))
	clear_filters(inv)
	return rec.config
end

--- One visit: every configured item is kept at its amount (filled from the network, the surplus taken back),
--- the other items are imported. At most IFACE_SLOTS_PER_VISIT operations.
function M.interface_step(rec)
	local e = rec.entity
	local config = config_of(rec)
	local net = N.active_of(e)
	if not net then
		local _, why = N.usable(N.network_of(e))
		rec.status = why or "no-network"
		return 0
	end
	local inv = e.get_inventory(defines.inventory.chest)
	local ops, moved = 0, 0
	local kept = {}
	for i = 1, CONFIG_SLOTS do
		local c = config[i]
		if c then
			local key = N.key_of(c.name, c.quality)
			kept[key] = true
			local have = inv.get_item_count{ name = c.name, quality = c.quality }
			if have < c.amount then
				local got = N.extract_to(net, inv, key, c.amount - have)
				if got > 0 then moved = moved + got ops = ops + 1 end
			elseif have > c.amount then
				local can = N.can_insert(net, c.name, c.quality, have - c.amount)
				local taken = can > 0 and inv.remove{ name = c.name, quality = c.quality, count = can } or 0
				if taken > 0 then
					local stored = N.insert(net, c.name, c.quality, taken)
					if stored < taken then inv.insert{ name = c.name, quality = c.quality, count = taken - stored } end
					moved = moved + stored
					ops = ops + 1
				end
			end
		end
	end
	local start = rec.slot or 1
	local size = #inv
	for k = 0, size - 1 do
		if ops >= IFACE_SLOTS_PER_VISIT then rec.slot = (start - 1 + k) % size + 1 break end
		local i = (start - 1 + k) % size + 1
		local stack = inv[i]
		if stack.valid_for_read and not kept[N.key_of(stack.name, stack.quality.name)] then
			local n = N.insert_stack(net, stack)
			if n then moved = moved + n ops = ops + 1 end
		end
	end
	if ops < IFACE_SLOTS_PER_VISIT then rec.slot = 1 end
	rec.status = "ok"
	return moved
end

--- the config: { [i] = { name, quality, amount } }, i = 1 .. CONFIG_SLOTS (a copy)
function M.get_interface_config(entity)
	if kind(entity) ~= "interface" then return nil end
	local out = {}
	for i, c in pairs(config_of(register(state(), entity))) do
		out[i] = { name = c.name, quality = c.quality, amount = c.amount }
	end
	return out
end

function M.set_interface_config(entity, config)
	if kind(entity) ~= "interface" then return false end
	local rec = register(state(), entity)
	config_of(rec)
	rec.config = clean_config(config)
	return true
end

--- One config slot: `name` nil clears it. Without `amount` the slot keeps its amount, an item moved from another
--- slot keeps that slot's amount (the other slot is cleared), a new item starts with one stack.
function M.set_interface_slot(entity, i, name, quality, amount)
	if kind(entity) ~= "interface" or not (i >= 1 and i <= CONFIG_SLOTS) then return false end
	local config = M.get_interface_config(entity)
	if name and prototypes.item[name] then
		quality = quality or "normal"
		local old = config[i]
		for j, c in pairs(config) do          -- the item moves from another slot
			if j ~= i and c.name == name and c.quality == quality then
				if amount == nil then amount = c.amount end
				config[j] = nil
			end
		end
		if amount == nil then
			amount = (old and old.name == name and old.quality == quality) and old.amount or prototypes.item[name].stack_size
		end
		config[i] = { name = name, quality = quality, amount = amount }
	else
		config[i] = nil
	end
	return M.set_interface_config(entity, config)
end

--- the config as a list for blueprint tags (sparse tables do not survive tags): { { slot, name, quality, amount } }
local function config_tag(config)
	local out = {}
	for i = 1, CONFIG_SLOTS do
		local c = config[i]
		if c then out[#out + 1] = { slot = i, name = c.name, quality = c.quality, amount = c.amount } end
	end
	return out
end

--- the config from a blueprint tag (R3 { config }, before R3 { filters })
local function config_from_tag(t)
	if type(t) ~= "table" then return nil end
	if type(t.config) == "table" then return t.config end
	if type(t.filters) == "table" then return config_from_filters(t.filters) end
	return nil
end

--- the interface's state for its window: { config, status, contents = { { key, count } } }
function M.get_interface(entity)
	if kind(entity) ~= "interface" then return nil end
	local rec = register(state(), entity)
	local inv = entity.get_inventory(defines.inventory.chest)
	local contents = {}
	for _, item in pairs(inv.get_contents()) do
		contents[#contents + 1] = { key = N.key_of(item.name, item.quality), count = item.count }
	end
	table.sort(contents, function(a, b) return a.key < b.key end)
	return { config = M.get_interface_config(entity), status = rec.status, contents = contents, slots = CONFIG_SLOTS }
end
M.CONFIG_SLOTS = CONFIG_SLOTS
M.MAX_FILTERS = MAX_FILTERS

--------------------------------------------------------------------------------
--- buses
--------------------------------------------------------------------------------

local OUTPUT = { ["assembling-machine"] = defines.inventory.crafter_output, ["furnace"] = defines.inventory.furnace_result,
	["container"] = defines.inventory.chest, ["logistic-container"] = defines.inventory.chest }
local INPUT = { ["assembling-machine"] = defines.inventory.crafter_input, ["furnace"] = defines.inventory.furnace_source,
	["container"] = defines.inventory.chest, ["logistic-container"] = defines.inventory.chest }

local BUSES = { ["import-bus"] = true, ["export-bus"] = true, ["fluid-import-bus"] = true, ["fluid-export-bus"] = true }
local FLUID_BUSES = { ["fluid-import-bus"] = true, ["fluid-export-bus"] = true }
local IMPORTS = { ["import-bus"] = true, ["fluid-import-bus"] = true }

--- the entity in front of a bus that has the inventory (fluid boxes) the bus works with (cached until it is gone)
local function target_of(rec)
	local t = rec.target
	local e = rec.entity
	if t and t.valid and rec.dir == e.direction then return t end
	rec.target, rec.dir = nil, e.direction
	local d = FRONT[e.direction] or FRONT[defines.direction.north]
	local table_ = rec.kind == "import-bus" and OUTPUT or INPUT
	for _, o in pairs(e.surface.find_entities_filtered{ position = { e.position.x + d[1], e.position.y + d[2] } }) do
		if o.valid and not N.kind_of(o.name) then
			local fits
			if FLUID_BUSES[rec.kind] then fits = o.fluidbox and #o.fluidbox > 0 else fits = table_[o.type] end
			if fits then
				rec.target = o
				return o
			end
		end
	end
	return nil
end

local function allowed(rec, name)
	if #rec.filters == 0 then return IMPORTS[rec.kind] == true end
	for _, f in pairs(rec.filters) do
		if f == name then return true end
	end
	return false
end

function M.bus_step(rec)
	local e = rec.entity
	local net = N.active_of(e)
	if not net then
		local _, why = N.usable(N.network_of(e))
		rec.status = why or "no-network"
		return 0
	end
	local t = target_of(rec)
	if not t then rec.status = "no-target" return 0 end
	local moved = 0
	if FLUID_BUSES[rec.kind] then
		moved = M.fluid_bus_step(rec, net, t)
	elseif rec.kind == "import-bus" then
		local inv = t.get_inventory(OUTPUT[t.type])
		if not inv then rec.status = "no-target" return 0 end
		for i = 1, #inv do
			if moved >= BUS_ITEMS then break end
			local stack = inv[i]
			if stack.valid_for_read and allowed(rec, stack.name) then
				local n = N.insert_partial(net, stack, BUS_ITEMS - moved)
				if n then moved = moved + n end
			end
		end
	else
		local inv = t.get_inventory(INPUT[t.type])
		if not inv then rec.status = "no-target" return 0 end
		local machine = t.type == "assembling-machine" or t.type == "furnace"
		for _, name in pairs(rec.filters) do
			if moved >= BUS_ITEMS then break end
			local proto = prototypes.item[name]
			if proto then
				local want = BUS_ITEMS - moved
				if machine then want = math.min(want, proto.stack_size - inv.get_item_count(name)) end
				if want > 0 then
					moved = moved + N.extract_to(net, inv, N.key_of(name, "normal"), want)
				end
			end
		end
	end
	rec.status = "ok"
	return moved
end

--- A fluid bus visit: the import bus empties the output boxes of a machine (any box of a tank) into the
--- network, the export bus fills its filtered fluids into the entity (insert_fluid: the machine's input boxes,
--- a tank), at the fluid's default temperature. Up to BUS_FLUID units per visit. Returns the units moved.
function M.fluid_bus_step(rec, net, t)
	local fb = t.fluidbox
	local moved = 0
	if rec.kind == "fluid-import-bus" then
		for i = 1, #fb do
			if moved >= BUS_FLUID then break end
			local f = fb[i]
			local p = fb.get_prototype(i)
			if p and p.production_type == nil and p[1] then p = p[1] end      -- merged prototypes: the first one
			local kind_ = p and p.production_type
			if f and f.amount > 1e-6 and kind_ ~= "input" and allowed(rec, f.name) then
				local take = N.can_insert_fluid(net, f.name, math.min(f.amount, BUS_FLUID - moved))
				if take > 1e-6 then
					local left = f.amount - take
					fb[i] = left > 1e-6 and { name = f.name, amount = left, temperature = f.temperature } or nil
					local stored = N.insert_fluid(net, f.name, take)
					if stored < take - 1e-6 then                 -- cannot happen (room was checked), but never lose fluid
						t.insert_fluid{ name = f.name, amount = take - stored, temperature = f.temperature }
					end
					moved = moved + stored
				end
			end
		end
	else
		for _, name in pairs(rec.filters) do
			if moved >= BUS_FLUID then break end
			local avail = math.min(N.fluid_count(net, name), BUS_FLUID - moved)
			if avail > 1e-6 then
				local inserted = t.insert_fluid{ name = name, amount = avail }
				if inserted > 0 then moved = moved + N.extract_fluid(net, name, inserted) end
			end
		end
	end
	return moved
end

function M.set_bus_filters(entity, filters)
	local k = kind(entity)
	if not BUSES[k] then return false end
	local rec = register(state(), entity)
	local list, seen = {}, {}
	local protos = FLUID_BUSES[k] and prototypes.fluid or prototypes.item
	for _, name in pairs(filters or {}) do
		if type(name) == "string" and protos[name] and not seen[name] and #list < MAX_FILTERS then
			seen[name] = true
			list[#list + 1] = name
		end
	end
	rec.filters = list
	return true
end

function M.get_bus(entity)
	local s = storage.fork_me_io
	local rec = s and entity and entity.valid and s.recs[entity.unit_number]
	if not rec then return nil end
	local t = rec.target
	return { filters = { table.unpack(rec.filters) }, status = rec.status, target = t and t.valid and t.name or nil }
end

--- one filter of a bus (the window's filter buttons): `name` nil clears it; the list stays packed
function M.set_bus_filter(entity, index, name)
	local s = state()
	if not BUSES[kind(entity)] then return false end
	local rec = register(s, entity)
	local list = {}
	for i = 1, MAX_FILTERS do
		local v
		if i == index then v = name else v = rec.filters[i] end
		if v then list[#list + 1] = v end
	end
	return M.set_bus_filters(entity, list)
end

--- the bus's state for its window: { kind, filters, status, target, fluid }
function M.bus_info(entity)
	local k = kind(entity)
	if not BUSES[k] then return nil end
	register(state(), entity)
	local b = M.get_bus(entity)
	b.kind, b.fluid, b.import, b.max = k, FLUID_BUSES[k] == true, IMPORTS[k] == true, MAX_FILTERS
	return b
end

--------------------------------------------------------------------------------
--- step, events
--------------------------------------------------------------------------------

local function on_step()
	fluids.on_step()
	local s = storage.fork_me_io
	if not s then return end
	local n = #s.list
	if n == 0 then return end
	for _ = 1, math.min(ENDPOINTS_PER_STEP, n) do
		if s.cursor > #s.list then s.cursor = 1 end
		local unit = s.list[s.cursor]
		local rec = s.recs[unit]
		if rec and rec.entity.valid then
			if rec.kind == "interface" then M.interface_step(rec) else M.bus_step(rec) end
			s.cursor = s.cursor + 1
		else
			drop(s, unit)
		end
		if #s.list == 0 then break end
	end
end

script.on_nth_tick(STEP_TICKS, on_step)

--- `tags`: blueprint tags of a built ghost; `source`: the original of a clone
function M.on_built(entity, tags, source)
	local k = kind(entity)
	if k ~= "interface" and not BUSES[k] then return end
	register(state(), entity)
	if k == "interface" then
		local config = config_from_tag(type(tags) == "table" and tags[IFACE_TAG] or nil)
		if config then M.set_interface_config(entity, config)
		elseif source and source.valid and kind(source) == "interface" then M.set_interface_config(entity, M.get_interface_config(source)) end
		clear_filters(entity.get_inventory(defines.inventory.chest))      -- a blueprint before R3 may carry slot filters
	else
		local t = type(tags) == "table" and tags[BUS_TAG] or nil
		if type(t) == "table" then M.set_bus_filters(entity, t.filters)
		elseif source and source.valid and kind(source) == k then
			local from = M.get_bus(source)
			M.set_bus_filters(entity, from and from.filters or {})
		end
	end
end

function M.on_removed(entity)
	local s = storage.fork_me_io
	if s and entity and entity.valid and entity.unit_number and s.recs[entity.unit_number] then drop(s, entity.unit_number) end
end

function M.on_rotated(entity)
	local s = storage.fork_me_io
	local rec = s and entity and entity.valid and s.recs[entity.unit_number]
	if rec then rec.target = nil end
end

function M.on_entity_settings_pasted(event)
	local src, dst = event.source, event.destination
	if not (src and src.valid and dst and dst.valid and src.name == dst.name) then return end
	local k = kind(src)
	if k == "interface" then M.set_interface_config(dst, M.get_interface_config(src))
	elseif BUSES[k] then
		local from = M.get_bus(src)
		M.set_bus_filters(dst, from and from.filters or {})
	end
end

--- blueprint hook of the autocrafting module (one on_player_setup_blueprint handler)
function M.tag_blueprint(bp, mapping)
	for index, entity in pairs(mapping) do
		local k = kind(entity)
		if k == "interface" then
			local config = config_tag(M.get_interface_config(entity))
			if #config > 0 then bp.set_blueprint_entity_tag(index, IFACE_TAG, { config = config }) end
		elseif BUSES[k] then
			local b = M.get_bus(entity)
			if b and #b.filters > 0 then bp.set_blueprint_entity_tag(index, BUS_TAG, { filters = b.filters }) end
		end
	end
end

--- rebuild the records from the world; filters of buses and the config of interfaces are kept by unit number
function M.on_configuration_changed()
	local s = state()
	local old = s.recs
	s.recs, s.list, s.cursor = {}, {}, 1
	local names = {}
	for _, name in pairs(N.node_names()) do
		local k = N.kind_of(name)
		if k == "interface" or BUSES[k] then names[#names + 1] = name end
	end
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = names }) do
			local rec = register(s, e)
			local o = old[e.unit_number]
			if o and o.filters and BUSES[rec.kind] then M.set_bus_filters(e, o.filters) end
			if o and o.config and rec.kind == "interface" then rec.config = clean_config(o.config) end
			rec.target = nil
		end
	end
	table.sort(s.list)
end

remote.add_interface("gregtorio-me-io", {
	--- one visit of an interface or bus now (what the step does); returns the items moved
	step = function(entity)
		local k = kind(entity)
		if not k then return 0 end
		local rec = register(state(), entity)
		if k == "interface" then return M.interface_step(rec) end
		return M.bus_step(rec)
	end,
	set_interface_config = function(entity, config) return M.set_interface_config(entity, config) end,
	get_interface_config = function(entity) return M.get_interface_config(entity) end,
	set_interface_slot = function(entity, i, name, quality, amount) return M.set_interface_slot(entity, i, name, quality, amount) end,
	get_interface = function(entity) return M.get_interface(entity) end,
	set_bus_filters = function(entity, filters) return M.set_bus_filters(entity, filters) end,
	set_bus_filter = function(entity, index, name) return M.set_bus_filter(entity, index, name) end,
	get_bus = function(entity) return M.get_bus(entity) end,
	bus_info = function(entity) return M.bus_info(entity) end,
	paste = function(source, destination) M.on_entity_settings_pasted{ source = source, destination = destination } end,
	tag_blueprint = function(bp, mapping) M.tag_blueprint(bp, mapping) end,
	--- what a build event does (`tags`: blueprint tags, `source`: the original of a clone)
	built = function(entity, tags, source) M.on_built(entity, tags, source) end,
})

return M
