--------------------------------------------------------------------------------
--- ME QUANTUM BRIDGE AND ME WIRELESS LINK (me-network issues #385 and #384, option 2 each; AE2's Quantum Network Bridge and
--- AE2 Stuff's Wireless Connector; prototypes/network.lua; guide: docs/AE2.md "ME Quantum Bridge", "ME Wireless Link")
---   * Two kinds of linking block with a frequency (a whole number set in its window, 0: none); the kinds never link with
---     each other.
---     * The ME Quantum Bridge (3x3): exactly two bridges of a frequency are a pair; while both have power it is linked: a
---       graph edge between them (N.set_qlink), at any distance and on any surface (another planet, a space platform, a
---       factory floor of another mod); a constant drain (mod-data `quantum_bridge.watts`). A third bridge of a frequency
---       links nothing (the frequency is taken); the other two stay unlinked until it goes.
---     * The ME Wireless Link (1x1, issue #559): all links of a frequency on a surface form one wireless network, as many as
---       there are. Two of them may link within `wireless_link.range` tiles (between their centres), so a group can be a
---       chain. The edges (N.set_wlinks) are a minimum spanning forest of the links that have power, by distance (Prim's,
---       ties by unit number): n - 1 edges for a group in reach, not one per pair, and each link's edge to its nearest
---       member in reach is among them. A link's drain grows with the longest of its edges: `base` W, and `per_chunk` W
---       more for every started 32 tiles (a pair: both ends pay their edge, as before); an unlinked one draws the base.
---   * Power: each block is an electric energy interface that draws its drain from the power grid where it stands; the
---     network does not pay for it (POWERED_SELF). The link forms when both have at least half their buffer (two seconds of
---     the drain) and goes when one of them has run dry (no flicker at the edge).
---   * Like AE2: one network, one controller. Two networks with a controller each, linked, are in conflict (the controller
---     rule of the network: the second controller's network does not work); build the far side without a controller.
---   * The checks of the pairs run in the network's slow step (every 60 ticks, N.slow_hooks, as the ME Chest's power): one
---     energy read per block; a change of a frequency or a built block is checked at once.
---   * Kept in blueprints, settings paste (the mod's own keys, issue #527) and clones: the frequency (a third block of it
---     then waits).
--- State: storage.fork_me_qbridge = { recs = { [unit] = { entity, freq, where } } }; the links are the network's state
--- (storage.fork_me_net.qlink).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")

local M = {}

local NAME = "me-quantum-bridge"
local LINK = "me-wireless-link"
--- the kinds: their blueprint tag, their mod-data spec, whether they link across surfaces
local KINDS = {
	[NAME] = { tag = "fork_me_qbridge", spec = "quantum_bridge", across = true },
	[LINK] = { tag = "fork_me_wireless_link", spec = "wireless_link", across = false },
}
local MAX_FREQ = 2 ^ 31 - 1
local CHUNK = 32

local function state()
	local s = storage.fork_me_qbridge
	if not s then
		s = { recs = {} }
		storage.fork_me_qbridge = s
	end
	return s
end

local function is_linker(entity) return entity and entity.valid and KINDS[entity.name] ~= nil end

local function rec_of(entity)
	local s = storage.fork_me_qbridge
	return s and is_linker(entity) and s.recs[entity.unit_number] or nil
end

local spec_cache = {}
--- the mod-data numbers of a kind (quantum bridge: { watts }; wireless link: { base, per_chunk, range })
local function spec(name)
	local v = spec_cache[name]
	if not v then
		local md = prototypes.mod_data["fork-me-network"]
		v = md and md.data[KINDS[name].spec] or {}
		spec_cache[name] = v
	end
	return v
end

--- the drain (W) of a block of kind `name` linked over `dist` tiles (nil: no partner in reach)
local function drain(name, dist)
	local sp = spec(name)
	if name == NAME then return sp.watts or 1000000 end
	if not dist then return sp.base or 0 end
	return (sp.base or 0) + (sp.per_chunk or 0) * math.ceil(dist / CHUNK)
end
M.drain = drain

--- the wireless link's drain on the block: its power use and a buffer of two seconds of it
local function set_drain(entity, watts)
	if entity.name ~= LINK then return end
	local per_tick = watts / 60
	if entity.power_usage ~= per_tick then
		entity.power_usage = per_tick
		entity.electric_buffer_size = math.max(watts * 2, 1)
	end
end

--- does the block have power? `linked`: it is linked now (it keeps the link until its buffer has run dry; a new link wants
--- half of the buffer)
local function powered(entity, linked)
	local buffer = entity.electric_buffer_size or 0
	if buffer <= 0 then return false end
	if linked then return entity.energy > 0 end
	return entity.energy >= buffer / 2
end

--- the valid blocks of kind `name` and frequency `f`, by unit number
local function members(s, name, f)
	local out = {}
	for unit, rec in pairs(s.recs) do
		if rec.freq == f and rec.entity.valid and rec.entity.name == name then out[#out + 1] = unit end
	end
	table.sort(out)
	return out
end

--- may `a` and `b` (a pair of kind `name`) link where they stand? Returns true and the distance (nil for the bridge), or
--- false, the reason ("other-surface", "out-of-range") and the distance
local function reach(name, a, b)
	if KINDS[name].across then return true, nil end
	if a.surface ~= b.surface then return false, "other-surface" end
	local dx, dy = a.position.x - b.position.x, a.position.y - b.position.y
	local dist = math.sqrt(dx * dx + dy * dy)
	if dist > (spec(name).range or 0) then return false, "out-of-range", dist end
	return true, dist
end

local last_sig = {}                     -- frequency -> the links (with power) of its last decision (issue #559, derived)

--- issue #559: the distance from the link of record `rec` to the nearest other link of frequency `f` in its reach (nil: none)
local function nearest_in_reach(s, rec, f)
	local range = spec(LINK).range or 0
	local w, m = rec.where, nil
	for unit, o in pairs(s.recs) do
		if o ~= rec and o.freq == f and o.where.surface == w.surface and o.entity.valid and o.entity.name == LINK then
			local dx, dy = o.where.x - w.x, o.where.y - w.y
			local d2 = dx * dx + dy * dy
			if d2 <= range * range and (not m or d2 < m) then m = d2 end
		end
	end
	return m and math.sqrt(m) or nil
end

--- Issue #559: decide the group of ME Wireless Links of frequency `f`: the edges of a minimum spanning forest of the links that
--- have power (a linked one keeps it until its buffer has run dry, as a pair did), two of them in reach when they stand on one
--- surface within the range; each link's drain by its longest edge. A pair link of a save before #559 (N.set_qlink) goes.
--- Returns true when the graph changed.
local function decide_links(s, f)
	local list = members(s, LINK, f)
	local changed = false
	local range = spec(LINK).range or 0
	local r2 = range * range
	local on, keys = {}, {}
	for i, unit in ipairs(list) do
		local e = s.recs[unit].entity
		if N.qlink_of(e) then changed = N.set_qlink(e, nil) or changed end
		on[i] = powered(e, N.wlinks_of(e) ~= nil)
		keys[i] = unit .. (on[i] and "+" or "-")
	end
	--- (the same links and the same of them with power as at the last decision: the same forest and drains; derived, so a load
	--- or a joining peer decides once more and gets the same edges)
	local sig = table.concat(keys, ",")
	if last_sig[f] == sig then return changed end
	last_sig[f] = sig
	local n = #list
	local xs, ys, ss = {}, {}, {}                              -- (the places of the records: no API call in the loops)
	for i, unit in ipairs(list) do
		local w = s.recs[unit].where
		xs[i], ys[i], ss[i] = w.x, w.y, w.surface
	end
	--- Prim's minimum spanning forest of the links with power
	local done, best, parent, edges, longest = {}, {}, {}, {}, {}
	for i = 1, n do best[i] = math.huge end
	for _ = 1, n do
		local bi
		for i = 1, n do
			if on[i] and not done[i] and (not bi or best[i] < best[bi]) then bi = i end   -- (none in reach: the lowest unit, a new tree)
		end
		if not bi then break end
		done[bi] = true
		local pi = parent[bi]
		if pi then
			local d = math.sqrt(best[bi])
			edges[#edges + 1] = { list[bi], list[pi] }
			if d > (longest[bi] or -1) then longest[bi] = d end
			if d > (longest[pi] or -1) then longest[pi] = d end
		end
		local ax, ay, as = xs[bi], ys[bi], ss[bi]
		for j = 1, n do
			if on[j] and not done[j] and ss[j] == as then
				local dx, dy = ax - xs[j], ay - ys[j]
				local d2 = dx * dx + dy * dy
				if d2 <= r2 and d2 < best[j] then
					best[j] = d2
					parent[j] = bi
				end
			end
		end
	end
	--- a link without power pays for the distance to its nearest link in reach (as a pair's ends did before they linked: its
	--- buffer is the size the link wants)
	for i = 1, n do
		if not on[i] then
			local m
			for j = 1, n do
				if j ~= i and ss[j] == ss[i] then
					local dx, dy = xs[i] - xs[j], ys[i] - ys[j]
					local d2 = dx * dx + dy * dy
					if d2 <= r2 and (not m or d2 < m) then m = d2 end
				end
			end
			longest[i] = m and math.sqrt(m) or nil
		end
	end
	for i, unit in ipairs(list) do set_drain(s.recs[unit].entity, drain(LINK, longest[i])) end
	return N.set_wlinks(list, edges) or changed
end

--- Decide the pair of kind `name` and frequency `f` (0: none): linked while there are exactly two blocks of it, they reach
--- each other and both have power; every other block of it is unlinked (and draws its base). The ME Wireless Link's group:
--- decide_links. Returns true when a link changed.
local function decide(s, name, f)
	if not f or f == 0 then return false end
	if name == LINK then return decide_links(s, f) end
	local list = members(s, name, f)
	local changed = false
	if #list == 2 then
		local a, b = s.recs[list[1]].entity, s.recs[list[2]].entity
		local ok, dist = reach(name, a, b)
		local linked = N.qlink_of(a) == b.unit_number
		local w = drain(name, ok and dist or nil)
		set_drain(a, w)
		set_drain(b, w)
		if ok and powered(a, linked) and powered(b, linked) then
			if not linked then changed = N.set_qlink(a, b) end
		elseif linked then
			changed = N.set_qlink(a, nil)
		end
	else
		for _, unit in ipairs(list) do
			local e = s.recs[unit].entity
			set_drain(e, drain(name, nil))
			if N.qlink_of(e) then changed = N.set_qlink(e, nil) or changed end
		end
	end
	return changed
end

local function register(entity)
	local s = state()
	local unit = entity.unit_number
	local rec = s.recs[unit]
	if not rec then
		rec = { entity = entity, freq = 0, where = { surface = entity.surface.index, x = entity.position.x, y = entity.position.y } }
		s.recs[unit] = rec
		set_drain(entity, drain(entity.name, nil))
	end
	return rec
end

--- set the frequency of a block (a whole number 0 .. 2^31 - 1; 0: none); its old and its new pair are decided at once.
--- Returns true when it was set.
function M.set_frequency(entity, f)
	if not is_linker(entity) then return false end
	f = math.floor(tonumber(f) or -1)
	if f < 0 or f > MAX_FREQ then return false end
	local s = state()
	local rec = register(entity)
	local old = rec.freq
	if old == f then return true end
	if N.qlink_of(entity) then N.set_qlink(entity, nil) end
	--- issue #559: a wireless link without power and without an edge (a block just built) changes neither group: its drain is
	--- set for its nearest link in reach, and the next slow step decides both groups (a burst of n built links costs n^2, not
	--- n^3); else it leaves its old group at once and both groups are decided now
	local quiet = entity.name == LINK and not N.wlinks_of(entity) and not powered(entity, false)
	if entity.name == LINK then N.set_wlinks({ entity.unit_number }, {}) end
	rec.freq = f
	set_drain(entity, drain(entity.name, nil))
	if quiet then
		last_sig[old], last_sig[f] = nil, nil
		set_drain(entity, drain(LINK, f ~= 0 and nearest_in_reach(s, rec, f) or nil))
		return true
	end
	decide(s, entity.name, old)
	decide(s, entity.name, f)
	return true
end

--- Issue #559: what the window of a wireless link shows (see M.info): `group` the links of its frequency on its surface (with
--- itself), `edges` how many it is linked to, `partner` and `distance` its nearest linked one (else the nearest of the group).
--- Status: "no-frequency", "linked", "waiting" (alone on its surface; "other-surface" when a link of the frequency is on
--- another one), "out-of-range" (none of the group in reach), "no-power" (this one), "no-power-there" (the ones in reach).
local function link_info(s, entity, rec, out)
	if rec.freq == 0 then out.status = "no-frequency" return out end
	local own = entity.surface.index
	local near, nd, lnear, lnd, other, inreach = nil, nil, nil, nil, nil, false
	local linked = N.wlinks_of(entity) or {}
	out.group, out.edges = 1, table_size(linked)
	for _, unit in ipairs(members(s, LINK, rec.freq)) do
		local e = s.recs[unit].entity
		if unit ~= entity.unit_number then
			if e.surface.index ~= own then
				other = other or e
			else
				out.group = out.group + 1
				local dx, dy = e.position.x - entity.position.x, e.position.y - entity.position.y
				local d = math.sqrt(dx * dx + dy * dy)
				if not nd or d < nd then near, nd = e, d end
				if linked[unit] and (not lnd or d < lnd) then lnear, lnd = e, d end
				if d <= (out.range or 0) then inreach = true end
			end
		end
	end
	local p, d = lnear or near, lnear and lnd or nd
	if p then out.partner, out.distance = { surface = p.surface.name, x = p.position.x, y = p.position.y }, d end
	if out.edges > 0 then out.status = "linked"
	elseif not near then
		out.status = other and "other-surface" or "waiting"
		if other then out.partner = { surface = other.surface.name, x = other.position.x, y = other.position.y } end
	elseif not inreach then out.status = "out-of-range"
	elseif not powered(entity, false) then out.status = "no-power"
	else out.status = "no-power-there" end
	return out
end

--- what the window shows: { kind ("bridge" or "link"), freq, status, partner = { surface, x, y } or nil, watts (its drain
--- now), energy, buffer, distance and range (a wireless link) }. Status: "no-frequency", "linked", "waiting" (no second
--- block of the frequency), "taken" (more than two bridges), "other-surface", "no-power" (this one), "no-power-there". A
--- wireless link: link_info.
function M.info(entity)
	local rec = rec_of(entity)
	if not rec then return nil end
	local s = state()
	local name = entity.name
	local out = { kind = name == NAME and "bridge" or "link", freq = rec.freq, energy = entity.energy,
		buffer = entity.electric_buffer_size, watts = name == LINK and entity.power_usage * 60 or drain(name),
		range = name == LINK and spec(name).range or nil }
	if name == LINK then return link_info(s, entity, rec, out) end
	local list = rec.freq ~= 0 and members(s, name, rec.freq) or {}
	if #list == 2 then
		local other = s.recs[list[1] == entity.unit_number and list[2] or list[1]].entity
		local ok, why, dist = reach(name, entity, other)
		out.distance = ok and why or dist
		out.partner = { surface = other.surface.name, x = other.position.x, y = other.position.y }
		if N.qlink_of(entity) then out.status = "linked" return out end
		if not ok then out.status = why
		elseif not powered(entity, false) then out.status = "no-power"
		else out.status = "no-power-there" end
		return out
	end
	if rec.freq == 0 then out.status = "no-frequency"
	elseif #list < 2 then out.status = "waiting"
	else out.status = "taken" end
	return out
end

--- the network's slow step (every 60 ticks): the pairs of every kind and frequency in use
local function slow()
	local s = storage.fork_me_qbridge
	if not (s and next(s.recs)) then return end
	local list, seen = {}, {}
	for unit, rec in pairs(s.recs) do
		if not rec.entity.valid then
			s.recs[unit] = nil                                    -- (removed without an event: the graph's sweep drops its node)
		elseif rec.freq ~= 0 then
			local key = rec.entity.name .. ":" .. rec.freq
			if not seen[key] then
				seen[key] = true
				list[#list + 1] = { rec.entity.name, rec.freq, key }
			end
		end
	end
	table.sort(list, function(a, b) return a[3] < b[3] end)
	for _, p in ipairs(list) do decide(s, p[1], p[2]) end
end
N.slow_hooks[#N.slow_hooks + 1] = slow
M.step = slow

--------------------------------------------------------------------------------
--- events
--------------------------------------------------------------------------------

--- `tags`: blueprint tags of a built ghost (or of a paste over a block, issue #383); `source`: the original of a clone
function M.on_built(entity, tags, source)
	if not is_linker(entity) then return end
	register(entity)
	local t = type(tags) == "table" and tags[KINDS[entity.name].tag] or nil
	local f
	if type(t) == "table" then f = t.freq
	elseif is_linker(source) and source.name == entity.name then
		local from = rec_of(source)
		f = from and from.freq
	end
	if f then M.set_frequency(entity, f) end
end

function M.on_removed(entity)
	local s = storage.fork_me_qbridge
	if not (s and is_linker(entity) and entity.unit_number) then return end
	local rec = s.recs[entity.unit_number]
	if not rec then return end
	s.recs[entity.unit_number] = nil                              -- (its link goes with its node: N.on_removed; a third block
	if entity.name == LINK then                                   -- of the frequency pairs at the next slow step)
		N.set_wlinks({ entity.unit_number }, {})                   -- (issue #559: the rest of its group links anew at once)
		decide(s, LINK, rec.freq)
	end
end

--- settings paste: the frequency, between two blocks of the same kind. Issue #527: the mod's copy and paste keys call it
--- (scripts/fork-me-paste-keys.lua, prototypes/paste.lua KEYS). The game pastes nothing onto a bridge or a link, not even
--- LuaEntity.copy_settings from a script (allow_copy_paste stays the energy interface's false), so their power settings
--- (which the game copies between energy interfaces that allow it) need no repair here; the runtime test SETTINGSPASTE
--- fails if the game pastes again.
function M.on_entity_settings_pasted(event)
	local src, dst = event.source, event.destination
	if not (is_linker(dst) and is_linker(src) and src.name == dst.name) then return end
	local from = rec_of(src)
	if from then M.set_frequency(dst, from.freq) end
end

function M.tag_blueprint(bp, mapping)
	local s = storage.fork_me_qbridge
	if not s then return end
	for index, entity in pairs(mapping) do
		local rec = entity.valid and KINDS[entity.name] and s.recs[entity.unit_number]
		if rec and rec.freq ~= 0 then bp.set_blueprint_entity_tag(index, KINDS[entity.name].tag, { freq = rec.freq }) end
	end
end

--- after a mod change: the blocks of the world (records kept by unit number), every pair decided again
function M.on_configuration_changed()
	local s = state()
	for unit, rec in pairs(s.recs) do
		if not (rec.entity and rec.entity.valid) then s.recs[unit] = nil end
	end
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = { NAME, LINK } }) do register(e) end
	end
	slow()
end

function M.by_unit(unit)
	local s = storage.fork_me_qbridge
	local rec = s and s.recs[unit]
	return rec and rec.entity and rec.entity.valid and rec.entity or nil
end

remote.add_interface("gregtorio-me-qbridge", {
	info = function(entity) return M.info(entity) end,
	set_frequency = function(entity, f) return M.set_frequency(entity, f) end,
	paste = function(source, destination) M.on_entity_settings_pasted{ source = source, destination = destination } end,
	--- the slow step's check of every pair (tests: without waiting for the next one)
	step = function() slow() end,
	--- issue #384: the drain (W) of a block of kind `name` linked over `dist` tiles (nil: unpaired)
	drain = function(name, dist) return drain(name, dist) end,
})

M.NAME = NAME
M.LINK = LINK
return M
