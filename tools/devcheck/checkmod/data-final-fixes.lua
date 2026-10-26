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

--- R recipe categories enabled ingredients results hidden hide_from_player_crafting subgroup group
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
	D("R", n, table.concat(r.categories or { "crafting" }, ","), tostring(r.enabled ~= false), names(r.ingredients), names(r.results),
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
--- what trees, rocks, plants and asteroid chunks give when mined (vanilla wood, stone, carbon, ice ...)
for _, t in pairs({ "tree", "simple-entity", "plant", "asteroid-chunk", "fish" }) do
	for n, e in pairs(data.raw[t] or {}) do
		local m = e.minable
		if m then D("M", n, m.result or "", names(m.results), "basic-solid") end
	end
end
--- the fluid of a tile is what an offshore pump on it gives (water, lava, ammonia ...)
for n, t in pairs(data.raw.tile or {}) do
	if t.fluid then D("O", "tile:" .. n, t.fluid) end
end
--- burnt results: what a burnt fuel leaves (a used fuel cell)
for t, _ in pairs(defines.prototypes.item) do
	for n, it in pairs(data.raw[t] or {}) do
		if it.burnt_result then D("B", n, it.burnt_result) end
	end
end
section("DUMP", dump)

--- Every __me-network__/ file referenced anywhere, with its owner prototype (and every file of the texture mod
--- me-network-ae2-textures, issue #239, when it is loaded)
local function mine(v)
	return type(v) == "string" and (v:sub(1, 15) == "__me-network__/" or v:sub(1, 28) == "__me-network-ae2-textures__/")
end
local paths, seen = {}, {}
local function scan(t, owner, depth)
	if depth > 12 then return end
	for _, v in pairs(t) do
		if mine(v) then
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

--- Icons of this mod and of the texture mod with their icon_size (issue #247: headless Factorio loads no image, so a
--- size that does not fit the file shows only in the game)
local icons = {}
local function icon_rows(p, owner)
	if mine(p.icon) then icons[#icons + 1] = table.concat({ owner, p.icon, p.icon_size or 64 }, "\t") end
	for _, l in pairs(type(p.icons) == "table" and p.icons or {}) do
		if type(l) == "table" and mine(l.icon) then
			icons[#icons + 1] = table.concat({ owner, l.icon, l.icon_size or p.icon_size or 64 }, "\t")
		end
	end
end
for t, ps in pairs(data.raw) do
	for n, p in pairs(ps) do if type(p) == "table" then icon_rows(p, t .. ":" .. n) end end
end
section("ICONS", icons)

--- Prototypes with an icon of this mod: their names must be in the locale
local loc = {}
local function own(p) return mine(p.icon) end
for t, _ in pairs(defines.prototypes.item) do
	for n, p in pairs(data.raw[t] or {}) do if own(p) and not p.hidden then loc[#loc + 1] = "item-name	" .. n end end
end
for n, p in pairs(data.raw.technology) do
	if own(p) and p.enabled ~= false then loc[#loc + 1] = "technology-name	" .. n end
end
for t, _ in pairs(defines.prototypes.entity) do
	for n, p in pairs(data.raw[t] or {}) do if own(p) and p.minable and not p.hidden then loc[#loc + 1] = "entity-name	" .. n end end
end
for n, p in pairs(data.raw["item-group"]) do                -- (issue #474: the tab "ME Network")
	if own(p) then loc[#loc + 1] = "item-group-name	" .. n end
end
section("LOCALE", loc)

--- The recipes and technologies of me-network (ME_NETWORK, prototypes/api.lua)
local own_rows = {}
for _, n in pairs(ME_NETWORK and ME_NETWORK.recipes or {}) do own_rows[#own_rows + 1] = "recipe	" .. n end
for _, n in pairs(ME_NETWORK and ME_NETWORK.technologies or {}) do own_rows[#own_rows + 1] = "technology	" .. n end
section("OWN", own_rows)

--- issue #474: the items of me-network (ME_NETWORK.items) with their subgroup, its item group (the inventory tab),
--- whether they are hidden and their order; "stray" rows: an item with an icon of this mod that is not in
--- ME_NETWORK.items (made without add_item); and every subgroup with its group and order
local function item_proto(n)
	for t, _ in pairs(defines.prototypes.item) do
		if data.raw[t] and data.raw[t][n] then return data.raw[t][n] end
	end
end
local tab_rows, listed = {}, {}
for _, n in pairs(ME_NETWORK and ME_NETWORK.items or {}) do
	listed[n] = true
	local p = item_proto(n)
	local sg = p and p.subgroup or "other"
	local g = data.raw["item-subgroup"][sg] and data.raw["item-subgroup"][sg].group or "other"
	tab_rows[#tab_rows + 1] = table.concat({ "item", n, sg, g, tostring(p ~= nil and p.hidden == true), p and p.order or "" }, "\t")
end
for t, _ in pairs(defines.prototypes.item) do
	for n, p in pairs(data.raw[t] or {}) do
		if not listed[n] and mine(p.icon) then tab_rows[#tab_rows + 1] = "stray\t" .. n end
	end
end
for n, sg in pairs(data.raw["item-subgroup"]) do
	tab_rows[#tab_rows + 1] = table.concat({ "subgroup", n, sg.group or "", sg.order or "" }, "\t")
end
section("TAB", tab_rows)

--- Rykon00/Gregtorio#215: the recipes of this mod that Gregtorio keeps locked on purpose (its FORK_RECIPES_LOCKED, name
--- -> reason; absent without Gregtorio)
local locked = {}
for _, n in pairs(ME_NETWORK and ME_NETWORK.recipes or {}) do
	local why = FORK_RECIPES_LOCKED and FORK_RECIPES_LOCKED[n]
	if why then locked[#locked + 1] = n .. "	" .. why end
end
section("GREGTORIOLOCKED", locked)

--- Issue #487 (the port to Factorio 2.1): every key a prototype still carries that Factorio removed (removed-keys.lua,
--- written by tools/devcheck/removed_keys.py from the API of both versions). Factorio 2.1 refuses a few of them with an error
--- (a recipe's `category`, a product's `probability`, an item's `fuel_category`, a fluid box's temperatures) and ignores the
--- others (a crafting machine's `forced_symmetry`, a fluid box's `hide_connection_info`, a recipe's `always_show_products`,
--- ...), which fail silently. One row per key: <data.raw type>/<name><path>, the key.
local K = require("removed-keys")
local found = {}
local function walk(v, node, path, seen)
	local spec = K.nodes[node]
	if type(v) ~= "table" or not spec then return end
	if spec.tag and type(v.type) == "string" and v.type ~= spec.tag then return end    -- (another option of a union)
	seen[v] = seen[v] or {}
	if seen[v][node] then return end
	seen[v][node] = true
	for i, x in ipairs(v) do walk(x, node, path .. "[" .. i .. "]", seen) end
	for k, x in pairs(v) do
		if type(k) == "string" then
			if spec.removed[k] then found[#found + 1] = path .. "\t" .. k end
			for _, n in ipairs(spec.fields[k] or {}) do walk(x, n, path .. "." .. k, seen) end
		end
	end
end
for t, list in pairs(data.raw) do
	local node = K.prototypes[t]
	if node then
		for n, p in pairs(list) do walk(p, node, t .. "/" .. n, {}) end
	end
end
table.sort(found)
section("REMOVEDKEYS", found)

--- Issue #519: settings paste. The game pastes only between entities whose prototypes allow it (prototypes/paste.lua), and
--- the runtime tests call the handlers directly, so they never see a missing list. Rows: "handler\t<module>" for every
--- module the table names (devcheck.py compares them with the handlers in scripts/), "missing\t<prototype>\t<what>" for
--- a source of the table, a target of it or a crafting machine whose final prototype lacks a target or allow_copy_paste.
--- Issue #527: a block of KEYS (pasted by the mod's own keys) must not have allow_copy_paste (the game would try its own
--- paste and say "Not operable"), nor be in SOURCES, and the keys' custom inputs must follow the game's controls without
--- consuming them.
local PASTE = require("__me-network__.prototypes.paste")
local paste_rows, handlers = {}, {}
local function pastable(p)                   -- (an electric energy interface's allow_copy_paste is false by default)
	if p.allow_copy_paste == nil then return p.type ~= "electric-energy-interface" end
	return p.allow_copy_paste == true
end
local function lacks(p, targets, owner)
	local listed = {}
	for _, n in pairs(p.additional_pastable_entities or {}) do listed[n] = true end
	for _, n in ipairs(targets) do
		if not listed[n] then paste_rows[#paste_rows + 1] = "missing\t" .. owner .. "\tadditional_pastable_entities has no " .. n end
	end
end
for name, spec in pairs(PASTE.SOURCES) do
	handlers[spec.handler] = true
	local p = PASTE.entity(name)
	if not p then
		paste_rows[#paste_rows + 1] = "missing\t" .. name .. "\tno such entity prototype"
	else
		if not pastable(p) then paste_rows[#paste_rows + 1] = "missing\t" .. name .. "\tallow_copy_paste is false (a source)" end
		lacks(p, spec.targets, name)
		for _, t in ipairs(spec.targets) do
			local tp = PASTE.entity(t)
			if not tp then
				paste_rows[#paste_rows + 1] = "missing\t" .. t .. "\tno such entity prototype (a target of " .. name .. ")"
			elseif not pastable(tp) then
				paste_rows[#paste_rows + 1] = "missing\t" .. t .. "\tallow_copy_paste is false (a target of " .. name .. ")"
			end
		end
	end
end
for name, spec in pairs(PASTE.KEYS) do
	handlers[spec.handler] = true
	local p = PASTE.entity(name)
	if not p then
		paste_rows[#paste_rows + 1] = "missing	" .. name .. "	no such entity prototype (pasted by the keys)"
	else
		if pastable(p) then
			paste_rows[#paste_rows + 1] = "missing	" .. name .. "	allow_copy_paste is true, but the keys paste it (KEYS)"
		end
		if PASTE.SOURCES[name] then paste_rows[#paste_rows + 1] = "missing	" .. name .. "	in SOURCES and in KEYS" end
		for _, t in ipairs(spec.targets) do
			if not PASTE.KEYS[t] then
				paste_rows[#paste_rows + 1] = "missing	" .. t .. "	a target of " .. name .. " that the keys do not paste (KEYS)"
			end
		end
	end
end
for _, key in pairs(PASTE.INPUTS) do
	local ci = data.raw["custom-input"][key.name]
	if not ci then
		paste_rows[#paste_rows + 1] = "missing	" .. key.name .. "	no such custom input"
	elseif ci.linked_game_control ~= key.control or (ci.consuming or "none") ~= "none" then
		paste_rows[#paste_rows + 1] = "missing	" .. key.name .. "	not linked to " .. key.control .. " with consuming \"none\""
	end
end
handlers[PASTE.MACHINE_HANDLER] = true
for _, t in ipairs(PASTE.MACHINE_TYPES) do
	for n, p in pairs(data.raw[t] or {}) do lacks(p, PASTE.MACHINE_TARGETS, t .. ":" .. n) end
end
for m in pairs(PASTE.BUILTIN) do handlers[m] = true end
for m in pairs(handlers) do paste_rows[#paste_rows + 1] = "handler\t" .. m end
table.sort(paste_rows)
section("PASTE", paste_rows)
