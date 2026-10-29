--------------------------------------------------------------------------------
--- ME NETWORK: THE ME LOGISTIC INTERFACE (me-network issue #531, the second package of the crossover "me-network x logistic
--- network"; not in AE2; prototypes/network.lua, docs/AE2.md "ME Logistic Interface")
---   * A 1x1 ME block (4 kW through the controller) with three hidden logistic chests on its tile, members of the vanilla
---     logistic network whose area it stands in (Factorio 2.1.23, measured headless: robots serve hidden chests, also two on
---     one tile, and construction robots fetch from them):
---       provider   a passive provider: "Offer" rows (item with quality, amount) are kept stocked from the network; robots
---                  take from it (requesters, construction, players). Requesters take from active providers first, then
---                  storage chests, then passive providers: the ME stock is the base's last source. Issue #540: a row counts
---                  and takes only what ME holds outside an ME Logistic Storage Bus of the same logistic network (`skip_of`),
---                  so the base's own items never move into the provider.
---       requester  a requester: "Request" rows (item, keep this many in the network) ask the robots for what the network
---                  lacks: target - the network's count (external cells too) - what lies in the requester - what robots
---                  bring to it now (targeted_items_deliver); written with set_slot only when it changes, 0 at the target.
---       storage    a storage chest: robots drop trash and surplus there ("Accept trash", on by default; off: it is filtered
---                  on an item that is never delivered, `REFUSE`, and takes nothing). A filter item makes it the preferred
---                  drop of that item (the game's rule for a filtered storage chest: then it takes only that item).
---     Every visit pulls the requester (its main inventory and its trash: a requester's trash is an active provider point)
---     and the storage chest into the network; what the network cannot store stays ("ME full"). The storage chest's
---     items that robots reserved for a pickup stay (`targeted_items_pickup`: taking them is safe, the robots plan again,
---     but they fly in vain); so does the provider's surplus that robots reserved when a row shrinks.
---   * Loop guard: robots carry an item between a requester and a passive provider on the same tile (measured), so per
---     logistic network an item is either offered or requested, never both, across all ME Logistic Interfaces of it: a
---     request row of an item that an interface of the same logistic network offers is not applied (shown red in the window).
---     The lookup (logistic network id -> offered keys) is derived from the records (each record's network id of its last
---     visit, `rec.lid`, and its offer rows), never saved. What is pulled in never goes into an ME Logistic Storage Bus of
---     the same logistic network (N.insert_partial's `skip`), and that bus never stores into, counts or takes from the hidden
---     chests (issue #530: this module is a source of its ME-owned chests).
---   * Automatic requests (issue #532, on by default, the switch "auto"): what the failed starts of the ME network's level
---     maintainers and Crafting Cards lacked (AC.waiting_needs, the maintainer's option A) is asked for too, in the
---     requester's second section: per key the need (what they lacked together, less what arrived since) less what lies
---     in the requester and is on its way, the largest first, at most the setting "keys" (20). Per logistic network and ME
---     network only the first interface (by unit number) with the switch on asks; keys offered in the logistic network
---     (the loop guard) and keys of its own request rows are left out.
---   * Automatic mode (issue #537; `rec.mode` "auto", the default of a block built since; a record without it, a block built
---     before, is Manual): the rows still apply, and the block also
---       offers  what the logistic network's requester points (chests, rocket silos, characters, vehicles) want and the
---               network cannot supply itself: per key the open demand (min - content - targeted_items_deliver of every
---               point) less what the logistic network holds outside the ME-owned chests (issue #530: else the stock would
---               cover the demand, the demand vanish and ME take the stock back); the stock is min(that, ME's count, the
---               setting "stacks" x stack size). ME's count and the extraction leave out an ME Logistic Storage Bus of the
---               same logistic network (`skip_of`: what it shows is the base's own). Keys ME blocks wait for (net.wait_in but the interfaces' own waits,
---               AC.waiting_needs) are not offered (the network's needs first), nor keys of rows in that logistic network.
---               A key without unmet demand keeps its stock (no fill, no return) for two passes, then what robots did not
---               reserve goes back. Unknown items (their mod is gone) are counted, not offered; a stock that does not fit
---               the provider's free slots is left out, the largest unmet keys first.
---       asks    for what ME blocks wait for: the keys of net.wait_in (but the interfaces') and AC.waiting_needs, one stack
---               each, and only while the logistic network holds them outside the ME-owned chests (the second section, as
---               #532; in Automatic mode it asks whatever the switch "auto" says).
---     The scan: a pass per logistic network with an automatic block, one after the other; its first automatic block by
---     unit number leads, a stock goes to the automatic block nearest to the point with the largest open demand of the key
---     (ties by unit number). A pass reads the points' filters (the setting "points per tick", default 2, about 25 us each;
---     the point list kept in `storage`, taken again after POINTS_TTL ticks or a requester built), then works out the keys
---     (KEY_WORK keys per point of the budget), then decides in one tick. Everything a pass keeps is in `storage`
---     (`s.dm`, `s.auto`, `s.pts`): it decides when blocks are woken. Issue #538: what construction needs in the logistic
---     network (ghosts, upgrades, item request proxies; scripts/fork-me-logistic-construction.lua) is added to the points'
---     demand at the end of phase 1, at the position of its first record.
---   * Cards: the ME Interface's (Interface Capacity Card: 9 more rows per card, up to 36; Crafting Card: an offer row the
---     network cannot fill, outside the base's own chests, starts a job, as the interface's, issue #411).
---   * Visits: a queue of its own (Sched, tag "logistic_interface") with a budget (map settings "ME Logistic Interface visits
---     per tick", at least and at most). A visit that moved something comes back after MIN_INTERVAL ticks, one that did not
---     twice as late each time up to the idle limit (a robot's drop raises no event); an offer row's item arriving in the
---     network (N.wait_for) and a request row's item falling below its target (N.wait_below) wake it.
---   * Kept in blueprints, settings paste and clones: the rows, the switch, the filter and the cards (tag
---     fork_me_logistic_interface). Mined: the chests' contents go into the network, without one into the buffer; destroyed or
---     removed by a script: spilled. Hidden chests without their block are removed in on_configuration_changed.
--- State: storage.fork_me_lif = { recs = { [unit] = { entity, provider, requester, store, offer, request, accept, filter,
--- inv, cards, want, nrows, ccard, lid, status, rq, mode, ... the scheduler's fields } }, list, lpos, q, dm (the pass that
--- runs: lid, phase, i, acc, top, unk, keys, own, unmet), dlast (the logistic network of the last pass), dstale (the tick a
--- requester was built), pts = { [lid] = { list, at } } (the requester points), auto = { [lid] = { keys = { [key] = { u, n, z } },
--- nunk, nofit, nwait } } (the stock of the last pass: block u keeps n; n 0: kept as it is; z the passes without demand) }.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local Sched = require("scripts.fork-me-schedule")
local CS = require("scripts.fork-me-cardslots")
local AC = require("scripts.fork-me-autocraft")
local L = require("scripts.fork-me-logistic-storagebus")
local C = require("scripts.fork-me-logistic-construction")     -- (issue #538: what construction needs)

local M = {}

local NAME = "me-logistic-interface"
local PROVIDER, REQUESTER, STORAGE = NAME .. "-provider", NAME .. "-requester", NAME .. "-storage"
local REFUSE = NAME .. "-nothing"           -- (a hidden item: the storage chest's filter while it accepts nothing)
local CHESTS = { provider = PROVIDER, requester = REQUESTER, store = STORAGE }
local CHEST_NAMES = { PROVIDER, REQUESTER, STORAGE }
local TAG = "fork_me_logistic_interface"
local WAKER = "logistic_interface"
local MIN_INTERVAL = 30              -- ticks until the next visit of an interface that moved something
local MAX_AMOUNT = 1000000
local CHEST = defines.inventory.chest
local TRASH = defines.inventory.logistic_container_trash
local MAIN_POINT = defines.logistic_member_index.logistic_container
local TABS = { offer = true, request = true }
--- Issue #411, as the ME Interface's: a start that failed waits this long before the key is tried again (no pattern: longer)
local CRAFT_RETRY, CRAFT_RETRY_NONE = 300, 1200
--- Issue #537, the automatic mode: the scheduler's counters of the demand scan, the age of a point list, the keys worked out
--- per point of the budget, the passes a key without demand keeps its stock
local DEMAND = "logistic_demand"
local POINTS_TTL = 600
local KEY_WORK = 4
local HOLD_PASSES = 2
--- the entity types with requester points (a build of one takes the point lists again)
local REQUESTER_TYPES = { ["logistic-container"] = true, ["rocket-silo"] = true, character = true, car = true,
	["spider-vehicle"] = true, ["cargo-landing-pad"] = true, ["space-platform-hub"] = true }

M.NAME, M.CHEST_NAMES, M.REFUSE = NAME, CHEST_NAMES, REFUSE

local function state()
	local s = storage.fork_me_lif
	if not s then
		s = { recs = {}, list = {}, lpos = {}, q = Sched.new(WAKER) }
		storage.fork_me_lif = s
	end
	return s
end

local function is_block(entity) return entity and entity.valid and entity.name == NAME end
local function is_chest(entity) return entity and entity.valid and (entity.name == PROVIDER or entity.name == REQUESTER
	or entity.name == STORAGE) end

local function rec_of(entity)
	local s = storage.fork_me_lif
	return s and is_block(entity) and s.recs[entity.unit_number] or nil
end

local function unit_rec(unit)
	local s = storage.fork_me_lif
	return s and s.recs[unit]
end

local function idle_limit() return math.max(MIN_INTERVAL, Sched.setting("idle")) end

--- the rows of a tab (9 and 9 more per Interface Capacity Card)
local function rows_of(rec) return rec.nrows or N.card_rules().interface.rows end

local function row_key(r) return N.key_of(r.name, r.quality) end

--------------------------------------------------------------------------------
--- the loop guard (derived from the records, never saved)
--------------------------------------------------------------------------------

local guard = nil                    -- logistic network id -> { key -> true } of the offer rows of its interfaces

--- the keys offered in logistic network `lid` (by any interface whose last visit found it there)
local function offered_in(lid)
	if not lid then return nil end
	if not guard then
		guard = {}
		local s = storage.fork_me_lif
		for _, rec in pairs(s and s.recs or {}) do
			if rec.lid then
				local g = guard[rec.lid]
				if not g then
					g = {}
					guard[rec.lid] = g
				end
				for i = 1, rows_of(rec) do
					local r = rec.offer[i]
					if r then g[row_key(r)] = true end
				end
			end
		end
		--- issue #537: what the automatic mode offers (and keeps) there
		for lid, a in pairs(s and s.auto or {}) do
			local g = guard[lid]
			if not g then
				g = {}
				guard[lid] = g
			end
			for key in pairs(a.keys) do g[key] = true end
		end
	end
	return guard[lid]
end

--- issue #537: the automatic blocks by logistic network (lid -> their units, sorted; the first leads) and the ids with one,
--- sorted (derived from the records, never saved)
local autos, auto_lids = nil, nil
local function auto_blocks()
	if not autos then
		autos, auto_lids = {}, {}
		local s = storage.fork_me_lif
		for unit, rec in pairs(s and s.recs or {}) do
			if rec.mode == "auto" and rec.lid and rec.entity.valid then
				local list = autos[rec.lid]
				if not list then
					list = {}
					autos[rec.lid] = list
					auto_lids[#auto_lids + 1] = rec.lid
				end
				list[#list + 1] = unit
			end
		end
		for _, list in pairs(autos) do table.sort(list) end
		table.sort(auto_lids)
	end
	return autos, auto_lids
end

--- issue #532: the interface that asks for the failed starts' needs, per logistic network and ME network: the first by unit
--- number with the switch on ("<lid>:<network id>" -> unit; made again when a record or the graph changed). Issue #537: a
--- block in Automatic mode asks whatever its switch says, and comes before the blocks in Manual mode.
local firsts, firsts_auto, firsts_ver = nil, nil, -1
local function asks(rec) return rec.lid ~= nil and (rec.mode == "auto" or rec.auto ~= false) end
local function asks_needs(rec, net)
	if not asks(rec) then return false end
	local v = N.version()
	if not firsts or firsts_ver ~= v then
		firsts, firsts_auto, firsts_ver = {}, {}, v
		local s = storage.fork_me_lif
		for unit, r in pairs(s and s.recs or {}) do
			local n = asks(r) and N.network_of_unit(unit)
			if n then
				local k = r.lid .. ":" .. n.id
				local auto = r.mode == "auto"
				local cur = firsts[k]
				if not cur or (auto and not firsts_auto[k]) or (auto == firsts_auto[k] and unit < cur) then
					firsts[k], firsts_auto[k] = unit, auto
				end
			end
		end
	end
	return firsts[rec.lid .. ":" .. net.id] == rec.entity.unit_number
end

local function guard_changed() guard, firsts, autos, auto_lids = nil, nil, nil, nil end
C.auto_lids = auto_blocks
M.offered_in = function(lid) return offered_in(lid) end

--- is request row `i` of `rec` not applied (its item is offered in the same logistic network)?
local function collides(rec, i)
	local r = rec.request[i]
	local g = r and offered_in(rec.lid)
	return g ~= nil and g[row_key(r)] == true
end

--------------------------------------------------------------------------------
--- the hidden chests
--------------------------------------------------------------------------------

--- the storage chest's filter: the filter item while it accepts trash (nil: none), REFUSE while it does not
local function apply_accept(rec)
	local st = rec.store
	if not (st and st.valid) then return end
	if rec.accept == false then
		st.storage_filter = REFUSE
	elseif rec.filter then
		st.storage_filter = { name = rec.filter.name, quality = rec.filter.quality }
	else
		st.storage_filter = nil
	end
end

--- the requester's section of the rows (the first; made when missing)
local function section_of(rec)
	local p = rec.requester.get_logistic_point(MAIN_POINT)
	if not p then return nil end
	return p.get_section(1) or p.add_section()
end

--- issue #532: the requester's section of the automatic requests (the second; made when missing)
local function auto_section(rec)
	local p = rec.requester.get_logistic_point(MAIN_POINT)
	if not (p and section_of(rec)) then return nil end
	return p.get_section(2) or p.add_section()
end

--- the three chests of `rec` on its tile: kept, taken over (a clone's, a chest no record has) or made
local function ensure_chests(rec)
	local e = rec.entity
	local made = false
	for field, name in pairs(CHESTS) do
		local c = rec[field]
		if not (c and c.valid) then
			c = e.surface.find_entity(name, e.position)
			if not c then
				c = e.surface.create_entity{ name = name, position = e.position, force = e.force, create_build_effect_smoke = false }
			end
			if c then
				c.destructible = false
				rec[field] = c
				made = true
			end
		end
	end
	if made then
		local p = rec.requester and rec.requester.valid and rec.requester.get_logistic_point(MAIN_POINT)
		if p then p.trash_not_requested = false end
		rec.rq = nil                                       -- (the requests are written again)
		apply_accept(rec)
		L.owned_changed()
	end
end

--- everything in the three chests goes into `net` (when given), what does not fit into `buffer` (when given), the rest is
--- spilled where the block stood; the chests are destroyed
local function empty_chests(rec, net, buffer)
	local w = rec.where
	local surface = w and game.surfaces[w.surface]
	for field in pairs(CHESTS) do
		local c = rec[field]
		if c and c.valid then
			for _, inv in ipairs({ c.get_inventory(CHEST), c.get_inventory(TRASH) }) do
				for i = 1, #inv do
					local st = inv[i]
					if st.valid_for_read and net then N.insert_stack(net, st) end
					if st.valid_for_read and buffer and buffer.valid then
						local n = buffer.insert(st)
						if n >= st.count then st.clear() elseif n > 0 then st.count = st.count - n end
					end
					if st.valid_for_read and surface then
						surface.spill_item_stack{ position = { w.x, w.y }, stack = st, enable_looted = true, force = c.force,
							allow_belts = false }
						st.clear()
					end
				end
			end
			c.destroy()
		end
		rec[field] = nil
	end
end

--------------------------------------------------------------------------------
--- records and the queue
--------------------------------------------------------------------------------

local function wake(unit)
	local s = storage.fork_me_lif
	local rec = s and s.recs[unit]
	if not rec then return end
	rec.iv = nil
	Sched.wake(s.q, rec, unit)
end
M.wake = wake
N.wakers[WAKER] = wake

local cards
--- the rows of both tabs by the cards (rows beyond them are kept, shown nowhere and do nothing until a card gives room again)
local function resize_rows(rec)
	local rules = N.card_rules().interface
	local size = rules.rows + rules.per_capacity * math.min(cards.counts(rec).interface_capacity or 0, rules.limits.interface_capacity)
	rec.nrows = size ~= rules.rows and size or nil
	rec.rq = nil
	guard_changed()
end

cards = CS.new{
	rules = function() return N.card_rules().interface end,
	title = function(rec) return rec.entity and rec.entity.valid and rec.entity.localised_name or { "entity-name." .. NAME } end,
	rec_of = rec_of,
	on_cards = function(rec, light)
		resize_rows(rec)
		rec.ccard = cards.counts(rec).crafting and true or nil         -- (issue #411: a Crafting Card)
		if not light and rec.entity and rec.entity.valid then wake(rec.entity.unit_number) end
	end,
}
M.cards = cards

local function register(entity)
	local s = state()
	local unit = entity.unit_number
	local rec = s.recs[unit]
	if not rec then
		rec = { entity = entity, offer = {}, request = {}, accept = true, mode = "auto",      -- (issue #537: new blocks automatic)
			where = { surface = entity.surface.index, x = entity.position.x, y = entity.position.y } }
		s.recs[unit] = rec
		s.list[#s.list + 1] = unit
		s.lpos[unit] = #s.list
		Sched.at(s.q, rec, unit, game.tick + 1)
	end
	cards.inv_of(rec)
	ensure_chests(rec)
	if not rec.lid then                                           -- (the network its chests stand in, before the first visit)
		local n = rec.provider and rec.provider.valid and rec.provider.logistic_network
		rec.lid = n and n.network_id or nil
		if rec.lid then
			guard_changed()
			L.owned_changed()
		end
	end
	return rec
end

--- the block leaves: its chests are emptied (into `net` and `buffer`, else spilled), its cards go to `buffer` or are spilled
local function forget(s, unit, net, buffer)
	local rec = s.recs[unit]
	if not rec then return end
	Sched.forget(s.q, rec)
	empty_chests(rec, net, buffer)
	if buffer and buffer.valid then cards.give_cards(rec, buffer) else cards.spill_cards(rec) end
	cards.detach(rec)
	s.recs[unit] = nil
	Sched.list_remove(s.list, s.lpos, unit)
	guard_changed()
	L.owned_changed()
end

--- issue #532: what the failed starts of an ME network lack changed: its interfaces that ask for it look again at once
AC.missing_hooks[#AC.missing_hooks + 1] = function(net)
	local s = storage.fork_me_lif
	if not s then return end
	local units = {}
	for unit, rec in pairs(s.recs) do
		if rec.auto ~= false and rec.lid and N.network_of_unit(unit) == net then units[#units + 1] = unit end
	end
	table.sort(units)
	for _, unit in ipairs(units) do wake(unit) end
end

--- issue #530: the hidden chests are ME-owned chests of the ME Logistic Storage Bus
L.owned_source(function(add)
	local s = storage.fork_me_lif
	for _, rec in pairs(s and s.recs or {}) do
		local lid = rec.lid
		if lid then
			add(rec.provider, "provider", lid)
			add(rec.requester, "requester", lid)
			add(rec.store, "storage", lid)
		end
	end
end)

--------------------------------------------------------------------------------
--- a visit
--------------------------------------------------------------------------------

--- the items of each key robots reserved in `point` (targeted_items_pickup or _deliver): { key -> count }
local function reserved(point, field)
	local out = {}
	if not point then return out end
	for _, it in pairs(point[field]) do
		local key = N.key_of(it.name, it.quality)
		out[key] = (out[key] or 0) + it.count
	end
	return out
end

--- Issue #411 (as the ME Interface's Crafting Card): a job for `amount` of `key` when none runs for this block. Returns true
--- while a job crafts the key.
local function craft(rec, net, key, amount)
	local jobs = rec.cjobs
	local id = jobs and jobs[key]
	if id then
		if AC.job_running(id) then rec.cstat = "crafting" return true end
		jobs[key] = nil
	end
	local now = game.tick
	local retry = rec.cretry and rec.cretry[key]
	if retry and now < retry then return false end
	if rec.cretry then rec.cretry[key] = nil end
	if AC.active_job_for(net, key) then rec.cstat = "other-job" return true end
	local why
	if not AC.free_slot(net) then why = "no-free-cpu"
	else
		local nid, plan
		nid, why, plan = AC.start(rec.entity, key, math.max(1, math.floor(amount)), rec.entity.unit_number, nil, WAKER)
		--- issue #532: what the start lacked (until the try after the next one)
		AC.note_missing("c" .. rec.entity.unit_number .. ":" .. key, rec.entity.unit_number, net,
			why == "missing" and plan and plan.missing or nil, now + 2 * CRAFT_RETRY + 60)
		if nid then
			rec.cjobs = jobs or {}
			rec.cjobs[key] = nid
			rec.cstat = "crafting"
			return true
		end
	end
	rec.cstat = why or "failed"
	rec.cretry = rec.cretry or {}
	rec.cretry[key] = now + (why == "no-pattern" and CRAFT_RETRY_NONE or CRAFT_RETRY)
	return false
end

--- items of a pulled inventory into the network; what robots reserved for a pickup at `point` (when given) stays. Returns
--- what moved and whether something stayed that the network had no room for (a stack it can never take, a spoiling one, is
--- no "ME full": it stays and waits).
local function pull(inv, net, skip, point)
	local moved, refused = 0, false
	if inv.is_empty() then return 0, false end
	local res = point and reserved(point, "targeted_items_pickup")
	if res and not next(res) then res = nil end
	for i = 1, #inv do
		local st = inv[i]
		if st.valid_for_read then
			local max = st.count
			local key
			if res then
				key = N.key_of(st.name, st.quality.name)
				local r = res[key]
				if r and r > 0 then
					local keep = math.min(r, max)
					res[key] = r - keep
					max = max - keep
				end
			end
			if max > 0 then
				local n, why = N.insert_partial(net, st, max, skip)
				if n then moved = moved + n end
				if (n and n < max) or (not n and not N.refuses_stack(why)) then refused = true end
			end
		end
	end
	return moved, refused
end

--- the provider kept at the offer rows: filled from the network, its surplus (and what no row keeps) back unless robots
--- reserved it. Returns what moved.
local WANT, ITEM = {}, {}                -- (scratch tables of a visit: the offer's want per key, an item spec)
local function item(name, q)
	ITEM.name, ITEM.quality = name, q
	return ITEM
end

local AUTO, HOLD = {}, -1               -- (issue #537: the keys of the automatic stock; a want of HOLD keeps what lies there)
local function offer(rec, net, unit, skip)
	local inv = rec.provider.get_inventory(CHEST)
	local point = rec.provider.get_logistic_point(MAIN_POINT)
	local want, auto = WANT, AUTO
	for k in pairs(want) do want[k] = nil end
	for k in pairs(auto) do auto[k] = nil end
	local moved = 0
	for i = 1, rows_of(rec) do
		local r = rec.offer[i]
		if r and N.item_exists(r.name) then
			local key = row_key(r)
			want[key] = (want[key] or 0) + r.amount
		end
	end
	local res
	--- issue #537: the automatic stock of this block (what robots reserved comes on top: it is on its way out)
	local s = storage.fork_me_lif
	local a = rec.mode == "auto" and rec.lid and s.auto and s.auto[rec.lid]
	if a then
		for key, o in pairs(a.keys) do
			if o.u == unit and not want[key] and N.item_exists((N.parse_key(key))) then
				if o.n > 0 then
					res = res or reserved(point, "targeted_items_pickup")
					want[key] = o.n + (res[key] or 0)
					auto[key] = true
				else
					want[key] = HOLD
				end
			end
		end
	end
	for key, amount in pairs(want) do
		local name, q = N.parse_key(key)
		local have = amount ~= HOLD and inv.get_item_count(item(name, q)) or 0
		if amount == HOLD then                                         -- (no demand for a pass or two: neither filled nor returned)
		elseif have < amount then
			--- issues #537, #540: never from an ME Logistic Storage Bus of this logistic network (the base's own chests), for the
			--- automatic stock and the rows alike: a row offers what ME holds outside them
			local got = N.extract_to(net, inv, key, amount - have, skip)
			moved = moved + got
			if got <= 0 and (skip and N.count_key_skip(net, key, skip) or N.count_key(net, key)) <= 0 then
				N.wait_for(net, key, WAKER, unit, true)
				if rec.ccard and not auto[key] then craft(rec, net, key, amount - have) end
			end
		elseif have > amount then
			res = res or reserved(point, "targeted_items_pickup")
			local back = math.min(have - amount, have - (res[key] or 0))
			if back > 0 then
				local st = { name = name, quality = q, count = back }
				local n = inv.remove(st)
				if n > 0 then
					local stored = N.insert(net, name, q, n, skip)                -- (plain items only: rows take no other)
					if stored < n then inv.insert{ name = name, quality = q, count = n - stored } end
					moved = moved + stored
				end
			end
		end
	end
	--- what no row keeps (a row removed or changed): back into the network, but what robots reserved
	if not inv.is_empty() then
		for _, it in pairs(inv.get_contents()) do
			local key = N.key_of(it.name, it.quality)
			if not want[key] then
				res = res or reserved(point, "targeted_items_pickup")
				local back = it.count - (res[key] or 0)
				if back > 0 then
					local n = inv.remove{ name = it.name, quality = it.quality, count = back }
					local stored = n > 0 and N.insert(net, it.name, it.quality, n, skip) or 0
					if stored < n then inv.insert{ name = it.name, quality = it.quality, count = n - stored } end
					moved = moved + stored
				end
			end
		end
	end
	return moved
end

--- the requester's requests from the request rows: target - the network's count - what the requester holds - what robots
--- bring now; a colliding row, a row without a logistic network and a row at its target ask for 0. Written only when changed.
local function request(rec, net, unit)
	local section = section_of(rec)
	if not section then return end
	local inv = rec.requester.get_inventory(CHEST)
	local rq = rec.rq
	if not rq then
		rq = {}
		rec.rq = rq
	end
	local deliver
	local n = rows_of(rec)
	for i = 1, math.max(n, section.filters_count) do
		local r = i <= n and rec.request[i] or nil
		local key, count = nil, 0
		if r and rec.lid and N.item_exists(r.name) and not collides(rec, i) then
			key = row_key(r)
			local have = N.count_key(net, key)
			count = r.amount - have - inv.get_item_count(item(r.name, r.quality))
			if count > 0 then
				deliver = deliver or reserved(rec.requester.get_logistic_point(MAIN_POINT), "targeted_items_deliver")
				count = count - (deliver[key] or 0)
			end
			if count < 0 then count = 0 end
			if have < r.amount then N.wait_for(net, key, WAKER, unit, true) else N.wait_below(net, key, WAKER, unit, r.amount) end
		end
		local sig = count > 0 and (key .. "=" .. count) or false
		if rq[i] ~= sig then
			if sig then
				section.set_slot(i, { value = { name = r.name, quality = r.quality, comparator = "=" }, min = count })
			elseif i <= section.filters_count then
				section.clear_slot(i)
			end
			rq[i] = sig
		end
	end
end

--- Issue #532: the automatic requests into the requester's second section (slot i: the i-th largest need), written only when
--- changed (`rec.aq`); an interface that does not ask (the switch off, not the first, no logistic network) clears them.
--- Returns the keys asked for and the needed keys left out because they are offered: { { key, need, asked } }, skipped.
local function auto_request(rec, net, ln)
	local list, skipped = {}, 0
	if asks_needs(rec, net) then
		local offered = offered_in(rec.lid) or {}
		local own = {}
		for i = 1, rows_of(rec) do
			local r = rec.request[i]
			if r then own[row_key(r)] = true end
		end
		--- issue #537: in Automatic mode one stack at most, and only what the logistic network holds outside the ME-owned chests
		local auto = rec.mode == "auto"
		local function add(key, need)
			if own[key] or N.is_fluid_key(key) or key:find("#", 1, true) then return end
			own[key] = true                                          -- (each key once)
			local name, q = N.parse_key(key)
			if not M.row_item(name, q) then return end               -- (defined below)
			if offered[key] then
				skipped = skipped + 1
				return
			end
			if auto then
				local it = item(name, q)
				local supply = ln and ln.get_item_count(it) - L.owned_count(ln, it) or 0
				need = math.min(need, supply, prototypes.item[name].stack_size)
				if need <= 0 then return end
			end
			list[#list + 1] = { key = key, need = math.ceil(need), name = name, quality = q }
		end
		for key, t in pairs(AC.waiting_needs(net)) do
			local need = t.sum + t.base - N.count_key(net, key)
			if need > 0 then add(key, need) end
		end
		if auto then                                                 -- (issue #537: what ME blocks wait for, but the interfaces)
			for key, w in pairs(net.wait_in or {}) do
				for _, kind in pairs(w) do
					if kind ~= WAKER then
						add(key, math.huge)
						break
					end
				end
			end
		end
		table.sort(list, function(a, b) if a.need ~= b.need then return a.need > b.need end return a.key < b.key end)
		local max = Sched.setting("logistic_interface_auto")
		for i = #list, max + 1, -1 do list[i] = nil end
	end
	local aq = rec.aq
	if #list == 0 and not aq then return list, skipped end           -- (never asked: nothing to clear)
	local section = auto_section(rec)
	if not section then return list, skipped end
	if not aq then
		aq = {}
		rec.aq = aq
	end
	local inv, deliver = rec.requester.get_inventory(CHEST), nil
	for i, a in ipairs(list) do
		local count = a.need - inv.get_item_count(item(a.name, a.quality))
		if count > 0 then
			deliver = deliver or reserved(rec.requester.get_logistic_point(MAIN_POINT), "targeted_items_deliver")
			count = count - (deliver[a.key] or 0)
		end
		a.asked = count > 0 and count or 0
		local sig = a.asked > 0 and (a.key .. "=" .. a.asked) or false
		if aq[i] ~= sig then
			if sig then
				section.set_slot(i, { value = { name = a.name, quality = a.quality, comparator = "=" }, min = a.asked })
			elseif i <= section.filters_count then
				section.clear_slot(i)
			end
			aq[i] = sig
		end
	end
	for i = #list + 1, math.max(#aq, section.filters_count) do
		if aq[i] ~= false then
			if i <= section.filters_count then section.clear_slot(i) end
			aq[i] = false
		end
	end
	if #list == 0 then rec.aq = nil end
	return list, skipped
end

--- the storage engine's `skip` for logistic network `lid`: an ME Logistic Storage Bus that claimed it (one function per id,
--- kept for the load: it depends on the id only)
local skips, nskips = {}, 0
local function skip_of(lid)
	local f = skips[lid]
	if not f then
		if nskips >= 256 then skips, nskips = {}, 0 end            -- (network ids grow with every split and join)
		f = function(cell) return cell.logistic == true and cell.lid == lid end
		skips[lid] = f
		nskips = nskips + 1
	end
	return f
end

--- One visit (Sched.run). Returns the class of the counters (0 nothing moved, 1 something).
local function visit(rec, unit, fallback)
	local s = storage.fork_me_lif
	local e = rec.entity
	if not (e and e.valid) then
		forget(s, unit, nil, nil)
		return nil
	end
	ensure_chests(rec)
	if rec.want then cards.fill_cards(rec) end                  -- issue #590: the cards a blueprint, a paste or a clone asked for
	local now = game.tick
	local net = N.network_of(e)
	local ok, why = N.usable(net)
	if not ok then
		rec.status = net and (why or "no-network") or "no-network"
		if net then N.wait_usable(net, WAKER, unit) end
		Sched.park(s.q, rec, unit, rec.status == "no-power" and "no-power" or "no-network")
		return 0
	end
	local ln = rec.provider.logistic_network
	local lid = ln and ln.network_id
	if rec.lid ~= lid then
		rec.lid = lid
		guard_changed()
		L.owned_changed()                                         -- (its chests are the bus's to skip in this network now)
	end
	--- pull in: the requester (main and trash) and the storage chest; never into a logistic storage bus of this logistic network
	local skip = lid and skip_of(lid) or nil
	local m1, r1 = pull(rec.requester.get_inventory(CHEST), net, skip, nil)
	local m2, r2 = pull(rec.requester.get_inventory(TRASH), net, skip, nil)
	local m3, r3 = pull(rec.store.get_inventory(CHEST), net, skip, rec.store.get_logistic_point(MAIN_POINT))
	local moved, refused = m1 + m2 + m3, r1 or r2 or r3
	moved = moved + offer(rec, net, unit, skip)
	request(rec, net, unit)
	local auto, skipped = auto_request(rec, net, ln)              -- (issue #532)
	rec.anum, rec.askip = #auto > 0 and #auto or nil, skipped > 0 and skipped or nil
	rec.full = refused or nil
	rec.status = not lid and "no-logistic-network" or refused and "me-full" or "ok"
	if refused then N.wait_room(net, WAKER, unit) end
	if fallback and moved > 0 then Sched.missed(WAKER) end
	rec.iv = Sched.interval(rec.iv, moved, moved > 0, MIN_INTERVAL, MIN_INTERVAL, idle_limit())
	Sched.at(s.q, rec, unit, now + rec.iv, moved <= 0)
	return moved > 0 and 1 or 0
end

local function probe(rec, unit) return visit(rec, unit, rec.park ~= nil) end

--------------------------------------------------------------------------------
--- issue #537: the automatic mode's demand scan
--------------------------------------------------------------------------------

local OWN_CHEST = { [PROVIDER] = true, [REQUESTER] = true, [STORAGE] = true }
local known = {}                         -- item name -> its prototype exists (per load, a pure function of the prototypes)
local function exists(name)
	local v = known[name]
	if v == nil then
		v = prototypes.item[name] ~= nil
		known[name] = v
	end
	return v
end

--- phase 1: the open demand of one requester point into the pass (per key the sum, and the point of the largest)
local function scan_point(dm, p)
	if not (p.valid and p.enabled) then return end
	local owner = p.owner
	if not (owner and owner.valid) or OWN_CHEST[owner.name] then return end
	local filters = p.filters
	if not filters then return end
	local deliver
	for _, f in pairs(filters) do
		local name = f.name
		if name and f.count > 0 and (f.type == nil or f.type == "item") then
			if not exists(name) then
				dm.unk[name] = true
			else
				local q = f.quality or "normal"
				local open = f.count - owner.get_item_count(item(name, q))
				if open > 0 then
					local key = N.key_of(name, q)
					deliver = deliver or reserved(p, "targeted_items_deliver")
					open = open - (deliver[key] or 0)
					if open > 0 then
						dm.acc[key] = (dm.acc[key] or 0) + open
						local t = dm.top[key]
						if not t or open > t.d then
							local pos = owner.position
							dm.top[key] = { d = open, x = pos.x, y = pos.y }
						end
					end
				end
			end
		end
	end
end

local offerable = {}                     -- key -> may it be offered (M.row_item; per load, a pure function of the prototypes)
local stacks = {}                        -- item name -> stack size (the same)
local function stack_of(name)
	local n = stacks[name]
	if not n then
		n = prototypes.item[name].stack_size
		stacks[name] = n
	end
	return n
end
--- phase 2: the unmet demand of one key: what the logistic network `ln` cannot supply outside the ME-owned chests (what
--- those hold: dm.own, read once at the start of the phase)
local function scan_key(dm, ln, key)
	local name, q = N.parse_key(key)
	local ok = offerable[key]
	if ok == nil then
		ok = M.row_item(name, q)
		offerable[key] = ok
	end
	if not ok then return end
	local supply = ln.get_item_count(item(name, q)) - (dm.own[key] or 0)
	local unmet = dm.acc[key] - math.max(0, supply)
	if unmet > 0 then dm.unmet[key] = unmet end
end

--- does an ME block of `net` wait for `key`? (`needs`: AC.waiting_needs of the network, read once per decision)
local function me_waits(net, key, needs)
	if needs[key] then return true end
	local w = net.wait_in and net.wait_in[key]
	for _, kind in pairs(w or {}) do
		if kind ~= WAKER then return true end
	end
	return false
end

--- phase 3: the stock of each key and the block that keeps it; the blocks of the logistic network are woken
local function decide(s, dm, units)
	local lid = dm.lid
	local skip = skip_of(lid)
	local old = s.auto and s.auto[lid]
	old = old and old.keys or {}
	local rows = {}                                               -- (the keys of rows of the logistic network: theirs)
	for _, rec in pairs(s.recs) do
		if rec.lid == lid then
			for _, tab in ipairs({ "offer", "request" }) do
				for i = 1, rows_of(rec) do
					local r = rec[tab][i]
					if r then rows[row_key(r)] = true end
				end
			end
		end
	end
	local blocks, by_unit, nets, seen = {}, {}, {}, {}
	for _, unit in ipairs(units) do
		local rec = s.recs[unit]
		local net = rec and rec.entity.valid and rec.provider and rec.provider.valid and N.network_of(rec.entity)
		if net and N.usable(net) then
			local inv = rec.provider.get_inventory(CHEST)
			local free = #inv
			for i = 1, rows_of(rec) do
				local r = rec.offer[i]
				if r and exists(r.name) then free = free - math.ceil(r.amount / stack_of(r.name)) end
			end
			local b = { unit = unit, net = net, pos = rec.entity.position, inv = inv, free = free }
			blocks[#blocks + 1] = b
			by_unit[unit] = b
			if not seen[net.id] then
				seen[net.id] = true
				nets[#nets + 1] = net
			end
		end
	end
	local list = {}
	for key in pairs(dm.unmet) do list[#list + 1] = key end
	table.sort(list, function(a, b)
		local x, y = dm.unmet[a], dm.unmet[b]
		if x ~= y then return x > y end
		return a < b
	end)
	local cap = Sched.setting("logistic_interface_stacks")
	local keys, nofit, nwait, needs = {}, 0, 0, {}
	for _, key in ipairs(list) do
		if not rows[key] and cap > 0 then
			local t, o = dm.top[key], old[key]
			--- what each ME network has (once per network; not what an ME Logistic Storage Bus of this logistic network shows:
			--- that is the base's own), and what the block that kept the stock holds of it
			local have, any = {}, o ~= nil
			for _, net in ipairs(nets) do
				local c = N.count_key_skip(net, key, skip)
				have[net.id] = c
				if c > 0 then any = true end
			end
			--- the nearest block (ties: the lower unit) whose ME network has the key
			local best, avail, name, q
			if any then
				name, q = N.parse_key(key)
				for _, b in ipairs(blocks) do b.d = (b.pos.x - t.x) ^ 2 + (b.pos.y - t.y) ^ 2 end
				if #blocks > 1 then table.sort(blocks, function(x, y) if x.d ~= y.d then return x.d < y.d end return x.unit < y.unit end) end
				for _, b in ipairs(blocks) do
					local n = have[b.net.id] + ((o and o.u == b.unit) and b.inv.get_item_count(item(name, q)) or 0)
					if n > 0 then
						best, avail = b, n
						break
					end
				end
			end
			if best then
				needs[best.net.id] = needs[best.net.id] or AC.waiting_needs(best.net)
				if me_waits(best.net, key, needs[best.net.id]) then
					nwait = nwait + 1
				else
					local stack = stack_of(name)
					local n = math.min(math.ceil(dm.unmet[key]), avail, cap * stack)
					local slots = math.ceil(n / stack)
					if slots > best.free then
						nofit = nofit + 1
					else
						best.free = best.free - slots
						keys[key] = { u = best.unit, n = n, z = 0 }
					end
				end
			end
		end
	end
	--- a key that had a stock and no unmet demand now keeps it as it is for HOLD_PASSES passes (robots on their way)
	for key, o in pairs(old) do
		local b = by_unit[o.u]
		if not (keys[key] or dm.unmet[key] or rows[key]) and o.z + 1 < HOLD_PASSES and b then
			needs[b.net.id] = needs[b.net.id] or AC.waiting_needs(b.net)
			if not me_waits(b.net, key, needs[b.net.id]) then keys[key] = { u = o.u, n = 0, z = o.z + 1 } end
		end
	end
	local nunk = 0
	for _ in pairs(dm.unk) do nunk = nunk + 1 end
	s.auto = s.auto or {}
	s.auto[lid] = { keys = keys, nunk = nunk, nofit = nofit, nwait = nwait }
	guard_changed()
	local woken = {}
	for _, unit in ipairs(units) do woken[unit] = true end
	for _, o in pairs(old) do woken[o.u] = true end
	local list2 = {}
	for unit in pairs(woken) do list2[#list2 + 1] = unit end
	table.sort(list2)
	for _, unit in ipairs(list2) do wake(unit) end
end

--- the logistic network of the leader (the first automatic block of `lid`), nil when it stands elsewhere now
local function leader_network(s, units, lid)
	local rec = units and s.recs[units[1]]
	local ln = rec and rec.provider and rec.provider.valid and rec.provider.logistic_network
	return ln and ln.network_id == lid and ln or nil
end

--- issue #538: the logistic network `lid` now (through its leader), or nil
local function net_of(lid)
	local s = storage.fork_me_lif
	local all = auto_blocks()
	return s and leader_network(s, all[lid], lid)
end

--- One tick of the scan: `budget` requester points (a key of phase 2 costs 1 / KEY_WORK of a point)
local function demand_step(s, tick)
	local all, lids = auto_blocks()
	if #lids == 0 then
		if s.dm or s.auto or s.pts then
			s.dm, s.auto, s.pts = nil, nil, nil
			guard_changed()
		end
		return
	end
	local dm = s.dm
	if dm and not all[dm.lid] then dm, s.dm = nil, nil end
	if not dm then
		--- the next logistic network after the last one; the passes and point lists of networks without an automatic block go
		local lid = lids[1]
		for _, id in ipairs(lids) do
			if s.dlast and id > s.dlast then
				lid = id
				break
			end
		end
		s.dlast = lid
		for id in pairs(s.auto or {}) do if not all[id] then s.auto[id] = nil end end
		for id in pairs(s.pts or {}) do if not all[id] then s.pts[id] = nil end end
		local ln = leader_network(s, all[lid], lid)
		if not ln then return end
		s.pts = s.pts or {}
		local c = s.pts[lid]
		if not c or tick - c.at >= POINTS_TTL or (s.dstale and s.dstale >= c.at) then
			c = { list = ln.requester_points, at = tick }
			s.pts[lid] = c
		end
		dm = { lid = lid, phase = 1, i = 1, acc = {}, top = {}, unk = {}, unmet = {} }
		s.dm = dm
	end
	local ln = leader_network(s, all[dm.lid], dm.lid)
	if not ln then
		s.dm = nil
		return
	end
	local work, done = Sched.setting("logistic_demand") * KEY_WORK, 0
	if dm.phase == 1 then
		local list = s.pts[dm.lid].list
		while work >= KEY_WORK and dm.i <= #list do
			scan_point(dm, list[dm.i])
			dm.i = dm.i + 1
			work = work - KEY_WORK
			done = done + 1
		end
		if dm.i > #list then
			--- issue #538: what construction needs (ghosts, upgrades, item request proxies), as a point at its first record
			for key, t in pairs(C.tally(dm.lid)) do
				dm.acc[key] = (dm.acc[key] or 0) + t.n
				local top = dm.top[key]
				if not top or t.n > top.d then dm.top[key] = { d = t.n, x = t.x, y = t.y } end
			end
			local keys = {}
			for key in pairs(dm.acc) do keys[#keys + 1] = key end
			table.sort(keys)
			dm.phase, dm.i, dm.keys, dm.own = 2, 1, keys, L.owned_contents(ln)
		end
	end
	if dm.phase == 2 then
		local keys = dm.keys
		while work > 0 and dm.i <= #keys do
			scan_key(dm, ln, keys[dm.i])
			dm.i = dm.i + 1
			work = work - 1
		end
		if dm.i > #keys then dm.phase = 3 end
	elseif dm.phase == 3 then
		decide(s, dm, all[dm.lid])
		s.dm = nil
	end
	Sched.work(DEMAND, done)
end

function M.on_tick(tick)
	local s = storage.fork_me_lif
	if s and #s.list > 0 then
		Sched.run(s.q, tick, Sched.setting("logistic_interface"), Sched.setting("logistic_interface_max"), unit_rec, visit, probe,
			WAKER)
		demand_step(s, tick)
		C.on_tick(tick, net_of)                                  -- (issue #538: the construction safety net)
	end
end

--------------------------------------------------------------------------------
--- the rows and switches (the window, the remote, the settings)
--------------------------------------------------------------------------------

--- may `name` / `quality` be a row? (a plain item that does not spoil: ME stores no spoiling items yet)
local function row_item(name, quality)
	local p = name and prototypes.item[name]
	if not (p and prototypes.quality[quality or "normal"]) then return false end
	if N.item_class(p.type) ~= "plain" then return false end
	return p.get_spoil_ticks(quality or "normal") <= 0
end
M.row_item = row_item

--- row `i` of tab `tab` ("offer" or "request"): `key` (an item key, nil clears the row) and `amount` (nil: kept, else one
--- stack). Refused (false, nothing changes): another tab, a row beyond the rows, a key that is no row item, a key another row
--- of the tab has. Returns true when set.
function M.set_row(entity, tab, i, key, amount)
	local rec = rec_of(entity)
	if not (rec and TABS[tab] and type(i) == "number" and i >= 1 and i <= rows_of(rec)) then return false end
	local rows = rec[tab]
	if key == nil then
		rows[i] = nil
	else
		if type(key) ~= "string" or N.is_fluid_key(key) or key:find("#", 1, true) then return false end
		local name, q = N.parse_key(key)
		if not row_item(name, q) then return false end
		for j = 1, rows_of(rec) do
			local o = rows[j]
			if j ~= i and o and row_key(o) == key then return false end
		end
		local old = rows[i]
		if amount == nil then amount = (old and row_key(old) == key) and old.amount or prototypes.item[name].stack_size end
		amount = math.max(0, math.min(MAX_AMOUNT, math.floor(tonumber(amount) or 0)))
		rows[i] = { name = name, quality = q, amount = amount }
	end
	if tab == "offer" then guard_changed() end
	wake(entity.unit_number)
	return true
end

--- the amount of row `i` of `tab` (the row stays)
function M.set_amount(entity, tab, i, amount)
	local rec = rec_of(entity)
	local r = rec and TABS[tab] and rec[tab][i]
	if not r then return false end
	r.amount = math.max(0, math.min(MAX_AMOUNT, math.floor(tonumber(amount) or 0)))
	wake(entity.unit_number)
	return true
end

--- "Accept trash" on or off
function M.set_accept(entity, on)
	local rec = rec_of(entity)
	if not rec then return false end
	rec.accept = on and true or false
	apply_accept(rec)
	wake(entity.unit_number)
	return true
end

--- issue #532: the automatic requests for what the failed crafting starts lack, on (the default) or off
function M.set_auto(entity, on)
	local rec = rec_of(entity)
	if not rec then return false end
	if on then rec.auto = nil else rec.auto = false end
	guard_changed()
	wake(entity.unit_number)
	return true
end

--- issue #537: the mode, "auto" (Automatic) or "manual"; refused for anything else
function M.set_mode(entity, mode)
	local rec = rec_of(entity)
	if not (rec and (mode == "auto" or mode == "manual")) then return false end
	rec.mode = mode == "auto" and "auto" or nil
	guard_changed()
	wake(entity.unit_number)
	return true
end

--- the storage chest's filter item (`key`, nil: none); refused for a key that is no row item
function M.set_filter(entity, key)
	local rec = rec_of(entity)
	if not rec then return false end
	if key == nil then
		rec.filter = nil
	else
		if type(key) ~= "string" or N.is_fluid_key(key) or key:find("#", 1, true) then return false end
		local name, q = N.parse_key(key)
		if not row_item(name, q) then return false end
		rec.filter = { name = name, quality = q }
	end
	apply_accept(rec)
	wake(entity.unit_number)
	return true
end

local function copy_rows(rows, n)
	local out = {}
	for i = 1, n do
		local r = rows[i]
		if r then out[#out + 1] = { i = i, name = r.name, quality = r.quality, amount = r.amount } end
	end
	return out
end

local function settings_of(rec)
	local list = rec.want and { table.unpack(rec.want) } or cards.card_list(rec)
	return { offer = copy_rows(rec.offer, 36), request = copy_rows(rec.request, 36), accept = rec.accept ~= false,
		filter = rec.filter and N.key_of(rec.filter.name, rec.filter.quality) or nil, cards = list, auto = rec.auto ~= false,
		mode = rec.mode == "auto" and "auto" or "manual" }
end

--- the settings `t` (a blueprint tag, a source's settings) onto `entity`; `player`: the cards come from its inventory first
--- (`inv` instead for a test, issue #590)
local function apply(entity, t, player, inv)
	local rec = rec_of(entity)
	if not (rec and type(t) == "table") then return end
	if type(t.cards) == "table" then cards.want_cards(entity, t.cards, player, inv) end   -- (first: the rows they give room for)
	for _, tab in ipairs({ "offer", "request" }) do
		rec[tab] = {}
		for _, r in ipairs(type(t[tab]) == "table" and t[tab] or {}) do
			local i = tonumber(r.i)
			if i and i >= 1 and i <= 36 and row_item(r.name, r.quality) then
				rec[tab][i] = { name = r.name, quality = r.quality or "normal", amount = math.max(0, math.min(MAX_AMOUNT,
					math.floor(tonumber(r.amount) or 0))) }
			end
		end
	end
	rec.accept = t.accept ~= false
	if t.auto == false then rec.auto = false else rec.auto = nil end   -- (issue #532: on unless the settings say off)
	if t.mode == "auto" then rec.mode = "auto" elseif t.mode == "manual" then rec.mode = nil end   -- (issue #537; none: kept)
	rec.filter = nil
	if type(t.filter) == "string" then M.set_filter(entity, t.filter) end
	rec.rq = nil
	apply_accept(rec)
	guard_changed()
	wake(entity.unit_number)
end

--- what the window shows: { offer, request (rows by index), rows, collide = { i -> true }, accept, filter, lid, status,
--- full, provider and requester contents, card slots and cards, wanted cards, the Crafting Card's state }
function M.info(entity)
	local rec = rec_of(entity)
	if not rec then return nil end
	local d = { rows = rows_of(rec), offer = {}, request = {}, collide = {}, accept = rec.accept ~= false, lid = rec.lid,
		status = rec.status or "ok", full = rec.full == true, slots = N.card_rules().interface.slots, cards = {} }
	for i = 1, d.rows do
		local o, r = rec.offer[i], rec.request[i]
		if o then d.offer[i] = { key = row_key(o), name = o.name, quality = o.quality, amount = o.amount } end
		if r then
			d.request[i] = { key = row_key(r), name = r.name, quality = r.quality, amount = r.amount, asked = 0 }
			if collides(rec, i) then d.collide[i] = true end
		end
	end
	local section = rec.requester and rec.requester.valid and section_of(rec)
	if section then
		for i = 1, d.rows do
			local f = d.request[i] and i <= section.filters_count and section.get_slot(i)
			if f and f.value then d.request[i].asked = f.min or 0 end
		end
	end
	d.filter = rec.filter and N.key_of(rec.filter.name, rec.filter.quality) or nil
	--- issue #532: the switch, whether this interface asks (the first of its logistic and ME network), what it asks for now
	d.auto = rec.auto ~= false
	local net = N.network_of(entity)
	d.auto_asks = net ~= nil and N.usable(net) and asks_needs(rec, net) or false
	d.auto_skipped = rec.askip or 0
	d.auto_list = {}
	local asec = rec.aq and rec.requester and rec.requester.valid and auto_section(rec)
	if asec then
		for i = 1, asec.filters_count do
			local f = asec.get_slot(i)
			if f and f.value and f.min and f.min > 0 then
				d.auto_list[#d.auto_list + 1] = { key = N.key_of(f.value.name, f.value.quality or "normal"), asked = f.min }
			end
		end
	end
	--- issue #537: the mode; what the automatic mode offers here (key, the stock it keeps, 0: kept as it is) and the counts of
	--- its logistic network's last pass (offered there, unknown items, keys that did not fit, keys left to waiting ME blocks)
	d.mode = rec.mode == "auto" and "auto" or "manual"
	d.auto_offer, d.auto_offered, d.auto_unknown, d.auto_nofit, d.auto_waits = {}, 0, 0, 0, 0
	local s = storage.fork_me_lif
	local a = rec.lid and s.auto and s.auto[rec.lid]
	if a then
		for key, o in pairs(a.keys) do
			if o.n > 0 then d.auto_offered = d.auto_offered + 1 end
			if o.u == entity.unit_number and rec.mode == "auto" then d.auto_offer[#d.auto_offer + 1] = { key = key, amount = o.n } end
		end
		table.sort(d.auto_offer, function(x, y) return x.key < y.key end)
		d.auto_unknown, d.auto_nofit, d.auto_waits = a.nunk, a.nofit, a.nwait
	end
	d.auto_build = 0                                              -- (issue #538: the items construction needs there)
	for _, t in pairs(rec.lid and C.tally(rec.lid) or {}) do d.auto_build = d.auto_build + t.n end
	local all = auto_blocks()
	local list = rec.lid and all[rec.lid]
	d.auto_leads = rec.mode == "auto" and list ~= nil and list[1] == entity.unit_number
	local ncollide = 0
	for _ in pairs(d.collide) do ncollide = ncollide + 1 end
	d.ncollide = ncollide
	for slot, name in pairs(rec.cards or {}) do d.cards[slot] = name end
	d.want = rec.want and cards.missing_cards(rec, rec.want) or nil
	d.craft = rec.ccard and (rec.cstat or "idle") or nil
	local function contents(c, index)
		local out = {}
		local inv = c and c.valid and c.get_inventory(index)
		for _, it in pairs(inv and inv.get_contents() or {}) do
			out[#out + 1] = { key = N.key_of(it.name, it.quality), count = it.count }
		end
		table.sort(out, function(a, b) return a.key < b.key end)
		return out
	end
	d.stock = contents(rec.provider, CHEST)
	d.held = contents(rec.requester, CHEST)
	d.trash = contents(rec.store, CHEST)
	return d
end

--- the card slots (a script inventory, scripts/fork-me-cardslots.lua)
function M.card_inventory(entity)
	local rec = rec_of(entity)
	return rec and cards.inv_of(rec) or nil
end

--------------------------------------------------------------------------------
--- events
--------------------------------------------------------------------------------

--- `tags`: blueprint tags (or of a paste over a block, issue #383); `source`: the original of a clone. A cloned hidden chest
--- goes to the block that stands on its tile (it takes the clone's contents and drops its own chest), or waits for its
--- block's clone (ensure_chests takes it over). `player`: who built it by hand or pasted over it (issue #590: the cards of the
--- tag from its inventory first, `inv` instead for a test; nil for robots: the network).
function M.on_built(entity, tags, source, player, inv)
	local s0 = storage.fork_me_lif
	if s0 and s0.pts and entity.valid and REQUESTER_TYPES[entity.type] then s0.dstale = game.tick end   -- (issue #537)
	if is_chest(entity) then
		local s = storage.fork_me_lif
		for _, b in pairs(entity.surface.find_entities_filtered{ name = NAME, position = entity.position }) do
			local rec = s and s.recs[b.unit_number]
			if rec then
				for field, name in pairs(CHESTS) do
					local own = rec[field]
					if name == entity.name and own ~= entity then
						if own and own.valid then own.destroy() end            -- (a block's fresh chest, empty)
						entity.destructible = false
						rec[field] = entity
						rec.rq = nil
						apply_accept(rec)
						L.owned_changed()
					end
				end
			end
		end
		return
	end
	if not is_block(entity) then return end
	register(entity)
	local t = type(tags) == "table" and tags[TAG] or nil
	if type(t) == "table" then
		apply(entity, t, player, inv)
	elseif is_block(source) then
		local from = rec_of(source)
		if from then apply(entity, settings_of(from), nil) end
	end
	wake(entity.unit_number)
end

--- mined (`buffer`: the chests' contents go into the network, the rest and the cards into the buffer) or destroyed (nil:
--- spilled where it stood)
function M.on_removed(entity, buffer)
	if not (is_block(entity) and entity.unit_number) then return end
	local s = storage.fork_me_lif
	if not s then return end
	local net = buffer and N.network_of(entity) or nil
	if net and not N.usable(net) then net = nil end
	forget(s, entity.unit_number, net, buffer)
end

function M.on_entity_settings_pasted(event)
	local src, dst = event.source, event.destination
	if not (is_block(src) and is_block(dst)) then return end
	local from = rec_of(src)
	if not from then return end
	local player = event.player_index and game.get_player(event.player_index) or nil
	apply(dst, settings_of(from), player)
end

function M.tag_blueprint(bp, mapping)
	local s = storage.fork_me_lif
	if not s then return end
	for index, entity in pairs(mapping) do
		local rec = entity.valid and entity.name == NAME and s.recs[entity.unit_number]
		if rec then bp.set_blueprint_entity_tag(index, TAG, settings_of(rec)) end
	end
end

--- after a mod change: the blocks of the world (records kept, new ones made, the chests made where missing), the hidden
--- chests that belong to no block removed (their contents spilled), rows of items that are gone dropped, every block visited
function M.on_configuration_changed()
	local s = state()
	if not s.q then s.q = Sched.new(WAKER) end
	if not s.lpos then s.lpos = {} end
	for unit, rec in pairs(s.recs) do
		if not (rec.entity and rec.entity.valid) then forget(s, unit, nil, nil) end
	end
	for _, rec in pairs(s.recs) do
		for _, tab in ipairs({ "offer", "request" }) do
			for i, r in pairs(rec[tab]) do
				if not row_item(r.name, r.quality) then rec[tab][i] = nil end
			end
		end
		if rec.filter and not row_item(rec.filter.name, rec.filter.quality) then rec.filter = nil end
		rec.rq = nil
	end
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = NAME }) do register(e) end
	end
	local owned = {}
	for _, rec in pairs(s.recs) do
		for field in pairs(CHESTS) do
			local c = rec[field]
			if c and c.valid then owned[c.unit_number] = true end
		end
		apply_accept(rec)
	end
	for _, surface in pairs(game.surfaces) do
		for _, c in pairs(surface.find_entities_filtered{ name = CHEST_NAMES }) do
			if not owned[c.unit_number] then
				for _, index in ipairs({ CHEST, TRASH }) do
					local inv = c.get_inventory(index)
					for i = 1, inv and #inv or 0 do
						if inv[i].valid_for_read then
							surface.spill_item_stack{ position = c.position, stack = inv[i], enable_looted = true, force = c.force,
								allow_belts = false }
						end
					end
				end
				c.destroy()
			end
		end
	end
	guard_changed()
	L.owned_changed()
	for unit in pairs(s.recs) do wake(unit) end
end

--- the block of a window by its unit number
function M.by_unit(unit)
	local rec = unit_rec(unit)
	return rec and rec.entity and rec.entity.valid and rec.entity or nil
end

--- (tests, /me-stats) the queue and the number of blocks
function M.queue()
	local s = storage.fork_me_lif
	return s and s.q, s and #s.list or 0
end

remote.add_interface("gregtorio-me-logistic-interface", {
	info = function(entity) return M.info(entity) end,
	set_row = function(entity, tab, i, key, amount) return M.set_row(entity, tab, i, key, amount) end,
	set_amount = function(entity, tab, i, amount) return M.set_amount(entity, tab, i, amount) end,
	set_accept = function(entity, on) return M.set_accept(entity, on) end,
	set_filter = function(entity, key) return M.set_filter(entity, key) end,
	set_auto = function(entity, on) return M.set_auto(entity, on) end,                     -- (issue #532)
	set_mode = function(entity, mode) return M.set_mode(entity, mode) end,                 -- (issue #537)
	--- (tests, issue #537) the automatic mode's state: { auto (the stock per logistic network), dm (the pass: lid, phase, i),
	--- points (per logistic network the length of the point list) }
	demand = function()
		local s = storage.fork_me_lif
		if not s then return nil end
		local points = {}
		for lid, c in pairs(s.pts or {}) do points[lid] = #c.list end
		return { auto = s.auto, dm = s.dm and { lid = s.dm.lid, phase = s.dm.phase, i = s.dm.i } or nil, points = points }
	end,
	get_settings = function(entity)
		local rec = rec_of(entity)
		return rec and settings_of(rec) or nil
	end,
	--- (tests, issue #538) what construction needs in logistic network `lid`: { [key] = count }
	construction = function(lid)
		local out = {}
		for key, t in pairs(C.tally(lid)) do out[key] = t.n end
		return out
	end,
	--- the hidden chests: { provider, requester, store }
	chests = function(entity)
		local rec = rec_of(entity)
		return rec and { provider = rec.provider, requester = rec.requester, store = rec.store } or nil
	end,
	--- one visit now
	visit = function(entity)
		local rec = rec_of(entity)
		if not rec then return false end
		visit(rec, entity.unit_number, false)
		return true
	end,
	--- the runtime test's save and load check (issue #38): the block's schedule
	schedule = function(entity)
		local rec = rec_of(entity)
		if not rec then return nil end
		local due = rec.due
		return { due = (due and due > 0) and due or nil, interval = rec.iv, probing = rec.sq == true and not rec.park,
			front = due == Sched.FRONT, backlog = due == Sched.BACKLOG, parked = rec.park, lid = rec.lid }
	end,
	built = function(entity, tags, source, inv) M.on_built(entity, tags, source, nil, inv) end,   -- (`inv`: issue #590)
	removed = function(entity, buffer) M.on_removed(entity, buffer) end,
	paste = function(source, destination, player_index)
		M.on_entity_settings_pasted{ source = source, destination = destination, player_index = player_index }
	end,
	card_click = function(entity, slot, cursor, inventory, shift) return cards.card_click(entity, slot, cursor, inventory, shift) end,
	shift_in = function(entity, stack) return cards.shift_in(entity, stack) end,
	offered = function(lid) return offered_in(lid) end,
})

return M
