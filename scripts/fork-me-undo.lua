--------------------------------------------------------------------------------
--- ME NETWORK: UNDO KEEPS A BLOCK'S SETTINGS (issue #796)
---   * A block a player removes comes back with undo (Ctrl+Z) as a ghost. The game makes that ghost from what it knows of
---     the entity, and the settings of an ME block live in this mod's storage: the ghost had no tags, and the block built
---     from it was blank (an ME Interface without rows, sides and priority).
---   * The undo record of a removal ("removed-entity" in LuaUndoRedoStack) takes tags, and the game puts them on the ghost
---     it makes and into the ghost's build event (measured in a client, 2.1.24). So the tags a blueprint of the block would
---     carry (the blueprint hooks of the modules, asked for this one entity) are set on that record: undo then gives what
---     placing a blueprint of the block gives, cards and patterns included by the rules of a ghost (taken from the builder
---     or the network, never from nothing).
---   * The record does not exist yet in the event of the removal; it is there on the next tick, as the first item of the
---     player's undo stack (measured for on_player_mined_entity and for on_marked_for_deconstruction). So the tags are taken
---     in the event, while the block still has its settings, and written a tick later.
---   * Removed by hand: on_player_mined_entity. Removed by robots: the record is made when the player marks the block
---     (deconstruction planner, cut), so the tags are those of that moment; a setting changed between the mark and the
---     robot's visit is not in them. Robots, platforms and scripts that remove a block nobody marked make no undo record.
---   * Cables are left out (no settings, and they are the many of a big deconstruction); a block without settings makes
---     no entry.
--- State: storage.fork_me_undo (nil while nothing waits): a list of { p = player index, tick, name, x, y, s = surface index,
--- tags } of the removals whose record is tagged on the next tick.
--------------------------------------------------------------------------------

local M = {}

--- function(bp, mapping): the blueprint hooks of the modules (control.lua: fork_ae2.tag_blueprint)
M.tag = nil
--- function(name) -> the kind of an ME member, or nil (control.lua: fork_net.kind_of)
M.kind = nil

--- a copy of plain data (the hooks hand out tables of the modules' own records, which the removal empties)
local function copy(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, x in pairs(v) do out[k] = copy(x) end
	return out
end

--- The tags a blueprint of `entity` alone would carry (nil: none). The hooks only call set_blueprint_entity_tag, so a table
--- stands for the blueprint.
function M.tags_of(entity)
	if not (M.tag and entity and entity.valid) then return nil end
	local tags
	local bp = { valid = true, set_blueprint_entity_tag = function(_, name, value)
		tags = tags or {}
		tags[name] = copy(value)
	end }
	M.tag(bp, { entity })
	return tags
end

--- `entity` is removed by player `index` (mined, or marked for deconstruction): its settings wait for the undo record
function M.on_removed(entity, index)
	if not (index and entity and entity.valid) then return end
	local kind = M.kind and M.kind(entity.name)
	if not kind or kind == "cable" then return end
	local tags = M.tags_of(entity)
	if not tags then return end
	local q = storage.fork_me_undo
	if not q then
		q = {}
		storage.fork_me_undo = q
	end
	local p = entity.position
	q[#q + 1] = { p = index, tick = game.tick, name = entity.name, x = p.x, y = p.y, s = entity.surface.index, tags = tags }
end

local function key(surface, name, x, y)
	return surface .. "|" .. name .. "|" .. x .. "|" .. y
end

--- the removals `list` of `player`: each one's tags onto its action in the newest undo item
local function apply(player, list)
	local stack = player.undo_redo_stack
	if stack.get_undo_item_count() < 1 then return end
	local by = {}
	for i, action in pairs(stack.get_undo_item(1)) do
		local t = action.type == "removed-entity" and action.target
		if t and t.position and action.surface_index then
			by[key(action.surface_index, t.name, t.position.x, t.position.y)] = i
		end
	end
	for _, e in ipairs(list) do
		local i = by[key(e.s, e.name, e.x, e.y)]
		if i then
			for name, value in pairs(e.tags) do stack.set_undo_tag(1, i, name, value) end
		end
	end
end

--- on_tick: the removals of the ticks before (nothing while nothing waits)
function M.on_tick(tick)
	local q = storage.fork_me_undo
	if not q then return end
	local rest, per
	for _, e in ipairs(q) do
		if e.tick >= tick then
			rest = rest or {}
			rest[#rest + 1] = e
		else
			per = per or {}
			per[e.p] = per[e.p] or {}
			per[e.p][#per[e.p] + 1] = e
		end
	end
	storage.fork_me_undo = rest
	for index, list in pairs(per or {}) do
		local player = game.get_player(index)
		--- (the undo stack is the player's: a record this mod cannot read or write must not stop the game)
		if player and player.valid then pcall(apply, player, list) end
	end
end

remote.add_interface("gregtorio-me-undo", {
	--- tests: the tags undo gives `entity` back with (nil: none)
	tags_of = function(entity) return M.tags_of(entity) end,
	--- tests (the harness has no player and so no undo stack): `entity` as removed by player `index`
	removed = function(entity, index) M.on_removed(entity, index) end,
	--- tests: the removals that wait for their undo record
	queued = function() return storage.fork_me_undo or {} end,
})

return M
