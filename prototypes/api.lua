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
--- issue #154: the 64 px pictures of the 3D style (tools/gen_ae2_sprites.py --hd): icons 64 x 64, entity pictures at scale 0.5
M.hd_icons = M.root .. "graphics/icons/hd/"
M.hd_entity_path = M.entity_path .. "hd/"
--- what can be walked over (the ME cable, since issue #129 the buses and the ME Terminal): a building's collision mask without the
--- "player" layer, so a character passes through; nothing can be built on it (the "object" layer stays) and no item lies on it
--- (the "item" layer). Cars and tanks pass too (their mask has the "player" layer as well).
M.WALKABLE = { layers = { item = true, meltable = true, object = true, water_tile = true, is_lower_object = true } }
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
	local item = {
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
	}
	for k, v in pairs(def.fields or {}) do item[k] = v end      -- (the fields of another item type: a module's category, tier, effect)
	data:extend({ item })
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

--- The module category of the Acceleration Card (issue #110): the card is a module, and the ME Molecular Assembler is the
--- one machine whose module slots take it (data-final-fixes.lua keeps it out of every other machine and beacon)
M.ACCELERATION = "me-acceleration"
M.ACCELERATION_SLOTS = 5          -- AE2: a Molecular Assembler takes up to 5 acceleration cards (TileMolecularAssembler)

--- the ME Molecular Assembler: a copy of `base` for item recipes only (no fluid boxes) with its own graphics. Since issue
--- #131 it is one tile (AE2's is one block), whatever size `base` has: the boxes, the picture and everything the copy would
--- inherit that is laid out for a bigger machine are set here, so every caller gets the same block.
function M.make_molecular_assembler(def)
	local assembler = table.deepcopy(data.raw["assembling-machine"][def.base])
	assembler.name = "me-molecular-assembler"
	assembler.icon = M.hd_icons .. "me-molecular-assembler.png"
	assembler.icon_size = 64
	assembler.icons = nil
	assembler.minable = { mining_time = 0.5, result = "me-molecular-assembler" }
	assembler.fast_replaceable_group = nil
	assembler.next_upgrade = nil
	assembler.crafting_categories = def.crafting_categories
	assembler.crafting_speed = def.crafting_speed
	assembler.energy_usage = def.energy_usage
	assembler.fluid_boxes = nil
	assembler.fluid_boxes_off_when_no_fluid_recipe = nil
	--- issue #110: five slots for Acceleration Cards and nothing else (no module of the game, no beacon: AE2's assembler has
	--- its upgrade slots and no more); the card's speed and consumption effects are the only ones it takes
	assembler.module_slots = M.ACCELERATION_SLOTS
	assembler.allowed_module_categories = { M.ACCELERATION }
	assembler.allowed_effects = { "speed", "consumption" }
	assembler.effect_receiver = { uses_module_effects = true, uses_beacon_effects = false, uses_surface_effects = true }
	--- issue #131: one tile, like the other 1x1 ME blocks (a base machine's 3x3 boxes are not kept)
	assembler.collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } }
	assembler.selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } }
	assembler.drawing_box_vertical_extension = nil
	--- the pictures: 64 px at scale 0.5 (issue #220: the 3D style), the one tile (a working strip of four frames below each other). A frozen patch of the base machine
	--- (Space Age) is not kept: it is a picture of the base's 3x3 body.
	assembler.graphics_set = {
		idle_animation = { layers = { {
			filename = M.hd_entity_path .. "me-molecular-assembler-idle.png",
			width = 64, height = 64, scale = 0.5, frame_count = 1, repeat_count = 4, shift = { 0, 0 },
		} } },
		animation = { layers = { {
			filename = M.hd_entity_path .. "me-molecular-assembler-working.png",
			width = 64, height = 64, scale = 0.5, frame_count = 4, line_length = 1, animation_speed = 0.3, shift = { 0, 0 },
		} } },
	}
	--- what else a 3x3 machine lays out for its size: the recipe icon of the alt mode and the icons of the five Acceleration Cards
	--- (small and in a row under it: the default places three icons per row at the lower edge of a 3x3 box), the alert icon,
	--- the circuit connector (a 1x1 one when the base has one: its points lie outside one tile; Gregtorio's machines have none) and the corpse
	--- and the dying explosion (the base's are big, like its body)
	assembler.icon_draw_specification = { scale = 0.5, shift = { 0, -0.1 } }
	assembler.icons_positioning = { {
		inventory_index = defines.inventory.crafter_modules, shift = { 0, 0.36 }, scale = 0.17, max_icons_per_row = 5, max_icon_rows = 1,
	} }
	assembler.alert_icon_shift = { 0, -0.15 }
	assembler.alert_icon_scale = 0.5
	if assembler.circuit_connector then            -- (a base machine with a wire connection keeps one, a 1x1 one: a list, one per direction)
		local one = circuit_connector_definitions and circuit_connector_definitions["chest"]
		assembler.circuit_connector = one and { one, one, one, one } or nil
	end
	assembler.corpse = "small-remnants"
	assembler.dying_explosion = "medium-explosion"
	assembler.water_reflection = nil
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
