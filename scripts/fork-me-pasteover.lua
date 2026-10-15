--------------------------------------------------------------------------------
--- ME NETWORK: A BLUEPRINT PASTED OVER ME BLOCKS (issue #383)
---   * A blueprint (also the copy of the copy-paste tool, Ctrl+C / Ctrl+V) carries the settings of the ME blocks as
---     entity tags (the handler of on_player_setup_blueprint, scripts/fork-me-autocraft.lua). Built on free ground they
---     come with the ghost and its build event. Pasted over a block of the same kind that stands there already, the game
---     makes no ghost and raises no event (Factorio 2.0; 2.1 has on_blueprint_settings_pasted): the block stayed as it was.
---     So the player's paste is looked at before it happens (on_pre_build: the blueprint in the cursor, where and how it is
---     placed): each blueprint entity with tags of this mod is put where the game puts it, and a block of its name that
---     stands there takes the settings of the tags, as a block built from the ghost would (`M.appliers`, set by
---     control.lua: the modules' build handlers with the tags).
---   * Where a blueprint entity lands: M.layout, as the game places a blueprint; the runtime test (copypaste.lua) checks it
---     against the ghosts of LuaItemStack.build_blueprint in four directions (that call takes no flip: the flips follow
---     the same rule untested). Blueprints with rails or absolute snapping place by other rules and are left alone.
---   * Only tags of this mod count: a blueprint entity without them changes nothing (a blank block pasted over a
---     configured one keeps it configured). The active blueprint of a book in the cursor counts too.
--- No state.
--------------------------------------------------------------------------------

local M = {}

--- the tags of the mod's modules (a blueprint entity of an ME block has at most one of them, with the cards of a block)
M.TAGS = { "fork_me_interface", "fork_me_bus", "fork_me_storage_bus", "fork_me_provider", "fork_me_maintainer",
	"fork_me_circuit", "fork_me_drive", "fork_me_monitor", "fork_me_emitter", "fork_me_access_point",
	"fork_me_fluid_storage_bus", "fork_me_io_port", "fork_me_qbridge",
	"fork_me_wireless_link" }

--- function(entity, tags) per entity name: the settings of `tags` onto an existing block (control.lua fills it)
M.appliers = {}
M.apply = nil                            -- function(entity, tags): the default applier (control.lua)

local function has_tag(tags)
	if type(tags) ~= "table" then return false end
	for _, name in ipairs(M.TAGS) do if tags[name] ~= nil then return true end end
	return false
end

--- the size of an entity prototype in tiles (width, height)
local size_cache = {}
local function size_of(name)
	local v = size_cache[name]
	if not v then
		local p = prototypes.entity[name]
		v = { p and p.tile_width or 1, p and p.tile_height or 1 }
		size_cache[name] = v
	end
	return v[1], v[2]
end

--- a coordinate on the grid of a side of `n` tiles: odd sizes on a tile centre, even ones on a tile corner (half up)
local function snap(v, n)
	if n % 2 == 1 then return math.floor(v) + 0.5 end
	return math.floor(v + 0.5)
end

--- the tiles a blueprint entity covers (width, height), turned with its direction
local function footprint(be)
	local w, h = size_of(be.name)
	if math.floor(((be.direction or 0) % 16) / 4) % 2 == 1 then w, h = h, w end
	return w, h
end

--- Where the entities of a blueprint land when it is placed at `at` with `direction` (defines.direction, north: as it is)
--- and the flips (`fh`, `fv`), as the game builds it (measured against LuaItemStack.build_blueprint, issue #383): the
--- middle of what its entities and tiles cover goes to `at`, put on the grid of that area's size (an odd width on a tile
--- centre, an even one on a tile corner, turned with the blueprint), and every entity keeps its place relative to it,
--- flipped (in the blueprint's own frame) and turned. Returns function(be) -> position.
function M.layout(entities, tiles, at, direction, fh, fv)
	local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
	for _, be in pairs(entities) do
		local w, h = footprint(be)
		local p = be.position
		if p.x - w / 2 < x1 then x1 = p.x - w / 2 end
		if p.y - h / 2 < y1 then y1 = p.y - h / 2 end
		if p.x + w / 2 > x2 then x2 = p.x + w / 2 end
		if p.y + h / 2 > y2 then y2 = p.y + h / 2 end
	end
	for _, t in pairs(tiles or {}) do
		local p = t.position
		if p.x < x1 then x1 = p.x end
		if p.y < y1 then y1 = p.y end
		if p.x + 1 > x2 then x2 = p.x + 1 end
		if p.y + 1 > y2 then y2 = p.y + 1 end
	end
	local cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
	local W, H = math.floor(x2 - x1 + 0.5), math.floor(y2 - y1 + 0.5)
	local turns = math.floor(((direction or 0) % 16) / 4)   -- (2.0 directions: 16 steps, a quarter turn is 4)
	if turns % 2 == 1 then W, H = H, W end
	local gx, gy = snap(at.x, W), snap(at.y, H)
	return function(be)
		local x, y = be.position.x - cx, be.position.y - cy
		if fh then x = -x end
		if fv then y = -y end
		for _ = 1, turns do x, y = -y, x end
		return { x = gx + x, y = gy + y }
	end
end

--- The blueprint `bp` (a blueprint item, a book item's active blueprint, or a blueprint record, also a book's), unless its
--- placement follows other rules than M.layout's (rails, which keep a grid of two tiles; absolute snapping): its entities,
--- its tiles and those of its entities with tags of this mod (nil when there are none). `player`: whose cursor holds it.
local function readable(bp, player)
	if not (bp and bp.valid) then return nil end
	if bp.object_name == "LuaItemStack" then
		if not bp.valid_for_read then return nil end
		if bp.is_blueprint_book then
			local inv = bp.get_inventory(defines.inventory.item_main)
			local inner = inv and bp.active_index and inv[bp.active_index]
			if inner then return readable(inner, player) end
			return nil
		end
		if not (bp.is_blueprint and bp.is_blueprint_setup()) then return nil end
	elseif bp.object_name == "LuaRecord" then
		if bp.type == "blueprint-book" then
			local i = player and bp.get_active_index(player)
			local inner = i and bp.contents and bp.contents[i]
			if inner then return readable(inner, player) end
			return nil
		end
		if bp.type ~= "blueprint" or not bp.is_blueprint_setup() then return nil end
	else
		return nil
	end
	if bp.blueprint_snap_to_grid then return nil end
	local entities = bp.get_blueprint_entities() or {}
	local tagged
	for _, be in pairs(entities) do
		local p = prototypes.entity[be.name]
		if not p or p.type:find("rail", 1, true) then return nil end
		if has_tag(be.tags) then
			tagged = tagged or {}
			tagged[#tagged + 1] = be
		end
	end
	if not tagged then return nil end
	return entities, bp.get_blueprint_tiles() or {}, tagged
end

--- Paste `bp` at `at` (direction, flips) on `surface` for `force` (`player`: whose cursor, for a book record): every block of
--- a tagged blueprint entity's name standing where it lands takes its settings. Returns the number of blocks that did.
function M.paste(bp, surface, force, at, direction, fh, fv, player)
	local entities, tiles, tagged = readable(bp, player)
	if not tagged then return 0 end
	local place = M.layout(entities, tiles, at, direction, fh, fv)
	local turn = math.floor(((direction or 0) % 16) / 4) * 4
	local n = 0
	for _, be in ipairs(tagged) do
		local found = surface.find_entities_filtered{ name = be.name, position = place(be), force = force, limit = 1 }[1]
		--- (a block that faces another way than the pasted one would is not the one meant: left alone, unless flipped)
		local facing = fh or fv or not be.direction or found and found.direction == (be.direction + turn) % 16
		if found and found.valid and facing then
			local f = M.appliers[be.name] or M.apply
			if f then
				f(found, be.tags)
				n = n + 1
			end
		end
	end
	return n
end

--- on_pre_build: a player places the blueprint (or copy) in the cursor
function M.on_pre_build(event)
	local player = game.get_player(event.player_index)
	if not (player and player.valid and player.is_cursor_blueprint()) then return end
	local bp = player.cursor_record
	if not (bp and bp.valid) then bp = player.cursor_stack end
	--- a blueprint that another mod changed may be unreadable: never break the paste
	pcall(M.paste, bp, player.surface, player.force, event.position, event.direction, event.flip_horizontal, event.flip_vertical,
		player)
end

--- the runtime test (copypaste.lua): the landing of a blueprint entity, and a paste as on_pre_build makes it
remote.add_interface("gregtorio-me-pasteover", {
	--- where each entity of `bp` lands (by name; the test's blueprints have one entity of each name)
	landings = function(bp, at, direction, fh, fv)
		local entities = bp.get_blueprint_entities() or {}
		local place = M.layout(entities, bp.get_blueprint_tiles() or {}, at, direction, fh, fv)
		local out = {}
		for _, be in pairs(entities) do out[be.name] = place(be) end
		return out
	end,
	paste = function(bp, surface, force, at, direction, fh, fv) return M.paste(bp, surface, force, at, direction, fh, fv) end,
})

return M
