--- ME Network: the last data stage.

--- Issue #3: the old fluid blocks (ME_NETWORK.removed: ME Fluid Interface, ME Fluid Import / Export / Storage Bus) are
--- made by no recipe. A mod that makes a recipe for one of them itself (Gregtorio Continued 0.5.0 does, in its
--- prototypes/120-fork-me-network-compat.lua) loses that recipe here, and every technology loses its unlock (issue #146:
--- the items are gone, so such a recipe would stop the game from loading; migrations/me-network-old-fluid-blocks.json
--- turns a stray item into the unified one). The legacy Crafting CPUs (issue #145) are in ME_NETWORK.removed too.
local ME = ME_NETWORK
local function makes_removed(recipe)
	if ME.removed[recipe.name] then return true end
	for _, r in pairs(recipe.results or {}) do
		if (r.type == nil or r.type == "item") and ME.removed[r.name] then return true end
	end
	return false
end
local gone = {}
for name, recipe in pairs(data.raw.recipe) do
	if makes_removed(recipe) then gone[#gone + 1] = name end
end
table.sort(gone)
for _, name in ipairs(gone) do
	log("ME-NETWORK: recipe " .. name .. " makes an item that is no longer made, removed")
	ME.remove_recipe(name)
end

--- Issue #12: a crafting machine's recipe pasted onto the ME Interface, the import, export and storage bus
--- (scripts/fork-me-recipe-paste.lua). The game raises on_entity_settings_pasted for such a pair only when the
--- source prototype lists the target in additional_pastable_entities, so every crafting machine of every mod gets
--- the four blocks added to its list (what other mods put there stays).
local PASTE_TARGETS = { "me-network-interface", "me-import-bus", "me-export-bus", "me-storage-bus" }
for _, machine_type in pairs({ "assembling-machine", "furnace", "rocket-silo" }) do
	for _, machine in pairs(data.raw[machine_type] or {}) do
		local list = machine.additional_pastable_entities or {}
		local listed = {}
		for _, name in pairs(list) do listed[name] = true end
		for _, name in ipairs(PASTE_TARGETS) do
			if not listed[name] then list[#list + 1] = name end
		end
		machine.additional_pastable_entities = list
	end
end

--- Issue #110: the Acceleration Card is a module (the ME Molecular Assembler's module slots show it), and a machine without
--- `allowed_module_categories` takes every category: so every machine and beacon that has module slots and no list gets one
--- with every module category of the game but this mod's. A list another mod made already (Gregtorio Continued gives its
--- machines "every category but mold" in its data stage, which names this mod's category too) loses this mod's category. The
--- ME Molecular Assembler is the one machine that keeps it (its list is only the card). A category another mod adds in its own
--- data-final-fixes, after this one, is not in the lists made here: such a mod lists its machines itself.
do
	local categories = {}
	for name in pairs(data.raw["module-category"] or {}) do
		if name ~= ME.ACCELERATION then categories[#categories + 1] = name end
	end
	table.sort(categories)
	for _, prototypes_of_type in pairs(data.raw) do
		for name, entity in pairs(prototypes_of_type) do
			if type(entity) == "table" and type(entity.module_slots) == "number" and entity.module_slots > 0 and name ~= "me-molecular-assembler" then
				if entity.allowed_module_categories == nil then
					entity.allowed_module_categories = table.deepcopy(categories)
				else
					local kept = {}
					for _, category in ipairs(entity.allowed_module_categories) do
						if category ~= ME.ACCELERATION then kept[#kept + 1] = category end
					end
					entity.allowed_module_categories = kept
				end
			end
		end
	end
end

--- Issue #17: the upgrade cards technology costs what ME 64k Storage costs (its prerequisite), unless a mod set it
--- itself (ME_NETWORK.set_technology). A mod that puts the network on its own tiers (Gregtorio Continued) thereby gets a
--- researchable cards technology on the 64k tier before it knows about the cards.
local cards_tech, storage_64k = data.raw.technology["me-upgrade-cards"], data.raw.technology["me-storage-64k"]
if cards_tech and storage_64k and not ME.customized["me-upgrade-cards"] then
	cards_tech.unit = table.deepcopy(storage_64k.unit)
	cards_tech.research_trigger = table.deepcopy(storage_64k.research_trigger)
	if cards_tech.research_trigger then cards_tech.unit = nil end
	cards_tech.prerequisites = { "me-storage-64k" }
end

--- Issue #6: a crafting block recipe (the multiblock crafting CPUs) that no technology unlocks, because another mod
--- replaced the recipe list of its technology (ME_NETWORK.set_technology: Gregtorio Continued sets me-autocrafting,
--- me-co-processing and me-quantum-crafting), is unlocked by its technology of this mod again; a mod that gives the
--- recipe to a technology of its own keeps that.
local unlocked = {}
for _, tech in pairs(data.raw.technology) do
	for _, e in pairs(tech.effects or {}) do
		if e.type == "unlock-recipe" then unlocked[e.recipe] = true end
	end
end
local blocks = {}
for name in pairs(ME.crafting_block_tech or {}) do blocks[#blocks + 1] = name end
table.sort(blocks)
for _, name in ipairs(blocks) do
	local tech = data.raw.technology[ME.crafting_block_tech[name]]
	if data.raw.recipe[name] and not unlocked[name] and tech then
		tech.effects = tech.effects or {}
		tech.effects[#tech.effects + 1] = { type = "unlock-recipe", recipe = name }
		data.raw.recipe[name].enabled = false
	end
end

--- Issue #110: the Acceleration Card is unlocked by the cards technology in the same way: a mod that replaced that technology's
--- recipe list (Gregtorio Continued does) has not heard of a card this mod added later, so the card's recipe, its own
--- (Gregtorio's compat file gives it the GregTech ingredients) or ours, is unlocked there as well.
--- Issue #156: the same for the Pattern Capacity Card.
for _, name in ipairs({ "me-acceleration-card", "me-pattern-capacity-card", "me-interface-capacity-card" }) do
	local tech, recipe = data.raw.technology["me-upgrade-cards"], data.raw.recipe[name]
	if tech and recipe and not unlocked[name] then
		tech.effects = tech.effects or {}
		tech.effects[#tech.effects + 1] = { type = "unlock-recipe", recipe = name }
		recipe.enabled = false
	end
end
