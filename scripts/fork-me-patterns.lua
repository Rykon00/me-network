--------------------------------------------------------------------------------
--- FORK AE2: ENCODED PATTERNS (issue #80; docs/AE2.md "Patterns", docs/ME-REWORK.md "Encoded patterns")
---   * A pattern is plain data: { kind = "crafting" | "processing", recipe (crafting), inputs, outputs }, inputs and
---     outputs are lists of { key, amount } (resource keys of autocrafting: the item name, "fluid/<name>").
---     A crafting pattern names a recipe: its inputs and outputs are the recipe's (read again from the recipe when
---     it is used, so a changed recipe is followed). A processing pattern has free inputs and outputs.
---   * The blank pattern (me-blank-pattern) is a plain item. The encoded pattern (me-encoded-pattern) is an item
---     with tags, stack size 1: the pattern is its tag `fork_me_pattern`, the tooltip lists inputs and outputs
---     (custom description).
---   * Encoding takes a blank pattern from the cursor, the player's inventory or the ME network and puts the
---     encoded pattern into the cursor or the inventory; clearing turns an encoded pattern back into a blank one.
---     Nothing is created or lost on the way: the blank is taken only when the encoded pattern has a place.
--- The pattern slots of the providers, the planner and the jobs are in scripts/fork-me-autocraft.lua; the Patterns
--- tab of the ME Terminal (the encoding window) in scripts/fork-me-terminal.lua.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")

local M = {}

M.BLANK = "me-blank-pattern"
M.ENCODED = "me-encoded-pattern"
M.TAG = "fork_me_pattern"
M.MAX_INPUTS = 9           -- processing pattern: input rows of the encoding window
M.MAX_OUTPUTS = 6          -- processing pattern: output rows
M.MAX_AMOUNT = 1000000     -- per row

local FLUID_PREFIX = "fluid/"

local function is_fluid(key) return key:sub(1, #FLUID_PREFIX) == FLUID_PREFIX end
local function fluid_name(key) return key:sub(#FLUID_PREFIX + 1) end
M.is_fluid = is_fluid

--- item keys of a pattern are plain items (no items with tags: their data cannot be moved by name and count)
local function valid_key(key)
	if type(key) ~= "string" or key == "" then return false end
	if is_fluid(key) then return prototypes.fluid[fluid_name(key)] ~= nil end
	key = N.alias(key) or key                         -- a replaced item (issue #3)
	local proto = prototypes.item[key]
	return proto ~= nil and proto.type ~= "item-with-tags"
end
M.valid_key = valid_key

local function key_of(entry)
	if entry.type == "fluid" then return FLUID_PREFIX .. entry.name end
	return entry.name
end

--- expected amount per craft of a recipe product (probability and range)
local function expected(p)
	local amount = p.amount or ((p.amount_min + p.amount_max) / 2)
	return amount * (p.probability or 1)
end

--------------------------------------------------------------------------------
--- pattern data
--------------------------------------------------------------------------------

--- the inputs and outputs of a recipe as { key, amount } lists (amounts summed per key)
local function recipe_lists(proto)
	local function list(entries, amount_of)
		local out, at = {}, {}
		for _, e in pairs(entries) do
			local key = key_of(e)
			local n = amount_of(e)
			if n > 0 then
				if at[key] then out[at[key]].amount = out[at[key]].amount + n
				else
					out[#out + 1] = { key = key, amount = n }
					at[key] = #out
				end
			end
		end
		return out
	end
	return list(proto.ingredients, function(e) return e.amount end), list(proto.products, expected)
end

--- A clean copy of a list of { key, amount }: valid keys, positive amounts (items whole), each key once, at most
--- `max` rows. Returns nil when the list is empty or a row is invalid.
local function clean_list(list, max)
	if type(list) ~= "table" then return nil end
	local out, at = {}, {}
	for _, row in ipairs(list) do
		if type(row) ~= "table" or not valid_key(row.key) then return nil end
		local key = is_fluid(row.key) and row.key or (N.alias(row.key) or row.key)   -- a replaced item (issue #3)
		local amount = tonumber(row.amount)
		if not amount or amount <= 0 or amount ~= amount then return nil end
		if not is_fluid(key) then amount = math.floor(amount + 1e-9) end
		amount = math.min(amount, M.MAX_AMOUNT)
		if amount <= 0 then return nil end
		if at[key] then out[at[key]].amount = math.min(M.MAX_AMOUNT, out[at[key]].amount + amount)
		else
			out[#out + 1] = { key = key, amount = amount }
			at[key] = #out
		end
	end
	if #out == 0 or #out > max then return nil end
	return out
end

--- Validate a pattern (from tags, the encoding window, a blueprint). Returns the clean pattern, or nil and the
--- reason: "invalid" (broken data), "no-recipe" (the recipe is gone), "hidden" (a hidden recipe).
function M.normalize(def)
	if type(def) ~= "table" then return nil, "invalid" end
	if def.kind == "crafting" then
		local recipe = def.recipe
		--- issue #3: the recipe of a replaced item (the old fluid blocks) is the recipe of its replacement
		if type(recipe) == "string" and N.alias(recipe) and not (prototypes.recipe[recipe] and not prototypes.recipe[recipe].hidden) then
			recipe = N.alias(recipe)
		end
		local proto = type(recipe) == "string" and prototypes.recipe[recipe]
		if not proto then return nil, "no-recipe" end
		if proto.hidden then return nil, "hidden" end
		local inputs, outputs = recipe_lists(proto)
		if #outputs == 0 then return nil, "invalid" end
		return { kind = "crafting", recipe = proto.name, inputs = inputs, outputs = outputs }
	elseif def.kind == "processing" then
		local inputs = clean_list(def.inputs, M.MAX_INPUTS)
		local outputs = clean_list(def.outputs, M.MAX_OUTPUTS)
		if not (inputs and outputs) then return nil, "invalid" end
		local out = { kind = "processing", inputs = inputs, outputs = outputs }
		if type(def.recipe) == "string" and prototypes.recipe[def.recipe] then out.recipe = def.recipe end   -- where it came from
		return out
	end
	return nil, "invalid"
end

--- A crafting pattern of a recipe the force has unlocked. Returns the pattern, or nil and the reason
--- ("no-recipe", "not-researched", "hidden").
function M.crafting(force, recipe)
	local proto = type(recipe) == "string" and prototypes.recipe[recipe]
	if not proto then return nil, "no-recipe" end
	local r = force and force.recipes[recipe]
	if not (r and r.enabled) then return nil, "not-researched" end
	return M.normalize{ kind = "crafting", recipe = recipe }
end

--- A processing pattern: `inputs` and `outputs` are lists of { key, amount }; empty rows (nil key) are skipped.
--- `recipe`: the recipe it was filled from (only remembered). Returns the pattern, or nil and "invalid".
function M.processing(inputs, outputs, recipe)
	local function packed(list)
		local out = {}
		for _, row in pairs(list or {}) do
			if row and row.key then out[#out + 1] = { key = row.key, amount = row.amount } end
		end
		return out
	end
	return M.normalize{ kind = "processing", inputs = packed(inputs), outputs = packed(outputs), recipe = recipe }
end

--- the inputs and outputs of a recipe as processing pattern rows (the encoding window's "From recipe")
function M.recipe_rows(recipe)
	local proto = prototypes.recipe[recipe]
	if not proto then return nil end
	local inputs, outputs = recipe_lists(proto)
	return inputs, outputs
end

local function num(n)
	if n == math.floor(n) then return string.format("%d", n) end
	return string.format("%.6g", n)
end

--- The identity of a pattern: two equal patterns (in two providers) are one pattern of the network, their
--- machines are pooled.
function M.id_of(def)
	if def.kind == "crafting" then return "c/" .. def.recipe end
	local function part(list)
		local rows = {}
		for _, r in ipairs(list) do rows[#rows + 1] = r.key .. "*" .. num(r.amount) end
		table.sort(rows)
		return table.concat(rows, ",")
	end
	return "p/" .. part(def.inputs) .. ">" .. part(def.outputs)
end

--- What the planner and the jobs use: ingredients and products as { type, name, amount, ... } like a recipe's.
--- A crafting pattern reads its recipe (probabilities and ranges included), a processing pattern its rows.
function M.ingredients(def)
	if def.kind == "crafting" then
		local proto = prototypes.recipe[def.recipe]
		return proto and proto.ingredients or {}
	end
	local out = {}
	for _, r in ipairs(def.inputs) do
		out[#out + 1] = { type = is_fluid(r.key) and "fluid" or "item", name = is_fluid(r.key) and fluid_name(r.key) or r.key, amount = r.amount }
	end
	return out
end

function M.products(def)
	if def.kind == "crafting" then
		local proto = prototypes.recipe[def.recipe]
		return proto and proto.products or {}
	end
	local out = {}
	for _, r in ipairs(def.outputs) do
		out[#out + 1] = { type = is_fluid(r.key) and "fluid" or "item", name = is_fluid(r.key) and fluid_name(r.key) or r.key, amount = r.amount }
	end
	return out
end

--- amount of `key` per run of the pattern (from its rows)
function M.output_of(def, key)
	for _, r in ipairs(def.outputs) do if r.key == key then return r.amount end end
	return 0
end

--------------------------------------------------------------------------------
--- the item
--------------------------------------------------------------------------------

--- a LocalisedString of many parts (at most 19 per level: nested)
local function concat(parts)
	if #parts <= 19 then
		local out = { "" }
		for _, p in ipairs(parts) do out[#out + 1] = p end
		return out
	end
	local groups = {}
	for i = 1, #parts, 19 do
		local g = { "" }
		for j = i, math.min(i + 18, #parts) do g[#g + 1] = parts[j] end
		groups[#groups + 1] = g
	end
	return concat(groups)
end

local function row_text(r)
	if is_fluid(r.key) then
		local proto = prototypes.fluid[fluid_name(r.key)]
		return { "", "\n  [fluid=" .. fluid_name(r.key) .. "] " .. num(r.amount) .. " ", proto and proto.localised_name or r.key }
	end
	local proto = prototypes.item[r.key]
	return { "", "\n  [item=" .. r.key .. "] " .. num(r.amount) .. "x ", proto and proto.localised_name or r.key }
end

--- The tooltip of an encoded pattern: kind (and recipe), the inputs and the outputs
function M.description(def)
	local parts = {}
	if def.kind == "crafting" then
		local proto = prototypes.recipe[def.recipe]
		parts[#parts + 1] = { "fork-me-pattern.tip-crafting", "[recipe=" .. def.recipe .. "]", proto and proto.localised_name or def.recipe }
	else
		parts[#parts + 1] = { "fork-me-pattern.tip-processing" }
	end
	parts[#parts + 1] = { "", "\n", { "fork-me-pattern.tip-inputs" } }
	for _, r in ipairs(def.inputs) do parts[#parts + 1] = row_text(r) end
	parts[#parts + 1] = { "", "\n", { "fork-me-pattern.tip-outputs" } }
	for _, r in ipairs(def.outputs) do parts[#parts + 1] = row_text(r) end
	return concat(parts)
end

--- the item stack definition of an encoded pattern
function M.stack_def(def)
	return { name = M.ENCODED, count = 1, tags = { [M.TAG] = def }, custom_description = M.description(def) }
end

--- the pattern of an encoded pattern stack (as stored: not validated), nil for anything else
function M.read(stack)
	if not (stack and stack.valid_for_read and stack.name == M.ENCODED and stack.is_item_with_tags) then return nil end
	local tags = stack.tags
	local def = tags and tags[M.TAG]
	if type(def) ~= "table" then return nil end
	return def
end

--- true for an encoded pattern stack (even with broken data: it can still be cleared)
function M.is_encoded(stack)
	return stack ~= nil and stack.valid_for_read and stack.name == M.ENCODED
end

--- The pattern and its tooltip data for a GUI or a test: { kind, recipe, inputs, outputs, id, description }
function M.info(stack)
	local raw = M.read(stack)
	if not raw then return nil end
	local def, why = M.normalize(raw)
	local out = { kind = raw.kind, recipe = raw.recipe, inputs = raw.inputs, outputs = raw.outputs, valid = def ~= nil, reason = why }
	if def then out.id = M.id_of(def) out.description = M.description(def) end
	return out
end

--------------------------------------------------------------------------------
--- encoding and clearing (the logic of the Patterns tab; the runtime test calls the same functions)
--------------------------------------------------------------------------------

--- Encode `def` onto a blank pattern. `cursor`: the player's cursor stack (or nil), `inv`: the main inventory (or
--- nil), `net`: the terminal's network (or nil). The blank comes from the cursor, else the inventory, else the
--- network; the encoded pattern goes into the cursor (where the blank was, or an empty cursor), else into the
--- inventory. Returns "cursor" or "inventory", or nil and a reason ("invalid", "no-blank", "inventory-full").
function M.encode(cursor, inv, net, def)
	local clean, why = M.normalize(def)
	if not clean then return nil, why end
	local item = M.stack_def(clean)
	local source
	if cursor and cursor.valid_for_read and cursor.name == M.BLANK and cursor.quality.name == "normal" then
		source = "cursor"
	elseif inv and inv.get_item_count{ name = M.BLANK, quality = "normal" } > 0 then
		source = "inventory"
	elseif net and N.count(net, M.BLANK, "normal") > 0 then
		source = "network"
	else
		return nil, "no-blank"
	end
	--- the encoded pattern replaces a single blank in the cursor, or goes into an empty cursor
	if source == "cursor" and cursor.count == 1 then
		cursor.set_stack(item)
		return "cursor"
	end
	local function take()
		if source == "cursor" then cursor.count = cursor.count - 1 return true end
		if source == "inventory" then return inv.remove{ name = M.BLANK, quality = "normal", count = 1 } == 1 end
		return N.extract(net, M.BLANK, "normal", 1) == 1
	end
	if cursor and not cursor.valid_for_read then
		if not take() then return nil, "no-blank" end
		cursor.set_stack(item)
		return "cursor"
	end
	--- else into the inventory (the blank is taken first: its slot may be the free one); no room: the blank goes back
	if not inv then return nil, "inventory-full" end
	if not take() then return nil, "no-blank" end
	if inv.insert(item) < 1 then
		if source == "cursor" then cursor.count = cursor.count + 1
		elseif source == "inventory" then inv.insert{ name = M.BLANK, count = 1 }
		else N.insert(net, M.BLANK, "normal", 1) end
		return nil, "inventory-full"
	end
	return "inventory"
end

--- Clear an encoded pattern stack: it becomes one blank pattern. Returns true when it did.
function M.clear(stack)
	if not M.is_encoded(stack) then return false end
	stack.set_stack{ name = M.BLANK, count = 1 }
	return true
end

return M
