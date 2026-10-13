--------------------------------------------------------------------------------
--- FORK AE2: ME TOGGLE BUS AND ME INVERTED TOGGLE BUS (issue #355; prototypes/autocrafting.lua)
--- AE2-Unofficial's toggle buses (appeng/parts/misc/PartToggleBus.java: it connects its two sides while redstone is on it,
--- `updateInternalState` makes or breaks the grid connection; PartInvertedToggleBus.java: the opposite). Here a lamp whose
--- circuit condition is the redstone: the storage engine registers the bus while it joins and unregisters it while it is
--- open (N.set_toggle: the network splits and merges as for a removed and a built cable, with everything that follows from
--- that: crafting jobs, windows, storage of the parts).
--- Work (issue #5's rule: a queue and a budget, no tick handler of its own): a step hook of fork-me-autocraft.lua checks at
--- most CHECKS_PER_TICK buses per tick in the order of storage.fork_me_toggle.list, each at most every INTERVAL ticks; a
--- check reads the lamp's condition (N.toggle_wants) and changes the graph only when the wish changed. The game copies the
--- condition (blueprints, settings paste, clones). State: storage.fork_me_toggle (lazy).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local autocraft = require("scripts.fork-me-autocraft")

local M = {}

local NAMES = { ["me-toggle-bus"] = true, ["me-inverted-toggle-bus"] = true }
M.NAMES = NAMES
local CHECKS_PER_TICK = 8
local INTERVAL = 10               -- ticks: how late a bus follows its condition at most, while the budget holds

local function state()
	local s = storage.fork_me_toggle
	if not s then
		s = { recs = {}, list = {}, cursor = 1 }
		storage.fork_me_toggle = s
	end
	return s
end

--- the bus's status in its tooltip: joined (green) or apart (red)
local function show(entity, joined)
	entity.custom_status = { diode = joined and defines.entity_status_diode.green or defines.entity_status_diode.red,
		label = { joined and "fork-me-toggle.joined" or "fork-me-toggle.apart" } }
end

local function record(entity)
	local s = state()
	local unit = entity.unit_number
	local rec = s.recs[unit]
	if not rec then
		rec = { entity = entity }
		s.recs[unit] = rec
		s.list[#s.list + 1] = unit
	end
	return rec
end

--- one check: the condition now, the graph changed when it differs from the bus's state
local function check(rec)
	local e = rec.entity
	rec.last = game.tick
	local want = N.toggle_wants(e)
	if want ~= rec.joined then
		N.set_toggle(e, want)
		rec.joined = N.toggle_joined(e)
		show(e, rec.joined)
	end
end
M.check = check

--- the step hook (every tick): at most CHECKS_PER_TICK buses, each at most every INTERVAL ticks
local function on_tick(_, tick)
	local s = storage.fork_me_toggle
	if not (s and #s.list > 0) then return end
	local done, tries = 0, 0
	while done < CHECKS_PER_TICK and tries < #s.list do
		tries = tries + 1
		if s.cursor > #s.list then s.cursor = 1 end
		local unit = s.list[s.cursor]
		local rec = s.recs[unit]
		if not (rec and rec.entity.valid) then
			s.recs[unit] = nil
			table.remove(s.list, s.cursor)
		else
			if rec.last and tick - rec.last < INTERVAL then break end    -- (in this order the rest is newer)
			check(rec)
			done = done + 1
			s.cursor = s.cursor + 1
		end
	end
end
autocraft.step_hooks[#autocraft.step_hooks + 1] = on_tick

--- a built bus (after the storage engine registered it or not): its record and status
function M.on_built(entity)
	if not (entity and entity.valid and NAMES[entity.name]) then return end
	local rec = record(entity)
	rec.joined = N.toggle_joined(entity)
	rec.last = game.tick
	show(entity, rec.joined)
end

--- after a mod change: the buses of the world (the graph was rebuilt without the open ones), checked again
function M.on_configuration_changed()
	local s = state()
	s.recs, s.list, s.cursor = {}, {}, 1
	local names = {}
	for n in pairs(NAMES) do if prototypes.entity[n] then names[#names + 1] = n end end
	if #names == 0 then return end
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = names }) do
			local rec = record(e)
			rec.joined = N.toggle_joined(e)
			check(rec)
		end
	end
	table.sort(s.list)
end

remote.add_interface("gregtorio-me-toggle", {
	--- (tests) a check now (what the step does); returns whether the bus joins afterwards
	check = function(entity)
		if not (entity and entity.valid and NAMES[entity.name]) then return nil end
		local rec = record(entity)
		check(rec)
		return rec.joined
	end,
	--- { joined, wants }
	get = function(entity)
		if not (entity and entity.valid and NAMES[entity.name]) then return nil end
		return { joined = N.toggle_joined(entity), wants = N.toggle_wants(entity) }
	end,
})

return M
