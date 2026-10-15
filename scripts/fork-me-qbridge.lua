--------------------------------------------------------------------------------
--- ME QUANTUM BRIDGE (me-network issue #385, option 2; AE2's Quantum Network Bridge; prototypes/network.lua; guide:
--- docs/AE2.md "ME Quantum Bridge")
---   * A 3x3 member of the network with a frequency (a whole number set in its window, 0: none). Exactly two bridges with the
---     same frequency are a pair; while both have power, the pair is linked: a graph edge between them (N.set_qlink), so
---     the networks on both sides are one network, at any distance and on any surface (another planet, a space platform, a
---     factory floor of another mod). A third bridge of a frequency links nothing (the frequency is taken); the other two
---     stay linked.
---   * Power: each bridge is an electric energy interface that draws its constant drain (mod-data `quantum_bridge.watts`)
---     from the power grid where it stands. The link forms when both have at least half their buffer and goes when one of
---     them has run dry (no flicker at the edge). The ME network itself does not pay for it (POWERED_SELF).
---   * Like AE2: one network, one controller. Two networks with a controller each, linked, are in conflict (the controller
---     rule of the network: the second controller's network does not work); build the far side without a controller.
---   * The checks of the pairs run in the network's slow step (every 60 ticks, N.slow_hooks, as the ME Chest's power): one
---     energy read per bridge; a change of a frequency, a built or removed bridge is checked at once.
---   * Kept in blueprints, settings paste and clones: the frequency (a third bridge of it then waits).
--- State: storage.fork_me_qbridge = { recs = { [unit] = { entity, freq, where } }, list (units, sorted) }; the links are
--- the network's state (storage.fork_me_net.qlink).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")

local M = {}

local NAME = "me-quantum-bridge"
local TAG = "fork_me_qbridge"
local MAX_FREQ = 2 ^ 31 - 1

local function state()
	local s = storage.fork_me_qbridge
	if not s then
		s = { recs = {} }
		storage.fork_me_qbridge = s
	end
	return s
end

local function is_bridge(entity) return entity and entity.valid and entity.name == NAME end

local function rec_of(entity)
	local s = storage.fork_me_qbridge
	return s and is_bridge(entity) and s.recs[entity.unit_number] or nil
end

local watts_cache
local function watts()
	if not watts_cache then
		local md = prototypes.mod_data["fork-me-network"]
		watts_cache = md and md.data.quantum_bridge and md.data.quantum_bridge.watts or 1000000
	end
	return watts_cache
end

--- does the bridge have power? `linked`: it is linked now (it keeps the link until its buffer has run dry; a new link wants
--- half of the buffer)
local function powered(entity, linked)
	local buffer = entity.electric_buffer_size or 0
	if buffer <= 0 then return false end
	if linked then return entity.energy > 0 end
	return entity.energy >= buffer / 2
end

--- the valid bridges of frequency `f`, by unit number
local function members(s, f)
	local out = {}
	for unit, rec in pairs(s.recs) do
		if rec.freq == f and rec.entity.valid then out[#out + 1] = unit end
	end
	table.sort(out)
	return out
end

--- Decide the pair of frequency `f` (0: none): linked while there are exactly two bridges of it and both have power;
--- every other bridge of it is unlinked. Returns true when a link changed.
local function decide(s, f)
	if not f or f == 0 then return false end
	local list = members(s, f)
	local changed = false
	if #list == 2 then
		local a, b = s.recs[list[1]].entity, s.recs[list[2]].entity
		local linked = N.qlink_of(a) == b.unit_number
		if powered(a, linked) and powered(b, linked) then
			if not linked then changed = N.set_qlink(a, b) end
		elseif linked then
			changed = N.set_qlink(a, nil)
		end
	else
		for _, unit in ipairs(list) do
			local e = s.recs[unit].entity
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
	end
	return rec
end

--- set the frequency of a bridge (a whole number 0 .. 2^31 - 1; 0: none); its old and its new pair are decided at once.
--- Returns true when it was set.
function M.set_frequency(entity, f)
	if not is_bridge(entity) then return false end
	f = math.floor(tonumber(f) or -1)
	if f < 0 or f > MAX_FREQ then return false end
	local s = state()
	local rec = register(entity)
	local old = rec.freq
	if old == f then return true end
	if N.qlink_of(entity) then N.set_qlink(entity, nil) end
	rec.freq = f
	decide(s, old)
	decide(s, f)
	return true
end

--- what the window shows: { freq, status, partner = { surface, x, y } or nil, watts, energy, buffer }. Status: "no-frequency",
--- "linked", "waiting" (no second bridge of the frequency), "taken" (more than two), "no-power" (this one), "no-power-there".
function M.info(entity)
	local rec = rec_of(entity)
	if not rec then return nil end
	local s = state()
	local out = { freq = rec.freq, watts = watts(), energy = entity.energy, buffer = entity.electric_buffer_size }
	local pu = N.qlink_of(entity)
	if pu then
		local p = s.recs[pu] and s.recs[pu].entity
		out.status = "linked"
		if p and p.valid then out.partner = { surface = p.surface.name, x = p.position.x, y = p.position.y } end
		return out
	end
	if rec.freq == 0 then out.status = "no-frequency" return out end
	local list = members(s, rec.freq)
	if #list < 2 then out.status = "waiting"
	elseif #list > 2 then out.status = "taken"
	elseif not powered(entity, false) then out.status = "no-power"
	else out.status = "no-power-there" end
	return out
end

--- the network's slow step (every 60 ticks): the pairs of every frequency in use
local function slow()
	local s = storage.fork_me_qbridge
	if not (s and next(s.recs)) then return end
	local freqs, seen = {}, {}
	for unit, rec in pairs(s.recs) do
		if not rec.entity.valid then
			s.recs[unit] = nil                                    -- (removed without an event: the graph's sweep drops its node)
		elseif rec.freq ~= 0 and not seen[rec.freq] then
			seen[rec.freq] = true
			freqs[#freqs + 1] = rec.freq
		end
	end
	table.sort(freqs)
	for _, f in ipairs(freqs) do decide(s, f) end
end
N.slow_hooks[#N.slow_hooks + 1] = slow
M.step = slow

--------------------------------------------------------------------------------
--- events
--------------------------------------------------------------------------------

--- `tags`: blueprint tags of a built ghost (or of a paste over a bridge, issue #383); `source`: the original of a clone
function M.on_built(entity, tags, source)
	if not is_bridge(entity) then return end
	register(entity)
	local t = type(tags) == "table" and tags[TAG] or nil
	local f
	if type(t) == "table" then f = t.freq
	elseif is_bridge(source) then
		local from = rec_of(source)
		f = from and from.freq
	end
	if f then M.set_frequency(entity, f) end
end

function M.on_removed(entity)
	local s = storage.fork_me_qbridge
	if not (s and is_bridge(entity) and entity.unit_number) then return end
	local rec = s.recs[entity.unit_number]
	if not rec then return end
	s.recs[entity.unit_number] = nil                              -- (its link goes with its node: N.on_removed; a third bridge
end                                                           -- of the frequency pairs at the next slow step)

function M.on_entity_settings_pasted(event)
	local src, dst = event.source, event.destination
	if not (is_bridge(src) and is_bridge(dst)) then return end
	local from = rec_of(src)
	if from then M.set_frequency(dst, from.freq) end
end

function M.tag_blueprint(bp, mapping)
	local s = storage.fork_me_qbridge
	if not s then return end
	for index, entity in pairs(mapping) do
		local rec = entity.valid and entity.name == NAME and s.recs[entity.unit_number]
		if rec and rec.freq ~= 0 then bp.set_blueprint_entity_tag(index, TAG, { freq = rec.freq }) end
	end
end

--- after a mod change: the bridges of the world (records kept by unit number), every pair decided again
function M.on_configuration_changed()
	local s = state()
	for unit, rec in pairs(s.recs) do
		if not (rec.entity and rec.entity.valid) then s.recs[unit] = nil end
	end
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = NAME }) do register(e) end
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
	--- the slow step's check of every pair (tests: without waiting for the next one)
	step = function() slow() end,
})

M.NAME = NAME
return M
