--------------------------------------------------------------------------------
--- ME NETWORK: UPGRADE CARDS (me-network issue #17; design: docs/ME-REWORK.md "Upgrade cards, storage bus settings,
--- the Cell Workbench and priorities", guide: docs/AE2.md)
--- AE2's cards: two components (basic and advanced card) and the cards made from one of them plus one item. A card
--- goes into a card slot of an ME Storage Bus (its window) or of a storage cell (the ME Cell Workbench). The names
--- start with "me-": Gregtorio Continued has items called advanced-card and acceleration-card of its own.
--- AE2's numbers (its source, forge/1.20.1: init/internal/InitUpgrades.java, parts/storagebus/StorageBusPart.java,
--- items/storage/BasicStorageCell.java) reach the runtime through the mod-data "fork-me-network" (data.cards).
--------------------------------------------------------------------------------

local ME = ME_NETWORK
local ICON_FORK = ME.icons .. "fork/"

local function I(list) local t = {} for i = 1, #list, 2 do t[#t + 1] = { type = "item", name = list[i], amount = list[i + 1] } end return t end

data:extend({ { type = "module-category", name = ME.ACCELERATION } })      -- issue #110

--- name, order, recipe; `kind`: what the card does at runtime (nil: a component)
local CARDS = {
	--- AE2 (issue #233; prototypes/network.lua, the stand-ins): 2 gold, 3 iron, a redstone, a calculation processor -> 2; the
	--- advanced card 2 diamonds instead of the gold
	{ name = "me-basic-card", order = "a", amount = 2,
	  ingredients = I{ "copper-plate", 2, "iron-plate", 3, "copper-cable", 1, "advanced-circuit", 1 } },
	{ name = "me-advanced-card", order = "b", amount = 2,
	  ingredients = I{ "processing-unit", 2, "iron-plate", 3, "copper-cable", 1, "advanced-circuit", 1 } },
	{ name = "me-capacity-card", order = "c", kind = "capacity", ingredients = I{ "me-basic-card", 1, "stone", 1 } },   -- (certus)
	{ name = "me-overflow-destruction-card", order = "d", kind = "void",
	  ingredients = I{ "me-basic-card", 1, "advanced-circuit", 1 } },
	{ name = "me-fuzzy-card", order = "e", kind = "fuzzy", ingredients = I{ "me-advanced-card", 1, "copper-cable", 1 } },
	--- issue #156: AE2-Unofficial's Pattern Capacity Card (Upgrades.PATTERN_CAPACITY): 9 more pattern slots in an ME Pattern
	--- Provider each, up to 3; the storage Capacity Card does not work there and this one only where there are patterns
	{ name = "me-pattern-capacity-card", order = "e2", kind = "pattern_capacity",                  -- (AE2-Unofficial's recipe)
	  ingredients = I{ "me-advanced-card", 1, "me-16k-storage-component", 2, "me-interface", 1 } },
	--- issue #196: an ME Interface Capacity Card: 9 more config rows in an ME Interface each, up to 3 (option (b) of the issue:
	--- AE2's interface has no such card; its pattern slots are the Pattern Provider's here)
	{ name = "me-interface-capacity-card", order = "e3", kind = "interface_capacity",
	  ingredients = I{ "me-advanced-card", 1, "me-capacity-card", 1 } },
	--- issue #193: AE2-Unofficial's Sticky Card (Upgrades.STICKY): a cell or storage bus with it gets an item it already holds
	--- (or is partitioned for) before every other storage, whatever the priorities (NetworkInventoryHandler's sticky pass)
	--- (AE2-Unofficial: a basic card and a slimeball, which has no stand-in: an iron chest, as before)
	{ name = "me-sticky-card", order = "e4", kind = "sticky", ingredients = I{ "me-basic-card", 1, "iron-chest", 1 } },
	--- issue #354: AE2-Unofficial's Ore Dictionary Filter Card (Upgrades.ORE_FILTER; recipe: an advanced card and a book,
	--- materials/cards.recipe): here the Group Filter Card, a text over the item's name, subgroup and group
	--- (scripts/fork-me-groupfilter.lua) in place of the filter slots, on item cells, the storage bus and (issue #363) the import
	--- and export bus (AE2-U: no ore filter on fluid cells). The book's stand-in: a constant combinator (a list written down).
	{ name = "me-group-filter-card", order = "e5", kind = "gfilter",
	  ingredients = I{ "me-advanced-card", 1, "constant-combinator", 1 } },
	--- issue #411: AE2's Crafting Card (Upgrades.CRAFTING; recipe: a basic card and a crafting table, materials/cards.recipe): an
	--- export bus whose filtered item the network lacks, or an ME Interface whose row it cannot fill, starts a crafting job for
	--- it. The crafting table's stand-in: an assembling machine 1.
	{ name = "me-crafting-card", order = "e6", kind = "crafting",
	  ingredients = I{ "me-basic-card", 1, "assembling-machine-1", 1 } },
	{ name = "me-inverter-card", order = "f", kind = "inverter",
	  ingredients = I{ "me-advanced-card", 1, "decider-combinator", 1 } },
	{ name = "me-equal-distribution-card", order = "g", kind = "equal",
	  ingredients = I{ "me-advanced-card", 1, "advanced-circuit", 1 } },
	--- issue #110: AE2's Acceleration Card (Upgrades.SPEED), a module so that the ME Molecular Assembler's module slots show
	--- it (the game draws them): +80 % crafting speed and +80 % power per card, five cards 5 times as fast at 5 times the
	--- power, which is AE2's assembler at its five cards (progress 50 of 10, power 5.0 times). The first cards are stronger
	--- in the game than AE2's table (1.3, 1.7, 2.0, 2.5, 5.0 times); a module's effect is the same for every card.
	{ name = "me-acceleration-card", order = "h", kind = "speed", fields = {
		category = ME.ACCELERATION, tier = 1, effect = { speed = 0.8, consumption = 0.8 } },
	  ingredients = I{ "me-advanced-card", 1, "copper-cable", 1 } },                                  -- (a fluix crystal)
	--- issue #356: AE2-Unofficial's Super Speed Card and Superluminal Speed Card (Upgrades.SUPERSPEED, SUPERLUMINALSPEED;
	--- MaterialType CardSuperSpeed, CardSuperluminalSpeed): the import and export bus take up to 4 of each, mixed with
	--- Acceleration Cards in their 4 slots, and the items per operation add up (`bus` below). AE2-U's recipes
	--- (materials/cards.recipe): an Acceleration Card and a 16k storage component; a Super Speed Card and a 1024k component
	--- (issue #414: ME Network has it now; before, 4 256k components, the same bytes)
	{ name = "me-super-speed-card", order = "h2", kind = "superspeed",
	  ingredients = I{ "me-acceleration-card", 1, "me-16k-storage-component", 1 } },
	{ name = "me-superluminal-speed-card", order = "h3", kind = "superluminal",
	  ingredients = I{ "me-super-speed-card", 1, "me-1024k-storage-component", 1 } },
}

--- issue #474: the capacity and speed cards have a row of their own in the tab (the cards were more than one row)
local CAPACITY_SPEED = { capacity = true, pattern_capacity = true, interface_capacity = true, speed = true, superspeed = true,
	superluminal = true }
local kinds = {}
local recipes = {}
for _, c in ipairs(CARDS) do
	ME.add_item{
		type = c.fields and "module" or nil,
		fields = c.fields,
		name = c.name,
		icon = ME.hd_icons .. c.name .. ".png",          -- (issue #221: the 3D style, 64 px)
		icon_size = 64,
		subgroup = CAPACITY_SPEED[c.kind] and "fork-me-capacity-speed-cards" or "fork-me-cards",   -- (issue #474: two rows)
		order = c.order,
		stack_size = 50,
		localised_description = { "item-description." .. c.name },
		recipe = { energy_required = 2, amount = c.amount, ingredients = c.ingredients },
	}
	if c.kind then kinds[c.name] = c.kind end
	if c.name ~= "me-superluminal-speed-card" then recipes[#recipes + 1] = c.name end
end
--- issue #594: the Superluminal Speed Card takes a 1024k component, so ME 1024k Storage unlocks it (it was the cards
--- technology's, which comes much earlier) and has the cards technology as a prerequisite (the Super Speed Card)
do
	local tech = data.raw.technology["me-storage-1024k"]
	data.raw.recipe["me-superluminal-speed-card"].enabled = false
	table.insert(tech.effects, { type = "unlock-recipe", recipe = "me-superluminal-speed-card" })
	table.insert(tech.prerequisites, "me-upgrade-cards")
end

--- The card slots and how many of each kind a block takes (AE2: StorageBusPart.getUpgradeSlots(), BasicStorageCell
--- .getUpgrades(), InitUpgrades.init()); the filters of a storage bus: 18 + 9 per capacity card (StorageBusPart
--- .createFilter())
data.raw["mod-data"]["fork-me-network"].data.cards = {
	kinds = kinds,
	storage_bus = { slots = 5, limits = { capacity = 5, fuzzy = 1, inverter = 1, void = 1, sticky = 1, gfilter = 1 }, filters = 18, per_capacity = 9 },
	item_cell = { slots = 4, limits = { fuzzy = 1, inverter = 1, equal = 1, void = 1, sticky = 1, gfilter = 1 } },
	fluid_cell = { slots = 3, limits = { inverter = 1, equal = 1, void = 1, sticky = 1 } },
	--- issue #440: a view cell takes 2 cards (AE2-Unofficial: ItemViewCell.getUpgradesInventory, CellUpgrades(is, 2)): a Fuzzy
	--- and an Inverter Card
	view_cell = { slots = 2, limits = { fuzzy = 1, inverter = 1 } },
	--- issue #110: the ME Import Bus and Export Bus take up to 4 Acceleration Cards (AE2's upgrade slots of the buses: its speed
	--- cards, PartImportBus / PartExportBus); `speed`: by the number of cards, the factor on the items per second of the map
	--- setting "bus speed" (AE2: 1, 8, 32, 64, 96 items per operation). Issue #356: up to 4 Super Speed and 4 Superluminal Speed
	--- Cards too, in the same 4 slots; `superspeed` and `superluminal`: by the number of each, what they add to that factor
	--- (AE2-U: PartExportBus.calculateAmountToSend, the kinds add up)
	--- Issue #413: the Capacity Card (up to 2, AE2-U: Registration.java, `parts.importBus()` / `parts.exportBus()`) and the
	--- Fuzzy Card (1); `filters` filters and `per_capacity` more with each Capacity Card (9 / 18 / 27; AE2-U: 1 / 5 / 9, but
	--- the buses here had 9 from the start). `import_bus`: the import bus's rules, the same and one Inverter Card (AE2-U has
	--- no inverter on the buses: an addition of this mod, its filters become a blacklist)
	--- (issue #411: the Crafting Card, 1, on the export bus only, AE2-U: `parts.exportBus()`)
	bus = { slots = 4, limits = { speed = 4, superspeed = 4, superluminal = 4, gfilter = 1, capacity = 2, fuzzy = 1,
		crafting = 1 }, filters = 9, per_capacity = 9 },
	import_bus = { slots = 4, limits = { speed = 4, superspeed = 4, superluminal = 4, gfilter = 1, capacity = 2, fuzzy = 1,
		inverter = 1 }, filters = 9, per_capacity = 9 },
	--- issue #386: the ME IO Port takes the speed cards of the buses (AE2's IO port: speed cards), with the same factors
	io_port = { slots = 4, limits = { speed = 4, superspeed = 4, superluminal = 4 } },
	superspeed = { 16, 128, 1024, 8192 },
	superluminal = { 131072, 1048576, 8388608, 67108864 },
	--- issue #156: the ME Pattern Provider takes up to 3 Pattern Capacity Cards (AE2-U: Registration.java, `blocks.iface()`, 3);
	--- it has `patterns` pattern slots and `per_capacity` more with each card (9 / 18 / 27 / 36)
	provider = { slots = 3, limits = { pattern_capacity = 3 }, patterns = 9, per_capacity = 9 },
	--- issue #196: the ME Interface takes up to 3 Interface Capacity Cards: `rows` config rows and `per_capacity` more with each
	--- issue #411: and the Crafting Card (1) in a fourth slot (AE2-U's interface: 4 upgrade slots, DualityInterface; a script
	--- inventory of 3 slots of an older save is made bigger when it is first read, scripts/fork-me-cardslots.lua)
	interface = { slots = 4, limits = { interface_capacity = 3, crafting = 1 }, rows = 9, per_capacity = 9 },
	speed = { 1, 8, 32, 64, 96 },
}

--- The ME Cell Workbench (part 3 of issue #17): one cell, its partition and its card slots. AE2's workbench needs
--- neither the network nor power (blockentity/misc/CellWorkbenchBlockEntity.java extends AEBaseBlockEntity): no ME
--- member, no power (scripts/fork-me-workbench.lua). AE2's recipe: 2 wool, a calculation processor, 5 iron, a wooden chest
--- (issue #233; prototypes/network.lua, the stand-ins).
ME.add_item{
	name = "me-cell-workbench",
	icon = ME.hd_icons .. "me-cell-workbench.png",
	icon_size = 64,
	subgroup = "fork-me-drives",
	order = "d",
	stack_size = 10,
	place_result = "me-cell-workbench",
	recipe = { energy_required = 2, ingredients = I{ "copper-cable", 2, "advanced-circuit", 1, "iron-plate", 5, "wooden-chest", 1 } },
}
data:extend({ {
	type = "simple-entity-with-force",
	name = "me-cell-workbench",
	icon = ME.hd_icons .. "me-cell-workbench.png",
	icon_size = 64,
	flags = { "placeable-neutral", "player-creation" },
	minable = { mining_time = 0.2, result = "me-cell-workbench" },
	placeable_by = { item = "me-cell-workbench", count = 1 },
	max_health = 150,
	is_military_target = false,
	corpse = "small-remnants",
	collision_box = ME.solid_box(),                   -- (issue #268)
	selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
	picture = { layers = {
		{ filename = ME.hd_entity_path .. "me-cell-workbench.png", priority = "high", width = 64, height = 64, scale = 0.5 },
		--- its shadow: tools/gen_ae2_sprites.py WORKBENCH_SHADOW (6, 4) px to the east and the south, the PNG's top left
		--- at the block's top left
		{ filename = ME.entity_path .. "me-cell-workbench-shadow.png", priority = "high", width = 38, height = 36,
		  shift = { 3 / 32, 2 / 32 }, draw_as_shadow = true },
	} },
	localised_description = { "entity-description.me-cell-workbench" },
} })
recipes[#recipes + 1] = "me-cell-workbench"

--- Issue #440: AE2's View Cell (AE2-Unofficial: items/storage/ItemViewCell.java; scripts/fork-me-viewcells.lua): a list of
--- items and fluids for the ME Terminal's storage list, partitioned in the workbench. AE2-Unofficial's recipe
--- (network/cells/view.recipe, shapeless): a certus quartz crystal and a storage housing; the stand-ins of issue #233 (certus
--- quartz = stone). Its spec is in `view_cells`, never in `cells`: it stores nothing.
ME.add_item{
	type = "item-with-tags",
	name = "me-view-cell",
	icon = ME.hd_icons .. "basic-storage-housing.png",
	icon_size = 64,
	--- (the storage housing in blue: no picture of its own; the texture mod could give it AE2-Unofficial's ItemViewCell)
	fields = { icons = { { icon = ME.hd_icons .. "basic-storage-housing.png", icon_size = 64, tint = { 0.55, 0.85, 1, 1 } } } },
	subgroup = "fork-me-special-cells",
	order = "a",
	stack_size = 1,
	recipe = { energy_required = 1, ingredients = I{ "basic-storage-housing", 1, "stone", 1 } },
}
data.raw["mod-data"]["fork-me-network"].data.view_cells = { ["me-view-cell"] = { view = true, kind = "view", types = 63, bytes = 0 } }
recipes[#recipes + 1] = "me-view-cell"

--- Issue #561: the ME Memory Card (AE2's ToolMemoryCard), a selection tool here: select one ME block = copy its settings (what its
--- blueprint tags carry, a provider's patterns too) onto the card; alt-select = paste them onto every block of that name in the
--- area; a select without an ME block empties it (scripts/fork-me-memorycard.lua). AE2-Unofficial's recipe
--- (recipes/tools/network.recipe): a calculation processor, 2 iron, 2 gold, a redstone. Unlocked with ME Network (below).
ME.add_item{
	type = "selection-tool",
	name = "me-memory-card",
	icon = ME.hd_icons .. "me-memory-card.png",
	icon_size = 64,
	subgroup = "fork-me-cards",
	order = "z",
	stack_size = 1,
	localised_description = { "item-description.me-memory-card" },
	fields = {
		flags = { "not-stackable" },
		select = { border_color = { 0.27, 0.67, 0.96 }, cursor_box_type = "copy", mode = { "same-force", "any-entity" } },
		alt_select = { border_color = { 0.96, 0.75, 0.2 }, cursor_box_type = "pair", mode = { "same-force", "any-entity" } },
	},
	recipe = { energy_required = 2, ingredients = I{ "advanced-circuit", 1, "iron-plate", 2, "copper-plate", 2, "copper-cable", 1 } },
}
do
	local tech = data.raw.technology["me-network"]
	data.raw.recipe["me-memory-card"].enabled = false
	table.insert(tech.effects, { type = "unlock-recipe", recipe = "me-memory-card" })
end

--- after ME 64k Storage (the advanced card needs a processing unit); its cost follows that technology in
--- data-final-fixes.lua unless another mod sets it (ME_NETWORK.set_technology)
ME.add_technology{ name = "me-upgrade-cards", prerequisites = { "me-storage-64k", "circuit-network" }, unit = ME.unit(3, 400), recipes = recipes }
