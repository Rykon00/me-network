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
---   * Issue #28 (docs/ME-REWORK.md "Windows next to the player's inventory"): a window that shows an inventory is a
---     frame in player.gui.relative anchored to the game's window of a script inventory, which is the player's
---     `opened` GUI: the game shows the player's real inventory and the inventory's slots, the ME frame beside them.
---     The game raises no event for a change of a script inventory; the player's main inventory and cursor events
---     (on_inventory_changed) and the refresh call the window's sync(player, frame, inventory), which checks the slots
---     (what may not be there goes back: give_back) and makes the block's record follow them.
--- State: what a window shows lives in its elements' tags; the inventory of a player's open window in
--- storage.fork_me_gui_open[player_index] = { inventory, own (the player's own inventory: emptied and destroyed on
--- close), tick (opened) }.
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
--- windows: a frame beside the game's window of a script inventory (issue #28), or a screen frame
--------------------------------------------------------------------------------

--- the frame stands right of the game's window of a script inventory (the maintainer's probe on issue #28). The anchor
--- has no name, so it matches any script inventory: the frame exists only while ours is the opened GUI.
local ANCHOR = { gui = defines.relative_gui_type.script_inventory_gui, position = defines.relative_gui_position.right }

local function open_state()
	local s = storage.fork_me_gui_open
	if not s then
		s = {}
		storage.fork_me_gui_open = s
	end
	return s
end

--- the inventory of the player's open window (nil for a window without one), and its record
function M.inventory_of(player)
	local s = storage.fork_me_gui_open
	local r = s and s[player.index]
	if r and r.inventory and r.inventory.valid then return r.inventory, r end
	return nil
end

--- is `inventory` the player's opened GUI?
local function is_opened(player, inventory)
	return player.opened_gui_type == defines.gui_type.script_inventory and player.opened == inventory
end

--- the players whose open window shows `inventory` (two players at one block share the block's inventory)
function M.viewers(inventory)
	local out = {}
	for index, r in pairs(storage.fork_me_gui_open or {}) do
		if r.inventory and r.inventory.valid and r.inventory == inventory then
			local p = game.get_player(index)
			if p then out[#out + 1] = p end
		end
	end
	return out
end

--- the player's open ME window (or nil), and its name
function M.window_of(player)
	local frame = player.gui.relative.fork_me_window
	if frame and frame.valid then return frame, frame.tags.fork_me_window end
	frame = player.gui.screen.fork_me_window
	if frame and frame.valid then return frame, frame.tags.fork_me_window end
	return nil
end

--- Close the player's window: the window's sync and close run, an inventory of the player's own is emptied into the
--- player's inventory and destroyed, the frames go. `write_opened`: the opened GUI is set to nil when it is still the
--- window's inventory (not when the game closes it, nor when another window replaces it).
local function teardown(player, write_opened)
	local frame, name = M.window_of(player)
	local def = name and windows[name]
	local s = storage.fork_me_gui_open
	local r = s and s[player.index]
	if r then
		s[player.index] = nil
		local inv = r.inventory
		if inv and inv.valid then
			if def and frame then
				if def.sync then def.sync(player, frame, inv) end
				if def.close then def.close(player, frame, inv) end
			end
			if r.own then
				for i = 1, #inv do M.give_back(player, inv[i]) end
				inv.destroy()
			elseif write_opened and player.connected and is_opened(player, inv) then
				player.opened = nil
			end
		end
	end
	for _, root in pairs({ player.gui.relative, player.gui.screen }) do
		local f = root.fork_me_window
		if f and f.valid then f.destroy() end
	end
end

function M.close_window(player) teardown(player, true) end

--- A window: closes the player's ME window, builds frame, title bar and content frame. Returns the frame and the
--- content flow. `tags` go onto the frame (fork_me_window = name is added). With `inventory` (a script inventory) the
--- frame is anchored beside the game's window of it and the inventory becomes the player's opened GUI; `own`: it is the
--- player's own (emptied and destroyed on close). Without, a screen frame is the opened GUI (R3).
function M.open_window(player, name, caption, tags, inventory, own)
	teardown(player, false)
	local t = { fork_me_window = name, opened_tick = game.tick }
	for k, v in pairs(tags or {}) do t[k] = v end
	local frame
	if inventory then
		--- the record first: the on_gui_closed of the window this one replaces names the old inventory
		open_state()[player.index] = { inventory = inventory, own = own or nil, tick = game.tick }
		frame = player.gui.relative.add{ type = "frame", name = "fork_me_window", direction = "vertical", tags = t, anchor = ANCHOR }
	else
		frame = player.gui.screen.add{ type = "frame", name = "fork_me_window", direction = "vertical", tags = t }
	end
	local bar = frame.add{ type = "flow", direction = "horizontal" }
	if not inventory then bar.drag_target = frame end
	bar.style.horizontal_spacing = 8
	bar.add{ type = "label", caption = caption, style = "frame_title", ignored_by_interaction = true }
	local drag = bar.add{ type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true }
	drag.style.horizontally_stretchable = true
	drag.style.height = 24
	drag.style.right_margin = 4
	bar.add{ type = "sprite-button", style = "frame_action_button", sprite = "utility/close",
		tooltip = { "gui.close-instruction" }, tags = M.act("close") }
	local inner = frame.add{ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" }
	local content = inner.add{ type = "flow", name = "fork_me_content", direction = "vertical" }
	content.style.vertical_spacing = 6
	if inventory then
		if not is_opened(player, inventory) then player.opened = inventory end
	else
		frame.auto_center = true
		player.opened = frame
	end
	return frame, content
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

--- A slot button for an item or fluid (`key`: item name, "name@quality" or "fluid/<name>"), with the amount
--- formatted in the tooltip and the button's number. `style` defaults to slot_button.
function M.slot(parent, key, amount, tags, style, extra_tooltip)
	local def = { type = "sprite-button", style = style or "slot_button", tags = tags }
	if key then
		if key:sub(1, 6) == "fluid/" then
			local name = key:sub(7)
			local proto = prototypes.fluid[name]
			if proto then def.sprite = "fluid/" .. name end
			def.tooltip = { "", proto and proto.localised_name or name, amount and (": " .. M.fmt(amount)) or "", extra_tooltip or "" }
		else
			local name, q = key:match("^([^@#]+)@?([^#]*)")
			q = (q and q ~= "") and q or "normal"
			if prototypes.item[name] and prototypes.quality[q] then
				def.sprite = "item/" .. name
				def.elem_tooltip = { type = "item-with-quality", name = name, quality = q }
				if extra_tooltip then def.tooltip = extra_tooltip end
			else
				def.tooltip = key                     -- the prototype is gone (a mod was removed)
			end
		end
	end
	if amount then def.number = math.floor(amount) end
	return parent.add(def)
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
--- or ME kinds } }; refresh returns false to close the window
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
		local inv = M.inventory_of(player)            -- already open (the open key and on_gui_opened both fire)
		if not inv then player.opened = frame elseif not is_opened(player, inv) then player.opened = inv end
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
	end
	local fn = actions[act]
	if not fn then return false end
	fn(event, player, el)
	return true
end

--- on_gui_closed: our window was closed (E, Escape, another GUI opened)
function M.on_closed(event)
	if event.gui_type == defines.gui_type.script_inventory then
		local player = game.get_player(event.player_index)
		local s = storage.fork_me_gui_open
		local r = player and s and s[player.index]
		if not r then return false end
		local inv, closed = r.inventory, event.inventory
		if not (inv and inv.valid) then                   -- the block was removed: its inventory went with it
			teardown(player, false)
			return true
		end
		if not (closed and closed.valid and closed == inv) then return false end
		--- the open key's own game action can close the window in the tick it was opened: keep it open then
		if r.tick == game.tick then
			player.opened = inv
			return true
		end
		teardown(player, false)
		return true
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
		el.destroy()
		return true
	end
	return false
end

--- every 60 ticks (terminal module): refresh the open windows (one per player), close those whose entity is
--- gone or out of reach
function M.refresh_all()
	local n = 0
	for _, player in pairs(game.connected_players) do
		local frame, name = M.window_of(player)
		local inv = M.inventory_of(player)
		local s = storage.fork_me_gui_open
		local stale = s and s[player.index] and not inv     -- (the block and its inventory were removed)
		if (frame or inv or stale) and n < REFRESH_MAX then
			n = n + 1
			local def = frame and windows[name]
			if not def or stale then
				teardown(player, true)
			elseif inv then
				if not is_opened(player, inv) then
					teardown(player, false)                    -- dying or another GUI closed it without an event
				else
					if def.sync then def.sync(player, frame, inv) end   -- (the backstop: a move inside the inventory)
					if frame.valid and def.refresh and def.refresh(player, frame) == false then teardown(player, true) end
				end
			elseif player.opened ~= frame then
				frame.destroy()                            -- dying or another GUI closed it without an event
			else
				local ok = def.refresh and def.refresh(player, frame)
				if ok == false then frame.destroy() end
			end
		end
	end
end

--- refresh the player's window now (after a button changed something)
function M.refresh_one(player)
	local frame, name = M.window_of(player)
	local def = frame and windows[name]
	if def and def.refresh and def.refresh(player, frame) == false and frame.valid then teardown(player, true) end
end

--- refresh every window that shows `inventory`
function M.refresh_viewers(inventory)
	for _, p in ipairs(M.viewers(inventory)) do M.refresh_one(p) end
end

--- on_player_main_inventory_changed, on_player_cursor_stack_changed: the player may have moved an item into or out of
--- the inventory of the open window. The window's sync checks the slots; when it changed something every window on the
--- same inventory is refreshed. A player without an ME window inventory costs one lookup.
function M.on_inventory_changed(event)
	local s = storage.fork_me_gui_open
	local r = s and s[event.player_index]
	if not (r and r.inventory and r.inventory.valid) then return end
	local player = game.get_player(event.player_index)
	local frame, name = M.window_of(player)
	local def = frame and windows[name]
	if not (def and def.sync) then return end
	if def.sync(player, frame, r.inventory) then M.refresh_viewers(r.inventory) end
end

--- a player left the game (no on_gui_closed then): the window closes, an inventory of their own is emptied first
function M.on_left(player)
	if player and player.valid then teardown(player, false) end
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

--- after a mod update every open ME window is closed (a window built by an older version may lack elements)
function M.close_all()
	for _, player in pairs(game.players) do teardown(player, true) end
end

return M
