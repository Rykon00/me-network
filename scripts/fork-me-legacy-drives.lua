--------------------------------------------------------------------------------
--- ME NETWORK: THE OLD DRIVE ITEMS OF A SAVE BECOME ME DRIVES WITH THEIR CELLS (issue #777; first issue #689)
--- Before issue #68 an ME Drive was one item per tier with four cells built in (me-drive-1k ... me-drive-256k, and the
--- fluid drives me-fluid-drive-1k ... me-fluid-drive-256k, which carry their fluid in their tags). Since 0.5.0 they have no
--- recipe and are hidden, and a save of 0.5.x may still hold them. Their prototypes stay (prototypes/network.lua,
--- prototypes/fluids.lua: hidden, not placeable), so the engine keeps the items when such a save is loaded, and this module
--- replaces every one, once per save: each old item becomes an ME Drive (of its quality), its four cells (a fluid drive's
--- fluid in them, more cells where four do not hold it) and its extra card (the Acceleration Card of a 256k drive, if the
--- game has that item). Where it looks:
---   * the inventories of entities (chests, wagons, vehicles, characters, corpses, robots, machines, rocket silos and rockets,
---     cargo pads and pods, space platform hubs) and of players without a character, the cursor, an inserter's hand, items on
---     the ground and on belts, this mod's script inventories (an ME IO Port, an ME Cell Workbench);
---   * the cells of the ME Drives and ME Chests (fork-me-network.lua, M.convert_legacy_drive_keys).
--- The drive goes back into the slot the old item was in; what does not fit into that inventory (or that drive's cells) is
--- spilled on the ground at its place. An old item inside a storage cell that lies outside a drive is not looked for here: it
--- is replaced when that cell is read the next time (fork-me-network.lua, cell_from_tags), so it is found wherever it is.
---
--- SAVE MIGRATIONS ARE NOT REMOVED (CONTRIBUTING.md, "Save migrations stay"). 0.6.0 had this conversion, 0.7.0 removed it and
--- refused every save from before 0.6.0 (issue #690); a player whose other mods need the newer version could then not load
--- the save with 0.6.0 any more. Do not remove this module, its prototypes or its test (devcheck `migrate`, part of `all`).
---
--- Why on_configuration_changed and not a file in migrations/: a Lua migration runs before on_configuration_changed, so
--- before control.lua has refused a save that cannot be converted (issue #146), taken over a Gregtorio hand-over, replaced
--- the old buses (issue #628) and cleaned the keys of removed items (issue #503); this conversion writes into the drive
--- records those steps leave. Both run once per save and never in a tick: here `storage.fork_me_legacy_drives == DONE` says
--- the save is done (a new map gets it in on_init). Every save that does not have that value is scanned once, also one that
--- comes from 0.6.x or 0.7.0: 0.6.0 marked a save with `true` but did not open cells outside a drive, so a 0.6.x save can
--- hold an old item again (taken out of such a cell later), and the scan is one pass over the map's inventories at an update.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")

local M = {}

--- the old drive items: { name -> { cell, cells, extra, fluid, fluid_tag } } (mod-data "fork-me-network")
local function legacy()
	local md = prototypes.mod_data["fork-me-network"]
	return md and md.data.legacy_drives or {}
end

--- how many stacks the definitions fill
local function stacks_of(defs)
	local n = 0
	for _, def in ipairs(defs) do
		local proto = prototypes.item[def.name]
		if proto then n = n + math.ceil(def.count / proto.stack_size) end
	end
	return n
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
	if not legacy()[stack.name] then return 0 end
	local name, count, quality = stack.name, stack.count, stack.quality.name
	local tags = stack.is_item_with_tags and stack.tags or nil
	local defs = N.legacy_products(name, count, quality, tags)
	if #defs == 0 then return 0 end
	stack.clear()
	--- the drive takes the old item's slot (it stacks to 10 as the old item did)
	local drive = table.remove(defs, 1)
	if stack.set_stack(drive) then
		local got = stack.count
		if got < drive.count then table.insert(defs, 1, { name = drive.name, count = drive.count - got, quality = quality }) end
	else
		table.insert(defs, 1, drive)
	end
	local rest = insert and insert_all(insert, defs) or defs
	if #rest > 0 then spill(surface, position, rest) end
	return count
end

--- `surface` nil (a script inventory, which has no place): an old item is replaced only when everything fits into `inv`
local function convert_inventory(inv, surface, position)
	if not (inv and inv.valid) then return 0 end
	local n = 0
	local names = legacy()
	for i = 1, #inv do
		local stack = inv[i]
		if stack.valid_for_read and names[stack.name] then
			local fits = surface ~= nil
			if not fits then
				local defs = N.legacy_products(stack.name, stack.count, stack.quality.name, stack.is_item_with_tags and stack.tags or nil)
				fits = inv.count_empty_stacks(false, false) >= stacks_of(defs) - 1       -- (the drives take the old item's slot)
			end
			if fits then n = n + convert_stack(stack, function(def) return inv.insert(def) end, surface, position) end
		end
	end
	return n
end

--- the entity types whose inventories, hands, belts or ground stacks can hold an item
local INVENTORY_TYPES = { "container", "logistic-container", "linked-container", "infinity-container", "temporary-container",
	"car", "spider-vehicle", "cargo-wagon", "character", "character-corpse", "assembling-machine", "furnace", "rocket-silo",
	"rocket-silo-rocket", "cargo-landing-pad", "cargo-pod", "space-platform-hub", "logistic-robot", "construction-robot" }
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
			local defs = N.legacy_products(st.name, count, st.quality.name, st.is_item_with_tags and st.tags or nil)
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
						spill(surface, e.position, N.legacy_products(f.name, got, f.quality, f.tags))
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

--- this mod's script inventories (the cell of an ME IO Port or an ME Cell Workbench, a parked cursor stack)
local function convert_script_inventories()
	local n = 0
	for _, inv in pairs((game.get_script_inventories(script.mod_name) or {})[script.mod_name] or {}) do
		n = n + convert_inventory(inv, nil, nil)
	end
	return n
end

--- `quiet`: no log line and no message (the tests' second run)
local function convert_all(quiet)
	local names = legacy()
	if not next(names) then return 0 end
	local n, spills = N.convert_legacy_drive_keys()
	for _, sp in ipairs(spills) do spill(sp.surface, sp.position, sp.defs) end
	n = n + convert_players()
	n = n + convert_script_inventories()
	for _, surface in pairs(game.surfaces) do n = n + convert_entities(surface) end
	if n > 0 and not quiet then
		log("ME-LEGACY-DRIVES " .. n)
		game.print({ "fork-me-net.legacy-drives-converted", n })
	end
	return n
end

--- the value of `storage.fork_me_legacy_drives` of a converted save (0.6.x wrote `true`, 0.7.0 cleared it)
local DONE = 2

--- on_configuration_changed (before the graph rebuild), once per save
function M.convert()
	if storage.fork_me_legacy_drives == DONE then return 0 end
	storage.fork_me_legacy_drives = DONE
	return convert_all()
end

--- a new map holds no old drive item
function M.on_init()
	storage.fork_me_legacy_drives = DONE
end

remote.add_interface("gregtorio-me-legacy-drives", {
	--- tests: convert again, whatever the flag says; returns the number of old items replaced
	convert = function() return convert_all(true) end,
	--- has this save been converted (or was it started without old items)?
	done = function() return storage.fork_me_legacy_drives == DONE end,
})

return M
