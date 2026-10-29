--- Runs after every mod's data.lua (this mod optionally depends on me-network and gregtorio-continued), but before other mods'
--- data-updates such as quality's recycling generation, which aborts loading on broken
--- recipes. Lists every reference to a missing prototype so all problems show up at once (validate.lua).
local out = require("validate")()
local function L(...) out[#out + 1] = table.concat({ ... }, "\t") end
--- issue #487: ME_NETWORK.recipe_keys turns a recipe in Factorio 2.0's form (another mod's call of add_recipe or
--- replace_recipe) into 2.1's: `category` and `additional_categories` into `categories`, `probability` into
--- `independent_probability`
if ME_NETWORK and ME_NETWORK.recipe_keys then
	local r = ME_NETWORK.recipe_keys({ category = "advanced-crafting", additional_categories = { "crafting", "advanced-crafting" },
		results = { { type = "item", name = "x", amount = 1, probability = 0.5 }, { type = "item", name = "y", amount = 1 } } })
	local cats = table.concat(r.categories or {}, ",")
	if cats ~= "advanced-crafting,crafting" or r.category or r.additional_categories or r.results[1].probability
			or r.results[1].independent_probability ~= 0.5 or r.results[2].independent_probability then
		L("APIKEYS", "ME_NETWORK.recipe_keys", cats .. " " .. serpent.line(r))
	end
	local same = ME_NETWORK.recipe_keys({ categories = { "crafting" }, results = {} })
	if table.concat(same.categories, ",") ~= "crafting" then L("APIKEYS", "ME_NETWORK.recipe_keys (2.1 form)", serpent.line(same)) end
end
log("DEVCHECK-VALIDATE-BEGIN\n" .. table.concat(out, "\n") .. "\nDEVCHECK-VALIDATE-END")
