--- ME Network: the data-updates stage.

--- Issue #598: with Krastorio 2 (or Krastorio 2 Spaced Out) the network follows its materials and science tiers
--- (prototypes/compat/krastorio2.lua). Not with Gregtorio Continued, whose recipes and tiers win, and not when the startup
--- setting me-network-krastorio2-recipes is off (settings.lua makes it only when one of the two mods is active).
local k2_recipes = settings.startup["me-network-krastorio2-recipes"]
if (mods["Krastorio2"] or mods["Krastorio2-spaced-out"]) and not mods["gregtorio-continued"] and k2_recipes and k2_recipes.value then
	require("prototypes.compat.krastorio2")
end
