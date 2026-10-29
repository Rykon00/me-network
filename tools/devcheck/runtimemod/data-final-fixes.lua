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
		type = "recipe", name = name, categories = { "zz-devcheck-paste" }, energy_required = 1, enabled = false,
		ingredients = ingredients, results = { { type = "item", name = items[1], amount = 1 } },
		icon = "__base__/graphics/icons/signal/signal-info.png", subgroup = "intermediate-product",
	} })
end
recipe("zz-devcheck-paste-many", 20, 5)        -- more than the rows and filters of every block
--- issue #157: one craft needs more of a fluid than an interface side holds (5000)
data:extend({ { type = "recipe", name = "zz-devcheck-paste-big", categories = { "zz-devcheck-paste" }, energy_required = 1, enabled = false,
	ingredients = { { type = "item", name = items[1], amount = 3 }, { type = "fluid", name = fluids[1], amount = 6000 } },
	results = { { type = "item", name = items[1], amount = 1 } },
	icon = "__base__/graphics/icons/signal/signal-info.png", subgroup = "intermediate-product" } })
recipe("zz-devcheck-paste-fluids", 2, 5)       -- more fluids than the interface's four sides

--- Issue #588: since Gregtorio #612 its gear recipe `iron-gear-crafting-table`, the one the autocrafting tests craft, also uses
--- up a charge of GT crafting tools (the items `hammer-usage`, `wire-cutter-usage`; Gregtorio's FORK_TOOLS). The tests check
--- autocrafting, not Gregtorio's tools: the recipe keeps its plate and sticks, as the stand-in of data.lua has it.
do
	local r = data.raw.recipe["iron-gear-crafting-table"]
	local tools = {}
	for _, usage in pairs(type(FORK_TOOLS) == "table" and FORK_TOOLS or {}) do tools[usage] = true end
	if r and r.ingredients then
		for i = #r.ingredients, 1, -1 do
			local name = r.ingredients[i].name or r.ingredients[i][1]
			if tools[name] or (type(name) == "string" and name:match("%-usage$")) then table.remove(r.ingredients, i) end
		end
	end
end

--- Issue #588: the fluid tests (the fluid jobs, the unified I/O, the recipe paste, the interface keeping one craft) take
--- Gregtorio's phenolic circuit board as their chemical reactor recipe of an item and a fluid: a resin board and 10 phenol.
--- Gregtorio #712 made it GT New Horizons' assembler recipe (wood pulp and glue); in the tests it keeps the reactor recipe,
--- in the categories of Gregtorio's silicon tetrachloride (the same reactors), as the stand-in of data.lua has it.
do
	local r, sic = data.raw.recipe["phenolic-circuit-board"], data.raw.recipe["silicon-tetrachloride"]
	local has_phenol = false
	for _, ing in pairs(r and r.ingredients or {}) do
		if ing.name == "phenol" then has_phenol = true end
	end
	if r and sic and not has_phenol and data.raw.item["resin-circuit-board"] and data.raw.fluid["phenol"] then
		r.categories = sic.categories or { sic.category }
		r.category = nil
		r.energy_required = 5
		r.ingredients = { { type = "item", name = "resin-circuit-board", amount = 1 }, { type = "fluid", name = "phenol", amount = 10 } }
		r.results = { { type = "item", name = "phenolic-circuit-board", amount = 1 } }
		r.main_product = "phenolic-circuit-board"
	end
end

--- Gregtorio issue #560: Gregtorio's ore machines are furnaces since its 0.5.9 (they pick the recipe from their input, none
--- is set). The tests that need a GT machine whose recipe is set (the autocraft test, scan.lua, providers.lua) take
--- `zz-devcheck-macerator`, an assembling machine with the EV macerator's categories, speed and graphics (Gregtorio's, or
--- the stand-in of data.lua); the furnace cases keep the iron furnace.
do
	local src = data.raw["assembling-machine"]["ev-macerator"] or data.raw.furnace["ev-macerator"]
	if src then
		local m = table.deepcopy(src)
		m.type, m.name = "assembling-machine", "zz-devcheck-macerator"
		m.source_inventory_size, m.result_inventory_size, m.cant_insert_at_source_message_key = nil, nil, nil
		m.minable = { mining_time = 0.2, result = "zz-devcheck-macerator" }
		m.next_upgrade, m.fast_replaceable_group = nil, nil
		m.localised_name = src.localised_name or { "entity-name.ev-macerator" }
		data:extend({ m, { type = "item", name = "zz-devcheck-macerator", localised_name = m.localised_name,
			icon = "__base__/graphics/icons/signal/signal-info.png", stack_size = 50, place_result = "zz-devcheck-macerator",
			subgroup = "intermediate-product" } })
	end
end

--- The provider scan test (me-network issue #50, lever 6, scan.lua): a recipe of the macerator's category whose research the
--- test takes and gives back (no other test uses it)
do
	local macerator = data.raw["assembling-machine"]["zz-devcheck-macerator"]
	data:extend({ {
		type = "recipe", name = "zz-devcheck-scan", categories = { macerator and macerator.crafting_categories[1] or "crafting" },
		energy_required = 1, enabled = false,
		ingredients = { { type = "item", name = "raw-iron", amount = 1 } }, results = { { type = "item", name = "crushed-iron", amount = 1 } },
		icon = "__base__/graphics/icons/signal/signal-info.png", subgroup = "intermediate-product",
	} })
end

--- issue #158 (providers.lua): a second recipe of the macerator's category (Gregtorio's or the stand-in of data.lua), so a
--- test can keep the machine busy on another recipe
do
	local m = data.raw["assembling-machine"]["zz-devcheck-macerator"]
	local cat = m and m.crafting_categories and m.crafting_categories[1]
	if cat then
		data:extend({ { type = "recipe", name = "zz-devcheck-macerate-plate", categories = { cat }, energy_required = 4, enabled = true,
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

--- me-network issue #278: the controller's part from the controller view (runtimemod/data.lua's stand-ins): one animation
--- per state, above the controller's picture at its position, y-sorted with it
do
	local c = data.raw["simple-entity-with-force"]["me-controller-light"]
	if not (c and c.animations and #c.animations == 3 and c.secondary_draw_order == 1 and c.render_layer == "object"
		and c.hidden and not c.selectable_in_game) then
		error("devcheck (issue #278): the controller's part is not made from the controller view: "
			.. serpent.line(c and { c.animations and #c.animations, c.secondary_draw_order, c.render_layer }))
	end
end

--- me-network issue #282: each direction of a bus is its picture and, above it, its marker (plate and arrows) on the
--- picture's face (me-network's own bus view: 58 px at the top left, scale 0.5)
do
	local bad = {}
	for _, name in pairs({ "me-import-bus", "me-export-bus", "me-storage-bus" }) do
		local e = data.raw["simple-entity-with-force"][name]
		for _, dir in pairs({ "north", "east", "south", "west" }) do
			local l = e and e.picture and e.picture[dir] and e.picture[dir].layers
			local m = l and l[2]
			local base = "/" .. name .. "-" .. dir
			if not (l and #l == 2 and l[1].filename:sub(-#base - 4) == base .. ".png" and m.filename:sub(-#base - 11) == base .. "-marker.png"
				and m.width == 58 and math.abs(m.scale - 0.5) < 1e-9 and math.abs(m.shift[1] + 0.046875) < 1e-9
				and math.abs(m.shift[2] + 0.046875) < 1e-9) then
				bad[#bad + 1] = name .. " " .. dir .. ": " .. serpent.line(l)
			end
		end
	end
	if #bad > 0 then error("devcheck (issue #282): the buses' marker layers: " .. table.concat(bad, "; ")) end
end

--- issue #480 (tagcraft.lua): autocrafting of the item with tags `zz-devcheck-tagged-wall` (data.lua): a recipe that makes it
--- from an iron plate and one that makes a plain item of its own from two, in the first category of the ME Molecular
--- Assembler as every mod has left it (vanilla: crafting; Gregtorio rebuilds the assembler with its own categories)
do
	local ma = data.raw["assembling-machine"]["me-molecular-assembler"]
	local cat = ma and ma.crafting_categories and ma.crafting_categories[1] or "crafting"
	local icon = "__base__/graphics/icons/wall.png"
	data:extend({
		{ type = "item", name = "zz-devcheck-tagged-post", icon = icon, stack_size = 50, subgroup = "intermediate-product" },
		{ type = "recipe", name = "zz-devcheck-tagged-wall", categories = { cat }, energy_required = 0.5, enabled = true, icon = icon,
			subgroup = "intermediate-product", ingredients = { { type = "item", name = "iron-plate", amount = 1 } },
			results = { { type = "item", name = "zz-devcheck-tagged-wall", amount = 1 } } },
		{ type = "recipe", name = "zz-devcheck-tagged-post", categories = { cat }, energy_required = 0.5, enabled = true, icon = icon,
			subgroup = "intermediate-product", ingredients = { { type = "item", name = "zz-devcheck-tagged-wall", amount = 2 } },
			results = { { type = "item", name = "zz-devcheck-tagged-post", amount = 1 } } },
	})
end

--- me-network issue #557: a fast recipe of the ME Molecular Assembler (a plate into a gear in a tenth of a second), in its first
--- crafting category, so that a machine finishes 16 crafts long before a job's next step (fastcraft.lua)
local ma = data.raw["assembling-machine"]["me-molecular-assembler"]
if ma and ma.crafting_categories and ma.crafting_categories[1] then
	data:extend({ {
		type = "recipe", name = "zz-devcheck-fast-gear", categories = { ma.crafting_categories[1] }, energy_required = 0.1,
		enabled = false, ingredients = { { type = "item", name = "iron-plate", amount = 1 } },
		results = { { type = "item", name = "iron-gear-wheel", amount = 1 } },
		icon = "__base__/graphics/icons/signal/signal-info.png", subgroup = "intermediate-product",
	} })
end
