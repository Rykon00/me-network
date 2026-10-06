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
--- Visits (issue #5, issue #38; scripts/fork-me-schedule.lua): every interface and bus is due at a tick (s.q,
--- rec.due); the on_tick handler of control.lua visits what is due, at most the setting "at most" per tick. When a
--- block is due comes from the buffer on its other side (the headroom rule): a visit knows what the target holds
--- of the bus's items after it inserted and what the target used since the last visit, or what the source
--- gathered and how much room it has left, so it knows when that buffer would run empty or full and comes back
--- at about half of that time (the whole time while the block moves all its speed allows: the catch-up covers
--- the wait), between MIN_INTERVAL and MAX_CATCH_UP; a block whose other side had run out (a machine without
--- input, an output full) is served before the backlog next time. A block blocked on its target's side (source
--- empty, target full, no target, an interface with nothing to do) is not visited but probed: one cheap engine
--- call at the idle limit (a setting), and visited at once when the probe sees a change. A block blocked on the
--- network's side (its key absent, the network full, no network, no power, no filters) is parked: visited again
--- only when the network wakes it (N.wait_for, N.wait_room, N.wait_usable, a change of the graph, its settings).
--- A bus moves its speed (a setting, items and fluid per second) times the ticks since its last visit (at most
--- MAX_CATCH_UP ticks' worth), so a bus that is visited less often moves more per visit; an interface handles
--- IFACE_SLOTS_PER_VISIT item slots per 15 ticks since its last visit, and its four sides.
--- State: storage.fork_me_io (records by unit number, the queue). GUI state lives in the GUI elements.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local T = require("scripts.fork-me-targets")
local Sched = require("scripts.fork-me-schedule")
local CS = require("scripts.fork-me-cardslots")

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
		s = { recs = {}, list = {}, lpos = {}, cursor = 1, q = Sched.new("io") }
		storage.fork_me_io = s
	end
	if not s.lpos then s.lpos = {} end                 -- (positions of s.list, for O(1) removals; built at the first removal)
	return s
end

--- the queue of the visits; a save from before issue #5 gets one with every block due within a second, a queue
--- of 0.3.0 its probe list and counts (issue #38)
local function queue(s)
	local q = s.q
	if q and q.sl then return q end
	if not q then
		q = Sched.new("io")
		s.q = q
		for i, unit in ipairs(s.list) do
			local rec = s.recs[unit]
			if rec then
				rec.due, rec.inq, rec.sq = nil, nil, nil
				Sched.at(q, rec, unit, game.tick + 1 + (i - 1) % 60)
			end
		end
		return q
	end
	local recs = {}
	for _, unit in ipairs(s.list) do
		local rec = s.recs[unit]
		if rec then recs[#recs + 1] = rec end
	end
	return Sched.upgrade(q, recs, "io")
end

--- the idle limit of the interfaces and buses (0.2.0 visited 24 blocks per 15 ticks: an idle block never waits
--- longer than that cycle took)
local function idle_limit(s)
	return Sched.idle_limit(Sched.setting("idle"), #s.list, 24 / 15, MIN_INTERVAL)
end

--- visit the block before everything else (its settings, its target or the network changed)
local function wake(unit)
	local s = storage.fork_me_io
	local rec = s and s.recs[unit]
	if not rec then return end
	rec.sidle = nil
	if rec.park then
		rec.last, rec.left = nil, nil                         -- (parked: how long it could have moved is unknown)
	elseif rec.sq then
		rec.last, rec.left = math.max(rec.last or 0, game.tick - idle_limit(s)), nil   -- (as a sleeper of 0.3.0)
	end
	rec.iv, rec.block, rec.seen = nil, nil, nil
	Sched.wake(queue(s), rec, unit)
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

--- the stack size of an item (the headroom of a slot), cached per load
local stack_cache = {}
local function stack_of(name)
	local v = stack_cache[name]
	if not v then
		local proto = prototypes.item[name]
		v = proto and proto.stack_size or 50
		stack_cache[name] = v
	end
	return v
end

--- Scratch tables (issue #38, lever 4): the API copies the arguments of a call, so one table serves every call of its
--- kind; the visits make no garbage for them. Never kept across a call that could use them again.
local KEPT = {}                                      -- interface_step: the keys of the rows
local INFO = {}                                      -- bus_step: what the parts of a visit report
local Q_COUNT = { name = "", quality = "normal" }    -- inv.get_item_count
local Q_REMOVE = { name = "", quality = "normal", count = 0 }   -- inv.remove

--- does the item exist? (cached per load: prototypes.item is an engine call)
local item_cache = {}
local function item_known(name)
	local v = item_cache[name]
	if v == nil then
		v = prototypes.item[name] ~= nil
		item_cache[name] = v
	end
	return v
end

local function register(s, entity)
	local unit = entity.unit_number
	local rec = s.recs[unit]
	if not rec then
		rec = { entity = entity, kind = kind(entity), filters = {}, status = "ok" }
		s.recs[unit] = rec
		s.list[#s.list + 1] = unit
		if s.lpos then s.lpos[unit] = #s.list end
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
	if rec then Sched.forget(queue(s), rec) end
	if s.prio then s.prio[unit] = nil end
	s.recs[unit] = nil
	Sched.list_remove(s.list, s.lpos, unit)
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
	rec.sidle = nil
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
	rec.sidle = nil
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
	local fb = T.fluidbox(t)
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
		held = T.fluidbox(t)[1]
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
local function interface_sides(rec, net, config, short, dt)
	if rec.sidle then return 0, math.huge end           -- nothing connected, nothing exported, nothing in the tanks (see the end)
	local tanks = ensure_tanks(rec)
	if not tanks then return 0, math.huge end
	local anyheld, sstarved = false, false
	local moved, time = 0, math.huge
	dt = dt or STEP_TICKS
	local sides = rec.sides or {}
	local fstatus = rec.fstatus or {}
	rec.fstatus = fstatus
	local exports                                         -- segment ids of the export sides (a loop check)
	for d = 1, #SIDES do
		local t = tanks[d]
		local setting = sides[d]
		local held = T.fluidbox(t)[1]
		if held and held.amount <= EPS then held = nil end
		if held then anyheld = true end
		if setting == "off" then
			fstatus[d] = "off"
		elseif type(setting) == "number" and is_fluid_row(config[setting]) then
			local key = FLUID_PREFIX .. config[setting].name
			if not held then sstarved = true end                      -- the side's tank had run out
			local why, n, lack = export_side(t, held, config[setting], net, short and (rec.priority or 0))
			fstatus[d] = why
			moved = moved + n
			if why == "empty-network" or why == "reserved" then N.wait_for(net, key, "io", rec.entity.unit_number, true) end
			if short and lack > EPS then short[key] = (short[key] or 0) + lack end
			if n + lack > EPS then                                   -- the side is drained at (n + lack) per dt
				local tt = math.min(config[setting].amount, volume()) * dt / (n + lack)
				if tt < time then time = tt end
			end
		elseif held then
			if rec.exporting and not exports then
				exports = {}
				for e = 1, #SIDES do
					if type(sides[e]) == "number" then
						local id = T.fluidbox(tanks[e]).get_fluid_segment_id(1)
						if id then exports[id] = true end
					end
				end
			end
			local id = exports and T.fluidbox(t).get_fluid_segment_id(1)
			if id and exports[id] then
				fstatus[d] = "loop"
			else
				if held.amount >= volume() - EPS then sstarved = true end   -- the side's tank was full
				local n, why = tank_to_network(t, held, net)
				fstatus[d] = why
				moved = moved + n
				if n > EPS then                                      -- the side fills at n per dt
					local tt = volume() * dt / n
					if tt < time then time = tt end
				elseif why == "full" then                            -- the network takes none: woken when room appears
					N.wait_for(net, FLUID_PREFIX .. held.name, "io", rec.entity.unit_number, false)
					N.wait_room(net, "io", rec.entity.unit_number)
				end
			end
		else
			fstatus[d] = "import"
		end
	end
	--- no pipe or pump at a side (rec.fconn, kept by M.wake_near and ensure_tanks), no row that exports, nothing in the
	--- tanks: the next passes would find the same; a wake, a connection or a changed row looks again (rec.sidle = nil)
	if not (anyheld or rec.fconn or rec.exporting) then rec.sidle = true end
	return moved, time, sstarved
end

--- One visit: every configured item is kept at its amount (filled from the network, the surplus taken back),
--- the other items are imported (at most IFACE_SLOTS_PER_VISIT operations per STEP_TICKS since the last visit,
--- `dt`); then the four sides. Returns the items and fluid moved, whether the operations ran out, the ticks until
--- the next visit (the headroom rule over the rows, the imports and the sides), why it is blocked when nothing
--- moved ("idle": probed; an interface is never parked for a missing key, an inserter may feed it any time),
--- whether a row had run empty, its network, and the ticks until its buffer runs out at the rate this visit saw.
function M.interface_step(rec, dt)
	local e = rec.entity
	local config = config_of(rec)
	local net = N.active_of(e)
	if not net then
		local n0 = N.network_of(e)
		local _, why = N.usable(n0)
		rec.status = why or "no-network"
		return 0, false, nil, (n0 and why == "no-power") and "no-power" or "no-network", false, n0
	end
	local ticks = math.min(dt or STEP_TICKS, MAX_CATCH_UP)
	local max_ops = math.max(IFACE_SLOTS_PER_VISIT, math.floor(IFACE_SLOTS_PER_VISIT * ticks / STEP_TICKS))
	local inv = T.inventory(e, defines.inventory.chest)
	local ops, moved = 0, 0
	local held_total = 0                                      -- what the kept rows hold at the end of the row loop
	local kept = KEPT
	if next(kept) then
		for k in pairs(kept) do kept[k] = nil end
	end
	--- issue #17: priorities in use somewhere on the map (else nothing is reserved or registered: 0.3.0's visit)
	local s = storage.fork_me_io
	local short = ((s.prio and next(s.prio)) or rec.short) and {} or nil
	local p = rec.priority or 0
	local unit = e.unit_number
	local time, starved = math.huge, false
	local rows = rec.rows                                     -- what each row held after its last visit
	if not rows then
		rows = {}
		rec.rows = rows
	end
	for i = 1, CONFIG_SLOTS do
		local c = config[i]
		if c and c.type ~= "fluid" then
			local key = c.key
			if not key then
				key = N.key_of(c.name, c.quality)
				c.key = key
			end
			local counted = kept[key]                             -- (two rows of one key hold its items once)
			kept[key] = true
			Q_COUNT.name, Q_COUNT.quality = c.name, c.quality
			local have = inv.get_item_count(Q_COUNT)
			local final = have
			if have < c.amount then
				local want = c.amount - have
				if short then want = math.min(want, math.max(0, N.count_key(net, key) - reserved(net, key, p))) end
				local got = want > 0 and N.extract_to(net, inv, key, want) or 0
				if have == 0 and got > 0 then starved = true end        -- (a row that had run empty)
				if got > 0 then moved = moved + got ops = ops + 1
				elseif N.count_key(net, key) <= 0 or short then N.wait_for(net, key, "io", unit, true) end
				if short and have + got < c.amount then short[key] = c.amount - have - got end
				local after = have + got                              -- the row is taken at (amount - have) per dt
				final = after
				if rows[i] == nil then
					if got > 0 then time = MIN_INTERVAL end           -- (the first fill: the rate is unknown, look again soon)
				elseif after > 0 then
					local tt = after * ticks / (c.amount - have)
					if tt < time then time = tt end
				end
				rows[i] = after
			elseif have > c.amount then
				local can = N.can_insert(net, c.name, c.quality, have - c.amount)
				local taken = 0
				if can > 0 then
					local proto = prototypes.item[c.name]
					if proto and (N.item_class(proto.type) == "worn" or N.can_be_damaged(proto)) then
						--- (a removal by count takes the used item first, issue #76; a damaged stack is no surplus either, issue #84)
						taken = N.remove_whole(inv, c.name, c.quality, can)
					else
						Q_REMOVE.name, Q_REMOVE.quality, Q_REMOVE.count = c.name, c.quality, can
						taken = inv.remove(Q_REMOVE)
					end
				end
				if taken > 0 then
					local stored = N.insert(net, c.name, c.quality, taken)
					if stored < taken then inv.insert{ name = c.name, quality = c.quality, count = taken - stored } end
					final = have - stored
					moved = moved + stored
					ops = ops + 1
					local tt = stack_of(c.name) * ticks / (have - c.amount)   -- the surplus comes in at that rate
					if tt < time then time = tt end
				elseif can <= 0 then
					N.wait_for(net, key, "io", unit, false)               -- (room appears when some is taken)
				end
			end
			if not counted then held_total = held_total + final end
		end
	end
	local size = #inv
	local imported, free, isize = 0, 0, nil
	--- the walk over the slots only when something lies in the inventory that no row keeps (an interface whose rows
	--- hold what they hold, or that holds nothing, has nothing to import)
	local walk = false
	if not inv.is_empty() then
		walk = inv.get_item_count() ~= held_total          -- (more in it than the kept rows hold: something to import; no table)
	end
	local start = rec.slot or 1
	--- issue #115: the stacks the walk has still to find (an inventory with a few stacks and many empty slots: the empty rest
	--- counts as free without reading each slot; the operations limit is checked first, as at every slot)
	local stacks = walk and size - inv.count_empty_stacks(true, true) or 0
	for k = 0, walk and size - 1 or -1 do
		if ops >= max_ops then rec.slot = (start - 1 + k) % size + 1 break end
		if stacks <= 0 then free = free + size - k break end
		local i = (start - 1 + k) % size + 1
		local stack = inv[i]
		if stack.valid_for_read then
			stacks = stacks - 1
			local key = N.key_of(stack.name, stack.quality.name)
			if not kept[key] then
				local sname = stack.name
				local n = N.insert_stack(net, stack)
				if n then moved = moved + n ops = ops + 1 imported = imported + n isize = stack_of(sname)
				else                                                 -- the network takes none: woken when room appears
					N.wait_for(net, key, "io", unit, false)
					N.wait_room(net, "io", unit)
				end
			end
		else
			free = free + 1
		end
	end
	if ops < max_ops then rec.slot = 1 end
	if imported > 0 then                                             -- the free slots fill at that rate
		local tt = math.max(free, 1) * (isize or 50) * ticks / imported      -- (the stack size of what came in)
		if tt < time then time = tt end
	end
	local fmoved, ftime, sstarved = interface_sides(rec, net, config, short, ticks)
	moved = moved + fmoved
	if ftime < time then time = ftime end
	if short then sync_short(rec, net, next(short) and short or nil) end
	rec.status = "ok"
	local full = ops >= max_ops
	if moved <= 0 then return 0, false, nil, "idle", false, net end
	return moved, full, Sched.headroom(time, full, MIN_INTERVAL, MAX_CATCH_UP, rec.sh), nil, starved or sstarved, net, time
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

--- Issue #110: the card slots of an import and an export bus (scripts/fork-me-cardslots.lua; the cards of a block are the
--- items of a script inventory its window shows). Only the Acceleration Card fits: AE2's speed card, 4 of them, which
--- multiply the items a bus moves per second (the map setting "bus speed") by 1, 8, 32, 64 and 96 (0 to 4 cards:
--- `N.card_rules().speed`; AE2: PartImportBus and PartExportBus, 1, 8, 32, 64, 96 items per operation). Fluids are not
--- sped up (AE2's cards act on items). `rec.accel` is that factor (nil: 1), made from the cards when they change.
local function bus_rec(entity)
	local s = storage.fork_me_io
	return s and entity and entity.valid and entity.unit_number and BUSES[kind(entity)] and s.recs[entity.unit_number] or nil
end
local cards
cards = CS.new{
	rules = function() return N.card_rules().bus end,
	title = function(rec) return rec.entity and rec.entity.valid and rec.entity.localised_name or { "entity-name.me-import-bus" } end,
	rec_of = bus_rec,
	on_cards = function(rec, light)
		local n = cards.counts(rec).speed or 0
		rec.accel = n > 0 and N.card_rules().speed[n + 1] or nil
		if not light and rec.entity and rec.entity.valid then wake(rec.entity.unit_number) end
	end,
}

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
--- Tools (science packs), ammo and repair tools are not among them (issue #76): a stack of them is a whole item or a used
--- one, and a removal by count takes the used item first and hands it on as a whole one, so they go stack by stack
--- through N.insert_partial, which refuses a used stack.
--- Decided per prototype and quality, cached per load (by quality, then name: no string is built per call).
local function by_count(name, quality)
	local byq = by_count_cache[quality]
	if not byq then
		byq = {}
		by_count_cache[quality] = byq
	end
	local v = byq[name]
	if v == nil then
		local p = prototypes.item[name]
		v = p ~= nil and p.type == "item" and not p.place_result and p.get_spoil_ticks(quality) <= 0
		byq[name] = v
	end
	return v
end

--- the item part of an import visit: up to `cap` from the output inventory. Plain items by count (one
--- get_contents, one remove per item type), the others stack by stack (their data, damage or spoilage decides).
--- `info` (issue #38): what the source held of the bus's items (`held`), its slots and its biggest item (the room),
--- and whether the network took nothing (`netfull`). A stack the network refuses itself (N.refuses_stack) is neither: it
--- stays where it is and is left out of `held` (issue #85).
local function import_items(rec, net, t, cap, info)
	local inv = T.inventory(t, rec.t_inv)
	if not inv then return 0 end
	local all, set = rec.all, rec.iset
	local unit = rec.entity.unit_number
	local moved, stacks, held, main, mainc = 0, false, 0, nil, 0
	for _, c in pairs(inv.get_contents()) do
		if all or set[c.name] then
			held = held + c.count
			if c.count > mainc then main, mainc = c.name, c.count end
			if moved < cap then
				local q = c.quality or "normal"
				if by_count(c.name, q) then
					Q_REMOVE.name, Q_REMOVE.quality, Q_REMOVE.count = c.name, q, math.min(c.count, cap - moved)
					local removed = inv.remove(Q_REMOVE)
					if removed > 0 then
						local stored = N.insert(net, c.name, q, removed)
						if stored < removed then                  -- the network is full: the rest goes back
							local back = inv.insert{ name = c.name, quality = q, count = removed - stored }
							if back < removed - stored then
								t.surface.spill_item_stack{ position = t.position, stack = { name = c.name, quality = q, count = removed - stored - back } }
							end
							info.netfull = true
							N.wait_for(net, N.key_of(c.name, q), "io", unit, false)   -- (room appears when some is taken)
						end
						moved = moved + stored
					end
				else
					stacks = true
				end
			end
		end
	end
	if stacks then
		for i = 1, #inv do
			if moved >= cap then break end
			local stack = inv[i]
			if stack.valid_for_read and (all or set[stack.name]) and not by_count(stack.name, stack.quality.name) then
				local n, why = N.insert_partial(net, stack, cap - moved)
				if n then moved = moved + n
				elseif N.refuses_stack(why) then
					--- issue #85: the network refuses this stack itself (a used pack, a damaged item, a blueprint): room does
					--- not change that, so it is no "network full" and waits for nothing; it stays in the source, which the
					--- bus does not count as something left to take
					held = held - stack.count
				else
					info.netfull = true
					N.wait_for(net, N.key_of(stack.name, stack.quality.name), "io", unit, false)
				end
			end
		end
	end
	info.held, info.main, info.slots = held, main, #inv
	return moved
end

--- the item part of an export visit: the filtered items into the input inventory, up to `cap`; a filter the network
--- has none of waits for it (the bus wakes when it comes in). `info` (issue #38): the time (ticks) until the target
--- runs out of one of the items at the rate it used them since the last visit (`rec.tgt` keeps what the target held
--- after each visit), whether it had run out on arrival (`starved`), whether it takes nothing (`blocked`) or the
--- network lacks a key (`nokey`).
local function export_items(rec, net, t, cap, info)
	local inv = T.inventory(t, rec.t_inv)
	if not inv then return 0 end
	local machine = T.SLOTTED[t.type]
	local moved = 0
	local tgt = rec.tgt
	if not tgt then
		tgt = {}
		rec.tgt = tgt
	end
	local dt = info.dt or STEP_TICKS
	for _, name in ipairs(rec.filters) do
		if item_known(name) then
			local have = inv.get_item_count(name)
			local prev = tgt[name]
			if prev and prev > 0 and have == 0 then info.starved = true end
			local used = prev and prev - have or 0
			local want = cap - moved
			if machine then want = math.min(want, stack_of(name) - have) end
			local got = 0
			if want > 0 then
				local key = name                                  -- (the key of a plain item of normal quality)
				got = N.extract_to(net, inv, key, want)
				if got <= 0 then
					if N.count_key(net, key) <= 0 then
						N.wait_for(net, key, "io", rec.entity.unit_number, true)
						info.nokey = true
					else
						info.blocked = true                      -- the target takes nothing: full
					end
				end
				moved = moved + got
			end
			local after = have + got
			tgt[name] = after
			if used > 0 and after > 0 then
				local tt = after * dt / used
				if tt < info.time then info.time = tt end
			elseif not prev and got > 0 then
				info.time = MIN_INTERVAL                         -- (the rate is unknown yet: look again soon)
			end
		end
	end
	return moved
end

--- The fluid part of a visit: the import bus empties the output boxes of a machine (any box of a tank) into the
--- network, the export bus fills its filtered fluids into the entity (insert_fluid: the machine's input boxes, a
--- tank), at the fluid's default temperature. Up to `cap` units (by default what one visit moved before issue #5).
--- Returns the units moved. `info` (issue #38, see export_items): the import side learns the rate a box fills and
--- its capacity (`rec.fleft`: what was left in each box), the export side the capacity of what it fills
--- (`rec.fcap`, the most it ever inserted) and the rate that drains it.
function M.fluid_bus_step(rec, net, t, cap, info)
	cap = cap or Sched.setting("bus_fluid") * STEP_TICKS / 60
	info = info or { time = math.huge }
	local dt = info.dt or STEP_TICKS
	local fb = T.fluidbox(t)
	local moved = 0
	local unit = rec.entity.unit_number
	if IMPORTS[rec.kind] then
		local all, set = rec.all, rec.fset
		local fleft = rec.fleft or {}
		for i = 1, #fb do
			local f = fb[i]
			if f and f.amount > EPS and (all or set[f.name]) then
				local p = fb.get_prototype(i)
				if p and p.production_type == nil and p[1] then p = p[1] end      -- merged prototypes: the first one
				if not (p and p.production_type == "input") then
					local capf = fb.get_capacity(i)
					local arrived = f.amount - (fleft[i] or 0)
					if f.amount >= capf - EPS then info.starved = true end           -- a full box: the machine waited
					local left = f.amount
					if cap - moved > EPS then
						local take = N.can_insert_fluid(net, f.name, math.min(f.amount, cap - moved))
						if take > EPS then
							left = f.amount - take
							fb[i] = left > EPS and { name = f.name, amount = left, temperature = f.temperature } or nil
							local stored = N.insert_fluid(net, f.name, take)
							if stored < take - EPS then                 -- cannot happen (room was checked), but never lose fluid
								t.insert_fluid{ name = f.name, amount = take - stored, temperature = f.temperature }
							end
							moved = moved + stored
						else
							info.netfull = true
							N.wait_for(net, FLUID_PREFIX .. f.name, "io", unit, false)
						end
					end
					fleft[i] = left
					if left > EPS then                                   -- a rest: back when the bus's speed covers it
						local tt = math.max(MIN_INTERVAL, left * 60 / Sched.setting("bus_fluid"))
						if tt < info.time then info.time = tt end
					end
					if arrived > EPS then
						local tt = (capf - left) * dt / arrived
						if tt < info.time then info.time = tt end
					end
				end
			else
				fleft[i] = nil
			end
		end
		rec.fleft = fleft
	else
		for _, name in ipairs(rec.ffilters) do
			local total = N.fluid_count(net, name)
			if total <= EPS then
				N.wait_for(net, FLUID_PREFIX .. name, "io", unit, true)
				info.nokey = true
			elseif cap - moved > EPS then
				local want = math.min(total, cap - moved)
				local inserted = t.insert_fluid{ name = name, amount = want }
				if inserted > 0 then
					local got = N.extract_fluid(net, name, inserted)
					--- a storage bus's segment had less than its snapshot: never duplicate
					if got < inserted - EPS then t.remove_fluid{ name = name, amount = inserted - got } end
					moved = moved + got
					--- it had run dry when the target's room ended the insert and it took about the most it ever took that way
					--- (`rec.froom`); an insert the bus's speed ended says nothing of the target (issue #51: it counted as a dry
					--- target at every visit of a bus into a big tank)
					if inserted < want - EPS then
						local froom = rec.froom
						if froom and got >= froom * 0.95 then info.starved = true end
						if not froom or got > froom then rec.froom = got end
					end
					local fcap = rec.fcap or 0
					if got > fcap then fcap = got end
					local tt = rec.fcap and fcap * dt / got or MIN_INTERVAL      -- (no capacity known yet: look again soon)
					rec.fcap = fcap
					if tt < info.time then info.time = tt end
				else
					info.blocked = true                                  -- the target takes nothing: full
				end
			end
		end
	end
	return moved
end

--- One visit of a bus. `dt`: the ticks since its last visit (nil: one visit of before issue #5, STEP_TICKS): it moves
--- its speed times that, at most MAX_CATCH_UP ticks' worth. Returns what it moved, whether that was all it was
--- allowed to move, the ticks until its next visit (the headroom rule), why it is blocked when it moved nothing
--- (nil otherwise), whether its other side had run out, its network, and the ticks until the buffer on its other side
--- runs out at the rate this visit saw (math.huge: unknown).
function M.bus_step(rec, dt)
	local e = rec.entity
	local net = N.active_of(e)
	if not net then
		local n0 = N.network_of(e)
		local _, why = N.usable(n0)
		rec.status = why or "no-network"
		return 0, false, nil, (n0 and why == "no-power") and "no-power" or "no-network", false, n0
	end
	local t = target_of(rec)
	if not t then
		rec.status = "no-target"
		return 0, false, nil, "no-target", false, net
	end
	if not rec.iset then M.set_bus_filters(e, rec.filters) end          -- a record of a save before issue #3
	local ticks = math.min(dt or STEP_TICKS, MAX_CATCH_UP)
	if rec.want then cards.fill_cards(rec) end                         -- issue #110: the cards a blueprint or a paste asked for
	local icap = math.max(1, math.floor(Sched.setting("bus_items") * (rec.accel or 1) * ticks / 60))
	local fcap = Sched.setting("bus_fluid") * ticks / 60
	local import = IMPORTS[rec.kind]
	local items, fluid = 0, 0
	local info = INFO
	info.time, info.dt = math.huge, ticks
	info.held, info.main, info.slots, info.netfull, info.nokey, info.blocked, info.starved = nil, nil, nil, nil, nil, nil, nil
	local has_items = rec.t_inv and (rec.all or #rec.filters > 0)
	local has_fluid = rec.t_fluid and (rec.all or #rec.ffilters > 0)
	if has_items then
		items = import and import_items(rec, net, t, icap, info) or export_items(rec, net, t, icap, info)
	end
	if has_fluid then fluid = M.fluid_bus_step(rec, net, t, fcap, info) end
	rec.status = "ok"
	local moved = items + fluid
	local full = items >= icap or fluid >= fcap - EPS
	if moved <= 0 then
		if not (has_items or has_fluid) then return 0, false, nil, "unset", false, net end
		if info.netfull then return 0, false, nil, "net-full", false, net end
		if import then
			rec.left = 0                                      -- (seen empty: what the next visit finds arrived since)
			return 0, false, nil, "empty", false, net
		end
		if info.blocked or not info.nokey then return 0, false, nil, "full", false, net end
		return 0, false, nil, "no-key", false, net
	end
	if import and has_items then
		--- the source gathered `held` since it was emptied (minus what was left): it fills its room in about that;
		--- after a wake the rest is unknown (what is there was there before): look again soon and learn the rate
		local held = info.held or 0
		local known = rec.left ~= nil
		local arrived = held - (rec.left or 0)
		local left = held - items
		rec.left = left > 0 and left or 0
		if left > 0 then                                         -- a rest: back when the bus's speed covers it
			local tt = math.max(MIN_INTERVAL, left * 60 / (Sched.setting("bus_items") * (rec.accel or 1)))
			if tt < info.time then info.time = tt end
		end
		if not known then
			info.time = MIN_INTERVAL
		elseif arrived > 0 and info.slots and info.main then
			local size = info.slots * stack_of(info.main)
			local room = size - left
			if held * 10 >= size * 9 then info.starved = true end      -- (nearly full on arrival: the machine had stopped)
			local tt = room * ticks / arrived
			if tt < info.time then info.time = tt end
		end
	end
	return moved, full, Sched.headroom(info.time, full, MIN_INTERVAL, MAX_CATCH_UP, rec.sh), nil, info.starved or false, net, info.time
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

--- issue #110: the card slots of a bus for its window (the inventory whose slots it shows, the clicks on them)
function M.bus_inventory(entity)
	local rec = bus_rec(entity)
	return rec and cards.inv_of(rec) or nil
end
function M.bus_card_click(entity, slot, cursor, inventory, shift) return cards.card_click(entity, slot, cursor, inventory, shift) end
function M.bus_shift_in(entity, stack) return cards.shift_in(entity, stack) end
function M.bus_sync(entity, back)
	local rec = bus_rec(entity)
	return rec ~= nil and cards.sync(rec, back)
end

--- the bus's state for its window: { kind, filters, status, target, import, max, items, fluids; issue #110: slots, cards, accel, want }
function M.bus_info(entity)
	local k = kind(entity)
	if not BUSES[k] then return nil end
	local rec = register(state(), entity)
	local b = M.get_bus(entity)
	b.kind, b.import, b.max = k, IMPORTS[k] == true, MAX_FILTERS
	b.items, b.fluids = rec.t_inv ~= nil, rec.t_fluid == true
	--- issue #110: the card slots (the window shows them), the factor of the cards, the cards it waits for
	b.slots, b.accel = N.card_rules().bus.slots, rec.accel or 1
	b.rate = Sched.setting("bus_items") * b.accel          -- items per second at most
	b.cards = {}
	for slot, name in pairs(rec.cards or {}) do b.cards[slot] = name end
	b.want = rec.want and cards.missing_cards(rec, rec.want) or nil
	return b
end

--------------------------------------------------------------------------------
--- step, events
--------------------------------------------------------------------------------

local function rec_of(unit)
	local s = storage.fork_me_io
	return s.recs[unit]
end

--- blocked on the network's side: parked, woken by the network (the step registered N.wait_for; the rest here)
local NET_SIDE = { ["no-key"] = true, ["net-full"] = true, ["no-network"] = true, ["no-power"] = true, unset = true }

--- what the probe of a blocked block compares against: the items the source or the interface holds (one engine
--- call), plus the fluid of an interface's connected sides or of the source's boxes
local function probe_mark(rec)
	local e = rec.entity
	if rec.kind == "interface" then
		local n = T.inventory(e, defines.inventory.chest).get_item_count()
		local tanks = not rec.sidle and rec.tanks
		if tanks then
			local sides = rec.sides or {}
			for d = 1, #SIDES do
				local t = tanks[d]
				if sides[d] ~= "off" and t and t.valid then
					local f = T.fluidbox(t)[1]
					if f then n = n + math.floor(f.amount) end
				end
			end
		end
		return n
	end
	local t = rec.target
	if not (t and t.valid) then return 0 end
	local n = 0
	if rec.t_inv then
		local inv = T.inventory(t, rec.t_inv)
		if inv then n = inv.get_item_count() end
	end
	if rec.t_fluid then
		local fb = T.fluidbox(t)
		for i = 1, #fb do
			local f = fb[i]
			if f then n = n + math.floor(f.amount) end
		end
	end
	return n
end

--- the cheap check of a probed block: did its other side change? (true: visit it now)
local function probe_work(rec)
	local b = rec.block
	if b == "no-target" then return target_of(rec) ~= nil end
	if rec.kind == "interface" or b == "empty" then return probe_mark(rec) ~= rec.seen end
	--- "full": does the export target take something again?
	local t = rec.target
	if not (t and t.valid) then return true end
	if rec.t_inv then
		local inv = T.inventory(t, rec.t_inv)
		if inv then
			local machine = T.SLOTTED[t.type]
			local lab = t.type == "lab"
			for _, name in ipairs(rec.filters) do
				if prototypes.item[name] then
					if machine then
						--- (a lab takes only the packs it uses: a filter it refuses is no work, however empty its slot)
						if inv.get_item_count(name) < stack_of(name) and (not lab or inv.can_insert{ name = name }) then return true end
					elseif inv.can_insert{ name = name } then
						return true
					end
				end
			end
		end
	end
	if rec.t_fluid and #rec.ffilters > 0 then
		local fb = T.fluidbox(t)
		for i = 1, #fb do
			local f = fb[i]
			if not f or f.amount < fb.get_capacity(i) - EPS then return true end
		end
	end
	return false
end

--- Blocks that got the same interval from the same tick would come due in the same tick for ever, and the ceiling
--- would serve them in bursts (the backlog reached 481 at 5000 and the 99th percentile 5 ms): a block comes back
--- at the least loaded of four ticks around its interval (Sched.slot): up to 20 % sooner, and up to 20 % later
--- when the interval is half of the headroom time (a margin of 40 % is left), never later for a block that moved
--- all its speed allowed (its interval is the whole headroom time), sits at the catch-up limit or is probed.
--- Never below MIN_INTERVAL, never above MAX_CATCH_UP.
local function when(q, probe, unit, now, iv, late_ok)
	if iv <= MIN_INTERVAL then return now + iv end
	local early = math.min(math.floor(iv * 0.2), iv - MIN_INTERVAL)
	local late = late_ok and math.min(math.floor(iv * 0.2), MAX_CATCH_UP - iv) or 0
	return Sched.slot(q, probe, unit, now, iv, early, late)
end

--- the idle limit of this tick (computed once per tick for the probes and visits of M.on_tick)
local tick_limit = MAX_CATCH_UP

--- one scheduled visit: the block moves what its speed and the ticks since its last visit allow, and is due again
--- when the buffer on its other side needs it (the headroom rule); a block with nothing to do is probed or parked
local function visit(rec, unit, fallback)
	local s = storage.fork_me_io
	local e = rec.entity
	if not e.valid then
		destroy_tanks(rec)                    -- an interface removed without an event
		if BUSES[rec.kind] then cards.detach(rec) end        -- issue #110: a bus's cards are spilled where it stood
		drop(s, unit)                         -- (its shortfalls go too)
		return
	end
	local now = game.tick
	local dt = now - (rec.last or (now - MIN_INTERVAL))
	rec.last = now
	local moved, full, nextiv, block, starved, net, time
	if rec.kind == "interface" then
		moved, full, nextiv, block, starved, net, time = M.interface_step(rec, dt)
	else
		moved, full, nextiv, block, starved, net, time = M.bus_step(rec, dt)
	end
	rec.starve = starved or nil
	--- issue #51: how long the other side had been out, from the tick the visit before expected it to run out (`rec.outt`)
	if starved then Sched.starved("io", rec.outt and now - rec.outt or nil) end
	rec.outt = (not block and time and time < math.huge) and math.floor(now + time) or nil
	if not block then Sched.learn(rec, starved) end
	if fallback and moved > 0 then Sched.missed("io") end            -- (a parked block that finds work: its wake was missed)
	if block then
		local was = rec.block
		rec.block = block
		if NET_SIDE[block] then
			--- parked for its own network: no power or no network wake with the network (N.wait_usable: a change of the
			--- graph or the slow step's look at the power), a full network wakes when room appears
			if (block == "no-power" or block == "no-network") and net then N.wait_usable(net, "io", unit) end
			if block == "net-full" and net then N.wait_room(net, "io", unit) end
			Sched.park(s.q, rec, unit, block)
			return 0
		end
		local iv = (not was or not rec.iv or rec.iv < MIN_INTERVAL) and MIN_INTERVAL or rec.iv   -- (just blocked: from the shortest)
		iv = iv * 2
		if iv > tick_limit then iv = tick_limit end
		rec.iv = iv
		rec.seen = probe_mark(rec)
		Sched.at(s.q, rec, unit, when(s.q, true, unit, now, iv, false), true)
		return 0
	end
	rec.block, rec.seen = nil, nil
	if starved then nextiv = math.max(MIN_INTERVAL, math.floor(nextiv / 2)) end   -- (its other side had run out: sooner)
	--- issue #51: while the busy blocks are few against the floor, the floor's room is spent on margin, not saved
	local cap = Sched.margin_cap(s.q, Sched.setting("io"), MIN_INTERVAL)
	local capped = nextiv > cap
	if capped then nextiv = cap end
	rec.iv = nextiv
	Sched.at(s.q, rec, unit, when(s.q, false, unit, now, nextiv, not full and not starved and not capped and nextiv < MAX_CATCH_UP))
	return full and 2 or 1
end

--- one probe of a blocked block: one cheap check; a change wakes the block, else the next probe comes later
local function probe(rec, unit)
	local s = storage.fork_me_io
	local e = rec.entity
	if not e.valid then
		destroy_tanks(rec)
		drop(s, unit)
		return
	end
	if rec.park then                                          -- the slow fallback of a parked block: a full visit
		rec.last, rec.left = nil, nil
		return visit(rec, unit, true)
	end
	if probe_work(rec) then
		rec.sidle = nil
		rec.last, rec.left = math.max(rec.last or 0, game.tick - idle_limit(s)), nil   -- (as a sleeper of 0.3.0)
		Sched.wake(s.q, rec, unit)
		return 1
	end
	local iv = rec.iv
	iv = (iv and iv >= MIN_INTERVAL) and iv * 2 or MIN_INTERVAL * 2
	if iv > tick_limit then iv = tick_limit end
	rec.iv = iv
	local now = game.tick
	Sched.at(s.q, rec, unit, when(s.q, true, unit, now, iv, false), true)
	return 0
end

--- every tick (control.lua): the probes that are due, then the interfaces and buses that are due, between the
--- settings "at least" and "at most"
function M.on_tick(tick)
	local s = storage.fork_me_io
	if not s then return end
	tick_limit = idle_limit(s)
	if s.nonet then                                      -- (a save of the version that kept a list of blocks without a network)
		local units = {}
		for unit in pairs(s.nonet) do units[#units + 1] = unit end
		table.sort(units)
		s.nonet = nil
		for _, unit in ipairs(units) do wake(unit) end
	end
	Sched.run(queue(s), tick, Sched.setting("io"), Sched.setting("io_max"), rec_of, visit, probe, "io")
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
		if type(t) == "table" then
			M.set_bus_filters(entity, t.filters)
			if type(t.cards) == "table" and #t.cards > 0 then cards.want_cards(entity, t.cards, nil) end
		elseif source and source.valid and kind(source) == k then
			local from = M.get_bus(source)
			M.set_bus_filters(entity, from and from.filters or {})
			local from_rec = bus_rec(source)
			local list = from_rec and cards.card_list(from_rec)
			if list then cards.want_cards(entity, list, nil) end
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

--- `mined`: by a player, a robot or a platform (an interface's fluid goes into the network first; a LuaInventory: the mined
--- buffer, which takes a bus's cards)
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
	elseif BUSES[rec.kind] then
		--- issue #110: the cards of a mined bus go into the buffer, those of a destroyed one onto the ground
		if type(mined) == "userdata" or type(mined) == "table" then cards.give_cards(rec, mined) else cards.spill_cards(rec) end
		cards.detach(rec)
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
		--- issue #110: the source's cards are what the destination is to have (from the player's inventory, then the network)
		local from_rec, dst_rec = bus_rec(src), bus_rec(dst)
		if from_rec and dst_rec then
			local player = event.player_index and game.get_player(event.player_index) or nil
			cards.want_cards(dst, from_rec.want and { table.unpack(from_rec.want) } or cards.card_list(from_rec) or {}, player)
		end
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
			local rec = bus_rec(entity)
			local list = rec and (rec.want and { table.unpack(rec.want) } or cards.card_list(rec))
			if b and (#b.filters > 0 or list) then bp.set_blueprint_entity_tag(index, BUS_TAG, { filters = b.filters, cards = list }) end
		end
	end
end

--- rebuild the records from the world; filters of buses, the config and sides of interfaces are kept by unit
--- number; interfaces get their side tanks (an interface of a save from before issue #3: `fresh`)
function M.on_configuration_changed()
	local s = state()
	local old = s.recs
	s.recs, s.list, s.lpos, s.cursor, s.q, s.prio = {}, {}, {}, 1, Sched.new("io"), {}
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
			if BUSES[rec.kind] then
				M.set_bus_filters(e, o and (o.keys or o.filters) or {})
				if o then rec.inv, rec.cards, rec.want, rec.where, rec.accel = o.inv, o.cards, o.want, o.where, o.accel end   -- issue #110
			end
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
	--- issue #5: when a block is visited next: { due, interval, last } (the tick of its last visit); issue #38:
	--- `probing` (in the probe list, `block` says why), `parked` (why; no visit until a wake), `front` (woken, visited
	--- before the backlog), `backlog` (due, waiting)
	schedule = function(entity)
		local s = storage.fork_me_io
		local rec = s and entity and entity.valid and s.recs[entity.unit_number]
		if not rec then return nil end
		local due = rec.due
		return { due = (due and due > 0) and due or nil, interval = rec.iv, last = rec.last, probing = rec.sq == true and not rec.park,
			front = due == Sched.FRONT, backlog = due == Sched.BACKLOG, parked = rec.park, block = rec.block,
			starve = rec.starve or false }
	end,
	--- issue #51: the longest a busy interface or bus waits now (the margin of a short busy list), in ticks
	margin_cap = function()
		local s = storage.fork_me_io
		return s and Sched.margin_cap(queue(s), Sched.setting("io"), MIN_INTERVAL) or nil
	end,
	--- tests (issue #38): how often a parked block gets its slow fallback visit (ticks)
	set_park_fallback = function(ticks) Sched.PARK_FALLBACK = ticks end,
	--- issue #38: the scheduler's counters of every queue (fork-me-schedule.lua, M.snapshot); `reset` starts them anew
	sched_stats = function(reset)
		local snap = Sched.snapshot()
		if reset then Sched.reset_stats() end
		return snap
	end,
	--- the units waiting in the backlogs now, by queue, and (issue #38) the units in each queue's busy and sleep
	--- list and the units the module has at all (the benchmark samples it over time; the tests check the counts)
	backlogs = function()
		local io_s, sb, fsb, ae = storage.fork_me_io, storage.fork_me_sbus, storage.fork_me_fsbus, storage.fork_ae2
		local out = {}
		local function put(name, q, units)
			local back, pback = 0, 0
			local busy, probing = 0, 0
			if q then
				back, pback = Sched.backlog(q)
				busy, probing = Sched.counts(q)
			end
			out[name], out[name .. "_probe_backlog"] = back, pback
			out[name .. "_busy"], out[name .. "_probing"], out[name .. "_units"] = busy, probing, units or 0
		end
		put("io", io_s and io_s.q, io_s and #io_s.list)
		--- the parked blocks and why, the probed blocks and why (a walk over the records: tests and the benchmark)
		local kinds, parked = {}, 0
		for _, rec in pairs(io_s and io_s.recs or {}) do
			if rec.park then
				parked = parked + 1
				kinds["parked:" .. rec.park] = (kinds["parked:" .. rec.park] or 0) + 1
			elseif rec.sq then
				kinds["probe:" .. (rec.block or "?")] = (kinds["probe:" .. (rec.block or "?")] or 0) + 1
			end
		end
		out.io_parked, out.io_kinds = parked, kinds
		out.io_probing = out.io_probing - parked                        -- (the parked are in the probe list for their fallback)
		put("storage_bus", sb and sb.q, sb and #sb.list)
		put("fluid_storage_bus", fsb and fsb.q, fsb and #fsb.list)
		put("maintainer", ae and ae.mq, ae and ae.mlist and #ae.mlist)
		local mparked = 0
		for _, rec in pairs(ae and ae.maintainers or {}) do if rec.park then mparked = mparked + 1 end end
		out.maintainer_parked = mparked
		out.maintainer_probing = out.maintainer_probing - mparked
		put("circuit", ae and ae.cq, ae and ae.clist and #ae.clist)
		return out
	end,
	--- the Lua heap of this mod in kilobytes (the benchmark's long run watches it grow)
	--- tests and the benchmark: the mod's Lua heap in kB; `collect`: after a full collection (what is alive, not what is
	--- waiting to be collected)
	lua_memory = function(collect)
		if collect == "stop" or collect == "restart" then              -- (the benchmark's allocation rate: the collector stopped for a while)
			pcall(collectgarbage, collect)
		elseif collect then
			pcall(collectgarbage, "collect")
			pcall(collectgarbage, "collect")
		end
		return collectgarbage("count")
	end,
	--- issue #115: the benchmark's allocation meter (Sched.metered): on (true) or off (false: returns the KB allocated)
	alloc_meter = function(on)
		if on then Sched.meter_on() return 0 end
		return Sched.meter_off()
	end,
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
	--- issue #110: the card slots of a bus (what the window's clicks do; `want`: a list of names)
	bus_inventory = function(entity) local rec = bus_rec(entity) return rec and cards.inv_of(rec) or nil end,
	bus_card_click = function(entity, slot, cursor, inventory, shift) return cards.card_click(entity, slot, cursor, inventory, shift) end,
	bus_shift_in = function(entity, stack) return cards.shift_in(entity, stack) end,
	bus_want_cards = function(entity, want, player_index)
		return cards.want_cards(entity, want, player_index and game.get_player(player_index) or nil)
	end,
	--- tests (issue #110): what a mod update does to the records (their cards stay)
	configuration_changed = function() M.on_configuration_changed() end,
	bus_sync = function(entity, back) local rec = bus_rec(entity) return rec ~= nil and cards.sync(rec, back) end,
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
