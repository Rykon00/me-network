--- Runs after every mod's data.lua (this mod optionally depends on Gregtorio and gregtorio-continued), but before other mods'
--- data-updates such as quality's recycling generation, which aborts loading on broken
--- recipes. Lists every reference to a missing prototype so all problems show up at once.
local out = {}
local function L(...) out[#out + 1] = table.concat({ ... }, "\t") end
local function is_item(n)
	for t, _ in pairs(defines.prototypes.item) do if data.raw[t] and data.raw[t][n] then return true end end
	return false
end
for n, r in pairs(data.raw.recipe) do
	if not data.raw["recipe-category"][r.category or "crafting"] then L("BADCAT", n, tostring(r.category)) end
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
log("DEVCHECK-VALIDATE-BEGIN\n" .. table.concat(out, "\n") .. "\nDEVCHECK-VALIDATE-END")
