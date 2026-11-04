--------------------------------------------------------------------------------
--- ME NETWORK: THE OLD BUSES AND PATTERN PROVIDERS BECOME THE WIRED ONES (issue #628; prototypes/wired.lua)
--- Until 0.5.11 the ME Import, Export and Storage Bus and the ME Pattern Provider were simple entities. Since 0.5.12 they are
--- display panels that take circuit wires themselves, under the same names; migrations/me-network-wired-hosts.json renames the
--- old ones of a save to `<name>-legacy` (the same entity and unit number, hidden prototypes that collide with nothing).
---   * on_configuration_changed (and on_init), first: every placed old block is replaced by the wired block at its place
---     (direction, force, quality, health, last user), and its state moves to the new unit number: the module records with
---     everything in them (filters, cards, priorities, modes, patterns, locks, the condition and the old connector), the
---     graph node with its edges, its network and its waits, the storage bus's external cell, the jobs a bus's Crafting
---     Card started. The modules then rebuild their lists and queues from the records, as at every update. Ghosts of old
---     blocks become ghosts of the wired ones (their tags and wires kept).
---   * The build event, before every other module: an old block (built by a robot from an old ghost, or by a script) is
---     replaced at once and the event goes on with the wired block; an old ghost (a blueprint of the save, which the JSON
---     migration renamed) becomes a ghost of the wired block.
--- Old connectors (the hidden lamps of issue #412) are scripts/fork-me-connector.lua's (M.adopt): they hand their wires and
--- condition to the block at their place.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local IO = require("scripts.fork-me-io")
local SB = require("scripts.fork-me-storagebus")
local AC = require("scripts.fork-me-autocraft")
local Conn = require("scripts.fork-me-connector")
local PO = require("scripts.fork-me-pasteover")

local M = {}

local SUFFIX = "-legacy"
local WIRES = { defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green }

--- legacy name -> wired name (the hosts of the connector module whose legacy prototype exists; read once per load)
local LEGACY
local function legacy()
	if not LEGACY then
		LEGACY = {}
		for name in pairs(Conn.HOSTS) do
			if prototypes.entity[name .. SUFFIX] then LEGACY[name .. SUFFIX] = name end
		end
	end
	return LEGACY
end
function M.is_legacy(name) return legacy()[name] ~= nil end

--- the wires of `e` as { [wire id] = { { target, origin } } } (kept over its removal)
local function wires_of(e)
	local out = {}
	for _, w in pairs(WIRES) do
		local c = e.get_wire_connector(w, false)
		if c and c.connection_count > 0 then
			local list = {}
			for _, conn in pairs(c.connections) do list[#list + 1] = { conn.target, conn.origin } end
			out[w] = list
		end
	end
	return out
end
local function connect(e, wires)
	for w, list in pairs(wires) do
		local c = e.get_wire_connector(w, true)
		for _, t in ipairs(list) do
			if t[1].valid then c.connect_to(t[1], false, t[2]) end
		end
	end
end

--- Replaces the placed old block `old` by the wired block; `rekey`: its state moves to the new unit (a block of a save; a block
--- built just now has none). Returns the new entity, or nil (logged) when it could not be placed.
local function replace(old, rekey)
	local target = legacy()[old.name]
	local surface, position, direction, force = old.surface, old.position, old.direction, old.force
	local quality, last_user, health = old.quality, old.last_user, old.health
	local wires = wires_of(old)
	--- (the old block collides with nothing: the new one is built while it stands, its state moves, then it goes)
	local new = surface.create_entity{ name = target, position = position, direction = direction, force = force,
		quality = quality, create_build_effect_smoke = false }
	if not new then
		log("ME-WIRED: could not place " .. target .. " at " .. position.x .. "," .. position.y .. " on " .. surface.name)
		return nil
	end
	if last_user then new.last_user = last_user end
	if health and new.max_health and health < new.max_health then new.health = health end
	connect(new, wires)
	if rekey then
		local u = old.unit_number
		IO.rekey(u, new)
		SB.rekey(u, new)
		AC.rekey(u, new)
		Conn.rekey(u, new)
		N.rekey(u, new)                                       -- (last: a wait it fires wakes a block whose record moved)
	end
	old.destroy()
	return new
end

--- Replaces the ghost `g` of an old block by a ghost of the wired block (its tags and wires kept); returns it, or nil
local function replace_ghost(g)
	local target = legacy()[g.ghost_name]
	local surface = g.surface
	local def = { name = "entity-ghost", inner_name = target, position = g.position, direction = g.direction, force = g.force,
		quality = g.quality, tags = g.tags, create_build_effect_smoke = false }
	local wires, last_user = wires_of(g), g.last_user
	g.destroy()
	local ghost = surface.create_entity(def)
	if not ghost then
		--- (a blueprint of old blocks pasted over wired ones: the game put the old ghost on top, as it collides with nothing)
		--- the block there takes the ghost's settings, as a blueprint pasted over it gives them (scripts/fork-me-pasteover.lua)
		for _, e in pairs(surface.find_entities_filtered{ name = target, position = def.position, force = def.force }) do
			if PO.apply and type(def.tags) == "table" then PO.apply(e, def.tags, nil) end
			connect(e, wires)
		end
		return nil
	end
	if last_user then ghost.last_user = last_user end
	connect(ghost, wires)
	return ghost
end

--- on_configuration_changed and on_init, before the graph and the modules: every old block and ghost (sorted by unit number:
--- the new units keep their order). Logs what it did (ME-WIRED).
function M.migrate()
	local names = {}
	for name in pairs(legacy()) do names[#names + 1] = name end
	if #names == 0 then return end
	table.sort(names)
	local blocks, ghosts, failed = 0, 0, 0
	for _, surface in pairs(game.surfaces) do
		local list = surface.find_entities_filtered{ name = names }
		table.sort(list, function(a, b) return a.unit_number < b.unit_number end)
		for _, old in ipairs(list) do
			if old.valid then
				if replace(old, true) then blocks = blocks + 1 else failed = failed + 1 end
			end
		end
		for _, g in pairs(surface.find_entities_filtered{ ghost_name = names }) do
			if g.valid and replace_ghost(g) then ghosts = ghosts + 1 end
		end
	end
	if blocks + ghosts + failed > 0 then
		log(string.format("ME-WIRED: %d blocks, %d ghosts replaced by the wired blocks, %d could not be placed", blocks, ghosts, failed))
	end
end

--- The build event (control.lua, before every other module): an old block or its ghost is replaced; returns the entity the
--- event goes on with (the wired block, its ghost, or `entity` itself when it is no old one; nil when it could not be placed)
function M.on_built(entity)
	if not (entity and entity.valid) then return entity end
	local map = legacy()
	if entity.name == "entity-ghost" then
		if not map[entity.ghost_name] then return entity end
		return replace_ghost(entity)
	end
	if not map[entity.name] then return entity end
	return replace(entity, false)
end

return M
