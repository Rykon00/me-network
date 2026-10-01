--------------------------------------------------------------------------------
--- FORK AE2: FLUIDS IN THE ME NETWORK (issue #68, step R2; design: docs/ME-REWORK.md)
---   * Fluid Storage Cell = storage housing + storage component + pump, an item with tags (stack size 1)
---                          that goes into the ME Drive like an item cell. It stores fluids by name (one
---                          temperature per fluid): k*1024 bytes, k*8 bytes per fluid type, up to 18
---                          types, 8 fluid units per byte. Taken out of a drive it carries its fluids in
---                          its tags.
---   * ME Fluid Interface = 1x1 storage tank of the network: import (tank -> network, the default) or export
---                          (network -> tank, up to a fill level).
---   * ME Fluid Import / Export Bus = rotatable 1x1 blocks that take fluid out of / put fluid into the
---                          entity they face (tank, machine).
---   * The old ME Fluid Drive (four cells crafted in, contents in script state) stays hidden so saves load;
---     scripts/fork-me-migrate.lua replaces each one by an ME Drive with four fluid cells of its tier.
---     Placing an old fluid drive item gives the same (its fluid goes into the cells).
--- The cell numbers go into the mod-data "fork-me-network" of 120; the interface's numbers into the
--- mod-data "fork-me-fluids". Runtime: scripts/fork-me-network.lua (storage), scripts/fork-me-fluids.lua
--- (fluid interface), scripts/fork-me-io.lua (buses). Sprites and icons: tools/gen_ae2_sprites.py.
--------------------------------------------------------------------------------

local ENTITY_PATH = "__gregtorio-continued__/graphics/entity/fork/ae2/"
local ICON_FORK = ICON_PATH .. "fork/"

local UNITS_PER_BYTE = 8
local FLUID_TYPES = 18
local OLD_CELLS_PER_DRIVE = 4

--- cell tier -> "k", pump of the cell recipe, assembler category of the cell
local CELLS = {
	{ tier = "1k",   k = 1,   pump = "lv-pump", cell_cat = "lv-assembling-machine-recipes" },
	{ tier = "4k",   k = 4,   pump = "lv-pump", cell_cat = "lv-assembling-machine-recipes" },
	{ tier = "16k",  k = 16,  pump = "mv-pump", cell_cat = "mv-assembling-machine-recipes" },
	{ tier = "64k",  k = 64,  pump = "hv-pump", cell_cat = "hv-assembling-machine-recipes" },
	{ tier = "256k", k = 256, pump = "ev-pump", cell_cat = "ev-assembling-machine-recipes",
	  extra = { name = "acceleration-card", count = 1 } },
}

local INTERFACE = "me-fluid-interface"
local INTERFACE_VOLUME = 5000
local IMPORT_BUS, EXPORT_BUS = "me-fluid-import-bus", "me-fluid-export-bus"



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

	--- cell = storage housing + storage component + pump (unchanged recipe)
	create_item{
		name = cell,
		icon = ICON_FORK .. cell .. ".png",
		category = c.cell_cat,
		subgroup = "fork-me-fluid-cells",
		order = order,
		energy_required = 5,
		stack_size = 1,
		ingredients = {
			{ type = "item", name = "me-" .. c.tier .. "-storage-component", amount = 1 },
			{ type = "item", name = "basic-storage-housing", amount = 1 },
			{ type = "item", name = c.pump, amount = 1 },
		},
	}
	--- like the item cells (120): remove, change the type, add again
	local item = data.raw.item[cell]
	data.raw.item[cell] = nil
	item.type = "item-with-tags"
	data:extend({ item })
	data.raw.recipe[cell].auto_recycle = false         -- a recycler would void the fluid
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

create_item{
	name = INTERFACE,
	icon = ICON_FORK .. INTERFACE .. ".png",
	category = "hv-assembling-machine-recipes",
	subgroup = "fork-me-network",
	order = "h",
	energy_required = 10 * HV_SPEED,
	stack_size = 50,
	place_result = INTERFACE,
	ingredients = {
		{ type = "item", name = "me-interface", amount = 1 },
		{ type = "item", name = "hv-pump", amount = 1 },
		{ type = "item", name = "pipe", amount = 4 },
		{ type = "item", name = "fluix-cable", amount = 2 },
	},
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
--- ME FLUID IMPORT / EXPORT BUS (rotatable, like the item buses of 120)
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
}) do
	create_item{
		name = bus.name,
		icon = ICON_FORK .. bus.name .. ".png",
		category = "hv-assembling-machine-recipes",
		subgroup = "fork-me-network",
		order = bus.order,
		energy_required = 10 * HV_SPEED,
		stack_size = 50,
		place_result = bus.name,
		ingredients = {
			{ type = "item", name = bus.base, amount = 1 },
			{ type = "item", name = "hv-pump", amount = 1 },
			{ type = "item", name = "pipe", amount = 2 },
		},
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
--- TECHNOLOGIES
--------------------------------------------------------------------------------

local function sci(n)
	local packs = { "automation-science-pack", "logistic-science-pack", "military-science-pack",
		"chemical-science-pack", "production-science-pack", "utility-science-pack" }
	local amounts = { SP06, SP05, SP04, SP03, SP02, SP01 }
	local out = {}
	for i = 1, n do
		out[#out + 1] = { packs[i], amounts[#amounts - n + i] }
	end
	return out
end

local function tech(def)
	local effects = {}
	for _, r in pairs(def.recipes) do
		if data.raw.recipe[r] then
			effects[#effects + 1] = { type = "unlock-recipe", recipe = r }
			data.raw.recipe[r].enabled = false
		else
			log("FORK-AE2: tech " .. def.name .. ": missing recipe " .. r)
		end
	end
	data:extend({ {
		type = "technology",
		name = def.name,
		icon = "__gregtorio-continued__/graphics/technology/fork/" .. def.name .. ".png",
		icon_size = 256,
		effects = effects,
		prerequisites = def.prerequisites,
		unit = { count = def.count, ingredients = sci(def.packs), time = 30 },
	} })
end

--- EV: fluid cells up to 64k, the fluid interface, the fluid buses
tech{ name = "me-fluid-storage", prerequisites = { "me-autocrafting" }, packs = 5, count = 600, recipes = {
	INTERFACE, IMPORT_BUS, EXPORT_BUS, "me-1k-fluid-storage-cell", "me-4k-fluid-storage-cell",
	"me-16k-fluid-storage-cell", "me-64k-fluid-storage-cell" } }

--- IV: 256k fluid cells
tech{ name = "me-fluid-storage-256k", prerequisites = { "me-fluid-storage", "me-storage-256k" },
	packs = 6, count = 800, recipes = { "me-256k-fluid-storage-cell" } }
