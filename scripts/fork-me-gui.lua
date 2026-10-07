--------------------------------------------------------------------------------
--- FORK AE2: SHARED GUI OF THE ME WINDOWS (issue #68, step R3; docs/ME-REWORK.md, "GUIs (R3)")
---   * One window style: a screen frame with a title bar (caption, drag handle, close button) and a light
---     content frame, opened as the player's `opened` GUI (E and Escape close it like any window).
---   * Amounts are formatted with k/M/G everywhere (items and fluids): fmt().
---   * Routing: an element that acts carries the tag `fork_me_act` (an action name) and its data in its tags;
---     the modules register their actions with on(name, fn) at load time, and the terminal module sends every
---     GUI event of the mod to dispatch(). Windows are registered with window(name, def): def.open(player,
---     entity), def.refresh(player, frame) for the bounded refresh of open windows, def.entities (names whose
---     click opens it). open_entity() is called by the open key (simple entities have no vanilla GUI) and by
---     on_gui_opened (lamps, combinators, tanks, containers: the vanilla window is replaced at once).
---   * Issue #28 (docs/ME-REWORK.md "Windows next to the player's inventory"): a window can have the inventory pane:
---     the player's main inventory drawn by the mod on the left of the content (update_pane: only the buttons whose
---     slot changed; on_player_main_inventory_changed and on_player_cursor_stack_changed, nothing per tick). Its
---     clicks (inventory_click) work like the game's: pick up, put down, merge, swap, half a stack, and shift + click
---     sends the stack to the block (the window's `shift`). The block's slots in the content are buttons too
---     (block_click: the window's `click` refuses a wrong item before anything moves).
--- State: what a window shows lives in its elements' tags; the slot signatures of a pane in
--- storage.fork_me_gui_pane[player_index] = { size, sigs }.
--------------------------------------------------------------------------------

local M = {}

local actions = {}          -- action name -> function(event, player, element)
local windows = {}          -- window name -> { refresh, open }
local openers = {}          -- entity name or ME kind (scripts/fork-me-network.lua kind_of) -> function(player, entity)
local REFRESH_MAX = 30      -- open windows refreshed per step (one per player at most: player.opened)

--------------------------------------------------------------------------------
--- entities by unit number
--------------------------------------------------------------------------------

--- The entity of an ME window by its unit number. game.get_entity_by_unit_number returns nil for most entity
--- types (simple entities, lamps, containers, ...: every ME block), so the ME graph's node registry
--- (storage.fork_me_net.nodes) is asked first, then the lookups of the blocks that are no graph nodes (the ME Cell
--- Workbench: entity_lookup). A block with a window that neither finds gets an empty window that the next refresh
--- closes; the runtime test "ME partitions and windows" checks every block of its map.
local lookups = {}          -- function(unit) -> entity or nil

function M.entity_lookup(fn) lookups[#lookups + 1] = fn end

function M.entity_by_unit(unit)
	if not unit then return nil end
	local s = storage.fork_me_net
	local node = s and s.nodes and s.nodes[unit]
	if node and node.entity and node.entity.valid then return node.entity end
	for _, fn in ipairs(lookups) do
		local found = fn(unit)
		if found and found.valid then return found end
	end
	local e = game.get_entity_by_unit_number(unit)
	if e and e.valid then return e end
	return nil
end

--------------------------------------------------------------------------------
--- formatting
--------------------------------------------------------------------------------

--- "999", "12.3", "1.2k", "12k", "123k", "1.2M", ..., "1.2G"
function M.fmt(n)
	n = tonumber(n) or 0
	local neg = n < 0
	if neg then n = -n end
	local out
	if n < 1000 then
		out = n == math.floor(n) and string.format("%d", n) or string.format("%.1f", n)
	else
		local units = { "k", "M", "G", "T" }
		local i = 0
		while n >= 1000 and i < #units do n = n / 1000 i = i + 1 end
		out = (n < 10 and string.format("%.1f", math.floor(n * 10) / 10) or string.format("%d", math.floor(n))) .. units[i]
	end
	return (neg and "-" or "") .. out
end

--------------------------------------------------------------------------------
--- building blocks
--------------------------------------------------------------------------------

--- breadth first search for a named element below `root`
function M.find(root, name)
	local queue, i = { root }, 1
	while queue[i] do
		for _, child in pairs(queue[i].children) do
			if child.name == name then return child end
			queue[#queue + 1] = child
		end
		i = i + 1
	end
end

--- tags for an acting element: { fork_me_act = act, ...data }
function M.act(act, data)
	local t = { fork_me_act = act }
	for k, v in pairs(data or {}) do t[k] = v end
	return t
end

--------------------------------------------------------------------------------
--- windows: one screen frame; issue #28: with the player's inventory drawn by the mod on the left (the pane)
--------------------------------------------------------------------------------

local PANE_COLUMNS = 10
local PANE_HEIGHT = 600
--- LuaItemStacks of the main inventory's slots per player: only a cache for reading (indexing a slot makes a new
--- object each time; the values are always read from the game), so it is no game state and is not saved
local slot_cache = {}

local function pane_state()
	local s = storage.fork_me_gui_pane
	if not s then
		s = {}
		storage.fork_me_gui_pane = s
	end
	return s
end

--- the player's open ME window (or nil), and its name
function M.window_of(player)
	local frame = player.gui.screen.fork_me_window
	if frame and frame.valid then return frame, frame.tags.fork_me_window end
	return nil
end

function M.close_window(player)
	local frame = player.gui.screen.fork_me_window
	if frame and frame.valid then frame.destroy() end
	local picker = player.gui.screen.fork_me_picker       -- the picker (scripts/fork-me-picker.lua) belongs to the window
	if picker and picker.valid then picker.destroy() end
	local s = storage.fork_me_gui_pane
	if s then s[player.index] = nil end
	slot_cache[player.index] = nil
end

--- the table of the pane's slot buttons (named "s<slot>"), or nil
local function pane_table(frame)
	local body = frame and frame.valid and frame.fork_me_body
	local pane = body and body.fork_me_pane
	local scroll = pane and pane.fork_me_inv_scroll
	return scroll and scroll.fork_me_inv
end

--- Issue #75: an item with tags (a storage cell, an encoded pattern) has a description of its own (the stack's
--- `custom_description`) that the game's inventory shows and the item's prototype tooltip (`elem_tooltip`) does not
--- know. Which items can have one is prototype data, so it is looked up once per name (never saved) and the engine is
--- asked about a stack only when its item is one.
local tagged_names = {}

local function is_tagged(name)
	local t = tagged_names[name]
	if t == nil then
		local proto = prototypes.item[name]
		t = proto ~= nil and proto.type == "item-with-tags"
		tagged_names[name] = t
	end
	return t
end

--- What a slot shows of its stack beyond the item's name and count, as a piece of its signature ("" for every item
--- but an item with tags): the stack's item_number. Every write of a cell or pattern (set_stack) gives the stack a
--- new one, so a slot whose description changed is noticed without reading the description.
function M.stack_ident(s)
	if is_tagged(s.name) then return "#" .. tostring(s.item_number) end
	return ""
end

--- The tooltip a slot with the stack `s` has next to the item's own (`elem_tooltip`, which the game shows above it):
--- the stack's description when it has one, then `base` (the slot's own hint, or nil). A stack without a description
--- gets `base` alone, as before.
function M.stack_tooltip(s, base)
	local desc = s and s.valid_for_read and is_tagged(s.name) and s.custom_description or nil
	if desc == nil or desc == "" then return base end
	if base == nil then return desc end
	return { "", desc, "\n", base }
end

--- Show a stack on a slot button: sprite, count, quality, the game's item tooltip and the stack's own description
--- (stack_tooltip); `hand`: the empty slot the cursor's stack came from (the game's hand mark); `base`: the
--- slot's own tooltip. `s` may be nil or empty.
function M.render_slot(btn, s, hand, base)
	if s and s.valid_for_read then
		local name = s.name
		local q = script.feature_flags.quality and s.quality.name or "normal"
		btn.sprite = "item/" .. name
		btn.number = (s.count > 1 or s.prototype.stack_size > 1) and s.count or nil
		btn.quality = q ~= "normal" and q or nil
		btn.elem_tooltip = { type = "item-with-quality", name = name, quality = q }
		btn.tooltip = M.stack_tooltip(s, base)
	else
		btn.sprite = hand and "utility/hand" or ""
		btn.number = nil
		btn.quality = nil
		btn.elem_tooltip = nil
		btn.tooltip = base
	end
end

--- a slot button for the stack `s` (a block's slot), acting with `tags`; `tooltip`: its own hint
function M.stack_button(parent, s, tags, tooltip)
	local btn = parent.add{ type = "sprite-button", style = "slot_button", tags = tags }
	M.render_slot(btn, s, nil, tooltip)
	return btn
end

--- the left pane: "Character" (`hint`: what shift + click does there, as its tooltip and a line below), a scroll pane,
--- a table of 10 columns (filled by update_pane)
local function build_pane(parent, hint)
	local box = parent.add{ type = "frame", name = "fork_me_pane", style = "inside_shallow_frame_with_padding", direction = "vertical" }
	box.add{ type = "label", caption = { "fork-me-gui.character" }, style = "caption_label", tooltip = hint }
	if hint then M.label(box, hint, PANE_COLUMNS * 40) end
	local scroll = box.add{ type = "scroll-pane", name = "fork_me_inv_scroll", horizontal_scroll_policy = "never" }
	scroll.style.maximal_height = PANE_HEIGHT
	scroll.add{ type = "table", name = "fork_me_inv", column_count = PANE_COLUMNS, style = "filter_slot_table" }
end

--- The pane follows the main inventory: every slot's signature (name and count, an item with tags' item_number, or the
--- hand mark) is compared with the one shown, and only the buttons whose signature changed are set again (the quality is read for those only:
--- reading it costs twice as much as name and count, measured). `quality`: the quality of every filled slot is read
--- and compared too (the refresh, with the quality mod: a change of quality alone). A new window or a changed
--- inventory size builds the table and sets every button. Returns the number of buttons set.
function M.update_pane(player, quality)
	local frame = M.window_of(player)
	local t = pane_table(frame)
	local inv = t and player.get_main_inventory()
	if not inv then return 0 end
	local ps = pane_state()
	local st = ps[player.index]
	local n = #inv
	local full = false
	if not st or st.size ~= n then
		st = { size = n, sigs = {}, quals = {} }
		ps[player.index] = st
		t.clear()
		for i = 1, n do t.add{ type = "sprite-button", name = "s" .. i, style = "slot_button", tags = M.act("inv_slot", { slot = i }) } end
		full = true
	end
	quality = quality and script.feature_flags.quality and not full
	local cache = slot_cache[player.index]
	if not (cache and cache.inv == inv and cache.n == n) then
		cache = { inv = inv, n = n }
		for i = 1, n do cache[i] = inv[i] end
		slot_cache[player.index] = cache
	end
	local hand = player.hand_location
	local hand_slot = hand and hand.inventory == inv.index and hand.slot or nil
	local sigs, quals, set = st.sigs, st.quals, 0
	for i = 1, n do
		local s = cache[i]
		local sig, filled
		if s.valid_for_read then
			local name = s.name
			sig = name .. "#" .. s.count
			local tagged = tagged_names[name]               -- (stack_ident, inline: this runs for every slot)
			if tagged == nil then tagged = is_tagged(name) end
			if tagged then sig = sig .. "#" .. tostring(s.item_number) end
			filled = true
		elseif i == hand_slot then sig = "hand"
		else sig = "" end
		local q = quality and filled and s.quality.name or nil
		if full or sig ~= sigs[i] or (q and q ~= quals[i]) then
			sigs[i] = sig
			quals[i] = filled and script.feature_flags.quality and (q or s.quality.name) or nil
			M.render_slot(t["s" .. i], s, i == hand_slot)
			set = set + 1
		end
	end
	return set
end

--- A window: closes the player's ME window, builds frame, title bar and content frame; the frame is the player's
--- opened GUI. Returns the frame and the content flow. `tags` go onto the frame (fork_me_window = name is added).
--- Issue #28: every window has the pane, the player's inventory drawn on the left of the content (`pane` false: none).
function M.open_window(player, name, caption, tags, pane)
	pane = pane ~= false
	M.close_window(player)
	local t = { fork_me_window = name, opened_tick = game.tick }
	for k, v in pairs(tags or {}) do t[k] = v end
	local frame = player.gui.screen.add{ type = "frame", name = "fork_me_window", direction = "vertical", tags = t }
	local bar = frame.add{ type = "flow", direction = "horizontal" }
	bar.drag_target = frame
	bar.style.horizontal_spacing = 8
	bar.add{ type = "label", caption = caption, style = "frame_title", ignored_by_interaction = true }
	local drag = bar.add{ type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true }
	drag.style.horizontally_stretchable = true
	drag.style.height = 24
	drag.style.right_margin = 4
	bar.add{ type = "sprite-button", style = "frame_action_button", sprite = "utility/close",
		tooltip = { "gui.close-instruction" }, tags = M.act("close") }
	local body = frame.add{ type = "flow", name = "fork_me_body", direction = "horizontal" }
	body.style.horizontal_spacing = 12
	if pane then build_pane(body, windows[name] and windows[name].hint) end
	local inner = body.add{ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" }
	inner.style.vertically_stretchable = true
	local content = inner.add{ type = "flow", name = "fork_me_content", direction = "vertical" }
	content.style.vertical_spacing = 6
	frame.auto_center = true
	player.opened = frame
	if pane then M.update_pane(player, true) end
	return frame, content
end

--- the same item and quality? (a stack merges into another only then)
local function same_item(a, b)
	return a.name == b.name and a.quality.name == b.quality.name
end

--- A click on slot `slot` of the inventory pane, for a cursor stack and the main inventory (the window's function and
--- the tests'). `mode`: "left" (pick the stack up; with a stack in the cursor: put it down, merge or swap), "right"
--- (half the stack into the cursor; with a stack in the cursor: put one item down), "shift" (the stack goes to the
--- block: `def.shift(entity, stack, inv)`), "control" (every stack of that item goes to the block: `def.control`, or
--- `def.shift` for this stack when the window has none). Returns the reason a block refused, and "picked" as the
--- second value when the cursor took the whole stack (the caller marks the slot with the hand).
function M.inventory_click(cursor, inv, slot, mode, def, entity)
	local stack = inv and slot >= 1 and slot <= #inv and inv[slot]
	if not stack then return nil end
	if mode == "shift" or mode == "control" then
		if not stack.valid_for_read then return nil end
		if not (def and def.shift and entity and entity.valid) then return "no-target" end
		if mode == "control" and def.control then return def.control(entity, stack, inv) end
		return def.shift(entity, stack, inv)
	end
	if not cursor then return nil end
	if mode == "right" then
		if cursor.valid_for_read then
			if not stack.valid_for_read or same_item(stack, cursor) then stack.transfer_stack(cursor, 1) end
		elseif stack.valid_for_read then
			cursor.transfer_stack(stack, math.ceil(stack.count / 2))
		end
		return nil
	end
	if cursor.valid_for_read then
		if not stack.valid_for_read or same_item(stack, cursor) then stack.transfer_stack(cursor)
		else stack.swap_stack(cursor) end
		return nil
	end
	if not stack.valid_for_read then return nil end
	cursor.transfer_stack(stack)
	return nil, "picked"
end

--- A click on slot `slot` of the block in the window (its cards, its cell): `def.click(entity, slot, cursor, inv,
--- shift)` puts the cursor's item in (refused before anything moves when it does not belong there), takes the item into
--- the cursor or (shift) into the inventory. Returns the reason of a refusal.
function M.block_click(def, entity, slot, cursor, inv, shift)
	if not (def and def.click and entity and entity.valid) then return "no-target" end
	return def.click(entity, slot, cursor, inv, shift)
end

--- the short message of a refusal: the window's own text for its reasons (def.message), else fork-me-gui.refused-*
local function refused(player, why, def)
	if not why then return end
	local text = def and def.message and def.message(why) or { "fork-me-gui.refused-" .. why }
	player.create_local_flying_text{ text = text, create_at_cursor = true }
end

--- Where an item that may not be in a slot goes, never deleted: `to` a LuaPlayer (main inventory, else the ground at
--- the player), a LuaInventory (else the ground at `entity`) or nil (the ground at `entity`). `count`: only that many
--- of the stack (default all). The stack is empty or `count` smaller afterwards.
function M.give_back(to, stack, entity, count)
	if not (stack and stack.valid_for_read) then return end
	count = math.min(count or stack.count, stack.count)
	if count <= 0 then return end
	if count < stack.count then                        -- a part: through a stack of its own
		local tmp = game.create_inventory(1)
		tmp[1].transfer_stack(stack, count)
		M.give_back(to, tmp[1], entity)
		tmp.destroy()
		return
	end
	local surface, position
	if to and to.valid and to.object_name == "LuaPlayer" then
		local inv = to.get_main_inventory()
		if inv then
			local n = inv.insert(stack)
			if n >= stack.count then stack.clear() return end
			if n > 0 then stack.count = stack.count - n end
		end
		local c = to.character
		if c and c.valid then surface, position = c.surface, c.position else surface, position = to.surface, to.position end
	elseif to and to.valid and to.object_name == "LuaInventory" then
		local n = to.insert(stack)
		if n >= stack.count then stack.clear() return end
		if n > 0 then stack.count = stack.count - n end
	end
	if not surface and entity and entity.valid then surface, position = entity.surface, entity.position end
	if surface then
		surface.spill_item_stack{ position = position, stack = stack, allow_belts = false }
		stack.clear()
	end
end

--- a label that wraps at `width` pixels
function M.label(parent, caption, width, style, name)
	local l = parent.add{ type = "label", name = name, caption = caption, style = style }
	if width then
		l.style.single_line = false
		l.style.maximal_width = width
	end
	return l
end

--- a heading line
function M.heading(parent, caption)
	return parent.add{ type = "label", caption = caption, style = "caption_label" }
end

--- a horizontal flow with centered children
function M.row(parent, name)
	local r = parent.add{ type = "flow", name = name, direction = "horizontal" }
	r.style.vertical_align = "center"
	r.style.horizontal_spacing = 6
	return r
end

--- Issue #79: the key of an item with tags (a storage cell, an encoded pattern) kept in the network is
--- "name@quality#<json>", the json being { tags, description } as `N.storable` made it from the stack. The description is
--- therefore a function of the key (a stack written anew is another key), and the grid's buttons, which are made again
--- when their key changes, never show an old one. Read from the json once per key, cached for this load only (never
--- saved; emptied when it grows large). Returns the description (a localised string) or nil.
local description_cache, description_count = {}, 0

function M.key_description(key)
	local at = key:find("#", 1, true)
	if not at then return nil end
	local d = description_cache[key]
	if d == nil then
		local data = helpers.json_to_table(key:sub(at + 1))
		d = type(data) == "table" and data.description or false
		if d == "" or (type(d) ~= "table" and type(d) ~= "string") then d = false end
		if description_count >= 2000 then description_cache, description_count = {}, 0 end
		description_cache[key] = d
		description_count = description_count + 1
	end
	return d or nil
end

--- Issue #159: the fluid name and the degrees (nil: none) of a fluid key ("fluid/<name>", "fluid/<name>@<degrees>"),
--- and its name as a LocalisedString ("Steam (250 °C)"). (This module is a leaf: the network's own parser is not used.)
local function fluid_parts(key)
	local body = key:sub(7)
	local name, deg = body:match("^(.+)@(%-?%d+)$")
	if name and prototypes.fluid[name] then return name, tonumber(deg) end
	return body, nil
end
function M.fluid_label(key)
	local name, deg = fluid_parts(key)
	local proto = prototypes.fluid[name]
	local ln = proto and proto.localised_name or name
	if deg then return { "fork-me-gui.fluid-at-temperature", ln, tostring(deg) }, name, deg end
	return ln, name, nil
end

--- A slot button for an item or fluid (`key`: item name, "name@quality" or "fluid/<name>"; for an item with tags
--- the key's description is the first lines of the tooltip, below the item's own), with the amount formatted in the
--- tooltip and the button's number. `style` defaults to slot_button. `index`: the place among the parent's children
--- (default: last).
function M.slot(parent, key, amount, tags, style, extra_tooltip, index)
	local def = { type = "sprite-button", style = style or "slot_button", tags = tags, index = index }
	if key then
		if key:sub(1, 6) == "fluid/" then
			local label, name = M.fluid_label(key)
			if prototypes.fluid[name] then def.sprite = "fluid/" .. name end
			def.tooltip = { "", label, amount and (": " .. M.fmt(amount)) or "", extra_tooltip or "" }
		else
			local name, q = key:match("^([^@#]+)@?([^#]*)")
			q = (q and q ~= "") and q or "normal"
			if prototypes.item[name] and prototypes.quality[q] then
				def.sprite = "item/" .. name
				def.elem_tooltip = { type = "item-with-quality", name = name, quality = q }
				local desc = M.key_description(key)
				if desc and extra_tooltip then def.tooltip = { "", desc, "\n", extra_tooltip }
				else def.tooltip = desc or extra_tooltip end
			else
				def.tooltip = key                     -- the prototype is gone (a mod was removed)
			end
		end
	end
	if amount then def.number = math.floor(amount) end
	return parent.add(def)
end

--- Issue #70: a slot button for a key that a window sets (an interface row, a filter, the maintainer's target, a
--- partition slot), or an empty one (`key` nil), acting with `tags`: the item with its quality badge, the game's tooltip
--- and `tooltip` (the hint) below it; a fluid's name and the hint. Clicking it opens the picker (scripts/fork-me-picker.lua),
--- right click empties it: the windows' handlers do that.
function M.key_button(parent, key, tags, tooltip)
	local b = M.slot(parent, key, nil, tags)
	if key and key:sub(1, 6) ~= "fluid/" then
		local name, q = key:match("^([^@#]+)@?([^#]*)")
		if q and q ~= "" and q ~= "normal" and prototypes.quality[q] and script.feature_flags.quality then b.quality = q end
		if prototypes.item[name] then b.tooltip = tooltip else b.tooltip = { "", key, "\n", tooltip or "" } end
	elseif key then
		local label, _, deg = M.fluid_label(key)
		b.tooltip = { "", label, "\n", tooltip or "" }
		if deg then b.number = deg end                 -- issue #159: a filter of one temperature shows it
	else
		b.tooltip = tooltip
	end
	return b
end

--- Issue #50, lever 8: a new amount on a button M.slot made for the same key (the number, and a fluid's tooltip, which
--- holds the amount): the button is then what M.slot would make for the new amount.
function M.slot_amount(button, key, amount, extra_tooltip)
	button.number = amount and math.floor(amount) or nil
	if key and key:sub(1, 6) == "fluid/" then
		button.tooltip = { "", (M.fluid_label(key)), amount and (": " .. M.fmt(amount)) or "", extra_tooltip or "" }
	end
end

--- a numeric text field (integers, optionally negative) that acts on change and on confirm
function M.number_field(parent, value, tags, width, negative, name)
	local f = parent.add{ type = "textfield", name = name, text = tostring(value or 0), numeric = true, allow_decimal = false,
		allow_negative = negative or false, lose_focus_on_confirm = true, tags = tags }
	f.style.width = width or 80
	return f
end

--- a slot table with `columns` columns
function M.grid(parent, columns, name)
	local scroll = parent.add{ type = "scroll-pane", horizontal_scroll_policy = "never" }
	scroll.style.maximal_height = 6 * 40 + 8
	local t = scroll.add{ type = "table", name = name, column_count = columns, style = "filter_slot_table" }
	return t, scroll
end

--------------------------------------------------------------------------------
--- registry and routing
--------------------------------------------------------------------------------

function M.on(act, fn) actions[act] = fn end

--- a window: { open = function(player, entity, opts), refresh = function(player, frame), entities = { entity names
--- or ME kinds } }; refresh returns false to close the window. Issue #28, a window with the inventory pane and slots of
--- its block: shift = function(entity, stack, inventory) (where a shift-clicked stack of the player's inventory goes;
--- returns the reason when the block takes none of it) and click = function(entity, slot, cursor, inventory, shift)
--- (a click on the block's slot; returns the reason of a refusal, nothing moves then); optional hint (a line under
--- the pane's caption), control = function(entity,
--- stack, inventory) (control + click: every stack of that item) and message = function(reason) (the refusal's text)
function M.window(name, def)
	windows[name] = def
	for _, entity_name in pairs(def.entities or {}) do openers[entity_name] = def.open end
end

--- true when the entity opens an ME window (click or open key)
function M.has_window(entity)
	if not (entity and entity.valid) then return false end
	return (openers[entity.name] or (M.kind_of and openers[M.kind_of(entity.name) or ""])) ~= nil
end

--- open a registered window by name: def.open(player, entity, opts)
function M.open(name, player, entity, opts)
	local def = windows[name]
	if def then def.open(player, entity, opts) end
end

--- Show the vanilla window of an entity once (the ME Interface's "Open inventory"): the next on_gui_opened of
--- this player for it is let through. Kept in storage (multiplayer safe), cleared by the open key.
function M.open_vanilla(player, entity)
	storage.fork_me_gui_bypass = storage.fork_me_gui_bypass or {}
	storage.fork_me_gui_bypass[player.index] = entity.unit_number
	player.opened = entity
end

function M.clear_bypass(player)
	local b = storage.fork_me_gui_bypass
	if b then b[player.index] = nil end
end

--------------------------------------------------------------------------------
--- the open key and the cursor
--------------------------------------------------------------------------------

--- item types whose click acts on the world (build, select, throw, command a spidertron); the game opens no entity
--- window then
local TOOL_TYPES = {
	["blueprint"] = true, ["blueprint-book"] = true, ["deconstruction-item"] = true, ["upgrade-item"] = true,
	["copy-paste-tool"] = true, ["selection-tool"] = true, ["spidertron-remote"] = true, ["rail-planner"] = true,
	["capsule"] = true,
}
--- the wires of the shortcut bar are plain items (only in the cursor); a click with one connects a wire
local WIRES = { ["red-wire"] = true, ["green-wire"] = true, ["copper-wire"] = true }

--- What click_opens() needs to know about a player's cursor besides its stack: a blueprint (also one from the
--- blueprint library, whose cursor stack is not valid for reading), a library record, a ghost, a wire being dragged.
--- `entity`: the clicked block (a repair pack repairs a damaged one).
function M.cursor_flags(player, entity)
	local ratio = entity and entity.valid and entity.get_health_ratio()
	return {
		blueprint = player.is_cursor_blueprint(),
		record = player.cursor_record ~= nil,
		ghost = player.cursor_ghost ~= nil,
		wire = player.drag_target ~= nil,
		damaged = ratio ~= nil and ratio < 1,
	}
end

--- Whether a click on an ME block opens its window: exactly when the game opens the window of an entity with one
--- (a chest) for the same cursor. The click is the game's "open GUI" control, which is also the build and use
--- click: with a tool in the cursor the game uses the tool and opens nothing, so the ME window must not open either
--- (opening it would end the tool's action). `stack`: the cursor stack (or any item stack, nil for none); `flags`:
--- cursor_flags(). Returns the answer and a short reason.
function M.click_opens(stack, flags)
	flags = flags or {}
	if flags.blueprint or flags.record then return false, "blueprint" end
	if flags.ghost then return false, "ghost" end
	if flags.wire then return false, "wire" end
	if not (stack and stack.valid_for_read) then return true, "empty" end
	local proto = stack.prototype
	if TOOL_TYPES[proto.type] or stack.is_selection_tool then return false, proto.type end
	if WIRES[stack.name] then return false, "wire" end
	if proto.flags and proto.flags["only-in-cursor"] then return false, "cursor-tool" end
	if proto.place_result or proto.place_as_tile_result then return false, "build" end
	if proto.type == "repair-tool" and flags.damaged then return false, "repair" end
	return true, "item"
end

--- The open key on an entity, or the vanilla window of an entity that has one: open the ME window instead.
--- Returns true when the entity has an ME window.
function M.open_entity(player, entity)
	if not (entity and entity.valid) then return false end
	local open = openers[entity.name] or (M.kind_of and openers[M.kind_of(entity.name) or ""])
	if not open then return false end
	local b = storage.fork_me_gui_bypass
	if b and b[player.index] == entity.unit_number then
		b[player.index] = nil
		return true                                   -- the vanilla window, asked for by the ME window
	end
	if not player.can_reach_entity(entity) then return true end
	local frame, name = M.window_of(player)
	if frame and frame.tags.unit == entity.unit_number and not frame.tags.via and windows[name] and open == windows[name].open then
		player.opened = frame                         -- already open (the open key and on_gui_opened both fire)
		return true
	end
	open(player, entity)
	return true
end

--- every GUI event of the mod (click, text, elem, checked, switch, selection, confirmed)
function M.dispatch(event)
	local el = event.element
	if not (el and el.valid) then return false end
	local act = el.tags and el.tags.fork_me_act
	if not act then return false end
	local player = game.get_player(event.player_index)
	if act == "close" then
		M.close_window(player)
		return true
	elseif act == "back" then                       -- back to the terminal a drive or cell window came from
		local via = M.entity_by_unit(el.tags.via)
		if via and via.valid then M.open_entity(player, via) else M.close_window(player) end
		return true
	elseif act == "inv_slot" or act == "block_slot" then   -- issue #28: the inventory pane and the block's slots
		if event.name ~= defines.events.on_gui_click then return true end
		local frame, name = M.window_of(player)
		local def = name and windows[name]
		local entity = frame and M.entity_of(player, frame)
		local inv = player.get_main_inventory()
		if not (entity and inv) then return true end
		local why, picked
		if act == "inv_slot" then
			local mode = event.control and "control" or event.shift and "shift"
				or event.button == defines.mouse_button_type.right and "right" or "left"
			why, picked = M.inventory_click(player.cursor_stack, inv, el.tags.slot, mode, def, entity)
			if picked then
				local slot = el.tags.slot
				pcall(function() player.hand_location = { inventory = inv.index, slot = slot } end)
			end
		else
			why = M.block_click(def, entity, el.tags.slot, player.cursor_stack, inv, event.shift)
		end
		refused(player, why, def)
		M.update_pane(player)
		M.refresh_one(player)
		return true
	end
	local fn = actions[act]
	if not fn then return false end
	fn(event, player, el)
	return true
end

--- Hooks that see an ME window being closed before it is treated as closed: fn(player, window) returns true when the
--- window is to stay (the picker of issue #94 takes the close keys of the popup above it)
local closed_hooks = {}
function M.on_window_closed(fn) closed_hooks[#closed_hooks + 1] = fn end

--- on_gui_closed: our window was closed (E, Escape, another GUI opened)
function M.on_closed(event)
	if event.gui_type == defines.gui_type.script_inventory then
		--- a save made with #30 (same version number, no close_all): its frame anchored to a script inventory goes
		local player = game.get_player(event.player_index)
		local old = player and player.gui.relative.fork_me_window
		if old and old.valid then old.destroy() end
		return false
	end
	local el = event.element
	if el and el.valid and el.name == "fork_me_window" then
		--- the open key's own game action can close the window in the tick it was opened (an entity without a
		--- vanilla window): keep it open then
		local player = game.get_player(event.player_index)
		if el.tags.opened_tick == game.tick and player then
			player.opened = el
			return true
		end
		if player then
			for _, hook in ipairs(closed_hooks) do
				if hook(player, el) then return true end
			end
		end
		if player then M.close_window(player) else el.destroy() end
		return true
	end
	return false
end

--- every 60 ticks (terminal module): refresh the open windows (one per player), close those whose entity is
--- gone or out of reach; a window with the inventory pane sets every slot once (a change of quality alone)
function M.refresh_all()
	local n = 0
	for _, player in pairs(game.connected_players) do
		local picker = player.gui.screen.fork_me_picker      -- one that an Escape hid (scripts/fork-me-picker.lua)
		if picker and picker.valid and not picker.visible and picker.tags.cancel_tick ~= game.tick then picker.destroy() end
		local frame, name = M.window_of(player)
		if frame and n < REFRESH_MAX then
			n = n + 1
			local def = windows[name]
			if not def then
				M.close_window(player)
			elseif player.opened ~= frame then
				M.close_window(player)                     -- dying or another GUI closed it without an event
			else
				local ok = def.refresh and def.refresh(player, frame)
				if ok == false then
					M.close_window(player)
				elseif storage.fork_me_gui_pane and storage.fork_me_gui_pane[player.index] then
					M.update_pane(player, true)
				end
			end
		end
	end
end

--- refresh the player's window now (after a button changed something)
function M.refresh_one(player)
	local frame, name = M.window_of(player)
	local def = frame and windows[name]
	if def and def.refresh and def.refresh(player, frame) == false and frame.valid then M.close_window(player) end
end

--- on_player_main_inventory_changed, on_player_cursor_stack_changed (issue #28): the inventory pane of the player's
--- window follows the real inventory and the hand. A player without a pane costs one lookup.
function M.on_inventory_changed(event)
	local s = storage.fork_me_gui_pane
	if not (s and s[event.player_index]) then return end
	local player = game.get_player(event.player_index)
	if player then M.update_pane(player) end
end

--- a player left the game: the window closes
function M.on_left(player)
	if player and player.valid then M.close_window(player) end
end

--- The window's entity (by the unit number in its tags), nil when gone or out of reach. A window opened from a
--- terminal (tag `via`: the terminal's unit number) needs the terminal in reach, not the entity.
function M.entity_of(player, frame)
	local e = M.entity_by_unit(frame.tags.unit)
	if not (e and e.valid) then return nil end
	local via = M.entity_by_unit(frame.tags.via)
	if not player.can_reach_entity((via and via.valid) and via or e) then return nil end
	return e
end

--- a "Back" button to the terminal for a window opened from one
function M.back_button(parent, via)
	if not via then return nil end
	return parent.add{ type = "button", caption = { "fork-me-gui.back" }, tags = M.act("back", { via = via }) }
end

--- after a mod update every open ME window is closed (a window built by an older version may lack elements; the
--- frames anchored beside a script inventory of #30 too)
function M.close_all()
	for _, player in pairs(game.players) do
		M.close_window(player)
		local old = player.gui.relative.fork_me_window
		if old and old.valid then old.destroy() end
	end
	storage.fork_me_gui_open = nil
	storage.fork_me_gui_pane = nil
end

--- the text of a reason of the network module ([fork-me-net]: the network's state is a status-*, the rest error-*)
local NET_STATUS = { ["no-network"] = true, ["no-controller"] = true, ["conflict"] = true, ["no-power"] = true }
function M.net_message(why) return { "fork-me-net." .. (NET_STATUS[why] and "status-" or "error-") .. why } end

--- the definition of the window `name` (the tests' clicks in a window that no entity opens, the cell window)
function M.def_named(name) return windows[name] end

--- every registered window and what its pane does (the test that no window stays without one)
function M.window_list()
	local out = {}
	for name, def in pairs(windows) do
		out[name] = { pane = true, shift = def.shift ~= nil, control = def.control ~= nil, message = def.message ~= nil }
	end
	return out
end

--- the window definition of an entity's window (the tests' clicks)
function M.def_of(entity)
	if not (entity and entity.valid) then return nil end
	local open = openers[entity.name] or (M.kind_of and openers[M.kind_of(entity.name) or ""])
	for _, def in pairs(windows) do if def.open == open then return def end end
	return nil
end

return M
