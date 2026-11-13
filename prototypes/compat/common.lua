--------------------------------------------------------------------------------
--- What the compatibility files share (prototypes/compat/krastorio2.lua, space-exploration.lua): the stand-in swaps and
--- the ME Molecular Assembler made again
---
--- A swap table: recipe name -> { [stand-in] = list of { item, per }, add = list of { item, amount } }. The stand-in's
--- amount n becomes n * per of each item (per = a number) or exactly per.n (per = { n = ... }); `add` lists items added.
--- An item of nil is left out (a stand-in the other mod does not have). Recipes missing in the table keep their ingredients.
--------------------------------------------------------------------------------

local ME = ME_NETWORK
local M = {}

--- the recipe `r` (a prototype) with its stand-ins swapped (an item that is a stand-in of itself stays; equal items are
--- merged); a copy, `r` is not changed
function M.swapped(r, swaps)
	local out, at = {}, {}
	local function put(item, amount)
		if not item or amount <= 0 then return end
		if at[item] then out[at[item]].amount = out[at[item]].amount + amount
		else out[#out + 1] = { type = "item", name = item, amount = amount } at[item] = #out end
	end
	for _, i in ipairs(r.ingredients or {}) do
		local to = i.type ~= "fluid" and swaps[i.name]
		if to then
			for _, t in ipairs(to) do put(t[1], type(t[2]) == "table" and t[2].n or i.amount * t[2]) end
		elseif i.type == "fluid" then
			out[#out + 1] = table.deepcopy(i)
		else
			put(i.name, i.amount)
		end
	end
	for _, a in ipairs(swaps.add or {}) do put(a[1], a[2]) end
	local def = table.deepcopy(r)
	def.ingredients = out
	return def
end

--- every recipe of this mod that `swaps` names is replaced by its swapped form. `from`: recipe name -> the prototype to
--- start from instead of the recipe as it is now (the Space Exploration compatibility starts from the recipes as they
--- were before the Krastorio 2 compatibility, ME_NETWORK.standalone.recipes).
function M.apply(swaps, from)
	for _, name in ipairs(table.deepcopy(ME.recipes)) do
		local r = from and from[name] or data.raw.recipe[name]
		if swaps[name] and r and data.raw.recipe[name] then ME.replace_recipe(M.swapped(r, swaps[name])) end
	end
end

--- `over` laid on `under` (two swap tables): per recipe and stand-in the entry of `over` where it has one, else the one of
--- `under`; an `add` list of `over` replaces the one of `under`. A new table.
function M.merged(under, over)
	local out = {}
	for name, swaps in pairs(under or {}) do
		out[name] = {}
		for k, v in pairs(swaps) do out[name][k] = v end
	end
	for name, swaps in pairs(over or {}) do
		out[name] = out[name] or {}
		for k, v in pairs(swaps) do out[name][k] = v end
	end
	return out
end

--- The ME Molecular Assembler made again from the assembling machine 2 as it is now (prototypes/autocrafting.lua made it in
--- our data.lua from its item categories as they were then): the categories `keep(category)` allows, its speed and power as
--- they are. Returns the categories (nil without the two machines).
function M.remake_assembler(keep)
	local assembler = data.raw["assembling-machine"]["me-molecular-assembler"]
	local base = data.raw["assembling-machine"]["assembling-machine-2"]
	if not (assembler and base) then return end
	local categories = {}
	for _, c in pairs(base.crafting_categories or {}) do
		if keep(c) then categories[#categories + 1] = c end
	end
	ME.make_molecular_assembler{ base = "assembling-machine-2", crafting_categories = categories,
		crafting_speed = assembler.crafting_speed, energy_usage = assembler.energy_usage }
	--- (issue #711: the ME Space Molecular Assembler follows: the same categories and its own)
	if ME.space_assembler then ME.space_assembler.make() end
	return categories
end

return M
