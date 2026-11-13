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
--------------------------------------------------------------------------------

local ME = ME_NETWORK

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
