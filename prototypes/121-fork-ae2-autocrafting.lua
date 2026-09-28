--------------------------------------------------------------------------------
--- FORK AE2: AUTOCRAFTING (side quest, on top of the ME network from 120-fork-ae2.lua)
---   * Molecular Assembler = assembling machine for item-only crafting recipes. Set its
---                           recipe like any assembler; the recipe becomes a pattern.
---   * Pattern Provider    = small entity placed next to ANY machine (GT machine, furnace,
---                           Molecular Assembler). The recipe that machine has set becomes a
---                           pattern of the ME network the provider stands in.
---   * Crafting CPU        = powered entity of the ME network, runs one crafting job at a time.
---   * The planning and item moving is done by scripts/fork-me-autocraft.lua, the GUI is part of
---     the ME Terminal (scripts/fork-me-terminal.lua).
--- Sprites and icons: tools/gen_ae2_sprites.py.
--------------------------------------------------------------------------------

local ENTITY_PATH = "__Gregtorio__/graphics/entity/fork/ae2/"
local ICON_FORK = ICON_PATH .. "fork/"

--------------------------------------------------------------------------------
--- ITEMS AND RECIPES
--------------------------------------------------------------------------------

local function move_to(item_name, order)
	local item = data.raw.item[item_name]
	item.subgroup = "fork-me-network"
	item.order = order
	local recipe = data.raw.recipe[item_name]
	recipe.subgroup = "fork-me-network"
	recipe.order = order
end

create_item{
	name = "me-pattern-provider",
	icon = ICON_FORK .. "me-pattern-provider.png",
	category = "hv-assembling-machine-recipes",
	subgroup = "fork-me-network",
	order = "e",
	energy_required = 10 * HV_SPEED,
	stack_size = 50,
	place_result = "me-pattern-provider",
	ingredients = {
		{ type = "item", name = "me-interface", amount = 1 },
		{ type = "item", name = "engineering-processor", amount = 2 },
		{ type = "item", name = "fluix-cable", amount = 4 },
		{ type = "item", name = "hv-emitter", amount = 1 },
	},
}

create_item{
	name = "me-molecular-assembler",
	icon = ICON_FORK .. "me-molecular-assembler.png",
	category = "hv-assembling-machine-recipes",
	subgroup = "fork-me-network",
	order = "f",
	energy_required = 10 * HV_SPEED,
	stack_size = 10,
	place_result = "me-molecular-assembler",
	ingredients = {
		{ type = "item", name = "hv-machine-hull", amount = 1 },
		{ type = "item", name = "hv-robot-arm", amount = 2 },
		{ type = "item", name = "hv-emitter", amount = 1 },
		{ type = "item", name = "engineering-processor", amount = 2 },
		{ type = "item", name = "fluix-cable", amount = 4 },
	},
}

create_item{
	name = "me-crafting-cpu",
	icon = ICON_FORK .. "me-crafting-cpu.png",
	category = "ev-assembling-machine-recipes",
	subgroup = "fork-me-network",
	order = "g",
	energy_required = 10 * EV_SPEED,
	stack_size = 10,
	place_result = "me-crafting-cpu",
	ingredients = {
		{ type = "item", name = "ev-machine-hull", amount = 1 },
		{ type = "item", name = "me-controller", amount = 1 },
		{ type = "item", name = "me-64k-storage-cell", amount = 2 },
		{ type = "item", name = "processing-unit", amount = 4 },
		{ type = "item", name = "fluix-cable", amount = 8 },
	},
}



--------------------------------------------------------------------------------
--- PATTERN PROVIDER (passive marker, no power: it only tells the network which machine to use)
--------------------------------------------------------------------------------

data:extend({ {
	type = "simple-entity-with-force",
	name = "me-pattern-provider",
	icon = ICON_FORK .. "me-pattern-provider.png",
	icon_size = 32,
	flags = { "placeable-neutral", "player-creation" },
	minable = { mining_time = 0.2, result = "me-pattern-provider" },
	max_health = 150,
	corpse = "small-remnants",
	collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } },
	selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
	selection_priority = 60,
	picture = {
		filename = ENTITY_PATH .. "me-pattern-provider.png",
		priority = "extra-high",
		width = 32, height = 32,
	},
	localised_description = { "entity-description.me-pattern-provider" },
} })



--------------------------------------------------------------------------------
--- MOLECULAR ASSEMBLER (item recipes only, so no fluid boxes; crafts like an EV assembler)
--------------------------------------------------------------------------------

local assembler = table.deepcopy(data.raw["assembling-machine"]["hv-assembling-machine"])
assembler.name = "me-molecular-assembler"
assembler.icon = ICON_FORK .. "me-molecular-assembler.png"
assembler.icon_size = 32
assembler.minable = { mining_time = 0.5, result = "me-molecular-assembler" }
assembler.fast_replaceable_group = nil
assembler.next_upgrade = nil
assembler.crafting_categories = {
	"crafting-or-assembling-recipes", "crafting-table-recipes",
	"lv-assembling-machine-recipes", "mv-assembling-machine-recipes",
	"hv-assembling-machine-recipes", "ev-assembling-machine-recipes",
}
assembler.crafting_speed = 6
assembler.energy_usage = EU12_HV
assembler.fluid_boxes = nil
assembler.fluid_boxes_off_when_no_fluid_recipe = nil
assembler.graphics_set = {
	idle_animation = { layers = { {
		filename = ENTITY_PATH .. "me-molecular-assembler-idle.png",
		width = 96, height = 96, frame_count = 1, repeat_count = 4, shift = { 0, 0 },
	} } },
	animation = { layers = { {
		filename = ENTITY_PATH .. "me-molecular-assembler-working.png",
		width = 96, height = 96, frame_count = 4, line_length = 1, animation_speed = 0.3, shift = { 0, 0 },
	} } },
}
assembler.localised_description = { "entity-description.me-molecular-assembler" }
data:extend({ assembler })



--------------------------------------------------------------------------------
--- CRAFTING CPU (2x2 lamp like the ME Terminal: needs power, shows "no power" otherwise)
--------------------------------------------------------------------------------

local cpu = table.deepcopy(data.raw.lamp["small-lamp"])
cpu.name = "me-crafting-cpu"
cpu.icon = ICON_FORK .. "me-crafting-cpu.png"
cpu.icon_size = 32
cpu.minable = { mining_time = 0.3, result = "me-crafting-cpu" }
cpu.max_health = 300
cpu.corpse = "small-remnants"
cpu.dying_explosion = nil
cpu.collision_box = { { -0.8, -0.8 }, { 0.8, 0.8 } }
cpu.selection_box = { { -1, -1 }, { 1, 1 } }
cpu.energy_usage_per_tick = "60kW"
cpu.always_on = true
cpu.light = nil
cpu.light_when_colored = nil
cpu.picture_off = { layers = { {
	filename = ENTITY_PATH .. "me-crafting-cpu-off.png",
	priority = "high", width = 64, height = 64,
} } }
cpu.picture_on = {
	filename = ENTITY_PATH .. "me-crafting-cpu-on.png",
	priority = "high", width = 64, height = 64,
}
cpu.fast_replaceable_group = nil
cpu.next_upgrade = nil
cpu.localised_description = { "entity-description.me-crafting-cpu" }
data:extend({ cpu })



--------------------------------------------------------------------------------
--- TECHNOLOGY (EV: the CPU needs 64k cells)
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

local effects = {}
for _, r in pairs({ "me-pattern-provider", "me-molecular-assembler", "me-crafting-cpu" }) do
	effects[#effects + 1] = { type = "unlock-recipe", recipe = r }
	data.raw.recipe[r].enabled = false
end
data:extend({ {
	type = "technology",
	name = "me-autocrafting",
	icon = "__Gregtorio__/graphics/technology/fork/me-autocrafting.png",
	icon_size = 256,
	effects = effects,
	prerequisites = { "me-storage-64k" },
	unit = { count = 600, ingredients = sci(5), time = 30 },
} })
