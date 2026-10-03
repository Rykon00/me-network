--------------------------------------------------------------------------------
--- FORK AE2: IMPORT AND EXPORT (issue #68, step R1; issue #3 of me-network: items and fluids in one block;
--- prototypes/network.lua, prototypes/fluids.lua, docs/ME-REWORK.md)
---   * ME Interface: a container with up to CONFIG_SLOTS config rows (R3, AE2's config slots), each an item
---     (name, quality, amount) or a fluid (type "fluid", name, amount), mixed. The network keeps the amount of
---     each configured item in the container (fills up, takes back the surplus); every other item in it is
---     imported into the network (items the network cannot store stay). Inserters work with it like with a
---     chest. Saves before R3 used the container's slot filters: they become config rows (one full stack per
---     filtered slot) the first time the interface is visited, and the filters are cleared (config_of).
---   * Its fluids (issue #3): four hidden storage tanks on its tile, one per side (SIDES: north, east, south,
---     west), each connected only to the pipe on its side. A side is an import side (the default: what is piped
---     in goes into the network, the whole fluid segment, like the old ME Fluid Interface), off, or tied to a
---     fluid row (its tank is kept at the row's amount from the network). Several sides may share a row; four
---     fluids at most at once. Sides whose segment is that of an export side of the same interface import
---     nothing (a pipe loop). Mined: the sides' fluid goes into the network; destroyed: it is lost like a tank's.
---     An interface that moved nothing is visited less and less often (issue #5); building a fluid entity next to
---     one wakes it.
---   * The config and the sides are kept in script (rec.config, rec.sides), in blueprints (tag
---     fork_me_interface = { config, sides, priority }), settings paste and clones.
---   * Priority (me-network issue #17, -1000 ... 1000, rec.priority): when the network has less of an item or fluid
---     than the interfaces want, the higher priority interface is filled first. An interface whose row stays short
---     registers the shortfall in its network (net.short[key][unit] = { priority, amount }, the sums per priority in
---     net.short_p[key]); an interface takes only what is left after the shortfalls of higher priorities. While no
---     interface of the map has a priority other than 0 (s.prio empty) nothing is registered: the visit of 0.3.0.
---   * ME Import Bus / ME Export Bus: face one entity (their direction). Its kind is found once, when the
---     target is resolved, and kept with it (scripts/fork-me-targets.lua): an inventory of the bus's kind, fluid
---     boxes, or both (a machine with a fluid recipe). The import bus pulls items from the entity's output
---     (assembler, furnace result, chest) and fluid from its output boxes (a tank: every box); the export bus
---     puts its filtered items into the entity's input (machine: up to one stack each; chest: as far as it has
---     room) and its filtered fluids into the input boxes or the tank. Up to MAX_FILTERS filters, items and
---     fluids mixed (keys: item name, "fluid/<name>"), split into an item and a fluid set when they are set
---     (import: none = everything, items and fluids; export: none = nothing). Kept in blueprints (tag
---     fork_me_bus), settings paste and clones. The windows are in scripts/fork-me-windows.lua.
--- Visits (issue #5, scripts/fork-me-schedule.lua): every interface and bus is due at a tick (s.q, rec.due); the
--- on_tick handler of control.lua visits at most the setting "interface and bus visits per tick" of them. After a
--- visit the next one is MIN_INTERVAL ticks later while the block moved all it was allowed to, later while it moves
--- little (up to ACTIVE_INTERVAL), and twice as late each time it found nothing to do, up to the idle limit (a
--- setting). A bus moves its speed (a setting, items and fluid per second) times the ticks since its last visit
--- (at most MAX_CATCH_UP ticks' worth), so a bus that is visited less often moves more per visit; an interface
--- handles IFACE_SLOTS_PER_VISIT item slots per 15 ticks since its last visit, and its four sides. A block waiting
--- for a key the network does not hold (an export bus, an interface's row) wakes when the key comes in
--- (N.wait_for); its settings, a rotation and a target built in front of it wake it too.
--- State: storage.fork_me_io (records by unit number, the queue). GUI state lives in the GUI elements.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local T = require("scripts.fork-me-targets")
local Sched = require("scripts.fork-me-schedule")

local M = {}

local STEP_TICKS = 15                -- the ticks a visit of the remote `step` stands for (what one visit was before)
local MIN_INTERVAL = 15              -- ticks between two visits of a block that moved all it was allowed to
local ACTIVE_INTERVAL = 60           -- ... of a block that moves something but less
local MAX_CATCH_UP = 600             -- ticks of speed a visit may catch up at most
local IFACE_SLOTS_PER_VISIT = 8      -- item slots an interface handles per STEP_TICKS since its last visit
local MAX_FILTERS = 9
local CONFIG_SLOTS = 9
local MAX_AMOUNT = 1000000
local EPS = 1e-6
local FLUID_PREFIX = "fluid/"
local IFACE_TAG, BUS_TAG = "fork_me_interface", "fork_me_bus"
--- the sides of the interface: 1 north, 2 east, 3 south, 4 west (the directions of its side tanks)
local SIDES = { defines.direction.north, defines.direction.east, defines.direction.south, defines.direction.west }
local SIDE_OF = {}
for i, d in ipairs(SIDES) do SIDE_OF[d] = i end

local function state()
	local s = storage.fork_me_io
	if not s then
		s = { recs = {}, list = {}, cursor = 1, q = Sched.new() }
		storage.fork_me_io = s
	end
	return s
end

--- the queue of the visits; a save from before issue #5 gets one with every block due within a second
local function queue(s)
	if s.q then return s.q end
	s.q = Sched.new()
	for i, unit in ipairs(s.list) do
		local rec = s.recs[unit]
		if rec then
			rec.due = nil
			Sched.at(s.q, rec, unit, game.tick + 1 + (i - 1) % 60)
		end
	end
	return s.q
end

--- visit the block at the next tick (its settings, its target or the network changed)
local function wake(unit)
	local s = storage.fork_me_io
	local rec = s and s.recs[unit]
	if not rec then return end
	rec.iv = nil
	Sched.wake(queue(s), rec, unit, game.tick + 1)
end
M.wake = wake
N.wakers.io = wake

local function kind(entity) return entity and entity.valid and N.kind_of(entity.name) end

local function side_volume()
	local md = prototypes.mod_data["fork-me-fluids"]
	return md and md.data.side and md.data.side.volume or 5000
end
local VOLUME = nil                   -- side_volume(), read once per load (prototype data)
local function volume()
	VOLUME = VOLUME or side_volume()
	return VOLUME
end

local function register(s, entity)
	local unit = entity.unit_number
	local rec = s.recs[unit]
	if not rec then
		rec = { entity = entity, kind = kind(entity), filters = {}, status = "ok" }
		s.recs[unit] = rec
		s.list[#s.list + 1] = unit
		Sched.at(queue(s), rec, unit, game.tick + 1)
	end
	return rec
end

--------------------------------------------------------------------------------
--- interface priority (issue #17): the shortfalls of interfaces by priority, per network and key
--------------------------------------------------------------------------------

local MAX_PRIORITY = 1000

--- add `n` to the shortfall of priority `p` for `key`
local function short_sum(net, key, p, n)
	net.short_p = net.short_p or {}
	local sums = net.short_p[key]
	if not sums then
		sums = {}
		net.short_p[key] = sums
	end
	local now = (sums[p] or 0) + n
	sums[p] = now > EPS and now or nil
	if next(sums) == nil then net.short_p[key] = nil end
end

local function short_del(net, key, unit)
	local u = net and net.short and net.short[key]
	local e = u and u[unit]
	if not e then return end
	u[unit] = nil
	if next(u) == nil then net.short[key] = nil end
	short_sum(net, key, e[1], -e[2])
end

local function short_put(net, key, unit, p, n)
	net.short = net.short or {}
	local u = net.short[key]
	if not u then
		u = {}
		net.short[key] = u
	end
	local e = u[unit]
	if e then short_sum(net, key, e[1], -e[2]) end
	u[unit] = { p, n }
	short_sum(net, key, p, n)
end

--- what the interfaces of a priority above `p` lack of `key` in the network
local function reserved(net, key, p)
	local sums = net.short_p and net.short_p[key]
	if not sums then return 0 end
	local n = 0
	for q, v in pairs(sums) do
		if q > p then n = n + v end
	end
	return n
end

--- the interface's registered shortfalls become `short` ({ key -> amount }, nil: none) in network `net` (nil: drop all)
local function sync_short(rec, net, short)
	local unit = rec.entity.unit_number
	if rec.short and rec.short_net and not (net and rec.short_net == net.id) then
		local old = N.get(rec.short_net)
		for key in pairs(rec.short) do short_del(old, key, unit) end
		rec.short = nil
	end
	if not net then
		rec.short, rec.short_net = nil, nil
		return
	end
	for key in pairs(rec.short or {}) do
		if not (short and short[key]) then
			short_del(net, key, unit)
			rec.short[key] = nil
		end
	end
	local p = rec.priority or 0
	for key, n in pairs(short or {}) do
		local e = net.short and net.short[key] and net.short[key][unit]
		if not (e and e[1] == p and e[2] == n) then short_put(net, key, unit, p, n) end
		rec.short = rec.short or {}
		rec.short[key] = true
	end
	if rec.short and next(rec.short) == nil then rec.short = nil end
	rec.short_net = rec.short and net.id or nil
end

local function drop(s, unit)
	local rec = s.recs[unit]
	if rec and rec.short then sync_short(rec, nil) end
	if s.prio then s.prio[unit] = nil end
	s.recs[unit] = nil
	for i = #s.list, 1, -1 do
		if s.list[i] == unit then table.remove(s.list, i) end
	end
end

--- an item or fluid key from a filter: "fluid/<name>", or a plain name (an item if there is one, else a fluid)
local function filter_key(f)
	if type(f) ~= "string" then return nil end
	if N.is_fluid_key(f) then return prototypes.fluid[f:sub(#FLUID_PREFIX + 1)] and f or nil end
	if prototypes.item[f] then return f end
	if prototypes.fluid[f] then return FLUID_PREFIX .. f end
	return nil
end

--------------------------------------------------------------------------------
--- interface: config rows
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

local function is_fluid_row(c) return c ~= nil and c.type == "fluid" end

--- the key of a config row ("fluid/<name>" for a fluid)
local function row_key(c)
	if is_fluid_row(c) then return FLUID_PREFIX .. c.name end
	return N.key_of(c.name, c.quality)
end
M.row_key = row_key

--- A config checked against the prototypes: { [i] = { name, quality, amount } or { type = "fluid", name, amount } }
--- for i = 1 .. CONFIG_SLOTS (a list, or a list of { slot = i, ... } as in blueprint tags). Entries with amount 0
--- stay (shown, nothing kept), duplicates of an earlier slot are dropped. A fluid's amount is at most a side's volume.
local function clean_config(config)
	local out, seen = {}, {}
	if type(config) ~= "table" then return out end
	for k, c in pairs(config) do
		local i = type(c) == "table" and tonumber(c.slot) or tonumber(k)
		if type(c) == "table" and i and i >= 1 and i <= CONFIG_SLOTS and i == math.floor(i) then
			if c.type == "fluid" then
				if type(c.name) == "string" and prototypes.fluid[c.name] and not seen[FLUID_PREFIX .. c.name] then
					seen[FLUID_PREFIX .. c.name] = true
					out[i] = { type = "fluid", name = c.name,
						amount = math.max(0, math.min(volume(), math.floor(tonumber(c.amount) or 0))) }
				end
			elseif type(c.name) == "string" and prototypes.item[c.name] then
				local q = (type(c.quality) == "string" and prototypes.quality[c.quality]) and c.quality or "normal"
				local key = N.key_of(c.name, q)
				if not seen[key] then
					seen[key] = true
					local amount = math.max(0, math.min(MAX_AMOUNT, math.floor(tonumber(c.amount) or 0)))
					out[i] = { name = c.name, quality = q, amount = amount }
				end
			end
		end
	end
	return out
end

--- the sides checked against a config: { [1..4] = "off" | row index of a fluid row } (missing: import)
local function clean_sides(sides, config)
	local out = {}
	if type(sides) ~= "table" then return out end
	for k, v in pairs(sides) do
		local d = type(v) == "table" and tonumber(v.side) or tonumber(k)
		local value = v
		if type(v) == "table" then value = v.off and "off" or tonumber(v.row) end
		if d and SIDES[d] then
			if value == "off" then out[d] = "off"
			elseif type(value) == "number" and is_fluid_row(config[value]) then out[d] = value end
		end
	end
	return out
end

--- does any side keep a fluid? (cached in rec.exporting: idle interfaces skip their sides)
local function refresh_exporting(rec)
	local any = false
	for d = 1, #SIDES do
		if type((rec.sides or {})[d]) == "number" then any = true end
	end
	rec.exporting = any or nil
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

--------------------------------------------------------------------------------
--- interface: the side tanks
--------------------------------------------------------------------------------

--- rec.fconn: is anything connected to a side? (an idle interface without connections looks at its sides rarely)
local function refresh_connections(rec)
	local any = false
	for _, t in pairs(rec.tanks or {}) do
		if t.valid and #t.fluidbox.get_connections(1) > 0 then any = true break end
	end
	rec.fconn = any or nil
end

--- The four side tanks of an interface (found on its tile, created where missing). `fresh`: an interface of a save
--- made before its tanks existed: a side that a pipe, pump or tank already points at is set to "off", so a
--- pipeline that ran past the interface is not drained into the network. Returns the tanks (nil without the
--- prototype).
local function ensure_tanks(rec, fresh)
	local tanks = rec.tanks
	if tanks and tanks[1] and tanks[1].valid and tanks[2] and tanks[2].valid and tanks[3] and tanks[3].valid
		and tanks[4] and tanks[4].valid then return tanks end
	if not prototypes.entity[T.SIDE] then return nil end
	local e = rec.entity
	local found = {}
	for _, t in pairs(e.surface.find_entities_filtered{ name = T.SIDE, position = e.position }) do
		local d = SIDE_OF[t.direction]
		if d and not found[d] then found[d] = t else t.destroy() end
	end
	for d = 1, #SIDES do
		if not found[d] then
			local t = e.surface.create_entity{ name = T.SIDE, position = e.position, direction = SIDES[d], force = e.force,
				create_build_effect_smoke = false }
			if t then
				t.destructible = false
				found[d] = t
				if fresh and #t.fluidbox.get_connections(1) > 0 then
					rec.sides = rec.sides or {}
					rec.sides[d] = "off"
					log("FORK-ME-IO: ME Interface " .. e.unit_number .. " at " .. e.position.x .. "," .. e.position.y
						.. ": side " .. d .. " is connected to an existing pipe: off (switch it to import in its window)")
				end
			end
		end
	end
	rec.tanks = found
	refresh_connections(rec)
	return found
end
M.ensure_tanks = ensure_tanks

--- the four side tanks of an interface (north, east, south, west), created where missing
function M.tanks_of(entity)
	if kind(entity) ~= "interface" then return nil end
	return ensure_tanks(register(state(), entity))
end

local function destroy_tanks(rec)
	for _, t in pairs(rec.tanks or {}) do
		if t.valid then t.destroy() end
	end
	rec.tanks = nil
end

--- Move what a side tank holds into the network (the tank's whole fluid segment, as far as it fits); returns the
--- amount moved and a status.
local function tank_to_network(t, held, net)
	local fb = t.fluidbox
	local segment = fb.get_fluid_segment_contents(1)
	local available = math.max(held.amount, (segment and segment[held.name] or 0) + 1)   -- segment counts are rounded
	local room = N.can_insert_fluid(net, held.name, available)
	if room <= EPS then return 0, "full" end
	local removed = t.remove_fluid{ name = held.name, amount = room }
	if removed <= 0 then return 0, "ok" end
	local stored = N.insert_fluid(net, held.name, removed)
	if stored < removed - EPS then          -- cannot happen (room was checked), but never lose fluid
		t.insert_fluid{ name = held.name, amount = removed - stored, temperature = held.temperature }
	end
	return stored, "ok"
end
M.tank_to_network = tank_to_network

--- keep a side's tank at its row's amount of the row's fluid; returns the status, the amount moved and what the
--- side still lacks. `p`: the interface's priority when priorities are in use (issue #17: what interfaces of a higher
--- priority lack is left in the network)
local function export_side(t, held, row, net, p)
	local moved = 0
	if held and held.name ~= row.name then              -- another fluid: into the network first
		moved = tank_to_network(t, held, net)
		held = t.fluidbox[1]
		if held and held.amount <= EPS then held = nil end
		if held and held.name ~= row.name then return "blocked", moved, 0 end
	end
	local want = math.min(row.amount, volume()) - (held and held.amount or 0)
	if want <= EPS then return "ok", moved, 0 end
	local avail = N.fluid_count(net, row.name)
	if avail <= EPS then return "empty-network", moved, want end
	if p then avail = avail - reserved(net, FLUID_PREFIX .. row.name, p) end
	if avail <= EPS then return "reserved", moved, want end
	local inserted = t.insert_fluid{ name = row.name, amount = math.min(want, avail) }
	local got = 0
	if inserted > 0 then
		got = N.extract_fluid(net, row.name, inserted)
		--- a storage bus's segment had less than its snapshot: never duplicate
		if got < inserted - EPS then t.remove_fluid{ name = row.name, amount = inserted - got } end
		moved = moved + got
	end
	return "ok", moved, math.max(0, want - got)
end

--- one pass over the four sides; rec.fstatus[d] is what the window shows. Returns the fluid moved (an export side
--- whose fluid the network lacks waits for it: N.wait_for). `short`: the shortfalls of this visit (issue #17), nil
--- while priorities are not in use.
local function interface_sides(rec, net, config, short)
	local tanks = ensure_tanks(rec)
	if not tanks then return 0 end
	local moved = 0
	local sides = rec.sides or {}
	local fstatus = rec.fstatus or {}
	rec.fstatus = fstatus
	local exports                                         -- segment ids of the export sides (a loop check)
	for d = 1, #SIDES do
		local t = tanks[d]
		local setting = sides[d]
		local held = t.fluidbox[1]
		if held and held.amount <= EPS then held = nil end
		if setting == "off" then
			fstatus[d] = "off"
		elseif type(setting) == "number" and is_fluid_row(config[setting]) then
			local key = FLUID_PREFIX .. config[setting].name
			local why, n, lack = export_side(t, held, config[setting], net, short and (rec.priority or 0))
			fstatus[d] = why
			moved = moved + n
			if why == "empty-network" or why == "reserved" then N.wait_for(net, key, "io", rec.entity.unit_number, true) end
			if short and lack > EPS then short[key] = (short[key] or 0) + lack end
		elseif held then
			if rec.exporting and not exports then
				exports = {}
				for e = 1, #SIDES do
					if type(sides[e]) == "number" then
						local id = tanks[e].fluidbox.get_fluid_segment_id(1)
						if id then exports[id] = true end
					end
				end
			end
			local id = exports and t.fluidbox.get_fluid_segment_id(1)
			if id and exports[id] then
				fstatus[d] = "loop"
			else
				local n, why = tank_to_network(t, held, net)
				fstatus[d] = why
				moved = moved + n
			end
		else
			fstatus[d] = "import"
		end
	end
	return moved
end

--- One visit: every configured item is kept at its amount (filled from the network, the surplus taken back),
--- the other items are imported (at most IFACE_SLOTS_PER_VISIT operations per STEP_TICKS since the last visit,
--- `dt`); then the four sides. Returns the items and fluid moved and whether the operations ran out.
function M.interface_step(rec, dt)
	local e = rec.entity
	local config = config_of(rec)
	local net = N.active_of(e)
	if not net then
		local _, why = N.usable(N.network_of(e))
		rec.status = why or "no-network"
		return 0, false
	end
	local max_ops = math.max(IFACE_SLOTS_PER_VISIT, math.floor(IFACE_SLOTS_PER_VISIT * math.min(dt or STEP_TICKS, MAX_CATCH_UP) / STEP_TICKS))
	local inv = e.get_inventory(defines.inventory.chest)
	local ops, moved = 0, 0
	local kept = {}
	--- issue #17: priorities in use somewhere on the map (else nothing is reserved or registered: 0.3.0's visit)
	local s = storage.fork_me_io
	local short = ((s.prio and next(s.prio)) or rec.short) and {} or nil
	local p = rec.priority or 0
	for i = 1, CONFIG_SLOTS do
		local c = config[i]
		if c and not is_fluid_row(c) then
			local key = N.key_of(c.name, c.quality)
			kept[key] = true
			local have = inv.get_item_count{ name = c.name, quality = c.quality }
			if have < c.amount then
				local want = c.amount - have
				if short then want = math.min(want, math.max(0, N.count_key(net, key) - reserved(net, key, p))) end
				local got = want > 0 and N.extract_to(net, inv, key, want) or 0
				if got > 0 then moved = moved + got ops = ops + 1
				elseif N.count_key(net, key) <= 0 or short then N.wait_for(net, key, "io", e.unit_number, true) end
				if short and have + got < c.amount then short[key] = c.amount - have - got end
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
		if ops >= max_ops then rec.slot = (start - 1 + k) % size + 1 break end
		local i = (start - 1 + k) % size + 1
		local stack = inv[i]
		if stack.valid_for_read and not kept[N.key_of(stack.name, stack.quality.name)] then
			local n = N.insert_stack(net, stack)
			if n then moved = moved + n ops = ops + 1 end
		end
	end
	if ops < max_ops then rec.slot = 1 end
	moved = moved + interface_sides(rec, net, config, short)
	if short then sync_short(rec, net, next(short) and short or nil) end
	rec.status = "ok"
	return moved, ops >= max_ops
end

--- the interface's priority (issue #17; -1000 ... 1000, default 0)
function M.get_interface_priority(entity)
	if kind(entity) ~= "interface" then return nil end
	local s = storage.fork_me_io
	local rec = s and s.recs[entity.unit_number]
	return rec and rec.priority or 0
end

--- Set the priority; the shortfalls it registered go (they are registered again at its next visit, now)
function M.set_interface_priority(entity, priority)
	if kind(entity) ~= "interface" then return false end
	local s = state()
	local rec = register(s, entity)
	local p = math.max(-MAX_PRIORITY, math.min(MAX_PRIORITY, math.floor(tonumber(priority) or 0)))
	rec.priority = p ~= 0 and p or nil
	s.prio = s.prio or {}
	s.prio[entity.unit_number] = rec.priority
	if rec.short then sync_short(rec, nil) end
	wake(entity.unit_number)
	return true
end

--- the config: { [i] = { name, quality, amount } or { type = "fluid", name, amount } }, i = 1 .. CONFIG_SLOTS (a copy)
function M.get_interface_config(entity)
	if kind(entity) ~= "interface" then return nil end
	local out = {}
	for i, c in pairs(config_of(register(state(), entity))) do
		out[i] = { type = c.type, name = c.name, quality = c.quality, amount = c.amount }
	end
	return out
end

--- the sides: { [1..4] = "off" | row index } (a side without an entry imports); a copy
function M.get_interface_sides(entity)
	if kind(entity) ~= "interface" then return nil end
	local rec = register(state(), entity)
	local out = {}
	for d, v in pairs(rec.sides or {}) do out[d] = v end
	return out
end

--- Set the whole config (and with `sides` the sides; without, sides tied to a row that is no fluid row any more
--- import again).
function M.set_interface_config(entity, config, sides)
	if kind(entity) ~= "interface" then return false end
	local rec = register(state(), entity)
	config_of(rec)
	rec.config = clean_config(config)
	rec.sides = clean_sides(sides or rec.sides, rec.config)
	refresh_exporting(rec)
	wake(entity.unit_number)
	return true
end

--- One side: "import" (or nil), "off", or the index of a fluid row.
function M.set_interface_side(entity, side, value)
	if kind(entity) ~= "interface" or not SIDES[side] then return false end
	local rec = register(state(), entity)
	local config = config_of(rec)
	rec.sides = rec.sides or {}
	if value == "off" then rec.sides[side] = "off"
	elseif type(value) == "number" and is_fluid_row(config[value]) then rec.sides[side] = value
	else rec.sides[side] = nil end
	refresh_exporting(rec)
	wake(entity.unit_number)
	return true
end

--- a free side for a new fluid row: the first import side with something connected, else the first import side;
--- the second value tells whether something is connected to it
local function free_side(rec)
	local tanks = ensure_tanks(rec)
	local sides = rec.sides or {}
	local first
	for d = 1, #SIDES do
		if sides[d] == nil then
			first = first or d
			if tanks and #tanks[d].fluidbox.get_connections(1) > 0 then return d, true end
		end
	end
	return first, false
end

--- the side a new fluid row of the interface would get (see free_side; nil: no import side left), and whether a pipe
--- is connected to it
function M.free_side(entity)
	if kind(entity) ~= "interface" then return nil end
	return free_side(register(state(), entity))
end

--- One config row by key (item key "name" / "name@quality", or "fluid/<name>"); `key` nil clears it. Without `amount`
--- the row keeps its amount, a key moved from another row keeps that row's amount and sides (the other row is
--- cleared), a new item starts with one stack, a new fluid with a side's volume and the first free side.
function M.set_interface_key(entity, i, key, amount)
	if kind(entity) ~= "interface" or not (i >= 1 and i <= CONFIG_SLOTS) then return false end
	local rec = register(state(), entity)
	local config = M.get_interface_config(entity)
	local sides = M.get_interface_sides(entity)
	local row
	if key and N.is_fluid_key(key) and prototypes.fluid[key:sub(#FLUID_PREFIX + 1)] then
		row = { type = "fluid", name = key:sub(#FLUID_PREFIX + 1) }
	elseif key then
		local name, q = N.parse_key(key)
		if prototypes.item[name] then row = { name = name, quality = q } end
	end
	if row then
		local k = row_key(row)
		local old = config[i]
		for j, c in pairs(config) do                     -- the key moves from another row
			if j ~= i and row_key(c) == k then
				if amount == nil then amount = c.amount end
				for d, v in pairs(sides) do if v == j then sides[d] = i end end
				config[j] = nil
			end
		end
		if amount == nil then
			if old and row_key(old) == k then amount = old.amount
			elseif row.type == "fluid" then amount = volume()
			else amount = prototypes.item[row.name].stack_size end
		end
		row.amount = amount
		config[i] = row
	else
		config[i] = nil
	end
	local had_side = false
	for d, v in pairs(sides) do
		if v == i then
			if row and row.type == "fluid" then had_side = true else sides[d] = nil end
		end
	end
	M.set_interface_config(entity, config, sides)
	if row and row.type == "fluid" and not had_side then
		local d = free_side(rec)
		if d then M.set_interface_side(entity, d, i) end
	end
	return true
end

--- One item row (the remote call of R3): `name` nil clears it; see set_interface_key
function M.set_interface_slot(entity, i, name, quality, amount)
	if not name then return M.set_interface_key(entity, i, nil) end
	if not prototypes.item[name] then return false end
	return M.set_interface_key(entity, i, N.key_of(name, quality or "normal"), amount)
end

--- the config as a list for blueprint tags (sparse tables do not survive tags): { { slot, name, quality, amount, type } }
local function config_tag(config)
	local out = {}
	for i = 1, CONFIG_SLOTS do
		local c = config[i]
		if c then out[#out + 1] = { slot = i, type = c.type, name = c.name, quality = c.quality, amount = c.amount } end
	end
	return out
end

local function sides_tag(sides)
	local out = {}
	for d = 1, #SIDES do
		local v = sides and sides[d]
		if v == "off" then out[#out + 1] = { side = d, off = true }
		elseif type(v) == "number" then out[#out + 1] = { side = d, row = v } end
	end
	return out
end

--- the config and sides from a blueprint tag (issue #3 { config, sides }, R3 { config }, before R3 { filters })
local function config_from_tag(t)
	if type(t) ~= "table" then return nil end
	if type(t.config) == "table" then return t.config, t.sides end
	if type(t.filters) == "table" then return config_from_filters(t.filters) end
	return nil
end

--- the interface's tag (blueprints, scripts/fork-me-unify.lua): { config, sides, priority (issue #17, only when not 0) }
function M.interface_tag(config, sides, priority)
	return { config = config_tag(clean_config(config)), sides = sides_tag(sides),
		priority = priority and priority ~= 0 and priority or nil }
end

--- the interface's state for its window: { config, sides, status, contents = { { key, count } }, fluids = { [1..4] =
--- { setting, status, name, amount, connected } }, slots, volume }
function M.get_interface(entity)
	if kind(entity) ~= "interface" then return nil end
	local rec = register(state(), entity)
	local inv = entity.get_inventory(defines.inventory.chest)
	local contents = {}
	for _, item in pairs(inv.get_contents()) do
		contents[#contents + 1] = { key = N.key_of(item.name, item.quality), count = item.count }
	end
	table.sort(contents, function(a, b) return a.key < b.key end)
	local tanks = ensure_tanks(rec)
	local sides = M.get_interface_sides(entity)
	local fl = {}
	for d = 1, #SIDES do
		local t = tanks and tanks[d]
		local held = t and t.fluidbox[1]
		fl[d] = { setting = sides[d] or "import", status = rec.fstatus and rec.fstatus[d] or nil,
			name = held and held.amount > EPS and held.name or nil, amount = held and held.amount or 0,
			connected = t ~= nil and #t.fluidbox.get_connections(1) > 0 }
	end
	local short = {}
	for key in pairs(rec.short or {}) do
		local net = N.get(rec.short_net)
		local e = net and net.short and net.short[key] and net.short[key][entity.unit_number]
		if e then short[key] = e[2] end
	end
	return { config = M.get_interface_config(entity), sides = sides, status = rec.status, contents = contents,
		fluids = fl, slots = CONFIG_SLOTS, volume = volume(), priority = rec.priority or 0, short = short }
end
M.CONFIG_SLOTS = CONFIG_SLOTS
M.MAX_FILTERS = MAX_FILTERS
M.side_volume = function() return volume() end      -- the amount a new fluid row gets
M.SIDES = #SIDES

--------------------------------------------------------------------------------
--- buses
--------------------------------------------------------------------------------

local BUSES = { ["import-bus"] = true, ["export-bus"] = true, ["fluid-import-bus"] = true, ["fluid-export-bus"] = true }
local IMPORTS = { ["import-bus"] = true, ["fluid-import-bus"] = true }   -- (the old fluid kinds until they are replaced)

--- The entity in front of a bus that has an inventory of the bus's kind or fluid boxes; what it has is kept with it
--- (rec.t_inv: the inventory index, rec.t_fluid: fluid boxes), cached until it is gone or the bus is rotated.
local function target_of(rec)
	local t = rec.target
	local e = rec.entity
	if t and t.valid and rec.dir == e.direction then return t end
	rec.target, rec.dir, rec.t_inv, rec.t_fluid = nil, e.direction, nil, nil
	local table_ = IMPORTS[rec.kind] and T.OUTPUT or T.INPUT
	for _, o in pairs(e.surface.find_entities_filtered{ position = T.front(e) }) do
		if o.valid and not T.is_me(o) then
			local inv, fl = table_[o.type], T.has_fluid_boxes(o)
			if inv or fl then
				rec.target, rec.t_inv, rec.t_fluid = o, inv, fl or nil
				return o
			end
		end
	end
	return nil
end

local by_count_cache = {}
--- Items the import bus moves by count (issue #5): plain items that cannot be damaged, spoil or carry data, so
--- every stack of them is the same and the network takes them by name (one check per item type, not per stack).
--- Decided per prototype and quality, cached per load.
local function by_count(name, quality)
	local k = name .. "@" .. quality
	local v = by_count_cache[k]
	if v == nil then
		local p = prototypes.item[name]
		v = p ~= nil and p.type == "item" and not p.place_result and p.get_spoil_ticks(quality) <= 0
		by_count_cache[k] = v
	end
	return v
end

--- the item part of an import visit: up to `cap` from the output inventory. Plain items by count (one
--- get_contents, one remove per item type), the others stack by stack (their data, damage or spoilage decides).
local function import_items(rec, net, t, cap)
	local inv = t.get_inventory(rec.t_inv)
	if not inv then return 0 end
	local all, set = rec.all, rec.iset
	local moved, stacks = 0, false
	for _, c in pairs(inv.get_contents()) do
		if moved >= cap then break end
		local q = c.quality or "normal"
		if all or set[c.name] then
			if by_count(c.name, q) then
				local removed = inv.remove{ name = c.name, quality = q, count = math.min(c.count, cap - moved) }
				if removed > 0 then
					local stored = N.insert(net, c.name, q, removed)
					if stored < removed then                  -- the network is full: the rest goes back
						local back = inv.insert{ name = c.name, quality = q, count = removed - stored }
						if back < removed - stored then
							t.surface.spill_item_stack{ position = t.position, stack = { name = c.name, quality = q, count = removed - stored - back } }
						end
					end
					moved = moved + stored
				end
			else
				stacks = true
			end
		end
	end
	if stacks then
		for i = 1, #inv do
			if moved >= cap then break end
			local stack = inv[i]
			if stack.valid_for_read and (all or set[stack.name]) and not by_count(stack.name, stack.quality.name) then
				local n = N.insert_partial(net, stack, cap - moved)
				if n then moved = moved + n end
			end
		end
	end
	return moved
end

--- the item part of an export visit: the filtered items into the input inventory, up to `cap`; a filter the network
--- has none of waits for it (the bus wakes when it comes in)
local function export_items(rec, net, t, cap)
	local inv = t.get_inventory(rec.t_inv)
	if not inv then return 0 end
	local machine = t.type == "assembling-machine" or t.type == "furnace"
	local moved = 0
	for _, name in ipairs(rec.filters) do
		if moved >= cap then break end
		local proto = prototypes.item[name]
		if proto then
			local want = cap - moved
			if machine then want = math.min(want, proto.stack_size - inv.get_item_count(name)) end
			if want > 0 then
				local key = N.key_of(name, "normal")
				local got = N.extract_to(net, inv, key, want)
				moved = moved + got
				if got <= 0 and N.count_key(net, key) <= 0 then N.wait_for(net, key, "io", rec.entity.unit_number, true) end
			end
		end
	end
	return moved
end

--- The fluid part of a visit: the import bus empties the output boxes of a machine (any box of a tank) into the
--- network, the export bus fills its filtered fluids into the entity (insert_fluid: the machine's input boxes, a
--- tank), at the fluid's default temperature. Up to `cap` units (by default what one visit moved before issue #5).
--- Returns the units moved.
function M.fluid_bus_step(rec, net, t, cap)
	cap = cap or Sched.setting("bus_fluid") * STEP_TICKS / 60
	local fb = t.fluidbox
	local moved = 0
	if IMPORTS[rec.kind] then
		local all, set = rec.all, rec.fset
		for i = 1, #fb do
			if moved >= cap then break end
			local f = fb[i]
			if f and f.amount > EPS and (all or set[f.name]) then
				local p = fb.get_prototype(i)
				if p and p.production_type == nil and p[1] then p = p[1] end      -- merged prototypes: the first one
				if not (p and p.production_type == "input") then
					local take = N.can_insert_fluid(net, f.name, math.min(f.amount, cap - moved))
					if take > EPS then
						local left = f.amount - take
						fb[i] = left > EPS and { name = f.name, amount = left, temperature = f.temperature } or nil
						local stored = N.insert_fluid(net, f.name, take)
						if stored < take - EPS then                 -- cannot happen (room was checked), but never lose fluid
							t.insert_fluid{ name = f.name, amount = take - stored, temperature = f.temperature }
						end
						moved = moved + stored
					end
				end
			end
		end
	else
		for _, name in ipairs(rec.ffilters) do
			if moved >= cap then break end
			local avail = math.min(N.fluid_count(net, name), cap - moved)
			if avail <= EPS and N.fluid_count(net, name) <= EPS then
				N.wait_for(net, FLUID_PREFIX .. name, "io", rec.entity.unit_number, true)
			end
			if avail > EPS then
				local inserted = t.insert_fluid{ name = name, amount = avail }
				if inserted > 0 then
					local got = N.extract_fluid(net, name, inserted)
					--- a storage bus's segment had less than its snapshot: never duplicate
					if got < inserted - EPS then t.remove_fluid{ name = name, amount = inserted - got } end
					moved = moved + got
				end
			end
		end
	end
	return moved
end

--- One visit of a bus. `dt`: the ticks since its last visit (nil: one visit of before issue #5, STEP_TICKS): it moves
--- its speed times that, at most MAX_CATCH_UP ticks' worth. Returns what it moved and whether that was all it was
--- allowed to move.
function M.bus_step(rec, dt)
	local e = rec.entity
	local net = N.active_of(e)
	if not net then
		local _, why = N.usable(N.network_of(e))
		rec.status = why or "no-network"
		return 0, false
	end
	local t = target_of(rec)
	if not t then rec.status = "no-target" return 0, false end
	if not rec.iset then M.set_bus_filters(e, rec.filters) end          -- a record of a save before issue #3
	local ticks = math.min(dt or STEP_TICKS, MAX_CATCH_UP)
	local icap = math.max(1, math.floor(Sched.setting("bus_items") * ticks / 60))
	local fcap = Sched.setting("bus_fluid") * ticks / 60
	local import = IMPORTS[rec.kind]
	local items, fluid = 0, 0
	if rec.t_inv and (rec.all or #rec.filters > 0) then
		items = import and import_items(rec, net, t, icap) or export_items(rec, net, t, icap)
	end
	if rec.t_fluid and (rec.all or #rec.ffilters > 0) then
		fluid = M.fluid_bus_step(rec, net, t, fcap)
	end
	rec.status = "ok"
	return items + fluid, items >= icap or fluid >= fcap - EPS
end

--- Set the filters: a list of keys (item name, "fluid/<name>"; a plain name that is no item but a fluid is that
--- fluid), at most MAX_FILTERS. Split into rec.filters (item names) and rec.ffilters (fluid names) and their sets.
function M.set_bus_filters(entity, filters)
	local k = kind(entity)
	if not BUSES[k] then return false end
	local rec = register(state(), entity)
	local keys, items, fl, iset, fset, seen = {}, {}, {}, {}, {}, {}
	for _, f in pairs(filters or {}) do
		local key = filter_key(f)
		if key and not seen[key] and #keys < MAX_FILTERS then
			seen[key] = true
			keys[#keys + 1] = key
			if N.is_fluid_key(key) then
				local name = key:sub(#FLUID_PREFIX + 1)
				fl[#fl + 1] = name
				fset[name] = true
			else
				items[#items + 1] = key
				iset[key] = true
			end
		end
	end
	rec.keys, rec.filters, rec.ffilters, rec.iset, rec.fset = keys, items, fl, iset, fset
	rec.all = IMPORTS[k] and #keys == 0 or nil
	wake(entity.unit_number)
	return true
end

--- { filters = keys, status, target }
function M.get_bus(entity)
	local s = storage.fork_me_io
	local rec = s and entity and entity.valid and s.recs[entity.unit_number]
	if not rec then return nil end
	local t = rec.target
	return { filters = { table.unpack(rec.keys or rec.filters) }, status = rec.status, target = t and t.valid and t.name or nil }
end

--- one filter of a bus (the window's filter buttons): `key` nil clears it; the list stays packed
function M.set_bus_filter(entity, index, key)
	local s = state()
	if not BUSES[kind(entity)] then return false end
	local rec = register(s, entity)
	local current = rec.keys or rec.filters
	local list = {}
	for i = 1, MAX_FILTERS do
		local v
		if i == index then v = key else v = current[i] end
		if v then list[#list + 1] = v end
	end
	return M.set_bus_filters(entity, list)
end

--- the bus's state for its window: { kind, filters, status, target, import, max, items, fluids }
function M.bus_info(entity)
	local k = kind(entity)
	if not BUSES[k] then return nil end
	local rec = register(state(), entity)
	local b = M.get_bus(entity)
	b.kind, b.import, b.max = k, IMPORTS[k] == true, MAX_FILTERS
	b.items, b.fluids = rec.t_inv ~= nil, rec.t_fluid == true
	return b
end

--------------------------------------------------------------------------------
--- step, events
--------------------------------------------------------------------------------

local function rec_of(unit)
	local s = storage.fork_me_io
	return s.recs[unit]
end

--- one scheduled visit: the block moves what its speed and the ticks since its last visit allow, and is due again
--- after an interval that follows what it did (Sched.interval)
local function visit(rec, unit)
	local s = storage.fork_me_io
	local e = rec.entity
	if not e.valid then
		destroy_tanks(rec)                    -- an interface removed without an event
		drop(s, unit)                         -- (its shortfalls go too)
		return
	end
	local now = game.tick
	local dt = now - (rec.last or (now - MIN_INTERVAL))
	rec.last = now
	local moved, full
	if rec.kind == "interface" then moved, full = M.interface_step(rec, dt) else moved, full = M.bus_step(rec, dt) end
	--- (0.2.0 visited 24 blocks per 15 ticks: an idle block never waits longer than that cycle)
	local idle = Sched.idle_limit(Sched.setting("idle"), #s.list, 24 / 15, MIN_INTERVAL)
	rec.iv = Sched.interval(rec.iv, moved, full, MIN_INTERVAL, ACTIVE_INTERVAL, idle)
	Sched.at(s.q, rec, unit, now + rec.iv)
	if moved <= 0 then return 0 end
	return full and 2 or 1
end

--- every tick (control.lua): the interfaces and buses that are due, at most the setting's visits per tick
function M.on_tick(tick)
	local s = storage.fork_me_io
	if not s then return end
	Sched.run(queue(s), tick, Sched.setting("io"), rec_of, visit, "io")
end

--- `tags`: blueprint tags of a built ghost; `source`: the original of a clone
function M.on_built(entity, tags, source)
	if entity and entity.valid and entity.name == T.SIDE then          -- a cloned side tank: the interface's clone
		local s = storage.fork_me_io                                    -- takes it, unless it has one there already
		local d = SIDE_OF[entity.direction]
		for _, c in pairs(entity.surface.find_entities_filtered{ position = entity.position, type = "container" }) do
			local rec = s and s.recs[c.unit_number]
			local have = rec and rec.tanks and rec.tanks[d]
			if have and have.valid and have ~= entity then entity.destroy() return end
		end
		return
	end
	local k = kind(entity)
	if k ~= "interface" and not BUSES[k] then
		if entity and entity.valid and (T.has_fluid_boxes(entity) or T.OUTPUT[entity.type] or T.INPUT[entity.type]) then
			M.wake_near(entity)
		end
		return
	end
	local rec = register(state(), entity)
	if k == "interface" then
		ensure_tanks(rec)
		local t = type(tags) == "table" and tags[IFACE_TAG] or nil
		local config, sides = config_from_tag(t)
		if config then
			M.set_interface_config(entity, config, sides or {})
			if type(t) == "table" and t.priority then M.set_interface_priority(entity, t.priority) end
		elseif source and source.valid and kind(source) == "interface" then
			M.set_interface_config(entity, M.get_interface_config(source), M.get_interface_sides(source))
			M.set_interface_priority(entity, M.get_interface_priority(source))
		end
		clear_filters(entity.get_inventory(defines.inventory.chest))      -- a blueprint before R3 may carry slot filters
	else
		local t = type(tags) == "table" and tags[BUS_TAG] or nil
		if type(t) == "table" then M.set_bus_filters(entity, t.filters)
		elseif source and source.valid and kind(source) == k then
			local from = M.get_bus(source)
			M.set_bus_filters(entity, from and from.filters or {})
		else
			M.set_bus_filters(entity, {})
		end
	end
end

local block_names
--- An entity was built next to blocks: the interfaces next to a fluid entity look at their sides again, the buses
--- facing it take it as their target; both are visited at the next tick.
function M.wake_near(entity)
	local s = storage.fork_me_io
	if not s then return end
	if not block_names then
		block_names = {}
		for _, name in pairs(N.node_names()) do
			local k = N.kind_of(name)
			if k == "interface" or BUSES[k] then block_names[#block_names + 1] = name end
		end
	end
	local b = entity.bounding_box
	for _, i in pairs(entity.surface.find_entities_filtered{ name = block_names,
		area = { { b.left_top.x - 1, b.left_top.y - 1 }, { b.right_bottom.x + 1, b.right_bottom.y + 1 } } }) do
		local rec = s.recs[i.unit_number]
		if rec then
			if rec.kind == "interface" then
				if rec.tanks then refresh_connections(rec) wake(i.unit_number) end
			else
				local f = T.front(i)
				if f[1] > b.left_top.x and f[1] < b.right_bottom.x and f[2] > b.left_top.y and f[2] < b.right_bottom.y then
					rec.target = nil
					wake(i.unit_number)
				end
			end
		end
	end
end

--- `mined`: by a player, a robot or a platform (an interface's fluid goes into the network first)
function M.on_removed(entity, mined)
	local s = storage.fork_me_io
	local rec = s and entity and entity.valid and entity.unit_number and s.recs[entity.unit_number]
	if not rec then return end
	if rec.kind == "interface" then
		local net = mined and N.active_of(entity)
		for _, t in pairs(net and rec.tanks or {}) do
			local held = t.valid and t.fluidbox[1]
			if held and held.amount > EPS then tank_to_network(t, held, net) end
		end
		destroy_tanks(rec)
	end
	drop(s, entity.unit_number)
end

function M.on_rotated(entity)
	local s = storage.fork_me_io
	local rec = s and entity and entity.valid and s.recs[entity.unit_number]
	if rec then
		rec.target = nil
		wake(entity.unit_number)
	end
end

function M.on_entity_settings_pasted(event)
	local src, dst = event.source, event.destination
	if not (src and src.valid and dst and dst.valid and src.name == dst.name) then return end
	local k = kind(src)
	if k == "interface" then
		M.set_interface_config(dst, M.get_interface_config(src), M.get_interface_sides(src))
		M.set_interface_priority(dst, M.get_interface_priority(src))
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
			local config, sides = M.get_interface_config(entity), M.get_interface_sides(entity)
			local p = M.get_interface_priority(entity)
			if next(config) or next(sides) or p ~= 0 then
				bp.set_blueprint_entity_tag(index, IFACE_TAG, M.interface_tag(config, sides, p))
			end
		elseif BUSES[k] then
			local b = M.get_bus(entity)
			if b and #b.filters > 0 then bp.set_blueprint_entity_tag(index, BUS_TAG, { filters = b.filters }) end
		end
	end
end

--- rebuild the records from the world; filters of buses, the config and sides of interfaces are kept by unit
--- number; interfaces get their side tanks (an interface of a save from before issue #3: `fresh`)
function M.on_configuration_changed()
	local s = state()
	local old = s.recs
	s.recs, s.list, s.cursor, s.q, s.prio = {}, {}, 1, Sched.new(), {}
	--- issue #17: the shortfalls are registered again at the visits (the networks may be new ones)
	for _, net in pairs(N.state().nets) do net.short, net.short_p = nil, nil end
	VOLUME, block_names, by_count_cache = nil, nil, {}
	local names = {}
	for _, name in pairs(N.node_names()) do
		local k = N.kind_of(name)
		if k == "interface" or BUSES[k] then names[#names + 1] = name end
	end
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = names }) do
			local rec = register(s, e)
			local o = old[e.unit_number]
			if BUSES[rec.kind] then M.set_bus_filters(e, o and (o.keys or o.filters) or {}) end
			if rec.kind == "interface" then
				if o and o.config then rec.config = clean_config(o.config) end
				if o and o.priority then
					rec.priority = o.priority
					s.prio[e.unit_number] = o.priority
				end
				rec.sides = clean_sides(o and o.sides or {}, rec.config or {})
				rec.tanks = o and o.tanks
				local fresh = not (o and o.tanks) and #surface.find_entities_filtered{ name = T.SIDE, position = e.position } == 0
				ensure_tanks(rec, fresh)
				refresh_connections(rec)
				refresh_exporting(rec)
			end
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
		local moved
		if k == "interface" then moved = M.interface_step(rec) else moved = M.bus_step(rec) end
		return moved
	end,
	--- issue #5: when a block is visited next: { due, interval, last } (the tick of its last visit)
	schedule = function(entity)
		local s = storage.fork_me_io
		local rec = s and entity and entity.valid and s.recs[entity.unit_number]
		if not rec then return nil end
		return { due = rec.due, interval = rec.iv, last = rec.last }
	end,
	--- issue #38: the scheduler's counters of every queue (fork-me-schedule.lua, M.snapshot); `reset` starts them anew
	sched_stats = function(reset)
		local snap = Sched.snapshot()
		if reset then Sched.reset_stats() end
		return snap
	end,
	--- the units waiting in the backlogs now, by queue (the benchmark samples it over time)
	backlogs = function()
		local io_s, sb, fsb, ae = storage.fork_me_io, storage.fork_me_sbus, storage.fork_me_fsbus, storage.fork_ae2
		return { io = io_s and io_s.q and Sched.backlog(io_s.q) or 0, storage_bus = sb and sb.q and Sched.backlog(sb.q) or 0,
			fluid_storage_bus = fsb and fsb.q and Sched.backlog(fsb.q) or 0,
			maintainer = ae and ae.mq and Sched.backlog(ae.mq) or 0, circuit = ae and ae.cq and Sched.backlog(ae.cq) or 0 }
	end,
	--- the Lua heap of this mod in kilobytes (the benchmark's long run watches it grow)
	lua_memory = function() return collectgarbage("count") end,
	set_interface_config = function(entity, config, sides) return M.set_interface_config(entity, config, sides) end,
	get_interface_config = function(entity) return M.get_interface_config(entity) end,
	set_interface_slot = function(entity, i, name, quality, amount) return M.set_interface_slot(entity, i, name, quality, amount) end,
	set_interface_key = function(entity, i, key, amount) return M.set_interface_key(entity, i, key, amount) end,
	set_interface_side = function(entity, side, value) return M.set_interface_side(entity, side, value) end,
	get_interface_sides = function(entity) return M.get_interface_sides(entity) end,
	get_interface = function(entity) return M.get_interface(entity) end,
	--- issue #17: the interface's priority
	get_interface_priority = function(entity) return M.get_interface_priority(entity) end,
	set_interface_priority = function(entity, priority) return M.set_interface_priority(entity, priority) end,
	--- the four side tanks (north, east, south, west)
	interface_tanks = function(entity) return M.tanks_of(entity) end,
	set_bus_filters = function(entity, filters) return M.set_bus_filters(entity, filters) end,
	set_bus_filter = function(entity, index, key) return M.set_bus_filter(entity, index, key) end,
	get_bus = function(entity) return M.get_bus(entity) end,
	bus_info = function(entity) return M.bus_info(entity) end,
	paste = function(source, destination) M.on_entity_settings_pasted{ source = source, destination = destination } end,
	tag_blueprint = function(bp, mapping) M.tag_blueprint(bp, mapping) end,
	--- what a build event does (`tags`: blueprint tags, `source`: the original of a clone)
	built = function(entity, tags, source) M.on_built(entity, tags, source) end,
	--- what the removal events do (`mined`: the interface's fluid goes into the network first)
	removed = function(entity, mined) M.on_removed(entity, mined) end,
})

return M
