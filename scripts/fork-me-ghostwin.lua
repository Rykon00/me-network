--------------------------------------------------------------------------------
--- THE ME WINDOW OF A GHOST (me-network issue #659)
---   * A ghost of an ME block whose settings travel in blueprints opens the block's ME window, as the game opens the window of
---     an assembler's or an inserter's ghost, and what is set there is what the block gets when it is built: the ghost's tags.
---   * The windows are the blocks' own (scripts/fork-me-windows.lua and the modules), so nothing is written twice: opening a
---     ghost builds a stand-in, an entity of the ghost's name, direction and quality, on a hidden surface of its own
---     (SURFACE, lab tiles, hidden for every force), gives it the ghost's tags through the build path of control.lua (as a
---     robot builds the ghost, without a player: nothing comes from an inventory) and opens the stand-in's window. The
---     stand-in's settings go back into the ghost's tags through the blueprint hooks (the code that tags a blueprint: M.sync)
---     after every GUI event of the player, at every refresh and when the window closes; the ghost's tags of other mods stay.
---   * A stand-in stands alone (no cable, no power, no controller), and the blocks that find each other by a frequency skip
---     it (scripts/fork-me-standin.lua), so it never joins or splits a network of the world.
---   * When the window closes (or shows another block) the stand-in goes through the mining path (M.remove): what the
---     player put into it (a pattern, a card, a cell) comes back to the player, and the ghost wants it as a blueprint does.
---   * The window works while the ghost exists, from anywhere the game lets the player open the ghost (remote view too); it
---     closes when the ghost is built or removed. The game's own settings of a ghost (its wires, a lamp's condition) stay the
---     game's; the circuit and logistic panel shows its sections for the ghost's wires and the logistic network at the ghost.
--- State: storage.fork_me_ghostwin = { sessions = { [key] = { ghost, standin, unit } }, units = { [unit] = key }, next }; the
--- key is the player's index (the runtime test's sessions have keys of their own).
--------------------------------------------------------------------------------

local G = require("scripts.fork-me-gui")

local M = {}

M.SURFACE = "me-network-ghost-staging"
local SPACING = 16                    -- tiles between two stand-ins (the largest ME block is 3x3)
local SLOTS = 256                     -- places on the surface, used in turn

--- the windows a ghost opens: the blocks whose settings travel in blueprints (not the terminals, the controller, the
--- crafting CPU, the workbench: they have none)
local WINDOWS = {
	["drive"] = true, ["interface"] = true, ["bus"] = true, ["storage-bus"] = true, ["provider"] = true, ["maintainer"] = true,
	["circuit"] = true, ["monitor"] = true, ["level-emitter"] = true, ["advanced-level-emitter"] = true, ["io-port"] = true,
	["logistic-interface"] = true, ["quantum-bridge"] = true, ["p2p-tunnel"] = true, ["access-point"] = true,
}

--- set by control.lua: build(entity, tags) runs the build handlers, remove(entity, buffer) the mining handlers, tag(bp,
--- mapping) the blueprint hooks
M.build, M.remove, M.tag = nil, nil, nil

local function state()
	local s = storage.fork_me_ghostwin
	if not s then
		s = { sessions = {}, units = {}, next = 0 }
		storage.fork_me_ghostwin = s
	end
	return s
end

--- a tag that the blueprint hooks write (the others belong to other mods and stay on the ghost)
local function own_key(k)
	return type(k) == "string" and (k:sub(1, 8) == "fork_me_" or k:sub(1, 8) == "fork_ae2")
end

--- the window a ghost of `name` opens (nil: the game's ghost window)
function M.window_of_ghost(name)
	if not (name and prototypes.entity[name]) then return nil end
	local wname = G.window_for(name)
	return wname and WINDOWS[wname] and wname or nil
end

local function staging()
	local surface = game.surfaces[M.SURFACE]
	if not surface then
		surface = game.create_surface(M.SURFACE, { width = SLOTS * SPACING + 64, height = 64, peaceful_mode = true,
			no_enemies_mode = true, starting_area = "none" })
		surface.generate_with_lab_tiles = true
		surface.always_day = true
	end
	for _, force in pairs(game.forces) do
		if not force.get_surface_hidden(surface) then force.set_surface_hidden(surface, true) end
	end
	return surface
end

--- the session of `key`, nil when it has none
function M.session(key) return state().sessions[key] end

--- the ghost whose stand-in `entity` is (nil: it is none)
function M.ghost_of(entity)
	local s = storage.fork_me_ghostwin
	if not (s and entity and entity.valid and entity.unit_number) then return nil end
	local key = s.units[entity.unit_number]
	local ses = key ~= nil and s.sessions[key]
	return ses and ses.ghost.valid and ses.ghost or nil
end

--- Write the stand-in's settings into the ghost's tags. Returns false when the session is gone (ghost or stand-in invalid).
function M.sync(key)
	local ses = state().sessions[key]
	if not (ses and ses.ghost.valid and ses.standin.valid) then return false end
	local own = {}
	local bp = { valid = true, set_blueprint_entity_tag = function(_, k, v) own[k] = v end }
	M.tag(bp, { [1] = ses.standin })
	local tags = {}
	for k, v in pairs(ses.ghost.tags or {}) do
		if not own_key(k) then tags[k] = v end
	end
	for k, v in pairs(own) do tags[k] = v end
	ses.ghost.tags = tags
	pcall(function() ses.ghost.copy_settings(ses.standin) end)   -- (the game's own settings back)
	return true
end

--- End the session of `key`: the settings into the ghost (while it exists), the stand-in mined; what it held goes to the
--- player of the session (inventory, else the ground at the player), or into `into` (the runtime test). Returns the number of
--- items given back.
function M.unstage(key, into)
	local s = state()
	local ses = s.sessions[key]
	if not ses then return 0 end
	M.sync(key)
	s.sessions[key] = nil
	local given = 0
	local e = ses.standin
	if e and e.valid then
		local buffer = game.create_inventory(200)
		M.remove(e, buffer)
		--- (what the game's own window of the block put into it, e.g. the ME Interface's "Open inventory": the mining
		--- handlers take only the mod's parts, the game would empty the entity itself)
		if e.valid then
			for i = 1, e.get_max_inventory_index() do
				local inv = e.get_inventory(i)
				if inv and inv.valid then
					for j = 1, #inv do
						if inv[j].valid_for_read then buffer.insert(inv[j]) inv[j].clear() end
					end
				end
			end
			e.destroy()
		end
		local player = type(key) == "number" and game.get_player(key) or nil
		for i = 1, #buffer do
			local stack = buffer[i]
			if stack.valid_for_read then
				given = given + stack.count
				local got = into and into.insert(stack) or player and player.valid and player.insert(stack) or 0
				if got < stack.count and player and player.valid and player.character then
					stack.count = stack.count - got
					player.character.surface.spill_item_stack{ position = player.character.position, stack = stack,
						allow_belts = false }
				end
			end
		end
		buffer.destroy()
	end
	s.units[ses.unit] = nil
	return given
end

--- Build the stand-in of `ghost` for session `key` (an older session of the key ends first). Returns the stand-in or nil.
function M.stage(ghost, key)
	if not (ghost and ghost.valid and ghost.type == "entity-ghost" and M.window_of_ghost(ghost.ghost_name)) then return nil end
	M.unstage(key)
	local s = state()
	local surface = staging()
	local slot = s.next % SLOTS
	s.next = s.next + 1
	local proto = prototypes.entity[ghost.ghost_name]
	local x = slot * SPACING + 8
	local pos = { x = x + (proto.tile_width or 1) / 2, y = 8 + (proto.tile_height or 1) / 2 }
	surface.request_to_generate_chunks(pos, 0)
	surface.force_generate_chunk_requests()
	--- (a stand-in left behind by a session that ended without its window, or what the generator placed)
	for _, old in pairs(surface.find_entities_filtered{ area = { { x - 4, 0 }, { x + 12, 16 } } }) do
		if old.valid and old.type ~= "character" then
			if s.units[old.unit_number or -1] == nil then old.destroy() end
		end
	end
	local e = surface.create_entity{ name = ghost.ghost_name, position = pos, force = ghost.force, direction = ghost.direction,
		quality = ghost.quality, create_build_effect_smoke = false }
	if not (e and e.valid and e.unit_number) then
		if e and e.valid then e.destroy() end
		return nil
	end
	s.units[e.unit_number] = key                 -- (before the build: the frequency blocks skip it from the start)
	s.sessions[key] = { ghost = ghost, standin = e, unit = e.unit_number }
	pcall(function() e.copy_settings(ghost) end)  -- (the game's own settings: a lamp's conditions, as the maintainer's panel shows)
	M.build(e, ghost.tags or {})
	if not e.valid then                          -- (a handler replaced it: never for a block with a window)
		s.sessions[key], s.units[e.unit_number] = nil, nil
		return nil
	end
	return e
end

--- the title bar's note that the window is a ghost's
local function mark(player)
	local frame = G.window_of(player)
	local title = frame and G.find(frame, "fork_me_title")
	local bar = title and title.parent
	if bar and not bar.fork_me_ghost_note then
		local note = bar.add{ type = "label", name = "fork_me_ghost_note", caption = { "fork-me-gui.ghost-note" },
			tooltip = { "fork-me-gui.ghost-note-tooltip" }, ignored_by_interaction = false }
		note.style.font_color = { 0.55, 0.75, 1 }
		bar.swap_children(title.get_index_in_parent() + 1, note.get_index_in_parent())
	end
end

--- the player's ghost window: the stand-in's window opens (the same ghost again: the window that is open stays)
function M.open(player, ghost)
	if not M.window_of_ghost(ghost.ghost_name) then return false end
	local key = player.index
	local ses = state().sessions[key]
	local frame = G.window_of(player)
	if ses and ses.ghost == ghost and ses.standin.valid and frame and frame.tags.unit == ses.unit then
		player.opened = frame
		return true
	end
	local e = M.stage(ghost, key)
	if not e then return false end
	local _, def = G.window_for(e.name)
	def.open(player, e)
	mark(player)
	return true
end

--- The player's session ends when their window is not the stand-in's any more (closed, or another block's); else the
--- settings go into the ghost. Called after the GUI events, at the refresh and when a player leaves.
function M.settle(player)
	local key = player.index
	local ses = storage.fork_me_ghostwin and storage.fork_me_ghostwin.sessions[key]
	if not ses then return end
	local frame = G.window_of(player)
	if frame and frame.tags.unit == ses.unit and ses.ghost.valid and ses.standin.valid then
		M.sync(key)
		mark(player)                           -- (a window built again has no note)
	else
		M.unstage(key)
	end
end

--- on_configuration_changed (after the terminal closed every window): every session ends, and what else stands on the
--- hidden surface goes (a stand-in's hidden parts went with it)
function M.on_configuration_changed()
	local s = storage.fork_me_ghostwin
	if s then
		for key in pairs(s.sessions) do M.unstage(key) end
		s.units = {}
	end
	local surface = game.surfaces[M.SURFACE]
	if surface then
		for _, e in pairs(surface.find_entities_filtered{}) do
			if e.valid and e.type ~= "character" then e.destroy() end
		end
	end
end

--- the window of a stand-in is usable while its ghost exists (wherever the player could open the ghost)
G.remote_reach[#G.remote_reach + 1] = function(player, anchor)
	return M.ghost_of(anchor) ~= nil
end
--- the refresh of a stand-in's window: closed when the ghost is gone (built or removed), else the settings into the ghost
G.refresh_hooks[#G.refresh_hooks + 1] = function(player, frame)
	local ses = storage.fork_me_ghostwin and storage.fork_me_ghostwin.sessions[player.index]
	if not (ses and frame.tags.unit == ses.unit) then return true end
	if not (ses.ghost.valid and ses.standin.valid) then return false end
	M.sync(player.index)
	return true
end
--- every 60 ticks for every player: a session whose window is gone ends
G.player_hooks[#G.player_hooks + 1] = function(player) M.settle(player) end
G.ghost_open = function(player, ghost) return M.open(player, ghost) end
G.ghost_of = function(entity) return M.ghost_of(entity) end

--- the runtime test (tools/devcheck/runtimemod) has no player: it stages, syncs and unstages sessions of its own keys
remote.add_interface("gregtorio-me-ghostwin", {
	window_of_ghost = function(name) return M.window_of_ghost(name) end,
	stage = function(ghost, key) return M.stage(ghost, key) end,
	sync = function(key) return M.sync(key) end,
	unstage = function(key, into) return M.unstage(key, into) end,
	ghost_of = function(entity) return M.ghost_of(entity) end,
	is_standin = function(entity) return M.ghost_of(entity) ~= nil end,
	--- how many entities stand on the hidden surface and how many sessions are kept
	counts = function()
		local surface = game.surfaces[M.SURFACE]
		local n = 0
		if surface then
			for _, e in pairs(surface.find_entities_filtered{}) do if e.type ~= "character" then n = n + 1 end end
		end
		local s = storage.fork_me_ghostwin
		return { entities = n, sessions = s and table_size(s.sessions) or 0, units = s and table_size(s.units) or 0 }
	end,
})

return M
