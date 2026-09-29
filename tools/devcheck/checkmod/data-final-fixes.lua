--- Dumps the final prototype state into the log for tools/devcheck/devcheck.py.
--- Every section is framed by DEVCHECK-<NAME>-BEGIN / -END lines, one tab-separated row per line.
local function section(name, rows)
	log("DEVCHECK-" .. name .. "-BEGIN\n" .. table.concat(rows, "\n") .. "\nDEVCHECK-" .. name .. "-END")
end
local function names(list)
	local t = {}
	for _, x in pairs(list or {}) do
		if type(x) == "table" then t[#t + 1] = (x.type or "item") .. ":" .. (x.name or x[1]) else t[#t + 1] = tostring(x) end
	end
	return table.concat(t, ",")
end

--- R recipe category enabled ingredients results hidden hide_from_player_crafting subgroup group
--- C crafter type categories fluid_in fluid_out
--- I item type place_result | F fluid | T tech prereqs unlocks science trigger enabled
--- M resource result results category | O offshore-pump fluid
local dump = {}
local function D(...) dump[#dump + 1] = table.concat({ ... }, "\t") end
--- subgroup and tab of a recipe as the crafting menu shows it (without subgroup: the main product's)
local function product_proto(n)
	if data.raw.fluid[n] then return data.raw.fluid[n] end
	for t, _ in pairs(defines.prototypes.item) do
		if data.raw[t] and data.raw[t][n] then return data.raw[t][n] end
	end
end
local function recipe_subgroup(r)
	if r.subgroup then return r.subgroup end
	local main = r.main_product
	if (not main or main == "") and r.results and #r.results == 1 then main = r.results[1].name end
	local p = main and main ~= "" and product_proto(main)
	if not p then return "other" end
	return p.subgroup or (p.type == "fluid" and "fluid" or "other")
end
for n, r in pairs(data.raw.recipe) do
	local sg = recipe_subgroup(r)
	local g = data.raw["item-subgroup"][sg] and data.raw["item-subgroup"][sg].group or "other"
	D("R", n, r.category or "crafting", tostring(r.enabled ~= false), names(r.ingredients), names(r.results),
		tostring(r.hidden == true), tostring(r.hide_from_player_crafting == true), sg, g)
end
for _, t in pairs({ "assembling-machine", "furnace", "rocket-silo", "character" }) do
	for n, e in pairs(data.raw[t] or {}) do
		local fi, fo = 0, 0
		for _, fb in pairs(e.fluid_boxes or {}) do
			if fb.production_type == "input" or fb.production_type == "input-output" then fi = fi + 1 end
			if fb.production_type == "output" then fo = fo + 1 end
		end
		D("C", n, t, table.concat(e.crafting_categories or {}, ","), fi, fo)
	end
end
for t, _ in pairs(defines.prototypes.item) do
	for n, it in pairs(data.raw[t] or {}) do D("I", n, t, it.place_result or "") end
end
for n, _ in pairs(data.raw.fluid) do D("F", n) end
for n, tech in pairs(data.raw.technology) do
	local eff, ing = {}, {}
	for _, e in pairs(tech.effects or {}) do if e.type == "unlock-recipe" then eff[#eff + 1] = e.recipe end end
	if tech.unit then for _, i in pairs(tech.unit.ingredients or {}) do ing[#ing + 1] = i[1] or i.name end end
	local trig = tech.research_trigger and serpent.line(tech.research_trigger) or ""
	D("T", n, table.concat(tech.prerequisites or {}, ","), table.concat(eff, ","), table.concat(ing, ","), trig,
		tostring(tech.enabled ~= false and not tech.hidden))
end
for n, e in pairs(data.raw.resource) do
	local m = e.minable or {}
	D("M", n, m.result or "", names(m.results), e.category or "basic-solid")
end
for n, e in pairs(data.raw["offshore-pump"] or {}) do D("O", n, e.fluid or "") end
section("DUMP", dump)

--- Every __gregtorio-continued__/ file referenced anywhere, with its owner prototype
local paths, seen = {}, {}
local function scan(t, owner, depth)
	if depth > 12 then return end
	for _, v in pairs(t) do
		if type(v) == "string" and v:sub(1, 24) == "__gregtorio-continued__/" then
			local k = v .. "\t" .. owner
			if not seen[k] then seen[k] = true; paths[#paths + 1] = k end
		elseif type(v) == "table" then
			scan(v, owner, depth + 1)
		end
	end
end
for t, ps in pairs(data.raw) do for n, p in pairs(ps) do scan(p, t .. ":" .. n, 0) end end
section("PATHS", paths)

--- Sprite layers of crafting machines (to check sheet sizes against the image files)
local sprites = {}
local function layers_of(anim)
	if not anim then return {} end
	return anim.layers or { anim }
end
for n, e in pairs(data.raw["assembling-machine"]) do
	local gs = e.graphics_set or {}
	for _, key in pairs({ "animation", "idle_animation" }) do
		for _, l in pairs(layers_of(gs[key])) do
			if l.filename then
				sprites[#sprites + 1] = table.concat({ n, key, l.filename, l.width or 0, l.height or 0,
					l.frame_count or 1, l.line_length or 0, l.x or 0, l.y or 0 }, "\t")
			end
		end
	end
end
section("SPRITES", sprites)

--- Prototypes with a Gregtorio icon, for locale checks (tools/gen_locale.py input format)
local loc = {}
local function greg(p) return type(p.icon) == "string" and p.icon:sub(1, 24) == "__gregtorio-continued__/" end
for t, _ in pairs(defines.prototypes.item) do
	for n, p in pairs(data.raw[t] or {}) do if greg(p) then loc[#loc + 1] = "item-name\t" .. n end end
end
for n, p in pairs(data.raw.fluid) do if greg(p) then loc[#loc + 1] = "fluid-name\t" .. n end end
for n, p in pairs(data.raw.technology) do
	if greg(p) and p.enabled ~= false then loc[#loc + 1] = "technology-name\t" .. n end
end
for t, _ in pairs(defines.prototypes.entity) do
	for n, p in pairs(data.raw[t] or {}) do if greg(p) and p.minable then loc[#loc + 1] = "entity-name\t" .. n end end
end
section("LOCALE", loc)

--- Technology icons
local ti = {}
for n, t in pairs(data.raw.technology) do
	if t.enabled ~= false and not t.hidden then ti[#ti + 1] = n .. "\t" .. tostring(t.icon) end
end
section("TECHICONS", ti)

--- Crafting menu (issue #49): the startup setting and the allow-list of recipes that stay hidden
--- (FORK_CRAFTING_MENU_HIDDEN in prototypes/198-fork-crafting-menu.lua; absent in older versions)
local cm = {}
local s = settings.startup["gregtorio-continued-show-machine-recipes"]
cm[#cm + 1] = "setting\t" .. (s and tostring(s.value) or "absent")
for kind, list in pairs(FORK_CRAFTING_MENU_HIDDEN or {}) do
	for name, reason in pairs(list) do cm[#cm + 1] = kind .. "\t" .. name .. "\t" .. reason end
end
section("CRAFTMENU", cm)
