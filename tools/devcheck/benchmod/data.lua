--- Test fixture of the benchmark (never part of me-network): a container with as many slots as the warehouses of
--- storage mods, for the profile of a storage bus on a big chest.
local chest = table.deepcopy(data.raw.container["steel-chest"])
chest.name = "zz-bench-warehouse"
chest.inventory_size = 800
chest.minable = nil
chest.next_upgrade = nil
chest.fast_replaceable_group = nil
data:extend({ chest })

--- a tank of 1 000 000 units: the source and sink of the fluid capacity probes
local tank = table.deepcopy(data.raw["storage-tank"]["storage-tank"])
tank.name = "zz-bench-big-tank"
tank.fluid_box.volume = 1000000
tank.minable = nil
tank.next_upgrade = nil
tank.fast_replaceable_group = nil
data:extend({ tank })

--- issue #639: a roboport without collision (placed on a bus's tile in the dense scene; unpowered it has the 25 tiles of
--- logistic area whatever its prototype says, measured): the logistic condition of `conditions`
local port = table.deepcopy(data.raw.roboport.roboport)
port.name = "zz-bench-roboport"
port.collision_mask = { layers = {} }
port.collision_box = { { -0.1, -0.1 }, { 0.1, 0.1 } }
port.selection_box = { { -0.1, -0.1 }, { 0.1, 0.1 } }
port.selectable_in_game = false
port.minable = nil
port.next_upgrade = nil
port.fast_replaceable_group = nil
data:extend({ port })

--- issue #752: the recipes of the feed scene, a tenth of a second each in an assembling machine: a plate from water (a
--- crafting pattern with a fluid), a gear from a plate (items only), a stick from a gear (a processing pattern). Factorio
--- 2.0 names a recipe's category `category`, 2.1 `categories` and refuses the old key (the helper runs in both).
local major, minor = (mods["base"] or "2.0"):match("^(%d+)%.(%d+)")
local v21 = tonumber(major) > 2 or tonumber(minor) >= 1
local function feed_recipe(name, category, ingredient, result)
	local r = { type = "recipe", name = name, energy_required = 0.1, enabled = false, ingredients = { ingredient },
		results = { { type = "item", name = result, amount = 1 } },
		icon = "__base__/graphics/icons/" .. result .. ".png", subgroup = "intermediate-product" }
	if v21 then r.categories = { category } else r.category = category end
	return r
end
data:extend({
	feed_recipe("zz-feed-plate", "crafting-with-fluid", { type = "fluid", name = "water", amount = 10 }, "iron-plate"),
	feed_recipe("zz-feed-gear", "crafting", { type = "item", name = "iron-plate", amount = 1 }, "iron-gear-wheel"),
	feed_recipe("zz-feed-stick", "crafting", { type = "item", name = "iron-gear-wheel", amount = 1 }, "iron-stick"),
})
