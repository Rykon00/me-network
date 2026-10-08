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

data:extend({ { type = "item-subgroup", name = "fork-me-cards", group = data.raw["item-subgroup"]["fork-me-network"].group,
	order = "b-me-d" } })
data:extend({ { type = "module-category", name = ME.ACCELERATION } })      -- issue #110

--- name, order, recipe; `kind`: what the card does at runtime (nil: a component)
local CARDS = {
	{ name = "me-basic-card", order = "a", amount = 2,
	  ingredients = I{ "iron-plate", 2, "copper-cable", 2, "electronic-circuit", 1, "advanced-circuit", 1 } },
	{ name = "me-advanced-card", order = "b", amount = 2,
	  ingredients = I{ "iron-plate", 2, "processing-unit", 1, "electronic-circuit", 1, "advanced-circuit", 1 } },
	{ name = "me-capacity-card", order = "c", kind = "capacity", ingredients = I{ "me-basic-card", 1, "iron-chest", 1 } },
	{ name = "me-overflow-destruction-card", order = "d", kind = "void",
	  ingredients = I{ "me-basic-card", 1, "advanced-circuit", 1 } },
	{ name = "me-fuzzy-card", order = "e", kind = "fuzzy", ingredients = I{ "me-advanced-card", 1, "copper-cable", 1 } },
	--- issue #156: AE2-Unofficial's Pattern Capacity Card (Upgrades.PATTERN_CAPACITY): 9 more pattern slots in an ME Pattern
	--- Provider each, up to 3; the storage Capacity Card does not work there and this one only where there are patterns
	{ name = "me-pattern-capacity-card", order = "e2", kind = "pattern_capacity",
	  ingredients = I{ "me-advanced-card", 1, "me-capacity-card", 1 } },
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
	  ingredients = I{ "me-advanced-card", 1, "processing-unit", 1 } },
}

local kinds = {}
local recipes = {}
for _, c in ipairs(CARDS) do
	ME.add_item{
		type = c.fields and "module" or nil,
		fields = c.fields,
		name = c.name,
		icon = ICON_FORK .. c.name .. ".png",
		subgroup = "fork-me-cards",
		order = c.order,
		stack_size = 64,
		localised_description = { "item-description." .. c.name },
		recipe = { energy_required = 2, amount = c.amount, ingredients = c.ingredients },
	}
	if c.kind then kinds[c.name] = c.kind end
	recipes[#recipes + 1] = c.name
end

--- The card slots and how many of each kind a block takes (AE2: StorageBusPart.getUpgradeSlots(), BasicStorageCell
--- .getUpgrades(), InitUpgrades.init()); the filters of a storage bus: 18 + 9 per capacity card (StorageBusPart
--- .createFilter())
data.raw["mod-data"]["fork-me-network"].data.cards = {
	kinds = kinds,
	storage_bus = { slots = 5, limits = { capacity = 5, fuzzy = 1, inverter = 1, void = 1 }, filters = 18, per_capacity = 9 },
	item_cell = { slots = 4, limits = { fuzzy = 1, inverter = 1, equal = 1, void = 1 } },
	fluid_cell = { slots = 3, limits = { inverter = 1, equal = 1, void = 1 } },
	--- issue #110: the ME Import Bus and Export Bus take up to 4 Acceleration Cards (AE2's upgrade slots of the buses: its speed
	--- cards, PartImportBus / PartExportBus); `speed`: by the number of cards, the factor on the items per second of the map
	--- setting "bus speed" (AE2: 1, 8, 32, 64, 96 items per operation)
	bus = { slots = 4, limits = { speed = 4 } },
	--- issue #156: the ME Pattern Provider takes up to 3 Pattern Capacity Cards (AE2-U: Registration.java, `blocks.iface()`, 3);
	--- it has `patterns` pattern slots and `per_capacity` more with each card (9 / 18 / 27 / 36)
	provider = { slots = 3, limits = { pattern_capacity = 3 }, patterns = 9, per_capacity = 9 },
	speed = { 1, 8, 32, 64, 96 },
}

--- The ME Cell Workbench (part 3 of issue #17): one cell, its partition and its card slots. AE2's workbench needs
--- neither the network nor power (blockentity/misc/CellWorkbenchBlockEntity.java extends AEBaseBlockEntity): no ME
--- member, no power (scripts/fork-me-workbench.lua). AE2's recipe (crafting table, 2 white wool, calculation processor,
--- 4 iron ingots, chest) as vanilla items that Gregtorio Continued has too.
ME.add_item{
	name = "me-cell-workbench",
	icon = ICON_FORK .. "me-cell-workbench.png",
	subgroup = "fork-me-cards",
	order = "z",
	stack_size = 10,
	place_result = "me-cell-workbench",
	recipe = { energy_required = 2, ingredients = I{ "iron-chest", 1, "iron-plate", 4, "advanced-circuit", 1, "electronic-circuit", 2 } },
}
data:extend({ {
	type = "simple-entity-with-force",
	name = "me-cell-workbench",
	icon = ICON_FORK .. "me-cell-workbench.png",
	icon_size = 32,
	flags = { "placeable-neutral", "player-creation" },
	minable = { mining_time = 0.2, result = "me-cell-workbench" },
	placeable_by = { item = "me-cell-workbench", count = 1 },
	max_health = 150,
	is_military_target = false,
	corpse = "small-remnants",
	collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } },
	selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
	picture = { layers = {
		{ filename = ME.entity_path .. "me-cell-workbench.png", priority = "high", width = 32, height = 32 },
		--- its shadow: tools/gen_ae2_sprites.py WORKBENCH_SHADOW (6, 4) px to the east and the south, the PNG's top left
		--- at the block's top left
		{ filename = ME.entity_path .. "me-cell-workbench-shadow.png", priority = "high", width = 38, height = 36,
		  shift = { 3 / 32, 2 / 32 }, draw_as_shadow = true },
	} },
	localised_description = { "entity-description.me-cell-workbench" },
} })
recipes[#recipes + 1] = "me-cell-workbench"

--- after ME 64k Storage (the advanced card needs a processing unit); its cost follows that technology in
--- data-final-fixes.lua unless another mod sets it (ME_NETWORK.set_technology)
ME.add_technology{ name = "me-upgrade-cards", prerequisites = { "me-storage-64k" }, unit = ME.unit(3, 400), recipes = recipes }
