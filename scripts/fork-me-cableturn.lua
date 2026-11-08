--------------------------------------------------------------------------------
--- ME NETWORK: TURNED BLUEPRINTS OVER ME BLOCKS WHOSE DIRECTION DOES NOT SHOW (issues #673, #674)
---   * ME Cable, the ME Drive and the other blocks of AGNOSTIC_KINDS / AGNOSTIC_NAMES are entities that always have a
---     direction, but nothing uses it: one picture for every direction, no script reads it, no side of them differs. The game
---     refuses a paste (red, nothing built) that lands such a block on a standing block or ghost of the same name with another
---     direction, as it does for belts and inserters, and it decides that before any event (on_pre_build comes only for a paste
---     that builds). A blueprint's blocks land with the direction of the blueprint as it is held: turned by R / Shift + R,
---     mirrored by the flip keys (H: east and west change places, V: north and south).
---   * So while a player holds a blueprint (or book) with such blocks, those around them are turned to the direction they
---     will land with: when it comes into the cursor, on every rotate or flip key, and again after the player moved
---     MOVE tiles. The game does not tell how a held blueprint is turned, so it is counted here from the keys (linked
---     custom inputs, prototypes/network.lua), per blueprint item: the game keeps the turn of a blueprint item (and of a
---     book) when it is put away and taken again, and starts a new item (a copy, Ctrl + V) unturned. A library blueprint
---     (cursor_record, no item number) is counted from unturned each time it is taken.
---   * New blueprints and copies get these blocks stored as north (on_player_setup_blueprint), so a blueprint of blocks
---     that were turned here lands as the count says.
---   * The direction is written on the entity: no event, the same unit number, so contents, settings and the graph stay
---     as they are and no network is rebuilt. A block marked for deconstruction is left alone: it carries no network, a paste
---     never conflicts with it (the ghost goes on top of it, measured), and it must not come back through a paste that
---     matches it. Ghosts are turned too: a paste over a ghost of another direction is refused as well.
---   * Blocks that use their direction stay out, and a turned paste over them stays refused, a real conflict as for an
---     inserter: the buses, the P2P tunnels, the underground cable (their front or open side), and the blocks made from a
---     constant combinator (ME Level Emitter, ME Circuit Interface: their wire connection points and light follow it).
---     The Pattern Provider is left out as well (the maintainer's call, issue #674). The runtime test (turnblocks.lua) fails
---     for a block the game refuses that is in neither list.
---   * Measured with a real client (2.1.24, the cable): R, V + R, R + V, Shift + R, R + H + R, R then Q and taken again, a
---     book, the clipboard: each paste over cable built. Cost: two searches within RADIUS per key, nothing per tick.
--- State: storage.fork_me_cableturn (lazy): `mem` the counted direction by blueprint item number (only when not north),
--- `p` per player holding a blueprint with such blocks { k = item number or nil, d = direction, s, x, y = where the cables were turned }.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local P = require("scripts.fork-me-pasteover")

local M = {}

local RADIUS = 128                     -- tiles around the player whose blocks are turned
local MOVE = 32                        -- tiles a player moves before the blocks around them are turned again

--- The blocks whose direction nothing uses, by kind (scripts/fork-me-network.lua) and, where a kind holds blocks that do use
--- it or the block is no member, by name. Each has one picture for every direction and no script reads its direction; the
--- two sizes that are not 1x1 (controller, quantum bridge) are square, so a turn moves nothing.
local AGNOSTIC_KINDS = {
	cable = true, drive = true, crafting = true, ["io-port"] = true, charger = true, ["access-point"] = true,
	["pattern-terminal"] = true, ["interface-terminal"] = true, ["storage-monitor"] = true, ["conversion-monitor"] = true,
	["throughput-monitor"] = true, ["creative-energy"] = true, ["logistic-interface"] = true, controller = true,
	["quantum-bridge"] = true, ["wireless-link"] = true,
}
local AGNOSTIC_NAMES = { ["me-logistic-storage-bus"] = true, ["me-cell-workbench"] = true }

--- what each key does to the direction (defines.direction, 16 steps) a north block of the blueprint lands with
local OPS = {
	["fork-me-cable-rotate"] = function(d) return (d + 4) % 16 end,
	["fork-me-cable-reverse-rotate"] = function(d) return (d + 12) % 16 end,
	["fork-me-cable-flip-horizontal"] = function(d) return (16 - d) % 16 end,
	["fork-me-cable-flip-vertical"] = function(d) return (24 - d) % 16 end,
}
M.OPS = OPS

local function state()
	local st = storage.fork_me_cableturn
	if not st then
		st = { mem = {}, p = {} }
		storage.fork_me_cableturn = st
	end
	return st
end

local names_cache, names_set, items_cache
--- the names of the blocks whose direction nothing uses (a list and a set), and the items that place them
local function agnostic()
	if not names_cache then
		names_cache, names_set, items_cache = {}, {}, {}
		local function add(n)
			if names_set[n] or not prototypes.entity[n] then return end
			names_cache[#names_cache + 1] = n
			names_set[n] = true
			for _, it in pairs(prototypes.entity[n].items_to_place_this or {}) do items_cache[it.name or it] = true end
		end
		for _, n in ipairs(N.node_names()) do
			if AGNOSTIC_KINDS[N.kind_of(n)] or AGNOSTIC_NAMES[n] then add(n) end
		end
		for n in pairs(AGNOSTIC_NAMES) do add(n) end
		table.sort(names_cache)
	end
	return names_cache, names_set, items_cache
end

--- does the blueprint `bp` (from P.resolve) hold a block of agnostic()?
local function holds(bp)
	local _, _, items = agnostic()
	for _, c in pairs(bp.cost_to_build or {}) do
		if items[c.name] then return true end
	end
	return false
end

--- the blueprint in the player's cursor when it holds a block of agnostic(): its key (the item number of the blueprint or
--- book; nil for a library blueprint) and true; nil when the cursor holds no such blueprint
local function held(player)
	local rec = player.cursor_record
	local src, k
	if rec and rec.valid then
		src = rec
	else
		local st = player.cursor_stack
		if not (st and st.valid_for_read and (st.is_blueprint or st.is_blueprint_book)) then return nil end
		src, k = st, st.item_number
	end
	local bp = P.resolve(src, player)
	if not bp then return nil end
	if holds(bp) then return k, true end
	return nil
end

--- `list` (entities or ghosts) takes direction `d`; a block marked for deconstruction is left alone (see above). Returns the
--- number turned, added to `n`.
local function turn(list, d, n)
	for _, e in pairs(list) do
		if e.direction ~= d and not e.to_be_deconstructed() then
			e.direction = d
			n = n + 1
		end
	end
	return n
end

--- the blocks and ghosts of agnostic() within RADIUS of `position` on `surface` take direction `d`
function M.align(surface, position, d)
	local names = agnostic()
	local n = turn(surface.find_entities_filtered{ position = position, radius = RADIUS, name = names }, d, 0)
	return turn(surface.find_entities_filtered{ position = position, radius = RADIUS, ghost_name = names }, d, n)
end

local function align_for(player, pl)
	local pos = player.position
	pl.s, pl.x, pl.y = player.surface.index, pos.x, pos.y
	M.align(player.surface, pos, pl.d)
end

function M.on_cursor_changed(event)
	local player = game.get_player(event.player_index)
	if not (player and player.valid) then return end
	local st = state()
	local k, has = held(player)
	if not has then
		st.p[event.player_index] = nil
		return
	end
	local pl = { k = k, d = k and st.mem[k] or 0 }
	st.p[event.player_index] = pl
	align_for(player, pl)
end

function M.on_key(event)
	local st = storage.fork_me_cableturn
	local pl = st and st.p[event.player_index]
	if not pl then return end
	local player = game.get_player(event.player_index)
	if not (player and player.valid) then return end
	pl.d = OPS[event.input_name](pl.d)
	if pl.k then st.mem[pl.k] = pl.d ~= 0 and pl.d or nil end
	align_for(player, pl)
end

function M.on_moved(event)
	local st = storage.fork_me_cableturn
	local pl = st and st.p[event.player_index]
	if not pl then return end
	local player = game.get_player(event.player_index)
	if not (player and player.valid) then return end
	local pos = player.position
	if player.surface.index ~= pl.s or math.abs(pos.x - pl.x) > MOVE or math.abs(pos.y - pl.y) > MOVE then
		align_for(player, pl)
	end
end

--- on_player_setup_blueprint (after the other handlers): the blocks of agnostic() in a new blueprint or copy are stored as north
function M.normalise(bp)
	local ents = bp.get_blueprint_entities()
	if not ents then return false end
	local _, names = agnostic()
	local changed = false
	for _, be in pairs(ents) do
		if names[be.name] and (be.direction or 0) ~= 0 then
			be.direction = nil
			changed = true
		end
	end
	if changed then bp.set_blueprint_entities(ents) end
	return changed
end

function M.on_player_setup_blueprint(event)
	local player = game.get_player(event.player_index)
	local bp = event.record or event.stack
	local function usable(b)
		return b and b.valid and (b.object_name == "LuaRecord" or (b.valid_for_read and b.is_blueprint)) and b.is_blueprint_setup()
	end
	if not usable(bp) and player then bp = player.blueprint_to_setup end
	if not usable(bp) and player then bp = player.cursor_stack end
	if not usable(bp) then return end
	pcall(M.normalise, bp)                     -- (a blueprint another mod changed may be unreadable: never break blueprinting)
end

script.on_event(defines.events.on_player_cursor_stack_changed, M.on_cursor_changed)
script.on_event(defines.events.on_player_changed_position, M.on_moved)
for name in pairs(OPS) do script.on_event(name, M.on_key) end

remote.add_interface("gregtorio-me-cableturn", {
	--- tests: what the keys do (the blocks around `position` take the direction after the key names of `keys`)
	align = function(surface, position, keys)
		local d = 0
		for _, k in ipairs(keys or {}) do d = OPS[k](d) end
		return M.align(surface, position, d), d
	end,
	--- tests: what on_player_setup_blueprint does to a blueprint item
	normalise = function(bp) return M.normalise(bp) end,
	--- tests: does a blueprint with this content count as held?
	holds = function(bp) return holds(bp) end,
	--- tests: the names of the blocks whose direction nothing uses
	agnostic = function() return (agnostic()) end,
})

return M
