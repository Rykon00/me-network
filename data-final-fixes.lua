--- ME Network: the last data stage.

--- Issue #3: the old fluid blocks (ME_NETWORK.removed: ME Fluid Interface, ME Fluid Import / Export / Storage Bus) are
--- made by no recipe. A mod that makes a recipe for one of them itself (Gregtorio Continued 0.5.0 does, in its
--- prototypes/120-fork-me-network-compat.lua) loses that recipe here, and every technology loses its unlock; the item
--- stays hidden (saves still hold it, scripts/fork-me-unify.lua turns it into the unified item).
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
