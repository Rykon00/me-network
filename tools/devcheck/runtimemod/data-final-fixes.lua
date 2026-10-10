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
--- issue #157: one craft needs more of a fluid than an interface side holds (5000)
data:extend({ { type = "recipe", name = "zz-devcheck-paste-big", category = "zz-devcheck-paste", energy_required = 1, enabled = false,
	ingredients = { { type = "item", name = items[1], amount = 3 }, { type = "fluid", name = fluids[1], amount = 6000 } },
	results = { { type = "item", name = items[1], amount = 1 } },
	icon = "__base__/graphics/icons/signal/signal-info.png", subgroup = "intermediate-product" } })
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

--- me-network issue #267: the drive's cell lights are hidden entities whose picture variations sit where the render objects
--- of before sat (me-network's own view): bay 1's light covered (-0.341796875, -0.3681640625) .. (-0.130859375,
--- -0.3154296875) tiles, at 64 px a tile 13.5 x 3.375 px, i.e. 108 x 27 px of the white square at scale 1/16. The
--- lights are above the cells, both above the drive's picture at its position (secondary_draw_order), y-sorted with it.
do
	local light, cell = data.raw["simple-entity-with-force"]["me-drive-light"], data.raw["simple-entity-with-force"]["me-drive-cell"]
	local function near(a, b) return math.abs(a - b) < 1e-6 end
	local p = light and light.pictures and light.pictures[1]
	local ok = p and p.width == 108 and p.height == 27 and near(p.scale, 1 / 16)
		and near(p.shift[1], (-0.341796875 - 0.130859375) / 2) and near(p.shift[2], (-0.3681640625 - 0.3154296875) / 2)
		and #light.pictures == 40 and light.secondary_draw_order == 2 and light.render_layer == "object"
		and cell and #cell.pictures == 20 and cell.secondary_draw_order == 1
		and data.raw["simple-entity-with-force"]["me-chest-light"] and #data.raw["simple-entity-with-force"]["me-chest-light"].pictures == 4
	if not ok then
		error("devcheck (issue #267): the drive's light parts are not where the lights were: " .. serpent.line(p)
			.. " pictures " .. tostring(light and light.pictures and #light.pictures) .. " cell " .. tostring(cell and #cell.pictures))
	end
end
