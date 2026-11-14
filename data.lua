--- ME Network: an ME storage network with autocrafting and fluids, inspired by Applied Energistics 2.

--- Gregtorio Continued before 0.5.0 contains this network itself (same prototypes, same scripts). It does not depend
--- on this mod, so it loads first and has made the mod-data "fork-me-network" by now: refuse to run both.
if data.raw["mod-data"] and data.raw["mod-data"]["fork-me-network"] then
	error("\n\nME Network: this version of Gregtorio Continued (before 0.5.0) contains its own ME network.\n"
		.. "Update Gregtorio Continued to 0.5.0 or later (it hands its ME network over to ME Network), or disable ME Network.\n")
end

require("prototypes.api")
require("prototypes.network")
require("prototypes.autocrafting")
require("prototypes.fluids")
require("prototypes.cards")
require("prototypes.wireless")
require("prototypes.connector")                   -- (issue #412: the old circuit connector, kept for saves and blueprints, #628)
require("prototypes.paste").apply()               -- (issue #519: the settings paste of every block)

--- A collision mask is a table of its prototype alone: the blocks that are walked over were given the one table
--- ME_NETWORK.WALKABLE, and a mod that changes the mask of one prototype in place changed them all (Space Exploration adds
--- its "cannot stand in space" layer to every pipe-to-ground, the ME Underground Cable among them, and so kept the ME Cable,
--- the buses and the ME Terminal out of space).
for entity_type in pairs(defines.prototypes.entity) do
	for _, prototype in pairs(data.raw[entity_type] or {}) do
		if prototype.collision_mask == ME_NETWORK.WALKABLE then prototype.collision_mask = table.deepcopy(ME_NETWORK.WALKABLE) end
	end
end

--- Space Exploration: what must be said before its data-final-fixes (prototypes/compat/space-exploration-early.lua); the
--- recipes and technologies on its materials and tiers follow in data-updates.lua.
if mods["space-exploration"] then require("prototypes.compat.space-exploration-early") end
