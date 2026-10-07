--- The runtime tests (control.lua) were written in Gregtorio Continued and name a few of its machines, items, fluids
--- and recipes: a gear recipe from plates and sticks, a macerator, chemical reactors and a fluid extractor with fluid
--- recipes, an iron furnace with a dust recipe. Without Gregtorio this test mod adds stand-ins with the same names and
--- the same numbers (inputs, outputs, fluid boxes, sizes), so the same tests run on vanilla. With Gregtorio they run
--- on Gregtorio's own prototypes. The stand-ins are test fixtures, not part of me-network.

--- a selection tool as other mods add them (the cursor test: a click with it opens no ME window); with Gregtorio too
data:extend({ { type = "selection-tool", name = "zz-devcheck-selection-tool", icon = "__base__/graphics/icons/blueprint.png",
	stack_size = 1, flags = { "only-in-cursor", "spawnable" },
	select = { border_color = { 1, 0, 0 }, cursor_box_type = "entity", mode = { "any-entity" } },
	alt_select = { border_color = { 0, 1, 0 }, cursor_box_type = "entity", mode = { "any-entity" } } } })

--- items that carry data of their own, as other mods add them (issue #76, storable.lua: the network refuses an item with
--- an inventory and an item with a label by their prototype type, each with a message of its own; the base game has
--- no prototype of either type); with Gregtorio too
data:extend({
	{ type = "item-with-inventory", name = "zz-devcheck-inventory-item", icon = "__base__/graphics/icons/blueprint.png",
		stack_size = 1, inventory_size = 4 },
	{ type = "item-with-label", name = "zz-devcheck-label-item", icon = "__base__/graphics/icons/blueprint.png", stack_size = 1 },
})

--- the recipe paste test (issue #12): a 3x3 machine with six fluid inputs for a recipe with more ingredients than any
--- ME block holds (data-final-fixes.lua); with Gregtorio too. Made here, so me-network's data-final-fixes.lua adds
--- the ME blocks to its pastable entities like it does for every other crafting machine.
do
	local m = table.deepcopy(data.raw["assembling-machine"]["assembling-machine-2"])
	m.name = "zz-devcheck-paste-machine"
	m.crafting_categories = { "zz-devcheck-paste" }
	m.minable = nil
	m.next_upgrade = nil
	m.fast_replaceable_group = nil
	m.fluid_boxes_off_when_no_fluid_recipe = false
	m.fluid_boxes = {}
	for i, pos in ipairs({ { -1, -1 }, { 0, -1 }, { 1, -1 }, { -1, 1 }, { 0, 1 }, { 1, 1 } }) do
		m.fluid_boxes[i] = { production_type = "input", volume = 1000, pipe_connections = { {
			flow_direction = "input", direction = pos[2] < 0 and defines.direction.north or defines.direction.south,
			position = pos } } }
	end
	data:extend({ { type = "recipe-category", name = "zz-devcheck-paste" }, m })
end

--- issue #159 (temperature.lua): fluid temperatures in recipes, which neither the base game nor Gregtorio has: a machine
--- (an assembling machine 2 of its own category, so it works with Gregtorio too) with a recipe that takes steam between
--- 200 and 600 °C, one that takes water between 50 and 100 °C, and one that makes steam at 300 °C
do
	local m = table.deepcopy(data.raw["assembling-machine"]["assembling-machine-2"])
	m.name = "zz-devcheck-hot-machine"
	m.crafting_categories = { "zz-devcheck-hot" }
	m.minable = nil
	m.next_upgrade = nil
	m.fast_replaceable_group = nil
	local icon = "__base__/graphics/icons/signal/signal-info.png"
	local function hot(name, ingredients, results)
		return { type = "recipe", name = name, category = "zz-devcheck-hot", energy_required = 1, enabled = true, icon = icon,
			subgroup = "intermediate-product", ingredients = ingredients, results = results }
	end
	data:extend({ { type = "recipe-category", name = "zz-devcheck-hot" }, m,
		{ type = "item", name = "zz-devcheck-hot-token", icon = icon, stack_size = 50, subgroup = "intermediate-product" },
		hot("zz-devcheck-hot-steam", { { type = "fluid", name = "steam", amount = 10, minimum_temperature = 200, maximum_temperature = 600 } },
			{ { type = "item", name = "zz-devcheck-hot-token", amount = 1 } }),
		hot("zz-devcheck-warm-water", { { type = "fluid", name = "water", amount = 10, minimum_temperature = 50, maximum_temperature = 100 } },
			{ { type = "item", name = "zz-devcheck-hot-token", amount = 1 } }),
		hot("zz-devcheck-heat-steam", { { type = "fluid", name = "water", amount = 10 } },
			{ { type = "fluid", name = "steam", amount = 10, temperature = 300 } }) })
end

--- issue #158 (providers.lua): a machine with a fixed recipe and a second recipe of its category
do
	local m = table.deepcopy(data.raw["assembling-machine"]["assembling-machine-2"])
	m.name = "zz-devcheck-fixed-machine"
	m.crafting_categories = { "zz-devcheck-fixed" }
	m.fixed_recipe = "zz-devcheck-fixed"
	m.minable = nil
	m.next_upgrade = nil
	m.fast_replaceable_group = nil
	local icon = "__base__/graphics/icons/signal/signal-info.png"
	local function r(name)
		return { type = "recipe", name = name, category = "zz-devcheck-fixed", energy_required = 1, enabled = true, icon = icon,
			subgroup = "intermediate-product", ingredients = { { type = "item", name = "iron-plate", amount = 1 } },
			results = { { type = "item", name = "zz-devcheck-hot-token", amount = 1 } } }
	end
	data:extend({ { type = "recipe-category", name = "zz-devcheck-fixed" }, m, r("zz-devcheck-fixed"), r("zz-devcheck-unfixed") })
end

if mods["gregtorio-continued"] then return end

local ICON = "__base__/graphics/icons/signal/signal-info.png"
local function item(name)
	if data.raw.item[name] then return end
	data:extend({ { type = "item", name = name, icon = ICON, stack_size = 200, subgroup = "intermediate-product" } })
end
local function fluid(name)
	if data.raw.fluid[name] then return end
	data:extend({ { type = "fluid", name = name, icon = ICON, default_temperature = 15, base_color = { 0.5, 0.5, 0.5 },
		flow_color = { 0.7, 0.7, 0.7 } } })
end
local function category(name)
	if not data.raw["recipe-category"][name] then data:extend({ { type = "recipe-category", name = name } }) end
end
local function I(name, amount) return { type = "item", name = name, amount = amount } end
local function F(name, amount) return { type = "fluid", name = name, amount = amount } end
local function recipe(name, cat, time, ingredients, results)
	data:extend({ { type = "recipe", name = name, category = cat, energy_required = time, enabled = false,
		ingredients = ingredients, results = results, icon = ICON, subgroup = "intermediate-product" } })
end
local function machine(name, base_type, base, categories, speed)
	local e = table.deepcopy(data.raw[base_type][base])
	e.name = name
	e.crafting_categories = categories
	e.crafting_speed = speed
	e.minable = { mining_time = 0.2, result = name }
	e.next_upgrade = nil
	e.fast_replaceable_group = nil
	data:extend({ e, { type = "item", name = name, icon = ICON, stack_size = 50, place_result = name,
		subgroup = "intermediate-product" } })
end

for _, n in pairs({ "raw-iron", "crushed-iron", "iron-dust", "iron-ingot", "tin-ingot", "raw-silicon",
	"resin-circuit-board", "phenolic-circuit-board" }) do item(n) end
for _, n in pairs({ "chlorine", "hydrogen", "phenol", "silicon-tetrachloride", "molten-tin", "hydrochloric-acid" }) do fluid(n) end
for _, c in pairs({ "zz-macerator", "zz-chemical-reactor", "zz-extractor" }) do category(c) end

--- Gregtorio's gear recipe (crafting table): 1 plate + 2 sticks -> 1 gear, a hand recipe the molecular assembler
--- also makes
recipe("iron-gear-crafting-table", "crafting", 1, { I("iron-plate", 1), I("iron-stick", 2) }, { I("iron-gear-wheel", 1) })
recipe("crushed-iron", "zz-macerator", 20, { I("raw-iron", 1) }, { I("crushed-iron", 2) })
recipe("iron-dust-smelter", "smelting", 10, { I("iron-dust", 1) }, { I("iron-ingot", 1) })
recipe("silicon-tetrachloride", "zz-chemical-reactor", 3, { I("raw-silicon", 1), F("chlorine", 400) }, { F("silicon-tetrachloride", 100) })
recipe("molten-tin", "zz-extractor", 1.2, { I("tin-ingot", 1) }, { F("molten-tin", 14.4) })
recipe("phenolic-circuit-board", "zz-chemical-reactor", 5, { I("resin-circuit-board", 1), F("phenol", 10) }, { I("phenolic-circuit-board", 1) })
recipe("hydrochloric-acid", "zz-chemical-reactor", 3, { F("chlorine", 100), F("hydrogen", 100) }, { F("hydrochloric-acid", 100) })

--- 3x3 machines like Gregtorio's (two fluid inputs and outputs: the chemical plant), a 2x2 burner furnace
machine("ev-macerator", "assembling-machine", "assembling-machine-2", { "zz-macerator" }, 8)
machine("hv-chemical-reactor", "assembling-machine", "chemical-plant", { "zz-chemical-reactor" }, 4)
machine("ev-fluid-extractor", "assembling-machine", "chemical-plant", { "zz-extractor" }, 8)   -- Gregtorio issue #152
machine("iron-furnace", "furnace", "stone-furnace", { "smelting" }, 2)
