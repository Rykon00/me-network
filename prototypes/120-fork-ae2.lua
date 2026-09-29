--------------------------------------------------------------------------------
--- FORK AE2: ME NETWORK
--- Applied Energistics 2 mapped onto Factorio's logistic network (no per-tick scripts):
---   * ME network    = a logistic network. The ME Controller is a roboport without robots
---                     (network coverage only); the Roboport MK1 already contains one.
---   * ME Drive      = logistic storage chest. Capacity comes from the four storage cells it
---                     is built with (1k ... 256k), upgrade planner swaps drive tiers.
---   * ME Interface  = requester chest that trashes everything not requested: inserters put
---                     items in (import), requests pull items out (export), robots move them.
---   * ME Terminal   = powered screen; opening it shows the network contents and lets the
---                     player take or store items (control.lua, scripts/fork-me-terminal.lua).
--- Sprites and icons: tools/gen_ae2_sprites.py.
--------------------------------------------------------------------------------

local ENTITY_PATH = "__gregtorio-continued__/graphics/entity/fork/ae2/"
local ICON_FORK = ICON_PATH .. "fork/"

--- cell tier -> slots per cell, assembler category of cell and drive, extra drive ingredient
local CELLS = {
	{ tier = "1k",   slots = 16,  cell_cat = "lv-assembling-machine-recipes", drive_cat = "mv-assembling-machine-recipes", speed = MV_SPEED },
	{ tier = "4k",   slots = 32,  cell_cat = "lv-assembling-machine-recipes", drive_cat = "mv-assembling-machine-recipes", speed = MV_SPEED },
	{ tier = "16k",  slots = 64,  cell_cat = "mv-assembling-machine-recipes", drive_cat = "mv-assembling-machine-recipes", speed = MV_SPEED },
	{ tier = "64k",  slots = 128, cell_cat = "hv-assembling-machine-recipes", drive_cat = "ev-assembling-machine-recipes", speed = EV_SPEED },
	{ tier = "256k", slots = 256, cell_cat = "ev-assembling-machine-recipes", drive_cat = "iv-assembling-machine-recipes", speed = IV_SPEED,
	  extra = { type = "item", name = "acceleration-card", amount = 1 } },
}
local CELLS_PER_DRIVE = 4



--------------------------------------------------------------------------------
--- ITEM SUBGROUPS
--------------------------------------------------------------------------------

local group = data.raw["item-group"]["logistics"] and "logistics" or "processing-machine-recipes"
data:extend({
	{ type = "item-subgroup", name = "fork-me-network", group = group, order = "b-me-a" },
	{ type = "item-subgroup", name = "fork-me-drives", group = group, order = "b-me-b" },
	{ type = "item-subgroup", name = "fork-me-cells", group = group, order = "b-me-c" },
})

local function move_to(subgroup, item_name, order)
	local item = data.raw.item[item_name]
	if item then item.subgroup = subgroup; item.order = order end
	local recipe = data.raw.recipe[item_name]
	if recipe then recipe.subgroup = subgroup; recipe.order = order end
end
move_to("fork-me-network", "me-controller", "a")
move_to("fork-me-network", "me-interface", "b")
move_to("fork-me-network", "me-terminal", "c")
move_to("fork-me-network", "me-chest", "d")
move_to("fork-me-drives", "me-drive", "a")



--------------------------------------------------------------------------------
--- STORAGE CELLS AND DRIVES
--------------------------------------------------------------------------------

local storage_chest = data.raw["logistic-container"]["storage-chest"]

for i, c in ipairs(CELLS) do
	local cell = "me-" .. c.tier .. "-storage-cell"
	local drive = "me-drive-" .. c.tier
	local order = string.format("%02d", i)

	--- cell = storage housing + storage component
	create_item{
		name = cell,
		icon = ICON_FORK .. cell .. ".png",
		category = c.cell_cat,
		subgroup = "fork-me-cells",
		order = order,
		energy_required = 5,
		stack_size = 16,
		ingredients = {
			{ type = "item", name = "me-" .. c.tier .. "-storage-component", amount = 1 },
			{ type = "item", name = "basic-storage-housing", amount = 1 },
		},
	}

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
		subgroup = "fork-me-drives",
		order = "b" .. order,
		energy_required = 10 * c.speed,
		stack_size = 10,
		place_result = drive,
		ingredients = ingredients,
	}

	--- take the cells out again (e.g. after the upgrade planner replaced the drive)
	local parts = {
		{ type = "item", name = "me-drive", amount = 1 },
		{ type = "item", name = cell, amount = CELLS_PER_DRIVE },
	}
	if c.extra then parts[#parts + 1] = c.extra end
	create_recipe{
		recipe_name = drive .. "-disassembly",
		category = "crafting-or-assembling-recipes",
		subgroup = "fork-me-drives",
		order = "c" .. order,
		icon = ICON_FORK .. drive .. ".png",
		energy_required = 1,
		ingredients = { { type = "item", name = drive, amount = 1 } },
		results = parts,
	}
	data.raw.recipe[drive .. "-disassembly"].allow_decomposition = false
	data.raw.recipe[drive .. "-disassembly"].localised_name = { "recipe-name.fork-me-drive-disassembly", { "item-name." .. drive } }

	local e = table.deepcopy(storage_chest)
	e.name = drive
	e.icon = ICON_FORK .. drive .. ".png"
	e.icon_size = 32
	e.minable = { mining_time = 0.2, result = drive }
	e.inventory_size = c.slots * CELLS_PER_DRIVE
	e.fast_replaceable_group = "me-drive"
	e.next_upgrade = CELLS[i + 1] and ("me-drive-" .. CELLS[i + 1].tier) or nil
	e.corpse = "small-remnants"
	e.dying_explosion = nil
	e.max_health = 400
	e.animation = { layers = { {
		filename = ENTITY_PATH .. drive .. ".png",
		priority = "extra-high",
		width = 32, height = 32, frame_count = 1,
	} } }
	e.opened_duration = 0
	e.animation_sound = nil
	e.localised_description = { "entity-description.fork-me-drive", tostring(e.inventory_size), c.tier }
	data:extend({ e })
end



--------------------------------------------------------------------------------
--- ME INTERFACE (requester chest, "trash unrequested" is switched on when placed)
--------------------------------------------------------------------------------

local interface = table.deepcopy(data.raw["logistic-container"]["requester-chest"])
interface.name = "me-interface"
interface.icon = ICON_PATH .. "me-interface.png"
interface.icon_size = 32
interface.minable = { mining_time = 0.2, result = "me-interface" }
interface.inventory_size = 32
interface.trash_inventory_size = 16
interface.fast_replaceable_group = "me-interface"
interface.corpse = "small-remnants"
interface.dying_explosion = nil
interface.max_health = 400
interface.animation = { layers = { {
	filename = ENTITY_PATH .. "me-interface.png",
	priority = "extra-high",
	width = 32, height = 32, frame_count = 1,
} } }
interface.opened_duration = 0
interface.animation_sound = nil
data:extend({ interface })
data.raw.item["me-interface"].place_result = "me-interface"
data.raw.item["me-interface"].stack_size = 50



--------------------------------------------------------------------------------
--- ME TERMINAL (always-on lamp: needs power, its GUI is replaced by the terminal GUI)
--------------------------------------------------------------------------------

local terminal = table.deepcopy(data.raw.lamp["small-lamp"])
terminal.name = "me-terminal"
terminal.icon = ICON_PATH .. "me-terminal.png"
terminal.icon_size = 32
terminal.minable = { mining_time = 0.2, result = "me-terminal" }
terminal.max_health = 200
terminal.corpse = "small-remnants"
terminal.dying_explosion = nil
terminal.collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } }
terminal.selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } }
terminal.energy_usage_per_tick = "8kW"
terminal.always_on = true
terminal.light = { intensity = 0.4, size = 6, color = { 0.7, 0.55, 1 } }
terminal.light_when_colored = nil
terminal.picture_off = { layers = { {
	filename = ENTITY_PATH .. "me-terminal-off.png",
	priority = "high", width = 32, height = 32,
} } }
terminal.picture_on = {
	filename = ENTITY_PATH .. "me-terminal-on.png",
	priority = "high", width = 32, height = 32,
}
terminal.fast_replaceable_group = nil
terminal.next_upgrade = nil
data:extend({ terminal })
data.raw.item["me-terminal"].place_result = "me-terminal"
data.raw.item["me-terminal"].stack_size = 50

--- Opening the terminal (works whether or not the engine opens a GUI for lamps)
data:extend({ {
	type = "custom-input",
	name = "fork-me-terminal-open",
	key_sequence = "",
	linked_game_control = "open-gui",
	consuming = "none",
} })



--------------------------------------------------------------------------------
--- ME CONTROLLER (2x2 roboport without robots or charging pads: network coverage only)
--------------------------------------------------------------------------------

local controller = table.deepcopy(data.raw.roboport.roboport)
controller.name = "me-controller"
controller.icon = ICON_PATH .. "me-controller.png"
controller.icon_size = 32
controller.minable = { mining_time = 0.3, result = "me-controller" }
controller.max_health = 500
controller.corpse = "small-remnants"
controller.dying_explosion = nil
controller.collision_box = { { -0.8, -0.8 }, { 0.8, 0.8 } }
controller.selection_box = { { -1, -1 }, { 1, 1 } }
controller.energy_source = {
	type = "electric",
	usage_priority = "secondary-input",
	input_flow_limit = "1MW",
	buffer_capacity = "4MJ",
}
controller.recharge_minimum = "1MJ"
controller.energy_usage = "120kW"
controller.charging_energy = "1kW"
controller.logistics_radius = 16
controller.construction_radius = 0
controller.robot_slots_count = 0
controller.material_slots_count = 0
controller.charging_offsets = {}
controller.charging_station_count = 0
controller.base = { layers = { {
	filename = ENTITY_PATH .. "me-controller.png",
	priority = "medium", width = 64, height = 64,
} } }
controller.base_patch = util.empty_sprite()
controller.base_animation = util.empty_animation(1)
controller.door_animation_up = util.empty_animation(1)
controller.door_animation_down = util.empty_animation(1)
controller.recharging_animation = util.empty_animation(1)
controller.frozen_patch = nil
controller.integration_patch = nil
controller.water_reflection = nil
controller.open_door_trigger_effect = nil
controller.close_door_trigger_effect = nil
controller.fast_replaceable_group = nil
controller.next_upgrade = nil
data:extend({ controller })
data.raw.item["me-controller"].place_result = "me-controller"
data.raw.item["me-controller"].stack_size = 10



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
	return "me-" .. tier .. "-storage-cell", "me-drive-" .. tier, "me-drive-" .. tier .. "-disassembly"
end

--- The drive chassis was only auto-unlocked (199-fork-finalize) because nothing else made it;
--- the disassembly recipes above now also return it, so unlock it explicitly.
fork_add_unlock("logistic-system", "me-chest")
fork_add_unlock("logistic-system", "me-drive")

--- MV: basic cells, terminal
local mv = { "me-terminal", "computer-monitor", "certus-quartz-bolt", "certus-quartz-screw" }
for _, t in pairs({ "1k", "4k", "16k" }) do
	for _, r in pairs({ drive_recipes(t) }) do mv[#mv + 1] = r end
end
tech{ name = "me-network", prerequisites = { "logistic-system" }, packs = 3, count = 400, recipes = mv }

--- EV: 64k (the component needs epoxy boards)
local ev = { "me-64k-storage-component" }
for _, r in pairs({ drive_recipes("64k") }) do ev[#ev + 1] = r end
tech{ name = "me-storage-64k", prerequisites = { "me-network", "nanoprocessors", "advanced-hv-machines" },
	packs = 5, count = 800, recipes = ev }

--- IV: 256k and the cards (platinum), fiber-reinforced boards for the component
local iv = { "me-256k-storage-component", "advanced-card", "acceleration-card",
	"annealed-copper-foil", "fiber-reinforced-epoxy-sheet", "fiber-reinforced-circuit-board",
	"fiber-reinforced-printed-circuit-board" }
for _, r in pairs({ drive_recipes("256k") }) do iv[#iv + 1] = r end
tech{ name = "me-storage-256k", prerequisites = { "me-storage-64k", "industrial-precision-lathe", "ev-machines" },
	packs = 6, count = 1000, recipes = iv }
