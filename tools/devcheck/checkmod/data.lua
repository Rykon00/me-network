--- Runs after every mod's data.lua (this mod optionally depends on me-network and gregtorio-continued), but before other mods'
--- data-updates such as quality's recycling generation, which aborts loading on broken
--- recipes. Lists every reference to a missing prototype so all problems show up at once.
local out = {}
local function L(...) out[#out + 1] = table.concat({ ... }, "\t") end
local function is_item(n)
	for t, _ in pairs(defines.prototypes.item) do if data.raw[t] and data.raw[t][n] then return true end end
	return false
end
for n, r in pairs(data.raw.recipe) do
	for _, c in pairs(r.categories or { "crafting" }) do    -- (issue #487: Factorio 2.1's list of categories)
		if not data.raw["recipe-category"][c] then L("BADCAT", n, tostring(c)) end
	end
	for _, key in pairs({ "ingredients", "results" }) do
		for _, i in pairs(r[key] or {}) do
			local nm = i.name or i[1]
			if i.type == "fluid" then
				if not data.raw.fluid[nm] then L("NOFLUID", n, key, tostring(nm)) end
			elseif not is_item(nm) then
				L("NOITEM", n, key, tostring(nm))
			end
		end
	end
end
for n, t in pairs(data.raw.technology) do
	for _, e in pairs(t.effects or {}) do
		if e.type == "unlock-recipe" and not data.raw.recipe[e.recipe] then L("TECHRECIPE", n, e.recipe) end
	end
	for _, p in pairs(t.prerequisites or {}) do
		if not data.raw.technology[p] then L("TECHPREREQ", n, p) end
	end
end
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
