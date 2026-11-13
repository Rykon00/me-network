--------------------------------------------------------------------------------
--- SPACE EXPLORATION, the part that does not depend on the recipes setting (data.lua, whenever Space Exploration is
--- active, also with Gregtorio Continued and with the startup setting me-network-space-exploration-recipes off):
---
--- 1. Its procedural technology pass (prototypes/phase-3/technology-procedural.lua, in its data-final-fixes) reads the last
---    number in the name of every technology that is not its own as an upgrade level: string_to_simple_int("me-storage-64k")
---    is 64, a level of 13 and more means every science pack up to Deep Space Science 4 and a tenth of the count, and
---    data_util.tech_add_ingredients_with_prerequisites puts the pack technologies in front of it, so everything after ME 64k
---    Storage was behind Deep Space Science 4. The word "singularity" in a name adds Deep Space Science 1 as well. The pass
---    skips a technology whose name contains an entry of the global se_procedural_tech_exclusions (a plain substring search),
---    so every technology of this mod is entered there by its whole name (not the prefix "me-": that would also switch the
---    pass off for another mod's "flame-..." or "frame-..." technology).
--- 2. Space: its space-collision.lua gives the "space_tile" collision layer (cannot stand on space tiles: empty space,
---    space platform, spaceship floor) to every assembling machine, pipe-to-ground, storage tank and container that does
---    not say se_allow_in_space. An ME network is logistics and works in space like on land, so every entity of this mod
---    says so: the ME Molecular Assembler, the ME Underground Cable, and the hidden tanks and buffers of the ME Chest, the
---    ME Interface and the ME P2P tunnels (made by script, which would still work, but a blueprint or a clone of them
---    would not). The assembler has no productivity among its allowed effects and no "space-..." crafting category, so
---    Space Exploration makes no "-spaced" or "-grounded" twin of it that its runtime would swap in.
--- 3. Its character is smaller (prototypes/phase-3/character.lua: a collision box of -0.15 .. 0.15, the base game's is
---    -0.2 .. 0.2). The blocks of a Crafting CPU are one slab with a box of -0.35 .. 0.35 (issue #268: no gap a character
---    walks into), which leaves 0.3 tiles between two of them: exactly this character's width, so it fitted between them
---    (issue #705). With Space Exploration their box is -0.36 .. 0.36.
--- 4. The ME Space Molecular Assembler (issue #711, the maintainer's option A): a second ME Molecular Assembler for Space
---    Exploration's recipes of the category "space-crafting" (its space assembling machine's own: space belts and pipes,
---    the first science packs' parts). It is the same block made by the same function (ME_NETWORK.make_molecular_assembler
---    with a name): one tile, item recipes only, five Acceleration Cards, a member of the ME network that draws its power
---    through the controller, served by ME Pattern Providers next to it; its categories are the ME Molecular Assembler's and
---    "space-crafting". It stands only in space and not on a spaceship:
---      - like Space Exploration's own space machines it collides with ground and water tiles, so it is built on space
---        platform scaffold and plating only;
---      - Space Exploration makes a hidden "-grounded" twin of every machine with a "space-..." category that can stand on
---        spaceship floor, and swaps the two when a ship lands on a planet (its EntitySwap.swap_structure: the new entity is
---        made and the old one destroyed without an event). A block of the ME network is known by its unit number, so the
---        swap would take the assembler out of the network. With the spaceship layer in its mask no twin is made and it
---        cannot be built on a ship; a ship carries ME Molecular Assemblers.
---    Its recipe is an ME Molecular Assembler with heat shielding and low density structure (what Space Exploration's space
---    assembling machine adds to its base); its technology follows ME Autocrafting and Space Exploration's Space Assembling
---    with that technology's cost (the first one that unlocks a "space-crafting" recipe). Not with Gregtorio Continued (its
---    recipes are its own).
--------------------------------------------------------------------------------

local ME = ME_NETWORK

if not mods["gregtorio-continued"] and data.raw["recipe-category"]["space-crafting"] and spaceship_collision_layer then
	local NAME = "me-space-molecular-assembler"
	local TINT = { r = 0.62, g = 0.8, b = 1 }
	local function has(kind, name) return data.raw[kind] and data.raw[kind][name] ~= nil end
	local shielding = has("item", "se-heat-shielding") and "se-heat-shielding" or "steel-plate"
	ME.add_item{
		name = NAME,
		icon = ME.hd_icons .. "me-molecular-assembler.png",
		icon_size = 64,
		subgroup = "fork-me-autocrafting",
		order = "f2",
		stack_size = 10,
		place_result = NAME,
		fields = { icon = nil, icons = { { icon = ME.hd_icons .. "me-molecular-assembler.png", icon_size = 64, tint = TINT } } },
		recipe = { energy_required = 5, ingredients = {
			{ type = "item", name = "me-molecular-assembler", amount = 1 },
			{ type = "item", name = shielding, amount = 2 },
			{ type = "item", name = "low-density-structure", amount = 4 },
		} },
	}
	data.raw.item[NAME].icon = nil
	--- the entity: the ME Molecular Assembler as it is now, plus "space-crafting" (made again after the compatibility files
	--- remade the assembler, prototypes/compat/common.lua)
	ME.space_assembler = { name = NAME }
	function ME.space_assembler.make()
		local base = data.raw["assembling-machine"]["me-molecular-assembler"]
		local categories = { "space-crafting" }
		for _, c in pairs(base.crafting_categories or {}) do
			if c ~= "space-crafting" then categories[#categories + 1] = c end
		end
		ME.make_molecular_assembler{ name = NAME, base = "assembling-machine-2", crafting_categories = categories,
			crafting_speed = base.crafting_speed, energy_usage = base.energy_usage, tint = TINT,
			collision_mask = { layers = { ground_tile = true, water_tile = true, item = true, object = true, player = true,
				[spaceship_collision_layer] = true } } }
		ME.space_assembler.categories = categories
	end
	ME.space_assembler.make()
	local packs = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 }, { "chemical-science-pack", 1 } }
	if has("tool", "se-rocket-science-pack") then packs[#packs + 1] = { "se-rocket-science-pack", 1 } end
	local prerequisites = { "me-autocrafting" }
	if has("technology", "se-space-assembling") then prerequisites[#prerequisites + 1] = "se-space-assembling" end
	ME.add_technology{ name = "me-space-autocrafting", prerequisites = prerequisites,
		unit = { count = 100, time = 60, ingredients = packs }, recipes = { NAME } }
	--- (the picture of ME Autocrafting in the assembler's tint: no file of its own)
	local tech = data.raw.technology["me-space-autocrafting"]
	tech.icons = { { icon = ME.technology_path .. "me-autocrafting.png", icon_size = 256, tint = TINT } }
	tech.icon, tech.icon_size = nil, nil
end

se_procedural_tech_exclusions = se_procedural_tech_exclusions or {}
local excluded = {}
for _, name in ipairs(ME.technologies) do
	se_procedural_tech_exclusions[#se_procedural_tech_exclusions + 1] = name
	excluded[#excluded + 1] = name
end

--- every entity prototype of this mod: what an item of it places, and every prototype named "me-..." or "fork-me-..."
local placed = {}
for _, name in ipairs(ME.items) do
	for item_type in pairs(defines.prototypes.item) do
		local item = data.raw[item_type] and data.raw[item_type][name]
		if item and item.place_result then placed[item.place_result] = true end
	end
end
local in_space = {}
for entity_type in pairs(defines.prototypes.entity) do
	for name, prototype in pairs(data.raw[entity_type] or {}) do
		if placed[name] or name:sub(1, 3) == "me-" or name:sub(1, 8) == "fork-me-" then
			prototype.se_allow_in_space = true
			in_space[#in_space + 1] = name
		end
	end
end
table.sort(in_space)

--- 3. the blocks of a Crafting CPU (every prototype of their fast replaceable group)
local slab = {}
for _, prototype in pairs(data.raw["simple-entity-with-force"] or {}) do
	if prototype.fast_replaceable_group == "me-crafting-block" then
		prototype.collision_box = { { -0.36, -0.36 }, { 0.36, 0.36 } }
		slab[#slab + 1] = prototype.name
	end
end

--- what this file did, for devcheck (tools/devcheck/checkmod/data-final-fixes.lua, section SPACEEXPLORATION)
ME.space_exploration_early = { excluded = excluded, in_space = in_space, slab = slab }
