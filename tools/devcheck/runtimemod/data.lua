--- The runtime tests (control.lua) were written in Gregtorio Continued and name a few of its machines, items, fluids
--- and recipes: a gear recipe from plates and sticks, a macerator, chemical reactors and an extractor with fluid
--- recipes, an iron furnace with a dust recipe. Without Gregtorio this test mod adds stand-ins with the same names and
--- the same numbers (inputs, outputs, fluid boxes, sizes), so the same tests run on vanilla. With Gregtorio they run
--- on Gregtorio's own prototypes. The stand-ins are test fixtures, not part of me-network.
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
machine("ev-extractor", "assembling-machine", "chemical-plant", { "zz-extractor" }, 8)
machine("iron-furnace", "furnace", "stone-furnace", { "smelting" }, 2)
