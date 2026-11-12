--------------------------------------------------------------------------------
--- ME NETWORK: BLOCKS THAT ANOTHER MOD MOVES, AND SURFACES THAT GO (Space Exploration)
---
--- A mod that moves buildings clones them and then destroys the originals: Space Exploration flies a spaceship by
--- LuaSurface.clone_brush onto another surface (on_entity_cloned for every entity) and, in the same tick, raises
--- script_raised_destroy for every original and destroys it (its scripts/spaceship-clone.lua). For this mod a clone is a
--- copy: the clone gets the settings of its source and none of its contents (a cloned drive is empty, a cloned provider
--- has no patterns, cards are asked from the network), and a block a script destroys spills what it holds. Together that
--- left the cells, patterns and cards of a spaceship's network on the ground where it took off.
---
--- So a clone whose source a script destroys in the tick of the clone is a move: before the source is removed as any
--- destroyed block, what it holds goes to the clone (each module's M.on_moved): the cells of a drive, an ME Chest and an
--- ME IO Port with their contents, the patterns of a provider, the cards of every block with card slots, the slots of the
--- ME Cell Workbench and the pattern terminals, the view cells of a terminal, the terminal in a charger, what a P2P tunnel
--- carries. The removal that follows finds nothing to spill. What the game clones itself (the chest of an ME Interface, its
--- side tanks, the tank of an ME Chest, the three chests of an ME Logistic Interface) arrives with the clone; the source of
--- a logistic interface is emptied, or its chests' contents would exist twice.
---
--- The hidden parts of a block (tanks, chests) are entities of their own on its tile, and the other mod may destroy one
--- before the block: the destruction of a cloned part moves its block first.
---
--- A clone that keeps its source (the editor's clone tool, a mod that copies an area) stays a copy: the pairs of a tick are
--- forgotten with the tick.
---
--- An ME Controller that moved has a new unit number, and the Wireless ME Terminals linked to it hold the old one in their
--- item tags, wherever they lie: the old number is kept as a forward to the new one (M.resolve, read by the lookup of an
--- entity by its unit, scripts/fork-me-gui.lua).
---
--- A surface that is deleted or cleared takes its entities without an event. The members on it are removed before it
--- goes, as destroyed blocks (their networks, records and queues with them; what they would spill goes with the surface,
--- as a chest's contents do), so no network of a surface that no longer exists stays in `storage`.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")

local M = {}

--- the functions(source, destination) of the modules, in the order they run (control.lua fills it; the graph's cells last)
M.hooks = {}
--- function(event) of control.lua: a member destroyed (the modules, then the graph)
M.destroyed = nil

local function state()
	local s = storage.fork_me_move
	if not s then
		s = { tick = -1, pairs = {}, units = {} }
		storage.fork_me_move = s
	end
	return s
end

--- is `name` an entity of this mod? (a member of the graph, or one of the hidden parts: every prototype of this mod is
--- named "me-...")
local function ours(name) return N.kind_of(name) ~= nil or name:sub(1, 3) == "me-" end

--- on_entity_cloned: the pair is remembered for this tick
function M.on_cloned(source, destination)
	if not (source and source.valid and destination and destination.valid) then return end
	local unit = source.unit_number
	if not (unit and destination.unit_number and source.name == destination.name and ours(source.name)) then return end
	local s = state()
	local tick = game.tick
	if s.tick ~= tick then
		s.tick = tick
		s.pairs = {}
	end
	s.pairs[unit] = { source, destination }
end

--- the pair of `unit` cloned in this tick is taken out and its move made; true when there was one
local function move(s, unit)
	local pair = s.pairs[unit]
	if not pair then return false end
	s.pairs[unit] = nil
	local source, destination = pair[1], pair[2]
	if not (source.valid and destination.valid) then return false end
	for _, hook in ipairs(M.hooks) do hook(source, destination) end
	if N.kind_of(source.name) == "controller" then s.units[unit] = destination.unit_number end
	return true
end

--- script_raised_destroy, before the block is removed: `entity` is about to be destroyed by a script. When it was cloned in
--- this tick its contents go to the clone; a hidden part takes the blocks on its tile along. Returns true for a move.
function M.before_destroyed(entity)
	local s = storage.fork_me_move
	if not (s and s.tick == game.tick and entity and entity.valid and entity.unit_number) then return false end
	if not s.pairs[entity.unit_number] then return false end
	local member = N.kind_of(entity.name) ~= nil
	local moved = move(s, entity.unit_number)                -- (also a block that is no member of the graph: the ME Cell Workbench)
	if member then return moved end
	--- a hidden part (or a block without a place in the graph): the members on its tile
	local p = entity.position
	local found = entity.surface.find_entities_filtered{ area = { { p.x - 0.4, p.y - 0.4 }, { p.x + 0.4, p.y + 0.4 } },
		force = entity.force }
	for _, e in pairs(found) do
		if e.valid and e.unit_number and N.kind_of(e.name) then move(s, e.unit_number) end
	end
	return moved
end

--- the unit number a moved ME Controller has now (itself when it never moved)
function M.resolve(unit)
	local s = storage.fork_me_move
	local units = s and s.units
	if not units then return unit end
	local hops = 0
	while units[unit] and hops < 64 do
		unit = units[unit]
		hops = hops + 1
	end
	return unit
end

--- every member on the surface `index`, in the order of their unit numbers
local function members_on(index)
	local s = storage.fork_me_net
	local out = {}
	for unit, node in pairs(s and s.nodes or {}) do
		local e = node.entity
		if e and e.valid and e.surface.index == index then out[#out + 1] = unit end
	end
	for unit, e in pairs(s and s.decon or {}) do            -- (marked for deconstruction: out of the graph, still there)
		if e.valid and e.surface.index == index then out[#out + 1] = unit end
	end
	table.sort(out)
	return out
end
M.members_on = members_on

--- on_pre_surface_deleted, on_pre_surface_cleared: the members on the surface leave as destroyed blocks
function M.on_surface_gone(event)
	local s = storage.fork_me_net
	if not (s and M.destroyed) then return end
	for _, unit in ipairs(members_on(event.surface_index)) do
		local node = s.nodes[unit]
		local e = node and node.entity or (s.decon and s.decon[unit])
		if e and e.valid then M.destroyed{ entity = e } end
	end
end

--- Space Exploration asks every mod before it deletes the surface of a zone (its Zone.delete_surface calls the function
--- space_exploration_delete_surface of every remote interface that has one): a surface with blocks of an ME network is not
--- deleted, as it is not deleted with a chest or a power pole of the player on it. (A deletion that does not ask, a
--- spaceship's own surface when its console is gone, goes through on_surface_gone.)
remote.add_interface("me-network-space-exploration", {
	space_exploration_delete_surface = function(event)
		local n = event and event.surface_index and #members_on(event.surface_index) or 0
		if n == 0 then return { allow_delete = true } end
		return { allow_delete = false, message = { "fork-me-net.surface-has-network", n } }
	end,
	--- tests: the unit number a moved controller has now; the pairs remembered for this tick
	resolve = function(unit) return M.resolve(unit) end,
	--- tests: the members whose entity is gone; how many members, networks and drives the graph holds
	stale = function()
		local n = 0
		for _, node in pairs(storage.fork_me_net and storage.fork_me_net.nodes or {}) do
			if not (node.entity and node.entity.valid) then n = n + 1 end
		end
		return n
	end,
	counts = function()
		local s = storage.fork_me_net or {}
		local out = { nodes = 0, nets = 0, drives = 0 }
		for _ in pairs(s.nodes or {}) do out.nodes = out.nodes + 1 end
		for _ in pairs(s.nets or {}) do out.nets = out.nets + 1 end
		for _ in pairs(s.drives or {}) do out.drives = out.drives + 1 end
		return out
	end,
	pending = function()
		local s = storage.fork_me_move
		local n = 0
		for _ in pairs(s and s.tick == game.tick and s.pairs or {}) do n = n + 1 end
		return n
	end,
})

return M
