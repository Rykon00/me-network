--------------------------------------------------------------------------------
--- FORK AE2: THE FLUID SIDE OF THE ME STORAGE BUS (issue #68: the ME Fluid Storage Bus; issue #3 of me-network:
--- one storage bus for items and fluids, scripts/fork-me-storagebus.lua; docs/ME-REWORK.md "Fluid storage bus")
---   * A storage bus that faces a storage tank (or any entity with a fluid box that is no ME block) makes the fluid
---     of that tank's FLUID SEGMENT storage of the network. A tank shares its fluid with the pipes and tanks of its
---     segment, so the segment, not the tank, is the unit of storage: two tanks of one segment hold one amount of
---     fluid and are counted once. The storage bus module decides the side when it resolves the target
---     (`take`) and hands the fluid side's visits to this module.
---   * Identity: the faced fluid box's segment id (LuaFluidBox.get_fluid_segment_id), "s<id>". A fluid box that
---     belongs to no segment (a machine's box) is its own storage, "u<unit>:<box>". One bus per segment: a second
---     bus on the same segment, through any of its tanks, gets the status "shared-target" and takes over when the
---     first one goes. Building or removing pipes merges and splits segments and changes their ids; every visit
---     reads the id again, and two buses that end up on one segment are resolved in unit order (the lower unit
---     number keeps it, the other is cleared at once, so the segment is never counted twice).
---   * Contents: get_fluid_segment_contents, a snapshot per bus applied as a difference at its visits (issue #5:
---     its own queue, scripts/fork-me-schedule.lua, with the item side's budget and intervals; the buses marked by a
---     removal first). Every insert and extract through the bus works on the real segment: the engine asks `count` (the
---     segment's real amount, 0 when the bus no longer owns the segment) before it takes and corrects the snapshot.
---   * Extract and insert: the faced entity's remove_fluid / insert_fluid act on the whole segment (tested in
---     2.0.77); a box without a segment is changed through LuaFluidBox. Insert asks how much fits: the segment's
---     capacity (LuaFluidBox.get_capacity is the segment's) minus its contents, nothing if it holds another fluid
---     or its filter is another fluid.
---   * Temperature (the network keeps one temperature per fluid, R2): the segment's fluid is read at whatever
---     temperature it has, like the import bus (what leaves the network has the fluid's default temperature).
---     Inserts are refused while the segment's temperature differs from the fluid's default by more than
---     TEMP_TOLERANCE (the status "temperature"), so the network never mixes its fluid into hot steam.
--- State: the records are the storage bus's (storage.fork_me_net.ext, external cells, side = "fluid"); this module
--- keeps the fluid side's visit list and which bus owns which segment (storage.fork_me_fsbus).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local Sched = require("scripts.fork-me-schedule")

local M = {}

local OLD_KIND = "fluid-storage-bus"      -- the old ME Fluid Storage Bus (records until scripts/fork-me-unify.lua runs)
local MIN_INTERVAL = 30                   -- ticks until a bus whose segment changed reads it again
local PREFIX = "fluid/"
local EPS = 1e-6
local TEMP_TOLERANCE = 1            -- degrees: a segment this close to the default temperature takes the network's fluid

--- the storage bus module's visit (set by it): a visit whose target is gone or turned away resolves the target again
M.resolve_visit = nil
--- the storage bus module puts a bus that lost its fluid target into its own visit list (set by it)
M.lost = nil

local function state()
	local s = storage.fork_me_fsbus
	if not s then
		s = { list = {}, cursor = 1, claims = {}, urgent = {} }   -- claims: storage key -> bus unit
		storage.fork_me_fsbus = s
	end
	return s
end

--- the queue of the fluid side's visits; a save from before issue #5 gets one with every bus due within a second
local function queue(s)
	if s.q then return s.q end
	s.q = Sched.new()
	for i, unit in ipairs(s.list) do
		local rec = N.ext_get(unit)
		if rec then Sched.at(s.q, rec, unit, game.tick + 1 + (i - 1) % 60) end
	end
	return s.q
end

--- a record of a bus on fluid (the storage bus's fluid side, or an old fluid storage bus)
local function on_fluid(rec) return rec ~= nil and (rec.side == "fluid" or rec.ext == OLD_KIND) end

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
--- the external cell's functions (the storage bus's dispatch calls them on its fluid side)
--------------------------------------------------------------------------------

M.handlers = {
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
--- the handler of the storage bus's fluid side (rec.handler) and of old fluid storage buses until they are replaced
M.HANDLER = OLD_KIND
N.ext_handlers[OLD_KIND] = M.handlers

--------------------------------------------------------------------------------
--- target, claim and visit
--------------------------------------------------------------------------------

local function release(s, rec)
	if rec.seg and s.claims[rec.seg] == rec.unit then s.claims[rec.seg] = nil end
	rec.seg = nil
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

--- the storage bus resolves its target: can `o` be its fluid storage? (then rec.target, target_unit and box are set)
function M.take(rec, o)
	if not (o.unit_number and o.type ~= "entity-ghost") then return false end
	local ok, box = pcall(pick_box, o, rec.entity.position)
	if not (ok and box) then return false end
	rec.target, rec.target_unit, rec.box = o, o.unit_number, box
	return true
end

--- the bus leaves its fluid target (its claim goes; the storage bus clears the target)
function M.drop(rec)
	local s = storage.fork_me_fsbus
	if s then release(s, rec) end
	rec.seg, rec.box, rec.temp, rec.fluid = nil, nil, nil, nil
end

function M.list(rec)
	local s = state()
	for _, u in ipairs(s.list) do if u == rec.unit then return end end
	s.list[#s.list + 1] = rec.unit
	rec.siv = nil
	Sched.at(queue(s), rec, rec.unit, game.tick + 1)
end

--- read the segment at the next tick
function M.wake(rec)
	local s = storage.fork_me_fsbus
	if not s then return end
	rec.siv = nil
	Sched.wake(queue(s), rec, rec.unit, game.tick + 1)
end

function M.unlist(rec)
	local s = storage.fork_me_fsbus
	if not s then return end
	for i = #s.list, 1, -1 do if s.list[i] == rec.unit then table.remove(s.list, i) end end
	s.urgent[rec.unit] = nil
end

--- does bus `other` still own `key`? (it faces the storage and its live key is still `key`)
local function holds(other, key)
	local o = N.ext_get(other)
	if not (on_fluid(o) and o.entity.valid and o.seg == key) then return false end
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
			if cascade and on_fluid(o) and o.entity.valid then
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

--- One visit of a bus on fluid: claim its segment, read the segment once and apply the difference to the network.
--- `cascade` (default true): a stale claim of another bus makes that bus visit too. A bus whose target is gone or
--- that was rotated resolves its target again through the storage bus (it may face a chest now). Returns true when
--- the snapshot or the segment changed.
function M.visit(rec, cascade)
	local s = state()
	local e = rec.entity
	if not e.valid then return false end
	local t = rec.target
	if not (t and t.valid and rec.dir == e.direction and rec.box) then
		if M.resolve_visit and rec.ext ~= OLD_KIND then return M.resolve_visit(rec, cascade) end
		local changed = N.ext_sync(rec.unit, {})
		rec.status = "no-target"
		return changed
	end
	local seg = rec.seg
	local contents = {}
	rec.temp, rec.fluid = nil, nil
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
	local changed = N.ext_sync(rec.unit, contents) or seg ~= rec.seg
	if rec.status == "ok" or rec.status == "temperature" then
		local net = N.network_of(e)
		local ok, why = N.usable(net)
		if not ok then rec.status = why or "no-network" end
	end
	return changed
end

local function fluid_rec(unit)
	local rec = N.ext_get(unit)
	if on_fluid(rec) then return rec end
	return nil
end

local function visit_due(rec, unit)
	local s = storage.fork_me_fsbus
	if not rec.entity.valid then
		for i = #s.list, 1, -1 do if s.list[i] == unit then table.remove(s.list, i) end end
		N.ext_detach(unit)
		return
	end
	local changed = M.visit(rec)
	if not on_fluid(rec) then return end                -- on the item side now: its queue has it
	local idle = Sched.idle_limit(Sched.setting("storage_bus_idle"), #s.list, 8 / 15, MIN_INTERVAL)   -- (as the item side)
	rec.siv = Sched.interval(rec.siv, changed and 1 or 0, true, MIN_INTERVAL, MIN_INTERVAL, idle)
	Sched.at(queue(s), rec, unit, game.tick + rec.siv)
end

--- every tick (from the storage bus module): first the buses marked by a removal, then the buses that are due, at
--- most the setting "storage bus visits per tick"
function M.on_tick(tick)
	local s = storage.fork_me_fsbus
	if not (s and #s.list > 0) then return end
	if next(s.urgent) then
		local units = {}
		for unit in pairs(s.urgent) do units[#units + 1] = unit end
		table.sort(units)
		s.urgent = {}
		for _, unit in ipairs(units) do
			local rec = N.ext_get(unit)
			if on_fluid(rec) and rec.entity.valid then M.visit(rec) end
		end
	end
	Sched.run(queue(s), tick, Sched.setting("storage_bus"), fluid_rec, visit_due)
end

--- the remote's step (tests): what the fluid side does in one tick
function M.on_step() M.on_tick(game.tick) end

--- A removed entity that is no storage bus: the tank a bus faces leaves the network at once. Any other removed
--- entity with a fluid box (a pipe, a tank of the segment) may split a claimed segment: its owner is visited in the
--- next I/O step (the engine already never takes more than is there).
function M.on_removed(entity)
	local s = storage.fork_me_fsbus
	if not (s and entity and entity.valid and entity.unit_number) then return end
	local unit = entity.unit_number
	local fb = entity.fluidbox
	if not (fb and #fb > 0) then return end
	local lost = {}
	for _, bus in ipairs(s.list) do
		local r = N.ext_get(bus)
		if on_fluid(r) and r.target_unit == unit then lost[#lost + 1] = r end
	end
	for _, r in ipairs(lost) do
		M.drop(r)
		r.target, r.target_unit, r.status = nil, nil, "no-target"
		N.ext_sync(r.unit, {})
		if r.side == "fluid" and M.lost then          -- no side until it faces something again (the item list)
			r.side, r.handler = nil, nil
			M.unlist(r)
			M.lost(r)
		end
	end
	for i = 1, #fb do
		local id = fb.get_fluid_segment_id(i)
		local owner = id and s.claims["s" .. id]
		if owner then s.urgent[owner] = true end
	end
end

--- after the graph rebuild (the storage bus module lists its fluid side buses again, in unit order)
function M.reset()
	local s = state()
	s.list, s.cursor, s.claims, s.urgent, s.q = {}, 1, {}, {}, Sched.new()
end

return M
