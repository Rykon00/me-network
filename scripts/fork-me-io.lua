--------------------------------------------------------------------------------
--- FORK AE2: IMPORT AND EXPORT (issue #68, step R1; prototypes/120-fork-ae2.lua, docs/ME-REWORK.md)
---   * ME Interface: a container whose slots can be filtered. A filtered slot is an export slot: the
---     network keeps it filled with its item up to a full stack. Every unfiltered slot is imported: its
---     items go into the network (items the network cannot store stay). Inserters work with it like with
---     a chest. Filters are kept in blueprints (tag fork_me_interface), settings paste and clones.
---   * ME Import Bus / ME Export Bus: face one entity (their direction). The import bus pulls items from the
---     entity's output (assembler, furnace result, chest), the export bus puts its filtered items into the
---     entity's input (assembler or furnace input: up to one stack each; chest: as far as it has room).
---     Up to MAX_FILTERS filters (import: none = everything), set in a small window (open key), kept in
---     blueprints (tag fork_me_bus), settings paste and clones.
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
local MAX_FILTERS = 5
local IFACE_TAG, BUS_TAG = "fork_me_interface", "fork_me_bus"
local BUS_FRAME = "fork_me_bus"
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

--- one visit: unfiltered slots into the network, filtered slots topped up from it
function M.interface_step(rec)
	local e = rec.entity
	local net = N.active_of(e)
	if not net then
		local _, why = N.usable(N.network_of(e))
		rec.status = why or "no-network"
		return 0
	end
	local inv = e.get_inventory(defines.inventory.chest)
	local ops, moved = 0, 0
	local start = rec.slot or 1
	local size = #inv
	for k = 0, size - 1 do
		if ops >= IFACE_SLOTS_PER_VISIT then rec.slot = (start - 1 + k) % size + 1 break end
		local i = (start - 1 + k) % size + 1
		local stack = inv[i]
		local name, q = filter_of(inv, i)
		if name then
			local have = stack.valid_for_read and stack.count or 0
			local want = prototypes.item[name] and prototypes.item[name].stack_size - have or 0
			if want > 0 and (not stack.valid_for_read or (stack.name == name and stack.quality.name == q)) then
				local avail = N.count(net, name, q)
				local give = math.min(want, avail)
				if give > 0 then
					local got = N.extract(net, name, q, give)
					if stack.valid_for_read then stack.count = stack.count + got
					else stack.set_stack{ name = name, quality = q, count = got } end
					moved = moved + got
					ops = ops + 1
				end
			end
		elseif stack.valid_for_read then
			local n = N.insert_stack(net, stack)
			if n then moved = moved + n ops = ops + 1 end
		end
	end
	if ops < IFACE_SLOTS_PER_VISIT then rec.slot = 1 end
	rec.status = "ok"
	return moved
end

function M.get_interface_filters(entity)
	if kind(entity) ~= "interface" then return nil end
	local inv = entity.get_inventory(defines.inventory.chest)
	local out = {}
	for i = 1, #inv do
		local name, q = filter_of(inv, i)
		if name then out[i] = { name = name, quality = q } end
	end
	return out
end

function M.set_interface_filters(entity, filters)
	if kind(entity) ~= "interface" then return false end
	local inv = entity.get_inventory(defines.inventory.chest)
	for i = 1, #inv do
		local f = filters and filters[i]
		if f and prototypes.item[f.name] then
			inv.set_filter(i, { name = f.name, quality = f.quality or "normal" })
		else
			inv.set_filter(i, nil)
		end
	end
	return true
end

--------------------------------------------------------------------------------
--- buses
--------------------------------------------------------------------------------

local OUTPUT = { ["assembling-machine"] = defines.inventory.crafter_output, ["furnace"] = defines.inventory.furnace_result,
	["container"] = defines.inventory.chest, ["logistic-container"] = defines.inventory.chest }
local INPUT = { ["assembling-machine"] = defines.inventory.crafter_input, ["furnace"] = defines.inventory.furnace_source,
	["container"] = defines.inventory.chest, ["logistic-container"] = defines.inventory.chest }

--- the entity in front of a bus that has the inventory the bus works with (cached until it is gone)
local function target_of(rec)
	local t = rec.target
	local e = rec.entity
	if t and t.valid and rec.dir == e.direction then return t end
	rec.target, rec.dir = nil, e.direction
	local d = FRONT[e.direction] or FRONT[defines.direction.north]
	local table_ = rec.kind == "import-bus" and OUTPUT or INPUT
	for _, o in pairs(e.surface.find_entities_filtered{ position = { e.position.x + d[1], e.position.y + d[2] } }) do
		if o.valid and table_[o.type] and not N.kind_of(o.name) then
			rec.target = o
			return o
		end
	end
	return nil
end

local function allowed(rec, name)
	if #rec.filters == 0 then return rec.kind == "import-bus" end
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
	if rec.kind == "import-bus" then
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

function M.set_bus_filters(entity, filters)
	local k = kind(entity)
	if k ~= "import-bus" and k ~= "export-bus" then return false end
	local rec = register(state(), entity)
	local list, seen = {}, {}
	for _, name in pairs(filters or {}) do
		if type(name) == "string" and prototypes.item[name] and not seen[name] and #list < MAX_FILTERS then
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

--------------------------------------------------------------------------------
--- bus window (screen frame, the open key)
--------------------------------------------------------------------------------

local function bus_gui_open(player, entity)
	local frame = player.gui.screen[BUS_FRAME]
	if frame then frame.destroy() end
	local rec = register(state(), entity)
	frame = player.gui.screen.add{ type = "frame", name = BUS_FRAME, direction = "vertical", caption = entity.localised_name,
		tags = { unit = entity.unit_number } }
	frame.auto_center = true
	local help = frame.add{ type = "label", caption = { "fork-me-net." .. rec.kind .. "-help" } }
	help.style.single_line = false
	help.style.maximal_width = 300
	local row = frame.add{ type = "flow", direction = "horizontal" }
	for i = 1, MAX_FILTERS do
		row.add{ type = "choose-elem-button", elem_type = "item", item = rec.filters[i], tags = { fork_me_bus_filter = i } }
	end
	frame.add{ type = "label", name = "fork_me_bus_status", caption = { "fork-me-net.bus-" .. (rec.status or "ok") } }
	player.opened = frame
end

function M.on_open_input(player, entity)
	local k = kind(entity)
	if k ~= "import-bus" and k ~= "export-bus" then return false end
	if player.can_reach_entity(entity) then bus_gui_open(player, entity) end
	return true
end

function M.on_gui_elem_changed(event)
	local el = event.element
	local index = el and el.valid and el.tags and el.tags.fork_me_bus_filter
	if not index then return false end
	local frame = game.get_player(event.player_index).gui.screen[BUS_FRAME]
	local rec = frame and state().recs[frame.tags.unit]
	if not (rec and rec.entity.valid) then return true end
	local list = {}
	for i = 1, MAX_FILTERS do
		local v = i == index and el.elem_value or rec.filters[i]
		if v then list[#list + 1] = v end
	end
	M.set_bus_filters(rec.entity, list)
	return true
end

function M.on_gui_closed(event)
	local el = event.element
	if not (el and el.valid and el.name == BUS_FRAME) then return false end
	el.destroy()
	return true
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
	if k ~= "interface" and k ~= "import-bus" and k ~= "export-bus" then return end
	register(state(), entity)
	if k == "interface" then
		local t = type(tags) == "table" and tags[IFACE_TAG] or nil
		if type(t) == "table" then M.set_interface_filters(entity, t.filters)
		elseif source and source.valid and kind(source) == "interface" then M.set_interface_filters(entity, M.get_interface_filters(source)) end
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
	if k == "interface" then M.set_interface_filters(dst, M.get_interface_filters(src))
	elseif k == "import-bus" or k == "export-bus" then
		local from = M.get_bus(src)
		M.set_bus_filters(dst, from and from.filters or {})
	end
end

--- blueprint hook of the autocrafting module (one on_player_setup_blueprint handler)
function M.tag_blueprint(bp, mapping)
	for index, entity in pairs(mapping) do
		local k = kind(entity)
		if k == "interface" then
			local f = M.get_interface_filters(entity)
			if next(f) then bp.set_blueprint_entity_tag(index, IFACE_TAG, { filters = f }) end
		elseif k == "import-bus" or k == "export-bus" then
			local b = M.get_bus(entity)
			if b and #b.filters > 0 then bp.set_blueprint_entity_tag(index, BUS_TAG, { filters = b.filters }) end
		end
	end
end

--- rebuild the records from the world; filters of buses are kept by unit number
function M.on_configuration_changed()
	local s = state()
	local old = s.recs
	s.recs, s.list, s.cursor = {}, {}, 1
	local names = {}
	for _, name in pairs(N.node_names()) do
		local k = N.kind_of(name)
		if k == "interface" or k == "import-bus" or k == "export-bus" then names[#names + 1] = name end
	end
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = names }) do
			local rec = register(s, e)
			local o = old[e.unit_number]
			if o and o.filters then M.set_bus_filters(e, o.filters) end
			rec.target = nil
		end
	end
	table.sort(s.list)
	for _, player in pairs(game.players) do
		local frame = player.gui.screen[BUS_FRAME]
		if frame then frame.destroy() end
	end
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
	set_interface_filters = function(entity, filters) return M.set_interface_filters(entity, filters) end,
	get_interface_filters = function(entity) return M.get_interface_filters(entity) end,
	set_bus_filters = function(entity, filters) return M.set_bus_filters(entity, filters) end,
	get_bus = function(entity) return M.get_bus(entity) end,
	paste = function(source, destination) M.on_entity_settings_pasted{ source = source, destination = destination } end,
	tag_blueprint = function(bp, mapping) M.tag_blueprint(bp, mapping) end,
})

return M
