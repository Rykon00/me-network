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
---   * Issue #28, since issue #542 with Factorio 2.1's GUI element `inventory` (docs/ME-REWORK.md "Windows with the
---     player's inventory"): every window is one frame with the player's real inventory on the left (the pane: an
---     `inventory` element bound to it, drawn and clicked by the game: pick up, put down, swap, half a stack, the tooltips)
---     and the ME content on the right. The game raises on_gui_inventory_action for what it cannot do itself: shift +
---     click sends the stack to the block (the window's `shift`), control + click every stack of the item
---     (inventory_action). The block's slots in the content are buttons (block_click: the window's `click` refuses a
---     wrong item before anything moves).
--- State: what a window shows lives in its elements' tags; nothing of the pane is kept.
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

--- a power in W as the game writes it: "950 W", "124 kW", "1.9 MW" (issue #149)
function M.fmt_power(w)
	w = tonumber(w) or 0
	local units = { "W", "kW", "MW", "GW", "TW" }
	local i = 1
	while w >= 1000 and i < #units do w = w / 1000 i = i + 1 end
	local text = w == math.floor(w) and string.format("%d", w) or string.format("%.1f", w)
	return text .. " " .. units[i]
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
--- windows: one screen frame; issue #28: with the player's inventory on the left (the pane; issue #542: the game's
--- own `inventory` element)
--------------------------------------------------------------------------------

local PANE_COLUMNS = 10
local PANE_HEIGHT = 600

--- Issue #469: the height in GUI pixels that a part of a window may take on the player's screen: the screen's height at its
--- UI scale (display_resolution over display_scale) less `reserve` for the rest of the window, at most `max` (nil: no limit)
--- and at least `min`
function M.fit_height(player, reserve, max, min)
	local ok, h = pcall(function() return player.display_resolution.height / player.display_scale end)
	h = (ok and type(h) == "number") and math.floor(h - reserve) or max or min
	if max and h > max then h = max end
	if h < min then h = min end
	return h
end

--------------------------------------------------------------------------------
--- Issues #176 and #177: in remote view (a space platform: defines.controllers.remote) the hand holds nothing and
--- player.get_main_inventory() is nil. The pane then shows the character's inventory (player_inventory) with the game's
--- cursor handling off: every click on a stack sends it to the block as if shift were held (inventory_action), and what
--- is taken out of a block goes into that inventory with a flying text (hand hands the windows their cursor, inventory
--- and "remote"). Without an inventory nothing moves and the window says why. give_back never spills from remote view:
--- what has no place is parked (storage.fork_me_gui_parked[player_index]) and returned by return_parked.
--------------------------------------------------------------------------------

local PARK_SLOTS = 20

--- the player's open ME window (or nil), and its name
function M.window_of(player)
	local frame = player.gui.screen.fork_me_window
	if frame and frame.valid then return frame, frame.tags.fork_me_window end
	return nil
end

--- make the player's ME window the opened GUI again (the picker keeps a window open on the close keys)
function M.focus(player, frame)
	if player.opened ~= frame then player.opened = frame end
end

--- Issue #177: what could not go to a player in remote view waits here, never spilled and never lost (give_back);
--- return_parked() hands it over as soon as the player has an inventory in reach. Script inventories are saved.
local function parked_of(player, create)
	local s = storage.fork_me_gui_parked
	if not s then
		if not create then return nil end
		s = {}
		storage.fork_me_gui_parked = s
	end
	local p = s[player.index]
	if p and not (p.inv and p.inv.valid) then
		s[player.index] = nil
		p = nil
	end
	if not p and create then
		p = { inv = game.create_inventory(PARK_SLOTS), told = -1 }
		s[player.index] = p
	end
	return p
end

--- `stack` into the player's parked items (all of it, the stack is empty afterwards); says so once per tick to a
--- connected player
local function park(player, stack)
	local p = parked_of(player, true)
	if not p.inv.can_insert(stack) then p.inv.resize(#p.inv + PARK_SLOTS) end
	p.inv.insert(stack)
	stack.clear()
	if p.told ~= game.tick and player.connected ~= false then
		p.told = game.tick
		player.create_local_flying_text{ text = { M.player_inventory(player) and "fork-me-gui.parked-full" or "fork-me-gui.parked" },
			create_at_cursor = true }
	end
end

--- the number of items parked for the player
function M.parked_count(player)
	local p = parked_of(player, false)
	local n = 0
	for i = 1, p and #p.inv or 0 do
		if p.inv[i].valid_for_read then n = n + p.inv[i].count end
	end
	return n
end

--- Hand the player what was parked into their inventory (what does not fit stays parked). Returns the number of
--- stacks still parked. Called when a window opens or closes and at the refresh, outside remote view (or with an inventory).
function M.return_parked(player)
	local p = parked_of(player, false)
	if not p then return 0 end
	local inv = M.player_inventory(player)
	if inv then
		for i = 1, #p.inv do
			local st = p.inv[i]
			if st.valid_for_read then
				local n = inv.insert(st)
				if n >= st.count then st.clear() elseif n > 0 then st.count = st.count - n end
			end
		end
	end
	if p.inv.is_empty() then
		p.inv.destroy()
		storage.fork_me_gui_parked[player.index] = nil
		return 0
	end
	local n = 0
	for i = 1, #p.inv do if p.inv[i].valid_for_read then n = n + 1 end end
	return n
end

--- Issue #542: the hand-over buffer of issues #150 and #168 is gone (the inventory element replaced it). A save of 0.5.10 may
--- hold one per player, storage.fork_me_gui_buffer[player_index] = { inv, ... } (a script inventory that was the player's
--- opened GUI), and the ME frame anchored beside it in player.gui.relative. Its stacks go back to the player, never onto the
--- ground: into their inventory, what does not fit is parked (return_parked hands it over later). The frame goes. Called by
--- close_window (the old buffer's own close, on_closed) and through it by close_all (a mod update). Returns the number of
--- stacks handed back.
function M.drop_buffer(player)
	local s = storage.fork_me_gui_buffer
	local b = s and s[player.index]
	local n = 0
	if b then
		s[player.index] = nil
		if next(s) == nil then storage.fork_me_gui_buffer = nil end
		local inv = b.inv
		if inv and inv.valid then
			local to = M.player_inventory(player)
			for i = 1, #inv do
				local st = inv[i]
				if st.valid_for_read then
					n = n + 1
					local put = to and to.insert(st) or 0
					if put >= st.count then st.clear()
					else
						if put > 0 then st.count = st.count - put end
						park(player, st)
					end
				end
			end
			inv.destroy()
		end
	end
	local gui = player.gui
	local rel = gui and gui.relative and gui.relative.fork_me_window
	if rel and rel.valid then rel.destroy() end
	return n
end

function M.close_window(player)
	local frame = player.gui.screen.fork_me_window
	if frame and frame.valid then frame.destroy() end
	M.drop_buffer(player)                                 -- (issue #542: a buffer of a 0.5.10 save)
	local picker = player.gui.screen.fork_me_picker       -- the picker (scripts/fork-me-picker.lua) belongs to the window
	if picker and picker.valid then picker.destroy() end
	M.return_parked(player)
end

--- the pane's inventory element (named "fork_me_inv"), or nil
local function pane_element(frame)
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

--- Issue #542: the handling flags of the pane's inventory element. Outside remote view the game moves stacks between the
--- slots and the hand itself (left and right click, drag), opens an item (a blueprint book, an armor's grid) and trashes
--- a stack; shift + click and control + click it cannot do (it does not know where they go): they raise
--- on_gui_inventory_action for the mod. In remote view (issues #176, #177) the hand holds nothing, so the cursor moves are
--- the mod's too: a click sends the stack to the block.
function M.pane_flags(remote)
	return { handle_cursor_transfer = not remote, handle_cursor_split = not remote, handle_open_item = true,
		handle_open_mod_item = true, handle_send_stack_to_trash = true, handle_send_stacks_to_trash = true }
end

--- the left pane: "Character" (`hint`: what shift + click does there, as its tooltip and a line below), a scroll pane,
--- the inventory element bound to the player's inventory (issue #542: the game draws and updates its slots)
local function build_pane(parent, hint, player)
	local box = parent.add{ type = "frame", name = "fork_me_pane", style = "inside_shallow_frame_with_padding", direction = "vertical" }
	box.add{ type = "label", caption = { "fork-me-gui.character" }, style = "caption_label", tooltip = hint }
	if hint then M.label(box, hint, PANE_COLUMNS * 40) end
	local remote = M.in_remote_view(player)
	local inv = M.player_inventory(player)
	if remote then                                     -- issues #176, #177: what remote view does
		M.label(box, { inv and "fork-me-gui.remote-help" or "fork-me-gui.remote-no-inventory" }, PANE_COLUMNS * 40, nil, "fork_me_remote_help")
	end
	if not inv then return end                         -- (no element: there is nothing to show)
	local scroll = box.add{ type = "scroll-pane", name = "fork_me_inv_scroll", horizontal_scroll_policy = "never" }
	--- (issue #469: at most what the screen leaves below the title bar, the caption and the hint: a 1080p screen at 150 % UI
	--- scale has 720 GUI pixels)
	scroll.style.maximal_height = M.fit_height(player, 220, PANE_HEIGHT, 200)
	local def = { type = "inventory", name = "fork_me_inv", slots_per_row = PANE_COLUMNS, tags = M.act("inventory") }
	for k, v in pairs(M.pane_flags(remote)) do def[k] = v end
	local el = scroll.add(def)
	el.inventory = inv
end

--- Issue #542: the pane follows the player at the refresh (once a second): another inventory (the character died, remote
--- view was entered or left) is bound and the handling flags are set for it. Nothing to do per slot: the game draws them.
local function follow_inventory(player, frame)
	local el = pane_element(frame)
	if not el then return end
	local inv = M.player_inventory(player)
	if inv and el.inventory ~= inv then el.inventory = inv end
	local remote = M.in_remote_view(player)
	if el.handle_cursor_transfer == remote then
		el.handle_cursor_transfer = not remote
		el.handle_cursor_split = not remote
	end
end

--- A window: closes the player's ME window, builds frame, title bar and content frame; the frame is the player's
--- opened GUI. Returns the frame and the content flow. `tags` go onto the frame (fork_me_window = name is added).
--- Issue #28: every window has the pane, the player's inventory on the left of the content (`pane` false: none; issue
--- #542: the game's inventory element).
function M.open_window(player, name, caption, tags, pane)
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
	if pane ~= false then build_pane(body, windows[name] and windows[name].hint, player) end
	local inner = body.add{ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" }
	inner.style.vertically_stretchable = true
	local content = inner.add{ type = "flow", name = "fork_me_content", direction = "vertical" }
	content.style.vertical_spacing = 6
	frame.auto_center = true
	player.opened = frame
	return frame, content
end

--- `count` items of `stack` to the block through `def.shift` (a part goes through a stack of its own; what the block does not
--- take comes back into `stack`). Returns the reason of a refusal.
local function shift_part(def, entity, stack, inv, count)
	if count >= stack.count then return def.shift(entity, stack, inv) end
	local tmp = game.create_inventory(1)
	tmp[1].transfer_stack(stack, count)
	local why = def.shift(entity, tmp[1], inv)
	if tmp[1].valid_for_read then stack.transfer_stack(tmp[1]) end
	if tmp[1].valid_for_read then M.give_back(inv, tmp[1]) end   -- (never: the stack had room for it)
	tmp.destroy()
	return why
end

--- every stack of `inv` with the item and quality of `stack` to the block, each whole or (`half`) half of it; the reason
--- of a refusal when nothing went
local function shift_every(def, entity, stack, inv, half)
	local name, q = stack.name, stack.quality.name
	local filter = { name = name, quality = q }
	local before, why = inv.get_item_count(filter), nil
	for i = 1, #inv do
		local s = inv[i]
		if s.valid_for_read and s.name == name and s.quality.name == q then
			why = shift_part(def, entity, s, inv, half and math.ceil(s.count / 2) or s.count) or why
		end
	end
	if inv.get_item_count(filter) < before then return nil end
	return why
end

--- What an action of on_gui_inventory_action on slot `slot` of the pane does (the event handler's work and the tests'):
--- `action` is a defines.inventory_actions value. stack_transfer (shift + click) sends the stack to the block
--- (`def.shift(entity, stack, inv)`), stack_split (shift + right click) half of it, inventory_transfer (control + click) every
--- stack of the item (`def.control`, else `def.shift` per stack), inventory_split (control + right click) half of each.
--- `remote` (remote view, issue #177): a click (cursor_transfer, cursor_split; the game raises them only with its handling
--- off) sends the stack as shift + click does. Every other action is the game's. Returns the reason the block refused.
function M.inventory_action(inv, slot, action, def, entity, remote)
	local A = defines.inventory_actions
	if remote and (action == A.cursor_transfer or action == A.cursor_split) then action = A.stack_transfer end
	if not (action == A.stack_transfer or action == A.stack_split or action == A.inventory_transfer or action == A.inventory_split) then
		return nil
	end
	local stack = inv and inv.valid and slot and slot >= 1 and slot <= #inv and inv[slot]
	if not (stack and stack.valid_for_read) then return nil end
	if not (def and def.shift and entity and entity.valid) then return "no-target" end
	if action == A.stack_transfer then return def.shift(entity, stack, inv) end
	if action == A.stack_split then return shift_part(def, entity, stack, inv, math.ceil(stack.count / 2)) end
	if action == A.inventory_transfer and def.control then return def.control(entity, stack, inv) end
	return shift_every(def, entity, stack, inv, action == A.inventory_split)
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

--- Where an item that may not be in a slot goes, never deleted: `to` a LuaPlayer (their inventory, else the ground at
--- the player; in remote view never the ground: what the inventory does not take is parked, issue #177), a LuaInventory
--- (else the ground at `entity`) or nil (the ground at `entity`). `count`: only that many of the stack (default all).
--- The stack is empty or `count` smaller afterwards.
function M.give_back(to, stack, entity, count)
	if not (stack and stack.valid_for_read) then return end
	count = math.min(count or stack.count, stack.count)
	if count <= 0 then return end
	if count < stack.count then                        -- a part: through a stack of its own
		local tmp = game.create_inventory(1)
		tmp[1].transfer_stack(stack, count)
		M.give_back(to, tmp[1], entity)
		if tmp[1].valid_for_read then stack.transfer_stack(tmp[1]) end   -- (nothing is lost if it did not go)
		tmp.destroy()
		return
	end
	local surface, position
	if to and to.valid and to.object_name == "LuaPlayer" then
		local inv = M.player_inventory(to)
		if inv then
			local n = inv.insert(stack)
			if n >= stack.count then stack.clear() return end
			if n > 0 then stack.count = stack.count - n end
		end
		if M.in_remote_view(to) then                   -- (the character can be on another planet than the one in view)
			park(to, stack)
			return
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
--- "name@quality#<json>", the json being { tags, description } as `N.storable` made it from the stack (a damaged item's
--- has its health too, issues #102 and #481; a labelled item's its label, issue #485). The description is
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
		--- issue #481: a damaged item with tags keeps its own description in the key; the damage text below it is made from its
		--- health (a damaged item without tags has the damage text as its description, issue #102)
		local h = type(data) == "table" and data.health
		if type(h) == "number" and not (type(d) == "table" and d[1] == "fork-me-net.damaged-item") then
			local damage = { "fork-me-net.damaged-item", math.floor(h * 100 + 0.5) }
			d = d and { "", d, "\n", damage } or damage
		end
		--- issue #485: a label (Quality Turrets Reworked's "<name> (N Kills)") is the first line, so that stacks of one item that
		--- differ in their label can be told apart
		local label = type(data) == "table" and data.label
		if type(label) == "string" and label ~= "" then
			local line = { "fork-me-net.item-label", label }
			d = d and { "", line, "\n", d } or line
		end
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
				if q ~= "normal" then def.quality = q end    -- (issue #352: the quality's badge)
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
--- Is the player in remote view (the remote controller: a space platform, the map)? There the hand holds nothing and
--- player.get_main_inventory() is nil (issues #176, #177).
function M.in_remote_view(player)
	return player.controller_type == defines.controllers.remote
end

--- The player's inventory for the windows: their main inventory, else (remote view) their character's, else nil (no
--- character: editor, spectator). Issue #176.
function M.player_inventory(player)
	if not (player and player.valid) then return nil end
	local inv = player.get_main_inventory()
	if inv then return inv end
	local c = player.character
	return c and c.valid and c.get_inventory(defines.inventory.character_main) or nil
end

--- What a click in a window works with: the cursor stack, the player's inventory (nil when there is none) and whether
--- the player is in remote view. There the cursor is nil (the hand holds nothing: items never go through it, the game
--- would move them into the character's inventory unannounced) and the caller treats every take-out as a shift + click.
function M.hand(player)
	if M.in_remote_view(player) then return nil, M.player_inventory(player), true end
	return player.cursor_stack, M.player_inventory(player), false
end

--- the line that tells a player in remote view where a taken item went (issue #177)
function M.moved_text(player)
	player.create_local_flying_text{ text = { "fork-me-gui.moved-to-inventory" }, create_at_cursor = true }
end

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
	elseif act == "block_slot" then                 -- issue #28: the block's slots
		if event.name ~= defines.events.on_gui_click then return true end
		local frame, name = M.window_of(player)
		local def = name and windows[name]
		local entity = frame and M.entity_of(player, frame)
		local cursor, inv, remote = M.hand(player)
		if not entity then return true end
		local why, out = M.block_click(def, entity, el.tags.slot, cursor, inv, event.shift or remote)
		if remote and not why and out then M.moved_text(player) end
		refused(player, why, def)
		M.refresh_one(player)
		return true
	end
	local fn = actions[act]
	if not fn then return false end
	fn(event, player, el)
	return true
end

--- Issue #542: on_gui_inventory_action of the pane's inventory element: what the game leaves to the mod (shift + click,
--- control + click, their right click halves; in remote view every click) goes to the window's block (inventory_action),
--- a refusal says why. Returns true when the element is the mod's.
function M.on_inventory_action(event)
	local el = event.element
	if not (el and el.valid and el.tags and el.tags.fork_me_act == "inventory") then return false end
	local player = game.get_player(event.player_index)
	local frame, name = M.window_of(player)
	local def = name and windows[name]
	local entity = frame and M.entity_of(player, frame)
	if not entity then return true end
	local why = M.inventory_action(el.inventory, event.slot, event.action, def, entity, M.in_remote_view(player))
	refused(player, why, def)
	M.refresh_one(player)
	return true
end

--- Hooks that see an ME window being closed before it is treated as closed: fn(player, window) returns true when the
--- window is to stay (the picker of issue #94 takes the close keys of the popup above it)
local closed_hooks = {}
function M.on_window_closed(fn) closed_hooks[#closed_hooks + 1] = fn end

--- on_gui_closed: our window was closed (E, Escape, another GUI opened)
function M.on_closed(event)
	if event.gui_type == defines.gui_type.script_inventory then
		--- issue #542: the hand-over buffer of a window opened by 0.5.10 (a save loaded without on_configuration_changed, which
		--- closes it) was closed: its stacks go back to the player, its anchored frame goes (drop_buffer); and the frame anchored
		--- to a script inventory of a save made with #30
		local player = game.get_player(event.player_index)
		if player then M.drop_buffer(player) end
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
--- gone or out of reach; the pane follows the player's inventory (follow_inventory)
function M.refresh_all()
	local n = 0
	for _, player in pairs(game.connected_players) do
		if storage.fork_me_gui_parked then M.return_parked(player) end
		local picker = player.gui.screen.fork_me_picker      -- one that an Escape hid (scripts/fork-me-picker.lua)
		if picker and picker.valid and not picker.visible and picker.tags.cancel_tick ~= game.tick then picker.destroy() end
		for _, hook in ipairs(M.player_hooks) do hook(player) end
		local frame, name = M.window_of(player)
		if frame and n < REFRESH_MAX then
			n = n + 1
			local def = windows[name]
			if not def then
				M.close_window(player)
			elseif player.opened ~= frame then
				M.close_window(player)                     -- dying or another GUI closed it without an event
			else
				local ok = true
				for _, hook in ipairs(M.refresh_hooks) do
					if hook(player, frame) == false then ok = false end
				end
				ok = ok and (def.refresh and def.refresh(player, frame))
				if ok == false then
					M.close_window(player)
				elseif frame.valid then
					follow_inventory(player, frame)
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

--- Issue #179: a player was removed from the game: what the windows kept for them goes (the parked items of remote view and a
--- hand-over buffer of a 0.5.10 save, like the game drops a removed player's own inventory)
function M.forget_player(index)
	for _, key in ipairs({ "fork_me_gui_parked", "fork_me_gui_buffer" }) do
		local list = storage[key]
		local p = list and list[index]
		if p then
			if p.inv and p.inv.valid then p.inv.destroy() end
			list[index] = nil
		end
	end
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
	if not M.reachable(player, (via and via.valid) and via or e) then return nil end
	return e
end

--- Issue #206: may the player use the window of `anchor` from where they stand? In reach, or by a hook of `remote_reach` (the
--- wireless terminal: `anchor` is an access point in range of the player's linked terminal, which has energy).
M.remote_reach = {}
function M.reachable(player, anchor)
	if player.can_reach_entity(anchor) then return true end
	for _, f in ipairs(M.remote_reach) do
		if f(player, anchor) then return true end
	end
	return false
end

--- Issue #206: functions(player, frame) run at the refresh of every open window before the window's own (the wireless terminal
--- pays its energy there); one that returns false closes the window. And functions(player, entity) the open key tries first
--- (the wireless terminal: an item in the cursor is linked to the network of the clicked block); one that returns true ends it.
M.refresh_hooks = {}
M.open_key_hooks = {}
--- Issue #322: functions(player) run at the refresh for every connected player, window or not (the ME Interface's
--- tooltip in the world follows the entity the player points at)
M.player_hooks = {}

--- a "Back" button to the terminal for a window opened from one
function M.back_button(parent, via)
	if not via then return nil end
	return parent.add{ type = "button", caption = { "fork-me-gui.back" }, tags = M.act("back", { via = via }) }
end

--- after a mod update every open ME window is closed (a window built by an older version may lack elements; the
--- frames anchored beside a script inventory of #30 and the hand-over buffers of 0.5.10 too: close_window hands their
--- stacks back, issue #542); the pane's slot signatures of 0.5.10 and before (storage.fork_me_gui_pane) are dropped
function M.close_all()
	for _, player in pairs(game.players) do
		M.close_window(player)
	end
	local bs = storage.fork_me_gui_buffer                  -- (a buffer of a player that is gone: forget_player's rule)
	for index in pairs(bs or {}) do M.forget_player(index) end
	storage.fork_me_gui_buffer = nil
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
