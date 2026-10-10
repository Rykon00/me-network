--------------------------------------------------------------------------------
--- ME NETWORK: ME PATTERN TERMINAL (issue #130; the encoding window that was the Patterns tab of the ME Terminal, issue #80)
---   A block of its own (GTNH's AE2 has "ME Pattern Terminal" too; the plain terminal has no pattern function there). It is a
---   member of the network like the ME Terminal: it takes its power through the controller (#128) and can be walked over (#129).
---   * The window: the pattern editor (crafting mode: a recipe; processing mode: up to 9 inputs and 6 outputs, "fill from a
---     recipe"), the block's two slots, **Encode**, **Load pattern** and **Clear pattern**, and the player's inventory pane.
---   * The two slots are the block's inventory (a script inventory in `storage.fork_me_pterm[unit].inv`, like the card slots of
---     the buses): a **blank pattern slot** that takes only blank patterns, and an **output slot** that holds one encoded
---     pattern. Encode follows GTNH (appeng/helpers/PatternEncodingHelper.java): it takes one blank from the blank slot, else
---     one from the network, and nothing happens when there is none; the encoded pattern lands in the output slot (shift + click
---     on Encode: straight into the player's inventory); an encoded pattern lying in the output slot is encoded again in place,
---     without a blank. Clicking the empty blank slot with an empty hand fetches blank patterns from the network. The hand and
---     the inventory are not searched for blanks.
---   * Load pattern and Clear pattern work on the encoded pattern in the hand, else on the one in the output slot (a cleared
---     one becomes a blank pattern in the blank slot).
---   * What lies in the slots stays when the window closes, is saved, comes out when the block is mined (into the mined buffer)
---     and is spilled when it is destroyed or vanishes; blueprints, copies and clones start with empty slots.
--- The pattern data and the encoding itself are in scripts/fork-me-patterns.lua (`encode_slots`).
--- State: storage.fork_me_pterm[unit] = { entity, inv, where }; storage.fork_me_pterm_ui[player_index] = { pat = editor, shown }
--- (the editor is the player's, kept while the window is closed).
--- Every function here is called by the runtime test through the remote interface `gregtorio-me-pattern-terminal`.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local G = require("scripts.fork-me-gui")
local P = require("scripts.fork-me-patterns")
local picker = require("scripts.fork-me-picker")

local M = {}

local NAME = "me-pattern-terminal"
local BLANK_SLOT, OUTPUT_SLOT = 1, 2
local COLUMNS = 10
local WIDTH = 40 * COLUMNS + 12

--- Issue #210: the window of a wireless terminal in pattern mode has an access point as its entity: no block, no slots; Encode
--- takes the blank from the network and puts the pattern into the player's inventory, Load and Clear work on the hand.
local function wireless(entity) return entity ~= nil and entity.valid and N.kind_of(entity.name) == "access-point" end

local function records()
	storage.fork_me_pterm = storage.fork_me_pterm or {}
	return storage.fork_me_pterm
end

local function ui()
	storage.fork_me_pterm_ui = storage.fork_me_pterm_ui or {}
	return storage.fork_me_pterm_ui
end

--------------------------------------------------------------------------------
--- the block's record and its two slots
--------------------------------------------------------------------------------

--- where the slots' items go when nobody takes them: the block's position (kept: a block can vanish without an event)
local function remember_place(rec)
	local e = rec.entity
	if e and e.valid then rec.where = { surface = e.surface.index, x = e.position.x, y = e.position.y } end
end

--- the record of a pattern terminal (made when it is first asked for), or nil for any other entity
local function rec_of(entity)
	if not (entity and entity.valid and entity.name == NAME) then return nil end
	local unit = entity.unit_number
	local rec = records()[unit]
	if not rec then
		rec = { entity = entity }
		records()[unit] = rec
	end
	if not (rec.inv and rec.inv.valid) then rec.inv = game.create_inventory(2, { "entity-name." .. NAME }) end
	rec.entity = entity
	remember_place(rec)
	return rec
end
M.rec_of = rec_of

--- the slots as an inventory (slot 1: blank patterns, slot 2: the encoded pattern)
function M.inventory(entity)
	local rec = rec_of(entity)
	return rec and rec.inv or nil
end

--- the working network of a block, or nil and the reason ("no-network", "no-controller", "conflict", "no-power")
local function network(entity)
	local net = N.network_of(entity)
	if not net then return nil, "no-network" end
	local ok, why = N.usable(net)
	if not ok then return nil, why end
	return net
end
M.network = network

--- the blank patterns in the slot and in the network
function M.blanks(entity)
	local rec = rec_of(entity)
	local slot = rec and rec.inv[BLANK_SLOT]
	local own = (slot and slot.valid_for_read and slot.name == P.BLANK) and slot.count or 0
	local net = network(entity)
	return own, net and N.count(net, P.BLANK, "normal") or 0
end

--- every stack in the slots into `target` (a LuaInventory or the mined buffer); what does not fit onto the ground
local function give_all(rec, target)
	local e = rec.entity
	local surface, pos
	if e and e.valid then surface, pos = e.surface, e.position
	elseif rec.where then surface, pos = game.get_surface(rec.where.surface), { rec.where.x, rec.where.y } end
	for slot = 1, #rec.inv do
		local stack = rec.inv[slot]
		if stack.valid_for_read then
			local got = target and target.valid and target.insert(stack) or 0
			if got >= stack.count then
				stack.clear()
			else
				if got > 0 then stack.count = stack.count - got end
				if surface then
					surface.spill_item_stack{ position = pos, stack = stack, allow_belts = false }
					stack.clear()
				end
			end
		end
	end
end

--- The block is mined (`buffer`: the event's mined buffer) or destroyed (nil: its slots are spilled where it stood): the
--- record and its inventory go. Called before the entity is gone.
function M.on_removed(entity, buffer)
	if not (entity and entity.valid and entity.name == NAME) then return end
	local rec = records()[entity.unit_number]
	if not rec then return end
	if rec.inv and rec.inv.valid then
		give_all(rec, buffer)
		rec.inv.destroy()
	end
	records()[entity.unit_number] = nil
end

--- a member that vanished without an event (the network's sweep): its slots are spilled where it stood
N.vanish_hooks[#N.vanish_hooks + 1] = function(unit)
	local rec = storage.fork_me_pterm and storage.fork_me_pterm[unit]
	if not rec then return end
	if rec.inv and rec.inv.valid then
		give_all(rec, nil)
		rec.inv.destroy()
	end
	storage.fork_me_pterm[unit] = nil
end

--- built, revived or cloned: a record with empty slots (a blueprint or a clone never carries the slots' contents)
function M.on_built(entity)
	rec_of(entity)
end

--------------------------------------------------------------------------------
--- the editor (a plain table: mode "crafting" or "processing", the recipe, the input and output rows)
--------------------------------------------------------------------------------

local function new_editor()
	return { mode = "crafting", recipe = nil, inputs = {}, outputs = {} }
end
M.new_editor = new_editor

--- The pattern the editor describes, or nil and the reason ("no-recipe", "not-researched", "invalid", ...)
function M.pattern_of(force, ed)
	if ed.mode == "crafting" then return P.crafting(force, ed.recipe) end
	local inputs, outputs = {}, {}
	for i = 1, P.MAX_INPUTS do local r = ed.inputs[i] if r and r.key then inputs[#inputs + 1] = r end end
	for i = 1, P.MAX_OUTPUTS do local r = ed.outputs[i] if r and r.key then outputs[#outputs + 1] = r end end
	local recipe = ed.recipe and force.recipes[ed.recipe] and force.recipes[ed.recipe].enabled and ed.recipe or nil
	return P.processing(inputs, outputs, recipe)
end

--- The recipe chooser: in crafting mode the pattern's recipe, in processing mode it fills the rows from the
--- recipe. Returns true, or nil and the reason ("not-researched", "too-many-rows").
function M.set_editor_recipe(force, ed, recipe)
	if recipe == nil then ed.recipe = nil return true end
	local r = force.recipes[recipe]
	if not (r and r.enabled and prototypes.recipe[recipe]) then return nil, "not-researched" end
	ed.recipe = recipe
	if ed.mode == "processing" then
		local inputs, outputs = P.recipe_rows(recipe)
		if #inputs > P.MAX_INPUTS or #outputs > P.MAX_OUTPUTS then return nil, "too-many-rows" end
		ed.inputs, ed.outputs = inputs, outputs
	end
	return true
end

--- a row of the processing editor: `which` "inputs" or "outputs", `key` (nil clears the row), `amount` (nil keeps it)
function M.set_editor_row(ed, which, index, key, amount)
	local rows = ed[which]
	local max = which == "inputs" and P.MAX_INPUTS or P.MAX_OUTPUTS
	if not rows or index < 1 or index > max then return false end
	if key == false then rows[index] = nil return true end
	local row = rows[index] or { amount = 1 }
	if key ~= nil then
		if not P.valid_key(key) then return false end
		row.key = key
	end
	if amount ~= nil then row.amount = math.max(0, tonumber(amount) or 0) end
	rows[index] = row.key and row or nil
	return true
end

--- the encoded pattern a player can load or clear: the one in the hand, else the one in the output slot
local function source_stack(rec, cursor)
	if P.is_encoded(cursor) then return cursor, "hand" end
	local out = rec and rec.inv[OUTPUT_SLOT]
	if P.is_encoded(out) then return out, "output" end
	return nil
end

--- "Load pattern": the encoded pattern in the hand (else in the output slot) into the editor. Returns true and where it
--- came from ("hand" or "output"), or nil and a reason.
function M.load_pattern(entity, cursor, ed)
	local stack, where = source_stack(rec_of(entity), cursor)
	local raw = stack and P.read(stack)
	local def = raw and P.normalize(raw)
	if not def then return nil, "no-pattern-in-hand" end
	ed.mode, ed.recipe = def.kind, def.recipe
	ed.inputs, ed.outputs = {}, {}
	for i, r in ipairs(def.inputs) do if i <= P.MAX_INPUTS then ed.inputs[i] = { key = r.key, amount = r.amount } end end
	for i, r in ipairs(def.outputs) do if i <= P.MAX_OUTPUTS then ed.outputs[i] = { key = r.key, amount = r.amount } end end
	return true, where
end

--------------------------------------------------------------------------------
--- Encode, Clear and the clicks on the slots
--------------------------------------------------------------------------------

--- The Encode button: the editor's pattern into the output slot (P.encode_slots: the blank from the blank slot, else the
--- network; an encoded pattern in the output slot is encoded again in place). `back` (shift + click): a LuaInventory the
--- encoded pattern goes into at once (it stays in the slot when it does not fit). Needs a working network. Returns "output"
--- or "inventory", or nil and the reason.
function M.encode(entity, force, ed, back)
	local rec = rec_of(entity)
	if not rec and wireless(entity) then return M.encode_wireless(entity, force, ed, back) end
	if not rec then return nil, "no-network" end
	local net, why = network(entity)
	if not net then return nil, why end
	local def, dwhy = M.pattern_of(force, ed)
	if not def then return nil, dwhy end
	local where, ewhy = P.encode_slots(rec.inv[BLANK_SLOT], rec.inv[OUTPUT_SLOT], net, def)
	if not where then return nil, ewhy end
	local out = rec.inv[OUTPUT_SLOT]
	if back and back.valid and back.insert(out) >= 1 then
		out.clear()
		return "inventory"
	end
	return "output"
end

--- Issue #210: Encode without a block (a wireless terminal): the blank from the network, the pattern into `back` (the player's
--- inventory), refused before anything moves when there is no room. Returns "inventory", or nil and the reason.
function M.encode_wireless(entity, force, ed, back)
	if not (back and back.valid) then return nil, "no-inventory" end
	local net, why = network(entity)
	if not net then return nil, why end
	local def, dwhy = M.pattern_of(force, ed)
	if not def then return nil, dwhy end
	if not back.can_insert{ name = P.ENCODED, count = 1 } then return nil, "inventory-full" end
	local tmp = game.create_inventory(2)
	local where, ewhy = P.encode_slots(tmp[BLANK_SLOT], tmp[OUTPUT_SLOT], net, def)
	if where and tmp[OUTPUT_SLOT].valid_for_read then
		if back.insert(tmp[OUTPUT_SLOT]) >= 1 then tmp[OUTPUT_SLOT].clear() end
		if tmp[OUTPUT_SLOT].valid_for_read then N.insert_stack(net, tmp[OUTPUT_SLOT]) end   -- (no room after all: into the network)
	end
	for i = 1, 2 do
		if tmp[i].valid_for_read then N.insert_stack(net, tmp[i]) end
	end
	tmp.destroy()
	if not where then return nil, ewhy end
	return "inventory"
end

--- Encode a pattern given as data onto the two slots of `inv` (a 2-slot inventory of a test, standing for the block: its first
--- slot holds a blank, the encoded pattern lands in its second slot); `net`: where a blank comes from when the slot has none.
function M.encode_def(inv, net, def)
	return P.encode_slots(inv[BLANK_SLOT], inv[OUTPUT_SLOT], net, def)
end

--- "Clear pattern": the encoded pattern in the hand (else in the output slot) becomes a blank pattern; one from the output
--- slot goes into the blank slot, or into `back` (G.give_back: the player, an inventory, nil for the ground) when that holds
--- something else or is full. Returns true and where it was, or nil and a reason.
function M.clear(entity, cursor, back)
	local rec = rec_of(entity)
	local stack, where = source_stack(rec, cursor)
	if not stack then return nil, "no-pattern-in-hand" end
	if where == "hand" then
		P.clear(stack)
		return true, "hand"
	end
	stack.clear()
	local blank = rec.inv[BLANK_SLOT]
	if not blank.valid_for_read then
		blank.set_stack{ name = P.BLANK, count = 1 }
	elseif blank.name == P.BLANK and blank.quality.name == "normal" and blank.count < blank.prototype.stack_size then
		blank.count = blank.count + 1
	else
		local tmp = game.create_inventory(1)
		tmp[1].set_stack{ name = P.BLANK, count = 1 }
		G.give_back(back, tmp[1], entity)
		tmp.destroy()
	end
	return true, "output"
end

local function is_blank(stack)
	return stack ~= nil and stack.valid_for_read and stack.name == P.BLANK and stack.quality.name == "normal"
end

--- A click on slot `slot` of the window (the window's `click`; the tests call it too), for the player's `cursor` (LuaItemStack)
--- and main inventory `inventory`. Nothing moves when a reason is returned.
---   blank slot: with blank patterns in the cursor they go in (merging); with an empty cursor a filled slot is taken into the
---     cursor (shift: into the inventory), an empty slot fetches blank patterns from the network (up to a stack).
---   output slot: an encoded pattern in the cursor goes in (swapping with the one there); with an empty cursor the pattern is
---     taken into the cursor (shift: into the inventory).
function M.click(entity, slot, cursor, inventory, shift)
	local rec = rec_of(entity)
	if not rec then return "no-target" end
	local stack = rec.inv[slot]
	if not stack then return "no-target" end
	local holding = cursor and cursor.valid_for_read
	if slot == BLANK_SLOT then
		if holding then
			if not is_blank(cursor) then return "not-a-blank" end
			if stack.valid_for_read and stack.count >= stack.prototype.stack_size then return "slot-full" end
			stack.transfer_stack(cursor)
			return nil
		end
		if stack.valid_for_read then
			if shift then
				if not (inventory and inventory.valid) then return "no-inventory" end
				local got = inventory.insert(stack)
				if got < 1 then return "inventory-full" end
				if got >= stack.count then stack.clear() else stack.count = stack.count - got end
				return nil, "out"
			end
			if not (cursor and cursor.transfer_stack(stack)) then return "inventory-full" end
			return nil
		end
		local net, why = network(entity)
		if not net then return why end
		if N.count(net, P.BLANK, "normal") < 1 then return "no-blank" end
		N.extract_to(net, stack, P.BLANK, prototypes.item[P.BLANK].stack_size)
		return nil
	elseif slot == OUTPUT_SLOT then
		if holding then
			if not P.is_encoded(cursor) then return "not-encoded" end
			if stack.valid_for_read then stack.swap_stack(cursor) else stack.transfer_stack(cursor) end
			return nil
		end
		if not stack.valid_for_read then return nil end
		if shift then
			if not (inventory and inventory.valid) then return "no-inventory" end
			if inventory.insert(stack) < 1 then return "inventory-full" end
			stack.clear()
			return nil, "out"
		end
		if not (cursor and cursor.transfer_stack(stack)) then return "inventory-full" end
		return nil
	end
	return "no-target"
end

--- Shift + click on stack `stack` of the player's inventory in the window: blank patterns go into the blank slot, an encoded
--- pattern into the output slot (when it is empty). Returns the reason when nothing goes in.
function M.shift_in(entity, stack, inventory)
	local rec = rec_of(entity)
	if not rec then return "no-target" end
	if is_blank(stack) then
		local slot = rec.inv[BLANK_SLOT]
		if slot.valid_for_read and slot.count >= slot.prototype.stack_size then return "slot-full" end
		slot.transfer_stack(stack)
		return nil
	elseif P.is_encoded(stack) then
		local out = rec.inv[OUTPUT_SLOT]
		if out.valid_for_read then return "output-full" end
		out.transfer_stack(stack)
		return nil
	end
	return "not-a-pattern-slot"
end

--------------------------------------------------------------------------------
--- the window
--------------------------------------------------------------------------------

local function report(player, why)
	if why and why ~= "empty" then
		player.create_local_flying_text{ text = G.net_message(why), create_at_cursor = true }
	end
end

local function editor_rows(parent, ed, which, max)
	local t = parent.add{ type = "table", column_count = 6 }
	t.style.horizontal_spacing = 4
	for i = 1, max do
		local row = ed[which][i]
		G.key_button(t, row and row.key, G.act("pat_row", { which = which, index = i }), { "fork-me-gui.key-slot-tooltip" })
		--- (issue #261: a fluid amount of a pattern from before, 14.400000035762787, shows as 14.4; typing changes the row)
		local shown = row and P.clean_amount(row.amount, which == "inputs") or 0
		local f = G.number_field(t, shown, G.act("pat_amount", { which = which, index = i }), 60)
		f.allow_decimal = true
		f.enabled = row ~= nil
	end
end

local function build_pattern_box(box, player, ed)
	local mode = G.row(box)
	mode.add{ type = "switch", switch_state = ed.mode == "processing" and "right" or "left",
		left_label_caption = { "fork-me-pattern.kind-crafting" }, left_label_tooltip = { "fork-me-gui.patterns-crafting-tooltip" },
		right_label_caption = { "fork-me-pattern.kind-processing" }, right_label_tooltip = { "fork-me-gui.patterns-processing-tooltip" },
		tags = G.act("pat_mode") }
	local row = G.row(box)
	row.add{ type = "label", caption = { ed.mode == "crafting" and "fork-me-gui.patterns-recipe" or "fork-me-gui.patterns-from-recipe" } }
	row.add{ type = "choose-elem-button", elem_type = "recipe", recipe = ed.recipe, style = "slot_button",
		elem_filters = { { filter = "hidden", invert = true } }, tags = G.act("pat_recipe") }
	if ed.mode == "crafting" then
		local def = ed.recipe and P.crafting(player.force, ed.recipe)
		if not def then
			G.label(box, { "fork-me-gui.patterns-choose-recipe" }, WIDTH)
			return
		end
		local t = box.add{ type = "table", column_count = COLUMNS, style = "filter_slot_table" }
		for _, r in ipairs(def.inputs) do G.slot(t, r.key, r.amount) end
		t.add{ type = "label", caption = "  =>  " }
		for _, r in ipairs(def.outputs) do G.slot(t, r.key, r.amount) end
		return
	end
	G.heading(box, { "fork-me-gui.patterns-inputs" })
	editor_rows(box, ed, "inputs", P.MAX_INPUTS)
	G.heading(box, { "fork-me-gui.patterns-outputs" })
	editor_rows(box, ed, "outputs", P.MAX_OUTPUTS)
end

local function slot_column(parent, caption, name, slot, tooltip)
	local col = parent.add{ type = "flow", direction = "vertical" }
	col.style.horizontal_align = "center"
	col.add{ type = "label", caption = caption }
	col.add{ type = "sprite-button", name = name, style = "slot_button", tags = G.act("block_slot", { slot = slot }), tooltip = tooltip }
end

local function open(player, entity)
	if not (entity and entity.valid and (entity.name == NAME or wireless(entity))) then return end
	local remote_view = wireless(entity)
	if not remote_view then rec_of(entity) end
	local _, content = G.open_window(player, "pattern-terminal", { "fork-me-pattern-terminal.title" }, { unit = entity.unit_number })
	local u = ui()[player.index]
	if not u then
		u = { pat = new_editor() }
		ui()[player.index] = u
	end
	u.pat = u.pat or new_editor()
	u.shown = nil
	G.label(content, "", WIDTH, nil, "fork_me_net_line")
	if remote_view and G.wireless_mode_button then G.wireless_mode_button(content, entity, "terminal") end   -- (issue #210)
	G.label(content, { remote_view and "fork-me-wireless.patterns-help" or "fork-me-gui.patterns-help" }, WIDTH)
	content.add{ type = "flow", name = "fork_me_pat_box", direction = "vertical" }
	content.add{ type = "line" }
	local row = G.row(content)
	if not remote_view then
		slot_column(row, { "fork-me-pattern-terminal.blank-slot" }, "fork_me_pt_blank", BLANK_SLOT, { "fork-me-pattern-terminal.blank-slot-tooltip" })
	end
	local mid = row.add{ type = "flow", direction = "vertical" }
	mid.add{ type = "button", name = "fork_me_pat_encode", caption = { "fork-me-gui.patterns-encode" }, style = "confirm_button",
		tooltip = { remote_view and "fork-me-wireless.encode-tooltip" or "fork-me-gui.patterns-encode-tooltip" }, tags = G.act("pat_encode") }
	if not remote_view then
		slot_column(row, { "fork-me-pattern-terminal.output-slot" }, "fork_me_pt_output", OUTPUT_SLOT, { "fork-me-pattern-terminal.output-slot-tooltip" })
	end
	row.add{ type = "empty-widget" }.style.horizontally_stretchable = true
	local buttons = row.add{ type = "flow", direction = "vertical" }
	buttons.add{ type = "button", caption = { "fork-me-gui.patterns-load" }, tooltip = { "fork-me-gui.patterns-load-tooltip" },
		tags = G.act("pat_load") }
	buttons.add{ type = "button", caption = { "fork-me-gui.patterns-clear" }, tooltip = { "fork-me-gui.patterns-clear-tooltip" },
		tags = G.act("pat_clear") }
	G.label(content, "", WIDTH, nil, "fork_me_pat_status")
	M.refresh(player)
end
M.open = open

function M.refresh(player, frame)
	frame = frame or G.window_of(player)
	local u = ui()[player.index]
	if not (frame and u) then return false end
	local entity = G.entity_of(player, frame)
	local rec = entity and rec_of(entity)
	if not (rec or wireless(entity)) then return false end
	local net_line, box = G.find(frame, "fork_me_net_line"), G.find(frame, "fork_me_pat_box")
	if not (net_line and box) then return false end                           -- built by another version
	local net, why = network(entity)
	net_line.caption = net and { "fork-me-net.status-ok" } or { "fork-me-net.status-" .. why }
	local ed = u.pat or new_editor()
	u.pat = ed
	--- the box is rebuilt when the mode, the recipe or a row's item changes (not the amounts: their fields keep the focus)
	local sig = { ed.mode, tostring(ed.recipe) }
	for i = 1, P.MAX_INPUTS do sig[#sig + 1] = ed.inputs[i] and ed.inputs[i].key or "-" end
	for i = 1, P.MAX_OUTPUTS do sig[#sig + 1] = ed.outputs[i] and ed.outputs[i].key or "-" end
	sig = table.concat(sig, ",")
	if u.shown ~= sig then
		u.shown = sig
		box.clear()
		build_pattern_box(box, player, ed)
	end
	local out = rec and rec.inv[OUTPUT_SLOT]
	if rec then
		G.render_slot(G.find(frame, "fork_me_pt_blank"), rec.inv[BLANK_SLOT], nil, { "fork-me-pattern-terminal.blank-slot-tooltip" })
		G.render_slot(G.find(frame, "fork_me_pt_output"), out, nil, { "fork-me-pattern-terminal.output-slot-tooltip" })
	end
	local own, in_net = M.blanks(entity)
	G.find(frame, "fork_me_pat_status").caption = { "", { "fork-me-pattern-terminal.blanks", own, in_net },
		P.is_encoded(out) and { "fork-me-pattern-terminal.in-output" } or "",
		P.is_encoded(player.cursor_stack) and { "fork-me-gui.patterns-in-hand" } or "" }
	local def = M.pattern_of(player.force, ed)
	G.find(frame, "fork_me_pat_encode").enabled = net ~= nil and def ~= nil
		and (P.is_encoded(out) or own > 0 or in_net > 0)
	return true
end

--- the inventory pane: shift + click sends blank patterns to the blank slot and an encoded pattern to the output slot
G.window("pattern-terminal", { open = open, refresh = function(player, frame) return M.refresh(player, frame) end,
	entities = { NAME }, hint = { "fork-me-pattern-terminal.store-help" },
	shift = function(entity, stack, inventory) return M.shift_in(entity, stack, inventory) end,
	click = function(entity, slot, cursor, inventory, shift) return M.click(entity, slot, cursor, inventory, shift) end,
	message = G.net_message })

--------------------------------------------------------------------------------
--- actions (the elements' tags carry them: scripts/fork-me-gui.lua dispatch)
--------------------------------------------------------------------------------

local function ui_of(player) return ui()[player.index] end

G.on("pat_mode", function(event, player, el)
	if event.name ~= defines.events.on_gui_switch_state_changed then return end
	local u = ui_of(player)
	if not u then return end
	u.pat = u.pat or new_editor()
	u.pat.mode = el.switch_state == "right" and "processing" or "crafting"
	M.refresh(player)
end)

G.on("pat_recipe", function(event, player, el)
	if event.name ~= defines.events.on_gui_elem_changed then return end
	local u = ui_of(player)
	if not u then return end
	u.pat = u.pat or new_editor()
	local ok, why = M.set_editor_recipe(player.force, u.pat, el.elem_value)
	if not ok then
		el.elem_value = u.pat.recipe
		report(player, why)
	end
	u.shown = nil
	M.refresh(player)
end)

--- issue #70: a click on a row's button opens the picker (items and fluids, no quality: a pattern names plain items), right
--- click empties the row
G.on("pat_row", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local u = ui_of(player)
	if not u then return end
	u.pat = u.pat or new_editor()
	local which, index = el.tags.which, el.tags.index
	local row = u.pat[which][index]
	if event.button == defines.mouse_button_type.right then
		if row then M.set_editor_row(u.pat, which, index, false) M.refresh(player) end
		return
	end
	picker.open(player, { callback = "pat_row", data = { which = which, index = index }, kinds = { item = true, fluid = true },
		preset = picker.preset_of(row and row.key), quality = false })
end)

--- (a key a pattern cannot name, an item with tags, empties the row, with the message, as before)
picker.on_confirm("pat_row", function(player, data, choice)
	local u = ui_of(player)
	if not (u and u.pat) then return end
	local key = picker.key_of(choice, false)
	if key and not P.valid_key(key) then key = nil end
	if not key then report(player, "not-a-pattern-row") end
	M.set_editor_row(u.pat, data.which, data.index, key or false)
	M.refresh(player)
end)

G.on("pat_amount", function(event, player, el)
	if event.name ~= defines.events.on_gui_text_changed and event.name ~= defines.events.on_gui_confirmed then return end
	local u = ui_of(player)
	if not (u and u.pat) then return end
	M.set_editor_row(u.pat, el.tags.which, el.tags.index, nil, tonumber(el.text) or 0)
end)

local function window_entity(player)
	local frame = G.window_of(player)
	return frame and G.entity_of(player, frame)
end

G.on("pat_encode", function(event, player)
	local u, entity = ui_of(player), window_entity(player)
	if not (u and u.pat and entity) then return end
	local where, why = M.encode(entity, player.force, u.pat, (event.shift or wireless(entity)) and G.player_inventory(player) or nil)
	if where then
		player.create_local_flying_text{ text = { "fork-me-pattern-terminal.encoded-" .. where }, create_at_cursor = true }
	else
		report(player, why)
	end
	G.refresh_one(player)
end)

G.on("pat_clear", function(event, player)
	local entity = window_entity(player)
	if not entity then return end
	local _, why = M.clear(entity, (G.hand(player)), player)
	report(player, why)
	G.refresh_one(player)
end)

G.on("pat_load", function(event, player)
	local u, entity = ui_of(player), window_entity(player)
	if not (u and entity) then return end
	u.pat = u.pat or new_editor()
	local _, why = M.load_pattern(entity, (G.hand(player)), u.pat)
	report(player, why)
	u.shown = nil
	G.refresh_one(player)
end)

--------------------------------------------------------------------------------
--- the remote interface (the runtime test; every function is what a button does)
--------------------------------------------------------------------------------

remote.add_interface("gregtorio-me-pattern-terminal", {
	new_editor = function() return new_editor() end,
	pattern_of = function(force, ed) return M.pattern_of(force, ed) end,
	set_editor_recipe = function(force, ed, recipe)
		local ok, why = M.set_editor_recipe(force, ed, recipe)
		return ok, why, ed
	end,
	set_editor_row = function(ed, which, index, key, amount) local ok = M.set_editor_row(ed, which, index, key, amount) return ok, ed end,
	--- the Encode button; `back`: an inventory for shift + click
	encode = function(entity, force, ed, back) return M.encode(entity, force, ed, back) end,
	--- a pattern given as data onto the two slots of a 2-slot inventory (a blank in its first slot, the result in its second);
	--- `entity` (nil: none) gives the network a missing blank is taken from
	encode_def = function(inv, entity, def)
		local net = entity and network(entity) or nil
		return M.encode_def(inv, net, def)
	end,
	clear = function(entity, cursor, back) return M.clear(entity, cursor, back) end,
	--- issue #210: Encode of a wireless terminal (`entity` its access point): the blank from the network, the pattern into `back`
	encode_wireless = function(entity, force, ed, back) return M.encode_wireless(entity, force, ed, back) end,
	load_pattern = function(entity, cursor, ed)
		local ok, where = M.load_pattern(entity, cursor, ed)
		return ok, where, ed
	end,
	click = function(entity, slot, cursor, inventory, shift) return M.click(entity, slot, cursor, inventory, shift) end,
	shift_in = function(entity, stack, inventory) return M.shift_in(entity, stack, inventory) end,
	blanks = function(entity) return M.blanks(entity) end,
	--- the block's two slots as an inventory
	inventory = function(entity) return M.inventory(entity) end,
	--- the pattern in an encoded pattern stack (tags, tooltip data): { kind, recipe, inputs, outputs, valid, id, description }
	pattern_info = function(stack) return P.info(stack) end,
	--- (issue #261 tests) a fluid amount as a pattern keeps it: `up` for an input
	clean_amount = function(n, up) return P.clean_amount(n, up) end,
	problem = function(entity) local _, why = network(entity) return why end,
	--- how many blocks have a record (a mined or destroyed block leaves none)
	record_count = function() local n = 0 for _ in pairs(records()) do n = n + 1 end return n end,
	on_removed = function(entity, buffer) M.on_removed(entity, buffer) end,
	--- open the window for a player (the GUI is built and refreshed: catches errors in the window code)
	open = function(player, entity) open(player, entity) return G.window_of(player) ~= nil end,
	--- the editor of a player's window
	editor_of = function(player) local u = ui_of(player) return u and u.pat or nil end,
})

return M
