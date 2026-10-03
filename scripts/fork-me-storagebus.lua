--------------------------------------------------------------------------------
--- FORK AE2: ME STORAGE BUS (issue #68; issue #3 of me-network: items and fluids; prototypes/network.lua,
--- docs/ME-REWORK.md "Storage bus" and "Items and fluids in one block")
---   * A rotatable 1x1 ME block that faces a chest, a logistic chest, the editor's infinity chest or a cargo wagon:
---     that inventory becomes storage of the network (the item side, this module). Facing any other entity with a
---     fluid box (a storage tank), the fluid of that box's fluid segment becomes storage of the network (the fluid
---     side, scripts/fork-me-fluid-storagebus.lua: one bus per segment, the temperature rule). What it faces
---     decides, when the target is resolved; no target type has both. The terminal shows what is in it,
---     everything that extracts from the network can take from it, and inserts go into it by its filter and
---     priority.
---   * Settings: filters, items and fluids mixed (a whitelist of keys: the bus shows and takes only these; none =
---     everything), a priority (-1000 ... 1000, the order of R3 together with the drives) and a mode: read and
---     write, read only (the network takes from it, never puts into it) or write only (the network puts into it
---     and does not see what is in it). Kept in blueprints (tag fork_me_storage_bus), settings paste and clones.
---   * Issue #17, AE2's upgrade cards in 5 card slots (rec.cards): Capacity Cards (9 more filters each, up to 5), an
---     Inverter Card (the filters are a blacklist), a Fuzzy Card (a filter matches every quality), an Overflow
---     Destruction Card (what the network stores into the bus and does not fit is destroyed); the setting "filter on
---     extract" (rec.extract false: the filters decide only what goes in). The cards are items: put in and taken out
---     by hand in the window (issue #28: the items of a script inventory, rec.inv, shown as slots next to the
---     player's inventory drawn by the window; card_click and shift_in refuse a wrong card before it moves), given back when the bus is mined, spilled when it is destroyed or vanishes. Blueprints,
---     settings paste and clones copy which cards a bus wants (rec.want); it takes them from the player (paste) or
---     the network (at its visits), never out of nothing. apply() turns filters and cards into the fields the
---     storage engine reads (partition, deny, fnames, void, inonly).
---   * The bus's storage is an "external cell" of the storage engine (scripts/fork-me-network.lua): the
---     record below is that cell (ext = "storage-bus"; side = "fluid" and handler = "fluid-storage-bus" while it
---     faces fluid: the engine calls the fluid side's functions directly). Its `items` are a
---     snapshot of the inventory or segment; the engine keeps the network's totals and index from it.
---   * Consistency: inserters and players change the inventory without an event. Every bus is due at a tick
---     (issue #5, scripts/fork-me-schedule.lua; the fluid side has its own queue): the on_tick handler of control.lua
---     visits at most the setting "storage bus visits per tick" of them per side; a visit reads the inventory once
---     (get_contents) and applies the difference to the snapshot (N.ext_sync). A bus whose inventory changed is read
---     again after MIN_INTERVAL ticks, one that did not change twice as late each time, up to the storage bus idle
---     limit (a setting, 2 seconds by default): the longest time until the network sees a change. Between two visits the snapshot may be stale; every insert and extract through the bus works
---     on the real inventory (the engine asks `count` before it takes and corrects the snapshot), so the network
---     never hands out items that are gone; it may show items that are gone (until the next visit or extract) or
---     not yet show items that came in (until the next visit).
---   * Rules: one bus per inventory (a second bus on the same inventory is refused with a status and takes
---     over when the first one goes); a bus facing an ME block is refused (no loops); removing the bus or
---     the inventory drops the inventory from the network.
--- State: the records live in the network module (storage.fork_me_net.ext, they are the cells); this module
--- keeps the visit list of the item side and which bus uses which inventory (storage.fork_me_sbus).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local T = require("scripts.fork-me-targets")
local F = require("scripts.fork-me-fluid-storagebus")
local Sched = require("scripts.fork-me-schedule")
local G = require("scripts.fork-me-gui")

local M = {}

local KIND = "storage-bus"
local MIN_INTERVAL = 30             -- ticks until a bus whose inventory changed reads it again
local MAX_FILTERS = 18              -- the filters without a Capacity Card (AE2's 18)
local FILTER_LIMIT = 63             -- with five Capacity Cards (AE2: 18 + 5 x 9): what a bus keeps
local MAX_PRIORITY = 1000
local TAG = "fork_me_storage_bus"   -- blueprint tag: { mode, priority, filters = { keys }, extract, cards = { names } }
local OLD_TAG = "fork_me_fluid_storage_bus"   -- the old ME Fluid Storage Bus's tag: { mode, priority, filters = { fluid names } }
local MODES = { readwrite = true, read = true, write = true }
local INVENTORY = T.STORAGE
--- item types the network cannot hold as plain items (the same rule as the cells, M.storable of the network)
local NOT_PLAIN = {
	["item-with-inventory"] = true, ["item-with-tags"] = true, ["item-with-entity-data"] = true, ["blueprint"] = true,
	["blueprint-book"] = true, ["deconstruction-item"] = true, ["upgrade-item"] = true, ["copy-paste-tool"] = true,
	["selection-tool"] = true, ["spidertron-remote"] = true, ["armor"] = true,
}

local function state()
	local s = storage.fork_me_sbus
	if not s then
		s = { list = {}, cursor = 1, claims = {} }     -- claims: inventory owner unit -> bus unit
		storage.fork_me_sbus = s
	end
	return s
end

--- the queue of the item side's visits; a save from before issue #5 gets one with every bus due within a second,
--- a queue of 0.3.0 its probe list and counts (issue #38)
local function queue(s)
	local q = s.q
	if q and q.sl then return q end
	if not q then
		q = Sched.new("sbus")
		s.q = q
		for i, unit in ipairs(s.list) do
			local rec = N.ext_get(unit)
			if rec then
				rec.due, rec.inq, rec.sq = nil, nil, nil
				Sched.at(q, rec, unit, game.tick + 1 + (i - 1) % 60)
			end
		end
		return q
	end
	local recs = {}
	for _, unit in ipairs(s.list) do
		local rec = N.ext_get(unit)
		if rec then recs[#recs + 1] = rec end
	end
	return Sched.upgrade(q, recs, "sbus")
end

--- the idle limit of the item side (0.2.0 read 8 buses per 15 ticks: an idle bus never waits longer than that cycle)
local function idle_limit(s)
	return Sched.idle_limit(Sched.setting("storage_bus_idle"), #s.list, 8 / 15, MIN_INTERVAL)
end

local function is_bus(entity) return entity and entity.valid and N.kind_of(entity.name) == KIND end

--- the record (the external cell) of a bus
local function rec_of(entity)
	local rec = entity and entity.valid and entity.unit_number and N.ext_get(entity.unit_number) or nil
	return rec and rec.ext == KIND and rec or nil
end

--- is the bus in the item side's list? (a set beside the list, made when missing)
local function listed(s, unit)
	if not s.member then
		s.member = {}
		for _, u in ipairs(s.list) do s.member[u] = true end
	end
	return s.member[unit] == true
end

local function unlist(list, unit)
	for i = #list, 1, -1 do if list[i] == unit then table.remove(list, i) end end
end

--------------------------------------------------------------------------------
--- items
--------------------------------------------------------------------------------

local plain_cache = {}
--- can the network show and move this item through a storage bus? (plain items that do not spoil)
local function plain(name, quality)
	local k = name .. "@" .. quality
	local v = plain_cache[k]
	if v == nil then
		local p = prototypes.item[name]
		v = p ~= nil and not NOT_PLAIN[p.type] and p.get_spoil_ticks(quality) <= 0
		plain_cache[k] = v
	end
	return v
end

local accepts = N.accepts
--- may the network put `key` into the bus? (its filters: a whitelist, or a blacklist with an Inverter Card)
local function allowed(rec, key)
	local p = rec.partition
	if p then return p[key] == true or (rec.fnames ~= nil and accepts(rec, key)) end
	return rec.deny == nil or accepts(rec, key)
end
--- may the network see and take `key`? (the same, unless the bus filters only what goes in: issue #17)
local function shown(rec, key) return rec.inonly == true or allowed(rec, key) end

--- the target inventory if the bus may use it now (a cargo wagon only while it stands in front of the bus)
local function inventory_of(rec)
	local t = rec.target
	if not (t and t.valid) then return nil end
	if t.type == "cargo-wagon" then                      -- a train moves: the wagon must still cover the tile in front
		local e = rec.entity
		local here = e.surface.find_entities_filtered{ position = T.front(e), type = "cargo-wagon", limit = 1 }[1]
		if here ~= t then return nil end
	end
	return t.get_inventory(INVENTORY[t.type])
end

--------------------------------------------------------------------------------
--- the external cell's functions (called by the storage engine); the fluid side's are F.handlers
--------------------------------------------------------------------------------

local function item_of(key)
	if N.is_fluid_key(key) or key:find("#", 1, true) then return nil end
	local name, q = N.parse_key(key)
	if not plain(name, q) then return nil end
	return name, q
end

local ITEM = {
	--- items of `key` the inventory takes now
	room = function(rec, key)
		if rec.mode == "read" or not allowed(rec, key) then return 0 end
		local name, q = item_of(key)
		local inv = name and inventory_of(rec)
		if not inv then return 0 end
		return inv.get_insertable_count{ name = name, quality = q }
	end,
	--- put up to `count` into the inventory; returns the count inserted
	insert = function(rec, key, count)
		if rec.mode == "read" or not allowed(rec, key) then return 0 end
		local name, q = item_of(key)
		local inv = name and inventory_of(rec)
		if not inv then return 0 end
		return inv.insert{ name = name, quality = q, count = count }
	end,
	--- the real count of `key` in the inventory (0 when the bus cannot take from it)
	count = function(rec, key)
		if rec.mode == "write" or not shown(rec, key) then return 0 end
		local name, q = item_of(key)
		local inv = name and inventory_of(rec)
		if not inv then return 0 end
		return inv.get_item_count{ name = name, quality = q }
	end,
	--- take up to `count` out of the inventory; returns the count removed
	extract = function(rec, key, count)
		if rec.mode == "write" then return 0 end
		local name, q = item_of(key)
		local inv = name and inventory_of(rec)
		if not inv then return 0 end
		return inv.remove{ name = name, quality = q, count = count }
	end,
	--- issue #17, an Overflow Destruction Card: is what does not fit of `key` destroyed? (the bus takes the key and
	--- works on an inventory now; a bus facing nothing destroys nothing)
	voids = function(rec, key)
		if rec.mode == "read" or not allowed(rec, key) then return false end
		return item_of(key) ~= nil and rec.status == "ok" and inventory_of(rec) ~= nil
	end,
	--- the bus's record leaves the storage engine: a card still in it is spilled (a bus that vanished without an event)
	detached = function(rec) M.detach(rec) end,
}

N.ext_handlers[KIND] = ITEM             -- the fluid side: N.ext_handlers[F.HANDLER] through rec.handler

--------------------------------------------------------------------------------
--- target and visit
--------------------------------------------------------------------------------

local function release(s, rec)
	local tu = rec.target_unit
	if tu and s.claims[tu] == rec.unit then s.claims[tu] = nil end
	rec.target, rec.target_unit = nil, nil
end

--- is the inventory owner `tu` used by another bus that still faces it?
local function claimed_by_other(s, rec, tu)
	local other = s.claims[tu]
	if not other or other == rec.unit then return false end
	local o = N.ext_get(other)
	if o and o.entity.valid and o.side ~= "fluid" and o.target_unit == tu and o.target and o.target.valid then return true end
	s.claims[tu] = nil                                   -- a stale claim (bus gone, turned away or on fluid now)
	return false
end

--- put the bus into the visit list of its side (and out of the other one); a bus new to a side is due at once
local function list_side(s, rec)
	if rec.side == "fluid" then
		if listed(s, rec.unit) then
			unlist(s.list, rec.unit)
			s.member[rec.unit] = nil
			Sched.forget(queue(s), rec)
		end
		F.list(rec)
	else
		F.unlist(rec)
		if not listed(s, rec.unit) then
			s.list[#s.list + 1] = rec.unit
			s.member[rec.unit] = true
			rec.siv = nil
			Sched.at(queue(s), rec, rec.unit, game.tick + 1)
		end
	end
end

--- The entity in front of the bus: an inventory makes it an item side bus (rec.target, claimed), any other entity
--- with a fluid box a fluid side bus (F.take: rec.target and rec.box); sets rec.side and rec.status. A valid cached
--- target is kept.
local function resolve(s, rec)
	local e = rec.entity
	local t = rec.target
	if t and t.valid and rec.dir == e.direction then
		if rec.side == "fluid" then
			if rec.box then return t end
		elseif t.type ~= "cargo-wagon" or inventory_of(rec) then
			rec.status = "ok"
			return t
		end
	end
	release(s, rec)
	F.drop(rec)
	rec.dir = e.direction
	local status, side = "no-target", nil
	for _, o in pairs(e.surface.find_entities_filtered{ position = T.front(e) }) do
		if o.valid and o ~= e then
			if N.kind_of(o.name) or o.name:sub(1, 3) == "me-" then
				status = "me-target"                     -- an ME block (or an old ME chest, an interface's side): no loops
				break
			elseif INVENTORY[o.type] and o.unit_number then
				if claimed_by_other(s, rec, o.unit_number) then
					status = "shared-target"
				else
					s.claims[o.unit_number] = rec.unit
					rec.target, rec.target_unit = o, o.unit_number
					status = nil
				end
				break
			elseif F.take(rec, o) then
				side, status = "fluid", nil
				break
			end
		end
	end
	if rec.side ~= side then
		rec.side, rec.handler = side, side and F.HANDLER or nil
		N.ext_sync(rec.unit, {})                         -- the other side's snapshot goes
		N.ext_touch(rec.unit)                            -- it takes the other kind of keys now (the insertion lists)
	end
	list_side(s, rec)
	rec.status = status or "ok"
	return rec.target
end

--- One visit: find the target, read its inventory (or segment) once and apply the difference to the network.
--- Returns true when the snapshot or the target changed.
function M.visit(rec, cascade)
	local s = state()
	local e = rec.entity
	if not e.valid then return false end
	local before = rec.target
	local t = resolve(s, rec)
	if rec.side == "fluid" then
		local changed = F.visit(rec, cascade)
		if rec.want then M.fill_cards(rec) end
		return changed
	end
	local contents = {}
	local inv = t and inventory_of(rec)
	if inv and rec.mode ~= "write" then
		local all = rec.inonly or not (rec.partition or rec.deny)    -- (no filter to check: the common case)
		for _, it in pairs(inv.get_contents()) do
			local q = it.quality or "normal"
			if plain(it.name, q) then
				local key = N.key_of(it.name, q)
				if all or shown(rec, key) then contents[key] = (contents[key] or 0) + it.count end
			end
		end
	end
	local changed = N.ext_sync(rec.unit, contents) or before ~= rec.target
	if rec.status == "ok" then
		local net = N.network_of(e)
		local ok, why = N.usable(net)
		if not ok then rec.status = why or "no-network" end
	end
	if rec.want then M.fill_cards(rec) end
	return changed
end
--- the fluid side visits through this when its target is gone or the bus was rotated (it may face a chest now)
F.resolve_visit = function(rec, cascade) return M.visit(rec, cascade) end
F.lost = function(rec) list_side(state(), rec) end

--- the record of an item side bus that is due (nil when it is gone or on the fluid side now)
local function item_rec(unit)
	local rec = N.ext_get(unit)
	if rec and rec.ext == KIND and rec.side ~= "fluid" then return rec end
	return nil
end

local function visit_due(rec, unit)
	local s = storage.fork_me_sbus
	if not rec.entity.valid then
		unlist(s.list, unit)
		if s.member then s.member[unit] = nil end
		Sched.forget(queue(s), rec)
		N.ext_detach(unit)
		return
	end
	local changed = M.visit(rec)
	if rec.side == "fluid" then return end           -- on the fluid side now: its queue has it
	rec.siv = Sched.interval(rec.siv, changed and 1 or 0, true, MIN_INTERVAL, MIN_INTERVAL, idle_limit(s))
	Sched.at(queue(s), rec, unit, game.tick + rec.siv, not changed)   -- (unchanged: asleep until then)
	return changed and 1 or 0
end

--- every tick (control.lua): the item side buses that are due (the reads per tick are what is due, between the
--- settings "at least" and "at most"; an unchanged bus is read at its growing interval, the probe list), then the
--- fluid side's
function M.on_tick(tick)
	local s = storage.fork_me_sbus
	if s and #s.list > 0 then
		Sched.run(queue(s), tick, Sched.setting("storage_bus"), Sched.setting("storage_bus_max"), item_rec, visit_due, visit_due,
			"storage_bus")
	end
	F.on_tick(tick)
end

--- read the inventory or segment at the next tick (an entity was built in front of the bus)
function M.wake(unit)
	local rec = N.ext_get(unit)
	if not (rec and rec.ext == KIND) then return end
	rec.target = nil
	if rec.side == "fluid" then
		F.wake(rec)
	else
		local s = storage.fork_me_sbus
		if s and listed(s, unit) then
			rec.siv = nil
			Sched.wake(queue(s), rec, unit)
		end
	end
end

local bus_names
--- an entity was built: the storage buses facing it read it at the next tick
function M.wake_near(entity)
	if not (storage.fork_me_sbus and (T.STORAGE[entity.type] or T.has_fluid_boxes(entity))) then return end
	if not bus_names then
		bus_names = {}
		for _, name in pairs(N.node_names()) do
			if N.kind_of(name) == KIND then bus_names[#bus_names + 1] = name end
		end
	end
	local b = entity.bounding_box
	for _, bus in pairs(entity.surface.find_entities_filtered{ name = bus_names,
		area = { { b.left_top.x - 1, b.left_top.y - 1 }, { b.right_bottom.x + 1, b.right_bottom.y + 1 } } }) do
		local f = T.front(bus)
		if f[1] > b.left_top.x and f[1] < b.right_bottom.x and f[2] > b.left_top.y and f[2] < b.right_bottom.y then
			M.wake(bus.unit_number)
		end
	end
end

--------------------------------------------------------------------------------
--- settings
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
--- issue #17: the card slots
--------------------------------------------------------------------------------

local function rules() return N.card_rules().storage_bus end

--- the cards of a bus by kind: { capacity = n, ... }
local function card_counts(rec)
	local out = {}
	for _, name in pairs(rec.cards or {}) do
		local kind = N.card_kind(name)
		if kind then out[kind] = (out[kind] or 0) + 1 end
	end
	return out
end

--- the filters that apply: 18, and 9 more per Capacity Card (AE2)
local function filter_count(rec)
	local r = rules()
	return r.filters + r.per_capacity * (card_counts(rec).capacity or 0)
end

--- The fields the storage engine reads, from the filters, the cards and the settings: `partition` (whitelist) or
--- `deny` (blacklist, Inverter Card) of the first filter_count() filters, `fnames` (Fuzzy Card: the item names),
--- `void` (Overflow Destruction Card), `inonly` (filter only what goes in). A bus without cards and with the default
--- settings gets exactly the fields of 0.3.0.
local function apply(rec)
	local counts = card_counts(rec)
	local set, names
	local n = filter_count(rec)
	for i, key in ipairs(rec.filters or {}) do
		if i > n then break end
		set = set or {}
		set[key] = true
		if counts.fuzzy and not N.is_fluid_key(key) then
			names = names or {}
			names[(N.parse_key(key))] = true
		end
	end
	if counts.inverter then rec.partition, rec.deny = nil, set else rec.partition, rec.deny = set, nil end
	rec.fnames = names
	rec.void = counts.void and true or nil
	rec.inonly = rec.extract == false or nil
	N.ext_touch(rec.unit)
end

--- where a bus's cards go when nobody takes them: its position (kept, a bus can vanish without an event)
local function remember_place(rec)
	local e = rec.entity
	if e and e.valid then rec.where = { surface = e.surface.index, x = e.position.x, y = e.position.y } end
end

--- Issue #28: the card slots are a script inventory (rec.inv) whose slots the bus's window shows. Its stacks are the
--- cards; rec.cards ({ [slot] = name }) is what apply(), the window and the settings read,
--- made from the slots by sync() and by every function here that moves a card. A bus of a save before issue #28 kept
--- only the names: its inventory is made here, with a card item for each name (the version number may not change, so
--- no on_configuration_changed has to run first).
function M.inv_of(rec)
	local inv = rec.inv
	if inv and inv.valid then return inv end
	local e = rec.entity
	inv = game.create_inventory(rules().slots, e and e.valid and e.localised_name or { "entity-name.me-storage-bus" })
	for slot, name in pairs(rec.cards or {}) do
		if type(slot) == "number" and slot <= #inv and type(name) == "string" and prototypes.item[name] then
			inv[slot].set_stack{ name = name, count = 1 }
		end
	end
	rec.inv = inv
	return inv
end
local inv_of = M.inv_of

--- every stack in the card slots onto the ground (destroyed, vanished); the slots are empty afterwards
function M.spill_cards(rec)
	local inv = inv_of(rec)
	local e = rec.entity
	local surface, pos
	if e and e.valid then surface, pos = e.surface, e.position
	elseif rec.where then surface, pos = game.get_surface(rec.where.surface), { rec.where.x, rec.where.y } end
	for slot = 1, #inv do
		local stack = inv[slot]
		if stack.valid_for_read and surface then
			surface.spill_item_stack{ position = pos, stack = stack, allow_belts = false }
			stack.clear()
		end
	end
	rec.cards = {}
end

--- into `target` (LuaInventory or mined buffer), what does not fit onto the ground: everything in the slots, also an
--- item a sync has not seen yet
local function give_cards(rec, target)
	local inv = inv_of(rec)
	for slot = 1, #inv do
		local stack = inv[slot]
		if stack.valid_for_read and target and target.valid then
			local got = target.insert(stack)
			if got >= stack.count then stack.clear() elseif got > 0 then stack.count = stack.count - got end
		end
	end
	M.spill_cards(rec)
end

--- the record and its inventory leave (the storage engine dropped the cell): what is still in the slots is spilled
function M.detach(rec)
	M.spill_cards(rec)
	if rec.inv and rec.inv.valid and rec.inv.is_empty() then rec.inv.destroy() end
end

--- can the bus take one more card `name`? (a card of a kind it takes, below that kind's limit, an empty slot)
local function card_fits(rec, name)
	local kind = N.card_kind(name)
	local limit = kind and rules().limits[kind]
	if not limit then return false, "not-here" end
	if (card_counts(rec)[kind] or 0) >= limit then return false, "limit" end
	local inv = inv_of(rec)
	for slot = 1, rules().slots do
		if not inv[slot].valid_for_read then return slot end
	end
	return false, "full"
end

--- one card into the empty slot `slot`: from `from` (a LuaItemStack: one of it is moved, quality and all) or a new
--- stack of `name` (taken from the network by the caller)
local function install(rec, slot, name, from)
	local inv = inv_of(rec)
	if from then inv[slot].transfer_stack(from, 1) else inv[slot].set_stack{ name = name, count = 1 } end
	rec.cards = rec.cards or {}
	rec.cards[slot] = inv[slot].valid_for_read and inv[slot].name or nil
	remember_place(rec)
end

--- the cards of a bus as a list of names (slot order); nil when it has none
local function card_list(rec)
	local out
	for slot = 1, rules().slots do
		local name = rec.cards and rec.cards[slot]
		if name then
			out = out or {}
			out[#out + 1] = name
		end
	end
	return out
end

--- Issue #28: the card slots checked (the migration's backstop and the tests; the window's clicks refuse before they
--- move anything, so this finds nothing to do after them). One card per slot, of a kind the
--- bus takes, within its kind's limit: the cards that were in their slot already are kept first, then the new ones in
--- slot order; a second card of one stack goes into an empty slot when it may, else back to `back` (G.give_back: the
--- player, a LuaInventory, nil for the ground at the bus) with every other item. rec.cards follows the slots; a change
--- takes the bus out of waiting for blueprint cards (the player decides now). Returns true when the slots or the
--- cards changed.
function M.sync(rec, back)
	local inv = inv_of(rec)
	local r = rules()
	local old = rec.cards or {}
	local counts, kept, moved = {}, {}, false
	local function take(name)
		local kind = N.card_kind(name)
		local limit = kind and r.limits[kind]
		if not limit or (counts[kind] or 0) >= limit then return false end
		counts[kind] = (counts[kind] or 0) + 1
		return true
	end
	for pass = 1, 2 do
		for slot = 1, math.min(#inv, r.slots) do
			local stack = inv[slot]
			if stack.valid_for_read and not kept[slot] and (old[slot] == stack.name) == (pass == 1) and take(stack.name) then
				kept[slot] = true
			end
		end
	end
	for slot = 1, #inv do
		local stack = inv[slot]
		if stack.valid_for_read then
			local extra = kept[slot] and stack.count - 1 or stack.count
			while extra > 0 do
				local free
				if N.card_kind(stack.name) then
					for i = 1, math.min(#inv, r.slots) do
						if not inv[i].valid_for_read then free = i break end
					end
				end
				if free and take(stack.name) then
					inv[free].transfer_stack(stack, 1)
					kept[free] = true
					extra = extra - 1
				else
					G.give_back(back, stack, rec.entity, extra)
					extra = 0
				end
				moved = true
			end
		end
	end
	local cards, changed = {}, moved
	for slot = 1, r.slots do
		local stack = inv[slot]
		cards[slot] = kept[slot] and stack.valid_for_read and stack.name or nil
		if cards[slot] ~= old[slot] then changed = true end
	end
	if not changed then return false end
	rec.cards = cards
	rec.want = nil
	remember_place(rec)
	apply(rec)
	M.visit(rec)
	return true
end

--- A click on card slot `slot` of the window. With a card in the cursor one card of it goes in (into `slot`, else the
--- first empty slot); a card the bus does not take, one beyond its kind's limit or one without an empty slot is refused
--- before anything moves (the reason is returned, the cursor keeps it). With an empty cursor the card in the slot goes
--- into the cursor (`shift`: into `inventory`). Takes the bus out of waiting for blueprint cards.
function M.card_click(entity, slot, cursor, inventory, shift)
	local rec = rec_of(entity)
	if not rec then return "no-bus" end
	local inv = inv_of(rec)
	if cursor and cursor.valid_for_read then
		local free, why = card_fits(rec, cursor.name)
		if not free then return why end
		if slot >= 1 and slot <= rules().slots and not inv[slot].valid_for_read then free = slot end
		install(rec, free, nil, cursor)
	else
		local stack = slot >= 1 and slot <= #inv and inv[slot]
		if not (stack and stack.valid_for_read) then return nil end
		if shift then
			if not (inventory and inventory.valid and inventory.insert(stack) >= 1) then return "inventory-full" end
			stack.clear()
		elseif not (cursor and cursor.transfer_stack(stack)) then
			return "inventory-full"
		end
		if rec.cards then rec.cards[slot] = nil end
	end
	rec.want = nil
	apply(rec)
	M.visit(rec)
	return nil
end

--- Issue #28: shift + click on stack `stack` of the player's inventory in the bus's window: its cards go into the empty
--- slots, one each, as far as the kind's limit allows; the rest stays in the stack. Returns the reason when none goes
--- in (nothing moved then).
function M.shift_in(entity, stack)
	local rec = rec_of(entity)
	if not rec then return "no-bus" end
	if not (stack and stack.valid_for_read) then return nil end
	local moved, why = 0, nil
	while stack.valid_for_read do
		local free
		free, why = card_fits(rec, stack.name)
		if not free then break end
		install(rec, free, nil, stack)
		moved = moved + 1
	end
	if moved == 0 then return why end
	rec.want = nil
	apply(rec)
	M.visit(rec)
	return nil
end

--- the missing ones of `want` (a list of names) for the cards a bus has, as a list
local function missing_cards(rec, want)
	local have = {}
	for _, name in pairs(rec.cards or {}) do have[name] = (have[name] or 0) + 1 end
	local out = {}
	for _, name in ipairs(want) do
		if (have[name] or 0) > 0 then have[name] = have[name] - 1 else out[#out + 1] = name end
	end
	return out, have
end

--- the wanted cards the bus still lacks, taken from the network (one each); rec.want is dropped once nothing is missing
--- or nothing missing can ever go in
function M.fill_cards(rec)
	local want = rec.want
	if not want then return end
	local missing = missing_cards(rec, want)
	local net = N.active_of(rec.entity)
	local changed = false
	for _, name in ipairs(missing) do
		local slot = card_fits(rec, name)
		if slot and net and N.count(net, name, "normal") >= 1 and N.extract(net, name, "normal", 1) == 1 then
			install(rec, slot, name)
			changed = true
		end
	end
	local left = missing_cards(rec, want)
	local possible = false
	for _, name in ipairs(left) do if card_fits(rec, name) then possible = true end end
	if not possible then rec.want = nil end
	if changed then apply(rec) end
end

--- The bus is to have the cards `want` (names; a blueprint, a settings paste, a clone). Cards it has beyond them go
--- to `player` (inventory, else the network, else the ground at the player); missing ones come from the player's
--- inventory, then from the network, else the bus waits for them (rec.want). `player` nil: only the network.
function M.want_cards(entity, want, player)
	local rec = rec_of(entity)
	if not rec then return false end
	local inv = inv_of(rec)
	local list = {}
	for _, name in ipairs(type(want) == "table" and want or {}) do
		if type(name) == "string" and N.card_kind(name) and #list < rules().slots then list[#list + 1] = name end
	end
	--- what is too many goes first (so the limits leave room for the wanted ones)
	local _, extra = missing_cards(rec, list)
	local net = N.active_of(entity)
	local pinv = player and player.valid and player.get_main_inventory()
	for slot = 1, rules().slots do
		local name = rec.cards and rec.cards[slot]
		local stack = inv[slot]
		if name and (extra[name] or 0) > 0 and stack.valid_for_read then
			extra[name] = extra[name] - 1
			rec.cards[slot] = nil
			local got = pinv and pinv.insert(stack) or 0
			if got >= stack.count then stack.clear() end
			if stack.valid_for_read and net and N.insert(net, stack.name, stack.quality.name, stack.count) >= stack.count then stack.clear() end
			if stack.valid_for_read then
				local where = player and player.valid and player.character and player.character.valid and player.character or entity
				where.surface.spill_item_stack{ position = where.position, stack = stack, allow_belts = false }
				stack.clear()
			end
		end
	end
	for _, name in ipairs(missing_cards(rec, list)) do
		local slot = card_fits(rec, name)
		local from = slot and pinv and pinv.find_item_stack(name)
		if from then install(rec, slot, nil, from) end
	end
	rec.want = #missing_cards(rec, list) > 0 and list or nil
	apply(rec)
	if rec.want then M.fill_cards(rec) end
	M.visit(rec)
	return true
end

--- filters checked against the prototypes: a list of keys ("name", "name@quality", "fluid/<name>"; a plain name
--- that is no item but a fluid is that fluid), at most FILTER_LIMIT (the first filter_count() of them apply)
local function clean_filters(filters)
	local out, seen = {}, {}
	if type(filters) ~= "table" then return out end
	for _, key in ipairs(filters) do
		if type(key) == "string" and #out < FILTER_LIMIT and not key:find("#", 1, true) then
			local k
			if N.is_fluid_key(key) then
				if prototypes.fluid[key:sub(7)] then k = key end
			else
				local name, q = N.parse_key(key)
				if prototypes.item[name] and prototypes.quality[q] then k = N.key_of(name, q)
				elseif prototypes.fluid[key] then k = "fluid/" .. key end
			end
			if k and not seen[k] then
				seen[k] = true
				out[#out + 1] = k
			end
		end
	end
	return out
end

--- the settings of a bus: { mode, priority, filters = { keys }, extract = false (only when the filters decide only
--- what goes in), cards = { names } (the cards it has, or waits for; only when there are any) }
function M.get_settings(entity)
	local rec = rec_of(entity)
	if not rec then return nil end
	local out = { mode = rec.mode, priority = rec.priority or 0, filters = { table.unpack(rec.filters) },
		cards = rec.want and { table.unpack(rec.want) } or card_list(rec) }
	if rec.extract == false then out.extract = false end
	return out
end

--- Apply settings (missing fields keep their value; `cards` is not a setting: want_cards). The inventory or segment
--- is read again at once, so the network shows what the new filter and mode allow.
function M.set_settings(entity, settings)
	local rec = rec_of(entity)
	if not (rec and type(settings) == "table") then return false end
	if MODES[settings.mode] then rec.mode = settings.mode end
	if settings.priority ~= nil then
		local p = math.floor(tonumber(settings.priority) or 0)
		rec.priority = math.max(-MAX_PRIORITY, math.min(MAX_PRIORITY, p))
	end
	if settings.filters ~= nil then rec.filters = clean_filters(settings.filters) end
	if settings.extract == false then rec.extract = false elseif settings.extract ~= nil then rec.extract = nil end
	rec.hidden = rec.mode == "write" or nil
	apply(rec)
	M.visit(rec)
	return true
end

function M.set_mode(entity, mode) return M.set_settings(entity, { mode = mode }) end
function M.set_priority(entity, priority) return M.set_settings(entity, { priority = priority }) end
function M.set_filters(entity, filters) return M.set_settings(entity, { filters = filters }) end

--- one filter button of the window: `key` nil removes it; the list stays packed
function M.set_filter(entity, index, key)
	local rec = rec_of(entity)
	if not rec then return false end
	local list = {}
	for i = 1, math.max(#rec.filters, filter_count(rec)) do
		local v
		if i == index then v = key else v = rec.filters[i] end
		if v then list[#list + 1] = v end
	end
	return M.set_filters(entity, list)
end

--- AE2's "partition storage": the filters become what the chest or the tank's segment holds now (plain items that
--- the network can hold, in any order of their count; at most the filters that apply)
function M.filters_from_contents(entity)
	local rec = rec_of(entity)
	if not rec then return false end
	local s = state()
	local t = resolve(s, rec)
	local keys = {}
	if rec.side == "fluid" then
		local f = F.contents(rec)
		for name in pairs(f) do keys[#keys + 1] = "fluid/" .. name end
	else
		local inv = t and inventory_of(rec)
		for _, it in pairs(inv and inv.get_contents() or {}) do
			local q = it.quality or "normal"
			if plain(it.name, q) then keys[#keys + 1] = N.key_of(it.name, q) end
		end
	end
	table.sort(keys)
	local n = filter_count(rec)
	while #keys > n do keys[#keys] = nil end
	return M.set_settings(entity, { filters = keys })
end

function M.clear_filters(entity) return M.set_settings(entity, { filters = {} }) end

--- the filters that apply to the bus now (18, more with Capacity Cards)
function M.max_filters(entity)
	local rec = rec_of(entity)
	return rec and filter_count(rec) or MAX_FILTERS
end

--- issue #28: the inventory of the card slots (the window shows its slots), and its check after a change (`back`: the player
--- who changed it, or a LuaInventory; what may not be there goes there)
function M.inventory(entity)
	local rec = rec_of(entity)
	return rec and inv_of(rec) or nil
end

function M.sync_entity(entity, back)
	local rec = rec_of(entity)
	return rec ~= nil and M.sync(rec, back)
end

--- the window's data: { side, mode, priority, filters, max, status, target, items, types, contents; on fluid also
--- fluid, amount, temperature, segment; issue #17: cards = { [slot] = name }, slots, want (the cards it waits for),
--- extract, inverted, fuzzy, void, voided (amount destroyed so far) }
function M.info(entity)
	local rec = rec_of(entity)
	if not rec then return nil end
	local items, types = 0, 0
	for _, n in pairs(rec.items) do
		items = items + n
		types = types + 1
	end
	local t = rec.target
	local cards = {}
	for slot, name in pairs(rec.cards or {}) do cards[slot] = name end
	local counts = card_counts(rec)
	local out = { side = rec.side or "item", mode = rec.mode, priority = rec.priority or 0,
		filters = { table.unpack(rec.filters) }, max = filter_count(rec), status = rec.status or "ok",
		target = t and t.valid and t.name or nil, items = items, types = types, contents = rec.items,
		cards = cards, slots = rules().slots, want = rec.want and missing_cards(rec, rec.want) or nil,
		extract = rec.extract ~= false, inverted = counts.inverter ~= nil, fuzzy = counts.fuzzy ~= nil,
		void = rec.void == true, voided = rec.voided or 0 }
	if rec.side == "fluid" then
		out.fluid, out.amount, out.temperature, out.segment = rec.fluid, items, rec.temp, rec.seg
	end
	return out
end

M.MAX_FILTERS = MAX_FILTERS
M.FILTER_LIMIT = FILTER_LIMIT

--------------------------------------------------------------------------------
--- events
--------------------------------------------------------------------------------

local function register(entity)
	local s = state()
	local unit = entity.unit_number
	local rec = N.ext_get(unit)
	if not (rec and rec.ext == KIND) then
		rec = { ext = KIND, unit = unit, entity = entity, items = {}, data = {}, mode = "readwrite", priority = 0,
			filters = {}, status = "no-target" }
		N.ext_attach(entity, rec)
	end
	list_side(s, rec)
	return rec
end

--- the settings of a blueprint tag: issue #3 / the item bus's { mode, priority, filters = keys }, or the old fluid
--- storage bus's { mode, priority, filters = fluid names }
local function settings_of_tags(tags)
	if type(tags) ~= "table" then return nil end
	if type(tags[TAG]) == "table" then return tags[TAG] end
	local old = tags[OLD_TAG]
	if type(old) ~= "table" then return nil end
	local filters = {}
	for _, name in ipairs(old.filters or {}) do
		if type(name) == "string" then filters[#filters + 1] = N.is_fluid_key(name) and name or ("fluid/" .. name) end
	end
	return { mode = old.mode, priority = old.priority, filters = filters }
end
M.settings_of_tags = settings_of_tags

--- `tags`: blueprint tags of a built ghost; `source`: the original of a clone. The cards of the tag or the source are
--- wanted, taken from the network (issue #17): never copied.
function M.on_built(entity, tags, source)
	if not is_bus(entity) then return end
	local rec = register(entity)
	local t = settings_of_tags(tags)
	if not t and source and is_bus(source) then t = M.get_settings(source) end
	if t then
		M.set_settings(entity, t)
		if type(t.cards) == "table" and #t.cards > 0 then M.want_cards(entity, t.cards, nil) end
	else
		M.visit(rec)
	end
end

--- a removed entity: a bus lets its inventory or segment go (the network module drops its cell); its cards go into
--- `buffer` (mined) or onto the ground (destroyed, removed by a script); an inventory a bus uses leaves the network at
--- once; a removed fluid entity is the fluid side's business
function M.on_removed(entity, buffer)
	if not (entity and entity.valid and entity.unit_number) then return end
	local s = storage.fork_me_sbus
	local unit = entity.unit_number
	local rec = N.ext_get(unit)
	if rec and rec.ext == KIND then
		give_cards(rec, buffer)
		if s then
			release(s, rec)
			unlist(s.list, unit)
			Sched.forget(queue(s), rec)
			if s.member then s.member[unit] = nil end
		end
		F.drop(rec)
		F.unlist(rec)
		return
	end
	local bus = s and s.claims[unit]
	if bus then
		s.claims[unit] = nil
		local r = N.ext_get(bus)
		if r and r.target_unit == unit then
			r.target, r.target_unit, r.status = nil, nil, "no-target"
			N.ext_sync(bus, {})
		end
	end
	F.on_removed(entity)
end

function M.on_rotated(entity)
	local rec = is_bus(entity) and rec_of(entity)
	if rec then M.visit(rec) end
end

--- settings paste between buses: the settings, and the source's cards are wanted (from the player, then the network;
--- cards beyond them go to the player)
function M.on_entity_settings_pasted(event)
	local src, dst = event.source, event.destination
	if not (is_bus(src) and is_bus(dst)) then return end
	local st = M.get_settings(src)
	if st.extract == nil then st.extract = true end
	M.set_settings(dst, st)
	M.want_cards(dst, st.cards or {}, event.player_index and game.get_player(event.player_index) or nil)
end

--- blueprint hook of the autocrafting module (one on_player_setup_blueprint handler)
function M.tag_blueprint(bp, mapping)
	for index, entity in pairs(mapping) do
		if is_bus(entity) then
			local st = M.get_settings(entity)
			if st and (st.mode ~= "readwrite" or st.priority ~= 0 or #st.filters > 0 or st.extract == false or st.cards) then
				bp.set_blueprint_entity_tag(index, TAG, st)
			end
		end
	end
end

--- after the graph rebuild: every storage bus has a record and is in the visit list of its side, targets are found
--- again (the fluid side claims its segments in unit order)
function M.on_configuration_changed()
	local s = state()
	s.list, s.cursor, s.claims, s.member, s.q = {}, 1, {}, {}, Sched.new("sbus")
	F.reset()
	plain_cache, bus_names = {}, nil
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
		rec.target, rec.target_unit, rec.dir, rec.box, rec.seg = nil, nil, nil, nil, nil
		rec.filters = clean_filters(rec.filters)          -- (a save before issue #3 had item keys only: unchanged)
		inv_of(rec)                                       -- issue #28: the card names of an older save become the slots' cards
		if rec.cards or rec.extract == false then apply(rec) end   -- (no cards before issue #17: the fields stay)
	end
	for _, e in ipairs(all) do M.visit(N.ext_get(e.unit_number)) end
end

remote.add_interface("gregtorio-me-storagebus", {
	--- issue #38 (tests): when the bus reads next: { due, interval, probing, front, backlog, side }
	schedule = function(entity)
		local rec = rec_of(entity)
		if not rec then return nil end
		local due = rec.due
		return { due = (due and due > 0) and due or nil, interval = rec.siv, probing = rec.sq == true,
			front = due == Sched.FRONT, backlog = due == Sched.BACKLOG, side = rec.side or "item" }
	end,
	--- one visit now (what the I/O step does)
	visit = function(entity)
		local rec = rec_of(entity)
		if rec then M.visit(rec) end
		return rec ~= nil
	end,
	info = function(entity) return M.info(entity) end,
	get_settings = function(entity) return M.get_settings(entity) end,
	set_settings = function(entity, settings) return M.set_settings(entity, settings) end,
	set_filter = function(entity, index, key) return M.set_filter(entity, index, key) end,
	--- `player_index`: the player of a settings paste (cards from and to its inventory)
	paste = function(source, destination, player_index)
		M.on_entity_settings_pasted{ source = source, destination = destination, player_index = player_index }
	end,
	tag_blueprint = function(bp, mapping) M.tag_blueprint(bp, mapping) end,
	--- what a build event does (`tags`: blueprint tags, `source`: the original of a clone)
	built = function(entity, tags, source) M.on_built(entity, tags, source) end,
	--- what the removal events do for an inventory a bus uses (destroy() raises none); `buffer`: a mined bus's cards
	removed = function(entity, buffer) M.on_removed(entity, buffer) end,
	rotated = function(entity) M.on_rotated(entity) end,
	--- issue #17: the card slots (the window's click: a LuaItemStack as the cursor), wanted cards, the partition buttons
	card_click = function(entity, slot, cursor, inventory, shift) return M.card_click(entity, slot, cursor, inventory, shift) end,
	want_cards = function(entity, want, player_index)
		return M.want_cards(entity, want, player_index and game.get_player(player_index) or nil)
	end,
	from_contents = function(entity) return M.filters_from_contents(entity) end,
	clear = function(entity) return M.clear_filters(entity) end,
	--- issue #28: the card slots' inventory, and what a change by a player does (`back`: a LuaInventory standing for the
	--- player's inventory); returns true when the slots or the cards changed
	inventory = function(entity) return M.inventory(entity) end,
	sync = function(entity, back) return M.sync_entity(entity, back) end,
	--- shift + click on a stack of the player's inventory in the window: its cards into the empty slots
	shift_in = function(entity, stack) return M.shift_in(entity, stack) end,
})

--- issue #3: the old remote of the ME Fluid Storage Bus works on the storage bus (its fluid side)
remote.add_interface("gregtorio-me-fluid-storagebus", {
	visit = function(entity)
		local rec = rec_of(entity)
		if rec then M.visit(rec) end
		return rec ~= nil
	end,
	--- the fluid side's part of the I/O step (urgent visits, then the round robin)
	step = function() F.on_step() end,
	info = function(entity) return M.info(entity) end,
	get_settings = function(entity) return M.get_settings(entity) end,
	set_settings = function(entity, settings) return M.set_settings(entity, settings) end,
	set_filter = function(entity, index, key) return M.set_filter(entity, index, key) end,
	paste = function(source, destination) M.on_entity_settings_pasted{ source = source, destination = destination } end,
	tag_blueprint = function(bp, mapping) M.tag_blueprint(bp, mapping) end,
	built = function(entity, tags, source) M.on_built(entity, tags, source) end,
	removed = function(entity) M.on_removed(entity) end,
	rotated = function(entity) M.on_rotated(entity) end,
})

return M
