--------------------------------------------------------------------------------
--- FORK AE2: FLUIDS IN THE ME NETWORK (on top of the ME network from 120-fork-ae2.lua)
---   * Fluid Storage Cell = storage housing + storage component + pump. Four of them make
---                          an ME Fluid Drive; 8000 fluid units per "1k" of a cell (AE2:
---                          8 items per byte).
---   * ME Fluid Drive     = passive 1x1 entity of the ME network. Its contents are virtual:
---                          the runtime keeps a fluid -> amount table per drive, nothing is
---                          stored in an engine fluid box. Picking the drive up moves the
---                          contents onto the item (item-with-tags), placing it again restores
---                          them; a destroyed drive's fluids go to the other drives of its
---                          network or are kept for the next drive placed on the surface.
---   * ME Fluid Interface = 1x1 storage tank inside the network. Its GUI selects import
---                          (tank -> network) or export (network -> tank, up to a fill level).
---                          The network stores fluids by name only, without temperature.
---   * The numbers the runtime needs (drive capacities, interface volume) are passed through
---     the mod-data "fork-me-fluids", so nothing is duplicated in scripts/fork-me-fluids.lua.
--- Runtime logic: scripts/fork-me-fluids.lua. Sprites and icons: tools/gen_ae2_sprites.py.
--------------------------------------------------------------------------------

local ENTITY_PATH = "__gregtorio-continued__/graphics/entity/fork/ae2/"
local ICON_FORK = ICON_PATH .. "fork/"

--- fluid units one "1k" of a cell holds, and cells per drive
local UNITS_PER_K = 8000
local CELLS_PER_DRIVE = 4

--- cell tier -> "k" of the cell, pump of the cell recipe, assembler category of cell and
--- drive, extra drive ingredient (categories and speeds like the item cells in 120)
local CELLS = {
	{ tier = "1k",   k = 1,   pump = "lv-pump", cell_cat = "lv-assembling-machine-recipes", drive_cat = "mv-assembling-machine-recipes", speed = MV_SPEED },
	{ tier = "4k",   k = 4,   pump = "lv-pump", cell_cat = "lv-assembling-machine-recipes", drive_cat = "mv-assembling-machine-recipes", speed = MV_SPEED },
	{ tier = "16k",  k = 16,  pump = "mv-pump", cell_cat = "mv-assembling-machine-recipes", drive_cat = "mv-assembling-machine-recipes", speed = MV_SPEED },
	{ tier = "64k",  k = 64,  pump = "hv-pump", cell_cat = "hv-assembling-machine-recipes", drive_cat = "ev-assembling-machine-recipes", speed = EV_SPEED },
	{ tier = "256k", k = 256, pump = "ev-pump", cell_cat = "ev-assembling-machine-recipes", drive_cat = "iv-assembling-machine-recipes", speed = IV_SPEED,
	  extra = { type = "item", name = "acceleration-card", amount = 1 } },
}
for _, c in ipairs(CELLS) do c.capacity = c.k * UNITS_PER_K * CELLS_PER_DRIVE end

local INTERFACE = "me-fluid-interface"
local INTERFACE_VOLUME = 5000



--------------------------------------------------------------------------------
--- ITEM SUBGROUPS
--------------------------------------------------------------------------------

local group = data.raw["item-group"]["logistics"] and "logistics" or "processing-machine-recipes"
data:extend({
	{ type = "item-subgroup", name = "fork-me-fluid-cells", group = group, order = "b-me-d" },
	{ type = "item-subgroup", name = "fork-me-fluid-drives", group = group, order = "b-me-e" },
})



--------------------------------------------------------------------------------
--- FLUID STORAGE CELLS AND FLUID DRIVES
--------------------------------------------------------------------------------

local drive_capacity = {}

for i, c in ipairs(CELLS) do
	local cell = "me-" .. c.tier .. "-fluid-storage-cell"
	local drive = "me-fluid-drive-" .. c.tier
	local order = string.format("%02d", i)
	drive_capacity[drive] = c.capacity

	--- cell = storage housing + storage component + pump
	create_item{
		name = cell,
		icon = ICON_FORK .. cell .. ".png",
		category = c.cell_cat,
		subgroup = "fork-me-fluid-cells",
		order = order,
		energy_required = 5,
		stack_size = 16,
		ingredients = {
			{ type = "item", name = "me-" .. c.tier .. "-storage-component", amount = 1 },
			{ type = "item", name = "basic-storage-housing", amount = 1 },
			{ type = "item", name = c.pump, amount = 1 },
		},
	}
	data.raw.item[cell].localised_description = { "item-description.fork-me-fluid-storage-cell", c.tier, tostring(c.capacity) }

	--- drive = drive chassis + four cells
	local ingredients = {
		{ type = "item", name = "me-drive", amount = 1 },
		{ type = "item", name = cell, amount = CELLS_PER_DRIVE },
	}
	if c.extra then ingredients[#ingredients + 1] = c.extra end
	create_item{
		name = drive,
		icon = ICON_FORK .. drive .. ".png",
		category = c.drive_cat,
		subgroup = "fork-me-fluid-drives",
		order = "b" .. order,
		energy_required = 10 * c.speed,
		stack_size = 10,
		place_result = drive,
		ingredients = ingredients,
	}

	--- the drive item carries its fluids as tags when it is picked up (like 150-fork-molds
	--- turns the mold item into a module: remove it from data.raw.item, change the type, re-add)
	local item = data.raw.item[drive]
	data.raw.item[drive] = nil
	item.type = "item-with-tags"
	data:extend({ item })
	data.raw.recipe[drive].auto_recycle = false          -- a recycler would void the fluid on the item

	--- take the cells out again (e.g. after the upgrade planner replaced the drive). Hand crafting
	--- only: the hand craft event shows the consumed item with its tags, so the runtime can salvage
	--- the fluid of a loaded drive item; an assembler would consume it without any event.
	local parts = {
		{ type = "item", name = "me-drive", amount = 1 },
		{ type = "item", name = cell, amount = CELLS_PER_DRIVE },
	}
	if c.extra then parts[#parts + 1] = c.extra end
	create_recipe{
		recipe_name = drive .. "-disassembly",
		category = "manual-only-recipes",
		subgroup = "fork-me-fluid-drives",
		order = "c" .. order,
		icon = ICON_FORK .. drive .. ".png",
		energy_required = 1,
		ingredients = { { type = "item", name = drive, amount = 1 } },
		results = parts,
	}
	data.raw.recipe[drive .. "-disassembly"].allow_decomposition = false
	data.raw.recipe[drive .. "-disassembly"].localised_name = { "recipe-name.fork-me-drive-disassembly", { "item-name." .. drive } }
	data.raw.recipe[drive .. "-disassembly"].localised_description = { "recipe-description.fork-me-fluid-drive-disassembly" }

	--- passive marker entity: the contents live in the runtime (scripts/fork-me-fluids.lua)
	data:extend({ {
		type = "simple-entity-with-force",
		name = drive,
		icon = ICON_FORK .. drive .. ".png",
		icon_size = 32,
		flags = { "placeable-neutral", "player-creation" },
		minable = { mining_time = 0.2, result = drive },
		max_health = 400,
		--- a simple-entity-with-force is a military target by default; the drive is a chest-like
		--- passive block (the ME Drive is a logistic container, which is no target either)
		is_military_target = false,
		corpse = "small-remnants",
		collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } },
		selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
		selection_priority = 60,
		picture = {
			filename = ENTITY_PATH .. drive .. ".png",
			priority = "extra-high",
			width = 32, height = 32,
		},
		fast_replaceable_group = "me-fluid-drive",
		next_upgrade = CELLS[i + 1] and ("me-fluid-drive-" .. CELLS[i + 1].tier) or nil,
		localised_description = { "entity-description.fork-me-fluid-drive", tostring(c.capacity), c.tier },
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
	localised_description = { "entity-description." .. INTERFACE },
} })



--------------------------------------------------------------------------------
--- MOD DATA (read by scripts/fork-me-fluids.lua: no duplicated numbers)
--------------------------------------------------------------------------------

data:extend({ {
	type = "mod-data",
	name = "fork-me-fluids",
	data = {
		drives = drive_capacity,
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

local function drive_recipes(tier)
	return "me-" .. tier .. "-fluid-storage-cell", "me-fluid-drive-" .. tier, "me-fluid-drive-" .. tier .. "-disassembly"
end

--- EV: fluid cells and drives up to 64k, the fluid interface
local ev = { INTERFACE }
for _, t in pairs({ "1k", "4k", "16k", "64k" }) do
	for _, r in pairs({ drive_recipes(t) }) do ev[#ev + 1] = r end
end
tech{ name = "me-fluid-storage", prerequisites = { "me-autocrafting" }, packs = 5, count = 600, recipes = ev }

--- IV: 256k fluid cells and drives
local iv = {}
for _, r in pairs({ drive_recipes("256k") }) do iv[#iv + 1] = r end
tech{ name = "me-fluid-storage-256k", prerequisites = { "me-fluid-storage", "me-storage-256k" },
	packs = 6, count = 800, recipes = iv }
