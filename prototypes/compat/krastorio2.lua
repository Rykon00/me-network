--------------------------------------------------------------------------------
--- KRASTORIO 2 (issue #598): the ME network on Krastorio 2's materials and science tiers
---
--- Krastorio 2 (and Krastorio 2 Spaced Out) is not our mod, so this mod carries the compatibility itself, the way Gregtorio
--- Continued carries its own in its prototypes/120-fork-me-network-compat.lua: only through ME_NETWORK.replace_recipe and
--- ME_NETWORK.set_technology, no prototype renamed, nothing at runtime. data-updates.lua requires this file when one of the
--- two mods is active, Gregtorio Continued is not (its recipes win) and the startup setting me-network-krastorio2-recipes
--- is on. It runs in our data-updates, after Krastorio 2's (the hidden optional dependencies of info.json); Krastorio 2's
--- data-final-fixes (enforce-science-tier-separation.lua: the red to blue packs taken from technologies that need its
--- higher cards) still runs after it.
---
--- Every Krastorio 2 item goes through kr(): a name that Krastorio 2 or Spaced Out does not have (renamed in a later version)
--- degrades to the vanilla stand-in of the recipe without the compatibility, with one log line, instead of a load error.
--------------------------------------------------------------------------------

local ME = ME_NETWORK

--- the Krastorio 2 item `name` if a prototype of an item type has that name, else the vanilla `fallback` (one log line)
local function kr(name, fallback)
	for t in pairs(defines.prototypes.item) do
		if data.raw[t] and data.raw[t][name] then return name end
	end
	log("ME-NETWORK: Krastorio 2: no item " .. name .. ", " .. fallback .. " instead")
	return fallback
end

--- what this file did, for devcheck (tools/devcheck/checkmod/data-final-fixes.lua, section KRASTORIO2)
ME.krastorio2 = { kr = kr }
