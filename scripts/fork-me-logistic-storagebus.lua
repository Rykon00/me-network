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
--- State: the records are the storage bus's (storage.fork_me_net.ext); this module keeps the visit list, the queue and the
--- claims in storage.fork_me_lsbus = { list, lpos, claims, q }.
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
--- the external cell's functions (called by the storage engine)
--------------------------------------------------------------------------------

local Q = {}                               -- (the item spec of an engine call, reused)
local function spec(name, q, count)
	Q.name, Q.quality, Q.count = name, q, count
	return Q
end

local HANDLER = {
	--- items of `key` the storage chests take now: what the chest the network would drop it into takes (a lower bound)
	room = function(rec, key)
		if rec.mode == "read" or not allowed(rec, key) then return 0 end
		local name, q = item_of(key)
		local net = name and live(rec)
		if not net then return 0 end
		local point = net.select_drop_point{ stack = spec(name, q, nil), members = "storage" }
		local owner = point and point.owner
		local inv = owner and owner.valid and owner.get_inventory(defines.inventory.chest)
		if not inv then return 0 end
		return inv.get_insertable_count(spec(name, q, nil))
	end,
	--- put up to `count` into the storage chests; returns the count inserted
	insert = function(rec, key, count)
		if rec.mode == "read" or not allowed(rec, key) then return 0 end
		local name, q = item_of(key)
		local net = name and live(rec)
		if not net then return 0 end
		return net.insert(spec(name, q, count), "storage")
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
		return n
	end,
	--- take up to `count` out of the storage chests, then (provider mode) the provider chests; returns the count removed
	extract = function(rec, key, count)
		local name, q = item_of(key)
		local net = name and live(rec)
		if not net then return 0 end
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
--- name and quality once per call)
local function read(rec, net, member, contents, all, add)
	for _, it in pairs(net.get_contents(member)) do
		local key = key_for(it.name, it.quality or "normal")
		if key and (all or shown(rec, key)) then
			if add then contents[key] = (contents[key] or 0) + it.count else contents[key] = it.count end
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
		read(rec, net, "storage", contents, all, false)
		if rec.mode == "providers" then read(rec, net, "providers", contents, all, true) end
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
		read(rec, net, "storage", out, true, false)
		if rec.mode == "providers" then read(rec, net, "providers", out, true, true) end
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
