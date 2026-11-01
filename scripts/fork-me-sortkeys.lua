--------------------------------------------------------------------------------
--- FORK AE2: SORT KEYS OF THE TERMINAL (runtime, issue #602; scripts/fork-me-terminal.lua sorts by them)
---   * mod: the mod that made an item's or fluid's prototype (prototypes.get_history(type, name).created), looked up when
---     it is first sorted by mod (per load, outside storage).
---   * tier: when an item or fluid can first be made. The tier of a recipe the game enables from the start is 0; of
---     one a technology unlocks, the lowest tier of those technologies (technologies the game disables left out). A
---     technology's tier is the highest rank of its science packs (a pack's rank: its own tier + 1), a technology
---     researched by a trigger has the highest tier of its prerequisites. An item's or fluid's tier is the lowest tier of
---     the recipes that make it (hidden recipes, parameters and recycling not counted); one no such recipe makes has none.
---     So the red science pack has the tier 0, the green 1 and the blue 2 in vanilla, and Gregtorio's tier packs come out
---     of the same rule without a list of its packs.
--- The tiers are read from the prototypes as the game runs them, not from mod data of the data stage: a mod that depends on
--- this one (Gregtorio) rewrites recipes, technology effects, science packs and prerequisites in its own data-final-fixes,
--- after this mod's last data stage. Reading every recipe and technology costs about 0.9 s with Gregtorio (29 705 recipes,
--- 701 technologies: a walk of the game's prototype tables costs about 2 us per entry and a recipe's products about 9 us;
--- the engine's recipe and technology filters are slower still to walk: about 190 us per recipe of a result, 5.9 s for the
--- recipes of 300 items), so the tiers are made once when the prototypes can have changed (on_init,
--- on_configuration_changed: M.rebuild) and kept in storage.fork_me_tiers = { item = { name -> tier }, fluid = { name ->
--- tier } } (only what has a tier); a save without them (a development build of the same version) makes them at the first
--- sort by tier. Every peer has the same table through the save.
--------------------------------------------------------------------------------

local M = {}

local mods = { item = {}, fluid = {} }

--- the name of the mod that made the prototype of item or fluid `name` (`fluid` true: a fluid); "" when it is unknown
function M.mod_of(fluid, name)
	local kind = fluid and "fluid" or "item"
	local m = mods[kind][name]
	if not m then
		local p = fluid and prototypes.fluid[name] or prototypes.item[name]
		local ok, h = pcall(prototypes.get_history, fluid and "fluid" or (p and p.type or "item"), name)
		m = ok and h and h.created or ""
		mods[kind][name] = m
	end
	return m
end

--- Every tier of the game: { item = { name -> tier }, fluid = { name -> tier } } (see above)
local function compute()
	local made = { item = {}, fluid = {} }                 -- name -> { recipe names }
	local enabled = {}                                      -- recipe name -> true: enabled from the start
	--- (has_category raises an error for a category the game does not have: without the quality mod there is no recycling)
	local recycling = prototypes.recipe_category["recycling"] ~= nil
	for rname, r in pairs(prototypes.recipe) do
		if not (r.hidden or r.parameter or (recycling and r.has_category("recycling"))) then   -- (Factorio 2.1: a recipe has categories)
			if r.enabled then enabled[rname] = true end
			for _, p in pairs(r.products) do
				local t = made[p.type]
				if t then
					local l = t[p.name]
					if not l then l = {} t[p.name] = l end
					l[#l + 1] = rname
				end
			end
		end
	end
	local unlocks = {}                                      -- recipe name -> { technology names }
	for tname, t in pairs(prototypes.technology) do
		if t.enabled then
			for _, e in pairs(t.effects or {}) do
				if e.type == "unlock-recipe" and e.recipe then
					local l = unlocks[e.recipe]
					if not l then l = {} unlocks[e.recipe] = l end
					l[#l + 1] = tname
				end
			end
		end
	end
	local out = { item = {}, fluid = {} }
	local done = { item = {}, fluid = {} }                 -- name -> true once its tier is known (or it has none)
	local recipe_tiers, tech_tiers = {}, {}
	local busy = {}       -- (a cycle: a pack whose tier needs the technology that needs the pack counts as no tier there)
	local resource_tier
	local function tech_tier(tname)
		local v = tech_tiers[tname]
		if v ~= nil then return v or nil end
		if busy[tname] then return nil end
		busy[tname] = true
		local t = prototypes.technology[tname]
		local tier
		local packs = t and t.research_unit_ingredients
		if packs and #packs > 0 then
			tier = 1
			for _, ing in pairs(packs) do
				local r = resource_tier(ing.type == "fluid" and "fluid" or "item", ing.name)
				if r and r + 1 > tier then tier = r + 1 end
			end
		elseif t then
			tier = 0
			for pname in pairs(t.prerequisites or {}) do
				local r = tech_tier(pname)
				if r and r > tier then tier = r end
			end
		end
		busy[tname] = nil
		tech_tiers[tname] = tier or false
		return tier
	end
	local function recipe_tier(rname)
		local v = recipe_tiers[rname]
		if v ~= nil then return v or nil end
		local tier
		if enabled[rname] then
			tier = 0
		else
			for _, tname in ipairs(unlocks[rname] or {}) do
				local t = tech_tier(tname)
				if t and (not tier or t < tier) then tier = t end
			end
		end
		recipe_tiers[rname] = tier or false
		return tier
	end
	function resource_tier(kind, name)
		if done[kind][name] then return out[kind][name] end
		local key = kind .. "/" .. name
		if busy[key] then return nil end
		busy[key] = true
		local tier
		for _, rname in ipairs(made[kind][name] or {}) do
			local t = recipe_tier(rname)
			if t and (not tier or t < tier) then tier = t end
		end
		busy[key] = nil
		done[kind][name], out[kind][name] = true, tier
		return tier
	end
	for _, kind in ipairs({ "item", "fluid" }) do
		local names = {}
		for name in pairs(made[kind]) do names[#names + 1] = name end
		table.sort(names)                                    -- (the cycles are cut in the same place on every peer)
		for _, name in ipairs(names) do resource_tier(kind, name) end
	end
	return out
end

--- the tiers made anew from the prototypes (on_init, on_configuration_changed)
function M.rebuild()
	storage.fork_me_tiers = compute()
	return storage.fork_me_tiers
end

--- the tier of item or fluid `name` (`fluid` true: a fluid), nil when it has none
function M.tier_of(fluid, name)
	local t = storage.fork_me_tiers or M.rebuild()
	return t[fluid and "fluid" or "item"][name]
end

return M
