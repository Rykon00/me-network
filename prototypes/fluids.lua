--------------------------------------------------------------------------------
--- ME NETWORK: FLUIDS (Gregtorio issue #68, step R2; design: docs/ME-REWORK.md)
---   * Fluid Storage Cell = storage housing + storage component + pump, an item with tags (stack size 1)
---                          that goes into the ME Drive like an item cell. It stores fluids by name (one
---                          temperature per fluid): k*1024 bytes, k*8 bytes per fluid type, up to 18
---                          types, 8 fluid units per byte. Taken out of a drive it carries its fluids in
---                          its tags.
---   * ME Fluid Interface = 1x1 storage tank of the network: import (tank -> network, the default) or export
---                          (network -> tank, up to a fill level).
---   * ME Fluid Import / Export Bus = rotatable 1x1 blocks that take fluid out of / put fluid into the
---                          entity they face (tank, machine).
---   * ME Fluid Storage Bus = rotatable 1x1 block: the fluid segment of the tank it faces is storage of the
---                          network (scripts/fork-me-fluid-storagebus.lua).
---   * The old ME Fluid Drive (four cells crafted in, contents in script state) stays hidden so saves load;
---     scripts/fork-me-migrate.lua replaces each one by an ME Drive with four fluid cells of its tier.
---     Placing an old fluid drive item gives the same (its fluid goes into the cells).
--- The cell numbers go into the mod-data "fork-me-network" of network.lua; the interface's numbers into the
--- mod-data "fork-me-fluids". Runtime: scripts/fork-me-network.lua (storage), scripts/fork-me-fluids.lua
--- (fluid interface), scripts/fork-me-io.lua (buses), scripts/fork-me-fluid-storagebus.lua (fluid storage bus).
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

local INTERFACE = "me-fluid-interface"
local INTERFACE_VOLUME = 5000
local IMPORT_BUS, EXPORT_BUS = "me-fluid-import-bus", "me-fluid-export-bus"
local STORAGE_BUS = "me-fluid-storage-bus"   -- the fluid segment of the tank it faces is network storage



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
--- ME FLUID INTERFACE (1x1 storage tank; the runtime moves fluid between it and the network)
--------------------------------------------------------------------------------

ME.add_item{
	name = INTERFACE,
	icon = ICON_FORK .. INTERFACE .. ".png",
	subgroup = "fork-me-network",
	order = "h",
	stack_size = 50,
	place_result = INTERFACE,
	recipe = { energy_required = 2, ingredients = {
		{ type = "item", name = "me-interface", amount = 1 },
		{ type = "item", name = "pump", amount = 1 },
		{ type = "item", name = "pipe", amount = 4 },
		{ type = "item", name = "fluix-cable", amount = 2 },
	} },
}

data:extend({ {
	type = "storage-tank",
	name = INTERFACE,
	icon = ICON_FORK .. INTERFACE .. ".png",
	icon_size = 32,
	flags = { "placeable-neutral", "player-creation" },
	minable = { mining_time = 0.2, result = INTERFACE },
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
	--- a storage tank has no settings of its own: this lets the game copy the interface's settings
	--- (mode, fluid, level; the runtime copies them in on_entity_settings_pasted, issue #38)
	additional_pastable_entities = { INTERFACE },
	localised_description = { "entity-description." .. INTERFACE },
} })



--------------------------------------------------------------------------------
--- ME FLUID IMPORT / EXPORT / STORAGE BUS (rotatable, like the item buses of network.lua; the fluid storage bus makes the
--- fluid segment of the tank it faces network storage, runtime: scripts/fork-me-fluid-storagebus.lua)
--------------------------------------------------------------------------------

local function four_way(name)
	local out = {}
	for _, dir in pairs({ "north", "east", "south", "west" }) do
		out[dir] = { filename = ENTITY_PATH .. name .. "-" .. dir .. ".png", priority = "extra-high", width = 32, height = 32 }
	end
	return out
end

for _, bus in pairs({
	{ name = IMPORT_BUS, base = "me-import-bus", order = "h2" },
	{ name = EXPORT_BUS, base = "me-export-bus", order = "h3" },
	{ name = STORAGE_BUS, base = "me-storage-bus", order = "h4" },
}) do
	ME.add_item{
		name = bus.name,
		icon = ICON_FORK .. bus.name .. ".png",
		subgroup = "fork-me-network",
		order = bus.order,
		stack_size = 50,
		place_result = bus.name,
		recipe = { energy_required = 2, ingredients = {
			{ type = "item", name = bus.base, amount = 1 },
			{ type = "item", name = "pump", amount = 1 },
			{ type = "item", name = "pipe", amount = 2 },
		} },
	}
	data:extend({ {
		type = "simple-entity-with-force",
		name = bus.name,
		icon = ICON_FORK .. bus.name .. ".png",
		icon_size = 32,
		flags = { "placeable-neutral", "player-creation" },
		minable = { mining_time = 0.2, result = bus.name },
		placeable_by = { item = bus.name, count = 1 },
		max_health = 200,
		is_military_target = false,
		corpse = "small-remnants",
		collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } },
		selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
		selection_priority = 60,
		picture = four_way(bus.name),
		additional_pastable_entities = { bus.name },
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
		interface = { name = INTERFACE, volume = INTERFACE_VOLUME },
	},
} })



--------------------------------------------------------------------------------
--- TECHNOLOGIES (standalone: vanilla science)
--------------------------------------------------------------------------------

--- fluid cells up to 64k, the fluid interface, the fluid buses (import, export, storage)
ME.add_technology{ name = "me-fluid-storage", prerequisites = { "me-storage-64k", "fluid-handling" }, unit = ME.unit(3, 400),
	recipes = { INTERFACE, IMPORT_BUS, EXPORT_BUS, STORAGE_BUS, "me-1k-fluid-storage-cell", "me-4k-fluid-storage-cell",
		"me-16k-fluid-storage-cell", "me-64k-fluid-storage-cell" } }

ME.add_technology{ name = "me-fluid-storage-256k", prerequisites = { "me-fluid-storage", "me-storage-256k" },
	unit = ME.unit(4, 600), recipes = { "me-256k-fluid-storage-cell" } }
