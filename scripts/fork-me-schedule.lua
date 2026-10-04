--------------------------------------------------------------------------------
--- ME NETWORK: THE SCHEDULER (issue #5, issue #38 levers 1 and 2; docs/PERFORMANCE.md, docs/ME-REWORK.md)
---   * Every periodic visit (interfaces and buses, storage buses, level maintainers, circuit interfaces) is due at
---     a tick: a queue keeps, per tick, the units due then (`l.due[tick] = { unit, ... }`) and the record keeps its
---     due tick (`rec.due`). One on_tick handler (control.lua) runs each queue; units that do not fit into the
---     tick's budget wait in the backlog, first in first out, before the units of later ticks.
---   * When a unit is due is the module's decision (issue #38): a block with work is due when the buffer on its
---     other side would run full or empty (the headroom rule of fork-me-io.lua), not after a fixed period; a block
---     blocked on its target's side (source empty, target full, no target) is **probed** instead of visited (one
---     cheap engine call at the idle limit, the probe list `q.sl`); a block blocked on the network's side (its key
---     absent, the network full, no network, no power) is **parked**: not visited, woken by the network (N.wait_for,
---     N.wait_below, N.wait_usable, the change hooks), with one slow fallback visit about once a minute (a fallback
---     that finds work is a missed wake, counted). A wake puts a unit at the front of the busy list
---     (`q.front`), before the backlog, wherever it was; a unit whose other side ran out (`rec.starve`) goes to the
---     front when it comes due, too.
---   * The budget of a tick is what is due (the front, the backlog and the units due now), at least the floor and
---     at most the ceiling (map settings "at least" / "at most"). The sleepers' share of it, the probes, is capped at
---     the floor whatever the ceiling is, and the sum of visits and probes stays within the floor while the busy list
---     does not need more (they keep half of the floor when it does), so a network of sleepers never costs more per
---     tick than the budget of 0.3.0 did; the busy list gets the rest up to the ceiling. When the ceiling binds, the
---     earliest due come first. Counts, never measured time.
---   * A unit is in a list once per scheduling; an entry whose record says another tick or another list is stale
---     and skipped (a wake or a reschedule leaves the old entry behind instead of searching for it). The record
---     says where it is: `rec.due` (tick, BACKLOG, FRONT, nil while visited or parked), `rec.sq` (in the probe
---     list), `rec.inq` (the tag of the queue it is counted in; nil while parked), `rec.park` (why it is parked).
---   * Counters (`M.snapshot`): per list the visits, the units that came due, the backlog left at the end of each
---     tick, and the ticks between two visits of a unit by what the visit found (nothing to do, something, all it
---     was allowed to move). The record keeps its last visit tick (`rec.vis`); the counters live in this module,
---     never in storage: they differ between the peers of a game and decide nothing, the benchmark and the in-game
---     diagnostic read them. Reset on load.
--- State: the queues live in the modules' own storage tables; the settings are read once per load and on change.
--------------------------------------------------------------------------------

local M = {}

--- runtime-global settings (settings.lua): read once per load and when a player changes them. The visits per tick
--- of a kind of block have a floor (`io`, ...; what a tick visits at least while units wait) and a ceiling
--- (`io_max`, ...; what it visits at most, whatever is due).
local SETTINGS = {
	io = "me-network-io-visits-per-tick",
	io_max = "me-network-io-visits-per-tick-max",
	storage_bus = "me-network-storage-bus-visits-per-tick",
	storage_bus_max = "me-network-storage-bus-visits-per-tick-max",
	maintainer = "me-network-maintainer-checks-per-tick",
	maintainer_max = "me-network-maintainer-checks-per-tick-max",
	circuit = "me-network-circuit-updates-per-second",
	jobs = "me-network-crafting-jobs-per-tick",
	jobs_max = "me-network-crafting-jobs-per-tick-max",
	bus_items = "me-network-bus-items-per-second",
	bus_fluid = "me-network-bus-fluid-per-second",
	idle = "me-network-idle-limit",
	storage_bus_idle = "me-network-storage-bus-idle-limit",
}
M.DEFAULTS = { io = 16, io_max = 32, storage_bus = 8, storage_bus_max = 24, maintainer = 4, maintainer_max = 12,
	circuit = 10, jobs = 1, jobs_max = 2, bus_items = 256, bus_fluid = 4000, idle = 300, storage_bus_idle = 120 }
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
--- counters (issue #38): per list name { visits, ticks, due, back_sum, back_max, hist = { [class + 1] = { [dt] = n } } }
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

--- a visit of a unit of `name` arrived at an empty target or a full source (its other side had run out)
function M.starved(name)
	local st = stats[name] or stat(name)
	st.starved = (st.starved or 0) + 1
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

--- the counters as plain numbers: per list name the visits, ticks run, units that came due, the average and the
--- longest backlog at the end of a tick, and the interval statistics (ticks) by class (idle, partial, full)
function M.snapshot()
	local out = {}
	for name, st in pairs(stats) do
		out[name] = { visits = st.visits, ticks = st.ticks, due = st.due, backlog_max = st.back_max, starved = st.starved or 0, missed = st.missed or 0, wakes = st.wakes or 0,
			backlog_avg = st.ticks > 0 and st.back_sum / st.ticks or 0,
			idle = percentiles(st.hist[1]), partial = percentiles(st.hist[2]), full = percentiles(st.hist[3]) }
	end
	return out
end

function M.reset_stats()
	for name in pairs(stats) do stats[name] = nil end
end

--------------------------------------------------------------------------------
--- the queue
--------------------------------------------------------------------------------

local BACKLOG, FRONT = -1, -2
M.BACKLOG, M.FRONT = BACKLOG, FRONT

local function new_list() return { due = {}, back = {}, head = 1, n = 0 } end

--- a new queue; `tag`: its name in the records (unique per queue of the mod)
function M.new(tag)
	local q = new_list()
	q.front, q.fhead, q.sl, q.tag = {}, 1, new_list(), tag
	return q
end

--- A queue of 0.3.0 (one list, no counts) gets its front and probe lists and its tag; `recs`: the records the
--- module has scheduled in it (every one counts as busy until its next visit says otherwise)
function M.upgrade(q, recs, tag)
	if q.sl then return q end
	q.front, q.fhead, q.sl, q.tag = q.front or {}, q.fhead or 1, new_list(), tag
	q.n = 0
	for _, rec in pairs(recs) do
		if rec.due ~= nil then
			rec.inq, rec.sq = tag, nil
			q.n = q.n + 1
		end
	end
	return q
end

local function list_of(q, rec) return rec.sq and q.sl or q end

--- the accounting when `rec` is scheduled in list `l` of `q`
local function enter(q, rec, l)
	if rec.inq == q.tag then
		local old = list_of(q, rec)
		if old == l then return end
		old.n = old.n - 1
	else
		rec.inq = q.tag                               -- (a record counted in another queue was forgotten there)
	end
	l.n = l.n + 1
	rec.sq = (l == q.sl) or nil
	rec.park = nil
end

--- `unit` (record `rec`) is due at `tick` (at least the next tick): a visit, or a probe (`probe`)
function M.at(q, rec, unit, tick, probe)
	local now = game.tick
	if tick <= now then tick = now + 1 end
	local l = probe and q.sl or q
	enter(q, rec, l)
	rec.due = tick
	local list = l.due[tick]
	if not list then
		list = {}
		l.due[tick] = list
	end
	list[#list + 1] = unit
end

--- The tick for a unit that wants to come back in about `iv` ticks, anywhere from `early` ticks sooner to `late`
--- ticks later: of four ticks in that window, picked by a hash of the unit number, the one with the fewest units
--- already due (the lists of `q` are state, so every peer picks alike). Blocks of one interval then drift apart and
--- the load per tick stays flat, also for the consecutive units of one blueprint. `probe`: the probe list.
local EMPTY = {}
function M.slot(q, probe, unit, now, iv, early, late)
	if early + late <= 0 then return now + iv end
	local due = (probe and q.sl or q).due
	local lo, span = now + iv - early, early + late + 1
	local h = (unit * 2654435761) % 4294967296
	local best, load = lo, math.huge
	for j = 0, 3 do
		local t = lo + math.floor(((h + j * 1640531527) % 4294967296) / 4294967296 * span)
		local n = #(due[t] or EMPTY)
		if n < load then best, load = t, n end
	end
	return best
end

--- a wake: the unit goes to the front of the busy list (before the backlog), from wherever it was, parked or not;
--- a unit that waits there already, or in the busy backlog, is as early as it can be. (`tick` is accepted for the
--- callers of 0.3.0 and ignored: a wake is always the next tick.)
function M.wake(q, rec, unit, tick)
	if not rec.sq and rec.inq == q.tag and (rec.due == FRONT or rec.due == BACKLOG) then return end
	local st = stats[q.tag] or stat(q.tag)
	st.wakes = (st.wakes or 0) + 1                       -- (counted: a wake that did something)
	enter(q, rec, q)
	rec.due = FRONT
	q.front[#q.front + 1] = unit
end

--- `rec` leaves the scheduler (its block is gone, or it moves to another queue)
function M.forget(q, rec)
	rec.park = nil
	if rec.inq ~= q.tag then return end
	local l = list_of(q, rec)
	l.n = l.n - 1
	rec.inq, rec.sq, rec.due = nil, nil, nil
end

--- An array of units with O(1) removal: the last unit takes the removed one's place. `pos` (unit -> index) is kept
--- next to the array; if it is missing or does not match (a save without it) it is built again, once.
function M.list_remove(list, pos, unit)
	local i = pos and pos[unit]
	if not (i and list[i] == unit) then
		if not pos then
			for k = #list, 1, -1 do if list[k] == unit then table.remove(list, k) end end
			return
		end
		for k in pairs(pos) do pos[k] = nil end
		for k, u in ipairs(list) do pos[u] = k end
		i = pos[unit]
		if not i then return end
	end
	local last = #list
	local moved = list[last]
	list[i] = moved
	pos[moved] = i
	list[last] = nil
	pos[unit] = nil
end

--- `rec` is parked for `reason`: not visited, not probed; woken by the network (or by its module) when what it waits
--- for happens. A wake that is missed must not stand a block still for ever, silently: a parked block is in the probe
--- list with one slow fallback visit, about once in PARK_FALLBACK ticks, spread by Sched.slot (the module's probe
--- function recognises it by `rec.park` and visits it fully). A fallback visit that finds work is a missed wake and is
--- counted (M.missed): it must be 0 in the tests and the benchmark scenes.
M.PARK_FALLBACK = 3600
function M.park(q, rec, unit, reason)
	M.forget(q, rec)
	local now = game.tick
	local spread = math.floor(M.PARK_FALLBACK / 6)
	M.at(q, rec, unit, M.slot(q, true, unit, now, M.PARK_FALLBACK, spread, spread), true)
	rec.park = reason
end

--- a fallback visit of a parked unit of `name` found work: its wake was missed
function M.missed(name)
	local st = stats[name] or stat(name)
	st.missed = (st.missed or 0) + 1
end

--- the units of `l` due at `tick` join its backlog (a starved unit of the busy list joins the front)
local function arrive(q, l, tick, rec_of, st)
	local list = l.due[tick]
	if not list then return end
	l.due[tick] = nil
	st.due = st.due + #list
	local back, front = l.back, l.front
	for i = 1, #list do
		local unit = list[i]
		local rec = rec_of(unit)
		if rec and rec.due == tick and list_of(q, rec) == l then
			if front and rec.starve then
				rec.due = FRONT
				front[#front + 1] = unit
			else
				rec.due = BACKLOG
				back[#back + 1] = unit
			end
		end
	end
end

--- one visit (or probe) of `unit` with its counters
local function visit_one(rec, unit, tick, visit, st)
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

--- the visited front of the list `back` with `head` is dropped now and then
local function compact(l, field, headfield, head)
	local back = l[field]
	local n = #back
	if head > n then
		l[field], l[headfield] = {}, 1
	elseif head > 1024 and head > n / 2 then
		local rest = {}
		for i = head, n do rest[#rest + 1] = back[i] end
		l[field], l[headfield] = rest, 1
	else
		l[headfield] = head
	end
end

--- up to `budget` visits from the list `field` of `l` (`state`: the record state its entries carry); returns them
local function drain(q, l, field, headfield, state, tick, budget, rec_of, visit, st, front0)
	local back = l[field]
	local head, n = l[headfield], #back
	local done = 0
	--- `front0`: the length of the front list before this drain; what it grows by are units this drain woke (a probe that
	--- finds work): they count against the budget too
	while head <= n and done + (front0 and (#q.front - q.fhead + 1 - front0) or 0) < budget do
		local unit = back[head]
		back[head] = false
		head = head + 1
		local rec = rec_of(unit)
		if rec and rec.due == state and list_of(q, rec) == l then
			done = done + 1
			visit_one(rec, unit, tick, visit, st)
		end
	end
	compact(l, field, headfield, head)
	return done
end

local function waiting(l)
	local n = #l.back - l.head + 1
	if l.front then n = n + #l.front - l.fhead + 1 end
	return n < 0 and 0 or n
end

--- Run the queue: the probes that are due (`probe(rec, unit)`: one cheap check; it wakes the unit or probes it again
--- later, and returns the class of the counters), then the busy list: the woken and starved units first, then the
--- backlog with the units due at `tick` appended, at most the budget: what is due, at least `floor`, at most
--- `ceiling`. `rec_of(unit)` gives the record (nil: gone), `visit(rec, unit)` visits it (and schedules it again
--- with M.at, probes, parks or forgets it) and returns what it found (the class of the counters, nil: not
--- counted). `name` is the queue's name in the counters (the probe list is `name .. "_probe"`). The probes of a
--- tick are at most `floor`; the busy list gets `ceiling` less the probes done, at least `floor`. Returns the visits.
function M.run(q, tick, floor, ceiling, rec_of, visit, probe, name)
	name = name or "?"
	if not q.sl then                                   -- (a queue of an earlier version its module did not upgrade)
		q.front, q.fhead, q.sl, q.n, q.tag = q.front or {}, q.fhead or 1, new_list(), q.n or 0, q.tag or name
	end
	local st = stats[name] or stat(name)
	st.ticks = st.ticks + 1
	--- the probes first: a probe that finds work wakes its unit into the front, visited in this very tick
	local sl = q.sl
	local ss = stats[name .. "_probe"] or stat(name .. "_probe")
	ss.ticks = ss.ticks + 1
	arrive(q, sl, tick, rec_of, ss)
	floor = floor or 0
	ceiling = math.max(ceiling or floor, floor)
	--- what is due on the busy list decides the probes' share: the sum of visits and probes stays within the floor
	--- while the busy list does not need more (a probe that wakes its block counts for two), and the probes keep half
	--- of the floor when it does (they wait longer, they are never starved)
	arrive(q, q, tick, rec_of, st)
	local need = math.min(ceiling, waiting(q))
	local pcap = math.max(math.ceil(floor / 2), floor - need)
	if pcap > floor then pcap = floor end
	local probed = drain(q, sl, "back", "head", BACKLOG, tick, pcap, rec_of, probe or visit, ss, #q.front - q.fhead + 1)
	ss.visits = ss.visits + probed
	local pleft = waiting(sl)
	ss.back_sum = ss.back_sum + pleft
	if pleft > ss.back_max then ss.back_max = pleft end
	--- the busy list: what is due this tick (and what the probes woke), between the floor and the ceiling
	local due = waiting(q)
	local budget = math.max(floor, math.min(ceiling - probed, due))
	local done = drain(q, q, "front", "fhead", FRONT, tick, budget, rec_of, visit, st)
	done = done + drain(q, q, "back", "head", BACKLOG, tick, budget - done, rec_of, visit, st)
	local left = waiting(q)
	st.visits = st.visits + done
	st.back_sum = st.back_sum + left
	if left > st.back_max then st.back_max = left end
	return done + probed
end

--- the steps or visits of this tick for `n` units that each want one every `every` ticks, between the settings
function M.load_budget(n, every, floor, ceiling)
	return math.max(floor, math.min(math.max(ceiling or floor, floor), math.ceil(n / every)))
end

--- a budget given per second, as visits in this tick (spread evenly: the same ticks on every peer)
function M.per_second(rate, tick)
	return math.floor(tick * rate / 60) - math.floor((tick - 1) * rate / 60)
end

--- the units waiting in the busy backlog of `q` now (the front is not a backlog: woken this tick, served next
--- tick), and in its probe backlog
function M.backlog(q)
	local n = #q.back - q.head + 1
	return n < 0 and 0 or n, q.sl and waiting(q.sl) or 0
end

--- the units scheduled in the busy and in the probe list of `q`
function M.counts(q)
	return q.n or 0, q.sl and q.sl.n or 0
end

--- the number of units in the queue's lists (stale entries included; tests)
function M.size(q)
	local n = waiting(q) + (q.sl and waiting(q.sl) or 0)
	for _, list in pairs(q.due) do n = n + #list end
	if q.sl then for _, list in pairs(q.sl.due) do n = n + #list end end
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

--- The next visit from the headroom on the other side (issue #38): `time` is the ticks until the buffer there runs
--- full or empty at the rate this visit saw (math.huge when nothing moves), `full` whether the block moved all its
--- speed allowed (then the catch-up covers the wait and the headroom time itself is the interval, else about half
--- of it, so the visit comes before the buffer runs out; `share`: the block's own share, learned by M.learn). Between
--- `min` and `max` ticks.
--- The share a block waits, learned from what its visits find (issue #38, lever 3): it starts at half of the headroom
--- time, grows by SHARE_STEP after every visit that found its other side served (up to SHARE_MAX) and falls back to
--- half at once after a visit that arrived at an empty target or a full source. Fewer visits for a steady buffer, the
--- margin back as soon as the buffer was too tight. State of the record (`rec.sh`), the same on every peer.
function M.learn(rec, starved)
	local sh = rec.sh or M.SHARE_MIN
	if starved then
		rec.sh = M.SHARE_MIN
	elseif sh < M.SHARE_MAX then
		rec.sh = math.min(M.SHARE_MAX, sh + M.SHARE_STEP)
	end
end

--- (the headroom rule itself)
local HEADROOM_SHARE = 0.5
M.SHARE_MIN, M.SHARE_MAX, M.SHARE_STEP = HEADROOM_SHARE, 0.85, 0.05
function M.headroom(time, full, min, max, share)
	if not time or time ~= time or time >= max then return max end
	local t = full and time or time * (share or HEADROOM_SHARE)
	if t > max then return max end
	if t < min then return min end
	return math.floor(t)
end

return M
