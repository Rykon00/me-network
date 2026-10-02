--------------------------------------------------------------------------------
--- ME NETWORK (Gregtorio issue #68, step R1; design: docs/ME-REWORK.md, guide: docs/AE2.md)
--- Applied Energistics 2 style, no logistic network:
---   * ME Cable        = the fluix cable item places it. 1x1, connects on all four sides; a network is
---                       a connected group of ME blocks (cables, controller, drives, terminals, ...).
---   * ME Controller   = 2x2 electric energy interface: a network works with exactly one powered
---                       controller (two are a conflict). Its power use grows with the network.
---   * ME Drive        = the drive chassis item places it: 10 slots for storage cells (script GUI).
---   * Storage cells   = item-with-tags, stack size 1: the stored items live in the cell (AE2 bytes and
---                       types); a cell taken out carries its contents in its tags.
---   * ME Interface    = container with filterable slots: filtered slots are kept filled from the network
---                       (export), everything else is moved into the network (import).
---   * ME Import / Export Bus = rotatable 1x1 blocks that pull from / push into the entity they face.
---   * ME Storage Bus  = rotatable 1x1 block: the chest or cargo wagon it faces is storage of the network
---                       (scripts/fork-me-storagebus.lua).
---   * ME Terminal     = powered screen, the central GUI (scripts/fork-me-terminal.lua).
--- The old prototypes (roboport controller, logistic chest drives, requester interface) stay hidden, so
--- saves load; scripts/fork-me-migrate.lua replaces them. Runtime: scripts/fork-me-network.lua (graph,
--- storage, drives), scripts/fork-me-io.lua (interface, buses). Numbers reach the runtime through the
--- mod-data "fork-me-network". Sprites and icons: tools/gen_ae2_sprites.py.
--- Recipes and technologies here are the standalone ones (vanilla items and science); another mod can replace
--- them through ME_NETWORK (prototypes/api.lua). The prototype names are kept from Gregtorio Continued, where this
--- network was made: saves find their entities and items by name.
--------------------------------------------------------------------------------

local ME = ME_NETWORK
local ENTITY_PATH = ME.entity_path
local ICON_PATH = ME.icons
local ICON_FORK = ICON_PATH .. "fork/"

--- cell tier -> "k", old drive data (slots per cell, extra ingredient of the old drive item: it is given back
--- when such an item is placed, if that item exists)
local CELLS = {
	{ tier = "1k",   k = 1,   old_slots = 16 },
	{ tier = "4k",   k = 4,   old_slots = 32 },
	{ tier = "16k",  k = 16,  old_slots = 64 },
	{ tier = "64k",  k = 64,  old_slots = 128 },
	{ tier = "256k", k = 256, old_slots = 256,
	  extra = { name = "acceleration-card", count = 1 } },
}
local OLD_CELLS_PER_DRIVE = 4
local DRIVE_SLOTS = 10              -- AE2's ME Drive
local MAX_TYPES = 63                -- AE2: types per cell
local INTERFACE_SLOTS = 18          -- AE2: 9 config + 9 storage slots

local CONTROLLER, CABLE, DRIVE, INTERFACE = "me-network-controller", "me-cable", "me-drive", "me-network-interface"
local IMPORT_BUS, EXPORT_BUS = "me-import-bus", "me-export-bus"
local STORAGE_BUS = "me-storage-bus"
local UNDERGROUND = "me-underground-cable"
local UNDERGROUND_REACH = 10        -- max_underground_distance of the underground cable (the underground pipe's)
--- cables can be walked over (like heat pipes): no "player" layer, the rest of a building's mask
local WALKABLE = { layers = { item = true, meltable = true, object = true, water_tile = true, is_lower_object = true } }



--------------------------------------------------------------------------------
--- ITEM SUBGROUPS
--------------------------------------------------------------------------------

local group = data.raw["item-group"]["logistics"] and "logistics" or "processing-machine-recipes"
data:extend({
	{ type = "item-subgroup", name = "fork-me-network", group = group, order = "b-me-a" },
	{ type = "item-subgroup", name = "fork-me-drives", group = group, order = "b-me-b" },
	{ type = "item-subgroup", name = "fork-me-cells", group = group, order = "b-me-c" },
})




--------------------------------------------------------------------------------
--- THE BASIC ITEMS: cable, controller, interface, terminal, the drive and its chest, storage components and the
--- housing (the items of Gregtorio's upstream file 13-mv-age-item.lua; the entities they place are below)
--------------------------------------------------------------------------------

local function I(list) local t = {} for i = 1, #list, 2 do t[#t + 1] = { type = "item", name = list[i], amount = list[i + 1] } end return t end

ME.add_item{ name = "fluix-cable", subgroup = "fork-me-network", order = "a0",
	recipe = { ingredients = I{ "copper-cable", 2, "plastic-bar", 1 }, amount = 2, energy_required = 0.5 } }
ME.add_item{ name = "me-controller", subgroup = "fork-me-network", order = "a", stack_size = 10,
	recipe = { ingredients = I{ "steel-plate", 10, "advanced-circuit", 10, "fluix-cable", 4 }, energy_required = 5 } }
ME.add_item{ name = "me-interface", subgroup = "fork-me-network", order = "b", stack_size = 50,
	recipe = { ingredients = I{ "iron-chest", 1, "steel-plate", 4, "advanced-circuit", 2, "fluix-cable", 2 }, energy_required = 2 } }
ME.add_item{ name = "me-terminal", subgroup = "fork-me-network", order = "c", stack_size = 50,
	recipe = { ingredients = I{ "electronic-circuit", 4, "advanced-circuit", 1, "fluix-cable", 1 }, energy_required = 2 } }
ME.add_item{ name = "me-chest", subgroup = "fork-me-network", order = "d",
	recipe = { ingredients = I{ "steel-chest", 1, "electronic-circuit", 4, "fluix-cable", 2 }, energy_required = 2 } }
ME.add_item{ name = "me-drive", subgroup = "fork-me-drives", order = "a", stack_size = 10,
	recipe = { ingredients = I{ "me-chest", 1, "steel-plate", 4, "advanced-circuit", 4, "fluix-cable", 2 }, energy_required = 5 } }

--- AE2: a cell is a storage component in a housing; each component is made from three of the tier below
ME.add_item{ name = "basic-storage-housing", subgroup = "fork-me-cells", order = "a0",
	recipe = { ingredients = I{ "steel-plate", 2, "plastic-bar", 2 }, energy_required = 2 } }
local COMPONENTS = {
	{ "1k",   I{ "electronic-circuit", 4, "copper-cable", 6 } },
	{ "4k",   I{ "me-1k-storage-component", 3, "advanced-circuit", 2 } },
	{ "16k",  I{ "me-4k-storage-component", 3, "advanced-circuit", 4 } },
	{ "64k",  I{ "me-16k-storage-component", 3, "processing-unit", 2 } },
	{ "256k", I{ "me-64k-storage-component", 3, "processing-unit", 4 } },
}
for i, c in ipairs(COMPONENTS) do
	ME.add_item{ name = "me-" .. c[1] .. "-storage-component", subgroup = "fork-me-cells", order = "a" .. i,
		recipe = { ingredients = c[2], energy_required = 2 * i } }
end



--------------------------------------------------------------------------------
--- STORAGE CELLS (item-with-tags: the contents travel in the tags) AND THE OLD DRIVE ITEMS
--------------------------------------------------------------------------------

local cell_data, legacy_drives = {}, {}

for i, c in ipairs(CELLS) do
	local cell = "me-" .. c.tier .. "-storage-cell"
	local order = string.format("%02d", i)

	--- cell = storage housing + storage component; an item with tags (a recycler would void the contents)
	local item = ME.add_item{
		type = "item-with-tags",
		name = cell,
		icon = ICON_FORK .. cell .. ".png",
		subgroup = "fork-me-cells",
		order = order,
		stack_size = 1,
		recipe = { energy_required = 5, auto_recycle = false, ingredients = {
			{ type = "item", name = "me-" .. c.tier .. "-storage-component", amount = 1 },
			{ type = "item", name = "basic-storage-housing", amount = 1 },
		} },
	}
	local bytes = c.k * 1024
	local per_type = c.k * 8
	cell_data[cell] = { tier = c.tier, bytes = bytes, per_type = per_type, types = MAX_TYPES }
	item.localised_description = { "item-description.fork-me-storage-cell", c.tier, tostring(bytes),
		tostring(MAX_TYPES), tostring((bytes - per_type) * 8) }

	--- the old drive item (chassis + four cells, before issue #68): no recipe any more, hidden; placing one
	--- builds an ME Drive with its four (empty) cells
	local old = "me-drive-" .. c.tier
	data:extend({ {
		type = "item",
		name = old,
		icon = ICON_FORK .. old .. ".png",
		icon_size = 32,
		subgroup = "fork-me-drives",
		order = "z" .. order,
		stack_size = 10,
		place_result = DRIVE,
		hidden = true,
		localised_description = { "item-description.fork-me-legacy-drive", { "item-name." .. cell } },
	} })
	legacy_drives[old] = { cell = cell, cells = OLD_CELLS_PER_DRIVE, extra = c.extra }
end



--------------------------------------------------------------------------------
--- OLD PROTOTYPES (hidden, kept so saves load them; scripts/fork-me-migrate.lua replaces them)
--------------------------------------------------------------------------------

local function hide(e)
	e.hidden = true
	e.next_upgrade = nil
	e.fast_replaceable_group = nil
	return e
end

--- old drives: logistic storage chests holding the items themselves
local storage_chest = data.raw["logistic-container"]["storage-chest"]
for i, c in ipairs(CELLS) do
	local name = "me-drive-" .. c.tier
	local e = table.deepcopy(storage_chest)
	e.name = name
	e.icon = ICON_FORK .. name .. ".png"
	e.icon_size = 32
	e.minable = { mining_time = 0.2, result = name }
	e.inventory_size = c.old_slots * OLD_CELLS_PER_DRIVE
	e.corpse = "small-remnants"
	e.dying_explosion = nil
	e.max_health = 400
	e.animation = { layers = { {
		filename = ENTITY_PATH .. name .. ".png",
		priority = "extra-high",
		width = 32, height = 32, frame_count = 1,
	} } }
	e.opened_duration = 0
	e.animation_sound = nil
	e.localised_name = { "entity-name.fork-me-legacy", { "item-name." .. name } }
	data:extend({ hide(e) })
end

--- old interface: requester chest
local old_interface = table.deepcopy(data.raw["logistic-container"]["requester-chest"])
old_interface.name = "me-interface"
old_interface.icon = ICON_PATH .. "me-interface.png"
old_interface.icon_size = 32
old_interface.minable = { mining_time = 0.2, result = "me-interface" }
old_interface.inventory_size = 32
old_interface.trash_inventory_size = 16
old_interface.corpse = "small-remnants"
old_interface.dying_explosion = nil
old_interface.max_health = 400
old_interface.animation = { layers = { {
	filename = ENTITY_PATH .. "me-interface.png",
	priority = "extra-high",
	width = 32, height = 32, frame_count = 1,
} } }
old_interface.opened_duration = 0
old_interface.animation_sound = nil
old_interface.localised_name = { "entity-name.fork-me-legacy", { "item-name.me-interface" } }
data:extend({ hide(old_interface) })

--- old controller: 2x2 roboport without robots (network area only)
local old_controller = table.deepcopy(data.raw.roboport.roboport)
old_controller.name = "me-controller"
old_controller.icon = ICON_PATH .. "me-controller.png"
old_controller.icon_size = 32
old_controller.minable = { mining_time = 0.3, result = "me-controller" }
old_controller.max_health = 500
old_controller.corpse = "small-remnants"
old_controller.dying_explosion = nil
old_controller.collision_box = { { -0.8, -0.8 }, { 0.8, 0.8 } }
old_controller.selection_box = { { -1, -1 }, { 1, 1 } }
old_controller.energy_source = {
	type = "electric",
	usage_priority = "secondary-input",
	input_flow_limit = "1MW",
	buffer_capacity = "4MJ",
}
old_controller.recharge_minimum = "1MJ"
old_controller.energy_usage = "120kW"
old_controller.charging_energy = "1kW"
old_controller.logistics_radius = 16
old_controller.construction_radius = 0
old_controller.robot_slots_count = 0
old_controller.material_slots_count = 0
old_controller.charging_offsets = {}
old_controller.charging_station_count = 0
old_controller.base = { layers = { {
	filename = ENTITY_PATH .. "me-controller.png",
	priority = "medium", width = 64, height = 64,
} } }
old_controller.base_patch = util.empty_sprite()
old_controller.base_animation = util.empty_animation(1)
old_controller.door_animation_up = util.empty_animation(1)
old_controller.door_animation_down = util.empty_animation(1)
old_controller.recharging_animation = util.empty_animation(1)
old_controller.frozen_patch = nil
old_controller.integration_patch = nil
old_controller.water_reflection = nil
old_controller.open_door_trigger_effect = nil
old_controller.close_door_trigger_effect = nil
old_controller.localised_name = { "entity-name.fork-me-legacy", { "item-name.me-controller" } }
data:extend({ hide(old_controller) })



--------------------------------------------------------------------------------
--- ME CABLE (placed by the fluix cable item; 16 pictures, one per combination of connected sides:
--- graphics variation 1 + N*1 + E*2 + S*4 + W*8, set by the runtime)
--------------------------------------------------------------------------------

local function block(def)
	local e = {
		type = "simple-entity-with-force",
		name = def.name,
		icon = def.icon,
		icon_size = 32,
		flags = { "placeable-neutral", "player-creation" },
		minable = { mining_time = def.mining_time or 0.2, result = def.item or def.name },
		placeable_by = { item = def.item or def.name, count = 1 },
		max_health = def.health or 200,
		--- a simple-entity-with-force is a military target by default; ME blocks are passive like chests
		is_military_target = false,
		corpse = "small-remnants",
		collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } },
		selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
		selection_priority = def.selection_priority or 60,
		localised_description = def.description,
	}
	for k, v in pairs(def.extra or {}) do e[k] = v end
	data:extend({ e })
	return e
end

block{
	name = CABLE, item = "fluix-cable", icon = ICON_FORK .. "me-cable.png", health = 50, mining_time = 0.1,
	selection_priority = 40,
	description = { "entity-description.me-cable" },
	extra = {
		pictures = { sheet = {
			filename = ENTITY_PATH .. "me-cable.png",
			priority = "extra-high", width = 32, height = 32, variation_count = 16, line_length = 16,
		} },
		random_variation_on_create = false,
		render_layer = "lower-object",
		collision_mask = WALKABLE,
	},
}
data.raw.item["fluix-cable"].place_result = CABLE



--------------------------------------------------------------------------------
--- ME CONTROLLER (2x2 electric energy interface, no GUI; the runtime sets its power use)
--------------------------------------------------------------------------------

data:extend({ {
	type = "electric-energy-interface",
	name = CONTROLLER,
	icon = ICON_PATH .. "me-controller.png",
	icon_size = 32,
	flags = { "placeable-neutral", "player-creation" },
	minable = { mining_time = 0.3, result = "me-controller" },
	placeable_by = { item = "me-controller", count = 1 },
	max_health = 500,
	corpse = "small-remnants",
	collision_box = { { -0.8, -0.8 }, { 0.8, 0.8 } },
	selection_box = { { -1, -1 }, { 1, 1 } },
	gui_mode = "none",
	allow_copy_paste = false,
	energy_source = {
		type = "electric",
		usage_priority = "secondary-input",
		buffer_capacity = "100kJ",
		input_flow_limit = "10MW",
		output_flow_limit = "0W",
	},
	energy_production = "0W",
	energy_usage = "120kW",
	picture = {
		filename = ENTITY_PATH .. "me-network-controller.png",
		priority = "high", width = 64, height = 64,
	},
	localised_description = { "entity-description.me-network-controller" },
} })
data.raw.item["me-controller"].place_result = CONTROLLER



--------------------------------------------------------------------------------
--- ME DRIVE (the chassis item; cells go into its 10 slots through the script window)
--------------------------------------------------------------------------------

block{
	name = DRIVE, icon = ICON_PATH .. "me-drive.png", health = 400,
	description = { "entity-description.me-drive", tostring(DRIVE_SLOTS) },
	extra = { picture = {
		filename = ENTITY_PATH .. "me-drive.png",
		priority = "extra-high", width = 32, height = 32,
	},
	--- settings paste of the priority and the cell partitions (issue #68 step R3, scripts/fork-me-network.lua)
	additional_pastable_entities = { DRIVE } },
}
data.raw.item["me-drive"].place_result = DRIVE



--------------------------------------------------------------------------------
--- ME INTERFACE (container: config rows of items and fluids, the rest is imported; its four fluid sides are hidden
--- storage tanks of prototypes/fluids.lua, runtime: scripts/fork-me-io.lua)
--------------------------------------------------------------------------------

data:extend({ {
	type = "container",
	name = INTERFACE,
	icon = ICON_PATH .. "me-interface.png",
	icon_size = 32,
	flags = { "placeable-neutral", "player-creation" },
	minable = { mining_time = 0.2, result = "me-interface" },
	placeable_by = { item = "me-interface", count = 1 },
	max_health = 400,
	corpse = "small-remnants",
	collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } },
	selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
	inventory_size = INTERFACE_SLOTS,
	inventory_type = "with_filters_and_bar",
	picture = {                                       -- issue #3: with its four pipe sides (tools/gen_ae2_sprites.py --unified)
		filename = ENTITY_PATH .. "me-interface-unified.png",
		priority = "extra-high", width = 32, height = 32,
	},
	--- a container has no settings of its own: this lets the runtime copy the filters (settings paste)
	additional_pastable_entities = { INTERFACE },
	localised_description = { "entity-description.me-network-interface", tostring(INTERFACE_SLOTS) },
} })
data.raw.item["me-interface"].place_result = INTERFACE



--------------------------------------------------------------------------------
--- ME IMPORT BUS / ME EXPORT BUS (rotatable: the arrow points at the entity they work on)
--------------------------------------------------------------------------------

local function four_way(name)
	local out = {}
	for _, dir in pairs({ "north", "east", "south", "west" }) do
		out[dir] = { filename = ENTITY_PATH .. name .. "-" .. dir .. ".png", priority = "extra-high", width = 32, height = 32 }
	end
	return out
end

for _, bus in pairs({
	{ name = IMPORT_BUS, order = "b2" },
	{ name = EXPORT_BUS, order = "b3" },
}) do
	ME.add_item{
		name = bus.name,
		icon = ICON_FORK .. bus.name .. ".png",
		subgroup = "fork-me-network",
		order = bus.order,
		stack_size = 50,
		place_result = bus.name,
		recipe = { energy_required = 2, ingredients = I{ "fast-inserter", 1, "advanced-circuit", 1,
			"steel-plate", 2, "fluix-cable", 2 } },
	}
	block{
		name = bus.name, icon = ICON_FORK .. bus.name .. ".png",
		description = { "entity-description." .. bus.name },
		extra = { picture = four_way(bus.name) },
	}
end

--------------------------------------------------------------------------------
--- ME UNDERGROUND CABLE (rotatable pair, like the underground pipe: the direction points along the run;
--- above ground an end connects only on its back side, under ground to the first end within reach that faces
--- it; runtime: scripts/fork-me-network.lua, find_partner)
--------------------------------------------------------------------------------

ME.add_item{
	name = UNDERGROUND,
	icon = ICON_FORK .. UNDERGROUND .. ".png",
	subgroup = "fork-me-network",
	order = "a1",
	stack_size = 50,
	place_result = UNDERGROUND,
	recipe = { energy_required = 1, amount = 2, ingredients = I{ "fluix-cable", 8, "steel-plate", 2 } },
}
--- A real pipe-to-ground whose fluid box has its own connection category: it never connects to pipes or carries
--- fluid, but the engine pairs the ends exactly like underground pipes (reach, rotation, blocking, dragging) and
--- shows the pairing on hover and while placing. Its direction is the run's direction; the above ground
--- connection points backwards. The ME graph reads the engine's pairing (fluidbox.get_connections).
data:extend({ {
	type = "pipe-to-ground",
	name = UNDERGROUND,
	icon = ICON_FORK .. UNDERGROUND .. ".png",
	icon_size = 32,
	flags = { "placeable-neutral", "player-creation" },
	minable = { mining_time = 0.1, result = UNDERGROUND },
	placeable_by = { item = UNDERGROUND, count = 1 },
	max_health = 80,
	is_military_target = false,
	corpse = "small-remnants",
	collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } },
	selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
	selection_priority = 45,
	collision_mask = WALKABLE,
	fluid_box = {
		volume = 1,
		hide_connection_info = true,
		pipe_connections = {
			{ direction = defines.direction.south, position = { 0, 0 }, connection_category = "me-cable" },
			{ connection_type = "underground", direction = defines.direction.north, position = { 0, 0 },
			  max_underground_distance = UNDERGROUND_REACH, connection_category = "me-cable" },
		},
	},
	pictures = four_way(UNDERGROUND),
	localised_description = { "entity-description." .. UNDERGROUND, tostring(UNDERGROUND_REACH) },
} })

--- shift right click / shift left click copies the filters of the buses (runtime, on_entity_settings_pasted)
data.raw["simple-entity-with-force"][IMPORT_BUS].additional_pastable_entities = { IMPORT_BUS }
data.raw["simple-entity-with-force"][EXPORT_BUS].additional_pastable_entities = { EXPORT_BUS }

--------------------------------------------------------------------------------
--- ME STORAGE BUS (rotatable: the arrow side faces the chest or cargo wagon whose inventory becomes network
--- storage; AE2's recipe is an interface and two pistons; runtime: scripts/fork-me-storagebus.lua)
--------------------------------------------------------------------------------

ME.add_item{
	name = STORAGE_BUS,
	icon = ICON_FORK .. STORAGE_BUS .. ".png",
	subgroup = "fork-me-network",
	order = "b4",
	stack_size = 50,
	place_result = STORAGE_BUS,
	recipe = { energy_required = 2, ingredients = I{ "me-interface", 1, "fast-inserter", 2, "fluix-cable", 2 } },
}
block{
	name = STORAGE_BUS, icon = ICON_FORK .. STORAGE_BUS .. ".png",
	description = { "entity-description." .. STORAGE_BUS },
	extra = { picture = four_way(STORAGE_BUS), additional_pastable_entities = { STORAGE_BUS } },
}



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
terminal.localised_description = { "entity-description.me-terminal" }
data:extend({ terminal })
data.raw.item["me-terminal"].place_result = "me-terminal"

--- The "open GUI" key: opens the ME window of a block (scripts/fork-me-gui.lua; works whether or not the
--- engine opens a window for the entity), or puts the cell in the cursor into a drive
data:extend({ {
	type = "custom-input",
	name = "fork-me-terminal-open",
	key_sequence = "",
	linked_game_control = "open-gui",
	consuming = "none",
} })



--------------------------------------------------------------------------------
--- MOD DATA (read by scripts/fork-me-network.lua and fork-me-io.lua: no duplicated numbers)
--------------------------------------------------------------------------------

data:extend({ {
	type = "mod-data",
	name = "fork-me-network",
	data = {
		cells = cell_data,
		legacy_drives = legacy_drives,
		drive_slots = DRIVE_SLOTS,
		names = {
			controller = CONTROLLER, cable = CABLE, drive = DRIVE, interface = INTERFACE,
			import_bus = IMPORT_BUS, export_bus = EXPORT_BUS, terminal = "me-terminal",
			underground = UNDERGROUND, storage_bus = STORAGE_BUS,
		},
		underground_reach = UNDERGROUND_REACH,
		legacy = { controller = "me-controller", interface = "me-interface" },
	},
} })



--------------------------------------------------------------------------------
--- TECHNOLOGIES (standalone: vanilla science; Gregtorio puts them on its tiers through ME_NETWORK.set_technology)
--------------------------------------------------------------------------------

--- the cable, the controller, the drive, interface, terminal, buses and the cells up to 16k
ME.add_technology{ name = "me-network", prerequisites = { "advanced-circuit" }, unit = ME.unit(2, 300), recipes = {
	"fluix-cable", "me-controller", "me-chest", "me-drive", "me-interface", "me-terminal", "basic-storage-housing",
	"me-1k-storage-component", "me-4k-storage-component", "me-16k-storage-component",
	"me-1k-storage-cell", "me-4k-storage-cell", "me-16k-storage-cell", IMPORT_BUS, EXPORT_BUS, UNDERGROUND, STORAGE_BUS,
} }

ME.add_technology{ name = "me-storage-64k", prerequisites = { "me-network", "processing-unit" }, unit = ME.unit(3, 400),
	recipes = { "me-64k-storage-component", "me-64k-storage-cell" } }

ME.add_technology{ name = "me-storage-256k", prerequisites = { "me-storage-64k", "production-science-pack" },
	unit = ME.unit(4, 600), recipes = { "me-256k-storage-component", "me-256k-storage-cell" } }
