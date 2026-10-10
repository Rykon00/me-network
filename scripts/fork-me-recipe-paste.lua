--------------------------------------------------------------------------------
--- ME NETWORK: a crafting machine's recipe pasted onto an ME block (issue #12), like the game does for a requester
--- chest: shift right click on the machine, shift left click on the block. data-final-fixes.lua adds the ME
--- Interface, the import, export and storage bus to the `additional_pastable_entities` of every crafting machine
--- (assembling machines, furnaces, rocket silos of every mod), so the game raises on_entity_settings_pasted.
---   * The recipe: the machine's recipe and its quality; a furnace without one: its previous recipe.
---   * ME Interface: the config rows become the recipe's ingredients in recipe order (items at the recipe's quality),
---     a fluid row for each fluid. Issue #157: each row keeps one craft of the recipe (its ingredient amount; a fluid's
---     rounded up to whole units, as rows hold them; before, a full stack of each item and a side's volume of each
---     fluid), at most what a row holds (items MAX_ROW_AMOUNT, a fluid a side's volume: the player is told). 9 rows, 4
---     fluids at most (one per side). The sides: "off" stays off, a side tied to a fluid that is
---     in the new config again stays tied to it, a side tied to a row that goes away imports again. A fluid row
---     without a side gets the side the window gives a new fluid row: the first import side with a pipe, else the
---     first import side (the player is told that it has no pipe yet); with no import side left it has none.
---   * ME Storage Bus: the filters become the ingredients (facing a chest or cargo wagon the items, facing a tank
---     the fluids, with no target yet both), items at the recipe's quality; mode and priority stay. 18 filters.
---   * ME Export Bus: the filters become the ingredients, ME Import Bus: the products; items and fluids, 9
---     filters, items at the recipe's quality (issue #291; normal quality: the plain name, which the import bus takes in
---     every quality).
---   * Whatever did not fit, a fluid row without a pipe or side, a machine without a recipe: a flying text for the
---     player. When nothing applies to the block (no ingredients, no fluid for a tank, ...) the block is unchanged.
---   * Issue #161: a fluid with an exact temperature in the recipe (an ingredient's `temperature`, a product's) gets it in
---     the row or filter ("fluid/<name>@<degrees>"); without one (or with a range) the row or filter takes every temperature.
--- The set functions of the blocks are used, so the blueprint tags and the windows see the same settings; windows
--- that show the block are refreshed at once.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local io = require("scripts.fork-me-io")
local sbus = require("scripts.fork-me-storagebus")
local G = require("scripts.fork-me-gui")

local M = {}

local SOURCE_TYPES = { ["assembling-machine"] = true, ["furnace"] = true, ["rocket-silo"] = true }
local MAX_FLUID_ROWS = 4             -- one per side of the interface
local MAX_ROW_AMOUNT = 1000000       -- what an item row of the interface holds at most (fork-me-io.lua, MAX_AMOUNT)
local SIDE_NAMES = { "north", "east", "south", "west" }

local function name_of(x)
	if type(x) == "string" then return x end
	return x and x.name
end

--- the machine's recipe (LuaRecipe or LuaRecipePrototype) and the quality name; a furnace without one: its previous
--- recipe
local function recipe_of(machine)
	local recipe, quality = machine.get_recipe()
	if recipe then return recipe, name_of(quality) or "normal" end
	if machine.type == "furnace" then
		local prev = machine.previous_recipe
		local proto = prev and prototypes.recipe[name_of(prev.name)]
		if proto then return proto, name_of(prev.quality) or "normal" end
	end
	return nil
end

--- the items and fluids of an ingredient or product list, in recipe order, each once: { { type, name, temperature,
--- amount } } (`amount`: per craft, an ingredient listed twice added up; issue #157).
--- Issue #161: a fluid keeps an exact temperature of the recipe (an ingredient's `temperature`, a product's); an
--- ingredient with a range or none gets none (every temperature)
local function entries(list)
	local out, seen = {}, {}
	for _, p in ipairs(list or {}) do
		local t = p.type or "item"
		local known = (t == "item" and prototypes.item[p.name]) or (t == "fluid" and prototypes.fluid[p.name])
		local key = t .. "/" .. tostring(p.name)
		local amount = p.amount or p.amount_max or 0
		if known and not seen[key] then
			out[#out + 1] = { type = t, name = p.name, temperature = t == "fluid" and p.temperature or nil, amount = amount }
			seen[key] = out[#out]
		elseif known then
			seen[key].amount = seen[key].amount + amount
		end
	end
	return out
end

local function icons(list)
	local parts = {}
	for _, e in ipairs(list) do parts[#parts + 1] = "[" .. e.type .. "=" .. e.name .. "]" end
	return table.concat(parts, " ")
end

local function msg(msgs, key, ...)
	msgs[#msgs + 1] = { "fork-me-paste." .. key, ... }
end

--------------------------------------------------------------------------------
--- the blocks
--------------------------------------------------------------------------------

local function paste_interface(dst, recipe, quality, msgs)
	local wanted = entries(recipe.ingredients)
	if #wanted == 0 then return msg(msgs, "no-ingredients") end
	local old_config, old_sides = io.get_interface_config(dst), io.get_interface_sides(dst)
	local config, row_of_fluid, fluids = {}, {}, 0
	local rows_full, fluids_full, capped = {}, {}, {}
	for _, e in ipairs(wanted) do
		if #config >= io.row_capacity(dst) then
			rows_full[#rows_full + 1] = e
		elseif e.type == "fluid" then
			if fluids >= MAX_FLUID_ROWS then
				fluids_full[#fluids_full + 1] = e
			else
				fluids = fluids + 1
				--- one craft, in whole units (a row holds whole units: rounded up, so one craft is always there)
				local amount = math.ceil(e.amount - 1e-6)
				if amount > io.side_volume() then
					amount = io.side_volume()
					capped[#capped + 1] = e
				end
				config[#config + 1] = { type = "fluid", name = e.name, amount = amount, temperature = e.temperature }
				row_of_fluid[e.name] = #config
			end
		else
			local amount = math.ceil(e.amount - 1e-6)
			if amount > MAX_ROW_AMOUNT then
				amount = MAX_ROW_AMOUNT
				capped[#capped + 1] = e
			end
			config[#config + 1] = { name = e.name, quality = quality, amount = amount }
		end
	end
	--- the sides: off stays off, a fluid that is there again keeps its sides, the rest imports
	local sides, tied = {}, {}
	for d = 1, io.SIDES do
		local v = old_sides[d]
		if v == "off" then
			sides[d] = "off"
		elseif type(v) == "number" then
			local old = old_config[v]
			local i = old and old.type == "fluid" and row_of_fluid[old.name]
			if i then
				sides[d] = i
				tied[i] = true
			end
		end
	end
	io.set_interface_config(dst, config, sides)
	for i, c in ipairs(config) do
		if c.type == "fluid" and not tied[i] then
			local d, piped = io.free_side(dst)
			local icon = "[fluid=" .. c.name .. "]"
			if d then
				io.set_interface_side(dst, d, i)
				if not piped then msg(msgs, "no-pipe", icon, { "fork-me-gui.interface-side-" .. SIDE_NAMES[d] }) end
			else
				msg(msgs, "no-side", icon)
			end
		end
	end
	if #rows_full > 0 then msg(msgs, "rows-full", tostring(io.row_capacity(dst)), icons(rows_full)) end
	if #fluids_full > 0 then msg(msgs, "fluids-full", tostring(MAX_FLUID_ROWS), icons(fluids_full)) end
	if #capped > 0 then msg(msgs, "amount-capped", icons(capped)) end
end

--- the keys of `list` (entries) for filters: items as "name" (`quality`: "name@quality"), fluids as "fluid/name" (with an
--- exact temperature "fluid/name@degrees", issue #161);
--- the rest beyond `max` goes into the second list
local function keys_of(list, quality, max)
	local keys, left = {}, {}
	for _, e in ipairs(list) do
		if #keys >= max then
			left[#left + 1] = e
		elseif e.type == "fluid" then
			keys[#keys + 1] = N.fluid_filter_key(e.name, e.temperature)
		else
			keys[#keys + 1] = quality and N.key_of(e.name, quality) or e.name
		end
	end
	return keys, left
end

local function only(list, t)
	local out = {}
	for _, e in ipairs(list) do if e.type == t then out[#out + 1] = e end end
	return out
end

local function paste_storage_bus(dst, recipe, quality, msgs)
	local info = sbus.info(dst)
	if not info then return end
	local wanted = entries(recipe.ingredients)
	if #wanted == 0 then return msg(msgs, "no-ingredients") end
	if info.target then                                  -- what it faces decides: items on a chest, fluids on a tank
		local side = info.side == "fluid" and "fluid" or "item"
		wanted = only(wanted, side)
		if #wanted == 0 then return msg(msgs, side == "fluid" and "no-fluids" or "no-items") end
	end
	--- issue #17: the filters that apply (more with Capacity Cards); only the filters change (mode, priority, cards and
	--- the other settings stay)
	local keys, left = keys_of(wanted, quality, info.max)
	sbus.set_settings(dst, { filters = keys })
	if #left > 0 then msg(msgs, "filters-full", tostring(info.max), icons(left)) end
end

local function paste_bus(dst, recipe, quality, msgs, import)
	local wanted = entries(import and recipe.products or recipe.ingredients)
	if #wanted == 0 then return msg(msgs, import and "no-products" or "no-ingredients") end
	local keys, left = keys_of(wanted, quality, io.MAX_FILTERS)
	io.set_bus_filters(dst, keys)
	if #left > 0 then msg(msgs, "filters-full", tostring(io.MAX_FILTERS), icons(left)) end
end

local PASTE = {
	["interface"] = paste_interface,
	["storage-bus"] = paste_storage_bus,
	["export-bus"] = function(dst, recipe, quality, msgs) paste_bus(dst, recipe, quality, msgs, false) end,
	["import-bus"] = function(dst, recipe, quality, msgs) paste_bus(dst, recipe, quality, msgs, true) end,
}

--- Paste the recipe of the crafting machine `src` onto the ME block `dst`. Returns the messages for the player (a
--- list of localised strings, empty when everything fitted), or nil when this is no recipe paste.
function M.paste(src, dst)
	if not (src and src.valid and dst and dst.valid and SOURCE_TYPES[src.type]) then return nil end
	local fn = PASTE[N.kind_of(dst.name)]
	if not fn then return nil end
	local msgs = {}
	local recipe, quality = recipe_of(src)
	if recipe then fn(dst, recipe, quality, msgs) else msg(msgs, "no-recipe") end
	for _, player in pairs(game.connected_players) do      -- open windows of the block show it now
		local frame = G.window_of(player)
		if frame and frame.tags.unit == dst.unit_number then G.refresh_one(player) end
	end
	return msgs
end

--- the messages as one localised string (one line each)
local function joined(msgs)
	if #msgs == 1 then return msgs[1] end
	local out = { "" }
	for i, m in ipairs(msgs) do
		if i > 1 then out[#out + 1] = "\n" end
		out[#out + 1] = m
	end
	return out
end

function M.on_entity_settings_pasted(event)
	local msgs = M.paste(event.source, event.destination)
	if not (msgs and msgs[1]) then return end
	local player = event.player_index and game.get_player(event.player_index)
	if player then player.create_local_flying_text{ text = joined(msgs), create_at_cursor = true } end
end

remote.add_interface("gregtorio-me-recipe-paste", {
	--- what the paste event does (the harness has no player): returns the messages the player would see
	paste = function(source, destination) return M.paste(source, destination) end,
})

return M
