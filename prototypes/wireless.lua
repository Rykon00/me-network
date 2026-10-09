--------------------------------------------------------------------------------
--- ME NETWORK: WIRELESS (issues #153, #205 to #211; design: docs/ME-WIRELESS.md)
---   * ME Wireless Access Point: a 1x1 member of the network (power through the controller, like every member) whose range
---     the Wireless Boosters in its card slots extend: range 32 + 24 x b^1.5 tiles, power 20 kW + 10 kW x b^(1 + b / 16).
---   * Wireless ME Terminal: an item with tags (the linked network's controller and its energy) that a hotkey opens as an ME
---     Terminal (or, by its mode switch, as an ME Pattern Terminal) near an access point of that network.
---   * ME Wireless Terminal Module: the same for the equipment grid of an armour, paid from the grid.
---   * ME Charger: a 1x1 member that charges a Wireless ME Terminal from the network's power.
--- The numbers reach the runtime through the mod-data "fork-me-network" (data.wireless).
--------------------------------------------------------------------------------

local ME = ME_NETWORK
local ICON_FORK = ME.icons .. "fork/"
local ENTITY_PATH = ME.entity_path

local function I(list) local t = {} for i = 1, #list, 2 do t[#t + 1] = { type = "item", name = list[i], amount = list[i + 1] } end return t end

local NUMBERS = {
	--- the access point (the formulas above; b = the boosters in its card slots)
	base_range = 32, range_per_booster = 24, range_exponent = 1.5,
	base_power = 20000, power_per_booster = 10000, power_exponent_divisor = 16,
	--- the terminal item: its buffer (J), what an open window uses (W, times 1 + distance / range of its access point)
	item_buffer = 100000000, item_use = 200000,
	--- the charger: its rate (W, drawn through the controller while an item is not full) and its idle draw
	charge_rate = 1000000, charger_idle = 2000,
	--- the equipment module: its buffer (J, in the grid) and what an open window uses (W)
	module_buffer = 20000000, module_use = 200000,
}

data.raw["mod-data"]["fork-me-network"].data.wireless = NUMBERS
--- the access point's card slots: up to 4 Wireless Boosters (the generic card code, scripts/fork-me-cardslots.lua)
local cards = data.raw["mod-data"]["fork-me-network"].data.cards
cards.kinds["me-wireless-booster"] = "booster"
cards.access_point = { slots = 4, limits = { booster = 4 } }
local names = data.raw["mod-data"]["fork-me-network"].data.names
names.access_point, names.charger = "me-wireless-access-point", "me-charger"

data:extend({ { type = "item-subgroup", name = "fork-me-wireless", group = data.raw["item-subgroup"]["fork-me-network"].group,
	order = "b-me-e" } })

local recipes = {}

--- a 1x1 solid member like the crafting blocks (simple entities: the ME window opens by the open key)
local function block(name, description)
	data:extend({ {
		type = "simple-entity-with-force",
		name = name,
		icon = ME.hd_icons .. name .. ".png",          -- (issue #220: the 3D style)
		icon_size = 64,
		flags = { "placeable-neutral", "player-creation" },
		minable = { mining_time = 0.2, result = name },
		placeable_by = { item = name, count = 1 },
		max_health = 200,
		is_military_target = false,
		corpse = "small-remnants",
		collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } },
		selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
		picture = { filename = ME.hd_entity_path .. name .. ".png", priority = "high", width = 64, height = 64, scale = 0.5 },
		localised_description = description,
	} })
end

ME.add_item{
	name = "me-wireless-access-point",
	icon = ME.hd_icons .. "me-wireless-access-point.png",
	icon_size = 64,
	subgroup = "fork-me-wireless",
	order = "a",
	stack_size = 50,
	place_result = "me-wireless-access-point",
	recipe = { energy_required = 5, ingredients = I{ "radar", 1, "fluix-cable", 2, "processing-unit", 1 } },
}
block("me-wireless-access-point", { "entity-description.me-wireless-access-point" })
recipes[#recipes + 1] = "me-wireless-access-point"

ME.add_item{
	name = "me-wireless-booster",
	icon = ICON_FORK .. "me-wireless-booster.png",
	subgroup = "fork-me-wireless",
	order = "b",
	stack_size = 64,
	localised_description = { "item-description.me-wireless-booster" },
	recipe = { energy_required = 2, ingredients = I{ "advanced-circuit", 1, "copper-cable", 4, "iron-plate", 2 } },
}
recipes[#recipes + 1] = "me-wireless-booster"

ME.add_item{
	type = "item-with-tags",
	name = "me-wireless-terminal",
	icon = ICON_FORK .. "me-wireless-terminal.png",
	subgroup = "fork-me-wireless",
	order = "c",
	stack_size = 1,
	localised_description = { "item-description.me-wireless-terminal" },
	recipe = { energy_required = 5, ingredients = I{ "me-terminal", 1, "me-wireless-booster", 1, "battery", 4, "processing-unit", 1 } },
}
recipes[#recipes + 1] = "me-wireless-terminal"

ME.add_item{
	name = "me-charger",
	icon = ME.hd_icons .. "me-charger.png",
	icon_size = 64,
	subgroup = "fork-me-wireless",
	order = "d",
	stack_size = 50,
	place_result = "me-charger",
	recipe = { energy_required = 3, ingredients = I{ "battery", 2, "fluix-cable", 1, "advanced-circuit", 2, "iron-plate", 4 } },
}
block("me-charger", { "entity-description.me-charger" })
recipes[#recipes + 1] = "me-charger"

--- the equipment module: a battery piece of the armour's grid (the grid charges it, the script pays the window from it)
ME.add_item{
	name = "me-wireless-module",
	icon = ICON_FORK .. "me-wireless-module.png",
	subgroup = "fork-me-wireless",
	order = "e",
	stack_size = 10,
	localised_description = { "item-description.me-wireless-module" },
	fields = { place_as_equipment_result = "me-wireless-module" },
	recipe = { energy_required = 5, ingredients = I{ "me-wireless-terminal", 1, "battery", 10, "processing-unit", 2 } },
}
data:extend({ {
	type = "battery-equipment",
	name = "me-wireless-module",
	sprite = { filename = ICON_FORK .. "me-wireless-module.png", width = 32, height = 32, priority = "medium", scale = 2 },
	shape = { width = 2, height = 2, type = "full" },
	energy_source = { type = "electric", buffer_capacity = (NUMBERS.module_buffer / 1000000) .. "MJ", input_flow_limit = "2MW",
		output_flow_limit = "0W", usage_priority = "tertiary" },
	categories = { "armor" },
	localised_description = { "item-description.me-wireless-module" },
} })
recipes[#recipes + 1] = "me-wireless-module"

ME.add_technology{ name = "me-wireless", prerequisites = { "me-upgrade-cards", "battery" }, unit = ME.unit(3, 500), recipes = recipes }

--- the hotkey (rebindable in the controls): opens the wireless terminal of the item or the module
data:extend({ {
	type = "custom-input",
	name = "fork-me-wireless",
	key_sequence = "CONTROL + SHIFT + T",
	consuming = "none",
	order = "a",
} })
