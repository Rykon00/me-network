--------------------------------------------------------------------------------
--- ME NETWORK: THE OLD DRIVE ITEMS BECOME ME DRIVES WITH THEIR CELLS (issue #689)
--- Before issue #68 an ME Drive was one item per tier with four cells built in (me-drive-1k ... me-drive-256k, and the
--- fluid drives me-fluid-drive-1k ... me-fluid-drive-256k, which carry their fluid in their tags). Since 0.5.0 they have no
--- recipe and are hidden; placing one builds an ME Drive with its four cells (scripts/fork-me-network.lua, M.on_built).
--- 0.6.0 replaces every one a save still holds, once, in on_configuration_changed, so that a later version can remove their
--- prototypes (issue #690) without a save losing anything: each old item becomes an ME Drive (of its quality), its four
--- cells (a fluid drive's fluid in them, more cells where four do not hold it, as a build does) and its extra card (the
--- Acceleration Card of a 256k drive). Where it lies:
---   * the inventories of entities (chests, wagons, vehicles, characters, corpses, machines, rocket silos and rockets, cargo
---     pads and pods, space platform hubs) and of players without a character, the cursor, an inserter's hand, items on the
---     ground and on belts;
---   * the cells of the ME Drives and ME Chests (fork-me-network.lua, M.convert_legacy_drive_keys, before the graph rebuild).
--- The drive goes back into the slot the old item was in; what does not fit into that inventory (or that drive's cells) is
--- spilled on the ground at its place. Cells lying outside a drive keep what they hold (a stored old drive item in a loose
--- cell is not looked at; issue #690's removal drops it). `storage.fork_me_legacy_drives` says the save was converted
--- (a new map has nothing to convert and gets it in on_init).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")

local M = {}

local DRIVE = "me-drive"

--- the old drive items: { name -> { cell, cells, extra, fluid, fluid_tag } } (mod-data "fork-me-network")
local function legacy()
	local md = prototypes.mod_data["fork-me-network"]
	return md and md.data.legacy_drives or {}
end

--- the stack definitions that replace `count` old items `name` of quality `quality` (`tags`: an old fluid drive's tags)
local function products(info, count, quality, tags)
	local out = { { name = DRIVE, count = count, quality = quality } }
	local fluid = info.fluid and type(tags) == "table" and type(tags[info.fluid_tag]) == "table" and tags[info.fluid_tag]
	local empty = info.cells * count
	if fluid then
		local cells = N.fluid_cells(info.cell, fluid)
		for _ = 1, count do
			for _, def in ipairs(cells) do out[#out + 1] = def end
		end
		empty = math.max(0, info.cells - #cells) * count
	end
	if empty > 0 then out[#out + 1] = { name = info.cell, count = empty } end
	local extra = info.extra
	if extra and prototypes.item[extra.name] then out[#out + 1] = { name = extra.name, count = extra.count * count } end
	return out
end

--- spill stack definitions on the ground (any count: a definition larger than a stack is split)
local function spill(surface, position, defs)
	for _, def in ipairs(defs) do
		local proto = prototypes.item[def.name]
		if proto and def.count > 0 then
			local inv = game.create_inventory(math.ceil(def.count / proto.stack_size))
			inv.insert(def)
			for i = 1, #inv do
				if inv[i].valid_for_read then
					surface.spill_item_stack{ position = position, stack = inv[i], allow_belts = false }
				end
			end
			inv.destroy()
		end
	end
end

--- definitions into `insert` (a function: def -> count inserted), the rest returned
local function insert_all(insert, defs)
	local rest = {}
	for _, def in ipairs(defs) do
		local got = insert(def) or 0
		if got < def.count then
			local copy = {}
			for k, v in pairs(def) do copy[k] = v end
			copy.count = def.count - got
			rest[#rest + 1] = copy
		end
	end
	return rest
end

--- the old item in `stack` replaced in place by its ME Drive; the other products into `insert`, the rest spilled at
--- `surface`/`position`. Returns the number of old items replaced.
local function convert_stack(stack, insert, surface, position)
	if not (stack and stack.valid and stack.valid_for_read) then return 0 end
	local info = legacy()[stack.name]
	if not info then return 0 end
	local count, quality = stack.count, stack.quality.name
	local tags = stack.is_item_with_tags and stack.tags or nil
	local defs = products(info, count, quality, tags)
	stack.clear()
	--- the drive takes the old item's slot (it stacks to 10 as the old item did)
	local drive = table.remove(defs, 1)
	if stack.set_stack(drive) then
		local got = stack.count
		if got < drive.count then table.insert(defs, 1, { name = DRIVE, count = drive.count - got, quality = quality }) end
	else
		table.insert(defs, 1, drive)
	end
	local rest = insert and insert_all(insert, defs) or defs
	if #rest > 0 then spill(surface, position, rest) end
	return count
end

local function convert_inventory(inv, surface, position)
	if not (inv and inv.valid) then return 0 end
	local n = 0
	local names = legacy()
	for i = 1, #inv do
		local stack = inv[i]
		if stack.valid_for_read and names[stack.name] then
			n = n + convert_stack(stack, function(def) return inv.insert(def) end, surface, position)
		end
	end
	return n
end

--- the entity types whose inventories, hands, belts or ground stacks can hold an item
local INVENTORY_TYPES = { "container", "logistic-container", "linked-container", "infinity-container", "temporary-container",
	"car", "spider-vehicle", "cargo-wagon", "character", "character-corpse", "assembling-machine", "furnace", "rocket-silo",
	"rocket-silo-rocket", "cargo-landing-pad", "cargo-pod", "space-platform-hub" }
local BELT_TYPES = { "transport-belt", "underground-belt", "splitter", "loader", "loader-1x1", "linked-belt", "lane-splitter" }

--- the types of `types` that some entity prototype has (find_entities_filtered refuses an unknown type)
local function existing(types)
	local have = {}
	for _, p in pairs(prototypes.entity) do have[p.type] = true end
	local out = {}
	for _, t in ipairs(types) do
		if have[t] then out[#out + 1] = t end
	end
	return out
end

local function convert_entities(surface)
	local n = 0
	local names = legacy()
	for _, e in ipairs(surface.find_entities_filtered{ type = existing(INVENTORY_TYPES) }) do
		if e.valid then
			for i = 1, e.get_max_inventory_index() do
				n = n + convert_inventory(e.get_inventory(i), surface, e.position)
			end
		end
	end
	for _, e in ipairs(surface.find_entities_filtered{ type = "inserter" }) do
		local held = e.valid and e.held_stack
		if held and held.valid_for_read and names[held.name] then
			n = n + convert_stack(held, nil, surface, e.drop_position)
		end
	end
	for _, e in ipairs(surface.find_entities_filtered{ type = "item-entity" }) do
		local st = e.valid and e.stack
		if st and st.valid_for_read and names[st.name] then
			--- (clearing a ground stack removes its entity: the stack is read, the entity removed, everything spilled there)
			local count, position = st.count, e.position
			local defs = products(names[st.name], count, st.quality.name, st.is_item_with_tags and st.tags or nil)
			e.destroy()
			spill(surface, position, defs)
			n = n + count
		end
	end
	local belts = existing(BELT_TYPES)
	if #belts > 0 then
		for _, e in ipairs(surface.find_entities_filtered{ type = belts }) do
			for i = 1, e.get_max_transport_line_index() do
				local line = e.get_transport_line(i)
				local found = {}
				for _, item in ipairs(line.get_detailed_contents()) do
					local st = item.stack
					if st.valid_for_read and names[st.name] then
						found[#found + 1] = { name = st.name, quality = st.quality.name, count = st.count,
							tags = st.is_item_with_tags and st.tags or nil }
					end
				end
				for _, f in ipairs(found) do
					local got = line.remove_item{ name = f.name, quality = f.quality, count = f.count }
					if got > 0 then
						spill(surface, e.position, products(names[f.name], got, f.quality, f.tags))
						n = n + got
					end
				end
			end
		end
	end
	return n
end

local function convert_players()
	local n = 0
	for _, player in pairs(game.players) do
		local surface, position = player.physical_surface, player.physical_position
		--- a character's inventories are its entity's (convert_entities); a player without one has inventories of its own
		if not player.character then
			for i = 1, player.get_max_inventory_index() do
				local ok, inv = pcall(player.get_inventory, i)       -- (a controller without inventories of that kind)
				if ok and inv then n = n + convert_inventory(inv, surface, position) end
			end
		end
		local cursor = player.cursor_stack
		if cursor and cursor.valid_for_read and legacy()[cursor.name] then
			n = n + convert_stack(cursor, function(def) return player.insert(def) end, surface, position)
		end
	end
	return n
end

--- on_configuration_changed (before the graph rebuild), once per save; the remote function `convert` runs it again in the tests
function M.convert()
	if storage.fork_me_legacy_drives then return 0 end
	storage.fork_me_legacy_drives = true
	local names = legacy()
	if not next(names) then return 0 end
	local n, spills = N.convert_legacy_drive_keys(function(name, quality, count, data)
		return products(names[name], count, quality, type(data) == "table" and data.tags or nil)
	end)
	for _, sp in ipairs(spills) do spill(sp.surface, sp.position, sp.defs) end
	n = n + convert_players()
	for _, surface in pairs(game.surfaces) do n = n + convert_entities(surface) end
	if n > 0 then
		log("ME-LEGACY-DRIVES " .. n)
		game.print({ "fork-me-net.legacy-drives-converted", n })
	end
	return n
end

--- a new map holds no old drive item
function M.on_init()
	storage.fork_me_legacy_drives = true
end

--- tests: convert again (the flag cleared first)
function M.convert_again()
	storage.fork_me_legacy_drives = nil
	return M.convert()
end

remote.add_interface("gregtorio-me-legacy-drives", {
	convert = function() return M.convert_again() end,
})

return M
