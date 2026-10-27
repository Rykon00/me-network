--------------------------------------------------------------------------------
--- ME NETWORK: WHAT CONSTRUCTION NEEDS, FOR THE ME LOGISTIC INTERFACE'S AUTOMATIC MODE (me-network issue #538; the automatic
--- mode is issue #537, scripts/fork-me-logistic-interface.lua; docs/AE2.md "ME Logistic Interface")
---   * What construction robots fetch in a logistic network: an entity ghost (the first of `items_to_place_this` of the ghost's
---     prototype, in the ghost's quality, and the items it requests, `item_requests`: modules, fuel, ammo), a tile ghost (the
---     first item of the tile), an item request proxy (`item_requests`) and an entity marked for upgrade (the first item of its
---     target, in the target's quality). Each is a record of what it needs, by the logistic network whose construction area it
---     stands in (`find_logistic_networks_by_construction_area`: of those with an ME Logistic Interface in Automatic mode, the
---     lowest id); the sum per network and key is the tally the interface's demand scan adds to the requester points' demand.
---     Things in a logistic network without an automatic block are not recorded (no cost for the rest of the map).
---   * Counted from events only (counting on the surface cost 102 ms on the maintainer's Nauvis): added when built (the build
---     events of a ghost, tile ghost or proxy, a ghost left by a death: on_post_entity_died) or marked for upgrade; removed
---     through on_object_destroyed (every recorded object is registered: revived, mined, cancelled, destroyed, upgraded or a
---     proxy fulfilled, whatever the cause) and on_cancelled_upgrade.
---   * The safety net: a rescan of one logistic cell after the other of the networks with an automatic block (its construction
---     square in four quarters on four steps, one find_entities_filtered for ghosts and proxies each; the whole square with a
---     second search for upgrades cost 132 us per cell on the maintainer's Nauvis), at the map setting "construction cells
---     rescanned per second" (10). It adds what no event
---     announced (a ghost made by a script without raise_built, a network that got its first automatic block) and takes the
---     current needs of a proxy (one that was partly served raises no event); a recorded ghost is left as it is. Upgrades are
---     looked for only in the first round of a network (`s.full`): order_upgrade raises on_marked_for_upgrade whoever calls it,
---     so later ones come by their events; the first round finds the ones marked before the network got an automatic block.
---   * In `storage` (the maintainer's choice, issue #538): the records decide what is offered, and a peer that joins must see
---     what the server counted (events a script never raised would make a count built again from the world differ).
--- State: storage.fork_me_lifc = { recs = { [registration number] = { e, lid, items = { [key] = n }, x, y } }, tally = { [lid] =
--- { [key] = { n, x, y } } }, cur (the rescan: lid, cells, i, q the quarter), last (the lid of the last rescan),
--- full = { [lid] = true } (rescanned
--- once) }.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local Sched = require("scripts.fork-me-schedule")

local M = {}

local TYPES = { "entity-ghost", "tile-ghost", "item-request-proxy" }
local TRACKED = { ["entity-ghost"] = true, ["tile-ghost"] = true, ["item-request-proxy"] = true }
local QUEUE = "logistic_construction"         -- (the scheduler's counters of the rescan)

--- set by the interface module: function() -> { [lid] = units of its automatic blocks }, sorted ids
M.auto_lids = nil

local function state()
	local s = storage.fork_me_lifc
	if not s then
		s = { recs = {}, tally = {} }
		storage.fork_me_lifc = s
	end
	return s
end

--- the logistic network at `pos` (of `e`) whose construction area holds it and that has an automatic block (the lowest id), or nil
local function lid_of(e, pos, autos)
	local best
	for _, ln in pairs(e.surface.find_logistic_networks_by_construction_area(pos, e.force)) do
		local id = ln.network_id
		if autos[id] and (not best or id < best) then best = id end
	end
	return best
end

--- the first item to place an entity (`tile` false) or tile of prototype `name`, false for none (per load: a pure function)
local places = { [false] = {}, [true] = {} }
local function place_item(name, tile)
	local cache = places[tile]
	local v = cache[name]
	if v == nil then
		local proto = tile and prototypes.tile[name] or prototypes.entity[name]
		local list = proto and proto.items_to_place_this
		v = list and list[1] or false
		cache[name] = v
	end
	return v
end

--- what `e` needs: { [key] = count }
local function needs_of(e)
	local out = {}
	local function add(name, q, n)
		if n and n > 0 then
			local key = N.key_of(name, q or "normal")
			out[key] = (out[key] or 0) + n
		end
	end
	local t = e.type
	if t == "entity-ghost" or t == "tile-ghost" then
		local it = place_item(e.ghost_name, t == "tile-ghost")
		if it then add(it.name, t == "entity-ghost" and e.quality.name or "normal", it.count) end
		if t == "entity-ghost" then
			for _, r in pairs(e.item_requests) do add(r.name, r.quality, r.count) end
		end
	elseif t == "item-request-proxy" then
		for _, r in pairs(e.item_requests) do add(r.name, r.quality, r.count) end
	else
		local proto, q = e.get_upgrade_target()
		local it = proto and place_item(proto.name, false)
		if it then add(it.name, q and q.name or "normal", it.count) end
	end
	return out
end

local function drop(s, reg)
	local r = s.recs[reg]
	if not r then return end
	s.recs[reg] = nil
	local t = s.tally[r.lid]
	for key, n in pairs(r.items) do
		local e = t and t[key]
		if e then
			e.n = e.n - n
			if e.n <= 0 then t[key] = nil end
		end
	end
	if t and next(t) == nil then s.tally[r.lid] = nil end
end

--- record `e` (registered as `reg`) in logistic network `lid` with what it needs now
local function put(s, reg, e, lid, pos)
	drop(s, reg)
	local items = needs_of(e)
	if next(items) == nil then return end
	s.recs[reg] = { e = e, lid = lid, items = items, x = pos.x, y = pos.y }
	local t = s.tally[lid]
	if not t then
		t = {}
		s.tally[lid] = t
	end
	for key, n in pairs(items) do
		local v = t[key]
		if not v then
			t[key] = { n = n, x = pos.x, y = pos.y }
		else
			v.n = v.n + n
		end
	end
end

--- a ghost, tile ghost or proxy was built, an entity marked for upgrade (`e`); nothing while no block is automatic
local function track(e)
	local autos = M.auto_lids and M.auto_lids()
	if not (autos and next(autos) and e.valid) then return end
	local pos = e.position
	local lid = lid_of(e, pos, autos)
	if not lid then return end
	put(state(), script.register_on_object_destroyed(e), e, lid, pos)
end

function M.on_built(entity)
	if entity.valid and TRACKED[entity.type] then track(entity) end
end

function M.on_marked_for_upgrade(event) if event.entity then track(event.entity) end end

function M.on_cancelled_upgrade(event)
	local s, e = storage.fork_me_lifc, event.entity
	if s and e and e.valid then drop(s, script.register_on_object_destroyed(e)) end
end

function M.on_post_entity_died(event) if event.ghost then track(event.ghost) end end

function M.on_object_destroyed(event)
	local s = storage.fork_me_lifc
	if s then drop(s, event.registration_number) end
end

--- the tally of logistic network `lid`: { [key] = { n, x, y } } (do not change it)
local EMPTY = {}
function M.tally(lid)
	local s = storage.fork_me_lifc
	return s and s.tally[lid] or EMPTY
end

--- (the window, tests) the things recorded in `lid`
function M.count(lid)
	local s = storage.fork_me_lifc
	local n = 0
	for _, r in pairs(s and s.recs or {}) do if r.lid == lid then n = n + 1 end end
	return n
end

--------------------------------------------------------------------------------
--- the safety net
--------------------------------------------------------------------------------

--- one cell: what stands in its construction square (and belongs to `lid`) recorded with its needs now
--- (`quarter` 1..4: the quarter of the construction square, one per call: a whole square cost 132 us at once)
local QUARTERS = { { -1, -1 }, { 0, -1 }, { -1, 0 }, { 0, 0 } }
local function rescan_cell(s, lid, cell, autos, upgrades, quarter)
	if not (cell.valid and cell.construction_radius > 0) then return end
	local owner = cell.owner
	local p, r = owner.position, cell.construction_radius
	local qx, qy = p.x + QUARTERS[quarter][1] * r, p.y + QUARTERS[quarter][2] * r
	local area = { { qx, qy }, { qx + r, qy + r } }
	local surface, force = owner.surface, owner.force
	for _, e in pairs(surface.find_entities_filtered{ area = area, type = TYPES, force = force }) do
		local reg = script.register_on_object_destroyed(e)
		local rec = s.recs[reg]
		if rec and rec.lid == lid then
			--- what a ghost needs does not change; a proxy's needs shrink as robots serve it (no event)
			if e.type == "item-request-proxy" then put(s, reg, e, lid, e.position) end
		elseif not (rec and autos[rec.lid]) then                      -- (another network's record: it is rescanned there)
			local pos = e.position
			if lid_of(e, pos, autos) == lid then put(s, reg, e, lid, pos) end
		end
	end
	if not upgrades then return end
	for _, e in pairs(surface.find_entities_filtered{ area = area, to_be_upgraded = true, force = force }) do
		local reg = script.register_on_object_destroyed(e)
		if not s.recs[reg] then
			local pos = e.position
			if lid_of(e, pos, autos) == lid then put(s, reg, e, lid, pos) end
		end
	end
end

--- the records of networks that have no automatic block any more go
local function prune(s, autos)
	local gone = {}
	for reg, r in pairs(s.recs) do
		if not autos[r.lid] or not r.e.valid then gone[#gone + 1] = reg end
	end
	table.sort(gone)
	for _, reg in ipairs(gone) do drop(s, reg) end
	for lid in pairs(s.full or {}) do if not autos[lid] then s.full[lid] = nil end end
end

--- one tick of the rescan (`net_of(lid)`: the logistic network of that id now, or nil)
function M.on_tick(tick, net_of)
	local autos, lids = M.auto_lids()
	local s = storage.fork_me_lifc
	if #lids == 0 then
		if s and (next(s.recs) or s.cur) then
			s.recs, s.tally, s.cur = {}, {}, nil
		end
		return
	end
	local n = Sched.per_second(4 * Sched.setting("logistic_construction"), tick)   -- (quarters of a square)
	if n <= 0 then return end
	s = state()
	local done = 0
	while done < n do
		local cur = s.cur
		if cur and not autos[cur.lid] then cur, s.cur = nil, nil end
		if not cur then
			--- the next logistic network after the last one; at the first, the records of networks without one go
			local lid = lids[1]
			for _, id in ipairs(lids) do
				if s.last and id > s.last then
					lid = id
					break
				end
			end
			if lid == lids[1] then prune(s, autos) end
			s.last = lid
			local ln = net_of(lid)
			if not ln then break end
			cur = { lid = lid, cells = ln.cells, i = 1 }
			s.cur = cur
		end
		local cell = cur.cells[cur.i]
		cur.q = (cur.q or 0) + 1
		if cell then rescan_cell(s, cur.lid, cell, autos, not (s.full and s.full[cur.lid]), cur.q) end
		if cur.q >= 4 then cur.i, cur.q = cur.i + 1, 0 end
		if cur.i > #cur.cells then
			s.cur = nil
			s.full = s.full or {}
			s.full[cur.lid] = true                                  -- (rescanned once: upgrades come by their events)
		end
		done = done + 1
	end
	Sched.work(QUEUE, done)
end

--- after a mod change: what the records need is taken again (an item may be gone), the ones of invalid objects go
function M.on_configuration_changed()
	local s = storage.fork_me_lifc
	if not s then return end
	local recs = s.recs
	s.recs, s.tally = {}, {}
	local regs = {}
	for reg in pairs(recs) do regs[#regs + 1] = reg end
	table.sort(regs)
	for _, reg in ipairs(regs) do
		local r = recs[reg]
		if r.e.valid then put(s, reg, r.e, r.lid, r.e.position) end
	end
end

return M
