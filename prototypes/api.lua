--------------------------------------------------------------------------------
--- ME NETWORK: data-stage API (docs/API.md)
---
--- A global table ME_NETWORK for this mod's own prototype files and for mods that depend on me-network and want
--- other recipes or technologies for the ME blocks (Gregtorio Continued puts its GregTech recipes and tiers on them).
--- Every prototype name of this mod is fixed: saves find entities and items by name.
---
---   ME_NETWORK.recipes, ME_NETWORK.technologies   names of the recipes and technologies this mod made
---   ME_NETWORK.replace_recipe(def)                replace a recipe by a full definition (same name); the
---                                                 technologies that unlock it keep unlocking it
---   ME_NETWORK.remove_recipe(name)                delete a recipe and every unlock of it
---   ME_NETWORK.set_technology(name, def)          replace prerequisites, unit and/or the unlocked recipes
---                                                 (def.recipes: names, in order) of a technology
---   ME_NETWORK.make_molecular_assembler(def)      rebuild the ME Molecular Assembler from another assembling
---                                                 machine (base, crafting_categories, crafting_speed, energy_usage)
---   ME_NETWORK.removed                            items this mod no longer lets players make: { old item ->
---                                                 the item that replaced it }; their recipes are ignored by
---                                                 replace_recipe and deleted in data-final-fixes.lua (issue #3)
--------------------------------------------------------------------------------

ME_NETWORK = ME_NETWORK or {}
local M = ME_NETWORK

M.version = "0.1.0"
M.root = "__me-network__/"
M.icons = M.root .. "graphics/icons/"
M.entity_path = M.root .. "graphics/entity/fork/ae2/"
M.technology_path = M.root .. "graphics/technology/fork/"
M.recipes = M.recipes or {}
M.technologies = M.technologies or {}
M.removed = M.removed or {}
M.customized = M.customized or {}     -- technologies another mod changed with set_technology (data-final-fixes.lua)

local function remember(list, name)
	for _, n in pairs(list) do if n == name then return end end
	list[#list + 1] = name
end

--- A recipe of this mod (standalone: vanilla items). def: name, ingredients, results (default: one of the item
--- `name`), category (default "crafting"), energy_required, subgroup, order, main_product, auto_recycle
function M.add_recipe(def)
	data:extend({ {
		type = "recipe",
		name = def.name,
		category = def.category or "crafting",
		enabled = false,
		energy_required = def.energy_required or 1,
		ingredients = def.ingredients,
		results = def.results or { { type = "item", name = def.result or def.name, amount = def.amount or 1 } },
		subgroup = def.subgroup,
		order = def.order,
		main_product = def.main_product,
		auto_recycle = def.auto_recycle,
	} })
	remember(M.recipes, def.name)
end

--- An item (the fields are the same as Gregtorio's create_item gave them, so saves and other mods see the same
--- item) and, unless def.recipe is false, its recipe (def.recipe = the fields of add_recipe without the name)
function M.add_item(def)
	data:extend({ {
		type = def.type or "item",
		name = def.name,
		icon = def.icon or (M.icons .. def.name .. ".png"),
		icon_size = def.icon_size or 32,
		stack_size = def.stack_size or 64,
		subgroup = def.subgroup,
		order = def.order,
		place_result = def.place_result,
		hidden = def.hidden,
		localised_description = def.localised_description,
	} })
	if def.recipe ~= false then
		local r = def.recipe or {}
		r.name = r.name or def.name
		r.result = def.name
		r.subgroup = r.subgroup or def.subgroup
		r.order = r.order or def.order
		M.add_recipe(r)
	end
	return data.raw[def.type or "item"][def.name]
end

--- A technology of this mod: name, prerequisites, unit, recipes (unlocked, in order)
function M.add_technology(def)
	local effects = {}
	for _, r in pairs(def.recipes) do
		if data.raw.recipe[r] then
			effects[#effects + 1] = { type = "unlock-recipe", recipe = r }
			data.raw.recipe[r].enabled = false
		else
			log("ME-NETWORK: technology " .. def.name .. ": missing recipe " .. r)
		end
	end
	data:extend({ {
		type = "technology",
		name = def.name,
		icon = M.technology_path .. def.name .. ".png",
		icon_size = 256,
		effects = effects,
		prerequisites = def.prerequisites,
		unit = def.unit,
	} })
	remember(M.technologies, def.name)
end

function M.replace_recipe(def)
	if M.removed[def.name] then
		log("ME-NETWORK: replace_recipe: " .. def.name .. " is no longer made (now " .. M.removed[def.name] .. "), ignored")
		return
	end
	def.type = "recipe"
	data.raw.recipe[def.name] = nil
	data:extend({ def })
	remember(M.recipes, def.name)
end

function M.remove_recipe(name)
	data.raw.recipe[name] = nil
	for _, tech in pairs(data.raw.technology) do
		local keep = {}
		for _, e in pairs(tech.effects or {}) do
			if not (e.type == "unlock-recipe" and e.recipe == name) then keep[#keep + 1] = e end
		end
		if tech.effects then tech.effects = keep end
	end
	for i, n in pairs(M.recipes) do
		if n == name then table.remove(M.recipes, i) break end
	end
end

function M.set_technology(name, def)
	local tech = data.raw.technology[name]
	if not tech then error("ME_NETWORK.set_technology: no technology " .. name) end
	M.customized[name] = true
	if def.prerequisites then tech.prerequisites = def.prerequisites end
	if def.unit then tech.unit = def.unit end
	if def.recipes then
		local effects = {}
		for _, e in pairs(tech.effects or {}) do
			if e.type ~= "unlock-recipe" then effects[#effects + 1] = e end
		end
		for _, r in pairs(def.recipes) do
			if data.raw.recipe[r] then
				effects[#effects + 1] = { type = "unlock-recipe", recipe = r }
				data.raw.recipe[r].enabled = false
			else
				log("ME-NETWORK: technology " .. name .. ": missing recipe " .. r)
			end
		end
		tech.effects = effects
	end
end

--- the ME Molecular Assembler: a copy of `base` for item recipes only (no fluid boxes) with its own graphics
function M.make_molecular_assembler(def)
	local assembler = table.deepcopy(data.raw["assembling-machine"][def.base])
	assembler.name = "me-molecular-assembler"
	assembler.icon = M.icons .. "fork/me-molecular-assembler.png"
	assembler.icon_size = 32
	assembler.icons = nil
	assembler.minable = { mining_time = 0.5, result = "me-molecular-assembler" }
	assembler.fast_replaceable_group = nil
	assembler.next_upgrade = nil
	assembler.crafting_categories = def.crafting_categories
	assembler.crafting_speed = def.crafting_speed
	assembler.energy_usage = def.energy_usage
	assembler.fluid_boxes = nil
	assembler.fluid_boxes_off_when_no_fluid_recipe = nil
	assembler.graphics_set = {
		idle_animation = { layers = { {
			filename = M.entity_path .. "me-molecular-assembler-idle.png",
			width = 96, height = 96, frame_count = 1, repeat_count = 4, shift = { 0, 0 },
		} } },
		animation = { layers = { {
			filename = M.entity_path .. "me-molecular-assembler-working.png",
			width = 96, height = 96, frame_count = 4, line_length = 1, animation_speed = 0.3, shift = { 0, 0 },
		} } },
	}
	assembler.localised_description = { "entity-description.me-molecular-assembler" }
	data.raw["assembling-machine"]["me-molecular-assembler"] = nil
	data:extend({ assembler })
end

--- science packs for the standalone technologies: the first n of the vanilla packs, `count` units
function M.unit(n, count)
	local packs = { "automation-science-pack", "logistic-science-pack", "chemical-science-pack",
		"production-science-pack", "utility-science-pack" }
	local out = {}
	for i = 1, n do out[#out + 1] = { packs[i], 1 } end
	return { count = count, ingredients = out, time = 30 }
end
