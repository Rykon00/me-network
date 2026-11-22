--------------------------------------------------------------------------------
--- ME NETWORK: SETTINGS THAT TURN WITH A BLUEPRINT (issue #790)
---   * A blueprint placed turned (R, Shift+R) or flipped (H, V) moves every entity, and turns the ones that have a direction.
---     A block without one (the ME Interface is a container) is only moved, and the game never looks into entity tags: a
---     setting per side that lives in a tag (the interface's fluid sides, `fork_me_interface.sides`) stayed as it was in the
---     blueprint's own frame, so every side kept the setting of the side it was before the turn.
---   * Nothing tells a build event how the blueprint was placed. on_pre_build does (direction, flip_horizontal,
---     flip_vertical), and the build events of that placement follow it in the same tick: the turn is remembered there per
---     player and tick, only while the cursor holds a blueprint (an item placed by hand onto a ghost raises on_pre_build too,
---     and must not turn the ghost's tags a second time), and M.on_built gives the tags of a block or ghost built by that
---     player in that tick to the block's turner (`M.turners`, per entity name, set by control.lua). A ghost's tags are
---     written back, so robots (on_robot_built_entity brings the ghost's tags) and a hand build onto the ghost build the
---     turned settings; an instant build (editor, cheat mode) gets the turned tags directly.
---   * A paste over a block that stands there makes no build event: scripts/fork-me-pasteover.lua turns the tags through
---     the same turners (control.lua hands it this module's table).
---   * Not turned: a blueprint a script builds (LuaItemStack.build_blueprint raises no on_pre_build: the turn is unknown),
---     clones, and the tags a ghost's ME window writes (they are the world's sides already).
--- State: storage.fork_me_bpturn (lazy): per player index { tick, d, fh, fv } of the blueprint placed in that tick.
--------------------------------------------------------------------------------

local M = {}

--- function(tags, direction, flip_horizontal, flip_vertical) -> tags, per entity name: the tags of a blueprint entity as a
--- blueprint placed that way gives them (a copy, or the tags themselves when nothing turns); control.lua fills it
M.turners = {}
--- tests: function(entity, tags, index): the build handlers as on_built_entity of player `index` calls them (control.lua)
M.build = nil

local function state()
	local s = storage.fork_me_bpturn
	if not s then
		s = {}
		storage.fork_me_bpturn = s
	end
	return s
end

--- remember the placement of player `index` for the build events of this tick (nil direction and flips: nothing turned,
--- nothing kept)
local function note(index, direction, fh, fv)
	local d = math.floor(((tonumber(direction) or 0) % 16) / 4) * 4
	if d == 0 and not fh and not fv then
		if storage.fork_me_bpturn then storage.fork_me_bpturn[index] = nil end
		return
	end
	state()[index] = { tick = game.tick, d = d, fh = fh and true or nil, fv = fv and true or nil }
end

--- on_pre_build: the turn of a placed blueprint; anything else in the cursor forgets it
function M.on_pre_build(event)
	local index = event.player_index
	if not index then return end
	local player = game.get_player(index)
	if player and player.valid and player.is_cursor_blueprint() then
		note(index, event.direction, event.flip_horizontal, event.flip_vertical)
	elseif storage.fork_me_bpturn then
		storage.fork_me_bpturn[index] = nil
	end
end

--- The tags `entity` is to be set up with: turned when a player built it (or its ghost) with a turned blueprint in this
--- tick, else `tags` as they are. A ghost's tags are read from it and written back.
function M.on_built(entity, tags, event)
	local s = storage.fork_me_bpturn
	if not (s and event and event.name == defines.events.on_built_entity and event.player_index) then return tags end
	local e = s[event.player_index]
	if not e then return tags end
	if e.tick ~= game.tick then
		s[event.player_index] = nil
		return tags
	end
	if not (entity and entity.valid) then return tags end
	local ghost = entity.type == "entity-ghost"
	local turner = M.turners[ghost and entity.ghost_name or entity.name]
	if not turner then return tags end
	if ghost then tags = entity.tags end
	if type(tags) ~= "table" then return tags end
	local turned = turner(tags, e.d, e.fh, e.fv)
	if ghost and turned ~= tags then entity.tags = turned end
	return turned
end

remote.add_interface("gregtorio-me-bpturn", {
	--- tests (the harness has no player, and LuaItemStack.build_blueprint raises no on_pre_build): the placement of player
	--- `index` as on_pre_build remembers it for a blueprint in the cursor
	note = function(index, direction, fh, fv) note(index, direction, fh, fv) end,
	--- tests: on_pre_build with the event's fields (without a player of that index: nothing in the cursor, which forgets)
	pre_build = function(event) M.on_pre_build(event) end,
	--- tests: `entity` (a block or a ghost, built without an event) goes through the build handlers as built by player
	--- `index`; returns nothing (read the ghost's tags or the block's settings)
	built = function(entity, tags, index) M.build(entity, tags, index) end,
	--- tests: what is remembered for player `index` (nil: nothing)
	noted = function(index) return storage.fork_me_bpturn and storage.fork_me_bpturn[index] or nil end,
})

return M
