--------------------------------------------------------------------------------
--- ME NETWORK: PARAMETRISED BLUEPRINTS (issue #781)
--- The settings of the ME blocks travel in blueprints as entity tags (fork_me_*), which the game never looks into: an item in
--- a tag is not offered in the game's "Parametrise blueprint" window and a parameter in a tag is not replaced when the
--- blueprint is placed. Nothing tells a script the values a player chose (Factorio 2.1.24: no event field, no accessor). What
--- the game does replace is every item, fluid and number in the fields of an entity that it knows itself, also on the
--- prototypes the ME blocks are (measured in a client: a display panel's records, a section of a constant combinator).
--- So a second copy of the items, fluids and amounts of a block's settings, the mirror, is written into such a field of the
--- blueprint entity when a blueprint is made, and read back when the block or its ghost is built:
---   * ME Import, Export and Storage Bus (display panels): filter i is record i of the control behaviour, its icon the item
---     (with its quality) or the fluid; the record's condition has no signal, so it never shows.
---   * ME Level Emitter and Advanced Level Emitter (constant combinators): the resource and the threshold of row i are the
---     first slot of section i + 1, signal and count; the section is inactive, so it sends nothing. (Section 1 is the output
---     the runtime writes.)
---   * ME Circuit Interface (a constant combinator): filter i is slot i of an inactive section 2, count 1.
--- Only the blueprint has the mirror. A built block or ghost is read once (M.resolve, called by control.lua before the
--- modules' build handlers): where the mirror differs from the tag, the mirror is what the game replaced and goes into the
--- tags; then the field is emptied, so a block in the world never shows or sends anything of it, and a ghost's tags are the
--- resolved ones (its ME window, issue #659, shows them). A blueprint without the mirror (made before, or by another
--- tool) is built from its tags as ever.
--- Limits: a count of a combinator is a 32-bit integer, so a threshold above 2 147 483 647 is not mirrored (the tag's stays);
--- a fluid filter keeps its temperature only while its fluid is not replaced; a key with data (tags, a label) has no signal
--- and is not mirrored. The ME Interface's rows and the Level Maintainer's rows have no such field (a container's slot
--- filters take items only and no amount; both of a lamp's conditions are in use) and stay as they are.
--- No state, no tick: the work is done when a blueprint is made and when a block is built.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")

local M = {}

local INT32 = 2147483647
--- what a block mirrors: its kind and the tag that holds the settings
local KINDS = {
	["me-import-bus"] = { kind = "filters", tag = "fork_me_bus", field = "records" },
	["me-export-bus"] = { kind = "filters", tag = "fork_me_bus", field = "records" },
	["me-storage-bus"] = { kind = "filters", tag = "fork_me_storage_bus", field = "records" },
	["me-circuit-interface"] = { kind = "filters", tag = "fork_me_circuit", field = "section" },
	["me-level-emitter"] = { kind = "emitter", tag = "fork_me_emitter" },
	["me-advanced-level-emitter"] = { kind = "emitter", tag = "fork_me_emitter" },
}
M.KINDS = KINDS

--------------------------------------------------------------------------------
--- keys and signals
--------------------------------------------------------------------------------

--- the signal of a key (an item with its quality, a fluid; nil: a key with data or of a prototype that is gone)
local function signal_of(key)
	if type(key) ~= "string" then return nil end
	if N.is_fluid_key(key) then
		local name = N.split_fluid_key(key)
		return name and prototypes.fluid[name] and { type = "fluid", name = name } or nil
	end
	local name, q, data = N.parse_key(key)
	if data or not (name and prototypes.item[name]) then return nil end
	q = (q and q ~= "normal" and prototypes.quality[q]) and q or nil
	return { type = "item", name = name, quality = q }
end
M.signal_of = signal_of

local function same(a, b)
	return a ~= nil and b ~= nil and (a.type or "item") == (b.type or "item") and a.name == b.name
		and (a.quality or "normal") == (b.quality or "normal")
end

--- the key of a signal the game left in a mirror; `old`: the key the tag has at that place, kept when it names the same
--- thing (a fluid filter's temperature is in the key only). Nil: neither an item nor a fluid.
local function key_of(sig, old)
	if type(sig) ~= "table" or type(sig.name) ~= "string" then return nil end
	if old and same(signal_of(old), sig) then return old end
	local t = sig.type or "item"
	if t == "fluid" then return prototypes.fluid[sig.name] and ("fluid/" .. sig.name) or nil end
	if t ~= "item" or not prototypes.item[sig.name] then return nil end
	local q = sig.quality
	if type(q) == "table" then q = q.name end                 -- (a LuaQualityPrototype or its name)
	return N.key_of(sig.name, (q and prototypes.quality[q]) and q or "normal")
end

--- the signals of a list of keys (nil when one of them has none: the places must stay the list's)
local function signals_of(keys)
	if type(keys) ~= "table" then return nil end
	local out = {}
	for i, key in ipairs(keys) do
		local sig = signal_of(key)
		if not sig then return nil end
		out[i] = sig
	end
	return #out > 0 and out or nil
end

--- the rows of an emitter's tag that can be mirrored: { [i] = { key, amount } } (a plain emitter: row 1)
local function emitter_rows(t)
	local rows = {}
	if type(t) ~= "table" then return rows end
	if type(t.rows) == "table" then
		for i, r in pairs(t.rows) do
			if type(i) == "number" and type(r) == "table" and type(r.key) == "string" then rows[i] = r end
		end
	elseif type(t.key) == "string" and not t.energy then
		rows[1] = t
	end
	return rows
end

--------------------------------------------------------------------------------
--- a blueprint is made: the mirror goes into its entities
--------------------------------------------------------------------------------

--- a slot of a combinator section in a blueprint
local function bp_slot(index, sig, count)
	return { index = index, type = sig.type, name = sig.name, quality = sig.quality or "normal", comparator = "=", count = count }
end

--- section 1 of a combinator's blueprint entity (the output of the moment), the mirror's sections after it
local function bp_sections(be, extra)
	local cb = type(be.control_behavior) == "table" and be.control_behavior or {}
	local holder = type(cb.sections) == "table" and cb.sections or {}
	local list = {}
	for _, s in pairs(type(holder.sections) == "table" and holder.sections or {}) do
		if type(s) == "table" and (s.index or 1) == 1 then list[#list + 1] = s end
	end
	for _, s in ipairs(extra) do list[#list + 1] = s end
	holder.sections = list
	cb.sections = holder
	be.control_behavior = cb
end

--- writes the mirror of blueprint entity `be` (its tags are there); returns whether it changed
local function write(be)
	local def = KINDS[be.name]
	local t = def and type(be.tags) == "table" and be.tags[def.tag]
	if type(t) ~= "table" then return false end
	if def.kind == "filters" then
		local sigs = signals_of(t.filters)
		if not sigs then return false end
		if def.field == "records" then
			local records = {}
			for i, sig in ipairs(sigs) do
				records[i] = { icon = sig, text = "", condition = { comparator = "<", constant = 0 } }
			end
			local cb = type(be.control_behavior) == "table" and be.control_behavior or {}
			cb.parameters = records
			be.control_behavior = cb
		else
			local slots, seen = {}, {}
			for i, sig in ipairs(sigs) do
				local id = (sig.type or "item") .. "/" .. sig.name .. "/" .. (sig.quality or "normal")
				if seen[id] then return false end               -- (a section takes a signal once)
				seen[id] = true
				slots[i] = bp_slot(i, sig, 1)
			end
			bp_sections(be, { { index = 2, active = false, filters = slots } })
		end
		return true
	end
	local extra = {}
	for i, r in pairs(emitter_rows(t)) do
		local sig = signal_of(r.key)
		local amount = tonumber(r.amount) or 0
		if sig and amount >= 0 and amount <= INT32 then
			extra[#extra + 1] = { index = i + 1, active = false, filters = { bp_slot(1, sig, math.floor(amount)) } }
		end
	end
	if #extra == 0 then return false end
	table.sort(extra, function(a, b) return a.index < b.index end)
	bp_sections(be, extra)
	return true
end

--- the mirrors of every ME block of blueprint `bp` (an item stack or a record), after the modules wrote their tags
function M.mirror_blueprint(bp)
	local ents = bp.get_blueprint_entities()
	if not ents then return false end
	local changed = false
	for _, be in pairs(ents) do
		if KINDS[be.name] and write(be) then changed = true end
	end
	if changed then bp.set_blueprint_entities(ents) end
	return changed
end

function M.on_player_setup_blueprint(event)
	local player = game.get_player(event.player_index)
	local bp = event.record or event.stack
	local function usable(b)
		return b and b.valid and (b.object_name == "LuaRecord" or (b.valid_for_read and b.is_blueprint)) and b.is_blueprint_setup()
	end
	if not usable(bp) and player then bp = player.blueprint_to_setup end
	if not usable(bp) and player then bp = player.cursor_stack end
	if not usable(bp) then return end
	pcall(M.mirror_blueprint, bp)             -- (a blueprint another mod changed may be unreadable: never break blueprinting)
end

--------------------------------------------------------------------------------
--- a block or its ghost is built: the mirror goes into its tags
--------------------------------------------------------------------------------

local function copy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = copy(v) end
	return out
end

--- the mirrored keys of a display panel's records (nil: no mirror), the mirror's records removed. A record without an icon
--- is none of the mirror's (a display panel that got a control behaviour through a wire has one empty record of its own).
local function read_records(e, old)
	local cb = e.get_control_behavior()
	if not (cb and cb.records_count > 0) then return nil end
	local records = cb.records
	local keys, found, n = {}, false, 0
	for i = 1, #records do
		local icon = records[i].icon
		if icon then
			found, n = true, n + 1
			local key = key_of(icon, old[n])
			if key then keys[#keys + 1] = key end
		end
	end
	if not found then return nil end
	for i = #records, 1, -1 do
		if records[i].icon then cb.remove_record(i) end
	end
	return keys
end

--- the first slot of section `i` of a combinator: its signal and count (nil: none)
local function slot_of(section, index)
	local f = section and section.get_slot(index)
	local v = f and f.value
	if not v then return nil end
	return v, f.min
end

--- the mirror's sections of a combinator go (section 1 is the output)
local function drop_sections(cb)
	for i = cb.sections_count, 2, -1 do cb.remove_section(i) end
end

local function read_section(e, old)
	local cb = e.get_control_behavior()
	if not (cb and cb.sections_count >= 2) then return nil end
	local section = cb.get_section(2)
	local keys = {}
	for i = 1, math.max(#old, section.filters_count or 0) do
		local key = key_of((slot_of(section, i)), old[i])
		if key then keys[#keys + 1] = key end
	end
	drop_sections(cb)
	return keys
end

--- an emitter's rows from its sections: changes `t` (a copy of the tag); returns whether a mirror was there
local function read_emitter(e, t)
	local cb = e.get_control_behavior()
	if not (cb and cb.sections_count >= 2) then return false end
	for i, r in pairs(emitter_rows(t)) do
		local section = i + 1 <= cb.sections_count and cb.get_section(i + 1) or nil
		local sig, count = slot_of(section, 1)
		local key = sig and key_of(sig, r.key)
		if key then
			r.key = key
			--- (the tag's amount stays while the count is its whole part: nothing was replaced)
			if count and math.floor(tonumber(r.amount) or 0) ~= count then r.amount = math.max(0, count) end
		end
	end
	drop_sections(cb)
	return true
end

--- The tags a built block or ghost is to be set up with: `tags` with what the game left in the mirror (a new table), or
--- `tags` as they are when the block has no mirror. A ghost's tags are read from it and written back. The second value:
--- whether a mirror was read.
function M.resolve(entity, tags)
	if not (entity and entity.valid) then return tags, false end
	local ghost = entity.name == "entity-ghost"
	local def = KINDS[ghost and entity.ghost_name or entity.name]
	if not def then return tags, false end
	if ghost then tags = entity.tags end
	local out = copy(type(tags) == "table" and tags or {})
	local t = type(out[def.tag]) == "table" and out[def.tag] or {}
	local ok, found
	if def.kind == "filters" then
		local old = type(t.filters) == "table" and t.filters or {}
		local keys
		ok, keys = pcall(def.field == "records" and read_records or read_section, entity, old)
		found = ok and keys ~= nil
		if found then t.filters = keys end
	else
		ok, found = pcall(read_emitter, entity, t)
		found = ok and found
	end
	if not found then return tags, false end
	out[def.tag] = t
	if ghost then entity.tags = out end
	return out, true
end

remote.add_interface("gregtorio-me-mirror", {
	--- tests: the mirror written into a blueprint (what on_player_setup_blueprint does after the tags), the tags of a built
	--- block or ghost resolved
	mirror_blueprint = function(bp) return M.mirror_blueprint(bp) end,
	resolve = function(entity, tags) return { M.resolve(entity, tags) } end,
})

return M
