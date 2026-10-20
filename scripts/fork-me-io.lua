--------------------------------------------------------------------------------
--- FORK AE2: IMPORT AND EXPORT (issue #68, step R1; issue #3 of me-network: items and fluids in one block;
--- prototypes/network.lua, prototypes/fluids.lua, docs/ME-REWORK.md)
---   * ME Interface: a container with up to CONFIG_SLOTS config rows (R3, AE2's config slots), each an item
---     (name, quality, amount) or a fluid (type "fluid", name, amount, an optional temperature: issue #159), mixed. The network keeps the amount of
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
---     one wakes it. Issue #420 (lever 10): a side has its tank only where it is needed (an unconnected tank cost the
---     engine some 13 ns per tick): something is connected to it, it is tied to a fluid row, or its tank holds fluid. A
---     tank is made when an entity with fluid boxes is built, rotated or set up (settings paste, its window closed) beside
---     a side and kept when it connects; one interface every TANK_CHECK_TICKS looks at its sides again (a pipe that a
---     script built without an event, a machine whose recipe gave it a fluid box): a tank no longer needed goes, a
---     side with a fluid entity beside it gets one. Older saves lose their empty unconnected tanks on the update.
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
---     puts its filtered items into the entity's input (machine: up to one stack each, a crafting machine up to two
---     crafts of its recipe when that is more, issue #382; chest: as far as it has room) and its filtered fluids into
---     the input boxes or the tank. Up to MAX_FILTERS filters (issue #413: 9 more per Capacity Card), items and
---     fluids mixed (keys: item name, "fluid/<name>", "fluid/<name>@<degrees>"), split into an item and a fluid set when they are set
---     (import: none = everything, items and fluids; export: none = nothing). Kept in blueprints (tag
---     fork_me_bus), settings paste and clones. The windows are in scripts/fork-me-windows.lua.
--- Temperature (issue #159): what is imported keeps its temperature (a key per temperature, scripts/fork-me-network.lua).
--- A fluid filter or row without a temperature exports every temperature of the fluid: the default temperature first,
--- then from the coldest to the hottest; with one only that temperature. An export never mixes: into a box or tank that
--- holds the fluid already only the same temperature goes (TEMP_TOLERANCE), into a machine's box only what fits the
--- temperature range of its recipe (LuaFluidBox.get_filter); one temperature per side or box and visit. When the network
--- has the fluid only at temperatures that cannot go, the status is "temperature".
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
local AC = require("scripts.fork-me-autocraft")
local Conn = require("scripts.fork-me-connector")
--- issue #412: the connector module puts a block's off state into its record (the visit reads `rec.coff` only)
N.off_setters.io = function(unit, off)
	local s = storage.fork_me_io
	local rec = s and s.recs[unit]
	if rec then rec.coff = off or nil end
end

local M = {}

local STEP_TICKS = 15                -- the ticks a visit of the remote `step` stands for (what one visit was before)
local MIN_INTERVAL = 15              -- ticks between two visits of a block that moved all it was allowed to
local ACTIVE_INTERVAL = 60           -- ... of a block that moves something but less
local MAX_CATCH_UP = 600             -- ticks of speed a visit may catch up at most
local MAX_ICAP = 2 ^ 31 - 1          -- items a bus visit may move at most (issue #356: an engine count is 32 bit)
local IFACE_SLOTS_PER_VISIT = 8      -- item slots an interface handles per STEP_TICKS since its last visit
--- Issue #411: the Crafting Card. An export bus whose filtered item the network lacks, or an ME Interface whose item row it
--- cannot fill, starts a crafting job for what is missing (the bus: what the visit would move, at most a stack; the row: its
--- amount less what it holds), through the level maintainer's path (AC.start with the block as the owner, a request of
--- automation for the CPU modes). One job per block and key at a time (`rec.cjobs[key]`, AE2-U's MultiCraftingTracker keeps a
--- link per slot), none while another job crafts the key, none without a free CPU. A start that fails waits CRAFT_RETRY ticks
--- (CRAFT_RETRY_NONE when no pattern makes the key) before that key is tried again (`rec.cretry[key]`; the block is probed
--- until the earliest of them, `rec.cnext`); a job's end wakes the block (the waker "io"), the product's arrival wakes it as
--- any key does. CRAFT_STARTS: the starts of buses and interfaces per tick (a plan has its cost), the others wait a tick.
local CRAFT_RETRY, CRAFT_RETRY_NONE, CRAFT_STARTS = 300, 1200, 1
local craft_tick, craft_starts = -1, 0
local MAX_FILTERS = 9                -- the filters of a bus without a Capacity Card
local KEPT_FILTERS = 27              -- the filters a bus keeps: with two Capacity Cards (issue #413: 9 more each)
--- the filters that apply (issue #413): 9 and 9 more per Capacity Card (`rec.nf`, made from its cards; nil: 9). Filters beyond
--- them are kept in `rec.keys` and apply again when a card gives them room.
local function filters_of(rec) return rec.nf or MAX_FILTERS end

--- issue #411: a crafting job of `amount` of `key` for the block `rec` (its Crafting Card), when none runs for it. Returns
--- "crafting" (its job runs), "wait" (a start that failed waits for its retry; `rec.cnext`) or nil (nothing started this tick,
--- tried again at the next visit). `rec.cstat`: what the window says (the job, or why none started).
local function craft(rec, net, key, amount)
	local jobs = rec.cjobs
	local id = jobs and jobs[key]
	if id then
		if AC.job_running(id) then rec.cstat = "crafting" return "crafting" end
		jobs[key] = nil
	end
	local now = game.tick
	local retry = rec.cretry and rec.cretry[key]
	if retry then
		if now < retry then
			if not rec.cnext or retry < rec.cnext then rec.cnext = retry end
			return "wait"
		end
		rec.cretry[key] = nil
		if not next(rec.cretry) then rec.cretry = nil end
	end
	if AC.active_job_for(net, key) then rec.cstat = "other-job" return "crafting" end
	if now ~= craft_tick then craft_tick, craft_starts = now, 0 end
	if craft_starts >= CRAFT_STARTS then return nil end
	local why
	if not AC.free_slot(net) then why = "no-free-cpu"
	else
		craft_starts = craft_starts + 1
		local nid
		nid, why = AC.start(rec.entity, key, math.max(1, math.floor(amount)), rec.entity.unit_number, nil, "io")
		if nid then
			rec.cjobs = jobs or {}
			rec.cjobs[key] = nid
			rec.cstat = "crafting"
			return "crafting"
		end
	end
	rec.cstat = why or "failed"
	local at = now + (why == "no-pattern" and CRAFT_RETRY_NONE or CRAFT_RETRY)
	rec.cretry = rec.cretry or {}
	rec.cretry[key] = at
	if not rec.cnext or at < rec.cnext then rec.cnext = at end
	return "wait"
end

--- Issue #426: the request of an export bus in craft only (AE2-U's `Settings.CRAFT_ONLY`: it never exports from storage, it
--- crafts what its target can take and the job hands the products to the target, N.deliverers). The visit says "crafting"
--- (probed, woken by its job's end); a start that the tick's budget left is tried at the next tick, and one that waits for
--- another block's job of the key after CRAFT_RETRY ticks (that job's end wakes its own block only), through rec.cnext.
local function craft_only(rec, net, key, amount, info)
	local r = craft(rec, net, key, amount)
	local at = r == nil and game.tick + 1 or r == "crafting" and rec.cstat == "other-job" and game.tick + CRAFT_RETRY or nil
	if at and not (rec.cnext and rec.cnext <= at) then rec.cnext = at end
	info.nokey, info.cwait = true, true
end
local CONFIG_SLOTS = 9             -- the config rows of an interface without cards
local MAX_ROWS = 36                  -- with three Interface Capacity Cards (issue #196: 9 more rows each)

--- the config rows of an interface (issue #196): 9 and 9 more per Interface Capacity Card (`rec.nrows`, made from its cards by
--- resize_rows; nil: 9). Rows beyond them are kept aside (`rec.extra`) and come back when a card gives them room.
local function rows_of(rec) return rec.nrows or CONFIG_SLOTS end
local icards                         -- the interface's card slots (scripts/fork-me-cardslots.lua), made below
local MAX_AMOUNT = 1000000
local EPS = 1e-6
local FLUID_PREFIX = "fluid/"
local TEMP_TOLERANCE = 1             -- degrees: a box this close to a key's temperature takes it (issue #159)
local MIX_HINT = 5                   -- temperatures of one fluid from which an import shows the hint of issue #161
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
--- the idle limit of this tick (computed once per tick by M.on_tick; read by the visits, the probes and the idle sides
--- of issue #313)
local tick_limit = MAX_CATCH_UP

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

--- issue #382: what one craft of recipe `recipe` uses of item `name` (0: none), cached per load by recipe and item
local need_cache = {}
local function need_of(recipe, name)
	local byr = need_cache[recipe]
	if not byr then
		byr = {}
		local proto = prototypes.recipe[recipe]
		for _, ing in pairs(proto and proto.ingredients or {}) do
			if ing.type == "item" then byr[ing.name] = (byr[ing.name] or 0) + ing.amount end
		end
		need_cache[recipe] = byr
	end
	return byr[name] or 0
end

--- Issue #382: what an export bus tops item `name` up to in machine `t` (T.SLOTTED): a stack of it, or two crafts of the
--- machine's recipe when that is more (as an inserter does), so a recipe that needs more than a stack of an item starts.
--- `recipe`: the recipe's name, false for none (a lab, an idle machine), nil when not looked up yet (one engine call that
--- makes two objects: the callers ask only when the machine holds a stack already). Returns the level and the recipe.
local function machine_level(t, name, recipe)
	local level = stack_of(name)
	if recipe == nil then
		local r = t.type ~= "lab" and t.get_recipe()
		recipe = r and r.name or false
	end
	if recipe then
		local n = 2 * need_of(recipe, name)
		if n > level then level = n end
	end
	return level, recipe
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
	if N.is_fluid_key(f) then return N.clean_fluid_filter(f) end
	if prototypes.item[f] then return f end
	if prototypes.fluid[f] then return FLUID_PREFIX .. f end
	--- issue #291: an item of one quality, "name@quality" ("name@normal" is the plain name)
	local name, q, json = N.parse_key(f)
	if not json and prototypes.item[name] and prototypes.quality[q] and (q == "normal" or script.feature_flags.quality) then
		return N.key_of(name, q)
	end
	return nil
end

--- Issue #291: a bus's item filter is a plain name or "name@quality". The import bus takes every quality of a plain
--- name (as before) and only that quality of a filter with one; the export bus exports normal quality for a plain name
--- and the filter's quality for one with a quality. The name and quality of a filter key, cached per load.
local filter_items = {}
local function filter_item(key)
	local v = filter_items[key]
	if not v then
		local name, q = N.parse_key(key)
		v = { name, q }
		filter_items[key] = v
	end
	return v[1], v[2]
end

--- does the import filter set `set` take `name` of quality `q`? (`rec.iq`: the bus has a filter with a quality)
local function import_takes(rec, set, name, q)
	if set[name] then return true end
	return rec.iq and q ~= nil and q ~= "normal" and set[N.key_of(name, q)] or false
end
--- does an import bus take `name` of quality `q`: everything (`all`), else its group filter's text (issue #363) or its item filters,
--- turned into a blacklist by an Inverter Card (issue #413, `rec.binv`)
local function import_hit(rec, all, gf, set, name, q)
	if all then return true end
	local hit
	if gf then hit = N.GF.match(gf, N.key_of(name, q or "normal")) and true or false
	else hit = import_takes(rec, set, name, q) and true or false end
	return hit ~= (rec.binv or false)
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

--- the key of a config row (a fluid: its filter key, "fluid/<name>" or "fluid/<name>@<degrees>")
local function row_key(c)
	if is_fluid_row(c) then return N.fluid_filter_key(c.name, c.temperature) end
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
		if type(c) == "table" and i and i >= 1 and i <= MAX_ROWS and i == math.floor(i) then
			if c.type == "fluid" then
				local temp = tonumber(c.temperature)
				local key = type(c.name) == "string" and prototypes.fluid[c.name] and N.fluid_filter_key(c.name, temp)
				if key and not seen[key] then
					seen[key] = true
					local _, deg = N.split_fluid_key(key)
					out[i] = { type = "fluid", name = c.name, temperature = deg,
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

--- `config` (checked) as the interface's active rows (`rec.config`) and the rows its cards do not give room for (`rec.extra`)
local function split_rows(rec, config)
	local n = rows_of(rec)
	local active, extra = {}, nil
	for i, c in pairs(config) do
		if i <= n then
			active[i] = c
		else
			extra = extra or {}
			extra[i] = c
		end
	end
	rec.config, rec.extra = active, extra
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

--- Issue #412: the rows of an interface whose rows come from the circuit (`rec.ccfg`): every item and fluid signal on its
--- connector's wires with a positive count is a row of that amount, in the order of their keys, as many as the interface has
--- rows; a fluid row is at most a side's volume. The rows set by hand stay (`rec.config`) and work again without the option.
local function circuit_config(rec)
	local sig = Conn.signals(rec.entity.unit_number)
	local keys = {}
	for key, count in pairs(sig) do
		if count > 0 then keys[#keys + 1] = key end
	end
	table.sort(keys)
	local rows = {}
	for i = 1, math.min(#keys, rows_of(rec)) do
		local key = keys[i]
		if N.is_fluid_key(key) then
			local name = N.split_fluid_key(key)
			rows[i] = { type = "fluid", name = name, amount = sig[key] }
		else
			local name, q = N.parse_key(key)
			rows[i] = { name = name, quality = q, amount = sig[key] }
		end
	end
	return clean_config(rows)
end

--------------------------------------------------------------------------------
--- interface: the side tanks
--------------------------------------------------------------------------------

--- issue #420: the tile beside each side (north, east, south, west)
local NEAR = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }
local TANK_CHECK_TICKS = 8          -- issue #420: one interface looks at its sides again every so many ticks (the fallback)

--- rec.fconn: is anything connected to a side? (an idle interface without connections looks at its sides rarely)
local function refresh_connections(rec)
	rec.sidle = nil
	local any = false
	for _, t in pairs(rec.tanks or {}) do
		if t.valid and #t.fluidbox.get_connections(1) > 0 then any = true break end
	end
	rec.fconn = any or nil
end

--- the tank of side `d`, made on the interface's tile (it collides with nothing)
local function make_tank(rec, d)
	local e = rec.entity
	local t = e.surface.create_entity{ name = T.SIDE, position = e.position, direction = SIDES[d], force = e.force,
		create_build_effect_smoke = false }
	if t then t.destructible = false end
	return t
end

--- issue #420: does an entity with fluid boxes stand on the tile beside side `d` (a pipe, pump, tank or machine that
--- could connect there)? One engine query of that tile.
local function fluid_near(rec, d)
	local e = rec.entity
	local p = e.position
	local x, y = p.x + NEAR[d][1], p.y + NEAR[d][2]
	for _, o in pairs(e.surface.find_entities_filtered{ area = { { x - 0.4, y - 0.4 }, { x + 0.4, y + 0.4 } } }) do
		if o.valid and T.has_fluid_boxes(o) then return true end
	end
	return false
end

--- issue #420: is the tank of side `d` needed (tied to a row, holding fluid, or connected)?
local function tank_needed(rec, d, t)
	if type((rec.sides or {})[d]) == "number" then return true end
	local f = T.fluidbox(t)[1]
	if f and f.amount > 0 then return true end
	return #t.fluidbox.get_connections(1) > 0
end

--- Issue #420: side `d` gets its tank where it needs one: a side tied to a row always, else when an entity with fluid
--- boxes stands beside it and the new tank connects to it (else the tank goes again). `fresh`: an interface of a save made
--- before its tanks existed: a side that a pipe, pump or tank already points at is set to "off", so a pipeline that ran
--- past the interface is not drained into the network. Returns the tank (nil: none needed).
local function fit_side(rec, d, fresh)
	local tanks = rec.tanks
	local t = tanks[d]
	if t and t.valid then return t end
	tanks[d] = nil
	local tied = type((rec.sides or {})[d]) == "number"
	if not (tied or fluid_near(rec, d)) then return nil end
	t = make_tank(rec, d)
	if not t then return nil end
	if not tied and #t.fluidbox.get_connections(1) == 0 then
		t.destroy()
		return nil
	end
	tanks[d] = t
	if fresh and not tied then
		local e = rec.entity
		rec.sides = rec.sides or {}
		rec.sides[d] = "off"
		log("FORK-ME-IO: ME Interface " .. e.unit_number .. " at " .. e.position.x .. "," .. e.position.y
			.. ": side " .. d .. " is connected to an existing pipe: off (switch it to import in its window)")
	end
	return t
end

--- The side tanks of an interface: rec.tanks = { [side] = tank }, issue #420: only the sides that need one (fit_side). The
--- first call finds the tanks on its tile (a save or a clone that has them; an older save had four), keeps those that are
--- needed and fits the other sides; later calls drop the tanks that are gone. Returns the tanks (nil without the prototype).
local function ensure_tanks(rec, fresh)
	local tanks = rec.tanks
	if tanks then
		for d, t in pairs(tanks) do if not t.valid then tanks[d] = nil end end
		return tanks
	end
	if not prototypes.entity[T.SIDE] then return nil end
	local e = rec.entity
	tanks = {}
	for _, t in pairs(e.surface.find_entities_filtered{ name = T.SIDE, position = e.position }) do
		local d = SIDE_OF[t.direction]
		if d and not tanks[d] then tanks[d] = t else t.destroy() end
	end
	rec.tanks = tanks
	for d = 1, #SIDES do
		local t = tanks[d]
		if t then
			if not tank_needed(rec, d, t) then
				t.destroy()
				tanks[d] = nil
			end
		else
			fit_side(rec, d, fresh)
		end
	end
	refresh_connections(rec)
	return tanks
end
M.ensure_tanks = ensure_tanks

--- Issue #420: the sides of an interface looked at again (the fallback for what came without an event): a tank no longer
--- needed goes, a side with a fluid entity beside it gets one. True when something changed.
local function refit_tanks(rec)
	local tanks = ensure_tanks(rec)
	if not tanks then return false end
	local changed = false
	for d = 1, #SIDES do
		local t = tanks[d]
		if t then
			if not tank_needed(rec, d, t) then
				t.destroy()
				tanks[d] = nil
				changed = true
			end
		elseif fit_side(rec, d) then
			changed = true
		end
	end
	if changed then refresh_connections(rec) end
	return changed
end

--- the four side tanks of an interface (north, east, south, west), created where missing (for tests; issue #420: the
--- fallback look at its sides removes those that stay empty and unconnected again)
function M.tanks_of(entity)
	if kind(entity) ~= "interface" then return nil end
	local rec = register(state(), entity)
	local tanks = ensure_tanks(rec)
	if not tanks then return nil end
	for d = 1, #SIDES do
		if not (tanks[d] and tanks[d].valid) then tanks[d] = make_tank(rec, d) end
	end
	refresh_connections(rec)
	return tanks
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
	local segment = N.bound(fb).get_fluid_segment_contents(1)
	local available = math.max(held.amount, (segment and segment[held.name] or 0) + 1)   -- segment counts are rounded
	local room = N.can_insert_fluid(net, held.name, available, held.temperature)          -- (issue #159: its temperature)
	if room <= EPS then return 0, "full" end
	local removed = N.bound(t).remove_fluid{ name = held.name, amount = room }
	if removed <= 0 then return 0, "ok" end
	local stored = N.insert_fluid(net, held.name, removed, held.temperature)
	if stored < removed - EPS then          -- cannot happen (room was checked), but never lose fluid
		t.insert_fluid{ name = held.name, amount = removed - stored, temperature = held.temperature }
	end
	return stored, "ok"
end
M.tank_to_network = tank_to_network

--- Issue #159: the storage keys an export may take of fluid `name` for the filter key `fk` (no temperature: every
--- temperature, the default first, then from the coldest; with one: that key), that the network holds, within [lo, hi]
--- (nil: open) and, while the target holds the fluid at `held` degrees, at that temperature only. Returns a shared list
--- (read it before the next call) and its length.
local CAND, ONE = {}, {}
local function export_keys(net, name, fk, lo, hi, held)
	local _, deg = N.split_fluid_key(fk)
	local list
	if deg then
		ONE[1] = N.fluid_storage_key(fk)
		list = ONE
	else
		list = N.fluid_keys(net, name)
	end
	local items, n = net.items, 0
	for i = 1, #list do
		local key = list[i]
		if (items[key] or 0) > EPS then
			local t = N.fluid_temperature(key)
			if (not lo or t >= lo - EPS) and (not hi or t <= hi + EPS) and (not held or math.abs(t - held) <= TEMP_TOLERANCE) then
				n = n + 1
				CAND[n] = key
			end
		end
	end
	for i = n + 1, #CAND do CAND[i] = nil end
	return CAND, n
end
M.export_keys = export_keys

--- does the fluid `held` (a box's contents) belong to row or filter key `fk`? (its fluid, and its temperature if `fk`
--- names one)
local function holds_key(held, fk)
	return N.fluid_matches(fk, N.fluid_key(held.name, held.temperature))
end

--- Issue #161: fluid of several temperatures mixed in pipes before an import comes in at every whole degree the mix
--- reaches (a mixed steam line: up to 76 types in a simulated hour, docs/ME-REWORK.md), each a type of its own. After
--- an import of `name` the block remembers { fluid, number of its temperatures in the network } while the network holds
--- at least MIX_HINT of them (rec.fmix: its window shows a hint), and forgets it when it imports that fluid again with
--- fewer.
local function mix_check(rec, net, name)
	local n, items = 0, net.items
	for _, key in ipairs(N.fluid_keys(net, name)) do
		if (items[key] or 0) > EPS then n = n + 1 end
	end
	if n >= MIX_HINT then
		local m = rec.fmix
		if not (m and m[1] == name and m[2] == n) then rec.fmix = { name, n } end
	elseif rec.fmix and rec.fmix[1] == name then
		rec.fmix = nil
	end
end

--- keep a side's tank at its row's amount of the row's fluid; returns the status, the amount moved and what the
--- side still lacks, and the storage key it waits for (issue #159). `p`: the interface's priority when priorities are in use (issue #17: what interfaces of a higher
--- priority lack is left in the network)
local function export_side(t, held, row, net, p)
	local moved = 0
	local fk = row_key(row)
	if held and not holds_key(held, fk) then           -- another fluid (or a temperature the row does not take): into the network first
		moved = tank_to_network(t, held, net)
		held = T.fluidbox(t)[1]
		if held and held.amount <= EPS then held = nil end
		if held and not holds_key(held, fk) then return "blocked", moved, 0 end
	end
	local want = math.min(row.amount, volume()) - (held and held.amount or 0)
	local first = N.fluid_storage_key(fk)
	if want <= EPS then return "ok", moved, 0, first end
	local keys, n = export_keys(net, row.name, fk, nil, nil, held and held.temperature)
	if n == 0 then
		if N.fluid_total(net, row.name, fk) > EPS then return "temperature", moved, want, first end
		return "empty-network", moved, want, first
	end
	local key, avail
	for i = 1, n do                                      -- one temperature per visit: the tank holds it then
		key = keys[i]
		avail = net.items[key] or 0
		if p then avail = avail - reserved(net, key, p) end
		if avail > EPS then break end
	end
	if avail <= EPS then return "reserved", moved, want, keys[1] end
	local inserted = N.bound(t).insert_fluid{ name = row.name, amount = math.min(want, avail), temperature = N.fluid_temperature(key) }
	local got = 0
	if inserted > 0 then
		got = N.extract_fluid_key(net, key, inserted)
		--- a storage bus's segment had less than its snapshot: never duplicate
		if got < inserted - EPS then t.remove_fluid{ name = row.name, amount = inserted - got } end
		moved = moved + got
	end
	return "ok", moved, math.max(0, want - got), key
end

--- issue #313: a visited interface that does not look at its sides looks at its tanks every SIDLE_LOOK idle limits (four
--- reads each time: the bench's interfaces are visited less often than the idle limit, so every visit would read them)
local SIDLE_LOOK = 4

--- issue #313: does a tank of the interface hold fluid? (four reads; for an interface that does not look at its sides)
local function tanks_hold(rec)
	for _, t in pairs(rec.tanks or {}) do
		if t.valid then
			local f = T.fluidbox(t)[1]
			if f and f.amount > EPS then return true end
		end
	end
	return false
end

--- one pass over the four sides; rec.fstatus[d] is what the window shows. Returns the fluid moved (an export side
--- whose fluid the network lacks waits for it: N.wait_for). `short`: the shortfalls of this visit (issue #17), nil
--- while priorities are not in use.
local function interface_sides(rec, net, config, short, dt)
	--- nothing connected, nothing exported, nothing in the tanks (see the end): the sides are skipped. Issue #313: only up
	--- to SIDLE_LOOK idle limits after the pass that found it (`rec.sidle`: its tick; `true` of a save from before: at
	--- once): fluid that came without an event (a machine's fluid box connecting with its recipe, a rotated pump) is found
	--- then by an interface its items keep busy (an idle one, probed, looks at the idle limit: probe_work)
	if rec.sidle then
		if game.tick - (rec.sidle == true and 0 or rec.sidle) < SIDLE_LOOK * tick_limit then return 0, math.huge end
		--- at the idle limit one look at the tanks (four reads): only fluid in one of them makes the full pass
		if rec.tanks and not tanks_hold(rec) then
			rec.sidle = game.tick
			return 0, math.huge
		end
		rec.sidle = nil
	end
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
		local tied = type(setting) == "number" and is_fluid_row(config[setting])
		if tied and not t then t = fit_side(rec, d) end              -- (issue #420: a side tied to a row gets its tank)
		local held = t and T.fluidbox(t)[1]
		if held and held.amount <= EPS then held = nil end
		if held then anyheld = true end
		if setting == "off" then
			fstatus[d] = "off"
		elseif tied and t then
			if not held then sstarved = true end                      -- the side's tank had run out
			local why, n, lack, key = export_side(t, held, config[setting], net, short and (rec.priority or 0))
			fstatus[d] = why
			moved = moved + n
			if why == "empty-network" or why == "reserved" or why == "temperature" then
				--- (a row of every temperature waits for "fluid/<name>": any temperature of it wakes it, issue #159)
				N.wait_for(net, why == "reserved" and key or row_key(config[setting]), "io", rec.entity.unit_number, true)
				--- issue #426: the Crafting Card asks for what the side lacks of a fluid the network does not have (the row's
				--- temperature, or the fluid's default one)
				if why == "empty-network" and rec.ccard and lack > EPS then
					craft(rec, net, N.fluid_storage_key(row_key(config[setting])), lack)
				end
			end
			key = key or row_key(config[setting])
			if short and lack > EPS then short[key] = (short[key] or 0) + lack end
			if n + lack > EPS then                                   -- the side is drained at (n + lack) per dt
				local tt = math.min(config[setting].amount, volume()) * dt / (n + lack)
				if tt < time then time = tt end
			end
		elseif held then
			if rec.exporting and not exports then
				exports = {}
				for e = 1, #SIDES do
					if type(sides[e]) == "number" and tanks[e] then
						local id = N.bound(T.fluidbox(tanks[e])).get_fluid_segment_id(1)
						if id then exports[id] = true end
					end
				end
			end
			local id = exports and N.bound(T.fluidbox(t)).get_fluid_segment_id(1)
			if id and exports[id] then
				fstatus[d] = "loop"
			else
				if held.amount >= volume() - EPS then sstarved = true end   -- the side's tank was full
				local n, why = tank_to_network(t, held, net)
				fstatus[d] = why
				moved = moved + n
				if n > EPS then mix_check(rec, net, held.name) end
				if n > EPS then                                      -- the side fills at n per dt
					local tt = volume() * dt / n
					if tt < time then time = tt end
				elseif why == "full" then                            -- the network takes none: woken when room appears
					N.wait_for(net, N.fluid_key(held.name, held.temperature), "io", rec.entity.unit_number, false)
					N.wait_room(net, "io", rec.entity.unit_number)
				end
			end
		else
			fstatus[d] = "import"
		end
	end
	--- no pipe or pump at a side (rec.fconn, kept by M.wake_near and ensure_tanks), no row that exports, nothing in the
	--- tanks: the next passes would find the same; a wake, a connection or a changed row looks again (rec.sidle = nil)
	if not (anyheld or rec.fconn or rec.exporting) then rec.sidle = game.tick else rec.sidle = nil end
	return moved, time, sstarved
end

--- One visit: every configured item is kept at its amount (filled from the network, the surplus taken back),
--- the other items are imported (at most IFACE_SLOTS_PER_VISIT operations per STEP_TICKS since the last visit,
--- `dt`); then the four sides. Returns the items and fluid moved, whether the operations ran out, the ticks until
--- the next visit (the headroom rule over the rows, the imports and the sides), why it is blocked when nothing
--- moved ("idle": probed; an interface is never parked for a missing key, an inserter may feed it any time),
--- whether a row had run empty, its network, and the ticks until its buffer runs out at the rate this visit saw.
function M.interface_step(rec, dt, u)
	local e = rec.entity
	if rec.want then icards.fill_cards(rec) end                       -- issue #196: the cards a blueprint or a paste asked for
	local config = config_of(rec)
	if rec.cnext and game.tick >= rec.cnext then rec.cnext = nil end     -- (issue #411: a retry is due now)
	--- issue #412: its circuit connector's condition, the rows from the circuit
	if rec.coff then
		rec.status = "circuit-off"
		return 0, false, nil, "circuit", false, nil
	end
	if rec.ccfg then config = circuit_config(rec) end
	local net = u and N.active_of_unit(u) or not u and N.active_of(e) or nil   -- (`u`: the unit of a visit, issue #115)
	if not net then
		local n0 = u and N.network_of_unit(u) or not u and N.network_of(e) or nil
		local _, why = N.usable(n0)
		rec.status = why or "no-network"
		return 0, false, nil, (n0 and why == "no-power") and "no-power" or "no-network", false, n0
	end
	local ticks = math.min(dt or STEP_TICKS, MAX_CATCH_UP)
	local max_ops = math.max(IFACE_SLOTS_PER_VISIT, math.floor(IFACE_SLOTS_PER_VISIT * ticks / STEP_TICKS))
	local inv = T.inventory(e, defines.inventory.chest)
	local B = N.bound(inv)                                    -- (its methods: issue #115)
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
	for i = 1, rows_of(rec) do
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
			local have = B.get_item_count(Q_COUNT)
			local final = have
			if have < c.amount then
				local want = c.amount - have
				if short then want = math.min(want, math.max(0, N.count_key(net, key) - reserved(net, key, p))) end
				local got = want > 0 and N.extract_to(net, inv, key, want) or 0
				if have == 0 and got > 0 then starved = true end        -- (a row that had run empty)
				if got > 0 then moved = moved + got ops = ops + 1
				elseif N.count_key(net, key) <= 0 or short then
					N.wait_for(net, key, "io", unit, true)
					--- issue #411: the Crafting Card asks for what the row lacks
					if rec.ccard and N.count_key(net, key) <= 0 then craft(rec, net, key, c.amount - have) end
				end
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
						taken = B.remove(Q_REMOVE)
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
	if not B.is_empty() then
		walk = B.get_item_count() ~= held_total          -- (more in it than the kept rows hold: something to import; no table)
	end
	local start = rec.slot or 1
	--- issue #115: the stacks the walk has still to find (an inventory with a few stacks and many empty slots: the empty rest
	--- counts as free without reading each slot; the operations limit is checked first, as at every slot)
	local stacks = walk and size - B.count_empty_stacks(true, true) or 0
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
	local rec = register(state(), entity)
	for _, rows in ipairs({ config_of(rec), rec.extra or {} }) do          -- (issue #196: and the rows no card gives room for)
		for i, c in pairs(rows) do
			out[i] = { type = c.type, name = c.name, quality = c.quality, amount = c.amount, temperature = c.temperature }
		end
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
	split_rows(rec, clean_config(config))
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
			if tanks and tanks[d] and #tanks[d].fluidbox.get_connections(1) > 0 then return d, true end
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
	if kind(entity) ~= "interface" then return false end
	local rec = register(state(), entity)
	if not (i >= 1 and i <= rows_of(rec)) then return false end
	local config = M.get_interface_config(entity)
	local sides = M.get_interface_sides(entity)
	local row
	if key and N.clean_fluid_filter(key) then
		local name, deg = N.split_fluid_key(N.clean_fluid_filter(key))
		row = { type = "fluid", name = name, temperature = deg }
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
	for i = 1, MAX_ROWS do
		local c = config[i]
		if c then out[#out + 1] = { slot = i, type = c.type, name = c.name, quality = c.quality, amount = c.amount, temperature = c.temperature } end
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

--- the interface's tag (blueprints): { config, sides, priority (issue #17, only when not 0), cards (issue #196: the Interface
--- Capacity Cards it has, only when there are any) }
function M.interface_tag(config, sides, priority, cards, circuit)
	return { config = config_tag(clean_config(config)), sides = sides_tag(sides),
		priority = priority and priority ~= 0 and priority or nil, cards = cards, circuit = circuit or nil }   -- (issue #412)
end

--- the interface's state for its window: { config, sides, status, contents = { { key, count } }, fluids = { [1..4] =
--- { setting, status, name, amount, temperature, connected, segment } }, slots, volume }. `segment` (issue #311): what the
--- side's fluid segment (its tank and the pipes without a pump between) holds of the tank's fluid, read only here (the
--- open window, once a second); 0 when the tank is empty.
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
		local status = rec.fstatus and rec.fstatus[d] or nil
		--- issue #313: the last pass found this import side empty; it holds fluid now: imported at the next visit
		if status == "import" and held and held.amount > EPS then status = "waiting" end
		local segment = 0
		if held and held.amount > EPS then
			local c = T.fluidbox(t).get_fluid_segment_contents(1)
			segment = math.max(held.amount, c and c[held.name] or 0)
		end
		fl[d] = { setting = sides[d] or "import", status = status,
			name = held and held.amount > EPS and held.name or nil, amount = held and held.amount or 0,
			temperature = held and held.amount > EPS and held.temperature or nil,
			connected = t ~= nil and #t.fluidbox.get_connections(1) > 0, segment = segment }
	end
	local short = {}
	for key in pairs(rec.short or {}) do
		local net = N.get(rec.short_net)
		local e = net and net.short and net.short[key] and net.short[key][entity.unit_number]
		if e then short[key] = e[2] end
	end
	return { config = M.get_interface_config(entity), sides = sides, status = rec.status, contents = contents,
		fluids = fl, slots = rows_of(rec), volume = volume(), priority = rec.priority or 0, short = short,
		fmix = rec.fmix and { rec.fmix[1], rec.fmix[2] } or nil, card_slots = N.card_rules().interface.slots,
		want = rec.want and icards.missing_cards(rec, rec.want) or nil, kept = rec.extra and next(rec.extra) ~= nil or nil,
		craft = rec.ccard and (rec.cstat or "idle") or nil,        -- (issue #411: the Crafting Card's last request)
		circuit = rec.ccfg == true, circuit_rows = rec.ccfg and circuit_config(rec) or nil,   -- (issue #412)
		off = Conn.is_off(entity.unit_number) or nil }
end
M.CONFIG_SLOTS = CONFIG_SLOTS

--- the config rows of an interface with its cards (recipe paste: how many fit)
function M.row_capacity(entity)
	local rec = kind(entity) == "interface" and register(state(), entity)
	return rec and rows_of(rec) or CONFIG_SLOTS
end
M.MAX_FILTERS = MAX_FILTERS
M.side_volume = function() return volume() end      -- the amount a new fluid row gets
M.SIDES = #SIDES

--------------------------------------------------------------------------------
--- buses
--------------------------------------------------------------------------------

local BUSES = { ["import-bus"] = true, ["export-bus"] = true, ["fluid-import-bus"] = true, ["fluid-export-bus"] = true }
local IMPORTS = { ["import-bus"] = true, ["fluid-import-bus"] = true }   -- (the old fluid kinds until they are replaced)

--- Issue #110: the card slots of an import and an export bus (scripts/fork-me-cardslots.lua; the cards of a block are the
--- items of a script inventory its window shows). Only the Acceleration Card fits (issue #356: and the Super Speed and Superluminal
--- Speed Cards, whose amounts add to the factor): AE2's speed card, 4 of them, which
--- multiply the items a bus moves per second (the map setting "bus speed") by 1, 8, 32, 64 and 96 (0 to 4 cards:
--- `N.card_rules().speed`; AE2: PartImportBus and PartExportBus, 1, 8, 32, 64, 96 items per operation). Fluids are not
--- sped up (AE2's cards act on items). `rec.accel` is that factor (nil: 1), made from the cards when they change.
local function bus_rec(entity)
	local s = storage.fork_me_io
	return s and entity and entity.valid and entity.unit_number and BUSES[kind(entity)] and s.recs[entity.unit_number] or nil
end
local cards
--- Issue #413: the Capacity Card (9 more filters each, up to 2: `rec.nf`), the Fuzzy Card (a filter takes every quality of its
--- item: `rec.fz`) and, on the import bus only, the Inverter Card (the filters are a blacklist: `rec.binv`).
local function bus_rules(rec)
	local r = N.card_rules()
	return rec and IMPORTS[rec.kind] and r.import_bus or r.bus
end
cards = CS.new{
	rules = bus_rules,
	title = function(rec) return rec.entity and rec.entity.valid and rec.entity.localised_name or { "entity-name.me-import-bus" } end,
	rec_of = bus_rec,
	on_cards = function(rec, light)
		local counts, r = cards.counts(rec), N.card_rules()
		rec.gcard = counts.gfilter and true or nil            -- issue #363: a Group Filter Card
		local br = bus_rules(rec)
		local nf = br.filters + br.per_capacity * math.min(counts.capacity or 0, br.limits.capacity)
		rec.nf = nf ~= MAX_FILTERS and nf or nil
		rec.fz = counts.fuzzy and true or nil
		rec.binv = counts.inverter and IMPORTS[rec.kind] and true or nil
		rec.ccard = counts.crafting and not IMPORTS[rec.kind] and true or nil   -- issue #411: a Crafting Card (export bus)
		M.bus_split(rec)                                      -- (the filters that apply, and the group filter: M.bus_gf)
		local f = r.speed[(counts.speed or 0) + 1]
		--- issue #356: the Super Speed and Superluminal Speed Cards add to the factor (AE2-U: the kinds add up)
		if counts.superspeed then f = f + r.superspeed[counts.superspeed] end
		if counts.superluminal then f = f + r.superluminal[counts.superluminal] end
		rec.accel = f > 1 and f or nil
		if not light and rec.entity and rec.entity.valid then wake(rec.entity.unit_number) end
	end,
}

--- Issue #196: the card slots of an ME Interface (scripts/fork-me-cardslots.lua): only the Interface Capacity Card fits, 3 of them,
--- each gives 9 more config rows (9, 18, 27 or 36). A card taken out (or lost another way) leaves the rows it gave in
--- `rec.extra`: they are kept, shown nowhere and do nothing, until a card gives them room again. `rec.nrows` is the number of rows.
local function iface_rec(entity)
	local s = storage.fork_me_io
	return s and entity and entity.valid and entity.unit_number and kind(entity) == "interface" and s.recs[entity.unit_number] or nil
end
M.iface_rec = iface_rec

local function resize_rows(rec)
	local rules = N.card_rules().interface
	local size = rules.rows + rules.per_capacity * (icards.counts(rec).interface_capacity or 0)
	rec.nrows = size ~= CONFIG_SLOTS and size or nil
	local all = {}
	for _, rows in ipairs({ rec.config or {}, rec.extra or {} }) do for i, c in pairs(rows) do all[i] = c end end
	split_rows(rec, all)
	rec.sides = clean_sides(rec.sides, rec.config)
	refresh_exporting(rec)
	if rec.entity.valid then wake(rec.entity.unit_number) end
end

icards = CS.new{
	rules = function() return N.card_rules().interface end,
	title = function(rec) return rec.entity and rec.entity.valid and rec.entity.localised_name or { "entity-name.me-interface" } end,
	rec_of = iface_rec,
	on_cards = function(rec)
		resize_rows(rec)
		rec.ccard = icards.counts(rec).crafting and true or nil     -- issue #411: a Crafting Card
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

--- Issue #426: a job of a block's Crafting Card hands its products to the block (AE2-U's injectCraftedItems of the export bus
--- and of DualityInterface): an export bus puts them into its target, an interface items into its own inventory (a surplus over
--- its row goes back at its next visit) and fluid into the tank of a side tied to a row of that fluid. Returns what was taken.
N.deliverers.io = function(unit, key, count)
	local s = storage.fork_me_io
	local rec = s and s.recs[unit]
	local e = rec and rec.entity
	if not (e and e.valid) then return 0 end
	local fluid = N.fluid_name(key)
	local taken = 0
	if rec.kind == "interface" then
		if fluid then
			local tanks, config, sides = rec.tanks or {}, config_of(rec), rec.sides or {}
			for d = 1, #SIDES do
				local row = type(sides[d]) == "number" and config[sides[d]] or nil
				local t = tanks[d]
				if row and is_fluid_row(row) and t and t.valid and N.fluid_matches(row_key(row), key) then
					taken = taken + t.insert_fluid{ name = fluid, amount = count - taken, temperature = N.fluid_temperature(key) }
					if taken >= count - EPS then break end
				end
			end
		else
			local name, q = N.parse_key(key)
			local inv = T.inventory(e, defines.inventory.chest)
			taken = inv and inv.insert{ name = name, count = count, quality = q } or 0
		end
	elseif rec.kind == "export-bus" then
		local t = target_of(rec)
		if not t then return 0 end
		if fluid then
			if rec.t_fluid then taken = t.insert_fluid{ name = fluid, amount = count, temperature = N.fluid_temperature(key) } end
		else
			local name, q = N.parse_key(key)
			local inv = rec.t_inv and T.inventory(t, rec.t_inv)
			taken = inv and inv.insert{ name = name, count = count, quality = q } or 0
		end
	end
	if taken > 0 then wake(unit) end
	return taken
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
	local all, set, gf = rec.all, rec.iset, rec.gf             -- (issue #363: a group filter's text in place of the item filters)
	local unit = rec.entity.unit_number
	local moved, stacks, held, main, mainc = 0, false, 0, nil, 0
	local B = N.bound(inv)                                    -- (its methods: issue #115)
	for _, c in pairs(B.get_contents()) do
		if import_hit(rec, all, gf, set, c.name, c.quality) then
			held = held + c.count
			if c.count > mainc then main, mainc = c.name, c.count end
			if moved < cap then
				local q = c.quality or "normal"
				if by_count(c.name, q) then
					Q_REMOVE.name, Q_REMOVE.quality, Q_REMOVE.count = c.name, q, math.min(c.count, cap - moved)
					local removed = B.remove(Q_REMOVE)
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
			if stack.valid_for_read and import_hit(rec, all, gf, set, stack.name, stack.quality.name)
				and not by_count(stack.name, stack.quality.name) then
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
	local recipe                                          -- (issue #382: the machine's, looked up once a visit when needed)
	local moved = 0
	local tgt = rec.tgt
	if not tgt then
		tgt = {}
		rec.tgt = tgt
	end
	local dt = info.dt or STEP_TICKS
	--- the keys: the filters, or (issue #363) the group filter's keys in turn from where the last visit stopped, at most as many
	--- as the filters (the visit's cost stays a filter list's); a key of that list registers no wait of its own. Issue #413: with
	--- a Fuzzy Card the network's keys of the filters' items in every quality, in turn the same way.
	local gf = rec.gf or rec.fz
	local list, i, count
	if gf then
		list = M.gf_list(rec, net)
		i, count = rec.gcur or 1, math.min(#list, filters_of(rec))
	else
		list, i, count = rec.filters, 1, #rec.filters
	end
	local n = #list
	for _ = 1, count do
		if gf and moved >= cap then break end
		if i > n then i = 1 end
		local key = list[i]
		i = i + 1
		local name, q = filter_item(key)                      -- (issue #291: a filter may name a quality)
		if item_known(name) then
			local have
			if q == "normal" then have = N.bound(inv).get_item_count(name)
			else
				Q_COUNT.name, Q_COUNT.quality = name, q
				have = N.bound(inv).get_item_count(Q_COUNT)
			end
			local prev = tgt[key]
			if prev and prev > 0 and have == 0 then info.starved = true end
			local used = prev and prev - have or 0
			local want = cap - moved
			if machine then
				--- a stack, and once it holds a stack, two crafts of its recipe when that is more (issue #382); every bus
				--- counts what the machine holds, so several buses on one machine never fill it past that
				local room = stack_of(name) - have
				if room <= 0 and recipe ~= false then
					local level
					level, recipe = machine_level(t, name, recipe)
					room = level - have
				end
				want = math.min(want, room)
			end
			local got = 0
			if want > 0 and rec.conly and rec.ccard then
				--- issue #426: craft only (with the Crafting Card): nothing from storage, a job for what the target can take
				if not gf then
					local item = name
					if q ~= "normal" then
						Q_COUNT.name, Q_COUNT.quality = name, q
						item = Q_COUNT
					end
					if machine or N.bound(inv).can_insert(item) then
						craft_only(rec, net, key, math.min(want, stack_of(name)), info)
					else
						info.blocked = true                          -- the target takes nothing: full
					end
				end
			elseif want > 0 then
				got = N.extract_to(net, inv, key, want)          -- (a plain name: normal quality)
				if got <= 0 then
					if N.count_key(net, key) <= 0 then
						if not gf then
							N.wait_for(net, key, "io", rec.entity.unit_number, true)
							info.nokey = true
							--- issue #411: the Crafting Card asks for what this visit would move, at most a stack
							if rec.ccard and craft(rec, net, key, math.min(want, stack_of(name))) == "wait" then info.cwait = true end
						end
					else
						info.blocked = true                      -- the target takes nothing: full
					end
				end
				moved = moved + got
			end
			local after = have + got
			tgt[key] = after
			if used > 0 and after > 0 then
				local tt = after * dt / used
				if tt < info.time then info.time = tt end
			elseif not prev and got > 0 then
				info.time = MIN_INTERVAL                         -- (the rate is unknown yet: look again soon)
			end
		end
	end
	if gf then
		rec.gcur = i
		if moved <= 0 and not info.blocked then info.nokey = true end   -- (nothing that matches: probed, see probe_work)
	end
	return moved
end

--- Issue #159: why an export moved none of fluid `name` that the network holds (the window's status line): { fluid,
--- the temperatures the network has (text), what the target takes (text) }
local function temperature_why(net, name, fk, lo, hi, temp)
	local has = {}
	for _, key in ipairs(N.fluid_keys(net, name)) do
		if (net.items[key] or 0) > EPS and N.fluid_matches(fk, key) and #has < 4 then
			has[#has + 1] = string.format("%.0f", N.fluid_temperature(key))
		end
	end
	local want
	if temp then want = string.format("%.0f", temp)
	elseif lo and hi then want = lo == hi and string.format("%.0f", lo) or string.format("%.0f-%.0f", lo, hi)
	elseif lo then want = string.format(">=%.0f", lo)
	elseif hi then want = string.format("<=%.0f", hi)
	else want = "?" end
	return { name, table.concat(has, ", "), want }
end

--- Issue #159: what an export into the boxes `fb` may bring of fluid `name`: the temperature range of a box whose
--- filter is the fluid (a machine's recipe: get_filter has its minimum and maximum) and the temperature of a box that
--- holds the fluid already (nothing is mixed into it). nil where open. A machine's output boxes are left out (their
--- filter is the product's temperature, and nothing is inserted into them). Only a crafting machine (`machine`) has a
--- recipe's filters: the box filters of anything else are not read.
local CRAFTER = { ["assembling-machine"] = true, furnace = true, ["rocket-silo"] = true }
local function export_range(fb, name, machine)
	local lo, hi, temp
	local B = N.bound(fb)
	for i = 1, #fb do
		local f = fb[i]
		local has = f and f.name == name and f.amount > EPS
		local flt = machine and B.get_filter(i)
		if not machine then
			if has then return nil, nil, f.temperature end
		elseif has or (flt and flt.name == name) then
			local p = B.get_prototype(i)
			if p and p.production_type == nil and p[1] then p = p[1] end      -- merged prototypes: the first one
			if not (p and p.production_type == "output") then
				if has then temp = temp or f.temperature end
				if flt and flt.name == name then
					if flt.minimum_temperature and (not lo or flt.minimum_temperature > lo) then lo = flt.minimum_temperature end
					if flt.maximum_temperature and (not hi or flt.maximum_temperature < hi) then hi = flt.maximum_temperature end
				end
			end
		end
	end
	return lo, hi, temp
end

--- Issue #426: the room for fluid `name` in the boxes `fb`: empty boxes and boxes of that fluid, whose filter (if any) is the
--- fluid; a machine's output boxes take nothing
local function fluid_room(fb, name)
	local B = N.bound(fb)
	local room = 0
	for i = 1, #fb do
		local f = fb[i]
		if not f or f.name == name then
			local p = B.get_prototype(i)
			if p and p.production_type == nil and p[1] then p = p[1] end      -- merged prototypes: the first one
			local flt = B.get_filter(i)
			if not (p and p.production_type == "output") and (not flt or flt.name == name) then
				room = room + B.get_capacity(i) - (f and f.amount or 0)
			end
		end
	end
	return room
end

--- The fluid part of a visit: the import bus empties the output boxes of a machine (any box of a tank) into the
--- network, at the temperature they have (issue #159), the export bus fills its filtered fluids into the entity
--- (insert_fluid: the machine's input boxes, a tank), at the temperature of the key it takes (export_keys). Up to `cap` units (by default what one visit moved before issue #5).
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
			local v = f and f.amount > EPS and (all or set[f.name])
			if v and v ~= true then                          -- issue #159: filters with a temperature
				local key, ok = N.fluid_key(f.name, f.temperature), false
				for _, fk in ipairs(v) do if N.fluid_matches(fk, key) then ok = true break end end
				v = ok
			end
			if rec.binv and not all and f and f.amount > EPS then v = not v end   -- issue #413: an Inverter Card, a blacklist
			if v then
				local p = N.bound(fb).get_prototype(i)
				if p and p.production_type == nil and p[1] then p = p[1] end      -- merged prototypes: the first one
				if not (p and p.production_type == "input") then
					local capf = N.bound(fb).get_capacity(i)
					local arrived = f.amount - (fleft[i] or 0)
					if f.amount >= capf - EPS then info.starved = true end           -- a full box: the machine waited
					local left = f.amount
					if cap - moved > EPS then
						local take = N.can_insert_fluid(net, f.name, math.min(f.amount, cap - moved), f.temperature)
						if take > EPS then
							left = f.amount - take
							fb[i] = left > EPS and { name = f.name, amount = left, temperature = f.temperature } or nil
							local stored = N.insert_fluid(net, f.name, take, f.temperature)
							if stored > EPS then mix_check(rec, net, f.name) end
							if stored < take - EPS then                 -- cannot happen (room was checked), but never lose fluid
								t.insert_fluid{ name = f.name, amount = take - stored, temperature = f.temperature }
							end
							moved = moved + stored
						else
							info.netfull = true
							N.wait_for(net, N.fluid_key(f.name, f.temperature), "io", unit, false)
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
		local fkeys = rec.fkeys
		local machine = CRAFTER[t.type]
		local conly = rec.conly and rec.ccard                   -- issue #426: craft only, with the Crafting Card
		for fi, name in ipairs(rec.ffilters) do
			local fk = fkeys and fkeys[fi] or N.fluid_key(name)
			local key, total, tblock
			if conly then
				--- issue #426: nothing from storage; a job of the filter's fluid for what this visit would move, while the
				--- target has room for it
				if cap - moved > EPS then
					local room = fluid_room(fb, name)
					if room > EPS then craft_only(rec, net, N.fluid_storage_key(fk), math.min(cap - moved, room), info)
					else info.blocked = true end
				end
			elseif cap - moved > EPS then
				local lo, hi, temp = export_range(fb, name, machine)
				local keys, n = export_keys(net, name, fk, lo, hi, temp)
				for k = 1, n do                                 -- issue #159: one temperature per filter and visit
					key = keys[k]
					total = net.items[key] or 0
					if total > EPS then break end
				end
				if not key and N.fluid_total(net, name, fk) > EPS then
					--- the network has it, but only at temperatures the target cannot take: blocked on the target's side
					info.temperature = temperature_why(net, name, fk, lo, hi, temp)
					info.blocked, tblock = true, true
				end
			end
			if not key and cap - moved > EPS and not tblock and not conly then
				N.wait_for(net, fk, "io", unit, true)            -- (any temperature of a filter without one wakes it)
				info.nokey = true
				--- issue #426: the Crafting Card asks for the filter's fluid too (its default temperature, or the filter's), what
				--- this visit would move and the target can take
				if rec.ccard then
					local room = fluid_room(fb, name)
					if room > EPS and craft(rec, net, N.fluid_storage_key(fk), math.min(cap - moved, room)) == "wait" then
						info.cwait = true
					end
				end
			elseif key then
				local want = math.min(total, cap - moved)
				local inserted = N.bound(t).insert_fluid{ name = name, amount = want, temperature = N.fluid_temperature(key) }
				if inserted > 0 then
					local got = N.extract_fluid_key(net, key, inserted)
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
function M.bus_step(rec, dt, u)
	local e = rec.entity
	--- issue #412: its circuit connector's condition and, for an export bus in pulse mode, one visit per rise of the condition
	if rec.coff or (rec.pulse and not Conn.take_pulse(u or e.unit_number)) then
		rec.status = "circuit-off"
		return 0, false, nil, "circuit", false, nil
	end
	local net = u and N.active_of_unit(u) or not u and N.active_of(e) or nil   -- (`u`: the unit of a visit, issue #115)
	if not net then
		local n0 = u and N.network_of_unit(u) or not u and N.network_of(e) or nil
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
	--- (issue #356: at most MAX_ICAP, what an engine call takes as a count; four Superluminal Speed Cards ask for billions)
	local icap = math.max(1, math.min(MAX_ICAP, math.floor(Sched.setting("bus_items") * (rec.accel or 1) * ticks / 60)))
	local fcap = Sched.setting("bus_fluid") * ticks / 60
	local import = IMPORTS[rec.kind]
	local items, fluid = 0, 0
	local info = INFO
	info.time, info.dt = math.huge, ticks
	info.held, info.main, info.slots, info.netfull, info.nokey, info.blocked, info.starved = nil, nil, nil, nil, nil, nil, nil
	info.temperature, info.cwait = nil, nil
	if rec.cnext and game.tick >= rec.cnext then rec.cnext = nil end     -- (issue #411: a retry is due now)
	--- (issue #413: an import bus with an Inverter Card takes everything its filters do not name, items and fluids)
	local has_items = rec.t_inv and (rec.all or rec.binv or #rec.filters > 0 or rec.gf ~= nil)
	local has_fluid = rec.t_fluid and (rec.all or rec.binv or #rec.ffilters > 0)
	if has_items then
		items = import and import_items(rec, net, t, icap, info) or export_items(rec, net, t, icap, info)
	end
	if has_fluid then fluid = M.fluid_bus_step(rec, net, t, fcap, info) end
	rec.status, rec.tstat = "ok", nil
	local moved = items + fluid
	local full = items >= icap or fluid >= fcap - EPS
	if moved <= 0 then
		if not (has_items or has_fluid) then return 0, false, nil, "unset", false, net end
		if info.netfull then return 0, false, nil, "net-full", false, net end
		if import then
			rec.left = 0                                      -- (seen empty: what the next visit finds arrived since)
			return 0, false, nil, "empty", false, net
		end
		if info.temperature then rec.status, rec.tstat = "temperature", info.temperature end   -- (issue #159)
		if info.blocked or not info.nokey then return 0, false, nil, "full", false, net end
		--- issue #411: a crafting start waits for its retry: probed until then (a parked block would wait for its key only)
		if info.cwait then return 0, false, nil, "crafting", false, net end
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

--- Set the filters: a list of keys (item name, "name@quality" (issue #291), "fluid/<name>"; a plain name that is no
--- item but a fluid is that fluid), at most KEPT_FILTERS (issue #413: those beyond the Capacity Cards' room are kept in
--- rec.keys and do nothing), split by M.bus_split.
function M.set_bus_filters(entity, filters)
	local k = kind(entity)
	if not BUSES[k] then return false end
	local rec = register(state(), entity)
	local keys, seen = {}, {}
	for _, f in pairs(filters or {}) do
		local key = filter_key(f)
		if key and not seen[key] and #keys < KEPT_FILTERS then
			seen[key] = true
			keys[#keys + 1] = key
		end
	end
	rec.keys = keys
	M.bus_split(rec)
	wake(entity.unit_number)
	return true
end

--- The filters that apply (the first filters_of(rec) of rec.keys, issue #413) split into rec.filters (item keys) and
--- rec.ffilters (fluid names) and their sets; rec.iq: a filter names a quality. With a Fuzzy Card (rec.fz) the item set holds
--- the items' names, so a filter takes every quality of its item, and rec.fznames is that set for the export (M.gf_list).
function M.bus_split(rec)
	local items, fl, iset, fset = {}, {}, {}, {}
	local fkeys, temps, iq = {}, false, false
	local fz, n = rec.fz, filters_of(rec)
	for i, key in ipairs(rec.keys or rec.filters or {}) do
		if i > n then break end
		do
			if N.is_fluid_key(key) then
				local name, deg = N.split_fluid_key(key)
				fl[#fl + 1] = name
				fkeys[#fkeys + 1] = key
				--- issue #159: a fluid without a temperature takes every one (true), else the list of its filter keys
				if not deg then fset[name] = true
				elseif fset[name] ~= true then
					fset[name] = fset[name] or {}
					table.insert(fset[name], key)
				end
				if deg then temps = true end
			else
				items[#items + 1] = key
				if fz then iset[(filter_item(key))] = true
				else
					iset[key] = true
					if key:find("@", 1, true) then iq = true end
				end
			end
		end
	end
	if not rec.keys then rec.keys = { table.unpack(rec.filters or {}) } end   -- (a record of a save before issue #3)
	rec.filters, rec.ffilters, rec.iset, rec.fset = items, fl, iset, fset
	rec.fznames = fz and iset or nil
	rec.iq = iq or nil
	rec.fkeys = temps and fkeys or nil                    -- (the filter keys of rec.ffilters, only with a temperature)
	M.bus_gf(rec)
end

--- Issue #363: the Group Filter Card on an import or export bus (AE2-Unofficial: PartBaseImportBus.java:132,
--- PartBaseExportBus.java:95). With the card, the text (rec.gtext, a setting kept when the card goes) takes the place of the
--- item filters (the fluid filters stay): `rec.gf` is the text while the card is in. The import bus takes what matches from
--- its target; without a text it takes everything (AE2-U: an empty filter is none). The export bus goes through the network's
--- item keys that match, in turn (rec.glist, rebuilt when the network got new keys: net.kgen), at most MAX_FILTERS per visit
--- (MAX_FILTERS, the filters' count), each visit moving what its speed allows; without a text it exports nothing.
function M.bus_gf(rec)
	rec.gf = rec.gcard and rec.gtext or nil
	rec.all = IMPORTS[rec.kind] and ((rec.gcard and not rec.gtext)
		or (not rec.gcard and #(rec.filters or {}) + #(rec.ffilters or {}) == 0)) or nil
	rec.glist, rec.gkgen = nil, nil
end

--- the bus's group filter text ("" or nil clears it); the bus is visited again
function M.set_bus_gtext(entity, text)
	if not BUSES[kind(entity)] then return false end
	local rec = register(state(), entity)
	rec.gtext = N.GF.clean(text)
	M.bus_gf(rec)
	wake(entity.unit_number)
	return true
end

--- the network's item keys that match the export bus's text (sorted; rebuilt when the network got new keys); issue #413: with a
--- Fuzzy Card and no text, the keys of the filters' items in every quality
function M.gf_list(rec, net)
	if rec.glist and rec.gkgen == (net.kgen or 0) and rec.gknet == net.id then return rec.glist end
	local list, gf, names = {}, rec.gf, rec.fznames or {}
	for key in pairs(net.items) do
		if not N.is_fluid_key(key) and not key:find("#", 1, true) then
			local hit
			if gf then hit = N.GF.match(gf, key) else hit = names[(filter_item(key))] end
			if hit then list[#list + 1] = key end
		end
	end
	table.sort(list)
	rec.glist, rec.gkgen, rec.gknet = list, net.kgen or 0, net.id
	if (rec.gcur or 1) > #list then rec.gcur = 1 end
	return list
end

--- Issue #412: an export bus in pulse mode works once per rise of its connector's condition (AE2's "once per pulse")
function M.set_bus_pulse(entity, on)
	if kind(entity) ~= "export-bus" then return false end
	local rec = register(state(), entity)
	rec.pulse = on and true or nil
	Conn.ensure(entity)
	Conn.set_mode(entity.unit_number, rec.pulse, false)
	wake(entity.unit_number)
	return true
end

--- Issue #426: an export bus in craft only (AE2-U's `Settings.CRAFT_ONLY`) exports nothing from storage: with its Crafting Card
--- it crafts what its target can take, and the jobs hand the products to the target (without the card it exports as before)
function M.set_bus_craft_only(entity, on)
	if kind(entity) ~= "export-bus" then return false end
	local rec = register(state(), entity)
	rec.conly = on and true or nil
	wake(entity.unit_number)
	return true
end

--- Issue #412: the interface takes its rows from the circuit (`on`), or its own rows again
function M.set_interface_circuit(entity, on)
	if kind(entity) ~= "interface" then return false end
	local rec = register(state(), entity)
	rec.ccfg = on and true or nil
	Conn.ensure(entity)
	Conn.set_mode(entity.unit_number, false, rec.ccfg)
	wake(entity.unit_number)
	return true
end

--- { filters = keys, status, target }
function M.get_bus(entity)
	local s = storage.fork_me_io
	local rec = s and entity and entity.valid and s.recs[entity.unit_number]
	if not rec then return nil end
	local t = rec.target
	return { filters = { table.unpack(rec.keys or rec.filters) }, status = rec.status, target = t and t.valid and t.name or nil,
		gtext = rec.gtext, pulse = rec.pulse, conly = rec.conly }
end

--- one filter of a bus (the window's filter buttons): `key` nil clears it; the list stays packed
function M.set_bus_filter(entity, index, key)
	local s = state()
	if not BUSES[kind(entity)] then return false end
	local rec = register(s, entity)
	local current = rec.keys or rec.filters
	local list = {}
	for i = 1, KEPT_FILTERS do                                     -- (issue #413: the kept ones too)
		local v
		if i == index then v = key else v = current[i] end
		if v then list[#list + 1] = v end
	end
	return M.set_bus_filters(entity, list)
end

--- issue #413: the filters that apply to the bus now (9, more with Capacity Cards; the recipe paste)
function M.bus_filter_count(entity)
	local rec = bus_rec(entity)
	return rec and filters_of(rec) or MAX_FILTERS
end

--- issue #110: the card slots of a bus for its window (the inventory whose slots it shows, the clicks on them)
function M.interface_inventory(entity)
	local rec = iface_rec(entity)
	return rec and icards.inv_of(rec) or nil
end
function M.interface_card_click(entity, slot, cursor, inventory, shift) return icards.card_click(entity, slot, cursor, inventory, shift) end
function M.interface_shift_in(entity, stack) return icards.shift_in(entity, stack) end
function M.interface_sync(entity, back)
	local rec = iface_rec(entity)
	return rec ~= nil and icards.sync(rec, back)
end

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
	--- issue #413: the filters that apply (more with Capacity Cards), whether some are kept beyond them, the Fuzzy and Inverter Card
	b.kind, b.import, b.max = k, IMPORTS[k] == true, filters_of(rec)
	b.kept = #(rec.keys or {}) > b.max or nil
	b.fuzzy, b.inverted = rec.fz == true, rec.binv == true
	b.items, b.fluids = rec.t_inv ~= nil, rec.t_fluid == true
	b.tstat = rec.status == "temperature" and rec.tstat or nil      -- issue #159: { fluid, the network has, the target takes }
	b.fmix = rec.fmix and { rec.fmix[1], rec.fmix[2] } or nil       -- issue #161: { fluid, its temperatures in the network }
	--- issue #110: the card slots (the window shows them), the factor of the cards, the cards it waits for
	b.slots, b.accel = bus_rules(rec).slots, rec.accel or 1
	b.rate = Sched.setting("bus_items") * b.accel          -- items per second at most
	b.cards = {}
	for slot, name in pairs(rec.cards or {}) do b.cards[slot] = name end
	b.want = rec.want and cards.missing_cards(rec, rec.want) or nil
	b.gfilter = rec.gcard == true                          -- issue #363
	b.craft = rec.ccard and (rec.cstat or "idle") or nil   -- issue #411: the Crafting Card's last request
	b.pulse, b.off = rec.pulse == true, Conn.is_off(entity.unit_number) or nil   -- issue #412
	b.conly = rec.conly == true                            -- issue #426: craft only
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
--- (issue #412: "circuit", switched off by its connector's condition: woken by fork-me-connector.lua's check)
local NET_SIDE = { ["no-key"] = true, ["net-full"] = true, ["no-network"] = true, ["no-power"] = true, unset = true,
	circuit = true }

--- what the probe of a blocked block compares against: the items the source or the interface holds (one engine
--- call), plus the fluid of an interface's sides (not of one that does not look at them, `rec.sidle`: probe_work looks
--- at those at the idle limit, issue #313) or of the source's boxes. The second value of an interface: an import side
--- holds fluid that waits (issue #313).
local function probe_mark(rec)
	local e = rec.entity
	if rec.kind == "interface" then
		local n = N.bound(T.inventory(e, defines.inventory.chest)).get_item_count()
		local tanks, held = not rec.sidle and rec.tanks, false
		if tanks then
			local sides = rec.sides or {}
			for d = 1, #SIDES do
				local t = tanks[d]
				local setting = sides[d]
				if setting ~= "off" and t and t.valid then
					local f = T.fluidbox(t)[1]
					if f then
						n = n + math.floor(f.amount)
						--- (the safety net: an import side that waits for room or was not looked at; not one that feeds an
						--- export side, "loop", or holds what the network does not take, which a visit cannot change)
						local why = rec.fstatus and rec.fstatus[d]
						if type(setting) ~= "number" and f.amount > EPS and (why == nil or why == "import" or why == "full") then
							held = true
						end
					end
				end
			end
		end
		return n, held
	end
	local t = rec.target
	if not (t and t.valid) then return 0 end
	local n = 0
	if rec.t_inv then
		local inv = T.inventory(t, rec.t_inv)
		if inv then n = N.bound(inv).get_item_count() end
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
	--- issue #411: a crafting start that waited for its retry is tried again when it is due
	if rec.cnext and game.tick >= rec.cnext then return true end
	if b == "crafting" then return false end
	if b == "no-target" then return target_of(rec) ~= nil end
	if rec.kind == "interface" then
		local mark, held = probe_mark(rec)
		if mark ~= rec.seen then return true end
		--- issue #313: an interface that does not look at its sides (nothing was connected) looks at its tanks at the idle
		--- limit: fluid that came without an event (a machine's fluid box connecting with its recipe, a rotated pump) wakes it
		if rec.sidle then
			if game.tick - (rec.sidle == true and 0 or rec.sidle) >= tick_limit then
				if tanks_hold(rec) then return true end
				rec.sidle = game.tick
			end
			return false
		end
		--- issue #313: the safety net: fluid waits in an import side, so it is visited at least at the idle limit even when
		--- no wake came (room that appeared without one: a partition or a priority changed, ...); a missed wake costs
		--- seconds, not ever
		return held and game.tick - (rec.last or 0) >= tick_limit
	end
	if b == "empty" then return probe_mark(rec) ~= rec.seen end
	--- issue #363: an export bus with a group filter waits for no key of its own: a key new in the network, or the idle limit
	--- (issue #413: the same with a Fuzzy Card)
	if (rec.gf or rec.fz) and not IMPORTS[rec.kind] then
		local net = N.network_of(rec.entity)
		return (net ~= nil and (net.kgen or 0) ~= rec.gkgen) or game.tick - (rec.last or 0) >= tick_limit
	end
	--- "full": does the export target take something again?
	local t = rec.target
	if not (t and t.valid) then return true end
	if rec.t_inv then
		local inv = T.inventory(t, rec.t_inv)
		if inv then
			local machine = T.SLOTTED[t.type]
			local lab = t.type == "lab"
			local recipe
			for _, key in ipairs(rec.filters) do
				local name, q = filter_item(key)
				if prototypes.item[name] then
					local item = name
					if q ~= "normal" then
						Q_COUNT.name, Q_COUNT.quality = name, q
						item = Q_COUNT
					end
					if machine then
						--- (a lab takes only the packs it uses: a filter it refuses is no work, however empty its slot)
						local c = inv.get_item_count(item)
						if c < stack_of(name) then
							if not lab or inv.can_insert(item) then return true end
						elseif recipe ~= false then
							local level
							level, recipe = machine_level(t, name, recipe)   -- (issue #382: two crafts of its recipe)
							if c < level then return true end
						end
					elseif inv.can_insert(item) then
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

--- one scheduled visit: the block moves what its speed and the ticks since its last visit allow, and is due again
--- when the buffer on its other side needs it (the headroom rule); a block with nothing to do is probed or parked
local function visit(rec, unit, fallback)
	local s = storage.fork_me_io
	local e = rec.entity
	if not e.valid then
		destroy_tanks(rec)                    -- an interface removed without an event
		if BUSES[rec.kind] then cards.detach(rec) end        -- issue #110: a bus's cards are spilled where it stood
		if rec.kind == "interface" then icards.detach(rec) end   -- issue #196: an interface's cards are spilled where it stood
		drop(s, unit)                         -- (its shortfalls go too)
		return
	end
	local now = game.tick
	local dt = now - (rec.last or (now - MIN_INTERVAL))
	rec.last = now
	local moved, full, nextiv, block, starved, net, time
	if rec.kind == "interface" then
		moved, full, nextiv, block, starved, net, time = M.interface_step(rec, dt, unit)
	else
		moved, full, nextiv, block, starved, net, time = M.bus_step(rec, dt, unit)
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

--- Issue #420: the fallback of lever 10: the next interface of the list (s.tcur, in storage) looks at its sides again; a
--- tank that was made or removed wakes it
local function check_tanks(s)
	local list = s.list
	local n = #list
	for _ = 1, math.min(n, 16) do                        -- (the buses in the list are skipped, 16 entries at most)
		local i = s.tcur or 1
		if i > n then i = 1 end
		s.tcur = i + 1
		local unit = list[i]
		local rec = s.recs[unit]
		if rec and rec.kind == "interface" and rec.tanks and rec.entity.valid then
			if refit_tanks(rec) then wake(unit) end
			return
		end
	end
end

--- every tick (control.lua): the probes that are due, then the interfaces and buses that are due, between the
--- settings "at least" and "at most"
function M.on_tick(tick)
	local s = storage.fork_me_io
	if not s then return end
	tick_limit = idle_limit(s)
	if tick % TANK_CHECK_TICKS == 0 then check_tanks(s) end
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
		--- issue #196: the cards first (from the network, never from nothing), so the rows they give room for are there
		if type(t) == "table" and type(t.cards) == "table" and #t.cards > 0 then icards.want_cards(entity, t.cards, nil) end
		if config then
			M.set_interface_config(entity, config, sides or {})
			if type(t) == "table" and t.priority then M.set_interface_priority(entity, t.priority) end
			if type(t) == "table" and t.circuit then M.set_interface_circuit(entity, true) end     -- (issue #412)
		elseif source and source.valid and kind(source) == "interface" then
			local from_rec = iface_rec(source)
			local list = from_rec and icards.card_list(from_rec)
			if list then icards.want_cards(entity, list, nil) end
			M.set_interface_config(entity, M.get_interface_config(source), M.get_interface_sides(source))
			M.set_interface_priority(entity, M.get_interface_priority(source))
			if from_rec and from_rec.ccfg then M.set_interface_circuit(entity, true) end              -- (issue #412)
		end
		clear_filters(entity.get_inventory(defines.inventory.chest))      -- a blueprint before R3 may carry slot filters
	else
		local t = type(tags) == "table" and tags[BUS_TAG] or nil
		if type(t) == "table" then
			M.set_bus_filters(entity, t.filters)
			if t.gtext then M.set_bus_gtext(entity, t.gtext) end               -- (issue #363)
			if t.pulse then M.set_bus_pulse(entity, true) end                  -- (issue #412)
			if t.conly then M.set_bus_craft_only(entity, true) end             -- (issue #426)
			if type(t.cards) == "table" and #t.cards > 0 then cards.want_cards(entity, t.cards, nil) end
		elseif source and source.valid and kind(source) == k then
			local from = M.get_bus(source)
			M.set_bus_filters(entity, from and from.filters or {})
			if from and from.gtext then M.set_bus_gtext(entity, from.gtext) end
			if from and from.pulse then M.set_bus_pulse(entity, true) end      -- (issue #412)
			if from and from.conly then M.set_bus_craft_only(entity, true) end -- (issue #426)
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
				if rec.tanks then
					--- issue #420: a side that the entity stands beside gets its tank (kept when it connects)
					local p = i.position
					for d = 1, #SIDES do
						local x, y = p.x + NEAR[d][1], p.y + NEAR[d][2]
						if not rec.tanks[d] and x > b.left_top.x and x < b.right_bottom.x and y > b.left_top.y
							and y < b.right_bottom.y then fit_side(rec, d) end
					end
					refresh_connections(rec)
					wake(i.unit_number)
				end
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
		--- issue #196: the Interface Capacity Cards of a mined interface go into the buffer, those of a destroyed one onto the ground
		if type(mined) == "userdata" or type(mined) == "table" then icards.give_cards(rec, mined) else icards.spill_cards(rec) end
		icards.detach(rec)
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
	elseif s and entity and entity.valid and T.has_fluid_boxes(entity) then
		M.wake_near(entity)                                  -- (issue #420: a rotated pump may face an interface's side now)
	end
end

--- issue #420: a machine set up in its window or by a paste may have a fluid box beside an interface's side now (a recipe
--- with a fluid); its interfaces look at that side
function M.fluid_entity_changed(entity)
	if storage.fork_me_io and entity and entity.valid and not kind(entity) and entity.name ~= T.SIDE
		and T.has_fluid_boxes(entity) then
		M.wake_near(entity)
	end
end

function M.on_entity_settings_pasted(event)
	local src, dst = event.source, event.destination
	M.fluid_entity_changed(dst)                              -- (issue #420: a recipe pasted onto a machine)
	if not (src and src.valid and dst and dst.valid and src.name == dst.name) then return end
	local k = kind(src)
	if k == "interface" then
		--- issue #196: the source's Interface Capacity Cards are what the destination is to have (from the player, then the network)
		local from_rec = iface_rec(src)
		if from_rec then
			local player = event.player_index and game.get_player(event.player_index) or nil
			icards.want_cards(dst, from_rec.want and { table.unpack(from_rec.want) } or icards.card_list(from_rec) or {}, player)
		end
		M.set_interface_config(dst, M.get_interface_config(src), M.get_interface_sides(src))
		M.set_interface_priority(dst, M.get_interface_priority(src))
		M.set_interface_circuit(dst, from_rec and from_rec.ccfg)                            -- (issue #412)
	elseif BUSES[k] then
		local from = M.get_bus(src)
		M.set_bus_filters(dst, from and from.filters or {})
		M.set_bus_gtext(dst, from and from.gtext or "")                    -- (issue #363)
		if k == "export-bus" then
			M.set_bus_pulse(dst, from and from.pulse)                                -- (issue #412)
			M.set_bus_craft_only(dst, from and from.conly)                           -- (issue #426)
		end
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
			local rec = iface_rec(entity)
			local list = rec and (rec.want and { table.unpack(rec.want) } or icards.card_list(rec))
			if next(config) or next(sides) or p ~= 0 or list or (rec and rec.ccfg) then
				bp.set_blueprint_entity_tag(index, IFACE_TAG, M.interface_tag(config, sides, p, list, rec and rec.ccfg))
			end
		elseif BUSES[k] then
			local b = M.get_bus(entity)
			local rec = bus_rec(entity)
			local list = rec and (rec.want and { table.unpack(rec.want) } or cards.card_list(rec))
			if b and (#b.filters > 0 or list or b.gtext or b.pulse or b.conly) then
				bp.set_blueprint_entity_tag(index, BUS_TAG, { filters = b.filters, cards = list, gtext = b.gtext, pulse = b.pulse,
					conly = b.conly })                                             -- (issue #426: craft only)
			end
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
				if o then rec.gtext, rec.gcard = o.gtext, o.gcard M.bus_gf(rec) end                                       -- issue #363
			end
			if rec.kind == "interface" then
				if o then rec.inv, rec.cards, rec.want, rec.where, rec.nrows = o.inv, o.cards, o.want, o.where, o.nrows end   -- issue #196
				if o and o.config then split_rows(rec, clean_config(o.config)) end
				if o and o.extra then
					local all = {}
					for _, rows in ipairs({ rec.config or {}, o.extra }) do for i, c in pairs(rows) do all[i] = c end end
					split_rows(rec, clean_config(all))
				end
				if o and o.priority then
					rec.priority = o.priority
					s.prio[e.unit_number] = o.priority
				end
				rec.sides = clean_sides(o and o.sides or {}, rec.config or {})
				--- (issue #420: the tanks are found on the tile again, those that are not needed go: an older save had four)
				rec.tanks = nil
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
	--- issue #420 (tests): the interface looks at its sides now (the fallback's look); true when a tank was made or removed
	refit_tanks = function(entity)
		if kind(entity) ~= "interface" then return nil end
		return refit_tanks(register(state(), entity))
	end,
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
	idle_limit = function() return storage.fork_me_io and idle_limit(storage.fork_me_io) or nil end,   -- (issue #313 tests)
	set_bus_filters = function(entity, filters) return M.set_bus_filters(entity, filters) end,
	--- issue #412: the export bus's pulse mode, the interface's rows from the circuit
	set_bus_pulse = function(entity, on) return M.set_bus_pulse(entity, on) end,
	--- issue #426: the export bus's craft only
	set_bus_craft_only = function(entity, on) return M.set_bus_craft_only(entity, on) end,
	set_interface_circuit = function(entity, on) return M.set_interface_circuit(entity, on) end,
	--- issue #363: the Group Filter Card's text ("" clears it)
	set_bus_gtext = function(entity, text) return M.set_bus_gtext(entity, text) end,
	--- issue #110: the card slots of a bus (what the window's clicks do; `want`: a list of names)
	bus_inventory = function(entity) local rec = bus_rec(entity) return rec and cards.inv_of(rec) or nil end,
	--- issue #196: the card slots of an interface (the window's functions and the tests')
	interface_inventory = function(entity) return M.interface_inventory(entity) end,
	interface_card_click = function(entity, slot, cursor, inventory, shift) return icards.card_click(entity, slot, cursor, inventory, shift) end,
	interface_want_cards = function(entity, want, player_index)
		return icards.want_cards(entity, want, player_index and game.get_player(player_index) or nil)
	end,
	interface_sync = function(entity, back) return M.interface_sync(entity, back) end,
	row_capacity = function(entity) return M.row_capacity(entity) end,
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
