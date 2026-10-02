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
	{ name = "me-inverter-card", order = "f", kind = "inverter",
	  ingredients = I{ "me-advanced-card", 1, "decider-combinator", 1 } },
	{ name = "me-equal-distribution-card", order = "g", kind = "equal",
	  ingredients = I{ "me-advanced-card", 1, "advanced-circuit", 1 } },
}

local kinds = {}
local recipes = {}
for _, c in ipairs(CARDS) do
	ME.add_item{
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
}

--- after ME 64k Storage (the advanced card needs a processing unit); its cost follows that technology in
--- data-final-fixes.lua unless another mod sets it (ME_NETWORK.set_technology)
ME.add_technology{ name = "me-upgrade-cards", prerequisites = { "me-storage-64k" }, unit = ME.unit(3, 400), recipes = recipes }
