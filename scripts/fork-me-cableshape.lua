--------------------------------------------------------------------------------
--- ME NETWORK: THE SHAPE OF ME CABLE FROM BLUEPRINTS AND OF CABLE GHOSTS (issue #670)
---   * A cable's picture is graphics_variation = 1 + N + 2E + 4S + 8W, set from the graph by update_cable
---     (scripts/fork-me-network.lua) for built cables. The game copies a blueprint's stored `variation` onto what it builds:
---     onto the ghosts, and onto cables that stand where a pasted cable lands (no event). Both are corrected here.
---   * Pasted over cable: on_pre_build (scripts/fork-me-pasteover.lua reads the blueprint) notes the area its cables land on
---     (one tile more on each side); on the next tick every built cable there takes its shape from the graph again and every
---     cable ghost there is computed again (M.on_tick, which does nothing while nothing is noted). A cable has a direction
---     that does not show; a turned or flipped paste would land cables of another direction on it, which the game refuses
---     (red) as for belts: in on_pre_build each cable a blueprint cable lands on takes that cable's direction first.
---   * A cable ghost shows the shape it will have when built: an arm toward every side where an ME member of the graph or a
---     ghost of an ME block or cable touches it and may connect (the graph's rule, `connects`: an underground cable only on
---     the side it faces). Every ME ghost is recorded when it is made (on_built_entity, script_raised_built, a clone) and
---     queued; on the next tick (M.on_tick, at most FRESH_PER_TICK of them a tick, the rest on the ticks after) a cable ghost
---     of the queue takes its whole shape, and the cable ghosts next to any queued ghost their arm toward it. When a ghost
---     goes (built, cancelled, mined, undone, destroyed: on_object_destroyed, the one event that comes for every way), is
---     rotated, or when a member joins or leaves the graph next to it (N.ghost_hook, from add_node and remove_node_graph), the
---     cable ghosts next to it have the arm on that side set again from what stands there now, at once. Built cables keep the
---     graph's shape.
---   * Cost: the ghosts are found by tile in a lookup (`IDX`, derived from the records, built again on first use after a
---     load), so a ghost's ghost neighbours cost no search. Members are searched for (find_entities_filtered by their names)
---     once per chunk of the queue, and when a ghost goes next to a live cable ghost; a member that joins or leaves the graph
---     costs a lookup of the tiles around it while its surface has ME ghosts, nothing while it has none.
--- State: storage.fork_me_cableshape (lazy): `g` the ME ghosts by unit number ({ x1, y1, x2, y2, kind, dir, e = the ghost,
--- s = surface index, f = force name, v = the shape last set }), `n` their number per surface, `q` the unit numbers of the
--- ghosts waiting for their shape, `paste` the noted paste areas ({ surface, x1, y1, x2, y2, tick }) until the next tick.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local P = require("scripts.fork-me-pasteover")

local M = {}

local GHOST = "entity-ghost"
local FRESH_PER_TICK = 1000            -- queued ghosts shaped per tick (a 5000-ghost paste: five ticks)
local adjacent, side_of, connects = N.adjacent, N.side_of, N.connects

local function state()
	local st = storage.fork_me_cableshape
	if not st then
		st = { g = {}, n = {} }
		storage.fork_me_cableshape = st
	end
	return st
end

local cable_cache
--- the names of the kind "cable" (the ones with a shape)
local function cable_names()
	if not cable_cache then
		cable_cache = {}
		for _, n in ipairs(N.node_names()) do
			if N.kind_of(n) == "cable" then cable_cache[#cable_cache + 1] = n end
		end
	end
	return cable_cache
end

--- the ghosts by tile: IDX[surface index][key] = record (derived from storage.fork_me_cableshape.g)
local IDX
local function key(x, y) return (x + 1048576) * 2097152 + (y + 1048576) end

local function put(r)
	local t = IDX[r.s]
	if not t then
		t = {}
		IDX[r.s] = t
	end
	for x = r[1], r[3] - 1 do for y = r[2], r[4] - 1 do t[key(x, y)] = r end end
end

local function unput(r)
	local t = IDX[r.s]
	if not t then return end
	for x = r[1], r[3] - 1 do
		for y = r[2], r[4] - 1 do
			local k = key(x, y)
			if t[k] == r then t[k] = nil end
		end
	end
	if next(t) == nil then IDX[r.s] = nil end
end

local function index(st)
	if not IDX then
		IDX = {}
		for _, r in pairs(st.g) do put(r) end
	end
	return IDX
end

local size_cache = {}
local force_names = {}
local D = defines.direction
--- the record of the ME ghost `g` (made, indexed and registered once; `again`: made anew, it was rotated); nil when `g` is no
--- ME ghost
local function record(st, g, again)
	local unit = g.unit_number
	local r = st.g[unit]
	if r and not again and r.e == g then return r end
	local name = g.ghost_name
	local kind = N.kind_of(name)
	if not kind then return nil end
	local sz = size_cache[name]
	if not sz then
		local p = prototypes.entity[name]
		sz = { p.tile_width or 1, p.tile_height or 1 }
		size_cache[name] = sz
	end
	local pos, d = g.position, g.direction
	local w, h = sz[1], sz[2]
	if (d == D.east or d == D.west) and w ~= h then w, h = h, w end
	local si, fi = g.surface.index, g.force.index
	local fname = force_names[fi]
	if not fname then
		fname = game.forces[fi].name
		force_names[fi] = fname
	end
	if r then unput(r) else st.n[si] = (st.n[si] or 0) + 1 end
	local x, y = pos.x, pos.y
	r = { math.floor(x - w / 2 + 0.5), math.floor(y - h / 2 + 0.5), math.floor(x + w / 2 + 0.5), math.floor(y + h / 2 + 0.5),
		kind = kind, dir = d, e = g, s = si, f = fname, v = kind == "cable" and g.graphics_variation or nil, u = unit }
	st.g[unit] = r
	if not again then script.register_on_object_destroyed(g) end
	put(r)
	return r
end

--- the members of the graph whose boxes touch or overlap the area x1..x2, y1..y2 (tiles), by tile: key -> node
local function members_map(surface, force, x1, y1, x2, y2)
	local map = {}
	for _, e in pairs(surface.find_entities_filtered{ area = { { x1 - 0.5, y1 - 0.5 }, { x2 + 0.5, y2 + 0.5 } },
		name = N.node_names(), force = force }) do
		local node = N.node_of(e)
		if node then
			for x = node[1], node[3] - 1 do for y = node[2], node[4] - 1 do map[key(x, y)] = node end end
		end
	end
	return map
end

--- the tile next to a 1x1 box on `side` (1 N, 2 E, 4 S, 8 W)
local SIDE_VEC = { [1] = { 0, -1 }, [2] = { 1, 0 }, [4] = { 0, 1 }, [8] = { -1, 0 } }

--- what stands on tile (x, y) of surface `si` for a cable's shape: a ghost's record or a member's node (of `map`), or nil
local function occupant(si, x, y, map)
	local k = key(x, y)
	local t = IDX[si]
	return t and t[k] or map[k]
end

--- set the shape of the cable ghost of record `r` (the game's value is read only when it is not known)
local function set_shape(r, v)
	if r.v ~= v then
		r.v = v
		r.e.graphics_variation = v
	end
end

--- set the arm of the cable ghost of record `n` on `side` on or off
local function set_arm(n, side, on)
	local m = (n.v or 1) - 1
	local has = math.floor(m / side) % 2 == 1
	if has ~= on then set_shape(n, m + (on and side or -side) + 1) end
end

--- the live cable ghosts next to box `b` (on surface `si`, of force `force`): a list of { record, its side toward `b` }
local function cable_neighbours(si, b, force)
	local t = IDX[si]
	if not t then return nil end
	local out
	local function look(x, y)
		local r = t[key(x, y)]
		if r and r.kind == "cable" and r.f == force and not r.batch and adjacent(r, b) and r.e.valid then
			--- (a gone one: its own event comes; one of the batch being shaped takes its whole shape itself)
			out = out or {}
			out[#out + 1] = { r, side_of(r, b) }
		end
	end
	for x = b[1], b[3] - 1 do
		look(x, b[2] - 1)
		look(x, b[4])
	end
	for y = b[2], b[4] - 1 do
		look(b[1] - 1, y)
		look(b[3], y)
	end
	return out
end

--- the record `r` of a ghost that is new (or computed again; its ghost is valid): a cable ghost takes its whole shape (`map`:
--- the members around it by tile), the cable ghosts next to it their arm toward it
local function fresh(r, map)
	if r.kind == "cable" then
		local mask, x, y, si = 0, r[1], r[2], r.s
		for side, v in pairs(SIDE_VEC) do
			local o = occupant(si, x + v[1], y + v[2], map)
			if o and o ~= r and (not o.e or o.e.valid) and adjacent(r, o) and connects(r, o) then mask = mask + side end
		end
		set_shape(r, mask + 1)
	end
	for _, nb in ipairs(cable_neighbours(r.s, r, r.f) or {}) do set_arm(nb[1], nb[2], connects(nb[1], r)) end
end

--- the cable ghosts next to box `b` (`si`, `force` name) take their arm toward it from what stands there now; `getmap`:
--- function() -> the members near `b` by tile (searched only when a live cable ghost is there)
local function settle(si, b, force, getmap)
	local list = cable_neighbours(si, b, force)
	if not list then return end
	local map = getmap()
	for _, nb in ipairs(list) do
		local n, side = nb[1], nb[2]
		local v = SIDE_VEC[side]
		local o = occupant(si, n[1] + v[1], n[2] + v[2], map)
		set_arm(n, side, o ~= nil and (not o.e or o.e.valid) and connects(n, o))
	end
end

--- a ghost was made (built by a player or a script, cloned): an ME ghost is recorded and waits for the next tick
function M.on_built(entity)
	if not (entity and entity.valid and entity.name == GHOST) then return end
	local st = state()
	index(st)
	local r = record(st, entity)
	if not r then return end
	local q = st.q
	if not q then
		q = {}
		st.q = q
	end
	q[#q + 1] = r.u
end

--- an ME ghost was rotated (an underground cable faces another side)
function M.on_rotated(entity)
	if not (entity and entity.valid and entity.name == GHOST) then return end
	local st = storage.fork_me_cableshape
	local old = st and st.g[entity.unit_number]
	if not (old and old.e == entity) then return end
	index(st)
	local r = record(st, entity, true)
	local surface, force = entity.surface, entity.force
	local function map() return members_map(surface, force, old[1] - 1, old[2] - 1, old[3] + 1, old[4] + 1) end
	settle(old.s, old, old.f, map)                 -- (the arms the cable ghosts next to it had toward it)
	if r then fresh(r, map()) end
end

--- a recorded ghost is gone (built, cancelled, mined, undone, destroyed): its cable ghost neighbours follow
function M.on_object_destroyed(event)
	local st = storage.fork_me_cableshape
	local unit = event.useful_id
	local r = unit and st and st.g[unit]
	if not r or r.e.valid then return end           -- (not ours, or the ghost is still there)
	st.g[unit] = nil
	local si = r.s
	local left = (st.n[si] or 1) - 1
	st.n[si] = left > 0 and left or nil
	index(st)
	unput(r)
	local surface, force = game.surfaces[si], game.forces[r.f]
	if not (surface and force) then return end
	settle(si, r, r.f, function() return members_map(surface, force, r[1] - 1, r[2] - 1, r[3] + 1, r[4] + 1) end)
end

local EMPTY = {}
--- N.ghost_hook: the member `entity` (its node `node`) joined or left the graph: the cable ghosts next to it follow (nothing
--- to do while its surface has no ME ghost)
function N.ghost_hook(entity, node)
	local st = storage.fork_me_cableshape
	if not (st and st.n[node.surface]) then return end
	index(st)
	settle(node.surface, node, node.force, function()
		if N.node_of(entity) ~= node then return EMPTY end   -- (it left)
		local map = {}
		for x = node[1], node[3] - 1 do for y = node[2], node[4] - 1 do map[key(x, y)] = node end end
		return map
	end)
end

--- Where the cables of a blueprint land, pasted at `at` (on_pre_build; scripts/fork-me-pasteover.lua reads the blueprint):
--- the area of their tiles, one tile more on each side. `place`: function(be) -> position, or nil when the blueprint is
--- placed by other rules (rails, absolute snapping): then a square around `at` as large as the blueprint, both ways.
--- Turned or flipped pastes: a cable has a direction that does not show, and the game refuses a paste (red) that lands a
--- cable on a cable of another direction, as it does for belts. So each cable that a cable of the blueprint lands on is
--- turned first to the direction the blueprint gives it (`direction`, `fh`, `fv`: on_pre_build's), and the paste builds.
function M.note_paste(surface, entities, place, at, direction, fh, fv)
	local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
	local any = false
	local kinds = {}
	local turn = place and {}                  -- tile key -> the direction the blueprint gives the cable there
	local dir = (direction or 0) % 16
	for _, be in pairs(entities) do
		local k = kinds[be.name]
		if k == nil then
			k = N.kind_of(be.name) == "cable"
			kinds[be.name] = k
		end
		local p = be.position
		if k then
			any = true
			if place then
				p = place(be)
				local d = (be.direction or 0) % 16
				if fh then d = (16 - d) % 16 end           -- (east and west change places)
				if fv then d = (24 - d) % 16 end           -- (north and south)
				turn[key(math.floor(p.x), math.floor(p.y))] = (d + dir) % 16
			end
		end
		if k or not place then
			if p.x < x1 then x1 = p.x end
			if p.y < y1 then y1 = p.y end
			if p.x > x2 then x2 = p.x end
			if p.y > y2 then y2 = p.y end
		end
	end
	if not any then return end
	if turn then
		for _, e in pairs(surface.find_entities_filtered{ area = { { x1 - 0.5, y1 - 0.5 }, { x2 + 0.5, y2 + 0.5 } }, name = cable_names() }) do
			local q = e.position
			local d = turn[key(math.floor(q.x), math.floor(q.y))]
			if d and e.direction ~= d then e.direction = d end
		end
	end
	if not place then
		local r = math.max(x2 - x1, y2 - y1) + 2
		x1, y1, x2, y2 = at.x - r, at.y - r, at.x + r, at.y + r
	end
	local st = state()
	st.paste = st.paste or {}
	st.paste[#st.paste + 1] = { surface.index, x1 - 1.5, y1 - 1.5, x2 + 1.5, y2 + 1.5, game.tick }
end
P.cable_hook = M.note_paste

--- the area of the cable ghosts and built cables on `surface`: every one takes its shape again
local function reshape(st, surface, area)
	local names = cable_names()
	for _, e in pairs(surface.find_entities_filtered{ area = area, name = names }) do N.reshape_cable(e) end
	local ghosts = surface.find_entities_filtered{ area = area, ghost_name = names }
	if #ghosts == 0 then return end
	local map
	for _, g in pairs(ghosts) do
		local r = g.valid and record(st, g)
		if r then
			r.v = g.graphics_variation                 -- (the paste may have written the blueprint's)
			map = map or members_map(surface, g.force, area[1][1], area[1][2], area[2][1], area[2][2])
			fresh(r, map)
		end
	end
end

--- the queued ghosts (at most FRESH_PER_TICK): one search for members per chunk (and surface and force) of the queue; a ghost
--- of the batch is not given an arm by its neighbours of the batch (`batch`: it takes its whole shape itself)
local function drain(st)
	local q = st.q
	local n = #q
	local take = math.min(n, FRESH_PER_TICK)
	local groups, order = {}, {}
	local batch = {}
	for i = 1, take do
		local r = st.g[q[i]]
		if r and not r.batch and r.e.valid then
			r.batch = true
			batch[#batch + 1] = r
			local by = groups[r.s]
			if not by then
				by = {}
				groups[r.s] = by
			end
			local bf = by[r.f]
			if not bf then
				bf = {}
				by[r.f] = bf
			end
			local ck = math.floor(r[1] / 32) * 65536 + math.floor(r[2] / 32)
			local gr = bf[ck]
			if not gr then
				gr = { r[1], r[2], r[3], r[4] }
				bf[ck] = gr
				order[#order + 1] = gr
			else
				if r[1] < gr[1] then gr[1] = r[1] end
				if r[2] < gr[2] then gr[2] = r[2] end
				if r[3] > gr[3] then gr[3] = r[3] end
				if r[4] > gr[4] then gr[4] = r[4] end
			end
			gr[#gr + 1] = r
		end
	end
	for _, gr in ipairs(order) do
		local first = gr[5]
		local surface, force = game.surfaces[first.s], game.forces[first.f]
		if surface and force then
			local map = members_map(surface, force, gr[1] - 1, gr[2] - 1, gr[3] + 1, gr[4] + 1)
			for i = 5, #gr do fresh(gr[i], map) end
		end
	end
	for _, r in ipairs(batch) do r.batch = nil end
	if take == n then
		st.q = nil
	else
		local rest = {}
		for i = take + 1, n do rest[#rest + 1] = q[i] end
		st.q = rest
	end
end

--- on_tick: the queued ghosts, and the pastes noted before this tick (the game wrote the blueprint's shapes after
--- on_pre_build)
function M.on_tick(tick)
	local st = storage.fork_me_cableshape
	if not (st and (st.q or st.paste)) then return end
	index(st)
	if st.q then drain(st) end
	local list = st.paste
	if not list then return end
	local keep
	for _, p in ipairs(list) do
		if p[6] < tick then
			local surface = game.surfaces[p[1]]
			if surface then reshape(st, surface, { { p[2], p[3] }, { p[4], p[5] } }) end
		else
			keep = keep or {}
			keep[#keep + 1] = p
		end
	end
	st.paste = keep
end

--- on_init and on_configuration_changed (after the graph's rebuild): the ME ghosts of a save from before are recorded and
--- queued (the records of ghosts that are gone are dropped)
function M.migrate()
	local st = state()
	for unit, r in pairs(st.g) do
		if not r.e.valid then
			st.g[unit] = nil
			local left = (st.n[r.s] or 1) - 1
			st.n[r.s] = left > 0 and left or nil
		end
	end
	IDX = nil
	index(st)
	for _, surface in pairs(game.surfaces) do
		for _, g in ipairs(surface.find_entities_filtered{ name = GHOST, ghost_name = N.node_names() }) do M.on_built(g) end
	end
end

remote.add_interface("gregtorio-me-cableshape", {
	--- tests: what on_pre_build does for a player who pastes `bp` (a blueprint item) at `at`
	note_paste = function(bp, surface, force, at, direction, fh, fv)
		P.note_cables(bp, surface, { x = at.x or at[1], y = at.y or at[2] }, direction, fh, fv)
	end,
	--- tests: what the module keeps (the ghosts on `surface` only, when given)
	counts = function(surface)
		local st = storage.fork_me_cableshape
		local si = surface and surface.index
		local n, at = 0, {}
		for _, r in pairs(st and st.g or {}) do
			if not si or r.s == si then
				n = n + 1
				at[#at + 1] = r[1] .. "," .. r[2]
			end
		end
		local tiles = 0
		for _ in pairs(si and IDX and IDX[si] or {}) do tiles = tiles + 1 end
		return { ghosts = n, pastes = st and st.paste and #st.paste or 0, at = n > 0 and table.concat(at, " ") or nil,
			surfaces = si and st and st.n[si] or nil, tiles = tiles, queued = st and st.q and #st.q or 0 }
	end,
})

return M
