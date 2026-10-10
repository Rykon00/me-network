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
--- The old prototypes (roboport controller, logistic chest drives, requester interface) are gone since issue #146
--- (0.5.0 converted them; a save from before it is refused, control.lua). Runtime: scripts/fork-me-network.lua (graph,
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

--- cell tier -> "k", the extra ingredient of the old drive item (it is given back when such an item is placed, if that
--- item exists)
local CELLS = {
	{ tier = "1k",   k = 1 },
	{ tier = "4k",   k = 4 },
	{ tier = "16k",  k = 16 },
	{ tier = "64k",  k = 64 },
	{ tier = "256k", k = 256, extra = { name = "acceleration-card", count = 1 } },
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
--- issue #229: the ME Chest and its hidden parts on its tile (its own power buffer, its fluid input)
local CHEST, CHEST_POWER, CHEST_FLUID = "me-chest", "me-chest-power", "me-chest-fluid"
local CHEST_WATTS = 4000            -- W: what it draws from the power grid on its own (a member's 4 kW through the controller)
local CHEST_FLUID_VOLUME = 1000
--- cables can be walked over (like heat pipes): no "player" layer, the rest of a building's mask. Since issue #129 so can the
--- buses and the ME Terminal (prototypes/api.lua)
local WALKABLE = ME.WALKABLE



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

local HD_ICON, HD_ENTITY = ME.hd_icons, ME.hd_entity_path       -- issue #218: the 64 px pictures of the 3D style

local function I(list) local t = {} for i = 1, #list, 2 do t[#t + 1] = { type = "item", name = list[i], amount = list[i + 1] } end return t end

--- Recipes (issue #233): AE2's recipes (modern AE2, data/ae2/recipe; AE2-Unofficial for its own cards) with AE2's ingredients
--- and counts, every AE2 material by one vanilla stand-in (docs/AE2.md, "Recipes"): iron ingot = iron plate, copper ingot and
--- gold ingot = copper plate, diamond = processing unit, redstone, glowstone, fluix crystal and fluix dust = copper cable, certus
--- quartz = stone, glass, quartz glass and quartz fiber = plastic bar, sky stone = stone brick, logic processor = electronic
--- circuit, calculation processor = advanced circuit, engineering processor = processing unit (the ME Controller and the ME
--- Drive: an advanced circuit, so the network comes after advanced circuits as before), annihilation and formation core =
--- electronic circuit, illuminated panel = small lamp, piston = fast inserter, redstone torch = decider combinator, crafting
--- table = assembling machine 1, wool = copper cable, wireless receiver = radar, dense energy cell = 4 batteries, ender dust =
--- electronic circuit. Gregtorio Continued replaces them with its own (ME_NETWORK.replace_recipe).

--- fluix glass cable: 1 quartz fiber, 2 fluix crystals -> 4
ME.add_item{ name = "fluix-cable", icon = HD_ICON .. "fluix-cable.png", icon_size = 64, subgroup = "fork-me-network", order = "a0",
	recipe = { ingredients = I{ "plastic-bar", 1, "copper-cable", 2 }, amount = 4, energy_required = 0.5 } }
--- controller: 4 smooth sky stone, 4 fluix crystals, an engineering processor (an advanced circuit, see above)
ME.add_item{ name = "me-controller", icon = HD_ICON .. "me-controller.png", icon_size = 64, subgroup = "fork-me-network", order = "a", stack_size = 10,
	recipe = { ingredients = I{ "stone-brick", 4, "copper-cable", 4, "advanced-circuit", 1 }, energy_required = 5 } }
--- interface: 4 iron, 2 glass, an annihilation core, a formation core
ME.add_item{ name = "me-interface", icon = HD_ICON .. "me-interface.png", icon_size = 64, subgroup = "fork-me-network", order = "b", stack_size = 50,
	recipe = { ingredients = I{ "iron-plate", 4, "plastic-bar", 2, "electronic-circuit", 2 }, energy_required = 2 } }
--- terminal: a formation core, an annihilation core, a logic processor, an illuminated panel
ME.add_item{ name = "me-terminal", icon = HD_ICON .. "me-terminal.png", icon_size = 64, subgroup = "fork-me-network", order = "c", stack_size = 50,
	recipe = { ingredients = I{ "electronic-circuit", 3, "small-lamp", 1 }, energy_required = 2 } }
--- ME Chest (issue #229): 2 glass, a terminal, 2 fluix cables, 2 iron, a copper
ME.add_item{ name = "me-chest", icon = HD_ICON .. "me-chest.png", icon_size = 64, subgroup = "fork-me-network", order = "d",
	stack_size = 50,
	recipe = { ingredients = I{ "plastic-bar", 2, "me-terminal", 1, "fluix-cable", 2, "iron-plate", 2, "copper-plate", 1 }, energy_required = 2 } }
--- drive: 4 iron, 2 engineering processors (advanced circuits, see above), 2 fluix cables (no ME Chest: issue #231)
ME.add_item{ name = "me-drive", icon = HD_ICON .. "me-drive.png", icon_size = 64, subgroup = "fork-me-drives", order = "a", stack_size = 10,
	recipe = { ingredients = I{ "iron-plate", 4, "advanced-circuit", 2, "fluix-cable", 2 }, energy_required = 5 } }

--- AE2: a cell is a storage component in a housing; each component is made from three of the tier below
--- (housing: 2 quartz glass, 3 redstone, 2 iron, a copper; components: 1k 4 redstone, 4 certus quartz, a logic processor; 4k ...
--- 256k three of the tier below, a calculation processor, a quartz glass and 4 redstone (4k), glowstone (16k, 64k) or sky stone
--- dust (256k))
ME.add_item{ name = "basic-storage-housing", subgroup = "fork-me-cells", order = "a0",
	recipe = { ingredients = I{ "plastic-bar", 2, "copper-cable", 3, "iron-plate", 2, "copper-plate", 1 }, energy_required = 2 } }
local COMPONENTS = {
	{ "1k",   I{ "copper-cable", 4, "stone", 4, "electronic-circuit", 1 } },
	{ "4k",   I{ "me-1k-storage-component", 3, "advanced-circuit", 1, "plastic-bar", 1, "copper-cable", 4 } },
	{ "16k",  I{ "me-4k-storage-component", 3, "advanced-circuit", 1, "plastic-bar", 1, "copper-cable", 4 } },
	{ "64k",  I{ "me-16k-storage-component", 3, "advanced-circuit", 1, "plastic-bar", 1, "copper-cable", 4 } },
	{ "256k", I{ "me-64k-storage-component", 3, "advanced-circuit", 1, "plastic-bar", 1, "stone-brick", 4 } },
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
		icon = HD_ICON .. cell .. ".png",
		icon_size = 64,
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
	--- builds an ME Drive with its four (empty) cells (issue #146: kept, 0.5.0 left them in inventories as they were)
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
--- ME CABLE (placed by the fluix cable item; 16 pictures, one per combination of connected sides:
--- graphics variation 1 + N*1 + E*2 + S*4 + W*8, set by the runtime)
--------------------------------------------------------------------------------

local function block(def)
	local e = {
		type = "simple-entity-with-force",
		name = def.name,
		icon = def.icon,
		icon_size = def.icon_size or 32,
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
	name = CABLE, item = "fluix-cable", icon = HD_ICON .. "me-cable.png", icon_size = 64, health = 50, mining_time = 0.1,
	selection_priority = 40,
	description = { "entity-description.me-cable" },
	extra = {
		pictures = { sheet = {
			filename = HD_ENTITY .. "me-cable.png",
			priority = "extra-high", width = 64, height = 64, scale = 0.5, variation_count = 16, line_length = 16,
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
	icon = HD_ICON .. "me-controller.png",
	icon_size = 64,
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
		filename = HD_ENTITY .. "me-network-controller.png",
		priority = "high", width = 128, height = 128, scale = 0.5,
	},
	localised_description = { "entity-description.me-network-controller" },
} })
data.raw.item["me-controller"].place_result = CONTROLLER



--------------------------------------------------------------------------------
--- ME DRIVE (the chassis item; cells go into its 10 slots through the script window)
--------------------------------------------------------------------------------

block{
	name = DRIVE, icon = HD_ICON .. "me-drive.png", icon_size = 64, health = 400,
	description = { "entity-description.me-drive", tostring(DRIVE_SLOTS) },
	extra = { picture = {
		filename = HD_ENTITY .. "me-drive.png",
		priority = "extra-high", width = 64, height = 64, scale = 0.5,
	},
	--- settings paste of the priority and the cell partitions (issue #68 step R3, scripts/fork-me-network.lua)
	additional_pastable_entities = { DRIVE } },
}
data.raw.item["me-drive"].place_result = DRIVE



--------------------------------------------------------------------------------
--- ME CHEST (issue #229, AE2's ME Chest): one cell slot and a terminal of its own that sees that cell only (script window);
--- a container of one slot that inserters fill: the runtime empties it into the cell every tick (input only). On its tile a
--- hidden storage tank with a pipe connection on every side (a fluid cell is filled from it) and a hidden energy interface,
--- its own power buffer: the chest works without a network on power from the grid (scripts/fork-me-network.lua, ME CHEST).
--------------------------------------------------------------------------------

local HIDDEN_FLAGS = { "not-on-map", "not-blueprintable", "not-deconstructable", "not-upgradable", "hide-alt-info",
	"no-copy-paste", "not-in-kill-statistics", "placeable-off-grid" }

data:extend({ {
	type = "container",
	name = CHEST,
	icon = HD_ICON .. "me-chest.png",
	icon_size = 64,
	flags = { "placeable-neutral", "player-creation" },
	minable = { mining_time = 0.2, result = "me-chest" },
	placeable_by = { item = "me-chest", count = 1 },
	max_health = 300,
	corpse = "small-remnants",
	collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } },
	selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
	inventory_size = 1,
	inventory_type = "normal",
	picture = { filename = HD_ENTITY .. "me-chest.png", priority = "extra-high", width = 64, height = 64, scale = 0.5 },
	--- the priority and the cell's partition (drive settings) go with a paste between chests and drives
	additional_pastable_entities = { CHEST, DRIVE },
	localised_description = { "entity-description.me-chest" },
}, {
	type = "electric-energy-interface",
	name = CHEST_POWER,
	icon = HD_ICON .. "me-chest.png",
	icon_size = 64,
	flags = HIDDEN_FLAGS,
	hidden = true,
	selectable_in_game = false,
	max_health = 300,
	collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } },
	collision_mask = { layers = {} },                 -- shares the tile with the chest's container
	gui_mode = "none",
	allow_copy_paste = false,
	energy_source = {
		type = "electric",
		usage_priority = "secondary-input",
		buffer_capacity = "100kJ",                    -- 25 s on its own (AE2: 500 AE)
		input_flow_limit = "40kW",
		output_flow_limit = "0W",
		render_no_network_icon = false,
		render_no_power_icon = false,
	},
	energy_production = "0W",
	energy_usage = tostring(CHEST_WATTS) .. "W",
	localised_name = { "entity-name.me-chest" },
}, {
	type = "storage-tank",
	name = CHEST_FLUID,
	icon = HD_ICON .. "me-chest.png",
	icon_size = 64,
	flags = HIDDEN_FLAGS,
	hidden = true,
	selectable_in_game = false,
	max_health = 300,
	collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } },
	collision_mask = { layers = {} },
	fluid_box = {
		volume = CHEST_FLUID_VOLUME,
		hide_connection_info = true,
		pipe_connections = {
			{ direction = defines.direction.north, position = { 0, 0 } },
			{ direction = defines.direction.east, position = { 0, 0 } },
			{ direction = defines.direction.south, position = { 0, 0 } },
			{ direction = defines.direction.west, position = { 0, 0 } },
		},
	},
	window_bounding_box = { { 0, 0 }, { 0, 0 } },
	flow_length_in_ticks = 360,
	pictures = { picture = { filename = "__core__/graphics/empty.png", priority = "extra-high", width = 1, height = 1 } },
	two_direction_only = false,
	circuit_wire_max_distance = 0,
	localised_name = { "entity-name.me-chest" },
} })
data.raw.item["me-chest"].place_result = CHEST



--------------------------------------------------------------------------------
--- ME INTERFACE (container: config rows of items and fluids, the rest is imported; its four fluid sides are hidden
--- storage tanks of prototypes/fluids.lua, runtime: scripts/fork-me-io.lua)
--------------------------------------------------------------------------------

data:extend({ {
	type = "container",
	name = INTERFACE,
	icon = HD_ICON .. "me-interface.png",
	icon_size = 64,
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
		filename = HD_ENTITY .. "me-interface-unified.png",
		priority = "extra-high", width = 64, height = 64, scale = 0.5,
	},
	--- a container has no settings of its own: this lets the runtime copy the filters (settings paste)
	additional_pastable_entities = { INTERFACE },
	localised_description = { "entity-description.me-network-interface", tostring(INTERFACE_SLOTS) },
} })
data.raw.item["me-interface"].place_result = INTERFACE



--------------------------------------------------------------------------------
--- ME IMPORT BUS / ME EXPORT BUS (rotatable: the arrow points at the entity they work on)
--------------------------------------------------------------------------------

local function four_way(name, hd)
	local out = {}
	for _, dir in pairs({ "north", "east", "south", "west" }) do
		out[dir] = hd and { filename = HD_ENTITY .. name .. "-" .. dir .. ".png", priority = "extra-high", width = 64, height = 64, scale = 0.5 }
			or { filename = ENTITY_PATH .. name .. "-" .. dir .. ".png", priority = "extra-high", width = 32, height = 32 }
	end
	return out
end

--- issue #282: a bus's picture and, as a layer of its own above it, its marker (the plate on the side it faces and its
--- arrows, tools/gen_ae2_sprites.py --bus-markers: the picture's own pixels, so it changes nothing here). The marker sits
--- on the picture's face, BUS_FACE px at its top left; data-final-fixes.lua moves it to the face of the mod-data's bus
--- view, so a graphics mod that replaces the picture keeps the direction (docs/API.md "The bus view").
local BUS_FACE = 58
local function bus_picture(name)
	local out = four_way(name, true)
	for dir, sprite in pairs(out) do
		out[dir] = { layers = { sprite, { filename = HD_ENTITY .. name .. "-" .. dir .. "-marker.png", priority = "extra-high",
			width = BUS_FACE, height = BUS_FACE, scale = 0.5, shift = { BUS_FACE / 2 / 64 - 0.5, BUS_FACE / 2 / 64 - 0.5 } } } }
	end
	return out
end

for _, bus in pairs({
	{ name = IMPORT_BUS, order = "b2" },
	{ name = EXPORT_BUS, order = "b3" },
}) do
	ME.add_item{
		name = bus.name,
		icon = HD_ICON .. bus.name .. ".png",
		icon_size = 64,
		subgroup = "fork-me-network",
		order = bus.order,
		stack_size = 50,
		place_result = bus.name,
		--- AE2: an annihilation (import) or formation core (export), 2 iron, a piston
		recipe = { energy_required = 2, ingredients = I{ "electronic-circuit", 1, "iron-plate", 2, "fast-inserter", 1 } },
	}
	block{
		name = bus.name, icon = HD_ICON .. bus.name .. ".png", icon_size = 64,
		description = { "entity-description." .. bus.name },
		--- walkable like the cable (issue #129): drawn under the character
		extra = { picture = bus_picture(bus.name), render_layer = "lower-object", collision_mask = WALKABLE },
	}
end

--------------------------------------------------------------------------------
--- ME UNDERGROUND CABLE (rotatable pair, like the underground pipe: the direction points along the run;
--- above ground an end connects only on its back side, under ground to the first end within reach that faces
--- it; runtime: scripts/fork-me-network.lua, find_partner)
--------------------------------------------------------------------------------

ME.add_item{
	name = UNDERGROUND,
	icon = HD_ICON .. UNDERGROUND .. ".png",
	icon_size = 64,
	subgroup = "fork-me-network",
	order = "a1",
	stack_size = 50,
	place_result = UNDERGROUND,
	recipe = { energy_required = 1, amount = 2, ingredients = I{ "fluix-cable", 8, "iron-plate", 2 } },   -- (not in AE2)
}
--- A real pipe-to-ground whose fluid box has its own connection category: it never connects to pipes or carries
--- fluid, but the engine pairs the ends exactly like underground pipes (reach, rotation, blocking, dragging) and
--- shows the pairing on hover and while placing. Its direction is the run's direction; the above ground
--- connection points backwards. The ME graph reads the engine's pairing (fluidbox.get_connections).
data:extend({ {
	type = "pipe-to-ground",
	name = UNDERGROUND,
	icon = HD_ICON .. UNDERGROUND .. ".png",
	icon_size = 64,
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
	pictures = four_way(UNDERGROUND, true),
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
	icon = HD_ICON .. STORAGE_BUS .. ".png",
	icon_size = 64,
	subgroup = "fork-me-network",
	order = "b4",
	stack_size = 50,
	place_result = STORAGE_BUS,
	recipe = { energy_required = 2, ingredients = I{ "me-interface", 1, "fast-inserter", 2 } },   -- (AE2: an interface, 2 pistons)
}
block{
	name = STORAGE_BUS, icon = HD_ICON .. STORAGE_BUS .. ".png", icon_size = 64,
	description = { "entity-description." .. STORAGE_BUS },
	extra = { picture = bus_picture(STORAGE_BUS), additional_pastable_entities = { STORAGE_BUS },
		render_layer = "lower-object", collision_mask = WALKABLE },
}



--------------------------------------------------------------------------------
--- ME TERMINAL (a lamp, as it always was: saves hold it by type and name; its GUI is replaced by the terminal GUI)
---
--- Issue #128: it needs no pole, the ME Controller draws its power (`member_power` of the mod-data below, W). A lamp
--- with a void energy source is always "on" and has no power connection. So it can show whether its network works,
--- both pictures of the lamp are empty and the screen is drawn by the script (scripts/fork-me-network.lua, "screens"): a
--- render object that follows the entity (the whole picture, casing included), lit while the network works and dark when it
--- does not, and a light that goes with it. A lamp always draws its `picture_off` and its `picture_on` on top of it when it
--- is lit (the vanilla lamp's `picture_on` is only the glow): a `picture_off` of the casing would cover the script's picture,
--- which lies below it (issue #139: the terminal stayed dark).
--- Issue #258: so that a ghost has a picture, the dark picture is the terminal's `stateless_visualisation`, drawn by the
--- game on the entity and on its ghost (`draw_stateless_visualisations_in_ghost`) in the layer `lower-object`; the script's
--- screen lies one layer above it (`lower-object-above-shadow`) and covers it, both below the character.
--------------------------------------------------------------------------------

local TERMINAL_POWER = 8000             -- W drawn through the ME Controller (issue #128: what it drew from a pole before)

local terminal = table.deepcopy(data.raw.lamp["small-lamp"])
terminal.name = "me-terminal"
terminal.icon = HD_ICON .. "me-terminal.png"
terminal.icon_size = 64
terminal.minable = { mining_time = 0.2, result = "me-terminal" }
terminal.max_health = 200
terminal.corpse = "small-remnants"
terminal.dying_explosion = nil
terminal.collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } }
terminal.selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } }
terminal.energy_source = { type = "void" }
terminal.energy_usage_per_tick = (TERMINAL_POWER / 1000) .. "kW"
terminal.always_on = true
terminal.collision_mask = WALKABLE         -- issue #129: walkable like the cable (its screen is drawn under the character)
terminal.light = nil
terminal.light_when_colored = nil
terminal.glow_size = 0
terminal.picture_off = util.empty_sprite()
terminal.picture_on = util.empty_sprite()
terminal.stateless_visualisation = { render_layer = "lower-object",
	animation = { filename = HD_ENTITY .. "me-terminal-off.png", priority = "high", width = 64, height = 64, scale = 0.5 } }
terminal.draw_stateless_visualisations_in_ghost = true
terminal.fast_replaceable_group = nil
terminal.next_upgrade = nil
terminal.localised_description = { "entity-description.me-terminal", tostring(TERMINAL_POWER / 1000) }
data:extend({ terminal })
data.raw.item["me-terminal"].place_result = "me-terminal"

--- the screen the script draws (render objects need sprite prototypes); the light is the game's
data:extend({
	{ type = "sprite", name = "me-terminal-screen-on", filename = HD_ENTITY .. "me-terminal-lit.png",
	  priority = "high", width = 64, height = 64, scale = 0.5 },
	{ type = "sprite", name = "me-terminal-screen-off", filename = HD_ENTITY .. "me-terminal-off.png",
	  priority = "high", width = 64, height = 64, scale = 0.5 },
})

--- The "open GUI" key: opens the ME window of a block (scripts/fork-me-gui.lua; works whether or not the
--- engine opens a window for the entity), or puts the cell in the cursor into a drive
data:extend({ {
	type = "custom-input",
	name = "fork-me-terminal-open",
	key_sequence = "",
	linked_game_control = "open-gui",
	consuming = "none",
} })

--- The confirm key (linked to the game's "confirm-gui", "E" by default): takes the choice of the mod's item picker in
--- (scripts/fork-me-picker.lua, issue #94), as it does for the game's own green buttons
data:extend({ {
	type = "custom-input",
	name = "fork-me-picker-confirm",
	key_sequence = "",
	linked_game_control = "confirm-gui",
	consuming = "none",
} })

--- The search key (linked to the game's "focus-search", Ctrl + F by default): focuses the search field of the ME Terminal
--- and of the mod's item picker (scripts/fork-me-picker.lua, issue #148); the game's own search fields keep it
data:extend({ {
	type = "custom-input",
	name = "fork-me-focus-search",
	key_sequence = "",
	linked_game_control = "focus-search",
	consuming = "none",
} })



--------------------------------------------------------------------------------
--- MOD DATA (read by scripts/fork-me-network.lua and fork-me-io.lua: no duplicated numbers)
--------------------------------------------------------------------------------

--- issue #264: where the script draws a cell's light (and, if a graphics mod gives sprites for it, the cell itself) on the
--- ME Drive and the ME Chest, in px of their 64 px picture (scale 0.5: 64 px a tile) from its top left; docs/API.md "The
--- drive view". These are the places on this mod's own pictures: the bays of tools/gen_ae2_sprites.py (DRIVE_BAY_X,
--- DRIVE_BAY_Y, CHEST_BAY, 32 px) on the face of the 3D style, which covers 54 of the 64 px (issue #218).
local VIEW_FACE = 54 / 64
local function view_px(v) return 2 * VIEW_FACE * v end
local DRIVE_BAYS = {}
for _, y in ipairs({ 4, 9, 14, 19, 24 }) do
	for _, x in ipairs({ 5, 17 }) do DRIVE_BAYS[#DRIVE_BAYS + 1] = { x = view_px(x), y = view_px(y) } end
end
local BAY_LIGHT = { x = view_px(1), y = view_px(1), w = view_px(8), h = view_px(2) }
local DRIVE_VIEW = {
	drive = { bays = DRIVE_BAYS, light = BAY_LIGHT },
	chest = { bays = { { x = view_px(11), y = view_px(22) } }, light = BAY_LIGHT },
}

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
			underground = UNDERGROUND, storage_bus = STORAGE_BUS, pattern_terminal = "me-pattern-terminal",
			chest = CHEST,
		},
		--- issue #229: the ME Chest's hidden parts and what it draws on its own
		chest = { power = CHEST_POWER, fluid = CHEST_FLUID, watts = CHEST_WATTS },
		--- issue #128: the power (W) the ME Controller draws for a block that has no power connection of its own, by kind;
		--- a kind that is not here draws the default (4 kW), a crafting block its own number (mod-data "fork-me-autocraft")
		member_power = { terminal = TERMINAL_POWER },
		underground_reach = UNDERGROUND_REACH,
		drive_view = DRIVE_VIEW,
		--- issue #278: how a graphics mod shows the ME Controller's state (docs/API.md "The controller view"): an Animation
		--- per state ("off", "on", "conflict") drawn over the controller's picture; this mod's own view is empty (its
		--- picture alone, whatever the state)
		controller_view = {},
		--- issue #282: where a bus's marker (its plate and arrows, a layer of its own) is drawn on its picture: the square of
		--- the 64 px picture that is its face, px from its top left (docs/API.md "The bus view"); this mod's own face
		bus_view = { x = 0, y = 0, size = BUS_FACE },
	},
} })



--------------------------------------------------------------------------------
--- TECHNOLOGIES (standalone: vanilla science; Gregtorio puts them on its tiers through ME_NETWORK.set_technology)
--------------------------------------------------------------------------------

--- the cable, the controller, the drive, interface, terminal, buses and the cells up to 16k
ME.add_technology{ name = "me-network", prerequisites = { "advanced-circuit", "lamp", "fast-inserter" }, unit = ME.unit(2, 300), recipes = {
	"fluix-cable", "me-controller", "me-chest", "me-drive", "me-interface", "me-terminal", "basic-storage-housing",
	"me-1k-storage-component", "me-4k-storage-component", "me-16k-storage-component",
	"me-1k-storage-cell", "me-4k-storage-cell", "me-16k-storage-cell", IMPORT_BUS, EXPORT_BUS, UNDERGROUND, STORAGE_BUS,
} }

ME.add_technology{ name = "me-storage-64k", prerequisites = { "me-network", "processing-unit" }, unit = ME.unit(3, 400),
	recipes = { "me-64k-storage-component", "me-64k-storage-cell" } }

ME.add_technology{ name = "me-storage-256k", prerequisites = { "me-storage-64k", "production-science-pack" },
	unit = ME.unit(4, 600), recipes = { "me-256k-storage-component", "me-256k-storage-cell" } }
