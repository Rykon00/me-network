--- The recipe paste test (issue #12): recipes with more ingredients than the ME blocks hold, made of the first plain
--- items and fluids by name after every mod has changed its prototypes (so the fixture works with and without
--- Gregtorio). The game puts a recipe's ingredients in its own order (items first); the test reads that order. The
--- machine is in data.lua.
local items, fluids = {}, {}
local names = {}
for name in pairs(data.raw.item) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
	local p = data.raw.item[name]
	if #items < 20 and not p.hidden and not p.parameter and not p.spoil_ticks then items[#items + 1] = name end
end
names = {}
for name in pairs(data.raw.fluid) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
	local p = data.raw.fluid[name]
	if #fluids < 5 and not p.hidden and not p.parameter then fluids[#fluids + 1] = name end
end
local function recipe(name, n_items, n_fluids)
	local ingredients = {}
	for i = 1, n_items do ingredients[#ingredients + 1] = { type = "item", name = items[i], amount = 1 } end
	for i = 1, n_fluids do ingredients[#ingredients + 1] = { type = "fluid", name = fluids[i], amount = 1 } end
	data:extend({ {
		type = "recipe", name = name, category = "zz-devcheck-paste", energy_required = 1, enabled = false,
		ingredients = ingredients, results = { { type = "item", name = items[1], amount = 1 } },
		icon = "__base__/graphics/icons/signal/signal-info.png", subgroup = "intermediate-product",
	} })
end
recipe("zz-devcheck-paste-many", 20, 5)        -- more than the rows and filters of every block
recipe("zz-devcheck-paste-fluids", 2, 5)       -- more fluids than the interface's four sides

--- The provider scan test (me-network issue #50, lever 6, scan.lua): a recipe of the macerator's category whose research the
--- test takes and gives back (no other test uses it)
do
	local macerator = data.raw["assembling-machine"]["ev-macerator"]
	data:extend({ {
		type = "recipe", name = "zz-devcheck-scan", category = macerator and macerator.crafting_categories[1] or "crafting",
		energy_required = 1, enabled = false,
		ingredients = { { type = "item", name = "raw-iron", amount = 1 } }, results = { { type = "item", name = "crushed-iron", amount = 1 } },
		icon = "__base__/graphics/icons/signal/signal-info.png", subgroup = "intermediate-product",
	} })
end

--- issue #158 (providers.lua): a second recipe of the macerator's category (Gregtorio's or the stand-in of data.lua), so a
--- test can keep the machine busy on another recipe
do
	local m = data.raw["assembling-machine"]["ev-macerator"]
	local cat = m and m.crafting_categories and m.crafting_categories[1]
	if cat then
		data:extend({ { type = "recipe", name = "zz-devcheck-macerate-plate", category = cat, energy_required = 4, enabled = true,
			ingredients = { { type = "item", name = "iron-plate", amount = 1 } }, results = { { type = "item", name = "zz-devcheck-hot-token", amount = 1 } },
			icon = "__base__/graphics/icons/signal/signal-info.png", subgroup = "intermediate-product" } })
	end
end
