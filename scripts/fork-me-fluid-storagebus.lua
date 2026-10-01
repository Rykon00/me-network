--------------------------------------------------------------------------------
--- FORK AE2: ME FLUID STORAGE BUS (issue #68; prototypes/122-fork-ae2-fluids.lua, docs/ME-REWORK.md "Fluid storage bus")
---   * A rotatable 1x1 ME block that faces a storage tank (or any entity with a fluid box that is no ME block):
---     the fluid of that tank's FLUID SEGMENT becomes storage of the network. A tank shares its fluid with the
---     pipes and tanks of its segment, so the segment, not the tank, is the unit of storage: two tanks of one
---     segment hold one amount of fluid and are counted once.
---   * Identity: the faced fluid box's segment id (LuaFluidBox.get_fluid_segment_id), "s<id>". A fluid box that
---     belongs to no segment (a machine's box) is its own storage, "u<unit>:<box>". One bus per segment: a second
---     bus on the same segment, through any of its tanks, gets the status "shared-target" and takes over when the
---     first one goes. Building or removing pipes merges and splits segments and changes their ids; every visit
---     reads the id again, and two buses that end up on one segment are resolved in unit order (the lower unit
---     number keeps it, the other is cleared at once, so the segment is never counted twice).
---   * Contents: get_fluid_segment_contents, a snapshot per bus applied as a difference in the I/O step (15
---     ticks, scripts/fork-me-io.lua), VISITS_PER_STEP buses round robin, as the item storage bus does. Every
---     insert and extract through the bus works on the real segment: the engine asks `count` (the segment's real
---     amount, 0 when the bus no longer owns the segment) before it takes and corrects the snapshot.
---   * Extract and insert: the faced entity's remove_fluid / insert_fluid act on the whole segment (tested in
---     2.0.77); a box without a segment is changed through LuaFluidBox. Insert asks how much fits: the segment's
---     capacity (LuaFluidBox.get_capacity is the segment's) minus its contents, nothing if it holds another fluid
---     or its filter is another fluid.
---   * Temperature (the network keeps one temperature per fluid, R2): the segment's fluid is read at whatever
---     temperature it has, like the fluid import bus (what leaves the network has the fluid's default
---     temperature). Inserts are refused while the segment's temperature differs from the fluid's default by more
---     than TEMP_TOLERANCE (the status "temperature"), so the network never mixes its fluid into hot steam.
---   * Settings: fluid filters (a whitelist; none = every fluid), priority (-1000 ... 1000, shared with the drives
---     and the item storage buses) and mode (read and write, read only, write only). Kept in blueprints (tag
---     fork_me_fluid_storage_bus), settings paste and clones.
--- State: the records live in the network module (storage.fork_me_net.ext, they are external cells); this module
--- keeps the visit list and which bus owns which segment (storage.fork_me_fsbus).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")

local M = {}

local KIND = "fluid-storage-bus"
local VISITS_PER_STEP = 8           -- bus visits per I/O step (every 15 ticks)
local MAX_FILTERS = 5
local MAX_PRIORITY = 1000
local TAG = "fork_me_fluid_storage_bus"   -- blueprint tag: { mode, priority, filters = { fluid names } }
local MODES = { readwrite = true, read = true, write = true }
local PREFIX = "fluid/"
local EPS = 1e-6
local TEMP_TOLERANCE = 1            -- degrees: a segment this close to the default temperature takes the network's fluid
local FRONT = {
	[defines.direction.north] = { 0, -1 }, [defines.direction.east] = { 1, 0 },
	[defines.direction.south] = { 0, 1 }, [defines.direction.west] = { -1, 0 },
}

local function state()
	local s = storage.fork_me_fsbus
	if not s then
		s = { list = {}, cursor = 1, claims = {}, urgent = {} }   -- claims: storage key -> bus unit
		storage.fork_me_fsbus = s
	end
	return s
end

local function is_bus(entity) return entity and entity.valid and N.kind_of(entity.name) == KIND end

local function rec_of(entity)
	return entity and entity.valid and entity.unit_number and N.ext_get(entity.unit_number) or nil
end

local function fluid_of(key)
	if not N.is_fluid_key(key) then return nil end
	local name = key:sub(#PREFIX + 1)
	return prototypes.fluid[name] and name or nil
end

local function allowed(rec, key)
	return rec.partition == nil or rec.partition[key] == true
end

--------------------------------------------------------------------------------
--- the storage behind a bus: the faced fluid box, its segment
--------------------------------------------------------------------------------

--- the storage key of the faced box now ("s<segment id>", or "u<unit>:<box>" for a box without a segment), and
--- whether it is a segment
local function live_key(rec)
	local t = rec.target
	if not (t and t.valid and rec.box) then return nil end
	local id = t.fluidbox.get_fluid_segment_id(rec.box)
	if id then return "s" .. id, true end
	return "u" .. t.unit_number .. ":" .. rec.box, false
end

--- does the bus own the storage it faces right now? (the handlers work only then)
local function owns(rec)
	local key = live_key(rec)
	if not key or key ~= rec.seg then return false end
	local s = storage.fork_me_fsbus
	return s ~= nil and s.claims[key] == rec.unit
end

--- { fluid name -> amount } of the storage, its temperature (nil when unknown) and whether it is a segment
local function contents_of(rec)
	local t = rec.target
	local fb = t.fluidbox
	local held = fb[rec.box]
	local temp = held and held.temperature or nil
	if fb.get_fluid_segment_id(rec.box) then
		return fb.get_fluid_segment_contents(rec.box) or {}, temp, true
	end
	if held and held.amount > EPS then return { [held.name] = held.amount }, temp, false end
	return {}, temp, false
end

local function default_temperature(name)
	local p = prototypes.fluid[name]
	return p and p.default_temperature or 15
end

--- may the network put `name` in? (another fluid, a filter of another fluid, another temperature: no)
local function accepts(rec, name)
	local contents, temp = contents_of(rec)
	for other, amount in pairs(contents) do
		if other ~= name and amount > EPS then return false end
	end
	local f = rec.target.fluidbox.get_filter(rec.box)
	if f and f.name and f.name ~= name then return false end
	if temp and (contents[name] or 0) > EPS and math.abs(temp - default_temperature(name)) > TEMP_TOLERANCE then return false end
	return true, contents[name] or 0
end

--------------------------------------------------------------------------------
--- the external cell's functions (called by the storage engine)
--------------------------------------------------------------------------------

N.ext_handlers[KIND] = {
	--- units of `key` the storage takes now
	room = function(rec, key)
		if rec.mode == "read" or not allowed(rec, key) then return 0 end
		local name = fluid_of(key)
		if not (name and owns(rec)) then return 0 end
		local ok, have = accepts(rec, name)
		if not ok then return 0 end
		return math.max(0, rec.target.fluidbox.get_capacity(rec.box) - have)
	end,
	--- put up to `amount` in (at the fluid's default temperature); returns the amount inserted
	insert = function(rec, key, amount)
		if rec.mode == "read" or not allowed(rec, key) then return 0 end
		local name = fluid_of(key)
		if not (name and owns(rec) and accepts(rec, name)) then return 0 end
		local t = rec.target
		local temp = default_temperature(name)
		if t.fluidbox.get_fluid_segment_id(rec.box) then
			return t.insert_fluid{ name = name, amount = amount, temperature = temp }
		end
		local fb = t.fluidbox
		local held = fb[rec.box]
		local have = held and held.amount or 0
		local n = math.min(amount, fb.get_capacity(rec.box) - have)
		if n <= EPS then return 0 end
		fb[rec.box] = { name = name, amount = have + n, temperature = held and held.temperature or temp }
		local now = fb[rec.box]
		return math.max(0, (now and now.name == name and now.amount or 0) - have)
	end,
	--- the real amount of `key` in the storage (0 when the bus cannot take from it)
	count = function(rec, key)
		if rec.mode == "write" or not allowed(rec, key) then return 0 end
		local name = fluid_of(key)
		if not (name and owns(rec)) then return 0 end
		local contents = contents_of(rec)
		return contents[name] or 0
	end,
	--- take up to `amount` out; returns the amount removed
	extract = function(rec, key, amount)
		if rec.mode == "write" then return 0 end
		local name = fluid_of(key)
		if not (name and owns(rec)) then return 0 end
		local t = rec.target
		if t.fluidbox.get_fluid_segment_id(rec.box) then
			return t.remove_fluid{ name = name, amount = amount }
		end
		local fb = t.fluidbox
		local held = fb[rec.box]
		if not (held and held.name == name) then return 0 end
		local n = math.min(amount, held.amount)
		local left = held.amount - n
		fb[rec.box] = left > EPS and { name = name, amount = left, temperature = held.temperature } or nil
		return n
	end,
}

--------------------------------------------------------------------------------
--- target, claim and visit
--------------------------------------------------------------------------------

local function release(s, rec)
	if rec.seg and s.claims[rec.seg] == rec.unit then s.claims[rec.seg] = nil end
	rec.seg = nil
end

local function drop_target(s, rec)
	release(s, rec)
	rec.target, rec.target_unit, rec.box = nil, nil, nil
end

--- the fluid box of `o` the bus uses: the one with a pipe connection to the bus's tile, else the only one, else
--- the first one in a segment, else the first
local function pick_box(o, bus_pos)
	local fb = o.fluidbox
	local n = #fb
	if n == 0 then return nil end
	if n == 1 then return 1 end
	local first_seg
	for i = 1, n do
		for _, c in pairs(fb.get_pipe_connections(i)) do
			local tp = c.target_position
			if tp and math.abs(tp.x - bus_pos.x) < 0.5 and math.abs(tp.y - bus_pos.y) < 0.5 then return i end
		end
		if not first_seg and fb.get_fluid_segment_id(i) then first_seg = i end
	end
	return first_seg or 1
end

--- the entity in front of the bus; sets rec.target and rec.box, or rec.status
local function find_target(s, rec)
	local e = rec.entity
	local t = rec.target
	if t and t.valid and rec.dir == e.direction and rec.box then return t end
	drop_target(s, rec)
	rec.dir = e.direction
	local d = FRONT[e.direction] or FRONT[defines.direction.north]
	rec.status = "no-target"
	for _, o in pairs(e.surface.find_entities_filtered{ position = { e.position.x + d[1], e.position.y + d[2] } }) do
		if o.valid and o ~= e then
			if N.kind_of(o.name) or o.name:sub(1, 3) == "me-" then
				rec.status = "me-target"                     -- an ME block (the fluid interface too): no loops
				return nil
			end
			local ok, box = false, nil
			if o.unit_number and o.type ~= "entity-ghost" then ok, box = pcall(pick_box, o, e.position) end
			if ok and box then
				rec.target, rec.target_unit, rec.box = o, o.unit_number, box
				return o
			end
		end
	end
	return nil
end

--- does bus `other` still own `key`? (it faces the storage and its live key is still `key`)
local function holds(other, key)
	local o = N.ext_get(other)
	if not (o and o.ext == KIND and o.entity.valid and o.seg == key) then return false end
	if not (o.target and o.target.valid) then return false end
	return live_key(o) == key
end

--- The storage key of the bus now, claimed if possible. Conflicts are resolved in unit order: an older claim of
--- a lower unit wins; a stale claim (the other bus faces another segment now) is taken over and that bus is
--- visited at once, so a segment is never in two snapshots.
local function claim(s, rec, cascade)
	local key = live_key(rec)
	if rec.seg ~= key then release(s, rec) end
	if not key then return nil end
	local other = s.claims[key]
	if other and other ~= rec.unit then
		if holds(other, key) then
			if other < rec.unit then
				rec.status = "shared-target"
				return nil
			end
			local o = N.ext_get(other)                       -- this bus has the lower unit: the other one gives way
			o.seg, o.status = nil, "shared-target"
			N.ext_sync(other, {})
		else
			s.claims[key] = nil
			local o = N.ext_get(other)
			if cascade and o and o.ext == KIND and o.entity.valid then
				s.claims[key] = rec.unit
				rec.seg = key
				M.visit(o, false)                            -- the other bus moved to another segment: its snapshot now
			end
		end
	end
	s.claims[key] = rec.unit
	rec.seg = key
	return key
end

--- One visit: find the target, claim its segment, read the segment once and apply the difference to the network.
--- `cascade` (default true): a stale claim of another bus makes that bus visit too.
function M.visit(rec, cascade)
	local s = state()
	local e = rec.entity
	if not e.valid then return end
	local contents = {}
	rec.temp, rec.fluid = nil, nil
	if find_target(s, rec) then
		rec.status = "ok"
		if claim(s, rec, cascade ~= false) then
			local held, temp = contents_of(rec)
			for name, amount in pairs(held) do
				if amount > EPS then
					rec.fluid, rec.temp = name, temp
					local key = PREFIX .. name
					if rec.mode ~= "write" and allowed(rec, key) then contents[key] = amount end
					if temp and math.abs(temp - default_temperature(name)) > TEMP_TOLERANCE then rec.status = "temperature" end
				end
			end
		end
	end
	N.ext_sync(rec.unit, contents)
	if rec.status == "ok" or rec.status == "temperature" then
		local net = N.network_of(e)
		local ok, why = N.usable(net)
		if not ok then rec.status = why or "no-network" end
	end
end

--- the I/O step (scripts/fork-me-io.lua): first the buses marked by a removal, then VISITS_PER_STEP buses, round robin
function M.on_step()
	local s = storage.fork_me_fsbus
	if not (s and #s.list > 0) then return end
	if next(s.urgent) then
		local units = {}
		for unit in pairs(s.urgent) do units[#units + 1] = unit end
		table.sort(units)
		s.urgent = {}
		for _, unit in ipairs(units) do
			local rec = N.ext_get(unit)
			if rec and rec.ext == KIND and rec.entity.valid then M.visit(rec) end
		end
	end
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

--- filters checked against the prototypes: fluid names, at most MAX_FILTERS
local function clean_filters(filters)
	local out, seen = {}, {}
	if type(filters) ~= "table" then return out end
	for _, name in ipairs(filters) do
		if type(name) == "string" and N.is_fluid_key(name) then name = name:sub(#PREFIX + 1) end
		if type(name) == "string" and not seen[name] and #out < MAX_FILTERS and prototypes.fluid[name] then
			seen[name] = true
			out[#out + 1] = name
		end
	end
	return out
end

--- the settings of a bus: { mode, priority, filters = { fluid names } }
function M.get_settings(entity)
	local rec = rec_of(entity)
	if not (rec and rec.ext == KIND) then return nil end
	return { mode = rec.mode, priority = rec.priority or 0, filters = { table.unpack(rec.filters) } }
end

--- Apply settings (missing fields keep their value); the segment is read again at once
function M.set_settings(entity, settings)
	local rec = rec_of(entity)
	if not (rec and rec.ext == KIND and type(settings) == "table") then return false end
	if MODES[settings.mode] then rec.mode = settings.mode end
	if settings.priority ~= nil then
		local p = math.floor(tonumber(settings.priority) or 0)
		rec.priority = math.max(-MAX_PRIORITY, math.min(MAX_PRIORITY, p))
	end
	if settings.filters ~= nil then
		rec.filters = clean_filters(settings.filters)
		local set
		for _, name in ipairs(rec.filters) do
			set = set or {}
			set[PREFIX .. name] = true
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

--- one filter button of the window: `name` nil removes it; the list stays packed
function M.set_filter(entity, index, name)
	local rec = rec_of(entity)
	if not (rec and rec.ext == KIND) then return false end
	local list = {}
	for i = 1, MAX_FILTERS do
		local v
		if i == index then v = name else v = rec.filters[i] end
		if v then list[#list + 1] = v end
	end
	return M.set_filters(entity, list)
end

--- the window's data: { mode, priority, filters, max, status, target, fluid, amount, temperature, segment, contents }
function M.info(entity)
	local rec = rec_of(entity)
	if not (rec and rec.ext == KIND) then return nil end
	local amount = 0
	for _, n in pairs(rec.items) do amount = amount + n end
	local t = rec.target
	return { mode = rec.mode, priority = rec.priority or 0, filters = { table.unpack(rec.filters) }, max = MAX_FILTERS,
		status = rec.status or "ok", target = t and t.valid and t.name or nil, fluid = rec.fluid, amount = amount,
		temperature = rec.temp, segment = rec.seg, contents = rec.items }
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

--- A removed entity: a bus gives up its segment (the network module drops its cell). The tank a bus faces leaves
--- the network at once. Any other removed entity with a fluid box (a pipe, a tank of the segment) may split a
--- claimed segment: its owner is visited in the next I/O step (the engine already never takes more than is there).
function M.on_removed(entity)
	local s = storage.fork_me_fsbus
	if not (s and entity and entity.valid and entity.unit_number) then return end
	local unit = entity.unit_number
	local rec = N.ext_get(unit)
	if rec and rec.ext == KIND then
		release(s, rec)
		s.urgent[unit] = nil
		for i = #s.list, 1, -1 do if s.list[i] == unit then table.remove(s.list, i) end end
		return
	end
	local fb = entity.fluidbox
	if not (fb and #fb > 0) then return end
	for _, bus in ipairs(s.list) do
		local r = N.ext_get(bus)
		if r and r.target_unit == unit then
			drop_target(s, r)
			r.status = "no-target"
			N.ext_sync(bus, {})
		end
	end
	for i = 1, #fb do
		local id = fb.get_fluid_segment_id(i)
		local owner = id and s.claims["s" .. id]
		if owner then s.urgent[owner] = true end
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

--- after the graph rebuild: every fluid storage bus has a record and is in the visit list, segments are claimed
--- again in unit order
function M.on_configuration_changed()
	local s = state()
	s.list, s.cursor, s.claims, s.urgent = {}, 1, {}, {}
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
		rec.target, rec.target_unit, rec.box, rec.dir, rec.seg = nil, nil, nil, nil, nil
	end
	for _, e in ipairs(all) do M.visit(N.ext_get(e.unit_number)) end
end

remote.add_interface("gregtorio-me-fluid-storagebus", {
	--- one visit now (what the I/O step does)
	visit = function(entity)
		local rec = rec_of(entity)
		if rec and rec.ext == KIND then M.visit(rec) end
		return rec ~= nil
	end,
	--- the I/O step's part of this module (urgent visits, then the round robin)
	step = function() M.on_step() end,
	info = function(entity) return M.info(entity) end,
	get_settings = function(entity) return M.get_settings(entity) end,
	set_settings = function(entity, settings) return M.set_settings(entity, settings) end,
	set_filter = function(entity, index, name) return M.set_filter(entity, index, name) end,
	paste = function(source, destination) M.on_entity_settings_pasted{ source = source, destination = destination } end,
	tag_blueprint = function(bp, mapping) M.tag_blueprint(bp, mapping) end,
	built = function(entity, tags, source) M.on_built(entity, tags, source) end,
	--- what the removal events do (destroy() raises none)
	removed = function(entity) M.on_removed(entity) end,
	rotated = function(entity) M.on_rotated(entity) end,
})

return M
