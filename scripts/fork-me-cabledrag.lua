--------------------------------------------------------------------------------
--- ME NETWORK: DRAGGING ME CABLE UNDER AN OBSTACLE (like the game's belt dragging)
---   * A player who drags ME Cable (the fluix cable item) across an obstacle gets a pair of ME Underground Cables under
---     it, as the game does for belts: the last cable before the obstacle becomes the entrance (its cable side back to
---     the run, like an underground pipe), the first cable after it the exit (its cable side along the drag), and the run
---     goes on above ground behind the exit. The two
---     underground cables come from the player's main inventory, the two cables go back to it (what does not fit is
---     spilled at the player). Dragging ghosts (shift, or without cable in the inventory) makes ghosts of the pair.
---   * The game builds a dragged entity on every free tile under the cursor and nothing on a blocked one, so a drag over an
---     obstacle is two cables of one drag on one line with a gap between them. A gap is bridged when it is at most the
---     underground cable's reach, at least one of its tiles is blocked for a cable, and none of its tiles holds an ME
---     block (a cable crossed on the way joins the run anyway; an underground end there would take the pairing).
---   * Without two underground cables in the inventory (or for an obstacle wider than the reach) nothing changes, as with
---     belts.
---   * Dragging the ME Underground Cable itself is the game's own underground pipe drag (pairs at the full reach): the
---     underground cable is a pipe-to-ground with the vanilla underground pipe's connections (prototypes/network.lua).
--- What a drag is: on_pre_build says created_by_moving for the build that follows it in the same tick.
--- State: storage.fork_me_cabledrag (lazy): per player the last cable of the current drag (`players`: { last, ghost })
--- and the tick of a dragged pre-build (`moving`). (`ug` of 0.5.11 development builds is dropped.)
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")

local M = {}

local CABLE = "me-cable"
local CABLE_ITEM = "fluix-cable"
local UNDERGROUND = "me-underground-cable"

local VEC_DIR = {
	[1] = { [0] = defines.direction.east },
	[-1] = { [0] = defines.direction.west },
	[0] = { [1] = defines.direction.south, [-1] = defines.direction.north },
}
local OPPOSITE = {
	[defines.direction.north] = defines.direction.south, [defines.direction.south] = defines.direction.north,
	[defines.direction.east] = defines.direction.west, [defines.direction.west] = defines.direction.east,
}

local reach_cache
local function reach()
	if not reach_cache then
		local md = prototypes.mod_data["fork-me-network"]
		reach_cache = md and md.data.underground_reach or 10
	end
	return reach_cache
end

--- an ME block (a member of the graph) by name
local function is_me(name) return N.kind_of(name) ~= nil end

local function state()
	local s = storage.fork_me_cabledrag
	if not s then
		s = { players = {}, moving = {} }
		storage.fork_me_cabledrag = s
	end
	s.ug = nil
	return s
end

local function name_of(e)
	if e.type == "entity-ghost" then return e.ghost_name, true end
	return e.name, false
end

--- does a tile of the gap hold an ME block (or its ghost)?
local function holds_me(surface, pos, force)
	for _, e in pairs(surface.find_entities_filtered{ position = pos, force = force }) do
		local n = name_of(e)
		if is_me(n) then return true end
	end
	return false
end

--- the underground pair for the gap between `a` and `b` (two cables or two cable ghosts of one drag), or nil.
--- `inv`: where the underground cables come from and the cables go to (nil: only ghosts can be bridged).
function M.bridge(a, b, inv, spill_at)
	local an, ag = name_of(a)
	local bn, bg = name_of(b)
	if an ~= CABLE or bn ~= CABLE or ag ~= bg or a.surface ~= b.surface or a.force ~= b.force then return nil end
	local pa, pb = a.position, b.position
	local dx, dy = pb.x - pa.x, pb.y - pa.y
	if dx ~= 0 and dy ~= 0 then return nil end
	local dist = math.abs(dx + dy)
	if dist < 2 or dist > reach() then return nil end
	local vx, vy = dx / dist, dy / dist
	local dir = VEC_DIR[vx][vy]
	local surface, force = a.surface, a.force
	local blocked = false
	for i = 1, dist - 1 do
		local pos = { pa.x + vx * i, pa.y + vy * i }
		if holds_me(surface, pos, force) then return nil end
		if not blocked and not surface.can_place_entity{ name = CABLE, position = pos, force = force } then blocked = true end
	end
	if not blocked then return nil end
	local ghost = ag
	if not ghost then
		if not (inv and inv.valid and inv.get_item_count(UNDERGROUND) >= 2) then return nil end
	end
	local quality = a.quality and a.quality.name
	a.destroy{ raise_destroy = true }
	b.destroy{ raise_destroy = true }
	local function make(pos, d)
		local spec = { position = pos, direction = d, force = force, raise_built = true }
		if ghost then
			spec.name, spec.inner_name = "entity-ghost", UNDERGROUND
		else
			spec.name = UNDERGROUND
		end
		return surface.create_entity(spec)
	end
	--- an underground cable's cable side faces its direction (like an underground pipe): the entrance's back to the run
	local entry = make(pa, OPPOSITE[dir])
	local exit = make(pb, dir)
	if not ghost then
		inv.remove{ name = UNDERGROUND, count = (entry and 1 or 0) + (exit and 1 or 0) }
		local back = { name = CABLE_ITEM, count = 2, quality = quality }
		local n = inv.insert(back)
		if n < 2 then
			back.count = 2 - n
			surface.spill_item_stack{ position = spill_at or pb, stack = back, force = force, allow_belts = false }
		end
	end
	return exit, entry
end

--- on_pre_build: remember whether the build of this tick is part of a drag
function M.on_pre_build(event)
	if not event.player_index then return end
	state().moving[event.player_index] = event.created_by_moving and game.tick or nil
end

--- on_built_entity of a player (after every module registered the entity: it may be replaced here)
function M.on_built(entity, event)
	if not (event and event.name == defines.events.on_built_entity and event.player_index) then return end
	if not (entity and entity.valid) then return end
	local s = state()
	local pi = event.player_index
	local n, ghost = name_of(entity)
	if n ~= CABLE then
		s.players[pi] = nil
		return
	end
	local moving = s.moving[pi] == game.tick
	local rec = s.players[pi]
	if moving and rec and rec.last and rec.last.valid and rec.ghost == ghost then
		local player = game.get_player(pi)
		local inv = player and player.get_main_inventory()
		local exit = M.bridge(rec.last, entity, inv, player and player.character and player.position)
		if exit then
			--- the run goes on behind the exit; the exit cannot be the next entrance
			s.players[pi] = nil
			return
		end
	end
	s.players[pi] = { last = entity, ghost = ghost }
end

N.drag_bridge = M.bridge                 -- (the runtime test calls it through the remote interface)

return M
