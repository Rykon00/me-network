--- Every reference to a missing prototype in data.raw, one tab-separated row each. data.lua logs it after every mod's
--- data.lua (before quality's recycling generation, which aborts loading on broken recipes), data-final-fixes.lua
--- again at the end: issue #591, a third-party mod such as Krastorio 2 names in its data.lua recipes it adds in its
--- data-updates, so only a row that is still there at the end is a problem.
return function()
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
	return out
end
