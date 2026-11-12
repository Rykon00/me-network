--- ME Network: the data-updates stage.

--- Issue #598: with Krastorio 2 (or Krastorio 2 Spaced Out) the network follows its materials and science tiers
--- (prototypes/compat/krastorio2.lua). Not with Gregtorio Continued, whose recipes and tiers win, and not when the startup
--- setting me-network-krastorio2-recipes is off (settings.lua makes it only when one of the two mods is active).
--- The recipes and the prerequisites of this mod as they are without a compatibility file, kept for the files below (Space
--- Exploration's starts from them where it replaces what Krastorio 2's made of a recipe or technology).
local ME = ME_NETWORK
ME.standalone = { recipes = {}, prerequisites = {} }
for _, name in ipairs(ME.recipes) do ME.standalone.recipes[name] = table.deepcopy(data.raw.recipe[name]) end
for _, name in ipairs(ME.technologies) do
	ME.standalone.prerequisites[name] = table.deepcopy(data.raw.technology[name] and data.raw.technology[name].prerequisites or {})
end

local k2_recipes = settings.startup["me-network-krastorio2-recipes"]
if (mods["Krastorio2"] or mods["Krastorio2-spaced-out"]) and not mods["gregtorio-continued"] and k2_recipes and k2_recipes.value then
	require("prototypes.compat.krastorio2")
end

--- With Space Exploration the network follows its materials and science tiers (prototypes/compat/space-exploration.lua). Not
--- with Gregtorio Continued, and not when the startup setting me-network-space-exploration-recipes is off (settings.lua makes it
--- only with Space Exploration). Space Exploration with Krastorio 2 is a combination Space Exploration supports itself: the
--- Krastorio 2 file above runs first (its early materials: quartz, glass, automation cores, inserter parts, rare metals), this
--- one on top of it (every technology from ME 64k Storage on, and the materials from the 256k component up).
local se_recipes = settings.startup["me-network-space-exploration-recipes"]
if mods["space-exploration"] and not mods["gregtorio-continued"] and se_recipes and se_recipes.value then
	require("prototypes.compat.space-exploration")
end
