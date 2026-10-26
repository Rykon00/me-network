--------------------------------------------------------------------------------
--- ME NETWORK: THE ME LOGISTIC STORAGE BUS (me-network issue #506, the first package of the crossover "me-network x
--- logistic network"; prototypes/network.lua, docs/ME-REWORK.md "Logistic storage bus")
---   * A 1x1 ME block that is not rotated. Its storage is not a chest but the whole vanilla logistic network whose area it
---     stands in (LuaSurface::find_logistic_network_by_position at its position, for its force): an external cell of the
---     storage engine like the storage bus's, and the storage bus's record (ext = "storage-bus", rec.logistic, side =
---     "logistic", handler = HANDLER), so its window, settings, cards, blueprints, settings paste and clones are the storage
---     bus's (scripts/fork-me-storagebus.lua hands this module its visits, the modes and the window's contents).
---   * Modes: "readwrite" (shown as "Storage": the storage chests; the network reads them, takes from them and stores into
---     them), "providers" (also reads and takes from the provider chests: the engine's member "providers" holds the active
---     and passive provider and the buffer chests, so all three; the network stores only into storage chests) and "read"
---     (read only: the storage chests, the network never stores into them). The default priority is -100: the ME drives
---     fill first.
---   * Which network: resolved again at every visit and every call of the engine (1.4 us), never kept as an object: the
---     network ids change when networks split or join, and a network kept across ticks could differ from the one a peer
---     that joined the game finds. The bus uses the network only while its id is the one it claimed at its last visit
---     (`rec.lid`); between visits a split or a join makes it see nothing until its next visit (an extraction finds 0 and
---     corrects the snapshot, an insert goes elsewhere). One bus per logistic network: `claims[network id] = bus unit`;
---     conflicts are decided in unit order (the lower unit keeps it, as the fluid side's segments): the other bus gets
---     "shared-target" and shows nothing. Without a network at its position: "no-target" and an empty snapshot (the last
---     roboport of the area removed: at the next visit).
---   * What it shows and moves: plain items that do not spoil, of any quality (N.item_class "plain"); not the tools, ammo
---     and repair tools (a used one is counted and taken by count as a whole one: the network cannot pick the whole stacks of
---     a logistic network), not items with tags, a label or an inventory (the chests keep them apart by stack). A damaged
---     item is taken out by count like a whole one (LuaLogisticNetwork::remove_item does not look at health; docs/AE2.md).
---   * Engine calls (Factorio 2.1.23, every one with the quality): count = get_item_count per member; extract =
---     remove_item from "storage", then in the provider mode from "passive-provider", "active-provider" and "buffer";
---     insert = insert(stack, "storage"); room = the insertable count of the storage chest select_drop_point picks (a lower
---     bound: the network asks again when it took that); a visit = one get_contents per member read (0.28 ms for the
---     storage of 1048 roboports and 473 storage chests: only at visits, never more often than the queue allows).
---   * Visits: a queue of its own (Sched, tag "lsbus") with its own budget (settings "logistic storage bus visits per tick",
---     floor and ceiling); a bus whose network changed is read again after MIN_INTERVAL ticks, one that did not change twice
---     as late each time up to the storage bus idle limit (120 ticks). Everything that decides a visit is in `storage`.
---   * ME-owned chests (issue #530): the hidden logistic chests of the ME Logistic Interface (issue #531) are members of the
---     logistic network like any other. The bus never stores into them, never shows what they hold and never takes from
---     them (what lies there is the ME network's already, or its stock offered to the robots: storing, counting or taking it
---     would loop or count it twice). While no such chest stands in the bus's network, every engine call is the one above.
--- State: the records are the storage bus's (storage.fork_me_net.ext); this module keeps the visit list, the queue and the
--- claims in storage.fork_me_lsbus = { list, lpos, claims, q, owned_test }.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local Sched = require("scripts.fork-me-schedule")

local M = {}

M.NAME = "me-logistic-storage-bus"
M.HANDLER = "logistic-storage-bus"
M.DEFAULT_PRIORITY = -100
M.MODES = { readwrite = true, providers = true, read = true }
local MIN_INTERVAL = 30                    -- ticks until a bus whose network changed reads it again
local PROVIDERS = { "passive-provider", "active-provider", "buffer" }   -- (extraction order after "storage")

local function state()
	local s = storage.fork_me_lsbus
	if not s then
		s = { list = {}, lpos = {}, claims = {}, q = Sched.new("lsbus") }    -- claims: logistic network id -> bus unit
		storage.fork_me_lsbus = s
	end
	return s
end

local function idle_limit() return math.max(MIN_INTERVAL, Sched.setting("storage_bus_idle")) end

local function on_logistic(rec) return rec ~= nil and rec.logistic == true end

--------------------------------------------------------------------------------
--- items
--------------------------------------------------------------------------------

local keys = {}
--- the storage key of an item the bus can show and move (plain items that do not spoil), false for any other. Issue #509:
--- by quality, then name: one lookup per entry of a read, no key string built per entry (per load, never saved)
local function key_for(name, quality)
	local by_name = keys[quality]
	if not by_name then
		by_name = {}
		keys[quality] = by_name
	end
	local v = by_name[name]
	if v == nil then
		local p = prototypes.item[name]
		v = p ~= nil and N.item_class(p.type) == "plain" and p.get_spoil_ticks(quality) <= 0 and N.key_of(name, quality) or false
		by_name[name] = v
	end
	return v
end

local function item_of(key)
	if N.is_fluid_key(key) or key:find("#", 1, true) then return nil end
	local name, q = N.parse_key(key)
	if not key_for(name, q) then return nil end
	return name, q
end

local accepts = N.accepts
--- may the network put `key` into the bus? (its filters: a whitelist, or a blacklist; the storage bus's rule)
local function allowed(rec, key)
	if rec.gf then return accepts(rec, key) end
	local p = rec.partition
	if p then return p[key] == true or (rec.fnames ~= nil and accepts(rec, key)) end
	return rec.deny == nil or accepts(rec, key)
end
--- may the network see and take `key`? (the same, unless the bus filters only what goes in)
local function shown(rec, key) return rec.inonly == true or allowed(rec, key) end

--------------------------------------------------------------------------------
--- the logistic network
--------------------------------------------------------------------------------

--- the logistic network at the bus's position now (nil: none)
local function find(e)
	return e.surface.find_logistic_network_by_position(e.position, e.force)
end

--- the network the bus may use now: the one at its position whose id it claimed at its last visit
local function live(rec)
	local id = rec.lid
	if not id then return nil end
	local e = rec.entity
	if not e.valid then return nil end
	local net = find(e)
	if net and net.network_id == id then return net end
	return nil
end

--------------------------------------------------------------------------------
--- ME-owned logistic chests (issue #530)
--------------------------------------------------------------------------------
--- Derived from the owners' records in `storage`, never saved: `owned[unit] = { entity, role }`, built from the sources the
--- owning modules register when they are loaded (M.owned_source), again after a module says its chests changed
--- (M.owned_changed). Per logistic network the owned chests standing in it are looked up once per tick (`by_net`: valid in
--- one tick only, because a network's members change without an event; a peer that joins between two ticks finds the same).
--- Roles: "storage" (a storage chest, left out of the member "storage") and "provider" (a passive provider, left out of the
--- member "providers"); any owned chest is skipped as a drop and a supply point.

local CHEST = defines.inventory.chest
local ROLES = { "storage", "provider" }
local DROP_MEMBERS = { "storage", "storage-empty-slot", "storage-empty" }   -- (select_drop_point, in this order)
local FIRST_FIT = 64                       -- storage chests tried in order when select_drop_point picks only owned ones
local SUPPLY = { "storage" }               -- (the members of an extraction, as on the remove_item path)
local SUPPLY_PROVIDERS = { "storage", "passive-provider", "active-provider", "buffer" }
--- the inventory of a supply point's owner that the point stands for (an active provider point of an entity that is no
--- active provider chest is its trash)
local MAIN = { ["logistic-container"] = CHEST, ["cargo-landing-pad"] = defines.inventory.cargo_landing_pad_main }
local TRASH = {
	["logistic-container"] = defines.inventory.logistic_container_trash, character = defines.inventory.character_trash,
	["spider-vehicle"] = defines.inventory.spider_trash, car = defines.inventory.car_trash,
	["cargo-landing-pad"] = defines.inventory.cargo_landing_pad_trash,
}

local sources = {}                         -- functions(add) of the owning modules: add(entity, role) for each chest they own
local owned, owned_n = nil, 0              -- (nil: build again)
local by_net, by_net_tick = {}, -1

--- a module that owns logistic chests registers the function that lists them (when it is loaded)
function M.owned_source(fn)
	sources[#sources + 1] = fn
	owned = nil
end

--- the owned chests changed (built, removed): the lookup is built again at its next use
function M.owned_changed() owned = nil end

--- (tests) chests registered as owned by the runtime tests, kept in `storage` (a stand-in for the interface's records)
M.owned_source(function(add)
	local s = storage.fork_me_lsbus
	for _, o in pairs(s and s.owned_test or {}) do add(o.entity, o.role) end
end)

--- (tests) register `entity` as an owned chest of `role`, or (role nil) no more
function M.own_test(entity, role)
	local s = state()
	s.owned_test = s.owned_test or {}
	s.owned_test[entity.unit_number] = role and { entity = entity, role = role } or nil
	owned = nil
end

local function build_owned()
	owned, owned_n, by_net = {}, 0, {}
	local function add(e, role)
		if e and e.valid and not owned[e.unit_number] then
			owned[e.unit_number] = { e, role }
			owned_n = owned_n + 1
		end
	end
	for _, fn in ipairs(sources) do fn(add) end
end

--- the owned chests standing in `net` now: { storage = { entity }, provider = { entity }, units = { unit -> true } }, or nil
--- when there is none (always nil while nothing is owned: no engine call)
local function owned_in(net)
	if not owned then build_owned() end
	if owned_n == 0 then return nil end
	local tick = game.tick
	if by_net_tick ~= tick then by_net, by_net_tick = {}, tick end
	local id = net.network_id
	local g = by_net[id]
	if g == nil then
		g = false
		for unit, o in pairs(owned) do
			local e = o[1]
			local n = e.valid and e.logistic_network
			if n and n.network_id == id then
				if not g then
					g = { units = {} }
					for _, r in ipairs(ROLES) do g[r] = {} end
				end
				local list = g[o[2]]
				list[#list + 1] = e
				g.units[unit] = true
			end
		end
		by_net[id] = g
	end
	return g or nil
end

--- the count of `it` in the chests of `list`
local function held(list, it)
	local n = 0
	for _, e in ipairs(list) do
		if e.valid then n = n + e.get_inventory(CHEST).get_item_count(it) end
	end
	return n
end

--------------------------------------------------------------------------------
--- the external cell's functions (called by the storage engine)
--------------------------------------------------------------------------------

local Q = {}                               -- (the item spec of an engine call, reused)
local function spec(name, q, count)
	Q.name, Q.quality, Q.count = name, q, count
	return Q
end

--- issue #530: the inventory of a storage chest that is not owned and takes `name` / `q` now (nil: none): select_drop_point
--- for the members "storage", "storage-empty-slot" and "storage-empty", then the first FIRST_FIT storage chests in order
local function drop_inventory(net, own, name, q)
	for _, members in ipairs(DROP_MEMBERS) do
		local point = net.select_drop_point{ stack = spec(name, q, nil), members = members }
		local owner = point and point.owner
		if owner and owner.valid and not own.units[owner.unit_number] then
			local inv = owner.get_inventory(CHEST)
			if inv then return inv end
		end
	end
	local list = net.storages
	for i = 1, math.min(#list, FIRST_FIT) do
		local e = list[i]
		if not own.units[e.unit_number] then
			local inv = e.get_inventory(CHEST)
			if inv and inv.get_insertable_count(spec(name, q, nil)) > 0 then return inv end
		end
	end
	return nil
end

--- issue #530: take up to `count` of `name` / `q` from the supply points of `members` whose owner is not owned (in the order
--- of `members`); returns the count taken
local function take(net, own, name, q, count, members)
	local got = 0
	local points = net.get_supply_points(spec(name, q, nil))
	for _, member in ipairs(members) do
		for _, p in ipairs(points[member] or {}) do
			local owner = p.owner
			if owner.valid and not own.units[owner.unit_number] then
				local t = owner.type
				local index = MAIN[t]
				if member == "active-provider" and not (t == "logistic-container" and owner.prototype.logistic_mode == "active-provider") then
					index = TRASH[t]
				end
				local inv = index and owner.get_inventory(index)
				if inv then
					got = got + inv.remove(spec(name, q, count - got))
					if got >= count then return got end
				end
			end
		end
	end
	return got
end

local HANDLER = {
	--- items of `key` the storage chests take now: what the chest the network would drop it into takes (a lower bound)
	room = function(rec, key)
		if rec.mode == "read" or not allowed(rec, key) then return 0 end
		local name, q = item_of(key)
		local net = name and live(rec)
		if not net then return 0 end
		local inv
		local own = owned_in(net)
		if own then
			inv = drop_inventory(net, own, name, q)
		else
			local point = net.select_drop_point{ stack = spec(name, q, nil), members = "storage" }
			local owner = point and point.owner
			inv = owner and owner.valid and owner.get_inventory(CHEST)
		end
		if not inv then return 0 end
		return inv.get_insertable_count(spec(name, q, nil))
	end,
	--- put up to `count` into the storage chests; returns the count inserted
	insert = function(rec, key, count)
		if rec.mode == "read" or not allowed(rec, key) then return 0 end
		local name, q = item_of(key)
		local net = name and live(rec)
		if not net then return 0 end
		local own = owned_in(net)
		if not own then return net.insert(spec(name, q, count), "storage") end
		local left = count                                       -- (issue #530: chest by chest, never into an owned one)
		for _ = 1, 4 do
			local inv = drop_inventory(net, own, name, q)
			local n = inv and inv.insert(spec(name, q, left)) or 0
			if n == 0 then break end
			left = left - n
			if left <= 0 then break end
		end
		return count - left
	end,
	--- the real count of `key` in the members the bus reads (0 when it cannot take from them)
	count = function(rec, key)
		if not shown(rec, key) then return 0 end
		local name, q = item_of(key)
		local net = name and live(rec)
		if not net then return 0 end
		local it = spec(name, q, nil)
		local n = net.get_item_count(it, "storage")
		if rec.mode == "providers" then n = n + net.get_item_count(it, "providers") end
		local own = owned_in(net)
		if own then                                              -- (issue #530: what the owned chests hold is left out)
			n = n - held(own.storage, it)
			if rec.mode == "providers" then n = n - held(own.provider, it) end
			if n < 0 then n = 0 end
		end
		return n
	end,
	--- take up to `count` out of the storage chests, then (provider mode) the provider chests; returns the count removed
	extract = function(rec, key, count)
		local name, q = item_of(key)
		local net = name and live(rec)
		if not net then return 0 end
		local own = owned_in(net)
		if own and held(own.storage, spec(name, q, nil)) + held(own.provider, spec(name, q, nil)) > 0 then
			return take(net, own, name, q, count, rec.mode == "providers" and SUPPLY_PROVIDERS or SUPPLY)   -- (issue #530)
		end
		local got = net.remove_item(spec(name, q, count), "storage")
		if got < count and rec.mode == "providers" then
			for _, member in ipairs(PROVIDERS) do
				got = got + net.remove_item(spec(name, q, count - got), member)
				if got >= count then break end
			end
		end
		return got
	end,
	--- an Overflow Destruction Card: is what does not fit of `key` destroyed? (the bus takes the key and works on a network)
	voids = function(rec, key)
		if rec.mode == "read" or not allowed(rec, key) then return false end
		return item_of(key) ~= nil and rec.status == "ok" and live(rec) ~= nil
	end,
	--- can the bus ever hold `key`?
	takes = function(rec, key) return item_of(key) ~= nil end,
}

N.ext_handlers[M.HANDLER] = HANDLER

--------------------------------------------------------------------------------
--- claims and visits
--------------------------------------------------------------------------------

local function release(s, rec)
	local id = rec.lid
	if id and s.claims[id] == rec.unit then s.claims[id] = nil end
	rec.lid = nil
end

--- does bus `other` still own network `id`? (it stands in it and claimed it)
local function holds(other, id)
	local o = N.ext_get(other)
	if not (on_logistic(o) and o.entity.valid and o.lid == id) then return false end
	local net = find(o.entity)
	return net ~= nil and net.network_id == id
end

--- the network of the bus now, claimed if possible (nil: none, or another bus of a lower unit has it); sets rec.status
local function claim(s, rec)
	local net = find(rec.entity)
	local id = net and net.network_id
	if rec.lid ~= id then release(s, rec) end
	if not id then
		rec.status = "no-target"
		return nil
	end
	local other = s.claims[id]
	if other and other ~= rec.unit then
		if holds(other, id) then
			if other < rec.unit then
				rec.status = "shared-target"
				return nil
			end
			local o = N.ext_get(other)                       -- this bus has the lower unit: the other one gives way
			o.lid, o.status = nil, "shared-target"
			N.ext_sync(other, {})
		end
	end
	s.claims[id] = rec.unit
	rec.lid = id
	rec.status = "ok"
	return net
end

--- the bus leaves its network (the claim goes)
function M.drop(rec)
	local s = storage.fork_me_lsbus
	if s then release(s, rec) else rec.lid = nil end
end

local scratch, scratch_free = {}, true

--- the items of `member` the bus shows into `contents` (`add`: added to what an earlier member put there; the engine lists a
--- name and quality once per call); `own`: the owned chests of the network (issue #530), whose contents are left out
local function read(rec, net, member, contents, all, add, own)
	for _, it in pairs(net.get_contents(member)) do
		local key = key_for(it.name, it.quality or "normal")
		if key and (all or shown(rec, key)) then
			if add then contents[key] = (contents[key] or 0) + it.count else contents[key] = it.count end
		end
	end
	if not own then return end
	for _, e in ipairs(member == "storage" and own.storage or own.provider) do
		if e.valid then
			for _, it in pairs(e.get_inventory(CHEST).get_contents()) do
				local key = key_for(it.name, it.quality or "normal")
				local have = key and contents[key]
				if have then
					have = have - it.count
					contents[key] = have > 0 and have or nil
				end
			end
		end
	end
end

--- One visit: claim the network at the bus's position, read its storage chests (and provider chests) once and apply the
--- difference to the ME network. Returns true when the snapshot or the claimed network changed.
function M.visit(rec)
	local s = state()
	local e = rec.entity
	if not e.valid then return false end
	local before = rec.lid
	local net = claim(s, rec)
	local contents = scratch_free and scratch or {}
	if contents == scratch then
		scratch_free = false
		for k in pairs(contents) do contents[k] = nil end
	end
	if net then
		local all = rec.inonly or not (rec.partition or rec.deny or rec.gf)   -- (no filter to check: the common case)
		local own = owned_in(net)
		read(rec, net, "storage", contents, all, false, own)
		if rec.mode == "providers" then read(rec, net, "providers", contents, all, true, own) end
	end
	local changed = N.ext_sync(rec.unit, contents) or before ~= rec.lid
	if contents == scratch then scratch_free = true end
	if rec.status == "ok" then
		local ok, why = N.usable(N.network_of_unit(rec.unit))
		if not ok then rec.status = why or "no-network" end
	end
	return changed
end

--- what the network holds now that the bus could show (the window's "From contents"): { key -> count }
function M.contents(rec)
	local out = {}
	local net = live(rec) or (rec.entity.valid and find(rec.entity))
	if net then
		local own = owned_in(net)
		read(rec, net, "storage", out, true, false, own)
		if rec.mode == "providers" then read(rec, net, "providers", out, true, true, own) end
	end
	return out
end

local function lrec(unit)
	local rec = N.ext_get(unit)
	if on_logistic(rec) then return rec end
	return nil
end

--- the storage bus module's card filling after a visit (set by it)
M.after_visit = nil

local function visit_due(rec, unit)
	local s = storage.fork_me_lsbus
	if not rec.entity.valid then
		Sched.list_remove(s.list, s.lpos, unit)
		Sched.forget(s.q, rec)
		release(s, rec)
		N.ext_detach(unit)
		return
	end
	local changed = M.visit(rec)
	if M.after_visit then M.after_visit(rec) end
	rec.siv = Sched.interval(rec.siv, changed and 1 or 0, true, MIN_INTERVAL, MIN_INTERVAL, idle_limit())
	Sched.at(s.q, rec, unit, game.tick + rec.siv, not changed)   -- (unchanged: asleep until then)
	return changed and 1 or 0
end

--- every tick (from the storage bus module): the buses that are due, between the settings "at least" and "at most"
function M.on_tick(tick)
	local s = storage.fork_me_lsbus
	if not (s and #s.list > 0) then return end
	Sched.run(s.q, tick, Sched.setting("logistic_storage_bus"), Sched.setting("logistic_storage_bus_max"), lrec, visit_due,
		visit_due, "logistic_storage_bus")
end

--- the bus joins the visit list (due at the next tick) unless it is there
function M.list(rec)
	local s = state()
	local i = s.lpos[rec.unit]
	if i and s.list[i] == rec.unit then return end
	s.list[#s.list + 1] = rec.unit
	s.lpos[rec.unit] = #s.list
	rec.siv = nil
	Sched.at(s.q, rec, rec.unit, game.tick + 1)
end

function M.unlist(rec)
	local s = storage.fork_me_lsbus
	if not s then return end
	Sched.list_remove(s.list, s.lpos, rec.unit)
	Sched.forget(s.q, rec)
end

--- read the network at the next tick
function M.wake(rec)
	local s = storage.fork_me_lsbus
	if not s then return end
	rec.siv = nil
	Sched.wake(s.q, rec, rec.unit)
end

--- after the graph rebuild (the storage bus module lists its logistic buses again, in unit order, and visits them)
function M.reset()
	local s = state()
	s.list, s.lpos, s.claims, s.q = {}, {}, {}, Sched.new("lsbus")
	keys = {}
	owned = nil
end

--- (tests, /me-stats) the visit list's size and its queue
function M.queue()
	local s = storage.fork_me_lsbus
	return s and s.q, s and #s.list or 0
end

--- (tests) is the visit list its buses, each once, at their places?
function M.list_ok()
	local s = storage.fork_me_lsbus
	if not s then return true end
	local seen = {}
	for i, u in ipairs(s.list) do
		if seen[u] then return false, "logistic bus " .. u .. " is in the list twice" end
		seen[u] = true
		if s.lpos[u] ~= i then return false, "logistic bus " .. u .. " is not at its place" end
	end
	return true
end

return M
