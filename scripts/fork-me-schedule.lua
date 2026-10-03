--------------------------------------------------------------------------------
--- ME NETWORK: THE SCHEDULER (issue #5; docs/PERFORMANCE.md, docs/ME-REWORK.md "Tick budget")
---   * Every periodic visit (interfaces and buses, storage buses, level maintainers, circuit interfaces, provider
---     rescans) is due at a tick: a queue keeps, per tick, the units due then (`q.due[tick] = { unit, ... }`) and the
---     record keeps its due tick (`rec.due`). One on_tick handler (control.lua) runs each queue with its budget of
---     visits per tick; units that do not fit move to the next tick, in order. So no step does all its work in one
---     tick, and an idle unit costs nothing until it is due.
---   * A unit is in a list once per scheduling; an entry whose record says another tick is stale and skipped (a wake
---     or a reschedule leaves the old entry behind instead of searching for it). Units that were due but did not fit
---     wait in the backlog, first in first out, before the units of the next ticks.
---   * Budgets are counts of visits (runtime mod settings, the same for every player), never measured time.
---   * Counters (issue #38, `M.snapshot`): per queue the visits, the units that came due, the backlog left at the end
---     of each tick, and the ticks between two visits of a unit by what the visit found (nothing to do, something,
---     all it was allowed to move). The record keeps its last visit tick (`rec.vis`); the counters live in this
---     module, never in storage: they describe this peer's run and decide nothing, the benchmark and the in-game
---     diagnostic read them. Reset on load.
--- State: the queues live in the modules' own storage tables; the settings are read once per load and on change.
--------------------------------------------------------------------------------

local M = {}

--- runtime-global settings (settings.lua): read once per load and when a player changes them
local SETTINGS = {
	io = "me-network-io-visits-per-tick",
	storage_bus = "me-network-storage-bus-visits-per-tick",
	maintainer = "me-network-maintainer-checks-per-tick",
	circuit = "me-network-circuit-updates-per-second",
	jobs = "me-network-crafting-jobs-per-tick",
	bus_items = "me-network-bus-items-per-second",
	bus_fluid = "me-network-bus-fluid-per-second",
	idle = "me-network-idle-limit",
	storage_bus_idle = "me-network-storage-bus-idle-limit",
}
M.DEFAULTS = { io = 16, storage_bus = 8, maintainer = 4, circuit = 10, jobs = 1, bus_items = 256, bus_fluid = 4000,
	idle = 300, storage_bus_idle = 120 }
local values

function M.setting(key)
	if not values then
		values = {}
		for k, name in pairs(SETTINGS) do
			local s = settings.global[name]
			values[k] = s and s.value or M.DEFAULTS[k]
		end
	end
	return values[key]
end

function M.on_setting_changed() values = nil end

--------------------------------------------------------------------------------
--- counters (issue #38): per queue name { visits, ticks, due, back_sum, back_max, hist = { [class + 1] = { [dt] = n } } }
--- with class 0: the visit found nothing to do, 1: it moved something, 2: it moved all it was allowed to
--------------------------------------------------------------------------------

local stats = {}
M.stats = stats

local function stat(name)
	local st = stats[name]
	if not st then
		st = { visits = 0, ticks = 0, due = 0, back_sum = 0, back_max = 0, hist = { {}, {}, {} } }
		stats[name] = st
	end
	return st
end

--- one interval sample of `dt` ticks for a unit of `name` whose visit found `class` (units outside the queues: jobs)
function M.sample(name, dt, class)
	local h = (stats[name] or stat(name)).hist[(class or 0) + 1]
	h[dt] = (h[dt] or 0) + 1
end

local function percentiles(h)
	local keys, n = {}, 0
	for dt, c in pairs(h) do
		keys[#keys + 1] = dt
		n = n + c
	end
	if n == 0 then return { n = 0 } end
	table.sort(keys)
	local sum, acc, med, p99 = 0, 0, nil, nil
	for _, dt in ipairs(keys) do
		local c = h[dt]
		sum = sum + dt * c
		acc = acc + c
		if not med and acc * 2 >= n then med = dt end
		if not p99 and acc * 100 >= n * 99 then p99 = dt end
	end
	return { n = n, avg = sum / n, median = med, p99 = p99, max = keys[#keys], min = keys[1] }
end

--- the counters as plain numbers: per queue name the visits, ticks run, units that came due, the average and the
--- longest backlog at the end of a tick, and the interval statistics (ticks) by class (idle, partial, full)
function M.snapshot()
	local out = {}
	for name, st in pairs(stats) do
		out[name] = { visits = st.visits, ticks = st.ticks, due = st.due, backlog_max = st.back_max,
			backlog_avg = st.ticks > 0 and st.back_sum / st.ticks or 0,
			idle = percentiles(st.hist[1]), partial = percentiles(st.hist[2]), full = percentiles(st.hist[3]) }
	end
	return out
end

function M.reset_stats()
	for name in pairs(stats) do stats[name] = nil end
end

--- the units waiting in the backlog of `q` now
function M.backlog(q)
	return q.back and (#q.back - (q.head or 1) + 1) or 0
end

--- a queue: { due = { [tick] = { unit, ... } }, back = { unit, ... }, head }. `back` is the backlog: units that were
--- due and did not fit into their tick's budget, in order (rec.due = BACKLOG while they wait there); they come first.
local BACKLOG = -1
function M.new() return { due = {}, back = {}, head = 1 } end

--- `unit` (record `rec`) is due at `tick` (at least the next tick)
function M.at(q, rec, unit, tick)
	local now = game.tick
	if tick <= now then tick = now + 1 end
	rec.due = tick
	local list = q.due[tick]
	if not list then
		list = {}
		q.due[tick] = list
	end
	list[#list + 1] = unit
end

--- due at `tick` unless it is due earlier already (a wake); a unit in the backlog is due as soon as possible anyway
function M.wake(q, rec, unit, tick)
	tick = math.max(tick or 0, game.tick + 1)
	if rec.due == BACKLOG then return end
	if rec.due and rec.due <= tick and rec.due > game.tick then return end
	M.at(q, rec, unit, tick)
end

--- Run the units due: first the backlog, then the units due at `tick`. `rec_of(unit)` gives the record (nil: gone),
--- `visit(rec, unit)` visits it (and schedules it again with M.at, or drops it) and returns what it found (the
--- class of the counters, nil: not counted). At most `budget` visits; the units due at `tick` that do not fit go to
--- the end of the backlog (each unit is moved once, whatever the backlog's length). `name` is the queue's name in
--- the counters. Returns the number of visits.
function M.run(q, tick, budget, rec_of, visit, name)
	local back = q.back
	if not back then                                   -- a queue of an earlier version of this module
		back = {}
		q.back, q.head = back, 1
	end
	local st = stats[name or "?"] or stat(name or "?")
	st.ticks = st.ticks + 1
	local list = q.due[tick]
	if list then
		q.due[tick] = nil
		st.due = st.due + #list
		for i = 1, #list do
			local unit = list[i]
			local rec = rec_of(unit)
			if rec and rec.due == tick then
				rec.due = BACKLOG
				back[#back + 1] = unit
			end
		end
	end
	local head, n = q.head, #back
	if head > n then return 0 end
	local done = 0
	while head <= n and done < budget do
		local unit = back[head]
		back[head] = false
		head = head + 1
		local rec = rec_of(unit)
		if rec and rec.due == BACKLOG then
			done = done + 1
			rec.due = nil
			local last = rec.vis
			rec.vis = tick
			local class = visit(rec, unit)
			if class and last then
				local h = st.hist[class + 1]
				local dt = tick - last
				h[dt] = (h[dt] or 0) + 1
			end
		end
	end
	local left = n - head + 1
	st.visits = st.visits + done
	st.back_sum = st.back_sum + left
	if left > st.back_max then st.back_max = left end
	if head > n then
		q.back, q.head = {}, 1
	elseif head > 1024 and head > n / 2 then             -- drop the visited front now and then
		local rest = {}
		for i = head, n do rest[#rest + 1] = back[i] end
		q.back, q.head = rest, 1
	else
		q.head = head
	end
	return done
end

--- a budget given per second, as visits in this tick (spread evenly: the same ticks on every peer)
function M.per_second(rate, tick)
	return math.floor(tick * rate / 60) - math.floor((tick - 1) * rate / 60)
end

--- the number of units in the queue's lists (stale entries included; tests)
function M.size(q)
	local n = #(q.back or {}) - (q.head or 1) + 1
	for _, list in pairs(q.due) do n = n + #list end
	return n
end

--- The idle limit for `n` units: the setting, but never longer than the round robin of 0.2.0 took to come back to
--- a unit (`per_tick` units per tick then), so a small network reacts at least as fast as before
function M.idle_limit(setting, n, per_tick, min)
	return math.max(min, math.min(setting, math.ceil(n / per_tick)))
end

--- the next interval of a unit after a visit: short while it works (`full`: it moved all it was allowed to),
--- growing while it moves little, doubling up to `idle` while it has nothing to do
function M.interval(iv, moved, full, min, active_max, idle)
	iv = math.max(iv or min, min)
	if moved > 0 then
		if full then return min end
		return math.min(math.floor(iv * 1.5), math.max(active_max, min))
	end
	return math.min(iv * 2, idle)
end

return M
