--------------------------------------------------------------------------------
--- ME NETWORK: FLUIDS (Gregtorio issue #68, step R2; design: docs/ME-REWORK.md)
---   * Fluid Storage Cell = storage housing + storage component + pump, an item with tags (stack size 1)
---                          that goes into the ME Drive like an item cell. It stores fluids by name (one
---                          temperature per fluid): k*1024 bytes, k*8 bytes per fluid type, up to 18
---                          types, 8 fluid units per byte. Taken out of a drive it carries its fluids in
---                          its tags.
---   * ME Interface fluid sides (issue #3) = four hidden 1x1 storage tanks on the ME Interface's tile, one pipe
---                          connection each (north, east, south, west): pipes connect to the interface through them
---                          (scripts/fork-me-io.lua).
---   * The old ME Fluid Interface, ME Fluid Import / Export Bus and ME Fluid Storage Bus (issue #3: the ME Interface
---                          and the buses handle fluids themselves) stay hidden so saves load them:
---                          scripts/fork-me-unify.lua replaces each one by the unified block; their items have no
---                          recipe and place the unified block, their entities are placeable by the unified item
---                          (so ghosts of old blueprints survive and robots build them; the build event converts them).
---   * The old ME Fluid Drive (four cells crafted in, contents in script state) stays hidden so saves load;
---     scripts/fork-me-migrate.lua replaces each one by an ME Drive with four fluid cells of its tier.
---     Placing an old fluid drive item gives the same (its fluid goes into the cells).
--- The cell numbers go into the mod-data "fork-me-network" of network.lua; the interface's numbers into the
--- mod-data "fork-me-fluids". Runtime: scripts/fork-me-network.lua (storage), scripts/fork-me-fluids.lua
--- (the fluid calls), scripts/fork-me-io.lua (interface sides, buses), scripts/fork-me-fluid-storagebus.lua (the fluid
--- side of the storage bus), scripts/fork-me-unify.lua (the old fluid blocks).
--- Sprites and icons: tools/gen_ae2_sprites.py.
--------------------------------------------------------------------------------

local ME = ME_NETWORK
local ENTITY_PATH = ME.entity_path
local ICON_FORK = ME.icons .. "fork/"

local UNITS_PER_BYTE = 8
local FLUID_TYPES = 18
local OLD_CELLS_PER_DRIVE = 4

--- cell tier -> "k" (the extra item of an old 256k fluid drive item is given back if that item exists)
local CELLS = {
	{ tier = "1k",   k = 1 },
	{ tier = "4k",   k = 4 },
	{ tier = "16k",  k = 16 },
	{ tier = "64k",  k = 64 },
	{ tier = "256k", k = 256, extra = { name = "acceleration-card", count = 1 } },
}

local INTERFACE = "me-fluid-interface"          -- old (issue #3), hidden
local INTERFACE_VOLUME = 5000                   -- the old fluid interface's tank and each side of the ME Interface
local IMPORT_BUS, EXPORT_BUS = "me-fluid-import-bus", "me-fluid-export-bus"   -- old (issue #3), hidden
local STORAGE_BUS = "me-fluid-storage-bus"      -- old (issue #3), hidden
local SIDE = "me-network-interface-side"        -- a fluid side of the ME Interface
--- old block -> the unified block (entity and item) that replaces it
local UNIFIED_ENTITY = { [INTERFACE] = "me-network-interface", [IMPORT_BUS] = "me-import-bus",
	[EXPORT_BUS] = "me-export-bus", [STORAGE_BUS] = "me-storage-bus" }
local UNIFIED_ITEM = { [INTERFACE] = "me-interface", [IMPORT_BUS] = "me-import-bus",
	[EXPORT_BUS] = "me-export-bus", [STORAGE_BUS] = "me-storage-bus" }



--------------------------------------------------------------------------------
--- ITEM SUBGROUPS
--------------------------------------------------------------------------------

local group = data.raw["item-group"]["logistics"] and "logistics" or "processing-machine-recipes"
data:extend({
	{ type = "item-subgroup", name = "fork-me-fluid-cells", group = group, order = "b-me-d" },
	{ type = "item-subgroup", name = "fork-me-fluid-drives", group = group, order = "b-me-e" },
})



--------------------------------------------------------------------------------
--- FLUID STORAGE CELLS (items with tags) AND THE OLD FLUID DRIVES (hidden)
--------------------------------------------------------------------------------

local net_data = data.raw["mod-data"]["fork-me-network"].data

for i, c in ipairs(CELLS) do
	local cell = "me-" .. c.tier .. "-fluid-storage-cell"
	local drive = "me-fluid-drive-" .. c.tier
	local order = string.format("%02d", i)

	--- cell = storage housing + storage component + pump; an item with tags (a recycler would void the fluid)
	local item = ME.add_item{
		type = "item-with-tags",
		name = cell,
		icon = ICON_FORK .. cell .. ".png",
		subgroup = "fork-me-fluid-cells",
		order = order,
		stack_size = 1,
		recipe = { energy_required = 5, auto_recycle = false, ingredients = {
			{ type = "item", name = "me-" .. c.tier .. "-storage-component", amount = 1 },
			{ type = "item", name = "basic-storage-housing", amount = 1 },
			{ type = "item", name = "pump", amount = 1 },
		} },
	}
	local bytes = c.k * 1024
	local per_type = c.k * 8
	net_data.cells[cell] = { tier = c.tier, kind = "fluid", bytes = bytes, per_type = per_type, types = FLUID_TYPES,
		per_byte = UNITS_PER_BYTE }
	item.localised_description = { "item-description.fork-me-fluid-storage-cell", c.tier, tostring(bytes),
		tostring(FLUID_TYPES), tostring((bytes - per_type) * UNITS_PER_BYTE) }

	--- the old fluid drive item (chassis + four cells, fluid in its tags): no recipe any more, hidden; placing
	--- one builds an ME Drive with its four fluid cells holding its fluid
	data:extend({ {
		type = "item-with-tags",
		name = drive,
		icon = ICON_FORK .. drive .. ".png",
		icon_size = 32,
		subgroup = "fork-me-fluid-drives",
		order = "z" .. order,
		stack_size = 10,
		place_result = "me-drive",
		hidden = true,
		localised_description = { "item-description.fork-me-legacy-drive", { "item-name." .. cell } },
	} })
	net_data.legacy_drives[drive] = { cell = cell, cells = OLD_CELLS_PER_DRIVE, extra = c.extra, fluid = true,
		fluid_tag = "fork_me_fluids" }

	--- the old fluid drive entity: hidden, kept so saves load it (the migration replaces it)
	data:extend({ {
		type = "simple-entity-with-force",
		name = drive,
		icon = ICON_FORK .. drive .. ".png",
		icon_size = 32,
		flags = { "placeable-neutral", "player-creation" },
		minable = { mining_time = 0.2, result = drive },
		max_health = 400,
		is_military_target = false,
		corpse = "small-remnants",
		collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } },
		selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
		picture = {
			filename = ENTITY_PATH .. drive .. ".png",
			priority = "extra-high",
			width = 32, height = 32,
		},
		hidden = true,
		localised_name = { "entity-name.fork-me-legacy", { "item-name." .. drive } },
	} })
end



--------------------------------------------------------------------------------
--- THE ME INTERFACE'S FLUID SIDES (issue #3): four of these on the interface's tile, created by the runtime with
--- the directions north, east, south and west; each connects to the pipe on its side only (tested in 2.0.77)
--------------------------------------------------------------------------------

data:extend({ {
	type = "storage-tank",
	name = SIDE,
	icon = ICON_FORK .. INTERFACE .. ".png",
	icon_size = 32,
	flags = { "not-on-map", "not-blueprintable", "not-deconstructable", "not-upgradable", "hide-alt-info",
		"no-copy-paste", "not-in-kill-statistics" },
	hidden = true,
	selectable_in_game = false,
	max_health = 400,
	collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } },
	collision_mask = { layers = {} },                 -- shares the tile with the interface's container
	fluid_box = {
		volume = INTERFACE_VOLUME,
		hide_connection_info = true,
		pipe_connections = { { direction = defines.direction.north, position = { 0, 0 } } },
	},
	window_bounding_box = { { 0, 0 }, { 0, 0 } },
	flow_length_in_ticks = 360,
	pictures = { picture = { filename = "__core__/graphics/empty.png", priority = "extra-high", width = 1, height = 1 } },
	two_direction_only = false,
	circuit_wire_max_distance = 0,
	localised_name = { "entity-name.me-network-interface" },
} })



--------------------------------------------------------------------------------
--- THE OLD ME FLUID INTERFACE (1x1 storage tank; issue #3: hidden, replaced by the ME Interface when a save loads)
--------------------------------------------------------------------------------

ME.add_item{
	name = INTERFACE,
	icon = ICON_FORK .. INTERFACE .. ".png",
	subgroup = "fork-me-network",
	order = "z-h",
	stack_size = 50,
	place_result = UNIFIED_ENTITY[INTERFACE],
	hidden = true,
	recipe = false,
	localised_description = { "item-description.fork-me-unified", { "item-name." .. UNIFIED_ITEM[INTERFACE] } },
}

data:extend({ {
	type = "storage-tank",
	name = INTERFACE,
	icon = ICON_FORK .. INTERFACE .. ".png",
	icon_size = 32,
	flags = { "placeable-neutral", "player-creation" },
	minable = { mining_time = 0.2, result = UNIFIED_ITEM[INTERFACE] },
	placeable_by = { item = UNIFIED_ITEM[INTERFACE], count = 1 },
	hidden = true,
	max_health = 400,
	corpse = "small-remnants",
	collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } },
	selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
	fluid_box = {
		volume = INTERFACE_VOLUME,
		pipe_covers = pipecoverspictures(),
		hide_connection_info = true,                  -- four connections on one tile, like a pipe
		pipe_connections = {
			{ direction = defines.direction.north, position = { 0, 0 } },
			{ direction = defines.direction.east, position = { 0, 0 } },
			{ direction = defines.direction.south, position = { 0, 0 } },
			{ direction = defines.direction.west, position = { 0, 0 } },
		},
	},
	window_bounding_box = { { -0.25, -0.25 }, { 0.25, 0.25 } },
	flow_length_in_ticks = 360,
	pictures = {
		picture = {
			filename = ENTITY_PATH .. INTERFACE .. ".png",
			priority = "extra-high",
			width = 32, height = 32,
		},
	},
	two_direction_only = false,
	circuit_wire_max_distance = 0,
	localised_name = { "entity-name.fork-me-legacy", { "item-name." .. INTERFACE } },
	localised_description = { "entity-description." .. INTERFACE },
} })



--------------------------------------------------------------------------------
--- THE OLD ME FLUID IMPORT / EXPORT / STORAGE BUS (issue #3: hidden, replaced by the unified buses when a save loads)
--------------------------------------------------------------------------------

local function four_way(name)
	local out = {}
	for _, dir in pairs({ "north", "east", "south", "west" }) do
		out[dir] = { filename = ENTITY_PATH .. name .. "-" .. dir .. ".png", priority = "extra-high", width = 32, height = 32 }
	end
	return out
end

for _, bus in pairs({
	{ name = IMPORT_BUS, order = "z-h2" },
	{ name = EXPORT_BUS, order = "z-h3" },
	{ name = STORAGE_BUS, order = "z-h4" },
}) do
	ME.add_item{
		name = bus.name,
		icon = ICON_FORK .. bus.name .. ".png",
		subgroup = "fork-me-network",
		order = bus.order,
		stack_size = 50,
		place_result = UNIFIED_ENTITY[bus.name],
		hidden = true,
		recipe = false,
		localised_description = { "item-description.fork-me-unified", { "item-name." .. UNIFIED_ITEM[bus.name] } },
	}
	data:extend({ {
		type = "simple-entity-with-force",
		name = bus.name,
		icon = ICON_FORK .. bus.name .. ".png",
		icon_size = 32,
		flags = { "placeable-neutral", "player-creation" },
		minable = { mining_time = 0.2, result = UNIFIED_ITEM[bus.name] },
		placeable_by = { item = UNIFIED_ITEM[bus.name], count = 1 },
		hidden = true,
		max_health = 200,
		is_military_target = false,
		corpse = "small-remnants",
		collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } },
		selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
		selection_priority = 60,
		render_layer = "lower-object",                -- walkable like the unified buses (issue #129): a save that still has one behaves the same
		collision_mask = ME.WALKABLE,
		picture = four_way(bus.name),
		localised_name = { "entity-name.fork-me-legacy", { "item-name." .. bus.name } },
		localised_description = { "entity-description." .. bus.name },
	} })
end



--------------------------------------------------------------------------------
--- MOD DATA (read by scripts/fork-me-fluids.lua: no duplicated numbers)
--------------------------------------------------------------------------------

data:extend({ {
	type = "mod-data",
	name = "fork-me-fluids",
	data = {
		interface = { name = INTERFACE, volume = INTERFACE_VOLUME },   -- the old fluid interface (issue #3)
		side = { name = SIDE, volume = INTERFACE_VOLUME },               -- a fluid side of the ME Interface
		--- issue #3: the old fluid blocks and what replaces them (scripts/fork-me-unify.lua)
		unified = { entities = UNIFIED_ENTITY, items = UNIFIED_ITEM },
	},
} })



--------------------------------------------------------------------------------
--- TECHNOLOGIES (standalone: vanilla science)
--------------------------------------------------------------------------------

--- fluid cells up to 64k (issue #3: the ME Interface and the buses move fluids from the start, like AE2's)
ME.add_technology{ name = "me-fluid-storage", prerequisites = { "me-storage-64k", "fluid-handling" }, unit = ME.unit(3, 400),
	recipes = { "me-1k-fluid-storage-cell", "me-4k-fluid-storage-cell", "me-16k-fluid-storage-cell",
		"me-64k-fluid-storage-cell" } }

--- issue #3: the old fluid blocks have no recipe; a mod that makes one for them itself (Gregtorio Continued 0.5.0)
--- loses it in data-final-fixes.lua
for old in pairs(UNIFIED_ITEM) do ME.removed[old] = UNIFIED_ITEM[old] end

ME.add_technology{ name = "me-fluid-storage-256k", prerequisites = { "me-fluid-storage", "me-storage-256k" },
	unit = ME.unit(4, 600), recipes = { "me-256k-fluid-storage-cell" } }
