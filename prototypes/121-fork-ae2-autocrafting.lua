--------------------------------------------------------------------------------
--- FORK AE2: AUTOCRAFTING (side quest, on top of the ME network from 120-fork-ae2.lua)
---   * Molecular Assembler = assembling machine for item-only crafting recipes. Set its
---                           recipe like any assembler; the recipe becomes a pattern.
---   * Pattern Provider    = small ME block placed next to ANY machine (GT machine, furnace,
---                           Molecular Assembler). The recipe that machine has set becomes a
---                           pattern of the ME network the provider is connected to.
---   * Crafting CPU        = powered entity of the ME network, runs one crafting job at a time.
---                           Two bigger tiers (issue #38) run more jobs at once and move more
---                           items per step: Co-Processing (IV) and Quantum (LuV) Crafting CPU.
---   * Level Maintainer    = powered 1x1 block that keeps N of an item or fluid in stock: it starts
---                           a crafting job for the difference (issue #38). Its lamp circuit
---                           condition switches it on and off.
---   * Circuit Interface   = constant combinator that puts the items and fluids of its ME network
---                           (all, or a filtered set) onto the circuit wire (issue #38).
---   * The planning and item moving is done by scripts/fork-me-autocraft.lua, the GUI is part of
---     the ME Terminal (scripts/fork-me-terminal.lua); maintainer and circuit interface live in
---     scripts/fork-me-circuit.lua. CPU tier numbers go to the runtime through the mod-data
---     "fork-me-autocraft".
--- Sprites and icons: tools/gen_ae2_sprites.py.
--------------------------------------------------------------------------------

local ENTITY_PATH = "__gregtorio-continued__/graphics/entity/fork/ae2/"
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
		{ type = "item", name = "me-64k-storage-component", amount = 2 },     -- issue #68: cells carry contents, components do not
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
cpu.fast_replaceable_group = "me-crafting-cpu"
cpu.next_upgrade = "me-co-processing-cpu"
cpu.localised_description = { "entity-description.me-crafting-cpu" }
data:extend({ cpu })



--------------------------------------------------------------------------------
--- CPU TIERS (issue #38): the same 2x2 block, more jobs at once and more machine hand-overs per
--- step. Upgrade planner and fast replace swap the tiers (a job on a replaced CPU pauses and goes on
--- on the next free one).
--------------------------------------------------------------------------------

--- name -> parallel jobs, speed (machine hand-overs per step, times the base CPU's), power, tier of the sprite
local CPU_TIERS = {
	{ name = "me-crafting-cpu",         jobs = 1, speed = 1, power = "60kW" },
	{ name = "me-co-processing-cpu",    jobs = 2, speed = 2, power = "240kW", next = "me-quantum-crafting-cpu" },
	{ name = "me-quantum-crafting-cpu", jobs = 4, speed = 4, power = "960kW" },
}

for i, t in ipairs(CPU_TIERS) do
	if i > 1 then
		local e = table.deepcopy(cpu)
		e.name = t.name
		e.icon = ICON_FORK .. t.name .. ".png"
		e.minable = { mining_time = 0.3, result = t.name }
		e.energy_usage_per_tick = t.power
		e.picture_off = { layers = { {
			filename = ENTITY_PATH .. t.name .. "-off.png",
			priority = "high", width = 64, height = 64,
		} } }
		e.picture_on = {
			filename = ENTITY_PATH .. t.name .. "-on.png",
			priority = "high", width = 64, height = 64,
		}
		e.next_upgrade = t.next
		e.localised_description = { "entity-description.fork-me-crafting-cpu-tier", tostring(t.jobs), tostring(t.speed) }
		data:extend({ e })
	end
end

create_item{
	name = "me-co-processing-cpu",
	icon = ICON_FORK .. "me-co-processing-cpu.png",
	category = "iv-assembling-machine-recipes",
	subgroup = "fork-me-network",
	order = "g2",
	energy_required = 10 * IV_SPEED,
	stack_size = 10,
	place_result = "me-co-processing-cpu",
	ingredients = {
		{ type = "item", name = "me-crafting-cpu", amount = 1 },
		{ type = "item", name = "iv-machine-hull", amount = 1 },
		{ type = "item", name = "me-256k-storage-component", amount = 2 },
		{ type = "item", name = "acceleration-card", amount = 4 },
		{ type = "item", name = "iv-circuit", amount = 4 },
		{ type = "item", name = "fluix-cable", amount = 16 },
	},
}

create_item{
	name = "me-quantum-crafting-cpu",
	icon = ICON_FORK .. "me-quantum-crafting-cpu.png",
	category = "luv-assembling-machine-recipes",
	subgroup = "fork-me-network",
	order = "g3",
	energy_required = 10 * LUV_SPEED,
	stack_size = 10,
	place_result = "me-quantum-crafting-cpu",
	ingredients = {
		{ type = "item", name = "me-co-processing-cpu", amount = 1 },
		{ type = "item", name = "luv-machine-hull", amount = 1 },
		{ type = "item", name = "luv-emitter", amount = 2 },
		{ type = "item", name = "acceleration-card", amount = 8 },
		{ type = "item", name = "luv-circuit", amount = 4 },
		{ type = "item", name = "fluix-cable", amount = 32 },
	},
}

local cpu_data = {}
for _, t in ipairs(CPU_TIERS) do cpu_data[t.name] = { jobs = t.jobs, speed = t.speed } end



--------------------------------------------------------------------------------
--- LEVEL MAINTAINER (issue #38): keeps N of an item or fluid in stock. A 1x1 lamp like the ME
--- Terminal: needs power, and the lamp's circuit condition (kept on the entity, so the game copies and
--- blueprints it) switches it on and off. Target, amount and the condition are set in its ME window
--- (scripts/fork-me-windows.lua), which replaces the lamp's window.
--------------------------------------------------------------------------------

create_item{
	name = "me-level-maintainer",
	icon = ICON_FORK .. "me-level-maintainer.png",
	category = "ev-assembling-machine-recipes",
	subgroup = "fork-me-network",
	order = "g4",
	energy_required = 10 * EV_SPEED,
	stack_size = 50,
	place_result = "me-level-maintainer",
	ingredients = {
		{ type = "item", name = "me-interface", amount = 1 },
		{ type = "item", name = "ev-sensor", amount = 1 },
		{ type = "item", name = "ev-circuit", amount = 2 },
		{ type = "item", name = "fluix-cable", amount = 4 },
	},
}

local maintainer = table.deepcopy(data.raw.lamp["small-lamp"])
maintainer.name = "me-level-maintainer"
maintainer.icon = ICON_FORK .. "me-level-maintainer.png"
maintainer.icon_size = 32
maintainer.minable = { mining_time = 0.2, result = "me-level-maintainer" }
maintainer.max_health = 200
maintainer.corpse = "small-remnants"
maintainer.dying_explosion = nil
maintainer.collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } }
maintainer.selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } }
maintainer.energy_usage_per_tick = "30kW"
maintainer.always_on = true
maintainer.light = nil
maintainer.light_when_colored = nil
maintainer.picture_off = { layers = { {
	filename = ENTITY_PATH .. "me-level-maintainer-off.png",
	priority = "high", width = 32, height = 32,
} } }
maintainer.picture_on = {
	filename = ENTITY_PATH .. "me-level-maintainer-on.png",
	priority = "high", width = 32, height = 32,
}
maintainer.fast_replaceable_group = nil
maintainer.next_upgrade = nil
maintainer.localised_description = { "entity-description.me-level-maintainer" }
data:extend({ maintainer })



--------------------------------------------------------------------------------
--- CIRCUIT INTERFACE (issue #38): a constant combinator whose signals the runtime writes: the
--- items and fluids of its ME network, or the filtered ones. No power (like the pattern provider).
--------------------------------------------------------------------------------

create_item{
	name = "me-circuit-interface",
	icon = ICON_FORK .. "me-circuit-interface.png",
	category = "hv-assembling-machine-recipes",
	subgroup = "fork-me-network",
	order = "g5",
	energy_required = 10 * HV_SPEED,
	stack_size = 50,
	place_result = "me-circuit-interface",
	ingredients = {
		{ type = "item", name = "me-interface", amount = 1 },
		{ type = "item", name = "constant-combinator", amount = 1 },
		{ type = "item", name = "ev-sensor", amount = 1 },
		{ type = "item", name = "engineering-processor", amount = 2 },
		{ type = "item", name = "fluix-cable", amount = 4 },
	},
}

local circuit = table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
circuit.name = "me-circuit-interface"
circuit.icon = ICON_FORK .. "me-circuit-interface.png"
circuit.icon_size = 32
circuit.icons = nil
circuit.minable = { mining_time = 0.2, result = "me-circuit-interface" }
circuit.max_health = 200
circuit.corpse = "small-remnants"
circuit.dying_explosion = nil
circuit.sprites = {
	filename = ENTITY_PATH .. "me-circuit-interface.png",
	priority = "high", width = 32, height = 32,
}
circuit.fast_replaceable_group = nil
circuit.next_upgrade = nil
circuit.localised_description = { "entity-description.me-circuit-interface" }
data:extend({ circuit })



--------------------------------------------------------------------------------
--- MOD DATA (read by scripts/fork-me-autocraft.lua: no duplicated numbers)
--------------------------------------------------------------------------------

data:extend({ {
	type = "mod-data",
	name = "fork-me-autocraft",
	data = { cpus = cpu_data },
} })



--------------------------------------------------------------------------------
--- TECHNOLOGY (EV: the CPU needs 64k cells)
--------------------------------------------------------------------------------

local function sci(n)
	local packs = { "automation-science-pack", "logistic-science-pack", "military-science-pack",
		"chemical-science-pack", "production-science-pack", "utility-science-pack", "space-science-pack" }
	local amounts = { SP07, SP06, SP05, SP04, SP03, SP02, SP01 }
	local out = {}
	for i = 1, n do
		out[#out + 1] = { packs[i], amounts[#amounts - n + i] }
	end
	return out
end

local function tech(name, recipes, prerequisites, packs, count)
	local effects = {}
	for _, r in pairs(recipes) do
		effects[#effects + 1] = { type = "unlock-recipe", recipe = r }
		data.raw.recipe[r].enabled = false
	end
	data:extend({ {
		type = "technology",
		name = name,
		icon = "__gregtorio-continued__/graphics/technology/fork/" .. name .. ".png",
		icon_size = 256,
		effects = effects,
		prerequisites = prerequisites,
		unit = { count = count, ingredients = sci(packs), time = 30 },
	} })
end

tech("me-autocrafting", { "me-pattern-provider", "me-molecular-assembler", "me-crafting-cpu" }, { "me-storage-64k" }, 5, 600)

--- issue #38: level maintainer and circuit interface (EV, like the autocrafting they drive), bigger CPUs
--- at IV (256k cells and acceleration cards, IV components) and LuV (LuV components and hull)
tech("me-automation", { "me-level-maintainer", "me-circuit-interface" }, { "me-autocrafting", "circuit-network" }, 5, 800)
tech("me-co-processing", { "me-co-processing-cpu" }, { "me-autocrafting", "me-storage-256k", "iv-components" }, 6, 1200)
tech("me-quantum-crafting", { "me-quantum-crafting-cpu" }, { "me-co-processing", "luv-machines" }, 7, 1500)
